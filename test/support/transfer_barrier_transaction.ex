defmodule GtfsPlanner.Gtfs.TransferBarrierTransaction do
  @moduledoc """
  A SERIALIZABLE transaction boundary that can be paused immediately before commit.

  The transfer concurrency cases need two independently committing sessions whose
  commit order is fixed rather than hoped for: the session that must commit last
  has to have finished its writes but not its commit while the other session runs.
  This module is `GtfsPlanner.Gtfs.ReviewedApplyTransaction.Repo` — the production
  boundary — plus two test-only behaviors: a before-commit barrier and a recovery of
  the sandbox's pinned connection.

  The barrier: when the calling process dictionary holds a pid under
  `:transfer_barrier`, that pid receives `{:before_commit, self()}` after the
  transaction function returns and the process then blocks until it is sent
  `:commit`. Every other process, and every process without the entry, behaves
  exactly like the production module.

  The connection recovery: PostgreSQL answers a failed `COMMIT` with a disconnect
  (`Postgrex.Protocol.handle_transaction/3` returns `{:disconnect, err, state}` for
  any error reply to `COMMIT`), and `Sandbox.unboxed_run/2` pins one ownership
  connection to the session process for its whole run. The production connection
  pool replaces the disconnected connection, so the production retry loop's next
  attempt gets a live one; the sandbox's pinned ownership checkout does not, and
  the next attempt exits `:noproc` from `DBConnection.Holder.checkout/2` before it
  issues any SQL. This module therefore performs the replacement the sandbox omits
  — `Sandbox.unboxed_run/2` checks the dead connection in and checks a live one out
  — and re-enters the same transaction, so the case still exercises the production
  retry loop and its attempt budget instead of failing on a harness artifact.

  It exists only to force commit order in tests. Nothing in `lib/` uses it, and
  the concurrency case restores the configured module in `on_exit`.
  """

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  @replacement_attempts 3

  @impl true
  def run(transaction), do: run(transaction, [])

  @impl true
  def run(transaction, _options), do: run_with_retries(transaction, @replacement_attempts)

  defp run_with_retries(transaction, attempts) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")

      result = transaction.()
      maybe_wait()
      result
    end)
  catch
    # The sandbox's pinned ownership connection died with the failed COMMIT. Check
    # it in, take a live one, and re-enter the same transaction; the transaction
    # function is unchanged, so the production retry loop still owns the attempts.
    :exit, {:noproc, {DBConnection.Holder, :checkout, _opts}} when attempts > 0 ->
      replace_connection()
      run_with_retries(transaction, attempts - 1)
  end

  defp replace_connection(attempts \\ @replacement_attempts) do
    # Release the dead ownership connection and take a live one. The release is
    # `:not_found` when the disconnect already dropped the ownership mapping;
    # unlike `Sandbox.unboxed_run/2`, `Sandbox.checkout/2` leaves the process the
    # owner, so the next attempt can start its transaction without an implicit
    # checkout (which the manual-mode sandbox refuses).
    _ = Sandbox.checkin(Repo)
    :ok = Sandbox.checkout(Repo, sandbox: false)
  catch
    :exit, {:noproc, {DBConnection.Holder, :checkout, _opts}} when attempts > 1 ->
      replace_connection(attempts - 1)
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
