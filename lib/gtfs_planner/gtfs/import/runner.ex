defmodule GtfsPlanner.Gtfs.Import.Runner do
  @moduledoc """
  Short-lived, supervised owner for import and cleanup execution.

  A `Runner` is a temporary `GenServer` child under
  `GtfsPlanner.Gtfs.Import.RunnerSupervisor`. It is the durable-ownership
  boundary for a single claimed import or cleanup operation:

    * claims the operation in `init/1` through `ImportRuns`;
    * traps exits so an abnormal worker death arrives as a message, not a crash;
    * starts the injected worker as a linked task under `GtfsPlanner.TaskSupervisor`;
    * renews the database lease on a configurable timer;
    * terminates the linked worker when the lease is lost;
    * persists an unexpected closure as `interrupted`/`cleanup_failed` and
      broadcasts `{:import_run_changed, run_id}` only after the durable write.

  The child is `restart: :temporary`: replaying non-idempotent source writes is
  unsafe, so a dead runner is never auto-restarted (AC-7). PostgreSQL remains
  authoritative; the process is disposable and never makes source files durable.

  ## Worker contracts (forward contracts for steps 7/8)

    * import worker — default `GtfsPlanner.Gtfs.Import.Publication`.
      Invoked as `worker.run(run, lease_token, files, topic)` and returns
      `{:ok, version, result}` or `{:error, version, reason}`. It closes the
      run exclusively through `ImportRuns`.
    * cleanup worker — default `GtfsPlanner.Gtfs.Import.Recovery` (created in
      step 7). Invoked as `worker.run(organization_id, run_id, lease_token)`
      and closes the run through `ImportRuns.finish_cleanup/3` or
      `ImportRuns.fail_cleanup/4`.
  """

  use GenServer, restart: :temporary

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Failure}
  alias GtfsPlanner.Gtfs.ImportRuns

  @default_heartbeat_ms 60_000

  # --- public API -----------------------------------------------------------

  @doc """
  GenServer entry point used by the `DynamicSupervisor` child spec
  `{Runner, init_arg}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts a supervised runner that claims and executes an import for `run_id`
  using the supplied preparation `lease_token`, consuming `files`.

  The runner claims the import (pending -> running) itself in `init/1`. Returns
  the `DynamicSupervisor.on_start_child/0` result. On a claim failure the child
  stops without overwriting newer durable state.
  """
  @spec start_import(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), [map()]) ::
          DynamicSupervisor.on_start_child()
  def start_import(organization_id, run_id, lease_token, files) do
    DynamicSupervisor.start_child(
      runner_supervisor(),
      {__MODULE__,
       init_arg(:import, organization_id, run_id, lease_token: lease_token, files: files)}
    )
  end

  @doc """
  Starts a supervised runner that claims and executes cleanup for `run_id` on
  behalf of `actor`.

  The runner claims the cleanup (recoverable -> cleaning) itself in `init/1`,
  snapshotting the actor and receiving the cleanup lease token. Returns the
  `DynamicSupervisor.on_start_child/0` result. On a claim failure the child
  stops without overwriting newer durable state.
  """
  @spec start_cleanup(Ecto.UUID.t(), Ecto.UUID.t(), ImportRuns.actor()) ::
          DynamicSupervisor.on_start_child()
  def start_cleanup(organization_id, run_id, actor) do
    DynamicSupervisor.start_child(
      runner_supervisor(),
      {__MODULE__, init_arg(:cleanup, organization_id, run_id, actor: actor)}
    )
  end

  # --- callbacks ------------------------------------------------------------

  @impl true
  def init(opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    run_id = Keyword.fetch!(opts, :run_id)
    kind = Keyword.fetch!(opts, :kind)
    files = Keyword.get(opts, :files, [])

    case claim(kind, organization_id, run_id, opts) do
      {:ok, run, claimed_token} ->
        Process.flag(:trap_exit, true)

        worker = worker_module(kind, opts)
        heartbeat_ms = heartbeat_ms(opts)

        topic = ImportRuns.topic(run_id)
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

        task = start_linked_work(kind, worker, organization_id, run, claimed_token, files, topic)

        timer = schedule_lease_renew(heartbeat_ms)

        state = %{
          kind: kind,
          organization_id: organization_id,
          run_id: run_id,
          lease_token: claimed_token,
          worker: worker,
          task_pid: task.pid,
          topic: topic,
          active_phase: initial_phase(kind),
          heartbeat_ms: heartbeat_ms,
          timer: timer
        }

        {:ok, state}

      {:error, _reason} ->
        # Claim failed (lease_lost / not_found / invalid_transition /
        # already_claimed). Stop without overwriting newer durable state.
        {:stop, :claim_failed, nil}
    end
  end

  @impl true
  def handle_info(:renew_lease, state) do
    case ImportRuns.renew_lease(state.organization_id, state.run_id, state.lease_token) do
      :ok ->
        timer = schedule_lease_renew(state.heartbeat_ms)
        {:noreply, %{state | timer: timer}}

      {:error, :lease_lost} ->
        # Lease lost: terminate the linked worker and stop. The worker's
        # subsequent exit is trapped and handled (or it is already gone).
        terminate_worker(state)
        {:stop, :lease_lost, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, :normal}, %{task_pid: pid} = state) do
    # Normal worker completion: the worker already closed the run through
    # ImportRuns (Publication/Recovery). Broadcast and stop without a second
    # durable closure.
    broadcast_changed(state)
    cancel_timer(state)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{task_pid: pid} = state) do
    handle_worker_exit(reason, state)
  end

  def handle_info({:import_phase, phase}, %{kind: :import} = state)
      when phase in [:phase_1, :phase_2, :extensions, :publication] do
    {:noreply, %{state | active_phase: phase}}
  end

  # `Task.Supervisor.async` delivers the task's return value as `{ref, result}`
  # to the linked caller. The task is still linked, so its eventual exit (normal
  # or abnormal) is reported separately via `{:EXIT, pid, reason}`. Ignore the
  # result here; closure is driven by the EXIT message.
  def handle_info({_ref, _result}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    _ = msg
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state)
    :ok
  end

  # --- internal: claim ------------------------------------------------------

  defp claim(:import, organization_id, run_id, opts) do
    lease_token = Keyword.fetch!(opts, :lease_token)

    case ImportRuns.claim_import(organization_id, run_id, lease_token) do
      {:ok, run, _version, new_token} -> {:ok, run, new_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim(:cleanup, organization_id, run_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    case ImportRuns.claim_cleanup(organization_id, run_id, actor) do
      {:ok, run, _version, token} -> {:ok, run, token}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- internal: worker lifecycle -------------------------------------------

  defp start_linked_work(:import, worker, _organization_id, run, lease_token, files, topic) do
    task =
      Task.Supervisor.async(task_supervisor(), fn ->
        worker.run(run, lease_token, files, topic)
      end)

    %{pid: task.pid, ref: nil}
  end

  defp start_linked_work(:cleanup, worker, organization_id, run, lease_token, _files, _topic) do
    task =
      Task.Supervisor.async(task_supervisor(), fn ->
        worker.run(organization_id, run.id, lease_token)
      end)

    %{pid: task.pid, ref: nil}
  end

  defp terminate_worker(%{task_pid: pid, timer: timer} = _state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp cancel_timer(%{timer: timer}) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_state), do: :ok

  # --- internal: abnormal exit closure --------------------------------------

  defp handle_worker_exit(reason, state) do
    case persist_unexpected_exit(state, reason) do
      {:ok, _run, _version} -> broadcast_changed(state)
      {:ok, _run} -> broadcast_changed(state)
      {:error, _reason} -> :ok
    end

    cancel_timer(state)
    {:stop, {:worker_exit, reason}, state}
  end

  defp persist_unexpected_exit(%{kind: :import} = state, _reason) do
    failure =
      Failure.from_error(:executor_lost,
        phase: state.active_phase,
        outcome: :interrupted,
        counts_complete: false
      )

    ImportRuns.fail_import(state.organization_id, state.run_id, state.lease_token, failure)
  end

  defp persist_unexpected_exit(%{kind: :cleanup} = state, _reason) do
    ImportRuns.fail_cleanup(
      state.organization_id,
      state.run_id,
      state.lease_token,
      :executor_lost
    )
  end

  defp broadcast_changed(%{topic: topic, run_id: run_id}) do
    Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, topic, {:import_run_changed, run_id})
  end

  # --- internal: injected configuration -------------------------------------

  defp init_arg(kind, organization_id, run_id, opts) do
    [
      kind: kind,
      organization_id: organization_id,
      run_id: run_id,
      worker_module: Keyword.get(opts, :worker_module),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms)
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(
      case kind do
        :import -> [files: Keyword.get(opts, :files, [])]
        :cleanup -> []
      end
    )
  end

  defp worker_module(:import, opts) do
    case Keyword.get(opts, :worker_module) do
      nil -> Application.get_env(:gtfs_planner, :import_worker_module, Import.Publication)
      mod -> mod
    end
  end

  defp worker_module(:cleanup, opts) do
    case Keyword.get(opts, :worker_module) do
      nil -> Application.get_env(:gtfs_planner, :import_cleanup_worker_module, Import.Recovery)
      mod -> mod
    end
  end

  defp heartbeat_ms(opts) do
    case Keyword.get(opts, :heartbeat_ms) do
      nil ->
        Application.get_env(:gtfs_planner, :import_runner_heartbeat_ms, @default_heartbeat_ms)

      ms ->
        ms
    end
  end

  defp schedule_lease_renew(ms) do
    Process.send_after(self(), :renew_lease, ms)
  end

  defp initial_phase(:import), do: :phase_1
  defp initial_phase(:cleanup), do: :cleanup

  defp runner_supervisor, do: GtfsPlanner.Gtfs.Import.RunnerSupervisor
  defp task_supervisor, do: GtfsPlanner.TaskSupervisor
end
