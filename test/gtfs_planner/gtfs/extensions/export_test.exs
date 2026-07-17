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

    # Own a unique upload root so fixtures never touch the shared path.
    previous = Application.get_env(:gtfs_planner, :uploads_path)
    root = Path.join(System.tmp_dir!(), "ext_export_#{System.unique_integer([:positive])}")
    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous) do
        Application.delete_env(:gtfs_planner, :uploads_path)
      else
        Application.put_env(:gtfs_planner, :uploads_path, previous)
      end
    end)

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
      refute Enum.empty?(entries)

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

    test "emits image entries for stop levels with diagram filenames in the versioned namespace",
         %{org_id: org_id, version_id: version_id} do
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

      # Write a fake image into the immutable org/version namespace.
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      image_dir = Path.join([uploads_path, "diagrams", org_id, version_id, "station_main"])
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

    test "falls back to a referenced legacy image when the versioned file is absent", %{
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

      # Only a legacy file exists (no versioned write yet).
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      legacy_dir = Path.join([uploads_path, "diagrams", org_id, "station_main"])
      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "floor.png"), "legacy png data")

      assert {:ok, entries} = Export.build_zip_entries(org_id, version_id)

      image_entry =
        Enum.find(entries, fn {n, _} ->
          to_string(n) == "_pathways_extensions/diagrams/station_main/floor.png"
        end)

      assert image_entry != nil
      {_, binary} = image_entry
      assert binary == "legacy png data"
    after
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      File.rm_rf(Path.join(uploads_path, "diagrams"))
    end

    test "does not export a legacy image referenced only by another published version", %{
      org_id: org_id,
      version_id: selected_version_id
    } do
      historical_version = gtfs_version_fixture(org_id)

      selected_station =
        stop_fixture(org_id, selected_version_id,
          stop_id: "shared_station",
          location_type: 1
        )

      {:ok, _} = Gtfs.update_stop_diagram_coordinate(selected_station, %{x: 12.0, y: 24.0})

      historical_station =
        stop_fixture(org_id, historical_version.id,
          stop_id: selected_station.stop_id,
          location_type: 1
        )

      historical_level = level_fixture(org_id, historical_version.id, level_id: "L1")

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: historical_station.id,
          level_id: historical_level.id,
          organization_id: org_id,
          gtfs_version_id: historical_version.id,
          diagram_filename: "retired.png"
        })

      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      legacy_dir = Path.join([uploads_path, "diagrams", org_id, selected_station.stop_id])
      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "retired.png"), "legacy png data")

      assert {:ok, entries} = Export.build_zip_entries(org_id, selected_version_id)

      {_, manifest_json} =
        Enum.find(entries, fn {name, _content} -> name == ~c"_pathways_extensions.json" end)

      manifest = Jason.decode!(manifest_json)
      assert manifest["diagram_images"] == []

      refute Enum.any?(entries, fn {name, _content} ->
               String.contains?(to_string(name), "retired.png")
             end)
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

    test "rejects unsafe traversal filename when reading exported image", %{
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
          diagram_filename: "../secret.txt"
        })

      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      safe_dir = Path.join([uploads_path, "diagrams", org_id, "station_x"])
      File.mkdir_p!(safe_dir)
      File.write!(Path.join([uploads_path, "diagrams", org_id, "secret.txt"]), "sensitive")

      assert {:ok, entries} = Export.build_zip_entries(org_id, version_id)

      refute Enum.any?(entries, fn {name, _} ->
               String.contains?(to_string(name), "secret.txt")
             end)
    after
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
      File.rm_rf(Path.join(uploads_path, "diagrams"))
    end
  end
end
