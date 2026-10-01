defmodule GtfsPlanner.Gtfs.Import.Runner do
  @moduledoc """
  Short-lived, supervised owner for import and cleanup execution.

  A `Runner` is a temporary `GenServer` child under
  `GtfsPlanner.Gtfs.Import.RunnerSupervisor`. It is the durable-ownership
  boundary for a single claimed import or cleanup operation:

    * claims the operation in `init/1` through `ImportRuns`;
    * traps exits so an abnormal worker death arrives as a message, not a crash;
    * starts the injected worker as a linked task under `GtfsPlanner.TaskSupervisor`
      (an import starts it when its staged source is installed, see below);
    * renews the database lease on a configurable timer;
    * terminates the linked worker and broadcasts the change when the lease is lost;
    * persists an unexpected closure as `interrupted`/`cleanup_failed` and
      broadcasts `{:import_run_changed, run_id}` only after the durable write;
    * removes an import's staged source directory when it stops, whatever the outcome.

  ## Source handshake (imports)

  Admission and the claim come before any upload byte is read. `start_import/4` is
  refused at the supervisor's cap before `init/1` runs; once admitted, the runner
  claims the run and waits for the caller (the LiveView) to stage the upload and call
  `install_source/2`, which starts the worker. The runner closes the run as
  `source_not_installed`, removes the run's source directory and stops when
  `:import_source_install_timeout_ms` passes first, when the monitored caller exits
  first, or when the caller gives up with `cancel_source/1`. The lease keeps renewing
  while the runner waits.

  The child is `restart: :temporary`: replaying non-idempotent source writes is
  unsafe, so a dead runner is never auto-restarted (AC-7). PostgreSQL remains
  authoritative; the process is disposable and never makes source files durable.

  ## Worker contracts (forward contracts for steps 7/8)

    * import worker — default `GtfsPlanner.Gtfs.Import.Publication`.
      Invoked as `worker.run(run, lease_token, files, topic)` and returns
      `{:ok, version, result}` or `{:error, version, reason}`. `files` are the
      `%{filename, path}` descriptors of the run's staged source files
      (`GtfsPlanner.Gtfs.Import.SourceStorage`), never file contents, so the child
      spec, the task closure and the runner state stay small. The worker closes the
      run exclusively through `ImportRuns`.
    * cleanup worker — default `GtfsPlanner.Gtfs.Import.Recovery` (created in
      step 7). Invoked as `worker.run(organization_id, run_id, lease_token)`
      and closes the run through `ImportRuns.finish_cleanup/3` or
      `ImportRuns.fail_cleanup/4`.
  """

  use GenServer, restart: :temporary

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Failure, SourceStorage}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.RunnerAdmission

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
  Starts a supervised runner that claims `run_id` with the preparation `lease_token`
  and executes the import once its source is installed.

  The supervisor admits the child before `init/1` runs, so `{:error, :busy}` (the
  `:runner_limits` cap) means nothing was claimed and nothing was read: the run is
  still pending, and the caller closes it with `ImportRuns.fail_unstarted/3`. On any
  other claim failure the child stops without overwriting newer durable state.

  Options:

    * `:caller` - the process that stages the upload. The runner monitors it until the
      source is installed; its exit fails the run as `source_not_installed`.
    * `:files` - descriptors of a source that is already staged. The worker starts
      from `init/1` and no handshake takes place.

  Without `:files` the runner waits for `install_source/2` for
  `:import_source_install_timeout_ms`. It removes the staged files itself when it stops.
  """
  @spec start_import(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, :busy}
  def start_import(organization_id, run_id, lease_token, opts) when is_list(opts) do
    RunnerAdmission.start_child(
      runner_supervisor(),
      {__MODULE__,
       init_arg(:import, organization_id, run_id, Keyword.put(opts, :lease_token, lease_token))}
    )
  end

  @doc """
  Hands the staged `files` (descriptors from `SourceStorage.stage/4`) to a runner that
  is waiting for its source and starts the worker.

  Returns `{:error, :runner_stopped}` when the runner is gone, which happens after it
  closed the run as `source_not_installed`; the caller then removes the files it
  staged. A runner whose source is already installed answers
  `{:error, :not_awaiting_source}`.
  """
  @spec install_source(pid(), [map()]) :: :ok | {:error, :runner_stopped | :not_awaiting_source}
  def install_source(runner, files) when is_pid(runner) and is_list(files),
    do: call(runner, {:install_source, files})

  @doc """
  Tells a runner that is waiting for its source that none is coming (staging failed).

  The runner closes the run as `source_not_installed`, removes the run's source
  directory and stops, all before this returns. The error results are those of
  `install_source/2`.
  """
  @spec cancel_source(pid()) :: :ok | {:error, :runner_stopped | :not_awaiting_source}
  def cancel_source(runner) when is_pid(runner), do: call(runner, :cancel_source)

  @doc """
  Starts a supervised runner that claims and executes cleanup for `run_id` on
  behalf of `actor`.

  The runner claims the cleanup (recoverable -> cleaning) itself in `init/1`,
  snapshotting the actor and receiving the cleanup lease token. Returns the
  `DynamicSupervisor.on_start_child/0` result, or `{:error, :busy}` at the
  supervisor's cap, in which case the run is still recoverable and unchanged. On
  a claim failure the child stops without overwriting newer durable state.
  """
  @spec start_cleanup(Ecto.UUID.t(), Ecto.UUID.t(), ImportRuns.actor()) ::
          DynamicSupervisor.on_start_child() | {:error, :busy}
  def start_cleanup(organization_id, run_id, actor) do
    RunnerAdmission.start_child(
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

    case claim(kind, organization_id, run_id, opts) do
      {:ok, run, claimed_token} ->
        Process.flag(:trap_exit, true)

        heartbeat_ms = heartbeat_ms(opts)

        topic = ImportRuns.topic(run_id)
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

        state = %{
          kind: kind,
          organization_id: organization_id,
          run_id: run_id,
          run: run,
          lease_token: claimed_token,
          worker: worker_module(kind, opts),
          task_pid: nil,
          source_timer: nil,
          caller_ref: nil,
          topic: topic,
          active_phase: initial_phase(kind),
          heartbeat_ms: heartbeat_ms,
          timer: schedule_lease_renew(heartbeat_ms)
        }

        {:ok, begin_work(state, opts)}

      {:error, _reason} ->
        # Claim failed (lease_lost / not_found / invalid_transition /
        # already_claimed). Stop without overwriting newer durable state.
        {:stop, :claim_failed, nil}
    end
  end

  @impl true
  def handle_call({:install_source, files}, _from, %{kind: :import, task_pid: nil} = state) do
    {:reply, :ok, state |> stop_waiting_for_source() |> start_work(files)}
  end

  def handle_call(:cancel_source, _from, %{kind: :import, task_pid: nil} = state) do
    close_without_source(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_awaiting_source}, state}

  @impl true
  def handle_info(:renew_lease, state) do
    case ImportRuns.renew_lease(state.organization_id, state.run_id, state.lease_token) do
      :ok ->
        timer = schedule_lease_renew(state.heartbeat_ms)
        {:noreply, %{state | timer: timer}}

      {:error, :lease_lost} ->
        # Lease lost: terminate the linked worker and stop. The worker's
        # subsequent exit is trapped and handled (or it is already gone). The run
        # was changed by another writer, so subscribers reload it; when the writer
        # is this runner's own worker closing the run just before this tick, no
        # other process would announce the closure.
        terminate_worker(state)
        broadcast_changed(state)
        {:stop, :lease_lost, state}
    end
  end

  # Nobody installed the source in time, or the caller that was staging it exited first.
  # Both clauses act only while waiting: a message that arrives after installation is stale.
  def handle_info(:source_install_timeout, %{task_pid: nil} = state) do
    close_without_source(state)
    cancel_timer(state)
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{task_pid: nil, caller_ref: ref} = state
      ) do
    close_without_source(state)
    cancel_timer(state)
    {:stop, :normal, state}
  end

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
      when phase in [:phase_1, :phase_2, :derivation, :extensions, :publication] do
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
    remove_source(state)
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

  # A cleanup has no source to wait for, and an import given `:files` already has its source
  # staged. Any other import waits for `install_source/2`, with a deadline and a monitor on
  # the process that is staging the upload.
  defp begin_work(%{kind: :cleanup} = state, _opts), do: start_work(state, [])

  defp begin_work(%{kind: :import} = state, opts) do
    case Keyword.fetch(opts, :files) do
      {:ok, files} -> start_work(state, files)
      :error -> wait_for_source(state, Keyword.get(opts, :caller))
    end
  end

  defp wait_for_source(state, caller) do
    deadline = Process.send_after(self(), :source_install_timeout, source_install_timeout_ms())
    %{state | source_timer: deadline, caller_ref: caller && Process.monitor(caller)}
  end

  # The source arrived: the deadline and the caller monitor have done their job, and the caller
  # may now exit without taking the run down with it.
  defp stop_waiting_for_source(%{source_timer: source_timer, caller_ref: caller_ref} = state) do
    if is_reference(source_timer), do: Process.cancel_timer(source_timer)
    if is_reference(caller_ref), do: Process.demonitor(caller_ref, [:flush])
    %{state | source_timer: nil, caller_ref: nil}
  end

  defp start_work(state, files) do
    task =
      start_linked_work(
        state.kind,
        state.worker,
        state.organization_id,
        state.run,
        state.lease_token,
        files,
        state.topic
      )

    %{state | task_pid: task.pid}
  end

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

  # The source never arrived, so no worker started and nothing was imported: the run fails at
  # the upload phase and subscribers reload it. The directory goes first so the caller sees it
  # gone when this returns.
  defp close_without_source(state) do
    failure = Failure.from_error(:source_not_installed, phase: :upload)
    _ = ImportRuns.fail_import(state.organization_id, state.run_id, state.lease_token, failure)
    remove_source(state)
    broadcast_changed(state)
  end

  defp terminate_worker(%{task_pid: pid, timer: timer} = _state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp cancel_timer(%{timer: timer}) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_state), do: :ok

  # The staged files serve only this run's worker, which has exited or been killed by the
  # time the runner stops, so publish, failure, lease loss and shutdown all release them.
  # A failed removal is left to the orphan sweep in `TaskArtifactMaintenance`.
  defp remove_source(%{kind: :import, organization_id: organization_id, run_id: run_id}) do
    _ = SourceStorage.remove(organization_id, run_id)
    :ok
  end

  defp remove_source(_state), do: :ok

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

  # A runner that already stopped (deadline, caller exit, lease loss) cannot take the call.
  defp call(runner, request) do
    GenServer.call(runner, request)
  catch
    :exit, _reason -> {:error, :runner_stopped}
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

  defp source_install_timeout_ms,
    do: Application.fetch_env!(:gtfs_planner, :import_source_install_timeout_ms)

  defp schedule_lease_renew(ms) do
    Process.send_after(self(), :renew_lease, ms)
  end

  defp initial_phase(:import), do: :phase_1
  defp initial_phase(:cleanup), do: :cleanup

  defp runner_supervisor, do: GtfsPlanner.Gtfs.Import.RunnerSupervisor
  defp task_supervisor, do: GtfsPlanner.TaskSupervisor
end
