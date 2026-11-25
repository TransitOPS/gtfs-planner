defmodule GtfsPlanner.Gtfs.StationReport2.AccessibilityGrouping do
  @moduledoc """
  Pure non-name structural grouping, fare-gate zone partitioning, and
  verified-corridor collapsing for station accessibility views.

  All groupings and zone partitions are derived strictly from GTFS routes,
  pathway topology, and level assignments — never from parsing `stop_name`
  or `stop_id` text patterns (`INV-3`).
  """

  alias GtfsPlanner.Gtfs.Graph
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.StationReport2.Helpers
  alias GtfsPlanner.Values

  @max_route_components 6
  @fare_gate_modes [6, 7]
  @entrance_cut_modes [5, 6, 7]

  @type fare_zone :: :unpaid | :paid | :open
  @type cell_status :: :confirmed | :unverified | :partial | :no_route

  # --- Fare-gate zone partitioning (D-4) ---

  @doc """
  Partitions station stops into `:unpaid`, `:paid`, or `:open` fare zones
  by removing mode `6` (fare gate) and mode `7` (exit gate) pathways.

  When no mode `6` or `7` pathways exist in the snapshot, returns
  `has_fare_gates?: false` with every stop labeled `:open`.
  """
  @spec partition_fare_zones(map()) :: %{
          has_fare_gates?: boolean(),
          node_zones: %{String.t() => fare_zone()}
        }
  def partition_fare_zones(snapshot) when is_map(snapshot) do
    child_stops = Map.get(snapshot, :child_stops, [])
    pathways = Map.get(snapshot, :pathways, [])
    all_stop_ids = collect_station_stop_ids(child_stops, pathways)
    gate_pathways = Enum.filter(pathways, &(&1.pathway_mode in @fare_gate_modes))

    if gate_pathways == [] do
      %{
        has_fare_gates?: false,
        node_zones: Map.new(all_stop_ids, &{&1, :open})
      }
    else
      non_gate_pathways =
        Enum.reject(pathways, fn pathway ->
          pathway.pathway_mode in @fare_gate_modes
        end)

      undirected = Graph.build_undirected_adjacency(non_gate_pathways)

      entrance_ids =
        child_stops
        |> Enum.filter(&(Map.get(&1, :location_type) == 2))
        |> Enum.map(& &1.stop_id)

      unpaid_set = multi_source_bfs(entrance_ids, undirected)

      platform_and_ba_ids =
        child_stops
        |> Enum.filter(&(Map.get(&1, :location_type) in [0, 4]))
        |> Enum.map(& &1.stop_id)

      paid_set = multi_source_bfs(platform_and_ba_ids, undirected)

      node_zones =
        Map.new(all_stop_ids, &{&1, classify_stop_zone(&1, unpaid_set, paid_set)})

      %{has_fare_gates?: true, node_zones: node_zones}
    end
  end

  defp classify_stop_zone(stop_id, unpaid_set, paid_set) do
    cond do
      MapSet.member?(unpaid_set, stop_id) -> :unpaid
      MapSet.member?(paid_set, stop_id) -> :paid
      true -> :open
    end
  end

  # --- Non-name platform & entrance grouping + matrix (CR-S2, CR-S3, D-6) ---

  @doc """
  Groups step-free entrances and platforms purely by GTFS routes, graph
  topology, and levels, and builds the grouped entrance × platform access
  matrix.
  """
  @spec build_groups(map(), map()) :: %{
          entrance_groups: [map()],
          platform_groups: [map()],
          cells: %{
            {String.t(), String.t()} => %{
              entrance_group_id: String.t(),
              platform_group_id: String.t(),
              confirmed: non_neg_integer(),
              unverified: non_neg_integer(),
              no_route: non_neg_integer(),
              total: non_neg_integer(),
              status: cell_status(),
              pairs: [map()]
            }
          }
        }
  def build_groups(snapshot, analysis) when is_map(snapshot) and is_map(analysis) do
    level_index = build_level_index(Map.get(snapshot, :levels, []))
    child_stops = Map.get(snapshot, :child_stops, [])
    routes_by_stop = Map.get(analysis, :routes_by_stop, %{})

    entrance_groups = build_entrance_groups(analysis, level_index)

    platform_groups =
      build_platform_groups(
        Map.get(analysis, :platforms, []),
        child_stops,
        routes_by_stop,
        level_index
      )

    cells = build_group_matrix(entrance_groups, platform_groups, Map.get(analysis, :pairs, []))

    %{
      entrance_groups: entrance_groups,
      platform_groups: platform_groups,
      cells: cells
    }
  end

  # --- Verified-corridor collapsing (D-4, AC-5) ---

  @doc """
  Collapses maximal contiguous runs of `>= 2` `:confirmed` mode-1 flat walkways
  on the same level and fare zone without near-threshold warnings into a single
  expandable `:corridor` item, while preserving elevators, fare gates, ramps,
  moving sidewalks, near-threshold edges, and unverified edges as `:step` items.
  """
  @spec collapse_corridors([map()], map()) :: [
          %{
            type: :step | :corridor,
            id: String.t(),
            level_id: String.t() | nil,
            level_name: String.t() | nil,
            fare_zone: fare_zone(),
            steps: [map()],
            distance_meters: float(),
            duration_seconds: float(),
            edge_count: pos_integer()
          }
        ]
  def collapse_corridors(route_steps, fare_zones \\ %{}) when is_list(route_steps) do
    node_zones = extract_node_zones(fare_zones)

    route_steps
    |> chunk_corridor_runs(node_zones)
    |> Enum.map(&build_corridor_item(&1, node_zones))
  end

  # --- Private: Entrance grouping (single-rule structural components, CR-S3) ---

  defp build_entrance_groups(analysis, level_index) do
    step_free_entrances = Map.get(analysis, :step_free_entrances, [])

    if step_free_entrances == [] do
      []
    else
      entrance_by_id = Map.new(step_free_entrances, &{&1.stop_id, &1})
      sorted_ids = step_free_entrances |> Enum.map(& &1.stop_id) |> Enum.sort()

      # Barrier-free step-free graph with elevator components (mode 5) and
      # fare/exit gates (modes 6/7) removed.
      non_cut_pathways =
        analysis
        |> Map.get(:edges, [])
        |> Enum.filter(fn edge ->
          edge.classification in [:confirmed, :unverified] and
            edge.pathway_mode not in @entrance_cut_modes
        end)
        |> Enum.map(& &1.pathway)

      undirected = Graph.build_undirected_adjacency(non_cut_pathways)

      sorted_ids
      |> partition_stop_components(undirected)
      |> Enum.map(&build_entrance_group(&1, entrance_by_id, level_index))
      |> Enum.sort_by(&entrance_group_sort_key(&1, level_index))
    end
  end

  defp build_entrance_group(member_stop_ids, entrance_by_id, level_index) do
    sorted_ids = Enum.sort(member_stop_ids)
    members = Enum.map(sorted_ids, &Map.fetch!(entrance_by_id, &1))
    member_names = Enum.map(members, & &1.name)
    {level_ids, level_names} = distinct_levels(members, level_index)
    primary_level_id = List.first(level_ids)
    primary_level_name = List.first(level_names)

    %{
      id: "eg:" <> hd(sorted_ids),
      title: format_entrance_group_title(level_names, member_names),
      entrance_stop_ids: sorted_ids,
      entrances: members,
      member_names: member_names,
      entrance_count: length(sorted_ids),
      level_id: primary_level_id,
      level_name: primary_level_name,
      level_ids: level_ids,
      level_names: level_names
    }
  end

  defp format_entrance_group_title(level_names, member_names) do
    members_label = format_member_names(member_names)

    case level_names do
      [] -> members_label
      names -> "#{Enum.join(names, " / ")} · #{members_label}"
    end
  end

  defp format_member_names([single]), do: single
  defp format_member_names([first, second]), do: "#{first}, #{second}"
  defp format_member_names([first, second, third]), do: "#{first}, #{second}, #{third}"

  defp format_member_names([first, second | rest]) do
    "#{first}, #{second} +#{length(rest)} more"
  end

  defp entrance_group_sort_key(group, level_index) do
    {level_sort_key(group.level_id, level_index), group.id}
  end

  # --- Private: Platform grouping (bipartite routes -> rollup -> level fallback) ---

  defp build_platform_groups(platforms, child_stops, routes_by_stop, level_index) do
    if platforms == [] do
      []
    else
      ba_by_platform =
        child_stops
        |> Enum.filter(&(Map.get(&1, :location_type) == 4))
        |> Enum.group_by(&Map.get(&1, :parent_station))

      enriched_platforms =
        platforms
        |> Enum.sort_by(& &1.stop_id)
        |> Enum.map(fn platform ->
          routes = platform_serving_routes(platform, ba_by_platform, routes_by_stop)
          Map.put(platform, :resolved_routes, routes)
        end)

      {scheduled, unscheduled} =
        Enum.split_with(enriched_platforms, &(&1.resolved_routes != []))

      scheduled_groups = build_scheduled_platform_groups(scheduled, level_index)
      unscheduled_groups = build_unscheduled_platform_groups(unscheduled, level_index)

      (scheduled_groups ++ unscheduled_groups)
      |> Enum.sort_by(&platform_group_sort_key(&1, level_index))
    end
  end

  defp platform_serving_routes(platform, ba_by_platform, routes_by_stop) do
    ba_ids =
      ba_by_platform
      |> Map.get(platform.stop_id, [])
      |> Enum.map(& &1.stop_id)

    from_map =
      [platform.stop_id | ba_ids]
      |> Enum.flat_map(&Map.get(routes_by_stop, &1, []))

    (Map.get(platform, :routes, []) ++ from_map)
    |> Enum.uniq_by(& &1.route_id)
    |> Enum.sort_by(&route_sort_key/1)
  end

  defp build_scheduled_platform_groups([], _level_index), do: []

  defp build_scheduled_platform_groups(scheduled, level_index) do
    components = platform_route_components(scheduled)

    if length(components) <= @max_route_components do
      Enum.map(components, &build_route_component_group(&1, level_index))
    else
      scheduled
      |> Enum.group_by(fn platform ->
        {primary_route_type(platform.resolved_routes), Map.get(platform, :level_id)}
      end)
      |> Enum.map(fn {{route_type, level_id}, members} ->
        build_rolled_up_platform_group(route_type, level_id, members, level_index)
      end)
    end
  end

  defp platform_route_components(scheduled) do
    platform_by_id = Map.new(scheduled, &{&1.stop_id, &1})

    bipartite_adj =
      Enum.reduce(scheduled, %{}, fn platform, acc ->
        p_node = {:platform, platform.stop_id}

        Enum.reduce(platform.resolved_routes, acc, fn route, inner ->
          r_node = {:route, route.route_id}

          inner
          |> put_adj_edge(p_node, r_node)
          |> put_adj_edge(r_node, p_node)
        end)
      end)

    platform_nodes = Enum.map(scheduled, &{:platform, &1.stop_id})

    {components, _visited} =
      Enum.reduce(platform_nodes, {[], MapSet.new()}, fn p_node, {comps, visited} ->
        if MapSet.member?(visited, p_node) do
          {comps, visited}
        else
          comp_set = Graph.bfs(p_node, bipartite_adj)

          member_platforms =
            comp_set
            |> MapSet.to_list()
            |> Enum.flat_map(fn
              {:platform, stop_id} -> [Map.fetch!(platform_by_id, stop_id)]
              _ -> []
            end)
            |> Enum.sort_by(& &1.stop_id)

          {[member_platforms | comps], MapSet.union(visited, comp_set)}
        end
      end)

    Enum.reverse(components)
  end

  defp build_route_component_group(members, level_index) do
    sorted_members = Enum.sort_by(members, & &1.stop_id)
    stop_ids = Enum.map(sorted_members, & &1.stop_id)
    routes = collect_unique_routes(sorted_members)
    {level_ids, level_names} = distinct_levels(sorted_members, level_index)
    primary_type = primary_route_type(routes)

    %{
      id: "pg:" <> hd(stop_ids),
      title: format_route_component_title(routes),
      grouping_strategy: :route_component,
      platform_stop_ids: stop_ids,
      platforms: sorted_members,
      platform_count: length(stop_ids),
      routes: routes,
      route_ids: Enum.map(routes, & &1.route_id),
      route_type: primary_type,
      level_id: List.first(level_ids),
      level_ids: level_ids,
      level_names: level_names
    }
  end

  defp build_rolled_up_platform_group(route_type, level_id, members, level_index) do
    sorted_members = Enum.sort_by(members, & &1.stop_id)
    stop_ids = Enum.map(sorted_members, & &1.stop_id)
    routes = collect_unique_routes(sorted_members)
    {level_ids, level_names} = distinct_levels(sorted_members, level_index)
    level_label = level_display_name(level_id, level_index)

    title =
      case routes do
        [single] ->
          single_route_title(single)

        many ->
          base = "#{Route.route_type_label(route_type)} (#{length(many)} routes)"
          if level_id, do: "#{base} · #{level_label}", else: base
      end

    %{
      id: "pg:" <> hd(stop_ids),
      title: title,
      grouping_strategy: :route_type_level,
      platform_stop_ids: stop_ids,
      platforms: sorted_members,
      platform_count: length(stop_ids),
      routes: routes,
      route_ids: Enum.map(routes, & &1.route_id),
      route_type: route_type,
      level_id: level_id,
      level_ids: level_ids,
      level_names: level_names
    }
  end

  defp build_unscheduled_platform_groups([], _level_index), do: []

  defp build_unscheduled_platform_groups(unscheduled, level_index) do
    unscheduled
    |> Enum.group_by(&Map.get(&1, :level_id))
    |> Enum.map(fn {level_id, members} ->
      sorted_members = Enum.sort_by(members, & &1.stop_id)
      stop_ids = Enum.map(sorted_members, & &1.stop_id)
      level_label = level_display_name(level_id, level_index)

      %{
        id: "pg:" <> hd(stop_ids),
        title: level_label,
        grouping_strategy: :level_fallback,
        platform_stop_ids: stop_ids,
        platforms: sorted_members,
        platform_count: length(stop_ids),
        routes: [],
        route_ids: [],
        route_type: nil,
        level_id: level_id,
        level_ids: if(level_id, do: [level_id], else: []),
        level_names: [level_label]
      }
    end)
  end

  defp format_route_component_title([single]), do: single_route_title(single)

  defp format_route_component_title(routes) when length(routes) > 1 do
    type_labels =
      routes
      |> Enum.map(&Map.get(&1, :route_type))
      |> Enum.uniq()
      |> Enum.sort_by(&{is_nil(&1), &1 || 999})
      |> Enum.map_join(" / ", &Route.route_type_label/1)

    "#{type_labels} (#{length(routes)} routes)"
  end

  defp single_route_title(route) do
    Values.presence(Map.get(route, :route_short_name)) ||
      Values.presence(Map.get(route, :route_long_name)) ||
      route.route_id
  end

  defp collect_unique_routes(members) do
    members
    |> Enum.flat_map(& &1.resolved_routes)
    |> Enum.uniq_by(& &1.route_id)
    |> Enum.sort_by(&route_sort_key/1)
  end

  defp primary_route_type(routes) do
    routes
    |> Enum.map(&Map.get(&1, :route_type))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      types -> Enum.min(types)
    end
  end

  defp route_sort_key(route) do
    label =
      Values.presence(Map.get(route, :route_short_name)) ||
        Values.presence(Map.get(route, :route_long_name)) ||
        route.route_id

    {label, route.route_id}
  end

  defp platform_group_sort_key(group, level_index) do
    strategy_rank =
      case group.grouping_strategy do
        :route_component -> 0
        :route_type_level -> 0
        :level_fallback -> 1
      end

    type_rank = {if(is_integer(group.route_type), do: 0, else: 1), group.route_type || 999}
    {strategy_rank, level_sort_key(group.level_id, level_index), type_rank, group.id}
  end

  # --- Private: Grouped access matrix ---

  defp build_group_matrix(entrance_groups, platform_groups, pairs) do
    pair_by_key = Map.new(pairs, &{{&1.entrance_stop_id, &1.platform_stop_id}, &1})

    for eg <- entrance_groups, pg <- platform_groups, into: %{} do
      cell_pairs =
        for e_id <- eg.entrance_stop_ids,
            p_id <- pg.platform_stop_ids,
            pair = Map.get(pair_by_key, {e_id, p_id}),
            not is_nil(pair),
            do: pair

      counts =
        Enum.reduce(cell_pairs, %{confirmed: 0, unverified: 0, no_route: 0}, fn pair, acc ->
          Map.update!(acc, pair.status, &(&1 + 1))
        end)

      total = length(cell_pairs)

      cell = %{
        entrance_group_id: eg.id,
        platform_group_id: pg.id,
        confirmed: counts.confirmed,
        unverified: counts.unverified,
        no_route: counts.no_route,
        total: total,
        status: derive_cell_status(counts, total),
        pairs: cell_pairs
      }

      {{eg.id, pg.id}, cell}
    end
  end

  defp derive_cell_status(_counts, 0), do: :no_route
  defp derive_cell_status(%{confirmed: c}, total) when c == total, do: :confirmed
  defp derive_cell_status(%{no_route: n}, total) when n == total, do: :no_route
  defp derive_cell_status(%{no_route: 0}, _total), do: :unverified
  defp derive_cell_status(_counts, _total), do: :partial

  # --- Private: Corridor collapsing ---

  defp extract_node_zones(%{node_zones: node_zones}) when is_map(node_zones), do: node_zones
  defp extract_node_zones(map) when is_map(map), do: map
  defp extract_node_zones(_), do: %{}

  defp chunk_corridor_runs([], _node_zones), do: []

  defp chunk_corridor_runs(steps, node_zones) do
    steps
    |> Enum.reduce([], fn step, acc ->
      key = collapsible_run_key(step, node_zones)

      case acc do
        [{^key, run_steps} | rest] when not is_nil(key) ->
          [{key, [step | run_steps]} | rest]

        _ ->
          [{key, [step]} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {key, rev_steps} -> {key, Enum.reverse(rev_steps)} end)
  end

  defp collapsible_run_key(step, node_zones) do
    from_zone = Map.get(node_zones, step.from_stop_id, :open)
    to_zone = Map.get(node_zones, step.to_stop_id, :open)
    same_level? = Map.get(step, :from_level_id) == Map.get(step, :to_level_id)

    if step.pathway_mode == 1 and
         step.classification == :confirmed and
         not Map.get(step, :is_ramp, false) and
         Map.get(step, :near_threshold_fields, []) == [] and
         same_level? and
         from_zone == to_zone do
      {Map.get(step, :level_id), from_zone}
    else
      nil
    end
  end

  defp build_corridor_item({{_level_id, fare_zone}, steps}, _node_zones)
       when length(steps) >= 2 do
    first = hd(steps)
    last = List.last(steps)
    {dist, dur} = sum_step_metrics(steps)
    rounded_dist = Float.round(dist, 2)
    rounded_dur = Float.round(dur, 2)
    edge_count = length(steps)

    %{
      type: :corridor,
      id: "corridor:" <> first.pathway_id <> ".." <> last.pathway_id,
      level_id: Map.get(first, :level_id),
      level_name: Map.get(first, :level_name),
      fare_zone: fare_zone,
      steps: steps,
      from_stop_id: first.from_stop_id,
      from_stop_name: Map.get(first, :from_stop_name),
      to_stop_id: last.to_stop_id,
      to_stop_name: Map.get(last, :to_stop_name),
      distance_meters: rounded_dist,
      duration_seconds: rounded_dur,
      edge_count: edge_count,
      summary: format_corridor_summary(edge_count, rounded_dist, rounded_dur)
    }
  end

  defp build_corridor_item({_key, [step]}, node_zones) do
    {dist, dur} = sum_step_metrics([step])
    from_zone = Map.get(node_zones, step.from_stop_id, :open)
    to_zone = Map.get(node_zones, step.to_stop_id, :open)

    %{
      type: :step,
      id: "step:" <> step.pathway_id,
      level_id: Map.get(step, :level_id),
      level_name: Map.get(step, :level_name),
      fare_zone: from_zone,
      to_fare_zone: to_zone,
      steps: [step],
      step: step,
      from_stop_id: step.from_stop_id,
      from_stop_name: Map.get(step, :from_stop_name),
      to_stop_id: step.to_stop_id,
      to_stop_name: Map.get(step, :to_stop_name),
      distance_meters: Float.round(dist, 2),
      duration_seconds: Float.round(dur, 2),
      edge_count: 1
    }
  end

  defp sum_step_metrics(steps) do
    Enum.reduce(steps, {0.0, 0.0}, fn step, {dist_acc, dur_acc} ->
      dist =
        case Map.get(step, :distance_meters) do
          n when is_number(n) -> n / 1
          _ -> 0.0
        end

      dur =
        case Map.get(step, :duration_seconds) do
          n when is_number(n) -> n / 1
          _ -> 0.0
        end

      {dist_acc + dist, dur_acc + dur}
    end)
  end

  defp format_corridor_summary(edge_count, distance_meters, duration_seconds) do
    parts =
      ["#{edge_count} verified corridors"] ++
        if(distance_meters > 0.0, do: ["#{round(distance_meters)} m"], else: []) ++
        if(duration_seconds > 0.0, do: [Helpers.format_duration(duration_seconds)], else: [])

    Enum.join(parts, " · ")
  end

  # --- Private: Graph & level helpers ---

  defp collect_station_stop_ids(child_stops, pathways) do
    from_stops = Enum.map(child_stops, & &1.stop_id)
    from_pathways = Enum.flat_map(pathways, &[&1.from_stop_id, &1.to_stop_id])

    (from_stops ++ from_pathways)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp multi_source_bfs(seeds, adjacency) do
    Enum.reduce(seeds, MapSet.new(), fn seed, visited ->
      if MapSet.member?(visited, seed) do
        visited
      else
        MapSet.union(visited, Graph.bfs(seed, adjacency))
      end
    end)
  end

  defp partition_stop_components(sorted_stop_ids, undirected) do
    target_set = MapSet.new(sorted_stop_ids)

    {components, _visited} =
      Enum.reduce(sorted_stop_ids, {[], MapSet.new()}, fn stop_id, {comps, visited} ->
        if MapSet.member?(visited, stop_id) do
          {comps, visited}
        else
          comp = Graph.bfs(stop_id, undirected)
          members = comp |> MapSet.intersection(target_set) |> MapSet.to_list() |> Enum.sort()
          {[members | comps], MapSet.union(visited, comp)}
        end
      end)

    Enum.reverse(components)
  end

  defp put_adj_edge(adj, from, to) do
    Map.update(adj, from, MapSet.new([to]), &MapSet.put(&1, to))
  end

  defp build_level_index(levels) do
    levels
    |> Enum.map(fn
      %{level: level} -> level
      level when is_map(level) -> level
    end)
    |> Map.new(&{&1.level_id, &1})
  end

  defp distinct_levels(entries, level_index) do
    level_ids =
      entries
      |> Enum.map(&Map.get(&1, :level_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort_by(&level_sort_key(&1, level_index))

    level_names = Enum.map(level_ids, &level_display_name(&1, level_index))
    {level_ids, level_names}
  end

  defp level_display_name(nil, _level_index), do: "Unassigned level"

  defp level_display_name(level_id, level_index) do
    case Map.get(level_index, level_id) do
      nil -> level_id
      level -> Values.presence(Map.get(level, :level_name)) || level.level_id
    end
  end

  defp level_sort_key(nil, _level_index), do: {1, 0.0, ""}

  defp level_sort_key(level_id, level_index) do
    case Map.get(level_index, level_id) do
      nil ->
        {1, 0.0, level_id}

      level ->
        idx = Values.to_float(Map.get(level, :level_index))

        if is_number(idx) do
          {0, -idx, level_id}
        else
          {1, 0.0, level_id}
        end
    end
  end
end
