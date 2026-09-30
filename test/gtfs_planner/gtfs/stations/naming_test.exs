defmodule GtfsPlanner.Gtfs.Stations.NamingTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{
    AlignmentSegment,
    AuditContext,
    ChangeLog,
    DeadheadTime,
    FlexService,
    ReliefPoint,
    Stations,
    Stop,
    StopTime
  }

  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, stop_id: "ST", location_type: 1)

    first =
      stop_fixture(organization.id, version.id,
        stop_id: "S1",
        stop_name: "Platform One",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L1"
      )

    second =
      stop_fixture(organization.id, version.id,
        stop_id: "S2",
        stop_name: "Platform Two",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L1"
      )

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
      station: station,
      first: first,
      second: second,
      actor: actor,
      audit: audit
    }
  end

  test "preview and apply agree across pattern, alignment, and shared flex references", scope do
    pathway_fixture(scope.organization.id, scope.version.id, "S1", "S2", %{pathway_mode: 1})
    pattern = route_pattern_fixture(scope.organization.id, scope.version.id)
    pattern_stop = route_pattern_stop_fixture(pattern, "S1", 1)

    stop_time =
      insert(StopTime, scope, %{trip_id: "T", stop_id: "S1", stop_sequence: 1})

    alignment = insert(AlignmentSegment, scope, %{from_stop_id: "S1", to_stop_id: "S2"})

    flex =
      insert(FlexService, scope, %{
        key: "hub",
        name: "Hub",
        kind: :detour,
        hub_stop_ids: ["S1", "S2"]
      })

    relief = insert(ReliefPoint, scope, %{stop_id: "S1"})

    deadhead =
      insert(DeadheadTime, scope, %{
        from_ref: "stop:S1",
        to_ref: "stop:S2",
        minutes: 8
      })

    assert {:ok, preview} = Stations.preview_station_naming(scope.audit, :structured, nil)
    assert preview.renamed_stops_count == 2
    assert preview.updated_pathways_count == 2
    assert preview.updated_references_count == 10
    assert byte_size(preview.fingerprint) == 32

    assert {:ok, applied} =
             Stations.apply_station_naming(scope.audit, :structured, nil, preview.fingerprint)

    assert applied == %{
             renamed_stops: preview.renamed_stops_count,
             updated_pathways: preview.updated_pathways_count,
             updated_references: preview.updated_references_count
           }

    mapping = Map.new(preview.rows, fn row -> {row.old_id, row.new_id} end)
    assert Repo.get!(Stop, scope.first.id).stop_id == mapping["S1"]
    assert Repo.get!(Stop, scope.second.id).stop_id == mapping["S2"]
    assert Repo.get!(StopTime, stop_time.id).stop_id == mapping["S1"]
    assert Repo.reload!(pattern_stop).stop_id == mapping["S1"]
    assert Repo.get!(AlignmentSegment, alignment.id).from_stop_id == mapping["S1"]
    assert Repo.get!(AlignmentSegment, alignment.id).to_stop_id == mapping["S2"]
    assert Repo.get!(FlexService, flex.id).hub_stop_ids == [mapping["S1"], mapping["S2"]]
    assert Repo.get!(ReliefPoint, relief.id).stop_id == mapping["S1"]

    assert %{from_ref: from_ref, to_ref: to_ref, minutes: 8} =
             Repo.get!(DeadheadTime, deadhead.id)

    assert from_ref == "stop:#{mapping["S1"]}"
    assert to_ref == "stop:#{mapping["S2"]}"

    assert [first_log, second_log] = logs(scope)
    assert Enum.all?([first_log, second_log], &(&1.action == "updated"))

    assert Enum.sort([first_log.entity_id, second_log.entity_id]) ==
             Enum.sort([scope.first.id, scope.second.id])

    assert Enum.sort([first_log.changed_fields["stop_id"], second_log.changed_fields["stop_id"]]) ==
             Enum.sort([["S1", mapping["S1"]], ["S2", mapping["S2"]]])
  end

  test "a changed stop makes apply reject the preview without a second write", scope do
    assert {:ok, preview} = Stations.preview_station_naming(scope.audit, :structured, nil)

    assert {:ok, _renamed} =
             Stations.update_child_stop(
               scope.audit,
               scope.first.id,
               %{"stop_id" => "S1_CHANGED"},
               scope.first.lock_version
             )

    assert {:error, :stale_preview} =
             Stations.apply_station_naming(scope.audit, :structured, nil, preview.fingerprint)

    assert Repo.get!(Stop, scope.first.id).stop_id == "S1_CHANGED"
    assert Repo.get!(Stop, scope.second.id).stop_id == "S2"
    assert length(logs(scope)) == 1
  end

  test "a new natural reference makes apply reject unchanged stop names", scope do
    assert {:ok, preview} = Stations.preview_station_naming(scope.audit, :structured, nil)
    stop_time = insert(StopTime, scope, %{trip_id: "T", stop_id: "S1", stop_sequence: 1})

    assert {:error, :stale_preview} =
             Stations.apply_station_naming(scope.audit, :structured, nil, preview.fingerprint)

    assert Repo.get!(Stop, scope.first.id).stop_id == "S1"
    assert Repo.get!(StopTime, stop_time.id).stop_id == "S1"
    assert logs(scope) == []
  end

  test "structured and kebab previews keep collision errors", scope do
    stop_fixture(scope.organization.id, scope.version.id,
      stop_id: "st_platform_general_l1_01",
      stop_name: "Structured blocker"
    )

    assert {:error, {:naming_collision, structured}} =
             Stations.preview_station_naming(scope.audit, :structured, MapSet.new(["S1"]))

    assert "st_platform_general_l1_01" in structured

    stop_fixture(scope.organization.id, scope.version.id,
      stop_id: "platform-one-01",
      stop_name: "Kebab blocker"
    )

    assert {:error, {:naming_collision, kebab}} =
             Stations.preview_station_naming(scope.audit, :kebab, MapSet.new(["S1"]))

    assert "platform-one-01" in kebab
    assert Repo.get!(Stop, scope.first.id).stop_id == "S1"
    assert logs(scope) == []
  end

  test "a change log failure rolls back every renamed ID and reference", scope do
    stop_time = insert(StopTime, scope, %{trip_id: "T", stop_id: "S1", stop_sequence: 1})
    relief = insert(ReliefPoint, scope, %{stop_id: "S1"})
    deadhead = insert(DeadheadTime, scope, %{from_ref: "stop:S1", to_ref: "stop:S2", minutes: 8})
    assert {:ok, preview} = Stations.preview_station_naming(scope.audit, :structured, nil)

    Repo.query!(
      "ALTER TABLE change_logs ADD CONSTRAINT reject_naming_logs CHECK (entity_type <> 'stop') NOT VALID"
    )

    assert {:error, _reason} =
             Stations.apply_station_naming(scope.audit, :structured, nil, preview.fingerprint)

    assert Repo.get!(Stop, scope.first.id).stop_id == "S1"
    assert Repo.get!(Stop, scope.second.id).stop_id == "S2"
    assert Repo.get!(StopTime, stop_time.id).stop_id == "S1"
    assert Repo.get!(ReliefPoint, relief.id).stop_id == "S1"
    assert %{from_ref: "stop:S1", to_ref: "stop:S2"} = Repo.get!(DeadheadTime, deadhead.id)
    assert logs(scope) == []
  end

  test "preview and apply refuse an actor whose edit access was revoked", scope do
    assert {:ok, preview} = Stations.preview_station_naming(scope.audit, :structured, nil)

    membership =
      GtfsPlanner.Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)

    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} = Stations.preview_station_naming(scope.audit, :structured, nil)

    assert {:error, :forbidden} =
             Stations.apply_station_naming(scope.audit, :structured, nil, preview.fingerprint)

    assert Repo.get!(Stop, scope.first.id).stop_id == "S1"
    assert logs(scope) == []
  end

  defp insert(schema, scope, attrs) do
    schema
    |> struct(
      Map.merge(attrs, %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id
      })
    )
    |> Repo.insert!()
  end

  defp logs(scope) do
    Repo.all(
      from log in ChangeLog,
        where:
          log.organization_id == ^scope.organization.id and
            log.gtfs_version_id == ^scope.version.id and log.entity_type == "stop",
        order_by: [asc: log.entity_id]
    )
  end
end
