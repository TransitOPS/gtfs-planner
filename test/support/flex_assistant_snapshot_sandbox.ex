defmodule GtfsPlanner.Gtfs.Flex.Assistant.Snapshot.Sandbox do
  @moduledoc false

  # The SQL sandbox already owns an open transaction, and PostgreSQL refuses a
  # mid-transaction isolation change, so sandboxed tests reuse that snapshot.
  @behaviour GtfsPlanner.Gtfs.Flex.Assistant.Snapshot

  @impl true
  def begin_read, do: :ok
end
