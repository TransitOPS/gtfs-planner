defmodule GtfsPlanner.Gtfs.ServiceQueries.Snapshot.Sandbox do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ServiceQueries.Snapshot

  @impl true
  def begin_read, do: :ok
end
