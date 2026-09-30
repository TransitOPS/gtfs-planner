defmodule GtfsPlanner.Gtfs.StopReferencesTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{
    AlignmentSegment,
    FareLegJoinRule,
    FlexService,
    Pathway,
    RoutePatternStop,
    Stop,
    StopArea,
    StopReferences,
    StopTime,
    Transfer,
    Translation
  }

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest
  alias GtfsPlanner.Versions

  @reference_columns MapSet.new([
                       {"pathways", "from_stop_id"},
                       {"pathways", "to_stop_id"},
                       {"stop_times", "stop_id"},
                       {"transfers", "from_stop_id"},
                       {"transfers", "to_stop_id"},
                       {"stop_areas", "stop_id"},
                       {"fare_leg_join_rules", "from_stop_id"},
                       {"fare_leg_join_rules", "to_stop_id"},
                       {"stops", "parent_station"},
                       {"translations", "record_id"},
                       {"walkability_tests", "stop_id"},
                       {"route_pattern_stops", "stop_id"},
                       {"alignment_segments", "from_stop_id"},
                       {"alignment_segments", "to_stop_id"},
                       {"flex_services", "first_stop_id"},
                       {"flex_services", "last_stop_id"},
                       {"flex_services", "hub_stop_ids"}
                     ])

  test "catalog covers all conventional stop columns in scoped base tables" do
    columns =
      Repo.query!("""
      SELECT c.table_name, c.column_name
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name
      WHERE c.table_schema = 'public'
        AND t.table_type = 'BASE TABLE'
        AND EXISTS (
          SELECT 1 FROM information_schema.columns owner
          WHERE owner.table_schema = c.table_schema
            AND owner.table_name = c.table_name
            AND owner.column_name = 'organization_id'
        )
        AND (
          c.column_name = 'stop_id'
          OR c.column_name LIKE '%\\_stop\\_id' ESCAPE '\\'
          OR c.column_name LIKE '%\\_stop\\_ids' ESCAPE '\\'
          OR c.column_name = 'parent_station'
        )
      """).rows
      |> MapSet.new(fn [table, column] -> {table, column} end)

    assert columns ==
             @reference_columns
             |> MapSet.delete({"translations", "record_id"})
             |> MapSet.put({"stops", "stop_id"})
             |> MapSet.put({"change_logs", "station_stop_id"})
             |> MapSet.put({"stop_levels", "stop_id"})

    catalog_columns =
      StopReferences.catalog()
      |> MapSet.new(fn {_key, schema, field, _kind} ->
        {schema.__schema__(:source), Atom.to_string(field)}
      end)

    assert catalog_columns == @reference_columns

    assert Enum.all?(StopReferences.catalog(), fn {_key, schema, field, kind} ->
             schema.__schema__(:type, field) ==
               if(kind == :array, do: {:array, :string}, else: :string)
           end)

    # stop_levels.stop_id matches the name pattern but stores stops.id, a UUID.
    assert %{rows: [["uuid"]]} =
             Repo.query!("""
             SELECT data_type FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'stop_levels'
               AND column_name = 'stop_id'
             """)
  end

  test "count, rename and dependents cover every field without crossing versions" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)

    stop = stop_fixture(organization.id, version.id, stop_id: "S1")
    stop_fixture(organization.id, other_version.id, stop_id: "S1")
    rows = insert_references(organization.id, version.id, "S1")
    other_rows = insert_references(organization.id, other_version.id, "S1")

    counts = StopReferences.count(organization.id, version.id, ["S1"])
    keys = StopReferences.catalog() |> Enum.map(&elem(&1, 0))
    assert Map.take(counts, keys) == Map.new(keys, &{&1, 1})
    assert counts.total == length(keys)
    assert StopReferences.count(organization.id, version.id, []).total == 0

    dependents = StopReferences.dependents(organization.id, version.id, ["S1"])
    assert dependents == Map.drop(counts, [:pathways_from, :pathways_to, :total])

    assert {:ok, ^counts} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(organization.id, version.id)
               StopReferences.rename!(organization.id, version.id, %{"S1" => "S2"})
             end)

    assert Repo.get!(Stop, stop.id).stop_id == "S2"

    assert StopReferences.count(organization.id, version.id, ["S1"]).total == 0
    assert StopReferences.count(organization.id, version.id, ["S2"]) == counts
    assert StopReferences.count(organization.id, other_version.id, ["S1"]) == counts
    assert_reference_values(rows, "S2")
    assert_reference_values(other_rows, "S1")
    assert Repo.get!(Translation, rows.other_translation.id).record_id == "S1"
  end

  test "two-phase rename swaps stop IDs and their references" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    a = stop_fixture(organization.id, version.id, stop_id: "A")
    b = stop_fixture(organization.id, version.id, stop_id: "B")

    a_time =
      insert(StopTime, organization.id, version.id, %{
        trip_id: "a",
        stop_id: "A",
        stop_sequence: 1
      })

    b_time =
      insert(StopTime, organization.id, version.id, %{
        trip_id: "b",
        stop_id: "B",
        stop_sequence: 1
      })

    hubs =
      insert(FlexService, organization.id, version.id, %{
        key: "swap_hubs",
        name: "Swap hubs",
        kind: :detour,
        hub_stop_ids: ["A", "B"]
      })

    empty_hubs =
      insert(FlexService, organization.id, version.id, %{
        key: "empty_hubs",
        name: "Empty hubs",
        kind: :detour,
        hub_stop_ids: []
      })

    assert {:ok, %{stop_times: 2, flex_hubs: 1, total: 3}} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(organization.id, version.id)
               StopReferences.rename!(organization.id, version.id, %{"A" => "B", "B" => "A"})
             end)

    assert Repo.get!(Stop, a.id).stop_id == "B"
    assert Repo.get!(Stop, b.id).stop_id == "A"
    assert Repo.get!(StopTime, a_time.id).stop_id == "B"
    assert Repo.get!(StopTime, b_time.id).stop_id == "A"
    assert Repo.get!(FlexService, hubs.id).hub_stop_ids == ["B", "A"]
    assert Repo.get!(FlexService, empty_hubs.id).hub_stop_ids == []
  end

  test "an exclusive lock returns the scoped version and rejects another organization" do
    organization = organization_fixture()
    other_organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    assert {:ok, %Versions.GtfsVersion{id: version_id}} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(organization.id, version.id)
             end)

    assert version_id == version.id

    assert {:error, :not_found} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(other_organization.id, version.id)
             end)
  end

  defp insert_references(organization_id, version_id, stop_id) do
    pattern = route_pattern_fixture(organization_id, version_id)

    %{
      pathways_from:
        insert(Pathway, organization_id, version_id, %{
          pathway_id: "from",
          pathway_mode: 1,
          from_stop_id: stop_id,
          to_stop_id: "X"
        }),
      pathways_to:
        insert(Pathway, organization_id, version_id, %{
          pathway_id: "to",
          pathway_mode: 1,
          from_stop_id: "X",
          to_stop_id: stop_id
        }),
      stop_times:
        insert(StopTime, organization_id, version_id, %{
          trip_id: "trip",
          stop_id: stop_id,
          stop_sequence: 1
        }),
      transfers_from:
        insert(Transfer, organization_id, version_id, %{
          from_stop_id: stop_id,
          to_stop_id: "X",
          transfer_type: 0
        }),
      transfers_to:
        insert(Transfer, organization_id, version_id, %{
          from_stop_id: "X",
          to_stop_id: stop_id,
          transfer_type: 0
        }),
      stop_areas:
        insert(StopArea, organization_id, version_id, %{area_id: "area", stop_id: stop_id}),
      fare_leg_join_rules_from:
        insert(FareLegJoinRule, organization_id, version_id, %{
          from_stop_id: stop_id,
          to_stop_id: "X"
        }),
      fare_leg_join_rules_to:
        insert(FareLegJoinRule, organization_id, version_id, %{
          from_stop_id: "X",
          to_stop_id: stop_id
        }),
      parent_stations:
        insert(Stop, organization_id, version_id, %{
          stop_id: "child",
          stop_name: "Child",
          parent_station: stop_id
        }),
      translations:
        insert(Translation, organization_id, version_id, %{
          table_name: "stops",
          field_name: "stop_name",
          language: "en",
          translation: "Name",
          record_id: stop_id
        }),
      other_translation:
        insert(Translation, organization_id, version_id, %{
          table_name: "routes",
          field_name: "route_long_name",
          language: "en",
          translation: "Name",
          record_id: stop_id
        }),
      walkability_tests:
        insert(WalkabilityTest, organization_id, version_id, %{
          stop_id: stop_id,
          address: "123 Main St",
          address_lat: Decimal.new("42.3601"),
          address_lon: Decimal.new("-71.0589")
        }),
      route_pattern_stops: route_pattern_stop_fixture(pattern, stop_id, 1),
      alignment_segments_from:
        insert(AlignmentSegment, organization_id, version_id, %{
          from_stop_id: stop_id,
          to_stop_id: "X"
        }),
      alignment_segments_to:
        insert(AlignmentSegment, organization_id, version_id, %{
          from_stop_id: "X",
          to_stop_id: stop_id
        }),
      flex_first:
        insert(FlexService, organization_id, version_id, %{
          key: "first",
          name: "First",
          kind: :detour,
          first_stop_id: stop_id
        }),
      flex_last:
        insert(FlexService, organization_id, version_id, %{
          key: "last",
          name: "Last",
          kind: :detour,
          last_stop_id: stop_id
        }),
      flex_hubs:
        insert(FlexService, organization_id, version_id, %{
          key: "hubs",
          name: "Hubs",
          kind: :detour,
          hub_stop_ids: [stop_id, "X"]
        })
    }
  end

  defp insert(schema, organization_id, version_id, attrs) do
    schema
    |> struct(Map.merge(attrs, %{organization_id: organization_id, gtfs_version_id: version_id}))
    |> Repo.insert!()
  end

  defp assert_reference_values(rows, expected) do
    for {key, schema, field, kind} <- StopReferences.catalog() do
      row = Repo.get!(schema, Map.fetch!(rows, key).id)
      value = Map.fetch!(row, field)

      case kind do
        :array -> assert value == [expected, "X"]
        _ -> assert value == expected
      end
    end
  end
end
