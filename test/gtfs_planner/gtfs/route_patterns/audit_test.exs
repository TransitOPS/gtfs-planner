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
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = user_fixture()

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
        from log in ChangeLog,
          where: log.entity_type == "route_pattern" and log.entity_id == ^pattern.id
      )

    assert log.station_stop_id == nil
    refute Enum.any?(Gtfs.reversible_fields_for("route_pattern"))
    refute Enum.any?(Gtfs.reversible_fields_for("timed_pattern"))
    assert {:error, :audit_only_entity} = Gtfs.rollback_target_snapshot(log)

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

  test "an invalid actor-bound audit prevents the pattern mutation from committing", context do
    bad_audit = %{context.audit | actor_id: nil}

    assert {:error, %Ecto.Changeset{}} =
             Gtfs.create_pattern(context.route.route_id, attrs(context.stops), bad_audit)

    refute Repo.exists?(
             from pattern in RoutePattern,
               where: pattern.organization_id == ^context.organization.id
           )

    refute Repo.exists?(
             from log in ChangeLog,
               where: log.organization_id == ^context.organization.id
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
        from timing in TimedPattern,
          where: timing.route_pattern_id == ^pattern.id and timing.name == "Timing B"
      )

    [created_log] =
      Repo.all(
        from log in ChangeLog,
          where: log.entity_type == "timed_pattern" and log.entity_id == ^timing.id
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
        from log in ChangeLog,
          where:
            log.entity_type == "timed_pattern" and log.entity_id == ^timing.id and
              log.action == "updated"
      )

    assert updated_log.entity_external_id == stable_identity
    assert updated_log.changed_fields["name"]["from"] == "Timing B"
    assert updated_log.changed_fields["name"]["to"] == "Evening"
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
