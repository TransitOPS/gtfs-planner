defmodule GtfsPlanner.Routing.FeedAdapter do
  @moduledoc """
  Pure conversion from application Ecto structs to PathwaysRouter row shapes.
  """

  alias GtfsPlanner.Gtfs.{Pathway, Stop}

  @spec stop_rows([Stop.t()]) :: [map()]
  def stop_rows(stops) do
    Enum.map(stops, fn %Stop{} = stop ->
      %{
        id: stop.stop_id,
        name: stop.stop_name,
        desc: stop.stop_desc,
        stop_lat: stop.stop_lat,
        stop_lon: stop.stop_lon,
        location_type: stop.location_type,
        wheelchair_boarding: stop.wheelchair_boarding,
        parent_station: stop.parent_station,
        level_id: stop.level_id
      }
    end)
  end

  @spec pathway_rows([Pathway.t()]) :: [map()]
  def pathway_rows(pathways) do
    Enum.map(pathways, fn %Pathway{} = pw ->
      %{
        pathway_id: pw.pathway_id,
        pathway_mode: pw.pathway_mode,
        from_stop_id: pw.from_stop_id,
        to_stop_id: pw.to_stop_id,
        is_bidirectional: if(pw.is_bidirectional, do: 1, else: 0),
        traversal_time: pw.traversal_time,
        length: pw.length,
        stair_count: pw.stair_count,
        max_slope: pw.max_slope,
        signposted_as: pw.signposted_as,
        reversed_signposted_as: pw.reversed_signposted_as
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
