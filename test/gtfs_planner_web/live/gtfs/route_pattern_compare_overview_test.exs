defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareOverviewTest do
  @moduledoc """
  Merge evidence (EV-17) for CL-21: the compare page's all-patterns overview.

  `view=all` loads `Gtfs.load_pattern_overview/4` and renders `#compare-overview`:
  one column per pattern of the URL's direction (`dir`), one row per aligned visit
  with a numbered lane ring per column and a "Served by n of m" count, and the
  pick-two checkboxes whose server state keeps at most two patterns in pick order.
  The direction toggle and the calendar select patch URL params; a third pick drops
  the oldest; "Compare 2 patterns" opens the two view with the picked pair as `a`
  and `b`.

  The fixture's expectations are hand-derived from the stop lists. Route OVW1's
  direction 0 is `FULL [S1,S2,S3,S4]` (3 trips, the busiest and so the reference),
  `LOOP [S1,S2,S1,S3]` (2 trips) and `SHORT [S1,S2]` (1 trip): aligning LOOP to
  FULL pairs `S1, S2, S3` and leaves LOOP's second S1 visit as its own row between
  S2 and S3, so the five aligned visits are `S1, S2, S1, S3, S4` served by
  `3, 3, 1, 2, 1` of the three patterns. SHORT adds no row. Direction 1 holds
  `BACK [S1,S2]`, and route OVW2 has no direction-1 pattern at all.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); no adapter is substituted. The prepared
  focused gate command is:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_overview_test.exs
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{
        alias: "route-pattern-compare-overview-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-overview-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} corridor"
    })
  end

  defp stop(organization, version, route_id, index) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S#{index}",
      stop_name: "#{route_id} Stop #{index}",
      location_type: 0
    })
  end

  defp schedule_pattern(organization, version, route, attrs, stops) do
    schedule_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      route_pattern_id: attrs.id,
      route_pattern_name: attrs.name,
      direction_id: Map.get(attrs, :direction, 0),
      route_pattern_typicality: 1,
      route_pattern_sort_order: Map.get(attrs, :sort, 0),
      timing_name: "#{attrs.id} timing",
      stops: stops
    })
  end

  defp trip(organization, version, route, bundle, start_time) do
    schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
      service_id: "WEEKDAY",
      start_time: start_time
    })
  end

  # Route OVW1 (see the moduledoc): FULL is the busiest reference, LOOP repeats
  # its first stop, SHORT ends early and BACK runs the other direction. The
  # timepoints are FULL's two ends only, so the timepoint note is discriminating.
  defp overview_routes(%{organization: organization, version: version}) do
    route = route(organization, version, "OVW1")
    Enum.each(1..4, &stop(organization, version, "OVW1", &1))

    Enum.each([{"WEEKDAY", "Weekday"}, {"SATURDAY", "Saturday"}], fn {service_id, name} ->
      calendar_fixture(organization.id, version.id, %{service_id: service_id})

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: name
      })
    end)

    full =
      schedule_pattern(organization, version, route, %{id: "FULL", name: "Full", sort: 0}, [
        {"OVW1_S1", 0, 0, 1},
        {"OVW1_S2", 120, 120, 0},
        {"OVW1_S3", 240, 240, 0},
        {"OVW1_S4", 360, 360, 1}
      ])

    loop =
      schedule_pattern(organization, version, route, %{id: "LOOP", name: "Loop", sort: 1}, [
        {"OVW1_S1", 0, 0, 1},
        {"OVW1_S2", 120, 120, 0},
        {"OVW1_S1", 240, 240, 0},
        {"OVW1_S3", 360, 360, 0}
      ])

    short =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "SHORT", name: "Short turn", sort: 2},
        [
          {"OVW1_S1", 0, 0, 1},
          {"OVW1_S2", 120, 120, 0}
        ]
      )

    back =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "BACK", name: "Back", direction: 1, sort: 0},
        [
          {"OVW1_S1", 0, 0, 1},
          {"OVW1_S2", 120, 120, 0}
        ]
      )

    Enum.each(["06:00:00", "07:00:00", "08:00:00"], &trip(organization, version, route, full, &1))
    Enum.each(["09:00:00", "10:00:00"], &trip(organization, version, route, loop, &1))
    trip(organization, version, route, short, "11:00:00")
    trip(organization, version, route, back, "12:00:00")

    %{route: route, full: full, loop: loop, short: short, back: back}
  end

  # A route with a single direction-0 pattern: the direction toggle can point at
  # a direction no pattern serves.
  defp empty_direction_route(%{organization: organization, version: version}) do
    route = route(organization, version, "OVW2")
    Enum.each(1..2, &stop(organization, version, "OVW2", &1))

    schedule_pattern(organization, version, route, %{id: "ONLY", name: "Only", sort: 0}, [
      {"OVW2_S1", 0, 0, 1},
      {"OVW2_S2", 120, 120, 0}
    ])

    route
  end

  # The compare URL's query keys keep the LiveView's order (`@query_keys`), so
  # `assert_patch/2` can compare the exact string.
  @query_keys ~w(a b service ta tb reverse view dir picker)

  defp compare_path(version, route, params) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    query =
      for key <- @query_keys,
          value = params[key],
          value not in [nil, ""],
          do: {key, value}

    case query do
      [] -> base
      query -> base <> "?" <> URI.encode_query(query)
    end
  end

  defp overview_stop_ids(html) do
    ~r/<tr[^>]*id="overview-row-\d+"[^>]*data-stop-id="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, stop_id] -> stop_id end)
  end

  defp row_html(view, selector), do: view |> element(selector) |> render()

  describe "the all-patterns overview" do
    setup :editor_scope

    test "view=all renders one row per aligned visit with its served counts",
         %{conn: conn, version: version} = context do
      %{route: route} = overview_routes(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"view" => "all"}))

      assert has_element?(view, "#compare-overview")
      assert has_element?(view, "#compare-view-all[aria-current='page']")
      refute has_element?(view, "#compare-two-view")
      refute has_element?(view, "#compare-slots")

      # The columns are this route direction's patterns, busiest first.
      assert has_element?(view, "#overview-pattern-FULL", "Full")
      assert has_element?(view, "#overview-pattern-LOOP", "Loop")
      assert has_element?(view, "#overview-pattern-SHORT", "Short turn")
      refute has_element?(view, "#overview-pattern-BACK")

      assert has_element?(view, "#overview-pattern-FULL", "Typical · 4 stops")
      assert has_element?(view, "#overview-pattern-FULL", "3 trips on Weekday")
      assert has_element?(view, "#overview-pattern-LOOP", "2 trips on Weekday")
      assert has_element?(view, "#overview-pattern-SHORT", "1 trip on Weekday")

      # Five aligned visits: LOOP's second S1 visit keeps its own row between S2
      # and S3, and SHORT's two stops add no row of their own (AC-21, FH-27).
      assert overview_stop_ids(render(view)) == ~w(OVW1_S1 OVW1_S2 OVW1_S1 OVW1_S3 OVW1_S4)

      assert has_element?(view, "#overview-row-0", "3 of 3")
      assert has_element?(view, "#overview-row-1", "3 of 3")
      assert has_element?(view, "#overview-row-2", "1 of 3")
      assert has_element?(view, "#overview-row-3", "2 of 3")
      assert has_element?(view, "#overview-row-4", "1 of 3")

      # FULL's two ends are timepoints, so those rows say so and S2's does not.
      assert has_element?(view, "#overview-row-0", "Stop OVW1_S1 · timepoint")
      assert has_element?(view, "#overview-row-4", "Stop OVW1_S4 · timepoint")
      refute has_element?(view, "#overview-row-1", "timepoint")

      assert has_element?(view, "#overview-row-0", "OVW1 Stop 1")
      assert has_element?(view, "#overview-row-4", "OVW1 Stop 4")
    end

    test "a repeated visit keeps its own lane and the pass line fills the span",
         %{conn: conn, version: version} = context do
      %{route: route} = overview_routes(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"view" => "all"}))

      # LOOP's own S1 row carries LOOP's third visit and sits inside FULL's span,
      # where FULL has no mark of its own: its lane is the faint pass line.
      assert has_element?(view, "#overview-row-2 td[data-pattern='LOOP'][data-served='3']")
      refute has_element?(view, "#overview-row-2 td[data-pattern='FULL'][data-served]")
      assert row_html(view, "#overview-row-2 td[data-pattern='FULL']") =~ "opacity-45"
      refute row_html(view, "#overview-row-2 td[data-pattern='SHORT']") =~ "opacity-45"

      # SHORT ends at S2, so its lane has no mark past that row and no pass line
      # either: the pattern is over, not running on.
      assert has_element?(view, "#overview-row-1 td[data-pattern='SHORT'][data-served='2']")
      assert has_element?(view, "#overview-row-3 td[data-pattern='SHORT']")
      refute has_element?(view, "#overview-row-3 td[data-pattern='SHORT'][data-served]")
      refute row_html(view, "#overview-row-3 td[data-pattern='SHORT']") =~ "opacity-45"

      # The last row serves only FULL.
      assert has_element?(view, "#overview-row-4 td[data-pattern='FULL'][data-served='4']")
      refute has_element?(view, "#overview-row-4 td[data-pattern='LOOP'][data-served]")
    end

    test "the direction toggle patches dir and shows that direction only",
         %{conn: conn, version: version} = context do
      %{route: route} = overview_routes(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"view" => "all"}))

      assert has_element?(view, "#overview-dir-0[aria-current='page']")
      assert has_element?(view, "#overview-dir-0", "Direction 0")

      view |> element("#overview-dir-1") |> render_click()

      assert_patch(view, compare_path(version, route, %{"view" => "all", "dir" => "1"}))

      assert has_element?(view, "#overview-dir-1[aria-current='page']")
      assert has_element?(view, "#overview-pattern-BACK", "Back")
      refute has_element?(view, "#overview-pattern-FULL")
      assert overview_stop_ids(render(view)) == ~w(OVW1_S1 OVW1_S2)
      assert has_element?(view, "#overview-row-0", "1 of 1")
      assert has_element?(view, "#overview-row-1", "1 of 1")
    end

    test "a direction with no patterns says so instead of an empty table",
         %{conn: conn, version: version} = context do
      route = empty_direction_route(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"view" => "all"}))

      assert has_element?(view, "#overview-pattern-ONLY", "Only")
      refute has_element?(view, "#overview-empty")

      view |> element("#overview-dir-1") |> render_click()

      assert_patch(view, compare_path(version, route, %{"view" => "all", "dir" => "1"}))
      assert has_element?(view, "#overview-empty", "No patterns in Direction 1")
      refute has_element?(view, "#overview-table")
    end

    test "checking a third pattern unchecks the oldest and compares in pick order",
         %{conn: conn, version: version} = context do
      %{route: route} = overview_routes(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"view" => "all"}))

      assert has_element?(view, "#overview-hint", "Choose two patterns")
      assert has_element?(view, "#overview-compare[disabled][data-unavailable]")

      view |> element("#overview-pick-FULL") |> render_click()

      assert has_element?(view, "#overview-pick-FULL[checked]")
      assert has_element?(view, "#overview-hint", "Choose one more pattern.")
      assert has_element?(view, "#overview-compare[disabled][data-unavailable]")

      view |> element("#overview-pick-LOOP") |> render_click()

      assert has_element?(view, "#overview-pick-LOOP[checked]")
      assert has_element?(view, "#overview-hint", "Ready to compare.")
      refute has_element?(view, "#overview-compare[disabled]")
      refute has_element?(view, "#overview-compare[data-unavailable]")
      assert has_element?(view, "#overview-pattern-FULL", "Pattern A")
      assert has_element?(view, "#overview-pattern-LOOP", "Pattern B")

      # A third pick drops the oldest, so the two compared are the last two
      # chosen.
      view |> element("#overview-pick-SHORT") |> render_click()

      refute has_element?(view, "#overview-pick-FULL[checked]")
      assert has_element?(view, "#overview-pick-LOOP[checked]")
      assert has_element?(view, "#overview-pick-SHORT[checked]")
      assert has_element?(view, "#overview-pattern-LOOP", "Pattern A")
      assert has_element?(view, "#overview-pattern-SHORT", "Pattern B")

      # Unticking the second pick goes back to one chosen pattern.
      view |> element("#overview-pick-SHORT") |> render_click()

      refute has_element?(view, "#overview-pick-SHORT[checked]")
      assert has_element?(view, "#overview-pick-LOOP[checked]")
      assert has_element?(view, "#overview-compare[disabled]")

      view |> element("#overview-pick-SHORT") |> render_click()
      view |> element("#overview-compare") |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "LOOP", "b" => "SHORT"})
      )

      assert has_element?(view, "#compare-two-view")
      assert has_element?(view, "#slot-a", "Loop")
      assert has_element?(view, "#slot-b", "Short turn")
    end

    test "the calendar select counts the direction and keeps the picks",
         %{conn: conn, version: version} = context do
      %{route: route} = overview_routes(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"view" => "all"}))

      assert has_element?(view, "#compare-calendar", "Weekday (6 trips)")
      assert has_element?(view, "#compare-calendar", "Saturday (0 trips)")

      view |> element("#overview-pick-FULL") |> render_click()

      view
      |> element("#compare-calendar")
      |> render_change(%{"service" => "SATURDAY"})

      assert_patch(
        view,
        compare_path(version, route, %{"view" => "all", "service" => "SATURDAY"})
      )

      assert has_element?(view, "#overview-pattern-FULL", "No trips on Saturday")
      assert has_element?(view, "#overview-pick-FULL[checked]")
    end

    test "the picks belong to one direction and reset when it changes",
         %{conn: conn, version: version} = context do
      %{route: route} = overview_routes(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"view" => "all"}))

      view |> element("#overview-pick-FULL") |> render_click()
      view |> element("#overview-pick-LOOP") |> render_click()

      assert has_element?(view, "#overview-compare", "Compare 2 patterns")
      assert has_element?(view, "#overview-pattern-FULL", "Pattern A")

      view |> element("#overview-dir-1") |> render_click()

      assert_patch(view, compare_path(version, route, %{"view" => "all", "dir" => "1"}))
      assert has_element?(view, "#overview-pick-BACK")
      refute has_element?(view, "#overview-pick-BACK[checked]")
      assert has_element?(view, "#overview-hint", "Choose two patterns")
      assert has_element?(view, "#overview-compare[disabled]")
    end
  end
end
