defmodule GtfsPlanner.Gtfs.Transfers.StopReferenceLockTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog, Stop, StopReferences, Transfer}
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)
    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransaction.Repo)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    scope = unboxed(&seed_scope/0)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)
    %{scope: scope, supervisor: supervisor}
  end

  test "a transfer waits for stop rename and then refuses the old reference", %{
    scope: scope,
    supervisor: supervisor
  } do
    parent = self()

    renamer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Versions.lock_for_exclusive_write!(scope.organization.id, scope.version.id)
            send(parent, {:rename_holds_lock, backend_pid()})

            receive do
              :release -> :ok
            after
              @rendezvous_timeout -> raise "rename lock holder was not released"
            end

            StopReferences.rename!(scope.organization.id, scope.version.id, %{"S1" => "S2"})
          end)
        end)
      end)

    on_exit(fn -> send(renamer.pid, :release) end)
    assert_receive {:rename_holds_lock, rename_backend}, @rendezvous_timeout

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:transfer_ready, backend_pid()})

          Gtfs.create_general_transfer(
            %{"from_stop_id" => "S1", "to_stop_id" => "S3", "transfer_type" => "0"},
            scope.audit
          )
        end)
      end)

    assert_receive {:transfer_ready, transfer_backend}, @rendezvous_timeout

    assert :ok ==
             unboxed(fn ->
               await_blocker(transfer_backend, rename_backend, deadline())
             end)

    send(renamer.pid, :release)
    assert {:ok, _counts} = Task.await(renamer, @collect_timeout)

    assert {:error, %Ecto.Changeset{} = changeset} = Task.await(writer, @collect_timeout)
    assert {"Choose a stop or station in this version", _} = changeset.errors[:from_stop_id]

    assert %{stop_id: "S2", transfer_count: 0, old_reference_count: 0, transfer_log_count: 0} =
             unboxed(fn ->
               %{
                 stop_id: Repo.get!(Stop, scope.renamed_stop.id).stop_id,
                 transfer_count:
                   Repo.aggregate(
                     from(t in Transfer, where: t.organization_id == ^scope.organization.id),
                     :count
                   ),
                 old_reference_count:
                   Repo.aggregate(
                     from(t in Transfer,
                       where: t.organization_id == ^scope.organization.id,
                       where: t.from_stop_id == "S1" or t.to_stop_id == "S1"
                     ),
                     :count
                   ),
                 transfer_log_count:
                   Repo.aggregate(
                     from(l in ChangeLog,
                       where:
                         l.organization_id == ^scope.organization.id and
                           l.entity_type == "transfer"
                     ),
                     :count
                   )
               }
             end)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @rendezvous_timeout

  defp seed_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    renamed_stop = stop_fixture(organization.id, version.id, stop_id: "S1")
    stop_fixture(organization.id, version.id, stop_id: "S3")
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      renamed_stop: renamed_stop,
      actor: actor,
      audit: audit
    }
  end

  defp cleanup(scope) do
    organization_id = scope.organization.id

    Repo.delete_all(from(t in Transfer, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
    Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
    Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id == ^organization_id))
    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(u in User, where: u.id == ^scope.actor.id))
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
  end
end
