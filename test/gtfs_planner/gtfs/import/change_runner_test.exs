defmodule GtfsPlanner.Gtfs.Import.ChangeRunnerTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import.{ChangeArtifactStorage, ChangeRun, ChangeRunner, ChangeRuns}
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "reviewer@example.com"}

  defmodule WaitingWorker do
    def compute(_run, _generation, _token, _topic) do
      receive do
        :finish -> :ok
        :die -> Process.exit(self(), :kill)
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "change-runner-#{System.unique_integer([:positive])}")
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if old_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, old_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    %{root: root}
  end

  test "supervisor runner reaches the concrete worker and persists a durable review", %{
    root: root
  } do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    {:ok, manifest} =
      ChangeArtifactStorage.stage(
        organization.id,
        version.id,
        run_id,
        [%{filename: "levels.txt", content: "level_id,level_index\nL1,1\n"}],
        root: root
      )

    {:ok, run} =
      ChangeRuns.create_pending_compute(organization.id, version.id, @actor, manifest, run_id)

    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(run))

    assert {:ok, runner} = ChangeRunner.start_compute(organization.id, run.id)
    ref = Process.monitor(runner)
    assert_receive {:change_run_changed, ^run_id}
    assert_receive {:change_run_changed, ^run_id}
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
    assert %ChangeRun{state: :review} = Repo.get!(ChangeRun, run.id)
  end

  test "a runner is independent of its initiator and abnormal executor loss is fenced closed" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [])
    parent = self()

    initiator =
      spawn(fn ->
        {:ok, runner} =
          ChangeRunner.start_compute(organization.id, run.id, WaitingWorker, heartbeat_ms: 60_000)

        send(parent, {:runner, runner})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:runner, runner}
    Process.exit(initiator, :kill)
    assert :sys.get_state(runner).run_id == run.id
    worker = :sys.get_state(runner).task_pid
    ref = Process.monitor(runner)
    send(worker, :die)
    assert_receive {:DOWN, ^ref, :process, ^runner, :worker_exit}

    assert %ChangeRun{state: :failed, failure_code: "executor_lost"} =
             Repo.get!(ChangeRun, run.id)
  end
end
