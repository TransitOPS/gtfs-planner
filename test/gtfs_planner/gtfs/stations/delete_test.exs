defmodule GtfsPlanner.Gtfs.Stations.DeleteTest do
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
    FareLegJoinRule,
    FlexService,
    Level,
    Pathway,
    ReliefPoint,
    Stations,
    Stop,
    StopArea,
    StopLevel,
    StopTime,
    Transfer,
    Translation
  }

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest

  @non_cascadable [
    :stop_times,
    :transfers_from,
    :transfers_to,
    :route_pattern_stops,
    :alignment_segments_from,
    :alignment_segments_to,
    :flex_first,
    :flex_last,
    :flex_hubs,
    :fare_leg_join_rules_from,
    :fare_leg_join_rules_to,
    :stop_areas,
    :translations,
    :walkability_tests,
    :parent_stations,
    :relief_points,
    :deadhead_times_from,
    :deadhead_times_to
  ]

  setup do
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

    %{organization: organization, version: version, station: station, child: child, audit: audit}
  end

  test "each non-cascadable reference alone refuses deletion without mutation", scope do
    for key <- @non_cascadable do
      stop_id = "REF_#{key}"

      stop =
        child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
          stop_id: stop_id
        )

      reference = insert_reference(key, scope, stop_id)

      assert {:error, {:in_use, %{^key => 1} = counts}} =
               Stations.delete_child_stop(scope.audit, stop.id, stop.lock_version)

      assert map_size(counts) == 1
      assert Repo.get!(Stop, stop.id).stop_id == stop_id
      assert Repo.get!(reference.__struct__, reference.id)
      assert logs(scope, stop.id) == []
    end
  end

  test "references to a boarding area also prevent deleting its parent", scope do
    nested =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.child.stop_id,
        stop_id: "BOARDING",
        location_type: 4
      )

    insert(StopTime, scope, %{trip_id: "TRIP", stop_id: nested.stop_id, stop_sequence: 1})

    assert {:error, {:in_use, %{parent_stations: 1, stop_times: 1}}} =
             Stations.delete_child_stop(scope.audit, scope.child.id, scope.child.lock_version)

    assert Repo.get!(Stop, scope.child.id)
    assert Repo.get!(Stop, nested.id)
  end

  test "one deadhead pair counts each stop endpoint and leaves the row untouched", scope do
    row =
      insert(DeadheadTime, scope, %{
        from_ref: "stop:S1",
        to_ref: "stop:S1",
        minutes: 11
      })

    assert {:error, {:in_use, %{deadhead_times_from: 1, deadhead_times_to: 1}}} =
             Stations.delete_child_stop(scope.audit, scope.child.id, scope.child.lock_version)

    assert Repo.get!(Stop, scope.child.id)

    assert %{from_ref: "stop:S1", to_ref: "stop:S1", minutes: 11} =
             Repo.get!(DeadheadTime, row.id)

    assert all_logs(scope) == []
  end

  test "unreferenced deletion removes both pathways and stop levels with three logs", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    first =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    second =
      pathway_fixture(scope.organization.id, scope.version.id, other.stop_id, scope.child.stop_id)

    level =
      Repo.get_by!(Level,
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        level_id: scope.child.level_id
      )

    stop_level =
      %StopLevel{}
      |> StopLevel.changeset(%{
        stop_id: scope.child.stop_id,
        level_id: level.level_id,
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id
      })
      |> Repo.insert!()

    assert {:ok, %Stop{id: deleted_id}} =
             Stations.delete_child_stop(scope.audit, scope.child.id, scope.child.lock_version)

    assert deleted_id == scope.child.id
    assert Repo.get(Stop, deleted_id) == nil
    assert Repo.get(Pathway, first.id) == nil
    assert Repo.get(Pathway, second.id) == nil
    assert Repo.get(StopLevel, stop_level.id) == nil
    assert Repo.get!(Stop, other.id)

    assert Enum.sort(Enum.map(all_logs(scope), &{&1.entity_type, &1.entity_id, &1.action})) ==
             Enum.sort([
               {"pathway", first.id, "deleted"},
               {"pathway", second.id, "deleted"},
               {"stop", deleted_id, "deleted"}
             ])
  end

  test "deleting a boarding area keeps its parent platform", scope do
    boarding =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.child.stop_id,
        stop_id: "BOARDING_DELETED",
        location_type: 4,
        level_id: scope.child.level_id,
        diagram_coordinate: %{"x" => 12.0, "y" => 22.0}
      )

    assert {:ok, %Stop{id: deleted_id}} =
             Stations.delete_child_stop(scope.audit, boarding.id, boarding.lock_version)

    assert deleted_id == boarding.id
    assert Repo.get(Stop, boarding.id) == nil
    assert Repo.get!(Stop, scope.child.id)
  end

  test "a closure-backed pathway refuses deletion without changing rows or logs", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    calendar_fixture(scope.organization.id, scope.version.id, service_id: "SERVICE")

    assert {:ok, _} =
             GtfsPlanner.Gtfs.create_pathway_evolution(
               %{
                 pathway_id: pathway.pathway_id,
                 service_id: "SERVICE",
                 start_time: "09:00",
                 end_time: "10:00"
               },
               scope.audit
             )

    history_before_refusal = all_logs(scope)

    assert {:error, :pathway_in_use} =
             Stations.delete_child_stop(scope.audit, scope.child.id, scope.child.lock_version)

    assert Repo.get!(Stop, scope.child.id)
    assert Repo.get!(Pathway, pathway.id)
    assert all_logs(scope) == history_before_refusal
  end

  test "stale and foreign stops cannot be deleted", scope do
    current_revision = scope.child.lock_version

    other_station =
      stop_fixture(scope.organization.id, scope.version.id,
        stop_id: "OTHER_STATION",
        location_type: 1
      )

    foreign =
      child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id)

    assert {:error, {:stale, ^current_revision}} =
             Stations.delete_child_stop(scope.audit, scope.child.id, -1)

    assert {:error, :not_found} =
             Stations.delete_child_stop(scope.audit, foreign.id, foreign.lock_version)

    assert Repo.get!(Stop, scope.child.id)
    assert Repo.get!(Stop, foreign.id)
    assert all_logs(scope) == []
  end

  test "a failed audit insert rolls back pathway and stop deletion", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    invalid_audit = %{scope.audit | actor_email: nil}

    assert {:error, %Ecto.Changeset{}} =
             Stations.delete_child_stop(invalid_audit, scope.child.id, scope.child.lock_version)

    assert Repo.get!(Stop, scope.child.id)
    assert Repo.get!(Pathway, pathway.id)
    assert all_logs(scope) == []
  end

  test "diagram removal rejects stale revision and then clears fields with audit", scope do
    child =
      scope.child
      |> Ecto.Changeset.change(%{diagram_coordinate: %{"x" => 10.0, "y" => 20.0}})
      |> Repo.update!()

    current_revision = child.lock_version

    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)
    first = pathway_fixture(scope.organization.id, scope.version.id, child.stop_id, other.stop_id)

    second =
      pathway_fixture(scope.organization.id, scope.version.id, other.stop_id, child.stop_id)

    assert {:error, {:stale, ^current_revision}} =
             Stations.remove_child_stop_from_diagram(
               scope.audit,
               child.id,
               scope.child.lock_version
             )

    assert Repo.get!(Pathway, first.id)
    assert Repo.get!(Pathway, second.id)
    assert all_logs(scope) == []

    assert {:ok, %Stop{diagram_coordinate: nil, level_id: nil} = updated} =
             Stations.remove_child_stop_from_diagram(scope.audit, child.id, child.lock_version)

    assert updated.lock_version == child.lock_version + 1
    assert Repo.get(Pathway, first.id) == nil
    assert Repo.get(Pathway, second.id) == nil
    assert length(all_logs(scope)) == 3
    assert [%{action: "updated", changed_fields: fields}] = logs(scope, child.id)
    assert fields["level_id"] == %{"from" => child.level_id, "to" => nil}

    assert fields["diagram_coordinate"] == %{
             "from" => %{"x" => 10.0, "y" => 20.0},
             "to" => nil
           }
  end

  test "diagram removal refuses a closure-backed pathway", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    calendar_fixture(scope.organization.id, scope.version.id, service_id: "SERVICE")

    assert {:ok, _} =
             GtfsPlanner.Gtfs.create_pathway_evolution(
               %{
                 pathway_id: pathway.pathway_id,
                 service_id: "SERVICE",
                 start_time: "09:00",
                 end_time: "10:00"
               },
               scope.audit
             )

    history_before_refusal = all_logs(scope)

    assert {:error, :pathway_in_use} =
             Stations.remove_child_stop_from_diagram(
               scope.audit,
               scope.child.id,
               scope.child.lock_version
             )

    assert Repo.get!(Pathway, pathway.id)
    assert Repo.get!(Stop, scope.child.id).level_id == scope.child.level_id
    assert all_logs(scope) == history_before_refusal
  end

  test "diagram removal clears a nested boarding area and deletes its connected pathways",
       scope do
    level_id = scope.child.level_id

    platform =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        stop_id: "PLATFORM",
        level_id: level_id,
        diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
      )

    boarding =
      child_stop_fixture(scope.organization.id, scope.version.id, platform.stop_id,
        stop_id: "BOARDING_AREA",
        location_type: 4,
        level_id: level_id,
        diagram_coordinate: %{"x" => 12.0, "y" => 22.0}
      )

    sibling =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        stop_id: "SIBLING_NODE",
        location_type: 3,
        level_id: level_id,
        diagram_coordinate: %{"x" => 14.0, "y" => 24.0}
      )

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, boarding.stop_id, sibling.stop_id)

    assert {:ok, %Stop{diagram_coordinate: nil, level_id: nil}} =
             Stations.remove_child_stop_from_diagram(
               scope.audit,
               boarding.id,
               boarding.lock_version
             )

    assert Repo.get(Pathway, pathway.id) == nil
    assert Repo.get!(Stop, platform.id).diagram_coordinate == %{"x" => 10.0, "y" => 20.0}
  end

  test "removing a stop that is already off the diagram writes no second stop entry", scope do
    placed =
      scope.child
      |> Ecto.Changeset.change(%{diagram_coordinate: %{"x" => 10.0, "y" => 20.0}})
      |> Repo.update!()

    assert {:ok, removed} =
             Stations.remove_child_stop_from_diagram(scope.audit, placed.id, placed.lock_version)

    assert {:ok, %Stop{diagram_coordinate: nil, level_id: nil}} =
             Stations.remove_child_stop_from_diagram(
               scope.audit,
               removed.id,
               removed.lock_version
             )

    assert [%{action: "updated"}] = logs(scope, placed.id)
  end

  test "a failed audit insert rolls back diagram removal", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(scope.organization.id, scope.version.id, scope.child.stop_id, other.stop_id)

    invalid_audit = %{scope.audit | actor_email: nil}

    assert {:error, %Ecto.Changeset{}} =
             Stations.remove_child_stop_from_diagram(
               invalid_audit,
               scope.child.id,
               scope.child.lock_version
             )

    assert Repo.get!(Pathway, pathway.id)
    assert Repo.get!(Stop, scope.child.id).level_id == scope.child.level_id
    assert all_logs(scope) == []
  end

  defp insert_reference(:parent_stations, scope, stop_id) do
    child_stop_fixture(scope.organization.id, scope.version.id, stop_id,
      stop_id: "NESTED_#{System.unique_integer([:positive])}",
      location_type: 4
    )
  end

  defp insert_reference(:route_pattern_stops, scope, stop_id) do
    scope.organization.id
    |> route_pattern_fixture(scope.version.id)
    |> route_pattern_stop_fixture(stop_id, 1)
  end

  defp insert_reference(key, scope, stop_id) do
    insert(reference_schema(key), scope, reference_attrs(key, stop_id))
  end

  defp reference_attrs(:stop_times, stop_id),
    do: %{trip_id: "TRIP", stop_id: stop_id, stop_sequence: 1}

  defp reference_attrs(:transfers_from, stop_id),
    do: %{from_stop_id: stop_id, to_stop_id: "X", transfer_type: 0}

  defp reference_attrs(:transfers_to, stop_id),
    do: %{from_stop_id: "X", to_stop_id: stop_id, transfer_type: 0}

  defp reference_attrs(:alignment_segments_from, stop_id),
    do: %{from_stop_id: stop_id, to_stop_id: "X"}

  defp reference_attrs(:alignment_segments_to, stop_id),
    do: %{from_stop_id: "X", to_stop_id: stop_id}

  defp reference_attrs(:flex_first, stop_id),
    do: %{key: "first", name: "First", kind: :detour, first_stop_id: stop_id}

  defp reference_attrs(:flex_last, stop_id),
    do: %{key: "last", name: "Last", kind: :detour, last_stop_id: stop_id}

  defp reference_attrs(:flex_hubs, stop_id),
    do: %{key: "hub", name: "Hub", kind: :detour, hub_stop_ids: [stop_id]}

  defp reference_attrs(:fare_leg_join_rules_from, stop_id),
    do: %{from_stop_id: stop_id, to_stop_id: "X"}

  defp reference_attrs(:fare_leg_join_rules_to, stop_id),
    do: %{from_stop_id: "X", to_stop_id: stop_id}

  defp reference_attrs(:stop_areas, stop_id), do: %{area_id: "AREA", stop_id: stop_id}

  defp reference_attrs(:translations, stop_id) do
    %{
      table_name: "stops",
      field_name: "stop_name",
      language: "en",
      translation: "Name",
      record_id: stop_id
    }
  end

  defp reference_attrs(:walkability_tests, stop_id) do
    %{
      stop_id: stop_id,
      address: "123 Main St",
      address_lat: Decimal.new("42.3601"),
      address_lon: Decimal.new("-71.0589")
    }
  end

  defp reference_attrs(:relief_points, stop_id), do: %{stop_id: stop_id}

  defp reference_attrs(:deadhead_times_from, stop_id),
    do: %{from_ref: "stop:#{stop_id}", to_ref: "garage:#{Ecto.UUID.generate()}", minutes: 7}

  defp reference_attrs(:deadhead_times_to, stop_id),
    do: %{from_ref: "garage:#{Ecto.UUID.generate()}", to_ref: "stop:#{stop_id}", minutes: 8}

  defp reference_schema(:stop_times), do: StopTime
  defp reference_schema(key) when key in [:transfers_from, :transfers_to], do: Transfer

  defp reference_schema(key) when key in [:alignment_segments_from, :alignment_segments_to],
    do: AlignmentSegment

  defp reference_schema(key) when key in [:flex_first, :flex_last, :flex_hubs], do: FlexService

  defp reference_schema(key) when key in [:fare_leg_join_rules_from, :fare_leg_join_rules_to],
    do: FareLegJoinRule

  defp reference_schema(:stop_areas), do: StopArea
  defp reference_schema(:translations), do: Translation
  defp reference_schema(:walkability_tests), do: WalkabilityTest
  defp reference_schema(:relief_points), do: ReliefPoint

  defp reference_schema(key) when key in [:deadhead_times_from, :deadhead_times_to],
    do: DeadheadTime

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

  defp logs(scope, stop_id) do
    Repo.all(
      from(log in ChangeLog,
        where:
          log.organization_id == ^scope.organization.id and
            log.gtfs_version_id == ^scope.version.id and
            log.entity_type == "stop" and log.entity_id == ^stop_id
      )
    )
  end

  defp all_logs(scope) do
    Repo.all(
      from(log in ChangeLog,
        where:
          log.organization_id == ^scope.organization.id and
            log.gtfs_version_id == ^scope.version.id
      )
    )
  end
end
