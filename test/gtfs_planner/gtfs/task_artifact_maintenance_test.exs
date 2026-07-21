defmodule GtfsPlanner.Gtfs.TaskArtifactMaintenanceTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Import.{ChangeArtifactStorage, ChangeRun, ChangeRuns, ChangeWorker}
  alias GtfsPlanner.Gtfs.TaskArtifactMaintenance
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "maintenance@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "task-maintenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    :ok
  end

  test "reconciles expired import and export executors through one runtime owner" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    {:ok, change_run} =
      ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [])

    {:ok, _, _, _} = ChangeRuns.claim(organization.id, change_run.id, :compute)
    {:ok, export_run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _, _, _} = ExportRuns.claim(organization.id, export_run.id, :build)

    from(r in ChangeRun, where: r.id == ^change_run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    from(r in Run, where: r.id == ^export_run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    assert :ok = TaskArtifactMaintenance.maintain()
    assert Repo.get!(ChangeRun, change_run.id).state == :interrupted
    assert Repo.get!(Run, export_run.id).state == :interrupted
  end

  test "retains interrupted compute sources through maintenance so retry can finish" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    {:ok, manifest} =
      ChangeArtifactStorage.stage(organization.id, version.id, run_id, [
        %{
          filename: "stops.txt",
          content: "stop_id,stop_name,stop_lat,stop_lon\ncentral,Central,40.0,-70.0\n"
        }
      ])

    {:ok, run} =
      ChangeRuns.create_pending_compute(organization.id, version.id, @actor, manifest, run_id)

    {:ok, _, _, _} = ChangeRuns.claim(organization.id, run.id, :compute)

    from(r in ChangeRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    assert :ok = TaskArtifactMaintenance.maintain()
    assert Repo.get!(ChangeRun, run.id).state == :interrupted
    assert {:ok, pending} = ChangeRuns.retry(organization.id, run.id)
    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)
    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run))
    assert Repo.get!(ChangeRun, pending.id).state == :review
  end

  test "rejects compute retry after maintenance removes an expired source artifact" do
    previous_ttl = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds)

    previous_grace =
      Application.get_env(:gtfs_planner, :gtfs_task_artifacts_orphan_grace_seconds)

    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, 0)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_orphan_grace_seconds, 0)

    on_exit(fn ->
      Application.put_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, previous_ttl)

      if previous_grace,
        do:
          Application.put_env(
            :gtfs_planner,
            :gtfs_task_artifacts_orphan_grace_seconds,
            previous_grace
          ),
        else:
          Application.delete_env(
            :gtfs_planner,
            :gtfs_task_artifacts_orphan_grace_seconds
          )
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    {:ok, manifest} =
      ChangeArtifactStorage.stage(organization.id, version.id, run_id, [
        %{filename: "levels.txt", content: "level_id,level_index\nL1,1\n"}
      ])

    {:ok, run} =
      ChangeRuns.create_pending_compute(organization.id, version.id, @actor, manifest, run_id)

    {:ok, _claimed, generation, token} =
      ChangeRuns.claim(organization.id, run.id, :compute)

    assert {:ok, failed} =
             ChangeRuns.fail_compute(
               organization.id,
               run.id,
               generation,
               token,
               "compute_failed"
             )

    from(r in ChangeRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [finished_at: ~U[2000-01-01 00:00:00.000000Z]])

    assert :ok = TaskArtifactMaintenance.maintain()
    assert {:error, :missing_or_corrupt_artifact} = ChangeArtifactStorage.read(failed)
    assert {:error, :missing_or_corrupt_artifact} = ChangeRuns.retry(organization.id, run.id)
    assert Repo.get!(ChangeRun, run.id).state == :failed
  end

  test "serializes terminal retry with maintenance after its retained-run snapshot" do
    previous_ttl = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds)

    previous_grace =
      Application.get_env(:gtfs_planner, :gtfs_task_artifacts_orphan_grace_seconds)

    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, 0)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_orphan_grace_seconds, 0)

    on_exit(fn ->
      Application.put_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, previous_ttl)

      if previous_grace,
        do:
          Application.put_env(
            :gtfs_planner,
            :gtfs_task_artifacts_orphan_grace_seconds,
            previous_grace
          ),
        else:
          Application.delete_env(
            :gtfs_planner,
            :gtfs_task_artifacts_orphan_grace_seconds
          )
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    {:ok, manifest} =
      ChangeArtifactStorage.stage(organization.id, version.id, run_id, [
        %{filename: "levels.txt", content: "level_id,level_index\nL1,1\n"}
      ])

    {:ok, run} =
      ChangeRuns.create_pending_compute(organization.id, version.id, @actor, manifest, run_id)

    {:ok, _claimed, generation, token} =
      ChangeRuns.claim(organization.id, run.id, :compute)

    assert {:ok, _failed} =
             ChangeRuns.fail_compute(
               organization.id,
               run.id,
               generation,
               token,
               "compute_failed"
             )

    from(r in ChangeRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [finished_at: ~U[2000-01-01 00:00:00.000000Z]])

    parent = self()

    maintenance =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        TaskArtifactMaintenance.maintain(
          after_change_snapshot: fn ->
            send(parent, {:change_snapshot_taken, self()})

            receive do
              :continue_reconciliation -> :ok
            end
          end
        )
      end)

    assert_receive {:change_snapshot_taken, maintenance_pid}

    telemetry_handler = "retry-root-lock-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:gtfs_planner, :task_artifact_capacity, :lock_attempt],
        fn _event, _measurements, _metadata, destination ->
          send(destination, {:root_lock_attempted, self()})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    retry =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        send(parent, {:retry_started, self()})
        result = ChangeRuns.retry(organization.id, run.id)
        send(parent, {:retry_finished, self(), result})
        result
      end)

    assert_receive {:retry_started, retry_pid}
    assert_receive {:root_lock_attempted, ^retry_pid}
    refute_receive {:retry_finished, ^retry_pid, _result}, 100

    send(maintenance_pid, :continue_reconciliation)
    assert :ok = Task.await(maintenance)

    assert {:error, :missing_or_corrupt_artifact} = Task.await(retry)
    assert_receive {:retry_finished, ^retry_pid, {:error, :missing_or_corrupt_artifact}}
    assert Repo.get!(ChangeRun, run.id).state == :failed
  end

  test "does not delete a freshly staged directory before its run row is inserted" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    {:ok, manifest} =
      ChangeArtifactStorage.stage(organization.id, version.id, run_id, [
        %{filename: "levels.txt", content: "level_id,level_index\nL1,1\n"}
      ])

    assert :ok = TaskArtifactMaintenance.maintain()

    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               organization.id,
               version.id,
               @actor,
               manifest,
               run_id
             )

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)
    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run))
    assert Repo.get!(ChangeRun, run.id).state == :review
  end
end
