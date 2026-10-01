defmodule GtfsPlanner.Gtfs.Flex.AuthorizationTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Flex

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, membership: membership, audit: audit}
  end

  test "a revoked editor cannot create a service", context do
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Flex.create_service(context.audit, %{name: "Blocked", kind: :area})

    unavailable_audit = %{context.audit | gtfs_version_id: Ecto.UUID.generate()}

    assert {:error, :forbidden} =
             Flex.create_service(unavailable_audit, %{name: "Blocked", kind: :area})

    assert Flex.list_services(context.organization.id, context.version.id) == []
    refute_change_log(context)
  end

  test "a revoked editor cannot save service or area changes", context do
    {:ok, service} = Flex.create_service(context.audit, %{name: "Original", kind: :area})
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Flex.save_service(context.audit, service, %{name: "Changed"}, [])

    assert {:ok, persisted} =
             Flex.get_service(context.organization.id, context.version.id, service.id)

    assert persisted.name == "Original"
    assert persisted.lock_version == service.lock_version
    assert persisted.areas == []
    refute_change_log(context)
  end

  test "a revoked editor cannot change a service's active state", context do
    {:ok, service} = Flex.create_service(context.audit, %{name: "Active", kind: :area})
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} = Flex.set_active(context.audit, service.id, false)

    assert {:ok, persisted} =
             Flex.get_service(context.organization.id, context.version.id, service.id)

    assert persisted.active
    assert persisted.lock_version == service.lock_version
    refute_change_log(context)
  end

  test "a revoked editor cannot delete a service", context do
    {:ok, service} = Flex.create_service(context.audit, %{name: "Keep", kind: :area})
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} = Flex.delete_service(context.audit, service.id)

    assert {:ok, persisted} =
             Flex.get_service(context.organization.id, context.version.id, service.id)

    assert persisted.id == service.id
    refute_change_log(context)
  end

  test "a revoked editor cannot copy services into an empty version", context do
    source = gtfs_version_fixture(context.organization.id)
    source_audit = %{context.audit | gtfs_version_id: source.id}
    {:ok, _service} = Flex.create_service(source_audit, %{name: "Source", kind: :area})
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} = Flex.copy_from_version(context.audit, source.id)

    assert Flex.list_services(context.organization.id, context.version.id) == []
    refute_change_log(context)
  end

  test "a missing or wrong-role membership cannot create a service", context do
    outsider = user_fixture()
    outsider_audit = %{context.audit | actor_id: outsider.id, actor_email: outsider.email}

    admin = user_fixture()
    organization_membership_fixture(admin, context.organization, ["pathways_studio_admin"])
    admin_audit = %{context.audit | actor_id: admin.id, actor_email: admin.email}

    assert {:error, :forbidden} =
             Flex.create_service(outsider_audit, %{name: "Outsider", kind: :area})

    assert {:error, :forbidden} =
             Flex.create_service(admin_audit, %{name: "Admin", kind: :area})

    assert Flex.list_services(context.organization.id, context.version.id) == []
    refute_change_log(context)
  end

  defp refute_change_log(context) do
    refute Repo.exists?(
             from(log in ChangeLog,
               where:
                 log.organization_id == ^context.organization.id and
                   log.gtfs_version_id == ^context.version.id
             )
           )
  end
end
