defmodule GtfsPlanner.Gtfs.RoutePatterns.HeadsignPropagationTest do
  @moduledoc """
  Focused coverage for selection-aware pattern and timing saves (EV-7): a
  headsign selection is reported as `impact.headsign_trips` (never in
  `trips_affected`), validated against the new value's scope, written through
  the fenced trip writer under one operation id, and returned as
  `headsign_undo`. Existing 2/3-tuple operations keep their behaviour.

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_hs20 mix test
  test/gtfs_planner/gtfs/route_patterns/headsign_propagation_test.exs`.
  """

  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  @old_default "Lincoln City"
  @new_default "Lincoln City via Depoe Bay"

  setup do
    organization =
      organization_fixture(%{alias: "headsign-prop-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "HS20-0",
        headsign: @old_default,
        timing_name: "Weekday",
        stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
      })

    # A timing with its own headsign shields its trip from the pattern scope.
    school = timed_pattern_fixture(bundle.pattern, %{name: "School days", headsign: "Schools"})

    school_trip =
      trip_fixture(organization.id, version.id, route.route_id,
        trip_id: "hs20-school",
        service_id: "WK",
        trip_headsign: "Schools"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: bundle.pattern.route_pattern_id,
        timed_pattern_id: school.id,
        pattern_derivation_state: "linked"
      })

    # Five pattern-scope trips on the nil-headsign timing: three followers, a
    # padded import value and a differing trip.
    trip_attrs = [
      {"hs20-1", @old_default},
      {"hs20-2", @old_default},
      {"hs20-3", @old_default},
      {"hs20-4", " #{@old_default}"},
      {"hs20-5", "Roads End via Lincoln City"}
    ]

    trips =
      Enum.map(trip_attrs, fn {trip_id, headsign} ->
        schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
          service_id: "WK",
          trip_id: trip_id,
          trip_headsign: headsign
        })
        |> Map.fetch!(:trip)
      end)

    [follower_a, follower_b, follower_c, padded, differing] = trips

    %{
      organization: organization,
      version: version,
      route: route,
      audit: audit,
      pattern: bundle.pattern,
      timing: bundle.timing,
      school: school,
      school_trip: school_trip,
      followers: [follower_a, follower_b, follower_c],
      padded: padded,
      differing: differing
    }
  end

  test "a headsign-only details review reports headsign_trips 3 and trips_affected 0",
       %{pattern: pattern, audit: audit, followers: [a, b, c]} do
    operation = {:details, %{headsign: @new_default}, %{headsign_trip_ids: [a.id, b.id, c.id]}}

    assert {:ok, %{impact: %{trips_affected: 0, headsign_trips: 3}, proposed: proposed}} =
             Gtfs.review(pattern.id, operation, nil, audit)

    changes = proposed.headsign_changes
    assert length(changes) == 3
    assert Enum.all?(changes, &(&1.from == @old_default and &1.to == @new_default))
  end

  test "applying the details save writes the pattern headsign and exactly the selected trips",
       %{
         pattern: pattern,
         audit: audit,
         followers: [a, b, c],
         padded: padded,
         differing: differing
       } =
         context do
    operation = {:details, %{headsign: @new_default}, %{headsign_trip_ids: [a.id, b.id, c.id]}}

    {:ok, %{fingerprint: fingerprint, proposed: %{headsign_changes: changes}}} =
      Gtfs.review(pattern.id, operation, nil, audit)

    assert {:ok, %{trips_updated: 0, headsign_undo: undo}} =
             Gtfs.apply_review(pattern.id, operation, fingerprint, audit)

    assert %{headsign: @new_default} = Repo.reload!(pattern)

    assert %{
             default: %{scope: :pattern, from: @old_default, to: @new_default},
             trips: ^changes
           } = undo

    # The selected followers moved; the padded follower and the differing trip
    # kept their exact values.
    assert headsign_of(a) == @new_default
    assert headsign_of(b) == @new_default
    assert headsign_of(c) == @new_default
    assert headsign_of(padded) == @old_default
    assert headsign_of(differing) == "Roads End via Lincoln City"

    # The pattern row carries the shared operation id and all three affected
    # trips; each written trip carries its own audited row under the same id.
    pattern_log = pattern_updated_log(context, pattern)

    operation_id = pattern_log.changed_fields["operation_id"]
    assert is_binary(operation_id)
    assert pattern_log.changed_fields["affected_trips"] == %{"from" => nil, "to" => 3}
    assert pattern_log.changed_fields["headsign"]["from"] == @old_default
    assert pattern_log.changed_fields["headsign"]["to"] == @new_default

    logs = trip_logs(context)
    assert length(logs) == 3
    assert Enum.sort(Enum.map(logs, & &1.entity_id)) == Enum.sort([a.id, b.id, c.id])
    assert Enum.all?(logs, &(&1.changed_fields["operation_id"] == operation_id))
  end

  test "a headsign-only timing save without rows affects no trips and leaves stop times alone",
       %{pattern: pattern, timing: timing, audit: audit, padded: padded} = context do
    operation = {:timing, timing.id, %{headsign: "X"}, %{headsign_trip_ids: [padded.id]}}

    assert {:ok, %{fingerprint: fingerprint, impact: %{trips_affected: 0, headsign_trips: 1}}} =
             Gtfs.review(pattern.id, operation, nil, audit)

    stop_times_before = max_stop_time_updated_at(context)

    assert {:ok, %{trips_updated: 0, headsign_undo: undo}} =
             Gtfs.apply_review(pattern.id, operation, fingerprint, audit)

    # No rows were submitted, so nothing re-materialized.
    assert max_stop_time_updated_at(context) == stop_times_before
    assert %{headsign: "X"} = Repo.reload!(timing)
    assert headsign_of(padded) == "X"

    assert %{
             default: %{scope: {:timing, timing_id}, from: @old_default, to: "X"},
             trips: [%{id: written_id}]
           } = undo

    assert timing_id == timing.id
    assert written_id == padded.id
  end

  test "a shielded, foreign-pattern or other-organization id is rejected with nothing written",
       %{
         pattern: pattern,
         timing: timing,
         audit: audit,
         school_trip: school_trip,
         organization: organization,
         version: version,
         route: route
       } = context do
    other_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "HS20-1"
      })

    other_trip =
      trip_fixture(organization.id, version.id, route.route_id, trip_id: "hs20-other")
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: other_pattern.route_pattern_id,
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "missing_route"
      })

    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    foreign_route = route_fixture(foreign_org.id, foreign_version.id)

    foreign_bundle =
      schedule_pattern_fixture(foreign_org.id, foreign_version.id, %{
        route_id: foreign_route.route_id,
        route_pattern_id: "FOREIGN-0",
        stops: [{"FA", 0, 0, 1}, {"FB", 60, 60, 1}]
      })

    foreign_trip =
      schedule_trip_fixture(
        foreign_org.id,
        foreign_version.id,
        foreign_route.route_id,
        foreign_bundle,
        %{
          service_id: "WK",
          trip_id: "foreign-1"
        }
      )
      |> Map.fetch!(:trip)

    audits_before = change_log_count(context)
    trips_before = raw_headsigns([school_trip, other_trip])

    for invalid <- [
          {:details, %{headsign: "Z"}, %{headsign_trip_ids: [school_trip.id]}},
          {:details, %{headsign: "Z"}, %{headsign_trip_ids: [other_trip.id]}},
          {:details, %{headsign: "Z"}, %{headsign_trip_ids: [foreign_trip.id]}},
          {:timing, timing.id, %{headsign: "Z"}, %{headsign_trip_ids: [other_trip.id]}},
          {:details, %{headsign: "Z"}, %{headsign_trip_ids: ["not-a-uuid"]}}
        ] do
      assert {:error, :invalid_selection} = Gtfs.review(pattern.id, invalid, nil, audit)
    end

    # The apply path re-validates the selection before the full fingerprint check.
    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, {:details, %{headsign: "Z"}}, nil, audit)

    assert {:error, :invalid_selection} =
             Gtfs.apply_review(
               pattern.id,
               {:details, %{headsign: "Z"}, %{headsign_trip_ids: [school_trip.id]}},
               fingerprint,
               audit
             )

    assert change_log_count(context) == audits_before
    assert raw_headsigns([school_trip, other_trip]) == trips_before
  end

  test "a trip edited after review makes apply return stale_review with nothing written",
       %{pattern: pattern, audit: audit, differing: differing} = context do
    operation = {:details, %{headsign: "W"}, %{headsign_trip_ids: [differing.id]}}

    assert {:ok, %{fingerprint: fingerprint}} = Gtfs.review(pattern.id, operation, nil, audit)

    audits_after_review = change_log_count(context)

    differing
    |> Ecto.Changeset.change(trip_headsign: "Edited elsewhere")
    |> Repo.update!()

    assert {:error, :stale_review} = Gtfs.apply_review(pattern.id, operation, fingerprint, audit)

    assert headsign_of(differing) == "Edited elsewhere"
    assert %{headsign: @old_default} = Repo.reload!(pattern)
    assert change_log_count(context) == audits_after_review
  end

  test "existing direction and timing-rows operations keep their trips_affected and effects",
       %{pattern: pattern, timing: timing, audit: audit, school_trip: school_trip} = context do
    direction_operation = {:details, %{direction_id: 1}}

    assert {:ok, %{fingerprint: direction_fingerprint, impact: direction_impact}} =
             Gtfs.review(pattern.id, direction_operation, nil, audit)

    assert %{trips_affected: 6, headsign_trips: 0} = direction_impact

    assert {:ok, %{trips_updated: 6, headsign_undo: nil}} =
             Gtfs.apply_review(pattern.id, direction_operation, direction_fingerprint, audit)

    assert Repo.reload!(school_trip).direction_id == 1

    direction_log = pattern_updated_log(context, pattern)
    assert direction_log.changed_fields["affected_trips"] == %{"from" => nil, "to" => 6}
    # A save without a selection keeps the previous audit shape: no operation id.
    assert direction_log.changed_fields["operation_id"] == nil

    rows = timing_rows(timing.id)
    changed_rows = [hd(rows), %{Enum.at(rows, 1) | departure_offset: 360}]

    rows_operation = {:timing, timing.id, %{rows: changed_rows}}

    assert {:ok, %{fingerprint: rows_fingerprint, impact: rows_impact}} =
             Gtfs.review(pattern.id, rows_operation, nil, audit)

    assert %{trips_affected: 5, headsign_trips: 0} = rows_impact

    stop_times_before = max_stop_time_updated_at(context)

    assert {:ok, %{trips_updated: 5, headsign_undo: nil}} =
             Gtfs.apply_review(pattern.id, rows_operation, rows_fingerprint, audit)

    assert max_stop_time_updated_at(context) != stop_times_before
  end

  defp headsign_of(trip),
    do: trip |> Repo.reload!() |> Map.get(:trip_headsign) |> Headsigns.normalize()

  defp raw_headsigns(trips), do: Enum.map(trips, &Repo.reload!(&1).trip_headsign)

  defp trip_logs(context) do
    Repo.all(
      from(log in ChangeLog,
        where: log.organization_id == ^context.organization.id and log.entity_type == "trip"
      )
    )
  end

  defp pattern_updated_log(context, pattern) do
    Repo.one!(
      from(log in ChangeLog,
        where:
          log.organization_id == ^context.organization.id and
            log.entity_type == "route_pattern" and log.entity_id == ^pattern.id and
            log.action == "updated",
        order_by: [desc: log.inserted_at],
        limit: 1
      )
    )
  end

  defp change_log_count(context) do
    Repo.aggregate(
      from(log in ChangeLog, where: log.organization_id == ^context.organization.id),
      :count
    )
  end

  defp max_stop_time_updated_at(context) do
    Repo.one!(
      from(stop_time in StopTime,
        where: stop_time.organization_id == ^context.organization.id,
        select: max(stop_time.updated_at)
      )
    )
  end

  # Row order must match the pattern's occurrence positions: the timing-row
  # review compares the submitted stop-id sequence with `pattern_occurrences/1`
  # (position order), so ordering by the random UUID flaked the gate.
  defp timing_rows(timing_id) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id,
      order_by: [asc: occurrence.position]
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        route_pattern_stop_id: row.route_pattern_stop_id,
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        stop_headsign: row.stop_headsign
      }
    end)
  end
end
