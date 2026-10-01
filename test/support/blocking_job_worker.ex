defmodule GtfsPlanner.Support.BlockingJobWorker do
  @moduledoc false

  # A change, export or cleanup worker that holds its runner's slot until the
  # test sends `:finish`. The test process is the value of
  # `:blocking_job_worker_owner`; it receives
  # `{:blocking_job_worker_started, kind, worker_pid}` once the worker is running.
  # Import runs use `GtfsPlanner.Support.BlockingImportWorker`.

  def compute(_run, _generation, _token, _topic), do: hold(:compute)
  def apply(_run, _generation, _token, _audit_context, _topic), do: hold(:apply)
  def build(_run, _generation, _token, _topic), do: hold(:build)
  def run(_organization_id, _run_id, _lease_token), do: hold(:cleanup)

  defp hold(kind) do
    owner = Application.fetch_env!(:gtfs_planner, :blocking_job_worker_owner)
    send(owner, {:blocking_job_worker_started, kind, self()})

    receive do
      :finish -> :ok
    end
  end
end
