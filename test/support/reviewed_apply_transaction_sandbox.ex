defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.Sandbox do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias GtfsPlanner.Repo

  @impl true
  def run(transaction), do: run(transaction, [])

  @impl true
  def run(transaction, options) when is_function(transaction, 0) and is_list(options) do
    Repo.transaction(transaction, Keyword.take(options, [:timeout]))
  end
end
