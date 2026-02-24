defmodule GtfsPlanner.Gtfs.Extensions.ManifestTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Extensions.Manifest

  describe "build/4 and encode/1 -> decode/1 round-trip" do
    test "round-trips all extension data" do
      coords = [%{stop_id: "platform_north", diagram_coordinate: %{x: 50.5, y: 25.0}}]

      stop_levels = [
        %{
          stop_id: "station_main",
          level_id: "L1",
          diagram_filename: "lvl_L1_123.png",
          scale_point_a: %{x: 10.0, y: 20.0},
          scale_point_b: %{x: 80.0, y: 70.0},
          scale_distance_meters: "15.5",
          scale_meters_per_unit: "0.22"
        }
      ]

      flags = [%{route_id: "Red", active: false}]

      images = [
        %{
          station_stop_id: "station_main",
          filename: "lvl_L1_123.png",
          zip_path: "_pathways_extensions/diagrams/station_main/lvl_L1_123.png"
        }
      ]

      manifest = Manifest.build(coords, stop_levels, flags, images)
      json = Manifest.encode(manifest)
      assert {:ok, decoded} = Manifest.decode(json)

      assert decoded.version == 1
      assert is_binary(decoded.exported_at)

      [coord] = decoded.stop_diagram_coordinates
      assert coord.stop_id == "platform_north"
      assert coord.diagram_coordinate == %{x: 50.5, y: 25.0}

      [sl] = decoded.stop_levels
      assert sl.stop_id == "station_main"
      assert sl.level_id == "L1"
      assert sl.diagram_filename == "lvl_L1_123.png"
      assert sl.scale_point_a == %{x: 10.0, y: 20.0}
      assert sl.scale_point_b == %{x: 80.0, y: 70.0}
      assert sl.scale_distance_meters == "15.5"
      assert sl.scale_meters_per_unit == "0.22"

      [flag] = decoded.route_active_flags
      assert flag == %{route_id: "Red", active: false}

      [img] = decoded.diagram_images
      assert img.station_stop_id == "station_main"
      assert img.filename == "lvl_L1_123.png"
      assert img.zip_path == "_pathways_extensions/diagrams/station_main/lvl_L1_123.png"
    end
  end

  describe "decode/1 error handling" do
    test "returns error for unsupported version" do
      json = Jason.encode!(%{"version" => 99})
      assert {:error, {:unsupported_version, 99}} = Manifest.decode(json)
    end

    test "returns error for missing version" do
      json = Jason.encode!(%{"stop_diagram_coordinates" => []})
      assert {:error, :missing_version} = Manifest.decode(json)
    end

    test "returns error for malformed JSON" do
      assert {:error, _} = Manifest.decode("not json{")
    end

    test "returns error for non-binary input" do
      assert {:error, :invalid_manifest} = Manifest.decode(42)
    end

    test "defaults missing list fields to empty lists" do
      json = Jason.encode!(%{"version" => 1, "exported_at" => "2026-01-01T00:00:00Z"})
      assert {:ok, decoded} = Manifest.decode(json)

      assert decoded.stop_diagram_coordinates == []
      assert decoded.stop_levels == []
      assert decoded.route_active_flags == []
      assert decoded.diagram_images == []
    end
  end
end
