defmodule GtfsPlanner.Gtfs.StationReport2.Connectivity do
  @moduledoc """
  Three-dimension connectivity report for the Report 2 dashboard.

  Computes reachability, shortest paths, and accessibility for
  Entrance→Platform, Platform→Exit, and Platform→Platform dimensions
  using progressive computation (summary → route detail → expanded route).
  """

  alias GtfsPlanner.Gtfs.{Graph, Pathway, Stop, TraversalCalculator}

  @long_route_threshold 300
  @elevator_step_threshold 120
  @walkway_step_threshold 180
  # ── Step 3: build_summaries/1 ──────────────────────────────────────────────

  @doc """
  Computes lightweight boolean reachability summaries for all three dimensions.
  Called on page load in handle_params.
  """
  def build_summaries(%{child_stops: child_stops, pathways: pathways} = _snapshot) do
    {entrances, platforms} = entrances_and_platforms(child_stops)
    directed = Graph.build_directed_adjacency(pathways)
    platform_target_index = Graph.build_platform_target_index(child_stops)

    %{
      entrance_to_platform:
        build_dimension_summary(
          entrances,
          platforms,
          platform_target_index,
          directed,
          child_stops,
          :entrance_to_platform
        ),
      platform_to_exit:
        build_dimension_summary(
          platforms,
          entrances,
          platform_target_index,
          directed,
          child_stops,
          :platform_to_exit
        ),
      platform_to_platform:
        build_dimension_summary(
          platforms,
          platforms,
          platform_target_index,
          directed,
          child_stops,
          :platform_to_platform
        )
    }
  end

  defp build_dimension_summary(sources, targets, platform_target_index, directed, _child_stops, dimension) do
    {title, description, source_label} = dimension_metadata(dimension)

    # Compute reachability for each source
    summary_rows =
      Enum.map(sources, fn source ->
        start_ids = source_start_ids(source, platform_target_index, dimension)

        {reachable_names, unreachable_names} =
          targets
          |> Enum.reject(&(&1.stop_id == source.stop_id))
          |> Enum.reduce({[], []}, fn target, {reach, unreach} ->
            target_set = target_set_for_stop(target, platform_target_index, dimension)

            if target_set_empty?(target_set) do
              {reach, unreach}
            else
              is_reachable =
                Enum.any?(start_ids, fn start_id ->
                  Graph.reachable?(start_id, target_set, directed)
                end)

              name = target.stop_name || target.stop_id

              if is_reachable do
                {[name | reach], unreach}
              else
                {reach, [name | unreach]}
              end
            end
          end)

        reachable_names = Enum.reverse(reachable_names)
        unreachable_names = Enum.reverse(unreachable_names)

        row_status =
          cond do
            unreachable_names == [] and reachable_names != [] -> :full
            reachable_names != [] and unreachable_names != [] -> :partial
            true -> :none
          end

        %{
          source_stop_id: source.stop_id,
          source_name: source.stop_name || source.stop_id,
          reachable: reachable_names,
          unreachable: unreachable_names,
          status: row_status
        }
      end)

    # Compute stats
    source_count = length(sources)

    target_count = length(targets)

    total_pairs =
      Enum.reduce(summary_rows, 0, fn row, acc ->
        acc + length(row.reachable) + length(row.unreachable)
      end)

    connected_pairs =
      Enum.reduce(summary_rows, 0, fn row, acc ->
        acc + length(row.reachable)
      end)

    # Dimension status
    status =
      cond do
        summary_rows == [] -> :passed
        Enum.all?(summary_rows, &(&1.status == :full)) -> :passed
        Enum.any?(summary_rows, &(&1.status == :none)) -> :fail
        true -> :warning
      end

    # Alerts for zero-reachability entities
    alerts =
      summary_rows
      |> Enum.filter(&(&1.status == :none))
      |> Enum.map(fn row ->
        alert_text(row.source_name, dimension)
      end)

    %{
      title: title,
      description: description,
      source_label: source_label,
      status: status,
      stats: %{
        total_pairs: total_pairs,
        connected_pairs: connected_pairs,
        accessible_pairs: 0,
        source_count: source_count,
        target_count: target_count
      },
      summary_rows: summary_rows,
      alerts: alerts
    }
  end

  # ── Step 4: build_route_detail/2 ──────────────────────────────────────────

  @doc """
  Computes enriched route detail for one dimension.
  Called on dimension drill-down, not on page load.
  """
  def build_route_detail(
        %{child_stops: child_stops, pathways: pathways, levels: levels} = _snapshot,
        dimension_key
      ) do
    {entrances, platforms} = entrances_and_platforms(child_stops)
    platform_target_index = Graph.build_platform_target_index(child_stops)
    path_adj = Graph.build_path_traversal_adjacency(pathways)
    step_free_adj = Graph.build_step_free_path_traversal_adjacency(pathways)

    stop_index = build_stop_index(child_stops)
    pathway_index = build_pathway_index(pathways)
    level_index = build_level_index(levels)

    {sources, targets} = sources_and_targets_for_dimension(entrances, platforms, dimension_key)

    Enum.map(sources, fn source ->
      source_level = level_for_stop(source, level_index)

      target_rows =
        targets
        |> Enum.reject(&(&1.stop_id == source.stop_id))
        |> Enum.map(fn target ->
          build_target_row(
            source,
            target,
            platform_target_index,
            path_adj,
            step_free_adj,
            stop_index,
            pathway_index,
            level_index,
            dimension_key
          )
        end)

      %{
        source: %{
          name: source.stop_name || source.stop_id,
          stop_id: source.stop_id,
          level_name: source_level && source_level.level_name,
          level_index: source_level && source_level.level_index
        },
        targets: target_rows
      }
    end)
  end

  defp build_target_row(
         source,
         target,
         platform_target_index,
         path_adj,
         step_free_adj,
         stop_index,
         pathway_index,
         level_index,
         dimension_key
       ) do
    start_ids = source_start_ids(source, platform_target_index, dimension_key)
    target_set = target_set_for_stop(target, platform_target_index, dimension_key)

    # Find shortest path from any start node
    shortest_result =
      start_ids
      |> Enum.map(fn start_id ->
        case Graph.shortest_directed_path_to_any(path_adj, start_id, target_set) do
          {:found, path} ->
            enriched = enrich_path(path, pathway_index, stop_index, level_index)
            {enriched.totals.time_seconds, enriched}

          :not_found ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(fn {time, _} -> time end, fn -> nil end)

    # Find step-free path
    step_free_result =
      start_ids
      |> Enum.map(fn start_id ->
        case Graph.shortest_directed_path_to_any(step_free_adj, start_id, target_set) do
          {:found, path} ->
            enriched = enrich_path(path, pathway_index, stop_index, level_index)
            {enriched.totals.time_seconds, enriched}

          :not_found ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(fn {time, _} -> time end, fn -> nil end)

    target_level = level_for_stop(target, level_index)
    meta = build_target_meta(target, target_level)

    case shortest_result do
      nil ->
        %{
          name: target.stop_name || target.stop_id,
          stop_id: target.stop_id,
          meta: meta,
          time: nil,
          distance: nil,
          levels: nil,
          accessible: nil,
          accessible_note: nil,
          status: :nopath
        }

      {_time, enriched} ->
        accessible = step_free_result != nil

        accessible_note =
          case step_free_result do
            {_sf_time, sf_enriched} ->
              cond do
                sf_enriched.totals.has_elevator -> "elevator route available"
                sf_enriched.totals.level_changes == 0 -> "same-level walkway"
                true -> nil
              end

            nil ->
              if enriched.totals.has_stairs, do: "stairs only", else: nil
          end

        route_status =
          if enriched.totals.time_seconds > @long_route_threshold, do: :long, else: :reachable

        %{
          name: target.stop_name || target.stop_id,
          stop_id: target.stop_id,
          meta: meta,
          time: enriched.totals.time_seconds,
          distance: enriched.totals.distance_meters,
          levels: enriched.totals.level_changes,
          accessible: accessible,
          accessible_note: accessible_note,
          status: route_status
        }
    end
  end

  # ── Step 5: build_expanded_route/3 ────────────────────────────────────────

  @doc """
  Computes the full step-by-step expanded route between a source and target.
  Called on row expand, not on page load or drill-down.
  """
  def build_expanded_route(
        %{child_stops: child_stops, pathways: pathways, levels: levels} = _snapshot,
        source_stop_id,
        target_stop_id
      ) do
    platform_target_index = Graph.build_platform_target_index(child_stops)
    path_adj = Graph.build_path_traversal_adjacency(pathways)
    step_free_adj = Graph.build_step_free_path_traversal_adjacency(pathways)

    stop_index = build_stop_index(child_stops)
    pathway_index = build_pathway_index(pathways)
    level_index = build_level_index(levels)

    source = Map.get(stop_index, source_stop_id)
    target = Map.get(stop_index, target_stop_id)

    # Determine start IDs (platform + boarding areas for Platform→Exit)
    start_ids =
      case Map.get(platform_target_index, source_stop_id) do
        nil -> [source_stop_id]
        targets -> MapSet.to_list(targets)
      end

    # Determine target IDs
    target_ids =
      case Map.get(platform_target_index, target_stop_id) do
        nil -> MapSet.new([target_stop_id])
        targets -> targets
      end

    # Find shortest path from any start node
    shortest_result =
      start_ids
      |> Enum.map(fn start_id ->
        case Graph.shortest_directed_path_to_any(path_adj, start_id, target_ids) do
          {:found, path} ->
            enriched = enrich_path(path, pathway_index, stop_index, level_index)
            {enriched.totals.time_seconds, enriched}

          :not_found ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(fn {time, _} -> time end, fn -> nil end)

    # Find step-free path
    step_free_result =
      start_ids
      |> Enum.map(fn start_id ->
        case Graph.shortest_directed_path_to_any(step_free_adj, start_id, target_ids) do
          {:found, path} ->
            enriched = enrich_path(path, pathway_index, stop_index, level_index)
            {enriched.totals.time_seconds, enriched}

          :not_found ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(fn {time, _} -> time end, fn -> nil end)

    case shortest_result do
      nil ->
        :nopath

      {_time, enriched} ->
        source_level = level_for_stop(source, level_index)
        target_level = level_for_stop(target, level_index)
        meta = build_target_meta(target, target_level)
        accessible = step_free_result != nil

        accessible_note =
          case step_free_result do
            {_sf_time, sf_enriched} ->
              cond do
                sf_enriched.totals.has_elevator -> "elevator route available"
                sf_enriched.totals.level_changes == 0 -> "same-level walkway"
                true -> nil
              end

            nil ->
              if enriched.totals.has_stairs, do: "stairs only", else: nil
          end

        route_status =
          if enriched.totals.time_seconds > @long_route_threshold, do: :long, else: :reachable

        # Build steps
        steps = build_steps(enriched.hops, level_index)

        # Build warnings
        warnings = build_route_warnings(enriched.totals, steps)

        # Build level path
        level_path = build_level_path(enriched.hops)

        %{
          source: %{
            name: (source && source.stop_name) || source_stop_id,
            stop_id: source_stop_id,
            level_name: source_level && source_level.level_name,
            level_index: source_level && source_level.level_index
          },
          target: %{
            name: (target && target.stop_name) || target_stop_id,
            stop_id: target_stop_id,
            meta: meta
          },
          time: enriched.totals.time_seconds,
          distance: enriched.totals.distance_meters,
          levels: enriched.totals.level_changes,
          accessible: accessible,
          accessible_note: accessible_note,
          status: route_status,
          warnings: warnings,
          level_path: level_path,
          steps: steps
        }
    end
  end

  # ── Path enrichment (copied from station_report.ex) ───────────────────────

  defp enrich_path([], _pathway_index, _stop_index, _level_index) do
    %{
      hops: [],
      totals: %{
        time_seconds: 0.0,
        distance_meters: 0.0,
        level_changes: 0,
        has_stairs: false,
        has_escalator: false,
        has_elevator: false
      },
      all_bidirectional: true
    }
  end

  defp enrich_path(path, pathway_index, stop_index, level_index) do
    [start_hop | _] = path
    start_stop = Map.get(stop_index, start_hop.stop_id)

    start_enriched =
      build_enriched_hop(
        start_hop,
        start_stop,
        nil,
        %{time_seconds: 0.0, distance_meters: nil, calculation_method: :origin},
        nil,
        level_index
      )

    enriched_hops =
      path_segments(path)
      |> Enum.map(fn {from_hop, to_hop} ->
        pathway = Map.get(pathway_index, to_hop.pathway_id)
        to_stop = Map.get(stop_index, to_hop.stop_id)
        from_stop = Map.get(stop_index, from_hop.stop_id)
        level_diff = compute_level_diff(from_stop, to_stop, level_index)

        traversal =
          if pathway, do: TraversalCalculator.calculate(pathway, level_diff), else: nil

        build_enriched_hop(
          to_hop,
          to_stop,
          pathway,
          traversal,
          level_diff,
          level_index
        )
      end)

    hops = [start_enriched | enriched_hops]
    pathway_hops = Enum.filter(hops, &present?(&1.pathway_id))
    totals = path_totals(hops, pathway_hops)

    %{
      hops: hops,
      totals: totals,
      all_bidirectional: Enum.all?(pathway_hops, & &1.is_bidirectional)
    }
  end

  defp build_enriched_hop(hop, stop, pathway, traversal, level_diff, level_index) do
    level_data =
      case stop do
        nil -> nil
        _ -> level_for_stop(stop, level_index)
      end

    %{
      stop_id: hop.stop_id,
      stop_name: stop && stop.stop_name,
      location_type: stop && normalize_location_type(stop.location_type),
      location_type_label:
        stop && Stop.location_type_label(normalize_location_type(stop.location_type)),
      level_id: stop && stop.level_id,
      level_name: level_data && level_data.level_name,
      level_index: level_data && level_data.level_index,
      pathway_id: hop.pathway_id,
      pathway_mode: hop.pathway_mode,
      pathway_mode_label:
        if(is_integer(hop.pathway_mode), do: Pathway.mode_label(hop.pathway_mode), else: nil),
      is_bidirectional: pathway && pathway.is_bidirectional,
      signposted_as: pathway && pathway.signposted_as,
      reversed_signposted_as: pathway && pathway.reversed_signposted_as,
      level_diff: level_diff,
      time_seconds: traversal && traversal.time_seconds,
      distance_meters: traversal && traversal.distance_meters,
      calculation_method: traversal && traversal.calculation_method
    }
  end

  defp path_totals(hops, pathway_hops) do
    time_seconds =
      Enum.reduce(pathway_hops, 0.0, fn hop, acc ->
        acc + if(is_number(hop.time_seconds), do: hop.time_seconds, else: 0.0)
      end)

    distance_meters =
      Enum.reduce(pathway_hops, 0.0, fn hop, acc ->
        acc + if(is_number(hop.distance_meters), do: hop.distance_meters, else: 0.0)
      end)

    level_changes =
      path_segments(hops)
      |> Enum.count(fn {from_hop, to_hop} ->
        is_number(from_hop.level_index) and is_number(to_hop.level_index) and
          from_hop.level_index != to_hop.level_index
      end)

    has_stairs = Enum.any?(pathway_hops, &(&1.pathway_mode == 2))
    has_escalator = Enum.any?(pathway_hops, &(&1.pathway_mode == 4))
    has_elevator = Enum.any?(pathway_hops, &(&1.pathway_mode == 5))

    %{
      time_seconds: Float.round(time_seconds, 2),
      distance_meters: Float.round(distance_meters, 2),
      level_changes: level_changes,
      has_stairs: has_stairs,
      has_escalator: has_escalator,
      has_elevator: has_elevator
    }
  end

  # ── Step building ─────────────────────────────────────────────────────────

  defp build_steps(hops, level_index) do
    hops
    |> Enum.with_index(1)
    |> Enum.map(fn {hop, num} ->
      level_data =
        case hop.level_id do
          nil -> nil
          level_id -> Map.get(level_index, level_id)
        end

      mode_int = hop.pathway_mode
      mode = if is_integer(mode_int), do: Pathway.mode_label(mode_int), else: nil

      instruction = effective_signposted_as(hop)

      time_warning =
        cond do
          mode_int == 5 and is_number(hop.time_seconds) and
              hop.time_seconds > @elevator_step_threshold ->
            true

          mode_int in [1, 3] and is_number(hop.time_seconds) and
              hop.time_seconds > @walkway_step_threshold ->
            true

          true ->
            false
        end

      # Elevator and escalator steps show em-dash for distance
      dist =
        if mode_int in [4, 5] do
          nil
        else
          hop.distance_meters
        end

      %{
        num: num,
        mode: mode,
        mode_int: mode_int,
        stop_id: hop.stop_id,
        instruction: instruction,
        time: hop.time_seconds,
        dist: dist,
        level_id: hop.level_id,
        level_name: level_data && level_data.level_name,
        level_index: level_data && level_data.level_index,
        time_warning: time_warning
      }
    end)
  end

  defp build_route_warnings(totals, steps) do
    if totals.time_seconds > @long_route_threshold do
      # Find the step contributing most time
      worst_step =
        steps
        |> Enum.filter(&is_number(&1.time))
        |> Enum.max_by(& &1.time, fn -> nil end)

      case worst_step do
        nil ->
          []

        step ->
          mode_name = String.downcase(step.mode || "unknown")

          [
            "Route time of #{round(totals.time_seconds)}s exceeds the threshold. " <>
              "The #{mode_name} at step #{step.num} accounts for #{round(step.time)}s " <>
              "of total traversal time \u2014 check whether traversal_time is set correctly on this pathway."
          ]
      end
    else
      []
    end
  end

  defp build_level_path(hops) do
    hops
    |> Enum.map(& &1.level_name)
    |> Enum.filter(&present?/1)
    |> Enum.dedup()
    |> case do
      [] -> nil
      names -> Enum.join(names, " \u2192 ")
    end
  end

  # ── Dimension helpers ─────────────────────────────────────────────────────

  defp dimension_metadata(:entrance_to_platform) do
    {
      "Entrance-to-Platform Reachability",
      "Traces directed pathways from each entrance/exit to every reachable platform or boarding area.",
      "Entrance/Exit"
    }
  end

  defp dimension_metadata(:platform_to_exit) do
    {
      "Platform-to-Exit Reachability",
      "Traces directed pathways from each platform to every exit, ensuring riders can egress.",
      "Platform"
    }
  end

  defp dimension_metadata(:platform_to_platform) do
    {
      "Platform Interconnection Reachability",
      "Traces directed pathways between all platforms within the station using pathway edges.",
      "Platform"
    }
  end

  defp alert_text(name, :entrance_to_platform) do
    "Needs immediate attention: #{name} has no reachable platforms or boarding areas."
  end

  defp alert_text(name, :platform_to_exit) do
    "Needs immediate attention: #{name} cannot reach any exit in this station."
  end

  defp alert_text(name, :platform_to_platform) do
    "Needs immediate attention: #{name} cannot reach any other platform in this station."
  end

  defp entrances_and_platforms(child_stops) do
    entrances =
      child_stops
      |> Enum.filter(&(&1.location_type == 2))
      |> Enum.sort_by(& &1.stop_id)

    platforms =
      child_stops
      |> Enum.filter(&(&1.location_type == 0))
      |> Enum.sort_by(& &1.stop_id)

    {entrances, platforms}
  end

  defp sources_and_targets_for_dimension(entrances, platforms, :entrance_to_platform),
    do: {entrances, platforms}

  defp sources_and_targets_for_dimension(entrances, platforms, :platform_to_exit),
    do: {platforms, entrances}

  defp sources_and_targets_for_dimension(_entrances, platforms, :platform_to_platform),
    do: {platforms, platforms}

  defp source_start_ids(source, platform_target_index, dimension)
       when dimension in [:platform_to_exit, :platform_to_platform] do
    Map.get(platform_target_index, source.stop_id, MapSet.new([source.stop_id]))
    |> MapSet.to_list()
  end

  defp source_start_ids(source, _platform_target_index, _dimension) do
    [source.stop_id]
  end

  defp target_set_for_stop(target, platform_target_index, :entrance_to_platform) do
    Map.get(platform_target_index, target.stop_id, MapSet.new([target.stop_id]))
  end

  defp target_set_for_stop(target, _platform_target_index, :platform_to_exit) do
    MapSet.new([target.stop_id])
  end

  defp target_set_for_stop(target, platform_target_index, :platform_to_platform) do
    Map.get(platform_target_index, target.stop_id, MapSet.new([target.stop_id]))
  end

  defp target_set_empty?(set), do: MapSet.size(set) == 0

  # ── Index builders ────────────────────────────────────────────────────────

  defp build_stop_index(child_stops) do
    Map.new(child_stops, fn stop -> {stop.stop_id, stop} end)
  end

  defp build_pathway_index(pathways) do
    Map.new(pathways, fn pw -> {pw.pathway_id, pw} end)
  end

  defp build_level_index(levels) do
    levels
    |> Enum.map(fn %{level: level} -> level end)
    |> Map.new(fn level -> {level.level_id, level} end)
  end

  defp level_for_stop(nil, _level_index), do: nil

  defp level_for_stop(stop, level_index) do
    Map.get(level_index, stop.level_id)
  end

  defp compute_level_diff(from_stop, to_stop, level_index) do
    from_level = level_for_stop(from_stop, level_index)
    to_level = level_for_stop(to_stop, level_index)

    if from_level && to_level && is_number(from_level.level_index) &&
         is_number(to_level.level_index) do
      abs(to_level.level_index - from_level.level_index)
    else
      nil
    end
  end

  defp build_target_meta(nil, _level), do: ""

  defp build_target_meta(target, level) do
    type_label = Stop.location_type_label(normalize_location_type(target.location_type))
    level_name = level && level.level_name
    level_idx = level && level.level_index

    parts = [type_label]
    parts = if level_name, do: parts ++ [level_name], else: parts

    parts =
      if is_number(level_idx) do
        formatted =
          if level_idx < 0 do
            "\u2212" <> :erlang.float_to_binary(abs(level_idx / 1.0), decimals: 1)
          else
            :erlang.float_to_binary(level_idx / 1.0, decimals: 1)
          end

        parts ++ [formatted]
      else
        parts
      end

    Enum.join(parts, " \u00b7 ")
  end

  defp path_segments(path), do: do_path_segments(path, [])

  defp do_path_segments([from_hop, to_hop | rest], acc) do
    do_path_segments([to_hop | rest], [{from_hop, to_hop} | acc])
  end

  defp do_path_segments(_path, acc), do: Enum.reverse(acc)

  defp effective_signposted_as(hop) do
    normalize_signposted_as(hop.signposted_as)
  end

  defp normalize_signposted_as(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_signposted_as(value), do: value

  defp normalize_location_type(location_type) when is_integer(location_type), do: location_type
  defp normalize_location_type(_), do: -1

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true
end
