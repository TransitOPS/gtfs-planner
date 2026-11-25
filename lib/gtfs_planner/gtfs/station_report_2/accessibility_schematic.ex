defmodule GtfsPlanner.Gtfs.StationReport2.AccessibilitySchematic do
  @moduledoc """
  Pure deterministic cross-level SVG swimlane layout generator for station
  accessibility schematics.

  Orders swimlanes vertically by `level_index` descending (splitting levels
  into `Unpaid` and `Paid` sub-bands when fare gates exist and both zones
  appear on that level) and orders nodes horizontally by floorplan
  `diagram_coordinate.x` with entrance-to-platform BFS discovery order then
  `stop_id` as fallback (`CR-C4`, `AC-6`). Never inspects `stop_name` for
  layout or band placement (`INV-3`).
  """

  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.StationReport2.AccessibilityGrouping
  alias GtfsPlanner.Values

  @side_padding 120.0
  @top_padding 24.0
  @bottom_padding 24.0
  @node_spacing_x 248.0
  @node_width 144.0
  @node_height 40.0
  @min_node_gap 188.0
  @sub_band_height 92.0
  @lane_gap 34.0
  @min_width 680.0
  @min_height 220.0
  @parallel_offset_step 22.0

  @default_highlights %{
    barriers: false,
    unknown_data: false,
    near_threshold: false,
    single_elevator: false
  }

  @type mode :: :rider | :validation

  @doc """
  Builds a deterministic, non-overlapping cross-level SVG swimlane layout for
  the given station `snapshot` and `Accessibility.build/2` `analysis`.

  Options:
    * `:mode` - `:rider` (default) or `:validation`
    * `:highlights` - map of `%{barriers: bool, unknown_data: bool, near_threshold: bool, single_elevator: bool}`
    * `:fare_zones` - optional precomputed output of `AccessibilityGrouping.partition_fare_zones/1`
  """
  @spec build_layout(map(), map(), keyword() | map()) :: %{
          width: float(),
          height: float(),
          view_box: String.t(),
          mode: mode(),
          highlights: map(),
          has_fare_gates?: boolean(),
          lanes: [map()],
          nodes: [map()],
          edges: [map()],
          legend: [atom()]
        }
  def build_layout(snapshot, analysis, opts \\ []) when is_map(snapshot) and is_map(analysis) do
    opts_map = Map.new(opts)
    mode = normalize_mode(Map.get(opts_map, :mode))
    highlights = normalize_highlights(mode, Map.get(opts_map, :highlights))
    show_barriers? = mode == :validation and highlights.barriers

    fare_zones =
      Map.get(opts_map, :fare_zones) || AccessibilityGrouping.partition_fare_zones(snapshot)

    level_index = build_level_index(Map.get(snapshot, :levels, []))

    visible_analysis_edges =
      analysis
      |> Map.get(:edges, [])
      |> Enum.filter(&edge_visible?(&1, show_barriers?))

    visible_stops =
      select_visible_stops(snapshot, analysis, visible_analysis_edges, show_barriers?)

    visible_stop_ids = MapSet.new(visible_stops, & &1.stop_id)

    renderable_edges =
      Enum.filter(visible_analysis_edges, fn edge ->
        MapSet.member?(visible_stop_ids, edge.from_stop_id) and
          MapSet.member?(visible_stop_ids, edge.to_stop_id)
      end)

    bfs_order = compute_bfs_discovery_order(visible_stops, renderable_edges)

    lane_specs = build_lane_specs(visible_stops, level_index, fare_zones, bfs_order)

    {width, height, lanes, nodes} =
      position_lanes_and_nodes(lane_specs, analysis, renderable_edges)

    node_by_id = Map.new(nodes, &{&1.stop_id, &1})

    edges =
      build_positioned_edges(
        renderable_edges,
        node_by_id,
        mode,
        highlights
      )

    %{
      width: width,
      height: height,
      view_box: "0 0 #{format_num(width)} #{format_num(height)}",
      mode: mode,
      highlights: highlights,
      has_fare_gates?: fare_zones.has_fare_gates?,
      lanes: lanes,
      nodes: nodes,
      edges: edges,
      legend: build_legend(edges)
    }
  end

  # --- Options normalization ---

  defp normalize_mode(:validation), do: :validation
  defp normalize_mode(_), do: :rider

  defp normalize_highlights(:rider, _highlights), do: @default_highlights

  defp normalize_highlights(:validation, highlights) when is_map(highlights) do
    %{
      barriers: Map.get(highlights, :barriers, false) == true,
      unknown_data: Map.get(highlights, :unknown_data, false) == true,
      near_threshold: Map.get(highlights, :near_threshold, false) == true,
      single_elevator: Map.get(highlights, :single_elevator, false) == true
    }
  end

  defp normalize_highlights(:validation, _highlights), do: @default_highlights

  # --- Visibility filtering ---

  defp edge_visible?(%{classification: cls}, _show_barriers?)
       when cls in [:confirmed, :unverified],
       do: true

  defp edge_visible?(%{classification: cls}, true) when cls in [:barrier, :not_step_free],
    do: true

  defp edge_visible?(_edge, _show_barriers?), do: false

  defp select_visible_stops(snapshot, analysis, visible_edges, show_barriers?) do
    child_stops = Map.get(snapshot, :child_stops, [])
    stop_by_id = Map.new(child_stops, &{&1.stop_id, &1})

    step_free_entrance_ids =
      analysis
      |> Map.get(:step_free_entrances, [])
      |> MapSet.new(& &1.stop_id)

    inaccessible_entrance_ids =
      analysis
      |> Map.get(:inaccessible_entrances, [])
      |> MapSet.new(& &1.stop_id)

    platform_ids =
      analysis
      |> Map.get(:platforms, [])
      |> MapSet.new(& &1.stop_id)

    edge_endpoint_ids =
      visible_edges
      |> Enum.filter(fn edge ->
        Map.has_key?(stop_by_id, edge.from_stop_id) and
          Map.has_key?(stop_by_id, edge.to_stop_id) and
          (show_barriers? or
             (not MapSet.member?(inaccessible_entrance_ids, edge.from_stop_id) and
                not MapSet.member?(inaccessible_entrance_ids, edge.to_stop_id)))
      end)
      |> Enum.flat_map(&[&1.from_stop_id, &1.to_stop_id])
      |> MapSet.new()

    base_ids =
      step_free_entrance_ids
      |> MapSet.union(platform_ids)
      |> then(fn set ->
        if show_barriers?, do: MapSet.union(set, inaccessible_entrance_ids), else: set
      end)

    intermediate_ids =
      child_stops
      |> Enum.filter(fn stop ->
        Map.get(stop, :location_type) in [3, 4] and
          MapSet.member?(edge_endpoint_ids, stop.stop_id)
      end)
      |> MapSet.new(& &1.stop_id)

    base_ids
    |> MapSet.union(intermediate_ids)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.flat_map(fn stop_id ->
      case Map.get(stop_by_id, stop_id) do
        nil -> []
        stop -> [stop]
      end
    end)
  end

  # --- Entrance-to-platform BFS discovery order (CR-C4 fallback) ---

  defp compute_bfs_discovery_order(visible_stops, renderable_edges) do
    directed = build_sorted_directed_adj(renderable_edges)
    undirected = build_sorted_undirected_adj(renderable_edges)

    entrance_seeds =
      visible_stops
      |> Enum.filter(&(Map.get(&1, :location_type) == 2))
      |> Enum.sort_by(&seed_sort_key/1)
      |> Enum.map(& &1.stop_id)

    {order_map, counter} = run_ordered_bfs(entrance_seeds, directed, %{}, 0)

    # Secondary pass over undirected edges from already-discovered nodes so nodes
    # only attached via reverse/exit pathways still receive deterministic order.
    discovered_seeds =
      order_map
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    {order_map, _counter} = run_ordered_bfs(discovered_seeds, undirected, order_map, counter)
    order_map
  end

  defp seed_sort_key(stop) do
    case diagram_x(stop) do
      nil -> {1, 0.0, stop.stop_id}
      x -> {0, x, stop.stop_id}
    end
  end

  defp build_sorted_directed_adj(edges) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      acc = Map.update(acc, edge.from_stop_id, [edge.to_stop_id], &[edge.to_stop_id | &1])

      if edge.is_bidirectional do
        Map.update(acc, edge.to_stop_id, [edge.from_stop_id], &[edge.from_stop_id | &1])
      else
        acc
      end
    end)
    |> Map.new(fn {k, list} -> {k, list |> Enum.uniq() |> Enum.sort()} end)
  end

  defp build_sorted_undirected_adj(edges) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      acc
      |> Map.update(edge.from_stop_id, [edge.to_stop_id], &[edge.to_stop_id | &1])
      |> Map.update(edge.to_stop_id, [edge.from_stop_id], &[edge.from_stop_id | &1])
    end)
    |> Map.new(fn {k, list} -> {k, list |> Enum.uniq() |> Enum.sort()} end)
  end

  defp run_ordered_bfs(seeds, adjacency, initial_order, initial_counter) do
    {queue, order_map, counter} =
      Enum.reduce(seeds, {:queue.new(), initial_order, initial_counter}, fn seed, {q, ord, c} ->
        if Map.has_key?(ord, seed) do
          {:queue.in(seed, q), ord, c}
        else
          {:queue.in(seed, q), Map.put(ord, seed, c), c + 1}
        end
      end)

    do_ordered_bfs(queue, adjacency, order_map, counter)
  end

  defp do_ordered_bfs(queue, adjacency, order_map, counter) do
    case :queue.out(queue) do
      {{:value, current}, rest} ->
        neighbors = Map.get(adjacency, current, [])

        {next_queue, next_order, next_counter} =
          visit_neighbors(neighbors, rest, order_map, counter)

        do_ordered_bfs(next_queue, adjacency, next_order, next_counter)

      {:empty, _} ->
        {order_map, counter}
    end
  end

  defp visit_neighbors(neighbors, queue, order_map, counter) do
    Enum.reduce(neighbors, {queue, order_map, counter}, fn neighbor, {q, ord, c} ->
      if Map.has_key?(ord, neighbor) do
        {q, ord, c}
      else
        {:queue.in(neighbor, q), Map.put(ord, neighbor, c), c + 1}
      end
    end)
  end

  # --- Lane & sub-band grouping ---

  defp build_lane_specs(visible_stops, level_index, fare_zones, bfs_order) do
    visible_stops
    |> Enum.group_by(&Map.get(&1, :level_id))
    |> Enum.sort_by(fn {level_id, _stops} -> level_sort_key(level_id, level_index) end)
    |> Enum.map(fn {level_id, stops} ->
      level = level_id && Map.get(level_index, level_id)
      level_name = level_display_name(level_id, level)
      idx = level && Values.to_float(Map.get(level, :level_index))

      {split?, sub_bands} = build_sub_bands(level_id, stops, fare_zones, bfs_order)

      %{
        id: "lane:" <> (level_id || "unassigned"),
        level_id: level_id,
        level_name: level_name,
        level_index: idx,
        split_fare_zones?: split?,
        sub_bands: sub_bands
      }
    end)
  end

  defp build_sub_bands(level_id, stops, fare_zones, bfs_order) do
    node_zones = fare_zones.node_zones
    has_unpaid? = Enum.any?(stops, &(Map.get(node_zones, &1.stop_id, :open) == :unpaid))
    has_paid? = Enum.any?(stops, &(Map.get(node_zones, &1.stop_id, :open) == :paid))
    split? = fare_zones.has_fare_gates? and has_unpaid? and has_paid?

    if split? do
      {paid_stops, unpaid_stops} =
        Enum.split_with(stops, &(Map.get(node_zones, &1.stop_id, :open) == :paid))

      sub_bands = [
        %{
          id: sub_band_id(level_id, :unpaid),
          fare_zone: :unpaid,
          label: "Unpaid",
          stops: sort_band_stops(unpaid_stops, bfs_order)
        },
        %{
          id: sub_band_id(level_id, :paid),
          fare_zone: :paid,
          label: "Paid",
          stops: sort_band_stops(paid_stops, bfs_order)
        }
      ]

      {true, sub_bands}
    else
      dominant_zone =
        cond do
          not fare_zones.has_fare_gates? -> :open
          has_paid? -> :paid
          has_unpaid? -> :unpaid
          true -> :open
        end

      sub_bands = [
        %{
          id: sub_band_id(level_id, dominant_zone),
          fare_zone: dominant_zone,
          label: nil,
          stops: sort_band_stops(stops, bfs_order)
        }
      ]

      {false, sub_bands}
    end
  end

  defp sub_band_id(level_id, zone), do: "subband:#{level_id || "unassigned"}:#{zone}"

  defp sort_band_stops(stops, bfs_order) do
    Enum.sort_by(stops, fn stop ->
      bfs_rank = Map.get(bfs_order, stop.stop_id, 1_000_000)

      case diagram_x(stop) do
        nil -> {1, 0.0, bfs_rank, stop.stop_id}
        x -> {0, x, bfs_rank, stop.stop_id}
      end
    end)
  end

  # --- Coordinate assignment ---

  defp position_lanes_and_nodes(lane_specs, analysis, renderable_edges) do
    max_per_band =
      lane_specs
      |> Enum.flat_map(& &1.sub_bands)
      |> Enum.map(&length(&1.stops))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    content_width =
      if max_per_band <= 1 do
        @node_width
      else
        (max_per_band - 1) * @node_spacing_x + @node_width
      end

    width = Float.round(max(@min_width, content_width + @side_padding * 2.0), 2)
    center_x = width / 2.0

    entrance_by_id = Map.new(Map.get(analysis, :entrances, []), &{&1.stop_id, &1})
    platform_by_id = Map.new(Map.get(analysis, :platforms, []), &{&1.stop_id, &1})

    {rev_lanes, rev_nodes, final_y} =
      Enum.reduce(lane_specs, {[], [], @top_padding}, fn lane_spec,
                                                         {lanes_acc, nodes_acc, cur_y} ->
        {sub_bands, lane_nodes, next_y} =
          position_sub_bands(
            lane_spec,
            cur_y,
            center_x,
            entrance_by_id,
            platform_by_id
          )

        lane_height = Float.round(next_y - cur_y, 2)

        lane = %{
          id: lane_spec.id,
          level_id: lane_spec.level_id,
          level_name: lane_spec.level_name,
          level_index: lane_spec.level_index,
          y: Float.round(cur_y, 2),
          height: lane_height,
          split_fare_zones?: lane_spec.split_fare_zones?,
          sub_bands: sub_bands
        }

        {[lane | lanes_acc], Enum.reverse(lane_nodes) ++ nodes_acc, next_y + @lane_gap}
      end)

    raw_height =
      if lane_specs == [] do
        @min_height
      else
        final_y - @lane_gap + @bottom_padding
      end

    height = Float.round(max(@min_height, raw_height), 2)
    ordered_lanes = Enum.reverse(rev_lanes)
    band_order = Enum.flat_map(ordered_lanes, fn lane -> Enum.map(lane.sub_bands, & &1.id) end)
    initial_nodes = Enum.reverse(rev_nodes)

    aligned_nodes =
      align_cross_band_columns(initial_nodes, band_order, renderable_edges, width, max_per_band)

    {width, height, ordered_lanes, aligned_nodes}
  end

  defp position_sub_bands(lane_spec, start_y, center_x, entrance_by_id, platform_by_id) do
    {rev_subs, rev_nodes, end_y} =
      Enum.reduce(lane_spec.sub_bands, {[], [], start_y}, fn sub, {subs_acc, nodes_acc, cur_y} ->
        count = max(length(sub.stops), 1)
        cy = Float.round(cur_y + @sub_band_height / 2.0, 2)

        sub_nodes =
          sub.stops
          |> Enum.with_index()
          |> Enum.map(fn {stop, idx} ->
            cx = Float.round(center_x + (idx - (count - 1) / 2.0) * @node_spacing_x, 2)

            build_positioned_node(
              stop,
              lane_spec,
              sub,
              idx,
              cx,
              cy,
              entrance_by_id,
              platform_by_id
            )
          end)

        positioned_sub = %{
          id: sub.id,
          fare_zone: sub.fare_zone,
          label: sub.label,
          y: Float.round(cur_y, 2),
          height: @sub_band_height,
          node_ids: Enum.map(sub_nodes, & &1.stop_id)
        }

        {[positioned_sub | subs_acc], Enum.reverse(sub_nodes) ++ nodes_acc,
         cur_y + @sub_band_height}
      end)

    {Enum.reverse(rev_subs), Enum.reverse(rev_nodes), end_y}
  end

  # Snaps sparser bands' nodes to the vertical column(s) of their cross-band
  # neighbors while keeping horizontal centering, strict left-to-right order,
  # and guaranteed non-overlap clearance.
  defp align_cross_band_columns(nodes, band_order, renderable_edges, width, max_per_band) do
    min_x = Float.round(@side_padding + @node_width / 2.0, 2)
    max_x = Float.round(width - @side_padding - @node_width / 2.0, 2)
    band_by_stop = Map.new(nodes, &{&1.stop_id, &1.sub_band_id})
    cross_neighbors = build_cross_band_neighbors(renderable_edges, band_by_stop)

    bands_by_id =
      nodes
      |> Enum.group_by(& &1.sub_band_id)
      |> Map.new(fn {band_id, band_nodes} ->
        {band_id, Enum.sort_by(band_nodes, & &1.band_index)}
      end)

    x_by_stop = Map.new(nodes, &{&1.stop_id, &1.x})

    # Anchor the densest band(s) first and propagate exact column coordinates
    # outward to adjacent bands so multi-level chains (e.g. Paid Mezz -> Unpaid
    # Mezz -> Street and Paid Mezz -> Platforms) align into straight vertical
    # columns with zero horizontal jogs.
    anchored =
      bands_by_id
      |> Enum.filter(fn {_id, band_nodes} -> length(band_nodes) >= max_per_band end)
      |> Enum.flat_map(fn {_id, band_nodes} -> Enum.map(band_nodes, & &1.stop_id) end)
      |> MapSet.new()

    {aligned_x, _anchored} =
      propagate_column_alignment(
        band_order,
        bands_by_id,
        cross_neighbors,
        x_by_stop,
        anchored,
        max_per_band,
        min_x,
        max_x
      )

    Enum.map(nodes, fn node -> %{node | x: Map.fetch!(aligned_x, node.stop_id)} end)
  end

  defp propagate_column_alignment(
         band_order,
         bands_by_id,
         cross_neighbors,
         x_by_stop,
         anchored,
         max_per_band,
         min_x,
         max_x
       ) do
    unanchored_bands =
      Enum.reject(band_order, fn band_id ->
        length(Map.get(bands_by_id, band_id, [])) >= max_per_band
      end)

    do_propagate_alignment(
      unanchored_bands,
      bands_by_id,
      cross_neighbors,
      x_by_stop,
      anchored,
      min_x,
      max_x
    )
  end

  defp do_propagate_alignment(
         [],
         _bands_by_id,
         _cross_neighbors,
         x_by_stop,
         anchored,
         _min_x,
         _max_x
       ),
       do: {x_by_stop, anchored}

  defp do_propagate_alignment(
         remaining_bands,
         bands_by_id,
         cross_neighbors,
         x_by_stop,
         anchored,
         min_x,
         max_x
       ) do
    {ready, waiting} =
      Enum.split_with(remaining_bands, fn band_id ->
        band_has_anchored_neighbor?(Map.get(bands_by_id, band_id, []), cross_neighbors, anchored)
      end)

    if ready == [] do
      {x_by_stop, anchored}
    else
      {next_x, next_anchored} =
        align_ready_bands(ready, bands_by_id, cross_neighbors, x_by_stop, anchored, min_x, max_x)

      do_propagate_alignment(
        waiting,
        bands_by_id,
        cross_neighbors,
        next_x,
        next_anchored,
        min_x,
        max_x
      )
    end
  end

  defp band_has_anchored_neighbor?(band_nodes, cross_neighbors, anchored) do
    Enum.any?(band_nodes, fn node ->
      cross_neighbors
      |> Map.get(node.stop_id, [])
      |> Enum.any?(&MapSet.member?(anchored, &1))
    end)
  end

  defp align_ready_bands(ready, bands_by_id, cross_neighbors, x_by_stop, anchored, min_x, max_x) do
    Enum.reduce(ready, {x_by_stop, anchored}, fn band_id, {acc_x, acc_anc} ->
      band_nodes = Map.get(bands_by_id, band_id, [])

      updated_x =
        align_band_to_anchored(band_nodes, acc_x, acc_anc, cross_neighbors, min_x, max_x)

      updated_anc = Enum.reduce(band_nodes, acc_anc, &MapSet.put(&2, &1.stop_id))
      {updated_x, updated_anc}
    end)
  end

  defp align_band_to_anchored(band_nodes, x_by_stop, anchored, cross_neighbors, min_x, max_x) do
    desired =
      Enum.map(band_nodes, fn node ->
        neighbor_xs =
          cross_neighbors
          |> Map.get(node.stop_id, [])
          |> Enum.filter(&MapSet.member?(anchored, &1))
          |> Enum.uniq()
          |> Enum.map(&Map.get(x_by_stop, &1))
          |> Enum.reject(&is_nil/1)

        target =
          case neighbor_xs do
            [] -> Map.fetch!(x_by_stop, node.stop_id)
            xs -> Enum.sum(xs) / length(xs)
          end

        {node.stop_id, clamp_float(target, min_x, max_x)}
      end)

    spaced = enforce_monotonic_spacing(desired, min_x, max_x)

    Enum.reduce(spaced, x_by_stop, fn {stop_id, x}, acc ->
      Map.put(acc, stop_id, Float.round(x, 2))
    end)
  end

  defp build_cross_band_neighbors(edges, band_by_stop) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      b_from = Map.get(band_by_stop, edge.from_stop_id)
      b_to = Map.get(band_by_stop, edge.to_stop_id)

      if b_from && b_to && b_from != b_to do
        acc
        |> Map.update(edge.from_stop_id, [edge.to_stop_id], &[edge.to_stop_id | &1])
        |> Map.update(edge.to_stop_id, [edge.from_stop_id], &[edge.from_stop_id | &1])
      else
        acc
      end
    end)
  end

  defp enforce_monotonic_spacing([], _min_x, _max_x), do: []
  defp enforce_monotonic_spacing([{id, x}], _min_x, _max_x), do: [{id, x}]

  defp enforce_monotonic_spacing(pairs, min_x, max_x) do
    # Forward pass: push right to satisfy minimum center-to-center clearance
    {rev_fwd, _prev} =
      Enum.reduce(pairs, {[], nil}, fn {id, x}, {acc, prev_x} ->
        adjusted = if(prev_x, do: max(x, prev_x + @min_node_gap), else: max(x, min_x))
        {[{id, adjusted} | acc], adjusted}
      end)

    # Backward pass: pull left so everything stays inside [min_x, max_x]
    {final, _next} =
      Enum.reduce(rev_fwd, {[], nil}, fn {id, x}, {acc, next_x} ->
        adjusted = if(next_x, do: min(x, next_x - @min_node_gap), else: min(x, max_x))
        {[{id, max(adjusted, min_x)} | acc], max(adjusted, min_x)}
      end)

    final
  end

  defp clamp_float(value, lo, hi), do: value |> max(lo) |> min(hi)

  defp build_positioned_node(
         stop,
         lane_spec,
         sub,
         band_index,
         cx,
         cy,
         entrance_by_id,
         platform_by_id
       ) do
    entrance_entry = Map.get(entrance_by_id, stop.stop_id)
    platform_entry = Map.get(platform_by_id, stop.stop_id)

    %{
      id: "node:" <> stop.stop_id,
      stop_id: stop.stop_id,
      stop_uuid: Map.get(stop, :id),
      name: Values.presence(Map.get(stop, :stop_name)) || stop.stop_id,
      role: stop_role(Map.get(stop, :location_type)),
      location_type: Map.get(stop, :location_type),
      level_id: lane_spec.level_id,
      level_name: lane_spec.level_name,
      fare_zone: sub.fare_zone,
      sub_band_id: sub.id,
      band_index: band_index,
      step_free?: node_step_free?(entrance_entry),
      wheelchair_resolved: node_wheelchair_resolved(entrance_entry, platform_entry),
      diagram_coordinate: Map.get(stop, :diagram_coordinate),
      x: cx,
      y: cy,
      width: @node_width,
      height: @node_height
    }
  end

  defp stop_role(2), do: :entrance
  defp stop_role(0), do: :platform
  defp stop_role(4), do: :boarding_area
  defp stop_role(_), do: :node

  defp node_step_free?(%{step_free?: flag}), do: flag
  defp node_step_free?(_), do: true

  defp node_wheelchair_resolved(%{wheelchair_resolved: resolved}, _platform_entry), do: resolved
  defp node_wheelchair_resolved(_entrance_entry, %{wheelchair_resolved: resolved}), do: resolved
  defp node_wheelchair_resolved(_entrance_entry, _platform_entry), do: nil

  # --- Edge geometry & validation highlights ---

  defp build_positioned_edges(renderable_edges, node_by_id, mode, highlights) do
    any_highlight_active? = mode == :validation and Enum.any?(Map.values(highlights))

    # Group parallel edges connecting the same unordered stop pair so we can
    # separate them cleanly without colliding paths or callouts.
    grouped =
      renderable_edges
      |> Enum.sort_by(& &1.pathway_id)
      |> Enum.group_by(fn edge ->
        if edge.from_stop_id <= edge.to_stop_id do
          {edge.from_stop_id, edge.to_stop_id}
        else
          {edge.to_stop_id, edge.from_stop_id}
        end
      end)

    grouped
    |> Enum.flat_map(fn {_pair_key, pair_edges} ->
      position_parallel_edges(pair_edges, node_by_id, mode, highlights, any_highlight_active?)
    end)
    |> Enum.sort_by(& &1.pathway_id)
  end

  defp position_parallel_edges(pair_edges, node_by_id, mode, highlights, any_highlight_active?) do
    count = length(pair_edges)

    {positioned, _seen_callouts} =
      pair_edges
      |> Enum.with_index()
      |> Enum.map_reduce(MapSet.new(), fn {edge, idx}, seen_callouts ->
        offset = (idx - (count - 1) / 2.0) * @parallel_offset_step

        built =
          build_positioned_edge(
            edge,
            node_by_id,
            offset,
            idx,
            count,
            mode,
            highlights,
            any_highlight_active?
          )

        dedup_parallel_callout(built, seen_callouts)
      end)

    positioned
  end

  defp dedup_parallel_callout(%{callout: nil} = built, seen_callouts), do: {built, seen_callouts}

  defp dedup_parallel_callout(%{callout: label} = built, seen_callouts) do
    if MapSet.member?(seen_callouts, label) do
      {%{built | callout: nil}, seen_callouts}
    else
      {built, MapSet.put(seen_callouts, label)}
    end
  end

  defp build_positioned_edge(
         edge,
         node_by_id,
         offset,
         parallel_idx,
         parallel_count,
         mode,
         highlights,
         any_highlight_active?
       ) do
    from_node = Map.fetch!(node_by_id, edge.from_stop_id)
    to_node = Map.fetch!(node_by_id, edge.to_stop_id)

    active_highlights = compute_active_highlights(edge, mode, highlights)
    highlighted? = active_highlights != []
    dimmed? = any_highlight_active? and not highlighted?
    {style_role, stroke_style} = edge_style(edge, active_highlights)
    geometry = compute_edge_geometry(from_node, to_node, offset, parallel_idx, parallel_count)

    %{
      id: "edge:" <> edge.pathway_id,
      pathway_id: edge.pathway_id,
      pathway_uuid: edge.id,
      pathway_mode: edge.pathway_mode,
      pathway_mode_label: edge.pathway_mode_label,
      from_stop_id: edge.from_stop_id,
      to_stop_id: edge.to_stop_id,
      is_bidirectional: edge.is_bidirectional,
      from_level_id: edge.from_level_id,
      to_level_id: edge.to_level_id,
      level_id: edge.from_level_id || edge.to_level_id,
      classification: edge.classification,
      barriers: edge.barriers,
      missing_fields: edge.missing_fields,
      near_threshold_fields: edge.near_threshold_fields,
      elevator_id: edge.elevator_id,
      sole_link_elevator?: edge.sole_link_elevator?,
      is_fare_gate?: edge.pathway_mode in [6, 7],
      is_ramp: edge.is_ramp,
      active_highlights: active_highlights,
      highlighted?: highlighted?,
      dimmed?: dimmed?,
      style_role: style_role,
      stroke_style: stroke_style,
      callout: edge_callout(edge, active_highlights),
      x1: geometry.x1,
      y1: geometry.y1,
      x2: geometry.x2,
      y2: geometry.y2,
      label_x: geometry.label_x,
      label_y: geometry.label_y,
      path_d: geometry.path_d
    }
  end

  defp compute_active_highlights(_edge, :rider, _highlights), do: []

  defp compute_active_highlights(edge, :validation, highlights) do
    []
    |> maybe_add(
      highlights.barriers and edge.classification in [:barrier, :not_step_free],
      :barrier
    )
    |> maybe_add(
      highlights.unknown_data and edge.classification == :unverified,
      :unknown_data
    )
    |> maybe_add(
      highlights.near_threshold and edge.classification in [:confirmed, :unverified] and
        edge.near_threshold_fields != [],
      :near_threshold
    )
    |> maybe_add(
      highlights.single_elevator and edge.sole_link_elevator?,
      :single_elevator
    )
    |> Enum.reverse()
  end

  defp maybe_add(list, true, tag), do: [tag | list]
  defp maybe_add(list, false, _tag), do: list

  defp edge_style(%{classification: :barrier}, _active), do: {:pathway_barrier, :dashed}

  defp edge_style(%{classification: :not_step_free}, _active),
    do: {:pathway_not_step_free, :dashed}

  defp edge_style(edge, active_highlights) do
    cond do
      :single_elevator in active_highlights ->
        {:schematic_sole_elevator, :solid}

      :near_threshold in active_highlights ->
        {:schematic_near_threshold, :dashed}

      edge.classification == :unverified ->
        {:schematic_unverified, :dotted}

      true ->
        {:pathway_step_free, :solid}
    end
  end

  defp edge_callout(%{classification: :barrier}, _active), do: "Barrier"

  defp edge_callout(%{classification: :not_step_free} = edge, _active),
    do: edge.pathway_mode_label

  defp edge_callout(edge, active_highlights) do
    highlight_callout(active_highlights) || default_edge_callout(edge)
  end

  defp highlight_callout(active_highlights) do
    cond do
      :single_elevator in active_highlights -> "Sole elevator"
      :near_threshold in active_highlights -> "Near limit"
      :unknown_data in active_highlights -> "Unknown data"
      true -> nil
    end
  end

  defp default_edge_callout(%{pathway_mode: 5}), do: "Elevator"

  defp default_edge_callout(%{pathway_mode: mode} = edge) when mode in [6, 7],
    do: edge.pathway_mode_label

  defp default_edge_callout(%{is_ramp: true}), do: "Ramp"
  defp default_edge_callout(%{classification: :unverified}), do: "Unverified"
  defp default_edge_callout(_edge), do: nil

  defp compute_edge_geometry(from_node, to_node, offset, parallel_idx, parallel_count) do
    cond do
      from_node.stop_id == to_node.stop_id ->
        {half_w, _half_h} = node_anchor_extents(from_node)
        x1 = Float.round(from_node.x + half_w, 2)
        y1 = Float.round(from_node.y - 8.0, 2)
        y2 = Float.round(from_node.y + 8.0, 2)
        cx = Float.round(from_node.x + max(half_w, 12.0) + 28.0 + abs(offset), 2)

        %{
          x1: x1,
          y1: y1,
          x2: x1,
          y2: y2,
          label_x: cx,
          label_y: from_node.y,
          path_d:
            "M #{format_num(x1)} #{format_num(y1)} " <>
              "L #{format_num(cx)} #{format_num(y1)} " <>
              "L #{format_num(cx)} #{format_num(y2)} " <>
              "L #{format_num(x1)} #{format_num(y2)}"
        }

      from_node.y == to_node.y ->
        same_band_geometry(from_node, to_node, offset)

      true ->
        cross_band_geometry(from_node, to_node, offset, parallel_idx, parallel_count)
    end
  end

  defp node_anchor_extents(%{role: :entrance}), do: {9.0, 9.0}

  defp node_anchor_extents(%{role: role}) when role in [:platform, :boarding_area],
    do: {64.0, 7.0}

  defp node_anchor_extents(_node), do: {0.0, 0.0}

  defp same_band_geometry(from_node, to_node, offset) do
    {from_hw, from_hh} = node_anchor_extents(from_node)
    {to_hw, to_hh} = node_anchor_extents(to_node)

    {x1, x2} =
      if from_node.x <= to_node.x do
        {Float.round(from_node.x + from_hw, 2), Float.round(to_node.x - to_hw, 2)}
      else
        {Float.round(from_node.x - from_hw, 2), Float.round(to_node.x + to_hw, 2)}
      end

    y = from_node.y
    adjacent? = abs(from_node.band_index - to_node.band_index) <= 1

    if adjacent? do
      y_line = Float.round(y + offset * 0.4, 2)

      label_y =
        if(offset == 0.0, do: Float.round(y_line - 18.0, 2), else: Float.round(y_line - 14.0, 2))

      %{
        x1: x1,
        y1: y_line,
        x2: x2,
        y2: y_line,
        label_x: Float.round((x1 + x2) / 2.0, 2),
        label_y: label_y,
        path_d:
          "M #{format_num(x1)} #{format_num(y_line)} L #{format_num(x2)} #{format_num(y_line)}"
      }
    else
      # Non-adjacent same-band edge: orthogonal 90-degree bridge clearing intervening nodes
      ax = Float.round(from_node.x + offset * 0.4, 2)
      bx = Float.round(to_node.x + offset * 0.4, 2)
      y1 = Float.round(y - from_hh, 2)
      y2 = Float.round(y - to_hh, 2)
      detour_y = Float.round(y - max(from_hh, to_hh) - 24.0 - abs(offset) * 0.5, 2)

      %{
        x1: ax,
        y1: y1,
        x2: bx,
        y2: y2,
        label_x: Float.round((ax + bx) / 2.0, 2),
        label_y: detour_y,
        path_d:
          "M #{format_num(ax)} #{format_num(y1)} " <>
            "L #{format_num(ax)} #{format_num(detour_y)} " <>
            "L #{format_num(bx)} #{format_num(detour_y)} " <>
            "L #{format_num(bx)} #{format_num(y2)}"
      }
    end
  end

  defp cross_band_geometry(from_node, to_node, offset, parallel_idx, parallel_count) do
    {_from_hw, from_hh} = node_anchor_extents(from_node)
    {_to_hw, to_hh} = node_anchor_extents(to_node)
    going_down? = from_node.y < to_node.y
    x1 = Float.round(from_node.x + offset * 0.5, 2)
    x2 = Float.round(to_node.x + offset * 0.5, 2)

    {y1, y2} =
      if going_down? do
        {Float.round(from_node.y + from_hh, 2), Float.round(to_node.y - to_hh, 2)}
      else
        {Float.round(from_node.y - from_hh, 2), Float.round(to_node.y + to_hh, 2)}
      end

    t =
      if parallel_count > 1 do
        0.36 + 0.28 * (parallel_idx / (parallel_count - 1))
      else
        0.5
      end

    if x1 == x2 do
      # Vertically aligned nodes: pure straight vertical line
      label_y = Float.round(y1 + (y2 - y1) * t, 2)

      %{
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        label_x: x1,
        label_y: label_y,
        path_d: "M #{format_num(x1)} #{format_num(y1)} L #{format_num(x2)} #{format_num(y2)}"
      }
    else
      # Cross-column nodes: axis-aligned 90-degree orthogonal elbow
      bend_y = Float.round((y1 + y2) / 2.0 + offset * 0.35, 2)
      label_x = Float.round(x1 + (x2 - x1) * t, 2)

      %{
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        label_x: label_x,
        label_y: bend_y,
        path_d:
          "M #{format_num(x1)} #{format_num(y1)} " <>
            "L #{format_num(x1)} #{format_num(bend_y)} " <>
            "L #{format_num(x2)} #{format_num(bend_y)} " <>
            "L #{format_num(x2)} #{format_num(y2)}"
      }
    end
  end

  defp build_legend(edges) do
    []
    |> maybe_add(Enum.any?(edges, &(&1.classification == :confirmed)), :confirmed)
    |> maybe_add(Enum.any?(edges, &(&1.classification == :unverified)), :unverified)
    |> maybe_add(Enum.any?(edges, &(:near_threshold in &1.active_highlights)), :near_threshold)
    |> maybe_add(Enum.any?(edges, &(:single_elevator in &1.active_highlights)), :single_elevator)
    |> maybe_add(Enum.any?(edges, &(&1.classification == :barrier)), :barrier)
    |> maybe_add(Enum.any?(edges, &(&1.classification == :not_step_free)), :not_step_free)
    |> Enum.reverse()
  end

  # --- Helpers ---

  defp diagram_x(stop) do
    case Coordinates.normalize_point(Map.get(stop, :diagram_coordinate)) do
      %{x: x} -> x
      nil -> nil
    end
  end

  defp build_level_index(levels) do
    levels
    |> Enum.map(fn
      %{level: level} -> level
      level when is_map(level) -> level
    end)
    |> Map.new(&{&1.level_id, &1})
  end

  defp level_sort_key(nil, _level_index), do: {2, 0.0, ""}

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

  defp level_display_name(nil, _level), do: "Unassigned level"
  defp level_display_name(level_id, nil), do: level_id

  defp level_display_name(level_id, level) do
    Values.presence(Map.get(level, :level_name)) || level_id
  end

  defp format_num(value) when is_float(value) do
    if value == Float.round(value, 0) do
      Integer.to_string(trunc(value))
    else
      :erlang.float_to_binary(value, [:compact, decimals: 2])
    end
  end

  defp format_num(value) when is_integer(value), do: Integer.to_string(value)
end
