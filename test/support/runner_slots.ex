defmodule GtfsPlanner.Support.RunnerSlots do
  @moduledoc false

  # Each runner supervisor admits one job in every environment (`:runner_limits`),
  # so a runner that is still stopping blocks the next start with `{:error, :busy}`.
  # A test that starts a runner waits here before it starts the next job.

  @supervisors [
    GtfsPlanner.Gtfs.Import.RunnerSupervisor,
    GtfsPlanner.Gtfs.Import.ChangeRunnerSupervisor,
    GtfsPlanner.Gtfs.Export.RunnerSupervisor,
    GtfsPlanner.Reachability.RunnerSupervisor
  ]

  @doc """
  Waits until every runner supervisor in `@supervisors` has no children.

  A runner still alive after `timeout` milliseconds is killed, so a test that
  left a worker blocked cannot hold the slot for the tests after it.
  """
  def await_idle(timeout \\ 5_000) do
    for supervisor <- @supervisors,
        {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid) do
      await_down(pid, timeout)
    end

    :ok
  end

  defp await_down(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end
  end
end
