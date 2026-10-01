defmodule GtfsPlannerWeb.Gtfs.BlocksTimelineLiveTest do
  # The paged block timeline, observed through the ordinary
  # `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo` and
  # the scoped `Blocking` context. Rows are created inside the SQL Sandbox
  # transaction and rolled back; nothing here substitutes an adapter.
  #
  # The 1440x1000 density, sticky header, zoom and overflow measurements are
  # browser cases and live in `assets/e2e/blocks.spec.js`.
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

  defp stop(context, attrs) do
    stop_fixture(context.organization.id, context.version.id, attrs)
  end

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
  # (error), block 4 a short layover (warning) and block 5 an empty move alone
  # (an error of its own), which is what `status=problems` must separate. Two
  # unassigned trips keep the strip's unassigned figure non-zero, and one of
  # them ends after midnight so the axis spans the next day.
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

    # Block 5's handoff is the empty move the status sort must separate from the
    # other blocks: every other fixture stop shares the default coordinates, so
    # its second trip starts at a stop more than the 200 m proximity bound away
    # and the handoff check makes the gap a `{:moves, _}`. The two stops are ninety kilometres
    # apart, so the ten minutes between the trips cannot hold the drive and the
    # block check reports the gap as `:cannot_reach`.
    far =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_lat: Decimal.new("41.0000"),
        stop_lon: Decimal.new("-73.0000")
      })

    trip(context, %{trip_id: "5_0", block_id: "5", first: "08:00:00", last: "09:00:00"})

    trip(context, %{
      trip_id: "5_1",
      block_id: "5",
      first: "09:10:00",
      last: "10:00:00",
      first_stop: far.stop_id
    })

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

  # One block of two trips that meet at `stop`, the second starting at `first`,
  # so the pair has one real wait for a connection record to sit in.
  defp block_pair(context, block_id, stop, first) do
    from =
      trip(context, %{
        trip_id: "#{block_id}_from",
        block_id: block_id,
        first_stop: stop.stop_id,
        last_stop: stop.stop_id,
        first: "08:00:00",
        last: "09:00:00"
      })

    to =
      trip(context, %{
        trip_id: "#{block_id}_to",
        block_id: block_id,
        first_stop: stop.stop_id,
        last_stop: stop.stop_id,
        first: first,
        last: "10:00:00"
      })

    %{from: from, to: to}
  end

  # The rendered gap bar for one pair, so a case can read its attributes and
  # build the selector that finds it again.
  defp gap(view, pair) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(gap_selector(pair))
    |> Enum.fetch!(0)
  end

  defp gap_selector(pair),
    do: "[data-role='blocks-gap'][data-from='#{pair.from.id}'][data-to='#{pair.to.id}']"

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

    test "Time out orders the whole day type and the header shows the direction",
         %{version: version} = context do
      seed_paged_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?sort=out&dir=desc")

      # Block 1 leaves at 06:00 and every other block at 08:00, so the latest out
      # leads page 1 and the earliest one is on the last page of the day type.
      assert row_blocks(view) |> hd() == "2"
      refute "1" in row_blocks(view)
      assert has_element?(view, "th[aria-sort='descending']", "Time out")
      assert has_element?(view, "th[aria-sort='descending']", "↓")

      # The same key reverses: ascending puts the earliest pull-out first.
      view |> element("button[phx-value-key='out']") |> render_click()

      assert_patch(view, blocks_path(version.id) <> "?sort=out")
      assert has_element?(view, "th[aria-sort='ascending']", "↑")
      assert row_blocks(view) |> hd() == "1"
    end

    test "status puts the error blocks first with natural ties",
         %{version: version} = context do
      seed_paged_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?sort=status")

      # 2, 3 and 5 are errors and 4 a warning, and the ties are natural, so the
      # warning sorts after the three errors rather than among them.
      assert Enum.take(row_blocks(view), 4) == ["2", "3", "5", "4"]
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
      assert has_element?(view, "#blocks-summary-note", "Whole service day")
    end

    test "problems only keeps error and warning blocks", %{version: version} = context do
      seed_paged_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?status=problems")

      assert row_blocks(view) == ["2", "3", "4", "5"]
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

    test "the List view hides Select this page when the filter matches no block",
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

      {:ok, view, _html} = live(conn, base <> "?view=list&route=R2")

      assert has_element?(view, "#blocks-filtered-empty", "No blocks match these filters")
      refute has_element?(view, "#blocks-select-page")

      # The same page without the filter keeps the control: the empty state, not
      # the whole day type's block count, decides it.
      view |> element("#blocks-clear-filters") |> render_click()

      assert_patch(view, base <> "?view=list")
      assert has_element?(view, "#blocks-select-page")
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
      assert has_element?(view, "#panel-pool[aria-selected='true']")
      assert has_element?(view, "#panel-blocks[aria-selected='false']")
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
               "Select trips and place them on a new block."
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

    test "a span after midnight prints its next-day clock and time",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "overnight", block_id: "103", first: "24:30:00", last: "25:15:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      # The fixture's version has no garage, so the platform span is the trip
      # span and the cell carries both of its next-day ends.
      assert has_element?(
               view,
               "#blocks-timeline tbody tr[data-block='103'] .blocks-meta-out",
               "00:30 +1d–01:15 +1d"
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

  describe "connection settings on the gaps" do
    setup :editor_scope

    test "a decided connection marks its gap and an undecided one keeps its minutes",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})

      stay = block_pair(context, "101", main, "09:20:00")
      reboard = block_pair(context, "102", main, "09:20:00")
      plain = block_pair(context, "103", main, "09:20:00")

      in_seat_transfer_fixture(context.organization.id, context.version.id, stay.from, stay.to)

      transfer_fixture(context.organization.id, context.version.id, %{
        from_trip_id: reboard.from.trip_id,
        to_trip_id: reboard.to.trip_id,
        from_stop_id: main.stop_id,
        to_stop_id: main.stop_id,
        transfer_type: 5
      })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      # A type 4 record is riders stay on board: the gap draws the link icon in
      # place of its minutes and says so in its own title.
      stay_gap = gap(view, stay)
      assert LazyHTML.attribute(stay_gap, "data-setting") == ["stay"]

      assert has_element?(
               view,
               gap_selector(stay) <> " [data-role='blocks-gap-setting'] .hero-link-mini"
             )

      assert LazyHTML.attribute(stay_gap, "title") |> List.first() =~ "Riders stay on board"
      refute has_element?(view, gap_selector(stay) <> " .blocks-gap-label")

      # A type 5 record is the other decision, with the exit icon.
      reboard_gap = gap(view, reboard)
      assert LazyHTML.attribute(reboard_gap, "data-setting") == ["reboard"]

      assert has_element?(
               view,
               gap_selector(reboard) <>
                 " [data-role='blocks-gap-setting'] .hero-arrow-right-start-on-rectangle-mini"
             )

      assert LazyHTML.attribute(reboard_gap, "title") |> List.first() =~ "Riders must re-board"

      # A gap nobody has decided keeps its minutes and stays unsetting-marked.
      plain_gap = gap(view, plain)
      assert LazyHTML.attribute(plain_gap, "data-setting") == ["none"]
      assert has_element?(view, gap_selector(plain) <> " .blocks-gap-label", "20")
      refute has_element?(view, gap_selector(plain) <> " [data-role='blocks-gap-setting']")

      # Each gap still opens the connection it is drawn for.
      assert has_element?(
               view,
               gap_selector(stay) <> "[phx-click='open_gap'][phx-value-to='#{stay.to.id}']"
             )
    end

    test "a stale record marks its gap as needing review", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})
      other = stop(context, %{stop_id: "OTHER", stop_name: "Other St"})

      pair = block_pair(context, "101", main, "09:20:00")

      # The record names the pair but the wrong handoff stops, so the day load
      # finds it no longer matches the block and the connection needs review.
      transfer_fixture(context.organization.id, context.version.id, %{
        from_trip_id: pair.from.trip_id,
        to_trip_id: pair.to.trip_id,
        from_stop_id: other.stop_id,
        to_stop_id: other.stop_id,
        transfer_type: 4
      })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      marked = gap(view, pair)
      assert LazyHTML.attribute(marked, "data-setting") == ["review"]

      assert has_element?(
               view,
               gap_selector(pair) <>
                 " [data-role='blocks-gap-setting'] .hero-exclamation-triangle-mini"
             )

      assert LazyHTML.attribute(marked, "title") |> List.first() =~ "Needs review"
      refute has_element?(view, gap_selector(pair) <> " .blocks-gap-label")
    end

    test "the legend names every connection encoding in words",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "09:00:00"}, {"09:20:00", "10:00:00"}])

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(view, "#blocks-timeline-legend [data-role='connection-legend']")

      for label <- [
            "Not stated (minutes)",
            "Riders stay on board",
            "Riders must re-board",
            "Needs review"
          ] do
        assert has_element?(view, "#blocks-timeline-legend", label)
      end

      # The decided keys paint the same grounds the gaps carry, and each names
      # itself with its icon rather than colour alone.
      assert has_element?(
               view,
               "#blocks-timeline-legend .blocks-legend-stay .hero-link-mini"
             )

      assert has_element?(
               view,
               "#blocks-timeline-legend .blocks-legend-reboard .hero-arrow-right-start-on-rectangle-mini"
             )

      assert has_element?(
               view,
               "#blocks-timeline-legend .blocks-legend-review .hero-exclamation-triangle-mini"
             )
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
