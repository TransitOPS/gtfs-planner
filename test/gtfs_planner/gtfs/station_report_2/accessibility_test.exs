defmodule GtfsPlanner.Gtfs.StationReport2.AccessibilityTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationReport2.Accessibility
  alias GtfsPlanner.Gtfs.Stop

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
      stop_lat: Map.get(attrs, :stop_lat),
      stop_lon: Map.get(attrs, :stop_lon),
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
      min_width: Map.get(attrs, :min_width),
      signposted_as: Map.get(attrs, :signposted_as),
      reversed_signposted_as: Map.get(attrs, :reversed_signposted_as)
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

  defp confirmed_elevator(id, from_id, to_id, attrs) do
    pathway(
      id,
      5,
      from_id,
      to_id,
      Map.merge(%{min_width: Decimal.new("1.20"), traversal_time: 35}, attrs)
    )
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

  # --- Edge classification ---

  describe "edge step-free classification" do
    test "classifies stairs, escalators, barriers, unverified modes, and confirmed edges" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("n_nolevel", 3, %{level_id: nil}),
        stop("m1", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      pathways = [
        pathway("pw_stairs", 2, "e1", "m1"),
        pathway("pw_esc", 4, "e1", "m1"),
        pathway("pw_invalid", 9, "e1", "m1"),
        pathway("pw_steep", 1, "e1", "m1", %{
          max_slope: Decimal.new("0.10"),
          min_width: Decimal.new("1.50"),
          length: Decimal.new("15")
        }),
        pathway("pw_narrow_gate", 6, "e1", "m1", %{min_width: Decimal.new("0.75")}),
        pathway("pw_walk_missing_all", 1, "e1", "m1"),
        pathway("pw_walk_flat_ok", 1, "e1", "e1", %{
          min_width: Decimal.new("1.50"),
          length: Decimal.new("10")
        }),
        pathway("pw_ms_missing_slope", 3, "e1", "m1", %{
          min_width: Decimal.new("1.20"),
          traversal_time: 20
        }),
        pathway("pw_elev_missing", 5, "n_nolevel", "m1"),
        pathway("pw_elev_ok", 5, "m1", "p1", %{
          min_width: Decimal.new("1.20"),
          traversal_time: 30
        }),
        pathway("pw_gate_missing", 6, "m1", "p1"),
        pathway("pw_exit_ok", 7, "p1", "m1", %{
          is_bidirectional: false,
          min_width: Decimal.new("1.00")
        })
      ]

      result = Accessibility.build(snapshot(stops, pathways))
      by_id = Map.new(result.edges, &{&1.pathway_id, &1})

      assert by_id["pw_stairs"].classification == :not_step_free
      assert by_id["pw_esc"].classification == :not_step_free
      assert by_id["pw_invalid"].classification == :not_step_free

      assert by_id["pw_steep"].classification == :barrier
      assert by_id["pw_steep"].barriers == [:slope]

      assert by_id["pw_narrow_gate"].classification == :barrier
      assert by_id["pw_narrow_gate"].barriers == [:width]

      assert by_id["pw_walk_missing_all"].classification == :unverified

      assert by_id["pw_walk_missing_all"].missing_fields == [
               :max_slope,
               :min_width,
               :traversal_time_or_length
             ]

      assert by_id["pw_walk_flat_ok"].classification == :confirmed
      assert by_id["pw_walk_flat_ok"].missing_fields == []

      assert by_id["pw_ms_missing_slope"].classification == :unverified
      assert by_id["pw_ms_missing_slope"].missing_fields == [:max_slope]

      assert by_id["pw_elev_missing"].classification == :unverified

      assert by_id["pw_elev_missing"].missing_fields == [
               :endpoint_level_id,
               :min_width,
               :traversal_time
             ]

      assert by_id["pw_elev_ok"].classification == :confirmed
      assert by_id["pw_gate_missing"].classification == :unverified
      assert by_id["pw_gate_missing"].missing_fields == [:min_width]
      assert by_id["pw_exit_ok"].classification == :confirmed

      # 7 barrier-free step-free edges total: 3 confirmed + 4 unverified
      assert result.edge_completeness == %{complete: 3, total: 7}
    end
  end

  # --- Round-trip pair classification & boarding areas ---

  describe "round-trip pair classification and boarding areas" do
    test "requires confirmed paths in both directions and covers location_type 4 boarding areas" do
      stops = [
        stop("e_ok", 2, %{level_id: "L0"}),
        stop("e_asym", 2, %{level_id: "L0"}),
        stop("e_oneway", 2, %{level_id: "L0"}),
        stop("p1", 0, %{level_id: "L0"}),
        stop("ba1", 4, %{parent_station: "p1", level_id: "L0"})
      ]

      pathways = [
        # e_ok <-> ba1 (boarding area of p1) is confirmed both ways
        confirmed_walkway("pw_ok", "e_ok", "ba1"),
        # e_asym -> p1 confirmed, p1 -> e_asym unverified (missing min_width)
        confirmed_walkway("pw_asym_in", "e_asym", "p1", %{is_bidirectional: false}),
        pathway("pw_asym_out", 1, "p1", "e_asym", %{
          is_bidirectional: false,
          length: Decimal.new("15")
        }),
        # e_oneway -> p1 only, no return
        confirmed_walkway("pw_oneway", "e_oneway", "p1", %{is_bidirectional: false})
      ]

      result = Accessibility.build(snapshot(stops, pathways))
      by_ent = Map.new(result.pairs, &{&1.entrance_stop_id, &1})

      assert by_ent["e_ok"].status == :confirmed
      assert by_ent["e_ok"].to_platform_status == :confirmed
      assert by_ent["e_ok"].to_exit_status == :confirmed

      assert by_ent["e_asym"].status == :unverified
      assert by_ent["e_asym"].to_platform_status == :confirmed
      assert by_ent["e_asym"].to_exit_status == :unverified

      assert by_ent["e_oneway"].status == :no_route
      assert by_ent["e_oneway"].one_way_only? == true
      assert by_ent["e_oneway"].to_platform_status == :confirmed
      assert by_ent["e_oneway"].to_exit_status == :no_route

      assert result.confidence_counts == %{confirmed: 1, unverified: 1, no_route: 1}
      assert Enum.map(result.step_free_entrances, & &1.stop_id) == ["e_asym", "e_ok"]
      assert Enum.map(result.inaccessible_entrances, & &1.stop_id) == ["e_oneway"]
    end

    test "selects unverified displayed route by fewest unverified edges, then hops, then sorted pathway IDs" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("a1", 3, %{level_id: "L0"}),
        stop("b1", 3, %{level_id: "L0"}),
        stop("b2", 3, %{level_id: "L0"}),
        stop("c1", 3, %{level_id: "L0"}),
        stop("d1", 3, %{level_id: "L0"}),
        stop("p1", 0, %{level_id: "L0"}),
        stop("p2", 0, %{level_id: "L0"})
      ]

      pathways = [
        # To p1: short 2-hop path has 2 unverified edges; 3-hop path has only 1 unverified edge
        pathway("pw_u1", 1, "e1", "a1", %{length: Decimal.new("10")}),
        pathway("pw_u2", 1, "a1", "p1", %{length: Decimal.new("10")}),
        confirmed_walkway("pw_c1", "e1", "b1"),
        pathway("pw_u3", 1, "b1", "b2", %{length: Decimal.new("10")}),
        confirmed_walkway("pw_c2", "b2", "p1"),

        # To p2: two 2-hop paths with 1 unverified edge each; tie broken by sorted pathway IDs
        # Path C: ["pw_z", "pw_a"] -> sorted ["pw_a", "pw_z"]
        # Path D: ["pw_m", "pw_n"] -> sorted ["pw_m", "pw_n"]
        # Path C wins because ["pw_a", "pw_z"] < ["pw_m", "pw_n"]
        pathway("pw_z", 1, "e1", "c1", %{length: Decimal.new("10")}),
        confirmed_walkway("pw_a", "c1", "p2"),
        pathway("pw_m", 1, "e1", "d1", %{length: Decimal.new("10")}),
        confirmed_walkway("pw_n", "d1", "p2")
      ]

      result = Accessibility.build(snapshot(stops, pathways))
      by_plat = Map.new(result.pairs, &{&1.platform_stop_id, &1})

      assert by_plat["p1"].status == :unverified
      assert by_plat["p1"].to_platform_pathway_ids == ["pw_c1", "pw_u3", "pw_c2"]
      assert by_plat["p1"].to_exit_pathway_ids == ["pw_c2", "pw_u3", "pw_c1"]

      assert by_plat["p2"].status == :unverified
      assert by_plat["p2"].to_platform_pathway_ids == ["pw_z", "pw_a"]
      assert by_plat["p2"].to_exit_pathway_ids == ["pw_a", "pw_z"]
    end
  end

  # --- Whole-elevator connected components (CR-M1) ---

  describe "whole-elevator connected components (CR-M1)" do
    test "merges a two-row one-way elevator into one component and counts dependent pairs once" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("e2", 2, %{level_id: "L0"}),
        stop("l0_el", 3, %{level_id: "L0"}),
        stop("l2_el", 3, %{level_id: "L2"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      pathways = [
        confirmed_walkway("w1", "e1", "l0_el"),
        confirmed_walkway("w2", "e2", "l0_el"),
        confirmed_elevator("el_down", "l0_el", "l2_el", %{is_bidirectional: false}),
        confirmed_elevator("el_up", "l2_el", "l0_el", %{is_bidirectional: false}),
        confirmed_walkway("w3", "l2_el", "p1")
      ]

      result = Accessibility.build(snapshot(stops, pathways))

      assert [elevator] = result.elevators
      assert elevator.id == "el_down"
      assert elevator.label == "el_down / el_up"
      assert elevator.pathway_ids == ["el_down", "el_up"]
      assert elevator.sole_link_pairs == 2
      assert elevator.connects == "Street \u2194 Platform"

      assert [single_elev_issue] = Enum.filter(result.issues, &(&1.kind == :single_elevator))
      assert single_elev_issue.affected_pairs == 2
      assert single_elev_issue.pathway_ids == ["el_down", "el_up"]
      refute Map.has_key?(single_elev_issue, :outage_feed)
      refute Map.has_key?(single_elev_issue, :last_verified)
    end

    test "removes all 6 rows of a 3-landing pairwise elevator together to detect sole-link dependency" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("l0", 3, %{level_id: "L0"}),
        stop("l1", 3, %{level_id: "L1"}),
        stop("l2", 3, %{level_id: "L2"}),
        stop("p1", 0, %{level_id: "L2"})
      ]

      # 6 one-way pairwise elevator rows forming a K3 triangle between l0, l1, l2
      pathways = [
        confirmed_walkway("w_in", "e1", "l0"),
        confirmed_elevator("el_01", "l0", "l1", %{is_bidirectional: false}),
        confirmed_elevator("el_10", "l1", "l0", %{is_bidirectional: false}),
        confirmed_elevator("el_12", "l1", "l2", %{is_bidirectional: false}),
        confirmed_elevator("el_21", "l2", "l1", %{is_bidirectional: false}),
        confirmed_elevator("el_02", "l0", "l2", %{is_bidirectional: false}),
        confirmed_elevator("el_20", "l2", "l0", %{is_bidirectional: false}),
        confirmed_walkway("w_out", "l2", "p1")
      ]

      result = Accessibility.build(snapshot(stops, pathways))

      assert [elevator] = result.elevators
      assert elevator.id == "el_01"
      assert elevator.pathway_ids == ["el_01", "el_02", "el_10", "el_12", "el_20", "el_21"]
      assert elevator.sole_link_pairs == 1
      assert elevator.connects == "Street \u2194 Mezzanine \u2194 Platform"
    end
  end

  # --- Measured barriers (CR-D1) ---

  describe "measured barrier issues (CR-D1)" do
    test "excludes barrier edges from step-free reachability and counts blocked type-only pairs" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("e2", 2, %{level_id: "L0"}),
        stop("m1", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L1"})
      ]

      pathways = [
        # e1 -> m1 uses a steep ramp (barrier) as its only route
        pathway("pw_steep_ramp", 1, "e1", "m1", %{
          max_slope: Decimal.new("0.11"),
          min_width: Decimal.new("1.20"),
          length: Decimal.new("12")
        }),
        # e2 -> m1 has both a narrow gate (barrier) AND a confirmed wide gate
        pathway("pw_narrow_bypassed", 6, "e2", "m1", %{min_width: Decimal.new("0.70")}),
        pathway("pw_wide_gate", 6, "e2", "m1", %{min_width: Decimal.new("1.10")}),
        confirmed_walkway("pw_m_p", "m1", "p1")
      ]

      result = Accessibility.build(snapshot(stops, pathways))
      by_ent = Map.new(result.pairs, &{&1.entrance_stop_id, &1})

      assert by_ent["e1"].status == :no_route
      assert by_ent["e2"].status == :confirmed

      barrier_issues =
        result.issues
        |> Enum.filter(&(&1.kind == :barrier))
        |> Map.new(&{&1.primary_pathway_id, &1})

      steep_issue = barrier_issues["pw_steep_ramp"]
      assert steep_issue.affected_pairs == 1
      assert steep_issue.barriers == [:slope]
      assert steep_issue.description =~ "0.11"
      assert steep_issue.description =~ "0.0834"

      bypassed_issue = barrier_issues["pw_narrow_bypassed"]
      assert bypassed_issue.affected_pairs == 0
      assert bypassed_issue.barriers == [:width]
      assert bypassed_issue.description =~ "0.70"
      assert bypassed_issue.description =~ "0.81"
    end

    test "does not credit a bypassed barrier shortcut on the unblocked direction of an asymmetric pair" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("n1", 3, %{level_id: "L0"}),
        stop("p1", 0, %{level_id: "L0"})
      ]

      pathways = [
        # Outbound e1 -> p1 has a 2-hop barrier-free path AND a shorter 1-hop barrier shortcut
        confirmed_walkway("w_out_1", "e1", "n1", %{is_bidirectional: false}),
        confirmed_walkway("w_out_2", "n1", "p1", %{is_bidirectional: false}),
        pathway("pw_shortcut_barrier", 1, "e1", "p1", %{
          is_bidirectional: false,
          min_width: Decimal.new("0.70"),
          length: Decimal.new("5")
        }),
        # Return p1 -> e1 is ONLY via a barrier pathway
        pathway("pw_return_barrier", 1, "p1", "e1", %{
          is_bidirectional: false,
          min_width: Decimal.new("0.70"),
          length: Decimal.new("5")
        })
      ]

      result = Accessibility.build(snapshot(stops, pathways))

      barrier_issues =
        result.issues
        |> Enum.filter(&(&1.kind == :barrier))
        |> Map.new(&{&1.primary_pathway_id, &1})

      assert barrier_issues["pw_return_barrier"].affected_pairs == 1
      assert barrier_issues["pw_shortcut_barrier"].affected_pairs == 0
    end
  end

  # --- Import-shaped missing-width grouping (CR-D2) ---

  describe "import-shaped missing-width grouping (CR-D2)" do
    test "groups :unknown_data issues by {missing_fields, pathway_mode, level_or_level_pair}" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("n1", 3, %{level_id: "L0"}),
        stop("n2", 3, %{level_id: "L0"}),
        stop("n3", 3, %{level_id: "L0"}),
        stop("p1", 0, %{level_id: "L0", wheelchair_boarding: 1}),
        stop("p2", 0, %{level_id: "L0", wheelchair_boarding: 1})
      ]

      # One-way rows across the same level with length present but no min_width anywhere
      pathways = [
        pathway("w1_f", 1, "e1", "n1", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("w1_r", 1, "n1", "e1", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("w2_f", 1, "n1", "n2", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("w2_r", 1, "n2", "n1", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("w3_f", 1, "n2", "p1", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("w3_r", 1, "p1", "n2", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("w4_f", 1, "n2", "n3", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("w4_r", 1, "n3", "n2", %{is_bidirectional: false, length: Decimal.new("10")}),
        pathway("g1", 6, "n3", "p2", %{is_bidirectional: true})
      ]

      result = Accessibility.build(snapshot(stops, pathways))

      assert result.confidence_counts == %{confirmed: 0, unverified: 2, no_route: 0}

      unknown_issues = Enum.filter(result.issues, &(&1.kind == :unknown_data))
      # 8 walkway edges on L0 collapse into 1 grouped issue; 1 fare gate on L0 stays a single card
      assert length(unknown_issues) == 2

      walkway_group = Enum.find(unknown_issues, &(&1.pathway_mode == 1))
      assert walkway_group.grouped? == true
      assert walkway_group.edge_count == 8
      assert walkway_group.missing_fields == [:min_width]
      assert walkway_group.affected_pairs == 2

      gate_single = Enum.find(unknown_issues, &(&1.pathway_mode == 6))
      assert gate_single.grouped? == false
      assert gate_single.edge_count == 1
      assert gate_single.missing_fields == [:min_width]
      assert gate_single.affected_pairs == 1

      # Both accessible platforms have only unverified routes -> :flag_mismatch with :unconfirmed_only
      flag_issues = Enum.filter(result.issues, &(&1.kind == :flag_mismatch))
      assert length(flag_issues) == 2
      assert Enum.all?(flag_issues, &(&1.cause == :unconfirmed_only))
    end
  end

  # --- Station-wide flag_mismatch (CR-D3) ---

  describe "station-wide flag_mismatch (CR-D3)" do
    test "does not flag an accessible platform reachable via a confirmed round trip from at least one entrance" do
      station = stop("stn_1", 1, %{parent_station: nil, wheelchair_boarding: 1})

      stops = [
        stop("e_step_free", 2, %{level_id: "L0"}),
        stop("e_stairs_only", 2, %{level_id: "L0"}),
        stop("p_partial", 0, %{level_id: "L0", wheelchair_boarding: 1}),
        stop("p_no_route", 0, %{level_id: "L0", wheelchair_boarding: 0}),
        stop("p_unverified", 0, %{level_id: "L0", wheelchair_boarding: 1}),
        stop("p_marked_no", 0, %{level_id: "L0", wheelchair_boarding: 2})
      ]

      pathways = [
        confirmed_walkway("w_partial", "e_step_free", "p_partial"),
        pathway("stairs_partial", 2, "e_stairs_only", "p_partial"),
        pathway("stairs_only_p", 2, "e_step_free", "p_no_route"),
        pathway("w_unv", 1, "e_step_free", "p_unverified", %{length: Decimal.new("12")}),
        pathway("stairs_marked_no", 2, "e_step_free", "p_marked_no")
      ]

      result = Accessibility.build(snapshot(stops, pathways, station: station))

      flag_by_stop =
        result.issues
        |> Enum.filter(&(&1.kind == :flag_mismatch))
        |> Map.new(&{&1.stop_id, &1})

      # Partial-entrance platform has confirmed round trip from e_step_free -> NO mismatch
      refute Map.has_key?(flag_by_stop, "p_partial")
      # Platform explicitly wheelchair_boarding=2 -> NO mismatch
      refute Map.has_key?(flag_by_stop, "p_marked_no")

      # p_no_route inherits accessible from station and has no step-free route
      assert flag_by_stop["p_no_route"].cause == :no_step_free_route
      assert flag_by_stop["p_no_route"].wheelchair_source == :inherited
      assert flag_by_stop["p_no_route"].target_type == :stop

      # p_unverified has direct accessible flag and only unverified routes
      assert flag_by_stop["p_unverified"].cause == :unconfirmed_only
      assert flag_by_stop["p_unverified"].wheelchair_source == :direct
    end
  end

  # --- Near-threshold issues (D-1) ---

  describe "near_threshold issues (D-1)" do
    test "emits slope and width near-threshold issues citing 0.915 m continuous width" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("m1", 3, %{level_id: "L1"}),
        stop("p1", 0, %{level_id: "L1"})
      ]

      pathways = [
        confirmed_walkway("pw_ramp", "e1", "m1", %{max_slope: Decimal.new("-0.081")}),
        pathway("pw_tight_gate", 6, "m1", "p1", %{min_width: Decimal.new("0.92")})
      ]

      result = Accessibility.build(snapshot(stops, pathways))

      near_by_id =
        result.issues
        |> Enum.filter(&(&1.kind == :near_threshold))
        |> Map.new(&{&1.primary_pathway_id, &1})

      assert near_by_id["pw_ramp"].affected_pairs == 1
      assert near_by_id["pw_ramp"].near_threshold_fields == [:slope]
      assert near_by_id["pw_ramp"].description =~ "0.0834"

      assert near_by_id["pw_tight_gate"].affected_pairs == 1
      assert near_by_id["pw_tight_gate"].near_threshold_fields == [:width]
      assert near_by_id["pw_tight_gate"].description =~ "0.915 m"
      refute near_by_id["pw_tight_gate"].description =~ "0.81 m"
    end
  end

  # --- Cross-station incomplete notice (CR-C3) ---

  describe "cross-station incomplete notice (CR-C3)" do
    test "marks model :incomplete with sorted cross-station pathway IDs" do
      stops = [
        stop("e1", 2, %{level_id: "L0"}),
        stop("p1", 0, %{level_id: "L0"})
      ]

      pathways = [
        confirmed_walkway("w_local", "e1", "p1"),
        confirmed_walkway("w_ext_b", "p1", "other_station_stop_2"),
        confirmed_walkway("w_ext_a", "other_station_stop_1", "e1")
      ]

      result = Accessibility.build(snapshot(stops, pathways))

      assert result.completeness == :incomplete
      assert result.incomplete_reasons == [{:cross_station_pathways, ["w_ext_a", "w_ext_b"]}]
    end
  end

  # --- View-state precedence and network eligibility (CR-S4) ---

  describe "derive_view_state/1 and network_available?" do
    test "enforces strict precedence :loading > :error > :empty_topology > :no_step_free_access > :ready" do
      ready_model = %{
        entrances: [%{stop_id: "e1"}],
        platforms: [%{stop_id: "p1"}],
        edges: [%{pathway_id: "w1"}],
        step_free_entrances: [%{stop_id: "e1"}]
      }

      assert Accessibility.derive_view_state(%{
               view_state: :initial_loading,
               report_error: :timeout,
               model: nil
             }) == :loading

      assert Accessibility.derive_view_state(%{
               view_state: :error,
               report_error: :timeout,
               model: nil
             }) == :error

      assert Accessibility.derive_view_state(%{
               view_state: :ready,
               report_error: nil,
               model: %{ready_model | entrances: [], step_free_entrances: []}
             }) == :empty_topology

      assert Accessibility.derive_view_state(%{
               view_state: :ready,
               report_error: nil,
               model: %{ready_model | platforms: [], step_free_entrances: []}
             }) == :empty_topology

      assert Accessibility.derive_view_state(%{
               view_state: :ready,
               report_error: nil,
               model: %{ready_model | edges: [], step_free_entrances: []}
             }) == :empty_topology

      assert Accessibility.derive_view_state(%{
               view_state: :ready,
               report_error: nil,
               model: %{ready_model | step_free_entrances: []}
             }) == :no_step_free_access

      assert Accessibility.derive_view_state(%{
               view_state: :refreshing,
               report_error: nil,
               model: ready_model
             }) == :ready

      assert Accessibility.derive_view_state(%{
               view_state: :ready,
               report_error: nil,
               model: ready_model
             }) == :ready
    end

    test "network_available? boundary checks <= 40 step-free edges, <= 6 step-free entrances, <= 6 platforms" do
      # Exactly at the boundary: 6 entrances, 6 platforms, 40 step-free edges -> true
      boundary_snap = build_grid_snapshot(6, 6, 40)
      boundary_model = Accessibility.build(boundary_snap)
      assert boundary_model.network_available? == true
      assert boundary_model.default_view == :network

      # 41 step-free edges -> false
      over_edges = Accessibility.build(build_grid_snapshot(6, 6, 41))
      assert over_edges.network_available? == false
      assert over_edges.default_view == :impact

      # 7 step-free entrances -> false
      over_entrances = Accessibility.build(build_grid_snapshot(7, 2, 10))
      assert over_entrances.network_available? == false
      assert over_entrances.default_view == :impact

      # 7 platforms -> false
      over_platforms = Accessibility.build(build_grid_snapshot(2, 7, 10))
      assert over_platforms.network_available? == false
      assert over_platforms.default_view == :impact
    end
  end

  # --- On-demand route pricing (build_route/4) ---

  describe "build_route/4 on-demand pricing" do
    test "prices outbound and return step-free routes and returns :no_route when blocked" do
      stops = [
        stop("e1", 2, %{level_id: "L0", stop_name: "North Entrance"}),
        stop("l0_el", 3, %{level_id: "L0"}),
        stop("l2_el", 3, %{level_id: "L2"}),
        stop("p1", 0, %{level_id: "L2", stop_name: "Track 1"}),
        stop("e_blocked", 2, %{level_id: "L0"})
      ]

      pathways = [
        confirmed_walkway("w1", "e1", "l0_el", %{
          length: Decimal.new("25"),
          traversal_time: 20,
          signposted_as: "To Elevators",
          reversed_signposted_as: "To North Entrance"
        }),
        confirmed_elevator("el1_dn", "l0_el", "l2_el", %{
          is_bidirectional: false,
          traversal_time: 35
        }),
        confirmed_elevator("el1_up", "l2_el", "l0_el", %{
          is_bidirectional: false,
          traversal_time: 35
        }),
        confirmed_walkway("w2", "l2_el", "p1", %{
          length: Decimal.new("15"),
          traversal_time: 12
        }),
        pathway("stairs_only", 2, "e_blocked", "p1")
      ]

      snap = snapshot(stops, pathways)

      route = Accessibility.build_route(snap, "e1", "p1")
      assert route.status == :confirmed
      assert route.entrance_stop_id == "e1"
      assert route.platform_stop_id == "p1"
      assert route.elevator_ids == ["el1_dn"]
      assert length(route.steps) == 3
      assert route.distance_meters == 40.0

      # OTP-faithful PathwayTraversal timing: w1 (20s) + elevator (35s + 90s board/wait) + w2 (12s)
      assert route.duration_seconds == 157.0
      assert Enum.map(route.steps, & &1.pathway_id) == ["w1", "el1_dn", "w2"]
      assert Enum.at(route.steps, 0).signposted_as == "To Elevators"
      assert Enum.at(route.steps, 1).distance_meters == nil

      return_route = Accessibility.build_route(snap, "e1", "p1", direction: :to_exit)
      assert return_route.status == :confirmed
      assert return_route.direction == :to_exit
      assert return_route.elevator_ids == ["el1_dn"]
      assert Enum.map(return_route.steps, & &1.pathway_id) == ["w2", "el1_up", "w1"]
      assert Enum.at(return_route.steps, 2).signposted_as == "To North Entrance"

      assert Accessibility.build_route(snap, "e_blocked", "p1") == :no_route
      assert Accessibility.build_route(snap, "unknown", "p1") == :no_route
    end
  end

  # --- Synthetic 412-edge transfer hub (CR-S4, CR-C2) ---

  describe "412-edge transfer-center hub" do
    test "computes exact counts and sole-link elevator dependencies on 412 edges, 9 entrances, 12 platforms, 5 elevators" do
      snap = build_transfer_hub_412_snapshot()

      assert length(snap.pathways) == 412

      model = Accessibility.build(snap)

      assert model.network_available? == false
      assert model.default_view == :impact
      assert model.completeness == :complete
      assert length(model.entrances) == 9
      assert length(model.step_free_entrances) == 9
      assert length(model.platforms) == 12
      assert length(model.edges) == 412
      assert model.confidence_counts == %{confirmed: 108, unverified: 0, no_route: 0}
      assert length(model.elevators) == 5

      sole_by_id = Map.new(model.elevators, &{&1.id, &1.sole_link_pairs})
      assert sole_by_id["ev1_dn"] == 36
      assert sole_by_id["ev2_dn"] == 0
      assert sole_by_id["ev3_dn"] == 0
      assert sole_by_id["ev4_dn"] == 36
      assert sole_by_id["ev5_dn"] == 108

      # Top issue is Elevator 5 with 108 affected pairs
      assert [top_issue | _] = model.issues
      assert top_issue.kind == :single_elevator
      assert top_issue.elevator_id == "ev5_dn"
      assert top_issue.affected_pairs == 108

      # On-demand pricing for one selected pair succeeds cleanly
      route = Accessibility.build_route(snap, "e1", "p1")
      assert route.status == :confirmed
      assert route.elevator_ids == ["ev1_dn", "ev5_dn"]
      assert route.duration_seconds > 0.0
    end
  end

  # --- Synthetic topology builders ---

  defp build_grid_snapshot(entrance_count, platform_count, target_edge_count) do
    entrances = Enum.map(1..entrance_count, &stop("e#{&1}", 2, %{level_id: "L0"}))
    platforms = Enum.map(1..platform_count, &stop("p#{&1}", 0, %{level_id: "L0"}))
    hub = stop("hub", 3, %{level_id: "L0"})

    base_pathways =
      Enum.map(1..entrance_count, &confirmed_walkway("we_#{&1}", "e#{&1}", "hub")) ++
        Enum.map(1..platform_count, &confirmed_walkway("wp_#{&1}", "hub", "p#{&1}"))

    extra_needed = max(target_edge_count - length(base_pathways), 0)

    {extra_stops, extra_pathways} =
      if extra_needed == 0 do
        {[], []}
      else
        nodes = Enum.map(1..extra_needed, &stop("x#{&1}", 3, %{level_id: "L0"}))

        pws =
          Enum.map(1..extra_needed, fn idx ->
            prev = if(idx == 1, do: "hub", else: "x#{idx - 1}")
            confirmed_walkway("wx_#{idx}", prev, "x#{idx}")
          end)

        {nodes, pws}
      end

    snapshot([hub | entrances ++ platforms ++ extra_stops], base_pathways ++ extra_pathways)
  end

  defp build_transfer_hub_412_snapshot do
    entrances = Enum.map(1..9, &stop("e#{&1}", 2, %{level_id: "L0"}))
    platforms = Enum.map(1..12, &stop("p#{&1}", 0, %{level_id: "L2"}))

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

    elevator_rows = [
      confirmed_elevator("ev1_dn", "l0_ev1", "l1_ev1", %{is_bidirectional: false}),
      confirmed_elevator("ev1_up", "l1_ev1", "l0_ev1", %{is_bidirectional: false}),
      confirmed_elevator("ev2_dn", "l0_ev2", "l1_ev2", %{is_bidirectional: false}),
      confirmed_elevator("ev2_up", "l1_ev2", "l0_ev2", %{is_bidirectional: false}),
      confirmed_elevator("ev3_dn", "l0_ev3", "l1_ev3", %{is_bidirectional: false}),
      confirmed_elevator("ev3_up", "l1_ev3", "l0_ev3", %{is_bidirectional: false}),
      confirmed_elevator("ev4_dn", "l0_ev4", "l1_ev4", %{is_bidirectional: false}),
      confirmed_elevator("ev4_up", "l1_ev4", "l0_ev4", %{is_bidirectional: false}),
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
    # 10 + 11 + 6 + 12 = 39 base edges; add 373 mezzanine corridor edges -> 412 total
    extra_count = 412 - length(base_edges)
    concourse_nodes = Enum.map(1..extra_count, &stop("c#{&1}", 3, %{level_id: "L1"}))

    concourse_edges =
      Enum.map(1..extra_count, fn idx ->
        from_id = if(idx == 1, do: "m2", else: "c#{idx - 1}")
        confirmed_walkway("wc_#{idx}", from_id, "c#{idx}")
      end)

    snapshot(
      entrances ++ platforms ++ core_nodes ++ concourse_nodes,
      base_edges ++ concourse_edges
    )
  end
end
