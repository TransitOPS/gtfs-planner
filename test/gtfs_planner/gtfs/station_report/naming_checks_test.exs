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

    test "naming_title_case preserves acronym-style names" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "ADA Entrance to JFK")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :pass
    end

    test "naming_title_case warns for non-acronym all-caps words" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "WEST entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :warn
      assert [%{id: "E1", reason: "expected \"West Entrance\""}] = item.details
    end

    test "naming_title_case warns for uppercase four-letter words that are not acronyms" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "EXIT Plaza")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :warn
      assert [%{id: "E1", reason: "expected \"Exit Plaza\""}] = item.details
    end

    test "naming_title_case warns for common uppercase words that are not acronyms" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "MAIN Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :warn
      assert [%{id: "E1", reason: "expected \"Main Entrance\""}] = item.details
    end

    test "naming_title_case preserves four-letter acronyms" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "MUNI Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :pass
    end

    test "naming_title_case preserves unlisted four-letter acronyms" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("E1", 2, stop_name: "DART Station")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_title_case")

      assert item.status == :pass
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

    test "naming_jargon matches spaced variants" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("N1", 3, stop_name: "Fare Line Mezzanine Paid")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_jargon")

      assert item.status == :warn
      assert [%{id: "N1", reason: reason}] = item.details
      assert String.contains?(reason, "fare_line")
      assert String.contains?(reason, "mezzanine_paid")
    end

    test "naming_jargon does not match paid inside unpaid" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("N1", 3, stop_name: "Unpaid Area")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_jargon")

      assert item.status == :warn
      assert [%{id: "N1", reason: "contains: unpaid"}] = item.details
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

    # Check 47a: entrance prefix
    test "naming_entrance_prefix passes for type-2 with entrance_ prefix" do
      station = stop("STATION", 1)
      child = stop("entrance_main", 2)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_entrance_prefix")

      assert item.status == :pass
    end

    test "naming_entrance_prefix warns for type-2 without entrance_ prefix" do
      station = stop("STATION", 1)
      child = stop("ent_main", 2)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_entrance_prefix")

      assert item.status == :warn
      assert "ent_main" in item.details
    end

    # Check 47b: prefix type mismatch
    test "naming_prefix_type_mismatch flags node_ prefix on type 2" do
      station = stop("STATION", 1)
      child = stop("node_main_entrance", 2)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_prefix_type_mismatch")

      assert item.status == :warn
      assert [%{id: "node_main_entrance", reason: reason}] = item.details
      assert String.contains?(reason, "node_")
      assert String.contains?(reason, "type 3")
    end

    test "naming_prefix_type_mismatch passes when prefix matches type" do
      station = stop("STATION", 1)
      child = stop("node_lobby", 3)

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_prefix_type_mismatch")

      assert item.status == :pass
    end

    # Check 45: test/placeholder
    test "naming_test_placeholder flags stop_id with test token" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("test_entrance_1", 2, stop_name: "Test Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_test_placeholder")

      assert item.status == :warn
      assert length(item.details) >= 1
    end

    test "naming_test_placeholder passes for normal stop_ids" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_main", 2, stop_name: "Main Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_test_placeholder")

      assert item.status == :pass
    end

    # Check 46: direction mismatch
    test "naming_direction_mismatch flags contradicting directions" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_north", 2, stop_name: "South Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_direction_mismatch")

      assert item.status == :warn
      assert [%{id: "entrance_north", reason: _}] = item.details
    end

    test "naming_direction_mismatch passes when directions agree" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_north", 2, stop_name: "North Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_direction_mismatch")

      assert item.status == :pass
    end

    test "naming_direction_mismatch skips when only one side has directions" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_1", 2, stop_name: "North Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_direction_mismatch")

      assert item.status == :pass
    end

    # Check 50: duplicate id tokens
    test "naming_duplicate_id_tokens flags repeated tokens" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("boarding_boarding_18", 4, stop_name: "Bay 18")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_duplicate_id_tokens")

      assert item.status == :warn
      assert [%{id: "boarding_boarding_18", reason: reason}] = item.details
      assert String.contains?(reason, "boarding")
    end

    test "naming_duplicate_id_tokens passes for unique tokens" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_main_north", 2, stop_name: "Main North")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_duplicate_id_tokens")

      assert item.status == :pass
    end

    # Check 51: autogenerated name
    test "naming_autogenerated_name flags slugified names" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_main_north", 2, stop_name: "entrance main north")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_autogenerated_name")

      assert item.status == :warn
      assert [%{id: "entrance_main_north", reason: _}] = item.details
    end

    test "naming_autogenerated_name passes for humanized names" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_main_north", 2, stop_name: "Main North Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_autogenerated_name")

      assert item.status == :pass
    end

    # Check 49: parent name consistency
    test "naming_parent_name_consistency flags when no shared tokens" do
      station = stop("STATION", 1, stop_name: "Union Station")
      child = stop("entrance_cherry", 2, stop_name: "Cherry Street Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_parent_name_consistency")

      assert item.status == :warn
      assert [%{id: "entrance_cherry", reason: reason}] = item.details
      assert String.contains?(reason, "Union Station")
    end

    test "naming_parent_name_consistency passes when tokens overlap" do
      station = stop("STATION", 1, stop_name: "Union Station")
      child = stop("entrance_union_north", 2, stop_name: "Union North Entrance")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_parent_name_consistency")

      assert item.status == :pass
    end

    test "naming_parent_name_consistency skips type-3 nodes" do
      station = stop("STATION", 1, stop_name: "Union Station")
      child = stop("node_mezzanine", 3, stop_name: "Mezzanine Level")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_parent_name_consistency")

      assert item.status == :pass
    end

    # Check 42: typo detection
    test "naming_stop_id_typos flags near-miss tokens" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_mian_north", 2, stop_name: "Main North")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_stop_id_typos")

      assert item.status == :warn
      assert [%{id: "entrance_mian_north", reason: reason}] = item.details
      assert String.contains?(reason, "mian")
      assert String.contains?(reason, "main")
    end

    test "naming_stop_id_typos passes for known tokens" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_main_north", 2, stop_name: "Main North")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_stop_id_typos")

      assert item.status == :pass
    end

    test "naming_stop_id_typos skips short and numeric tokens" do
      station = stop("STATION", 1, stop_name: "Station")
      child = stop("entrance_a_42", 2, stop_name: "Entrance A")

      items = NamingChecks.validate(station, [child])
      item = find_item(items, "naming_stop_id_typos")

      assert item.status == :pass
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
