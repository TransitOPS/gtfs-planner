defmodule GtfsPlanner.Gtfs.PathwayEvolutions.ConcurrencyTest do
  # A closure create racing a calendar delete or a last-native-row change for
  # one service must never both commit (AC-11, FH-3). `async: false` and
  # `Sandbox.unboxed_run/2` give every worker its own committing PostgreSQL
  # connection; the published version row is also used as a rendezvous so both
  # writers are genuinely released into contention instead of being observed
  # one after the other. Fixtures are committed and explicitly deleted.
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
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @lock_wait 500
  @collect_timeout 10_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  test "a concurrent closure create and calendar delete never both commit", %{
    supervisor: supervisor
  } do
    scope = seed_scope("create-delete")

    on_exit(fn -> cleanup([scope]) end)

    pre_fingerprint = unboxed(fn -> source_fingerprint(scope) end)

    results =
      race_through_locked_version(scope, supervisor, fn index ->
        if index == 0 do
          create_closure(scope)
        else
          review_and_apply_delete(scope)
        end
      end)

    assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))

    state = identity_state(scope)

    # Never both: a surviving closure implies its native calendar rows.
    refute state.closure_rows == 1 and state.exception_rows == 0

    assert {state.closure_rows, state.exception_rows} in [{1, 1}, {0, 0}]

    if state.closure_rows == 1 do
      # Closure usage moved the calendar counts and fingerprint.
      source = unboxed(fn -> source_payload(scope) end)
      refute source.fingerprint == pre_fingerprint
      assert source.usage.closure_count == 1
      assert source.usage.pathway_ids == ["PW_ENTRY"]
      assert source.usage.trip_count == 0
    else
      assert unboxed(fn -> Gtfs.get_calendar(scope.organization.id, scope.version.id, "SVC") end) ==
               {:error, :not_found}
    end
  end

  test "a concurrent closure create and last-native-row removal never both commit", %{
    supervisor: supervisor
  } do
    scope = seed_scope("create-remove")

    on_exit(fn -> cleanup([scope]) end)

    # The review token is issued while no closure exists; only the apply races
    # the create, so a committed create must stale the apply rather than let a
    # last-native-row change land beside a new closure reference.
    review =
      unboxed(fn ->
        {:ok, review} =
          Gtfs.review_calendar_change(
            {:remove_exceptions, "SVC", [~D[2026-07-04]]},
            %{"SVC" => source_fingerprint(scope)},
            scope.audit
          )

        review
      end)

    results =
      race_through_locked_version(scope, supervisor, fn index ->
        if index == 0 do
          create_closure(scope)
        else
          unboxed(fn ->
            Gtfs.apply_calendar_change(
              {:remove_exceptions, "SVC", [~D[2026-07-04]]},
              review.fingerprint,
              scope.audit
            )
          end)
        end
      end)

    assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))

    state = identity_state(scope)

    refute state.closure_rows == 1 and state.exception_rows == 0

    assert {state.closure_rows, state.exception_rows} in [{1, 1}, {0, 0}]
  end

  test "a concurrent closure insert and pathway delete has exactly one valid outcome", %{
    supervisor: supervisor
  } do
    scope = seed_scope("insert-delete")

    on_exit(fn -> cleanup([scope]) end)

    # Task.await in the harness re-raises a worker crash, so an uncaught FK
    # or aborted-transaction error fails this test instead of hiding.
    results =
      race_through_locked_version(scope, supervisor, fn index ->
        if index == 0 do
          create_closure(scope)
        else
          # Join the version-row rendezvous without changing the production
          # delete path: delete_pathway/1 takes no version lock, so the test
          # holds the row explicitly to prove both writers were blocked
          # before release, then runs the ordinary facade delete.
          Repo.one(from(v in GtfsVersion, where: v.id == ^scope.version.id, lock: "FOR UPDATE"))

          case Gtfs.get_pathway_by_pathway_id(
                 scope.organization.id,
                 scope.version.id,
                 "PW_ENTRY"
               ) do
            nil -> {:error, :not_found}
            pathway -> Gtfs.apply_import_entity(:remove, :pathway, pathway, %{})
          end
        end
      end)

    [create_result, delete_result] = results

    assert match?({:ok, %Pathway{}}, delete_result) or
             delete_result == {:error, :pathway_in_use}

    assert match?({:ok, %{evolution: %PathwayEvolution{}}}, create_result) or
             match?({:error, %Ecto.Changeset{}}, create_result)

    state =
      unboxed(fn ->
        organization_id = scope.organization.id
        version_id = scope.version.id

        %{
          pathway_rows:
            Repo.aggregate(
              from(p in Pathway,
                where:
                  p.organization_id == ^organization_id and
                    p.gtfs_version_id == ^version_id and p.pathway_id == "PW_ENTRY"
              ),
              :count
            ),
          closure_rows:
            Repo.aggregate(
              from(e in PathwayEvolution,
                where:
                  e.organization_id == ^organization_id and
                    e.gtfs_version_id == ^version_id and e.pathway_id == "PW_ENTRY"
              ),
              :count
            )
        }
      end)

    # Exactly one side wins: RESTRICT forbids a closure without its pathway,
    # and the guard forbids deleting a pathway that still has closures.
    assert {state.pathway_rows, state.closure_rows} in [{1, 1}, {0, 0}]

    if state.closure_rows == 1 do
      assert match?({:ok, _}, create_result)
      assert delete_result == {:error, :pathway_in_use}
    else
      assert match?({:ok, %Pathway{}}, delete_result)
      assert match?({:error, %Ecto.Changeset{}}, create_result)
    end
  end

  defp create_closure(scope) do
    Gtfs.create_pathway_evolution(
      %{pathway_id: "PW_ENTRY", service_id: "SVC", start_time: "09:00", end_time: "10:00"},
      scope.audit
    )
  end

  defp review_and_apply_delete(scope) do
    with {:ok, source} <-
           Gtfs.get_calendar(scope.organization.id, scope.version.id, "SVC"),
         {:ok, review} <-
           Gtfs.review_calendar_change(
             {:delete, "SVC"},
             %{"SVC" => source.fingerprint},
             scope.audit
           ) do
      Gtfs.apply_calendar_change({:delete, "SVC"}, review.fingerprint, scope.audit)
    end
  end

  defp source_fingerprint(scope), do: source_payload(scope).fingerprint

  defp source_payload(scope) do
    {:ok, payload} = Gtfs.get_calendar(scope.organization.id, scope.version.id, "SVC")
    payload
  end

  # Releases both workers into real contention for the version row while an
  # independent session holds its exclusive lock, then verifies each worker was
  # still blocked before the lock is released.
  defp race_through_locked_version(scope, supervisor, run) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> hold_version_lock(scope, parent) end)

    assert_receive {:version_locked, holder_pid}, @collect_timeout
    assert holder_pid == holder.pid

    workers = start_workers(supervisor, parent, run)

    Enum.each(workers, &send(&1.pid, :start))

    refute Task.yield(Enum.at(workers, 0), @lock_wait)
    refute Task.yield(Enum.at(workers, 1), @lock_wait)

    monitor = Process.monitor(holder.pid)
    send(holder.pid, :release)
    assert_receive {:DOWN, ^monitor, :process, ^holder_pid, _}, @collect_timeout

    Enum.map(workers, fn worker -> Task.await(worker, @collect_timeout) end)
  end

  defp hold_version_lock(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn -> lock_version_row(scope.version.id, parent) end)
    end)
  end

  defp lock_version_row(version_id, parent) do
    Repo.one(from(v in GtfsVersion, where: v.id == ^version_id, lock: "FOR UPDATE"))
    send(parent, {:version_locked, self()})

    receive do
      :release -> Repo.rollback(:released)
    end
  end

  defp start_workers(supervisor, parent, run) do
    workers =
      Enum.map([0, 1], fn index ->
        Task.Supervisor.async_nolink(supervisor, fn -> run_worker(index, parent, run) end)
      end)

    assert_receive {:worker_ready, 0}, @collect_timeout
    assert_receive {:worker_ready, 1}, @collect_timeout
    workers
  end

  defp run_worker(index, parent, run) do
    send(parent, {:worker_ready, index})

    receive do
      :start -> :ok
    end

    result = unboxed(fn -> run.(index) end)
    send(parent, {:worker_done, index, result})
    result
  end

  defp seed_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization =
        organization_fixture(%{alias: "evolution-concurrency-#{suffix}-#{unique}"})

      version = gtfs_version_fixture(organization.id)

      actor =
        user_fixture(%{email: "evolution-concurrency-#{suffix}-#{unique}@example.com"})

      organization_membership_fixture(actor, organization)

      level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
      level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})

      stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

      stop_fixture(organization.id, version.id, %{
        stop_id: "ENT_1",
        location_type: 2,
        parent_station: "STN_1",
        level_id: "L_STREET"
      })

      stop_fixture(organization.id, version.id, %{
        stop_id: "PLAT_1",
        location_type: 0,
        parent_station: "STN_1",
        level_id: "L_PLAT"
      })

      pathway_fixture(organization.id, version.id, "ENT_1", "PLAT_1", %{
        pathway_id: "PW_ENTRY",
        pathway_mode: 2
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "SVC",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          station_stop_id: "STN_1",
          actor_id: actor.id,
          actor_email: actor.email
        }
      }
    end)
  end

  defp identity_state(scope) do
    unboxed(fn ->
      organization_id = scope.organization.id
      version_id = scope.version.id

      %{
        closure_rows:
          Repo.aggregate(
            from(e in PathwayEvolution,
              where:
                e.organization_id == ^organization_id and e.gtfs_version_id == ^version_id and
                  e.service_id == "SVC"
            ),
            :count
          ),
        exception_rows:
          Repo.aggregate(
            from(d in CalendarDate,
              where:
                d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id and
                  d.service_id == "SVC"
            ),
            :count
          )
      }
    end)
  end

  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids = Enum.map(scopes, & &1.organization.id)
      user_ids = Enum.map(scopes, & &1.actor.id)

      Repo.delete_all(from(e in PathwayEvolution, where: e.organization_id in ^organization_ids))

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(p in Pathway, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(l in Level, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))
      delete_versions!(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(
               from(e in PathwayEvolution, where: e.organization_id in ^organization_ids)
             )

      refute Repo.exists?(from(c in Calendar, where: c.organization_id in ^organization_ids))
      refute Repo.exists?(from(p in Pathway, where: p.organization_id in ^organization_ids))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
