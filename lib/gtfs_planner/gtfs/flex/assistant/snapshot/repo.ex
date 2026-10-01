defmodule GtfsPlanner.Gtfs.Flex.Assistant.Snapshot.Repo do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.Flex.Assistant.Snapshot

  alias GtfsPlanner.Repo

  @impl true
  def begin_read do
    # One read-only repeatable-read snapshot: a controlled writer between two of
    # the workspace's reads is invisible to every part of it.
    Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
    :ok
  end
end
