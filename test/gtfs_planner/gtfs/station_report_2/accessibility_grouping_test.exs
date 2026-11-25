defmodule GtfsPlanner.Gtfs.StationReport2.AccessibilityGroupingTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationReport2.Accessibility
  alias GtfsPlanner.Gtfs.StationReport2.AccessibilityGrouping
  alias GtfsPlanner.Gtfs.Stop

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  # --- Pure in-memory fixture helpers ---

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
        %{min_width: Decimal.new("1.50"), length: Decimal.new("30"), traversal_time: 25},
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

  defp route_info(route_id, short_name, long_name, route_type, opts \\ []) do
    %{
      route_id: route_id,
      route_short_name: short_name,
      route_long_name: long_name,
      route_type: route_type,
      route_color: Keyword.get(opts, :route_color, "0055AA"),
      route_text_color: Keyword.get(opts, :route_text_color, "FFFFFF")
    }
  end

  defp snapshot(child_stops, pathways, opts \\ []) do
    station = Keyword.get(opts, :station, stop("stn_1", 1, %{parent_station: nil}))

    levels =
      Keyword.get(opts, :levels, [
        level("L0", 0.0, "Street"),
        level("L1", -1.0, "Mezzanine"),
        level("L2", -2.0, "Platform")
      ])

    %{
      station: station,
      child_stops: child_stops,
      pathways: pathways,
      levels: levels
    }
  end

  # --- CR-S2: Gtfs.get_routes_for_stops/3 database contract ---

  describe "Gtfs.get_routes_for_stops/3 (CR-S2)" do
    test "returns route_type and route_long_name alongside existing route keys, scoped to org and version" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      plat_a = stop_fixture(org.id, version.id, %{stop_id: "PLAT_A", location_type: 0})
      plat_b = stop_fixture(org.id, version.id, %{stop_id: "PLAT_B", location_type: 0})

      subway =
        route_fixture(org.id, version.id, %{
          route_id: "R_RED",
          route_short_name: "Red",
          route_long_name: "Red Line Subway",
          route_type: 1,
          route_color: "DA291C",
          route_text_color: "FFFFFF"
        })

      rail =
        route_fixture(org.id, version.id, %{
          route_id: "R_CR",
          route_short_name: nil,
          route_long_name: "Fitchburg Commuter Rail",
          route_type: 2,
          route_color: "80276C",
          route_text_color: "FFFFFF"
        })

      trip_sub = trip_fixture(org.id, version.id, subway.route_id, %{trip_id: "T_SUB"})
      trip_cr = trip_fixture(org.id, version.id, rail.route_id, %{trip_id: "T_CR"})

      stop_time_fixture(org.id, version.id, trip_sub.trip_id, plat_a.stop_id)
      stop_time_fixture(org.id, version.id, trip_cr.trip_id, plat_b.stop_id)

      # Foreign org stop with the same stop_id must not leak in
      _foreign_stop =
        stop_fixture(other_org.id, other_version.id, %{stop_id: "PLAT_A", location_type: 0})

      foreign_route =
        route_fixture(other_org.id, other_version.id, %{
          route_id: "R_FOREIGN",
          route_short_name: "Foreign",
          route_long_name: "Foreign Line",
          route_type: 3
        })

      foreign_trip =
        trip_fixture(other_org.id, other_version.id, foreign_route.route_id, %{trip_id: "T_FOR"})

      stop_time_fixture(other_org.id, other_version.id, foreign_trip.trip_id, "PLAT_A")

      result = Gtfs.get_routes_for_stops(org.id, version.id, ["PLAT_A", "PLAT_B"])

      assert [sub_info] = result["PLAT_A"]
      assert sub_info.route_id == "R_RED"
      assert sub_info.route_short_name == "Red"
      assert sub_info.route_long_name == "Red Line Subway"
      assert sub_info.route_type == 1
      assert sub_info.route_color == "DA291C"
      assert sub_info.route_text_color == "FFFFFF"

      assert [cr_info] = result["PLAT_B"]
      assert cr_info.route_id == "R_CR"
      assert is_nil(cr_info.route_short_name)
      assert cr_info.route_long_name == "Fitchburg Commuter Rail"
      assert cr_info.route_type == 2
      assert cr_info.route_color == "80276C"
      assert cr_info.route_text_color == "FFFFFF"
    end
  end

  # --- Platform grouping ---

  describe "platform grouping" do
    test "groups scheduled platforms by bipartite route components" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("p1", 0, %{level_id: "L2"}),
        stop("p2", 0, %{level_id: "L2"}),
        stop("p3", 0, %{level_id: "L2"}),
        stop("p4", 0, %{level_id: "L2"}),
        stop("ba4", 4, %{parent_station: "p4", level_id: "L2"})
      ]

      pathways = [
        confirmed_walkway("w1", "e1", "p1"),
        confirmed_walkway("w2", "e1", "p2"),
        confirmed_walkway("w3", "e1", "p3"),
        confirmed_walkway("w4", "e1", "ba4")
      ]

      # p1 & p2 share R1/R2 transitively -> one multi-route Subway component
      # p3 has single route R3 (with short name)
      # p4 gets route R4 via its boarding area ba4 (long name only)
      routes_by_stop = %{
        "p1" => [route_info("R1", "A", "Line A", 1), route_info("R2", "B", "Line B", 1)],
        "p2" => [route_info("R2", "B", "Line B", 1)],
        "p3" => [route_info("R3", "Orange", "Orange Line", 1)],
        "ba4" => [route_info("R4", nil, "Commuter Rail West", 2)]
      }

      snap = snapshot(stops, pathways)
      analysis = Accessibility.build(snap, routes_by_stop)
      grouped = AccessibilityGrouping.build_groups(snap, analysis)

      assert length(grouped.platform_groups) == 3

      by_ids = Map.new(grouped.platform_groups, &{&1.platform_stop_ids, &1})

      assert by_ids[["p1", "p2"]].grouping_strategy == :route_component
      assert by_ids[["p1", "p2"]].route_ids == ["R1", "R2"]

      assert by_ids[["p3"]].grouping_strategy == :route_component

      assert by_ids[["p4"]].grouping_strategy == :route_component
      assert by_ids[["p4"]].route_ids == ["R4"]
    end

    test "rolls up scheduled platforms to {route_type, level_id} when distinct route components exceed 6" do
      e1 = stop("e1", 2, %{level_id: "L0"})

      bus_platforms = Enum.map(1..5, &stop("pb#{&1}", 0, %{level_id: "L0"}))
      rail_platforms = Enum.map(1..2, &stop("pr#{&1}", 0, %{level_id: "L2"}))

      pathways =
        Enum.map(
          bus_platforms ++ rail_platforms,
          &confirmed_walkway("w_#{&1.stop_id}", "e1", &1.stop_id)
        )

      # 7 distinct route components (> 6) -> must roll up into 2 {route_type, level_id} groups
      routes_by_stop =
        Map.merge(
          Map.new(1..5, fn i ->
            {"pb#{i}", [route_info("B#{i}", "Bus #{i}", "Bus Route #{i}", 3)]}
          end),
          Map.new(1..2, fn i -> {"pr#{i}", [route_info("CR#{i}", "CR #{i}", "Rail #{i}", 2)]} end)
        )

      snap = snapshot([e1 | bus_platforms ++ rail_platforms], pathways)
      analysis = Accessibility.build(snap, routes_by_stop)
      grouped = AccessibilityGrouping.build_groups(snap, analysis)

      assert length(grouped.platform_groups) == 2

      by_type_level = Map.new(grouped.platform_groups, &{{&1.route_type, &1.level_id}, &1})

      bus_group = by_type_level[{3, "L0"}]
      assert bus_group.grouping_strategy == :route_type_level
      assert bus_group.platform_stop_ids == ["pb1", "pb2", "pb3", "pb4", "pb5"]

      rail_group = by_type_level[{2, "L2"}]
      assert rail_group.grouping_strategy == :route_type_level
      assert rail_group.platform_stop_ids == ["pr1", "pr2"]
    end

    test "falls back to level_id alone for unscheduled platforms (CR-S3)" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("p1", 0, %{level_id: "L1"}),
        stop("p2", 0, %{level_id: "L1"}),
        stop("p3", 0, %{level_id: "L2"}),
        stop("p_nil", 0, %{level_id: nil})
      ]

      pathways = [
        confirmed_walkway("w1", "e1", "p1"),
        confirmed_walkway("w2", "e1", "p2"),
        confirmed_walkway("w3", "e1", "p3"),
        confirmed_walkway("w4", "e1", "p_nil")
      ]

      snap = snapshot(stops, pathways)
      analysis = Accessibility.build(snap, %{})
      grouped = AccessibilityGrouping.build_groups(snap, analysis)

      assert length(grouped.platform_groups) == 3

      by_level = Map.new(grouped.platform_groups, &{&1.level_id, &1})

      assert by_level["L1"].grouping_strategy == :level_fallback
      assert by_level["L1"].platform_stop_ids == ["p1", "p2"]

      assert by_level["L2"].grouping_strategy == :level_fallback
      assert by_level["L2"].platform_stop_ids == ["p3"]

      assert by_level[nil].grouping_strategy == :level_fallback
      assert by_level[nil].platform_stop_ids == ["p_nil"]
    end
  end

  # --- Entrance grouping (CR-S3 single-rule structural components) ---

  describe "entrance grouping (CR-S3)" do
    test "groups step-free entrances by connected components after removing elevators and mode 6/7 gates" do
      stops = [
        stop("e1", 2, %{level_id: "L0", stop_name: "Main St"}),
        stop("e2", 2, %{level_id: "L0", stop_name: "Oak Ave"}),
        stop("e3", 2, %{level_id: "L0", stop_name: "South Plaza"}),
        stop("e_gated", 2, %{level_id: "L0", stop_name: "Gate Entrance"}),
        stop("e_stairs", 2, %{level_id: "L0", stop_name: "Stairs Only"}),
        stop("n_north", 3, %{level_id: "L0"}),
        stop("n_south", 3, %{level_id: "L0"}),
        stop("m_paid", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      pathways = [
        # e1 and e2 share a barrier-free street corridor to n_north -> same group
        confirmed_walkway("w_e1", "e1", "n_north"),
        confirmed_walkway("w_e2", "e2", "n_north"),
        # Elevator separates n_north from m_paid
        confirmed_elevator("ev_north", "n_north", "m_paid"),
        # e3 uses a separate elevator -> separate group
        confirmed_walkway("w_e3", "e3", "n_south"),
        confirmed_elevator("ev_south", "n_south", "m_paid"),
        # e_gated connects to n_north ONLY across a mode-6 fare gate -> separate group!
        confirmed_gate("fg_sep", 6, "e_gated", "n_north"),
        # e_stairs only has stairs -> not step-free, excluded from entrance groups
        pathway("st_only", 2, "e_stairs", "m_paid"),
        confirmed_elevator("ev_plat", "m_paid", "p1")
      ]

      snap = snapshot(stops, pathways)
      analysis = Accessibility.build(snap)
      grouped = AccessibilityGrouping.build_groups(snap, analysis)

      assert length(grouped.entrance_groups) == 3

      by_members = Map.new(grouped.entrance_groups, &{&1.entrance_stop_ids, &1})

      assert Map.has_key?(by_members, ["e1", "e2"])

      assert Map.has_key?(by_members, ["e3"])

      assert Map.has_key?(by_members, ["e_gated"])

      # Inaccessible stairs entrance must not appear in any entrance group
      all_grouped_e = Enum.flat_map(grouped.entrance_groups, & &1.entrance_stop_ids)
      refute "e_stairs" in all_grouped_e
    end
  end

  # --- Fare-gate zone partitioning ---

  describe "partition_fare_zones/1" do
    test "labels entrance-reachable nodes :unpaid and platform-reachable nodes :paid when mode 6/7 gates exist" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("m_pre", 3, %{level_id: "L1"}),
        stop("m_post", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"}),
        stop("ba1", 4, %{parent_station: "p1", level_id: "L2"})
      ]

      pathways = [
        confirmed_elevator("ev_st_m", "e1", "m_pre"),
        confirmed_gate("fg_in", 6, "m_pre", "m_post", %{is_bidirectional: false}),
        confirmed_gate("fg_out", 7, "m_post", "m_pre", %{is_bidirectional: false}),
        confirmed_elevator("ev_m_p", "m_post", "p1"),
        confirmed_walkway("w_ba", "p1", "ba1")
      ]

      zones = AccessibilityGrouping.partition_fare_zones(snapshot(stops, pathways))

      assert zones.has_fare_gates? == true
      assert zones.node_zones["e1"] == :unpaid
      assert zones.node_zones["m_pre"] == :unpaid
      assert zones.node_zones["m_post"] == :paid
      assert zones.node_zones["p1"] == :paid
      assert zones.node_zones["ba1"] == :paid
    end

    test "returns has_fare_gates?: false and all nodes :open when no mode 6/7 pathways exist" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("m1", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      pathways = [
        confirmed_elevator("ev1", "e1", "m1"),
        confirmed_elevator("ev2", "m1", "p1")
      ]

      zones = AccessibilityGrouping.partition_fare_zones(snapshot(stops, pathways))

      assert zones.has_fare_gates? == false
      assert zones.node_zones == %{"e1" => :open, "m1" => :open, "p1" => :open}
    end
  end

  # --- Corridor collapsing ---

  describe "collapse_corridors/2" do
    test "collapses >= 2 contiguous confirmed flat mode-1 walkways on same level & zone and preserves boundaries" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("u1", 3, %{level_id: "L0"}),
        stop("u2", 3, %{level_id: "L0"}),
        stop("u3", 3, %{level_id: "L0"}),
        stop("u_near", 3, %{level_id: "L0"}),
        stop("u_unver", 3, %{level_id: "L0"}),
        stop("m_unpaid", 3, %{level_id: "L1"}),
        stop("m_paid", 3, %{level_id: "L1"}),
        stop("m_p1", 3, %{level_id: "L1"}),
        stop("m_p2", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      pathways = [
        # 3 contiguous confirmed flat walkways on L0 unpaid -> collapses into 1 corridor (90 m, 75 s)
        confirmed_walkway("w1", "e1", "u1", %{length: Decimal.new("30"), traversal_time: 25}),
        confirmed_walkway("w2", "u1", "u2", %{length: Decimal.new("40"), traversal_time: 30}),
        confirmed_walkway("w3", "u2", "u3", %{length: Decimal.new("20"), traversal_time: 20}),
        # Near-threshold walkway (width 0.88 m) -> stays uncollapsed
        confirmed_walkway("w_near", "u3", "u_near", %{
          min_width: Decimal.new("0.88"),
          length: Decimal.new("10"),
          traversal_time: 10
        }),
        # Unverified walkway (missing min_width) -> stays uncollapsed
        pathway("w_unver", 1, "u_near", "u_unver", %{
          length: Decimal.new("15"),
          traversal_time: 12
        }),
        # Ramp down to L1 -> stays uncollapsed
        confirmed_walkway("w_ramp", "u_unver", "m_unpaid", %{
          max_slope: Decimal.new("0.05"),
          length: Decimal.new("25"),
          traversal_time: 22
        }),
        # Fare gate crossing unpaid -> paid -> stays uncollapsed
        confirmed_gate("fg1", 6, "m_unpaid", "m_paid"),
        # 2 contiguous confirmed walkways on L1 paid -> collapses into 1 corridor
        confirmed_walkway("w_p1", "m_paid", "m_p1", %{
          length: Decimal.new("18"),
          traversal_time: 15
        }),
        confirmed_walkway("w_p2", "m_p1", "m_p2", %{length: Decimal.new("22"), traversal_time: 18}),
        # Elevator down to L2 -> stays uncollapsed
        confirmed_elevator("ev1", "m_p2", "p1")
      ]

      snap = snapshot(stops, pathways)
      fare_zones = AccessibilityGrouping.partition_fare_zones(snap)
      route = Accessibility.build_route(snap, "e1", "p1")
      assert route != :no_route

      collapsed = AccessibilityGrouping.collapse_corridors(route.steps, fare_zones)

      assert Enum.map(collapsed, & &1.type) == [
               :corridor,
               :step,
               :step,
               :step,
               :step,
               :corridor,
               :step
             ]

      [c1, s_near, s_unver, s_ramp, s_gate, c2, s_elev] = collapsed

      assert c1.id == "corridor:w1..w3"
      assert c1.level_id == "L0"
      assert c1.level_name == "Street"
      assert c1.fare_zone == :unpaid
      assert c1.edge_count == 3
      assert Enum.map(c1.steps, & &1.pathway_id) == ["w1", "w2", "w3"]
      assert c1.distance_meters == 90.0
      assert c1.duration_seconds == 75.0

      assert s_near.step.pathway_id == "w_near"
      assert s_near.edge_count == 1

      assert s_unver.step.pathway_id == "w_unver"
      assert s_ramp.step.pathway_id == "w_ramp"
      assert s_gate.step.pathway_id == "fg1"

      assert c2.id == "corridor:w_p1..w_p2"
      assert c2.level_id == "L1"
      assert c2.fare_zone == :paid
      assert c2.edge_count == 2
      assert Enum.map(c2.steps, & &1.pathway_id) == ["w_p1", "w_p2"]
      assert c2.distance_meters == 40.0
      assert c2.duration_seconds == 33.0

      assert s_elev.step.pathway_id == "ev1"
    end

    test "does not collapse single walkway or moving sidewalks (mode 3)" do
      steps = [
        %{
          pathway_id: "w1",
          pathway_mode: 1,
          classification: :confirmed,
          is_ramp: false,
          near_threshold_fields: [],
          from_stop_id: "a",
          to_stop_id: "b",
          from_level_id: "L0",
          to_level_id: "L0",
          level_id: "L0",
          level_name: "Street",
          distance_meters: 10.0,
          duration_seconds: 8.0
        },
        %{
          pathway_id: "ms1",
          pathway_mode: 3,
          classification: :confirmed,
          is_ramp: false,
          near_threshold_fields: [],
          from_stop_id: "b",
          to_stop_id: "c",
          from_level_id: "L0",
          to_level_id: "L0",
          level_id: "L0",
          level_name: "Street",
          distance_meters: 25.0,
          duration_seconds: 15.0
        },
        %{
          pathway_id: "ms2",
          pathway_mode: 3,
          classification: :confirmed,
          is_ramp: false,
          near_threshold_fields: [],
          from_stop_id: "c",
          to_stop_id: "d",
          from_level_id: "L0",
          to_level_id: "L0",
          level_id: "L0",
          level_name: "Street",
          distance_meters: 25.0,
          duration_seconds: 15.0
        }
      ]

      collapsed =
        AccessibilityGrouping.collapse_corridors(steps, %{has_fare_gates?: false, node_zones: %{}})

      assert Enum.map(collapsed, & &1.type) == [:step, :step, :step]
      assert Enum.map(collapsed, & &1.id) == ["step:w1", "step:ms1", "step:ms2"]
    end
  end

  # --- INV-3: Strict zero stop-name parsing ---

  describe "stop-name invariance (INV-3)" do
    test "replacing every stop_name with adversarial opaque strings preserves groups, fare zones, matrix, and corridors" do
      {snap, routes_by_stop} = build_multi_line_hub_snapshot()

      adversarial_names = [
        "North Exit Paid Platform A",
        "South Unpaid Mezzanine Elevator 9",
        "Line B Track 1 Paid Concourse",
        "xq_9812_opaque_node",
        "Fare Gate West Entrance 77",
        "zz_random_token_alpha"
      ]

      renamed_stops =
        snap.child_stops
        |> Enum.with_index()
        |> Enum.map(fn {s, idx} ->
          opaque = Enum.at(adversarial_names, rem(idx, length(adversarial_names))) <> "_#{idx}"
          %{s | stop_name: opaque}
        end)

      renamed_snap = %{snap | child_stops: renamed_stops}

      analysis_orig = Accessibility.build(snap, routes_by_stop)
      analysis_ren = Accessibility.build(renamed_snap, routes_by_stop)

      groups_orig = AccessibilityGrouping.build_groups(snap, analysis_orig)
      groups_ren = AccessibilityGrouping.build_groups(renamed_snap, analysis_ren)

      zones_orig = AccessibilityGrouping.partition_fare_zones(snap)
      zones_ren = AccessibilityGrouping.partition_fare_zones(renamed_snap)

      assert zones_orig == zones_ren

      # Platform groups are 100% invariant (including titles, since titles come from routes/levels)
      platform_sig = fn groups ->
        Enum.map(groups, fn g ->
          {g.id, g.title, g.grouping_strategy, g.platform_stop_ids, g.route_ids, g.level_ids}
        end)
      end

      assert platform_sig.(groups_orig.platform_groups) ==
               platform_sig.(groups_ren.platform_groups)

      # Entrance group partitions, IDs, levels, and ordering are 100% invariant
      entrance_sig = fn groups ->
        Enum.map(groups, fn g ->
          {g.id, g.entrance_stop_ids, g.level_ids, g.entrance_count}
        end)
      end

      assert entrance_sig.(groups_orig.entrance_groups) ==
               entrance_sig.(groups_ren.entrance_groups)

      # Matrix cells have identical keys, counts, statuses, and pair statuses
      cell_sig = fn cells ->
        Map.new(cells, fn {k, c} ->
          {k,
           {c.confirmed, c.unverified, c.no_route, c.total, c.status,
            Enum.map(c.pairs, &{&1.entrance_stop_id, &1.platform_stop_id, &1.status})}}
        end)
      end

      assert cell_sig.(groups_orig.cells) == cell_sig.(groups_ren.cells)

      # Collapsed corridor structure is 100% invariant
      route_orig = Accessibility.build_route(snap, "e1", "p1")
      route_ren = Accessibility.build_route(renamed_snap, "e1", "p1")

      corridor_sig = fn items ->
        Enum.map(items, fn item ->
          {item.type, item.id, item.level_id, item.fare_zone, item.edge_count,
           item.distance_meters, item.duration_seconds, Enum.map(item.steps, & &1.pathway_id)}
        end)
      end

      assert corridor_sig.(AccessibilityGrouping.collapse_corridors(route_orig.steps, zones_orig)) ==
               corridor_sig.(AccessibilityGrouping.collapse_corridors(route_ren.steps, zones_ren))
    end
  end

  # --- 412-edge transfer-center hub matrix totals ---

  describe "412-edge transfer-center hub grouped matrix" do
    test "produces compact grouped matrix whose cell totals equal step_free_entrances * platforms" do
      {snap, routes_by_stop} = build_transfer_hub_412_with_routes()

      assert length(snap.pathways) == 412

      analysis = Accessibility.build(snap, routes_by_stop)
      grouped = AccessibilityGrouping.build_groups(snap, analysis)

      # 9 entrances separated into 3 structural basins by elevators (ev1, ev2/ev3, ev4)
      assert length(grouped.entrance_groups) == 3
      assert Enum.map(grouped.entrance_groups, & &1.entrance_count) == [3, 3, 3]

      # 12 platforms across 3 transit lines -> 3 compact platform groups
      assert length(grouped.platform_groups) == 3
      assert map_size(grouped.cells) == 9

      totals =
        Enum.reduce(grouped.cells, %{confirmed: 0, unverified: 0, no_route: 0}, fn {_k, cell},
                                                                                   acc ->
          assert cell.total == cell.confirmed + cell.unverified + cell.no_route
          assert cell.total == length(cell.pairs)

          %{
            confirmed: acc.confirmed + cell.confirmed,
            unverified: acc.unverified + cell.unverified,
            no_route: acc.no_route + cell.no_route
          }
        end)

      expected_total = length(analysis.step_free_entrances) * length(analysis.platforms)
      assert expected_total == 108
      assert totals.confirmed + totals.unverified + totals.no_route == expected_total
      assert totals == analysis.confidence_counts
      assert totals.confirmed == 72
      assert totals.unverified == 36
      assert totals.no_route == 0
    end
  end

  # --- Synthetic fixtures ---

  defp build_multi_line_hub_snapshot do
    stops = [
      stop("e1", 2, %{level_id: "L0", stop_name: "North 1"}),
      stop("e2", 2, %{level_id: "L0", stop_name: "North 2"}),
      stop("e3", 2, %{level_id: "L0", stop_name: "South 1"}),
      stop("u_a", 3, %{level_id: "L0", stop_name: "North Lobby"}),
      stop("u_b", 3, %{level_id: "L0", stop_name: "North Elevator Lobby"}),
      stop("u_s", 3, %{level_id: "L0", stop_name: "South Lobby"}),
      stop("m_u", 3, %{level_id: "L1", stop_name: "Mezzanine Pre"}),
      stop("m_p", 3, %{level_id: "L1", stop_name: "Mezzanine Post"}),
      stop("p1", 0, %{level_id: "L2", stop_name: "Track 1"}),
      stop("p2", 0, %{level_id: "L2", stop_name: "Track 2"}),
      stop("p3", 0, %{level_id: "L2", stop_name: "Track 3"})
    ]

    pathways = [
      confirmed_walkway("w1", "e1", "u_a"),
      confirmed_walkway("w2", "u_a", "u_b"),
      confirmed_walkway("w3", "e2", "u_b"),
      confirmed_elevator("ev_n", "u_b", "m_u"),
      confirmed_walkway("w_s", "e3", "u_s"),
      confirmed_elevator("ev_s", "u_s", "m_u"),
      confirmed_gate("fg_1", 6, "m_u", "m_p"),
      confirmed_elevator("ev_p1", "m_p", "p1"),
      confirmed_elevator("ev_p2", "m_p", "p2"),
      confirmed_elevator("ev_p3", "m_p", "p3")
    ]

    routes_by_stop = %{
      "p1" => [route_info("LA", "Line A", "Line A Metro", 1)],
      "p2" => [route_info("LA", "Line A", "Line A Metro", 1)],
      "p3" => [route_info("LB", "Line B", "Line B Rail", 2)]
    }

    {snapshot(stops, pathways), routes_by_stop}
  end

  defp build_transfer_hub_412_with_routes do
    entrances = Enum.map(1..9, &stop("e#{&1}", 2, %{level_id: "L0", stop_name: "Entrance #{&1}"}))

    platforms =
      Enum.map(1..12, &stop("p#{&1}", 0, %{level_id: "L2", stop_name: "Platform #{&1}"}))

    core_nodes = [
      stop("l0_ev1", 3, %{level_id: "L0"}),
      stop("l0_hub2", 3, %{level_id: "L0"}),
      stop("l0_ev2", 3, %{level_id: "L0"}),
      stop("l0_ev3", 3, %{level_id: "L0"}),
      stop("l0_ev4", 3, %{level_id: "L0"}),
      stop("l1_ev1", 3, %{level_id: "L1"}),
      stop("l1_ev2", 3, %{level_id: "L1"}),
      stop("l1_ev3", 3, %{level_id: "L1"}),
      stop("l1_ev4", 3, %{level_id: "L1"}),
      stop("m1", 3, %{level_id: "L1"}),
      stop("m2", 3, %{level_id: "L1"}),
      stop("m3", 3, %{level_id: "L1"}),
      stop("pc", 3, %{level_id: "L2"})
    ]

    # Leave ev4 missing traversal_time so e7..e9 (36 pairs) classify as :unverified
    elevator_rows = [
      confirmed_elevator("ev1_dn", "l0_ev1", "l1_ev1", %{is_bidirectional: false}),
      confirmed_elevator("ev1_up", "l1_ev1", "l0_ev1", %{is_bidirectional: false}),
      confirmed_elevator("ev2_dn", "l0_ev2", "l1_ev2", %{is_bidirectional: false}),
      confirmed_elevator("ev2_up", "l1_ev2", "l0_ev2", %{is_bidirectional: false}),
      confirmed_elevator("ev3_dn", "l0_ev3", "l1_ev3", %{is_bidirectional: false}),
      confirmed_elevator("ev3_up", "l1_ev3", "l0_ev3", %{is_bidirectional: false}),
      pathway("ev4_dn", 5, "l0_ev4", "l1_ev4", %{
        is_bidirectional: false,
        min_width: Decimal.new("1.20")
      }),
      pathway("ev4_up", 5, "l1_ev4", "l0_ev4", %{
        is_bidirectional: false,
        min_width: Decimal.new("1.20")
      }),
      confirmed_elevator("ev5_dn", "m2", "pc", %{is_bidirectional: false}),
      confirmed_elevator("ev5_up", "pc", "m2", %{is_bidirectional: false})
    ]

    l0_walkways = [
      confirmed_walkway("w_e1", "e1", "l0_ev1"),
      confirmed_walkway("w_e2", "e2", "l0_ev1"),
      confirmed_walkway("w_e3", "e3", "l0_ev1"),
      confirmed_walkway("w_e4", "e4", "l0_hub2"),
      confirmed_walkway("w_e5", "e5", "l0_hub2"),
      confirmed_walkway("w_e6", "e6", "l0_hub2"),
      confirmed_walkway("w_h2_ev2", "l0_hub2", "l0_ev2"),
      confirmed_walkway("w_h2_ev3", "l0_hub2", "l0_ev3"),
      confirmed_walkway("w_e7", "e7", "l0_ev4"),
      confirmed_walkway("w_e8", "e8", "l0_ev4"),
      confirmed_walkway("w_e9", "e9", "l0_ev4")
    ]

    l1_walkways = [
      confirmed_walkway("w_l1_1", "l1_ev1", "m1"),
      confirmed_walkway("w_l1_2", "l1_ev2", "m2"),
      confirmed_walkway("w_l1_3", "l1_ev3", "m2"),
      confirmed_walkway("w_l1_4", "l1_ev4", "m3"),
      confirmed_walkway("w_m1_m2", "m1", "m2"),
      confirmed_walkway("w_m3_m2", "m3", "m2")
    ]

    l2_walkways = Enum.map(1..12, &confirmed_walkway("w_pc_p#{&1}", "pc", "p#{&1}"))

    base_edges = elevator_rows ++ l0_walkways ++ l1_walkways ++ l2_walkways
    extra_count = 412 - length(base_edges)
    concourse_nodes = Enum.map(1..extra_count, &stop("c#{&1}", 3, %{level_id: "L1"}))

    concourse_edges =
      Enum.map(1..extra_count, fn idx ->
        from_id = if(idx == 1, do: "m2", else: "c#{idx - 1}")
        confirmed_walkway("wc_#{idx}", from_id, "c#{idx}")
      end)

    routes_by_stop =
      Map.new(1..12, fn idx ->
        route =
          cond do
            idx <= 4 -> route_info("LINE_A", "Line A", "Line A Subway", 1)
            idx <= 8 -> route_info("LINE_B", "Line B", "Line B Subway", 1)
            true -> route_info("RAIL_1", "Rail", "Regional Rail", 2)
          end

        {"p#{idx}", [route]}
      end)

    snap =
      snapshot(
        entrances ++ platforms ++ core_nodes ++ concourse_nodes,
        base_edges ++ concourse_edges
      )

    {snap, routes_by_stop}
  end
end
