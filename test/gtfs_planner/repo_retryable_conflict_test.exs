defmodule GtfsPlanner.RepoRetryableConflictTest do
  # Mutates the global transaction-adapter env, so it must not run concurrently with
  # other tests; the env is restored in `on_exit`.
  use ExUnit.Case, async: false

  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Repo

  describe "Repo.retryable_conflict?/1" do
    test "accepts serialization failures in atom and string form" do
      assert Repo.retryable_conflict?(%Postgrex.Error{postgres: %{code: :serialization_failure}})
      assert Repo.retryable_conflict?(%Postgrex.Error{postgres: %{code: "40001"}})
    end

    test "accepts deadlocks in atom and string form" do
      assert Repo.retryable_conflict?(%Postgrex.Error{postgres: %{code: :deadlock_detected}})
      assert Repo.retryable_conflict?(%Postgrex.Error{postgres: %{code: "40P01"}})
    end

    test "accepts a struct built through Postgrex.Error.exception/1" do
      assert Repo.retryable_conflict?(Postgrex.Error.exception(postgres: %{code: "40001"}))
      assert Repo.retryable_conflict?(Postgrex.Error.exception(postgres: %{code: "40P01"}))
    end

    test "rejects unique violations" do
      refute Repo.retryable_conflict?(%Postgrex.Error{postgres: %{code: :unique_violation}})
      refute Repo.retryable_conflict?(%Postgrex.Error{postgres: %{code: "23505"}})
    end

    test "rejects non-Postgrex terms and Postgrex errors without a code" do
      refute Repo.retryable_conflict?(:busy)
      refute Repo.retryable_conflict?(nil)
      refute Repo.retryable_conflict?(%Postgrex.Error{message: "connection closed"})
    end
  end

  describe "ReviewedApplyTransaction.adapter/0" do
    test "returns the configured test adapter" do
      assert ReviewedApplyTransaction.adapter() == ReviewedApplyTransaction.Sandbox
    end

    test "falls back to the SERIALIZABLE Repo adapter when unconfigured" do
      previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)
      Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
          :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
        end
      end)

      assert ReviewedApplyTransaction.adapter() == ReviewedApplyTransaction.Repo
    end
  end
end
