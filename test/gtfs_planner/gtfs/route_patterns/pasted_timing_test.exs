defmodule GtfsPlanner.Gtfs.RoutePatterns.PastedTimingTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{
        alias: "route-pattern-pasted-timing-#{System.system_time(:nanosecond)}"
      })

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = user_fixture()

    %{
      organization: organization,
      version: version,
      route: route,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  test "a second paste the same day with an existing Pasted Sep 28 · A creates · B", context do
    pattern = create_pattern(context, ["A", "B", "C"])

    assert {:ok, _} =
             Repo.transaction(fn ->
               locked = lock_pattern(context, pattern)

               RoutePatterns.create_pasted_timing!(
                 locked,
                 "Pasted Sep 28 · A",
                 rows(),
                 nil,
                 context.audit
               )
             end)

    assert RoutePatterns.next_free_timing_name(pattern.id, "Pasted Sep 28", []) ==
             "Pasted Sep 28 · B"
  end

  test "pending names are skipped case-insensitively", context do
    pattern = create_pattern(context, ["A", "B"])

    assert RoutePatterns.next_free_timing_name(pattern.id, "Pasted Sep 28", []) ==
             "Pasted Sep 28 · A"

    assert RoutePatterns.next_free_timing_name(pattern.id, "Pasted Sep 28", [
             "pasted sep 28 · a",
             "Pasted Sep 28 · B"
           ]) == "Pasted Sep 28 · C"
  end

  test "create_pasted_timing! inserts one row per occurrence with timepoint 0/1 as given",
       context do
    pattern = create_pattern(context, ["A", "B", "C"])

    assert {:ok, timing} =
             Repo.transaction(fn ->
               locked = lock_pattern(context, pattern)

               timing =
                 RoutePatterns.create_pasted_timing!(
                   locked,
                   "Pasted Sep 28 · A",
                   rows(),
                   "Downtown",
                   context.audit
                 )

               assert RoutePatterns.next_free_timing_name(locked.id, "Pasted Sep 28", []) ==
                        "Pasted Sep 28 · B"

               timing
             end)

    assert timing.name == "Pasted Sep 28 · A"
    assert timing.headsign == "Downtown"

    stored =
      Repo.all(
        from row in TimedPatternStop,
          join: occurrence in RoutePatternStop,
          on: occurrence.id == row.route_pattern_stop_id,
          where: row.timed_pattern_id == ^timing.id,
          order_by: occurrence.position,
          select: {row.arrival_offset, row.departure_offset, row.timepoint}
      )

    assert stored == [{-60, 0, 1}, {300, 360, 0}, {600, 660, 1}]

    assert Repo.aggregate(
             from(t in TimedPattern, where: t.route_pattern_id == ^pattern.id),
             :count
           ) == 2
  end

  test "the audit log entry exists for the created timing", context do
    pattern = create_pattern(context, ["A", "B"])

    assert {:ok, timing} =
             Repo.transaction(fn ->
               locked = lock_pattern(context, pattern)

               RoutePatterns.create_pasted_timing!(
                 locked,
                 "Pasted Sep 28 · A",
                 [
                   %{arrival_offset: -30, departure_offset: 0, timepoint: 1},
                   %{arrival_offset: 240, departure_offset: 300, timepoint: 1}
                 ],
                 nil,
                 context.audit
               )
             end)

    [log] =
      Repo.all(
        from log in ChangeLog,
          where:
            log.entity_type == "timed_pattern" and log.entity_id == ^timing.id and
              log.action == "created"
      )

    assert log.entity_external_id == "#{timing.id}:#{pattern.route_pattern_id}"
    assert log.changed_fields["before"] == nil
    assert log.changed_fields["after"]["name"] == "Pasted Sep 28 · A"
    assert length(log.changed_fields["after"]["rows"]) == 2
  end

  test "a row-count mismatch rolls back", context do
    pattern = create_pattern(context, ["A", "B", "C"])

    assert {:error, :timing_rows_mismatch} =
             Repo.transaction(fn ->
               locked = lock_pattern(context, pattern)

               RoutePatterns.create_pasted_timing!(
                 locked,
                 "Pasted Sep 28 · A",
                 [%{arrival_offset: 0, departure_offset: 0, timepoint: 1}],
                 nil,
                 context.audit
               )
             end)

    refute Repo.exists?(
             from t in TimedPattern,
               where: t.route_pattern_id == ^pattern.id and t.name == "Pasted Sep 28 · A"
           )

    refute Repo.exists?(
             from log in ChangeLog,
               where: log.entity_type == "timed_pattern"
           )
  end

  defp create_pattern(context, names) do
    stops =
      for name <- names,
          do: stop_fixture(context.organization.id, context.version.id, %{stop_name: name})

    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        %{route_pattern_name: "Service", direction_id: 0, stops: Enum.map(stops, & &1.stop_id)},
        context.audit
      )

    pattern
  end

  defp lock_pattern(context, pattern) do
    route = RoutePatterns.lock_published_route!(context.audit, context.route.route_id)
    RoutePatterns.lock_pattern!(route, pattern.id)
  end

  defp rows do
    [
      %{arrival_offset: -60, departure_offset: 0, timepoint: 1},
      %{arrival_offset: 300, departure_offset: 360, timepoint: 0},
      %{arrival_offset: 600, departure_offset: 660, timepoint: 1}
    ]
  end
end
