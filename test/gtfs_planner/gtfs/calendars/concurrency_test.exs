defmodule GtfsPlanner.Gtfs.Calendars.ConcurrencyTest do
  # Independent calendar writers must serialize on the organization-scoped
  # published version row. `async: false` and `Sandbox.unboxed_run/2` give every
  # worker its own committing PostgreSQL connection; the version row is also used
  # as a rendezvous so both writers are genuinely released into contention
  # instead of being observed one after the other.
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
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @lock_wait 500
  @collect_timeout 10_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  test "simultaneous weekly and dates-only creates for one service ID yield one identity", %{
    supervisor: supervisor
  } do
    scope = seed_scope("same-id")

    on_exit(fn -> cleanup([scope]) end)

    results =
      race_through_locked_version(scope, supervisor, fn index ->
        if index == 0 do
          create_calendar(scope, %{
            service_id: "race_same_id",
            name: "Race Weekday",
            kind: :weekly,
            monday: 1,
            tuesday: 1,
            wednesday: 1,
            thursday: 1,
            friday: 1,
            saturday: 0,
            sunday: 0,
            start_date: ~D[2026-01-05],
            end_date: ~D[2026-01-30]
          })
        else
          create_calendar(scope, %{
            service_id: "race_same_id",
            name: "Race Dates",
            kind: :dates_only,
            dates: [~D[2026-07-04]]
          })
        end
      end)

    assert [success] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:ok, result} = success
    assert result.service_id == "race_same_id"

    assert [{:error, %Ecto.Changeset{}}] =
             Enum.reject(results, &match?({:ok, _}, &1))

    state = identity_state(scope, "race_same_id")

    assert state.weekly_rows + state.exception_rows > 0
    refute state.weekly_rows == 1 and state.exception_rows > 0
    assert state.attribute_rows == 1
    assert state.audit_rows == 1
  end

  test "simultaneous creates with one normalized name and different IDs yield one identity", %{
    supervisor: supervisor
  } do
    scope = seed_scope("same-name")

    on_exit(fn -> cleanup([scope]) end)

    results =
      race_through_locked_version(scope, supervisor, fn index ->
        create_calendar(scope, %{
          service_id: "race_name_#{index}",
          name: "  Shared School Name  ",
          kind: :dates_only,
          dates: [~D[2026-07-04]]
        })
      end)

    assert [{:ok, created}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, %Ecto.Changeset{errors: errors}}] =
             Enum.reject(results, &match?({:ok, _}, &1))

    assert Keyword.has_key?(errors, :service_description)

    assert identity_state(scope, created.service_id).attribute_rows == 1
    assert identity_state(scope, created.service_id).audit_rows == 1
    assert created.attributes.service_description == "Shared School Name"

    other_service_id = "race_name_#{if created.service_id == "race_name_0", do: 1, else: 0}"

    assert identity_state(scope, other_service_id) == %{
             weekly_rows: 0,
             exception_rows: 0,
             attribute_rows: 0,
             audit_rows: 0
           }
  end

  test "independent scopes both accept the same service ID and name", %{supervisor: supervisor} do
    first = seed_scope("scope-a")
    second = seed_scope("scope-b")

    on_exit(fn -> cleanup([first, second]) end)

    results =
      race(supervisor, fn index ->
        scope = if index == 0, do: first, else: second

        create_calendar(scope, %{
          service_id: "independent",
          name: "Independent",
          kind: :dates_only,
          dates: [~D[2026-07-04]]
        })
      end)

    assert [{:ok, first_result}, {:ok, second_result}] = results
    assert first_result.service_id == "independent"
    assert second_result.service_id == "independent"

    assert identity_state(first, "independent").attribute_rows == 1
    assert identity_state(second, "independent").attribute_rows == 1
  end

  test "a stale reviewed deletion is refused without refreshing its source token", _context do
    scope = seed_scope("stale-delete")

    on_exit(fn -> cleanup([scope]) end)

    payload =
      unboxed(fn ->
        {:ok, payload} =
          create_calendar(scope, %{
            service_id: "stale_delete",
            name: "Stale Delete",
            kind: :weekly,
            monday: 1,
            tuesday: 1,
            wednesday: 1,
            thursday: 1,
            friday: 1,
            saturday: 0,
            sunday: 0,
            start_date: ~D[2026-01-05],
            end_date: ~D[2026-01-30]
          })

        payload
      end)

    review =
      unboxed(fn ->
        {:ok, review} =
          Gtfs.review_calendar_change(
            {:delete, "stale_delete"},
            %{"stale_delete" => payload.fingerprint},
            scope.audit
          )

        review
      end)

    # A cooperating writer commits a new exception for the same identity between
    # review and apply, so the retained source token no longer describes current rows.
    unboxed(fn ->
      calendar_date_fixture(scope.organization.id, scope.version.id, %{
        service_id: "stale_delete",
        date: ~D[2026-01-14],
        exception_type: 1
      })
    end)

    assert {:error, :stale_review} =
             unboxed(fn ->
               Gtfs.apply_calendar_change(
                 {:delete, "stale_delete"},
                 review.fingerprint,
                 scope.audit
               )
             end)

    state = identity_state(scope, "stale_delete")
    assert state.weekly_rows == 1
    assert state.exception_rows == 1
    assert state.attribute_rows == 1
    assert state.audit_rows == 1

    # A refreshed review over the current rows issues a new token that applies.
    {current, fresh, deleted} =
      unboxed(fn ->
        {:ok, current} =
          Gtfs.get_calendar(scope.organization.id, scope.version.id, "stale_delete")

        {:ok, fresh} =
          Gtfs.review_calendar_change(
            {:delete, "stale_delete"},
            %{"stale_delete" => current.fingerprint},
            scope.audit
          )

        {:ok, deleted} =
          Gtfs.apply_calendar_change({:delete, "stale_delete"}, fresh.fingerprint, scope.audit)

        {current, fresh, deleted}
      end)

    refute current.fingerprint == payload.fingerprint
    assert is_binary(fresh.fingerprint)
    assert deleted.action == :deleted

    assert identity_state(scope, "stale_delete") == %{
             weekly_rows: 0,
             exception_rows: 0,
             attribute_rows: 0,
             audit_rows: 2
           }
  end

  defp create_calendar(scope, attrs), do: Gtfs.create_calendar(attrs, scope.audit)

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

  defp race(supervisor, run) do
    workers = start_workers(supervisor, self(), run)
    Enum.each(workers, &send(&1.pid, :start))
    Enum.map(workers, fn worker -> Task.await(worker, @collect_timeout) end)
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
        organization_fixture(%{alias: "calendar-concurrency-#{suffix}-#{unique}"})

      version = gtfs_version_fixture(organization.id)

      actor =
        user_fixture(%{email: "calendar-concurrency-#{suffix}-#{unique}@example.com"})

      organization_membership_fixture(actor, organization)

      %{
        organization: organization,
        version: version,
        actor: actor,
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

  defp identity_state(scope, service_id) do
    unboxed(fn ->
      organization_id = scope.organization.id
      version_id = scope.version.id

      %{
        weekly_rows: identity_row_count(Calendar, organization_id, version_id, service_id),
        exception_rows: identity_row_count(CalendarDate, organization_id, version_id, service_id),
        attribute_rows:
          identity_row_count(CalendarAttribute, organization_id, version_id, service_id),
        audit_rows: audit_row_count(organization_id, version_id, service_id)
      }
    end)
  end

  defp identity_row_count(schema, organization_id, version_id, service_id) do
    Repo.aggregate(
      from(row in schema,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
            row.service_id == ^service_id
      ),
      :count
    )
  end

  defp audit_row_count(organization_id, version_id, service_id) do
    Repo.aggregate(
      from(l in ChangeLog,
        where:
          l.organization_id == ^organization_id and l.gtfs_version_id == ^version_id and
            l.entity_type == "calendar" and l.entity_external_id == ^service_id
      ),
      :count
    )
  end

  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids = Enum.map(scopes, & &1.organization.id)
      user_ids = Enum.map(scopes, & &1.actor.id)

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id in ^organization_ids))

      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(c in Calendar, where: c.organization_id in ^organization_ids))

      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))

      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
