defmodule GtfsPlanner.Gtfs.PatternComparison.DefaultsOverviewTest do
  @moduledoc """
  Merge evidence (EV-8) for CL-15 and CL-21: `defaults/3` resolves R8's entry
  pair for the Patterns-tab link, and `overview/4` lays one direction's patterns
  out against the busiest one, keeping repeated visits as their own rows.
  Establishes INV-1 for both reads and preserves INV-2 (nothing is written) and
  INV-3 (`Alignment` stays pure).

  Every expected id, count and row is hand-derived from the fixtures below: the
  busiest calendar is known from the trip counts, and the overview's row order
  follows R1/R2 (one row per visit; A's own rows come first in a stretch) and
  the first/last served row rule for spans. The focused gate command is
  deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner/gtfs/pattern_comparison/defaults_overview_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.PatternComparison
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    Enum.each(~w(s1 s2 s3 s4 s5 s6), fn stop_id ->
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: String.upcase(stop_id),
        stop_lat: Decimal.new("44.0"),
        stop_lon: Decimal.new("-124.0")
      })
    end)

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})
    calendar_fixture(organization.id, version.id, %{service_id: "SATURDAY"})

    # Direction 0: Full (6 stops), Short turn (4) and Loop, which visits s2
    # twice. Direction 1: Reverse (7 stops, including the direction-only x1).
    full =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "full",
          name: "Full",
          direction_id: 0,
          sort_order: 0,
          typicality: 1,
          description: "All day, every day"
        },
        [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 0},
          {"s4", 180, 180, 1},
          {"s5", 240, 240, 1},
          {"s6", 300, 300, 1}
        ]
      )

    short =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "short",
          name: "Short turn",
          direction_id: 0,
          sort_order: 1,
          typicality: 2,
          description: "Weekday evenings"
        },
        [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 0},
          {"s4", 180, 180, 1}
        ]
      )

    loop =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "loop", name: "Loop", direction_id: 0, sort_order: 2, typicality: 3},
        [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 0},
          {"s4", 180, 180, 1},
          {"s2", 240, 240, 1}
        ]
      )

    back =
      schedule_pattern(
        organization,
        version,
        route,
        %{
          id: "back",
          name: "Reverse",
          direction_id: 1,
          sort_order: 0,
          typicality: 1,
          description: "Every day"
        },
        [
          {"x1", 0, 0, 1},
          {"s6", 60, 60, 1},
          {"s5", 120, 120, 1},
          {"s4", 180, 180, 1},
          {"s3", 240, 240, 1},
          {"s2", 300, 300, 1},
          {"s1", 360, 360, 1}
        ]
      )

    # WEEKDAY: full 5, short 3, loop 1, back 4 (route total 13).
    # SATURDAY: full 0, short 2, loop 1 (route total 3).
    # WEEKDAY is therefore the route's busiest calendar, and back (direction 1,
    # no sibling) is not the entry B even though it outranks short there.
    linked_trips(
      organization,
      version,
      route,
      full,
      "WEEKDAY",
      ~w(06:00:00 07:00:00 08:00:00 09:00:00 10:00:00)
    )

    linked_trips(organization, version, route, short, "WEEKDAY", ~w(11:00:00 12:00:00 13:00:00))
    linked_trips(organization, version, route, loop, "WEEKDAY", ~w(14:00:00))

    linked_trips(
      organization,
      version,
      route,
      back,
      "WEEKDAY",
      ~w(15:00:00 16:00:00 17:00:00 18:00:00)
    )

    linked_trips(organization, version, route, short, "SATURDAY", ~w(09:00:00 10:00:00))
    linked_trips(organization, version, route, loop, "SATURDAY", ~w(11:00:00))

    %{
      scope: %{organization_id: organization.id, gtfs_version_id: version.id},
      organization: organization,
      version: version,
      route: route
    }
  end

  test "opens the route's busiest pattern and the next by trips in its direction", context do
    # On the busiest calendar (WEEKDAY) full has 5 trips and short 3, the next
    # direction-0 pattern; back has more than short but is direction 1.
    assert PatternComparison.defaults(context.scope, context.route.route_id, []) ==
             {:ok, %{a: "full", b: "short"}}
  end

  test "counts on the requested calendar and falls back for an unknown one", context do
    # On SATURDAY the counts reverse: short 2, loop 1.
    assert PatternComparison.defaults(context.scope, context.route.route_id, service: "SATURDAY") ==
             {:ok, %{a: "short", b: "loop"}}

    assert PatternComparison.defaults(context.scope, context.route.route_id, service: "SUNDAY") ==
             {:ok, %{a: "full", b: "short"}}
  end

  test "returns b: nil for a single-pattern route and a: nil for a route without patterns",
       context do
    single_route = route_fixture(context.organization.id, context.version.id)

    only =
      schedule_pattern(
        context.organization,
        context.version,
        single_route,
        %{id: "only", name: "Only", direction_id: 0, sort_order: 0, typicality: 1},
        [{"s1", 0, 0, 1}]
      )

    linked_trips(
      context.organization,
      context.version,
      single_route,
      only,
      "WEEKDAY",
      ~w(06:00:00 07:00:00)
    )

    assert PatternComparison.defaults(context.scope, single_route.route_id, []) ==
             {:ok, %{a: "only", b: nil}}

    empty_route = route_fixture(context.organization.id, context.version.id)

    assert PatternComparison.defaults(context.scope, empty_route.route_id, []) ==
             {:ok, %{a: nil, b: nil}}
  end

  test "lays direction 0 out busiest first with counts, typicality and aligned rows", context do
    assert {:ok, overview} =
             PatternComparison.overview(context.scope, context.route.route_id, 0, "WEEKDAY")

    assert overview.route.route_id == context.route.route_id
    assert overview.service_id == "WEEKDAY"

    assert overview.calendars == [
             %{
               service_id: "SATURDAY",
               name: "SATURDAY",
               trips: %{"full" => 0, "short" => 2, "loop" => 1}
             },
             %{
               service_id: "WEEKDAY",
               name: "WEEKDAY",
               trips: %{"full" => 5, "short" => 3, "loop" => 1}
             }
           ]

    assert overview.patterns == [
             %{
               route_pattern_id: "full",
               name: "Full",
               typicality: "Typical",
               service_description: "All day, every day",
               stop_count: 6,
               trips: 5
             },
             %{
               route_pattern_id: "short",
               name: "Short turn",
               typicality: "Deviation",
               service_description: "Weekday evenings",
               stop_count: 4,
               trips: 3
             },
             %{
               route_pattern_id: "loop",
               name: "Loop",
               typicality: "Atypical",
               service_description: nil,
               stop_count: 5,
               trips: 1
             }
           ]

    # Loop's second s2 visit gets its own row after A's remaining rows; every
    # visit of every pattern is served exactly once, in order.
    assert Enum.map(overview.rows, & &1.stop_id) == ~w(s1 s2 s3 s4 s5 s6 s2)

    assert Enum.map(overview.rows, & &1.served) == [
             %{"full" => 1, "loop" => 1, "short" => 1},
             %{"full" => 2, "loop" => 2, "short" => 2},
             %{"full" => 3, "loop" => 3, "short" => 3},
             %{"full" => 4, "loop" => 4, "short" => 4},
             %{"full" => 5},
             %{"full" => 6},
             %{"loop" => 5}
           ]

    assert overview.spans == %{"full" => {0, 5}, "loop" => {0, 6}, "short" => {0, 3}}

    # Direction 1's pattern (and its only stop) stays out of this direction.
    assert Map.keys(overview.stops_by_id) |> Enum.sort() == ~w(s1 s2 s3 s4 s5 s6)
    refute Map.has_key?(overview.stops_by_id, "x1")
    refute Map.has_key?(overview.spans, "back")

    assert overview.stops_by_id["s1"].stop_name == "S1"
    assert %{timepoint?: false} = overview.stops_by_id["s3"]
    assert %{timepoint?: true} = overview.stops_by_id["s5"]

    assert {:ok, direction_one} =
             PatternComparison.overview(context.scope, context.route.route_id, 1, "WEEKDAY")

    assert Enum.map(direction_one.patterns, & &1.route_pattern_id) == ["back"]
    assert Enum.map(direction_one.rows, & &1.stop_id) == ~w(x1 s6 s5 s4 s3 s2 s1)
  end

  test "returns not found for a missing route and reads only the scoped version", context do
    assert PatternComparison.defaults(context.scope, "route_missing", []) == {:error, :not_found}

    assert PatternComparison.overview(context.scope, "route_missing", 0, nil) ==
             {:error, :not_found}

    # The same natural route_id in another organization and in another version
    # of this organization carries a busier pattern; neither may be read.
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    foreign_route =
      route_fixture(foreign_organization.id, foreign_version.id, %{
        route_id: context.route.route_id
      })

    foreign =
      schedule_pattern(
        foreign_organization,
        foreign_version,
        foreign_route,
        %{id: "foreign", name: "Foreign", direction_id: 0, sort_order: 0, typicality: 1},
        [{"s1", 0, 0, 1}]
      )

    linked_trips(
      foreign_organization,
      foreign_version,
      foreign_route,
      foreign,
      "WEEKDAY",
      ~w(00:01:00 00:02:00 00:03:00 00:04:00 00:05:00 00:06:00 00:07:00 00:08:00 00:09:00)
    )

    other_version = gtfs_version_fixture(context.organization.id)

    other_version_route =
      route_fixture(context.organization.id, other_version.id, %{
        route_id: context.route.route_id
      })

    other_version_pattern =
      schedule_pattern(
        context.organization,
        other_version,
        other_version_route,
        %{
          id: "other_version",
          name: "Other version",
          direction_id: 0,
          sort_order: 0,
          typicality: 1
        },
        [{"s1", 0, 0, 1}]
      )

    linked_trips(
      context.organization,
      other_version,
      other_version_route,
      other_version_pattern,
      "WEEKDAY",
      ~w(01:00:00 02:00:00 03:00:00 04:00:00 05:00:00 06:00:00 07:00:00 08:00:00 09:00:00)
    )

    assert PatternComparison.defaults(context.scope, context.route.route_id, []) ==
             {:ok, %{a: "full", b: "short"}}

    assert {:ok, overview} =
             PatternComparison.overview(context.scope, context.route.route_id, 0, "WEEKDAY")

    assert Enum.map(overview.patterns, & &1.route_pattern_id) == ["full", "short", "loop"]

    # A route on an unpublished version is out of scope for both reads.
    {:ok, staging} =
      Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

    staging_route =
      route_fixture(context.organization.id, staging.id, %{route_id: "staging_route"})

    staging_scope = %{organization_id: context.organization.id, gtfs_version_id: staging.id}

    assert PatternComparison.defaults(staging_scope, staging_route.route_id, []) ==
             {:error, :not_found}

    assert PatternComparison.overview(staging_scope, staging_route.route_id, 0, nil) ==
             {:error, :not_found}
  end

  # One named pattern with its own timing; `pattern` carries `:id`, `:name`,
  # `:direction_id`, `:sort_order`, `:typicality` and an optional
  # `:description` (the pattern's service description).
  defp schedule_pattern(organization, version, route, pattern, stops) do
    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: pattern.id,
        route_pattern_name: pattern.name,
        direction_id: pattern.direction_id,
        route_pattern_sort_order: pattern.sort_order,
        route_pattern_typicality: pattern.typicality,
        timing_name: "#{pattern.name} timing",
        stops: stops
      })

    Repo.update!(
      Ecto.Changeset.change(bundle.pattern, route_pattern_time_desc: pattern[:description])
    )

    bundle
  end

  defp linked_trips(organization, version, route, bundle, service_id, departures) do
    Enum.each(departures, fn departure ->
      trip =
        trip_fixture(organization.id, version.id, route.route_id, %{
          trip_id: "trip_#{service_id}_#{System.unique_integer([:positive])}",
          service_id: service_id
        })

      trip =
        trip_pattern_metadata_fixture(trip, %{
          route_pattern_id: bundle.pattern.route_pattern_id,
          timed_pattern_id: bundle.timing.id,
          pattern_derivation_state: "linked"
        })

      stop_time_fixture(organization.id, version.id, trip.trip_id, "s1", %{
        arrival_time: departure,
        departure_time: departure,
        stop_sequence: 1
      })
    end)
  end
end
