defmodule GtfsPlanner.Gtfs.Stations.ChildStopsTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{Audit, AuditContext, Stop, Stations}
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    station =
      stop_fixture(organization.id, version.id,
        stop_id: "STATION_#{System.unique_integer([:positive])}",
        location_type: 1
      )

    level = level_fixture(organization.id, version.id)

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
      level: level,
      audit: audit
    }
  end

  test "creation ignores forged ownership and parent fields and records the actor", %{
    audit: audit,
    level: level
  } do
    attrs = %{
      "organization_id" => Ecto.UUID.generate(),
      "gtfs_version_id" => Ecto.UUID.generate(),
      "parent_station" => "FOREIGN",
      "lock_version" => 99,
      "stop_id" => "CHILD_#{System.unique_integer([:positive])}",
      "stop_name" => "Child",
      "level_id" => level.level_id
    }

    assert {:ok, stop} = Stations.create_child_stop(audit, attrs)
    assert stop.organization_id == audit.organization_id
    assert stop.gtfs_version_id == audit.gtfs_version_id
    assert stop.parent_station == audit.station_stop_id
    assert stop.lock_version == 1
    assert Stations.get_child_stop(audit, stop.id).id == stop.id
    assert Enum.map(Stations.list_child_stops(audit), & &1.id) == [stop.id]
    assert [%{action: "created", actor_id: actor_id}] = logs(audit, stop)
    assert actor_id == audit.actor_id
  end

  test "a boarding area can be created under a platform in the selected station", scope do
    platform =
      child_stop_fixture(
        scope.organization.id,
        scope.version.id,
        scope.station.stop_id,
        stop_id: "BOARDING_PARENT",
        location_type: 0
      )

    assert {:ok, boarding} =
             Stations.create_child_stop(scope.audit, %{
               stop_id: "BOARDING_CHILD",
               stop_name: "Boarding area",
               location_type: 4,
               parent_platform: platform.stop_id,
               level_id: scope.level.level_id
             })

    assert boarding.parent_station == platform.stop_id
    assert Stations.get_child_stop(scope.audit, boarding.id).id == boarding.id

    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)

    foreign_platform =
      child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id,
        location_type: 0
      )

    assert {:error, :not_found} =
             Stations.create_child_stop(scope.audit, %{
               stop_id: "FOREIGN_BOARDING_CHILD",
               stop_name: "Foreign boarding area",
               location_type: 4,
               parent_platform: foreign_platform.stop_id,
               level_id: scope.level.level_id
             })

    assert GtfsPlanner.Gtfs.get_stop_by_stop_id(
             scope.organization.id,
             scope.version.id,
             "FOREIGN_BOARDING_CHILD"
           ) == nil
  end

  test "foreign organization, version, station, and absent UUIDs look identical", %{
    audit: audit,
    organization: organization,
    version: version,
    level: level
  } do
    other_org = organization_fixture()
    other_version = gtfs_version_fixture(organization.id)
    other_station = stop_fixture(organization.id, version.id, location_type: 1)

    _same_id_other_version =
      stop_fixture(organization.id, other_version.id,
        stop_id: audit.station_stop_id,
        location_type: 1
      )

    foreign_station =
      stop_fixture(other_org.id, gtfs_version_fixture(other_org.id).id, location_type: 1)

    foreign = [
      child_stop_fixture(other_org.id, foreign_station.gtfs_version_id, foreign_station.stop_id),
      child_stop_fixture(organization.id, other_version.id, audit.station_stop_id),
      child_stop_fixture(organization.id, version.id, other_station.stop_id),
      %{id: Ecto.UUID.generate()}
    ]

    for stop <- foreign do
      assert Stations.get_child_stop(audit, stop.id) == nil

      assert {:error, :not_found} =
               Stations.update_child_stop(audit, stop.id, %{stop_name: "Denied"}, 1)

      if Map.has_key?(stop, :stop_id) do
        assert Repo.get!(Stop, stop.id).stop_name == stop.stop_name
      else
        assert Repo.get(Stop, stop.id) == nil
      end

      assert logs(audit, stop) == []
    end

    assert {:ok, own} =
             Stations.create_child_stop(audit, %{
               stop_id: "OWN_#{System.unique_integer([:positive])}",
               level_id: level.level_id
             })

    assert [%{id: own_id}] = Stations.list_child_stops(audit)
    assert own_id == own.id
  end

  test "a level outside the selected version cannot be assigned", %{audit: audit} do
    other_org = organization_fixture()
    other_version = gtfs_version_fixture(other_org.id)
    foreign_level = level_fixture(other_org.id, other_version.id)

    assert {:error, :not_found} =
             Stations.create_child_stop(audit, %{
               stop_id: "FOREIGN_LEVEL_#{System.unique_integer([:positive])}",
               level_id: foreign_level.level_id
             })

    assert Stations.list_child_stops(audit) == []
  end

  test "stale updates and cross-station parents write no history", %{
    audit: audit,
    organization: organization,
    version: version,
    level: level
  } do
    child =
      child_stop_fixture(organization.id, version.id, audit.station_stop_id,
        level_id: level.level_id
      )

    assert {:ok, updated} =
             Stations.update_child_stop(
               audit,
               child.id,
               %{
                 "stop_name" => "Changed",
                 "organization_id" => Ecto.UUID.generate(),
                 "gtfs_version_id" => Ecto.UUID.generate(),
                 "lock_version" => 99
               },
               1
             )

    assert updated.lock_version == 2
    assert updated.organization_id == organization.id
    assert updated.gtfs_version_id == version.id
    assert [%{action: "updated", actor_id: actor_id, changed_fields: fields}] = logs(audit, child)
    assert actor_id == audit.actor_id
    assert fields["stop_name"] == %{"from" => child.stop_name, "to" => "Changed"}

    assert {:error, {:stale, 2}} =
             Stations.update_child_stop(audit, child.id, %{stop_name: "Stale"}, 1)

    assert {:error, :not_found} =
             Stations.update_child_stop(audit, child.id, %{parent_station: "OTHER"}, 2)

    assert Repo.get!(Stop, child.id).stop_name == "Changed"
    assert length(logs(audit, child)) == 1
  end

  test "diagram move increments the database revision and writes one log", %{
    audit: audit,
    organization: organization,
    version: version,
    level: level
  } do
    child =
      child_stop_fixture(organization.id, version.id, audit.station_stop_id,
        level_id: level.level_id
      )

    assert {:ok, moved} = Stations.move_child_stop(audit, child.id, %{x: 12, y: 34}, 1)
    assert moved.diagram_coordinate == %{x: 12, y: 34}
    assert moved.lock_version == 2
    assert [%{action: "updated", actor_id: actor_id}] = logs(audit, child)
    assert actor_id == audit.actor_id
  end

  test "a deactivated editor cannot mutate the stop or its history", %{
    audit: audit,
    actor: actor,
    organization: organization,
    version: version,
    level: level
  } do
    child =
      child_stop_fixture(organization.id, version.id, audit.station_stop_id,
        level_id: level.level_id
      )

    membership = GtfsPlanner.Accounts.get_user_org_membership(actor.id, organization.id)
    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Stations.update_child_stop(audit, child.id, %{stop_name: "Denied"}, 1)

    assert Repo.get!(Stop, child.id).stop_name == child.stop_name
    assert logs(audit, child) == []
  end

  test "history insertion failure rolls the stop update back", %{
    audit: audit,
    organization: organization,
    version: version,
    level: level
  } do
    child =
      child_stop_fixture(organization.id, version.id, audit.station_stop_id,
        level_id: level.level_id
      )

    Repo.query!(
      "ALTER TABLE change_logs ADD CONSTRAINT test_reject_stop_logs CHECK (entity_type <> 'stop') NOT VALID"
    )

    assert {:error, _reason} =
             Stations.update_child_stop(audit, child.id, %{stop_name: "Denied"}, 1)

    assert Repo.get!(Stop, child.id).stop_name == child.stop_name
    assert logs(audit, child) == []
  end

  test "an unpublished version cannot be edited", %{audit: audit, organization: organization} do
    assert {:ok, staging} =
             Versions.create_staging_gtfs_version(organization.id, %{name: "Unpublished"})

    staged_audit = %{audit | gtfs_version_id: staging.id}

    assert {:error, :not_found} =
             Stations.create_child_stop(staged_audit, %{stop_id: "STAGED_CHILD"})
  end

  defp logs(audit, stop) do
    Audit.list_change_logs_for_entity(
      audit.organization_id,
      audit.gtfs_version_id,
      "stop",
      stop.id
    )
  end
end
