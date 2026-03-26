defmodule GtfsPlanner.Gtfs.StationReport2.DataQuality do
  @moduledoc """
  Pure builder: snapshot -> list of data quality item maps with rendering metadata.

  Duplicates graph/BFS logic from StationReport to avoid coupling with the legacy report.
  """

  alias GtfsPlanner.Gtfs.StationReport.Helpers

  @step_free_modes MapSet.new([1, 3, 5, 6, 7])

  @spec build(%{station: map(), child_stops: [map()], pathways: [map()]}) :: [map()]
  def build(%{station: station, child_stops: child_stops, pathways: pathways}) do
    stop_index = Map.new([station | child_stops], fn stop -> {stop.stop_id, stop} end)
    node_set = MapSet.new(Enum.map(child_stops, & &1.stop_id))

    core_pathways = Enum.filter(pathways, &pathway_inside_nodes?(&1, node_set))

    undirected = build_undirected_adjacency(core_pathways)
    directed = build_directed_adjacency(core_pathways)
    platform_target_index = build_platform_target_index(child_stops)

    boarding_areas = Enum.filter(child_stops, &(&1.location_type == 4))
    platforms = Enum.filter(child_stops, &(&1.location_type == 0))
    entrances = Enum.filter(child_stops, &(&1.location_type == 2))
    generic_nodes = Enum.filter(child_stops, &(&1.location_type == 3))

    all_platform_targets =
      platform_target_index
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    [
      isolated_nodes_item(child_stops, undirected),
      boarding_area_parent_consistency_item(boarding_areas, stop_index),
      station_parent_consistency_item(station, platforms, entrances, generic_nodes),
      orphaned_platforms_item(platforms, boarding_areas),
      minimum_station_children_item(entrances, platforms),
      entrance_to_platform_connectivity_item(entrances, all_platform_targets, directed),
      platform_interconnection_item(platforms, platform_target_index, directed),
      wheelchair_boarding_consistency_item(
        station,
        entrances,
        core_pathways,
        platform_target_index
      ),
      wheelchair_contradicts_context_item(child_stops),
      wheelchair_inferrable_item(child_stops, core_pathways),
      duplicate_stop_ids_item(station, child_stops)
    ]
  end

  # --- Check builders ---

  defp isolated_nodes_item(child_stops, undirected) do
    monitored = Enum.filter(child_stops, &(&1.location_type in [2, 3, 4]))

    isolated_ids =
      monitored
      |> Enum.map(& &1.stop_id)
      |> Enum.reject(fn stop_id ->
        neighbors = Map.get(undirected, stop_id, MapSet.new())
        MapSet.size(neighbors) > 0
      end)

    count = length(isolated_ids)

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
      details: isolated_ids
    }
  end

  defp boarding_area_parent_consistency_item(boarding_areas, stop_index) do
    bad =
      boarding_areas
      |> Enum.filter(fn stop ->
        parent = Map.get(stop_index, stop.parent_station)
        is_nil(parent) or Map.get(parent, :location_type) != 0
      end)
      |> Enum.map(& &1.stop_id)

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

  defp station_parent_consistency_item(station, platforms, entrances, generic_nodes) do
    station_stop_id = station.stop_id

    violations =
      (platforms ++ entrances ++ generic_nodes)
      |> Enum.filter(&(&1.parent_station != station_stop_id))
      |> Enum.map(& &1.stop_id)

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

  defp entrance_to_platform_connectivity_item(entrances, all_platform_targets, directed) do
    details =
      Enum.map(entrances, fn entrance ->
        reachable = reachable?(entrance.stop_id, all_platform_targets, directed)
        %{stop_id: entrance.stop_id, reachable: reachable}
      end)

    unreachable = details |> Enum.reject(& &1.reachable) |> Enum.map(& &1.stop_id)
    reachable_count = length(details) - length(unreachable)
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

  defp platform_interconnection_item(platforms, platform_target_index, directed) do
    details =
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
              reachable?(start_id, other_targets, directed)
            end)
          end

        %{stop_id: platform.stop_id, connected: connected}
      end)

    disconnected = details |> Enum.reject(& &1.connected) |> Enum.map(& &1.stop_id)
    connected_count = length(details) - length(disconnected)
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
            &MapSet.member?(@step_free_modes, normalize_pathway_mode(&1.pathway_mode))
          )
          |> build_directed_adjacency()

        all_targets =
          platform_target_index
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        has_accessible_path =
          Enum.any?(entrances, fn entrance ->
            reachable?(entrance.stop_id, all_targets, accessible_directed)
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

  defp wheelchair_contradicts_context_item(child_stops) do
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

  defp wheelchair_inferrable_item(child_stops, pathways) do
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

        cond do
          MapSet.size(modes) == 0 ->
            []

          MapSet.subset?(modes, MapSet.new([2])) ->
            [%{id: stop.stop_id, reason: "only stairs connected \u2192 suggest 2"}]

          MapSet.member?(modes, 5) ->
            [%{id: stop.stop_id, reason: "elevator connected \u2192 suggest 1"}]

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

  defp duplicate_stop_ids_item(station, child_stops) do
    all_stops = [station | child_stops]

    duplicates =
      all_stops
      |> Enum.group_by(& &1.stop_id)
      |> Enum.filter(fn {_id, group} -> length(group) > 1 end)
      |> Enum.map(fn {id, _group} -> id end)

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

  # --- Graph utilities (duplicated from StationReport) ---

  defp build_directed_adjacency(pathways) do
    Enum.reduce(pathways, %{}, fn pathway, acc ->
      acc = put_edge(acc, pathway.from_stop_id, pathway.to_stop_id)

      if pathway.is_bidirectional do
        put_edge(acc, pathway.to_stop_id, pathway.from_stop_id)
      else
        acc
      end
    end)
  end

  defp build_undirected_adjacency(pathways) do
    Enum.reduce(pathways, %{}, fn pathway, acc ->
      acc
      |> put_edge(pathway.from_stop_id, pathway.to_stop_id)
      |> put_edge(pathway.to_stop_id, pathway.from_stop_id)
    end)
  end

  defp build_platform_target_index(child_stops) do
    boarding_areas_by_parent =
      child_stops
      |> Enum.filter(&(&1.location_type == 4))
      |> Enum.group_by(& &1.parent_station)

    child_stops
    |> Enum.filter(&(&1.location_type == 0))
    |> Map.new(fn platform ->
      ba_ids =
        boarding_areas_by_parent
        |> Map.get(platform.stop_id, [])
        |> Enum.map(& &1.stop_id)

      {platform.stop_id, MapSet.new([platform.stop_id | ba_ids])}
    end)
  end

  defp reachable?(from_stop_id, target_ids, directed) do
    if MapSet.size(target_ids) == 0 do
      false
    else
      from_stop_id
      |> bfs(directed)
      |> MapSet.intersection(target_ids)
      |> MapSet.size()
      |> Kernel.>(0)
    end
  end

  defp bfs(start, directed) do
    do_bfs(:queue.from_list([start]), MapSet.new([start]), directed)
  end

  defp do_bfs(queue, visited, directed) do
    case :queue.out(queue) do
      {{:value, current}, rest} ->
        neighbors = Map.get(directed, current, MapSet.new())

        {next_queue, next_visited} =
          Enum.reduce(neighbors, {rest, visited}, fn neighbor, {q, v} ->
            if MapSet.member?(v, neighbor) do
              {q, v}
            else
              {:queue.in(neighbor, q), MapSet.put(v, neighbor)}
            end
          end)

        do_bfs(next_queue, next_visited, directed)

      {:empty, _} ->
        visited
    end
  end

  defp put_edge(adjacency, from_stop_id, to_stop_id) do
    Map.update(adjacency, from_stop_id, MapSet.new([to_stop_id]), &MapSet.put(&1, to_stop_id))
  end

  defp pathway_inside_nodes?(pathway, node_set) do
    MapSet.member?(node_set, pathway.from_stop_id) and
      MapSet.member?(node_set, pathway.to_stop_id)
  end

  defp normalize_pathway_mode(pathway_mode) when is_integer(pathway_mode), do: pathway_mode
  defp normalize_pathway_mode(_), do: -1
end
