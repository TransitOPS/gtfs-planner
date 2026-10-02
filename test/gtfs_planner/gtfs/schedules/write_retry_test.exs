defmodule GtfsPlanner.Gtfs.Schedules.WriteRetryTest do
  @moduledoc """
  Merge evidence (EV-20) for CL-15: `Schedules.create_trips/3`'s bounded retry classifies
  PostgreSQL serialization conflicts with the shared `Repo.retryable_conflict?/1`.

  The deadlock cases swap the application's transaction boundary for
  `ReviewedApplyTransactionMock`, so the classifier runs against a real `%Postgrex.Error{}`
  without a live deadlock; the retry then executes the real closure through the configured
  test adapter, and written-row counts come from the database. The unique-violation case
  proves the loop still refuses every other PostgreSQL error.

  - one raised 40P01 → the whole create retries and writes exactly one set of trips;
  - three raised 40P01s → `{:error, :busy}` with no trip or stop-time row;
  - a raised 23505 → re-raised with no row written.

  The focused gate command (EV-20, branch review) is
  `mix test test/gtfs_planner/gtfs/schedules/write_retry_test.exs`; nothing here has been
  executed yet (implementation-first scheduling).
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.ScheduleEditingFixtures
  import Mox

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup :verify_on_exit!

  describe "Schedules.create_trips/3 retry classification" do
    test "one raised deadlock retries into the real transaction and writes one set of trips" do
      scope = editing_scope!("12")
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 1, fn _transaction ->
        raise postgrex_error("40P01", "deadlock detected")
      end)

      expect(ReviewedApplyTransactionMock, :run, 1, fn transaction ->
        ReviewedApplyTransaction.Sandbox.run(transaction)
      end)

      assert {:ok, %{trips: [created]}} =
               Gtfs.create_trips("12", create_attrs(scope), scope.audit)

      assert created.trip_id == "12-0-#{scope.service}-0700"
      assert trip_count(scope) == 1
      assert stop_time_count(scope) == 3
    end

    test "three raised deadlocks report :busy and write nothing" do
      scope = editing_scope!("12")
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
        raise postgrex_error("40P01", "deadlock detected")
      end)

      assert {:error, :busy} = Gtfs.create_trips("12", create_attrs(scope), scope.audit)

      assert trip_count(scope) == 0
      assert stop_time_count(scope) == 0
    end

    test "a raised unique violation is re-raised and writes nothing" do
      scope = editing_scope!("12")
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 1, fn _transaction ->
        raise postgrex_error("23505", "duplicate key value violates unique constraint")
      end)

      assert_raise Postgrex.Error, fn ->
        Gtfs.create_trips("12", create_attrs(scope), scope.audit)
      end

      assert trip_count(scope) == 0
      assert stop_time_count(scope) == 0
    end
  end

  # The failure cases swap the application's transaction boundary for the Mox mock, so
  # the original value is captured before the change and restored in `on_exit`
  # (unit-testing guide §6).
  defp use_reviewed_apply_transaction_mock do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)
  end

  # What a real server raises for the named SQLSTATE; the retry path classifies it by the
  # normalised atom, so no live deadlock or constraint violation is needed to exercise it.
  defp postgrex_error(code, message) do
    Postgrex.Error.exception(postgres: %{code: code, severity: "ERROR", message: message})
  end

  defp create_attrs(scope) do
    %{
      pattern_id: scope.bundle.pattern.id,
      timed_pattern_id: scope.bundle.timing.id,
      service_id: scope.service,
      start_time: "07:00:00",
      repeat: nil
    }
  end

  defp trip_count(scope) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id
      ),
      :count
    )
  end

  defp stop_time_count(scope) do
    Repo.aggregate(
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization.id and
            st.gtfs_version_id == ^scope.version.id
      ),
      :count
    )
  end
end
