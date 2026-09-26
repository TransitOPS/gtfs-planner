defmodule GtfsPlanner.Gtfs.Export.Snapshot.Sandbox do
  @moduledoc false

  # The SQL sandbox already owns an open transaction, and PostgreSQL refuses a
  # mid-transaction isolation change, so sandboxed tests reuse that snapshot.
  @behaviour GtfsPlanner.Gtfs.Export.Snapshot

  @impl true
  def begin_read, do: :ok
end
