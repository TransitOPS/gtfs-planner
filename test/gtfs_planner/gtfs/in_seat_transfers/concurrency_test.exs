defmodule GtfsPlanner.Gtfs.InSeatTransfers.ConcurrencyTest do
  @moduledoc """
  Merge evidence (EV-6) for CL-4: in-seat writes serialize with block edits and
  reject lost updates, so FH-5's three failures stay rejected.

  Each case commits its own disposable organization, version, route, actor, service
  and trips on an own connection, because every holder and every write runs on an
  own connection and must see them, and deletes exactly those rows in `on_exit`
  even when the test fails.

  - case 1 — two sessions set the same pair from the same `expected` with the first
    paused before its commit: the second cannot finish inside that window, and
    after the first commits the second ends `{:error, :stale}` while the pair keeps
    the first session's type (AC-4);
  - case 2 — the Blocks command assigning trip X (timed between the pair) to the
    pair's block is paused before its commit with the blocking lock held; the write
    waits for the lock and, once the command commits, is refused with R1's own
    `{:refused, _}` naming X rather than writing a record that is no longer
    consecutive (R1, R4). The write's snapshot predates the command's commit, so the
    refusal comes from SERIALIZABLE aborting the first attempt — the command read
    the pair's in-seat records — and the retry reading the moved trip;
  - case 3 — `:reviewed_apply_transaction` is the Mox mock: one raised
    `%Postgrex.Error{postgres: %{code: :deadlock_detected}}` retries into the real
    sandbox module and succeeds, and three raised deadlocks return `{:error, :busy}`
    without raising out of the command, with `on_exit` restoring the application
    env (R4).

  Case 1 and case 2 run at the production boundary's SERIALIZABLE isolation
  through `GtfsPlanner.Gtfs.TransferBarrierTransaction`, because `config/test.exs`
  configures a plain sandbox transaction that would make these cases prove nothing.
  Case 3 runs on the default sandbox module.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/in_seat_transfers/concurrency_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.TransferBarrierTransaction
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # Every case holds one lock open and observes another backend's wait, so each
  # test is bounded: EV-6's 180 s command deadline, and `on_exit` releases any
  # paused session the test never gets to release.
  @moduletag timeout: 120_000

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000
  @lock_wait 500
  @collect_timeout 10_000
  @poll 100

  # The process-dictionary key `TransferBarrierTransaction` reads.
  @barrier :transfer_barrier

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    # The production isolation level, so the serialization behaviour these cases
    # are about is the real one. Case 3 swaps this again for the Mox mock.
    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, TransferBarrierTransaction)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    %{supervisor: supervisor}
  end

  describe "two sessions writing one pair" do
    test "the second set of the same pair ends stale", %{supervisor: supervisor} do
      scope = committed_scope("pair-race")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      first =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(@barrier, parent)
          unboxed(fn -> set_connection(scope, :stay_on_board, []) end)
        end)

      assert_receive {:before_commit, first_pid}, @collect_timeout
      assert first_pid == first.pid
      on_exit(fn -> send(first_pid, :commit) end)

      second =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:second_ready, self()})
          unboxed(fn -> set_connection(scope, :must_reboard, []) end)
        end)

      assert_receive {:second_ready, second_pid}, @receive_timeout
      assert second_pid == second.pid

      # The first session holds the pair's rows, so the second cannot finish inside
      # this window however it loses.
      refute Task.yield(second, @lock_wait)

      send(first_pid, :commit)
      assert {:ok, %{choice: :stay_on_board}} = await_task(first, @collect_timeout)
      assert {:error, :stale} = await_task(second, @collect_timeout)

      # The stale session wrote nothing: the pair keeps the first session's single
      # type 4 row.
      rows = pair_rows(scope)
      assert length(rows) == 1
      assert hd(rows).transfer_type == 4
    end
  end

  describe "a block edit holding the blocking lock" do
    test "the write waits for the lock and is refused once the pair is not next", %{
      supervisor: supervisor
    } do
      scope = committed_scope("blocking-lock")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      # A → B is consecutive in block 101 while X, timed between them, is not
      # blocked. The holder is the Blocks command that assigns X to block 101,
      # paused before its commit with the blocking lock held: exactly the edit the
      # save must not write across.
      holder =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(@barrier, parent)
          unboxed(fn -> assign_x_to_block(scope) end)
        end)

      assert_receive {:before_commit, holder_pid}, @collect_timeout
      assert holder_pid == holder.pid
      on_exit(fn -> send(holder_pid, :commit) end)

      writer =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
            send(parent, {:write_pid, backend_pid})
            set_connection(scope, :stay_on_board, [])
          end)
        end)

      assert_receive {:write_pid, write_pid}, @receive_timeout
      assert wait_until_locked(write_pid)

      send(holder_pid, :commit)
      assert {:ok, %{changed_trip_ids: [_moved]}} = await_task(holder, @task_timeout)

      # The write's snapshot predates the command's commit. The command read the
      # pair's in-seat records and the write read X's pre-move row, so SERIALIZABLE
      # aborts the write and the retry evaluates R1 against the moved trip.
      assert {:error, {:refused, {:stale, {:not_next, [%{next_trip_id: "X"}]}}}} =
               await_task(writer, @collect_timeout)

      # The refusal wrote nothing: no row and no transfer log for the pair.
      assert pair_rows(scope) == []
      assert change_log_count(scope) == 0
    end
  end

  describe "retry classification through the configured transaction module" do
    test "one deadlock retries into the sandbox module and three report busy" do
      scope = committed_scope("deadlock")
      on_exit(fn -> cleanup([scope]) end)

      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 1, fn _transaction ->
        raise postgrex_deadlock()
      end)

      expect(ReviewedApplyTransactionMock, :run, 1, fn transaction ->
        ReviewedApplyTransaction.Sandbox.run(transaction)
      end)

      assert {:ok, %{choice: :stay_on_board}} =
               unboxed(fn -> set_connection(scope, :stay_on_board, []) end)

      assert length(pair_rows(scope)) == 1
      assert change_log_count(scope) == 1

      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
        raise postgrex_deadlock()
      end)

      # A raise out of the command would crash the process instead of answering, so
      # this is what rejects FH-5's "a deadlock raises out of the command".
      assert {:error, :busy} =
               unboxed(fn -> set_connection(scope, :must_reboard, expected_rows(scope)) end)

      # The exhausted write changed nothing: the pair still holds the first save's
      # single type 4 row.
      rows = pair_rows(scope)
      assert length(rows) == 1
      assert hd(rows).transfer_type == 4
      assert change_log_count(scope) == 1
    end
  end

  # -- Sessions --------------------------------------------------------------

  defp set_connection(scope, choice, expected) do
    Gtfs.set_in_seat_connection("a", "b", choice, expected, scope.audit)
  end

  # The production Blocks command, through the configured transaction module, so
  # it takes the blocking lock and reads the pair's in-seat records exactly as an
  # editor's assign does.
  defp assign_x_to_block(scope) do
    Gtfs.apply_block_change(nil, {:assign, [scope.trips.x.id], "101"}, scope.audit)
  end

  # Answers every before-commit message from a paused session with :commit until
  # the task returns. A retry after a serialization abort runs the transaction body
  # again and reaches the barrier again, so each message is answered as it arrives
  # rather than once.
  defp await_task(task, timeout) do
    await_task(task, System.monotonic_time(:millisecond) + timeout, timeout)
  end

  defp await_task(task, deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("the session did not return within #{timeout} ms")
    else
      receive do
        {:before_commit, pid} ->
          send(pid, :commit)
          await_task(task, deadline, timeout)
      after
        min(remaining, @poll) ->
          case Task.yield(task, min(remaining, @poll)) do
            {:ok, result} -> result
            {:exit, reason} -> flunk("the session exited before returning: #{inspect(reason)}")
            nil -> await_task(task, deadline, timeout)
          end
      end
    end
  end

  # The blocked backend reports itself in `pg_stat_activity` once it waits on the
  # lock, which is deterministic; the test polls it instead of sleeping on a guess.
  # The bound mirrors `blocking/concurrency_test.exs`: 500 attempts of 10 ms.
  #
  # The poll reads on this process's own sandbox connection instead of checking one
  # out: the case already holds a connection in its holder and one in the blocked
  # writer, and a further checkout would demand a pool connection a host with few
  # schedulers does not have, turning the poll into a `pool_timeout` error.
  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock'",
        [pid]
      )

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

  # What a real server raises for SQLSTATE 40P01; the retry path classifies it by
  # the normalised atom, so no live deadlock is needed to exercise the retry.
  defp postgrex_deadlock do
    %Postgrex.Error{
      postgres: %{code: :deadlock_detected, message: "deadlock detected", severity: "ERROR"}
    }
  end

  defp pair_rows(scope) do
    unboxed(fn ->
      Repo.all(
        from(t in Transfer,
          where:
            t.organization_id == ^scope.organization_id and
              t.gtfs_version_id == ^scope.version_id and t.from_trip_id == "a" and
              t.to_trip_id == "b",
          order_by: [asc: t.id]
        )
      )
    end)
  end

  defp expected_rows(scope) do
    Enum.map(
      pair_rows(scope),
      &%{
        id: &1.id,
        transfer_type: &1.transfer_type,
        updated_at: &1.updated_at
      }
    )
  end

  defp change_log_count(scope) do
    unboxed(fn ->
      Repo.aggregate(
        from(l in ChangeLog,
          where: l.organization_id == ^scope.organization_id and l.entity_type == "transfer"
        ),
        :count
      )
    end)
  end

  # -- Committed scope and cleanup -------------------------------------------

  # One organization per case, built in `unboxed` so the racing sessions can see
  # the rows on their own connections: A and B share block 101 and X is blocked
  # nowhere until a case moves it, on one service running on three dates so a
  # single day type is derived.
  defp committed_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization =
        organization_fixture(%{alias: "in-seat-concurrency-#{suffix}-#{unique}"})

      version = gtfs_version_fixture(organization.id)
      route = route_fixture(organization.id, version.id)
      actor = user_fixture()
      organization_membership_fixture(actor, organization)

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

      trip =
        fn attrs ->
          blocked_trip_fixture(organization.id, version.id, route.route_id, attrs)
        end

      a =
        trip.(%{
          trip_id: "a",
          service_id: "W",
          block_id: "101",
          first_arrival: "06:00:00",
          last_arrival: "07:00:00"
        })

      x =
        trip.(%{
          trip_id: "X",
          service_id: "W",
          first_arrival: "07:05:00",
          last_arrival: "08:05:00"
        })

      _b =
        trip.(%{
          trip_id: "b",
          service_id: "W",
          block_id: "101",
          first_arrival: "08:10:00",
          last_arrival: "09:10:00"
        })

      %{
        organization: organization,
        organization_id: organization.id,
        version_id: version.id,
        actor: actor,
        trips: %{a: a, x: x},
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

  # Deletes only the captured scope. The organization id is the captured root:
  # every row this file creates belongs to it, so nothing outside the fixture can
  # be touched.
  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids = Enum.map(scopes, & &1.organization_id)
      user_ids = Enum.map(scopes, & &1.actor.id)

      Repo.delete_all(from(t in Transfer, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(c in CalendarDate, where: c.organization_id in ^organization_ids))

      Repo.delete_all(from(c in CalendarAttribute, where: c.organization_id in ^organization_ids))

      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))
      delete_versions!(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(t in Transfer, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
