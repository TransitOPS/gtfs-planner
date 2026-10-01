defmodule GtfsPlanner.RunnerAdmission do
  @moduledoc """
  Admission for supervised jobs.

  Each runner supervisor sets a finite `max_children` from
  `config :gtfs_planner, :runner_limits`. `start_child/2` is the one place a
  start at that limit becomes `{:error, :busy}`, so callers name saturation the
  same way for every kind of job. The supervisor refuses before the child's
  `init/1` runs, so a refused job has claimed nothing and read nothing.
  """

  @doc """
  Starts `child_spec` under `supervisor`.

  Returns the `DynamicSupervisor.on_start_child/0` result, with
  `{:error, :max_children}` replaced by `{:error, :busy}`.
  """
  @spec start_child(
          Supervisor.supervisor(),
          Supervisor.child_spec() | {module(), term()} | module()
        ) :: DynamicSupervisor.on_start_child() | {:error, :busy}
  def start_child(supervisor, child_spec) do
    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:error, :max_children} -> {:error, :busy}
      result -> result
    end
  end
end
