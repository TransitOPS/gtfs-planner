defmodule GtfsPlanner.Gtfs.Extensions.ImportTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Extensions.{Import, Manifest}

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{org_id: organization.id, version_id: gtfs_version.id}
  end

  describe "import_extensions/5 - successful import" do
    test "restores stop diagram coordinates", %{org_id: org_id, version_id: version_id} do
      stop_fixture(org_id, version_id, stop_id: "platform_north")

      manifest =
        Manifest.build(
          [%{stop_id: "platform_north", diagram_coordinate: %{x: 50.5, y: 25.0}}],
          [],
          [],
          []
        )

      json = Manifest.encode(manifest)

      assert {:ok, counts} = Import.import_extensions(org_id, version_id, json, %{})
      assert counts.extensions_stop_coordinates == 1

      stop = Gtfs.get_stop_by_stop_id(org_id, version_id, "platform_north")
      assert stop.diagram_coordinate["x"] == 50.5
      assert stop.diagram_coordinate["y"] == 25.0
    end

    test "restores route active flags", %{org_id: org_id, version_id: version_id} do
      route_fixture(org_id, version_id, route_id: "Red", route_short_name: "Red", active: true)

      manifest = Manifest.build([], [], [%{route_id: "Red", active: false}], [])
      json = Manifest.encode(manifest)

      assert {:ok, counts} = Import.import_extensions(org_id, version_id, json, %{})
      assert counts.extensions_route_flags == 1

      route = Gtfs.get_route_by_route_id(org_id, version_id, "Red")
      assert route.active == false
    end

    test "upserts stop_levels with diagram and calibration fields", %{
      org_id: org_id,
      version_id: version_id
    } do
      station = stop_fixture(org_id, version_id, stop_id: "station_main", location_type: 1)
      level = level_fixture(org_id, version_id, level_id: "L1")

      # Pre-create a stop_level (simulates existing record)
      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org_id,
          gtfs_version_id: version_id
        })

      manifest =
        Manifest.build(
          [],
          [
            %{
              stop_id: "station_main",
              level_id: "L1",
              diagram_filename: "floor.png",
              scale_point_a: %{x: 10.0, y: 20.0},
              scale_point_b: %{x: 80.0, y: 70.0},
              scale_distance_meters: "15.5",
              scale_meters_per_unit: "0.22"
            }
          ],
          [],
          []
        )

      json = Manifest.encode(manifest)

      assert {:ok, counts} = Import.import_extensions(org_id, version_id, json, %{})
      assert counts.extensions_stop_levels == 1

      sl = Gtfs.get_stop_level(org_id, version_id, station.id, level.id)
      assert sl.diagram_filename == "floor.png"
      assert Decimal.equal?(sl.scale_distance_meters, Decimal.new("15.5"))
      assert Decimal.equal?(sl.scale_meters_per_unit, Decimal.new("0.22"))
    end

    test "upsert updates existing stop_level on re-import", %{
      org_id: org_id,
      version_id: version_id
    } do
      station = stop_fixture(org_id, version_id, stop_id: "station_main", location_type: 1)
      level = level_fixture(org_id, version_id, level_id: "L1")

      # First import
      manifest1 =
        Manifest.build(
          [],
          [
            %{
              stop_id: "station_main",
              level_id: "L1",
              diagram_filename: "v1.png",
              scale_point_a: nil,
              scale_point_b: nil,
              scale_distance_meters: nil,
              scale_meters_per_unit: nil
            }
          ],
          [],
          []
        )

      assert {:ok, _} =
               Import.import_extensions(org_id, version_id, Manifest.encode(manifest1), %{})

      # Second import with updated data
      manifest2 =
        Manifest.build(
          [],
          [
            %{
              stop_id: "station_main",
              level_id: "L1",
              diagram_filename: "v2.png",
              scale_point_a: %{x: 5.0, y: 10.0},
              scale_point_b: %{x: 90.0, y: 80.0},
              scale_distance_meters: "20.0",
              scale_meters_per_unit: "0.5"
            }
          ],
          [],
          []
        )

      assert {:ok, counts} =
               Import.import_extensions(org_id, version_id, Manifest.encode(manifest2), %{})

      assert counts.extensions_stop_levels == 1

      sl = Gtfs.get_stop_level(org_id, version_id, station.id, level.id)
      assert sl.diagram_filename == "v2.png"
      assert Decimal.equal?(sl.scale_distance_meters, Decimal.new("20.0"))
    end
  end

  describe "import_extensions/5 - missing references" do
    test "returns error for missing stop references", %{org_id: org_id, version_id: version_id} do
      manifest =
        Manifest.build(
          [%{stop_id: "nonexistent", diagram_coordinate: %{x: 1, y: 2}}],
          [],
          [],
          []
        )

      json = Manifest.encode(manifest)

      assert {:error, {:missing_references, refs}} =
               Import.import_extensions(org_id, version_id, json, %{})

      assert "nonexistent" in refs.stops
    end

    test "returns error for missing level references", %{org_id: org_id, version_id: version_id} do
      stop_fixture(org_id, version_id, stop_id: "station_main")

      manifest =
        Manifest.build(
          [],
          [
            %{
              stop_id: "station_main",
              level_id: "MISSING_LEVEL",
              diagram_filename: nil,
              scale_point_a: nil,
              scale_point_b: nil,
              scale_distance_meters: nil,
              scale_meters_per_unit: nil
            }
          ],
          [],
          []
        )

      json = Manifest.encode(manifest)

      assert {:error, {:missing_references, refs}} =
               Import.import_extensions(org_id, version_id, json, %{})

      assert "MISSING_LEVEL" in refs.levels
    end

    test "returns error for missing route references", %{org_id: org_id, version_id: version_id} do
      manifest = Manifest.build([], [], [%{route_id: "NOPE", active: false}], [])
      json = Manifest.encode(manifest)

      assert {:error, {:missing_references, refs}} =
               Import.import_extensions(org_id, version_id, json, %{})

      assert "NOPE" in refs.routes
    end

    test "only includes non-empty missing reference lists", %{
      org_id: org_id,
      version_id: version_id
    } do
      # Create a valid route but reference a missing stop
      route_fixture(org_id, version_id, route_id: "Red", route_short_name: "Red")

      manifest =
        Manifest.build(
          [%{stop_id: "missing_stop", diagram_coordinate: %{x: 1, y: 2}}],
          [],
          [%{route_id: "Red", active: false}],
          []
        )

      json = Manifest.encode(manifest)

      assert {:error, {:missing_references, refs}} =
               Import.import_extensions(org_id, version_id, json, %{})

      assert Map.has_key?(refs, :stops)
      refute Map.has_key?(refs, :levels)
      refute Map.has_key?(refs, :routes)
    end

    test "returns error when diagram image references unknown station stop", %{
      org_id: org_id,
      version_id: version_id
    } do
      level_fixture(org_id, version_id, level_id: "L1")

      manifest =
        Manifest.build(
          [],
          [],
          [],
          [
            %{
              station_stop_id: "missing_station",
              filename: "floor.png",
              zip_path: "_pathways_extensions/diagrams/missing_station/floor.png"
            }
          ]
        )

      json = Manifest.encode(manifest)

      assert {:error, {:missing_references, refs}} =
               Import.import_extensions(org_id, version_id, json, %{})

      assert "missing_station" in refs.stops
      assert %{station_stop_id: "missing_station", filename: "floor.png"} in refs.diagram_images
    end

    test "returns error when diagram image does not match stop_level diagram filename", %{
      org_id: org_id,
      version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "station_main", location_type: 1)
      level_fixture(org_id, version_id, level_id: "L1")

      manifest =
        Manifest.build(
          [],
          [
            %{
              stop_id: "station_main",
              level_id: "L1",
              diagram_filename: "expected.png",
              scale_point_a: nil,
              scale_point_b: nil,
              scale_distance_meters: nil,
              scale_meters_per_unit: nil
            }
          ],
          [],
          [
            %{
              station_stop_id: "station_main",
              filename: "unexpected.png",
              zip_path: "_pathways_extensions/diagrams/station_main/unexpected.png"
            }
          ]
        )

      json = Manifest.encode(manifest)

      assert {:error, {:missing_references, refs}} =
               Import.import_extensions(org_id, version_id, json, %{})

      assert %{station_stop_id: "station_main", filename: "unexpected.png"} in refs.diagram_images
    end
  end

  describe "import_extensions/5 - image restore" do
    test "restores images from zip path map", %{org_id: org_id, version_id: version_id} do
      stop_fixture(org_id, version_id, stop_id: "station_main", location_type: 1)
      level_fixture(org_id, version_id, level_id: "L1")

      manifest =
        Manifest.build(
          [],
          [
            %{
              stop_id: "station_main",
              level_id: "L1",
              diagram_filename: "floor.png",
              scale_point_a: nil,
              scale_point_b: nil,
              scale_distance_meters: nil,
              scale_meters_per_unit: nil
            }
          ],
          [],
          [
            %{
              station_stop_id: "station_main",
              filename: "floor.png",
              zip_path: "_pathways_extensions/diagrams/station_main/floor.png"
            }
          ]
        )

      json = Manifest.encode(manifest)

      images = %{
        "_pathways_extensions/diagrams/station_main/floor.png" => "fake png"
      }

      assert {:ok, counts} = Import.import_extensions(org_id, version_id, json, images)
      assert counts.extensions_images == 1

      # Verify file was written
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      dest = Path.join([uploads_path, "diagrams", org_id, "station_main", "floor.png"])
      assert File.read!(dest) == "fake png"
    after
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      File.rm_rf(Path.join(uploads_path, "diagrams"))
    end

    test "warns and continues when referenced image binary is missing", %{
      org_id: org_id,
      version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "station_main", location_type: 1)
      level_fixture(org_id, version_id, level_id: "L1")

      manifest =
        Manifest.build(
          [],
          [
            %{
              stop_id: "station_main",
              level_id: "L1",
              diagram_filename: "floor.png",
              scale_point_a: nil,
              scale_point_b: nil,
              scale_distance_meters: nil,
              scale_meters_per_unit: nil
            }
          ],
          [],
          [
            %{
              station_stop_id: "station_main",
              filename: "floor.png",
              zip_path: "_pathways_extensions/diagrams/station_main/floor.png"
            }
          ]
        )

      json = Manifest.encode(manifest)

      # Pass empty image map - should warn but not fail
      assert {:ok, counts} = Import.import_extensions(org_id, version_id, json, %{})
      assert counts.extensions_images == 0
      assert counts.extensions_stop_levels == 1
    end
  end
end
