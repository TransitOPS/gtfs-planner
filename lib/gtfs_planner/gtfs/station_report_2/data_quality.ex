defmodule GtfsPlanner.Gtfs.StationReport2.DataQuality do
  @moduledoc """
  Pure builder: snapshot -> list of data quality item maps with rendering metadata.
  """

  alias GtfsPlanner.Gtfs.Graph
  alias GtfsPlanner.Gtfs.StationReport.Helpers

  @spec build(%{station: map(), child_stops: [map()], pathways: [map()]}) :: [map()]
  def build(%{station: station, child_stops: child_stops, pathways: pathways}) do
    stop_index = Map.new([station | child_stops], fn stop -> {stop.stop_id, stop} end)
    node_set = MapSet.new(Enum.map(child_stops, & &1.stop_id))

    core_pathways = Enum.filter(pathways, &pathway_inside_nodes?(&1, node_set))

    undirected = Graph.build_undirected_adjacency(core_pathways)
    directed = Graph.build_directed_adjacency(core_pathways)
    platform_target_index = Graph.build_platform_target_index(child_stops)

    boarding_areas = Enum.filter(child_stops, &(&1.location_type == 4))
    platforms = Enum.filter(child_stops, &(&1.location_type == 0))
    entrances = Enum.filter(child_stops, &(&1.location_type == 2))
    generic_nodes = Enum.filter(child_stops, &(&1.location_type == 3))

    all_platform_targets =
      platform_target_index
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    [
      isolated_nodes_item(child_stops, undirected, stop_index),
      boarding_area_parent_consistency_item(boarding_areas, stop_index),
      station_parent_consistency_item(station, platforms, entrances, generic_nodes, stop_index),
      orphaned_platforms_item(platforms, boarding_areas),
      minimum_station_children_item(entrances, platforms),
      entrance_to_platform_connectivity_item(entrances, all_platform_targets, directed, stop_index),
      platform_interconnection_item(platforms, platform_target_index, directed, stop_index),
      wheelchair_boarding_consistency_item(
        station,
        entrances,
        core_pathways,
        platform_target_index
      ),
      wheelchair_contradicts_context_item(child_stops, stop_index),
      wheelchair_inferrable_item(child_stops, core_pathways, stop_index),
      duplicate_stop_ids_item(station, child_stops, stop_index)
    ]
  end

  # --- Check builders ---

  defp isolated_nodes_item(child_stops, undirected, stop_index) do
    monitored = Enum.filter(child_stops, &(&1.location_type in [2, 3, 4]))

    isolated =
      monitored
      |> Enum.map(& &1.stop_id)
      |> Enum.reject(fn stop_id ->
        neighbors = Map.get(undirected, stop_id, MapSet.new())
        MapSet.size(neighbors) > 0
      end)
      |> Enum.map(&stop_id_entry(&1, stop_index))

    count = length(isolated)

    %{
      id: "isolated_nodes",
      label: "Isolated nodes",
      description:
        "Entrances, generic nodes, and boarding areas (types 2/3/4) disconnected from the station graph",
      status: if(count == 0, do: :pass, else: :fail),
      value: count,
      value_format: :count,
      detail_label: "Show affected stops",
      detail_layout: if(count > 0, do: :stop_ids),
      details: isolated
    }
  end

  defp boarding_area_parent_consistency_item(boarding_areas, stop_index) do
    bad =
      boarding_areas
      |> Enum.filter(fn stop ->
        parent = Map.get(stop_index, stop.parent_station)
        is_nil(parent) or Map.get(parent, :location_type) != 0
      end)
      |> Enum.map(&stop_id_entry(&1.stop_id, stop_index))

    count = length(bad)

    %{
      id: "boarding_area_parent_consistency",
      label: "Boarding areas must have platform parent",
      description: "Boarding areas whose parent_station is not a platform",
      status: if(count == 0, do: :pass, else: :fail),
      value: count,
      value_format: :count,
      detail_label: "Show affected stops",
      detail_layout: if(count > 0, do: :stop_ids),
      details: bad
    }
  end

  defp station_parent_consistency_item(station, platforms, entrances, generic_nodes, stop_index) do
    station_stop_id = station.stop_id

    violations =
      (platforms ++ entrances ++ generic_nodes)
      |> Enum.filter(&(&1.parent_station != station_stop_id))
      |> Enum.map(&stop_id_entry(&1.stop_id, stop_index))

    count = length(violations)

    %{
      id: "station_parent_consistency",
      label: "Parent station assignment",
      description:
        "All platforms, entrances, and generic nodes belong to the correct parent station",
      status: if(count == 0, do: :pass, else: :fail),
      value: count,
      value_format: :count,
      detail_label: "Show affected stops",
      detail_layout: if(count > 0, do: :stop_ids),
      details: violations
    }
  end

  defp orphaned_platforms_item(platforms, boarding_areas) do
    orphaned =
      platforms
      |> Enum.reject(fn platform ->
        Enum.any?(boarding_areas, &(&1.parent_station == platform.stop_id))
      end)
      |> Enum.map(& &1.stop_id)

    %{
      id: "orphaned_platforms",
      label: "Platforms missing boarding areas",
      description:
        "Platforms without boarding-area children \u2014 review recommended for multi-berth platforms",
      status: :info,
      value: length(orphaned),
      value_format: :count,
      detail_label: nil,
      detail_layout: nil,
      details: nil
    }
  end

  defp minimum_station_children_item(entrances, platforms) do
    entrance_count = length(entrances)
    platform_count = length(platforms)
    ok = entrance_count > 0 and platform_count > 0

    %{
      id: "minimum_station_children",
      label: "Minimum station children",
      description:
        "At least 1 entrance and 1 platform required \u2014 #{entrance_count} entrances \u00b7 #{platform_count} platforms found",
      status: if(ok, do: :pass, else: :fail),
      value: ok,
      value_format: :boolean,
      detail_label: nil,
      detail_layout: nil,
      details: nil
    }
  end

  defp entrance_to_platform_connectivity_item(
         entrances,
         all_platform_targets,
         directed,
         stop_index
       ) do
    checked =
      Enum.map(entrances, fn entrance ->
        reachable = Graph.reachable?(entrance.stop_id, all_platform_targets, directed)
        %{stop_id: entrance.stop_id, reachable: reachable}
      end)

    unreachable =
      checked
      |> Enum.reject(& &1.reachable)
      |> Enum.map(&stop_id_entry(&1.stop_id, stop_index))

    reachable_count = length(checked) - length(unreachable)
    unreachable_count = length(unreachable)

    %{
      id: "entrance_to_platform_connectivity",
      label: "Entrance-to-platform reachability",
      description: "Entrances with no pathway to any platform",
      status: if(unreachable_count == 0, do: :pass, else: :fail),
      value: %{unreachable: unreachable_count, reachable: reachable_count},
      value_format: :compound,
      detail_label: "Show unreachable entrances",
      detail_layout: if(unreachable_count > 0, do: :stop_ids_with_dots),
      details: unreachable
    }
  end

  defp platform_interconnection_item(platforms, platform_target_index, directed, stop_index) do
    checked =
      Enum.map(platforms, fn platform ->
        other_targets =
          platform_target_index
          |> Map.delete(platform.stop_id)
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        own_targets =
          Map.get(platform_target_index, platform.stop_id, MapSet.new([platform.stop_id]))

        connected =
          if MapSet.size(other_targets) == 0 do
            true
          else
            Enum.any?(own_targets, fn start_id ->
              Graph.reachable?(start_id, other_targets, directed)
            end)
          end

        %{stop_id: platform.stop_id, connected: connected}
      end)

    disconnected =
      checked
      |> Enum.reject(& &1.connected)
      |> Enum.map(&stop_id_entry(&1.stop_id, stop_index))

    connected_count = length(checked) - length(disconnected)
    disconnected_count = length(disconnected)

    %{
      id: "platform_interconnection",
      label: "Platform interconnection",
      description:
        "Platforms that cannot be reached from any other platform via pathways",
      status: if(disconnected_count == 0, do: :pass, else: :fail),
      value: %{disconnected: disconnected_count, connected: connected_count},
      value_format: :compound,
      detail_label: "Show disconnected platforms",
      detail_layout: if(disconnected_count > 0, do: :stop_ids_with_dots),
      details: disconnected
    }
  end

  defp wheelchair_boarding_consistency_item(
         station,
         entrances,
         pathways,
         platform_target_index
       ) do
    wheelchair_val = station.wheelchair_boarding

    cond do
      wheelchair_val != 1 ->
        %{
          id: "wheelchair_boarding_consistency",
          label: "Wheelchair boarding consistency",
          description:
            "No wheelchair-accessible pathway exists between any entrance and platform",
          status: :pass,
          value: "Not applicable",
          value_format: :text,
          detail_label: nil,
          detail_layout: nil,
          details: nil
        }

      entrances == [] or map_size(platform_target_index) == 0 ->
        %{
          id: "wheelchair_boarding_consistency",
          label: "Wheelchair boarding consistency",
          description:
            "No wheelchair-accessible pathway exists between any entrance and platform",
          status: :fail,
          value: "No entrances or platforms",
          value_format: :text,
          detail_label: nil,
          detail_layout: nil,
          details: nil
        }

      true ->
        accessible_directed =
          pathways
          |> Enum.filter(
            &(&1.pathway_mode in [1, 3, 5, 6, 7])
          )
          |> Graph.build_directed_adjacency()

        all_targets =
          platform_target_index
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        has_accessible_path =
          Enum.any?(entrances, fn entrance ->
            Graph.reachable?(entrance.stop_id, all_targets, accessible_directed)
          end)

        %{
          id: "wheelchair_boarding_consistency",
          label: "Wheelchair boarding consistency",
          description:
            "No wheelchair-accessible pathway exists between any entrance and platform",
          status: if(has_accessible_path, do: :pass, else: :fail),
          value:
            if(has_accessible_path, do: "Accessible path exists", else: "No accessible path"),
          value_format: :text,
          detail_label: nil,
          detail_layout: nil,
          details: nil
        }
    end
  end

  defp wheelchair_contradicts_context_item(child_stops, _stop_index) do
    by_level =
      child_stops
      |> Enum.filter(&Helpers.present?(&1.level_id))
      |> Enum.group_by(& &1.level_id)

    flagged =
      Enum.flat_map(by_level, fn {_level_id, siblings} ->
        with_value = Enum.filter(siblings, &(&1.wheelchair_boarding in [1, 2]))

        if length(with_value) >= 2 do
          accessible_count = Enum.count(with_value, &(&1.wheelchair_boarding == 1))
          ratio = accessible_count / length(with_value)

          if ratio > 0.5 do
            with_value
            |> Enum.filter(&(&1.wheelchair_boarding == 2))
            |> Enum.map(fn stop ->
              pct = round(ratio * 100)

              %{
                id: stop.stop_id,
                name: stop_display_name(stop, stop.stop_id),
                reason:
                  "marked not-accessible but #{pct}% of level siblings are accessible"
              }
            end)
          else
            []
          end
        else
          []
        end
      end)

    count = length(flagged)

    %{
      id: "wheelchair_contradicts_context",
      label: "Inaccessible stops consistent with siblings",
      description: "Stops marked wheelchair_boarding=2 where accessible siblings exist",
      status: if(count == 0, do: :pass, else: :warn),
      value: count,
      value_format: :count,
      detail_label: "Show affected stops",
      detail_layout: if(count > 0, do: :stop_ids_with_reasons),
      details: flagged
    }
  end

  defp wheelchair_inferrable_item(child_stops, pathways, stop_index) do
    connected_modes =
      Enum.reduce(pathways, %{}, fn pw, acc ->
        mode = normalize_pathway_mode(pw.pathway_mode)

        acc
        |> Map.update(pw.from_stop_id, MapSet.new([mode]), &MapSet.put(&1, mode))
        |> Map.update(pw.to_stop_id, MapSet.new([mode]), &MapSet.put(&1, mode))
      end)

    flagged =
      child_stops
      |> Enum.filter(&(&1.wheelchair_boarding in [0, nil]))
      |> Enum.flat_map(fn stop ->
        modes = Map.get(connected_modes, stop.stop_id, MapSet.new())
        name = stop_display_name(Map.get(stop_index, stop.stop_id), stop.stop_id)

        cond do
          MapSet.size(modes) == 0 ->
            []

          MapSet.subset?(modes, MapSet.new([2])) ->
            [%{id: stop.stop_id, name: name, reason: "only stairs connected \u2192 suggest 2"}]

          MapSet.member?(modes, 5) ->
            [%{id: stop.stop_id, name: name, reason: "elevator connected \u2192 suggest 1"}]

          true ->
            []
        end
      end)

    count = length(flagged)

    %{
      id: "wheelchair_inferrable",
      label: "Wheelchair boarding determinable from pathways",
      description:
        "Stops where wheelchair_boarding can be inferred from connected pathway types",
      status: if(count == 0, do: :pass, else: :warn),
      value: count,
      value_format: :count,
      detail_label: "Show suggestions",
      detail_layout: if(count > 0, do: :stop_ids_with_reasons),
      details: flagged
    }
  end

  defp duplicate_stop_ids_item(station, child_stops, stop_index) do
    all_stops = [station | child_stops]

    duplicates =
      all_stops
      |> Enum.group_by(& &1.stop_id)
      |> Enum.filter(fn {_id, group} -> length(group) > 1 end)
      |> Enum.map(fn {id, _group} -> stop_id_entry(id, stop_index) end)

    count = length(duplicates)

    %{
      id: "duplicate_stop_ids",
      label: "Unique stop IDs",
      description: "All stop_id values are unique across the station",
      status: if(count == 0, do: :pass, else: :fail),
      value: count,
      value_format: :count,
      detail_label: "Show affected stops",
      detail_layout: if(count > 0, do: :stop_ids),
      details: duplicates
    }
  end

  # --- Name resolution helpers ---

  defp stop_id_entry(id, stop_index) do
    %{id: id, name: stop_display_name(Map.get(stop_index, id), id)}
  end

  defp stop_display_name(%{stop_name: name}, _id) when is_binary(name) and name != "", do: name
  defp stop_display_name(_stop_or_nil, id), do: id

  defp pathway_inside_nodes?(pathway, node_set) do
    MapSet.member?(node_set, pathway.from_stop_id) and
      MapSet.member?(node_set, pathway.to_stop_id)
  end

  defp normalize_pathway_mode(pathway_mode) when is_integer(pathway_mode), do: pathway_mode
  defp normalize_pathway_mode(_), do: -1
end
