defmodule GtfsPlanner.Gtfs.Stations.DeleteConcurrencyTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog, Level, Stations, Stop, StopTime}
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    scope = unboxed(&seed_scope/0)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)
    %{scope: scope, supervisor: supervisor}
  end

  test "a committed writer ahead of deletion is counted and prevents deletion", %{
    scope: scope,
    supervisor: supervisor
  } do
    writer = start_writer(supervisor, scope, :hold_after_insert)
    assert_receive {:writer_holds, writer_backend}, @rendezvous_timeout

    deletion = start_delete(supervisor, scope, :delete_now)
    assert_receive {:delete_ready, delete_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(delete_backend, writer_backend, deadline()) end)

    send(writer.pid, :release)
    assert {:ok, %StopTime{}} = Task.await(writer, @collect_timeout)
    assert {:error, {:in_use, %{stop_times: 1}}} = Task.await(deletion, @collect_timeout)

    assert unboxed(fn -> Repo.get!(Stop, scope.child.id) end)
    assert unboxed(fn -> reference_ids(scope) end) == ["S1"]
  end

  test "a writer behind deletion sees the absent stop and inserts nothing", %{
    scope: scope,
    supervisor: supervisor
  } do
    deletion = start_delete(supervisor, scope, :hold_before_delete)
    assert_receive {:delete_holds, delete_backend}, @rendezvous_timeout

    writer = start_writer(supervisor, scope, :insert_now)
    assert_receive {:writer_ready, writer_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(writer_backend, delete_backend, deadline()) end)

    send(deletion.pid, :release)
    assert {:ok, {:ok, %Stop{id: deleted_id}}} = Task.await(deletion, @collect_timeout)
    assert deleted_id == scope.child.id
    assert {:ok, :absent} = Task.await(writer, @collect_timeout)

    assert unboxed(fn -> Repo.get(Stop, scope.child.id) end) == nil
    assert unboxed(fn -> reference_ids(scope) end) == []
  end

  defp seed_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, stop_id: "STATION", location_type: 1)
    child = child_stop_fixture(organization.id, version.id, station.stop_id, stop_id: "S1")

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: station.stop_id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, actor: actor, child: child, audit: audit}
  end

  defp start_writer(supervisor, scope, mode) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn -> write_reference(parent, scope, mode) end)
    end)
  end

  defp write_reference(parent, scope, mode) do
    Repo.transaction(fn ->
      backend = backend_pid()
      if mode == :insert_now, do: send(parent, {:writer_ready, backend})

      Versions.lock_for_input_write!(scope.organization.id, scope.version.id)

      stop =
        Repo.one(
          from(s in Stop,
            where:
              s.organization_id == ^scope.organization.id and
                s.gtfs_version_id == ^scope.version.id and s.stop_id == "S1"
          )
        )

      inserted =
        if stop,
          do: stop_time_fixture(scope.organization.id, scope.version.id, "TRIP", stop.stop_id),
          else: :absent

      if mode == :hold_after_insert do
        send(parent, {:writer_holds, backend})
        await_release()
      end

      inserted
    end)
  end

  defp start_delete(supervisor, scope, mode) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn -> delete_child(parent, scope, mode) end)
    end)
  end

  defp delete_child(parent, scope, mode) do
    case mode do
      :hold_before_delete ->
        Repo.transaction(fn ->
          backend = backend_pid()
          Authorization.lock_editor!(scope.audit)
          Versions.lock_for_exclusive_write!(scope.organization.id, scope.version.id)
          send(parent, {:delete_holds, backend})
          await_release()
          Stations.delete_child_stop(scope.audit, scope.child.id, scope.child.lock_version)
        end)

      :delete_now ->
        backend = backend_pid()
        send(parent, {:delete_ready, backend})

        Stations.delete_child_stop(scope.audit, scope.child.id, scope.child.lock_version)
    end
  end

  defp await_release do
    receive do
      :release -> :ok
    after
      @rendezvous_timeout -> raise "lock holder was not released"
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @rendezvous_timeout

  defp reference_ids(scope) do
    Repo.all(
      from(row in StopTime,
        where:
          row.organization_id == ^scope.organization.id and
            row.gtfs_version_id == ^scope.version.id,
        select: row.stop_id
      )
    )
  end

  defp cleanup(scope) do
    org_id = scope.organization.id
    Repo.delete_all(from(row in ChangeLog, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in StopTime, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Stop, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Level, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in UserOrgMembership, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in GtfsVersion, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Organization, where: row.id == ^org_id))
    Repo.delete_all(from(row in User, where: row.id == ^scope.actor.id))
  end
end
