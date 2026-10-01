defmodule GtfsPlanner.Gtfs.ServiceQueries.Snapshot.Repo do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ServiceQueries.Snapshot

  alias GtfsPlanner.Repo

  @impl true
  def begin_read do
    # One read-only repeatable-read snapshot: a controlled writer between two of
    # this module's reads is invisible to every part of the answer.
    Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
    :ok
  end
end
