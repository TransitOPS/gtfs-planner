defmodule GtfsPlanner.Gtfs.StationReport.GpsChecksTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport.Helpers
  alias GtfsPlanner.Gtfs.StationReport.GpsChecks
  alias GtfsPlanner.Gtfs.Stop

  describe "validate/2" do
    test "positive_longitude fails when child has opposite sign" do
      station = stop("STATION", 1, stop_lat: dec("47.0"), stop_lon: dec("-74.0"))
      child = stop("E1", 2, stop_lat: dec("47.0"), stop_lon: dec("74.0"))

      items = GpsChecks.validate(station, [child])
      item = find_item(items, "positive_longitude")

      assert item.status == :fail
      assert item.category == :error
      assert "E1" in item.details
    end

    test "positive_longitude passes when signs match" do
      station = stop("STATION", 1, stop_lat: dec("47.0"), stop_lon: dec("-74.0"))
      child = stop("E1", 2, stop_lat: dec("47.0"), stop_lon: dec("-74.001"))

      items = GpsChecks.validate(station, [child])
      item = find_item(items, "positive_longitude")

      assert item.status == :pass
    end

    test "entrance_gps_distance fails when entrance is far from station" do
      station = stop("STATION", 1, stop_lat: dec("47.0"), stop_lon: dec("-122.0"))
      # ~1 degree away = ~111km
      entrance = stop("E1", 2, stop_lat: dec("48.0"), stop_lon: dec("-122.0"))

      items = GpsChecks.validate(station, [entrance])
      item = find_item(items, "entrance_gps_distance")

      assert item.status == :fail
      assert item.category == :error
      assert [%{id: "E1", reason: reason}] = item.details
      assert String.contains?(reason, "m from station")
    end

    test "entrance_gps_distance passes when entrance is close" do
      station = stop("STATION", 1, stop_lat: dec("47.0"), stop_lon: dec("-122.0"))
      entrance = stop("E1", 2, stop_lat: dec("47.0001"), stop_lon: dec("-122.0001"))

      items = GpsChecks.validate(station, [entrance])
      item = find_item(items, "entrance_gps_distance")

      assert item.status == :pass
    end

    test "entrance_gps_distance fails when raw distance is just above 500m" do
      station = stop("STATION", 1, stop_lat: dec("0"), stop_lon: dec("0"))
      entrance = stop("E1", 2, stop_lat: dec(lat_for_distance_m(500.04)), stop_lon: dec("0"))

      distance =
        Helpers.haversine(
          station.stop_lat,
          station.stop_lon,
          entrance.stop_lat,
          entrance.stop_lon
        )

      assert distance > 500
      assert Float.round(distance, 1) == 500.0

      items = GpsChecks.validate(station, [entrance])
      item = find_item(items, "entrance_gps_distance")

      assert item.status == :fail
      assert [%{id: "E1", reason: "500.0m from station"}] = item.details
    end

    test "child stops with nil coordinates are skipped" do
      station = stop("STATION", 1, stop_lat: dec("47.0"), stop_lon: dec("-122.0"))
      child = stop("E1", 2, stop_lat: nil, stop_lon: nil)

      items = GpsChecks.validate(station, [child])
      item = find_item(items, "positive_longitude")

      assert item.status == :pass
    end

    test "station with nil coordinates passes all GPS checks" do
      station = stop("STATION", 1, stop_lat: nil, stop_lon: nil)
      child = stop("E1", 2, stop_lat: dec("47.0"), stop_lon: dec("74.0"))

      items = GpsChecks.validate(station, [child])

      Enum.each(items, fn item ->
        assert item.status == :pass
      end)
    end

    test "optional_gps_clustering warns when type-3 node is far" do
      station = stop("STATION", 1, stop_lat: dec("47.0"), stop_lon: dec("-122.0"))
      node = stop("G1", 3, stop_lat: dec("47.01"), stop_lon: dec("-122.0"))

      items = GpsChecks.validate(station, [node])
      item = find_item(items, "optional_gps_clustering")

      assert item.status == :warn
      assert item.category == :warning
      assert [%{id: "G1", reason: _}] = item.details
    end

    test "optional_gps_clustering passes when node is close" do
      station = stop("STATION", 1, stop_lat: dec("47.0"), stop_lon: dec("-122.0"))
      node = stop("G1", 3, stop_lat: dec("47.0001"), stop_lon: dec("-122.0001"))

      items = GpsChecks.validate(station, [node])
      item = find_item(items, "optional_gps_clustering")

      assert item.status == :pass
    end

    test "optional_gps_clustering warns when raw distance is just above 200m" do
      station = stop("STATION", 1, stop_lat: dec("0"), stop_lon: dec("0"))
      node = stop("G1", 3, stop_lat: dec(lat_for_distance_m(200.04)), stop_lon: dec("0"))

      distance =
        Helpers.haversine(station.stop_lat, station.stop_lon, node.stop_lat, node.stop_lon)

      assert distance > 200
      assert Float.round(distance, 1) == 200.0

      items = GpsChecks.validate(station, [node])
      item = find_item(items, "optional_gps_clustering")

      assert item.status == :warn
      assert [%{id: "G1", reason: "200.0m from station"}] = item.details
    end
  end

  defp stop(stop_id, location_type), do: stop(stop_id, location_type, [])

  defp stop(stop_id, location_type, attrs) do
    attrs = Map.new(attrs)

    %Stop{
      stop_id: stop_id,
      stop_name: stop_id,
      location_type: location_type,
      parent_station: Map.get(attrs, :parent_station),
      stop_lat: Map.get(attrs, :stop_lat),
      stop_lon: Map.get(attrs, :stop_lon),
      wheelchair_boarding: Map.get(attrs, :wheelchair_boarding)
    }
  end

  defp dec(value) when is_float(value), do: Decimal.from_float(value)
  defp dec(value), do: Decimal.new(value)

  defp lat_for_distance_m(distance_m) do
    distance_m / 6_371_000.0 * 180.0 / :math.pi()
  end

  defp find_item(items, id) do
    Enum.find(items, &(&1.id == id))
  end
end
