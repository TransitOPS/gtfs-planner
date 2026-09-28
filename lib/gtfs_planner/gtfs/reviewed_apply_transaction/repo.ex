defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.Repo do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias GtfsPlanner.Repo

  @impl true
  def run(transaction), do: run(transaction, [])

  @impl true
  def run(transaction, options) when is_function(transaction, 0) and is_list(options) do
    Repo.transaction(
      fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        transaction.()
      end,
      trusted_options(options)
    )
  end

  # Only the trusted `:timeout` option crosses this boundary; every other key is
  # dropped before it reaches Repo.transaction/2.
  defp trusted_options(options), do: Keyword.take(options, [:timeout])
end
