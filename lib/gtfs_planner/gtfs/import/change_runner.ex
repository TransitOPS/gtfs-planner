defmodule GtfsPlanner.Gtfs.Import.ChangeRunner do
  @moduledoc "Temporary, fenced owner for durable change-review computation."

  use GenServer, restart: :temporary

  alias GtfsPlanner.Gtfs.Import.{ChangeRun, ChangeRuns, ChangeWorker}

  @default_heartbeat_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec start_compute(Ecto.UUID.t(), Ecto.UUID.t(), module(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_compute(organization_id, run_id, worker_module \\ ChangeWorker, opts \\ []) do
    DynamicSupervisor.start_child(
      GtfsPlanner.Gtfs.Import.ChangeRunnerSupervisor,
      {__MODULE__,
       Keyword.merge(opts,
         organization_id: organization_id,
         run_id: run_id,
         worker_module: worker_module
       )}
    )
  end

  @impl true
  def init(opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    run_id = Keyword.fetch!(opts, :run_id)

    case ChangeRuns.claim(organization_id, run_id, :compute) do
      {:ok, %ChangeRun{} = run, generation, token} ->
        Process.flag(:trap_exit, true)
        worker = Keyword.get(opts, :worker_module, ChangeWorker)

        task =
          Task.Supervisor.async(GtfsPlanner.TaskSupervisor, fn ->
            worker.compute(run, generation, token, ChangeRuns.topic(run))
          end)

        heartbeat_ms = Keyword.get(opts, :heartbeat_ms, @default_heartbeat_ms)

        {:ok,
         %{
           organization_id: organization_id,
           run_id: run_id,
           generation: generation,
           token: token,
           task_pid: task.pid,
           task_ref: task.ref,
           heartbeat_ms: heartbeat_ms,
           timer: Process.send_after(self(), :renew_lease, heartbeat_ms)
         }}

      {:error, _reason} ->
        {:stop, :claim_failed}
    end
  end

  @impl true
  def handle_info(:renew_lease, state) do
    case ChangeRuns.renew_lease(
           state.organization_id,
           state.run_id,
           state.generation,
           state.token
         ) do
      :ok ->
        {:noreply, %{state | timer: Process.send_after(self(), :renew_lease, state.heartbeat_ms)}}

      {:error, :lease_lost} ->
        Process.exit(state.task_pid, :kill)
        {:stop, :lease_lost, state}
    end
  end

  def handle_info({ref, :ok}, %{task_ref: ref} = state), do: {:noreply, state}

  def handle_info({:EXIT, pid, :normal}, %{task_pid: pid} = state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _reason}, %{task_pid: pid} = state) do
    _ =
      ChangeRuns.fail_compute(
        state.organization_id,
        state.run_id,
        state.generation,
        state.token,
        "executor_lost"
      )

    {:stop, :worker_exit, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    :ok
  end
end
