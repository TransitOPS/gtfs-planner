defmodule GtfsPlanner.Gtfs.StationReport2.ConnectivityTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport2.Connectivity

  defp make_stop(attrs) do
    Map.merge(
      %{
        stop_name: "Stop",
        wheelchair_boarding: nil,
        level_id: nil,
        stop_lat: nil,
        stop_lon: nil,
        parent_station: "STATION_1"
      },
      attrs
    )
  end

  defp make_level(attrs) do
    level = Map.merge(%{level_id: "L1", level_name: "Street", level_index: 0.0}, attrs)
    %{level: level, stop_count: 0}
  end

  defp make_pathway(attrs) do
    Map.merge(
      %{
        pathway_id: "PW_1",
        pathway_mode: 1,
        is_bidirectional: true,
        traversal_time: 30,
        length: nil,
        stair_count: nil,
        max_slope: nil,
        min_width: nil,
        signposted_as: nil,
        reversed_signposted_as: nil
      },
      attrs
    )
  end

  defp connected_snapshot do
    %{
      child_stops: [
        make_stop(%{stop_id: "ENT_1", stop_name: "Entrance A", location_type: 2}),
        make_stop(%{stop_id: "ENT_2", stop_name: "Entrance B", location_type: 2}),
        make_stop(%{stop_id: "PLAT_1", stop_name: "Platform 1", location_type: 0}),
        make_stop(%{stop_id: "PLAT_2", stop_name: "Platform 2", location_type: 0}),
        make_stop(%{stop_id: "NODE_1", stop_name: "Node 1", location_type: 3})
      ],
      pathways: [
        make_pathway(%{pathway_id: "PW_1", from_stop_id: "ENT_1", to_stop_id: "NODE_1"}),
        make_pathway(%{pathway_id: "PW_2", from_stop_id: "NODE_1", to_stop_id: "PLAT_1"}),
        make_pathway(%{pathway_id: "PW_3", from_stop_id: "NODE_1", to_stop_id: "PLAT_2"}),
        make_pathway(%{pathway_id: "PW_4", from_stop_id: "ENT_2", to_stop_id: "NODE_1"})
      ],
      levels: [make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0})]
    }
  end

  describe "build_summaries/1" do
    test "fully connected station returns :passed for all dimensions" do
      summaries = Connectivity.build_summaries(connected_snapshot())

      assert summaries.entrance_to_platform.status == :passed
      assert summaries.platform_to_exit.status == :passed
      assert summaries.platform_to_platform.status == :passed

      assert summaries.entrance_to_platform.alerts == []
    end

    test "partially connected entrance returns :warning" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance A", location_type: 2}),
          make_stop(%{stop_id: "ENT_2", stop_name: "Entrance B", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform 1", location_type: 0}),
          make_stop(%{stop_id: "PLAT_2", stop_name: "Platform 2", location_type: 0})
        ],
        pathways: [
          # ENT_1 reaches both platforms (unidirectional — no reverse path)
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            is_bidirectional: false
          }),
          make_pathway(%{
            pathway_id: "PW_2",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_2",
            is_bidirectional: false
          }),
          # ENT_2 can only reach PLAT_1 (unidirectional)
          make_pathway(%{
            pathway_id: "PW_3",
            from_stop_id: "ENT_2",
            to_stop_id: "PLAT_1",
            is_bidirectional: false
          })
        ],
        levels: []
      }

      summaries = Connectivity.build_summaries(snapshot)

      ent2_row =
        Enum.find(summaries.entrance_to_platform.summary_rows, &(&1.source_stop_id == "ENT_2"))

      assert ent2_row.status == :partial
      assert summaries.entrance_to_platform.status == :warning
    end

    test "disconnected entrance returns :none status with alert" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Connected Entrance", location_type: 2}),
          make_stop(%{stop_id: "ENT_2", stop_name: "Disconnected Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform 1", location_type: 0})
        ],
        pathways: [
          make_pathway(%{pathway_id: "PW_1", from_stop_id: "ENT_1", to_stop_id: "PLAT_1"})
        ],
        levels: []
      }

      summaries = Connectivity.build_summaries(snapshot)

      ent2_row =
        Enum.find(summaries.entrance_to_platform.summary_rows, &(&1.source_stop_id == "ENT_2"))

      assert ent2_row.status == :none
      assert summaries.entrance_to_platform.status == :fail
      assert length(summaries.entrance_to_platform.alerts) == 1
      assert hd(summaries.entrance_to_platform.alerts) =~ "Disconnected Entrance"
    end

    test "no entrances returns empty summary rows" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform 1", location_type: 0})
        ],
        pathways: [],
        levels: []
      }

      summaries = Connectivity.build_summaries(snapshot)
      assert summaries.entrance_to_platform.summary_rows == []
    end

    test "no pathways returns zero connected pairs" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0})
        ],
        pathways: [],
        levels: []
      }

      summaries = Connectivity.build_summaries(snapshot)
      assert summaries.entrance_to_platform.stats.connected_pairs == 0
    end

    test "platform with boarding areas reachable via boarding area" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0}),
          make_stop(%{
            stop_id: "BA_1",
            stop_name: "Boarding Area",
            location_type: 4,
            parent_station: "PLAT_1"
          })
        ],
        pathways: [
          make_pathway(%{pathway_id: "PW_1", from_stop_id: "ENT_1", to_stop_id: "BA_1"})
        ],
        levels: []
      }

      summaries = Connectivity.build_summaries(snapshot)
      ent_row = hd(summaries.entrance_to_platform.summary_rows)
      assert ent_row.status == :full
    end

    test "platform-to-platform partial connectivity" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform A", location_type: 0}),
          make_stop(%{stop_id: "PLAT_2", stop_name: "Platform B", location_type: 0}),
          make_stop(%{stop_id: "PLAT_3", stop_name: "Platform C", location_type: 0})
        ],
        pathways: [
          make_pathway(%{pathway_id: "PW_1", from_stop_id: "PLAT_1", to_stop_id: "PLAT_2"})
          # PLAT_3 disconnected
        ],
        levels: []
      }

      summaries = Connectivity.build_summaries(snapshot)

      plat3_row =
        Enum.find(summaries.platform_to_platform.summary_rows, &(&1.source_stop_id == "PLAT_3"))

      assert plat3_row.status == :none
    end
  end

  describe "build_route_detail/2" do
    test "returns enriched route groups with correct metrics" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{stop_id: "NODE_1", stop_name: "Node", location_type: 3, level_id: "L1"}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L1"})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "NODE_1",
            traversal_time: 15
          }),
          make_pathway(%{
            pathway_id: "PW_2",
            from_stop_id: "NODE_1",
            to_stop_id: "PLAT_1",
            traversal_time: 20
          })
        ],
        levels: [make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0})]
      }

      groups = Connectivity.build_route_detail(snapshot, :entrance_to_platform)

      assert length(groups) == 1
      group = hd(groups)
      assert group.source.name == "Entrance"
      assert length(group.targets) == 1

      target = hd(group.targets)
      assert target.name == "Platform"
      assert target.status == :reachable
      assert is_number(target.time)
      assert is_number(target.distance)
    end

    test "no path pair returns :nopath status" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0})
        ],
        pathways: [],
        levels: []
      }

      groups = Connectivity.build_route_detail(snapshot, :entrance_to_platform)
      target = hd(hd(groups).targets)
      assert target.status == :nopath
      assert target.time == nil
    end

    test "long route returns :long status" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            traversal_time: 400
          })
        ],
        levels: []
      }

      groups = Connectivity.build_route_detail(snapshot, :entrance_to_platform)
      target = hd(hd(groups).targets)
      assert target.status == :long
    end

    test "step-free path sets accessible to true" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L2"})
        ],
        pathways: [
          # Elevator (step-free)
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            pathway_mode: 5,
            traversal_time: 45
          })
        ],
        levels: [
          make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0}),
          make_level(%{level_id: "L2", level_name: "Platform", level_index: -1.0})
        ]
      }

      groups = Connectivity.build_route_detail(snapshot, :entrance_to_platform)
      target = hd(hd(groups).targets)
      assert target.accessible == true
      assert target.accessible_note == "elevator route available"
    end

    test "accessible_note derived from step-free path when general path uses stairs" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{
            stop_id: "NODE_S",
            stop_name: "Stairs Node",
            location_type: 3,
            level_id: "L2"
          }),
          make_stop(%{
            stop_id: "NODE_E",
            stop_name: "Elevator Node",
            location_type: 3,
            level_id: "L2"
          }),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L2"})
        ],
        pathways: [
          # Stairs route: ENT_1 -> NODE_S -> PLAT_1 (shorter, general shortest path)
          make_pathway(%{
            pathway_id: "PW_S1",
            from_stop_id: "ENT_1",
            to_stop_id: "NODE_S",
            pathway_mode: 2,
            traversal_time: 10
          }),
          make_pathway(%{
            pathway_id: "PW_S2",
            from_stop_id: "NODE_S",
            to_stop_id: "PLAT_1",
            pathway_mode: 1,
            traversal_time: 10
          }),
          # Elevator route: ENT_1 -> NODE_E -> PLAT_1 (longer, but step-free)
          make_pathway(%{
            pathway_id: "PW_E1",
            from_stop_id: "ENT_1",
            to_stop_id: "NODE_E",
            pathway_mode: 5,
            traversal_time: 30
          }),
          make_pathway(%{
            pathway_id: "PW_E2",
            from_stop_id: "NODE_E",
            to_stop_id: "PLAT_1",
            pathway_mode: 1,
            traversal_time: 30
          })
        ],
        levels: [
          make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0}),
          make_level(%{level_id: "L2", level_name: "Platform", level_index: -1.0})
        ]
      }

      groups = Connectivity.build_route_detail(snapshot, :entrance_to_platform)
      target = hd(hd(groups).targets)
      # General shortest path uses stairs, but step-free elevator route exists
      assert target.accessible == true
      assert target.accessible_note == "elevator route available"
    end

    test "accessible_note is stairs only when no step-free path exists" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L2"})
        ],
        pathways: [
          # Only stairs (not step-free)
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            pathway_mode: 2,
            traversal_time: 20
          })
        ],
        levels: [
          make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0}),
          make_level(%{level_id: "L2", level_name: "Platform", level_index: -1.0})
        ]
      }

      groups = Connectivity.build_route_detail(snapshot, :entrance_to_platform)
      target = hd(hd(groups).targets)
      assert target.accessible == false
      assert target.accessible_note == "stairs only"
    end

    test "accessible_note is same-level walkway when step-free path has no level changes" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L1"})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            pathway_mode: 1,
            traversal_time: 15
          })
        ],
        levels: [
          make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0})
        ]
      }

      groups = Connectivity.build_route_detail(snapshot, :entrance_to_platform)
      target = hd(hd(groups).targets)
      assert target.accessible == true
      assert target.accessible_note == "same-level walkway"
    end
  end

  describe "build_expanded_route/3" do
    test "returns steps with correct structure" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{stop_id: "NODE_1", stop_name: "Node", location_type: 3, level_id: "L1"}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L1"})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "NODE_1",
            traversal_time: 15
          }),
          make_pathway(%{
            pathway_id: "PW_2",
            from_stop_id: "NODE_1",
            to_stop_id: "PLAT_1",
            traversal_time: 20
          })
        ],
        levels: [make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0})]
      }

      result = Connectivity.build_expanded_route(snapshot, "ENT_1", "PLAT_1")

      assert is_map(result)
      assert result.source.stop_id == "ENT_1"
      assert result.target.stop_id == "PLAT_1"
      assert length(result.steps) == 3
      assert result.status == :reachable

      step1 = hd(result.steps)
      assert step1.num == 1
      assert step1.stop_id == "ENT_1"
    end

    test "elevator step over threshold sets time_warning" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L2"})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            pathway_mode: 5,
            traversal_time: 200
          })
        ],
        levels: [
          make_level(%{level_id: "L1", level_name: "Street", level_index: 0.0}),
          make_level(%{level_id: "L2", level_name: "Platform", level_index: -1.0})
        ]
      }

      result = Connectivity.build_expanded_route(snapshot, "ENT_1", "PLAT_1")
      elevator_step = Enum.find(result.steps, &(&1.mode_int == 5))
      assert elevator_step.time_warning == true
    end

    test "uses reversed signposted_as when traversing bidirectional edge in reverse" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            is_bidirectional: true,
            signposted_as: "To Platform",
            reversed_signposted_as: "To Entrance"
          })
        ],
        levels: []
      }

      result = Connectivity.build_expanded_route(snapshot, "PLAT_1", "ENT_1")
      destination_step = Enum.find(result.steps, &(&1.stop_id == "ENT_1"))

      assert destination_step.instruction == "To Entrance"
    end

    test "uses reversed signposted_as on non-bidirectional pathway traversed in reverse" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0})
        ],
        pathways: [
          # Bidirectional pathway so BFS can reach ENT_1 from PLAT_1
          make_pathway(%{
            pathway_id: "PW_BIDIR",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            is_bidirectional: true,
            signposted_as: nil,
            reversed_signposted_as: nil,
            traversal_time: 100
          }),
          # Unidirectional pathway (shorter) — also from ENT_1 → PLAT_1
          # BFS traverses this in reverse because it's cheaper, but only
          # the bidirectional edge is actually walkable in reverse.
          # We test effective_signposted_as directly for the non-bidirectional case.
          make_pathway(%{
            pathway_id: "PW_UNI",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            is_bidirectional: false,
            signposted_as: "Forward Only",
            reversed_signposted_as: "Reverse Only",
            traversal_time: 20
          })
        ],
        levels: []
      }

      # Integration: the BFS uses the bidirectional edge for PLAT_1 → ENT_1
      result = Connectivity.build_expanded_route(snapshot, "PLAT_1", "ENT_1")
      assert is_map(result)

      # Unit: directly test effective_signposted_as with the exact scenario the fix addresses
      # (traversed_reverse? true on a non-bidirectional hop)
      hop = %{
        traversed_reverse?: true,
        is_bidirectional: false,
        signposted_as: "Forward Only",
        reversed_signposted_as: "Reverse Only"
      }

      assert Connectivity.effective_signposted_as(hop) == "Reverse Only"
    end

    test "effective_signposted_as returns nil when reversed signage is missing" do
      hop = %{
        traversed_reverse?: true,
        is_bidirectional: false,
        signposted_as: "Fallback",
        reversed_signposted_as: nil
      }

      assert Connectivity.effective_signposted_as(hop) == nil
    end

    test "effective_signposted_as returns signposted_as for forward traversal" do
      hop = %{
        traversed_reverse?: false,
        is_bidirectional: true,
        signposted_as: "Forward",
        reversed_signposted_as: "Reverse"
      }

      assert Connectivity.effective_signposted_as(hop) == "Forward"
    end

    test "long route generates warning string" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "PLAT_1",
            traversal_time: 400
          })
        ],
        levels: []
      }

      result = Connectivity.build_expanded_route(snapshot, "ENT_1", "PLAT_1")
      assert result.status == :long
      assert length(result.warnings) == 1
      assert hd(result.warnings) =~ "exceeds the threshold"
    end

    test "no path returns :nopath" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0})
        ],
        pathways: [],
        levels: []
      }

      assert :nopath = Connectivity.build_expanded_route(snapshot, "ENT_1", "PLAT_1")
    end

    test "level path string is built correctly" do
      snapshot = %{
        child_stops: [
          make_stop(%{stop_id: "ENT_1", stop_name: "Entrance", location_type: 2, level_id: "L1"}),
          make_stop(%{stop_id: "NODE_1", stop_name: "Node", location_type: 3, level_id: "L2"}),
          make_stop(%{stop_id: "PLAT_1", stop_name: "Platform", location_type: 0, level_id: "L3"})
        ],
        pathways: [
          make_pathway(%{
            pathway_id: "PW_1",
            from_stop_id: "ENT_1",
            to_stop_id: "NODE_1",
            pathway_mode: 5,
            traversal_time: 30
          }),
          make_pathway(%{
            pathway_id: "PW_2",
            from_stop_id: "NODE_1",
            to_stop_id: "PLAT_1",
            pathway_mode: 5,
            traversal_time: 30
          })
        ],
        levels: [
          make_level(%{level_id: "L1", level_name: "Busway", level_index: 0.0}),
          make_level(%{level_id: "L2", level_name: "Mezzanine", level_index: -1.0}),
          make_level(%{level_id: "L3", level_name: "Platform", level_index: -2.0})
        ]
      }

      result = Connectivity.build_expanded_route(snapshot, "ENT_1", "PLAT_1")
      assert result.level_path == "Busway → Mezzanine → Platform"
    end
  end
end
