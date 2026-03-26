defmodule GtfsPlanner.Gtfs.StationReport2.Gps do
  @moduledoc """
  Pure builder: snapshot -> list of GPS item maps with rendering metadata.

  Reuses `GpsChecks.validate/2` for 3 of 4 items, builds GPS presence table separately.
  """

  alias GtfsPlanner.Gtfs.StationReport.GpsChecks

  @type_labels %{
    0 => "Stop / Platform",
    1 => "Station",
    2 => "Entrance / Exit",
    3 => "Generic Node",
    4 => "Boarding Area"
  }

  @type_order [0, 1, 2, 3, 4]

  # Types 0, 1, 2 are required to have GPS coordinates
  @required_types MapSet.new([0, 1, 2])

  @spec build(%{station: map(), child_stops: [map()]}) :: [map()]
  def build(%{station: station, child_stops: child_stops}) do
    stop_index = Map.new([station | child_stops], fn stop -> {stop.stop_id, stop} end)

    [
      gps_presence_by_type_item(station, child_stops)
      | wrap_gps_checks(GpsChecks.validate(station, child_stops), stop_index)
    ]
  end

  defp gps_presence_by_type_item(station, child_stops) do
    stops = [station | child_stops]
    grouped = Enum.group_by(stops, &normalize_location_type(&1.location_type))

    table_rows =
      @type_order
      |> Enum.filter(&Map.has_key?(grouped, &1))
      |> Enum.map(fn type ->
        type_stops = Map.get(grouped, type, [])
        present = Enum.count(type_stops, &has_coordinates?/1)
        missing = length(type_stops) - present

        %{
          type: type,
          type_label: Map.get(@type_labels, type, "Unknown (#{type})"),
          present: present,
          missing: missing,
          required: MapSet.member?(@required_types, type)
        }
      end)

    required_missing =
      table_rows
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.missing)
      |> Enum.sum()

    %{
      id: "gps_presence_by_type",
      label: "GPS presence by location type",
      description:
        "Stops, stations, and entrances all have coordinates \u2014 nodes and boarding areas use inherited positioning",
      status: if(required_missing == 0, do: :pass, else: :fail),
      value: nil,
      value_format: :count,
      detail_label: nil,
      detail_layout: :table,
      details: table_rows
    }
  end

  defp wrap_gps_checks(items, stop_index) do
    Enum.map(items, fn item ->
      {description, detail_label, _base_layout} = metadata_for(item.id)

      %{
        id: item.id,
        label: label_for(item.id),
        description: description,
        status: item.status,
        value: item.value,
        value_format: :count,
        detail_label: detail_label,
        detail_layout: detail_layout_for(item),
        details: enrich_details(item.details, stop_index)
      }
    end)
  end

  defp enrich_details(nil, _stop_index), do: nil
  defp enrich_details([], _stop_index), do: []

  defp enrich_details([%{id: _, reason: _} | _] = details, stop_index) do
    Enum.map(details, fn %{id: id, reason: reason} ->
      %{id: id, name: stop_display_name(stop_index, id), reason: reason}
    end)
  end

  defp enrich_details([id | _] = details, stop_index) when is_binary(id) do
    Enum.map(details, fn id ->
      %{id: id, name: stop_display_name(stop_index, id)}
    end)
  end

  defp stop_display_name(stop_index, id) do
    case Map.get(stop_index, id) do
      %{stop_name: name} when is_binary(name) and name != "" -> name
      _ -> id
    end
  end

  defp label_for("positive_longitude"), do: "Longitude sign consistency"
  defp label_for("entrance_gps_distance"), do: "Entrance distance from station"
  defp label_for("optional_gps_clustering"), do: "Node GPS clustering"

  defp metadata_for("positive_longitude") do
    {"Stops with a longitude sign that does not match the station", "Show affected stops",
     :stop_ids}
  end

  defp metadata_for("entrance_gps_distance") do
    {"Entrances positioned more than 500m from the station", "Show distances",
     :stop_ids_with_reasons}
  end

  defp metadata_for("optional_gps_clustering") do
    {"Nodes with coordinates that cluster unusually far from their neighbors",
     "Show affected stops", :stop_ids_with_reasons}
  end

  defp detail_layout_for(%{details: nil}), do: nil
  defp detail_layout_for(%{details: []}), do: nil

  defp detail_layout_for(%{id: id}) do
    case id do
      "positive_longitude" -> :stop_ids
      "entrance_gps_distance" -> :stop_ids_with_reasons
      "optional_gps_clustering" -> :stop_ids_with_reasons
    end
  end

  defp has_coordinates?(stop) do
    not is_nil(stop.stop_lat) and not is_nil(stop.stop_lon)
  end

  defp normalize_location_type(location_type) when is_integer(location_type), do: location_type
  defp normalize_location_type(_), do: -1
end
