defmodule GtfsPlanner.Routing.FeedAdapterTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.{Level, Pathway, Stop}
  alias GtfsPlanner.Routing.FeedAdapter

  describe "stop_rows/1" do
    test "renames stop_id/stop_name/stop_desc and maps coordinate fields" do
      stop = %Stop{
        stop_id: "ENT_A",
        stop_name: "Market St Entrance",
        stop_desc: "Main entrance",
        stop_lat: Decimal.new("39.9526"),
        stop_lon: Decimal.new("-75.1652"),
        location_type: 2,
        wheelchair_boarding: 1,
        parent_station: "PHL_30ST",
        level_id: "L1",
        platform_code: "A"
      }

      [row] = FeedAdapter.stop_rows([stop])

      assert row.id == "ENT_A"
      assert row.name == "Market St Entrance"
      assert row.desc == "Main entrance"
      assert row.location_type == 2
      assert row.wheelchair_boarding == 1
      assert row.parent_station == "PHL_30ST"
      assert row.level_id == "L1"
    end

    test "omits :code even when platform_code is set" do
      stop = %Stop{
        stop_id: "PLAT_1",
        stop_name: "Platform 1",
        platform_code: "1",
        stop_lat: Decimal.new("39.0"),
        stop_lon: Decimal.new("-75.0")
      }

      [row] = FeedAdapter.stop_rows([stop])

      refute Map.has_key?(row, :code)
    end

    test "passes Decimal stop_lat/stop_lon through unconverted" do
      stop = %Stop{
        stop_id: "S1",
        stop_lat: Decimal.new("39.9526"),
        stop_lon: Decimal.new("-75.1652")
      }

      [row] = FeedAdapter.stop_rows([stop])

      assert %Decimal{} = row.stop_lat
      assert %Decimal{} = row.stop_lon
      assert Decimal.equal?(row.stop_lat, Decimal.new("39.9526"))
    end

    test "preserves nil parent_station as nil" do
      stop = %Stop{
        stop_id: "STATION",
        parent_station: nil
      }

      [row] = FeedAdapter.stop_rows([stop])

      assert row.parent_station == nil
    end
  end

  describe "pathway_rows/1" do
    test "converts is_bidirectional true to 1 and false to 0" do
      bidir = %Pathway{
        pathway_id: "PW_1",
        pathway_mode: 1,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B"
      }

      unidir = %Pathway{
        pathway_id: "PW_2",
        pathway_mode: 2,
        is_bidirectional: false,
        from_stop_id: "C",
        to_stop_id: "D"
      }

      [row_bidir, row_unidir] = FeedAdapter.pathway_rows([bidir, unidir])

      assert row_bidir.is_bidirectional == 1
      assert row_unidir.is_bidirectional == 0
    end

    test "preserves Decimal length and max_slope" do
      pathway = %Pathway{
        pathway_id: "PW_3",
        pathway_mode: 1,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B",
        length: Decimal.new("133.5"),
        max_slope: Decimal.new("0.05")
      }

      [row] = FeedAdapter.pathway_rows([pathway])

      assert %Decimal{} = row.length
      assert Decimal.equal?(row.length, Decimal.new("133.5"))
      assert %Decimal{} = row.max_slope
    end

    test "maps all pathway fields" do
      pathway = %Pathway{
        pathway_id: "PW_4",
        pathway_mode: 5,
        is_bidirectional: true,
        from_stop_id: "X",
        to_stop_id: "Y",
        traversal_time: 90,
        length: Decimal.new("10"),
        stair_count: nil,
        max_slope: nil,
        signposted_as: "To Elevator",
        reversed_signposted_as: "From Elevator"
      }

      [row] = FeedAdapter.pathway_rows([pathway])

      assert row.pathway_id == "PW_4"
      assert row.pathway_mode == 5
      assert row.from_stop_id == "X"
      assert row.to_stop_id == "Y"
      assert row.traversal_time == 90
      assert row.signposted_as == "To Elevator"
      assert row.reversed_signposted_as == "From Elevator"
    end
  end

  describe "level_rows/1" do
    test "unwraps nested station-level records and emits only router keys" do
      level = %Level{
        level_id: "L1",
        level_index: 0.0,
        level_name: "Ground"
      }

      station_levels = [
        %{
          level: level,
          stop_count: 5,
          diagram_filename: "ground.png",
          stop_level: %{id: "some-uuid"}
        }
      ]

      [row] = FeedAdapter.level_rows(station_levels)

      assert row.level_id == "L1"
      assert row.level_index == 0.0
      assert row.level_name == "Ground"
      refute Map.has_key?(row, :stop_count)
      refute Map.has_key?(row, :diagram_filename)
      refute Map.has_key?(row, :stop_level)
      refute Map.has_key?(row, :level)
    end

    test "handles multiple levels" do
      levels = [
        %{
          level: %Level{level_id: "L1", level_index: 0.0, level_name: "Ground"},
          stop_count: 3,
          diagram_filename: nil,
          stop_level: nil
        },
        %{
          level: %Level{level_id: "L2", level_index: 1.0, level_name: "Mezzanine"},
          stop_count: 2,
          diagram_filename: nil,
          stop_level: nil
        }
      ]

      rows = FeedAdapter.level_rows(levels)

      assert length(rows) == 2
      assert Enum.at(rows, 0).level_id == "L1"
      assert Enum.at(rows, 1).level_id == "L2"
    end
  end
end
