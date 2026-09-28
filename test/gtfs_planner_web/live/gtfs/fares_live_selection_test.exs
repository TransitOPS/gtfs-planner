defmodule GtfsPlannerWeb.Gtfs.FaresLiveSelectionTest do
  @moduledoc """
  Merge evidence (EV-16) for the Zones tab's stop selection and selection bar.

  Every case mounts the real route and reads the version's real data through the
  default `CatalogReadAdapter.Repo` adapter, so the rows, the counts and the
  "N matching" the head offers come from `FareZones.list_stops/3`,
  `FareZones.matching_stop_ids/3` and the inventory rather than from the
  component's own output. Each control is used through the element it renders:
  a row's checkbox, the head's two select actions, the bar's Clear. The two
  cases whose payload a row cannot produce send the event directly, because a
  browser holding a stop ID from another tenant is exactly what they model.

  The selection is server state and must not reach the URL, so the cases assert
  both what the bar says and what the rows render: the fixture pages 150 stops in
  one zone so page 1 holds 100 and page 2 holds 50, which is what makes "the
  whole match" observable as something other than "the page".

  Expected text is written the way `Phoenix.LiveViewTest` compares it: rendered
  text is whitespace-normalized, so padded zone IDs would be read from the HTML
  instead of through a text filter; this file has no padded ID and reads the
  selection's own state from the rendered checkbox attributes.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @east_count 150

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "B", "Eastbank", "teal")

    # 150 boardable stops in one zone: page 1 holds 100 of them, page 2 holds 50,
    # so "select the page" and "select all matching" are two different sets.
    east =
      for index <- 1..@east_count do
        located_stop("STOP_B_#{pad(index)}", "Riverside #{pad(index)}", "B")
      end

    # A station is not boardable: it never renders, and its UUID is never a
    # valid selection even though it carries this version's zone A.
    central = [
      located_stop("HARBOR", "Harbor Point", "A"),
      located_stop("CENTRAL_STATION", "Central Union Station", "A")
      |> Map.put(:location_type, 1)
    ]

    unassigned = [
      located_stop("GATE_50%", "Gate 50%", nil),
      %{stop_id: "DEPOT", stop_name: "Depot Yard", zone_id: nil, located_at: {nil, nil}}
    ]

    rows = insert_stops(organization, version, east ++ central ++ unassigned)

    # The same organization's other version carries a stop whose UUID is real but
    # belongs to another version, and another organization carries a stop of its
    # own: neither may enter this version's selection.
    other_version = gtfs_version_fixture(organization.id)

    [other_version_stop] =
      insert_stops(organization, other_version, [
        located_stop("HARBOR", "Other Version Harbor", "A")
      ])

    other_organization = organization_fixture()
    other_org_version = gtfs_version_fixture(other_organization.id)

    [foreign_stop] =
      insert_stops(other_organization, other_org_version, [
        located_stop("FOREIGN", "Other Tenant Stop", "A")
      ])

    %{
      user: user,
      organization: organization,
      version: version,
      other_version_stop: other_version_stop,
      foreign_stop: foreign_stop,
      stop_ids: Map.new(rows, &{&1.stop_id, &1.id}),
      stop_id_by_row_id: Map.new(rows, &{&1.id, &1.stop_id})
    }
  end

  describe "checkboxes" do
    test "a row's checkbox selects that stop and the bar counts one stop", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      # Nothing selected: the reference's hint, and no count line.
      assert bar_hint(view) == "Select stops to assign or remove a fare zone."
      refute has_element?(view, "#fare-zone-selection-count")
      refute has_element?(view, "#fare-zone-selection-outside")

      # Every row carries a checkbox named by its stop, and none is checked.
      assert has_element?(view, "#fare-zone-stops-container thead th", "Select")
      assert length(checkbox_states(view)) == 100
      assert checked_stop_ids(view, stop_id_by_row_id) == []

      toggle_stop(view, stop_ids["HARBOR"])

      assert checked_stop_ids(view, stop_id_by_row_id) == ["HARBOR"]
      assert bar_count(view) == "1 stop selected"

      # The selected stop is inside the current filter (All stops), so nothing is
      # hidden from it.
      refute has_element?(view, "#fare-zone-selection-outside")

      # A second checkbox adds to the selection rather than replacing it.
      toggle_stop(view, stop_ids["DEPOT"])

      assert checked_stop_ids(view, stop_id_by_row_id) == ["DEPOT", "HARBOR"]
      assert bar_count(view) == "2 stops selected"

      # Toggling the same row again removes exactly that stop.
      toggle_stop(view, stop_ids["HARBOR"])

      assert checked_stop_ids(view, stop_id_by_row_id) == ["DEPOT"]
      assert bar_count(view) == "1 stop selected"
    end

    test "the selection never reaches the URL", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=B")

      base_hrefs = Enum.map(1..2, &row_href(view, "#fare-zone-row-#{&1}"))

      toggle_stop(view, stop_ids["STOP_B_001"])
      render_click(view, "select_matching")

      # A selection is a socket's state: no patch, no query string, and the
      # inventory's own links keep the zone they carried.
      assert bar_count(view) == "150 stops selected"
      assert Enum.map(1..2, &row_href(view, "#fare-zone-row-#{&1}")) == base_hrefs
      refute render(view) =~ "selection="
      # The drawer's own palette keeps an `<option selected>` in the page even
      # when closed, so probe the query-string form the URL would carry.
      refute render(view) =~ "?selected="
    end
  end

  describe "the page and the whole match" do
    test "Select 100 shown selects only the current page", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      # 153 boardable stops, one page of 100: the head's two actions differ.
      assert has_element?(view, "#fare-zone-stop-head", "153 shown")
      assert has_element?(view, "#fare-zone-select-shown", "Select 100 shown")
      assert has_element?(view, "#fare-zone-select-matching", "Select all 153 matching")

      view |> element("#fare-zone-select-shown") |> render_click()

      assert bar_count(view) == "100 stops selected"
      assert length(checked_stop_ids(view, stop_id_by_row_id)) == 100

      # The list is still one page, and the match is not what got selected: page 2
      # holds the other 53 stops, none of them selected.
      assert has_element?(view, "#fare-zone-stops-pagination", "Showing 1–100 of 153 stops")

      view
      |> element("#fare-zone-stops-pagination button[phx-value-page='2']")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?page=2")

      page_two = visible_stop_ids(view, stop_id_by_row_id)

      assert length(page_two) == 53
      assert checked_stop_ids(view, stop_id_by_row_id) == []
      assert bar_count(view) == "100 stops selected"

      # Selecting the page again adds it, so the whole version is selected.
      view |> element("#fare-zone-select-shown") |> render_click()

      assert bar_count(view) == "153 stops selected"
      assert length(checked_stop_ids(view, stop_id_by_row_id)) == 53
    end

    test "Select all 150 matching selects every stop of the filter and search", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=B")

      assert has_element?(view, "#fare-zone-select-matching", "Select all 150 matching")
      assert length(visible_stop_ids(view, stop_id_by_row_id)) == 100

      view |> element("#fare-zone-select-matching") |> render_click()

      assert bar_count(view) == "150 stops selected"
      assert length(checked_stop_ids(view, stop_id_by_row_id)) == 100

      # The 50 stops page 1 does not render are selected too.
      view
      |> element("#fare-zone-stops-pagination button[phx-value-page='2']")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=B&page=2")

      page_two = visible_stop_ids(view, stop_id_by_row_id)

      assert length(page_two) == 50
      assert List.first(page_two) == "STOP_B_101"
      assert checked_stop_ids(view, stop_id_by_row_id) == page_two
      assert bar_count(view) == "150 stops selected"

      # A search narrows the match the action offers and selects.
      view |> form("#fare-zone-search-form", %{"q" => "Riverside 150"}) |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=B&q=Riverside+150")

      assert has_element?(view, "#fare-zone-select-matching", "Select all 1 matching")
      assert has_element?(view, "#fare-zone-select-shown", "Select 1 shown")

      view |> element("#fare-zone-clear-selection") |> render_click()
      view |> element("#fare-zone-select-matching") |> render_click()

      assert bar_count(view) == "1 stop selected"
      assert checked_stop_ids(view, stop_id_by_row_id) == ["STOP_B_150"]
    end
  end

  describe "persistence" do
    test "a selection survives a page and a filter, and the bar counts what the filter hides", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      toggle_stop(view, stop_ids["STOP_B_001"])

      assert bar_count(view) == "1 stop selected"

      # Page 2 of the same filter: the stop is not rendered, the selection is not
      # lost, and the bar still owns it.
      view
      |> element("#fare-zone-stops-pagination button[phx-value-page='2']")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?page=2")
      assert bar_count(view) == "1 stop selected"
      assert checked_stop_ids(view, stop_id_by_row_id) == []
      refute has_element?(view, "#fare-zone-selection-outside")

      # The filter still contains it, and page 1 renders it checked again.
      render_patch(view, row_href(view, "#fare-zone-row-2"))

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=B")
      assert has_element?(view, "#fare-zone-stage-title", "Eastbank")
      assert length(visible_stop_ids(view, stop_id_by_row_id)) == 100
      assert checked_stop_ids(view, stop_id_by_row_id) == ["STOP_B_001"]
      assert bar_count(view) == "1 stop selected"

      # A filter that does not contain the selected stop keeps the selection and
      # discloses that the filter cannot show it.
      render_patch(view, row_href(view, "#fare-zone-row-1"))

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=A")
      assert visible_stop_ids(view, stop_id_by_row_id) == ["HARBOR"]
      assert bar_count(view) == "1 stop selected"
      assert bar_outside(view) == "1 outside current filter"
      assert checked_stop_ids(view, stop_id_by_row_id) == []

      # The unassigned filter hides it too, entered through the link the panel
      # shipped.
      render_patch(view, row_href(view, "#fare-zone-row-unassigned"))

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?filter=unassigned")
      assert bar_outside(view) == "1 outside current filter"

      # A search that no longer matches it does the same.
      render_patch(view, row_href(view, "#fare-zone-row-all"))

      view |> form("#fare-zone-search-form", %{"q" => "Riverside 002"}) |> render_change()

      assert visible_stop_ids(view, stop_id_by_row_id) == ["STOP_B_002"]
      assert bar_count(view) == "1 stop selected"
      assert bar_outside(view) == "1 outside current filter"

      # A filter that holds the whole selection reports nothing hidden.
      view |> element("#fare-zone-clear-selection") |> render_click()
      view |> element("#fare-zone-select-shown") |> render_click()

      assert bar_count(view) == "1 stop selected"
      refute has_element?(view, "#fare-zone-selection-outside")
    end
  end

  describe "clear" do
    test "Clear empties the selection and the bar shows the reference's hint", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      toggle_stop(view, stop_ids["HARBOR"])
      toggle_stop(view, stop_ids["DEPOT"])

      assert checked_stop_ids(view, stop_id_by_row_id) == ["DEPOT", "HARBOR"]
      assert has_element?(view, "#fare-zone-clear-selection", "Clear")

      view |> element("#fare-zone-clear-selection") |> render_click()

      assert bar_hint(view) == "Select stops to assign or remove a fare zone."
      refute has_element?(view, "#fare-zone-selection-count")
      refute has_element?(view, "#fare-zone-clear-selection")
      assert checked_stop_ids(view, stop_id_by_row_id) == []
      assert length(checkbox_states(view)) == 100
    end
  end

  describe "a toggle that arrives from a browser" do
    test "an ID outside this version's boardable stops changes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      other_version_stop: other_version_stop,
      foreign_stop: foreign_stop,
      stop_ids: stop_ids,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      toggle_stop(view, stop_ids["HARBOR"])
      assert bar_count(view) == "1 stop selected"

      # Another organization's stop, this organization's other version, this
      # version's own station (not boardable), a value that is not a UUID at all
      # and a payload with no ID: each leaves the selection exactly as it was.
      for id <- [
            foreign_stop.id,
            other_version_stop.id,
            stop_ids["CENTRAL_STATION"],
            "not-a-uuid",
            ""
          ] do
        render_click(view, "toggle_stop", %{"id" => id})
        assert bar_count(view) == "1 stop selected"
        assert checked_stop_ids(view, stop_id_by_row_id) == ["HARBOR"]
      end

      render_click(view, "toggle_stop", %{})
      assert bar_count(view) == "1 stop selected"

      # The same events against an empty selection cannot create one either.
      view |> element("#fare-zone-clear-selection") |> render_click()

      for id <- [foreign_stop.id, other_version_stop.id, "not-a-uuid"] do
        render_click(view, "toggle_stop", %{"id" => id})
        assert bar_hint(view) == "Select stops to assign or remove a fare zone."
        assert checked_stop_ids(view, stop_id_by_row_id) == []
      end

      # A crafted event cannot reach another version either: the same UUID is a
      # real stop there, but never one of this version's.
      {:ok, other_view, _html} =
        live(conn, "/gtfs/#{version.id}/settings/fares?zone=A")

      render_click(other_view, "toggle_stop", %{"id" => foreign_stop.id})
      assert bar_hint(other_view) == "Select stops to assign or remove a fare zone."
    end

    test "a stop that left the version cannot be toggled back in", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      toggle_stop(view, stop_ids["HARBOR"])
      assert bar_count(view) == "1 stop selected"

      # The row disappears (another editor removed the stop); the selection keeps
      # it, and the bar says the filter cannot show it.
      {1, nil} =
        Repo.delete_all(from(s in Stop, where: s.id == ^stop_ids["HARBOR"]))

      render_patch(view, row_href(view, "#fare-zone-row-1"))

      assert bar_count(view) == "1 stop selected"
      assert bar_outside(view) == "1 outside current filter"
      refute has_element?(view, "#stops-#{stop_ids["HARBOR"]}")

      # The vanished ID cannot enter the selection again - it is no longer a stop
      # of this version - while the operator can still dismiss what they selected.
      render_click(view, "toggle_stop", %{"id" => stop_ids["HARBOR"]})

      assert bar_hint(view) == "Select stops to assign or remove a fare zone."

      render_click(view, "toggle_stop", %{"id" => stop_ids["HARBOR"]})

      assert bar_hint(view) == "Select stops to assign or remove a fare zone."
      assert checked_stop_ids(view, stop_id_by_row_id) == []
    end
  end

  # The rendered href of one inventory row. The panel owns the encoding, so the
  # tests enter a filter through the link it produced rather than by rebuilding
  # the URL.
  defp row_href(view, selector) do
    [href] = attribute(view, selector, "href")
    href
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  # The stop IDs of the rendered rows, in document order. Rows carry their
  # stop's UUID as the DOM ID, never a zone ID.
  defp visible_stop_ids(view, stop_id_by_row_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> row_uuids()
    |> Enum.map(&Map.fetch!(stop_id_by_row_id, &1))
  end

  # The stop IDs whose rendered checkbox is checked. The server re-streams the
  # page on every selection change, so this is the same state the bar counts.
  defp checked_stop_ids(view, stop_id_by_row_id) do
    doc = view |> render() |> LazyHTML.from_fragment()

    doc
    |> row_uuids()
    |> Enum.filter(&row_checked?(doc, &1))
    |> Enum.map(&Map.fetch!(stop_id_by_row_id, &1))
  end

  # Every rendered checkbox as `{stop UUID, checked?}`, so a case can prove the
  # count of boxes and that an unchecked row renders no `checked` attribute.
  defp checkbox_states(view) do
    doc = view |> render() |> LazyHTML.from_fragment()

    doc
    |> row_uuids()
    |> Enum.map(fn uuid -> {uuid, row_checked?(doc, uuid)} end)
  end

  defp row_uuids(doc) do
    doc
    |> LazyHTML.query("#fare-zone-stops tr")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn "stops-" <> uuid -> uuid end)
  end

  defp row_checked?(doc, uuid) do
    doc
    |> LazyHTML.query("#stops-#{uuid} input[type='checkbox']")
    |> LazyHTML.attribute("checked")
    |> Enum.any?()
  end

  # The bar's own lines, read one at a time: the bar also holds the Clear
  # button, which is not part of either count.
  defp bar_hint(view), do: text_of(view, "#fare-zone-selection-hint")
  defp bar_count(view), do: text_of(view, "#fare-zone-selection-count")
  defp bar_outside(view), do: text_of(view, "#fare-zone-selection-outside")

  defp text_of(view, selector) do
    value =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if value == "", do: nil, else: value
  end

  defp toggle_stop(view, uuid) do
    view
    |> element("#stops-#{uuid} input[type='checkbox']")
    |> render_click()
  end

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn stop ->
        {lat, lon} = Map.get(stop, :located_at, {nil, nil})

        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop.stop_id,
          stop_name: stop.stop_name,
          location_type: Map.get(stop, :location_type, 0),
          zone_id: Map.get(stop, :zone_id),
          stop_lat: decimal(lat),
          stop_lon: decimal(lon),
          parent_station: Map.get(stop, :parent_station),
          platform_code: Map.get(stop, :platform_code),
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
    rows
  end

  defp insert_zone(organization, version, zone_id, name, color) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareZone, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          zone_id: zone_id,
          name: name,
          color: color,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp located_stop(stop_id, stop_name, zone_id),
    do: %{stop_id: stop_id, stop_name: stop_name, zone_id: zone_id, located_at: {42.3, -71.1}}

  defp pad(index), do: String.pad_leading(Integer.to_string(index), 3, "0")

  defp decimal(nil), do: nil
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value), do: Decimal.new(value)
end
