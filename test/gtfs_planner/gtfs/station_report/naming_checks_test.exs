defmodule GtfsPlanner.Gtfs.StationReport.NamingChecksTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport.NamingChecks
  alias GtfsPlanner.Gtfs.Stop

  describe "validate/2" do
    test "naming_title_case warns for non-title-case stop names" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "main entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :warn
      assert item.category == :convention
      assert [%{id: "E1", reason: "expected \"Main Entrance\""}] = item.details
    end

    test "naming_title_case passes for correctly cased names" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "Main Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :pass
    end

    test "naming_title_case handles minor words correctly" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "gate of the north")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :warn
      assert [%{id: "E1", reason: "expected \"Gate of the North\""}] = item.details
    end

    test "naming_title_case skips stops with nil stop_name" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: nil)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      # Only station is checked, and it passes
      assert item.status == :pass
    end

    test "naming_jargon warns when stop name contains jargon" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("N1", 3, stop_name: "Paid Area Node")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_jargon")

      assert item.status == :warn
      assert item.category == :convention
      assert [%{id: "N1", reason: reason}] = item.details
      assert String.contains?(reason, "paid")
    end

    test "naming_jargon passes when no jargon detected" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("N1", 3, stop_name: "Concourse Level")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_jargon")

      assert item.status == :pass
    end

    test "naming_node_prefix passes for type-3 with node_ prefix" do
      station = stop("STATION", 1)
      child = stop("node_lobby", 3)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_node_prefix")

      assert item.status == :pass
    end

    test "naming_node_prefix warns for type-3 without node_ prefix" do
      station = stop("STATION", 1)
      child = stop("generic_lobby", 3)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_node_prefix")

      assert item.status == :warn
      assert item.category == :convention
      assert "generic_lobby" in item.details
    end

    test "naming_boarding_prefix passes for type-4 with boarding_ prefix" do
      station = stop("STATION", 1)
      child = stop("boarding_a1", 4)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_boarding_prefix")

      assert item.status == :pass
    end

    test "naming_boarding_prefix warns for type-4 without boarding_ prefix" do
      station = stop("STATION", 1)
      child = stop("ba_platform_1", 4)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_boarding_prefix")

      assert item.status == :warn
      assert item.category == :convention
      assert "ba_platform_1" in item.details
    end

    test "empty child_stops returns all passing checks" do
      station = stop("STATION", 1, stop_name: "Station")

      items = NamingChecks.validate(station, [])

      Enum.each(items, fn item ->
        assert item.status == :pass, "Expected #{item.id} to pass"
      end)
    end
  end

  defp stop(stop_id, location_type, attrs \\ []) do
    attrs = Map.new(attrs)

    %Stop{
      stop_id: stop_id,
      stop_name: Map.get(attrs, :stop_name, stop_id),
      location_type: location_type,
      parent_station: Map.get(attrs, :parent_station)
    }
  end

  defp find_item(items, id) do
    Enum.find(items, &(&1.id == id))
  end
end
