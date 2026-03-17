defmodule GtfsPlanner.Gtfs.StationReport.LevelChecksTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport.LevelChecks
  alias GtfsPlanner.Gtfs.{Level, Stop}

  describe "validate/2" do
    test "level_referential_integrity fails when stop references missing level" do
      child_stops = [stop("P1", 0, level_id: "L_UNKNOWN")]
      levels = [%{level: level("L1", 0.0), stop_count: 0}]

      items = LevelChecks.validate(child_stops, levels)
      item = find_item(items, "level_referential_integrity")

      assert item.status == :fail
      assert item.category == :error
      assert Enum.any?(item.details, &(&1.id == "L_UNKNOWN" and &1.reason =~ "missing"))
    end

    test "level_referential_integrity warns for orphan level" do
      child_stops = [stop("P1", 0, level_id: "L1")]

      levels = [
        %{level: level("L1", 0.0), stop_count: 1},
        %{level: level("L_UNUSED", 1.0), stop_count: 0}
      ]

      items = LevelChecks.validate(child_stops, levels)
      item = find_item(items, "level_referential_integrity")

      assert item.status == :warn
      assert item.category == :warning
      assert Enum.any?(item.details, &(&1.id == "L_UNUSED" and &1.reason == "orphan"))
    end

    test "level_referential_integrity passes when all match" do
      child_stops = [stop("P1", 0, level_id: "L1")]
      levels = [%{level: level("L1", 0.0), stop_count: 1}]

      items = LevelChecks.validate(child_stops, levels)
      item = find_item(items, "level_referential_integrity")

      assert item.status == :pass
    end

    test "platforms_missing_level warns for platform with nil level_id" do
      child_stops = [stop("P1", 0, level_id: nil)]

      items = LevelChecks.validate(child_stops, [])
      item = find_item(items, "platforms_missing_level")

      assert item.status == :warn
      assert item.category == :warning
      assert "P1" in item.details
    end

    test "platforms_missing_level passes when platform has level_id" do
      child_stops = [stop("P1", 0, level_id: "L1")]

      items = LevelChecks.validate(child_stops, [])
      item = find_item(items, "platforms_missing_level")

      assert item.status == :pass
    end

    test "level_naming_consistency warns for inconsistent naming" do
      levels = [%{level: level("GROUND_LEVEL", 0.0, "Ground"), stop_count: 1}]

      items = LevelChecks.validate([], levels)
      item = find_item(items, "level_naming_consistency")

      assert item.status == :warn
      assert item.category == :convention
    end

    test "level_naming_consistency passes when naming is consistent" do
      levels = [%{level: level("GROUND_LEVEL", 0.0, "Ground Level"), stop_count: 1}]

      items = LevelChecks.validate([], levels)
      item = find_item(items, "level_naming_consistency")

      assert item.status == :pass
    end

    test "empty levels and no level_ids on stops produces all passing" do
      items = LevelChecks.validate([], [])

      Enum.each(items, fn item ->
        assert item.status == :pass, "Expected #{item.id} to pass"
      end)
    end
  end

  defp stop(stop_id, location_type, attrs \\ []) do
    attrs = Map.new(attrs)

    %Stop{
      stop_id: stop_id,
      stop_name: stop_id,
      location_type: location_type,
      parent_station: Map.get(attrs, :parent_station),
      level_id: Map.get(attrs, :level_id)
    }
  end

  defp level(level_id, level_index, level_name \\ nil) do
    %Level{level_id: level_id, level_index: level_index, level_name: level_name}
  end

  defp find_item(items, id) do
    Enum.find(items, &(&1.id == id))
  end
end
