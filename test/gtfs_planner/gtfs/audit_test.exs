defmodule GtfsPlanner.Gtfs.AuditTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: Ecto.UUID.generate(),
      actor_email: "audit@example.com"
    }

    %{audit: audit, organization: organization, version: version}
  end

  test "unsupported entity type returns a changeset error", %{audit: audit} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Audit.record_change_in_transaction(audit, :unsupported, nil, "created", %{
               stop_id: "S1"
             })

    assert {"is invalid", _} = changeset.errors[:entity_type]
  end

  test "failed history insertion rolls back the entity update", %{audit: audit} do
    stop =
      stop_fixture(audit.organization_id, audit.gtfs_version_id, %{
        stop_id: "AUDIT_ROLLBACK",
        stop_name: "Original"
      })

    assert {:error, %Ecto.Changeset{} = changeset} =
             Repo.transaction(fn ->
               {:ok, updated} =
                 stop
                 |> Ecto.Changeset.change(stop_name: "Changed")
                 |> Repo.update()

               case Audit.record_change_in_transaction(audit, :stop, updated, "invalid", %{
                      stop_name: "Changed"
                    }) do
                 {:ok, _log} -> flunk("invalid history action was accepted")
                 {:error, changeset} -> Repo.rollback(changeset)
               end
             end)

    assert {"is invalid", _} = changeset.errors[:action]
    assert Repo.get!(Stop, stop.id).stop_name == "Original"

    assert Audit.list_change_logs_for_entity(
             audit.organization_id,
             audit.gtfs_version_id,
             "stop",
             stop.id
           ) == []
  end

  test "scoped history lookup hides other organizations", %{audit: audit, version: version} do
    stop = stop_fixture(audit.organization_id, version.id, %{stop_id: "AUDIT_SCOPE"})

    assert {:ok, log} =
             Repo.transaction(fn ->
               {:ok, log} = Audit.record_change_in_transaction(audit, :stop, stop, "created", %{})
               log
             end)

    other = organization_fixture()
    assert Audit.get_change_log(other.id, version.id, log.id) == nil
    assert Audit.get_change_log(audit.organization_id, Ecto.UUID.generate(), log.id) == nil
    assert Audit.get_change_log(audit.organization_id, version.id, log.id).id == log.id
  end
end
