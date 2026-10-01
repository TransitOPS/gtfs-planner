defmodule GtfsPlanner.Gtfs.RoutePatterns.DerivationTest do
  @moduledoc """
  Route-local derivation: supplied-identity preservation, bounded grouping and
  reason codes, signature reuse, manual build auditing and route-atomic retry.

  Expected values come from the pinned supplied-ID fixture and hand-authored
  trip/stop-time fixtures; no production function computes an expected value.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @fixture_dir Path.expand("../../../fixtures/gtfs/route_patterns", __DIR__)

  setup do
    organization =
      organization_fixture(%{
        alias: "route-pattern-derivation-#{System.system_time(:nanosecond)}"
      })

    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  test "supplied ids are preserved while wrong-route, dangling and mismatching references stay custom",
       context do
    _red = route_fixture(context.organization.id, context.version.id, %{route_id: "Red"})
    _blue = route_fixture(context.organization.id, context.version.id, %{route_id: "Blue"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}, {"C", "Cedar"}])
    [a, b, c] = [stops["A"], stops["B"], stops["C"]]
    blue_stops = stops_fixture(context, [{"X", "Xavier"}, {"Y", "Yarrow"}])
    [x, y] = [blue_stops["X"], blue_stops["Y"]]

    insert_pinned_patterns(context)

    representative =
      imported_trip(context, "Red", "Red-1-0-t1", %{
        direction_id: 0,
        route_pattern_id: "Red-1-0",
        rows: [
          time_row(a, "08:00:00"),
          time_row(b, "08:05:00"),
          time_row(c, "08:10:00")
        ]
      })

    ok_trip =
      imported_trip(context, "Red", "T-red-ok", %{
        direction_id: 0,
        route_pattern_id: "Red-1-0",
        rows: [
          time_row(a, "08:00:00"),
          time_row(b, "08:05:00"),
          time_row(c, "08:10:00")
        ]
      })

    diff_trip =
      imported_trip(context, "Red", "T-red-diff", %{
        direction_id: 0,
        route_pattern_id: "Red-1-0",
        rows: [time_row(a, "08:00:00"), time_row(c, "08:10:00")]
      })

    dangling_trip =
      imported_trip(context, "Red", "T-red-dangling", %{
        direction_id: 0,
        route_pattern_id: "Ghost-9-0",
        rows: [time_row(a, "08:00:00"), time_row(b, "08:05:00")]
      })

    wrong_route_trip =
      imported_trip(context, "Red", "T-red-wrongroute", %{
        direction_id: 0,
        route_pattern_id: "Blue-2-0",
        rows: [time_row(a, "08:00:00"), time_row(b, "08:05:00")]
      })

    wrong_direction_trip =
      imported_trip(context, "Red", "T-red-wrongdir", %{
        direction_id: 1,
        route_pattern_id: "Red-1-0",
        rows: [time_row(a, "08:00:00"), time_row(b, "08:05:00")]
      })

    imported_trip(context, "Blue", "Blue-2-0-t1", %{
      direction_id: 0,
      route_pattern_id: "Blue-2-0",
      rows: [time_row(x, "07:00:00", "07:00:00", 1), time_row(y, "07:10:00", "07:10:00", 2)]
    })

    blue_ok =
      imported_trip(context, "Blue", "T-blue-ok", %{
        direction_id: 0,
        route_pattern_id: "Blue-2-0",
        rows: [
          time_row(x, "07:00:00", "07:00:00", 1),
          time_row(y, "07:10:00", "07:10:00", 2)
        ]
      })

    unchanged_before = stop_time_snapshot(context)

    assert {:ok, summary} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:import, nil}
             )

    assert summary.patterns_created == 1
    assert summary.timings_created == 3
    assert summary.trips_linked == 5
    assert summary.trips_custom == 3
    assert summary.routes_failed == 0

    pattern = red_pattern(context, "Red-1-0")

    assert Enum.map(occurrences(pattern.id), &{&1.position, &1.stop_id}) == [
             {1, "A"},
             {2, "B"},
             {3, "C"}
           ]

    assert linked(representative).route_pattern_id == "Red-1-0"
    assert linked(ok_trip).route_pattern_id == "Red-1-0"
    assert linked(blue_ok).route_pattern_id == "Blue-2-0"
    assert linked(ok_trip).pattern_derivation_state == "linked"
    assert linked(ok_trip).timed_pattern_id == linked(representative).timed_pattern_id
    refute is_nil(linked(ok_trip).timed_pattern_id)

    # The differing trip's stop order becomes a child pattern labelled by the
    # supplied owner, so it links instead of staying custom `different_stops`.
    child = child_of(context, pattern)
    assert Enum.map(occurrences(child.id), &{&1.position, &1.stop_id}) == [{1, "A"}, {2, "C"}]
    assert linked(diff_trip).route_pattern_id == child.route_pattern_id

    assert custom(dangling_trip).pattern_derivation_reason == "missing_pattern"
    assert custom(wrong_route_trip).pattern_derivation_reason == "scope_mismatch"
    assert custom(wrong_direction_trip).pattern_derivation_reason == "scope_mismatch"

    assert Enum.all?(
             [dangling_trip, wrong_route_trip, wrong_direction_trip],
             &is_nil(custom(&1).timed_pattern_id)
           )

    [timing] = timings(pattern.id)

    assert Enum.map(timing_rows(timing.id), &{&1.arrival_offset, &1.departure_offset}) == [
             {0, 0},
             {300, 300},
             {600, 600}
           ]

    # The referenced pattern rows stay untouched where nothing referenced them.
    assert red_pattern(context, "Red-1-1").route_id == "Red"
    assert occurrences(red_pattern(context, "Red-1-1").id) == []

    assert stop_time_snapshot(context) == unchanged_before
  end

  test "trips group by route, direction and ordered stop ids with loops, sparse labels and timing reuse",
       context do
    route = route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}, {"C", "Cedar"}])
    [a, b, c] = [stops["A"], stops["B"], stops["C"]]

    loop_rows = fn
      first_arrival ->
        [
          time_row(a, first_arrival, "08:00:00", 10),
          time_row(b, "08:05:00", "08:05:00", 20),
          time_row(a, "08:10:00", "08:10:00", 30)
        ]
    end

    # Identical vector twice -> one reusable timing; the first stop keeps a
    # signed dwell through its first departure.
    imported_trip(context, "R1", "t-d0-1", %{
      direction_id: 0,
      trip_headsign: "Ashmont",
      rows: loop_rows.("07:59:30")
    })

    imported_trip(context, "R1", "t-d0-2", %{
      direction_id: 0,
      trip_headsign: "Ashmont",
      rows: loop_rows.("07:59:30")
    })

    # Same stops, one different stop-time attribute -> a second timing.
    third = [
      time_row(a, "07:59:30", "08:00:00", 10),
      time_row(b, "08:05:00", "08:05:00", 20, %{pickup_type: 2}),
      time_row(a, "08:10:00", "08:10:00", 30)
    ]

    imported_trip(context, "R1", "t-d0-3", %{
      direction_id: 0,
      trip_headsign: "Braintree",
      rows: third
    })

    imported_trip(context, "R1", "t-d0-short", %{
      direction_id: 0,
      rows: [
        time_row(a, "09:00:00", "09:00:00", 5),
        time_row(b, "09:05:00", "09:05:00", 6),
        time_row(c, "09:10:00", "09:10:00", 7)
      ]
    })

    imported_trip(context, "R1", "t-d1-1", %{
      direction_id: 1,
      rows: [
        time_row(a, "10:00:00", "10:00:00", 1),
        time_row(b, "10:05:00", "10:05:00", 2),
        time_row(a, "10:10:00", "10:10:00", 3)
      ]
    })

    imported_trip(context, "R1", "t-d1-2", %{
      direction_id: 1,
      rows: [
        time_row(a, "11:00:00", "11:00:00", 1),
        time_row(b, "11:05:00", "11:05:00", 2),
        time_row(a, "11:10:00", "11:10:00", 3)
      ]
    })

    unchanged_before = stop_time_snapshot(context)

    assert {:ok, summary} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:import, nil}
             )

    assert summary.patterns_created == 3
    assert summary.timings_created == 4
    assert summary.trips_linked == 6
    assert summary.trips_custom == 0

    patterns = patterns_for(context, route.route_id)
    assert length(patterns) == 3
    assert Enum.all?(patterns, &String.starts_with?(&1.route_pattern_id, "app-"))

    loop_d0 = Enum.find(patterns, &(&1.direction_id == 0 and &1.route_pattern_typicality == 1))
    assert loop_d0.route_pattern_name == "Alpine – Alpine"
    assert loop_d0.representative_trip_id == "t-d0-1"
    assert not is_nil(loop_d0.derivation_key)

    loop_d0_occurrences = occurrences(loop_d0.id)

    assert Enum.map(loop_d0_occurrences, &{&1.position, &1.stop_id}) == [
             {1, "A"},
             {2, "B"},
             {3, "A"}
           ]

    assert length(Enum.uniq(Enum.map(loop_d0_occurrences, & &1.id))) == 3

    short_d0 = Enum.find(patterns, &(&1.direction_id == 0 and &1.route_pattern_typicality == 0))
    assert short_d0.route_pattern_name == "Alpine – Cedar"

    loop_d1 = Enum.find(patterns, &(&1.direction_id == 1))
    assert loop_d1.route_pattern_typicality == 1
    assert String.starts_with?(loop_d1.route_pattern_name, "Alpine – Alpine (")
    assert loop_d1.route_pattern_name != loop_d0.route_pattern_name

    loop_timings = timings(loop_d0.id)
    assert Enum.map(loop_timings, & &1.name) == ["Timing A", "Timing B"]
    assert Enum.all?(loop_timings, &(not is_nil(&1.derivation_key)))

    [timing_a, timing_b] = loop_timings

    assert Enum.map(timing_rows(timing_a.id), &{&1.arrival_offset, &1.departure_offset}) == [
             {-30, 0},
             {300, 300},
             {600, 600}
           ]

    assert timing_a.headsign == "Ashmont"
    assert timing_b.headsign == "Braintree"

    assert Enum.map(timing_rows(timing_b.id), &{&1.arrival_offset, &1.departure_offset}) == [
             {-30, 0},
             {300, 300},
             {600, 600}
           ]

    assert Enum.at(timing_rows(timing_b.id), 1).pickup_type == 2
    assert Enum.at(timing_rows(timing_a.id), 1).pickup_type == nil

    linked_trips =
      Repo.all(
        from(t in Trip,
          where:
            t.organization_id == ^context.organization.id and
              t.gtfs_version_id == ^context.version.id and t.route_id == ^"R1"
        )
      )

    assert Enum.all?(linked_trips, &(&1.pattern_derivation_state == "linked"))
    assert Enum.all?(linked_trips, &String.starts_with?(&1.route_pattern_id, "app-"))
    assert Enum.all?(linked_trips, &(not is_nil(&1.timed_pattern_id)))

    assert length(Enum.uniq(Enum.map(linked_trips, & &1.route_pattern_id))) == 3

    assert stop_time_snapshot(context) == unchanged_before
  end

  test "every unrepresentable trip gets its exact bounded reason with unchanged stop times",
       context do
    _route = route_fixture(context.organization.id, context.version.id, %{route_id: "R2"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}])
    [a, b] = [stops["A"], stops["B"]]

    canonical = [
      time_row(a, "08:00:00", "08:00:00", 1),
      time_row(b, "08:05:00", "08:05:00", 2)
    ]

    imported_trip(context, "R2", "can-1", %{direction_id: 0, rows: canonical})
    imported_trip(context, "R2", "can-2", %{direction_id: 0, rows: canonical})

    cases = %{
      "t-missing" =>
        {0, [time_row(a, "08:00:00", "08:00:00", 1), time_row(b, nil, nil, 2)], "missing_times"},
      "t-invalid" =>
        {0, [time_row(a, "08:00:00", "08:00:00", 1), time_row(b, "08:99:00", "08:99:00", 2)],
         "invalid_time"},
      "t-chrono" =>
        {0,
         [
           time_row(a, "08:00:00", "08:10:00", 1),
           time_row(b, "08:05:00", "08:05:00", 2)
         ], "invalid_chronology"},
      "t-attr" =>
        {0,
         [
           time_row(a, "08:00:00", "08:00:00", 1),
           time_row(b, "08:05:00", "08:05:00", 2, %{pickup_type: 9})
         ], "invalid_attribute"},
      "t-nodir" => {nil, canonical, "missing_direction"},
      "t-one" => {0, [time_row(a, "08:00:00", "08:00:00", 1)], "unusable_stops"},
      "t-adjacent" =>
        {0, [time_row(a, "08:00:00", "08:00:00", 1), time_row(a, "08:05:00", "08:05:00", 2)],
         "unusable_stops"}
    }

    Enum.each(cases, fn {trip_id, {direction, rows, _reason}} ->
      imported_trip(context, "R2", trip_id, %{direction_id: direction, rows: rows})
    end)

    unchanged_before = stop_time_snapshot(context)

    assert {:ok, summary} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:import, nil}
             )

    assert summary.trips_linked == 2
    assert summary.trips_custom == 7

    Enum.each(cases, fn {trip_id, {_direction, _rows, reason}} ->
      assert custom(trip_id).pattern_derivation_reason == reason,
             "expected #{trip_id} to be custom with #{reason}"
    end)

    assert stop_time_snapshot(context) == unchanged_before
  end

  test "retry reuses stored timings and staff edits clear the derived signatures", context do
    route = route_fixture(context.organization.id, context.version.id, %{route_id: "R3"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}, {"C", "Cedar"}])
    [a, b, c] = [stops["A"], stops["B"], stops["C"]]

    original = [
      time_row(a, "08:00:00", "08:00:00", 1),
      time_row(b, "08:05:00", "08:05:00", 2)
    ]

    imported_trip(context, "R3", "base-1", %{direction_id: 0, rows: original})
    imported_trip(context, "R3", "base-2", %{direction_id: 0, rows: original})

    assert {:ok, %{timings_created: 1, trips_linked: 2}} = derive_route(context, route.route_id)

    [pattern] = patterns_for(context, route.route_id)
    [timing] = timings(pattern.id)
    signature = timing.derivation_key
    occurrence_ids = Enum.map(occurrences(pattern.id), & &1.id)
    assert length(occurrence_ids) == 2

    imported_trip(context, "R3", "reuse-same", %{direction_id: 0, rows: original})

    assert {:ok, %{timings_created: 0, trips_linked: 1}} = derive_route(context, route.route_id)
    assert linked("reuse-same").timed_pattern_id == timing.id

    imported_trip(context, "R3", "reuse-diff", %{
      direction_id: 0,
      rows: [
        time_row(a, "09:00:00", "09:00:00", 1),
        time_row(b, "09:15:00", "09:15:00", 2)
      ]
    })

    assert {:ok, %{timings_created: 1, trips_linked: 1}} = derive_route(context, route.route_id)
    names = pattern.id |> timings() |> Enum.map(& &1.name)
    assert names == ["Timing A", "Timing B"]

    # Existing initialized pattern stops are never rebuilt by retry.
    assert Enum.map(occurrences(pattern.id), & &1.id) == occurrence_ids

    # A staff timing edit clears the derived signature and rewrites only its rows.
    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(context.organization.id, context.version.id, route.route_id, pattern.id)

    timing_operation =
      {:timing, timing.id,
       %{
         rows: [
           %{
             route_pattern_stop_id: Enum.at(occurrence_ids, 0),
             arrival_offset: 0,
             departure_offset: 0
           },
           %{
             route_pattern_stop_id: Enum.at(occurrence_ids, 1),
             arrival_offset: 420,
             departure_offset: 420
           }
         ]
       }}

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, timing_operation, source, context.audit)

    assert {:ok, %{trips_updated: 3}} =
             Gtfs.apply_review(pattern.id, timing_operation, fingerprint, context.audit)

    assert is_nil(Repo.get!(TimedPattern, timing.id).derivation_key)

    # The staff-edited timing can no longer be matched, so the original vector
    # builds a fresh timing instead of silently reusing obsolete content.
    imported_trip(context, "R3", "reuse-after-edit", %{direction_id: 0, rows: original})

    assert {:ok, %{timings_created: 1, trips_linked: 1}} = derive_route(context, route.route_id)
    rebound = linked("reuse-after-edit").timed_pattern_id
    assert rebound != timing.id
    assert Repo.get!(TimedPattern, rebound).derivation_key == signature

    # A structural edit clears the pattern key and every timing key.
    route2 = route_fixture(context.organization.id, context.version.id, %{route_id: "R4"})

    imported_trip(context, "R4", "struct-1", %{direction_id: 0, rows: original})

    assert {:ok, %{timings_created: 1}} = derive_route(context, route2.route_id)

    [struct_pattern] = patterns_for(context, route2.route_id)
    [struct_timing] = timings(struct_pattern.id)
    struct_occurrences = occurrences(struct_pattern.id)

    {:ok, %{source_fingerprint: struct_source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        route2.route_id,
        struct_pattern.id
      )

    stop_operation =
      {:stops,
       Enum.map(struct_occurrences, &%{id: &1.id, stop_id: &1.stop_id}) ++
         [%{key: "new-stop", stop_id: c.stop_id}],
       %{
         struct_timing.id => %{
           rows: [%{stop_id: c.stop_id, arrival_offset: 900, departure_offset: 900}],
           acknowledged: true
         }
       }}

    assert {:ok, %{fingerprint: struct_fingerprint}} =
             Gtfs.review(struct_pattern.id, stop_operation, struct_source, context.audit)

    assert {:ok, %{trips_updated: 1}} =
             Gtfs.apply_review(
               struct_pattern.id,
               stop_operation,
               struct_fingerprint,
               context.audit
             )

    assert is_nil(Repo.get!(RoutePattern, struct_pattern.id).derivation_key)

    assert Enum.all?(
             timings(struct_pattern.id),
             &is_nil(Repo.get!(TimedPattern, &1.id).derivation_key)
           )
  end

  test "the manual build records one route_pattern_build summary and refuses a custom-only retry",
       context do
    route = route_fixture(context.organization.id, context.version.id, %{route_id: "R5"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}])
    [a, b] = [stops["A"], stops["B"]]

    imported_trip(context, "R5", "build-1", %{
      direction_id: 0,
      rows: [time_row(a, "08:00:00", "08:00:00", 1), time_row(b, "08:05:00", "08:05:00", 2)]
    })

    imported_trip(context, "R5", "build-2", %{
      direction_id: 0,
      rows: [
        time_row(a, "09:00:00", "09:00:00", 1),
        time_row(b, "09:20:00", "09:20:00", 2)
      ]
    })

    assert {:ok, summary} = Gtfs.build_route_patterns("R5", context.audit)
    assert summary == %{patterns_created: 1, timings_created: 2, trips_linked: 2, trips_custom: 0}

    [log] =
      Repo.all(
        from(log in ChangeLog,
          where: log.entity_type == "route_pattern_build" and log.entity_id == ^route.id
        )
      )

    assert log.entity_external_id == "R5"
    assert log.action == "updated"
    assert is_nil(log.station_stop_id)
    assert log.actor_id == context.audit.actor_id
    assert log.changed_fields["before"] == %{"pending" => 2, "custom" => 0, "linked" => 0}
    assert log.changed_fields["after"] == %{"pending" => 0, "custom" => 0, "linked" => 2}
    assert log.changed_fields["patterns_created"] == 1
    assert log.changed_fields["timings_created"] == 2

    assert {:error, :audit_only_entity} = GtfsPlanner.Gtfs.Stations.rollback_target_snapshot(log)
    assert Gtfs.reversible_fields_for("route_pattern_build") == []

    # Custom classification alone is not retryable and creates no second summary.
    assert {:error, :nothing_pending} = Gtfs.build_route_patterns("R5", context.audit)

    assert Repo.aggregate(
             from(log in ChangeLog,
               where:
                 log.organization_id == ^context.organization.id and
                   log.gtfs_version_id == ^context.version.id and
                   log.entity_type == "route_pattern_build"
             ),
             :count
           ) == 1

    # A route with nothing pending is a derivation no-op: no audit row.
    noop_route = route_fixture(context.organization.id, context.version.id, %{route_id: "R6"})

    assert {:ok, %{patterns_created: 0, timings_created: 0, trips_linked: 0, trips_custom: 0}} =
             Derivation.derive_route(
               context.organization.id,
               context.version.id,
               noop_route.route_id,
               {:editor, context.audit}
             )

    assert Repo.aggregate(
             from(log in ChangeLog,
               where: log.entity_type == "route_pattern_build" and log.entity_id == ^noop_route.id
             ),
             :count
           ) == 0
  end

  test "interrupted derivation keeps earlier routes and retry finishes pending routes without duplicates",
       context do
    r1 = route_fixture(context.organization.id, context.version.id, %{route_id: "R7"})
    r2 = route_fixture(context.organization.id, context.version.id, %{route_id: "R8"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}])
    [a, b] = [stops["A"], stops["B"]]

    rows = [time_row(a, "08:00:00", "08:00:00", 1), time_row(b, "08:05:00", "08:05:00", 2)]

    imported_trip(context, "R7", "r7-1", %{direction_id: 0, rows: rows})
    imported_trip(context, "R8", "r8-1", %{direction_id: 0, rows: rows})
    imported_trip(context, "Ghost", "ghost-1", %{direction_id: 0, rows: rows})

    # A curated manual pattern with its own timing must survive every retry.
    assert {:ok, curated} =
             Gtfs.create_pattern(
               "R7",
               %{route_pattern_name: "Curated", direction_id: 0, stops: ["A", "B"]},
               context.audit
             )

    Application.put_env(:gtfs_planner, :route_pattern_derivation_inject_failure, "R8")

    on_exit(fn ->
      Application.delete_env(:gtfs_planner, :route_pattern_derivation_inject_failure)
    end)

    assert {:ok, first} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:import, nil}
             )

    assert first.routes_failed == 1
    assert first.trips_custom == 1
    assert first.patterns_created == 1

    r1_patterns = patterns_for(context, r1.route_id)
    assert length(r1_patterns) == 2

    assert Enum.sort(Enum.map(r1_patterns, & &1.route_pattern_name)) == [
             "Alpine – Birch",
             "Curated"
           ]

    assert patterns_for(context, r2.route_id) == []

    assert Repo.get_by!(GtfsPlanner.Gtfs.Route, route_id: "R8").pattern_derivation_error ==
             "injected_derivation_failure"

    assert Repo.get_by!(Trip, trip_id: "r8-1").pattern_derivation_state == "pending"
    assert custom("ghost-1").pattern_derivation_reason == "missing_route"
    refute Repo.exists?(from(r in GtfsPlanner.Gtfs.Route, where: r.route_id == ^"Ghost"))

    r1_pattern_ids = Enum.sort(Enum.map(r1_patterns, & &1.id))
    curated_timings = timings(curated.id)

    Application.delete_env(:gtfs_planner, :route_pattern_derivation_inject_failure)

    assert {:ok, second} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:import, nil}
             )

    assert second.routes_failed == 0
    assert second.patterns_created == 1
    assert second.trips_linked == 1

    assert Enum.sort(Enum.map(patterns_for(context, r1.route_id), & &1.id)) == r1_pattern_ids
    assert length(patterns_for(context, r2.route_id)) == 1
    assert is_nil(Repo.get_by!(GtfsPlanner.Gtfs.Route, route_id: "R8").pattern_derivation_error)
    assert linked("r8-1").pattern_derivation_state == "linked"

    assert timings(curated.id) == curated_timings

    # Retrying everything again is idempotent.
    assert {:ok, third} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:import, nil}
             )

    assert third.patterns_created == 0
    assert third.timings_created == 0
    assert third.trips_linked == 0
    assert third.trips_custom == 0
    assert length(patterns_for(context, r1.route_id)) == 2
    assert length(patterns_for(context, r2.route_id)) == 1
  end

  test "a supplied pattern without a representative uses its most common eligible sequence",
       context do
    _route = route_fixture(context.organization.id, context.version.id, %{route_id: "F1"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}, {"C", "Cedar"}])
    [a, b, c] = [stops["A"], stops["B"], stops["C"]]

    supplied_pattern(context, "F1", "F1-1-0")

    for trip_id <- ["f1-t1", "f1-t2"] do
      imported_trip(context, "F1", trip_id, %{
        direction_id: 0,
        route_pattern_id: "F1-1-0",
        rows: [
          time_row(a, "08:00:00"),
          time_row(b, "08:05:00"),
          time_row(c, "08:10:00")
        ]
      })
    end

    imported_trip(context, "F1", "f1-t3", %{
      direction_id: 0,
      route_pattern_id: "F1-1-0",
      rows: [time_row(a, "08:00:00"), time_row(c, "08:10:00")]
    })

    assert {:ok, summary} = derive_route(context, "F1")
    assert summary.trips_linked == 3
    assert summary.trips_custom == 0

    pattern = red_pattern(context, "F1-1-0")

    assert Enum.map(occurrences(pattern.id), &{&1.position, &1.stop_id}) ==
             [{1, "A"}, {2, "B"}, {3, "C"}]

    # The less common order becomes a child of the supplied pattern rather than
    # a custom reference.
    assert linked("f1-t3").route_pattern_id == child_of(context, pattern).route_pattern_id
    assert linked("f1-t1").timed_pattern_id == linked("f1-t2").timed_pattern_id
  end

  test "competing eligible sequences are broken by the lexical representative trip id", context do
    _route = route_fixture(context.organization.id, context.version.id, %{route_id: "F1T"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}, {"C", "Cedar"}])
    [a, b, c] = [stops["A"], stops["B"], stops["C"]]

    supplied_pattern(context, "F1T", "F1T-1-0")

    imported_trip(context, "F1T", "f1t-a", %{
      direction_id: 0,
      route_pattern_id: "F1T-1-0",
      rows: [time_row(a, "08:00:00"), time_row(b, "08:05:00"), time_row(c, "08:10:00")]
    })

    imported_trip(context, "F1T", "f1t-b", %{
      direction_id: 0,
      route_pattern_id: "F1T-1-0",
      rows: [time_row(a, "08:00:00"), time_row(c, "08:05:00"), time_row(b, "08:10:00")]
    })

    assert {:ok, summary} = derive_route(context, "F1T")
    assert summary.trips_linked == 2
    assert summary.trips_custom == 0

    assert Enum.map(occurrences(red_pattern(context, "F1T-1-0").id), & &1.stop_id) == [
             "A",
             "B",
             "C"
           ]

    # The lexically later trip loses the tie and becomes the labelled child.
    assert linked("f1t-b").route_pattern_id ==
             child_of(context, red_pattern(context, "F1T-1-0")).route_pattern_id
  end

  test "a direction-mismatched or missing-direction supplied reference stays custom", context do
    _route = route_fixture(context.organization.id, context.version.id, %{route_id: "F2"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}])
    [a, b] = [stops["A"], stops["B"]]

    supplied_pattern(context, "F2", "F2-1-0")

    rows = [time_row(a, "08:00:00"), time_row(b, "08:05:00")]

    imported_trip(context, "F2", "f2-opposite", %{
      direction_id: 1,
      route_pattern_id: "F2-1-0",
      rows: rows
    })

    imported_trip(context, "F2", "f2-nodir", %{
      direction_id: nil,
      route_pattern_id: "F2-1-0",
      rows: rows
    })

    assert {:ok, summary} = derive_route(context, "F2")
    assert summary.trips_linked == 0
    assert summary.trips_custom == 2
    assert custom("f2-opposite").pattern_derivation_reason == "scope_mismatch"
    assert custom("f2-nodir").pattern_derivation_reason == "missing_direction"
    assert occurrences(red_pattern(context, "F2-1-0").id) == []
  end

  test "a station stop type never becomes an editable pattern stop", context do
    _route = route_fixture(context.organization.id, context.version.id, %{route_id: "F3"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}])
    [a, b] = [stops["A"], stops["B"]]

    station =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "F3STATION",
        stop_name: "F3 Station",
        location_type: 1
      })

    supplied_pattern(context, "F3", "F3-1-0", %{representative_trip_id: "f3-rep"})

    # The representative references a station, so the pattern falls back to the
    # eligible sequence another trip actually uses.
    imported_trip(context, "F3", "f3-rep", %{
      direction_id: 0,
      route_pattern_id: "F3-1-0",
      rows: [time_row(station, "08:00:00"), time_row(b, "08:05:00")]
    })

    imported_trip(context, "F3", "f3-ok", %{
      direction_id: 0,
      route_pattern_id: "F3-1-0",
      rows: [time_row(a, "08:00:00"), time_row(b, "08:05:00")]
    })

    assert {:ok, summary} = derive_route(context, "F3")
    assert summary.trips_linked == 1
    assert summary.trips_custom == 1

    pattern = red_pattern(context, "F3-1-0")
    assert Enum.map(occurrences(pattern.id), & &1.stop_id) == ["A", "B"]
    assert custom("f3-rep").pattern_derivation_reason == "unusable_stops"

    # A trip without a supplied pattern is grouped the same way: a station in its
    # sequence keeps it custom instead of creating a derived pattern.
    _derived_route =
      route_fixture(context.organization.id, context.version.id, %{route_id: "F3D"})

    imported_trip(context, "F3D", "f3d-1", %{
      direction_id: 0,
      rows: [time_row(station, "09:00:00"), time_row(b, "09:05:00")]
    })

    assert {:ok, derived} = derive_route(context, "F3D")
    assert derived.patterns_created == 0
    assert derived.trips_custom == 1
    assert patterns_for(context, "F3D") == []
    assert custom("f3d-1").pattern_derivation_reason == "unusable_stops"
  end

  test "a supplied pattern with known stops and no representable trip keeps a zero Timing A",
       context do
    _route = route_fixture(context.organization.id, context.version.id, %{route_id: "F4"})
    stops = stops_fixture(context, [{"A", "Alpine"}, {"B", "Birch"}])
    [a, b] = [stops["A"], stops["B"]]

    supplied_pattern(context, "F4", "F4-1-0", %{representative_trip_id: "f4-rep"})

    imported_trip(context, "F4", "f4-rep", %{
      direction_id: 0,
      route_pattern_id: "F4-1-0",
      rows: [time_row(a, "08:00:00", "08:00:00", 1), time_row(b, nil, nil, 2)]
    })

    assert {:ok, summary} = derive_route(context, "F4")
    assert summary.trips_linked == 0
    assert summary.trips_custom == 1
    assert summary.timings_created == 1

    pattern = red_pattern(context, "F4-1-0")
    assert Enum.map(occurrences(pattern.id), & &1.stop_id) == ["A", "B"]

    assert [timing] = timings(pattern.id)
    assert timing.name == "Timing A"
    assert is_nil(timing.derivation_key)

    assert Enum.map(timing_rows(timing.id), &{&1.arrival_offset, &1.departure_offset}) ==
             [{0, 0}, {0, 0}]

    custom_trip = custom("f4-rep")
    assert is_nil(custom_trip.timed_pattern_id)

    # A retry of the same route reuses the template timing instead of adding a
    # second one, and never rebuilds the initialized occurrences.
    custom_trip
    |> Ecto.Changeset.change(pattern_derivation_state: "pending")
    |> Repo.update!()

    assert {:ok, retry} = derive_route(context, "F4")
    assert retry.timings_created == 0
    assert length(timings(pattern.id)) == 1
    assert length(occurrences(pattern.id)) == 2
  end

  test "an unsupplied all-custom derived group has an unassigned zero timing", context do
    route_fixture(context.organization.id, context.version.id, %{route_id: "CUSTOM"})
    stops = stops_fixture(context, [{"A", "A"}, {"B", "B"}])

    imported_trip(context, "CUSTOM", "custom-only", %{
      rows: [time_row(stops["A"], "08:00:00", "08:00:00", 1), time_row(stops["B"], nil, nil, 2)]
    })

    assert {:ok, summary} = derive_route(context, "CUSTOM")
    assert summary.trips_custom == 1
    assert summary.timings_created == 1
    pattern = Repo.one!(from(p in RoutePattern, where: p.route_id == "CUSTOM"))
    assert [timing] = timings(pattern.id)

    assert Enum.map(timing_rows(timing.id), &{&1.arrival_offset, &1.departure_offset}) == [
             {0, 0},
             {0, 0}
           ]

    assert is_nil(custom("custom-only").timed_pattern_id)
  end

  test "sparse pending pages query exact trip membership across interleaved routes", context do
    for route <- ["Sparse", "Other"],
        do: route_fixture(context.organization.id, context.version.id, %{route_id: route})

    stops = stops_fixture(context, [{"A", "A"}, {"B", "B"}])

    rows = [
      time_row(stops["A"], "08:00:00", "08:00:00", 1),
      time_row(stops["B"], "08:10:00", "08:10:00", 2)
    ]

    for id <- ["000", "zzz"], do: imported_trip(context, "Sparse", id, %{rows: rows})
    imported_trip(context, "Other", "middle", %{rows: rows})
    handler = "page-membership-#{System.unique_integer([:positive])}"
    owner = self()

    :telemetry.attach(
      handler,
      [:gtfs_planner, :repo, :query],
      fn _, _, metadata, _ ->
        if metadata.source == "stop_times" and String.starts_with?(metadata.query, "SELECT"),
          do: send(owner, {:page_query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, %{trips_linked: 2}} = derive_route(context, "Sparse")
    assert Repo.get_by!(Trip, trip_id: "middle").pattern_derivation_state == "pending"
    queries = collect_page_queries([])
    assert Enum.count(queries, &String.contains?(&1, "= ANY")) >= 2
    refute Enum.any?(queries, &String.contains?(&1, ">="))
  end

  defp collect_page_queries(acc) do
    receive do
      {:page_query, query} -> collect_page_queries([query | acc])
    after
      0 -> acc
    end
  end

  # --- helpers --------------------------------------------------------------

  defp derive_route(context, route_id) do
    Derivation.derive_route(
      context.organization.id,
      context.version.id,
      route_id,
      {:import, nil}
    )
  end

  defp pinned_source do
    path = Path.join(@fixture_dir, "mbta_route_patterns_subset.txt")
    content = File.read!(path)
    metadata = @fixture_dir |> Path.join("source.json") |> File.read!() |> Jason.decode!()

    assert Base.encode16(:crypto.hash(:sha256, content), case: :lower) == metadata["sha256"]

    [header | rows] = content |> String.trim_trailing() |> String.split("\n")
    columns = String.split(header, ",")

    Enum.map(rows, fn row ->
      fields = String.split(row, ",")
      columns |> Enum.zip(fields) |> Map.new()
    end)
  end

  defp insert_pinned_patterns(context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(pinned_source(), fn row ->
        %{
          id: Ecto.UUID.generate(),
          route_pattern_id: row["route_pattern_id"],
          route_id: row["route_id"],
          direction_id: String.to_integer(row["direction_id"]),
          route_pattern_name: row["route_pattern_name"],
          route_pattern_time_desc: row["route_pattern_time_desc"],
          route_pattern_typicality: String.to_integer(row["route_pattern_typicality"]),
          route_pattern_sort_order: String.to_integer(row["route_pattern_sort_order"]),
          representative_trip_id: row["representative_trip_id"],
          canonical_route_pattern: String.to_integer(row["canonical_route_pattern"]),
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(RoutePattern, rows)
    count
  end

  defp stops_fixture(context, specs) do
    Map.new(specs, fn {stop_id, name} ->
      stop =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: stop_id,
          stop_name: name
        })

      {stop_id, stop}
    end)
  end

  defp time_row(stop, arrival, departure \\ nil, sequence \\ nil, extra \\ %{}) do
    base = %{
      stop_id: stop.stop_id,
      arrival_time: arrival,
      departure_time: departure || arrival,
      timepoint: nil,
      pickup_type: nil,
      drop_off_type: nil,
      stop_headsign: nil
    }

    base =
      if is_nil(sequence), do: base, else: Map.put(base, :stop_sequence, sequence)

    Map.merge(base, extra)
  end

  defp imported_trip(context, route_id, trip_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          trip_id: trip_id,
          route_id: route_id,
          service_id: "WK",
          direction_id: 0,
          trip_headsign: nil,
          route_pattern_id: nil,
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          inserted_at: now,
          updated_at: now
        },
        Map.take(attrs, [:direction_id, :trip_headsign, :route_pattern_id])
      )

    {1, nil} = Repo.insert_all(Trip, [row])

    attrs
    |> Map.fetch!(:rows)
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_time, index} ->
      stop_time =
        stop_time
        |> Map.put_new(:stop_sequence, index)
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          trip_id: trip_id,
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          inserted_at: now,
          updated_at: now
        })

      {1, nil} = Repo.insert_all(StopTime, [stop_time])
    end)

    Repo.get_by!(Trip,
      trip_id: trip_id,
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id
    )
  end

  defp stop_time_snapshot(context) do
    from(st in StopTime,
      where:
        st.organization_id == ^context.organization.id and
          st.gtfs_version_id == ^context.version.id,
      order_by: [asc: st.trip_id, asc: st.stop_sequence],
      select:
        {st.id, st.trip_id, st.stop_id, st.stop_sequence, st.arrival_time, st.departure_time,
         st.timepoint, st.pickup_type, st.drop_off_type, st.stop_headsign}
    )
    |> Repo.all()
  end

  defp linked(trip_id) when is_binary(trip_id), do: Repo.get_by!(Trip, trip_id: trip_id)

  defp linked(trip) when is_struct(trip), do: Repo.get!(Trip, trip.id)

  defp custom(trip_id) when is_binary(trip_id) do
    trip = Repo.get_by!(Trip, trip_id: trip_id)
    assert trip.pattern_derivation_state == "custom"
    trip
  end

  defp custom(trip) when is_struct(trip) do
    trip = Repo.get!(Trip, trip.id)
    assert trip.pattern_derivation_state == "custom"
    trip
  end

  defp patterns_for(context, route_id) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^context.organization.id and
          p.gtfs_version_id == ^context.version.id and p.route_id == ^route_id,
      order_by: [asc: p.direction_id, asc: p.route_pattern_id]
    )
    |> Repo.all()
  end

  defp supplied_pattern(context, route_id, natural_id, attrs \\ %{}) do
    %RoutePattern{}
    |> RoutePattern.changeset(
      Map.merge(
        %{
          route_pattern_id: natural_id,
          route_id: route_id,
          direction_id: 0,
          route_pattern_name: natural_id,
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp red_pattern(context, natural_id) do
    Repo.get_by!(RoutePattern,
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      route_pattern_id: natural_id
    )
  end

  # The one pattern this supplied owner labelled, which derivation creates when
  # the supplied pattern's trips serve a second ordered stop list.
  defp child_of(context, owner) do
    Repo.get_by!(RoutePattern,
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      label_pattern_id: owner.id
    )
  end

  defp occurrences(pattern_id) do
    from(o in RoutePatternStop,
      where: o.route_pattern_id == ^pattern_id,
      order_by: [asc: o.position]
    )
    |> Repo.all()
  end

  defp timings(pattern_id) do
    from(t in TimedPattern,
      where: t.route_pattern_id == ^pattern_id,
      order_by: [asc: t.name, asc: t.id]
    )
    |> Repo.all()
  end

  defp timing_rows(timing_id) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id,
      order_by: [asc: occurrence.position]
    )
    |> Repo.all()
  end
end
