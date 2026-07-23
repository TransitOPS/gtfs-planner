defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.Sandbox do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias GtfsPlanner.Repo

  @impl true
  def run(transaction), do: Repo.transaction(transaction)
end
