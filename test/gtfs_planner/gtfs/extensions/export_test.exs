defmodule GtfsPlanner.Gtfs.Extensions.ExportTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.Extensions.Export
  alias GtfsPlanner.Gtfs

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{
      org_id: organization.id,
      version_id: gtfs_version.id
    }
  end

  describe "build_zip_entries/2" do
    test "returns empty list when no extensions data exists", %{
      org_id: org_id,
      version_id: version_id
    } do
      # Create standard GTFS data only (no diagram_coordinate, no stop_levels, all routes active)
      stop_fixture(org_id, version_id, stop_id: "S1")
      route_fixture(org_id, version_id, route_id: "R1", route_short_name: "1", active: true)

      assert {:ok, []} = Export.build_zip_entries(org_id, version_id)
    end

    test "includes manifest with stop diagram coordinates", %{
      org_id: org_id,
      version_id: version_id
    } do
      stop = stop_fixture(org_id, version_id, stop_id: "platform_north")
      {:ok, _} = Gtfs.update_stop_diagram_coordinate(stop, %{x: 50.5, y: 25.0})

      assert {:ok, entries} = Export.build_zip_entries(org_id, version_id)
      assert length(entries) >= 1

      {name, content} = Enum.find(entries, fn {n, _} -> n == ~c"_pathways_extensions.json" end)
      assert name == ~c"_pathways_extensions.json"

      manifest = Jason.decode!(content)
      assert manifest["version"] == 1
      [coord] = manifest["stop_diagram_coordinates"]
      assert coord["stop_id"] == "platform_north"
      assert coord["diagram_coordinate"] == %{"x" => 50.5, "y" => 25.0}
    end

    test "includes manifest with inactive route flags", %{
      org_id: org_id,
      version_id: version_id
    } do
      route_fixture(org_id, version_id, route_id: "Red", route_short_name: "Red", active: false)
      route_fixture(org_id, version_id, route_id: "Blue", route_short_name: "Blue", active: true)

      assert {:ok, entries} = Export.build_zip_entries(org_id, version_id)

      {_, content} = Enum.find(entries, fn {n, _} -> n == ~c"_pathways_extensions.json" end)
      manifest = Jason.decode!(content)

      # Only inactive routes appear in the manifest
      assert [%{"route_id" => "Red", "active" => false}] = manifest["route_active_flags"]
    end

    test "serializes decimal fields as strings", %{
      org_id: org_id,
      version_id: version_id
    } do
      station = stop_fixture(org_id, version_id, stop_id: "station_main", location_type: 1)
      level = level_fixture(org_id, version_id, level_id: "L1")

      {:ok, sl} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org_id,
          gtfs_version_id: version_id,
          diagram_filename: "test.png"
        })

      {:ok, _} =
        Gtfs.update_stop_level_scale(sl, %{
          scale_point_a: %{x: 10.0, y: 20.0},
          scale_point_b: %{x: 80.0, y: 70.0},
          scale_distance_meters: Decimal.new("15.5"),
          scale_meters_per_unit: Decimal.new("0.22")
        })

      assert {:ok, entries} = Export.build_zip_entries(org_id, version_id)

      {_, content} = Enum.find(entries, fn {n, _} -> n == ~c"_pathways_extensions.json" end)
      manifest = Jason.decode!(content)
      [sl_entry] = manifest["stop_levels"]

      assert sl_entry["stop_id"] == "station_main"
      assert sl_entry["level_id"] == "L1"
      assert is_binary(sl_entry["scale_distance_meters"])
      assert is_binary(sl_entry["scale_meters_per_unit"])
    end

    test "emits image entries for stop levels with diagram filenames", %{
      org_id: org_id,
      version_id: version_id
    } do
      station = stop_fixture(org_id, version_id, stop_id: "station_main", location_type: 1)
      level = level_fixture(org_id, version_id, level_id: "L1")

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org_id,
          gtfs_version_id: version_id,
          diagram_filename: "floor.png"
        })

      # Write a fake image to the uploads path
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      image_dir = Path.join([uploads_path, "diagrams", org_id, "station_main"])
      File.mkdir_p!(image_dir)
      image_path = Path.join(image_dir, "floor.png")
      File.write!(image_path, "fake png data")

      assert {:ok, entries} = Export.build_zip_entries(org_id, version_id)

      # Should have manifest + image entry
      image_entry =
        Enum.find(entries, fn {n, _} ->
          to_string(n) == "_pathways_extensions/diagrams/station_main/floor.png"
        end)

      assert image_entry != nil
      {_, binary} = image_entry
      assert binary == "fake png data"

      # Verify manifest references the image
      {_, content} = Enum.find(entries, fn {n, _} -> n == ~c"_pathways_extensions.json" end)
      manifest = Jason.decode!(content)
      [img] = manifest["diagram_images"]
      assert img["station_stop_id"] == "station_main"
      assert img["filename"] == "floor.png"
      assert img["zip_path"] == "_pathways_extensions/diagrams/station_main/floor.png"
    after
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      File.rm_rf(Path.join(uploads_path, "diagrams"))
    end

    test "skips missing image files with warning", %{
      org_id: org_id,
      version_id: version_id
    } do
      station = stop_fixture(org_id, version_id, stop_id: "station_x", location_type: 1)
      level = level_fixture(org_id, version_id, level_id: "L1")

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org_id,
          gtfs_version_id: version_id,
          diagram_filename: "missing.png"
        })

      # Don't write any image file - should still succeed with just manifest
      assert {:ok, entries} = Export.build_zip_entries(org_id, version_id)

      # Should have manifest but no image entry
      assert length(entries) == 1
      {name, _} = hd(entries)
      assert name == ~c"_pathways_extensions.json"
    end
  end
end
