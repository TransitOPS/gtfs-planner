defmodule GtfsPlannerWeb.Gtfs.StopDetailComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlannerWeb.Gtfs.StopDetailComponents

  defp level(level_id, index, name \\ nil),
    do: %Level{level_id: level_id, level_index: index, level_name: name}

  defp child(stop_id, location_type, level \\ nil),
    do: %Stop{
      id: stop_id,
      stop_id: stop_id,
      location_type: location_type,
      parent_station: "STATION",
      level: level
    }

  defp declared(level, filename \\ nil),
    do: %{level: level, stop_count: 0, diagram_filename: filename, stop_level: nil}

  describe "stop_kind/1" do
    test "reads a stop with no parent as a stop and one inside a station as a platform" do
      assert StopDetailComponents.stop_kind(%Stop{location_type: 0, parent_station: nil}) ==
               "Stop"

      assert StopDetailComponents.stop_kind(%Stop{location_type: 0, parent_station: ""}) ==
               "Stop"

      assert StopDetailComponents.stop_kind(%Stop{location_type: 0, parent_station: "NTC"}) ==
               "Platform"
    end

    test "names each other location type in plain words" do
      assert StopDetailComponents.stop_kind(%Stop{location_type: 1}) == "Station"
      assert StopDetailComponents.stop_kind(%Stop{location_type: 2}) == "Entrance"
      assert StopDetailComponents.stop_kind(%Stop{location_type: 3}) == "Connection point"
      assert StopDetailComponents.stop_kind(%Stop{location_type: 4}) == "Boarding area"
    end
  end

  describe "inventory/3" do
    test "counts what is inside a station" do
      stops = [
        child("B1", 0),
        child("B2", 0),
        child("E1", 2),
        child("WR", 3),
        child("BA", 4)
      ]

      levels = [declared(level("L0", 0.0)), declared(level("L1", 1.0))]

      assert StopDetailComponents.inventory(%Stop{location_type: 1}, stops, levels) ==
               "Station · 2 platforms, 1 entrance, 2 connection points, 2 levels"
    end

    test "says nothing was added when a station has no stops" do
      assert StopDetailComponents.inventory(%Stop{location_type: 1}, [], []) ==
               "Station · nothing added yet"
    end

    test "leaves out the counts of a region that did not load" do
      assert StopDetailComponents.inventory(%Stop{location_type: 1}, :unavailable, []) ==
               "Station"

      assert StopDetailComponents.inventory(
               %Stop{location_type: 1},
               [child("B1", 0)],
               :unavailable
             ) == "Station · 1 platform, 0 entrances"
    end

    test "names the kind of any record that is not a station" do
      assert StopDetailComponents.inventory(
               %Stop{location_type: 0, parent_station: nil},
               [],
               []
             ) == "Stop"

      assert StopDetailComponents.inventory(%Stop{location_type: 2}, [], []) == "Entrance"
    end
  end

  describe "build_floors/2" do
    test "puts ground first, then upper floors, then below ground" do
      levels = [
        declared(level("LB2", -2.0)),
        declared(level("L1", 1.0)),
        declared(level("LB1", -1.0)),
        declared(level("L0", 0.0))
      ]

      floors = StopDetailComponents.build_floors(levels, [])

      assert Enum.map(floors, & &1.id) == ["L0", "L1", "LB1", "LB2"]
    end

    test "groups each stop under its own level" do
      street = level("L0", 0.0, "Street level")
      concourse = level("L1", 1.0, "Concourse")
      bay = child("B1", 0, street)
      lobby = child("UL", 3, concourse)

      floors =
        StopDetailComponents.build_floors(
          [declared(street), declared(concourse)],
          [bay, lobby]
        )

      assert [%{name: "Street level", stops: [^bay]}, %{name: "Concourse", stops: [^lobby]}] =
               floors
    end

    test "names a floor by its ID when the level has no name" do
      [floor] = StopDetailComponents.build_floors([declared(level("L0", 0.0))], [])

      assert floor.name == "L0"
    end

    test "keeps a level that holds no stops as an empty floor" do
      [floor] = StopDetailComponents.build_floors([declared(level("L0", 0.0))], [])

      assert floor.stops == []
    end

    test "reads a floorplan from the level's diagram file" do
      floors =
        StopDetailComponents.build_floors(
          [
            declared(level("L0", 0.0), "plan.png"),
            declared(level("L1", 1.0), nil),
            declared(level("L2", 2.0), "")
          ],
          []
        )

      assert Enum.map(floors, & &1.floorplan) == [:added, :missing, :missing]
    end

    test "collects stops with no level into a last group that needs attention" do
      street = level("L0", 0.0)
      orphan = child("B6", 0)

      floors =
        StopDetailComponents.build_floors([declared(street)], [child("B1", 0, street), orphan])

      assert [%{id: "L0", no_level?: false}, %{id: "none", no_level?: true, stops: [^orphan]}] =
               floors
    end

    test "adds no group for stops when every stop has a level" do
      street = level("L0", 0.0)

      floors = StopDetailComponents.build_floors([declared(street)], [child("B1", 0, street)])

      assert Enum.map(floors, & &1.id) == ["L0"]
    end

    test "groups stops under their own levels when the levels did not load" do
      street = level("L0", 0.0, "Street level")

      [floor] = StopDetailComponents.build_floors(:unavailable, [child("B1", 0, street)])

      assert %{name: "Street level", floorplan: :unknown, stops: [%Stop{stop_id: "B1"}]} = floor
    end

    test "leaves a floor's stops unset when the stops did not load" do
      [floor] = StopDetailComponents.build_floors([declared(level("L0", 0.0))], :unavailable)

      assert floor.stops == nil
    end

    test "returns no floors when neither region loaded" do
      assert StopDetailComponents.build_floors(:unavailable, :unavailable) == []
    end
  end

  describe "access_status/1" do
    test "says a missing value is not recorded rather than inaccessible" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StopDetailComponents.access_status status={:unknown} source={:missing} />
        """)

      assert html =~ ~s(data-accessibility="unknown")
      assert html =~ "Not recorded"
      refute html =~ "Not accessible"
    end

    test "says where an inherited value comes from" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StopDetailComponents.access_status status={:accessible} source={:inherited} />
        """)

      assert html =~ ~s(data-accessibility="accessible")
      assert html =~ ~s(data-accessibility-source="inherited")
      assert html =~ "Follows the station"
    end

    test "does not credit a direct value to the station" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StopDetailComponents.access_status status={:not_accessible} source={:direct} />
        """)

      assert html =~ "Not accessible"
      refute html =~ "Follows the station"
    end
  end
end
