defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareEntryTest do
  @moduledoc """
  Merge evidence (EV-20) for CL-15: the Patterns tab's secondary "Compare
  patterns" entry and the pattern editor's "Compare with another pattern" link.
  Each exists only where the route has patterns, and each opens the compare page
  in the state the spec defines: no `a` resolves R8's default pair, and `a`
  alone opens the choose-B state with B's suggestions and A's stops.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); no adapter is substituted because no case
  renders an outage state. Expected ids, hrefs and the default pair are
  hand-derived from the fixtures below. The focused gate command is:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_entry_test.exs
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
        alias: "route-pattern-compare-entry-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-entry-#{System.unique_integer([:positive])}@example.com"
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
      direction_id: attrs.direction_id,
      route_pattern_sort_order: Map.get(attrs, :sort_order, 0),
      timing_name: attrs.name,
      stops: stops
    })
  end

  # Route CMP1 with its four stops, a Weekday calendar carrying the trips and an
  # idle Saturday: Full runs twice and Short turn once, both in direction 0, so
  # R8's entry pair is Full against Short turn on Weekday (A 2 · B 1) and the
  # choose-B state has exactly one suggestion.
  defp comparison_route(%{organization: organization, version: version}) do
    route = route(organization, version, "CMP1")
    Enum.each(1..4, &stop(organization, version, "CMP1", &1))

    Enum.each(~w(WEEKDAY SATURDAY), fn service_id ->
      calendar_fixture(organization.id, version.id, %{service_id: service_id})

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: String.capitalize(String.downcase(service_id))
      })
    end)

    full =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "FULL", name: "Full", direction_id: 0, sort_order: 0},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 1},
          {"CMP1_S3", 240, 240, 0},
          {"CMP1_S4", 360, 360, 1}
        ]
      )

    short =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "SHORT", name: "Short turn", direction_id: 0, sort_order: 1},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 1},
          {"CMP1_S3", 240, 240, 1}
        ]
      )

    Enum.each(["06:00:00", "07:00:00"], fn start_time ->
      schedule_trip_fixture(organization.id, version.id, route.route_id, full, %{
        service_id: "WEEKDAY",
        start_time: start_time
      })
    end)

    schedule_trip_fixture(organization.id, version.id, route.route_id, short, %{
      service_id: "WEEKDAY",
      start_time: "08:00:00"
    })

    %{route: route, full: full, short: short}
  end

  defp patterns_path(version, route), do: "/gtfs/#{version.id}/routes/#{route.route_id}/patterns"

  defp new_pattern_path(version, route),
    do: patterns_path(version, route) <> "/new"

  defp pattern_path(version, route, pattern_id),
    do: patterns_path(version, route) <> "/#{pattern_id}"

  defp compare_path(version, route, params \\ %{}) do
    base = patterns_path(version, route) <> "/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  describe "compare entry links" do
    setup :editor_scope

    test "the Patterns tab shows Compare patterns, which opens R8's default pair",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)
      entry_href = compare_path(version, route)
      default_pair = compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"})

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-compare[href='#{entry_href}']", "Compare patterns")
      assert has_element?(view, "#patterns-create")

      # The entry is a navigate link, so the browser follows it. The compare page
      # then resolves R8's entry pair from the seeded trips (Full 2, Short turn
      # 1) and pushes that pair as a patch; Phoenix.LiveViewTest's proxy does not
      # surface a patch issued during the connected mount, so the test performs
      # the same patch itself, as the live suite's entry case does.
      {:ok, compare_view, _html} = live(conn, entry_href)
      render_patch(compare_view, default_pair)

      assert has_element?(compare_view, "#compare-calendar", "Weekday (A 2 · B 1 trips)")
      assert has_element?(compare_view, "#slot-a", "Full")
      assert has_element?(compare_view, "#slot-b", "Short turn")
    end

    test "a route with no patterns has no Compare patterns entry",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "EMPTY1")

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-heading", "Stop patterns")
      refute has_element?(view, "#patterns-compare")
    end

    test "the pattern editor links to the choose-B state with A's stops",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)
      entry_href = compare_path(version, route, %{"a" => "FULL"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, "FULL"))

      assert has_element?(
               view,
               "#pattern-compare[href='#{entry_href}']",
               "Compare with another pattern"
             )

      {:ok, compare_view, _html} = live(conn, entry_href)

      # A is the edited pattern and B is unchosen: the page suggests the
      # direction's other patterns and lists A's own stops (AC-15).
      assert has_element?(compare_view, "#slot-a", "Full")
      assert has_element?(compare_view, "#slot-b-empty", "Choose a pattern to compare")
      assert has_element?(compare_view, "#summary-suggestions")
      assert has_element?(compare_view, "#summary-suggestion-SHORT", "Short turn")
      assert has_element?(compare_view, "#stops-title", "Stops in A")
      assert has_element?(compare_view, "#compare-stops", "CMP1 Stop 1")
      assert has_element?(compare_view, "#compare-stops", "CMP1 Stop 4")
      refute has_element?(compare_view, "#compare-row-0")
    end

    test "the creating page offers no compare link",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} = live(conn, new_pattern_path(version, route))

      assert has_element?(view, "#pattern-header")
      refute has_element?(view, "#pattern-compare")
    end
  end
end
