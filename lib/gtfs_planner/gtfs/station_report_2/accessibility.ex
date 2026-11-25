defmodule GtfsPlanner.Gtfs.StationReport2.Accessibility do
  @moduledoc """
  Pure station accessibility analysis and view-state derivation engine.

  Classifies station pathways using `Pathway`'s ADA barrier and near-threshold
  thresholds, models multi-row elevators as whole connected components, evaluates
  round-trip step-free entrance-to-platform journeys (`:confirmed`, `:unverified`,
  `:no_route`), ranks accessibility issues by rider impact, and prices individual
  routes on demand via `Routing.PathwayTraversal`.
  """

  alias GtfsPlanner.Gtfs.Graph
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Routing.PathwayTraversal
  alias GtfsPlanner.Values

  @max_network_step_free_edges 40
  @max_network_step_free_entrances 6
  @max_network_platforms 6

  @type edge_classification :: :confirmed | :unverified | :barrier | :not_step_free
  @type pair_status :: :confirmed | :unverified | :no_route
  @type derived_view_state ::
          :loading | :error | :empty_topology | :no_step_free_access | :ready

  @doc """
  Builds the complete accessibility analysis model for a station snapshot.

  Runs one single-source traversal per entrance per graph and never calls
  `Routing.PathwayTraversal` eagerly. Use `build_route/4` to price a selected
  entrance-to-platform route on demand.
  """
  @spec build(map(), map()) :: map()
  def build(snapshot, routes_by_stop \\ %{}) when is_map(snapshot) and is_map(routes_by_stop) do
    station = Map.fetch!(snapshot, :station)
    child_stops = Map.get(snapshot, :child_stops, [])
    pathways = Map.get(snapshot, :pathways, [])
    levels = Map.get(snapshot, :levels, [])

    stop_index = build_stop_index([station | child_stops])
    level_index = build_level_index(levels)
    platform_target_index = Graph.build_platform_target_index(child_stops)

    entrances = stops_with_location_type(child_stops, 2)
    platforms = stops_with_location_type(child_stops, 0)

    incomplete_reasons = compute_incomplete_reasons(snapshot, entrances, platforms)
    completeness = if(incomplete_reasons == [], do: :complete, else: :incomplete)

    classified_edges = classify_edges(pathways, stop_index, level_index)
    barrier_free_edges = Enum.filter(classified_edges, &barrier_free_edge?/1)
    barrier_free_pathways = Enum.map(barrier_free_edges, & &1.pathway)
    unverified_ids = unverified_pathway_ids(barrier_free_edges)

    {elevators_base, elevator_by_pathway_id} =
      build_elevator_components(barrier_free_edges, stop_index, level_index)

    {fwd_trees, rev_trees} =
      compute_directional_trees(entrances, barrier_free_pathways, unverified_ids)

    pairs =
      build_pairs(
        entrances,
        platforms,
        platform_target_index,
        fwd_trees,
        rev_trees,
        elevator_by_pathway_id
      )

    step_free_entrance_ids =
      pairs
      |> Enum.filter(&(&1.status in [:confirmed, :unverified]))
      |> MapSet.new(& &1.entrance_stop_id)

    elevators =
      compute_sole_link_pairs(
        elevators_base,
        barrier_free_pathways,
        entrances,
        step_free_entrance_ids,
        platform_target_index,
        pairs
      )

    sole_link_elevator_ids =
      elevators
      |> Enum.filter(&(&1.sole_link_pairs > 0))
      |> MapSet.new(& &1.id)

    edges = annotate_edges(classified_edges, elevator_by_pathway_id, sole_link_elevator_ids)

    entrance_entries =
      Enum.map(entrances, fn stop ->
        build_entrance_entry(stop, station, level_index, step_free_entrance_ids)
      end)

    {step_free_entrances, inaccessible_entrances} =
      Enum.split_with(entrance_entries, & &1.step_free?)

    platform_entries =
      Enum.map(platforms, fn stop ->
        build_platform_entry(stop, station, level_index, routes_by_stop)
      end)

    issues =
      build_issues(%{
        station: station,
        pathways: pathways,
        edges: edges,
        entrances: entrances,
        platforms: platforms,
        platform_target_index: platform_target_index,
        pairs: pairs,
        elevators: elevators,
        level_index: level_index
      })

    edge_completeness = %{
      complete: Enum.count(barrier_free_edges, &(&1.classification == :confirmed)),
      total: length(barrier_free_edges)
    }

    network_available? =
      length(barrier_free_edges) <= @max_network_step_free_edges and
        length(step_free_entrances) <= @max_network_step_free_entrances and
        length(platforms) <= @max_network_platforms

    %{
      network_available?: network_available?,
      default_view: if(network_available?, do: :network, else: :impact),
      completeness: completeness,
      incomplete_reasons: incomplete_reasons,
      entrances: entrance_entries,
      step_free_entrances: step_free_entrances,
      inaccessible_entrances: inaccessible_entrances,
      platforms: platform_entries,
      edges: edges,
      edge_completeness: edge_completeness,
      pairs: pairs,
      confidence_counts: count_pair_confidence(pairs),
      elevators: elevators,
      issues: issues,
      routes_by_stop: routes_by_stop
    }
  end

  @doc """
  Computes and prices a single entrance-to-platform step-free route on demand.

  Evaluates both `to_platform` and `to_exit` round-trip reachability; returns
  `:no_route` when either direction lacks a barrier-free step-free path. Calls
  `Routing.PathwayTraversal.traverse/4` only for pathways on the selected route.

  Options:
    * `:direction` - `:to_platform` (default) or `:to_exit`
  """
  @spec build_route(map(), String.t(), String.t(), keyword()) :: map() | :no_route
  def build_route(snapshot, entrance_stop_id, platform_stop_id, opts \\ [])
      when is_map(snapshot) and is_binary(entrance_stop_id) and is_binary(platform_stop_id) do
    direction = Keyword.get(opts, :direction, :to_platform)
    station = Map.fetch!(snapshot, :station)
    child_stops = Map.get(snapshot, :child_stops, [])
    pathways = Map.get(snapshot, :pathways, [])
    levels = Map.get(snapshot, :levels, [])

    stop_index = build_stop_index([station | child_stops])
    level_index = build_level_index(levels)

    with entrance_stop when not is_nil(entrance_stop) <- Map.get(stop_index, entrance_stop_id),
         platform_stop when not is_nil(platform_stop) <- Map.get(stop_index, platform_stop_id) do
      compute_and_price_route(%{
        entrance_stop: entrance_stop,
        platform_stop: platform_stop,
        child_stops: child_stops,
        pathways: pathways,
        levels: levels,
        stop_index: stop_index,
        level_index: level_index,
        direction: direction
      })
    else
      nil -> :no_route
    end
  end

  @doc """
  Derives the canonical UI state with strict precedence:
  `:loading > :error > :empty_topology > :no_step_free_access > :ready`.
  """
  @spec derive_view_state(%{
          optional(:view_state) => atom(),
          optional(:report_error) => term(),
          optional(:model) => map() | nil
        }) :: derived_view_state()
  def derive_view_state(assigns_state) when is_map(assigns_state) do
    view_state = Map.get(assigns_state, :view_state)
    report_error = Map.get(assigns_state, :report_error)
    model = Map.get(assigns_state, :model)

    cond do
      is_nil(model) and view_state == :initial_loading ->
        :loading

      is_nil(model) and not is_nil(report_error) ->
        :error

      is_nil(model) ->
        :loading

      empty_topology?(model) ->
        :empty_topology

      Map.get(model, :step_free_entrances, []) == [] ->
        :no_step_free_access

      true ->
        :ready
    end
  end

  defp empty_topology?(model) do
    Map.get(model, :entrances, []) == [] or
      Map.get(model, :platforms, []) == [] or
      Map.get(model, :edges, []) == []
  end

  # --- Cross-station completeness (CR-C3) ---

  defp compute_incomplete_reasons(snapshot, entrances, platforms) do
    missing =
      for {stops, reason} <- [{entrances, :no_entrances}, {platforms, :no_platforms}],
          stops == [],
          do: reason

    case cross_station_pathway_ids(snapshot) do
      [] -> missing
      pathway_ids -> missing ++ [{:cross_station_pathways, pathway_ids}]
    end
  end

  defp cross_station_pathway_ids(snapshot) do
    station_stop_id = snapshot.station.stop_id
    child_stops = Map.get(snapshot, :child_stops, [])
    pathways = Map.get(snapshot, :pathways, [])

    in_station =
      Enum.reduce(child_stops, MapSet.new([station_stop_id]), &MapSet.put(&2, &1.stop_id))

    pathways
    |> Enum.filter(fn pathway ->
      not (MapSet.member?(in_station, pathway.from_stop_id) and
             MapSet.member?(in_station, pathway.to_stop_id))
    end)
    |> Enum.map(& &1.pathway_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- Edge classification (D-1, D-2, CR-S5) ---

  defp classify_edges(pathways, stop_index, level_index) do
    pathways
    |> Enum.map(&classify_edge(&1, stop_index, level_index))
    |> Enum.sort_by(& &1.pathway_id)
  end

  defp classify_edge(pathway, stop_index, level_index) do
    from_stop = Map.get(stop_index, pathway.from_stop_id)
    to_stop = Map.get(stop_index, pathway.to_stop_id)
    from_level = level_for_stop(from_stop, level_index)
    to_level = level_for_stop(to_stop, level_index)
    state = Pathway.step_free_state(pathway)
    barriers = if(state == :barrier, do: Pathway.step_free_barriers(pathway), else: [])

    {classification, missing_fields, near_threshold_fields} =
      resolve_edge_classification(state, pathway, from_level, to_level)

    is_ramp =
      pathway.pathway_mode in [1, 3] and
        (different_level_index?(from_level, to_level) or
           nonzero_slope?(Map.get(pathway, :max_slope)))

    %{
      pathway: pathway,
      id: Map.get(pathway, :id),
      pathway_id: pathway.pathway_id,
      pathway_mode: pathway.pathway_mode,
      pathway_mode_label: Pathway.mode_label(pathway.pathway_mode),
      from_stop_id: pathway.from_stop_id,
      to_stop_id: pathway.to_stop_id,
      is_bidirectional: Map.get(pathway, :is_bidirectional, false),
      from_level_id: Values.presence(from_stop && Map.get(from_stop, :level_id)),
      to_level_id: Values.presence(to_stop && Map.get(to_stop, :level_id)),
      from_level_name: from_level && Map.get(from_level, :level_name),
      to_level_name: to_level && Map.get(to_level, :level_name),
      classification: classification,
      barriers: barriers,
      missing_fields: missing_fields,
      near_threshold_fields: near_threshold_fields,
      is_ramp: is_ramp,
      elevator_id: nil,
      sole_link_elevator?: false
    }
  end

  defp resolve_edge_classification(:step_free, pathway, from_level, to_level) do
    missing = missing_required_fields(pathway, from_level, to_level)
    near = Pathway.near_threshold_fields(pathway)
    cls = if(missing == [], do: :confirmed, else: :unverified)
    {cls, missing, near}
  end

  defp resolve_edge_classification(:barrier, _pathway, _from_level, _to_level),
    do: {:barrier, [], []}

  defp resolve_edge_classification(_other, _pathway, _from_level, _to_level),
    do: {:not_step_free, [], []}

  defp missing_required_fields(%{pathway_mode: mode} = pathway, from_level, to_level)
       when mode in [1, 3] do
    has_width = positive_measurement?(Map.get(pathway, :min_width))

    has_time_or_length =
      positive_measurement?(Map.get(pathway, :traversal_time)) or
        positive_measurement?(Map.get(pathway, :length))

    needs_slope =
      different_level_index?(from_level, to_level) and
        not recorded_slope?(Map.get(pathway, :max_slope))

    []
    |> maybe_prepend(not has_width, :min_width)
    |> maybe_prepend(not has_time_or_length, :traversal_time_or_length)
    |> maybe_prepend(needs_slope, :max_slope)
    |> Enum.sort()
  end

  defp missing_required_fields(%{pathway_mode: 5} = pathway, from_level, to_level) do
    has_time = positive_measurement?(Map.get(pathway, :traversal_time))
    has_width = positive_measurement?(Map.get(pathway, :min_width))
    has_levels = not is_nil(from_level) and not is_nil(to_level)

    []
    |> maybe_prepend(not has_time, :traversal_time)
    |> maybe_prepend(not has_width, :min_width)
    |> maybe_prepend(not has_levels, :endpoint_level_id)
    |> Enum.sort()
  end

  defp missing_required_fields(%{pathway_mode: mode} = pathway, _from_level, _to_level)
       when mode in [6, 7] do
    if positive_measurement?(Map.get(pathway, :min_width)), do: [], else: [:min_width]
  end

  defp missing_required_fields(_pathway, _from_level, _to_level), do: []

  defp maybe_prepend(list, true, item), do: [item | list]
  defp maybe_prepend(list, false, _item), do: list

  defp barrier_free_edge?(%{classification: cls}), do: cls in [:confirmed, :unverified]

  defp unverified_pathway_ids(barrier_free_edges) do
    barrier_free_edges
    |> Enum.filter(&(&1.classification == :unverified))
    |> MapSet.new(& &1.pathway_id)
  end

  defp positive_measurement?(%Decimal{} = value), do: Decimal.positive?(value)
  defp positive_measurement?(value) when is_number(value), do: value > 0
  defp positive_measurement?(_value), do: false

  defp recorded_slope?(%Decimal{}), do: true
  defp recorded_slope?(value) when is_number(value), do: true
  defp recorded_slope?(_value), do: false

  defp nonzero_slope?(%Decimal{} = value), do: not Decimal.equal?(value, Decimal.new(0))
  defp nonzero_slope?(value) when is_number(value), do: value != 0
  defp nonzero_slope?(_value), do: false

  defp different_level_index?(from_level, to_level)
       when not is_nil(from_level) and not is_nil(to_level) do
    from_idx = Values.to_float(Map.get(from_level, :level_index))
    to_idx = Values.to_float(Map.get(to_level, :level_index))
    is_number(from_idx) and is_number(to_idx) and from_idx != to_idx
  end

  defp different_level_index?(_from_level, _to_level), do: false

  defp annotate_edges(edges, elevator_by_pathway_id, sole_link_elevator_ids) do
    Enum.map(edges, fn edge ->
      elevator_id = Map.get(elevator_by_pathway_id, edge.pathway_id)
      sole_link? = not is_nil(elevator_id) and MapSet.member?(sole_link_elevator_ids, elevator_id)
      %{edge | elevator_id: elevator_id, sole_link_elevator?: sole_link?}
    end)
  end

  # --- Whole-elevator connected components (CR-M1) ---

  defp build_elevator_components(barrier_free_edges, stop_index, level_index) do
    elevator_edges = Enum.filter(barrier_free_edges, &(&1.pathway_mode == 5))

    if elevator_edges == [] do
      {[], %{}}
    else
      undirected = Graph.build_undirected_adjacency(Enum.map(elevator_edges, & &1.pathway))

      stop_ids =
        elevator_edges
        |> Enum.flat_map(&[&1.from_stop_id, &1.to_stop_id])
        |> Enum.uniq()
        |> Enum.sort()

      components =
        stop_ids
        |> find_connected_components(undirected)
        |> Enum.map(&build_elevator_component(&1, elevator_edges, stop_index, level_index))
        |> Enum.sort_by(& &1.id)

      elevator_by_pathway_id = index_elevators_by_pathway_id(components)

      {components, elevator_by_pathway_id}
    end
  end

  defp index_elevators_by_pathway_id(components) do
    for component <- components,
        pathway_id <- component.pathway_ids,
        into: %{} do
      {pathway_id, component.id}
    end
  end

  defp build_elevator_component(component_stops, elevator_edges, stop_index, level_index) do
    member_edges =
      elevator_edges
      |> Enum.filter(&MapSet.member?(component_stops, &1.from_stop_id))
      |> Enum.sort_by(& &1.pathway_id)

    pathway_ids = Enum.map(member_edges, & &1.pathway_id)
    primary_edge = hd(member_edges)

    %{
      id: hd(pathway_ids),
      label: format_elevator_label(pathway_ids),
      pathway_ids: pathway_ids,
      primary_pathway: primary_edge.pathway,
      connects: format_elevator_connects(component_stops, stop_index, level_index),
      sole_link_pairs: 0
    }
  end

  defp find_connected_components(stop_ids, undirected) do
    {components, _visited} =
      Enum.reduce(stop_ids, {[], MapSet.new()}, fn stop_id, {comps, visited} ->
        if MapSet.member?(visited, stop_id) do
          {comps, visited}
        else
          comp = Graph.bfs(stop_id, undirected)
          {[comp | comps], MapSet.union(visited, comp)}
        end
      end)

    Enum.reverse(components)
  end

  defp format_elevator_label([single]), do: single
  defp format_elevator_label([first, second]), do: "#{first} / #{second}"
  defp format_elevator_label([first | rest]), do: "#{first} (#{length(rest) + 1} pathways)"

  defp format_elevator_connects(stop_set, stop_index, level_index) do
    stop_set
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(&elevator_stop_level_sort_key(&1, stop_index, level_index))
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.sort_by(fn {idx, label} ->
      {if(is_number(idx), do: 0, else: 1), if(is_number(idx), do: -idx, else: 0.0), label}
    end)
    |> Enum.map_join(" \u2194 ", &elem(&1, 1))
  end

  defp elevator_stop_level_sort_key(stop_id, stop_index, level_index) do
    stop = Map.get(stop_index, stop_id)
    level = level_for_stop(stop, level_index)

    if level do
      {
        Values.to_float(Map.get(level, :level_index)),
        Map.get(level, :level_name) || level.level_id
      }
    else
      {nil, (stop && Map.get(stop, :level_id)) || stop_display_name(stop) || stop_id}
    end
  end

  defp compute_sole_link_pairs(
         elevators,
         barrier_free_pathways,
         entrances,
         step_free_entrance_ids,
         platform_target_index,
         pairs
       ) do
    reachable_pairs = Enum.filter(pairs, &(&1.status in [:confirmed, :unverified]))

    if elevators == [] or reachable_pairs == [] do
      elevators
    else
      active_entrances =
        Enum.filter(entrances, &MapSet.member?(step_free_entrance_ids, &1.stop_id))

      Enum.map(elevators, fn elevator ->
        sole_count =
          count_lost_pairs_without_elevator(
            elevator,
            barrier_free_pathways,
            active_entrances,
            platform_target_index,
            reachable_pairs
          )

        %{elevator | sole_link_pairs: sole_count}
      end)
    end
  end

  defp count_lost_pairs_without_elevator(
         elevator,
         barrier_free_pathways,
         active_entrances,
         platform_target_index,
         reachable_pairs
       ) do
    removed_ids = MapSet.new(elevator.pathway_ids)
    remaining = Enum.reject(barrier_free_pathways, &MapSet.member?(removed_ids, &1.pathway_id))
    fwd_adj = Graph.build_directed_adjacency(remaining)
    rev_adj = Graph.build_directed_adjacency(reverse_pathways(remaining))

    fwd_reach = Map.new(active_entrances, &{&1.stop_id, Graph.bfs(&1.stop_id, fwd_adj)})
    rev_reach = Map.new(active_entrances, &{&1.stop_id, Graph.bfs(&1.stop_id, rev_adj)})

    Enum.count(reachable_pairs, fn pair ->
      targets = platform_targets(platform_target_index, pair.platform_stop_id)
      fwd_set = Map.get(fwd_reach, pair.entrance_stop_id, MapSet.new())
      rev_set = Map.get(rev_reach, pair.entrance_stop_id, MapSet.new())

      MapSet.disjoint?(fwd_set, targets) or MapSet.disjoint?(rev_set, targets)
    end)
  end

  # --- Shortest fewest-unverified path search (one pass per source per graph) ---

  defp compute_directional_trees(entrances, pathways, unverified_ids) do
    fwd_adj = Graph.build_path_traversal_adjacency(pathways)
    rev_adj = Graph.build_path_traversal_adjacency(reverse_pathways(pathways))

    fwd_trees =
      Map.new(entrances, fn entrance ->
        {entrance.stop_id, shortest_unverified_tree(entrance.stop_id, fwd_adj, unverified_ids)}
      end)

    rev_trees =
      Map.new(entrances, fn entrance ->
        {entrance.stop_id, shortest_unverified_tree(entrance.stop_id, rev_adj, unverified_ids)}
      end)

    {fwd_trees, rev_trees}
  end

  # Two-level Dijkstra minimizing `{unverified_count, hop_count, sorted_pathway_ids}`.
  # Inserting the same pathway ID into equal-size sorted lists preserves lexicographic
  # ordering, so optimal substructure holds strictly.
  defp shortest_unverified_tree(start_stop_id, adjacency, unverified_ids) do
    initial_cost = {0, 0, []}
    best_costs = %{start_stop_id => initial_cost}
    queue = :gb_sets.singleton({initial_cost, start_stop_id})

    do_dijkstra(queue, best_costs, %{}, adjacency, unverified_ids)
  end

  defp do_dijkstra(queue, best_costs, came_from, adjacency, unverified_ids) do
    if :gb_sets.is_empty(queue) do
      %{best_costs: best_costs, came_from: came_from}
    else
      {{cost, current}, rest_queue} = :gb_sets.take_smallest(queue)

      if cost != Map.get(best_costs, current) do
        do_dijkstra(rest_queue, best_costs, came_from, adjacency, unverified_ids)
      else
        edges = Map.get(adjacency, current, [])

        {next_queue, next_best, next_came_from} =
          relax_edges(edges, current, cost, {rest_queue, best_costs, came_from}, unverified_ids)

        do_dijkstra(next_queue, next_best, next_came_from, adjacency, unverified_ids)
      end
    end
  end

  defp relax_edges(edges, current, {u_count, hops, sorted_ids}, state, unverified_ids) do
    Enum.reduce(edges, state, fn edge, {q, best, cf} ->
      weight = if(MapSet.member?(unverified_ids, edge.pathway_id), do: 1, else: 0)
      candidate_cost = {u_count + weight, hops + 1, insert_sorted(sorted_ids, edge.pathway_id)}
      prev_cost = Map.get(best, edge.to_stop_id)

      if is_nil(prev_cost) or candidate_cost < prev_cost do
        step = %{
          prev_stop_id: current,
          pathway_id: edge.pathway_id,
          pathway_mode: edge.pathway_mode
        }

        {
          :gb_sets.add_element({candidate_cost, edge.to_stop_id}, q),
          Map.put(best, edge.to_stop_id, candidate_cost),
          Map.put(cf, edge.to_stop_id, step)
        }
      else
        {q, best, cf}
      end
    end)
  end

  defp insert_sorted([], item), do: [item]
  defp insert_sorted([head | tail], item) when item <= head, do: [item, head | tail]
  defp insert_sorted([head | tail], item), do: [head | insert_sorted(tail, item)]

  defp best_target(%{best_costs: best_costs}, target_set) do
    target_set
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.reduce(:not_found, fn target_id, best ->
      case Map.fetch(best_costs, target_id) do
        {:ok, cost} -> pick_better_target(best, target_id, cost)
        :error -> best
      end
    end)
  end

  defp pick_better_target(:not_found, target_id, cost), do: {:ok, target_id, cost}

  defp pick_better_target({:ok, _best_id, best_cost} = current, target_id, cost) do
    if cost < best_cost, do: {:ok, target_id, cost}, else: current
  end

  defp cost_status({0, _hops, _ids}), do: :confirmed
  defp cost_status({_u, _hops, _ids}), do: :unverified

  defp reconstruct_forward_segments(came_from, start_stop_id, target_stop_id) do
    do_reconstruct_forward(came_from, start_stop_id, target_stop_id, [])
  end

  defp do_reconstruct_forward(_came_from, start_stop_id, start_stop_id, acc), do: acc

  defp do_reconstruct_forward(came_from, start_stop_id, current_stop_id, acc) do
    case Map.get(came_from, current_stop_id) do
      nil ->
        acc

      %{prev_stop_id: prev_stop_id, pathway_id: pathway_id, pathway_mode: pathway_mode} ->
        segment = %{
          from_stop_id: prev_stop_id,
          to_stop_id: current_stop_id,
          pathway_id: pathway_id,
          pathway_mode: pathway_mode
        }

        do_reconstruct_forward(came_from, start_stop_id, prev_stop_id, [segment | acc])
    end
  end

  # Walking came_from on the reversed graph from `target` back to `start` yields
  # the exact forward directed segments from `target` to `start`.
  defp reconstruct_reverse_segments(came_from, start_stop_id, end_stop_id) do
    do_reconstruct_reverse(came_from, start_stop_id, end_stop_id, [])
  end

  defp do_reconstruct_reverse(_came_from, end_stop_id, end_stop_id, acc), do: Enum.reverse(acc)

  defp do_reconstruct_reverse(came_from, current_stop_id, end_stop_id, acc) do
    case Map.get(came_from, current_stop_id) do
      nil ->
        Enum.reverse(acc)

      %{prev_stop_id: next_stop_id, pathway_id: pathway_id, pathway_mode: pathway_mode} ->
        segment = %{
          from_stop_id: current_stop_id,
          to_stop_id: next_stop_id,
          pathway_id: pathway_id,
          pathway_mode: pathway_mode
        }

        do_reconstruct_reverse(came_from, next_stop_id, end_stop_id, [segment | acc])
    end
  end

  defp reverse_pathways(pathways) do
    Enum.map(pathways, fn pathway ->
      %{
        pathway_id: pathway.pathway_id,
        pathway_mode: pathway.pathway_mode,
        from_stop_id: pathway.to_stop_id,
        to_stop_id: pathway.from_stop_id,
        is_bidirectional: Map.get(pathway, :is_bidirectional, false)
      }
    end)
  end

  # --- Pairs & entries ---

  defp build_pairs(
         entrances,
         platforms,
         platform_target_index,
         fwd_trees,
         rev_trees,
         elevator_by_pathway_id
       ) do
    for entrance <- entrances,
        platform <- platforms do
      build_pair(
        entrance,
        platform,
        platform_target_index,
        fwd_trees,
        rev_trees,
        elevator_by_pathway_id
      )
    end
  end

  defp build_pair(
         entrance,
         platform,
         platform_target_index,
         fwd_trees,
         rev_trees,
         elevator_by_pathway_id
       ) do
    targets = platform_targets(platform_target_index, platform.stop_id)
    fwd_tree = Map.fetch!(fwd_trees, entrance.stop_id)
    rev_tree = Map.fetch!(rev_trees, entrance.stop_id)

    {to_platform_status, to_platform_ids, to_platform_unverified} =
      extract_direction_result(
        best_target(fwd_tree, targets),
        fwd_tree.came_from,
        entrance.stop_id,
        :forward
      )

    {to_exit_status, to_exit_ids, to_exit_unverified} =
      extract_direction_result(
        best_target(rev_tree, targets),
        rev_tree.came_from,
        entrance.stop_id,
        :reverse
      )

    status = combine_round_trip_status(to_platform_status, to_exit_status)

    one_way_only? =
      status == :no_route and (to_platform_status != :no_route or to_exit_status != :no_route)

    elevator_ids =
      if status in [:confirmed, :unverified] do
        (to_platform_ids ++ to_exit_ids)
        |> Enum.map(&Map.get(elevator_by_pathway_id, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
      else
        []
      end

    %{
      entrance_stop_id: entrance.stop_id,
      entrance_name: stop_display_name(entrance),
      platform_stop_id: platform.stop_id,
      platform_name: stop_display_name(platform),
      status: status,
      to_platform_status: to_platform_status,
      to_exit_status: to_exit_status,
      one_way_only?: one_way_only?,
      to_platform_pathway_ids: to_platform_ids,
      to_exit_pathway_ids: to_exit_ids,
      elevator_ids: elevator_ids,
      unverified_edge_count: to_platform_unverified + to_exit_unverified
    }
  end

  defp combine_round_trip_status(:confirmed, :confirmed), do: :confirmed

  defp combine_round_trip_status(a, b) when a != :no_route and b != :no_route, do: :unverified

  defp combine_round_trip_status(_a, _b), do: :no_route

  defp extract_direction_result(:not_found, _came_from, _entrance_stop_id, _dir) do
    {:no_route, [], 0}
  end

  defp extract_direction_result(
         {:ok, target_id, {unverified_count, _hops, _sorted_ids} = cost},
         came_from,
         entrance_stop_id,
         direction
       ) do
    segments =
      case direction do
        :forward -> reconstruct_forward_segments(came_from, entrance_stop_id, target_id)
        :reverse -> reconstruct_reverse_segments(came_from, target_id, entrance_stop_id)
      end

    {cost_status(cost), Enum.map(segments, & &1.pathway_id), unverified_count}
  end

  defp count_pair_confidence(pairs) do
    Enum.reduce(pairs, %{confirmed: 0, unverified: 0, no_route: 0}, fn pair, acc ->
      Map.update!(acc, pair.status, &(&1 + 1))
    end)
  end

  defp build_entrance_entry(stop, station, level_index, step_free_entrance_ids) do
    level = level_for_stop(stop, level_index)

    %{
      id: Map.get(stop, :id),
      stop_id: stop.stop_id,
      stop_name: Map.get(stop, :stop_name),
      name: stop_display_name(stop),
      location_type: stop.location_type,
      level_id: Map.get(stop, :level_id),
      level_name: level && Map.get(level, :level_name),
      level_index: level && Map.get(level, :level_index),
      wheelchair_boarding: Map.get(stop, :wheelchair_boarding),
      wheelchair_resolved: resolve_wheelchair(stop, station),
      diagram_coordinate: Map.get(stop, :diagram_coordinate),
      step_free?: MapSet.member?(step_free_entrance_ids, stop.stop_id),
      stop: stop
    }
  end

  defp build_platform_entry(stop, station, level_index, routes_by_stop) do
    level = level_for_stop(stop, level_index)

    %{
      id: Map.get(stop, :id),
      stop_id: stop.stop_id,
      stop_name: Map.get(stop, :stop_name),
      name: stop_display_name(stop),
      location_type: stop.location_type,
      level_id: Map.get(stop, :level_id),
      level_name: level && Map.get(level, :level_name),
      level_index: level && Map.get(level, :level_index),
      wheelchair_boarding: Map.get(stop, :wheelchair_boarding),
      wheelchair_resolved: resolve_wheelchair(stop, station),
      diagram_coordinate: Map.get(stop, :diagram_coordinate),
      routes: Map.get(routes_by_stop, stop.stop_id, []),
      stop: stop
    }
  end

  # --- Issues (CR-M1, CR-D1, CR-D2, CR-D3, D-1) ---

  defp build_issues(ctx) do
    (build_single_elevator_issues(ctx.elevators, ctx.edges) ++
       build_barrier_issues(ctx) ++
       build_unknown_data_issues(ctx.edges, ctx.pairs, ctx.level_index) ++
       build_flag_mismatch_issues(ctx.station, ctx.platforms, ctx.pairs) ++
       build_near_threshold_issues(ctx.edges, ctx.pairs))
    |> Enum.sort_by(fn issue -> {-issue.affected_pairs, kind_rank(issue.kind), issue.id} end)
  end

  defp kind_rank(:barrier), do: 1
  defp kind_rank(:single_elevator), do: 2
  defp kind_rank(:flag_mismatch), do: 3
  defp kind_rank(:unknown_data), do: 4
  defp kind_rank(:near_threshold), do: 5

  defp build_single_elevator_issues(elevators, edges) do
    edge_by_pathway_id = Map.new(edges, &{&1.pathway_id, &1})

    elevators
    |> Enum.filter(&(&1.sole_link_pairs > 0))
    |> Enum.map(fn elevator ->
      primary_edge = Map.get(edge_by_pathway_id, elevator.primary_pathway.pathway_id)

      %{
        id: "single_elevator:" <> elevator.id,
        kind: :single_elevator,
        severity: :warning,
        affected_pairs: elevator.sole_link_pairs,
        title: "Single elevator dependency: #{elevator.label}",
        description:
          "#{elevator.label} (#{elevator.connects}) is the only step-free link for " <>
            "#{elevator.sole_link_pairs} #{pluralize_pair(elevator.sole_link_pairs)}.",
        elevator_id: elevator.id,
        pathway_ids: elevator.pathway_ids,
        primary_pathway_id: elevator.primary_pathway.pathway_id,
        primary_pathway_uuid: Map.get(elevator.primary_pathway, :id),
        level_id: primary_edge && (primary_edge.from_level_id || primary_edge.to_level_id),
        target_type: :pathway
      }
    end)
  end

  defp build_barrier_issues(%{
         pathways: pathways,
         edges: edges,
         entrances: entrances,
         platform_target_index: platform_target_index,
         pairs: pairs
       }) do
    barrier_edges = Enum.filter(edges, &(&1.classification == :barrier))

    if barrier_edges == [] do
      []
    else
      type_only_pathways = Enum.filter(pathways, &Graph.step_free_mode?(&1.pathway_mode))
      barrier_ids = MapSet.new(barrier_edges, & &1.pathway_id)

      {type_fwd, type_rev} =
        compute_directional_trees(entrances, type_only_pathways, barrier_ids)

      blocked_counts =
        count_barrier_blocked_pairs(pairs, platform_target_index, type_fwd, type_rev)

      Enum.map(barrier_edges, &build_barrier_issue(&1, blocked_counts))
    end
  end

  defp count_barrier_blocked_pairs(pairs, platform_target_index, type_fwd, type_rev) do
    pairs
    |> Enum.filter(&(&1.status == :no_route))
    |> Enum.reduce(%{}, fn pair, acc ->
      pair
      |> pair_type_only_pathway_ids(platform_target_index, type_fwd, type_rev)
      |> Enum.reduce(acc, fn pid, counts -> Map.update(counts, pid, 1, &(&1 + 1)) end)
    end)
  end

  defp pair_type_only_pathway_ids(pair, platform_target_index, type_fwd, type_rev) do
    targets = platform_targets(platform_target_index, pair.platform_stop_id)
    fwd_tree = Map.fetch!(type_fwd, pair.entrance_stop_id)
    rev_tree = Map.fetch!(type_rev, pair.entrance_stop_id)

    with {:ok, fwd_target, _} <- best_target(fwd_tree, targets),
         {:ok, rev_target, _} <- best_target(rev_tree, targets) do
      fwd_ids =
        fwd_tree.came_from
        |> reconstruct_forward_segments(pair.entrance_stop_id, fwd_target)
        |> Enum.map(& &1.pathway_id)

      rev_ids =
        rev_tree.came_from
        |> reconstruct_reverse_segments(rev_target, pair.entrance_stop_id)
        |> Enum.map(& &1.pathway_id)

      Enum.uniq(fwd_ids ++ rev_ids)
    else
      :not_found -> []
    end
  end

  defp build_barrier_issue(edge, blocked_counts) do
    affected = Map.get(blocked_counts, edge.pathway_id, 0)
    reasons = format_barrier_reasons(edge.pathway, edge.barriers)

    %{
      id: "barrier:" <> edge.pathway_id,
      kind: :barrier,
      severity: :error,
      affected_pairs: affected,
      title: "Measured barrier: #{edge.pathway_id} (#{edge.pathway_mode_label})",
      description:
        "#{edge.pathway_id} fails ADA step-free limits (#{reasons}); " <>
          "blocks #{affected} type-only step-free #{pluralize_pair(affected)}.",
      barriers: edge.barriers,
      measurements: %{
        max_slope: Map.get(edge.pathway, :max_slope),
        min_width: Map.get(edge.pathway, :min_width)
      },
      pathway_ids: [edge.pathway_id],
      primary_pathway_id: edge.pathway_id,
      primary_pathway_uuid: edge.id,
      level_id: edge.from_level_id || edge.to_level_id,
      target_type: :pathway
    }
  end

  defp format_barrier_reasons(pathway, barriers) do
    thresholds = Pathway.accessibility_thresholds()

    Enum.map_join(barriers, "; ", fn
      :slope ->
        "max_slope #{Decimal.to_string(pathway.max_slope)} exceeds " <>
          "#{Decimal.to_string(thresholds.max_slope)} (1:12 limit)"

      :width ->
        "min_width #{Decimal.to_string(pathway.min_width)} m is below " <>
          "#{Decimal.to_string(thresholds.min_width)} m (32 in. limit)"
    end)
  end

  defp build_unknown_data_issues(edges, pairs, level_index) do
    pair_pathway_sets =
      pairs
      |> Enum.filter(&(&1.status == :unverified))
      |> Enum.map(&MapSet.new(&1.to_platform_pathway_ids ++ &1.to_exit_pathway_ids))

    edges
    |> Enum.filter(&(&1.classification == :unverified))
    |> Enum.group_by(&{&1.missing_fields, &1.pathway_mode, level_or_level_pair(&1)})
    |> Enum.map(fn {group_key, group_edges} ->
      build_unknown_data_issue(group_key, group_edges, pair_pathway_sets, level_index)
    end)
  end

  defp build_unknown_data_issue(
         {missing_fields, pathway_mode, level_key},
         group_edges,
         pair_pathway_sets,
         level_index
       ) do
    sorted_edges = Enum.sort_by(group_edges, & &1.pathway_id)
    pathway_ids = Enum.map(sorted_edges, & &1.pathway_id)
    group_id_set = MapSet.new(pathway_ids)
    primary = hd(sorted_edges)
    mode_label = Pathway.mode_label(pathway_mode)
    level_label = format_level_key(level_key, level_index)
    edge_count = length(sorted_edges)
    grouped? = edge_count > 1

    affected_pairs =
      Enum.count(pair_pathway_sets, &(not MapSet.disjoint?(&1, group_id_set)))

    {title, description} =
      unknown_data_copy(
        grouped?,
        primary,
        mode_label,
        level_label,
        edge_count,
        format_missing_fields(missing_fields),
        affected_pairs
      )

    %{
      id: "unknown_data:" <> hd(pathway_ids),
      kind: :unknown_data,
      severity: :unverified,
      affected_pairs: affected_pairs,
      title: title,
      description: description,
      missing_fields: missing_fields,
      pathway_mode: pathway_mode,
      pathway_mode_label: mode_label,
      level_or_level_pair: level_key,
      level_label: level_label,
      edge_count: edge_count,
      grouped?: grouped?,
      pathway_ids: pathway_ids,
      primary_pathway_id: primary.pathway_id,
      primary_pathway_uuid: primary.id,
      level_id: primary.from_level_id || primary.to_level_id,
      target_type: :pathway
    }
  end

  defp unknown_data_copy(
         true,
         _primary,
         mode_label,
         level_label,
         edge_count,
         missing_text,
         affected_pairs
       ) do
    downcased_mode = String.downcase(mode_label)

    {
      "#{missing_text} missing on #{edge_count} #{downcased_mode} pathways (#{level_label})",
      "#{edge_count} #{downcased_mode} pathways on #{level_label} are missing #{missing_text}, " <>
        "leaving #{affected_pairs} #{pluralize_pair(affected_pairs)} unverified."
    }
  end

  defp unknown_data_copy(
         false,
         primary,
         mode_label,
         level_label,
         _edge_count,
         missing_text,
         affected_pairs
       ) do
    {
      "#{primary.pathway_id} (#{mode_label}): missing #{missing_text}",
      "#{primary.pathway_id} (#{mode_label}, #{level_label}) is missing #{missing_text}, " <>
        "leaving #{affected_pairs} #{pluralize_pair(affected_pairs)} unverified."
    }
  end

  defp level_or_level_pair(%{from_level_id: l1, to_level_id: l2}) when l1 == l2, do: {:single, l1}

  defp level_or_level_pair(%{from_level_id: l1, to_level_id: l2}) do
    [a, b] = Enum.sort_by([l1, l2], &{is_nil(&1), &1})
    {:pair, a, b}
  end

  defp format_level_key({:single, nil}, _level_index), do: "unassigned level"

  defp format_level_key({:single, level_id}, level_index) do
    level_label_for_id(level_id, level_index)
  end

  defp format_level_key({:pair, l1, l2}, level_index) do
    "#{level_label_for_id(l1, level_index)} \u2194 #{level_label_for_id(l2, level_index)}"
  end

  defp level_label_for_id(nil, _level_index), do: "unassigned level"

  defp level_label_for_id(level_id, level_index) do
    case Map.get(level_index, level_id) do
      nil -> level_id
      level -> Map.get(level, :level_name) || level.level_id
    end
  end

  defp format_missing_fields(fields) do
    Enum.map_join(fields, ", ", fn
      :min_width -> "min_width"
      :max_slope -> "max_slope"
      :traversal_time -> "traversal_time"
      :traversal_time_or_length -> "traversal_time or length"
      :endpoint_level_id -> "endpoint level_id"
      other -> to_string(other)
    end)
  end

  defp build_flag_mismatch_issues(station, platforms, pairs) do
    pairs_by_platform = Enum.group_by(pairs, & &1.platform_stop_id)

    Enum.flat_map(platforms, fn platform ->
      platform_flag_mismatch_issue(platform, station, pairs_by_platform)
    end)
  end

  defp platform_flag_mismatch_issue(platform, station, pairs_by_platform) do
    resolved = resolve_wheelchair(platform, station)
    platform_pairs = Map.get(pairs_by_platform, platform.stop_id, [])

    if resolved.status != :accessible or Enum.any?(platform_pairs, &(&1.status == :confirmed)) do
      []
    else
      has_unverified? = Enum.any?(platform_pairs, &(&1.status == :unverified))
      cause = if(has_unverified?, do: :unconfirmed_only, else: :no_step_free_route)
      name = stop_display_name(platform)

      source_text =
        if(resolved.source == :inherited, do: "inherited from station", else: "direct")

      [
        %{
          id: "flag_mismatch:" <> platform.stop_id,
          kind: :flag_mismatch,
          severity: :error,
          affected_pairs: length(platform_pairs),
          title: "Flag mismatch: #{name}",
          description: flag_mismatch_description(cause, name, source_text),
          cause: cause,
          wheelchair_source: resolved.source,
          stop_id: platform.stop_id,
          stop_uuid: Map.get(platform, :id),
          target_type: :stop
        }
      ]
    end
  end

  defp flag_mismatch_description(:unconfirmed_only, name, source_text) do
    "#{name} resolves as wheelchair accessible (#{source_text}), " <>
      "but only unverified step-free routes reach it and none are confirmed."
  end

  defp flag_mismatch_description(:no_step_free_route, name, source_text) do
    "#{name} resolves as wheelchair accessible (#{source_text}), " <>
      "but no entrance has a step-free round-trip route to it."
  end

  defp build_near_threshold_issues(edges, pairs) do
    near_edges =
      Enum.filter(edges, fn edge ->
        barrier_free_edge?(edge) and edge.near_threshold_fields != []
      end)

    if near_edges == [] do
      []
    else
      pair_pathway_sets =
        pairs
        |> Enum.filter(&(&1.status in [:confirmed, :unverified]))
        |> Enum.map(&MapSet.new(&1.to_platform_pathway_ids ++ &1.to_exit_pathway_ids))

      Enum.map(near_edges, fn edge ->
        affected = Enum.count(pair_pathway_sets, &MapSet.member?(&1, edge.pathway_id))
        details = format_near_threshold_details(edge.pathway, edge.near_threshold_fields)

        %{
          id: "near_threshold:" <> edge.pathway_id,
          kind: :near_threshold,
          severity: :warning,
          affected_pairs: affected,
          title: "Near threshold: #{edge.pathway_id} (#{edge.pathway_mode_label})",
          description:
            "#{edge.pathway_id} is close to ADA limits (#{details}) on " <>
              "#{affected} reachable #{pluralize_pair(affected)}.",
          near_threshold_fields: edge.near_threshold_fields,
          pathway_ids: [edge.pathway_id],
          primary_pathway_id: edge.pathway_id,
          primary_pathway_uuid: edge.id,
          level_id: edge.from_level_id || edge.to_level_id,
          target_type: :pathway
        }
      end)
    end
  end

  defp format_near_threshold_details(pathway, fields) do
    thresholds = Pathway.accessibility_thresholds()

    Enum.map_join(fields, "; ", fn
      :slope ->
        "max_slope #{Decimal.to_string(pathway.max_slope)} approaches " <>
          "#{Decimal.to_string(thresholds.max_slope)} (1:12 ADA ramp limit)"

      :width ->
        "min_width #{Decimal.to_string(pathway.min_width)} m is near " <>
          "#{Decimal.to_string(thresholds.comfort_width)} m (36 in. continuous width)"
    end)
  end

  # --- On-demand route pricing (build_route/4 only) ---

  defp compute_and_price_route(ctx) do
    platform_target_index = Graph.build_platform_target_index(ctx.child_stops)
    classified_edges = classify_edges(ctx.pathways, ctx.stop_index, ctx.level_index)
    barrier_free_edges = Enum.filter(classified_edges, &barrier_free_edge?/1)
    barrier_free_pathways = Enum.map(barrier_free_edges, & &1.pathway)
    unverified_ids = unverified_pathway_ids(barrier_free_edges)

    fwd_adj = Graph.build_path_traversal_adjacency(barrier_free_pathways)
    rev_adj = Graph.build_path_traversal_adjacency(reverse_pathways(barrier_free_pathways))

    fwd_tree = shortest_unverified_tree(ctx.entrance_stop.stop_id, fwd_adj, unverified_ids)
    rev_tree = shortest_unverified_tree(ctx.entrance_stop.stop_id, rev_adj, unverified_ids)

    targets = platform_targets(platform_target_index, ctx.platform_stop.stop_id)

    with {:ok, to_platform_target, to_platform_cost} <- best_target(fwd_tree, targets),
         {:ok, to_exit_target, to_exit_cost} <- best_target(rev_tree, targets) do
      segments =
        select_route_segments(
          ctx.direction,
          fwd_tree.came_from,
          rev_tree.came_from,
          ctx.entrance_stop.stop_id,
          to_platform_target,
          to_exit_target
        )

      build_priced_route_result(
        ctx,
        barrier_free_edges,
        segments,
        cost_status(to_platform_cost),
        cost_status(to_exit_cost)
      )
    else
      :not_found -> :no_route
    end
  end

  defp select_route_segments(:to_exit, _fwd_cf, rev_cf, entrance_id, _to_plat, to_exit) do
    reconstruct_reverse_segments(rev_cf, to_exit, entrance_id)
  end

  defp select_route_segments(_direction, fwd_cf, _rev_cf, entrance_id, to_plat, _to_exit) do
    reconstruct_forward_segments(fwd_cf, entrance_id, to_plat)
  end

  defp build_priced_route_result(
         ctx,
         barrier_free_edges,
         segments,
         to_platform_status,
         to_exit_status
       ) do
    edge_by_pathway_id = Map.new(barrier_free_edges, &{&1.pathway_id, &1})

    {elevators, elevator_by_pathway_id} =
      build_elevator_components(barrier_free_edges, ctx.stop_index, ctx.level_index)

    elevator_by_id = Map.new(elevators, &{&1.id, &1})
    normalized_levels = normalize_levels_for_traversal(ctx.levels)

    steps =
      segments
      |> Enum.with_index(1)
      |> Enum.map(fn {segment, index} ->
        build_priced_step(
          segment,
          index,
          edge_by_pathway_id,
          elevator_by_pathway_id,
          elevator_by_id,
          ctx.stop_index,
          ctx.level_index,
          normalized_levels
        )
      end)

    {distance_meters, duration_seconds} = sum_step_metrics(steps)

    elevator_ids =
      steps
      |> Enum.map(& &1.elevator_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      status: combine_round_trip_status(to_platform_status, to_exit_status),
      direction: ctx.direction,
      entrance_stop_id: ctx.entrance_stop.stop_id,
      platform_stop_id: ctx.platform_stop.stop_id,
      entrance_name: stop_display_name(ctx.entrance_stop),
      platform_name: stop_display_name(ctx.platform_stop),
      to_platform_status: to_platform_status,
      to_exit_status: to_exit_status,
      distance_meters: Float.round(distance_meters, 2),
      duration_seconds: Float.round(duration_seconds, 2),
      elevator_ids: elevator_ids,
      steps: steps
    }
  end

  defp build_priced_step(
         segment,
         index,
         edge_by_pathway_id,
         elevator_by_pathway_id,
         elevator_by_id,
         stop_index,
         level_index,
         normalized_levels
       ) do
    edge = Map.fetch!(edge_by_pathway_id, segment.pathway_id)
    pathway = edge.pathway
    from_stop = Map.get(stop_index, segment.from_stop_id)
    to_stop = Map.get(stop_index, segment.to_stop_id)
    from_level = level_for_stop(from_stop, level_index)
    to_level = level_for_stop(to_stop, level_index)
    traversed_reverse? = segment_reversed?(pathway, segment)
    traversal = price_pathway_segment(pathway, from_stop, to_stop, normalized_levels)
    elevator_id = Map.get(elevator_by_pathway_id, edge.pathway_id)
    from_level_id = stop_level_id(from_stop)
    to_level_id = stop_level_id(to_stop)

    %{
      index: index,
      pathway_id: edge.pathway_id,
      pathway_uuid: edge.id,
      pathway_mode: edge.pathway_mode,
      pathway_mode_label: edge.pathway_mode_label,
      classification: edge.classification,
      missing_fields: edge.missing_fields,
      near_threshold_fields: edge.near_threshold_fields,
      is_ramp: edge.is_ramp,
      from_stop_id: segment.from_stop_id,
      from_stop_name: stop_display_name(from_stop) || segment.from_stop_id,
      to_stop_id: segment.to_stop_id,
      to_stop_name: stop_display_name(to_stop) || segment.to_stop_id,
      from_level_id: from_level_id,
      to_level_id: to_level_id,
      level_id: from_level_id || to_level_id,
      level_name: level_name(from_level) || level_name(to_level),
      to_level_name: level_name(to_level),
      is_bidirectional: edge.is_bidirectional,
      traversed_reverse?: traversed_reverse?,
      signposted_as: step_signpost(pathway, traversed_reverse?),
      max_slope: Map.get(pathway, :max_slope),
      min_width: Map.get(pathway, :min_width),
      elevator_id: elevator_id,
      elevator_label: elevator_label(elevator_id, elevator_by_id),
      distance_meters: step_distance_meters(edge.pathway_mode, traversal),
      duration_seconds: traversal && traversal.time_seconds,
      pathway: pathway
    }
  end

  defp segment_reversed?(pathway, segment) do
    pathway.from_stop_id == segment.to_stop_id and pathway.to_stop_id == segment.from_stop_id
  end

  defp stop_level_id(nil), do: nil
  defp stop_level_id(stop), do: Values.presence(Map.get(stop, :level_id))

  defp level_name(nil), do: nil
  defp level_name(level), do: Map.get(level, :level_name)

  defp step_signpost(pathway, true),
    do: Values.presence(Map.get(pathway, :reversed_signposted_as))

  defp step_signpost(pathway, false), do: Values.presence(Map.get(pathway, :signposted_as))

  defp elevator_label(nil, _elevator_by_id), do: nil
  defp elevator_label(id, elevator_by_id), do: get_in(elevator_by_id, [id, :label])

  defp step_distance_meters(5, _traversal), do: nil
  defp step_distance_meters(_mode, %{distance_meters: dist}), do: dist
  defp step_distance_meters(_mode, _traversal), do: nil

  defp price_pathway_segment(pathway, from_stop, to_stop, normalized_levels)
       when not is_nil(from_stop) and not is_nil(to_stop) do
    normalized_pathway = Map.put_new(pathway, :is_bidirectional, false)

    case PathwayTraversal.traverse(
           normalized_pathway,
           normalize_stop_for_traversal(from_stop),
           normalize_stop_for_traversal(to_stop),
           normalized_levels
         ) do
      {:ok, traversal} -> traversal
      {:error, _reason} -> nil
    end
  end

  defp price_pathway_segment(_pathway, _from_stop, _to_stop, _levels), do: nil

  defp normalize_stop_for_traversal(stop) do
    %{
      stop_id: stop.stop_id,
      stop_name: Map.get(stop, :stop_name),
      stop_desc: Map.get(stop, :stop_desc),
      stop_lat: Map.get(stop, :stop_lat),
      stop_lon: Map.get(stop, :stop_lon),
      location_type: Map.get(stop, :location_type, 0),
      wheelchair_boarding: Map.get(stop, :wheelchair_boarding),
      parent_station: Map.get(stop, :parent_station),
      level_id: Map.get(stop, :level_id)
    }
  end

  defp normalize_levels_for_traversal(levels) do
    Enum.map(levels, fn
      %{level: level} ->
        %{level: normalize_level_map(level)}

      level when is_map(level) ->
        %{level: normalize_level_map(level)}
    end)
  end

  defp normalize_level_map(level) do
    %{
      level_id: level.level_id,
      level_index: Map.get(level, :level_index, 0.0),
      level_name: Map.get(level, :level_name)
    }
  end

  defp sum_step_metrics(steps) do
    Enum.reduce(steps, {0.0, 0.0}, fn step, {dist_acc, dur_acc} ->
      dist = if(is_number(step.distance_meters), do: step.distance_meters, else: 0.0)
      dur = if(is_number(step.duration_seconds), do: step.duration_seconds, else: 0.0)
      {dist_acc + dist, dur_acc + dur}
    end)
  end

  # --- General helpers ---

  defp platform_targets(platform_target_index, platform_stop_id) do
    Map.get(platform_target_index, platform_stop_id, MapSet.new([platform_stop_id]))
  end

  defp stops_with_location_type(child_stops, location_type) do
    child_stops
    |> Enum.filter(&(Map.get(&1, :location_type) == location_type))
    |> Enum.sort_by(& &1.stop_id)
  end

  defp build_stop_index(stops) do
    Map.new(stops, &{&1.stop_id, &1})
  end

  defp build_level_index(levels) do
    levels
    |> Enum.map(fn
      %{level: level} -> level
      level when is_map(level) -> level
    end)
    |> Map.new(&{&1.level_id, &1})
  end

  defp level_for_stop(nil, _level_index), do: nil

  defp level_for_stop(stop, level_index) do
    case Map.get(stop, :level_id) do
      nil -> nil
      level_id -> Map.get(level_index, level_id)
    end
  end

  defp resolve_wheelchair(stop, station) do
    Stop.resolve_wheelchair_boarding(to_stop_struct(stop), to_stop_struct(station))
  end

  defp to_stop_struct(%Stop{} = stop), do: stop
  defp to_stop_struct(nil), do: nil
  defp to_stop_struct(map) when is_map(map), do: struct(Stop, map)

  defp stop_display_name(nil), do: nil

  defp stop_display_name(stop) do
    Values.presence(Map.get(stop, :stop_name)) || Map.get(stop, :stop_id)
  end

  defp pluralize_pair(1), do: "pair"
  defp pluralize_pair(_count), do: "pairs"
end
