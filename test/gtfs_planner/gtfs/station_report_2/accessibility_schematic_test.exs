defmodule GtfsPlanner.Gtfs.StationReport2.AccessibilitySchematicTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationReport2.Accessibility
  alias GtfsPlanner.Gtfs.StationReport2.AccessibilitySchematic
  alias GtfsPlanner.Gtfs.Stop

  # Minimum center-to-center spacing between nodes in one band
  # (AccessibilitySchematic's @min_node_gap).
  @min_node_gap 188.0

  # --- Fixture helpers ---

  defp level(id, index, name) do
    %{
      level: %Level{
        id: Ecto.UUID.generate(),
        level_id: id,
        level_index: index,
        level_name: name
      }
    }
  end

  defp stop(stop_id, location_type, attrs) do
    base = %Stop{
      id: Ecto.UUID.generate(),
      stop_id: stop_id,
      stop_name: Map.get(attrs, :stop_name, stop_id),
      location_type: location_type,
      parent_station: Map.get(attrs, :parent_station, "stn_1"),
      level_id: Map.get(attrs, :level_id),
      wheelchair_boarding: Map.get(attrs, :wheelchair_boarding),
      diagram_coordinate: Map.get(attrs, :diagram_coordinate)
    }

    struct!(base, attrs)
  end

  defp pathway(pathway_id, mode, from_stop_id, to_stop_id, attrs \\ %{}) do
    base = %Pathway{
      id: Ecto.UUID.generate(),
      pathway_id: pathway_id,
      pathway_mode: mode,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      is_bidirectional: Map.get(attrs, :is_bidirectional, true),
      traversal_time: Map.get(attrs, :traversal_time),
      length: Map.get(attrs, :length),
      max_slope: Map.get(attrs, :max_slope),
      min_width: Map.get(attrs, :min_width)
    }

    struct!(base, attrs)
  end

  defp confirmed_walkway(id, from_id, to_id, attrs \\ %{}) do
    pathway(
      id,
      1,
      from_id,
      to_id,
      Map.merge(
        %{min_width: Decimal.new("1.50"), length: Decimal.new("20"), traversal_time: 20},
        attrs
      )
    )
  end

  defp confirmed_elevator(id, from_id, to_id, attrs \\ %{}) do
    pathway(
      id,
      5,
      from_id,
      to_id,
      Map.merge(%{min_width: Decimal.new("1.20"), traversal_time: 35}, attrs)
    )
  end

  defp confirmed_gate(id, mode, from_id, to_id, attrs \\ %{}) do
    pathway(id, mode, from_id, to_id, Map.merge(%{min_width: Decimal.new("1.00")}, attrs))
  end

  defp snapshot(child_stops, pathways, opts \\ []) do
    station = Keyword.get(opts, :station, stop("stn_1", 1, %{parent_station: nil}))

    levels =
      Keyword.get(opts, :levels, [
        level("L0", 0.0, "Street"),
        level("L1", -1.0, "Mezzanine"),
        level("L2", -2.0, "Platforms")
      ])

    %{
      station: station,
      child_stops: child_stops,
      pathways: pathways,
      levels: levels
    }
  end

  defp assert_no_node_overlaps(nodes) do
    pairs =
      for {n1, i} <- Enum.with_index(nodes),
          {n2, j} <- Enum.with_index(nodes),
          i < j,
          do: {n1, n2}

    Enum.each(pairs, fn {n1, n2} ->
      horiz_sep = abs(n1.x - n2.x)
      vert_sep = abs(n1.y - n2.y)
      min_x = (n1.width + n2.width) / 2.0
      min_y = (n1.height + n2.height) / 2.0

      assert horiz_sep >= min_x or vert_sep >= min_y,
             "Nodes #{n1.stop_id} (#{n1.x}, #{n1.y}) and #{n2.stop_id} (#{n2.x}, #{n2.y}) overlap"
    end)
  end

  # --- Vertical level ordering & unpaid/paid sub-bands ---

  describe "vertical swimlane ordering and fare-gate sub-bands" do
    test "orders levels by level_index descending, places unassigned stops last, and splits unpaid/paid intermediate levels" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("m_unpaid", 3, %{level_id: "L1"}),
        stop("m_paid", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"}),
        stop("p_unassigned", 0, %{level_id: nil})
      ]

      pathways = [
        confirmed_elevator("ev_st_m", "e1", "m_unpaid"),
        confirmed_gate("fg_1", 6, "m_unpaid", "m_paid"),
        confirmed_elevator("ev_m_p", "m_paid", "p1"),
        confirmed_walkway("w_unassigned", "p1", "p_unassigned")
      ]

      # Pass levels out of order to verify deterministic level_index descending sort
      snap =
        snapshot(stops, pathways,
          levels: [
            level("L2", -2.0, "Platforms"),
            level("L0", 0.0, "Street"),
            level("L1", -1.0, "Mezzanine")
          ]
        )

      analysis = Accessibility.build(snap)
      layout = AccessibilitySchematic.build_layout(snap, analysis, mode: :rider)

      assert layout.width > 0
      assert layout.height > 0
      assert layout.has_fare_gates? == true
      assert Enum.map(layout.lanes, & &1.level_id) == ["L0", "L1", "L2", nil]

      # Lane y positions strictly increase top-to-bottom
      lane_ys = Enum.map(layout.lanes, & &1.y)
      assert lane_ys == Enum.sort(lane_ys)
      assert length(Enum.uniq(lane_ys)) == 4

      # Only Mezzanine (which has both unpaid and paid nodes) splits into Unpaid / Paid sub-bands
      [l0, l1, l2, l_nil] = layout.lanes
      refute l0.split_fare_zones?
      assert l1.split_fare_zones? == true
      refute l2.split_fare_zones?
      refute l_nil.split_fare_zones?

      assert Enum.map(l1.sub_bands, & &1.fare_zone) == [:unpaid, :paid]

      [unpaid_band, paid_band] = l1.sub_bands
      assert unpaid_band.y < paid_band.y
      assert unpaid_band.node_ids == ["m_unpaid"]
      assert paid_band.node_ids == ["m_paid"]

      assert_no_node_overlaps(layout.nodes)
    end

    test "does not split any level when no fare gates exist" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("m1", 3, %{level_id: "L1"}),
        stop("m2", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      pathways = [
        confirmed_elevator("ev1", "e1", "m1"),
        confirmed_walkway("w1", "m1", "m2"),
        confirmed_elevator("ev2", "m2", "p1")
      ]

      snap = snapshot(stops, pathways)
      analysis = Accessibility.build(snap)
      layout = AccessibilitySchematic.build_layout(snap, analysis, mode: :rider)

      assert layout.has_fare_gates? == false
      assert Enum.all?(layout.lanes, &(not &1.split_fare_zones?))
      assert_no_node_overlaps(layout.nodes)
    end
  end

  # --- Horizontal ordering (CR-C4) ---

  describe "horizontal node ordering (CR-C4)" do
    test "orders nodes by floorplan diagram_coordinate.x when present" do
      stops = [
        stop("e_right", 2, %{level_id: "L0", diagram_coordinate: %{"x" => 80, "y" => 10}}),
        stop("e_left", 2, %{level_id: "L0", diagram_coordinate: %{x: 15, y: 10}}),
        stop("e_mid", 2, %{level_id: "L0", diagram_coordinate: %{"x" => 45.5, "y" => 10}}),
        stop("p_right", 0, %{level_id: "L2", diagram_coordinate: %{x: 75, y: 20}}),
        stop("p_left", 0, %{level_id: "L2", diagram_coordinate: %{x: 20, y: 20}})
      ]

      pathways = [
        confirmed_elevator("ev1", "e_left", "p_left"),
        confirmed_elevator("ev2", "e_mid", "p_left"),
        confirmed_elevator("ev3", "e_right", "p_right")
      ]

      snap = snapshot(stops, pathways)
      analysis = Accessibility.build(snap)
      layout = AccessibilitySchematic.build_layout(snap, analysis, mode: :rider)

      node_by_id = Map.new(layout.nodes, &{&1.stop_id, &1})

      assert node_by_id["e_left"].x < node_by_id["e_mid"].x
      assert node_by_id["e_mid"].x < node_by_id["e_right"].x
      assert node_by_id["p_left"].x < node_by_id["p_right"].x
      assert_no_node_overlaps(layout.nodes)
    end

    test "falls back to entrance-to-platform BFS discovery order then stop_id when diagram_coordinate is absent" do
      # Without coordinates, e1 discovers z_first before a_second -> z_first must sit left of a_second!
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("z_first", 3, %{level_id: "L1"}),
        stop("a_second", 3, %{level_id: "L1"}),
        stop("p_early", 0, %{level_id: "L2"}),
        stop("p_late", 0, %{level_id: "L2"})
      ]

      pathways = [
        confirmed_elevator("ev_start", "e1", "z_first"),
        confirmed_walkway("w_chain", "z_first", "a_second"),
        confirmed_elevator("ev_p1", "z_first", "p_early"),
        confirmed_elevator("ev_p2", "a_second", "p_late")
      ]

      snap = snapshot(stops, pathways)
      analysis = Accessibility.build(snap)
      layout = AccessibilitySchematic.build_layout(snap, analysis, mode: :rider)

      node_by_id = Map.new(layout.nodes, &{&1.stop_id, &1})

      assert node_by_id["z_first"].x < node_by_id["a_second"].x
      assert node_by_id["p_early"].x < node_by_id["p_late"].x
      assert_no_node_overlaps(layout.nodes)
    end

    test "snaps a sparse level's node to its elevator neighbor's column without breaking order or spacing" do
      # mix test test/gtfs_planner/gtfs/station_report_2/accessibility_schematic_test.exs --only test:"test horizontal node ordering (CR-C4) snaps a sparse level's node to its elevator neighbor's column without breaking order or spacing"
      #
      # Platforms (dense, 3 nodes) anchor the columns. Both Street entrances
      # (sparse, 2 nodes) ride an elevator to the middle platform: e_a takes that
      # column and e_b, which wants the same column, is pushed right instead of
      # overlapping.
      stops = [
        stop("e_a", 2, %{level_id: "L0", diagram_coordinate: %{x: 10, y: 0}}),
        stop("e_b", 2, %{level_id: "L0", diagram_coordinate: %{x: 20, y: 0}}),
        stop("p_left", 0, %{level_id: "L2", diagram_coordinate: %{x: 10, y: 0}}),
        stop("p_mid", 0, %{level_id: "L2", diagram_coordinate: %{x: 50, y: 0}}),
        stop("p_right", 0, %{level_id: "L2", diagram_coordinate: %{x: 90, y: 0}})
      ]

      pathways = [
        confirmed_elevator("ev_a", "e_a", "p_mid"),
        confirmed_elevator("ev_b", "e_b", "p_mid"),
        confirmed_walkway("w_left", "p_left", "p_mid"),
        confirmed_walkway("w_right", "p_mid", "p_right")
      ]

      snap =
        snapshot(stops, pathways,
          levels: [level("L0", 0.0, "Street"), level("L2", -2.0, "Platforms")]
        )

      layout = AccessibilitySchematic.build_layout(snap, Accessibility.build(snap), mode: :rider)
      node_by_id = Map.new(layout.nodes, &{&1.stop_id, &1})

      # Elevator-connected nodes share a vertical column
      assert node_by_id["e_a"].x == node_by_id["p_mid"].x

      # Left-to-right order within each band follows diagram_coordinate.x
      assert node_by_id["e_a"].x < node_by_id["e_b"].x
      assert node_by_id["p_left"].x < node_by_id["p_mid"].x
      assert node_by_id["p_mid"].x < node_by_id["p_right"].x

      # No two nodes in a band sit closer than the minimum center-to-center gap
      for {_band, band_nodes} <- Enum.group_by(layout.nodes, & &1.sub_band_id) do
        band_nodes
        |> Enum.map(& &1.x)
        |> Enum.sort()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [left, right] -> assert right - left >= @min_node_gap end)
      end

      assert_no_node_overlaps(layout.nodes)
    end
  end

  # --- Visibility & highlight filters (AC-6) ---

  describe "mode visibility and validation highlight tagging (AC-6)" do
    setup do
      stops = [
        stop("e_ok", 2, %{level_id: "L0"}),
        stop("e_stairs", 2, %{level_id: "L0"}),
        stop("m_pre", 3, %{level_id: "L1"}),
        stop("m_post", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      pathways = [
        # Near-threshold walkway (width 0.88 m)
        confirmed_walkway("w_near", "e_ok", "m_pre", %{
          min_width: Decimal.new("0.88"),
          max_slope: Decimal.new("0.04")
        }),
        # Unverified fare gate (missing min_width)
        pathway("fg_unver", 6, "m_pre", "m_post"),
        # Sole-link elevator (2 one-way rows)
        confirmed_elevator("ev_dn", "m_post", "p1", %{is_bidirectional: false}),
        confirmed_elevator("ev_up", "p1", "m_post", %{is_bidirectional: false}),
        # Measured barrier (steep ramp 12%) from inaccessible entrance
        pathway("ramp_barrier", 1, "e_stairs", "m_pre", %{
          max_slope: Decimal.new("0.12"),
          min_width: Decimal.new("1.50"),
          length: Decimal.new("12")
        }),
        # Stairs from inaccessible entrance
        pathway("stairs_1", 2, "e_stairs", "m_pre")
      ]

      snap = snapshot(stops, pathways)
      analysis = Accessibility.build(snap)
      %{snap: snap, analysis: analysis}
    end

    test "hides inaccessible entrances and barriers in :rider mode and :validation with barriers: false",
         %{snap: snap, analysis: analysis} do
      rider = AccessibilitySchematic.build_layout(snap, analysis, mode: :rider)

      val_no_barriers =
        AccessibilitySchematic.build_layout(snap, analysis,
          mode: :validation,
          highlights: %{
            barriers: false,
            unknown_data: false,
            near_threshold: false,
            single_elevator: false
          }
        )

      for layout <- [rider, val_no_barriers] do
        node_ids = MapSet.new(layout.nodes, & &1.stop_id)
        edge_ids = MapSet.new(layout.edges, & &1.pathway_id)

        assert MapSet.member?(node_ids, "e_ok")
        refute MapSet.member?(node_ids, "e_stairs")

        assert MapSet.member?(edge_ids, "w_near")
        assert MapSet.member?(edge_ids, "fg_unver")
        assert MapSet.member?(edge_ids, "ev_dn")
        assert MapSet.member?(edge_ids, "ev_up")
        refute MapSet.member?(edge_ids, "ramp_barrier")
        refute MapSet.member?(edge_ids, "stairs_1")

        # Parallel one-way elevator edges have distinct path geometry so they do not collide
        by_id = Map.new(layout.edges, &{&1.pathway_id, &1})
        assert by_id["ev_dn"].path_d != by_id["ev_up"].path_d
        assert by_id["ev_dn"].label_x != by_id["ev_up"].label_x

        assert by_id["fg_unver"].style_role == :schematic_unverified
        assert by_id["fg_unver"].stroke_style == :dotted
        assert Enum.all?(layout.edges, &(&1.active_highlights == [] and not &1.dimmed?))
      end
    end

    test "reveals barriers and inaccessible entrances and tags all four validation highlights",
         %{snap: snap, analysis: analysis} do
      layout =
        AccessibilitySchematic.build_layout(snap, analysis,
          mode: :validation,
          highlights: %{
            barriers: true,
            unknown_data: true,
            near_threshold: true,
            single_elevator: true
          }
        )

      node_by_id = Map.new(layout.nodes, &{&1.stop_id, &1})
      edge_by_id = Map.new(layout.edges, &{&1.pathway_id, &1})

      assert Map.has_key?(node_by_id, "e_stairs")
      assert node_by_id["e_stairs"].step_free? == false
      assert node_by_id["e_ok"].step_free? == true

      assert edge_by_id["ramp_barrier"].active_highlights == [:barrier]
      assert edge_by_id["ramp_barrier"].style_role == :pathway_barrier
      assert edge_by_id["ramp_barrier"].stroke_style == :dashed

      assert edge_by_id["stairs_1"].active_highlights == [:barrier]
      assert edge_by_id["stairs_1"].style_role == :pathway_not_step_free

      assert edge_by_id["fg_unver"].active_highlights == [:unknown_data]
      assert edge_by_id["fg_unver"].style_role == :schematic_unverified
      assert edge_by_id["fg_unver"].stroke_style == :dotted

      assert edge_by_id["w_near"].active_highlights == [:near_threshold]
      assert edge_by_id["w_near"].style_role == :schematic_near_threshold
      assert edge_by_id["w_near"].stroke_style == :dashed

      assert edge_by_id["ev_dn"].active_highlights == [:single_elevator]
      assert edge_by_id["ev_dn"].style_role == :schematic_sole_elevator
      assert edge_by_id["ev_up"].active_highlights == [:single_elevator]

      assert_no_node_overlaps(layout.nodes)
    end

    test "dims non-matching edges when a subset of validation highlights is active",
         %{snap: snap, analysis: analysis} do
      layout =
        AccessibilitySchematic.build_layout(snap, analysis,
          mode: :validation,
          highlights: %{
            barriers: false,
            unknown_data: true,
            near_threshold: false,
            single_elevator: false
          }
        )

      edge_by_id = Map.new(layout.edges, &{&1.pathway_id, &1})

      assert edge_by_id["fg_unver"].highlighted? == true
      assert edge_by_id["fg_unver"].dimmed? == false

      assert edge_by_id["ev_dn"].highlighted? == false
      assert edge_by_id["ev_dn"].dimmed? == true
    end
  end

  # --- INV-3 & determinism ---

  describe "determinism and stop-name invariance (INV-3)" do
    test "produces identical coordinates, lanes, and edge paths regardless of stop_name values" do
      stops = [
        stop("e1", 2, %{level_id: "L0", stop_name: "North Entrance"}),
        stop("e2", 2, %{level_id: "L0", stop_name: "South Entrance"}),
        stop("m_u", 3, %{level_id: "L1", stop_name: "Unpaid Concourse"}),
        stop("m_p", 3, %{level_id: "L1", stop_name: "Paid Concourse"}),
        stop("p1", 0, %{level_id: "L2", stop_name: "Platform 1"}),
        stop("p2", 0, %{level_id: "L2", stop_name: "Platform 2"})
      ]

      pathways = [
        confirmed_elevator("ev1", "e1", "m_u"),
        confirmed_elevator("ev2", "e2", "m_u"),
        confirmed_gate("fg1", 6, "m_u", "m_p"),
        confirmed_elevator("ev3", "m_p", "p1"),
        confirmed_elevator("ev4", "m_p", "p2")
      ]

      snap1 = snapshot(stops, pathways)

      renamed_stops =
        stops
        |> Enum.with_index()
        |> Enum.map(fn {s, i} -> %{s | stop_name: "ZZ_Paid_Unpaid_North_#{99 - i}"} end)

      snap2 = snapshot(renamed_stops, pathways)

      layout1 =
        AccessibilitySchematic.build_layout(snap1, Accessibility.build(snap1), mode: :rider)

      layout2 =
        AccessibilitySchematic.build_layout(snap2, Accessibility.build(snap2), mode: :rider)

      assert layout1.width == layout2.width
      assert layout1.height == layout2.height
      assert layout1.view_box == layout2.view_box
      assert layout1.lanes == layout2.lanes

      node_geom = fn nodes ->
        Enum.map(nodes, &{&1.stop_id, &1.x, &1.y, &1.level_id, &1.fare_zone, &1.role})
      end

      edge_geom = fn edges ->
        Enum.map(edges, &{&1.pathway_id, &1.path_d, &1.x1, &1.y1, &1.x2, &1.y2, &1.style_role})
      end

      assert node_geom.(layout1.nodes) == node_geom.(layout2.nodes)
      assert edge_geom.(layout1.edges) == edge_geom.(layout2.edges)
      assert_no_node_overlaps(layout1.nodes)
    end
  end
end
