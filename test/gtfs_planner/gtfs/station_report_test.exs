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
               "accessibility",
               "entrance_platform_connectivity",
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
      assert step_free.status == :fail
      assert step_free.value.connected_pairs == 1

      unavailable = section(report, "not_available")
      unavailable_item = item(unavailable, "unavailable_metrics")
      assert unavailable_item.value > 0
      assert "mechanical_stair_count" in unavailable_item.details
    end

    test "respects directed pathways for entrance to boarding reachability" do
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
      connectivity = item(integrity, "entrance_to_boarding_connectivity")
      assert connectivity.status == :fail
      assert [%{entrance_stop_id: "E1", reachable: false}] = connectivity.details
    end

    test "step-free metric excludes stairs and escalators" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("E1", 2, parent_station: "STATION", level_id: "L1"),
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

      assert [%{entrance_stop_id: "E1", platform_stop_id: "B1", reachable: false}] =
               step_free.details
    end

    test "entrance to platform paths include direct reachable metadata" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
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
      assert item.value == %{entrances: 1, boarding_areas: 1, connected_pairs: 1, total_pairs: 1}

      assert [
               %{
                 entrance_stop_id: "ENT_A",
                 platform_stop_id: "BOARD_A",
                 reachable: true,
                 path: [
                   %{stop_id: "ENT_A", pathway_id: nil, pathway_mode: nil},
                   %{stop_id: "BOARD_A", pathway_id: "PW_DIRECT", pathway_mode: 5}
                 ]
               }
             ] = item.details
    end

    test "entrance to platform paths respect pathway directionality" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [
            stop("ENT_A", 2, parent_station: "STATION"),
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
                 platform_stop_id: "BOARD_A",
                 reachable: false,
                 path: []
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

      assert Enum.map(row.path, & &1.stop_id) == ["ENT_A", "GEN_A", "BOARD_A"]

      assert row.path == [
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
               {"ENT_A", "BOARD_A"},
               {"ENT_A", "BOARD_B"},
               {"ENT_B", "BOARD_A"},
               {"ENT_B", "BOARD_B"}
             ]

      detail =
        Enum.find(
          item.details,
          &(&1.entrance_stop_id == "ENT_A" and &1.platform_stop_id == "BOARD_A")
        )

      assert detail.path == [
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
      assert detail.enriched.hops |> Enum.map(& &1.stop_id) == ["ENT_A", "GEN_A", "BOARD_A"]

      assert detail.enriched.hops |> Enum.at(2) |> Map.get(:calculation_method) ==
               :elevator_level_diff_estimate

      assert detail.enriched.totals.segment_count == 2
      assert detail.enriched.totals.has_elevator
      assert detail.enriched.totals.has_stairs == false
      assert detail.enriched.totals.level_changes == 1
      assert detail.enriched.totals.signposted_segments == 1
      assert detail.enriched.all_bidirectional == false
    end

    test "entrance to platform paths warn when entrances or platforms are missing" do
      report =
        StationReport.build(%{
          station: stop("STATION", 1),
          child_stops: [stop("PLAT_A", 0, parent_station: "STATION")],
          levels: [],
          pathways: []
        })

      section = section(report, "entrance_platform_connectivity")
      item = item(section, "entrance_platform_paths")

      assert item.status == :warn
      assert item.value == %{entrances: 0, boarding_areas: 0, connected_pairs: 0, total_pairs: 0}
      assert item.details == []
    end

    test "raises on invalid snapshot shape" do
      assert_raise FunctionClauseError, fn ->
        apply(StationReport, :build, [%{station: stop("STATION", 1)}])
      end
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
