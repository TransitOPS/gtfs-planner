defmodule GtfsPlanner.Gtfs.Blocking.ConcurrencyTest do
  @moduledoc """
  Merge evidence (EV-12) for CL-11: INV-1's lock contract holds under concurrent
  writers, so FH-11's three failures stay rejected.

  Each case commits its own disposable organization, version, route, actor, service
  and trips on an own connection, because every holder and every apply runs on an
  own connection and must see them, and deletes exactly those rows in `on_exit` even
  when the test fails. The interleavings are deterministic: a holder keeps its lock
  open until the test releases it, and the test waits for the other backend's
  `pg_stat_activity` lock wait through `wait_until_locked/2` (bounded to 5 s) instead
  of sleeping on a guess.

  - case 1 — a third connection holds `pg_advisory_xact_lock(hashtext('blocking:' ||
    version_id))`; two `:new` applies on different trips of one service both wait for
    it, and after the release both succeed with different block IDs (R8, R11, AC-14);
  - case 2 — after `{:needs_confirmation, review}`, a holder retimes a non-targeted
    trip of the touched block and advances its `updated_at` without committing; the
    confirmed apply waits on that row lock, and once the holder commits the apply
    returns `{:error, {:stale_review, _}}` with no `block_id` changed;
  - case 3 — `:reviewed_apply_transaction` is the Mox mock: one raised
    `%Postgrex.Error{postgres: %{code: :deadlock_detected}}` retries into the real
    sandbox module and succeeds, three raised deadlocks return `{:error, :busy}`
    without raising, and `on_exit` restores the application env;
  - case 4 — a holder updates two trips of the touched block in descending UUID
    order with `update_all` while an apply runs; the apply returns a tagged result
    and never raises out of the command.

  The applies run at READ COMMITTED: `config/test.exs` selects
  `ReviewedApplyTransaction.Sandbox`, a plain `Repo.transaction`. SERIALIZABLE, the
  production module's `40001` snapshot behaviour, and a real server-side deadlock
  are outside this test's scope. The focused gate command is deferred to branch
  review: `mix test test/gtfs_planner/gtfs/blocking/concurrency_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # Every case holds one lock open and observes another backend's wait, so each test
  # is bounded: EV-12's 120 s command deadline per test, and a 10 s self-release for
  # any hold the test never gets to release.
  @moduletag timeout: 120_000

  @weekday_service "WK"
  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  describe "new-block ID allocation under a held blocking lock" do
    test "two new-block applies wait for the lock and resolve different IDs" do
      scope =
        committed_scope(%{
          p: %{trip_id: "p", first_arrival: "08:00:00", last_arrival: "09:00:00"},
          q: %{trip_id: "q", first_arrival: "10:00:00", last_arrival: "11:00:00"}
        })

      on_exit(fn -> cleanup_committed_scope(scope) end)

      day_type_key = weekday_key(scope)
      parent = self()

      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      first =
        Task.async(fn ->
          apply_on_own_connection(
            scope,
            day_type_key,
            {:assign, [scope.trips.p.id], :new},
            nil,
            parent
          )
        end)

      assert_receive {:apply_pid, first_pid}, @receive_timeout

      second =
        Task.async(fn ->
          apply_on_own_connection(
            scope,
            day_type_key,
            {:assign, [scope.trips.q.id], :new},
            nil,
            parent
          )
        end)

      assert_receive {:apply_pid, second_pid}, @receive_timeout

      # Both applies are inside their own transaction, past the version read, and
      # waiting for the advisory lock the third connection owns.
      assert wait_until_locked(first_pid)
      assert wait_until_locked(second_pid)

      send(holder.pid, :release)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      assert {:ok, first_result} = Task.await(first, @task_timeout)
      assert {:ok, second_result} = Task.await(second, @task_timeout)

      assert first_result.block_id != second_result.block_id
      assert Enum.sort([first_result.block_id, second_result.block_id]) == ["1", "2"]
      assert first_result.changed_trip_ids == [scope.trips.p.id]
      assert second_result.changed_trip_ids == [scope.trips.q.id]

      assert persisted(scope.trips.p).block_id == first_result.block_id
      assert persisted(scope.trips.q).block_id == second_result.block_id
      assert change_log_count(scope) == 2
    end
  end

  describe "a retime of a non-targeted trip of the touched block" do
    test "the confirmed apply is stale and writes nothing" do
      scope =
        committed_scope(%{
          a: %{
            trip_id: "a",
            block_id: "101",
            first_arrival: "08:00:00",
            last_arrival: "09:00:00"
          },
          b: %{
            trip_id: "b",
            block_id: "101",
            first_arrival: "11:00:00",
            last_arrival: "12:00:00"
          },
          c: %{trip_id: "c", first_arrival: "08:30:00", last_arrival: "09:30:00"}
        })

      on_exit(fn -> cleanup_committed_scope(scope) end)

      day_type_key = weekday_key(scope)
      command = {:assign, [scope.trips.c.id], "101"}

      # The assignment overlaps the "101" trip it joins, so the command needs
      # confirmation and carries the fingerprint to confirm.
      assert {:needs_confirmation, review} =
               unboxed(fn -> apply_command(scope, day_type_key, command, nil) end)

      assert review.needs_confirmation?
      assert review.target == "101"

      parent = self()
      retimed = "12:30:00"
      holder = Task.async(fn -> hold_retime(scope, scope.trips.b, retimed, parent) end)
      assert_receive {:retime_held, 1, 1}, @receive_timeout

      applier =
        Task.async(fn ->
          apply_on_own_connection(scope, day_type_key, command, review.fingerprint, parent)
        end)

      assert_receive {:apply_pid, apply_pid}, @receive_timeout

      # The apply's `FOR UPDATE` reaches the touched block while the holder still
      # owns the retimed trip's row lock.
      assert wait_until_locked(apply_pid)

      send(holder.pid, :commit)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      assert {:error, {:stale_review, refreshed}} = Task.await(applier, @task_timeout)
      assert refreshed.fingerprint != review.fingerprint

      # The retime the holder committed is what the apply re-read under the lock.
      assert last_departure_time(scope, scope.trips.b) == retimed

      assert DateTime.compare(persisted(scope.trips.b).updated_at, scope.trips.b.updated_at) ==
               :gt

      assert persisted(scope.trips.a).block_id == "101"
      assert persisted(scope.trips.b).block_id == "101"
      assert persisted(scope.trips.c).block_id == nil
      assert change_log_count(scope) == 0
    end
  end

  describe "retry classification through the configured transaction module" do
    test "one deadlock retries into the sandbox module and three report busy" do
      scope =
        committed_scope(%{
          x: %{trip_id: "x", first_arrival: "08:00:00", last_arrival: "09:00:00"},
          y: %{trip_id: "y", first_arrival: "10:00:00", last_arrival: "11:00:00"}
        })

      on_exit(fn -> cleanup_committed_scope(scope) end)

      day_type_key = weekday_key(scope)
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 1, fn _transaction ->
        raise postgrex_deadlock()
      end)

      expect(ReviewedApplyTransactionMock, :run, 1, fn transaction ->
        ReviewedApplyTransaction.Sandbox.run(transaction)
      end)

      assert {:ok, result} =
               unboxed(fn ->
                 apply_command(scope, day_type_key, {:assign, [scope.trips.x.id], "101"}, nil)
               end)

      assert result.changed_trip_ids == [scope.trips.x.id]
      assert result.block_id == "101"
      assert persisted(scope.trips.x).block_id == "101"
      assert change_log_count(scope) == 1

      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
        raise postgrex_deadlock()
      end)

      assert {:error, :busy} =
               unboxed(fn ->
                 apply_command(scope, day_type_key, {:assign, [scope.trips.y.id], "101"}, nil)
               end)

      assert persisted(scope.trips.y).block_id == nil
      assert change_log_count(scope) == 1
    end
  end

  describe "a writer holding the touched block's rows in descending order" do
    test "the apply returns a tagged result instead of raising" do
      scope =
        committed_scope(%{
          t1: %{
            trip_id: "t1",
            block_id: "101",
            first_arrival: "08:00:00",
            last_arrival: "09:00:00"
          },
          t2: %{
            trip_id: "t2",
            block_id: "101",
            first_arrival: "10:00:00",
            last_arrival: "11:00:00"
          },
          c: %{trip_id: "c", first_arrival: "06:00:00", last_arrival: "07:00:00"},
          d: %{trip_id: "d", first_arrival: "12:00:00", last_arrival: "13:00:00"}
        })

      on_exit(fn -> cleanup_committed_scope(scope) end)

      day_type_key = weekday_key(scope)
      parent = self()
      block_trips = Enum.sort_by([scope.trips.t1, scope.trips.t2], & &1.id)

      # Two changes always need confirmation, so the command reaches the review and
      # reports its tag whatever the holder's rows do.
      command = {:assign, [scope.trips.c.id, scope.trips.d.id], "101"}

      holder = Task.async(fn -> hold_descending_touch(scope, block_trips, parent) end)
      assert_receive {:touch_held, 2}, @receive_timeout

      applier =
        Task.async(fn ->
          apply_on_own_connection(scope, day_type_key, command, nil, parent)
        end)

      assert_receive {:apply_pid, apply_pid}, @receive_timeout

      # The apply's ascending `FOR UPDATE` waits on the two rows this reverse-order
      # writer holds.
      assert wait_until_locked(apply_pid)

      send(holder.pid, :commit)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      # A raise would crash the linked task, so `Task.await/2` failing here is what
      # rejects FH-11's "a deadlock raises out of the action".
      assert {:needs_confirmation, review} = Task.await(applier, @task_timeout)
      assert review.needs_confirmation?

      assert Enum.all?(block_trips, fn trip ->
               DateTime.compare(persisted(trip).updated_at, trip.updated_at) == :gt
             end)

      assert persisted(scope.trips.c).block_id == nil
      assert persisted(scope.trips.d).block_id == nil
      assert change_log_count(scope) == 0
    end
  end

  # Committed fixtures for one case: a fresh organization, version, route, actor, the
  # weekday service and the trips the case names. They are created on an own
  # connection because the holders and the applies run on their own connections and
  # must see them; `cleanup_committed_scope/1` deletes exactly these rows.
  defp committed_scope(trip_specs) do
    unboxed(fn ->
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      route = route_fixture(organization.id, version.id)
      actor = editor_fixture(organization)

      calendar_service_fixture(organization.id, version.id, %{
        service_id: @weekday_service,
        name: "Weekday"
      })

      trips =
        Map.new(trip_specs, fn {key, attrs} ->
          {key,
           blocked_trip_fixture(
             organization.id,
             version.id,
             route.route_id,
             Map.put_new(attrs, :service_id, @weekday_service)
           )}
        end)

      %{
        organization_id: organization.id,
        version_id: version.id,
        actor_id: actor.id,
        trips: trips,
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          station_stop_id: nil,
          actor_id: actor.id,
          actor_email: actor.email
        }
      }
    end)
  end

  # Deletes exactly the rows `committed_scope/1` created and the applies' change logs,
  # keyed to their own organization, on an own connection so the deletion is not part
  # of the SQL Sandbox transaction and runs even when the test failed.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      organization_id = scope.organization_id

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(c in CalendarAttribute, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(c in CalendarDate, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^scope.actor_id))
    end)
  end

  # The weekday day type's key from `Calendars.list_calendars/3` (the single
  # service-date source) on an own connection: its version `FOR SHARE` lock must not
  # outlive the read, or the sandboxed test process would block the cleanup's delete
  # of the version row.
  defp weekday_key(scope) do
    unboxed(fn ->
      {:ok, calendars} = Calendars.list_calendars(scope.organization_id, scope.version_id)

      day_type =
        Enum.find(DayTypes.derive(calendars), &(&1.service_ids == [@weekday_service]))

      assert day_type, "the fixtures carry no #{@weekday_service} day type"
      day_type.key
    end)
  end

  defp apply_command(scope, day_type_key, command, confirmation) do
    Gtfs.apply_block_change(day_type_key, command, scope.audit, confirmation)
  end

  # An apply on its own connection: its transaction must commit for the advisory lock
  # and its row locks to be released, and it reports the backend pid the test polls.
  defp apply_on_own_connection(scope, day_type_key, command, confirmation, parent) do
    unboxed(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
      send(parent, {:apply_pid, backend_pid})
      apply_command(scope, day_type_key, command, confirmation)
    end)
  end

  # Holds the version's blocking lock on an own connection, with the statement
  # `Blocking.lock_blocking!/1` issues, until the test releases it.
  defp hold_blocking_lock(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "blocking:" <> scope.version_id
        ])

        send(parent, :blocking_lock_held)

        receive do
          :release -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # Retimes one trip's last stop and advances its `updated_at`, holding both row locks
  # uncommitted until the test commits them, so a confirmed apply that reaches the
  # touched block waits for this writer's decision about the trip.
  defp hold_retime(scope, trip, new_time, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        {stop_times, _} =
          Repo.update_all(
            from(st in StopTime,
              where:
                st.organization_id == ^scope.organization_id and
                  st.gtfs_version_id == ^scope.version_id and st.trip_id == ^trip.trip_id and
                  st.stop_sequence == 2
            ),
            set: [arrival_time: new_time, departure_time: new_time]
          )

        {trips, _} =
          Repo.update_all(
            from(t in Trip,
              where:
                t.organization_id == ^scope.organization_id and
                  t.gtfs_version_id == ^scope.version_id and t.id == ^trip.id
            ),
            set: [updated_at: DateTime.utc_now()]
          )

        send(parent, {:retime_held, stop_times, trips})

        receive do
          :commit -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # Updates two trips of the touched block in descending UUID order and holds their
  # row locks until the test commits them. The locked `select` makes the descending
  # order the lock order, so this writer takes the rows the apply's ascending
  # `FOR UPDATE` takes, in the reverse sequence.
  defp hold_descending_touch(scope, trips, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        ids = Enum.map(trips, & &1.id)

        descending =
          from(t in Trip,
            where:
              t.organization_id == ^scope.organization_id and
                t.gtfs_version_id == ^scope.version_id and t.id in ^ids,
            order_by: [desc: t.id],
            select: t.id,
            lock: "FOR UPDATE"
          )

        {updated, _} =
          Repo.update_all(
            from(t in Trip,
              where:
                t.organization_id == ^scope.organization_id and
                  t.gtfs_version_id == ^scope.version_id and t.id in subquery(descending)
            ),
            set: [updated_at: DateTime.utc_now()]
          )

        send(parent, {:touch_held, updated})

        receive do
          :commit -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # The blocked backend reports itself in `pg_stat_activity` once it waits on the
  # lock, which is deterministic; the test polls it instead of sleeping on a guess.
  # The bound mirrors `schedules_test.exs`'s `wait_until_locked/2`: 500 attempts of
  # 10 ms, so 5 s.
  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    waiting =
      unboxed(fn ->
        {:ok, %{rows: [[waiting]]}} =
          Repo.query(
            "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock'",
            [pid]
          )

        waiting
      end)

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        flunk("the backend #{inspect(pid)} never waited on a lock")

      true ->
        Process.sleep(10)
        wait_until_locked(pid, attempts - 1)
    end
  end

  # Case 3 swaps the application's transaction boundary for the Mox mock, so the
  # original value is captured before the change and restored in `on_exit`
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

  # What a real server raises for SQLSTATE 40P01; the retry path classifies it by the
  # normalised atom, so no live deadlock is needed to exercise the retry.
  defp postgrex_deadlock do
    %Postgrex.Error{
      postgres: %{code: :deadlock_detected, message: "deadlock detected", severity: "ERROR"}
    }
  end

  defp persisted(%{id: id}), do: Repo.get!(Trip, id)

  defp last_departure_time(scope, trip) do
    Repo.one!(
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization_id and
            st.gtfs_version_id == ^scope.version_id and st.trip_id == ^trip.trip_id and
            st.stop_sequence == 2,
        select: st.departure_time
      )
    )
  end

  defp change_log_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization_id and
            l.gtfs_version_id == ^scope.version_id and l.entity_type == "trip"
      ),
      :count
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
