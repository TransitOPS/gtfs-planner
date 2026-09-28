defmodule GtfsPlanner.Gtfs.Transfers.ConcurrencyTest do
  @moduledoc """
  Merge evidence (EV-12) for the SERIALIZABLE write interleavings.

  A create or update that names trip X must compose with `Schedules.delete_trips/4`
  of X in either commit order, a second write of one rule must end `:stale` instead
  of overwriting it, and a key collision must be reported after the failed
  transaction has rolled back — never by raising inside it.

  Two sessions commit independently, each on its own connection through
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, and a message barrier immediately
  before commit orders them (`GtfsPlanner.Gtfs.TransferBarrierTransaction`), so the
  interleaving is forced rather than hoped for. Each case runs the production
  transaction module's isolation level (SERIALIZABLE) through the public `Gtfs`
  facades; only the module itself is replaced, because `config/test.exs` configures
  a plain sandbox transaction that would make these cases prove nothing. The final
  state is read on a third connection.

  The assertions fix each session's allowed outcome set and, for the trip-deletion
  races, the invariant SERIALIZABLE exists to keep: no committed transfer names a
  trip row that is gone. Whichever session SSI aborts, or which runs out of retries
  as `:busy`, the invariant must hold — a create that commits a reference to a
  deleted trip is rejected here.

  EV-12 does not prove the single-session write cases (EV-9, EV-10, EV-11), the
  retry counts (EV-9), the LiveView surfaces (EV-20 … EV-25), or any interleaving
  other than the forced ones on one local PostgreSQL instance.

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner/gtfs/transfers/concurrency_test.exs`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.TransferBarrierTransaction
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.TransfersFixtures
  alias GtfsPlanner.Versions.GtfsVersion

  # The fixture network's calendar and route, so the extra trip X is deleted through
  # the same natural IDs a caller uses.
  @service "WKDY"
  @route "12"
  # The schedules concurrency precedent's window for "must not have finished" and
  # its per-step collect timeout.
  @lock_wait 500
  @collect_timeout 10_000
  @poll 100
  # The process-dictionary key `TransferBarrierTransaction` reads.
  @barrier :transfer_barrier

  # These cases replace the global write transaction module (CR-11), so the module
  # is non-async and restores the exact previous value.
  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, TransferBarrierTransaction)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    %{supervisor: supervisor}
  end

  describe "a create racing the deletion of the trip it names" do
    test "a create paused before commit, then a delete that commits first", %{
      supervisor: supervisor
    } do
      scope = seed_scope("create-then-delete")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      creator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(@barrier, parent)
          unboxed(fn -> Gtfs.create_general_transfer(trip_rule_attrs(scope), scope.audit) end)
        end)

      assert_receive {:before_commit, create_pid}, @collect_timeout
      assert create_pid == creator.pid
      on_exit(fn -> send(create_pid, :commit) end)

      # The create has written its row and holds it uncommitted, so the delete on
      # its own connection cannot see that transfer yet.
      delete_result = unboxed(fn -> delete_trip_x(scope) end)

      assert delete_result in [{:ok, %{trips: 1, transfers: 0}}, {:error, :busy}]

      send(create_pid, :commit)
      create_result = await_task(creator, @collect_timeout)

      assert_created_busy_or_missing_trip(create_result)

      case delete_result do
        {:ok, %{trips: 1, transfers: 0}} -> refute trip_exists?(scope)
        {:error, :busy} -> assert trip_exists?(scope)
      end

      # The invariant both commit orders must keep: no committed transfer names a
      # trip row that is gone.
      refute dangling_transfer?(scope)
    end

    test "a delete paused before commit, then a create that commits first", %{
      supervisor: supervisor
    } do
      scope = seed_scope("delete-then-create")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      deleter =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(@barrier, parent)
          unboxed(fn -> delete_trip_x(scope) end)
        end)

      assert_receive {:before_commit, delete_pid}, @collect_timeout
      assert delete_pid == deleter.pid
      on_exit(fn -> send(delete_pid, :commit) end)

      # The deleter has removed trip X and its children but has not committed, so
      # the create still reads trip X and may write a rule naming it.
      creator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn -> Gtfs.create_general_transfer(trip_rule_attrs(scope), scope.audit) end)
        end)

      create_result = await_task(creator, @collect_timeout)
      assert_created_busy_or_missing_trip(create_result)

      send(delete_pid, :commit)
      delete_result = await_task(deleter, @collect_timeout)

      case delete_result do
        {:ok, %{trips: 1, transfers: count}} ->
          # A delete that committed sees the create's row exactly when the create
          # committed, and then removes it with the trip.
          assert count == if(match?({:ok, _created}, create_result), do: 1, else: 0)
          refute transfer_names_trip?(scope)

        {:error, :busy} ->
          # Nothing was deleted, so trip X is still there and the rule may name it.
          assert trip_exists?(scope)
      end

      refute dangling_transfer?(scope)
    end
  end

  describe "two sessions writing one rule" do
    test "the second update of the same rule ends stale", %{supervisor: supervisor} do
      scope = seed_scope("update-race")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      row = create_rule(scope, %{"min_transfer_time" => "180"})

      first =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(@barrier, parent)

          unboxed(fn ->
            Gtfs.update_general_transfer(
              row.id,
              %{"min_transfer_time" => "300"},
              row.updated_at,
              scope.audit
            )
          end)
        end)

      assert_receive {:before_commit, first_pid}, @collect_timeout
      assert first_pid == first.pid
      on_exit(fn -> send(first_pid, :commit) end)

      second =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:second_ready, self()})

          unboxed(fn ->
            Gtfs.update_general_transfer(
              row.id,
              %{"min_transfer_time" => "600"},
              row.updated_at,
              scope.audit
            )
          end)
        end)

      assert_receive {:second_ready, second_pid}, @collect_timeout
      assert second_pid == second.pid

      # The first update holds the row's write lock, so the second cannot finish
      # inside this window however it loses.
      refute Task.yield(second, @lock_wait)

      send(first_pid, :commit)
      assert {:ok, %Transfer{min_transfer_time: 300}} = await_task(first, @collect_timeout)
      assert {:error, :stale} = await_task(second, @collect_timeout)

      # The stale update wrote nothing: the stored minimum time is the first update's.
      assert reload(scope, row.id).min_transfer_time == 300
    end

    test "a bulk delete of two rules deletes nothing when one member changed concurrently", %{
      supervisor: supervisor
    } do
      scope = seed_scope("bulk-delete-race")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      changed = create_rule(scope, %{"min_transfer_time" => "180"})
      untouched = create_rule(scope, %{"to_stop_id" => "HBR", "min_transfer_time" => "120"})

      updater =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(@barrier, parent)

          unboxed(fn ->
            Gtfs.update_general_transfer(
              changed.id,
              %{"min_transfer_time" => "300"},
              changed.updated_at,
              scope.audit
            )
          end)
        end)

      assert_receive {:before_commit, updater_pid}, @collect_timeout
      assert updater_pid == updater.pid
      on_exit(fn -> send(updater_pid, :commit) end)

      pairs = [{changed.id, changed.updated_at}, {untouched.id, untouched.updated_at}]

      deleter =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:deleter_ready, self()})
          unboxed(fn -> Gtfs.delete_general_transfers(pairs, scope.audit) end)
        end)

      assert_receive {:deleter_ready, deleter_pid}, @collect_timeout
      assert deleter_pid == deleter.pid

      # The batch loaded both rows as fresh and is now waiting on the changed row's
      # write lock, so it cannot have deleted anything yet.
      refute Task.yield(deleter, @lock_wait)

      send(updater_pid, :commit)
      assert {:ok, %Transfer{}} = await_task(updater, @collect_timeout)
      assert {:error, :stale} = await_task(deleter, @collect_timeout)

      # All-or-nothing: the member no session wrote is still stored, and the stale
      # member keeps the update's value.
      assert reload(scope, changed.id).min_transfer_time == 300
      assert reload(scope, untouched.id).min_transfer_time == 120
    end
  end

  describe "duplicate recovery under the production transaction" do
    test "a second create of one stop-only key reports the row that holds it" do
      scope = seed_scope("duplicate")
      on_exit(fn -> cleanup([scope]) end)

      attrs = %{"from_stop_id" => "CEN-A", "to_stop_id" => "CEN-C", "transfer_type" => "0"}

      assert {:ok, first} = unboxed(fn -> Gtfs.create_general_transfer(attrs, scope.audit) end)

      # The collision lookup runs after the aborted transaction has rolled back, so
      # it must read the stored row rather than raise inside the aborted one.
      assert {:error, {:duplicate, collision}} =
               unboxed(fn -> Gtfs.create_general_transfer(attrs, scope.audit) end)

      assert collision == %{id: first.id, transfer_type: 0}
      assert transfer_count(scope) == 1
      assert change_log_count(scope) == 1
    end

    test "an in-seat row holding the same six-field key collides the same way" do
      scope = seed_scope("duplicate-in-seat")
      on_exit(fn -> cleanup([scope]) end)

      in_seat =
        unboxed(fn ->
          transfer_fixture(scope.organization.id, scope.version.id, %{
            from_stop_id: "MKT",
            to_stop_id: "HBR",
            from_trip_id: "12-1010",
            to_trip_id: "24-0920",
            transfer_type: 4
          })
        end)

      # Empty equals empty and the type is not part of the key (R5, INV-3), so a
      # general rule with the in-seat row's key is refused, not written.
      assert {:error, {:duplicate, collision}} =
               unboxed(fn ->
                 Gtfs.create_general_transfer(
                   %{
                     "from_stop_id" => "MKT",
                     "to_stop_id" => "HBR",
                     "from_trip_id" => "12-1010",
                     "to_trip_id" => "24-0920",
                     "transfer_type" => "0"
                   },
                   scope.audit
                 )
               end)

      assert collision == %{id: in_seat.id, transfer_type: 4}
      assert transfer_count(scope) == 1
    end
  end

  # -- Sessions --------------------------------------------------------------

  # The create's allowed outcomes: it committed, its retries were exhausted, or the
  # retry after a serialization abort no longer found trip X.
  defp assert_created_busy_or_missing_trip(result) do
    case result do
      {:ok, %Transfer{}} ->
        :ok

      {:error, :busy} ->
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        assert {"Choose a trip in this version", _meta} = changeset.errors[:from_trip_id]

      other ->
        flunk("unexpected create result: #{inspect(other)}")
    end
  end

  defp delete_trip_x(scope), do: Gtfs.delete_trips(@route, @service, [scope.trip.id], scope.audit)

  # A stop-only type 2 rule from CEN-A, overridden by the caller's string keys.
  defp create_rule(scope, attrs) do
    unboxed(fn ->
      {:ok, transfer} =
        Gtfs.create_general_transfer(
          Map.merge(
            %{"from_stop_id" => "CEN-A", "to_stop_id" => "CEN-C", "transfer_type" => "2"},
            attrs
          ),
          scope.audit
        )

      transfer
    end)
  end

  defp trip_rule_attrs(scope) do
    %{
      "from_stop_id" => "CEN",
      "to_stop_id" => "HBR",
      "from_route_id" => @route,
      "from_trip_id" => scope.trip.trip_id,
      "transfer_type" => "0"
    }
  end

  # Answers every before-commit message from a paused session with :commit until the
  # task returns. A retry after a serialization abort runs the transaction body again
  # and reaches the barrier again, so each message is answered as it arrives rather
  # than once.
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

  # -- Final state, read on a fresh connection -------------------------------

  # INV-4/AC-9: a transfer may name trip X only while X's row is still there. A
  # transfer naming a missing trip is the dangling reference both commit orders
  # must avoid.
  defp dangling_transfer?(scope) do
    not trip_exists?(scope) and transfer_names_trip?(scope)
  end

  defp trip_exists?(scope) do
    unboxed(fn -> Repo.exists?(from(t in Trip, where: t.id == ^scope.trip.id)) end)
  end

  defp transfer_names_trip?(scope) do
    unboxed(fn ->
      Repo.exists?(
        from(t in Transfer,
          where:
            t.organization_id == ^scope.organization.id and
              (t.from_trip_id == ^scope.trip.trip_id or t.to_trip_id == ^scope.trip.trip_id)
        )
      )
    end)
  end

  defp reload(scope, id) do
    unboxed(fn ->
      Repo.get_by!(Transfer, id: id, organization_id: scope.organization.id)
    end)
  end

  defp transfer_count(scope) do
    unboxed(fn ->
      Repo.aggregate(
        from(t in Transfer, where: t.organization_id == ^scope.organization.id),
        :count
      )
    end)
  end

  defp change_log_count(scope) do
    unboxed(fn ->
      Repo.aggregate(
        from(l in ChangeLog,
          where: l.organization_id == ^scope.organization.id and l.entity_type == "transfer"
        ),
        :count
      )
    end)
  end

  # -- Committed scope and cleanup -------------------------------------------

  # One organization per case, built in `unboxed` so the two racing sessions can see
  # the rows on their own connections: the shared literal network, one extra route 12
  # trip X serving CEN-A and HBR, the calendar its trips name, and an actor.
  defp seed_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization =
        organization_fixture(%{alias: "transfer-concurrency-#{suffix}-#{unique}"})

      version = gtfs_version_fixture(organization.id)
      TransfersFixtures.transfer_network_fixture(organization.id, version.id)
      actor = user_fixture()

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }

      {:ok, _calendar} = Gtfs.create_calendar(calendar_attrs(suffix), audit)

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        trip: extra_trip(organization.id, version.id, unique)
      }
    end)
  end

  defp calendar_attrs(suffix) do
    %{
      service_id: @service,
      name: "Transfers concurrency #{suffix}",
      kind: :weekly,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-02-27]
    }
  end

  defp extra_trip(organization_id, version_id, unique) do
    trip_id = "12-x#{unique}"

    trip =
      trip_fixture(organization_id, version_id, @route, %{
        trip_id: trip_id,
        service_id: @service,
        trip_headsign: "Harbor"
      })

    stop_time_fixture(organization_id, version_id, trip_id, "CEN-A", %{
      arrival_time: "09:00:00",
      departure_time: "09:00:00",
      stop_sequence: 1
    })

    stop_time_fixture(organization_id, version_id, trip_id, "HBR", %{
      arrival_time: "09:15:00",
      departure_time: "09:15:00",
      stop_sequence: 2
    })

    trip
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Deletes only the captured scope. The organization id is the captured root: every
  # row this file creates belongs to it, so nothing outside the fixture can be
  # touched.
  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids = Enum.map(scopes, & &1.organization.id)
      user_ids = Enum.map(scopes, & &1.actor.id)

      Repo.delete_all(from(t in Transfer, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id in ^organization_ids))

      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
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
end
