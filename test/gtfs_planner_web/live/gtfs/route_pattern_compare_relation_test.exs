defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareRelationTest do
  @moduledoc """
  Merge evidence (EV-12) for CL-4 and CL-17: the compare page's relationship
  callouts and the reverse toggle. Opposite directions show the info callout
  with "Show B in reverse order"; patching `reverse=1` shows the reversed
  callout, the countdown note on B's slot card and "Show B in its own order";
  identical stop lists show the success callout; a pair with no shared stops
  shows the neutral callout and compares no times.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); no adapter is substituted because no case
  renders the outage state (EV-10 owns it). Expected copy, ids and URLs are
  hand-derived from the fixtures below. The focused gate command is deferred to
  branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_relation_test.exs

  The prepared cases also name two stop-table facts — B's ring numbers count
  down under `reverse=1`, and no running-time header renders while reversed or
  with no shared stops. The stop table is step 16's surface (EV-14); this file
  pins the parts of those facts the compare read already carries: the reversed
  callout and B's note, plus a `#compare-stops` guard that stays meaningful once
  the table renders the "B vs A" running-time column.
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
        alias: "route-pattern-compare-relation-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-relation-#{System.unique_integer([:positive])}@example.com"
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
      route_pattern_typicality: Map.get(attrs, :typicality, 1),
      route_pattern_sort_order: Map.get(attrs, :sort_order, 0),
      timing_name: attrs.timing_name,
      stops: stops
    })
  end

  # Route CMP1 runs Full (S1–S4), Back (the same stops in B's own reverse
  # order), Twin (Full's stop list again) and Short (Full's first three
  # stops); route CMP2 carries Alone, which shares no stop with them. The
  # Weekday calendar and Full's two trips give the page a resolved calendar.
  defp comparison_route(%{organization: organization, version: version}) do
    route = route(organization, version, "CMP1")
    Enum.each(1..4, &stop(organization, version, "CMP1", &1))

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      service_description: "Weekday"
    })

    full =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "FULL", name: "Full", direction_id: 0, sort_order: 0, timing_name: "Weekday base"},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 0},
          {"CMP1_S4", 360, 360, 1}
        ]
      )

    back =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "BACK", name: "Back", direction_id: 1, sort_order: 0, timing_name: "Weekday base"},
        [
          {"CMP1_S4", 0, 0, 1},
          {"CMP1_S3", 120, 120, 0},
          {"CMP1_S2", 240, 240, 0},
          {"CMP1_S1", 360, 360, 1}
        ]
      )

    twin =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "TWIN", name: "Twin", direction_id: 0, sort_order: 1, timing_name: "Weekday base"},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 0},
          {"CMP1_S4", 360, 360, 1}
        ]
      )

    short =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "SHORT",
          name: "Short turn",
          direction_id: 0,
          sort_order: 2,
          timing_name: "Weekday short"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 1}
        ]
      )

    Enum.each(["06:00:00", "07:00:00"], fn start_time ->
      schedule_trip_fixture(organization.id, version.id, route.route_id, full, %{
        service_id: "WEEKDAY",
        start_time: start_time
      })
    end)

    other_route = route(organization, version, "CMP2")
    Enum.each(1..2, &stop(organization, version, "CMP2", &1))

    alone =
      schedule_pattern(
        organization,
        version,
        other_route,
        %{id: "ALONE", name: "Alone", direction_id: 0, sort_order: 0, timing_name: "Other base"},
        [{"CMP2_S1", 0, 0, 1}, {"CMP2_S2", 600, 600, 1}]
      )

    %{
      route: route,
      full: full,
      back: back,
      twin: twin,
      short: short,
      other_route: other_route,
      alone: alone
    }
  end

  defp compare_path(version, route, params) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  describe "relationship callouts" do
    setup :editor_scope

    test "opposite directions show the callout and patch reverse=1",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "BACK"}))

      assert has_element?(
               view,
               "#relation-opposite",
               "These patterns run in opposite directions"
             )

      assert has_element?(
               view,
               "#relation-opposite",
               "serves most of the same stops in reverse order"
             )

      refute has_element?(view, "#relation-reversed")
      refute has_element?(view, "#relation-identical")
      refute has_element?(view, "#relation-none")

      view
      |> element("#compare-reverse-toggle", "Show B in reverse order")
      |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "BACK", "reverse" => "1"})
      )

      assert has_element?(view, "#relation-reversed", "B is shown in reverse order")
    end

    test "reverse=1 shows the reversed callout, B's note and the way back",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{
            "a" => "FULL",
            "b" => "BACK",
            "service" => "WEEKDAY",
            "reverse" => "1"
          })
        )

      assert has_element?(view, "#relation-reversed", "B is shown in reverse order")

      assert has_element?(
               view,
               "#relation-reversed",
               "Its stops are listed last to first so they line up with"
             )

      assert has_element?(
               view,
               "#relation-reversed",
               "Running times aren’t compared while B is reversed"
             )

      refute has_element?(view, "#relation-opposite")
      assert has_element?(view, "#slot-b", "shown in reverse order")
      refute has_element?(view, "#slot-a", "shown in reverse order")

      # The stop table is step 16's surface; no running-time column header may
      # render while B is reversed (the reference's showTimesNow is false).
      refute has_element?(view, "#compare-stops", "B vs A")

      view
      |> element("#compare-reverse-toggle", "Show B in its own order")
      |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "BACK", "service" => "WEEKDAY"})
      )

      assert has_element?(view, "#relation-opposite", "These patterns run in opposite directions")
    end

    test "identical stop lists show the success callout",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "TWIN"}))

      assert has_element?(view, "#relation-identical", "Same stops in the same order")
      assert has_element?(view, "#relation-identical", "serve the same 4 stops in the same order")
      refute has_element?(view, "#relation-opposite")
      refute has_element?(view, "#relation-none")
      refute has_element?(view, "#compare-reverse-toggle")
    end

    test "disjoint patterns show the neutral callout and compare no times",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "ALONE"}))

      assert has_element?(view, "#relation-none", "These patterns share no stops")
      assert has_element?(view, "#relation-none", "running times aren’t compared")
      assert has_element?(view, "#slot-b", "Alone")
      refute has_element?(view, "#relation-opposite")
      refute has_element?(view, "#relation-identical")
      refute has_element?(view, "#compare-reverse-toggle")

      # Step 16's running-time column must not render for a pair with no
      # shared stops; the prepared "no running-time header" case.
      refute has_element?(view, "#compare-stops", "B vs A")
    end

    test "reverse=1 outranks the identical callout", %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "TWIN", "reverse" => "1"})
        )

      assert has_element?(view, "#relation-reversed")
      refute has_element?(view, "#relation-identical")
    end

    test "a partly shared pair shows no relationship callout",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      assert has_element?(view, "#slot-a", "Full")
      assert has_element?(view, "#slot-b", "Short turn")
      refute has_element?(view, "[id^='relation-']")
      refute has_element?(view, "#compare-reverse-toggle")
    end
  end
end
