defmodule GtfsPlanner.Gtfs.StationReport do
  @moduledoc """
  Pure station report builder for deterministic station metrics.

  Accepts a station snapshot and returns a stable report contract that can be
  rendered in LiveViews or reused by other interfaces.
  """

  alias GtfsPlanner.Gtfs.{Pathway, Stop}

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
        accessibility_section(child_stops, core_pathways, stop_index, level_index),
        entrance_platform_connectivity_section(child_stops, core_pathways),
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

  defp entrance_platform_connectivity_section(child_stops, pathways) do
    {entrances, boarding_areas} = entrances_and_boarding_areas(child_stops)

    cond do
      entrances == [] or boarding_areas == [] ->
        %{
          id: "entrance_platform_connectivity",
          title: "Entrance -> Boarding Connectivity",
          items: [
            item(
              "entrance_platform_paths",
              "Entrance-to-boarding directed shortest paths",
              :warn,
              %{entrances: 0, boarding_areas: 0, connected_pairs: 0, total_pairs: 0},
              []
            )
          ]
        }

      true ->
        adjacency = build_path_traversal_adjacency(pathways)

        details =
          for entrance <- entrances, boarding_area <- boarding_areas do
            case shortest_directed_path(adjacency, entrance.stop_id, boarding_area.stop_id) do
              {:found, path} ->
                %{
                  entrance_stop_id: entrance.stop_id,
                  platform_stop_id: boarding_area.stop_id,
                  reachable: true,
                  path: path
                }

              :not_found ->
                %{
                  entrance_stop_id: entrance.stop_id,
                  platform_stop_id: boarding_area.stop_id,
                  reachable: false,
                  path: []
                }
            end
          end

        connected_pairs = Enum.count(details, & &1.reachable)
        total_pairs = length(details)

        %{
          id: "entrance_platform_connectivity",
          title: "Entrance -> Boarding Connectivity",
          items: [
            item(
              "entrance_platform_paths",
              "Entrance-to-boarding directed shortest paths",
              if(connected_pairs == total_pairs and total_pairs > 0, do: :pass, else: :fail),
              %{
                entrances: length(entrances),
                boarding_areas: length(boarding_areas),
                connected_pairs: connected_pairs,
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

  defp put_path_edge(adjacency, from_stop_id, to_stop_id, pathway) do
    edge = %{
      to_stop_id: to_stop_id,
      pathway_id: pathway.pathway_id,
      pathway_mode: normalize_pathway_mode(pathway.pathway_mode)
    }

    Map.update(adjacency, from_stop_id, [edge], &[edge | &1])
  end

  defp shortest_directed_path(adjacency, start_stop_id, target_stop_id) do
    queue = :queue.from_list([start_stop_id])
    visited = MapSet.new([start_stop_id])

    do_shortest_directed_path(
      queue,
      visited,
      %{},
      adjacency,
      start_stop_id,
      target_stop_id
    )
  end

  defp do_shortest_directed_path(
         queue,
         visited,
         came_from,
         adjacency,
         start_stop_id,
         target_stop_id
       ) do
    case :queue.out(queue) do
      {{:value, current}, rest} ->
        if current == target_stop_id do
          {:found, reconstruct_path(came_from, start_stop_id, target_stop_id)}
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

          do_shortest_directed_path(
            next_queue,
            next_visited,
            next_came_from,
            adjacency,
            start_stop_id,
            target_stop_id
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

  defp pathway_id_sort_key(pathway), do: pathway.pathway_id || ""

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
end
