defmodule GtfsPlanner.Routing.FeedAdapter do
  @moduledoc """
  Pure conversion from application Ecto structs to PathwaysRouter row shapes.
  """

  @spec stop_rows([map()]) :: [map()]
  def stop_rows(stops) do
    Enum.map(stops, fn stop ->
      %{
        id: stop.stop_id,
        name: stop.stop_name,
        desc: Map.get(stop, :stop_desc),
        stop_lat: stop.stop_lat,
        stop_lon: stop.stop_lon,
        location_type: Map.get(stop, :location_type, 0),
        wheelchair_boarding: Map.get(stop, :wheelchair_boarding),
        parent_station: Map.get(stop, :parent_station),
        level_id: Map.get(stop, :level_id)
      }
    end)
  end

  @spec pathway_rows([map()]) :: [map()]
  def pathway_rows(pathways) do
    Enum.map(pathways, fn pw ->
      %{
        pathway_id: pw.pathway_id,
        pathway_mode: pw.pathway_mode,
        from_stop_id: pw.from_stop_id,
        to_stop_id: pw.to_stop_id,
        is_bidirectional: if(pw.is_bidirectional, do: 1, else: 0),
        traversal_time: Map.get(pw, :traversal_time),
        length: Map.get(pw, :length),
        stair_count: Map.get(pw, :stair_count),
        max_slope: Map.get(pw, :max_slope),
        signposted_as: Map.get(pw, :signposted_as),
        reversed_signposted_as: Map.get(pw, :reversed_signposted_as)
      }
    end)
  end

  @spec level_rows([map()]) :: [map()]
  def level_rows(station_levels) do
    Enum.map(station_levels, fn %{level: level} ->
      %{
        level_id: level.level_id,
        level_index: level.level_index,
        level_name: level.level_name
      }
    end)
  end
end
