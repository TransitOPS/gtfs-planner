defmodule GtfsPlannerWeb.Gtfs.BlocksPoolLiveTest do
  # EV-21: the List view, the paged Unassigned panel and the “not plotted” list,
  # observed through the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes
  # an adapter.
  #
  # The card's browser case (stacked narrow records and no page-level horizontal
  # overflow at 375px) belongs to `assets/e2e/blocks.spec.js`, which step 29 owns
  # with EV-28; this file writes the six server cases.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_pool_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  # The pool holds one page of 100 trips, like the block pages (Pages / URL state).
  @page_size 100

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

  # One block built from `{first, last}` clock pairs; a pair that shares a stop
  # makes the handoff a same-stop one, and a `nil` last time makes the trip
  # unplottable (the stored empty time).
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

  # 149 plottable pool trips, one per minute from 06:00, plus a trip whose last
  # time is missing: page 1 is the first 100 departures, page 2 the remaining 49
  # and then the untimed trip (EV-21's 150-trip case).
  defp seed_pool_day(context) do
    calendar(context, "WK", "Weekday")

    for index <- 1..149 do
      first = 6 * 3_600 + (index - 1) * 60

      trip(context, %{
        trip_id: pool_id(index),
        first: clock(first),
        last: clock(first + 1_800)
      })
    end

    trip(context, %{trip_id: "p_untimed", last: nil})
  end

  defp pool_id(index), do: "p" <> String.pad_leading(Integer.to_string(index), 3, "0")

  defp clock(secs) do
    "#{pad(div(secs, 3_600))}:#{pad(div(rem(secs, 3_600), 60))}:00"
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  # The pool's trip IDs in document order, read from each row's selection
  # control: the row order is what the departure sort and the paging produce.
  defp pool_trip_ids(view) do
    view
    |> doc()
    |> LazyHTML.query("#blocks-pool-table [data-role='select-trip']")
    |> LazyHTML.attribute("data-trip")
  end

  defp element_count(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  # The day-type select's option values, so the day form can be driven by label
  # the way a reader drives it.
  defp day_key(view, label) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-day option")
    |> Enum.find_value(fn option ->
      if String.starts_with?(LazyHTML.text(option) |> String.trim(), label) do
        LazyHTML.attribute(option, "value") |> List.first()
      end
    end)
  end

  defp block_table_id(block_id),
    do: "#block-list-block-" <> Base.url_encode64(block_id, padding: false)

  describe "the Unassigned panel" do
    setup :editor_scope

    test "150 unassigned trips page 100 at a time in departure order with untimed trips last",
         %{version: version} = context do
      seed_pool_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      assert has_element?(view, "#panel-pool", ~r/Unassigned trips\s+150\b/)
      assert element_count(view, "#blocks-pool-table tr") == @page_size

      page_one = pool_trip_ids(view)
      assert length(page_one) == @page_size
      assert hd(page_one) == "p001"
      assert List.last(page_one) == "p100"

      view |> element("#blocks-pool-pager button[phx-value-page='2']") |> render_click()

      assert_patch(view, base <> "?panel=pool&pool_page=2")

      page_two = pool_trip_ids(view)
      assert length(page_two) == 50
      assert hd(page_two) == "p101"
      assert List.last(page_two) == "p_untimed"
      refute Enum.member?(page_two, "p100")
    end

    test "a frequency trip and a trip with no usable time print their reason",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      frequency = trip(context, %{trip_id: "freq_1", first: "09:00:00", last: "10:00:00"})

      frequency_row_fixture(context.organization.id, context.version.id, %{
        trip_id: frequency.trip_id,
        headway_secs: 1_200
      })

      trip(context, %{trip_id: "unplottable_1", last: nil})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='pool-eligibility']",
               "Repeats every 20 min · not a single trip"
             )

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='pool-eligibility']",
               "Time missing"
             )

      assert has_element?(
               view,
               "#blocks-pool-table a[href='/gtfs/#{version.id}/routes/R1/schedules?service_id=WK']",
               "Fix times in Schedules"
             )
    end

    test "each pool row offers a trip checkbox and an action",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "pool_a", first: "08:00:00", last: "09:00:00"})
      trip(context, %{trip_id: "pool_untimed", last: nil})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='select-trip'][data-trip='pool_a'][phx-click='toggle_trip']"
             )

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='assign-trip'][phx-value-scope='trip'][phx-value-trip='pool_a']",
               "Assign trip"
             )

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='view-trip'][phx-value-trip='pool_untimed']",
               "View trip"
             )

      refute has_element?(
               view,
               "#blocks-pool-table [data-role='assign-trip'][phx-value-trip='pool_untimed']"
             )
    end

    test "the route filter narrows the pool page without moving the whole-day counts",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "R2",
        route_short_name: "2",
        route_long_name: "Central"
      })

      trip(context, %{trip_id: "r1_pool", first: "06:00:00", last: "06:30:00"})
      trip(context, %{trip_id: "r2_pool", route: "R2", first: "07:00:00", last: "07:30:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool&route=R2")

      assert pool_trip_ids(view) == ["r2_pool"]
      assert has_element?(view, "#blocks-pool-pager", "of 1 trips")
      assert has_element?(view, "#blocks-summary-counts-item-unassigned", "2")
    end

    test "a filter that matches no pool trip shows the pool's own empty state",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "R2",
        route_short_name: "2"
      })

      # R2 must name a trip of this day type for the filter to survive the load:
      # `normalize_route/2` falls back to all routes when the day holds none of
      # the route (EV-19's “an unknown route falls back to all routes”), so a
      # blocked R2 trip keeps the route while the pool holds none of it.
      trip(context, %{
        trip_id: "r2_blocked",
        route: "R2",
        block_id: "201",
        first: "07:00:00",
        last: "07:30:00"
      })

      trip(context, %{trip_id: "r1_pool", first: "08:00:00", last: "09:00:00"})

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool&route=R2")

      assert has_element?(view, "#blocks-pool-filtered-empty", "No unassigned trips match")
      refute has_element?(view, "#blocks-filtered-empty")
      refute has_element?(view, "#blocks-pool-table")

      view |> element("#blocks-pool-clear-filters") |> render_click()

      assert_patch(view, base <> "?panel=pool")
      assert pool_trip_ids(view) == ["r1_pool"]
    end

    test "an empty pool without a filter says every trip has a block",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "09:00:00"}])

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      assert has_element?(view, "#blocks-pool-empty", "Every trip has a block")
      refute has_element?(view, "#blocks-pool-filtered-empty")
    end

    test "switching day type re-streams the pool with the new day's trips",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      calendar(context, "SAT", "Saturday", @weekend)
      trip(context, %{trip_id: "wk_pool_a", first: "08:00:00", last: "09:00:00"})
      trip(context, %{trip_id: "wk_pool_b", first: "08:10:00", last: "09:10:00"})

      trip(context, %{
        trip_id: "sat_pool",
        service_id: "SAT",
        first: "10:00:00",
        last: "11:00:00"
      })

      conn = editor_conn(context)
      base = blocks_path(version.id)
      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      # The Weekday day type is the default (more dates), so the pool starts on it.
      assert has_element?(view, "#panel-pool", ~r/Unassigned trips\s+2\b/)
      assert pool_trip_ids(view) == ["wk_pool_a", "wk_pool_b"]

      saturday = day_key(view, "Saturday")
      assert saturday

      view |> element("#blocks-day-form") |> render_change(%{"day" => saturday})

      assert_patch(view, base <> "?day=#{saturday}&panel=pool")

      # The pool is re-streamed, not reused: the new day's own rows and count.
      assert has_element?(view, "#panel-pool", ~r/Unassigned trips\s+1\b/)
      assert pool_trip_ids(view) == ["sat_pool"]
    end

    test "with no blocks the panel shows the guidance and still lists the pool",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "only_pool", first: "08:00:00", last: "09:00:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      assert has_element?(
               view,
               "#blocks-workspace-guidance",
               "Start by selecting trips and placing them on a new block."
             )

      assert pool_trip_ids(view) == ["only_pool"]
    end
  end

  describe "the List view" do
    setup :editor_scope

    test "each streamed block renders its own trip table with the reference's columns",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "08:40:00"}, {"08:50:00", "09:30:00"}])
      block_trips(context, "102", [{"11:00:00", "11:40:00"}])

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?view=list")

      assert element_count(view, "#blocks-lists table") == 2
      assert has_element?(view, "#blocks-lists #{block_table_id("101")}")
      assert has_element?(view, "#blocks-lists #{block_table_id("102")}")

      table = block_table_id("101")
      assert has_element?(view, "#{table} tr", "101_0")
      assert has_element?(view, "#{table} tr", "Riverside")
      assert has_element?(view, "#{table}-container", "From → To")
      assert has_element?(view, "#{table}-container", "Gap")
      assert has_element?(view, "#{table}-container", "Issues")

      # The trip's endpoint line carries its terminal after an arrow.
      assert has_element?(view, "#{table} tr", "→")

      # The gap before the second trip is the ten minutes between the two.
      assert has_element?(
               view,
               "#{table} [data-role='list-gap'][data-minutes='10']",
               "10 min"
             )

      # The first trip of a block has no gap.
      assert element_count(view, "#{table} [data-role='list-gap']") == 1
    end

    test "a trip's issues print as status badges, worst first",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "09:00:00"}, {"08:30:00", "09:30:00"}])
      block_trips(context, "102", [{"11:00:00", "11:40:00"}])

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?view=list")

      table = block_table_id("101")

      assert has_element?(
               view,
               "#{table} [data-role='trip-issue'][data-code='overlap']",
               "Overlap"
             )

      # A block with nothing to report says so in text, not with a colour.
      assert has_element?(
               view,
               "#{block_table_id("102")} [data-role='trip-issues']",
               "No problems"
             )

      assert has_element?(
               view,
               "#{table} [data-role='select-trip'][data-trip='101_0'][phx-click='toggle_trip']"
             )
    end

    test "the route filter hides the other routes' trips in the list",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "R2",
        route_short_name: "2"
      })

      block_trips(context, "101", [{"08:00:00", "08:40:00"}, {"08:50:00", "09:30:00"}])

      trip(context, %{
        trip_id: "101_1_r2",
        block_id: "101",
        route: "R2",
        first: "10:00:00",
        last: "10:40:00"
      })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?view=list&route=R1")

      table = block_table_id("101")

      refute has_element?(view, "#blocks-pool-table")
      assert has_element?(view, "#{table} tr", "101_0")
      refute has_element?(view, "#{table} [data-role='select-trip'][data-trip='101_1_r2']")
    end
  end

  describe "the not-plotted list" do
    setup :editor_scope

    test "a blocked unplottable trip is listed with its reason and a Schedules link",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      trip(context, %{trip_id: "blocked_untimed", block_id: "104", last: nil})
      trip(context, %{trip_id: "pool_untimed", last: nil})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?view=list")

      assert has_element?(
               view,
               "#blocks-untimed [data-role='untimed-trip'][data-trip='blocked_untimed']",
               "Time missing"
             )

      assert has_element?(
               view,
               "#blocks-untimed a[href='/gtfs/#{version.id}/routes/R1/schedules?service_id=WK']",
               "Fix times in Schedules"
             )

      refute has_element?(
               view,
               "#blocks-untimed [data-role='untimed-trip'][data-trip='pool_untimed']"
             )
    end

    test "the list is absent when every blocked trip can be plotted",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      block_trips(context, "101", [{"08:00:00", "09:00:00"}])

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      refute has_element?(view, "#blocks-untimed")
    end
  end
end
