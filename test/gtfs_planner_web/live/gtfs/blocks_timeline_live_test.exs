defmodule GtfsPlannerWeb.Gtfs.BlocksTimelineLiveTest do
  # EV-20: the paged block timeline, observed through the ordinary
  # `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo` and
  # the scoped `Blocking` context. Rows are created inside the SQL Sandbox
  # transaction and rolled back; nothing here substitutes an adapter.
  #
  # The card's tenth case is a browser case: the 1440x1000 density, sticky header,
  # zoom and overflow measurements live in `assets/e2e/blocks.spec.js`, which step
  # 29 owns with EV-28. This file writes the nine server cases.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_timeline_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.Components.RouteIdentity

  # The day type's first page holds 100 blocks, so a fixture with 230 blocks has
  # three pages.
  @page_size 100

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "1"})

    %{user: user, organization: organization, version: version, route: route}
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp calendar(context, service_id, name) do
    calendar_service_fixture(context.organization.id, context.version.id, %{
      service_id: service_id,
      name: name
    })
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

  # One block built from `{first, last}` clock pairs, each trip on the day type's
  # route. A pair of trips that touch or overlap uses one stop each, so the
  # handoff between separate trips is an empty move.
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

  # 230 blocks: block 1 holds the day type's most trips, blocks 2 and 3 an overlap
  # (error), block 4 a short layover (warning) and block 5 an empty move alone (a
  # notice), which is what `status=problems` must separate. Two unassigned trips
  # keep the strip's unassigned figure non-zero, and one of them ends after
  # midnight so the axis spans the next day.
  defp seed_paged_day(context) do
    calendar(context, "WK", "Weekday")

    block_trips(context, "1", [
      {"06:00:00", "06:40:00"},
      {"07:00:00", "07:40:00"},
      {"08:00:00", "08:40:00"},
      {"09:00:00", "09:40:00"},
      {"10:00:00", "10:40:00"}
    ])

    block_trips(context, "2", [{"08:00:00", "09:00:00"}, {"08:30:00", "09:30:00"}])
    block_trips(context, "3", [{"08:00:00", "09:00:00"}, {"08:15:00", "09:15:00"}])
    block_trips(context, "4", [{"08:00:00", "09:00:00"}, {"09:02:00", "10:00:00"}])
    block_trips(context, "5", [{"08:00:00", "09:00:00"}, {"09:10:00", "10:00:00"}])

    Enum.each(6..230, fn index ->
      block_trips(context, Integer.to_string(index), [{"08:00:00", "09:00:00"}])
    end)

    trip(context, %{trip_id: "pool_1", first: "05:00:00", last: "06:00:00"})
    trip(context, %{trip_id: "pool_2", first: "25:30:00", last: "26:00:00"})
  end

  defp element_count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  # The rendered block IDs, in document order, so a case can assert the sort.
  defp row_blocks(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-timeline tbody tr")
    |> LazyHTML.attribute("data-block")
  end

  defp bar_attribute(view, trip_id, attribute) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role='trip-bar'][data-trip='#{trip_id}']))
    |> LazyHTML.attribute(attribute)
    |> List.first()
  end

  defp strip_value(view, key) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-summary-counts-item-#{key}")
    |> LazyHTML.query("[data-role='count-strip-value']")
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "paging" do
    setup :editor_scope

    test "230 blocks page 100 at a time and the pager patches the page",
         %{version: version} = context do
      seed_paged_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert strip_value(view, "blocks") == "230"
      assert element_count(view, "#blocks-timeline tbody tr") == @page_size

      {:ok, third, _html} = live(conn, blocks_path(version.id) <> "?page=3")

      assert element_count(third, "#blocks-timeline tbody tr") == 30

      view |> element("#blocks-pager button[phx-value-page='2']") |> render_click()

      assert_patch(view, blocks_path(version.id) <> "?page=2")
      assert element_count(view, "#blocks-timeline tbody tr") == @page_size
    end

    test "a page past the day's own last page shows the last page's rows",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "09:00:00"}])

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?page=3")

      assert row_blocks(view) == ["101"]
    end
  end

  describe "sorting the whole day type" do
    setup :editor_scope

    test "the busiest block leads the page and the header shows the direction",
         %{version: version} = context do
      seed_paged_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?sort=trips&dir=desc")

      assert row_blocks(view) |> hd() == "1"
      assert has_element?(view, "th[aria-sort='descending']", "Trips")
      assert has_element?(view, "th[aria-sort='descending']", "↓")

      # The same key reverses, and the day type's other blocks keep the natural
      # block order the sort breaks ties with.
      view |> element("button[phx-value-key='trips']") |> render_click()

      assert_patch(view, blocks_path(version.id) <> "?sort=trips")
      assert has_element?(view, "th[aria-sort='ascending']", "↑")
      assert row_blocks(view) |> hd() == "1"
    end

    test "status puts the error blocks first with natural ties",
         %{version: version} = context do
      seed_paged_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?sort=status")

      assert Enum.take(row_blocks(view), 4) == ["2", "3", "4", "5"]
    end
  end

  describe "filters" do
    setup :editor_scope

    test "the route filter keeps blocks with a trip on the route and hides other routes' bars",
         %{version: version} = context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "R2",
        route_short_name: "2"
      })

      calendar(context, "WK", "Weekday")

      block_trips(context, "101", [{"06:00:00", "07:00:00"}])

      trip(context, %{
        trip_id: "mix",
        block_id: "101",
        route: "R2",
        first: "07:10:00",
        last: "08:00:00"
      })

      trip(context, %{
        trip_id: "only2",
        block_id: "102",
        route: "R2",
        first: "08:00:00",
        last: "09:00:00"
      })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?route=R1")

      assert row_blocks(view) == ["101"]
      assert has_element?(view, "[data-role='trip-bar'][data-trip='101_0']")
      refute has_element?(view, "[data-role='trip-bar'][data-trip='mix']")

      # The strip is the whole day type's, so a filter cannot move it.
      assert strip_value(view, "blocks") == "2"
      assert strip_value(view, "unassigned") == "0"
      assert has_element?(view, "#blocks-summary-note", "Whole day type")
    end

    test "problems only keeps error and warning blocks", %{version: version} = context do
      seed_paged_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?status=problems")

      assert row_blocks(view) == ["2", "3", "4"]
      assert strip_value(view, "blocks") == "230"
    end

    test "a filter with no matching block shows the empty state and Clear filters restores it",
         %{version: version} = context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "R2",
        route_short_name: "2"
      })

      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "09:00:00"}])
      trip(context, %{trip_id: "only2", route: "R2", first: "08:00:00", last: "09:00:00"})

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?route=R2")

      assert has_element?(view, "#blocks-filtered-empty", "No blocks match these filters")
      assert element_count(view, "#blocks-timeline tbody tr") == 0

      view |> element("#blocks-clear-filters") |> render_click()

      assert_patch(view, base)
      assert row_blocks(view) == ["101"]
    end
  end

  describe "the workspace controls" do
    setup :editor_scope

    test "the view, scale and panel controls patch the URL", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "09:00:00"}])

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      view |> element("#blocks-view-form") |> render_change(%{"view" => "list"})
      assert_patch(view, base <> "?view=list")

      view |> element("#blocks-view-form") |> render_change(%{"view" => "timeline"})
      assert_patch(view, base)

      view |> element("#blocks-scale-form") |> render_change(%{"scale" => "zoom"})
      assert_patch(view, base <> "?scale=zoom")

      assert has_element?(view, "#blocks-timeline[data-scale='zoom']")

      view |> element("#panel-pool") |> render_click()

      assert_patch(view, base <> "?panel=pool&scale=zoom")
      assert has_element?(view, "#panel-pool[aria-pressed='true']")
      assert has_element?(view, "#panel-blocks[aria-pressed='false']")
    end

    test "the timeline keeps the pager out of a day with no blocks",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "pool_1", first: "08:00:00", last: "09:00:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(
               view,
               "#blocks-workspace-guidance",
               "Start by selecting trips and assigning them to a new block."
             )

      refute has_element?(view, "#blocks-pager")
    end
  end

  describe "bar geometry" do
    setup :editor_scope

    test "a trip's bar sits at its share of the axis", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "early", block_id: "101", first: "06:00:00", last: "07:00:00"})
      trip(context, %{trip_id: "late", block_id: "102", first: "09:00:00", last: "10:00:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      # The axis is 06:00-10:00, so each trip's hour is a quarter of the span.
      assert bar_attribute(view, "early", "style") =~ "left: 0.00%"
      assert bar_attribute(view, "early", "style") =~ "width: 25.00%"
      assert bar_attribute(view, "late", "style") =~ "left: 75.00%"
      assert bar_attribute(view, "late", "style") =~ "width: 25.00%"

      assert has_element?(view, "#blocks-timeline .blocks-axis-tick", "06:00")
      assert has_element?(view, "#blocks-timeline .blocks-axis-tick", "08:00")
    end

    test "an end after midnight prints its next-day clock and time",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "overnight", block_id: "103", first: "24:30:00", last: "25:15:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(
               view,
               "#blocks-timeline tbody tr[data-block='103'] .blocks-meta-end",
               "01:15 +1d"
             )

      assert bar_attribute(view, "overnight", "style") =~ "width: 37.50%"
    end
  end

  describe "the risk marks on a row" do
    setup :editor_scope

    test "overlaps, short layovers and empty moves are marked without relying on colour",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      block_trips(context, "101", [{"08:00:00", "09:00:00"}, {"08:30:00", "09:30:00"}])
      block_trips(context, "102", [{"08:00:00", "09:00:00"}, {"09:02:00", "10:00:00"}])
      block_trips(context, "103", [{"11:00:00", "12:00:00"}, {"12:10:00", "13:00:00"}])

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      # The second bar of the overlapping pair carries the error icon and shifts
      # above the first; a trip in a block without an overlap carries neither.
      assert has_element?(
               view,
               "[data-role='trip-bar'][data-trip='101_1'] [data-role='trip-bar-overlap']"
             )

      refute has_element?(
               view,
               "[data-role='trip-bar'][data-trip='102_0'] [data-role='trip-bar-overlap']"
             )

      assert bar_attribute(view, "101_1", "class") =~ "blocks-bar-shift"
      refute bar_attribute(view, "101_0", "class") =~ "blocks-bar-shift"

      # The overlap pair's negative gap is suppressed, so two gaps render: the
      # 2-minute one (a short layover) and the 10-minute one. Every fixture stop
      # shares the default coordinates, so both handoffs are `nearby-0`, not
      # `moves`, and no move icon renders.
      assert element_count(view, "[data-role='blocks-gap']") == 2
      assert element_count(view, "[data-role='blocks-gap'][data-handoff='nearby-0']") == 2
      refute has_element?(view, "[data-role='blocks-gap'] [data-role='gap-move-icon']")

      assert element_count(view, "[data-role='blocks-gap'][data-short='true']") == 1
      assert element_count(view, "[data-role='blocks-gap'][data-short='false']") == 1
    end
  end

  describe "route colours" do
    test "route_colors/1 carries the colours route_badge/1 already rendered" do
      route = %{
        route_color: "267548",
        route_text_color: "FFFFFF",
        route_short_name: "1"
      }

      assert RouteIdentity.route_colors(route) ==
               {"background-color: #267548; color: #FFFFFF", nil}

      assert RouteIdentity.route_colors(%{route_color: "not-a-color"}) ==
               {nil, "bg-base-300 text-base-content"}

      assert RouteIdentity.route_colors(%{}) == {nil, "bg-base-300 text-base-content"}

      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: "267548", route_text_color: "FFFFFF", route_short_name: "1"}
        } />
        """)

      assert html =~ "background-color: #267548"
      assert html =~ "color: #FFFFFF"
      assert html =~ "1"
    end
  end
end
