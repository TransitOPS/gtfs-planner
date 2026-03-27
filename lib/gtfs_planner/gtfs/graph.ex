defmodule GtfsPlanner.Gtfs.Graph do
  @moduledoc """
  Pure graph primitives for GTFS pathway networks.

  Provides adjacency builders, BFS traversal, reachability checks,
  shortest path computation, and platform target indexing. No domain
  logic — callers supply stops and pathways, this module returns
  graph structures and traversal results.
  """

  @step_free_modes MapSet.new([1, 3, 5, 6, 7])

  # --- Adjacency builders ---

  @doc """
  Builds a directed adjacency map from pathways.
  Bidirectional pathways produce edges in both directions.
  Returns `%{stop_id => MapSet.t(stop_id)}`.
  """
  def build_directed_adjacency(pathways) do
    Enum.reduce(pathways, %{}, fn pathway, acc ->
      acc = put_edge(acc, pathway.from_stop_id, pathway.to_stop_id)

      if pathway.is_bidirectional do
        put_edge(acc, pathway.to_stop_id, pathway.from_stop_id)
      else
        acc
      end
    end)
  end

  @doc """
  Builds an undirected adjacency map — all pathways treated as bidirectional.
  Returns `%{stop_id => MapSet.t(stop_id)}`.
  """
  def build_undirected_adjacency(pathways) do
    Enum.reduce(pathways, %{}, fn pathway, acc ->
      acc
      |> put_edge(pathway.from_stop_id, pathway.to_stop_id)
      |> put_edge(pathway.to_stop_id, pathway.from_stop_id)
    end)
  end

  @doc """
  Builds a directed adjacency map enriched with pathway metadata.
  Each edge carries `%{to_stop_id, pathway_id, pathway_mode}`.
  Returns `%{stop_id => [edge]}` with edges sorted by `{to_stop_id, pathway_id}`.
  """
  def build_path_traversal_adjacency(pathways) do
    pathways
    |> Enum.reduce(%{}, fn pathway, acc ->
      acc = put_path_edge(acc, pathway.from_stop_id, pathway.to_stop_id, pathway)

      if pathway.is_bidirectional do
        put_path_edge(acc, pathway.to_stop_id, pathway.from_stop_id, pathway)
      else
        acc
      end
    end)
    |> Enum.into(%{}, fn {from_stop_id, edges} ->
      {from_stop_id, Enum.sort_by(edges, &{&1.to_stop_id, &1.pathway_id})}
    end)
  end

  @doc """
  Like `build_path_traversal_adjacency/1` but filtered to step-free modes
  (walkway, moving sidewalk, elevator, fare gate, exit gate).
  """
  def build_step_free_path_traversal_adjacency(pathways) do
    pathways
    |> Enum.filter(&MapSet.member?(@step_free_modes, normalize_pathway_mode(&1.pathway_mode)))
    |> build_path_traversal_adjacency()
  end

  @doc """
  Maps each platform (location_type 0) to a set containing itself
  and all its boarding areas (location_type 4).
  Returns `%{platform_stop_id => MapSet.t(stop_id)}`.
  """
  def build_platform_target_index(child_stops) do
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

  # --- Traversal ---

  @doc """
  BFS from `start_stop_id`. Returns a MapSet of all reachable stop IDs
  (including start).
  """
  def bfs(start_stop_id, directed_adjacency) do
    do_bfs(:queue.from_list([start_stop_id]), MapSet.new([start_stop_id]), directed_adjacency)
  end

  @doc """
  Returns `true` if any member of `target_ids` is reachable from
  `from_stop_id` via BFS on the directed adjacency.
  """
  def reachable?(from_stop_id, target_ids, directed_adjacency) do
    if MapSet.size(target_ids) == 0 do
      false
    else
      do_reachable?(
        :queue.from_list([from_stop_id]),
        MapSet.new([from_stop_id]),
        target_ids,
        directed_adjacency
      )
    end
  end

  @doc """
  Finds the shortest directed path from `start_stop_id` to any member
  of `target_ids` using BFS on the path-traversal adjacency.

  Returns `{:found, [hop]}` where each hop is
  `%{stop_id, pathway_id, pathway_mode}`, or `:not_found`.
  """
  def shortest_directed_path_to_any(adjacency, start_stop_id, target_ids) do
    if MapSet.member?(target_ids, start_stop_id) do
      {:found, reconstruct_path(%{}, start_stop_id, start_stop_id)}
    else
      queue = :queue.from_list([start_stop_id])
      visited = MapSet.new([start_stop_id])

      do_shortest_directed_path_to_any(
        queue,
        visited,
        %{},
        adjacency,
        start_stop_id,
        target_ids
      )
    end
  end

  # --- Private helpers ---

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

  defp do_reachable?(queue, visited, target_ids, directed) do
    case :queue.out(queue) do
      {{:value, current}, rest} ->
        if MapSet.member?(target_ids, current) do
          true
        else
          neighbors = Map.get(directed, current, MapSet.new())

          {next_queue, next_visited} =
            Enum.reduce(neighbors, {rest, visited}, fn neighbor, {q, v} ->
              if MapSet.member?(v, neighbor) do
                {q, v}
              else
                {:queue.in(neighbor, q), MapSet.put(v, neighbor)}
              end
            end)

          do_reachable?(next_queue, next_visited, target_ids, directed)
        end

      {:empty, _} ->
        false
    end
  end

  defp do_shortest_directed_path_to_any(
         queue,
         visited,
         came_from,
         adjacency,
         start_stop_id,
         target_ids
       ) do
    case :queue.out(queue) do
      {{:value, current}, rest} ->
        if MapSet.member?(target_ids, current) do
          {:found, reconstruct_path(came_from, start_stop_id, current)}
        else
          neighbors = Map.get(adjacency, current, [])

          {next_queue, next_visited, next_came_from} =
            Enum.reduce(neighbors, {rest, visited, came_from}, fn edge, {q, v, c} ->
              next_stop_id = edge.to_stop_id

              if MapSet.member?(v, next_stop_id) do
                {q, v, c}
              else
                {
                  :queue.in(next_stop_id, q),
                  MapSet.put(v, next_stop_id),
                  Map.put(c, next_stop_id, %{
                    prev_stop_id: current,
                    pathway_id: edge.pathway_id,
                    pathway_mode: edge.pathway_mode
                  })
                }
              end
            end)

          do_shortest_directed_path_to_any(
            next_queue,
            next_visited,
            next_came_from,
            adjacency,
            start_stop_id,
            target_ids
          )
        end

      {:empty, _} ->
        :not_found
    end
  end

  defp reconstruct_path(came_from, start_stop_id, target_stop_id) do
    path = reconstruct_path_hops(came_from, target_stop_id, [])

    [%{stop_id: start_stop_id, pathway_id: nil, pathway_mode: nil} | path]
  end

  defp reconstruct_path_hops(came_from, stop_id, acc) do
    case Map.get(came_from, stop_id) do
      nil ->
        acc

      %{prev_stop_id: prev_stop_id, pathway_id: pathway_id, pathway_mode: pathway_mode} ->
        reconstruct_path_hops(came_from, prev_stop_id, [
          %{stop_id: stop_id, pathway_id: pathway_id, pathway_mode: pathway_mode} | acc
        ])
    end
  end

  defp put_edge(adjacency, from_stop_id, to_stop_id) do
    Map.update(adjacency, from_stop_id, MapSet.new([to_stop_id]), &MapSet.put(&1, to_stop_id))
  end

  defp put_path_edge(adjacency, from_stop_id, to_stop_id, pathway) do
    edge = %{
      to_stop_id: to_stop_id,
      pathway_id: pathway.pathway_id,
      pathway_mode: normalize_pathway_mode(pathway.pathway_mode)
    }

    Map.update(adjacency, from_stop_id, [edge], &[edge | &1])
  end

  defp normalize_pathway_mode(pathway_mode) when is_integer(pathway_mode), do: pathway_mode
  defp normalize_pathway_mode(_), do: -1
end
