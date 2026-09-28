defmodule GtfsPlanner.Gtfs.TransferBarrierTransaction do
  @moduledoc """
  A SERIALIZABLE transaction boundary that can be paused immediately before commit.

  The transfer concurrency cases need two independently committing sessions whose
  commit order is fixed rather than hoped for: the session that must commit last
  has to have finished its writes but not its commit while the other session runs.
  This module is `GtfsPlanner.Gtfs.ReviewedApplyTransaction.Repo` — the production
  boundary — plus a barrier: when the calling process dictionary holds a pid under
  `:transfer_barrier`, that pid receives `{:before_commit, self()}` after the
  transaction function returns and the process then blocks until it is sent
  `:commit`. Every other process, and every process without the entry, behaves
  exactly like the production module.

  It exists only to force commit order in tests. Nothing in `lib/` uses it, and
  the concurrency case restores the configured module in `on_exit`.
  """

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias GtfsPlanner.Repo

  @impl true
  def run(transaction) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")

      result = transaction.()
      maybe_wait()
      result
    end)
  end

  # A session pauses only when its own process dictionary holds the barrier pid, so
  # the other session in the same case runs to completion without waiting.
  defp maybe_wait do
    case Process.get(:transfer_barrier) do
      pid when is_pid(pid) ->
        send(pid, {:before_commit, self()})

        receive do
          :commit -> :ok
        end

      _unset ->
        :ok
    end
  end
end
