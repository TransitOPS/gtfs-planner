defmodule GtfsPlanner.Routing.FeedAdapter do
  @moduledoc """
  Pure conversion from application Ecto structs to PathwaysRouter row shapes.
  """

  @doc """
  Gives each stop without coordinates those of its nearest located ancestor.

  GTFS lets a station element omit `stop_lat` and `stop_lon`; the element then
  sits at its parent. PathwaysRouter resolves one level of that, and only when
  the parent is in the same feed, then drops every stop still unlocated along
  with the pathways that touch it. Resolving the whole chain here keeps a
  boarding area under an unlocated platform in the station graph. A stop with
  no located ancestor in `stops` is returned unchanged, so no coordinate is
  invented.
  """
  @spec inherit_coordinates([map()]) :: [map()]
  def inherit_coordinates(stops) do
    by_id = Map.new(stops, &{&1.stop_id, &1})

    Enum.map(stops, fn stop ->
      with false <- located?(stop),
           %{} = ancestor <-
             located_ancestor(Map.get(stop, :parent_station), by_id, MapSet.new([stop.stop_id])) do
        %{stop | stop_lat: ancestor.stop_lat, stop_lon: ancestor.stop_lon}
      else
        _located_or_no_ancestor -> stop
      end
    end)
  end

  # `seen` ends the walk on a parent cycle in malformed data.
  defp located_ancestor(parent_id, by_id, seen) do
    case Map.get(by_id, parent_id) do
      nil ->
        nil

      parent ->
        cond do
          located?(parent) ->
            parent

          MapSet.member?(seen, parent_id) ->
            nil

          true ->
            located_ancestor(Map.get(parent, :parent_station), by_id, MapSet.put(seen, parent_id))
        end
    end
  end

  @doc "Whether a stop records both of its own coordinates."
  @spec located?(map()) :: boolean()
  def located?(stop), do: not is_nil(stop.stop_lat) and not is_nil(stop.stop_lon)

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
