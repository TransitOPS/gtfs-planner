defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.Repo do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias GtfsPlanner.Repo

  @impl true
  def run(transaction), do: run(transaction, [])

  @default_isolation :serializable
  @isolations [:serializable, :read_committed]
  @levels %{serializable: "SERIALIZABLE", read_committed: "READ COMMITTED"}

  @impl true
  def run(transaction, options) when is_function(transaction, 0) and is_list(options) do
    isolation = Keyword.get(options, :isolation, @default_isolation)

    Repo.transaction(
      fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL #{level(isolation)}")
        transaction.()
      end,
      trusted_options(options)
    )
  end

  # Only the trusted `:timeout` option crosses this boundary; every other key is
  # dropped before it reaches Repo.transaction/2.
  defp trusted_options(options), do: Keyword.take(options, [:timeout])

  # An unknown level is refused at the boundary rather than interpolated into SQL.
  defp level(isolation) when isolation in @isolations, do: @levels[isolation]

  defp level(isolation) do
    raise ArgumentError,
          "unsupported reviewed apply isolation level: #{inspect(isolation)}"
  end
end
