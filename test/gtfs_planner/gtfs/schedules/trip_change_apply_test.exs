defmodule GtfsPlanner.Gtfs.Schedules.TripChangeApplyTest do
  @moduledoc """
  Merge evidence (EV-10) for the change apply path (step 11):

  - A reviewed +5 minute shift of three linked trips writes the literal new
    clocks, forces a new `updated_at` on every shifted trip (FH-15) and returns
    the restore payload an undo re-submits (INV-2, INV-4).
  - A change committed between review and apply is refused as
    `{:error, {:stale_review, review}}` with the stop-time rows byte-equal
    (FH-14); an `{:expected, …}` map with an old `updated_at` is
    `{:error, :stale}` and writes nothing.
  - A negative shift is `{:error, {:refused, [{:error, :negative_time}]}}` with
    no row and no log (FH-18).
  - With the `change_logs` rejection trigger installed, a 3-trip shift raises and
    every trip's clocks and `updated_at` are unchanged (FH-13).
  - The audit logs read `before` before any write, carry the pre-write clocks and
    share one `operation_id` with the full affected trip list (FH-16).
  - 501 ids are `{:error, :too_many_trips}`; a foreign or unknown trip UUID is
    `{:error, :not_found}` (FH-30).
  - Two committing sessions: an ordinary `update_trip/5` that commits between the
    review and the apply leaves the reviewed apply stale through the production
    `ReviewedApplyTransaction.Repo` adapter, and only its captured scope is
    deleted in `on_exit`.

  Every expected value is literal and hand-derived from R3, R4, R11 and the §4.4
  contract in spec.md; no expectation is computed by the code under test. Every
  apply runs through the real production entry point `Gtfs.apply_trip_change/4`.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_change_apply_test.exs` (EV-10,
  300 s deadline).
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.OrganizationsFixtures, only: [delete_versions!: 1]
  import GtfsPlanner.ScheduleEditingFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  setup do
    %{scope: editing_scope!("12")}
  end

  describe "a reviewed shift" do
    test "writes the literal clocks and a new updated_at on every selected trip", %{scope: scope} do
      first = linked_trip!(scope, "07:00:00")
      second = linked_trip!(scope, "08:00:00")
      third = linked_trip!(scope, "09:00:00")
      selected = Enum.sort([first.id, second.id, third.id])
      reviewed_updated_at = Map.new([first, second, third], &{&1.id, &1.updated_at})
      command = {:shift, selected, 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert Enum.sort(result.changed_trip_ids) == selected
      assert result.created_trip_ids == []
      assert result.deleted_trip_ids == []
      assert result.transfers_removed == 0
      assert result.change_set == review.change_set
      assert {:ok, _uuid} = Ecto.UUID.cast(result.operation_id)
      assert result.restore.operation_id == result.operation_id
      assert result.restore.route_id == "12"

      assert Map.keys(result.restore) |> Enum.sort() == [
               :created,
               :gtfs_version_id,
               :operation_id,
               :organization_id,
               :route_id,
               :trips
             ]

      assert stop_time_clocks(first) == [
               {"07:05:00", "07:05:00", nil, nil},
               {"07:10:00", "07:10:30", nil, nil},
               {"07:17:00", "07:17:00", nil, nil}
             ]

      assert stop_time_clocks(second) == [
               {"08:05:00", "08:05:00", nil, nil},
               {"08:10:00", "08:10:30", nil, nil},
               {"08:17:00", "08:17:00", nil, nil}
             ]

      assert stop_time_clocks(third) == [
               {"09:05:00", "09:05:00", nil, nil},
               {"09:10:00", "09:10:30", nil, nil},
               {"09:17:00", "09:17:00", nil, nil}
             ]

      Enum.each([first, second, third], fn trip ->
        row = trip_row(trip)
        assert DateTime.compare(row.updated_at, reviewed_updated_at[trip.id]) == :gt
        assert row.pattern_derivation_state == "linked"
        assert row.timed_pattern_id == scope.bundle.timing.id
      end)

      # The restore payload captured the pre-write rows and the updated_at this
      # write produced, so an undo can fence on it (R10).
      restore = Map.new(result.restore.trips, &{&1.id, &1})
      assert Map.keys(restore) |> Enum.sort() == selected
      assert restore[first.id].fields.service_id == scope.service
      assert restore[first.id].fields.pattern_derivation_state == "linked"

      assert Enum.map(restore[first.id].stop_times, & &1.departure_time) == [
               "07:00:00",
               "07:05:30",
               "07:12:00"
             ]

      assert restore[first.id].written_updated_at == trip_row(first).updated_at
      assert result.restore.created == []
    end

    test "keeps the block of a blocked pair through a shift", %{scope: scope} do
      [first, second] = blocked_pair!(scope, "B-193", ["07:00:00", "08:00:00"])
      selected = Enum.sort([first.id, second.id])
      command = {:shift, selected, 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert Enum.sort(result.changed_trip_ids) == selected

      assert stop_time_clocks(first) == [
               {"07:05:00", "07:05:00", nil, nil},
               {"07:10:00", "07:10:30", nil, nil},
               {"07:17:00", "07:17:00", nil, nil}
             ]

      Enum.each([first, second], fn trip ->
        assert trip_row(trip).block_id == "B-193"
      end)

      restore = Map.new(result.restore.trips, &{&1.id, &1})
      assert restore[first.id].fields.block_id == "B-193"
    end

    test "a change between review and apply is refused with the rows byte-equal", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")
      other = linked_trip!(scope, "08:00:00")
      selected = Enum.sort([trip.id, other.id])
      command = {:shift, selected, 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      # Another editor retimes one selected trip through the ordinary writer; the
      # reviewed fingerprint no longer describes the rows under lock.
      assert {:ok, _updated} =
               Gtfs.update_trip(
                 "12",
                 trip.id,
                 %{start_time: "07:10:00"},
                 trip.updated_at,
                 scope.audit
               )

      rows_before = stop_time_rows(scope, [trip.trip_id, other.trip_id])
      logs_before = log_count(scope)

      assert {:error, {:stale_review, stale_review}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert stale_review.command == review.command
      assert stale_review.fingerprint != review.fingerprint
      assert stop_time_rows(scope, [trip.trip_id, other.trip_id]) == rows_before
      assert log_count(scope) == logs_before
    end
  end

  describe "the R3 fence" do
    test "an expected map applies a nudge when every trip still has the loaded updated_at",
         %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 {:shift, [trip.id], 300, nil},
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert result.changed_trip_ids == [trip.id]

      assert stop_time_clocks(trip) == [
               {"07:05:00", "07:05:00", nil, nil},
               {"07:10:00", "07:10:30", nil, nil},
               {"07:17:00", "07:17:00", nil, nil}
             ]

      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :gt
      assert [log] = trip_logs(trip)
      assert log.action == "updated"
      assert result.restore.trips |> Enum.map(& &1.id) == [trip.id]
    end

    test "an old updated_at is stale and writes nothing", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")
      old = DateTime.add(trip.updated_at, -1, :second)
      rows_before = stop_time_rows(scope, [trip.trip_id])

      assert {:error, :stale} =
               Gtfs.apply_trip_change(
                 "12",
                 {:shift, [trip.id], 300, nil},
                 {:expected, %{trip.id => old}},
                 scope.audit
               )

      assert stop_time_rows(scope, [trip.trip_id]) == rows_before
      assert trip_logs(trip) == []
      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :eq
    end

    test "a reviewed timing change is stale when the chosen timing's rows change before apply",
         %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")
      slow = extra_timing!(scope.bundle, [{0, 0, 1}, {360, 390, 1}, {840, 840, 1}], "Slow")
      command = {:set_timing, [trip.id], slow.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      # Another editor lengthens the Slow timing's last leg after the review; the
      # command trip itself is untouched.
      from(s in TimedPatternStop,
        where: s.timed_pattern_id == ^slow.id and s.arrival_offset == 840
      )
      |> Repo.update_all(set: [arrival_offset: 900, departure_offset: 900])

      rows_before = stop_time_rows(scope, [trip.trip_id])

      assert {:error, {:stale_review, stale_review}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert stale_review.fingerprint != review.fingerprint
      assert stop_time_rows(scope, [trip.trip_id]) == rows_before
      assert trip_logs(trip) == []
    end

    test "a fence outside the §4.4 table is refused with nothing written", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")
      rows_before = stop_time_rows(scope, [trip.trip_id])

      assert {:error, :fence_required} =
               Gtfs.apply_trip_change("12", {:shift, [trip.id], 300, nil}, :none, scope.audit)

      assert stop_time_rows(scope, [trip.trip_id]) == rows_before
      assert trip_logs(trip) == []
    end
  end

  describe "refusals and rollback" do
    test "a negative shift is refused and writes no row or log", %{scope: scope} do
      trip = linked_trip!(scope, "00:05:00")
      command = {:shift, [trip.id], -600, nil}
      rows_before = stop_time_rows(scope, [trip.trip_id])

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:error, {:refused, [{:error, :negative_time}]}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert stop_time_rows(scope, [trip.trip_id]) == rows_before
      assert trip_logs(trip) == []
    end

    test "an audit failure after the data writes rolls every trip back", %{scope: scope} do
      first = linked_trip!(scope, "07:00:00")
      second = linked_trip!(scope, "08:00:00")
      third = linked_trip!(scope, "09:00:00")
      selected = Enum.sort([first.id, second.id, third.id])
      trips = [first, second, third]
      command = {:shift, selected, 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      clocks_before = Map.new(trips, &{&1.id, stop_time_clocks(&1)})

      updated_before =
        Map.new(trips, fn trip -> {trip.id, trip_row(trip).updated_at} end)

      install_trip_audit_rejection_trigger!()

      assert_raise Postgrex.Error, fn ->
        Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)
      end

      remove_trip_audit_rejection_trigger!()

      Enum.each(trips, fn trip ->
        assert stop_time_clocks(trip) == clocks_before[trip.id]
        assert trip_row(trip).updated_at == updated_before[trip.id]
      end)

      assert Enum.all?(trips, &(trip_logs(&1) == []))
    end
  end

  describe "the audit logs" do
    test "read the pre-write clocks and share one operation", %{scope: scope} do
      first = custom_trip!(scope, custom_stop_times(25_200))
      second = custom_trip!(scope, custom_stop_times(28_800))
      third = custom_trip!(scope, custom_stop_times(32_400))
      selected = Enum.sort([first.id, second.id, third.id])
      command = {:shift, selected, 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, _result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert [log] = trip_logs(first)
      assert log.action == "updated"
      assert log.changed_fields["before"]["start_time"] == "07:00:00"

      assert log.changed_fields["before"]["stop_times"] == [
               %{"stop_id" => "A", "arrival_time" => "07:00:00", "departure_time" => "07:00:00"},
               %{"stop_id" => "B", "arrival_time" => "07:05:00", "departure_time" => "07:05:30"},
               %{"stop_id" => "C", "arrival_time" => "07:12:00", "departure_time" => "07:12:00"}
             ]

      # The custom trip stays custom (its stored timepoint is not the timing's), so
      # the after snapshot carries the written clocks.
      assert log.changed_fields["after"]["start_time"] == "07:05:00"

      assert log.changed_fields["after"]["stop_times"] == [
               %{"stop_id" => "A", "arrival_time" => "07:05:00", "departure_time" => "07:05:00"},
               %{"stop_id" => "B", "arrival_time" => "07:10:00", "departure_time" => "07:10:30"},
               %{"stop_id" => "C", "arrival_time" => "07:17:00", "departure_time" => "07:17:00"}
             ]

      logs = Enum.flat_map([first, second, third], &trip_logs/1)
      assert length(logs) == 3

      operation_ids =
        logs |> Enum.map(& &1.changed_fields["operation_id"]) |> Enum.uniq()

      assert [operation_id] = operation_ids
      assert {:ok, _uuid} = Ecto.UUID.cast(operation_id)

      Enum.each(logs, fn entry ->
        assert entry.changed_fields["affected_trip_ids"] |> Enum.sort() == selected
      end)
    end
  end

  describe "command scoping" do
    test "501 ids are too many trips", %{scope: scope} do
      ids = Enum.map(1..501, fn _index -> Ecto.UUID.generate() end)

      assert {:error, :too_many_trips} =
               Gtfs.apply_trip_change("12", {:shift, ids, 300, nil}, :none, scope.audit)
    end

    test "a foreign or unknown trip UUID is not found", %{scope: scope} do
      foreign = editing_scope!("91")
      foreign_trip = linked_trip!(foreign, "07:00:00")

      assert {:error, :not_found} =
               Gtfs.apply_trip_change(
                 "12",
                 {:shift, [foreign_trip.id], 300, nil},
                 {:reviewed, Ecto.UUID.generate()},
                 scope.audit
               )

      other_route =
        editing_scope!("13",
          organization: scope.organization,
          version: scope.version,
          actor: scope.actor,
          audit: scope.audit
        )

      other_trip = linked_trip!(other_route, "07:00:00")

      assert {:error, :not_found} =
               Gtfs.apply_trip_change(
                 "12",
                 {:shift, [other_trip.id], 300, nil},
                 {:reviewed, Ecto.UUID.generate()},
                 scope.audit
               )

      assert {:error, :not_found} =
               Gtfs.apply_trip_change(
                 "12",
                 {:shift, [Ecto.UUID.generate()], 300, nil},
                 {:reviewed, Ecto.UUID.generate()},
                 scope.audit
               )
    end
  end

  describe "two committing sessions" do
    test "an update committed between review and apply makes the reviewed apply stale" do
      scope = committed_scope!("two-sessions")
      on_exit(fn -> cleanup_committed_scope(scope) end)

      use_production_transaction_adapter!()

      assert {:ok, review} =
               unboxed(fn ->
                 Gtfs.review_trip_change(
                   scope.route_id,
                   {:shift, [scope.trip.id], 300, nil},
                   scope.audit
                 )
               end)

      # The second session commits a retime of one reviewed trip.
      assert {:ok, _updated} =
               unboxed(fn ->
                 Gtfs.update_trip(
                   scope.route_id,
                   scope.trip.id,
                   %{start_time: "07:10:00"},
                   scope.trip.updated_at,
                   scope.audit
                 )
               end)

      committed_clocks = unboxed(fn -> stop_time_clocks(scope.trip) end)

      assert {:error, {:stale_review, stale_review}} =
               unboxed(fn ->
                 Gtfs.apply_trip_change(
                   scope.route_id,
                   {:shift, [scope.trip.id], 300, nil},
                   {:reviewed, review.fingerprint},
                   scope.audit
                 )
               end)

      assert stale_review.fingerprint != review.fingerprint
      assert unboxed(fn -> stop_time_clocks(scope.trip) end) == committed_clocks
    end
  end

  # -- Committed scope for the two-session case -------------------------------

  # Creates the whole scope out of the sandbox so a second session can commit
  # against it; `cleanup_committed_scope/1` removes exactly that scope again.
  defp committed_scope!(route_id) do
    unboxed(fn ->
      scope = editing_scope!(route_id)
      trip = linked_trip!(scope, "07:00:00")
      scope |> Map.put(:route_id, route_id) |> Map.put(:trip, trip)
    end)
  end

  defp use_production_transaction_adapter! do
    previous = Application.get_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )

    on_exit(fn ->
      Application.put_env(:gtfs_planner, :reviewed_apply_transaction, previous)
    end)

    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Deletes only the captured fixture scope. The organization id is the captured
  # root: every row created here belongs to it, so nothing outside this fixture
  # can be touched.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      organization_ids = [scope.organization.id]
      user_ids = [scope.actor.id]

      Repo.delete_all(
        from(r in TimedPatternStop,
          where:
            r.timed_pattern_id in subquery(
              from(t in TimedPattern,
                where: t.organization_id in ^organization_ids,
                select: t.id
              )
            )
        )
      )

      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(f in Frequency, where: f.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id in ^organization_ids))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id in ^organization_ids))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id in ^organization_ids))

      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))
      delete_versions!(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(c in Calendar, where: c.organization_id in ^organization_ids))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end

  # -- Readbacks --------------------------------------------------------------

  defp stop_time_rows(scope, trip_ids) do
    Repo.all(
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization.id and
            st.gtfs_version_id == ^scope.version.id and st.trip_id in ^trip_ids,
        order_by: [asc: st.trip_id, asc: st.stop_sequence, asc: st.id]
      )
    )
  end

  defp log_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization.id and
            l.gtfs_version_id == ^scope.version.id
      ),
      :count
    )
  end

  defp custom_stop_times(start_secs) do
    [
      {"A", start_secs, start_secs},
      {"B", start_secs + 300, start_secs + 330},
      {"C", start_secs + 720, start_secs + 720}
    ]
    |> Enum.map(fn {stop_id, arrival, departure} ->
      {stop_id, GtfsTime.format(arrival), GtfsTime.format(departure)}
    end)
  end

  # Test-only fault injection: a constraint trigger on `change_logs` raises on the
  # next trip audit insert, after the trip and stop-time rows are written. It is
  # created inside the sandbox transaction, so the guaranteed test rollback removes
  # it, and the test also drops it explicitly. No production failure switch exists.
  defp install_trip_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION trip_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'trip' THEN
        RAISE EXCEPTION 'trip audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER trip_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION trip_audit_rejection();
    """)
  end

  defp remove_trip_audit_rejection_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS trip_audit_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS trip_audit_rejection()")
  end
end
