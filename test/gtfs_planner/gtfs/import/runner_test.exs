defmodule GtfsPlanner.Gtfs.Import.RunnerTest do
  @moduledoc """
  Supervised runner ownership: claim, lease heartbeat, linked-work monitoring,
  lease-loss cancellation, abnormal-exit closure, stale-token shutdown, and
  temporary (non-restarting) supervision.

  Uses the application `RunnerSupervisor`, `:sys.get_state/1`,
  `Process.monitor/1`, and explicit messages.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Import.Runner
  alias GtfsPlanner.Gtfs.Import.RunnerSupervisor
  alias GtfsPlanner.Repo

  import Ecto.Query

  import GtfsPlanner.OrganizationsFixtures

  # Creating a target and claiming a cleanup reauthorize their actor, so the actor is a real
  # active editor of the organization.
  defp editor_actor(org) do
    editor = editor_fixture(org)
    %{id: editor.id, email: editor.email}
  end

  # Fake import worker: waits for a control message from the test, then either
  # completes (`:complete`) or dies abnormally (`:die`). It never touches the DB.
  defmodule FakeImportWorker do
    def run(_run, _token, _files, topic) do
      receive do
        :complete ->
          {:ok, nil, :ok}

        :die ->
          Process.exit(self(), :kill)

        {:phase, phase, caller} ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, topic, {:import_phase, phase})
          send(caller, {:phase_reported, phase})
          run(nil, nil, nil, topic)
      after
        10_000 -> {:ok, nil, :ok}
      end
    end
  end

  # Fake cleanup worker: same control protocol, signature
  # `run(organization_id, run_id, lease_token)`.
  defmodule FakeCleanupWorker do
    def run(_organization_id, _run_id, _token) do
      receive do
        :complete -> :ok
        :die -> Process.exit(self(), :kill)
      after
        10_000 -> :ok
      end
    end
  end

  setup do
    # Inject the fake workers and a very long heartbeat so manual `:renew_lease`
    # ticks drive the renewal assertions. Restore on exit.
    original_import = Application.get_env(:gtfs_planner, :import_worker_module)
    original_cleanup = Application.get_env(:gtfs_planner, :import_cleanup_worker_module)
    original_heartbeat = Application.get_env(:gtfs_planner, :import_runner_heartbeat_ms)

    Application.put_env(:gtfs_planner, :import_worker_module, FakeImportWorker)
    Application.put_env(:gtfs_planner, :import_cleanup_worker_module, FakeCleanupWorker)
    Application.put_env(:gtfs_planner, :import_runner_heartbeat_ms, 60_000)

    on_exit(fn ->
      Application.put_env(:gtfs_planner, :import_worker_module, original_import)
      Application.put_env(:gtfs_planner, :import_cleanup_worker_module, original_cleanup)
      Application.put_env(:gtfs_planner, :import_runner_heartbeat_ms, original_heartbeat)
    end)

    :ok
  end

  defp allow_repo(pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
  end

  defp set_run_lease_expiry(run, expiry) do
    from(r in Run, where: r.id == ^run.id) |> Repo.update_all(set: [lease_expires_at: expiry])
  end

  # --- AC-6: disconnect independence ----------------------------------------

  test "start_import/4 claims in init/1 and survives initiating-process death" do
    org = organization_fixture()

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(org.id, editor_actor(org), %{name: "Feed"})

    parent = self()

    # Spawn the runner from a throwaway process so killing it does not stop the
    # supervised runner (children of RunnerSupervisor, not of the spawner).
    spawner =
      spawn(fn ->
        {:ok, pid} = Runner.start_import(org.id, run.id, run.lease_token, files: [])
        allow_repo(pid)
        send(parent, {:runner, pid})
        # Stay alive until the parent signals shutdown.
        receive do
          :done -> :ok
        end
      end)

    runner_pid =
      receive do
        {:runner, pid} -> pid
      after
        5_000 -> flunk("runner did not start")
      end

    # The run was claimed: pending -> running.
    assert Repo.get!(Run, run.id).state == "running"

    # Killing the initiating process must NOT stop the runner.
    Process.exit(spawner, :kill)

    # Wait until the spawner is down, then assert the runner is still alive.
    ref = Process.monitor(spawner)
    assert_receive {:DOWN, ^ref, :process, ^spawner, _}

    # :sys.get_state raises if the process is dead, so this asserts liveness.
    state = :sys.get_state(runner_pid)
    assert state.run_id == run.id
    assert state.kind == :import

    # Clean up the still-running runner.
    ref2 = Process.monitor(runner_pid)
    Process.exit(runner_pid, :kill)
    assert_receive {:DOWN, ^ref2, :process, ^runner_pid, _}
  end

  # --- AC-8: lease heartbeat + lease-loss cancellation -----------------------

  test "renews its lease on tick and terminates linked work after lease loss" do
    org = organization_fixture()

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(org.id, editor_actor(org), %{name: "Feed"})

    {:ok, runner_pid} = Runner.start_import(org.id, run.id, run.lease_token, files: [])
    allow_repo(runner_pid)

    state = :sys.get_state(runner_pid)
    worker_pid = state.task_pid
    worker_ref = Process.monitor(worker_pid)

    # Record the lease expiry, send a manual renewal tick, and confirm it moved.
    before = Repo.get!(Run, run.id).lease_expires_at
    previous_expiry = DateTime.add(before, -1, :second)
    set_run_lease_expiry(run, previous_expiry)
    send(runner_pid, :renew_lease)
    # Synchronize: the tick is handled synchronously and updates the row.
    assert :sys.get_state(runner_pid).run_id == run.id
    after_ = Repo.get!(Run, run.id).lease_expires_at
    assert DateTime.compare(after_, previous_expiry) == :gt

    # Expire the lease in the database, then send another renewal tick. The runner
    # must terminate the linked worker, tell subscribers the run changed, and stop.
    set_run_lease_expiry(run, ~U[2000-01-01 00:00:00.000000Z])
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))

    ref = Process.monitor(runner_pid)
    send(runner_pid, :renew_lease)
    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :lease_lost}
    run_id = run.id
    assert_received {:import_run_changed, ^run_id}

    # The linked worker was killed.
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}
    # The runner did not write a second closure (still running, lease cleared by reconcile only).
    assert Repo.get!(Run, run.id).state == "running"
  end

  # --- AC-33: cleanup lease renewal ------------------------------------------

  test "a cleanup runner renews its lease on every heartbeat and the run stays cleaning" do
    org = organization_fixture()
    actor = editor_actor(org)

    {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, actor, %{name: "Feed"})

    set_run_lease_expiry(run, ~U[2000-01-01 00:00:00.000000Z])
    [_reconciled] = ImportRuns.reconcile_expired(org.id)

    # The suite's setup restores the heartbeat after the test.
    Application.put_env(:gtfs_planner, :import_runner_heartbeat_ms, 50)

    {:ok, runner_pid} = Runner.start_cleanup(org.id, run.id, actor)
    allow_repo(runner_pid)

    runner_ref = Process.monitor(runner_pid)
    worker_pid = :sys.get_state(runner_pid).task_pid

    # Trace the runner's receives so the test counts heartbeats instead of sleeping.
    1 = :erlang.trace(runner_pid, true, [:receive])
    assert_receive {:trace, ^runner_pid, :receive, :renew_lease}, 5_000
    assert_receive {:trace, ^runner_pid, :receive, :renew_lease}, 5_000

    # The state call queues behind the second heartbeat, so the runner handled it.
    state = :sys.get_state(runner_pid)
    refute_received {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}
    assert state.kind == :cleanup
    assert Repo.get!(Run, run.id).state == "cleaning"

    send(worker_pid, :complete)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}
  end

  # --- AC-7/AC-11: abnormal worker exit closure + temporary non-restart ------

  test "an abnormal import worker exit is persisted as interrupted and broadcast" do
    org = organization_fixture()

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(org.id, editor_actor(org), %{name: "Feed"})

    {:ok, runner_pid} = Runner.start_import(org.id, run.id, run.lease_token, files: [])
    allow_repo(runner_pid)

    state = :sys.get_state(runner_pid)
    worker_pid = state.task_pid

    topic = ImportRuns.topic(run.id)
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

    runner_ref = Process.monitor(runner_pid)

    send(worker_pid, {:phase, :extensions, self()})
    assert_receive {:phase_reported, :extensions}
    assert :sys.get_state(runner_pid).active_phase == :extensions

    # Trigger an abnormal (killed) worker exit.
    send(worker_pid, :die)

    # The interruption is broadcast before the runner stops; the wait matches the
    # explicit waits this file uses elsewhere, so a loaded host cannot turn an
    # arriving message into a missing one.
    assert_receive {:import_run_changed, _}, 5_000
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, {:worker_exit, :killed}}

    run_after = Repo.get!(Run, run.id)
    assert run_after.state == "interrupted"
    assert run_after.counts_complete == false
    assert run_after.reason_code == "executor_lost"
    assert run_after.phase == "extensions"

    # The child is temporary: it is gone and not respawned.
    assert DynamicSupervisor.count_children(RunnerSupervisor).active == 0
  end

  test "an abnormal cleanup worker exit is persisted as cleanup_failed and broadcast" do
    org = organization_fixture()

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(org.id, editor_actor(org), %{name: "Feed"})

    # Move the run into a recoverable state: expire its pending lease and
    # reconcile (pending -> interrupted), which is eligible for cleanup claim.
    set_run_lease_expiry(run, ~U[2000-01-01 00:00:00.000000Z])
    [_reconciled] = ImportRuns.reconcile_expired(org.id)
    assert Repo.get!(Run, run.id).state == "interrupted"

    # The runner claims cleanup itself in init/1 (snapshotting the actor).
    {:ok, runner_pid} = Runner.start_cleanup(org.id, run.id, editor_actor(org))
    allow_repo(runner_pid)

    state = :sys.get_state(runner_pid)
    worker_pid = state.task_pid

    topic = ImportRuns.topic(run.id)
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

    runner_ref = Process.monitor(runner_pid)

    send(worker_pid, :die)

    assert_receive {:import_run_changed, _}
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, {:worker_exit, :killed}}

    run_after = Repo.get!(Run, run.id)
    assert run_after.state == "cleanup_failed"
    assert run_after.reason_code == "executor_lost"

    assert DynamicSupervisor.count_children(RunnerSupervisor).active == 0
  end

  test "an abnormal worker exit after lease loss does not broadcast an unpersisted closure" do
    org = organization_fixture()

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(org.id, editor_actor(org), %{name: "Feed"})

    {:ok, runner_pid} = Runner.start_import(org.id, run.id, run.lease_token, files: [])
    allow_repo(runner_pid)

    state = :sys.get_state(runner_pid)
    worker_pid = state.task_pid

    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))

    run_id = run.id
    replacement_token = Ecto.UUID.generate()

    {1, nil} =
      from(r in Run, where: r.id == ^run.id)
      |> Repo.update_all(set: [lease_token: replacement_token])

    runner_ref = Process.monitor(runner_pid)
    send(worker_pid, :die)

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, {:worker_exit, :killed}}
    refute_receive {:import_run_changed, ^run_id}, 100

    persisted = Repo.get!(Run, run.id)
    assert persisted.state == "running"
    assert persisted.lease_token == replacement_token
  end

  # --- AC-8: stale-token shutdown without overwriting newer state -----------

  test "a stale/wrong-token runner shuts down without overwriting state" do
    org = organization_fixture()

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(org.id, editor_actor(org), %{name: "Feed"})

    # Start a runner with a WRONG token. init/1 must fail the claim and stop
    # without writing. A failed init returns an error tuple from start_child.
    assert {:error, {:bad_return_value, {:stop, :claim_failed, nil}}} =
             Runner.start_import(org.id, run.id, Ecto.UUID.generate(), files: [])

    reloaded = Repo.get!(Run, run.id)
    assert reloaded.state == "pending"
    assert reloaded.lease_token == run.lease_token

    assert DynamicSupervisor.count_children(RunnerSupervisor).active == 0
  end

  # --- normal completion: broadcast only, no second closure -----------------

  test "normal import worker completion broadcasts without a second closure" do
    org = organization_fixture()

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(org.id, editor_actor(org), %{name: "Feed"})

    {:ok, runner_pid} = Runner.start_import(org.id, run.id, run.lease_token, files: [])
    allow_repo(runner_pid)

    state = :sys.get_state(runner_pid)
    worker_pid = state.task_pid

    topic = ImportRuns.topic(run.id)
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

    runner_ref = Process.monitor(runner_pid)

    send(worker_pid, :complete)

    assert_receive {:import_run_changed, _}

    # The run remains in the state set by the fake worker's no-op return
    # (running — the fake does not close it; the real Publication closes it).
    # The runner must not write a second closure.
    assert Repo.get!(Run, run.id).state == "running"

    # The linked (now completed) task is dead and the runner stopped cleanly.
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}
    assert DynamicSupervisor.count_children(RunnerSupervisor).active == 0
  end
end
