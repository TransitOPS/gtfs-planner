defmodule GtfsPlanner.Gtfs.Stations.RollbackTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{
    Audit,
    AuditContext,
    ChangeLog,
    Level,
    Pathway,
    Stations,
    Stop,
    StopLevel
  }

  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, location_type: 1)
    child = child_stop_fixture(organization.id, version.id, station.stop_id, stop_name: "Before")

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
      child: child,
      audit: audit
    }
  end

  test "rolls back a current child edit and records the link to its source log", scope do
    assert {:ok, edited} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_name: "After"}, 1)

    [source_log] = logs(scope.audit, "stop", scope.child.id)

    assert {:ok, restored} =
             Stations.rollback_entity(scope.audit, source_log.id, edited.lock_version)

    assert restored.stop_name == "Before"
    assert restored.lock_version == edited.lock_version + 1

    assert [rollback_log, ^source_log] = logs(scope.audit, "stop", scope.child.id)
    assert rollback_log.action == "rolled_back"
    assert rollback_log.rolled_back_to_log_id == source_log.id
    assert rollback_log.actor_id == scope.actor.id
    assert rollback_log.changed_fields["stop_name"] == %{"from" => "After", "to" => "Before"}

    assert {:error, :already_matches_current} =
             Stations.rollback_entity(scope.audit, source_log.id, restored.lock_version)

    assert {:ok, redone} =
             Stations.rollback_entity(scope.audit, rollback_log.id, restored.lock_version)

    assert redone.stop_name == "After"
  end

  test "restores pathway and level fields with linked rollback history", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    assert {:ok, edited_pathway} =
             Stations.update_pathway(
               scope.audit,
               pathway.id,
               %{signposted_as: "After"},
               pathway.lock_version
             )

    [pathway_log] = logs(scope.audit, "pathway", pathway.id)

    assert {:ok, restored_pathway} =
             Stations.rollback_entity(scope.audit, pathway_log.id, edited_pathway.lock_version)

    assert restored_pathway.signposted_as == pathway.signposted_as
    assert [pathway_rollback_log, ^pathway_log] = logs(scope.audit, "pathway", pathway.id)
    assert pathway_rollback_log.rolled_back_to_log_id == pathway_log.id

    level = level_fixture(scope.organization.id, scope.version.id)
    assert {:ok, _stop_level} = Stations.add_existing_level(scope.audit, level.id)

    assert {:ok, edited_level} =
             Stations.update_level(
               scope.audit,
               level.id,
               %{level_name: "After"},
               level.lock_version
             )

    [level_log] = logs(scope.audit, "level", level.id)

    assert {:ok, restored_level} =
             Stations.rollback_entity(scope.audit, level_log.id, edited_level.lock_version)

    assert restored_level.level_name == level.level_name
    assert [level_rollback_log, ^level_log] = logs(scope.audit, "level", level.id)
    assert level_rollback_log.rolled_back_to_log_id == level_log.id
  end

  test "the historical station ID still identifies a detached level", scope do
    level = level_fixture(scope.organization.id, scope.version.id)
    assert {:ok, stop_level} = Stations.add_existing_level(scope.audit, level.id)

    assert {:ok, edited} =
             Stations.update_level(
               scope.audit,
               level.id,
               %{level_name: "After"},
               level.lock_version
             )

    [source_log] = logs(scope.audit, "level", level.id)

    assert {:ok, :removed} =
             Stations.remove_level_from_station(scope.audit, level.id, stop_level.lock_version)

    current = Repo.get!(Level, level.id)
    assert current.lock_version == edited.lock_version

    assert {:ok, restored} =
             Stations.rollback_entity(scope.audit, source_log.id, current.lock_version)

    assert restored.level_name == level.level_name
  end

  test "uses current entity membership when the log retains an old station ID", scope do
    historical_audit = %{scope.audit | station_stop_id: "OLD_STATION_ID"}

    assert {:ok, source_log} =
             Repo.transaction(fn ->
               {:ok, log} =
                 Audit.record_change_in_transaction(
                   historical_audit,
                   :stop,
                   scope.child,
                   "updated",
                   %{stop_name: "After"}
                 )

               log
             end)

    assert {:ok, edited} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_name: "After"}, 1)

    assert {:ok, restored} =
             Stations.rollback_entity(scope.audit, source_log.id, edited.lock_version)

    assert restored.stop_name == "Before"
    assert [rollback_log | _] = logs(scope.audit, "stop", scope.child.id)
    assert rollback_log.rolled_back_to_log_id == source_log.id
  end

  test "refuses logs outside the selected station, version, or organization", scope do
    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)

    other_child =
      child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id)

    other_station_audit = %{scope.audit | station_stop_id: other_station.stop_id}

    assert {:ok, station_edit} =
             Stations.update_child_stop(
               other_station_audit,
               other_child.id,
               %{stop_name: "Edit"},
               1
             )

    [station_log] = logs(other_station_audit, "stop", other_child.id)

    other_version = gtfs_version_fixture(scope.organization.id)
    version_station = stop_fixture(scope.organization.id, other_version.id, location_type: 1)

    version_child =
      child_stop_fixture(scope.organization.id, other_version.id, version_station.stop_id)

    other_version_audit =
      %{scope.audit | gtfs_version_id: other_version.id, station_stop_id: version_station.stop_id}

    assert {:ok, version_edit} =
             Stations.update_child_stop(
               other_version_audit,
               version_child.id,
               %{stop_name: "Edit"},
               1
             )

    [version_log] = logs(other_version_audit, "stop", version_child.id)

    other_organization = organization_fixture()
    other_actor = editor_fixture(other_organization)
    org_version = gtfs_version_fixture(other_organization.id)
    org_station = stop_fixture(other_organization.id, org_version.id, location_type: 1)
    org_child = child_stop_fixture(other_organization.id, org_version.id, org_station.stop_id)

    other_org_audit = %AuditContext{
      organization_id: other_organization.id,
      gtfs_version_id: org_version.id,
      station_stop_id: org_station.stop_id,
      actor_id: other_actor.id,
      actor_email: other_actor.email
    }

    assert {:ok, org_edit} =
             Stations.update_child_stop(other_org_audit, org_child.id, %{stop_name: "Edit"}, 1)

    [org_log] = logs(other_org_audit, "stop", org_child.id)

    assert {:error, :not_found} =
             Stations.rollback_entity(scope.audit, station_log.id, station_edit.lock_version)

    assert {:error, :not_found} =
             Stations.rollback_entity(scope.audit, version_log.id, version_edit.lock_version)

    assert {:error, :not_found} =
             Stations.rollback_entity(scope.audit, org_log.id, org_edit.lock_version)

    assert Repo.get!(Stop, other_child.id).stop_name == "Edit"
    assert Repo.get!(Stop, version_child.id).stop_name == "Edit"
    assert Repo.get!(Stop, org_child.id).stop_name == "Edit"
  end

  test "refuses a deactivated actor without changing the entity or history", scope do
    assert {:ok, edited} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_name: "After"}, 1)

    [log] = logs(scope.audit, "stop", scope.child.id)

    membership =
      GtfsPlanner.Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)

    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Stations.rollback_entity(scope.audit, log.id, edited.lock_version)

    assert Repo.get!(Stop, scope.child.id).stop_name == "After"
    assert logs(scope.audit, "stop", scope.child.id) == [log]
  end

  test "refuses a revision changed since preview without a new log", scope do
    assert {:ok, edited} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_name: "After"}, 1)

    [source_log] = logs(scope.audit, "stop", scope.child.id)

    assert {:ok, later} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_desc: "Later"},
               edited.lock_version
             )

    assert {:error, {:stale, current}} =
             Stations.rollback_entity(scope.audit, source_log.id, edited.lock_version)

    assert current == later.lock_version
    assert Repo.get!(Stop, scope.child.id).stop_name == "After"
    assert length(logs(scope.audit, "stop", scope.child.id)) == 2
  end

  test "rolls back a stop ID through the reference catalog under the exclusive version lock",
       scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    original_id = scope.child.stop_id

    assert {:ok, renamed} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_id: "NEW_ID"}, 1)

    [source_log] = logs(scope.audit, "stop", scope.child.id)
    assert Repo.get!(Pathway, pathway.id).from_stop_id == "NEW_ID"

    assert {:ok, restored} =
             Stations.rollback_entity(scope.audit, source_log.id, renamed.lock_version)

    assert restored.stop_id == original_id
    assert Repo.get!(Pathway, pathway.id).from_stop_id == original_id
    assert [rollback_log, ^source_log] = logs(scope.audit, "stop", scope.child.id)
    assert rollback_log.changed_fields["stop_id"] == ["NEW_ID", original_id]
    assert rollback_log.rolled_back_to_log_id == source_log.id
  end

  test "an older name log leaves a later stop ID unchanged when no ID was stored", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    assert {:ok, named} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_name: "After"}, 1)

    [name_log] = logs(scope.audit, "stop", scope.child.id)
    refute Map.has_key?(name_log.changed_fields, "stop_id")
    refute Map.has_key?(name_log.snapshot, "stop_id")

    assert {:ok, renamed} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_id: "LATER_ID"},
               named.lock_version
             )

    assert {:ok, restored} =
             Stations.rollback_entity(scope.audit, name_log.id, renamed.lock_version)

    assert restored.stop_id == "LATER_ID"
    assert restored.stop_name == "Before"
    assert Repo.get!(Pathway, pathway.id).from_stop_id == "LATER_ID"
  end

  test "a rollback history constraint failure restores the entity and references", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    assert {:ok, renamed} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_id: "NEW_ID"}, 1)

    [source_log] = logs(scope.audit, "stop", scope.child.id)

    Repo.query!(
      "ALTER TABLE change_logs ADD CONSTRAINT reject_rollback_logs CHECK (action <> 'rolled_back') NOT VALID"
    )

    assert {:error, _reason} =
             Stations.rollback_entity(scope.audit, source_log.id, renamed.lock_version)

    assert Repo.get!(Stop, scope.child.id).stop_id == "NEW_ID"
    assert Repo.get!(Pathway, pathway.id).from_stop_id == "NEW_ID"
    assert logs(scope.audit, "stop", scope.child.id) == [source_log]
  end

  test "a deleted station entity keeps the stored action error after its row is gone", scope do
    assert {:ok, _deleted} = Stations.delete_child_stop(scope.audit, scope.child.id, 1)
    [deleted_log] = logs(scope.audit, "stop", scope.child.id)

    assert {:error, :cannot_rollback_create_or_delete} =
             Stations.rollback_entity(scope.audit, deleted_log.id, 1)
  end

  test "a missing historical snapshot keeps its stored error", scope do
    assert {:ok, edited} =
             Stations.update_child_stop(scope.audit, scope.child.id, %{stop_name: "After"}, 1)

    [log] = logs(scope.audit, "stop", scope.child.id)
    log = log |> Ecto.Changeset.change(snapshot: nil) |> Repo.update!()

    assert {:error, :missing_rollback_snapshot} =
             Stations.rollback_entity(scope.audit, log.id, edited.lock_version)

    assert Repo.get!(Stop, scope.child.id).stop_name == "After"
  end

  test "rejects non-station audit types even when their log names this station", scope do
    route = route_fixture(scope.organization.id, scope.version.id)

    assert {:ok, log} =
             Repo.transaction(fn ->
               {:ok, log} =
                 Audit.record_change_in_transaction(scope.audit, :route, route, "updated", %{})

               log
             end)

    assert {:error, :audit_only_entity} = Stations.rollback_entity(scope.audit, log.id, 1)
    assert Repo.get!(GtfsPlanner.Gtfs.Route, route.id).id == route.id

    other_station_audit = %{scope.audit | station_stop_id: "OTHER_STATION"}

    assert {:ok, other_station_log} =
             Repo.transaction(fn ->
               {:ok, other_log} =
                 Audit.record_change_in_transaction(
                   other_station_audit,
                   :route,
                   route,
                   "updated",
                   %{}
                 )

               other_log
             end)

    assert {:error, :not_found} = Stations.rollback_entity(scope.audit, other_station_log.id, 1)
  end

  test "stop-level history with a missing diagram file remains audit-only", scope do
    level = level_fixture(scope.organization.id, scope.version.id)
    assert {:ok, stop_level} = Stations.add_existing_level(scope.audit, level.id)

    missing_filename = "aged-missing-#{Ecto.UUID.generate()}.png"

    stop_level =
      stop_level
      |> Ecto.Changeset.change(diagram_filename: missing_filename)
      |> Repo.update!()

    alignment = %{
      floorplan_center_lat: 40.7128,
      floorplan_center_lon: -74.0060,
      floorplan_scale_mpp: 0.25,
      floorplan_rotation_deg: 0.0
    }

    assert {:ok, aligned} =
             Stations.save_alignment(
               scope.audit,
               stop_level.id,
               alignment,
               stop_level.lock_version
             )

    [source_log | _] = logs(scope.audit, "stop_level", stop_level.id)
    assert source_log.snapshot["diagram_filename"] == missing_filename

    assert {:error, :not_found} =
             GtfsPlanner.Gtfs.DiagramStorage.published_path(
               scope.organization.id,
               scope.version.id,
               scope.station.stop_id,
               missing_filename
             )

    before = Repo.get!(StopLevel, stop_level.id)
    history = logs(scope.audit, "stop_level", stop_level.id)

    assert {:error, :audit_only_entity} =
             Stations.rollback_entity(scope.audit, source_log.id, aligned.lock_version)

    assert Repo.get!(StopLevel, stop_level.id) == before
    assert logs(scope.audit, "stop_level", stop_level.id) == history
  end

  test "the shared target preserves snapshot values and fills only historical pairs" do
    stop_log = %ChangeLog{
      entity_type: "stop",
      action: "updated",
      snapshot: %{stop_name: "Snapshot", stop_id: "ORIGINAL"},
      changed_fields: %{
        "stop_name" => %{"from" => "Diff", "to" => "Current"},
        :stop_desc => ["Earlier", "Later"],
        "stop_lat" => %{"from" => nil, "to" => 40.0}
      }
    }

    assert {:ok, target} = Stations.rollback_target_snapshot(stop_log)
    assert target["stop_name"] == "Snapshot"
    assert target["stop_id"] == "ORIGINAL"
    assert target["stop_desc"] == "Earlier"
    assert Map.has_key?(target, "stop_lat") and is_nil(target["stop_lat"])
    refute Map.has_key?(target, "platform_code")

    assert {:ok, %{"stop_id" => "OLD"}} =
             Stations.rollback_target_snapshot(%{
               stop_log
               | snapshot: %{},
                 changed_fields: %{"stop_id" => ["OLD", "NEW"]}
             })

    assert {:ok, %{"signposted_as" => "Earlier"} = pathway_target} =
             Stations.rollback_target_snapshot(%ChangeLog{
               entity_type: "pathway",
               action: "updated",
               snapshot: %{"pathway_id" => "P1", "from_stop_id" => "A"},
               changed_fields: %{"signposted_as" => %{"from" => "Earlier", "to" => "Later"}}
             })

    refute Map.has_key?(pathway_target, "pathway_id")
    refute Map.has_key?(pathway_target, "from_stop_id")

    assert {:ok, %{"level_name" => "Earlier"} = level_target} =
             Stations.rollback_target_snapshot(%ChangeLog{
               entity_type: "level",
               action: "updated",
               snapshot: %{"level_id" => "L1"},
               changed_fields: %{"level_name" => ["Earlier", "Later"]}
             })

    refute Map.has_key?(level_target, "level_id")
  end

  test "the shared target preserves refusal and missing-snapshot errors" do
    assert {:error, :audit_only_entity} =
             Stations.rollback_target_snapshot(%ChangeLog{
               entity_type: "stop_level",
               action: "created"
             })

    assert {:error, :cannot_rollback_create_or_delete} =
             Stations.rollback_target_snapshot(%ChangeLog{entity_type: "stop", action: "created"})

    assert {:error, :cannot_rollback_create_or_delete} =
             Stations.rollback_target_snapshot(%ChangeLog{
               entity_type: "level",
               action: "deleted"
             })

    assert {:error, :missing_rollback_snapshot} =
             Stations.rollback_target_snapshot(%ChangeLog{
               entity_type: "pathway",
               action: "updated",
               snapshot: nil
             })
  end

  defp logs(audit, type, id),
    do: Audit.list_change_logs_for_entity(audit.organization_id, audit.gtfs_version_id, type, id)
end
