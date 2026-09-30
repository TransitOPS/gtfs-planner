defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.MoveCalendarTest do
  @moduledoc """
  Merge evidence (EV-14) for the R6 Change calendar through the engine (step 15):

  - The block 103 counterexample: two trips of one block both move Weekday → Saturday
    in one command and keep block 103 (FH-20, AC-13). A decision made one trip at a
    time would clear A while B was still on Weekday.
  - Moving A alone clears A's block — `block_id: nil` beside the target service and a
    `{:note, {:cleared_block, id, "103"}}` — and leaves B byte-unchanged.
  - A move writes no transfer row: the in-seat record naming the two trips is
    byte-unchanged after an apply that clears A's block (FH-21).
  - Moving a listed trip onto a service whose dates carry the pattern's frequency
    service is refused with `{:mixed_service, _}` and writes nothing (FH-10, R9,
    AC-20).

  Every expected value is literal and hand-derived from R6, R9 and the §4.4
  contracts in spec.md; nothing computes an expectation with the planner under test.
  Every apply runs through the real production entry point `Gtfs.apply_trip_change/4`
  with its reviewed-fingerprint fence, on the real local PostgreSQL test database with
  sandboxed fixtures.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_changes/move_calendar_test.exs`
  (EV-14, 120 s deadline); it is deferred to branch review.
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  describe "the R6 simultaneous block decision (AC-13, FH-20)" do
    test "both trips of block 103 moving Weekday to Saturday keep block 103" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      [a, b] = blocked_pair!(scope, "103", ["07:00:00", "08:00:00"])

      command = {:move_calendar, [a.id, b.id], saturday}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 2, created: 0, deleted: 0, excluded: 0, skipped: 0}
      assert review.change_set.consequences == []
      assert review.preview == %{}

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert Enum.sort(result.changed_trip_ids) == Enum.sort([a.id, b.id])
      assert trip_row(a).service_id == saturday
      assert trip_row(b).service_id == saturday
      assert trip_row(a).block_id == "103"
      assert trip_row(b).block_id == "103"
      assert DateTime.compare(trip_row(a).updated_at, a.updated_at) == :gt

      for trip <- [a, b] do
        assert [log] = trip_logs(trip)
        assert log.action == "updated"
        assert log.changed_fields["operation_id"] == result.operation_id
        assert log.changed_fields["before"]["service_id"] == scope.service
        assert log.changed_fields["after"]["service_id"] == saturday
        assert log.changed_fields["before"]["block_id"] == "103"
        assert log.changed_fields["after"]["block_id"] == "103"
      end
    end

    test "moving A alone clears only A's block and leaves B unchanged" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      [a, b] = blocked_pair!(scope, "103", ["07:00:00", "08:00:00"])
      b_before = trip_row(b)

      command = {:move_calendar, [a.id], saturday}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 1, created: 0, deleted: 0, excluded: 0, skipped: 0}
      assert review.change_set.consequences == [{:note, {:cleared_block, a.id, "103"}}]

      assert [update] = review.change_set.updates
      assert update.trip_id == a.id
      assert update.fields == %{service_id: saturday, block_id: nil}
      assert update.stop_times == :unchanged
      assert update.frequencies == :unchanged

      assert {:ok, _result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert trip_row(a).service_id == saturday
      assert trip_row(a).block_id == nil
      assert trip_row(b) == b_before
      assert trip_logs(b) == []
    end
  end

  describe "transfers (FH-21)" do
    test "a move writes no transfer row" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      [a, b] = blocked_pair!(scope, "103", ["07:00:00", "08:00:00"])
      transfer = in_seat_transfer_fixture(scope.organization.id, scope.version.id, a, b)
      rows_before = transfer_rows(scope)

      assert [row] = rows_before
      assert row.id == transfer.id
      assert row.from_trip_id == a.trip_id
      assert row.to_trip_id == b.trip_id
      assert row.transfer_type == 4

      command = {:move_calendar, [a.id], saturday}
      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, _result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert trip_row(a).service_id == saturday
      assert trip_row(a).block_id == nil
      assert transfer_rows(scope) == rows_before
    end
  end

  describe "R9 mixing (AC-20, FH-10)" do
    test "moving a listed trip onto a service whose dates carry frequency service is refused" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      %{daily: daily} = shared_dates_calendars!(scope)

      listed = linked_trip!(scope, "07:00:00")

      frequency_trip!(scope, [%{start_secs: 28_800, end_secs: 32_400, headway_secs: 600}],
        service_id: saturday
      )

      command = {:move_calendar, [listed.id], daily}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert [{:error, {:mixed_service, details}}] = review.change_set.consequences
      assert MapSet.new(details.service_ids) == MapSet.new([daily, saturday])
      # Every Saturday of the fixture year: 2026-01-03 through 2026-12-26.
      assert details.date_count == 52

      assert {:error, {:refused, [{:error, {:mixed_service, refused}}]}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert refused == details
      assert trip_row(listed).service_id == scope.service
      assert trip_logs(listed) == []
    end
  end

  # -- Fixtures and readbacks -------------------------------------------------

  defp transfer_rows(scope) do
    Repo.all(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id,
        order_by: [asc: t.id],
        select: %{
          id: t.id,
          from_trip_id: t.from_trip_id,
          to_trip_id: t.to_trip_id,
          from_stop_id: t.from_stop_id,
          to_stop_id: t.to_stop_id,
          transfer_type: t.transfer_type
        }
      )
    )
  end
end
