defmodule GtfsPlanner.Gtfs.StationReport2.GpsTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport2.Gps

  @required_keys ~w(id label description status value value_format detail_label detail_layout details)a

  defp make_station(attrs \\ %{}) do
    Map.merge(
      %{
        stop_id: "STATION_1",
        stop_name: "Test Station",
        location_type: 1,
        parent_station: nil,
        wheelchair_boarding: nil,
        level_id: nil,
        stop_lat: Decimal.new("40.0"),
        stop_lon: Decimal.new("-74.0")
      },
      attrs
    )
  end

  defp make_stop(attrs) do
    Map.merge(
      %{
        stop_name: "Stop",
        wheelchair_boarding: nil,
        level_id: nil,
        stop_lat: Decimal.new("40.0"),
        stop_lon: Decimal.new("-74.0")
      },
      attrs
    )
  end

  describe "build/1" do
    test "returns exactly 4 items with all required keys" do
      items = Gps.build(%{station: make_station(), child_stops: []})

      assert length(items) == 4

      Enum.each(items, fn item ->
        Enum.each(@required_keys, fn key ->
          assert Map.has_key?(item, key), "Missing key #{key} in item #{item.id}"
        end)
      end)
    end

    test "items are in the correct order" do
      items = Gps.build(%{station: make_station(), child_stops: []})
      ids = Enum.map(items, & &1.id)

      assert ids == [
               "gps_presence_by_type",
               "positive_longitude",
               "entrance_gps_distance",
               "optional_gps_clustering"
             ]
    end

    test "station with all GPS present passes gps_presence_by_type" do
      platform =
        make_stop(%{
          stop_id: "PLAT_1",
          location_type: 0,
          parent_station: "STATION_1"
        })

      items = Gps.build(%{station: make_station(), child_stops: [platform]})
      check = Enum.find(items, &(&1.id == "gps_presence_by_type"))

      assert check.status == :pass
      assert check.detail_layout == :table
      assert is_list(check.details)

      # Station type row
      station_row = Enum.find(check.details, &(&1.type == 1))
      assert station_row.present == 1
      assert station_row.missing == 0
    end

    test "station with nil lat/lon passes GPS checks with 0 counts" do
      station = make_station(%{stop_lat: nil, stop_lon: nil})
      items = Gps.build(%{station: station, child_stops: []})

      lon_check = Enum.find(items, &(&1.id == "positive_longitude"))
      assert lon_check.status == :pass
      assert lon_check.value == 0

      dist_check = Enum.find(items, &(&1.id == "entrance_gps_distance"))
      assert dist_check.status == :pass
      assert dist_check.value == 0
    end

    test "child with opposite longitude sign fails positive_longitude with enriched details" do
      entrance =
        make_stop(%{
          stop_id: "ENT_1",
          stop_name: "Main Entrance",
          location_type: 2,
          parent_station: "STATION_1",
          stop_lon: Decimal.new("74.0")
        })

      items = Gps.build(%{station: make_station(), child_stops: [entrance]})
      check = Enum.find(items, &(&1.id == "positive_longitude"))

      assert check.status == :fail
      assert check.value == 1
      assert [%{id: "ENT_1", name: "Main Entrance"}] = check.details
    end

    test "entrance far from station fails entrance_gps_distance with enriched details" do
      entrance =
        make_stop(%{
          stop_id: "ENT_1",
          stop_name: "Far Entrance",
          location_type: 2,
          parent_station: "STATION_1",
          stop_lat: Decimal.new("-33.8"),
          stop_lon: Decimal.new("151.2")
        })

      items = Gps.build(%{station: make_station(), child_stops: [entrance]})
      check = Enum.find(items, &(&1.id == "entrance_gps_distance"))

      assert check.status == :fail
      assert check.value == 1
      assert [%{id: "ENT_1", name: "Far Entrance", reason: reason}] = check.details
      assert is_binary(reason)
    end

    test "empty stop_name falls back to stop_id in enriched details" do
      entrance =
        make_stop(%{
          stop_id: "ENT_1",
          stop_name: "",
          location_type: 2,
          parent_station: "STATION_1",
          stop_lon: Decimal.new("74.0")
        })

      items = Gps.build(%{station: make_station(), child_stops: [entrance]})
      check = Enum.find(items, &(&1.id == "positive_longitude"))

      assert [%{id: "ENT_1", name: "ENT_1"}] = check.details
    end

    test "gps_presence_by_type table details have correct structure" do
      items = Gps.build(%{station: make_station(), child_stops: []})
      check = Enum.find(items, &(&1.id == "gps_presence_by_type"))

      Enum.each(check.details, fn row ->
        assert Map.has_key?(row, :type)
        assert Map.has_key?(row, :type_label)
        assert Map.has_key?(row, :present)
        assert Map.has_key?(row, :missing)
        assert Map.has_key?(row, :required)
      end)
    end
  end
end
