defmodule GtfsPlanner.Gtfs.StationReport2.GpsChecks do
  @moduledoc """
  GPS coordinate validation checks for station report.

  Validates coordinate plausibility: sign consistency, entrance distance
  from station, and node clustering.
  """

  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  @entrance_distance_threshold_m 500
  @clustering_distance_threshold_m 200

  @doc """
  Returns GPS validation items for a station and its child stops.
  """
  @spec validate(map(), [map()]) :: [map()]
  def validate(station, child_stops) do
    station_lat = Helpers.decimal_to_float(station.stop_lat)
    station_lon = Helpers.decimal_to_float(station.stop_lon)

    [
      positive_longitude_check(station_lon, child_stops),
      entrance_gps_distance_check(station_lat, station_lon, child_stops),
      optional_gps_clustering_check(station_lat, station_lon, child_stops)
    ]
  end

  defp positive_longitude_check(nil, _child_stops) do
    Helpers.item(
      "positive_longitude",
      "Longitude sign consistency with station",
      :pass,
      :error,
      0
    )
  end

  defp positive_longitude_check(station_lon, child_stops) do
    flagged =
      child_stops
      |> Enum.filter(fn stop ->
        child_lon = Helpers.decimal_to_float(stop.stop_lon)
        child_lon != nil and signs_differ?(station_lon, child_lon)
      end)
      |> Enum.map(& &1.stop_id)

    Helpers.item(
      "positive_longitude",
      "Longitude sign consistency with station",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  defp entrance_gps_distance_check(nil, _station_lon, _child_stops) do
    Helpers.item(
      "entrance_gps_distance",
      "Entrance GPS distance from station",
      :pass,
      :error,
      0
    )
  end

  defp entrance_gps_distance_check(_station_lat, nil, _child_stops) do
    Helpers.item(
      "entrance_gps_distance",
      "Entrance GPS distance from station",
      :pass,
      :error,
      0
    )
  end

  defp entrance_gps_distance_check(station_lat, station_lon, child_stops) do
    entrances = Enum.filter(child_stops, &(&1.location_type == 2))

    flagged =
      entrances
      |> Enum.filter(fn stop ->
        child_lat = Helpers.decimal_to_float(stop.stop_lat)
        child_lon = Helpers.decimal_to_float(stop.stop_lon)
        child_lat != nil and child_lon != nil
      end)
      |> Enum.map(fn stop ->
        child_lat = Helpers.decimal_to_float(stop.stop_lat)
        child_lon = Helpers.decimal_to_float(stop.stop_lon)
        distance = Helpers.haversine(station_lat, station_lon, child_lat, child_lon)
        {stop.stop_id, distance}
      end)
      |> Enum.filter(fn {_id, distance} -> distance > @entrance_distance_threshold_m end)
      |> Enum.map(fn {id, distance} ->
        %{id: id, reason: "#{Float.round(distance, 1)}m from station"}
      end)

    Helpers.item(
      "entrance_gps_distance",
      "Entrance GPS distance from station",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  defp optional_gps_clustering_check(nil, _station_lon, _child_stops) do
    Helpers.item(
      "optional_gps_clustering",
      "Optional node GPS clustering",
      :pass,
      :warning,
      0
    )
  end

  defp optional_gps_clustering_check(_station_lat, nil, _child_stops) do
    Helpers.item(
      "optional_gps_clustering",
      "Optional node GPS clustering",
      :pass,
      :warning,
      0
    )
  end

  defp optional_gps_clustering_check(station_lat, station_lon, child_stops) do
    optional_types = MapSet.new([3, 4])

    flagged =
      child_stops
      |> Enum.filter(fn stop ->
        MapSet.member?(optional_types, stop.location_type) and
          Helpers.decimal_to_float(stop.stop_lat) != nil and
          Helpers.decimal_to_float(stop.stop_lon) != nil
      end)
      |> Enum.map(fn stop ->
        child_lat = Helpers.decimal_to_float(stop.stop_lat)
        child_lon = Helpers.decimal_to_float(stop.stop_lon)
        distance = Helpers.haversine(station_lat, station_lon, child_lat, child_lon)
        {stop.stop_id, distance}
      end)
      |> Enum.filter(fn {_id, distance} -> distance > @clustering_distance_threshold_m end)
      |> Enum.map(fn {id, distance} ->
        %{id: id, reason: "#{Float.round(distance, 1)}m from station"}
      end)

    Helpers.item(
      "optional_gps_clustering",
      "Optional node GPS clustering",
      if(flagged == [], do: :pass, else: :warn),
      :warning,
      length(flagged),
      flagged
    )
  end

  defp signs_differ?(a, b) when is_number(a) and is_number(b) do
    (a > 0 and b < 0) or (a < 0 and b > 0)
  end
end
