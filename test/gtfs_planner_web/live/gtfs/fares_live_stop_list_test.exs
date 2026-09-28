defmodule GtfsPlannerWeb.Gtfs.FaresLiveStopListTest do
  @moduledoc """
  Merge evidence (EV-15) for the Zones tab's searchable, paginated stop list.

  Every case mounts the real route and reads the version's real data through the
  default `CatalogReadAdapter.Repo` adapter, so the rows, counts and zone names
  come from `FareZones.list_stops/3` and the inventory rather than from the
  component's own output. The fixture carries the shapes the criteria name: 150
  boardable stops in one zone (so page 2 of a 100-row page holds 50), a zone
  whose ID holds a space next to the same ID without it, a platform under a
  station, a stop without coordinates, a declared zone with no stops, stops with
  no zone, and a search term containing `%`.

  Each control is used through the element it renders - the search form patches
  `?q=` and the pagination buttons patch `?page=` - and each filter is entered
  through the href the inventory shipped, so no case can pass by rebuilding a URL
  the page never produced.

  Expected text is written the way `Phoenix.LiveViewTest` compares it: the
  rendered text is whitespace-normalized, so a byte-exact padded ID is read from
  the rendered HTML instead of through a text filter.
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

    # " A" and "A" are two zones with two rows: no path may trim an existing ID.
    insert_zone(organization, version, " A", "Padded", "plum")
    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "B", "Eastbank", "teal")
    insert_zone(organization, version, "C", "Cedar", "ochre")

    # 150 boardable stops in one zone, so a page holds 100 and page 2 holds 50.
    east =
      for index <- 1..@east_count do
        located_stop("STOP_B_#{pad(index)}", "Riverside #{pad(index)}", "B")
      end

    # A station is not boardable, so it never appears in the list; the platform
    # under it does, marked as assigned separately.
    local = [
      located_stop("STOP_PAD", "Padded Stop", " A"),
      located_stop("HARBOR", "Harbor Point", "A"),
      located_stop("PLATFORM_1", "Central Union Platform 1", "A")
      |> Map.merge(%{parent_station: "CENTRAL_STATION", platform_code: "1"}),
      located_stop("CENTRAL_STATION", "Central Union Station", "A")
      |> Map.put(:location_type, 1),
      located_stop("GATE_50%", "Gate 50%", nil),
      located_stop("GATE_500", "Gate 500", nil),
      %{stop_id: "DEPOT", stop_name: "Depot Yard", zone_id: nil, located_at: {nil, nil}}
    ]

    rows = insert_stops(organization, version, east ++ local)

    # A second version of the same organization carries one stop with this
    # version's Harbor Point stop ID: no version's rows may leak into another's
    # list.
    other_version = gtfs_version_fixture(organization.id)

    [other_harbor] =
      insert_stops(organization, other_version, [
        located_stop("HARBOR", "Other Version Harbor", "A")
      ])

    %{
      user: user,
      organization: organization,
      version: version,
      other_version: other_version,
      other_harbor: other_harbor,
      stop_ids: Map.new(rows, &{&1.stop_id, &1.id}),
      stop_id_by_row_id: Map.new(rows, &{&1.id, &1.stop_id})
    }
  end

  describe "search" do
    test "the search form patches ?q=, lists only matches and drops the page", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/settings/fares?zone=B&page=2")

      assert search_value(view) == ""
      assert has_element?(view, "#fare-zone-without-location", "0 without map location")
      assert has_element?(view, "#fare-zone-stops-pagination", "Showing 101–150 of 150 stops")

      view
      |> form("#fare-zone-search-form", %{"q" => "Riverside 150"})
      |> render_change()

      # The filter and the search both survive, the page does not: a narrowed
      # list starts at its own first page.
      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=B&q=Riverside+150")

      assert search_value(view) == "Riverside 150"
      assert visible_stop_ids(view, stop_id_by_row_id) == ["STOP_B_150"]
      assert has_element?(view, "#fare-zone-stop-head", "1 shown")
      assert has_element?(view, "#fare-zone-stops-pagination", "Showing 1–1 of 1 stops")
      assert has_element?(view, "#fare-zone-stage-title", "Eastbank")
    end

    test "a search term is matched literally and kept byte-for-byte", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      view
      |> form("#fare-zone-search-form", %{"q" => "50%"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?q=50%25")

      # `%` reaches the query as the character the operator typed, so it matches
      # "Gate 50%" and not "Gate 500".
      assert search_value(view) == "50%"
      assert visible_stop_ids(view, stop_id_by_row_id) == ["GATE_50%"]
    end

    test "a search that matches nothing shows its own empty state and clears to All stops", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=B")

      view
      |> form("#fare-zone-search-form", %{"q" => "zzzz"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=B&q=zzzz")

      refute has_element?(view, "#fare-zone-stops")
      assert has_element?(view, "#fare-zone-stops-empty", "No stops match your search")
      assert has_element?(view, "#fare-zone-stops-empty", "Try a stop name or ID")

      # The unlocated count belongs to the filter, not to the search, so it stays
      # the zone's own count while nothing matches.
      assert has_element?(view, "#fare-zone-without-location", "0 without map location")
      assert has_element?(view, "#fare-zone-stop-head", "0 shown")

      # One action leaves both the search and the filter, which is what the
      # operator has to do to see stops again.
      assert empty_action_href(view) == "/gtfs/#{version.id}/settings/fares"

      render_patch(view, empty_action_href(view))

      assert search_value(view) == ""
      assert has_element?(view, "#fare-zone-row-all[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "All stops")
      assert length(visible_stop_ids(view, stop_id_by_row_id)) == 100
      refute has_element?(view, "#fare-zone-stops-empty")
    end
  end

  describe "pagination" do
    test "page 2 of 150 stops holds 50 rows, and Previous and Next patch ?page=", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      assert row_href(view, "#fare-zone-row-3") == "/gtfs/#{version.id}/settings/fares?zone=B"
      render_patch(view, row_href(view, "#fare-zone-row-3"))

      assert has_element?(view, "#fare-zone-stop-head", "150 shown")
      assert has_element?(view, "#fare-zone-stops-pagination", "Showing 1–100 of 150 stops")

      # One page of rows, never the whole match: the list is bounded by the page.
      assert length(visible_stop_ids(view, stop_id_by_row_id)) == 100
      assert List.first(visible_stop_ids(view, stop_id_by_row_id)) == "STOP_B_001"

      view
      |> element("#fare-zone-stops-pagination button[phx-value-page='2']")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=B&page=2")

      page_two = visible_stop_ids(view, stop_id_by_row_id)

      assert length(page_two) == 50
      assert List.first(page_two) == "STOP_B_101"
      assert List.last(page_two) == "STOP_B_150"
      assert has_element?(view, "#fare-zone-stops-pagination", "Showing 101–150 of 150 stops")

      # Previous patches the page it returns to.
      view
      |> element("#fare-zone-stops-pagination button[phx-value-page='1']")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=B&page=1")
      assert List.first(visible_stop_ids(view, stop_id_by_row_id)) == "STOP_B_001"
    end

    test "a page past the end is clamped to the last page", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=B&page=99")

      assert has_element?(view, "#fare-zone-stop-head", "150 shown")
      assert has_element?(view, "#fare-zone-stops-pagination", "Showing 101–150 of 150 stops")
      assert length(visible_stop_ids(view, stop_id_by_row_id)) == 50
      assert List.first(visible_stop_ids(view, stop_id_by_row_id)) == "STOP_B_101"
    end
  end

  describe "rows" do
    test "a platform row names its assignment and an unlocated stop names its list selection", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      assert has_element?(
               view,
               "#stops-#{stop_ids["PLATFORM_1"]}",
               "Platform · assigned separately"
             )

      assert has_element?(
               view,
               "#stops-#{stop_ids["DEPOT"]}",
               "No map location · list selection available"
             )

      # A located stop that is not a platform carries neither subtext.
      assert has_element?(view, "#stops-#{stop_ids["HARBOR"]}", "Harbor Point")

      refute has_element?(
               view,
               "#stops-#{stop_ids["HARBOR"]}",
               "Platform · assigned separately"
             )

      refute has_element?(
               view,
               "#stops-#{stop_ids["HARBOR"]}",
               "No map location · list selection available"
             )

      refute has_element?(
               view,
               "#stops-#{stop_ids["PLATFORM_1"]}",
               "No map location · list selection available"
             )
    end

    test "each row names its zone with the zone's exact ID, name and color", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      # The padded zone and the plain one are two zones, so their rows disagree.
      assert has_element?(view, "#stops-#{stop_ids["STOP_PAD"]}", "Padded")
      assert has_element?(view, "#stops-#{stop_ids["STOP_PAD"]}", "Padded Stop")
      assert has_element?(view, "#stops-#{stop_ids["HARBOR"]}", "Central")
      refute has_element?(view, "#stops-#{stop_ids["STOP_PAD"]}", "Central")
      refute has_element?(view, "#stops-#{stop_ids["HARBOR"]}", "Padded")

      chip = zone_chip_html(view, stop_ids["STOP_PAD"])

      assert chip =~ " A"
      assert chip =~ ~s(style="color: #4b1f78; background-color: #4b1f781a")

      # A stop without a zone gets the neutral chip with the dash the reference
      # draws, and the zone cell names it Unassigned.
      assert has_element?(view, "#stops-#{stop_ids["DEPOT"]}", "Unassigned")
      assert zone_chip_html(view, stop_ids["DEPOT"]) =~ "–"
      refute zone_chip_html(view, stop_ids["DEPOT"]) =~ "color: #"
    end

    test "a station, another version's stops and a trimmed zone filter never change the list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids,
      stop_id_by_row_id: stop_id_by_row_id,
      other_harbor: other_harbor
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      # 157 boardable stops: 150 in Eastbank, 2 in Central, 1 in Padded and 3
      # with no zone. The station is not one of them, and the other version's
      # stop of the same stop ID is not either.
      assert has_element?(view, "#fare-zone-stop-head", "157 shown")
      refute has_element?(view, "#stops-#{stop_ids["CENTRAL_STATION"]}")
      refute has_element?(view, "#stops-#{other_harbor.id}")
      refute render(view) =~ "Other Version Harbor"

      # The shipped links prove the byte-exact IDs and the encoded zone query.
      assert Enum.map(1..4, &row_href(view, "#fare-zone-row-#{&1}")) == [
               "/gtfs/#{version.id}/settings/fares?zone=+A",
               "/gtfs/#{version.id}/settings/fares?zone=A",
               "/gtfs/#{version.id}/settings/fares?zone=B",
               "/gtfs/#{version.id}/settings/fares?zone=C"
             ]

      render_patch(view, row_href(view, "#fare-zone-row-1"))

      assert visible_stop_ids(view, stop_id_by_row_id) == ["STOP_PAD"]
      assert render(view) =~ "1 stop · Zone ID  A"

      render_patch(view, row_href(view, "#fare-zone-row-2"))

      assert visible_stop_ids(view, stop_id_by_row_id) == ["PLATFORM_1", "HARBOR"]
      assert has_element?(view, "#fare-zone-stage-subtitle", "2 stops · Zone ID A")
    end
  end

  describe "filtered empty states" do
    test "a zone with no stops offers Show all stops", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      render_patch(view, row_href(view, "#fare-zone-row-4"))

      assert_patched(view, "/gtfs/#{version.id}/settings/fares?zone=C")

      refute has_element?(view, "#fare-zone-stops")
      assert has_element?(view, "#fare-zone-stops-empty", "No stops in this zone yet")

      assert has_element?(
               view,
               "#fare-zone-stops-empty",
               "Select stops from All stops, then assign them to this zone."
             )

      assert has_element?(view, "#fare-zone-stops-empty-action", "Show all stops")
      assert empty_action_href(view) == "/gtfs/#{version.id}/settings/fares"

      render_patch(view, empty_action_href(view))

      assert has_element?(view, "#fare-zone-row-all[aria-current='page']")
      assert has_element?(view, "#fare-zone-stop-head", "157 shown")
    end

    test "a filter with nothing unassigned names that", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids,
      stop_id_by_row_id: stop_id_by_row_id
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?filter=unassigned")

      assert has_element?(view, "#fare-zone-stop-head", "3 shown")
      assert has_element?(view, "#fare-zone-without-location", "1 without map location")
      assert visible_stop_ids(view, stop_id_by_row_id) == ["GATE_50%", "GATE_500", "DEPOT"]

      unassigned_ids = Enum.map(["DEPOT", "GATE_50%", "GATE_500"], &stop_ids[&1])

      {3, nil} =
        Repo.update_all(
          from(s in Stop, where: s.id in ^unassigned_ids),
          set: [zone_id: "A"]
        )

      render_patch(view, "/gtfs/#{version.id}/settings/fares?zone=C")
      render_patch(view, "/gtfs/#{version.id}/settings/fares?filter=unassigned")

      refute has_element?(view, "#fare-zone-stops")
      assert has_element?(view, "#fare-zone-stops-empty", "No unassigned stops")

      assert has_element?(
               view,
               "#fare-zone-stops-empty",
               "Every stop in this version has a fare zone."
             )

      assert has_element?(view, "#fare-zone-stops-empty-action", "Show all stops")
      assert has_element?(view, "#fare-zone-without-location", "0 without map location")
      assert has_element?(view, "#fare-zone-row-unassigned-count", "0")
    end

    test "a version with no boardable stops shows the first-use copy without an action", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      empty_version = gtfs_version_fixture(organization.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{empty_version.id}/settings/fares")

      refute has_element?(view, "#fare-zone-stops")
      assert has_element?(view, "#fare-zone-stops-empty", "No stops yet")

      assert has_element?(
               view,
               "#fare-zone-stops-empty",
               "Stops appear here after you import a GTFS feed."
             )

      refute has_element?(view, "#fare-zone-stops-empty-action")
      assert has_element?(view, "#fare-zone-stop-head", "0 shown")
      assert has_element?(view, "#fare-zone-without-location", "0 without map location")
    end
  end

  # The rendered href of one inventory row. The panel owns the encoding, so the
  # tests enter a filter through the link it produced rather than by rebuilding
  # the URL.
  defp row_href(view, selector) do
    [href] = attribute(view, selector, "href")
    href
  end

  defp empty_action_href(view), do: row_href(view, "#fare-zone-stops-empty-action")

  defp search_value(view) do
    case attribute(view, "#fare-zone-search", "value") do
      [value] -> value
      [] -> ""
    end
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
    |> attribute("#fare-zone-stops tr", "id")
    |> Enum.map(fn "stops-" <> uuid -> Map.fetch!(stop_id_by_row_id, uuid) end)
  end

  defp zone_chip_html(view, stop_id) do
    [chip] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#stops-#{stop_id} span[aria-hidden='true']")

    LazyHTML.to_html(chip)
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
  defp decimal(value), do: Decimal.new(value)
end
