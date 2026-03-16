defmodule GtfsPlanner.Gtfs.StationReport.PathwayChecksTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport.PathwayChecks
  alias GtfsPlanner.Gtfs.{Level, Pathway, Stop}

  describe "validate/3" do
    test "pathway_bidirectional_mechanical fails for bidirectional mode 3" do
      pw = pathway("PW1", "A", "B", 3, true)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_bidirectional_mechanical")

      assert item.status == :fail
      assert item.category == :error
      assert "PW1" in item.details
    end

    test "pathway_bidirectional_mechanical passes for non-bidirectional mode 3" do
      pw = pathway("PW1", "A", "B", 3, false)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_bidirectional_mechanical")

      assert item.status == :pass
    end

    test "pathway_stairs_zero_count fails for mode 2 with stair_count 0" do
      pw = pathway("PW1", "A", "B", 2, true, stair_count: 0)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_stairs_zero_count")

      assert item.status == :fail
      assert item.category == :error
      assert "PW1" in item.details
    end

    test "pathway_stairs_zero_count passes for mode 2 with stair_count > 0" do
      pw = pathway("PW1", "A", "B", 2, true, stair_count: 12)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_stairs_zero_count")

      assert item.status == :pass
    end

    test "pathway_speed_plausibility warns for impossibly fast walkway" do
      # 100m / 10s = 10 m/s
      pw = pathway("PW1", "A", "B", 1, true, length: Decimal.new("100"), traversal_time: 10)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_speed_plausibility")

      assert item.status == :warn
      assert item.category == :analysis
      assert [%{id: "PW1", reason: reason}] = item.details
      assert String.contains?(reason, "m/s")
    end

    test "pathway_speed_plausibility passes for reasonable walkway speed" do
      # 100m / 100s = 1 m/s
      pw = pathway("PW1", "A", "B", 1, true, length: Decimal.new("100"), traversal_time: 100)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_speed_plausibility")

      assert item.status == :pass
    end

    test "pathway_dangling_refs fails when stop_id not in index" do
      pw = pathway("PW1", "MISSING_A", "B", 1, true)
      items = PathwayChecks.validate([pw], %{"B" => %Stop{stop_id: "B"}}, %{})
      item = find_item(items, "pathway_dangling_refs")

      assert item.status == :fail
      assert item.category == :error
      assert [%{id: "PW1", reason: reason}] = item.details
      assert String.contains?(reason, "MISSING_A")
    end

    test "pathway_self_referencing fails when from == to" do
      pw = pathway("PW1", "A", "A", 1, true)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_self_referencing")

      assert item.status == :fail
      assert item.category == :error
      assert "PW1" in item.details
    end

    test "pathway_signage_formatting warns for trailing whitespace" do
      pw = pathway("PW1", "A", "B", 1, true, signposted_as: "Platform  ")
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_signage_formatting")

      assert item.status == :warn
      assert item.category == :convention
    end

    test "pathway_signage_commas warns for comma in signage" do
      pw = pathway("PW1", "A", "B", 1, true, signposted_as: "Platform A, B")
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_signage_commas")

      assert item.status == :warn
      assert item.category == :warning
    end

    test "pathway_stair_sign_consistency fails when sign contradicts direction" do
      si = %{
        "A" => %Stop{stop_id: "A", level_id: "L1"},
        "B" => %Stop{stop_id: "B", level_id: "L2"}
      }

      li = %{
        "L1" => %Level{level_id: "L1", level_index: 0.0},
        "L2" => %Level{level_id: "L2", level_index: 1.0}
      }

      # Going up (L1 -> L2) but stair_count is negative
      pw = pathway("PW1", "A", "B", 2, true, stair_count: -10)
      items = PathwayChecks.validate([pw], si, li)
      item = find_item(items, "pathway_stair_sign_consistency")

      assert item.status == :fail
      assert item.category == :error
      assert "PW1" in item.details
    end

    test "pathway_traversal_time_outliers flags extreme values" do
      pathways = [
        pathway("PW1", "A", "B", 1, true, traversal_time: 30),
        pathway("PW2", "B", "C", 1, true, traversal_time: 30),
        pathway("PW3", "C", "D", 1, true, traversal_time: 30),
        pathway("PW4", "D", "E", 1, true, traversal_time: 30),
        pathway("PW5", "E", "F", 1, true, traversal_time: 30),
        pathway("OUTLIER", "F", "G", 1, true, traversal_time: 300)
      ]

      items = PathwayChecks.validate(pathways, stop_index(), %{})
      item = find_item(items, "pathway_traversal_time_outliers")

      assert item.status == :warn
      assert item.category == :analysis
      assert Enum.any?(item.details, &(&1.id == "OUTLIER"))
    end

    test "empty pathways produce all passing checks" do
      items = PathwayChecks.validate([], %{}, %{})

      Enum.each(items, fn item ->
        assert item.status in [:pass, :info], "Expected #{item.id} to pass or be info"
      end)
    end

    test "pathways where endpoints have no level_id skip stair sign check" do
      si = %{
        "A" => %Stop{stop_id: "A", level_id: nil},
        "B" => %Stop{stop_id: "B", level_id: nil}
      }

      pw = pathway("PW1", "A", "B", 2, true, stair_count: -10)
      items = PathwayChecks.validate([pw], si, %{})
      item = find_item(items, "pathway_stair_sign_consistency")

      assert item.status == :pass
    end

    test "pathway_bidirectional_gates fails for bidirectional mode 6" do
      pw = pathway("PW1", "A", "B", 6, true)
      items = PathwayChecks.validate([pw], stop_index(), %{})
      item = find_item(items, "pathway_bidirectional_gates")

      assert item.status == :fail
      assert "PW1" in item.details
    end

    test "pathway_duplicate_routes warns for duplicate from/to/mode" do
      pw1 = pathway("PW1", "A", "B", 1, true)
      pw2 = pathway("PW2", "A", "B", 1, true)
      items = PathwayChecks.validate([pw1, pw2], stop_index(), %{})
      item = find_item(items, "pathway_duplicate_routes")

      assert item.status == :warn
      assert item.category == :warning
    end

    test "pathway_duplicate_ids fails for duplicate pathway_id" do
      pw1 = pathway("PW1", "A", "B", 1, true)
      pw2 = pathway("PW1", "C", "D", 1, true)
      items = PathwayChecks.validate([pw1, pw2], stop_index(), %{})
      item = find_item(items, "pathway_duplicate_ids")

      assert item.status == :fail
      assert item.category == :error
      assert "PW1" in item.details
    end
  end

  defp pathway(pathway_id, from, to, mode, bidir, attrs \\ []) do
    attrs = Map.new(attrs)

    %Pathway{
      pathway_id: pathway_id,
      from_stop_id: from,
      to_stop_id: to,
      pathway_mode: mode,
      is_bidirectional: bidir,
      traversal_time: Map.get(attrs, :traversal_time),
      length: Map.get(attrs, :length),
      min_width: Map.get(attrs, :min_width),
      max_slope: Map.get(attrs, :max_slope),
      stair_count: Map.get(attrs, :stair_count),
      signposted_as: Map.get(attrs, :signposted_as),
      reversed_signposted_as: Map.get(attrs, :reversed_signposted_as)
    }
  end

  defp stop_index do
    %{
      "A" => %Stop{stop_id: "A"},
      "B" => %Stop{stop_id: "B"},
      "C" => %Stop{stop_id: "C"},
      "D" => %Stop{stop_id: "D"},
      "E" => %Stop{stop_id: "E"},
      "F" => %Stop{stop_id: "F"},
      "G" => %Stop{stop_id: "G"}
    }
  end

  defp find_item(items, id) do
    Enum.find(items, &(&1.id == id))
  end
end
