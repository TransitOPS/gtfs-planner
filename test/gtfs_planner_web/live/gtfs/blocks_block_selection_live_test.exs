defmodule GtfsPlannerWeb.Gtfs.BlocksBlockSelectionLiveTest do
  # The Blocks tab's block selection, observed through the ordinary
  # `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo` and
  # the scoped `Blocking` context. Rows are created inside the SQL Sandbox
  # transaction and rolled back; nothing here substitutes an adapter.
  #
  # The last case asserts the hand-off the Rebuild button makes — the
  # `drawer=suggest` patch — and not the drawer it opens.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  @weekend %{
    monday: 0,
    tuesday: 0,
    wednesday: 0,
    thursday: 0,
    friday: 0,
    saturday: 1,
    sunday: 0
  }

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Riverside"
      })

    %{user: user, organization: organization, version: version, route: route}
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp calendar(context, service_id, name, attrs \\ %{}) do
    calendar_service_fixture(
      context.organization.id,
      context.version.id,
      Map.merge(Map.new(attrs), %{service_id: service_id, name: name})
    )
  end

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    route_id = Map.get(attrs, :route, context.route.route_id)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      attrs
      |> Map.delete(:route)
      |> Map.put_new(:service_id, "WK")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp block_trips(context, block_id, pairs) do
    Enum.each(Enum.with_index(pairs), fn {{first, last}, index} ->
      trip(context, %{
        trip_id: "#{block_id}_#{index}",
        block_id: block_id,
        first: first,
        last: last
      })
    end)
  end

  # Three weekday blocks, two of them on a second route so a route filter has
  # something to narrow, an unassigned trip so the Unassigned panel has a row to
  # select, and a Saturday trip so a day-type change has somewhere to go.
  defp block_day(context) do
    calendar(context, "WK", "Weekday")
    calendar(context, "SAT", "Saturday", @weekend)

    route_fixture(context.organization.id, context.version.id, %{
      route_id: "R2",
      route_short_name: "2",
      route_long_name: "Central"
    })

    block_trips(context, "101", [{"06:00:00", "06:30:00"}])
    block_trips(context, "102", [{"08:00:00", "08:30:00"}])
    block_trips(context, "103", [{"10:00:00", "10:30:00"}])

    trip(context, %{
      trip_id: "r2_trip",
      route: "R2",
      block_id: "104",
      first: "12:00:00",
      last: "12:30:00"
    })

    trip(context, %{trip_id: "pool_trip", first: "14:00:00", last: "14:30:00"})

    trip(context, %{
      trip_id: "sat_trip",
      service_id: "SAT",
      block_id: "105",
      first: "09:00:00",
      last: "09:30:00"
    })
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp element_count(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  # The block bar's own sentence, so a case reads what the reader reads.
  defp block_count(view) do
    view |> doc() |> LazyHTML.query("#block-selection-count") |> LazyHTML.text() |> String.trim()
  end

  # The day-type select's option value for a label, so the day form can be driven
  # by label the way a reader drives it.
  defp day_key(view, label) do
    view
    |> doc()
    |> LazyHTML.query("#blocks-day option")
    |> Enum.find_value(fn option ->
      if String.starts_with?(LazyHTML.text(option) |> String.trim(), label) do
        LazyHTML.attribute(option, "value") |> List.first()
      end
    end)
  end

  defp toggle_block(view, block_id) do
    view
    |> element("[data-role='select-block'][data-block='#{block_id}']")
    |> render_click()
  end

  defp toggle_trip(view, trip_id) do
    view
    |> element("[data-role='select-trip'][data-trip='#{trip_id}']")
    |> render_click()
  end

  defp select_all_blocks(view), do: view |> element("#blocks-select-all-blocks") |> render_click()

  defp clear_blocks(view), do: view |> element("#block-selection-clear") |> render_click()

  defp rebuild_selected(view), do: view |> element("#block-selection-rebuild") |> render_click()

  describe "the block selection on the timeline" do
    setup :editor_scope

    test "every row has a checkbox and two checked rows raise the block bar",
         %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      # One checkbox per block row, and the header's own page control.
      assert element_count(view, "[data-role='select-block']") == 4
      assert has_element?(view, "[data-role='select-all-blocks']")

      refute has_element?(view, "#block-selection-bar")

      toggle_block(view, "101")
      toggle_block(view, "102")

      assert block_count(view) == "2 blocks selected"
      assert has_element?(view, "#block-selection-bar")
      assert has_element?(view, "#block-selection-bar", "Clear selection")
      assert has_element?(view, "#block-selection-bar", "Rebuild selected blocks")

      # The rows themselves carry the checked state the reader set, because the
      # streamed page is re-sent when the selection changes.
      assert has_element?(view, "[data-role='select-block'][data-block='101'][checked]")
      assert has_element?(view, "[data-role='select-block'][data-block='102'][checked]")
      refute has_element?(view, "[data-role='select-block'][data-block='103'][checked]")

      # Unchecking one row leaves the other alone.
      toggle_block(view, "102")

      assert block_count(view) == "1 block selected"
      refute has_element?(view, "[data-role='select-block'][data-block='102'][checked]")
    end

    test "a selection of blocks hands the page's one primary to Rebuild selected blocks",
         %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(view, "#blocks-review-checks.btn-primary")

      toggle_block(view, "101")

      assert has_element?(view, "#block-selection-rebuild.btn-primary")
      assert has_element?(view, "#blocks-review-checks.btn-outline")

      view |> element("#block-selection-clear") |> render_click()

      assert has_element?(view, "#blocks-review-checks.btn-primary")
    end

    test "the header checkbox selects the page and unselects it", %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      select_all_blocks(view)

      assert block_count(view) == "4 blocks selected"
      assert element_count(view, "[data-role='select-block'][checked]") == 4
      assert has_element?(view, "[data-role='select-all-blocks'][checked]")

      select_all_blocks(view)

      refute has_element?(view, "#block-selection-bar")
      assert element_count(view, "[data-role='select-block'][checked]") == 0
      refute has_element?(view, "[data-role='select-all-blocks'][checked]")
    end

    test "the header checkbox adds the rest of a partly selected page",
         %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      toggle_block(view, "101")
      select_all_blocks(view)

      assert block_count(view) == "4 blocks selected"
      assert has_element?(view, "[data-role='select-all-blocks'][checked]")
    end

    test "the selection survives a page change and clear empties it",
         %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      toggle_block(view, "101")
      assert block_count(view) == "1 block selected"

      # A sort keeps the same page, so the bar is unchanged by the round trip.
      # Sorting by a key the page was not on starts ascending, so `dir` stays at
      # its default and is omitted; clicking the same key again is what toggles.
      view |> element("button[phx-click='sort'][phx-value-key='hours']") |> render_click()
      assert_patch(view, base <> "?sort=hours")

      view |> element("button[phx-click='sort'][phx-value-key='hours']") |> render_click()
      assert_patch(view, base <> "?sort=hours&dir=desc")
      assert block_count(view) == "1 block selected"
      assert has_element?(view, "[data-role='select-block'][data-block='101'][checked]")

      clear_blocks(view)

      refute has_element?(view, "#block-selection-bar")
      assert element_count(view, "[data-role='select-block'][checked]") == 0
      refute has_element?(view, "#blocks-bulk-bar")
    end
  end

  describe "the block selection beside the trip selection" do
    setup :editor_scope

    test "block selection leaves the Unassigned trip selection alone",
         %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      toggle_trip(view, "pool_trip")
      assert has_element?(view, "#blocks-bulk-bar")
      refute has_element?(view, "#block-selection-bar")

      view |> element("#panel-blocks") |> render_click()

      toggle_block(view, "101")

      assert block_count(view) == "1 block selected"
      # The trip selection is still the one the reader made: the two bars count
      # different things and neither event touches the other's set.
      assert has_element?(view, "#blocks-bulk-bar")

      view |> element("#panel-pool") |> render_click()

      assert has_element?(view, "#blocks-bulk-bar")
      assert has_element?(view, "[data-role='select-trip'][data-trip='pool_trip'][checked]")
      assert block_count(view) == "1 block selected"
    end

    test "clearing the trip selection leaves the block selection alone",
         %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      toggle_trip(view, "pool_trip")
      view |> element("#panel-blocks") |> render_click()
      toggle_block(view, "101")

      assert has_element?(view, "#blocks-bulk-bar")
      view |> element("#bulk-clear") |> render_click()

      refute has_element?(view, "#blocks-bulk-bar")
      assert block_count(view) == "1 block selected"
      assert has_element?(view, "[data-role='select-block'][data-block='101'][checked]")
    end
  end

  describe "clearing the block selection" do
    setup :editor_scope

    test "a route filter clears it", %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      toggle_block(view, "101")
      assert block_count(view) == "1 block selected"

      view |> element("#blocks-filter-form") |> render_change(%{"route" => "R2"})

      assert_patch(view, base <> "?route=R2")
      refute has_element?(view, "#block-selection-bar")
      assert element_count(view, "[data-role='select-block'][checked]") == 0
      # The filter narrowed the page to the one block on that route.
      assert element_count(view, "[data-role='select-block']") == 1
    end

    test "a day-type change clears it", %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      toggle_block(view, "101")
      saturday = day_key(view, "Saturday")

      view |> element("#blocks-day-form") |> render_change(%{"day" => saturday})

      assert_patch(view, base <> "?day=#{saturday}")
      refute has_element?(view, "#block-selection-bar")
      assert element_count(view, "[data-role='select-block']") == 1
    end

    test "another version starts with an empty selection", %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      toggle_block(view, "101")
      assert block_count(view) == "1 block selected"

      other = gtfs_version_fixture(context.organization.id)
      conn = log_in_user(build_conn(), context.user, organization: context.organization)

      {:ok, other_view, _html} = live(conn, blocks_path(other.id))

      refute has_element?(other_view, "#block-selection-bar")
    end
  end

  describe "rebuilding the selected blocks" do
    setup :editor_scope

    test "the button opens the suggest drawer with the selection in the URL",
         %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      toggle_block(view, "101")
      toggle_block(view, "102")

      rebuild_selected(view)

      # The button hands off to the drawer behind this URL key, whose selected
      # scope reads the same `:block_selection`.
      assert_patch(view, base <> "?drawer=suggest")
      assert block_count(view) == "2 blocks selected"
    end

    test "the bar is not on the page without a selection", %{version: version} = context do
      block_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      # The bar holds the only way to reach `rebuild_selected`, so an empty
      # selection cannot ask for a rebuild.
      assert element_count(view, "#block-selection-bar") == 0
    end
  end
end
