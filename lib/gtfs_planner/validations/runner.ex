defmodule GtfsPlanner.Validations.Runner do
  @moduledoc """
  Temporary supervised owner of one MobilityData validation run.

  `init/1` claims the run and starts the configured validator module's
  `validate/3` in a task under `GtfsPlanner.TaskSupervisor`. The runner renews
  the run's lease every `:validation_runner_heartbeat_ms` (default 60,000) and is
  the only writer of the run's terminal state:

    * `{:ok, result}` completes the run.
    * `{:error, reason}` fails it with a short reason (`"timeout"`, `"cancelled"`,
      `"report_too_large"`, `"invalid_report"`, ...). The validator's output stays
      in the log, not in the row.
    * A task that exits without a result fails the run as `"executor_lost"`.
    * A lease that was lost (expired and reconciled, or taken over) writes
      nothing: the runner cancels the validator task and stops with
      `{:shutdown, :lease_lost}`.

  A runner that is shut down while its task runs cancels the task the same way, so
  the CLI process is killed before the runner exits. A result write that raises
  leaves the run `running`; its lease expires and `Validations.reconcile_expired/1`
  fails it.

  Start runners with `Validations.start_mobility_data_run/4`.
  """

  # The shutdown timeout covers `@cancel_wait_ms`: the validator kills its CLI
  # process and waits up to five seconds for its exit status after a cancel.
  use GenServer, restart: :temporary, shutdown: 10_000

  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Validations

  require Logger

  @default_heartbeat_ms 60_000
  @cancel_wait_ms 8_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    run_id = Keyword.fetch!(opts, :run_id)
    # Read before the claim, so a missing module leaves the run unclaimed and
    # `start_mobility_data_run/4` can close it.
    validator = Application.fetch_env!(:gtfs_planner, :validator_module)

    case Validations.claim_run(organization_id, run_id) do
      {:ok, run, token} ->
        Process.flag(:trap_exit, true)

        task =
          Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
            validator.validate(organization_id, run.gtfs_version_id, validation_run_id: run.id)
          end)

        state = %{
          organization_id: organization_id,
          run_id: run_id,
          token: token,
          task: task,
          timer: nil
        }

        {:ok, schedule_renewal(state)}

      {:error, _reason} ->
        {:stop, :claim_failed}
    end
  end

  @impl true
  def handle_info(:renew_lease, state) do
    case Validations.renew_lease(state.organization_id, state.run_id, state.token) do
      :ok ->
        {:noreply, schedule_renewal(state)}

      {:error, :lease_lost} ->
        Logger.warning("Validation run #{state.run_id} lost its lease; cancelling the validator")
        {:stop, {:shutdown, :lease_lost}, state}
    end
  end

  # The task is cleared before the terminal write runs in `handle_continue/2`, so a
  # write that raises does not make `terminate/2` cancel a task that already exited.
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil}, {:continue, {:finish, result}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("Validation run #{state.run_id} lost its validator task: #{inspect(reason)}")
    {:noreply, %{state | task: nil}, {:continue, {:finish, {:error, "executor_lost"}}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_continue({:finish, result}, state), do: finish(result, state)

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    if state.task, do: stop_task(state.task)
    :ok
  end

  defp schedule_renewal(state) do
    heartbeat_ms =
      Application.get_env(:gtfs_planner, :validation_runner_heartbeat_ms, @default_heartbeat_ms)

    %{state | timer: Process.send_after(self(), :renew_lease, heartbeat_ms)}
  end

  defp finish({:ok, %Validator.Result{} = result}, state) do
    conclude(
      Validations.complete_run(state.organization_id, state.run_id, state.token, result),
      state
    )
  end

  defp finish({:error, reason}, state) do
    conclude(
      Validations.fail_run(
        state.organization_id,
        state.run_id,
        state.token,
        failure_reason(reason)
      ),
      state
    )
  end

  defp conclude({:ok, _run}, state), do: {:stop, :normal, state}
  defp conclude({:error, :lease_lost}, state), do: {:stop, {:shutdown, :lease_lost}, state}

  # `error_details` holds a short reason: a `{:cli_failed, code, output}` reason
  # carries up to 64 KiB of CLI output, which the validator already logged.
  defp failure_reason(reason) when is_atom(reason) or is_binary(reason), do: reason

  defp failure_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp failure_reason(reason), do: inspect(reason, limit: 20, printable_limit: 200)

  # The task owns the validator's CLI port. A cancel makes it kill the CLI process
  # and return; killing the task first would close the port but leave the JVM running.
  defp stop_task(%Task{} = task) do
    Validator.cancel(task.pid)
    Task.yield(task, @cancel_wait_ms) || Task.shutdown(task, :brutal_kill)
    :ok
  end
end
