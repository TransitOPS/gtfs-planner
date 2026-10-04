defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.Sandbox do
  @moduledoc """
  The sandbox adapter: a plain `Repo.transaction/1` inside the enclosing savepoint.

  A sandbox connection already holds an open transaction, so this adapter cannot
  change the enclosing transaction's isolation level and therefore drops the
  `:isolation` option, exactly as it drops every option but `:timeout`. The
  production level is proved by the unboxed independent-connection cases instead.
  """

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias GtfsPlanner.Repo

  @impl true
  def run(transaction), do: run(transaction, [])

  @impl true
  def run(transaction, options) when is_function(transaction, 0) and is_list(options) do
    Repo.transaction(transaction, Keyword.take(options, [:timeout]))
  end
end
