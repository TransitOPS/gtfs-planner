defmodule GtfsPlanner.Gtfs.StationReportTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.{Level, Pathway, StationReport, Stop}

  describe "build/1" do
    test "builds deterministic sections and includes core metrics" do
      report = StationReport.build(sample_snapshot())

      assert report.station_stop_id == "STATION"
      assert %DateTime{} = report.generated_at

      section_ids = Enum.map(report.sections, & &1.id)

      assert section_ids == [
               "inventory",
               "gps",
               "data_integrity",
               "naming_conventions",
               "entrance_platform_connectivity",
               "pathway_validation",
               "levels_validation",
               "accessibility",
               "attribute_completeness",
               "not_available"
             ]

      inventory = section(report, "inventory")
      node_inventory = item(inventory, "node_inventory")
      assert node_inventory.value[1] == 1
      assert node_inventory.value[0] == 1
      assert node_inventory.value[2] == 1
      assert node_inventory.value[4] == 2

      gps = section(report, "gps")
      gps_item = item(gps, "gps_presence_by_type")
      assert gps_item.status == :fail
      assert gps_item.value["0"].missing == 1

      integrity = section(report, "data_integrity")
      isolated = item(integrity, "isolated_nodes")
      assert isolated.status == :fail
      assert "G1" in isolated.details

      accessibility = section(report, "accessibility")
      step_free = item(accessibility, "step_free_routes")
      assert step_free.status == :pass
      assert step_free.value.connected_pairs == 1

      unavailable = section(report, "not_available")
      unavailable_item = item(unavailable, "unavailable_metrics")
      assert unavailable_item.value > 0
      assert "mechanical_stair_count" in unavailable_item.details
    end

    test "gps section includes gps validation items from GpsChecks" do
      report =
        StationReport.build(%{
          station:
            stop("STATION", 1, stop_lat: Decimal.new("47.0"), stop_lon: Decimal.new("-122.0")),
          child_stops: [
            stop("E1", 2,
              parent_station: "STATION",
              stop_lat: Decimal.new("47.0"),
              stop_lon: Decimal.new("-122.0001")
            ),
            stop("G1", 3,
              parent_station: "STATION",
              stop_lat: Decimal.new("47.01"),
              stop_lon: Decimal.new("122.0")
            )
          ],
          levels: [],
          pathways: []
        })

      gps = section(report, "gps")

      assert item(gps, "positive_longitude").status == :fail
      assert item(gps, "entrance_gps_distance").status == :pass
      assert item(gps, "optional_gps_clustering").status == :warn
    end

    test "includes naming validation items in the built report" do
      report =
        StationReport.build(%{
          station: %Stop{
            stop_id: "STATION",
            stop_name: "Station",
            location_type: 1
          },
          child_stops: [
            %Stop{
              stop_id: "generic_lobby",
              stop_name: "Fare Line Mezzanine Paid",
              location_type: 3,
              parent_station: "STATION"
            },
            %Stop{
              stop_id: "ba_platform_1",
              stop_name: "platform a",
              location_type: 4,
              parent_station: "STATION"
            }
          ],
          levels: [],
          pathways: []
        })

      naming = section(report, "naming_conventions")

      assert item(naming, "naming_title_case").status == :warn
      assert item(naming, "naming_jargon").status == :warn
      assert item(naming, "naming_node_prefix").details == ["generic_lobby"]
      assert item(naming, "naming_boarding_prefix").details == ["ba_platform_1"]
    end

    test "includes pathway validation items in the built report" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION", level_id: "L1"),
            stop("PLAT_A", 0, parent_station: "STATION", level_id: "L2")
          ],
          levels: [
            %{level: level("L1", 0.0), stop_count: 1},
            %{level: level("L2", 1.0), stop_count: 1}
          ],
          pathways: [
            pathway("PW_STAIR", "ENT_A", "PLAT_A", 2, true, stair_count: -5),
            pathway("PW_FAST", "ENT_A", "PLAT_A", 1, true,
              length: Decimal.new("100"),
              traversal_time: 10
            )
          ]
        })

      validation = section(report, "pathway_validation")

      assert item(validation, "pathway_stair_sign_consistency").status == :fail
      assert "PW_STAIR" in item(validation, "pathway_stair_sign_consistency").details
      assert item(validation, "pathway_speed_plausibility").status == :warn

      assert [%{id: "PW_FAST", reason: reason}] =
               item(validation, "pathway_speed_plausibility").details

      assert String.contains?(reason, "m/s")
    end

    test "includes level validation items in the built report" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("PLAT_A", 0, parent_station: "STATION", level_id: nil),
            stop("PLAT_B", 0, parent_station: "STATION", level_id: "L_UNKNOWN")
          ],
          levels: [
            %{level: level("L1", 0.0), stop_count: 0},
            %{
              level: %Level{level_id: "GROUND_LEVEL", level_index: 1.0, level_name: "Ground"},
              stop_count: 0
            }
          ],
          pathways: []
        })

      validation = section(report, "levels_validation")

      assert item(validation, "level_referential_integrity").status == :fail
      assert item(validation, "platforms_missing_level").status == :warn
      assert item(validation, "level_naming_consistency").status == :warn
    end

    test "respects directed pathways for entrance to platform reachability" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("E1", 2, parent_station: "STATION"),
            stop("B1", 4, parent_station: "P1"),
            stop("P1", 0, parent_station: "STATION")
          ],
          levels: [%{level: level("L1", 0.0), stop_count: 3}],
          pathways: [
            pathway("P1", "B1", "E1", 1, false)
          ]
        })

      integrity = section(report, "data_integrity")
      connectivity = item(integrity, "entrance_to_platform_connectivity")
      assert connectivity.status == :fail
      assert [%{entrance_stop_id: "E1", reachable: false}] = connectivity.details
    end

    test "single-platform stations pass interconnection when no peer platform exists" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("P1", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: []
        })

      integrity = section(report, "data_integrity")
      interconnection = item(integrity, "platform_interconnection")

      assert interconnection.status == :pass
      assert interconnection.value == %{connected: 1, disconnected: 0}
      assert [%{platform_stop_id: "P1", connected: true}] = interconnection.details
    end

    test "step-free metric excludes stairs and escalators" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("E1", 2, parent_station: "STATION", level_id: "L1"),
            stop("P1", 0, parent_station: "STATION", level_id: "L2"),
            stop("B1", 4, parent_station: "P1", level_id: "L2")
          ],
          levels: [
            %{level: level("L1", 0.0), stop_count: 1},
            %{level: level("L2", 1.0), stop_count: 1}
          ],
          pathways: [
            pathway("STAIRS", "E1", "B1", 2, true),
            pathway("ESC", "E1", "B1", 4, false)
          ]
        })

      accessibility = section(report, "accessibility")
      step_free = item(accessibility, "step_free_routes")

      assert step_free.status == :fail

      assert [%{entrance_stop_id: "E1", platform_stop_id: "P1", reachable: false}] =
               step_free.details
    end

    test "entrance to platform paths include direct reachable metadata" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("BOARD_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            pathway("PW_DIRECT", "ENT_A", "BOARD_A", 5, false)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert item.status == :pass

      assert item.value == %{
               entrances: 1,
               platforms: 1,
               connected_pairs: 1,
               accessible_pairs: 1,
               total_pairs: 1
             }

      assert [
               %{
                 entrance_stop_id: "ENT_A",
                 platform_stop_id: "PLAT_A",
                 reachable: true,
                 accessible: true,
                 shortest: %{
                   path: [
                     %{stop_id: "ENT_A", pathway_id: nil, pathway_mode: nil},
                     %{stop_id: "BOARD_A", pathway_id: "PW_DIRECT", pathway_mode: 5}
                   ]
                 }
               }
             ] = item.details
    end

    test "entrance to platform paths respect pathway directionality" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("BOARD_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            pathway("PW_REVERSE", "BOARD_A", "ENT_A", 1, false)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert item.status == :fail

      assert [
               %{
                 entrance_stop_id: "ENT_A",
                 platform_stop_id: "PLAT_A",
                 reachable: false,
                 shortest: nil
               }
             ] = item.details
    end

    test "entrance to platform paths include multi-hop routes with hop metadata" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("GEN_A", 3, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("BOARD_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            pathway("PW_A", "ENT_A", "GEN_A", 1, false),
            pathway("PW_B", "GEN_A", "BOARD_A", 3, false)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [row] = item.details

      assert row.reachable
      assert row.platform_stop_id == "PLAT_A"

      assert Enum.map(row.shortest.path, & &1.stop_id) == ["ENT_A", "GEN_A", "BOARD_A"]

      assert row.shortest.path == [
               %{stop_id: "ENT_A", pathway_id: nil, pathway_mode: nil},
               %{stop_id: "GEN_A", pathway_id: "PW_A", pathway_mode: 1},
               %{stop_id: "BOARD_A", pathway_id: "PW_B", pathway_mode: 3}
             ]
    end

    test "entrance to platform paths are deterministic with duplicate directional edges" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_B", 2, parent_station: "STATION"),
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("PLAT_B", 0, parent_station: "STATION"),
            stop("BOARD_B", 4, parent_station: "PLAT_B"),
            stop("BOARD_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            pathway("PW_200", "ENT_A", "BOARD_A", 1, false),
            pathway("PW_100", "ENT_A", "BOARD_A", 1, false),
            pathway("PW_300", "ENT_B", "BOARD_B", 1, false),
            pathway("PW_400", "ENT_A", "BOARD_B", 1, false),
            pathway("PW_500", "ENT_B", "BOARD_A", 1, false)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert Enum.map(item.details, &{&1.entrance_stop_id, &1.platform_stop_id}) == [
               {"ENT_A", "PLAT_A"},
               {"ENT_A", "PLAT_B"},
               {"ENT_B", "PLAT_A"},
               {"ENT_B", "PLAT_B"}
             ]

      detail =
        Enum.find(
          item.details,
          &(&1.entrance_stop_id == "ENT_A" and &1.platform_stop_id == "PLAT_A")
        )

      assert detail.shortest.path == [
               %{stop_id: "ENT_A", pathway_id: nil, pathway_mode: nil},
               %{stop_id: "BOARD_A", pathway_id: "PW_100", pathway_mode: 1}
             ]
    end

    test "entrance to platform paths include enriched traversal totals and bidirectionality" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION", level_id: "L1"),
            stop("GEN_A", 3, parent_station: "STATION", level_id: "L1"),
            stop("PLAT_A", 0, parent_station: "STATION", level_id: "L2"),
            stop("BOARD_A", 4, parent_station: "PLAT_A", level_id: "L2")
          ],
          levels: [
            %{level: level("L1", 0.0), stop_count: 2},
            %{level: level("L2", 1.0), stop_count: 1}
          ],
          pathways: [
            pathway("PW_WALK", "ENT_A", "GEN_A", 1, true,
              length: Decimal.new("10"),
              signposted_as: "Platform"
            ),
            pathway("PW_ELEV", "GEN_A", "BOARD_A", 5, false, reversed_signposted_as: "Street")
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable

      assert detail.shortest.enriched.hops |> Enum.map(& &1.stop_id) ==
               ["ENT_A", "GEN_A", "BOARD_A"]

      assert detail.shortest.enriched.hops |> Enum.at(2) |> Map.get(:calculation_method) ==
               :elevator_level_diff_estimate

      assert detail.shortest.enriched.totals.segment_count == 2
      assert detail.shortest.enriched.totals.has_elevator
      assert detail.shortest.enriched.totals.has_stairs == false
      assert detail.shortest.enriched.totals.level_changes == 1
      assert detail.shortest.enriched.totals.signposted_segments == 1
      assert detail.shortest.enriched.all_bidirectional == false
    end

    test "entrance to platform paths mark reverse traversal for bidirectional segments" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("GEN_A", 3, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("BOARD_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            pathway("PW_LOBBY", "ENT_A", "GEN_A", 1, true,
              signposted_as: "To concourse",
              reversed_signposted_as: "To entrance"
            ),
            pathway("PW_FINAL", "BOARD_A", "GEN_A", 1, true,
              signposted_as: "To concourse",
              reversed_signposted_as: "To platform"
            )
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable
      refute detail.shortest.enriched.hops |> Enum.at(1) |> Map.get(:traversed_reverse?)
      assert detail.shortest.enriched.hops |> Enum.at(2) |> Map.get(:traversed_reverse?)
      assert detail.shortest.enriched.totals.signposted_segments == 2

      assert detail.shortest.enriched.hops |> Enum.at(2) |> Map.get(:reversed_signposted_as) ==
               "To platform"
    end

    test "entrance to platform paths do not count reverse-only signage on forward traversal" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("BOARD_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            pathway("PW_DIRECT", "ENT_A", "BOARD_A", 1, true,
              reversed_signposted_as: "To entrance"
            )
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable
      refute detail.shortest.enriched.hops |> Enum.at(1) |> Map.get(:traversed_reverse?)
      assert detail.shortest.enriched.totals.signposted_segments == 0
    end

    test "entrance to platform paths fall back to forward signage when reverse signage is whitespace" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("BOARD_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            pathway("PW_DIRECT", "BOARD_A", "ENT_A", 1, true,
              signposted_as: "To platform",
              reversed_signposted_as: "   "
            )
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable
      assert detail.shortest.enriched.hops |> Enum.at(1) |> Map.get(:traversed_reverse?)
      assert detail.shortest.enriched.totals.signposted_segments == 1
    end

    test "platform without boarding areas is reachable" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: [
            pathway("PW_WALK", "ENT_A", "PLAT_A", 1, true)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert item.status == :pass

      assert item.value == %{
               entrances: 1,
               platforms: 1,
               connected_pairs: 1,
               accessible_pairs: 1,
               total_pairs: 1
             }

      [detail] = item.details
      assert detail.reachable
      assert detail.platform_stop_id == "PLAT_A"
    end

    test "warn summary preserves entrance and platform counts when pairs cannot be formed" do
      entrance_only_report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION")
          ],
          levels: [],
          pathways: []
        })

      section = section(entrance_only_report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert item.status == :warn

      assert item.value == %{
               entrances: 1,
               platforms: 0,
               connected_pairs: 0,
               accessible_pairs: 0,
               total_pairs: 0
             }

      platform_only_report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("PLAT_A", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: []
        })

      section = section(platform_only_report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert item.status == :warn

      assert item.value == %{
               entrances: 0,
               platforms: 1,
               connected_pairs: 0,
               accessible_pairs: 0,
               total_pairs: 0
             }
    end

    test "accessible path differs from default when only stairs connect directly" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("GEN_A", 3, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: [
            # Direct path via stairs (not step-free)
            pathway("PW_STAIRS", "ENT_A", "PLAT_A", 2, true),
            # Step-free detour via generic node + elevator
            pathway("PW_WALK", "ENT_A", "GEN_A", 1, true),
            pathway("PW_ELEV", "GEN_A", "PLAT_A", 5, true)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable
      assert detail.accessible
      refute detail.paths_identical
      assert detail.shortest != nil
      assert detail.accessible_path != nil

      # Default path is direct via stairs (fewer hops)
      assert Enum.map(detail.shortest.path, & &1.stop_id) == ["ENT_A", "PLAT_A"]

      # Accessible path goes through GEN_A
      assert Enum.map(detail.accessible_path.path, & &1.stop_id) ==
               ["ENT_A", "GEN_A", "PLAT_A"]
    end

    test "no step-free path available when only stairs exist" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: [
            pathway("PW_STAIRS", "ENT_A", "PLAT_A", 2, true)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable
      refute detail.accessible
      assert detail.accessible_path == nil
      refute detail.paths_identical
    end

    test "paths identical when all step-free modes used" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: [
            pathway("PW_WALK", "ENT_A", "PLAT_A", 1, true)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable
      assert detail.accessible
      assert detail.paths_identical
    end

    test "BFS reaches boarding area under platform" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
            stop("PLAT_A", 0, parent_station: "STATION"),
            stop("BA_A", 4, parent_station: "PLAT_A")
          ],
          levels: [],
          pathways: [
            # Only a pathway to the boarding area, not the platform itself
            pathway("PW_WALK", "ENT_A", "BA_A", 1, true)
          ]
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")
      [detail] = item.details

      assert detail.reachable
      assert detail.platform_stop_id == "PLAT_A"
      assert Enum.map(detail.shortest.path, & &1.stop_id) == ["ENT_A", "BA_A"]
    end

    test "entrance to platform paths warn when entrances or platforms are missing" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [stop("ENT_A", 2, parent_station: "STATION")],
          levels: [],
          pathways: []
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert item.status == :warn

      assert item.value == %{
               entrances: 1,
               platforms: 0,
               connected_pairs: 0,
               accessible_pairs: 0,
               total_pairs: 0
             }

      assert item.details == []
    end

    test "raises on invalid snapshot shape" do
      assert_raise FunctionClauseError, fn ->
        apply(StationReport, :build, [%{station: stop("STATION", 1)}])
      end
    end

    test "all existing items have category: :error" do
      report = StationReport.build(sample_snapshot())

      for section <- report.sections,
          item <- section.items,
          # New submodule items may have other categories
          item.id not in [
            "wheelchair_boarding_consistency",
            "duplicate_stop_ids",
            "reverse_reachability"
          ] do
        assert Map.has_key?(item, :category),
               "Item #{item.id} in section #{section.id} missing category"
      end
    end

    test "wheelchair_boarding_consistency fails when station claims accessible but no accessible path exists" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1, wheelchair_boarding: 1),
          child_stops: [
            stop("E1", 2, parent_station: "STATION"),
            stop("P1", 0, parent_station: "STATION"),
            stop("B1", 4, parent_station: "P1")
          ],
          levels: [],
          # Only stairs connect — not accessible via modes 1/5/6/7
          pathways: [
            pathway("PW_STAIRS", "E1", "B1", 2, true, stair_count: 10)
          ]
        })

      integrity = section(report, "data_integrity")
      wbc = item(integrity, "wheelchair_boarding_consistency")

      assert wbc.status == :fail
    end

    test "wheelchair_boarding_consistency passes when accessible path exists via elevator" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1, wheelchair_boarding: 1),
          child_stops: [
            stop("E1", 2, parent_station: "STATION"),
            stop("P1", 0, parent_station: "STATION"),
            stop("B1", 4, parent_station: "P1")
          ],
          levels: [],
          pathways: [
            pathway("PW_ELEV", "E1", "B1", 5, true)
          ]
        })

      integrity = section(report, "data_integrity")
      wbc = item(integrity, "wheelchair_boarding_consistency")

      assert wbc.status == :pass
    end

    test "wheelchair_boarding_consistency passes when station wheelchair_boarding is 0 or nil" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1, wheelchair_boarding: 0),
          child_stops: [
            stop("E1", 2, parent_station: "STATION"),
            stop("P1", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: []
        })

      integrity = section(report, "data_integrity")
      wbc = item(integrity, "wheelchair_boarding_consistency")

      assert wbc.status == :pass
    end

    test "reverse_reachability fails when forward works but reverse does not" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("E1", 2, parent_station: "STATION"),
            stop("P1", 0, parent_station: "STATION"),
            stop("B1", 4, parent_station: "P1")
          ],
          levels: [],
          # Unidirectional: E1 -> B1 only, no way back
          pathways: [
            pathway("PW_GATE", "E1", "B1", 6, false)
          ]
        })

      connectivity = section(report, "entrance_platform_connectivity")
      reverse = item(connectivity, "reverse_reachability")

      assert reverse.status == :fail
      assert reverse.value > 0
    end

    test "reverse_reachability passes for bidirectional walkway" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("E1", 2, parent_station: "STATION"),
            stop("P1", 0, parent_station: "STATION")
          ],
          levels: [],
          pathways: [
            pathway("PW_WALK", "E1", "P1", 1, true)
          ]
        })

      connectivity = section(report, "entrance_platform_connectivity")
      reverse = item(connectivity, "reverse_reachability")

      assert reverse.status == :pass
    end
  end

  defp sample_snapshot do
    %{
      station: stop("STATION", 1, stop_lat: Decimal.new("47.0"), stop_lon: Decimal.new("-122.0")),
      child_stops: [
        stop("PLAT_A", 0,
          parent_station: "STATION",
          stop_lat: nil,
          stop_lon: Decimal.new("-122.0"),
          wheelchair_boarding: 1,
          level_id: "L2"
        ),
        stop("ENT_A", 2,
          parent_station: "STATION",
          stop_lat: Decimal.new("47.1"),
          stop_lon: Decimal.new("-122.1"),
          wheelchair_boarding: 2,
          level_id: "L1"
        ),
        stop("B_A_1", 4,
          parent_station: "PLAT_A",
          wheelchair_boarding: 1,
          level_id: "L2"
        ),
        stop("B_A_2", 4,
          parent_station: "PLAT_A",
          wheelchair_boarding: nil,
          level_id: "L2"
        ),
        stop("G1", 3,
          parent_station: "STATION",
          wheelchair_boarding: 0,
          level_id: "L1"
        )
      ],
      levels: [
        %{level: level("L1", 0.0), stop_count: 2},
        %{level: level("L2", 1.0), stop_count: 3}
      ],
      pathways: [
        pathway("PW_STAIRS", "ENT_A", "B_A_1", 2, true, stair_count: 10),
        pathway("PW_ESC", "B_A_1", "B_A_2", 4, false),
        pathway("PW_ELEV", "ENT_A", "PLAT_A", 5, true, min_width: Decimal.new("1.2")),
        pathway("PW_ELEV_BOARD", "ENT_A", "B_A_1", 5, true, min_width: Decimal.new("1.2"))
      ]
    }
  end

  defp stop(stop_id, location_type, attrs \\ []) do
    attrs = Map.new(attrs)

    %Stop{
      stop_id: stop_id,
      stop_name: stop_id,
      location_type: location_type,
      parent_station: Map.get(attrs, :parent_station),
      level_id: Map.get(attrs, :level_id),
      stop_lat: Map.get(attrs, :stop_lat),
      stop_lon: Map.get(attrs, :stop_lon),
      wheelchair_boarding: Map.get(attrs, :wheelchair_boarding)
    }
  end

  defp pathway(pathway_id, from_stop_id, to_stop_id, pathway_mode, is_bidirectional, attrs \\ []) do
    attrs = Map.new(attrs)

    %Pathway{
      pathway_id: pathway_id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      pathway_mode: pathway_mode,
      is_bidirectional: is_bidirectional,
      traversal_time: Map.get(attrs, :traversal_time),
      length: Map.get(attrs, :length),
      min_width: Map.get(attrs, :min_width),
      max_slope: Map.get(attrs, :max_slope),
      stair_count: Map.get(attrs, :stair_count),
      signposted_as: Map.get(attrs, :signposted_as),
      reversed_signposted_as: Map.get(attrs, :reversed_signposted_as)
    }
  end

  defp level(level_id, level_index) do
    %Level{level_id: level_id, level_index: level_index}
  end

  defp section(report, id) do
    Enum.find(report.sections, &(&1.id == id))
  end

  defp item(section, id) do
    Enum.find(section.items, &(&1.id == id))
  end
end
