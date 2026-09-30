defmodule GtfsPlanner.Gtfs.Stations.PathwaysTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{Audit, AuditContext, Pathway, Stations}
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, location_type: 1)
    from = child_stop_fixture(organization.id, version.id, station.stop_id)
    to = child_stop_fixture(organization.id, version.id, station.stop_id)

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
      station: station,
      from: from,
      to: to,
      audit: audit
    }
  end

  test "creation uses selected ownership and records one audit row", scope do
    attrs =
      valid_pathway_attrs(%{
        from_stop_id: scope.from.stop_id,
        to_stop_id: scope.to.stop_id
      })
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.merge(%{
        "organization_id" => Ecto.UUID.generate(),
        "gtfs_version_id" => Ecto.UUID.generate(),
        "lock_version" => 99
      })

    assert {:ok, pathway} = Stations.create_pathway(scope.audit, attrs)
    assert pathway.organization_id == scope.organization.id
    assert pathway.gtfs_version_id == scope.version.id
    assert pathway.lock_version == 1
    assert {:ok, loaded} = Stations.get_pathway(scope.audit, pathway.id)
    assert loaded.from_stop.id == scope.from.id
    assert loaded.to_stop.id == scope.to.id
    assert [%{action: "created", actor_id: actor_id}] = logs(scope.audit, pathway)
    assert actor_id == scope.actor.id
  end

  test "foreign organization, version, station and missing IDs are indistinguishable", scope do
    other_org = organization_fixture()
    other_version = gtfs_version_fixture(scope.organization.id)
    other_org_version = gtfs_version_fixture(other_org.id)
    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)
    foreign_station = stop_fixture(other_org.id, other_org_version.id, location_type: 1)
    version_station = stop_fixture(scope.organization.id, other_version.id, location_type: 1)

    foreign = [
      pathway_in_station(other_org.id, other_org_version.id, foreign_station.stop_id),
      pathway_in_station(scope.organization.id, other_version.id, version_station.stop_id),
      pathway_in_station(scope.organization.id, scope.version.id, other_station.stop_id),
      pathway_fixture(
        scope.organization.id,
        scope.version.id,
        scope.from.stop_id,
        child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id).stop_id
      )
    ]

    for pathway <- foreign do
      assert {:error, :not_found} = Stations.get_pathway(scope.audit, pathway.id)

      assert {:error, :not_found} =
               Stations.update_pathway(scope.audit, pathway.id, %{traversal_time: 20}, 1)

      assert {:error, :not_found} = Stations.delete_pathway(scope.audit, pathway.id, 1)
      assert Repo.get!(Pathway, pathway.id).traversal_time == pathway.traversal_time
      assert logs(scope.audit, pathway) == []
    end

    missing = Ecto.UUID.generate()
    assert {:error, :not_found} = Stations.get_pathway(scope.audit, missing)
    assert {:error, :not_found} = Stations.update_pathway(scope.audit, missing, %{}, 1)
    assert {:error, :not_found} = Stations.delete_pathway(scope.audit, missing, 1)
    assert {:error, :not_found} = Stations.get_pathway(scope.audit, "invalid-uuid")
  end

  test "creation and endpoint edits reject stops outside the selected station", scope do
    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)
    outside = child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id)

    for field <- [:from_stop_id, :to_stop_id] do
      attrs =
        valid_pathway_attrs(%{
          from_stop_id: scope.from.stop_id,
          to_stop_id: scope.to.stop_id
        })
        |> Map.put(field, outside.stop_id)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Stations.create_pathway(scope.audit, attrs)

      assert Keyword.has_key?(changeset.errors, field)
    end

    pathway = own_pathway(scope)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Stations.update_pathway(scope.audit, pathway.id, %{to_stop_id: outside.stop_id}, 1)

    assert Keyword.has_key?(changeset.errors, :to_stop_id)
    assert Repo.get!(Pathway, pathway.id).to_stop_id == scope.to.stop_id
    assert logs(scope.audit, pathway) == []
  end

  test "a flip changes endpoints, increments once and writes one updated log", scope do
    pathway = own_pathway(scope)

    assert {:ok, flipped} =
             Stations.update_pathway(
               scope.audit,
               pathway.id,
               %{
                 from_stop_id: scope.to.stop_id,
                 to_stop_id: scope.from.stop_id,
                 traversal_time: 120,
                 pathway_id: "FORGED",
                 organization_id: Ecto.UUID.generate(),
                 gtfs_version_id: Ecto.UUID.generate(),
                 lock_version: 99
               },
               pathway.lock_version
             )

    assert flipped.from_stop_id == scope.to.stop_id
    assert flipped.to_stop_id == scope.from.stop_id
    assert flipped.traversal_time == 120
    assert flipped.pathway_id == pathway.pathway_id
    assert flipped.organization_id == scope.organization.id
    assert flipped.gtfs_version_id == scope.version.id
    assert flipped.lock_version == pathway.lock_version + 1
    assert [%{action: "updated", changed_fields: fields}] = logs(scope.audit, pathway)
    assert fields["from_stop_id"] == %{"from" => scope.from.stop_id, "to" => scope.to.stop_id}
    assert fields["to_stop_id"] == %{"from" => scope.to.stop_id, "to" => scope.from.stop_id}

    assert {:error, {:stale, 2}} =
             Stations.update_pathway(scope.audit, pathway.id, %{traversal_time: 300}, 1)

    assert Repo.get!(Pathway, pathway.id).traversal_time == 120
    assert length(logs(scope.audit, pathway)) == 1
  end

  test "delete refuses an evolution-backed pathway and preserves history", scope do
    pathway = own_pathway(scope)
    calendar_fixture(scope.organization.id, scope.version.id, service_id: "SERVICE")

    assert {:ok, _evolution} =
             GtfsPlanner.Gtfs.create_pathway_evolution(
               %{
                 pathway_id: pathway.pathway_id,
                 service_id: "SERVICE",
                 start_time: "09:00",
                 end_time: "10:00"
               },
               scope.audit
             )

    assert {:error, :pathway_in_use} =
             Stations.delete_pathway(scope.audit, pathway.id, pathway.lock_version)

    assert Repo.get!(Pathway, pathway.id)
    assert logs(scope.audit, pathway) == []
  end

  test "delete requires the current revision and records one deletion", scope do
    pathway = own_pathway(scope)

    assert {:error, {:stale, 1}} = Stations.delete_pathway(scope.audit, pathway.id, 0)
    assert Repo.get!(Pathway, pathway.id)
    assert logs(scope.audit, pathway) == []

    assert {:ok, deleted} =
             Stations.delete_pathway(scope.audit, pathway.id, pathway.lock_version)

    assert deleted.id == pathway.id
    assert Repo.get(Pathway, pathway.id) == nil
    assert [%{action: "deleted"}] = logs(scope.audit, pathway)
  end

  test "a deactivated editor cannot create, update or delete a pathway", scope do
    pathway = own_pathway(scope)

    membership =
      GtfsPlanner.Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)

    deactivate_membership_fixture(membership)

    attrs = valid_pathway_attrs(%{from_stop_id: scope.from.stop_id, to_stop_id: scope.to.stop_id})
    assert {:error, :forbidden} = Stations.create_pathway(scope.audit, attrs)

    assert {:error, :forbidden} =
             Stations.update_pathway(scope.audit, pathway.id, %{traversal_time: 20}, 1)

    assert {:error, :forbidden} = Stations.delete_pathway(scope.audit, pathway.id, 1)
    assert Repo.get!(Pathway, pathway.id).traversal_time == pathway.traversal_time
    assert logs(scope.audit, pathway) == []
  end

  test "a failed history insert rolls back creation, update and deletion", scope do
    invalid_audit = %{scope.audit | actor_email: nil}
    attrs = valid_pathway_attrs(%{from_stop_id: scope.from.stop_id, to_stop_id: scope.to.stop_id})

    assert {:error, %Ecto.Changeset{}} = Stations.create_pathway(invalid_audit, attrs)

    assert Repo.get_by(Pathway,
             organization_id: scope.organization.id,
             pathway_id: attrs.pathway_id
           ) == nil

    pathway = own_pathway(scope)

    assert {:error, %Ecto.Changeset{}} =
             Stations.update_pathway(invalid_audit, pathway.id, %{traversal_time: 20}, 1)

    assert Repo.get!(Pathway, pathway.id).traversal_time == pathway.traversal_time
    assert logs(scope.audit, pathway) == []

    assert {:error, %Ecto.Changeset{}} =
             Stations.delete_pathway(invalid_audit, pathway.id, pathway.lock_version)

    assert Repo.get!(Pathway, pathway.id)
    assert logs(scope.audit, pathway) == []
  end

  defp own_pathway(scope) do
    pathway_fixture(
      scope.organization.id,
      scope.version.id,
      scope.from.stop_id,
      scope.to.stop_id
    )
  end

  defp pathway_in_station(organization_id, version_id, station_stop_id) do
    from = child_stop_fixture(organization_id, version_id, station_stop_id)
    to = child_stop_fixture(organization_id, version_id, station_stop_id)
    pathway_fixture(organization_id, version_id, from.stop_id, to.stop_id)
  end

  defp logs(audit, pathway) do
    Audit.list_change_logs_for_entity(
      audit.organization_id,
      audit.gtfs_version_id,
      "pathway",
      pathway.id
    )
  end
end
