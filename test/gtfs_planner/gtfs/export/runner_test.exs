defmodule GtfsPlanner.Gtfs.Export.RunnerTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export.{Run, Runner}
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  defmodule WaitingWorker do
    def build(_run, _generation, _token, _topic) do
      receive do
        :finish -> :ok
        :die -> Process.exit(self(), :kill)
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "export-runner-#{System.unique_integer([:positive])}")
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if old_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, old_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    :ok
  end

  test "application-supervised runner reaches the concrete worker and durable ready artifact" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ExportRuns.topic(run))

    assert {:ok, runner} = Runner.start_build(organization.id, run.id)
    ref = Process.monitor(runner)
    assert_receive {:export_run_changed, _}
    assert_receive {:export_run_changed, _}
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
    assert %Run{state: :ready, artifact_size_bytes: size} = Repo.get!(Run, run.id)
    assert size > 0
  end

  test "initiator loss and worker crash close once without automatic replay" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    parent = self()

    initiator =
      spawn(fn ->
        {:ok, runner} =
          Runner.start_build(organization.id, run.id, WaitingWorker, heartbeat_ms: 60_000)

        send(parent, {:runner, runner})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:runner, runner}
    Process.exit(initiator, :kill)
    assert :sys.get_state(runner).run_id == run.id
    worker = :sys.get_state(runner).task_pid
    ref = Process.monitor(runner)
    send(worker, :die)
    assert_receive {:DOWN, ^ref, :process, ^runner, :worker_exit}
    assert %Run{state: :failed, failure_code: "executor_lost"} = Repo.get!(Run, run.id)
    assert DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Export.RunnerSupervisor) == []
  end

  test "duplicate start cannot claim or replay an active build" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    assert {:ok, runner} = Runner.start_build(organization.id, run.id, WaitingWorker)
    assert {:error, :claim_failed} = Runner.start_build(organization.id, run.id, WaitingWorker)

    assert {:ok, _} = ExportRuns.request_cancel(organization.id, run.id)
    worker = :sys.get_state(runner).task_pid
    ref = Process.monitor(runner)
    send(worker, :die)
    assert_receive {:DOWN, ^ref, :process, ^runner, :worker_exit}
    assert %Run{state: :cancelled} = Repo.get!(Run, run.id)
    assert DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Export.RunnerSupervisor) == []
  end
end
