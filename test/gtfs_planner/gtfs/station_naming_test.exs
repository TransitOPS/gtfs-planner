defmodule GtfsPlanner.Gtfs.StationNamingTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StationNaming

  describe "kebabify/1" do
    test "converts spaces and uppercase to kebab-case" do
      assert Stop.kebabify("Platform 2") == "platform-2"
    end

    test "strips special characters" do
      assert Stop.kebabify("Track #3 (North)") == "track-3-north"
    end

    test "collapses consecutive hyphens" do
      assert Stop.kebabify("stop---name") == "stop-name"
    end

    test "trims leading and trailing hyphens" do
      assert Stop.kebabify("  --hello--  ") == "hello"
    end

    test "truncates to 64 characters" do
      long = String.duplicate("a", 100)
      assert String.length(Stop.kebabify(long)) == 64
    end

    test "returns empty string for nil" do
      assert Stop.kebabify(nil) == ""
    end

    test "returns empty string for empty string" do
      assert Stop.kebabify("") == ""
    end
  end

  describe "build_naming_map/3" do
    test "generates deterministic names for mixed child stop types" do
      child_stops = [
        %{stop_id: "PLAT_A", location_type: 0, level_id: "concourse"},
        %{stop_id: "PLAT_B", location_type: 0, level_id: "concourse"},
        %{stop_id: "ENT_1", location_type: 2, level_id: "street"},
        %{stop_id: "NODE_1", location_type: 3, level_id: "concourse"}
      ]

      pathways = [
        %{from_stop_id: "PLAT_A", to_stop_id: "NODE_1", pathway_mode: 5},
        %{from_stop_id: "PLAT_B", to_stop_id: "NODE_1", pathway_mode: 1}
      ]

      result = StationNaming.build_naming_map(child_stops, pathways, "CENTRAL")

      mapping = Map.new(result, fn %{old_id: old, new_id: new} -> {old, new} end)

      # PLAT_A connected to elevator (mode 5)
      assert mapping["PLAT_A"] == "central_platform_elevator_concourse_01"

      # PLAT_B connected to walkway (mode 1)
      assert mapping["PLAT_B"] == "central_platform_walkway_concourse_01"

      # ENT_1 no pathways → general
      assert mapping["ENT_1"] == "central_entrance_general_street_01"

      # NODE_1 connected to both elevator (5) and walkway (1); elevator wins
      assert mapping["NODE_1"] == "central_node_elevator_concourse_01"
    end

    test "assigns sequential numbers within a partition" do
      child_stops = [
        %{stop_id: "C_STOP", location_type: 0, level_id: "L1"},
        %{stop_id: "A_STOP", location_type: 0, level_id: "L1"},
        %{stop_id: "B_STOP", location_type: 0, level_id: "L1"}
      ]

      result = StationNaming.build_naming_map(child_stops, [], "STATION")

      mapping = Map.new(result, fn %{old_id: old, new_id: new} -> {old, new} end)

      # Sorted by original stop_id ascending: A_STOP=01, B_STOP=02, C_STOP=03
      assert mapping["A_STOP"] == "station_platform_general_l1_01"
      assert mapping["B_STOP"] == "station_platform_general_l1_02"
      assert mapping["C_STOP"] == "station_platform_general_l1_03"
    end

    test "uses nolvl for stops without level_id" do
      child_stops = [
        %{stop_id: "STOP_1", location_type: 3, level_id: nil}
      ]

      result = StationNaming.build_naming_map(child_stops, [], "MY_STATION")

      assert [%{old_id: "STOP_1", new_id: "my_station_node_general_nolvl_01"}] = result
    end

    test "returns empty list for no child stops" do
      assert [] == StationNaming.build_naming_map([], [], "STATION")
    end

    test "feature priority: elevator beats escalator beats stairs" do
      child_stops = [
        %{stop_id: "S1", location_type: 3, level_id: "L1"}
      ]

      pathways = [
        %{from_stop_id: "S1", to_stop_id: "OTHER", pathway_mode: 2},
        %{from_stop_id: "OTHER", to_stop_id: "S1", pathway_mode: 4},
        %{from_stop_id: "S1", to_stop_id: "OTHER", pathway_mode: 1}
      ]

      result = StationNaming.build_naming_map(child_stops, pathways, "X")

      # escalator (4) beats stairs (2) and walkway (1)
      assert [%{new_id: "x_node_escalator_l1_01"}] = result
    end

    test "slugifies station stop_id" do
      child_stops = [
        %{stop_id: "S1", location_type: 0, level_id: "Ground Floor"}
      ]

      result = StationNaming.build_naming_map(child_stops, [], "Grand Central Terminal")

      assert [%{new_id: "grand_central_terminal_platform_general_ground_floor_01"}] = result
    end
  end

  describe "build_kebab_naming_map/1" do
    test "basic kebab-casing with sequence" do
      child_stops = [
        %{stop_id: "S1", stop_name: "Platform 2", location_type: 0, level_id: "L1"}
      ]

      result = StationNaming.build_kebab_naming_map(child_stops)

      assert [%{old_id: "S1", new_id: "platform-2-01"}] = result
    end

    test "groups stops with same name and assigns sequential IDs" do
      child_stops = [
        %{stop_id: "B_STOP", stop_name: "Main Hall", location_type: 3, level_id: "L1"},
        %{stop_id: "A_STOP", stop_name: "Main Hall", location_type: 3, level_id: "L1"}
      ]

      result = StationNaming.build_kebab_naming_map(child_stops)
      mapping = Map.new(result, fn %{old_id: old, new_id: new} -> {old, new} end)

      # Sorted by stop_id: A_STOP=01, B_STOP=02
      assert mapping["A_STOP"] == "main-hall-01"
      assert mapping["B_STOP"] == "main-hall-02"
    end

    test "strips special characters" do
      child_stops = [
        %{stop_id: "S1", stop_name: "Track #3 (North)", location_type: 0, level_id: "L1"}
      ]

      result = StationNaming.build_kebab_naming_map(child_stops)

      assert [%{old_id: "S1", new_id: "track-3-north-01"}] = result
    end

    test "falls back to stop_id when stop_name is nil" do
      child_stops = [
        %{stop_id: "MY_STOP", stop_name: nil, location_type: 3, level_id: nil}
      ]

      result = StationNaming.build_kebab_naming_map(child_stops)

      assert [%{old_id: "MY_STOP", new_id: "my-stop-01"}] = result
    end

    test "returns empty list for empty input" do
      assert [] == StationNaming.build_kebab_naming_map([])
    end
  end

  describe "detect_collisions/2" do
    test "returns empty when no collisions" do
      naming_map = [%{old_id: "OLD_1", new_id: "new_1"}]
      existing = MapSet.new(["OLD_1", "OTHER"])

      assert [] == StationNaming.detect_collisions(naming_map, existing)
    end

    test "detects collisions with external IDs" do
      naming_map = [
        %{old_id: "OLD_1", new_id: "new_1"},
        %{old_id: "OLD_2", new_id: "CONFLICT"}
      ]

      existing = MapSet.new(["OLD_1", "OLD_2", "CONFLICT"])

      assert ["CONFLICT"] = StationNaming.detect_collisions(naming_map, existing)
    end

    test "does not flag collision when new_id matches an old_id being renamed" do
      naming_map = [
        %{old_id: "A", new_id: "B"},
        %{old_id: "B", new_id: "C"}
      ]

      existing = MapSet.new(["A", "B"])

      assert [] == StationNaming.detect_collisions(naming_map, existing)
    end
  end
end
