defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.Repo do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias GtfsPlanner.Repo

  @impl true
  def run(transaction) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
      transaction.()
    end)
  end
end
