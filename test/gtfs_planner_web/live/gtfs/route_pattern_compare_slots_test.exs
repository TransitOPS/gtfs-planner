defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareSlotsTest do
  @moduledoc """
  Merge evidence (EV-11) for CL-8, CL-11 and CL-16: the compare page's pattern
  slot cards show each side's name, direction, stop count, typicality, service
  description and trips on the chosen calendar, B's cross-route badge, the
  "Not used on … · runs on …" fallback, the no-timings "None yet" state, the
  running-times select and the swap (including its cross-route navigation and
  the unavailable and choose-B variants).

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); no adapter is substituted because no case
  renders the outage state (EV-10 owns it). Expected copy, ids and URLs are
  hand-derived from the fixtures below. The focused gate command is deferred to
  branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_slots_test.exs
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{
        alias: "route-pattern-compare-slots-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-slots-#{System.unique_integer([:positive])}@example.com"
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

  # Route CMP1 with its four stops and a Weekday calendar; Full runs twice,
  # Short turn once, and Bare has occurrences but no timing. Route CMP2 carries
  # the cross-route pattern OTHER. Full carries the service description, so the
  # meta line's optional part is asserted on a pattern that has one.
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
        %{id: "FULL", name: "Full", direction_id: 0, sort_order: 0, timing_name: "Weekday base"},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 0},
          {"CMP1_S4", 360, 360, 1}
        ]
      )

    Repo.update!(Ecto.Changeset.change(full.pattern, route_pattern_time_desc: "Weekday service"))

    short =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "SHORT",
          name: "Short turn",
          direction_id: 0,
          sort_order: 1,
          timing_name: "Weekday short"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 0},
          {"CMP1_S3", 240, 240, 1}
        ]
      )

    weekend = timed_pattern_fixture(short.pattern, %{name: "Weekend"})

    bare =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "BARE",
        route_pattern_name: "Bare",
        direction_id: 0,
        route_pattern_sort_order: 2,
        route_pattern_typicality: 1
      })

    ["CMP1_S1", "CMP1_S2"]
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(bare, stop_id, position)
    end)

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

    other_route = route(organization, version, "CMP2")
    Enum.each(1..2, &stop(organization, version, "CMP2", &1))

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
        [{"CMP2_S1", 0, 0, 1}, {"CMP2_S2", 600, 600, 1}]
      )

    %{
      route: route,
      full: full,
      short: short,
      weekend: weekend,
      bare: bare,
      other_route: other_route,
      other: other
    }
  end

  defp compare_path(version, route, params) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  describe "pattern slots" do
    setup :editor_scope

    test "the cards show each pattern's facts and trips on the calendar",
         %{conn: conn, version: version} = context do
      %{route: route, full: full, short: short} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      assert has_element?(view, "#slot-a[aria-label='Pattern A']")
      assert has_element?(view, "#slot-a", "Full")
      assert has_element?(view, "#slot-a", "Direction 0 · 4 stops · Typical · Weekday service")
      assert has_element?(view, "#slot-a", ~r/2 trips\s*on Weekday/)
      assert has_element?(view, "#slot-a option[value='#{full.timing.id}'][selected]")

      assert has_element?(view, "#slot-b[aria-label='Pattern B']")
      assert has_element?(view, "#slot-b", "Short turn")
      assert has_element?(view, "#slot-b", "Direction 0 · 3 stops · Typical")
      assert has_element?(view, "#slot-b", ~r/1 trip\s*on Weekday/)
      assert has_element?(view, "#slot-b option[value='#{short.timing.id}'][selected]")

      assert has_element?(
               view,
               "#slot-b option[value='#{short.timing.id}']",
               "Weekday short · 1 trip"
             )

      assert has_element?(view, "#compare-swap[aria-label='Swap A and B'][title='Swap A and B']")

      assert has_element?(
               view,
               "#slot-a-open[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns/FULL?task=stops']"
             )

      assert has_element?(
               view,
               "#slot-b-open[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns/SHORT?task=stops']"
             )
    end

    test "a pattern unused on the calendar names the calendars it runs on",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(
          conn,
          compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "service" => "SATURDAY"})
        )

      assert has_element?(
               view,
               "#slot-a",
               ~r/Not used on Saturday\s*·\s*runs on Weekday/
             )

      refute has_element?(view, "#slot-a", "2 trips on Weekday")
    end

    test "B on another route carries its route badge and name",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "OTHER"}))

      assert has_element?(view, "#slot-b", "Other route pattern")
      assert has_element?(view, "#slot-b", "CMP2")
      assert has_element?(view, "#slot-b", "CMP2 corridor")
      refute has_element?(view, "#slot-a", "CMP2 corridor")
    end

    test "swap patches A and B", %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      view |> element("#compare-swap") |> render_click()

      assert_patch(view, compare_path(version, route, %{"a" => "SHORT", "b" => "FULL"}))
    end

    test "a pinned timing follows its pattern across the swap",
         %{conn: conn, version: version} = context do
      %{route: route, full: full, short: short} = comparison_route(context)

      params = %{
        "a" => "FULL",
        "b" => "SHORT",
        "ta" => full.timing.id,
        "tb" => short.timing.id
      }

      {:ok, view, _html} = live(conn, compare_path(version, route, params))

      view |> element("#compare-swap") |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{
          "a" => "SHORT",
          "b" => "FULL",
          "ta" => short.timing.id,
          "tb" => full.timing.id
        })
      )
    end

    test "a cross-route swap navigates to the other route's compare page",
         %{conn: conn, version: version} = context do
      %{route: route, other_route: other_route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "OTHER"}))

      view |> element("#compare-swap") |> render_click()

      assert_redirect(
        view,
        compare_path(version, other_route, %{"a" => "OTHER", "b" => "FULL"})
      )
    end

    test "an unknown B shows the unavailable card naming it",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "UNKNOWN"}))

      assert has_element?(view, "#slot-a", "Full")
      assert has_element?(view, "#slot-b-unavailable", "Pattern B isn’t available")
      assert has_element?(view, "#slot-b-unavailable", "UNKNOWN")
      assert has_element?(view, "#slot-b-unavailable a", "Choose pattern B")
      assert has_element?(view, "#compare-swap[disabled]")

      view |> element("#slot-b-unavailable a", "Choose pattern B") |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "UNKNOWN", "picker" => "b"})
      )
    end

    test "a visit without B shows the choose-B card", %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"a" => "FULL"}))

      assert has_element?(view, "#slot-a", "Full")
      assert has_element?(view, "#slot-b-empty", "Choose a pattern to compare")
      assert has_element?(view, "#slot-b-empty a", "Choose pattern B")
      assert has_element?(view, "#compare-swap[disabled]")
    end

    test "Change A and Change B open the picker through the URL",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      view |> element("#slot-a-change") |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "picker" => "a"})
      )
    end

    test "changing the B running-times select patches tb",
         %{conn: conn, version: version} = context do
      %{route: route, weekend: weekend} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      view
      |> element("#slot-b-timing")
      |> render_change(%{"tb" => weekend.id})

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "tb" => weekend.id})
      )
    end

    test "a pattern with no timings shows None yet and its Timings task",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "BARE"}))

      assert has_element?(view, "#slot-b", "Running times")
      assert has_element?(view, "#slot-b", "None yet")

      assert has_element?(
               view,
               "#slot-b-add-times[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns/BARE?task=timings']"
             )

      refute has_element?(view, "#slot-b-timing")
    end
  end
end
