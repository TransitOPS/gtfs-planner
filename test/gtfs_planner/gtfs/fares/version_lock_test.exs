defmodule GtfsPlanner.Gtfs.Fares.VersionLockTest do
  @moduledoc """
  Merge evidence (EV-5) for the write lock shared by `Fares` and `FareZones`.

  `Fares.VersionLock.transact/3` is `FareZones` `transact/3` moved out
  unchanged (R15), so these cases pin both halves of that contract: which scope
  pairs may write at all, and that a second writer waits for the version row
  instead of writing beside the first.

  The scope cases assert the literal `{:error, :not_found}` — worked by hand
  from the rule that only a published version of that organization is writable —
  and fail inside the write function if it ever runs. The serialization case
  uses two separately committing sessions (`Sandbox.unboxed_run/2`) with
  committed rows, never one shared sandbox connection, so the writer's wait is a
  real row lock. The test is deliberately not `async: true`; it creates unique
  organizations and deletes every row it commits on exit.
  """
  use ExUnit.Case, async: false

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import Ecto.Query
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Fares.VersionLock
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  setup do
    {organization, version, staging, audit} =
      unboxed(fn ->
        organization = organization_fixture()
        editor = editor_fixture(organization)
        version = gtfs_version_fixture(organization.id)
        staging = staging_version(organization.id)

        audit = audit(organization, version, editor)

        {organization, version, staging, audit}
      end)

    on_exit(fn -> cleanup(organization.id) end)

    %{organization: organization, version: version, staging: staging, audit: audit}
  end

  test "a published version of the organization runs the write and returns its result",
       %{audit: audit} do
    assert {:ok, :written} =
             unboxed(fn ->
               VersionLock.transact(audit, fn -> :written end)
             end)
  end

  test "a foreign version id under this organization writes nothing",
       %{audit: audit} do
    other_organization = unboxed(fn -> organization_fixture() end)
    on_exit(fn -> cleanup(other_organization.id) end)

    other_version = unboxed(fn -> gtfs_version_fixture(other_organization.id) end)

    unboxed(fn ->
      assert {:error, :not_found} =
               VersionLock.transact(%{audit | gtfs_version_id: other_version.id}, fn ->
                 must_not_run()
               end)
    end)
  end

  test "a scope whose duplicated IDs differ from the audit identity is forbidden",
       %{organization: organization, version: version, audit: audit} do
    assert {:error, :forbidden} =
             VersionLock.transact(
               %{organization_id: Ecto.UUID.generate(), gtfs_version_id: version.id, audit: audit},
               fn -> must_not_run() end
             )

    assert {:error, :forbidden} =
             VersionLock.transact(
               %{organization_id: organization.id, gtfs_version_id: Ecto.UUID.generate(), audit: audit},
               fn -> must_not_run() end
             )
  end

  test "a non-editor cannot write", %{audit: audit, organization: organization} do
    non_editor = unboxed(fn -> GtfsPlanner.AccountsFixtures.user_fixture() end)
    denied_audit = audit(organization, %{id: audit.gtfs_version_id}, non_editor)

    assert {:error, :forbidden} =
             unboxed(fn -> VersionLock.transact(denied_audit, fn -> must_not_run() end) end)
  end

  test "a revoked editor cannot write", %{audit: audit, organization: organization} do
    membership = unboxed(fn -> GtfsPlanner.Repo.get_by!(GtfsPlanner.Accounts.UserOrgMembership,
      user_id: audit.actor_id,
      organization_id: organization.id
    ) end)

    unboxed(fn -> GtfsPlanner.AccountsFixtures.deactivate_membership_fixture(membership) end)

    assert {:error, :forbidden} =
             unboxed(fn -> VersionLock.transact(audit, fn -> must_not_run() end) end)
  end

  test "an unpublished version writes nothing", %{staging: staging, audit: audit} do
    assert staging.publication_status == "staging"
    assert is_nil(staging.published_at)

    unboxed(fn ->
      assert {:error, :not_found} =
               VersionLock.transact(%{audit | gtfs_version_id: staging.id}, fn ->
                 must_not_run()
               end)
    end)
  end

  test "a write that rolls back returns its own error",
       %{audit: audit} do
    unboxed(fn ->
      assert {:error, :stale} =
               VersionLock.transact(audit, fn ->
                 Repo.rollback(:stale)
               end)
    end)
  end

  test "a session holding the version row blocks transact until it commits" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    fixture = committed_fixture("lock")
    on_exit(fn -> cleanup(fixture.organization.id) end)

    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            locked =
              Repo.one(
                from(v in GtfsVersion,
                  where:
                    v.id == ^fixture.version.id and
                      v.organization_id == ^fixture.organization.id,
                  lock: "FOR UPDATE"
                )
              )

            send(parent, {:locked, locked.id})

            receive do
              :release -> :released
            end
          end)
        end)
      end)

    assert_receive {:locked, version_id}, 5_000
    assert version_id == fixture.version.id

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(parent, {:writer_started, System.monotonic_time()})

        unboxed(fn ->
               VersionLock.transact(fixture.audit, fn -> :written end)
        end)
      end)

    assert_receive {:writer_started, _}, 5_000

    assert Task.yield(writer, 200) == nil

    send(holder.pid, :release)

    assert Task.await(holder, 10_000) == {:ok, :released}
    assert Task.await(writer, 10_000) == {:ok, :written}
  end

  # The write function is never reached for a scope pair that cannot be a
  # published version, so reaching it at all is the failure this asserts.
  defp must_not_run, do: flunk("the write function must not run for a refused scope pair")

  defp staging_version(organization_id) do
    {:ok, version} =
      Versions.create_staging_gtfs_version(organization_id, %{
        name: "Staging #{System.unique_integer()}"
      })

    version
  end

  defp committed_fixture(suffix) do
    unboxed(fn ->
      organization =
        organization_fixture(%{
          alias: "version-lock-#{suffix}-#{System.system_time(:nanosecond)}"
        })

      %{
        organization: organization,
        version: gtfs_version_fixture(organization.id),
        editor: editor_fixture(organization)
      }
      |> then(fn fixture ->
        Map.put(fixture, :audit, audit(fixture.organization, fixture.version, fixture.editor))
      end)
    end)
  end

  defp audit(organization, version, editor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: editor.id,
      actor_email: editor.email
    }
  end

  defp cleanup(organization_id) do
    unboxed(fn ->
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
