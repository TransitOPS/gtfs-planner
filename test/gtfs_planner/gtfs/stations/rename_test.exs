defmodule GtfsPlanner.Gtfs.Stations.RenameTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{
    AlignmentSegment,
    Alignments,
    Audit,
    AuditContext,
    DeadheadTime,
    Export,
    FareLegJoinRule,
    FlexService,
    Pathway,
    ReliefPoint,
    Shape,
    Stations,
    Stop,
    StopArea,
    StopReferences,
    StopTime,
    Transfer,
    Translation
  }

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Validations.WalkabilityTest

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

  test "rename updates each catalog reference in one version and records one change", scope do
    other_version = gtfs_version_fixture(scope.organization.id)
    stop_fixture(scope.organization.id, other_version.id, stop_id: "S1")
    rows = insert_references(scope.organization.id, scope.version.id, "S1")
    other_rows = insert_references(scope.organization.id, other_version.id, "S1")

    assert {:ok, updated} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{"stop_id" => "S2", "stop_name" => "Renamed"},
               scope.child.lock_version
             )

    assert updated.id == scope.child.id
    assert updated.stop_id == "S2"
    assert updated.stop_name == "Renamed"
    assert Repo.get!(Stop, scope.child.id).stop_id == "S2"
    assert StopReferences.count(scope.organization.id, scope.version.id, ["S1"]).total == 0
    assert_reference_values(rows, "S2")
    assert_reference_values(other_rows, "S1")
    assert Repo.get!(Translation, rows.other_translation.id).record_id == "S1"

    assert [log] = logs(scope)
    assert log.action == "updated"
    assert log.changed_fields["stop_id"] == ["S1", "S2"]

    assert log.changed_fields["stop_name"] == %{
             "from" => scope.child.stop_name,
             "to" => "Renamed"
           }

    assert log.changed_fields["references"]["total"] == length(StopReferences.catalog())

    for {key, _schema, _field, _kind} <- StopReferences.catalog() do
      assert log.changed_fields["references"][Atom.to_string(key)] == 1
    end
  end

  test "collision and invalid IDs leave the stop, references, and audit untouched", scope do
    stop_fixture(scope.organization.id, scope.version.id, stop_id: "S2")
    rows = insert_references(scope.organization.id, scope.version.id, "S1")

    for attempted <- ["S2", "   "] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Stations.update_child_stop(
                 scope.audit,
                 scope.child.id,
                 %{"stop_id" => attempted},
                 scope.child.lock_version
               )

      assert Keyword.has_key?(changeset.errors, :stop_id)
      assert Repo.get!(Stop, scope.child.id).stop_id == "S1"
      assert_reference_values(rows, "S1")
      assert logs(scope) == []
    end
  end

  test "same ID is a normal update and does not rewrite references", scope do
    row =
      insert(StopTime, scope.organization.id, scope.version.id, %{
        trip_id: "T",
        stop_id: "S1",
        stop_sequence: 1
      })

    assert {:ok, updated} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{"stop_id" => "S1", "stop_desc" => "New description"},
               scope.child.lock_version
             )

    assert updated.stop_desc == "New description"
    assert Repo.get!(StopTime, row.id).stop_id == "S1"
    assert [log] = logs(scope)
    refute Map.has_key?(log.changed_fields, "stop_id")
    refute Map.has_key?(log.changed_fields, "references")
  end

  test "a log insertion failure rolls the cascade back", scope do
    rows = insert_references(scope.organization.id, scope.version.id, "S1")

    Repo.query!(
      "ALTER TABLE change_logs ADD CONSTRAINT reject_stop_rename_logs CHECK (entity_type <> 'stop') NOT VALID"
    )

    assert {:error, _} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{"stop_id" => "S2"},
               scope.child.lock_version
             )

    assert Repo.get!(Stop, scope.child.id).stop_id == "S1"
    assert_reference_values(rows, "S1")
    assert logs(scope) == []
  end

  test "an invalid pre-existing deadhead target pair rolls the whole rename back", scope do
    garage_ref = "garage:#{Ecto.UUID.generate()}"
    relief = insert(ReliefPoint, scope.organization.id, scope.version.id, %{stop_id: "S1"})

    source =
      insert(DeadheadTime, scope.organization.id, scope.version.id, %{
        from_ref: "stop:S1",
        to_ref: garage_ref,
        minutes: 9
      })

    target =
      insert(DeadheadTime, scope.organization.id, scope.version.id, %{
        from_ref: "stop:S2",
        to_ref: garage_ref,
        minutes: 10
      })

    error =
      assert_raise Postgrex.Error, fn ->
        Stations.update_child_stop(
          scope.audit,
          scope.child.id,
          %{"stop_id" => "S2"},
          scope.child.lock_version
        )
      end

    assert error.postgres.code == :unique_violation
    assert Repo.get!(Stop, scope.child.id).stop_id == "S1"
    assert Repo.get!(ReliefPoint, relief.id).stop_id == "S1"
    assert %{from_ref: "stop:S1", minutes: 9} = Repo.get!(DeadheadTime, source.id)
    assert %{from_ref: "stop:S2", minutes: 10} = Repo.get!(DeadheadTime, target.id)
    assert logs(scope) == []
  end

  test "alignment export state and exported connectivity survive the rename", scope do
    agency_fixture(scope.organization.id, scope.version.id, agency_id: "A")
    route_fixture(scope.organization.id, scope.version.id, route_id: "R")

    stop_fixture(scope.organization.id, scope.version.id,
      stop_id: "END",
      stop_lat: Decimal.new("40.7138"),
      stop_lon: Decimal.new("-74.0050")
    )

    for {sequence, lat, lon} <- [
          {1, "40.7128", "-74.0060"},
          {2, "40.7138", "-74.0050"}
        ] do
      %Shape{}
      |> Shape.changeset(%{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        shape_id: "P",
        shape_pt_sequence: sequence,
        shape_pt_lat: lat,
        shape_pt_lon: lon
      })
      |> Repo.insert!()
    end

    pattern =
      route_pattern_fixture(scope.organization.id, scope.version.id, %{
        route_id: "R",
        route_pattern_id: "P"
      })

    route_pattern_stop_fixture(pattern, "S1", 1)
    route_pattern_stop_fixture(pattern, "END", 2)

    %AlignmentSegment{
      organization_id: scope.organization.id,
      gtfs_version_id: scope.version.id,
      from_stop_id: "S1",
      to_stop_id: "END"
    }
    |> AlignmentSegment.changeset(%{points: []})
    |> Repo.insert!()

    %{digest: digest} = Alignments.resolve(pattern)
    assert is_binary(digest)
    pattern |> Ecto.Changeset.change(%{shape_id: "P", alignment_digest: digest}) |> Repo.update!()
    assert %{status: %{export: :current}} = Alignments.resolve(Repo.reload!(pattern))

    pathway_fixture(scope.organization.id, scope.version.id, "S1", "END", pathway_id: "PWAY")
    trip = trip_fixture(scope.organization.id, scope.version.id, "R", trip_id: "T")

    stop_time_fixture(scope.organization.id, scope.version.id, trip.trip_id, "S1",
      stop_sequence: 1
    )

    stop_time_fixture(scope.organization.id, scope.version.id, trip.trip_id, "END",
      stop_sequence: 2
    )

    assert {:ok, _} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{"stop_id" => "S2"},
               scope.child.lock_version
             )

    assert %{status: %{export: :current}} = Alignments.resolve(Repo.reload!(pattern))

    assert {:ok, zip} = Export.export_to_zip(scope.organization.id, scope.version.id, :full)
    {:ok, files} = :zip.unzip(zip, [:memory])

    import_files =
      Enum.map(files, fn {name, content} -> %{filename: to_string(name), content: content} end)

    imported_version = gtfs_version_fixture(scope.organization.id)

    assert {:ok, _} =
             StagedImport.import_files(scope.organization.id, imported_version.id, import_files)

    assert pathway_pairs(scope.organization.id, scope.version.id) ==
             pathway_pairs(scope.organization.id, imported_version.id)

    assert stop_sequence(scope.organization.id, scope.version.id, "T") ==
             stop_sequence(scope.organization.id, imported_version.id, "T")

    assert pathway_pairs(scope.organization.id, imported_version.id) == [{"S2", "END"}]
    assert stop_sequence(scope.organization.id, imported_version.id, "T") == ["S2", "END"]
  end

  defp logs(scope) do
    Audit.list_change_logs_for_entity(
      scope.organization.id,
      scope.version.id,
      "stop",
      scope.child.id
    )
  end

  defp pathway_pairs(org_id, version_id) do
    import Ecto.Query

    Repo.all(
      from p in Pathway,
        where: p.organization_id == ^org_id and p.gtfs_version_id == ^version_id,
        select: {p.from_stop_id, p.to_stop_id},
        order_by: p.pathway_id
    )
  end

  defp stop_sequence(org_id, version_id, trip_id) do
    import Ecto.Query

    Repo.all(
      from s in StopTime,
        where:
          s.organization_id == ^org_id and s.gtfs_version_id == ^version_id and
            s.trip_id == ^trip_id,
        select: s.stop_id,
        order_by: s.stop_sequence
    )
  end

  defp insert_references(org_id, version_id, stop_id) do
    pattern = route_pattern_fixture(org_id, version_id)

    %{
      pathways_from:
        insert(Pathway, org_id, version_id, %{
          pathway_id: "from",
          pathway_mode: 1,
          from_stop_id: stop_id,
          to_stop_id: "X"
        }),
      pathways_to:
        insert(Pathway, org_id, version_id, %{
          pathway_id: "to",
          pathway_mode: 1,
          from_stop_id: "X",
          to_stop_id: stop_id
        }),
      stop_times:
        insert(StopTime, org_id, version_id, %{
          trip_id: "trip",
          stop_id: stop_id,
          stop_sequence: 1
        }),
      transfers_from:
        insert(Transfer, org_id, version_id, %{
          from_stop_id: stop_id,
          to_stop_id: "X",
          transfer_type: 0
        }),
      transfers_to:
        insert(Transfer, org_id, version_id, %{
          from_stop_id: "X",
          to_stop_id: stop_id,
          transfer_type: 0
        }),
      stop_areas: insert(StopArea, org_id, version_id, %{area_id: "area", stop_id: stop_id}),
      fare_leg_join_rules_from:
        insert(FareLegJoinRule, org_id, version_id, %{from_stop_id: stop_id, to_stop_id: "X"}),
      fare_leg_join_rules_to:
        insert(FareLegJoinRule, org_id, version_id, %{from_stop_id: "X", to_stop_id: stop_id}),
      parent_stations:
        insert(Stop, org_id, version_id, %{
          stop_id: "child",
          stop_name: "Child",
          parent_station: stop_id
        }),
      translations:
        insert(Translation, org_id, version_id, %{
          table_name: "stops",
          field_name: "stop_name",
          language: "en",
          translation: "Name",
          record_id: stop_id
        }),
      other_translation:
        insert(Translation, org_id, version_id, %{
          table_name: "routes",
          field_name: "route_long_name",
          language: "en",
          translation: "Name",
          record_id: stop_id
        }),
      walkability_tests:
        insert(WalkabilityTest, org_id, version_id, %{
          stop_id: stop_id,
          address: "123 Main St",
          address_lat: Decimal.new("42.3601"),
          address_lon: Decimal.new("-71.0589")
        }),
      route_pattern_stops: route_pattern_stop_fixture(pattern, stop_id, 1),
      alignment_segments_from:
        insert(AlignmentSegment, org_id, version_id, %{from_stop_id: stop_id, to_stop_id: "X"}),
      alignment_segments_to:
        insert(AlignmentSegment, org_id, version_id, %{from_stop_id: "X", to_stop_id: stop_id}),
      relief_points: insert(ReliefPoint, org_id, version_id, %{stop_id: stop_id}),
      deadhead_times_from:
        insert(DeadheadTime, org_id, version_id, %{
          from_ref: "stop:#{stop_id}",
          to_ref: "garage:#{Ecto.UUID.generate()}",
          minutes: 9
        }),
      deadhead_times_to:
        insert(DeadheadTime, org_id, version_id, %{
          from_ref: "garage:#{Ecto.UUID.generate()}",
          to_ref: "stop:#{stop_id}",
          minutes: 10
        }),
      flex_first:
        insert(FlexService, org_id, version_id, %{
          key: "first",
          name: "First",
          kind: :detour,
          first_stop_id: stop_id
        }),
      flex_last:
        insert(FlexService, org_id, version_id, %{
          key: "last",
          name: "Last",
          kind: :detour,
          last_stop_id: stop_id
        }),
      flex_hubs:
        insert(FlexService, org_id, version_id, %{
          key: "hubs",
          name: "Hubs",
          kind: :detour,
          hub_stop_ids: [stop_id, "X"]
        })
    }
  end

  defp insert(schema, org_id, version_id, attrs) do
    schema
    |> struct(Map.merge(attrs, %{organization_id: org_id, gtfs_version_id: version_id}))
    |> Repo.insert!()
  end

  defp assert_reference_values(rows, expected) do
    for {key, schema, field, kind} <- StopReferences.catalog() do
      value = Repo.get!(schema, Map.fetch!(rows, key).id) |> Map.fetch!(field)

      case kind do
        :array -> assert value == [expected, "X"]
        {:prefixed, "stop:"} -> assert value == "stop:#{expected}"
        _ -> assert value == expected
      end
    end
  end
end
