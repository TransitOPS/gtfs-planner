defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareSummaryTest do
  @moduledoc """
  Merge evidence (EV-13) for CL-7 and CL-18: the compare page's "What's
  different" summary. The numbered list renders the difference sentences from
  `Alignment.differences/2`'s detail — a replacement stretch with its anchor
  stops, added and skipped stops and stretch time; a short turn; a collapsed
  four-pair move; boarding labels; and the smaller-timing note. The metric strip
  shows end to end with the signed change and percentage, the trips per side on
  the chosen calendar and 20 departures-by-hour bars per side on one scale. With
  B absent the card shows the "Suggested comparisons" links, limited to three,
  patching `b`.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); no adapter is substituted because no case
  renders the outage state (EV-10 owns it). Expected copy, numbers and URLs are
  hand-derived from the fixtures below; the times are read from the read, never
  recomputed (`INV-5`), and the item buttons post no events (`INV-4`). The
  focused gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_summary_test.exs
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
        alias: "route-pattern-compare-summary-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-summary-#{System.unique_integer([:positive])}@example.com"
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

  defp stop(organization, version, suffix) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "CMP1_S#{suffix}",
      stop_name: "CMP1 Stop #{suffix}",
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

  # Route CMP1 with ten stops and a Weekday calendar. FULL is the five-stop
  # reference; DEV replaces its third stop with two own stops and takes 12 min
  # longer over the S2-S4 stretch (25:30 against 13:30); SHORT ends at S2;
  # MOVED_A and MOVED_B are the same eight stops rotated by four visits, which
  # leaves four moved pairs; BOARD_B's S2 only picks riders up where BOARD_A
  # does both; NUDGE is FULL with two 30 s stretch differences (direction 1, so
  # it stays out of A's suggestions). FULL/DEV/SHORT carry trips, giving the
  # strip both sides' counts and two hour bars on A against three on B.
  defp comparison_route(%{organization: organization, version: version}) do
    route = route(organization, version, "CMP1")
    Enum.each([1, 2, 3, "3A", "3B", 4, 5, 6, 7, 8], &stop(organization, version, &1))

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
          {"CMP1_S2", 180, 180, 0},
          {"CMP1_S3", 540, 540, 0},
          {"CMP1_S4", 990, 990, 0},
          {"CMP1_S5", 1200, 1200, 1}
        ]
      )

    dev =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "DEV",
          name: "Deviation",
          direction_id: 0,
          sort_order: 1,
          timing_name: "Weekday base"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 180, 180, 0},
          {"CMP1_S3A", 600, 600, 0},
          {"CMP1_S3B", 1200, 1200, 0},
          {"CMP1_S4", 1710, 1710, 0},
          {"CMP1_S5", 1920, 1920, 1}
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
          {"CMP1_S2", 180, 180, 1}
        ]
      )

    moved_a =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "MOVED_A",
          name: "Moved A",
          direction_id: 0,
          sort_order: 3,
          timing_name: "Weekday base"
        },
        [
          {"CMP1_S5", 0, 0, 1},
          {"CMP1_S6", 180, 180, 0},
          {"CMP1_S7", 360, 360, 0},
          {"CMP1_S8", 540, 540, 0},
          {"CMP1_S1", 720, 720, 0},
          {"CMP1_S2", 900, 900, 0},
          {"CMP1_S3", 1080, 1080, 0},
          {"CMP1_S4", 1260, 1260, 1}
        ]
      )

    _moved_b =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "MOVED_B",
          name: "Moved B",
          direction_id: 0,
          sort_order: 4,
          timing_name: "Weekday base"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 180, 180, 0},
          {"CMP1_S3", 360, 360, 0},
          {"CMP1_S4", 540, 540, 0},
          {"CMP1_S5", 720, 720, 0},
          {"CMP1_S6", 900, 900, 0},
          {"CMP1_S7", 1080, 1080, 0},
          {"CMP1_S8", 1260, 1260, 1}
        ]
      )

    schedule_pattern(
      organization,
      version,
      route,
      %{
        id: "BOARD_A",
        name: "Board A",
        direction_id: 1,
        sort_order: 1,
        timing_name: "Weekday base"
      },
      [
        {"CMP1_S1", 0, 0, 1},
        {"CMP1_S2", 120, 120, 1},
        {"CMP1_S3", 240, 240, 1}
      ]
    )

    board_b =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "BOARD_B",
          name: "Board B",
          direction_id: 1,
          sort_order: 2,
          timing_name: "Weekday base"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 1},
          {"CMP1_S3", 240, 240, 1}
        ]
      )

    Repo.update!(Ecto.Changeset.change(Enum.at(board_b.rows, 1), drop_off_type: 1))

    _nudge =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "NUDGE",
          name: "Nudge",
          direction_id: 1,
          sort_order: 0,
          timing_name: "Weekday base"
        },
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 210, 210, 0},
          {"CMP1_S3", 540, 540, 0},
          {"CMP1_S4", 990, 990, 0},
          {"CMP1_S5", 1200, 1200, 1}
        ]
      )

    Enum.each(["06:00:00", "07:00:00"], fn start_time ->
      schedule_trip_fixture(organization.id, version.id, route.route_id, full, %{
        service_id: "WEEKDAY",
        start_time: start_time
      })
    end)

    Enum.each(["08:00:00", "09:00:00", "10:00:00"], fn start_time ->
      schedule_trip_fixture(organization.id, version.id, route.route_id, dev, %{
        service_id: "WEEKDAY",
        start_time: start_time
      })
    end)

    schedule_trip_fixture(organization.id, version.id, route.route_id, short, %{
      service_id: "WEEKDAY",
      start_time: "11:00:00"
    })

    %{route: route, full: full, dev: dev, short: short, moved_a: moved_a}
  end

  defp compare_path(version, route, params) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp count_matches(html, regex), do: length(Regex.scan(regex, html))

  describe "difference list and metric strip" do
    setup :editor_scope

    test "the replacement names both anchors, the added and skipped stops and the stretch time",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "DEV"}))

      assert has_element?(
               view,
               "#summary-diff-1",
               "Between CMP1 Stop 2 and CMP1 Stop 4, B serves CMP1 Stop 3A and CMP1 Stop 3B instead of CMP1 Stop 3."
             )

      assert has_element?(
               view,
               "#summary-diff-1",
               "That stretch takes B 12 min longer (25:30 against 13:30)."
             )

      assert has_element?(view, "#summary-counts", "4 in common · 1 only in A · 2 only in B")
      refute has_element?(view, "#summary-diff-2")

      assert has_element?(view, "#summary-diff-1[data-diff-index='0']")
      assert has_element?(view, "#summary-diff-1[aria-pressed='false']")
    end

    test "the short turn renders B ends at … and A continues",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      assert has_element?(
               view,
               "#summary-diff-1",
               "B ends at CMP1 Stop 2. A continues 3 more stops to CMP1 Stop 5."
             )

      refute has_element?(view, "#summary-diff-2")
    end

    test "four moved pairs collapse into one item", %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "MOVED_A", "b" => "MOVED_B"}))

      assert has_element?(
               view,
               "#summary-diff-1",
               "4 stops are served in a different order, such as"
             )

      refute has_element?(view, "#summary-diff-2")
    end

    test "boarding differences name both sides' labels",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "BOARD_A", "b" => "BOARD_B"}))

      assert has_element?(
               view,
               "#summary-diff-1",
               "At CMP1 Stop 2, B only picks riders up; A picks up and lets off."
             )

      refute has_element?(view, "#summary-diff-2")
    end

    test "the smaller-timing note counts the unlisted differences",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "NUDGE"}))

      assert has_element?(
               view,
               "#summary-smaller-timing",
               ~r/2 smaller timing differences\s+are in the stop list\./
             )

      assert has_element?(view, "#compare-summary", "No differences in stops or running times.")
      refute has_element?(view, "#summary-diff-1")
    end

    test "the strip shows end to end, trips and 20 hour bars per side",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "DEV"}))

      assert has_element?(view, "#summary-end-a", "20:00")
      assert has_element?(view, "#summary-end-b", "32:00")
      assert has_element?(view, "#summary-end-change", "+12:00 (+60%)")
      assert has_element?(view, "#compare-summary", "Trips on Weekday")
      assert has_element?(view, "#summary-trips-a", "2")
      assert has_element?(view, "#summary-trips-b", "3")

      html = render(view)
      assert count_matches(html, ~r/data-hour-bar="a-\d+"/) == 20
      assert count_matches(html, ~r/data-hour-bar="b-\d+"/) == 20

      assert view |> element("[data-hour-bar='a-6']") |> render() =~
               ~s(title="06:00–07:00: 1 trip")

      assert view |> element("[data-hour-bar='b-10']") |> render() =~
               ~s(title="10:00–11:00: 1 trip")
    end

    test "B absent renders up to three suggestions and patches b",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"a" => "FULL"}))

      assert has_element?(view, "#summary-suggestions", "Suggested comparisons")

      assert has_element?(
               view,
               "#summary-suggestions",
               ~r/as\s+A\s*,\s*most used on Weekday\s+first\./
             )

      assert has_element?(view, "#summary-suggestion-DEV", "Deviation")
      assert has_element?(view, "#summary-suggestion-SHORT", "Short turn")
      assert has_element?(view, "#summary-suggestion-MOVED_A", "Moved A")

      assert count_matches(render(view), ~r/id="summary-suggestion-/) == 3

      view |> element("#summary-suggestion-DEV") |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "DEV", "service" => "WEEKDAY"})
      )
    end
  end
end
