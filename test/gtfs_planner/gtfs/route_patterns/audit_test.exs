defmodule GtfsPlanner.Gtfs.RoutePatterns.AuditTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: "must-be-cleared",
      actor_id: actor.id,
      actor_email: actor.email
    }

    first = stop_fixture(organization.id, version.id)
    second = stop_fixture(organization.id, version.id)

    %{
      organization: organization,
      version: version,
      route: route,
      audit: audit,
      stops: [first, second]
    }
  end

  test "pattern and timing audit types are accepted but have no rollback fields", context do
    assert {:ok, pattern} =
             Gtfs.create_pattern(context.route.route_id, attrs(context.stops), context.audit)

    [log] =
      Repo.all(
        from(log in ChangeLog,
          where: log.entity_type == "route_pattern" and log.entity_id == ^pattern.id
        )
      )

    assert log.station_stop_id == nil
    assert log.changed_fields["before"] == nil
    assert log.changed_fields["after"]["route_pattern_name"] == "Crosstown"
    refute Enum.any?(Gtfs.reversible_fields_for("route_pattern"))
    refute Enum.any?(Gtfs.reversible_fields_for("timed_pattern"))
    assert {:error, :audit_only_entity} = GtfsPlanner.Gtfs.Stations.rollback_target_snapshot(log)

    assert ChangeLog.changeset(%ChangeLog{}, %{
             entity_type: "timed_pattern",
             entity_id: Ecto.UUID.generate(),
             entity_external_id: "#{Ecto.UUID.generate()}:#{pattern.route_pattern_id}",
             actor_id: context.audit.actor_id,
             actor_email: context.audit.actor_email,
             action: "updated",
             organization_id: context.organization.id,
             gtfs_version_id: context.version.id
           }).valid?
  end

  test "an invalid actor is forbidden before the pattern mutation", context do
    bad_audit = %{context.audit | actor_id: nil}

    assert {:error, :forbidden} =
             Gtfs.create_pattern(context.route.route_id, attrs(context.stops), bad_audit)

    refute Repo.exists?(
             from(pattern in RoutePattern,
               where: pattern.organization_id == ^context.organization.id
             )
           )

    refute Repo.exists?(
             from(log in ChangeLog,
               where: log.organization_id == ^context.organization.id
             )
           )
  end

  test "an identical details save leaves timestamps and audit history unchanged", context do
    assert {:ok, pattern} =
             Gtfs.create_pattern(context.route.route_id, attrs(context.stops), context.audit)

    before_pattern = Repo.get!(RoutePattern, pattern.id)

    before_logs =
      Repo.aggregate(from(log in ChangeLog, where: log.entity_id == ^pattern.id), :count)

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    operation = {:details, %{headsign: pattern.headsign}}

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert {:ok, %{pattern: unchanged}} =
             Gtfs.apply_review(pattern.id, operation, fingerprint, context.audit)

    assert unchanged.updated_at == before_pattern.updated_at

    assert Repo.aggregate(from(log in ChangeLog, where: log.entity_id == ^pattern.id), :count) ==
             before_logs
  end

  test "a stale source fingerprint is rejected before a pattern or audit write", context do
    assert {:ok, pattern} =
             Gtfs.create_pattern(context.route.route_id, attrs(context.stops), context.audit)

    before_pattern = Repo.get!(RoutePattern, pattern.id)

    before_logs =
      Repo.aggregate(from(log in ChangeLog, where: log.entity_id == ^pattern.id), :count)

    operation = {:details, %{headsign: "Stale edit"}}

    assert {:error, :stale_review} =
             Gtfs.review(pattern.id, operation, "wrong-source-fingerprint", context.audit)

    assert Repo.get!(RoutePattern, pattern.id) == before_pattern

    assert Repo.aggregate(from(log in ChangeLog, where: log.entity_id == ^pattern.id), :count) ==
             before_logs
  end

  test "timing audit identity survives a name change and snapshots its stable occurrence rows",
       context do
    assert {:ok, pattern} =
             Gtfs.create_pattern(context.route.route_id, attrs(context.stops), context.audit)

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    operation = {:add_timing, %{name: "Timing B", headsign: "Uptown"}}

    assert {:ok, %{fingerprint: reviewed}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert {:ok, _} = Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

    timing =
      Repo.one!(
        from(timing in TimedPattern,
          where: timing.route_pattern_id == ^pattern.id and timing.name == "Timing B"
        )
      )

    [created_log] =
      Repo.all(
        from(log in ChangeLog,
          where: log.entity_type == "timed_pattern" and log.entity_id == ^timing.id
        )
      )

    stable_identity = "#{timing.id}:#{pattern.route_pattern_id}"
    assert created_log.entity_external_id == stable_identity
    assert created_log.station_stop_id == nil
    assert created_log.changed_fields["before"] == nil
    assert length(created_log.changed_fields["after"]["rows"]) == 2

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    rename = {:timing, timing.id, %{name: "Evening", headsign: "Uptown"}}

    assert {:ok, %{fingerprint: reviewed}} =
             Gtfs.review(pattern.id, rename, source, context.audit)

    assert {:ok, _} = Gtfs.apply_review(pattern.id, rename, reviewed, context.audit)

    [updated_log] =
      Repo.all(
        from(log in ChangeLog,
          where:
            log.entity_type == "timed_pattern" and log.entity_id == ^timing.id and
              log.action == "updated"
        )
      )

    assert updated_log.entity_external_id == stable_identity
    assert updated_log.changed_fields["name"]["from"] == "Timing B"
    assert updated_log.changed_fields["name"]["to"] == "Evening"

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    delete = {:delete_timing, timing.id}

    assert {:ok, %{fingerprint: reviewed}} =
             Gtfs.review(pattern.id, delete, source, context.audit)

    assert {:ok, _} = Gtfs.apply_review(pattern.id, delete, reviewed, context.audit)

    [deleted_log] =
      Repo.all(
        from(log in ChangeLog,
          where:
            log.entity_type == "timed_pattern" and log.entity_id == ^timing.id and
              log.action == "deleted"
        )
      )

    assert deleted_log.entity_external_id == stable_identity
    assert deleted_log.changed_fields["before"]["name"] == "Evening"
    assert deleted_log.changed_fields["after"] == nil
  end

  test "a structural edit snapshots the real before structure and its affected count", context do
    third = stop_fixture(context.organization.id, context.version.id, %{stop_id: "third"})
    stops = context.stops ++ [third]

    assert {:ok, pattern} =
             Gtfs.create_pattern(context.route.route_id, attrs(stops), context.audit)

    assert length(occurrences(pattern)) == 3

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    kept = Enum.take(occurrences(pattern), 2)
    operation = {:stops, Enum.map(kept, &%{id: &1.id, stop_id: &1.stop_id}), %{}}

    assert {:ok, %{fingerprint: reviewed}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert {:ok, %{trips_updated: 0}} =
             Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

    [log] =
      Repo.all(
        from(log in ChangeLog,
          where:
            log.entity_type == "route_pattern" and log.entity_id == ^pattern.id and
              log.action == "updated"
        )
      )

    before_snapshot = log.changed_fields["before"]["to"]
    after_snapshot = log.changed_fields["after"]["to"]

    # The before snapshot is the structure that was actually replaced, not the
    # post-mutation one, and its timing rows still describe all three stops.
    assert snapshot_stop_ids(before_snapshot) == Enum.map(stops, & &1.stop_id)
    assert snapshot_stop_ids(after_snapshot) == Enum.map(kept, & &1.stop_id)

    [before_timing] = snapshot_value(before_snapshot, "timings")
    [after_timing] = snapshot_value(after_snapshot, "timings")
    assert length(snapshot_value(before_timing, "rows")) == 3
    assert length(snapshot_value(after_timing, "rows")) == 2

    # The dedicated audit clause keeps the affected-trip count for both entity
    # types instead of dropping it as an unknown field.
    assert log.changed_fields["affected_trips"] == %{"from" => nil, "to" => 0}
  end

  test "an identical timing vector writes no rows, signature change or audit", context do
    assert {:ok, pattern} =
             Gtfs.create_pattern(context.route.route_id, attrs(context.stops), context.audit)

    [timing] =
      Repo.all(from(timing in TimedPattern, where: timing.route_pattern_id == ^pattern.id))

    before_pattern = Repo.get!(RoutePattern, pattern.id)
    before_timing = Repo.get!(TimedPattern, timing.id)
    before_rows = timing_row_values(timing.id)
    before_logs = Repo.aggregate(ChangeLog, :count)

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    operation = {:timing, timing.id, %{rows: before_rows}}

    assert {:ok, %{fingerprint: reviewed}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert {:ok, %{trips_updated: 0, pattern: unchanged}} =
             Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

    assert unchanged.id == before_pattern.id
    assert Repo.aggregate(ChangeLog, :count) == before_logs
    assert timing_row_values(timing.id) == before_rows
    assert Repo.get!(TimedPattern, timing.id).updated_at == before_timing.updated_at
    assert Repo.get!(RoutePattern, pattern.id).updated_at == before_pattern.updated_at
  end

  # Snapshot values round-trip through the JSON column, so keys are strings on
  # read; accept either shape so the assertion does not depend on encoding.
  defp snapshot_value(map, key),
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp snapshot_stop_ids(snapshot) do
    snapshot
    |> snapshot_value("occurrences")
    |> Enum.map(&snapshot_value(&1, "stop_id"))
  end

  defp occurrences(pattern) do
    Repo.all(
      from(occurrence in RoutePatternStop,
        where: occurrence.route_pattern_id == ^pattern.id,
        order_by: [asc: occurrence.position]
      )
    )
  end

  defp timing_row_values(timing_id) do
    Repo.all(
      from(row in TimedPatternStop,
        join: occurrence in RoutePatternStop,
        on: occurrence.id == row.route_pattern_stop_id,
        where: row.timed_pattern_id == ^timing_id,
        order_by: [asc: occurrence.position],
        select: %{
          route_pattern_stop_id: row.route_pattern_stop_id,
          arrival_offset: row.arrival_offset,
          departure_offset: row.departure_offset,
          timepoint: row.timepoint,
          pickup_type: row.pickup_type,
          drop_off_type: row.drop_off_type,
          stop_headsign: row.stop_headsign
        }
      )
    )
  end

  defp attrs(stops) do
    %{
      route_pattern_name: "Crosstown",
      direction_id: 0,
      headsign: "Harbor",
      stops: Enum.map(stops, & &1.stop_id)
    }
  end
end
