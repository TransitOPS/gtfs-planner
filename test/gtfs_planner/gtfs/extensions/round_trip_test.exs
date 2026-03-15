defmodule GtfsPlanner.Gtfs.Extensions.RoundTripTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{Export, Import}

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  describe "export -> import round-trip" do
    test "extensions data survives a full export/import cycle" do
      # -- Setup: org A with extension data -----------------------------------
      org_a = organization_fixture()
      version_a = gtfs_version_fixture(org_a.id)

      # Agency required for routes in full export
      agency_fixture(org_a.id, version_a.id, agency_id: "AGENCY1")

      station =
        stop_fixture(org_a.id, version_a.id, stop_id: "station_main", location_type: 1)

      child =
        stop_fixture(org_a.id, version_a.id,
          stop_id: "platform_north",
          parent_station: station.stop_id,
          level_id: "L1",
          location_type: 0
        )

      level = level_fixture(org_a.id, version_a.id, level_id: "L1")

      route_fixture(org_a.id, version_a.id,
        route_id: "Red",
        route_short_name: "Red",
        active: false
      )

      # Set diagram coordinate on child stop
      {:ok, _} = Gtfs.update_stop_diagram_coordinate(child, %{x: 42.5, y: 18.3})

      # Create stop_level with diagram and calibration
      {:ok, sl} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org_a.id,
          gtfs_version_id: version_a.id,
          diagram_filename: "floor_L1.png"
        })

      {:ok, _} =
        Gtfs.update_stop_level_scale(sl, %{
          scale_point_a: %{x: 5.0, y: 10.0},
          scale_point_b: %{x: 95.0, y: 90.0},
          scale_distance_meters: Decimal.new("25.0"),
          scale_meters_per_unit: Decimal.new("0.35")
        })

      # Write a fake diagram image
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      img_dir = Path.join([uploads_path, "diagrams", org_a.id, "station_main"])
      File.mkdir_p!(img_dir)
      File.write!(Path.join(img_dir, "floor_L1.png"), "PNG_BINARY_DATA")

      # -- Export from org A (full export includes routes.txt) -----------------
      assert {:ok, zip_binary} = Export.export_to_zip(org_a.id, version_a.id, :full)

      # Verify extensions manifest is in the zip
      {:ok, zip_entries} = :zip.unzip(zip_binary, [:memory])
      zip_filenames = Enum.map(zip_entries, fn {name, _} -> to_string(name) end)
      assert "_pathways_extensions.json" in zip_filenames

      # -- Import into org B ---------------------------------------------------
      org_b = organization_fixture()
      version_b = gtfs_version_fixture(org_b.id)

      # Convert zip entries to file list format
      import_files =
        Enum.map(zip_entries, fn {name, content} ->
          %{filename: to_string(name), content: content}
        end)

      assert {:ok, {counts, _unrecognized, _topic, []}} =
               Import.import_files(org_b.id, version_b.id, import_files)

      # Standard GTFS data imported
      assert counts.stops >= 2
      assert counts.levels >= 1

      # Extensions data imported
      assert counts.extensions_stop_coordinates == 1
      assert counts.extensions_stop_levels == 1
      assert counts.extensions_route_flags == 1
      assert counts.extensions_images == 1

      # -- Verify restored DB state --------------------------------------------
      imported_child = Gtfs.get_stop_by_stop_id(org_b.id, version_b.id, "platform_north")
      assert imported_child.diagram_coordinate["x"] == 42.5
      assert imported_child.diagram_coordinate["y"] == 18.3

      imported_route = Gtfs.get_route_by_route_id(org_b.id, version_b.id, "Red")
      assert imported_route.active == false

      imported_station = Gtfs.get_stop_by_stop_id(org_b.id, version_b.id, "station_main")
      imported_level = Gtfs.get_level_by_level_id(org_b.id, version_b.id, "L1")

      imported_sl =
        Gtfs.get_stop_level(org_b.id, version_b.id, imported_station.id, imported_level.id)

      assert imported_sl.diagram_filename == "floor_L1.png"
      assert Decimal.equal?(imported_sl.scale_distance_meters, Decimal.new("25.0"))
      assert Decimal.equal?(imported_sl.scale_meters_per_unit, Decimal.new("0.35"))

      # -- Verify restored image -----------------------------------------------
      dest_path =
        Path.join([uploads_path, "diagrams", org_b.id, "station_main", "floor_L1.png"])

      assert File.read!(dest_path) == "PNG_BINARY_DATA"
    after
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      File.rm_rf(Path.join(uploads_path, "diagrams"))
    end

    test "standard GTFS import without extensions behaves as before" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)

      levels_content = "level_id,level_index,level_name\nL1,0.0,Ground Floor"
      stops_content = "stop_id,stop_name,stop_lat,stop_lon,level_id\nS1,Stop 1,40.7,-74.0,L1"

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content}
      ]

      assert {:ok, {counts, [], _topic, []}} = Import.import_files(org.id, version.id, files)

      assert counts.levels == 1
      assert counts.stops == 1
      # No extensions keys present (they're only added when manifest exists)
      refute Map.has_key?(counts, :extensions_stop_coordinates)
    end
  end
end
