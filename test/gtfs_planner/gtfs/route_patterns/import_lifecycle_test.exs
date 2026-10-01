defmodule GtfsPlanner.Gtfs.RoutePatterns.ImportLifecycleTest do
  @moduledoc """
  Derivation inside the real import lifecycle: a full Runner/Publication import,
  a non-fatal route-local derivation failure with manual retry, and cleanup
  ownership of the app-owned pattern tables after a failure following derivation.

  The supplied-identity oracle is the pinned MBTA-shaped subset under
  `test/fixtures/gtfs/route_patterns/`; every other expected value is authored in
  the fixtures below. No production function computes an expected value.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Failure, Publication, Recovery, Run, Runner}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.TaskSupervisor
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  alias Ecto.Adapters.SQL.Sandbox

  @fixture_dir Path.expand("../../../fixtures/gtfs/route_patterns", __DIR__)

  @routes """
  route_id,route_type,route_short_name,route_long_name
  Red,3,1,Red Line
  Blue,3,2,Blue Line
  """

  @stops """
  stop_id,stop_name,stop_lat,stop_lon,location_type,wheelchair_boarding
  A,Alpha,40.0,-75.0,0,0
  B,Beta,40.1,-75.1,0,0
  C,Gamma,40.2,-75.2,0,0
  """

  @trips """
  trip_id,route_id,service_id,direction_id,trip_headsign,route_pattern_id
  Red-1-0-t1,Red,WK,0,Ashmont,Red-1-0
  T-red-ok,Red,WK,0,Ashmont,Red-1-0
  T-red-dangling,Red,WK,0,Ashmont,Ghost-9-0
  T-red-derived-1,Red,WK,1,Alewife,
  T-red-derived-2,Red,WK,1,Alewife,
  Blue-2-0-t1,Blue,WK,0,Bowdoin,Blue-2-0
  T-blue-ok,Blue,WK,0,Bowdoin,Blue-2-0
  """

  @stop_times """
  trip_id,stop_id,stop_sequence,arrival_time,departure_time
  Red-1-0-t1,A,1,08:00:00,08:00:00
  Red-1-0-t1,B,2,08:05:00,08:05:00
  Red-1-0-t1,C,3,08:10:00,08:10:00
  T-red-ok,A,1,09:00:00,09:00:00
  T-red-ok,B,2,09:05:00,09:05:00
  T-red-ok,C,3,09:10:00,09:10:00
  T-red-dangling,A,1,10:00:00,10:00:00
  T-red-dangling,B,2,10:05:00,10:05:00
  T-red-derived-1,A,10,11:00:00,11:00:00
  T-red-derived-1,B,20,11:05:00,11:05:00
  T-red-derived-2,A,10,12:00:00,12:00:00
  T-red-derived-2,B,20,12:05:00,12:05:00
  Blue-2-0-t1,A,1,07:00:00,07:00:00
  Blue-2-0-t1,B,2,07:10:00,07:10:00
  T-blue-ok,A,1,06:00:00,06:00:00
  T-blue-ok,B,2,06:10:00,06:10:00
  """

  setup do
    Application.delete_env(:gtfs_planner, :route_pattern_derivation_inject_failure)

    on_exit(fn ->
      Application.delete_env(:gtfs_planner, :route_pattern_derivation_inject_failure)
    end)

    organization =
      organization_fixture(%{alias: "route-pattern-import-#{System.system_time(:nanosecond)}"})

    # Creating a target, publishing and claiming a cleanup reauthorize the actor, so the actor is
    # an active editor.
    actor = editor_fixture(organization)

    %{organization: organization, actor: actor}
  end

  test "a real Runner/Publication import derives patterns and publishes the version", context do
    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(
        context.organization.id,
        %{
          id: context.actor.id,
          email: context.actor.email
        },
        %{name: "Derivation Feed"}
      )

    {:ok, runner_pid} =
      Runner.start_import(
        context.organization.id,
        run.id,
        run.lease_token,
        files: StagedImport.stage(feed())
      )

    refute runner_pid == self()
    Sandbox.allow(Repo, self(), runner_pid)

    await_runner(runner_pid)

    assert Repo.get!(Run, run.id).state == "published"

    version = Repo.get!(GtfsVersion, run.gtfs_version_id)
    assert version.publication_status == "published"
    assert Versions.published_gtfs_version_for_org?(context.organization.id, version.id)

    counts = Repo.get!(Run, run.id).committed_counts
    assert counts["routes"] == 2
    assert counts["stops"] == 3
    assert counts["trips"] == 7
    assert counts["stop_times"] == 16
    assert counts["route_patterns"] == 3
    assert counts["patterns_created"] == 1
    assert counts["timings_created"] == 3
    assert counts["trips_linked"] == 6
    assert counts["trips_custom"] == 1

    # Supplied identities are preserved verbatim and their occurrence lists come
    # from the pinned representative trips.
    supplied = pattern(context, version.id, "Red-1-0")

    assert Enum.map(occurrences(supplied.id), &{&1.position, &1.stop_id}) == [
             {1, "A"},
             {2, "B"},
             {3, "C"}
           ]

    assert linked_trip(context, version.id, "T-red-ok").route_pattern_id == "Red-1-0"

    assert linked_trip(context, version.id, "T-red-ok").timed_pattern_id ==
             linked_trip(context, version.id, "Red-1-0-t1").timed_pattern_id

    blue = pattern(context, version.id, "Blue-2-0")
    assert Enum.map(occurrences(blue.id), &{&1.position, &1.stop_id}) == [{1, "A"}, {2, "B"}]
    assert linked_trip(context, version.id, "T-blue-ok").route_pattern_id == "Blue-2-0"

    dangling = Repo.get_by!(Trip, trip_id: "T-red-dangling", gtfs_version_id: version.id)
    assert dangling.pattern_derivation_state == "custom"
    assert dangling.pattern_derivation_reason == "missing_pattern"
    assert is_nil(dangling.timed_pattern_id)

    derived = Enum.find(patterns(context, version.id, "Red"), &(&1.direction_id == 1))
    assert Enum.map(occurrences(derived.id), &{&1.position, &1.stop_id}) == [{1, "A"}, {2, "B"}]
    assert derived.route_pattern_name == "Alpha – Beta"

    assert Enum.all?(
             ["T-red-derived-1", "T-red-derived-2"],
             &(linked_trip(context, version.id, &1).route_pattern_id == derived.route_pattern_id)
           )
  end

  test "a route-local derivation failure is non-fatal and a manual retry finishes it", context do
    {:ok, %{run: run, version: _version}} =
      ImportRuns.create_pending_target(
        context.organization.id,
        %{
          id: context.actor.id,
          email: context.actor.email
        },
        %{name: "Retry Feed"}
      )

    {:ok, claimed, _version, token} =
      ImportRuns.claim_import(context.organization.id, run.id, run.lease_token)

    Application.put_env(:gtfs_planner, :route_pattern_derivation_inject_failure, "Blue")

    assert {:ok, published, result} =
             Publication.run(
               claimed,
               token,
               StagedImport.stage(feed()),
               "import:derivation-retry"
             )

    assert published.publication_status == "published"
    assert Import.Result.publishable?(result)
    assert result.counts.patterns_created == 1
    assert result.counts.timings_created == 2
    assert result.counts.trips_linked == 4
    assert result.counts.trips_custom == 1

    blue_route =
      Repo.get_by!(Route,
        route_id: "Blue",
        organization_id: context.organization.id,
        gtfs_version_id: published.id
      )

    assert blue_route.pattern_derivation_error == "injected_derivation_failure"
    assert occurrences(pattern(context, published.id, "Blue-2-0").id) == []

    assert Repo.get_by!(Trip, trip_id: "T-blue-ok", gtfs_version_id: published.id).pattern_derivation_state ==
             "pending"

    Application.delete_env(:gtfs_planner, :route_pattern_derivation_inject_failure)

    audit = %AuditContext{
      organization_id: context.organization.id,
      gtfs_version_id: published.id,
      actor_id: context.actor.id,
      actor_email: context.actor.email
    }

    assert {:ok, retry_summary} = Gtfs.build_route_patterns("Blue", audit)

    assert retry_summary == %{
             patterns_created: 0,
             timings_created: 1,
             trips_linked: 2,
             trips_custom: 0
           }

    assert is_nil(Repo.get!(Route, blue_route.id).pattern_derivation_error)

    assert Repo.get_by!(Trip, trip_id: "T-blue-ok", gtfs_version_id: published.id).pattern_derivation_state ==
             "linked"

    assert length(patterns(context, published.id, "Blue")) == 1

    [build_log] =
      Repo.all(
        from(log in ChangeLog,
          where: log.entity_type == "route_pattern_build" and log.entity_id == ^blue_route.id
        )
      )

    assert build_log.action == "updated"
    assert build_log.actor_id == context.actor.id
    assert build_log.changed_fields["before"] == %{"pending" => 2, "custom" => 0, "linked" => 0}
    assert build_log.changed_fields["after"] == %{"pending" => 0, "custom" => 0, "linked" => 2}

    assert {:error, :nothing_pending} = Gtfs.build_route_patterns("Blue", audit)
  end

  test "cleanup after a failure following derivation removes every owned pattern table",
       context do
    {:ok, %{run: run, version: _version}} =
      ImportRuns.create_pending_target(
        context.organization.id,
        %{
          id: context.actor.id,
          email: context.actor.email
        },
        %{name: "Cleanup Feed"}
      )

    {:ok, claimed, _version, token} =
      ImportRuns.claim_import(context.organization.id, run.id, run.lease_token)

    files =
      feed() ++
        [
          %{
            filename: "_pathways_extensions.json",
            content:
              Jason.encode!(%{
                version: 1,
                exported_at: "2026-02-25T00:00:00Z",
                route_active_flags: [%{route_id: "NOPE", active: true}]
              })
          }
        ]

    assert {:error, failed_version, %Failure{} = failure} =
             Publication.run(
               claimed,
               token,
               StagedImport.stage(files),
               "import:derivation-cleanup"
             )

    assert failure.phase == :extensions
    assert failed_version.publication_status == "failed"

    # Derivation ran and committed before the extension phase failed.
    assert Repo.aggregate(
             from(p in RoutePattern, where: p.gtfs_version_id == ^failed_version.id),
             :count
           ) > 0

    assert Repo.aggregate(
             from(r in TimedPatternStop,
               join: t in TimedPattern,
               on: t.id == r.timed_pattern_id,
               where: t.gtfs_version_id == ^failed_version.id
             ),
             :count
           ) > 0

    # An unrelated version keeps its pattern rows through the cleanup.
    other = gtfs_version_fixture(context.organization.id)
    other_pattern = route_pattern_fixture(context.organization.id, other.id)
    other_occurrence = route_pattern_stop_fixture(other_pattern, "A", 1)
    other_timing = timed_pattern_fixture(other_pattern)
    other_row = timed_pattern_stop_fixture(other_timing, other_occurrence)

    {:ok, _, cleanup_version, cleanup_token} =
      ImportRuns.claim_cleanup(context.organization.id, run.id, %{
        id: context.actor.id,
        email: context.actor.email
      })

    assert {:ok, nil} = Recovery.discard_claimed(claimed, cleanup_version, cleanup_token)

    assert Repo.aggregate(
             from(p in RoutePattern, where: p.gtfs_version_id == ^failed_version.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(p in RoutePatternStop, where: p.gtfs_version_id == ^failed_version.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(p in TimedPattern, where: p.gtfs_version_id == ^failed_version.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(r in TimedPatternStop,
               join: t in TimedPattern,
               on: t.id == r.timed_pattern_id,
               where: t.gtfs_version_id == ^failed_version.id
             ),
             :count
           ) == 0

    assert Repo.get!(Run, run.id).state == "cleaned"
    assert is_nil(Repo.get(GtfsVersion, failed_version.id))

    # Parent-join scoping left the unrelated version's pattern rows untouched.
    assert Repo.get!(RoutePattern, other_pattern.id)
    assert Repo.get!(RoutePatternStop, other_occurrence.id)
    assert Repo.get!(TimedPatternStop, other_row.id)

    assert Repo.aggregate(
             from(r in TimedPatternStop,
               join: t in TimedPattern,
               on: t.id == r.timed_pattern_id,
               where: t.gtfs_version_id == ^other.id
             ),
             :count
           ) == 1
  end

  # --- helpers --------------------------------------------------------------

  defp feed do
    [
      %{filename: "routes.txt", content: @routes},
      %{filename: "stops.txt", content: @stops},
      %{filename: "trips.txt", content: @trips},
      %{filename: "stop_times.txt", content: @stop_times},
      %{filename: "route_patterns.txt", content: pinned_patterns()}
    ]
  end

  defp pinned_patterns do
    path = Path.join(@fixture_dir, "mbta_route_patterns_subset.txt")
    content = File.read!(path)
    metadata = @fixture_dir |> Path.join("source.json") |> File.read!() |> Jason.decode!()

    assert Base.encode16(:crypto.hash(:sha256, content), case: :lower) == metadata["sha256"]
    content
  end

  defp await_runner(runner_pid) do
    for pid <- Task.Supervisor.children(TaskSupervisor) do
      Sandbox.allow(Repo, self(), pid)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 30_000
    end

    runner_ref = Process.monitor(runner_pid)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 30_000
  end

  defp pattern(context, version_id, natural_id) do
    Repo.get_by!(RoutePattern,
      organization_id: context.organization.id,
      gtfs_version_id: version_id,
      route_pattern_id: natural_id
    )
  end

  defp patterns(context, version_id, route_id) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^context.organization.id and p.gtfs_version_id == ^version_id and
          p.route_id == ^route_id,
      order_by: [asc: p.direction_id, asc: p.route_pattern_id]
    )
    |> Repo.all()
  end

  defp occurrences(pattern_id) do
    from(o in RoutePatternStop,
      where: o.route_pattern_id == ^pattern_id,
      order_by: [asc: o.position]
    )
    |> Repo.all()
  end

  defp linked_trip(context, version_id, trip_id) do
    trip =
      Repo.get_by!(Trip,
        trip_id: trip_id,
        organization_id: context.organization.id,
        gtfs_version_id: version_id
      )

    assert trip.pattern_derivation_state == "linked"
    trip
  end
end
