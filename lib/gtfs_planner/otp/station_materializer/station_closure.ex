defmodule GtfsPlanner.Otp.StationMaterializer.StationClosure do
  @moduledoc """
  Pure station-closure derivation for station-scoped GTFS slicing.

  Derives `kept_stop_ids` from `station_stop_id` by including:

  - the station stop id
  - direct children where `parent_station == station_stop_id`
  - boarding areas (`location_type == 4`) whose `parent_station`
    references a kept platform (`location_type == 0` direct child)
  """

  @type stop_row :: map()

  @spec derive_kept_stop_ids([stop_row()], String.t()) :: [String.t()]
  def derive_kept_stop_ids(stops, station_stop_id)
      when is_list(stops) and is_binary(station_stop_id) do
    direct_children =
      Enum.filter(stops, fn stop -> stop_parent_station(stop) == station_stop_id end)

    direct_child_ids =
      direct_children
      |> Enum.map(&stop_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    kept_platform_ids =
      direct_children
      |> Enum.filter(&(stop_location_type(&1) == 0))
      |> Enum.map(&stop_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    boarding_area_ids =
      stops
      |> Enum.filter(fn stop ->
        stop_location_type(stop) == 4 and MapSet.member?(kept_platform_ids, stop_parent_station(stop))
      end)
      |> Enum.map(&stop_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    station_stop_id
    |> List.wrap()
    |> MapSet.new()
    |> MapSet.union(direct_child_ids)
    |> MapSet.union(boarding_area_ids)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @spec validate_station_prerequisites([stop_row()], String.t()) ::
          {:ok, stop_row()} | {:error, [map()]}
  def validate_station_prerequisites(stops, station_stop_id)
      when is_list(stops) and is_binary(station_stop_id) do
    matching_rows = Enum.filter(stops, &(stop_id(&1) == station_stop_id))

    case matching_rows do
      [] ->
        {:error, [station_stop_not_found_issue(station_stop_id)]}

      [station_row] ->
        if stop_location_type(station_row) == 1 do
          {:ok, station_row}
        else
          {:error,
           [
             station_stop_invalid_type_issue(
               station_stop_id,
               stop_location_type(station_row)
             )
           ]}
        end

      rows ->
        {:error, [station_stop_duplicated_issue(station_stop_id, length(rows))]}
    end
  end

  defp stop_id(%{values: values}) when is_map(values), do: map_get(values, "stop_id")
  defp stop_id(stop) when is_map(stop), do: map_get(stop, "stop_id")

  defp stop_parent_station(%{values: values}) when is_map(values),
    do: map_get(values, "parent_station")

  defp stop_parent_station(stop) when is_map(stop), do: map_get(stop, "parent_station")

  defp stop_location_type(%{values: values}) when is_map(values),
    do: map_get(values, "location_type") |> parse_int()

  defp stop_location_type(stop) when is_map(stop), do: map_get(stop, "location_type") |> parse_int()

  defp map_get(map, "stop_id"), do: Map.get(map, "stop_id") || Map.get(map, :stop_id)
  defp map_get(map, "parent_station"), do: Map.get(map, "parent_station") || Map.get(map, :parent_station)
  defp map_get(map, "location_type"), do: Map.get(map, "location_type") || Map.get(map, :location_type)

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp station_stop_not_found_issue(station_stop_id) do
    %{
      code: :station_stop_not_found,
      severity: :blocking,
      message: "Station stop_id was not found in stops.txt",
      context: %{station_stop_id: station_stop_id}
    }
  end

  defp station_stop_duplicated_issue(station_stop_id, row_count) do
    %{
      code: :station_stop_duplicated,
      severity: :blocking,
      message: "Station stop_id is duplicated in stops.txt",
      context: %{station_stop_id: station_stop_id, row_count: row_count}
    }
  end

  defp station_stop_invalid_type_issue(station_stop_id, location_type) do
    %{
      code: :station_stop_invalid_type,
      severity: :blocking,
      message: "Station stop_id must have location_type=1 in stops.txt",
      context: %{station_stop_id: station_stop_id, location_type: location_type}
    }
  end
end
