defmodule GtfsPlannerWeb.Gtfs.StationJournalMarkersTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlannerWeb.Gtfs.StationJournalMarkers

  describe "build_index/2 and project/2 for pins" do
    test "projects all pins with valid finite 0.0..100.0 coordinates on active level" do
      level_id = Ecto.UUID.generate()
      other_level_id = Ecto.UUID.generate()

      now = DateTime.utc_now()

      noted_pin = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: level_id,
        diagram_x: 45.5,
        diagram_y: 60.0,
        body: "First line note\nSecond line note",
        captured_at: now,
        inserted_at: now
      }

      closed_pin = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: level_id,
        diagram_x: 10.0,
        diagram_y: 20.0,
        body: nil,
        captured_at: now,
        closed_at: now,
        inserted_at: now
      }

      off_level_pin = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: other_level_id,
        diagram_x: 30.0,
        diagram_y: 40.0,
        body: "Off level",
        captured_at: now,
        inserted_at: now
      }

      targets = %{
        presentations: %{},
        nodes: %{},
        pathways: %{},
        stop_levels: %{}
      }

      index = StationJournalMarkers.build_index([noted_pin, closed_pin, off_level_pin], targets)

      geometry = %{
        active_level_id: level_id,
        child_stops: [],
        pathways: [],
        focused_marker_id: "journal-marker-pin-#{noted_pin.id}"
      }

      markers = StationJournalMarkers.project(index, geometry)

      assert length(markers) == 2

      noted_marker = Enum.find(markers, &(&1.id == "journal-marker-pin-#{noted_pin.id}"))
      assert noted_marker.kind == :pin
      assert noted_marker.total_count == 1
      assert noted_marker.x == 45.5
      assert noted_marker.y == 60.0
      assert noted_marker.accessible_name == "Journal entry: First line note"
      assert noted_marker.focused? == true

      closed_marker = Enum.find(markers, &(&1.id == "journal-marker-pin-#{closed_pin.id}"))
      assert closed_marker.kind == :pin
      assert closed_marker.total_count == 1
      assert closed_marker.x == 10.0
      assert closed_marker.y == 20.0
      assert closed_marker.accessible_name == "Journal entry: No note provided"
      assert closed_marker.focused? == false
    end

    test "omits station, non-finite, out-of-range, and missing level pins" do
      now = DateTime.utc_now()
      level_id = Ecto.UUID.generate()

      station_entry = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "station",
        body: "Station entry",
        captured_at: now,
        inserted_at: now
      }

      out_of_bounds_pin = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: level_id,
        diagram_x: 105.0,
        diagram_y: 50.0,
        captured_at: now,
        inserted_at: now
      }

      negative_pin = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: level_id,
        diagram_x: -0.1,
        diagram_y: 50.0,
        captured_at: now,
        inserted_at: now
      }

      no_level_pin = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: nil,
        diagram_x: 50.0,
        diagram_y: 50.0,
        captured_at: now,
        inserted_at: now
      }

      index =
        StationJournalMarkers.build_index(
          [station_entry, out_of_bounds_pin, negative_pin, no_level_pin],
          %{presentations: %{}, nodes: %{}, pathways: %{}, stop_levels: %{}}
        )

      geometry = %{
        active_level_id: level_id,
        child_stops: [],
        pathways: [],
        focused_marker_id: nil
      }

      assert StationJournalMarkers.project(index, geometry) == []
    end
  end

  describe "build_index/2 and project/2 for nodes" do
    test "aggregates node entries once with recency ordering, id tie break, and (+0.75, -0.75) offset" do
      level_id = Ecto.UUID.generate()
      node_id = Ecto.UUID.generate()
      t1 = DateTime.utc_now()
      t2 = DateTime.add(t1, 60, :second)

      # 3 entries on same node: two share captured_at/inserted_at t2, one is older
      e_closed = %JournalEntry{
        id: "e-closed-1",
        target_type: "node",
        target_id: node_id,
        captured_at: t2,
        closed_at: t2,
        inserted_at: t2
      }

      e_open_older = %JournalEntry{
        id: "e-open-old",
        target_type: "node",
        target_id: node_id,
        captured_at: t1,
        inserted_at: t1
      }

      e_open_newer = %JournalEntry{
        id: "e-open-new",
        target_type: "node",
        target_id: node_id,
        captured_at: t2,
        inserted_at: t2
      }

      node_stop = %Stop{
        id: node_id,
        stop_id: "STOP_1",
        stop_name: "Platform 1",
        level_id: level_id,
        diagram_coordinate: %{x: 40.0, y: 50.0}
      }

      targets = %{
        presentations: %{node_id => %{label: "Platform 1 Area"}},
        nodes: %{node_id => node_stop},
        pathways: %{},
        stop_levels: %{}
      }

      index = StationJournalMarkers.build_index([e_closed, e_open_older, e_open_newer], targets)
      group = index.groups["journal-marker-node-#{node_id}"]

      refute Map.has_key?(group, :entries)

      geometry = %{
        active_level_id: level_id,
        child_stops: [node_stop],
        pathways: [],
        focused_marker_id: nil
      }

      [marker] = StationJournalMarkers.project(index, geometry)

      assert marker.id == "journal-marker-node-#{node_id}"
      assert marker.kind == :node
      assert marker.target_id == node_id
      assert marker.total_count == 3
      # Check (+0.75, -0.75) offset
      assert marker.x == 40.75
      assert marker.y == 49.25
      # Pure recency ordering: captured_at desc, then inserted_at desc, then id desc.
      # e-open-new and e-closed-1 tie on both timestamps, so id desc decides.
      assert marker.entry_ids == ["e-open-new", "e-closed-1", "e-open-old"]
      assert marker.focus_entry_id == "e-open-new"
      assert marker.accessible_name == "Journal: 3 entries · Platform 1 Area"
    end

    test "projects node marker and floorplan locator when the group has only closed entries" do
      level_id = Ecto.UUID.generate()
      node_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      closed_entry = %JournalEntry{
        id: "closed-e-1",
        target_type: "node",
        target_id: node_id,
        captured_at: now,
        closed_at: now,
        inserted_at: now
      }

      node_stop = %Stop{
        id: node_id,
        stop_id: "STOP_1",
        stop_name: "Platform 1",
        level_id: level_id,
        diagram_coordinate: %{x: 40.0, y: 50.0}
      }

      targets = %{
        presentations: %{},
        nodes: %{node_id => node_stop},
        pathways: %{},
        stop_levels: %{}
      }

      index = StationJournalMarkers.build_index([closed_entry], targets)

      geometry = %{
        active_level_id: level_id,
        child_stops: [node_stop],
        pathways: [],
        focused_marker_id: nil
      }

      [marker] = StationJournalMarkers.project(index, geometry)

      assert marker.id == "journal-marker-node-#{node_id}"
      assert marker.kind == :node
      assert marker.total_count == 1
      assert marker.entry_ids == ["closed-e-1"]
      assert marker.focus_entry_id == "closed-e-1"
      assert marker.x == 40.75
      assert marker.y == 49.25
      assert marker.accessible_name == "Journal: 1 entry · Platform 1"

      # Closed entries are floorplan-locatable
      assert MapSet.member?(index.floorplan_entry_ids, "closed-e-1")

      assert {:ok, locator} = StationJournalMarkers.locate_entry(index, "closed-e-1")
      assert locator.marker_id == "journal-marker-node-#{node_id}"
      assert locator.level_id == level_id
    end
  end

  describe "build_index/2 and project/2 for pathways" do
    test "projects same-level pathway with canonical 0.75 perpendicular midpoint offset" do
      level_id = Ecto.UUID.generate()
      pathway_id = Ecto.UUID.generate()
      stop_a_id = Ecto.UUID.generate()
      stop_b_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      entry = %JournalEntry{
        id: Ecto.UUID.generate(),
        target_type: "pathway",
        target_id: pathway_id,
        captured_at: now,
        inserted_at: now
      }

      stop_a = %Stop{
        id: stop_a_id,
        stop_id: "A",
        stop_name: "Stop A",
        level_id: level_id,
        diagram_coordinate: %{x: 20.0, y: 50.0}
      }

      stop_b = %Stop{
        id: stop_b_id,
        stop_id: "B",
        stop_name: "Stop B",
        level_id: level_id,
        diagram_coordinate: %{x: 80.0, y: 50.0}
      }

      pathway = %Pathway{
        id: pathway_id,
        pathway_id: "PW_1",
        from_stop_id: stop_a_id,
        to_stop_id: stop_b_id,
        signposted_as: "Stairs to Mezzanine"
      }

      targets = %{
        presentations: %{pathway_id => %{label: "Stairs to Mezzanine"}},
        nodes: %{stop_a_id => stop_a, stop_b_id => stop_b},
        pathways: %{pathway_id => pathway},
        stop_levels: %{}
      }

      index = StationJournalMarkers.build_index([entry], targets)

      geometry = %{
        active_level_id: level_id,
        child_stops: [stop_a, stop_b],
        pathways: [pathway],
        focused_marker_id: nil
      }

      [marker] = StationJournalMarkers.project(index, geometry)

      assert marker.id == "journal-marker-pathway-#{pathway_id}"
      assert marker.kind == :pathway
      # Midpoint of (20,50) and (80,50) is (50, 50)
      # Horizontal segment dx=60, dy=0 -> dx>0 -> perpendicular offset with negative y is (0, -0.75)
      assert marker.x == 50.0
      assert marker.y == 49.25
      assert marker.accessible_name == "Journal: 1 entry · Stairs to Mezzanine"
    end

    test "omits cross-level and zero-length pathways" do
      level1_id = Ecto.UUID.generate()
      level2_id = Ecto.UUID.generate()
      pw_cross_id = Ecto.UUID.generate()
      pw_zero_id = Ecto.UUID.generate()

      s1 = %Stop{id: "s1", level_id: level1_id, diagram_coordinate: %{x: 10.0, y: 10.0}}
      s2 = %Stop{id: "s2", level_id: level2_id, diagram_coordinate: %{x: 20.0, y: 20.0}}
      s3 = %Stop{id: "s3", level_id: level1_id, diagram_coordinate: %{x: 30.0, y: 30.0}}
      s4 = %Stop{id: "s4", level_id: level1_id, diagram_coordinate: %{x: 30.0, y: 30.0}}

      pw_cross = %Pathway{id: pw_cross_id, from_stop_id: "s1", to_stop_id: "s2"}
      pw_zero = %Pathway{id: pw_zero_id, from_stop_id: "s3", to_stop_id: "s4"}

      now = DateTime.utc_now()

      e1 = %JournalEntry{
        id: "e1",
        target_type: "pathway",
        target_id: pw_cross_id,
        captured_at: now,
        inserted_at: now
      }

      e2 = %JournalEntry{
        id: "e2",
        target_type: "pathway",
        target_id: pw_zero_id,
        captured_at: now,
        inserted_at: now
      }

      targets = %{
        presentations: %{},
        nodes: %{"s1" => s1, "s2" => s2, "s3" => s3, "s4" => s4},
        pathways: %{pw_cross_id => pw_cross, pw_zero_id => pw_zero},
        stop_levels: %{}
      }

      index = StationJournalMarkers.build_index([e1, e2], targets)

      geometry = %{
        active_level_id: level1_id,
        child_stops: [s1, s3, s4],
        pathways: [pw_cross, pw_zero],
        focused_marker_id: nil
      }

      assert StationJournalMarkers.project(index, geometry) == []
    end
  end

  describe "active_marker/3 and locate_entry/2" do
    test "active_marker/3 resolves active projected marker or returns :error" do
      level_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      pin_entry = %JournalEntry{
        id: "pin-1",
        target_type: "pin",
        stop_level_id: level_id,
        diagram_x: 50.0,
        diagram_y: 50.0,
        body: "Test pin",
        captured_at: now,
        inserted_at: now
      }

      index =
        StationJournalMarkers.build_index([pin_entry], %{
          presentations: %{},
          nodes: %{},
          pathways: %{},
          stop_levels: %{}
        })

      geometry = %{
        active_level_id: level_id,
        child_stops: [],
        pathways: [],
        focused_marker_id: nil
      }

      assert {:ok, marker} =
               StationJournalMarkers.active_marker(index, "journal-marker-pin-pin-1", geometry)

      assert marker.id == "journal-marker-pin-pin-1"

      assert StationJournalMarkers.active_marker(index, "stale-marker-id", geometry) == :error
    end

    test "locate_entry/2 resolves valid floorplan entry locators and rejects invalid or stale entries" do
      level_id = Ecto.UUID.generate()
      node_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      pin_entry = %JournalEntry{
        id: "pin-100",
        target_type: "pin",
        stop_level_id: level_id,
        diagram_x: 25.0,
        diagram_y: 75.0,
        body: "Pin 100",
        captured_at: now,
        inserted_at: now
      }

      node_entry = %JournalEntry{
        id: "node-e-1",
        target_type: "node",
        target_id: node_id,
        captured_at: now,
        inserted_at: now
      }

      node_stop = %Stop{
        id: node_id,
        stop_id: "STOP_N",
        stop_name: "North Gate",
        level_id: level_id,
        diagram_coordinate: %{x: 10.0, y: 10.0}
      }

      targets = %{
        presentations: %{node_id => %{label: "North Gate"}},
        nodes: %{node_id => node_stop},
        pathways: %{},
        stop_levels: %{}
      }

      index = StationJournalMarkers.build_index([pin_entry, node_entry], targets)

      assert {:ok, pin_loc} = StationJournalMarkers.locate_entry(index, "pin-100")
      assert pin_loc.entry_id == "pin-100"
      assert pin_loc.marker_id == "journal-marker-pin-pin-100"
      assert pin_loc.level_id == level_id

      assert {:ok, node_loc} = StationJournalMarkers.locate_entry(index, "node-e-1")
      assert node_loc.entry_id == "node-e-1"
      assert node_loc.marker_id == "journal-marker-node-#{node_id}"
      assert node_loc.level_id == level_id

      assert StationJournalMarkers.locate_entry(index, "non-existent-entry") == :error
    end
  end
end
