defmodule GtfsPlanner.Support.BlockingImportWorker do
  @moduledoc false

  def run(_run, _lease_token, _files, _topic) do
    owner = Application.fetch_env!(:gtfs_planner, :blocking_import_worker_owner)
    send(owner, {:blocking_import_worker_started, self()})

    receive do
      :finish -> :ok
    end
  end
end
