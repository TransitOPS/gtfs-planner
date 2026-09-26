defmodule GtfsPlanner.Gtfs.Export.Snapshot.Repo do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.Export.Snapshot

  alias GtfsPlanner.Repo

  @impl true
  def begin_read do
    Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
    :ok
  end
end
