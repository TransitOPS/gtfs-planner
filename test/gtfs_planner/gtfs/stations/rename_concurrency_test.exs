defmodule GtfsPlanner.Gtfs.Stations.RenameConcurrencyTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.{User, UserOrgMembership}

  alias GtfsPlanner.Gtfs.{
    AuditContext,
    ChangeLog,
    Level,
    RoutePattern,
    RoutePatternStop,
    Stations,
    Stop,
    StopLevel
  }

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

  test "a cooperating writer commits before rename and its new reference is renamed", %{
    scope: scope,
    supervisor: supervisor
  } do
    writer = start_writer(supervisor, scope, :hold_after_insert)
    assert_receive {:writer_holds, writer_backend}, @rendezvous_timeout

    rename = start_rename(supervisor, scope, :rename_now)
    assert_receive {:rename_ready, rename_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(rename_backend, writer_backend, deadline()) end)

    send(writer.pid, :release)
    assert {:ok, %RoutePatternStop{}} = Task.await(writer, @collect_timeout)
    assert {:ok, {:ok, %Stop{stop_id: "S2"}}} = Task.await(rename, @collect_timeout)

    assert unboxed(fn -> reference_ids(scope) end) == ["S2"]
    assert unboxed(fn -> Repo.get!(Stop, scope.child.id).stop_id end) == "S2"
  end

  test "a writer waits for rename, then finds no old stop and inserts nothing", %{
    scope: scope,
    supervisor: supervisor
  } do
    rename = start_rename(supervisor, scope, :hold_before_rename)
    assert_receive {:rename_holds, rename_backend}, @rendezvous_timeout

    writer = start_writer(supervisor, scope, :insert_now)
    assert_receive {:writer_ready, writer_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(writer_backend, rename_backend, deadline()) end)

    send(rename.pid, :release)
    assert {:ok, {:ok, %Stop{stop_id: "S2"}}} = Task.await(rename, @collect_timeout)
    assert {:ok, :absent} = Task.await(writer, @collect_timeout)

    assert unboxed(fn -> reference_ids(scope) end) == []
    assert unboxed(fn -> Repo.get!(Stop, scope.child.id).stop_id end) == "S2"
  end

  defp seed_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, stop_id: "STATION", location_type: 1)
    child = child_stop_fixture(organization.id, version.id, station.stop_id, stop_id: "S1")
    pattern = route_pattern_fixture(organization.id, version.id)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: station.stop_id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      actor: actor,
      child: child,
      pattern: pattern,
      audit: audit
    }
  end

  defp start_writer(supervisor, scope, mode) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          backend = backend_pid()

          if mode == :insert_now, do: send(parent, {:writer_ready, backend})

          Versions.lock_for_input_write!(scope.organization.id, scope.version.id)

          stop =
            Repo.one(
              from s in Stop,
                where:
                  s.organization_id == ^scope.organization.id and
                    s.gtfs_version_id == ^scope.version.id and s.stop_id == "S1"
            )

          inserted =
            if stop,
              do: route_pattern_stop_fixture(scope.pattern, stop.stop_id, 1),
              else: :absent

          if mode == :hold_after_insert do
            send(parent, {:writer_holds, backend})
            await_release()
          end

          inserted
        end)
      end)
    end)
  end

  defp start_rename(supervisor, scope, mode) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          backend = backend_pid()

          case mode do
            :hold_before_rename ->
              Versions.lock_for_exclusive_write!(scope.organization.id, scope.version.id)
              send(parent, {:rename_holds, backend})
              await_release()

            :rename_now ->
              send(parent, {:rename_ready, backend})
          end

          Stations.update_child_stop(
            scope.audit,
            scope.child.id,
            %{"stop_id" => "S2"},
            scope.child.lock_version
          )
        end)
      end)
    end)
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
      from row in RoutePatternStop,
        where:
          row.organization_id == ^scope.organization.id and
            row.gtfs_version_id == ^scope.version.id,
        select: row.stop_id
    )
  end

  defp cleanup(scope) do
    org_id = scope.organization.id
    Repo.delete_all(from row in ChangeLog, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in RoutePatternStop, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in RoutePattern, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in StopLevel, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in Stop, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in Level, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in UserOrgMembership, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in GtfsVersion, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in Organization, where: row.id == ^org_id)
    Repo.delete_all(from row in User, where: row.id == ^scope.actor.id)
  end
end
