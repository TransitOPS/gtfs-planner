defmodule GtfsPlannerWeb.Gtfs.RoutePatternComparePickerTest do
  @moduledoc """
  Merge evidence (EV-16) for CL-20: the compare page's pattern picker opens from
  the URL's `picker` param as the planner drawer, searches pattern name, route
  name/number and served stop names in memory, groups this route by direction
  and then "Other routes", ranks by stops in common with the other side and then
  trips on the chosen calendar, disables the other side's row, marks the current
  one, and patches the choice back into the URL without the picker or the
  chosen side's pinned timing.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); no adapter is substituted because no case
  renders an outage state. Expected copy, ids and URLs are hand-derived from the
  fixtures below. The focused gate command is:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_picker_test.exs
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
        alias: "route-pattern-compare-picker-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-picker-#{System.unique_integer([:positive])}@example.com"
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

  defp stop(organization, version, stop_id, stop_name) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: stop_name,
      location_type: 0
    })
  end

  defp schedule_pattern(organization, version, route, attrs, stops) do
    schedule_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      route_pattern_id: attrs.id,
      route_pattern_name: attrs.name,
      direction_id: attrs.direction_id,
      route_pattern_typicality: Map.get(attrs, :typicality, 1),
      route_pattern_sort_order: Map.get(attrs, :sort_order, 0),
      timing_name: attrs.timing_name,
      stops: stops
    })
  end

  defp trip(organization, version, route, pattern, start_time) do
    schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
      service_id: "WEEKDAY",
      start_time: start_time
    })
  end

  # Route CMP1 carries four direction-0 patterns and one direction-1 pattern;
  # route CMP2 carries OTHER (which serves CMP1 stops 1 and 5 and its own
  # terminal), TWIN (which serves only CMP1 stops 1 and 5) and EXPRESS (which
  # serves no CMP1 stop). With FULL (stops 1 to 4) as A: DEV shares 4 stops with
  # 0 trips, MID shares 3 with 2 trips and SHORT shares 3 with 1, so the read's
  # ranking is stops in common first, trips second; OTHER and TWIN both share 1
  # with 3 and 1 trips, and EXPRESS shares none. DEV, MID, SHORT, LATE and
  # EXPRESS have no trips, so the picker's "not used on Weekday" branch is
  # asserted on them.
  defp comparison_fixtures(%{organization: organization, version: version}) do
    home = route(organization, version, "CMP1")
    Enum.each(1..5, &stop(organization, version, "CMP1_S#{&1}", "CMP1 Stop #{&1}"))

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      service_description: "Weekday"
    })

    full =
      schedule_pattern(
        organization,
        version,
        home,
        %{id: "FULL", name: "Full", direction_id: 0, sort_order: 0, timing_name: "Weekday base"},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 0},
          {"CMP1_S4", 360, 360, 1}
        ]
      )

    dev =
      schedule_pattern(
        organization,
        version,
        home,
        %{id: "DEV", name: "Deviation", direction_id: 0, sort_order: 1, timing_name: "Dev"},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 180, 180, 0},
          {"CMP1_S3", 300, 300, 0},
          {"CMP1_S4", 480, 480, 0},
          {"CMP1_S5", 600, 600, 1}
        ]
      )

    mid =
      schedule_pattern(
        organization,
        version,
        home,
        %{id: "MID", name: "Midday", direction_id: 0, sort_order: 2, timing_name: "Mid"},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 1}
        ]
      )

    short =
      schedule_pattern(
        organization,
        version,
        home,
        %{
          id: "SHORT",
          name: "Short turn",
          direction_id: 0,
          sort_order: 3,
          timing_name: "Weekday short"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 1}
        ]
      )

    late =
      schedule_pattern(
        organization,
        version,
        home,
        %{id: "LATE", name: "Late night", direction_id: 1, sort_order: 0, timing_name: "Late"},
        [
          {"CMP1_S5", 0, 0, 1},
          {"CMP1_S4", 120, 120, 0},
          {"CMP1_S3", 240, 240, 0},
          {"CMP1_S2", 360, 360, 0},
          {"CMP1_S1", 480, 480, 1}
        ]
      )

    other_route = route(organization, version, "CMP2")
    stop(organization, version, "CMP2_S1", "CMP2 Stop 1")
    stop(organization, version, "CMP2_S2", "CMP2 Stop 2")

    other =
      schedule_pattern(
        organization,
        version,
        other_route,
        %{
          id: "OTHER",
          name: "Other route pattern",
          direction_id: 0,
          sort_order: 0,
          timing_name: "Other weekday"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP2_S2", 300, 300, 1},
          {"CMP1_S5", 600, 600, 1}
        ]
      )

    twin =
      schedule_pattern(
        organization,
        version,
        other_route,
        %{id: "TWIN", name: "Twin", direction_id: 0, sort_order: 1, timing_name: "Twin"},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S5", 600, 600, 1}
        ]
      )

    express =
      schedule_pattern(
        organization,
        version,
        other_route,
        %{
          id: "EXPRESS",
          name: "Express",
          direction_id: 0,
          sort_order: 2,
          timing_name: "Express"
        },
        [
          {"CMP2_S1", 0, 0, 1}
        ]
      )

    Enum.each(["06:00:00", "07:00:00"], &trip(organization, version, home, full, &1))
    Enum.each(["06:10:00", "07:10:00"], &trip(organization, version, home, mid, &1))
    trip(organization, version, home, short, "06:30:00")

    Enum.each(
      ["06:00:00", "07:00:00", "08:00:00"],
      &trip(organization, version, other_route, other, &1)
    )

    trip(organization, version, other_route, twin, "06:20:00")

    %{
      route: home,
      other_route: other_route,
      full: full,
      dev: dev,
      mid: mid,
      short: short,
      late: late,
      other: other,
      twin: twin,
      express: express
    }
  end

  defp compare_path(version, route, params) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp row_positions(html, markers) do
    Enum.map(markers, fn marker ->
      case :binary.match(html, marker) do
        {position, _length} -> position
        :nomatch -> flunk("expected #{inspect(marker)} in the rendered picker")
      end
    end)
  end

  describe "pattern picker" do
    setup :editor_scope

    test "picker=b opens the drawer with the search's focus contract",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "b"})
        )

      assert has_element?(
               view,
               "#compare-picker-overlay[data-open='true'][data-initial-focus-id='picker-q'][data-return-focus-id='slot-b-change']"
             )

      assert has_element?(view, "#compare-picker[aria-labelledby='compare-picker-title']")
      assert has_element?(view, "#compare-picker", "Choose pattern B")
      assert has_element?(view, "#compare-picker", "To compare with")
      assert has_element?(view, "#compare-picker", "Full")
      assert has_element?(view, "#picker-q[name='query']")

      assert has_element?(
               view,
               "#picker-q-hint",
               "Search by pattern name, route or a stop it serves."
             )

      assert has_element?(
               view,
               "#compare-picker",
               "Patterns from #{version.name} only. To compare another version, switch versions first."
             )

      assert has_element?(view, "#picker-keep", "Keep current pattern")
    end

    test "searching a stop name finds a pattern on another route and names the stop",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "b"})
        )

      view
      |> element("#picker-q")
      |> render_change(%{"query" => "CMP2 Stop 2"})

      assert has_element?(view, "#picker-list h3", "Other routes")
      assert has_element?(view, "#picker-pattern-OTHER", "Other route pattern")
      assert has_element?(view, "#picker-pattern-OTHER", "stops at CMP2 Stop 2")
      refute has_element?(view, "#picker-pattern-TWIN")
      refute has_element?(view, "#picker-pattern-EXPRESS")
      refute has_element?(view, "#picker-pattern-FULL")
      refute has_element?(view, "#picker-empty")
    end

    test "a query with no match shows the empty state and Clear search restores the list",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "b"})
        )

      view |> element("#picker-q") |> render_change(%{"query" => "Seal Rock"})

      assert has_element?(view, "#picker-empty")
      assert has_element?(view, "#picker-empty", "No patterns match “Seal Rock”")

      assert has_element?(
               view,
               "#picker-empty",
               "Check the spelling, or search by a stop the pattern serves."
             )

      view |> element("#picker-clear", "Clear search") |> render_click()

      refute has_element?(view, "#picker-empty")
      assert has_element?(view, "#picker-q[value='']")
      assert has_element?(view, "#picker-pattern-FULL[disabled]")
    end

    test "the other side's row is disabled and the current row is marked",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "b"})
        )

      assert has_element?(view, "#picker-pattern-FULL[disabled]", "This is A")
      assert has_element?(view, "#picker-pattern-SHORT[aria-current='true']", "Current")
      refute has_element?(view, "#picker-pattern-SHORT[disabled]")
    end

    test "picker=a disables B and marks A; choosing another route's pattern navigates there",
         %{conn: conn, version: version} = context do
      %{route: route, other_route: other_route} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "a"})
        )

      assert has_element?(view, "#compare-picker", "Choose pattern A")
      assert has_element?(view, "#picker-pattern-SHORT[disabled]", "This is B")
      assert has_element?(view, "#picker-pattern-FULL[aria-current='true']", "Current")
      refute has_element?(view, "#picker-pattern-FULL[disabled]")

      view |> element("#picker-pattern-OTHER") |> render_click()

      assert_redirect(
        view,
        compare_path(version, other_route, %{"a" => "OTHER", "b" => "SHORT"})
      )
    end

    test "rows are ranked by stops in common, then trips, inside the direction groups",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "b"})
        )

      assert has_element?(view, "#picker-list h3", "Route CMP1 CMP1 corridor · Direction 0")
      assert has_element?(view, "#picker-list h3", "Route CMP1 CMP1 corridor · Direction 1")
      assert has_element?(view, "#picker-list h3", "Other routes")

      assert has_element?(view, "#picker-pattern-DEV", "4 stops in common")
      assert has_element?(view, "#picker-pattern-MID", "3 stops in common")
      assert has_element?(view, "#picker-pattern-SHORT[aria-current='true']", "Current")
      assert has_element?(view, "#picker-pattern-LATE", "4 stops in common")
      assert has_element?(view, "#picker-pattern-OTHER", "1 stop in common")
      assert has_element?(view, "#picker-pattern-TWIN", "1 stop in common")
      assert has_element?(view, "#picker-pattern-EXPRESS", "No stops in common")

      assert has_element?(view, "#picker-pattern-MID", "2 trips on Weekday")
      assert has_element?(view, "#picker-pattern-SHORT", "1 trip on Weekday")
      assert has_element?(view, "#picker-pattern-OTHER", "3 trips on Weekday")
      assert has_element?(view, "#picker-pattern-TWIN", "1 trip on Weekday")
      assert has_element?(view, "#picker-pattern-DEV", "not used on Weekday")
      assert has_element?(view, "#picker-pattern-EXPRESS", "not used on Weekday")

      positions =
        row_positions(render(view), [
          "picker-pattern-DEV",
          "picker-pattern-MID",
          "picker-pattern-SHORT",
          "· Direction 1",
          "picker-pattern-LATE",
          "Other routes",
          "picker-pattern-OTHER",
          "picker-pattern-TWIN",
          "picker-pattern-EXPRESS"
        ])

      assert positions == Enum.sort(positions)
    end

    test "choosing a row patches b and drops the picker and the pinned timing",
         %{conn: conn, version: version} = context do
      %{route: route, short: short} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{
            "a" => "FULL",
            "b" => "SHORT",
            "tb" => short.timing.id,
            "picker" => "b"
          })
        )

      view |> element("#picker-pattern-OTHER") |> render_click()

      assert_patch(view, compare_path(version, route, %{"a" => "FULL", "b" => "OTHER"}))
      refute has_element?(view, "#compare-picker")
      assert has_element?(view, "#slot-b", "Other route pattern")
      refute has_element?(view, "#slot-b option[value='#{short.timing.id}']")
    end

    test "closing the picker patches it away and keeps the selection",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_fixtures(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "b"})
        )

      view |> element("#picker-keep") |> render_click()

      assert_patch(view, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))
      refute has_element?(view, "#compare-picker")
      assert has_element?(view, "#slot-a", "Full")
      assert has_element?(view, "#slot-b", "Short turn")
    end

    test "patterns of another version or organization do not appear",
         %{conn: conn, version: version, organization: organization} = context do
      %{route: route} = comparison_fixtures(context)

      foreign_version = gtfs_version_fixture(organization.id, %{name: "Foreign version"})
      foreign_route = route(organization, foreign_version, "FOR1")
      stop(organization, foreign_version, "FOR1_S1", "Foreign stop")

      schedule_pattern(
        organization,
        foreign_version,
        foreign_route,
        %{
          id: "FOREIGN",
          name: "Foreign version pattern",
          direction_id: 0,
          sort_order: 0,
          timing_name: "Foreign"
        },
        [{"FOR1_S1", 0, 0, 1}]
      )

      foreign_org =
        organization_fixture(%{alias: "picker-foreign-org-#{System.system_time(:nanosecond)}"})

      foreign_org_version = gtfs_version_fixture(foreign_org.id)
      foreign_org_route = route(foreign_org, foreign_org_version, "FOR2")
      stop(foreign_org, foreign_org_version, "FOR2_S1", "Foreign organization stop")

      schedule_pattern(
        foreign_org,
        foreign_org_version,
        foreign_org_route,
        %{
          id: "FOREIGN_ORG",
          name: "Foreign organization pattern",
          direction_id: 0,
          sort_order: 0,
          timing_name: "Foreign org"
        },
        [{"FOR2_S1", 0, 0, 1}]
      )

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "b"})
        )

      refute has_element?(view, "#picker-list", "Foreign version pattern")
      refute has_element?(view, "#picker-list", "Foreign organization pattern")
      assert has_element?(view, "#picker-pattern-FULL")
    end
  end
end
