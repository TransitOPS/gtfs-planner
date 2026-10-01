defmodule GtfsPlanner.Gtfs.Export.ArtifactReconcileTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.TaskArtifactMaintenance
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "export-reconcile@example.com"}
  @one_hour 3600
  @receive_timeout 5_000

  setup do
    root =
      Path.join(System.tmp_dir!(), "artifact-reconcile-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    put_env(:gtfs_task_artifacts_path, root)
    put_env(:gtfs_task_artifacts_orphan_grace_seconds, 300)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{root: root, organization: organization, version: version}
  end

  test "removes an orphan run directory older than the orphan grace period", context do
    run_directory = publish_run_directory(context, Ecto.UUID.generate())
    age_directory(run_directory, @one_hour)

    assert :ok = TaskArtifactMaintenance.maintain()

    refute File.exists?(run_directory)
  end

  test "keeps an orphan run directory younger than the orphan grace period", context do
    run_directory = publish_run_directory(context, Ecto.UUID.generate())

    assert :ok = TaskArtifactMaintenance.maintain()

    assert File.dir?(run_directory)
  end

  test "keeps the directory of a retained run regardless of its age", context do
    {:ok, run} =
      ExportRuns.create_pending(context.organization.id, context.version.id, @actor, :full)

    run_directory = publish_run_directory(context, run.id)
    age_directory(run_directory, @one_hour)

    assert :ok = TaskArtifactMaintenance.maintain()

    assert File.dir?(run_directory)
  end

  test "keeps a run directory created after the retained-run snapshot", context do
    run_id = Ecto.UUID.generate()
    run_directory = run_directory(context, run_id)

    maintenance = start_maintenance_parked_after_snapshot()
    assert_receive {:export_snapshot_taken, maintenance_pid}, @receive_timeout

    File.mkdir_p!(run_directory)
    send(maintenance_pid, :continue_reconciliation)
    assert :ok = Task.await(maintenance)

    assert File.dir?(run_directory)
  end

  test "holds a publication until reconciliation releases the root lock", context do
    run_id = Ecto.UUID.generate()

    maintenance = start_maintenance_parked_after_snapshot()
    assert_receive {:export_snapshot_taken, maintenance_pid}, @receive_timeout
    attach_lock_attempt_telemetry()
    parent = self()

    publication =
      Task.async(fn ->
        send(parent, {:publication_started, self()})

        result =
          ArtifactStorage.publish(
            context.organization.id,
            context.version.id,
            run_id,
            "network.zip",
            "zip-bytes"
          )

        send(parent, {:publication_finished, self(), result})
        result
      end)

    assert_receive {:publication_started, publication_pid}, @receive_timeout
    assert_receive {:root_lock_attempted, ^publication_pid}, @receive_timeout
    refute_receive {:publication_finished, ^publication_pid, _result}, 100

    send(maintenance_pid, :continue_reconciliation)
    assert :ok = Task.await(maintenance)

    assert {:ok, artifact} = Task.await(publication)
    assert {:ok, _path} = ArtifactStorage.verify(artifact)
    assert File.dir?(run_directory(context, run_id))
  end

  defp start_maintenance_parked_after_snapshot do
    parent = self()

    Task.async(fn ->
      Sandbox.allow(Repo, parent, self())

      TaskArtifactMaintenance.maintain(
        after_export_snapshot: fn ->
          send(parent, {:export_snapshot_taken, self()})

          receive do
            :continue_reconciliation -> :ok
          end
        end
      )
    end)
  end

  defp attach_lock_attempt_telemetry do
    destination = self()
    handler_id = "artifact-reconcile-lock-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :task_artifact_capacity, :lock_attempt],
        fn _event, _measurements, _metadata, destination ->
          send(destination, {:root_lock_attempted, self()})
        end,
        destination
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp publish_run_directory(context, run_id) do
    {:ok, artifact} =
      ArtifactStorage.publish(
        context.organization.id,
        context.version.id,
        run_id,
        "network.zip",
        "zip-bytes"
      )

    Path.dirname(artifact.path)
  end

  defp run_directory(context, run_id) do
    Path.join([context.root, "export-runs", context.organization.id, context.version.id, run_id])
  end

  defp age_directory(path, seconds) do
    File.touch!(path, System.os_time(:second) - seconds)
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:gtfs_planner, key)
    Application.put_env(:gtfs_planner, key, value)
    on_exit(fn -> restore_env(key, previous) end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end
