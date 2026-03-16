defmodule GtfsPlanner.Gtfs.StationReport do
  @moduledoc """
  Pure station report builder for deterministic station metrics.

  Accepts a station snapshot and returns a stable report contract that can be
  rendered in LiveViews or reused by other interfaces.
  """

  alias GtfsPlanner.Gtfs.{Pathway, Stop, TraversalCalculator}

  @type status :: :pass | :fail | :warn | :info

  @type item :: %{
          id: String.t(),
          label: String.t(),
          status: status(),
          value: term(),
          details: term()
        }

  @type section :: %{
          id: String.t(),
          title: String.t(),
          items: [item()]
        }

  @type report :: %{
          station_stop_id: String.t(),
          generated_at: DateTime.t(),
          sections: [section()]
        }

  @step_free_modes MapSet.new([1, 3, 5, 6, 7])
  @elevator_coverage_modes MapSet.new([1, 3, 5, 6, 7])

  @pathway_completeness_fields [
    :traversal_time,
    :length,
    :min_width,
    :max_slope,
    :stair_count,
    :signposted_as,
    :reversed_signposted_as
  ]

  @mode_specific_fields %{
    1 => [:traversal_time, :length, :min_width, :max_slope],
    2 => [:traversal_time, :length, :stair_count],
    3 => [:traversal_time, :length, :min_width],
    4 => [:traversal_time],
    5 => [:traversal_time, :min_width],
    6 => [:traversal_time, :min_width],
    7 => [:traversal_time, :min_width]
  }

  @unavailable_metrics [
    "pathway_evolutions coverage/readiness",
    "wheelchair_assistance and wheelchair_assistance_phone",
    "mechanical_stair_count",
    "max_stair_flight",
    "surface_type",
    "handrail",
    "instructions and reversed_instructions",
    "generic-node semantic subcategories",
    "Pathways Equivalent (PE) complexity score"
  ]

  @doc """
  Builds a deterministic station report from a snapshot map.

  The snapshot must include `:station`, `:child_stops`, `:levels`, and `:pathways`.
  """
  @spec build(%{
          station: Stop.t(),
          child_stops: [Stop.t()],
          levels: [map()],
          pathways: [Pathway.t()]
        }) :: report()
  def build(%{station: station, child_stops: child_stops, levels: levels, pathways: pathways}) do
    stop_index = index_by_stop_id([station | child_stops])
    level_index = index_levels(levels)
    pathway_index = pathway_index(pathways)
    platform_target_index = build_platform_target_index(child_stops)
    node_set = MapSet.new(Enum.map(child_stops, & &1.stop_id))

    station_pathways = Enum.filter(pathways, &pathway_touches_nodes?(&1, node_set))
    core_pathways = Enum.filter(pathways, &pathway_inside_nodes?(&1, node_set))

    directed = build_directed_adjacency(core_pathways)
    undirected = build_undirected_adjacency(core_pathways)

    %{
      station_stop_id: station.stop_id,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      sections: [
        inventory_section(station, child_stops, levels, station_pathways),
        gps_section(station, child_stops),
        data_integrity_section(station, child_stops, undirected, directed, stop_index),
        entrance_platform_connectivity_section(
          child_stops,
          core_pathways,
          pathway_index,
          stop_index,
          level_index,
          platform_target_index
        ),
        accessibility_section(child_stops, core_pathways, stop_index, level_index),
        attribute_completeness_section(station_pathways),
        unavailable_section()
      ]
    }
  end

  defp inventory_section(station, child_stops, levels, pathways) do
    stops = [station | child_stops]

    node_counts =
      stops
      |> Enum.group_by(&normalize_location_type(&1.location_type))
      |> Enum.into(%{}, fn {location_type, nodes} -> {location_type, length(nodes)} end)

    edge_counts =
      pathways
      |> Enum.group_by(&normalize_pathway_mode(&1.pathway_mode))
      |> Enum.into(%{}, fn {mode, edges} -> {mode, length(edges)} end)

    directionality = %{
      bidirectional: Enum.count(pathways, & &1.is_bidirectional),
      unidirectional: Enum.count(pathways, &(not &1.is_bidirectional))
    }

    nodes_per_level =
      child_stops
      |> Enum.group_by(fn stop -> stop.level_id || "unassigned" end)
      |> Enum.into(%{}, fn {level_id, stops_on_level} -> {level_id, length(stops_on_level)} end)

    level_summary =
      Enum.map(levels, fn %{level: level, stop_count: stop_count} ->
        %{
          level_id: level.level_id,
          level_name: level.level_name,
          level_index: level.level_index,
          stop_count: stop_count
        }
      end)

    %{
      id: "inventory",
      title: "Station Inventory",
      items: [
        item("node_inventory", "Node inventory by location_type", :info, node_counts),
        item("edge_inventory", "Edge inventory by pathway_mode", :info, edge_counts),
        item(
          "pathway_directionality",
          "Bidirectional vs unidirectional pathways",
          :info,
          directionality
        ),
        item(
          "level_summary",
          "Level count, names, and indices",
          :info,
          length(levels),
          level_summary
        ),
        item("nodes_per_level", "Nodes per level", :info, nodes_per_level)
      ]
    }
  end

  defp gps_section(station, child_stops) do
    stops = [station | child_stops]
    required_types = MapSet.new([0, 1, 2])

    grouped = Enum.group_by(stops, &normalize_location_type(&1.location_type))

    by_type =
      grouped
      |> Enum.into(%{}, fn {location_type, type_stops} ->
        present = Enum.count(type_stops, &has_coordinates?/1)
        missing = length(type_stops) - present

        type_key = Integer.to_string(location_type)

        {type_key,
         %{
           present: present,
           missing: missing,
           required: MapSet.member?(required_types, location_type)
         }}
      end)

    required_missing =
      by_type
      |> Enum.filter(fn {_type, data} -> data.required end)
      |> Enum.map(fn {_type, data} -> data.missing end)
      |> Enum.sum()

    %{
      id: "gps",
      title: "GPS Coordinate Presence",
      items: [
        item(
          "gps_presence_by_type",
          "GPS presence by location_type",
          if(required_missing == 0, do: :pass, else: :fail),
          by_type
        )
      ]
    }
  end

  defp data_integrity_section(station, child_stops, undirected, directed, stop_index) do
    station_stop_id = station.stop_id

    monitored_nodes = Enum.filter(child_stops, &(&1.location_type in [2, 3, 4]))

    isolated_ids =
      monitored_nodes
      |> Enum.map(& &1.stop_id)
      |> Enum.reject(fn stop_id ->
        neighbors = Map.get(undirected, stop_id, MapSet.new())
        MapSet.size(neighbors) > 0
      end)

    boarding_areas = Enum.filter(child_stops, &(&1.location_type == 4))
    platforms = Enum.filter(child_stops, &(&1.location_type == 0))
    entrances = Enum.filter(child_stops, &(&1.location_type == 2))
    generic_nodes = Enum.filter(child_stops, &(&1.location_type == 3))

    bad_boarding_parents =
      boarding_areas
      |> Enum.filter(fn stop ->
        case Map.get(stop_index, stop.parent_station) do
          %Stop{location_type: 0} -> false
          _ -> true
        end
      end)
      |> Enum.map(& &1.stop_id)

    station_parent_violations =
      (platforms ++ entrances ++ generic_nodes)
      |> Enum.filter(&(&1.parent_station != station_stop_id))
      |> Enum.map(& &1.stop_id)

    orphaned_platforms =
      platforms
      |> Enum.reject(fn platform ->
        Enum.any?(boarding_areas, &(&1.parent_station == platform.stop_id))
      end)
      |> Enum.map(& &1.stop_id)

    minimum_children_ok = platforms != [] and entrances != []

    entrance_boarding = entrance_to_boarding_result(entrances, boarding_areas, directed)
    boarding_interconnection = boarding_interconnection_result(boarding_areas, directed)

    %{
      id: "data_integrity",
      title: "Data Integrity",
      items: [
        item(
          "isolated_nodes",
          "Isolated nodes for location_type 2/3/4",
          if(isolated_ids == [], do: :pass, else: :fail),
          length(isolated_ids),
          isolated_ids
        ),
        item(
          "boarding_area_parent_consistency",
          "Boarding areas must have platform parent_station",
          if(bad_boarding_parents == [], do: :pass, else: :fail),
          length(bad_boarding_parents),
          bad_boarding_parents
        ),
        item(
          "station_parent_consistency",
          "Platform/entrance/generic parent_station must be station",
          if(station_parent_violations == [], do: :pass, else: :fail),
          length(station_parent_violations),
          station_parent_violations
        ),
        item(
          "orphaned_platforms",
          "Platforms missing boarding-area children",
          if(orphaned_platforms == [], do: :pass, else: :fail),
          length(orphaned_platforms),
          orphaned_platforms
        ),
        item(
          "minimum_station_children",
          "Minimum station children (>= 1 entrance and >= 1 platform)",
          if(minimum_children_ok, do: :pass, else: :fail),
          minimum_children_ok,
          %{entrances: length(entrances), platforms: length(platforms)}
        ),
        item(
          "entrance_to_boarding_connectivity",
          "Entrance-to-boarding reachability",
          if(entrance_boarding.unreachable == [], do: :pass, else: :fail),
          %{
            reachable: entrance_boarding.reachable_count,
            unreachable: length(entrance_boarding.unreachable)
          },
          entrance_boarding.details
        ),
        item(
          "boarding_area_interconnection",
          "Boarding-area interconnection reachability",
          if(boarding_interconnection.unreachable == [], do: :pass, else: :fail),
          %{
            connected: boarding_interconnection.connected_count,
            disconnected: length(boarding_interconnection.unreachable)
          },
          boarding_interconnection.details
        )
      ]
    }
  end

  defp accessibility_section(child_stops, pathways, stop_index, level_index) do
    entrances = Enum.filter(child_stops, &(&1.location_type == 2))
    boarding_areas = Enum.filter(child_stops, &(&1.location_type == 4))

    step_free_directed =
      pathways
      |> Enum.filter(&MapSet.member?(@step_free_modes, normalize_pathway_mode(&1.pathway_mode)))
      |> build_directed_adjacency()

    elevator_directed =
      pathways
      |> Enum.filter(
        &MapSet.member?(@elevator_coverage_modes, normalize_pathway_mode(&1.pathway_mode))
      )
      |> build_directed_adjacency()

    step_free_result = step_free_result(entrances, boarding_areas, step_free_directed)

    wheelchair_distribution =
      child_stops
      |> Enum.group_by(&normalize_location_type(&1.location_type))
      |> Enum.into(%{}, fn {location_type, stops} ->
        counts =
          stops
          |> Enum.group_by(fn stop -> stop.wheelchair_boarding end)
          |> Enum.into(%{}, fn {value, value_stops} ->
            {normalize_wheelchair(value), length(value_stops)}
          end)

        {Integer.to_string(location_type), counts}
      end)

    elevator_coverage = elevator_coverage_result(child_stops, elevator_directed, level_index)

    escalator_direction =
      escalator_direction_result(
        Enum.filter(pathways, &(normalize_pathway_mode(&1.pathway_mode) == 4)),
        stop_index,
        level_index
      )

    %{
      id: "accessibility",
      title: "Accessibility Completeness",
      items: [
        item(
          "step_free_routes",
          "Step-free routes (entrance x boarding)",
          case step_free_result.status do
            :ok -> :pass
            :missing_pairs -> :warn
            :gaps -> :fail
          end,
          step_free_result.summary,
          step_free_result.matrix
        ),
        item(
          "wheelchair_boarding_distribution",
          "Wheelchair boarding distribution by location_type",
          :info,
          wheelchair_distribution
        ),
        item(
          "elevator_level_coverage",
          "Elevator-inclusive level reachability",
          if(elevator_coverage.unreachable_levels == [], do: :pass, else: :warn),
          %{
            reachable_levels: elevator_coverage.reachable_count,
            unreachable_levels: length(elevator_coverage.unreachable_levels)
          },
          elevator_coverage
        ),
        item(
          "escalator_direction_summary",
          "Escalator direction summary (up/down/unknown)",
          :info,
          escalator_direction
        )
      ]
    }
  end

  defp attribute_completeness_section(pathways) do
    field_stats =
      Enum.into(@pathway_completeness_fields, %{}, fn field ->
        {field, completeness_for_field(pathways, field)}
      end)

    mode_specific =
      @mode_specific_fields
      |> Enum.into(%{}, fn {mode, fields} ->
        mode_pathways = Enum.filter(pathways, &(normalize_pathway_mode(&1.pathway_mode) == mode))

        stats =
          fields
          |> Enum.into(%{}, fn field ->
            {field, completeness_for_field(mode_pathways, field)}
          end)

        {mode, stats}
      end)

    signage =
      Enum.reduce(
        pathways,
        %{
          signposted_as: %{present: 0, total: 0},
          reversed_signposted_as: %{present: 0, total: 0}
        },
        fn pathway, acc ->
          acc
          |> increment_presence(:signposted_as, present?(pathway.signposted_as))
          |> increment_presence(
            :reversed_signposted_as,
            pathway.is_bidirectional and present?(pathway.reversed_signposted_as),
            pathway.is_bidirectional
          )
        end
      )
      |> Enum.into(%{}, fn {key, value} ->
        {key, percentify(value)}
      end)

    %{
      id: "attribute_completeness",
      title: "Attribute Completeness",
      items: [
        item(
          "pathway_attribute_completeness",
          "Pathway attribute completeness",
          :info,
          field_stats
        ),
        item(
          "mode_specific_completeness",
          "Mode-specific pathway completeness",
          :info,
          mode_specific
        ),
        item("signage_completeness", "Signage completeness", :info, signage)
      ]
    }
  end

  defp entrance_platform_connectivity_section(
         child_stops,
         pathways,
         pathway_index,
         stop_index,
         level_index,
         platform_target_index
       ) do
    {entrances, platforms} = entrances_and_platforms(child_stops)

    cond do
      entrances == [] or platforms == [] ->
        %{
          id: "entrance_platform_connectivity",
          title: "Entrance -> Platform Connectivity",
          items: [
            item(
              "entrance_platform_paths",
              "Entrance-to-platform directed paths",
              :warn,
              %{
                entrances: 0,
                platforms: 0,
                connected_pairs: 0,
                accessible_pairs: 0,
                total_pairs: 0
              },
              []
            )
          ]
        }

      true ->
        all_adjacency = build_path_traversal_adjacency(pathways)
        step_free_adjacency = build_step_free_path_traversal_adjacency(pathways)

        details =
          for entrance <- entrances, platform <- platforms do
            targets =
              Map.get(
                platform_target_index,
                platform.stop_id,
                MapSet.new([platform.stop_id])
              )

            shortest_result =
              shortest_directed_path_to_any(all_adjacency, entrance.stop_id, targets)

            accessible_result =
              shortest_directed_path_to_any(step_free_adjacency, entrance.stop_id, targets)

            {shortest_data, accessible_data, paths_identical} =
              case {shortest_result, accessible_result} do
                {{:found, s_path}, {:found, a_path}} ->
                  s_enriched = enrich_path(s_path, pathway_index, stop_index, level_index)
                  a_enriched = enrich_path(a_path, pathway_index, stop_index, level_index)

                  identical =
                    Enum.map(s_path, & &1.stop_id) == Enum.map(a_path, & &1.stop_id)

                  {
                    %{path: s_path, enriched: s_enriched},
                    %{path: a_path, enriched: a_enriched},
                    identical
                  }

                {{:found, s_path}, :not_found} ->
                  s_enriched = enrich_path(s_path, pathway_index, stop_index, level_index)
                  {%{path: s_path, enriched: s_enriched}, nil, false}

                {:not_found, {:found, a_path}} ->
                  a_enriched = enrich_path(a_path, pathway_index, stop_index, level_index)
                  {nil, %{path: a_path, enriched: a_enriched}, false}

                {:not_found, :not_found} ->
                  {nil, nil, false}
              end

            %{
              entrance_stop_id: entrance.stop_id,
              platform_stop_id: platform.stop_id,
              reachable: shortest_data != nil,
              accessible: accessible_data != nil,
              shortest: shortest_data,
              accessible_path: accessible_data,
              paths_identical: paths_identical
            }
          end

        connected_pairs = Enum.count(details, & &1.reachable)
        accessible_pairs = Enum.count(details, & &1.accessible)
        total_pairs = length(details)

        %{
          id: "entrance_platform_connectivity",
          title: "Entrance -> Platform Connectivity",
          items: [
            item(
              "entrance_platform_paths",
              "Entrance-to-platform directed paths",
              if(connected_pairs == total_pairs and total_pairs > 0, do: :pass, else: :fail),
              %{
                entrances: length(entrances),
                platforms: length(platforms),
                connected_pairs: connected_pairs,
                accessible_pairs: accessible_pairs,
                total_pairs: total_pairs
              },
              details
            )
          ]
        }
    end
  end

  defp unavailable_section do
    %{
      id: "not_available",
      title: "Not Available In Current Schema",
      items: [
        item(
          "unavailable_metrics",
          "Excluded metrics",
          :info,
          length(@unavailable_metrics),
          @unavailable_metrics
        )
      ]
    }
  end

  defp entrance_to_boarding_result(entrances, boarding_areas, directed) do
    boarding_ids = MapSet.new(Enum.map(boarding_areas, & &1.stop_id))

    details =
      Enum.map(entrances, fn entrance ->
        reachable = reachable?(entrance.stop_id, boarding_ids, directed)
        %{entrance_stop_id: entrance.stop_id, reachable: reachable}
      end)

    unreachable = Enum.filter(details, &(not &1.reachable))

    %{
      details: details,
      unreachable: unreachable,
      reachable_count: length(details) - length(unreachable)
    }
  end

  defp boarding_interconnection_result(boarding_areas, directed) do
    boarding_ids = Enum.map(boarding_areas, & &1.stop_id)

    details =
      Enum.map(boarding_ids, fn boarding_id ->
        other_boarding_ids = boarding_ids |> Enum.reject(&(&1 == boarding_id)) |> MapSet.new()
        reachable = reachable?(boarding_id, other_boarding_ids, directed)
        %{boarding_stop_id: boarding_id, connected: reachable}
      end)

    unreachable = Enum.filter(details, &(not &1.connected))

    %{
      details: details,
      unreachable: unreachable,
      connected_count: length(details) - length(unreachable)
    }
  end

  defp step_free_result(entrances, boarding_areas, directed) do
    cond do
      entrances == [] or boarding_areas == [] ->
        %{
          status: :missing_pairs,
          summary: %{
            entrances: length(entrances),
            boarding_areas: length(boarding_areas),
            connected_pairs: 0,
            total_pairs: 0
          },
          matrix: []
        }

      true ->
        matrix =
          for entrance <- entrances, boarding_area <- boarding_areas do
            reachable =
              reachable?(entrance.stop_id, MapSet.new([boarding_area.stop_id]), directed)

            %{
              entrance_stop_id: entrance.stop_id,
              platform_stop_id: boarding_area.stop_id,
              reachable: reachable
            }
          end

        total_pairs = length(matrix)
        connected_pairs = Enum.count(matrix, & &1.reachable)

        %{
          status: if(connected_pairs == total_pairs, do: :ok, else: :gaps),
          summary: %{
            entrances: length(entrances),
            boarding_areas: length(boarding_areas),
            connected_pairs: connected_pairs,
            total_pairs: total_pairs
          },
          matrix: matrix
        }
    end
  end

  defp elevator_coverage_result(child_stops, directed, level_index) do
    level_ids_with_nodes =
      child_stops
      |> Enum.map(& &1.level_id)
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    entrances = Enum.filter(child_stops, &(&1.location_type == 2 and present?(&1.level_id)))

    starts =
      case entrances do
        [] -> Enum.map(child_stops, & &1.stop_id)
        _ -> Enum.map(entrances, & &1.stop_id)
      end

    reachable_nodes =
      Enum.reduce(starts, MapSet.new(), fn start, acc ->
        MapSet.union(acc, bfs(start, directed))
      end)

    reachable_levels =
      child_stops
      |> Enum.filter(&MapSet.member?(reachable_nodes, &1.stop_id))
      |> Enum.map(& &1.level_id)
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    unreachable_levels =
      level_ids_with_nodes
      |> MapSet.difference(reachable_levels)
      |> Enum.map(fn level_id ->
        case Map.get(level_index, level_id) do
          nil -> %{level_id: level_id, level_index: nil}
          level -> %{level_id: level_id, level_index: level.level_index}
        end
      end)
      |> Enum.sort_by(
        &{if(is_number(&1.level_index), do: 0, else: 1), &1.level_index || 0, &1.level_id}
      )

    %{
      level_ids_with_nodes: MapSet.to_list(level_ids_with_nodes),
      reachable_level_ids: MapSet.to_list(reachable_levels),
      reachable_count: MapSet.size(reachable_levels),
      unreachable_levels: unreachable_levels
    }
  end

  defp escalator_direction_result(escalators, stop_index, level_index) do
    Enum.reduce(escalators, %{up: 0, down: 0, unknown: 0}, fn escalator, acc ->
      from_stop = Map.get(stop_index, escalator.from_stop_id)
      to_stop = Map.get(stop_index, escalator.to_stop_id)

      from_index = level_index_for_stop(from_stop, level_index)
      to_index = level_index_for_stop(to_stop, level_index)

      cond do
        escalator.is_bidirectional ->
          Map.update!(acc, :unknown, &(&1 + 1))

        is_number(from_index) and is_number(to_index) and to_index > from_index ->
          Map.update!(acc, :up, &(&1 + 1))

        is_number(from_index) and is_number(to_index) and to_index < from_index ->
          Map.update!(acc, :down, &(&1 + 1))

        true ->
          Map.update!(acc, :unknown, &(&1 + 1))
      end
    end)
  end

  defp level_index_for_stop(nil, _level_index), do: nil

  defp level_index_for_stop(stop, level_index) do
    case Map.get(level_index, stop.level_id) do
      nil -> nil
      level -> level.level_index
    end
  end

  defp increment_presence(acc, key, present), do: increment_presence(acc, key, present, true)

  defp increment_presence(acc, key, present, include?) do
    data = Map.fetch!(acc, key)

    if include? do
      Map.put(acc, key, %{
        present: data.present + if(present, do: 1, else: 0),
        total: data.total + 1
      })
    else
      acc
    end
  end

  defp completeness_for_field(pathways, field) do
    total = length(pathways)
    present = Enum.count(pathways, &present?(Map.get(&1, field)))
    percentify(%{present: present, total: total})
  end

  defp percentify(%{present: present, total: total}) do
    percent =
      if total == 0 do
        0
      else
        Float.round(present * 100.0 / total, 1)
      end

    %{present: present, total: total, percent: percent}
  end

  defp item(id, label, status, value, details \\ nil) do
    %{id: id, label: label, status: status, value: value, details: details}
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

  defp build_path_traversal_adjacency(pathways) do
    pathways
    |> Enum.sort_by(&pathway_id_sort_key/1)
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

  defp build_step_free_path_traversal_adjacency(pathways) do
    pathways
    |> Enum.filter(&MapSet.member?(@step_free_modes, normalize_pathway_mode(&1.pathway_mode)))
    |> build_path_traversal_adjacency()
  end

  defp put_path_edge(adjacency, from_stop_id, to_stop_id, pathway) do
    edge = %{
      to_stop_id: to_stop_id,
      pathway_id: pathway.pathway_id,
      pathway_mode: normalize_pathway_mode(pathway.pathway_mode)
    }

    Map.update(adjacency, from_stop_id, [edge], &[edge | &1])
  end

  defp shortest_directed_path(adjacency, start_stop_id, target_stop_id) do
    shortest_directed_path_to_any(
      adjacency,
      start_stop_id,
      MapSet.new([target_stop_id])
    )
  end

  defp shortest_directed_path_to_any(adjacency, start_stop_id, target_ids) do
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

  defp reconstruct_path_hops(_came_from, nil, acc), do: acc

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

  defp entrances_and_boarding_areas(child_stops) do
    entrances =
      child_stops
      |> Enum.filter(&(&1.location_type == 2))
      |> Enum.sort_by(& &1.stop_id)

    boarding_areas =
      child_stops
      |> Enum.filter(&(&1.location_type == 4))
      |> Enum.sort_by(& &1.stop_id)

    {entrances, boarding_areas}
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

  defp pathway_id_sort_key(pathway), do: pathway.pathway_id || ""

  defp pathway_index(pathways) do
    Enum.reduce(pathways, %{}, fn pathway, acc ->
      Map.put(acc, pathway.pathway_id, pathway)
    end)
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

  defp level_for_stop(nil, _level_index), do: nil

  defp level_for_stop(stop, level_index) do
    Map.get(level_index, stop.level_id)
  end

  defp traversed_reverse?(nil, _from_stop_id, _to_stop_id), do: nil

  defp traversed_reverse?(pathway, from_stop_id, to_stop_id) do
    pathway.from_stop_id == to_stop_id and pathway.to_stop_id == from_stop_id
  end

  defp effective_signposted_as(%{traversed_reverse?: true, is_bidirectional: true} = hop) do
    normalize_signposted_as(hop.reversed_signposted_as) ||
      normalize_signposted_as(hop.signposted_as)
  end

  defp effective_signposted_as(hop) do
    normalize_signposted_as(hop.signposted_as)
  end

  defp path_segments(path), do: do_path_segments(path, [])

  defp do_path_segments([from_hop, to_hop | rest], acc) do
    do_path_segments([to_hop | rest], [{from_hop, to_hop} | acc])
  end

  defp do_path_segments(_path, acc), do: Enum.reverse(acc)

  defp enrich_path([], _pathway_index, _stop_index, _level_index), do: nil

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
        traversal = if pathway, do: TraversalCalculator.calculate(pathway, level_diff), else: nil
        traversed_reverse? = traversed_reverse?(pathway, from_hop.stop_id, to_hop.stop_id)

        build_enriched_hop(
          to_hop,
          to_stop,
          pathway,
          traversal,
          level_diff,
          level_index,
          traversed_reverse?
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

  defp build_enriched_hop(
         hop,
         stop,
         pathway,
         traversal,
         level_diff,
         level_index,
         traversed_reverse? \\ nil
       ) do
    stop_level = if stop, do: stop.level_id, else: nil

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
      level_id: stop_level,
      level_name: level_data && level_data.level_name,
      level_index: level_data && level_data.level_index,
      pathway_id: hop.pathway_id,
      pathway_mode: hop.pathway_mode,
      pathway_mode_label:
        if(is_integer(hop.pathway_mode), do: Pathway.mode_label(hop.pathway_mode), else: nil),
      is_bidirectional: pathway && pathway.is_bidirectional,
      traversed_reverse?: traversed_reverse?,
      signposted_as: pathway && pathway.signposted_as,
      reversed_signposted_as: pathway && pathway.reversed_signposted_as,
      level_diff: level_diff,
      time_seconds: traversal && traversal.time_seconds,
      distance_meters: traversal && traversal.distance_meters,
      calculation_method: traversal && traversal.calculation_method
    }
  end

  defp path_totals(hops, pathway_hops) do
    segment_count = max(length(hops) - 1, 0)

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

    unique_levels =
      hops
      |> Enum.map(& &1.level_id)
      |> Enum.filter(&present?/1)
      |> Enum.uniq()
      |> length()

    signposted_segments = Enum.count(pathway_hops, &present?(effective_signposted_as(&1)))
    has_stairs = Enum.any?(pathway_hops, &(&1.pathway_mode == 2))
    has_escalator = Enum.any?(pathway_hops, &(&1.pathway_mode == 4))
    has_elevator = Enum.any?(pathway_hops, &(&1.pathway_mode == 5))

    %{
      time_seconds: Float.round(time_seconds, 2),
      distance_meters: Float.round(distance_meters, 2),
      segment_count: segment_count,
      level_changes: level_changes,
      unique_levels: unique_levels,
      signposted_segments: signposted_segments,
      has_stairs: has_stairs,
      has_escalator: has_escalator,
      has_elevator: has_elevator,
      effective_speed:
        if(time_seconds > 0 and distance_meters > 0,
          do: Float.round(distance_meters / time_seconds, 2),
          else: nil
        )
    }
  end

  defp build_undirected_adjacency(pathways) do
    Enum.reduce(pathways, %{}, fn pathway, acc ->
      acc
      |> put_edge(pathway.from_stop_id, pathway.to_stop_id)
      |> put_edge(pathway.to_stop_id, pathway.from_stop_id)
    end)
  end

  defp put_edge(adjacency, from_stop_id, to_stop_id) do
    Map.update(adjacency, from_stop_id, MapSet.new([to_stop_id]), &MapSet.put(&1, to_stop_id))
  end

  defp pathway_touches_nodes?(pathway, node_set) do
    MapSet.member?(node_set, pathway.from_stop_id) or MapSet.member?(node_set, pathway.to_stop_id)
  end

  defp pathway_inside_nodes?(pathway, node_set) do
    MapSet.member?(node_set, pathway.from_stop_id) and
      MapSet.member?(node_set, pathway.to_stop_id)
  end

  defp index_by_stop_id(stops) do
    Map.new(stops, fn stop -> {stop.stop_id, stop} end)
  end

  defp index_levels(levels) do
    levels
    |> Enum.map(fn %{level: level} -> level end)
    |> Map.new(fn level -> {level.level_id, level} end)
  end

  defp has_coordinates?(stop) do
    not is_nil(stop.stop_lat) and not is_nil(stop.stop_lon)
  end

  defp normalize_location_type(location_type) when is_integer(location_type), do: location_type
  defp normalize_location_type(_), do: -1

  defp normalize_pathway_mode(pathway_mode) when is_integer(pathway_mode), do: pathway_mode
  defp normalize_pathway_mode(_), do: -1

  defp normalize_wheelchair(nil), do: "empty"
  defp normalize_wheelchair(value), do: Integer.to_string(value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  defp normalize_signposted_as(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_signposted_as(value), do: value
end
