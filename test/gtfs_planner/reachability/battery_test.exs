defmodule GtfsPlanner.Reachability.BatteryTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Reachability.Battery

  defp stop(id, location_type, name \\ nil) do
    %{stop_id: id, stop_name: name || id, location_type: location_type}
  end

  describe "derive/1" do
    test "2 entrances and 3 platforms produces 36 pairs" do
      snapshot = %{
        child_stops: [
          stop("ENT_A", 2),
          stop("ENT_B", 2),
          stop("PLAT_1", 0),
          stop("PLAT_2", 0),
          stop("PLAT_3", 0)
        ]
      }

      pairs = Battery.derive(snapshot)

      assert length(pairs) == 36
    end

    test "emits no pair where from_stop_id == to_stop_id" do
      snapshot = %{
        child_stops: [
          stop("ENT_A", 2),
          stop("PLAT_1", 0),
          stop("PLAT_2", 0)
        ]
      }

      pairs = Battery.derive(snapshot)

      refute Enum.any?(pairs, fn p -> p.from_stop_id == p.to_stop_id end)
    end

    test "excludes stops with location_type 1, 3, or 4 as endpoints" do
      snapshot = %{
        child_stops: [
          stop("ENT_A", 2),
          stop("PLAT_1", 0),
          stop("STATION", 1),
          stop("NODE", 3),
          stop("BOARD", 4)
        ]
      }

      pairs = Battery.derive(snapshot)

      refute Enum.any?(pairs, fn p -> p.from_stop_id in ["STATION", "NODE", "BOARD"] end)
      refute Enum.any?(pairs, fn p -> p.to_stop_id in ["STATION", "NODE", "BOARD"] end)
    end

    test "returns [] for a station with one platform and no entrances" do
      snapshot = %{child_stops: [stop("PLAT_1", 0)]}

      assert Battery.derive(snapshot) == []
    end

    test "shuffled child_stops produces identical lists including index values" do
      stops = [
        stop("ENT_A", 2),
        stop("ENT_B", 2),
        stop("PLAT_1", 0),
        stop("PLAT_2", 0)
      ]

      result1 = Battery.derive(%{child_stops: stops})
      result2 = Battery.derive(%{child_stops: Enum.shuffle(stops)})

      assert result1 == result2
    end

    test "pairs are ordered by kind, from_stop_id, to_stop_id, mode" do
      snapshot = %{
        child_stops: [
          stop("ENT_B", 2),
          stop("ENT_A", 2),
          stop("PLAT_2", 0),
          stop("PLAT_1", 0)
        ]
      }

      pairs = Battery.derive(snapshot)

      kinds = Enum.map(pairs, & &1.kind)
      entry_end = Enum.find_index(kinds, &(&1 != :entry))
      egress_end = Enum.find_index(Enum.drop(kinds, entry_end), &(&1 != :egress)) + entry_end

      assert Enum.all?(Enum.take(kinds, entry_end), &(&1 == :entry))
      assert Enum.all?(Enum.slice(kinds, entry_end, egress_end - entry_end), &(&1 == :egress))
      assert Enum.all?(Enum.drop(kinds, egress_end), &(&1 == :transfer))

      indices = Enum.map(pairs, & &1.index)
      assert indices == Enum.to_list(0..(length(pairs) - 1))
    end

    test "each pair has both walking and wheelchair modes" do
      snapshot = %{
        child_stops: [
          stop("ENT_A", 2),
          stop("PLAT_1", 0)
        ]
      }

      pairs = Battery.derive(snapshot)

      walking = Enum.count(pairs, &(&1.mode == :walking))
      wheelchair = Enum.count(pairs, &(&1.mode == :wheelchair))

      assert walking == wheelchair
    end
  end

  describe "max_pairs/0" do
    test "returns 2000" do
      assert Battery.max_pairs() == 2000
    end
  end
end
