defmodule GtfsPlanner.Agents.Packs.FareZones do
  @moduledoc """
  The Fare zone helper pack: bounded, read-only answers about the fare zones of
  the service version the conversation is bound to.

  Every tool takes its organization and version from the scope, never from an
  argument, so a tool can only read the version the person is looking at (INV-1).
  `list_zones` lists the version's inventory zones with their exact stop and rule
  counts, or only the zones whose ID or name contains an optional query.
  `find_routes` and `find_stops` return at most 20 candidates by name or ID,
  with the exact total and an incomplete marker, so an ambiguous name produces
  candidates for the person to choose from and never a guess. `query_zone_targets`
  resolves a route selection through `FareZones.route_selection/3`, the one owner of
  what such a selection means, into exact counts, a bounded sample with the other
  routes serving each stop, the shared routes and the selection fingerprint as
  evidence. `prepare_zone_assignment` resolves the same selection again on the
  server, previews the assignment and returns a prepared command that carries the
  explicit stop UUIDs, the predicate and the fingerprint; the native zone review
  decides whether and when it is saved. Each answer returns the server evidence the panel trusts beside the
  model's result. No tool writes anything and none accepts an organization, a
  version, a stop UUID or an "all" flag.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Packs.FareEvidence
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Wording

  @source_ref "gtfs_fare_zones"
  @zone_limit 50
  @candidate_limit 20
  @sample_limit 20
  @shared_route_limit 20
  @unavailable "This version is no longer available."

  @skill_path Path.expand("../../../../priv/agents/packs/fare_zones/SKILL.md", __DIR__)
  @external_resource @skill_path

  @skill @skill_path
         |> File.read!()
         |> String.split("\n")
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.join("\n")
         |> String.trim()

  @impl true
  def id, do: "fare_zones"

  @impl true
  def title, do: "Fare zone helper"

  @impl true
  def intro do
    "I can find stops by route, show their fare zones and shared routes, and prepare a zone assignment for you to review. I can't save or change anything."
  end

  @impl true
  def examples,
    do: [
      "Put unzoned Route 6 stops in Zone B except Airport",
      "Which Route 6 stops have no zone?"
    ]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "list_zones",
        description:
          "List the fare zones of this version with their zone ID, name, stop count and rule count. At most #{@zone_limit} zones are returned with the exact total. Pass the optional query, part of a zone ID or name, to find one zone when the version has more zones than are returned.",
        activity: "Listed fare zones",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 100}
          },
          "required" => [],
          "additionalProperties" => false
        }
      },
      candidate_tool(
        "find_routes",
        "Find routes of this version by route ID, short name or long name. Returns at most #{@candidate_limit} candidates with their exact route IDs and the exact total; when there is more than one candidate, show them and ask which route is meant.",
        "Found routes"
      ),
      candidate_tool(
        "find_stops",
        "Find boardable stops of this version by stop ID or name. Returns at most #{@candidate_limit} candidates with their exact stop IDs, zone IDs and the exact total; when there is more than one candidate, show them and ask which stop is meant.",
        "Found stops"
      ),
      %{
        name: "query_zone_targets",
        description:
          "Count and sample the boardable stops that serve the named routes, before anything is prepared. route_ids are exact route IDs from find_routes; only_unzoned keeps stops with no zone; exclude_stop_ids are exact stop IDs from find_stops to leave out. Returns exact counts, a sample of at most #{@sample_limit} stops with their other routes, and the routes the selected stops share.",
        activity: "Counted stops to assign",
        parameters: %{
          "type" => "object",
          "properties" => selection_properties(),
          "required" => ["route_ids", "only_unzoned", "exclude_stop_ids"],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_zone_assignment",
        description:
          "Prepare assigning the selected stops to one zone, for the person to review. Takes the same route_ids, only_unzoned and exclude_stop_ids as query_zone_targets and zone_id, the exact zone ID from list_zones. Nothing is saved: the person reviews the stops in the zone review and saves there.",
        activity: "Prepared a zone assignment",
        parameters: %{
          "type" => "object",
          "properties" =>
            Map.put(selection_properties(), "zone_id", %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => 200
            }),
          "required" => ["route_ids", "only_unzoned", "exclude_stop_ids", "zone_id"],
          "additionalProperties" => false
        }
      }
    ]
  end

  # The predicate arguments shared by every tool that resolves a route selection.
  # Identity arguments are not declared, so the dispatch fence refuses them.
  defp selection_properties do
    limits = FareZones.selection_limits()

    %{
      "route_ids" => %{
        "type" => "array",
        "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
        "minItems" => 1,
        "maxItems" => limits.routes
      },
      "only_unzoned" => %{"type" => "boolean"},
      "exclude_stop_ids" => %{
        "type" => "array",
        "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
        "maxItems" => limits.exclusions
      }
    }
  end

  defp candidate_tool(name, description, activity) do
    %{
      name: name,
      description: description,
      activity: activity,
      parameters: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string", "minLength" => 1, "maxLength" => 100}},
        "required" => ["query"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(name, args, %Scope{} = scope) do
    case Scope.identity(scope) do
      {:version, version_id} when version_id == scope.gtfs_version_id -> run(name, args, scope)
      _other -> {:error, @unavailable}
    end
  end

  defp run("list_zones", args, scope) do
    with {:ok, query} <- parse_zone_query(args), do: list_zones(query, scope)
  end

  defp run("find_routes", args, scope), do: find_routes(args, scope)
  defp run("find_stops", args, scope), do: find_stops(args, scope)
  defp run("query_zone_targets", args, scope), do: query_zone_targets(args, scope)
  defp run("prepare_zone_assignment", args, scope), do: prepare_zone_assignment(args, scope)

  # -- tools ------------------------------------------------------------------

  defp list_zones(query, %Scope{} = scope) do
    inventory = FareZones.inventory(scope.organization_id, scope.gtfs_version_id)
    matches = Enum.filter(inventory.zones, &zone_matches?(&1, query))
    total = length(matches)

    rows =
      matches
      |> Enum.take(@zone_limit)
      |> Enum.map(fn zone ->
        %{
          "zone_id" => zone.zone_id,
          "name" => zone.name,
          "stop_count" => zone.stop_count,
          "rule_count" => zone.rule_count
        }
      end)

    reason =
      if total > @zone_limit do
        "Showing #{@zone_limit} of #{total} #{if query, do: "matching "}zones."
      end

    result =
      %{"zones" => rows, "total" => total}
      |> Map.merge(completeness_fields(reason))

    evidence =
      FareEvidence.build(scope, %{
        kind: "fare_zones",
        title: "Fare zones",
        total: total,
        total_label: if(query, do: "matching zones", else: "zones"),
        completeness: if(reason, do: :incomplete, else: :complete),
        completeness_reason: reason,
        facts: [
          %{label: "Boardable stops", value: Integer.to_string(inventory.boardable_count)},
          %{label: "Stops with no zone", value: Integer.to_string(inventory.unassigned_count)}
        ],
        source_ref: @source_ref,
        digest: FareEvidence.digest({:fare_zones, 1, rows, total})
      })

    {:ok, result, evidence}
  end

  # The query is optional: without one every zone matches. With one, a zone
  # matches when its ID or name contains the text, ignoring case.
  defp parse_zone_query(%{"query" => _query} = args), do: parse_query(args)
  defp parse_zone_query(_args), do: {:ok, nil}

  defp zone_matches?(_zone, nil), do: true

  defp zone_matches?(zone, query) do
    needle = String.downcase(query)

    Enum.any?([zone.zone_id, zone.name], fn text ->
      is_binary(text) and String.contains?(String.downcase(text), needle)
    end)
  end

  defp find_routes(args, %Scope{} = scope) do
    with {:ok, query} <- parse_query(args) do
      opts = [search: query, page: 1, per_page: @candidate_limit]
      routes = Gtfs.list_routes(scope.organization_id, scope.gtfs_version_id, opts)
      total = Gtfs.count_routes(scope.organization_id, scope.gtfs_version_id, search: query)

      rows =
        Enum.map(routes, fn route ->
          %{
            "route_id" => route.route_id,
            "short_name" => route.route_short_name,
            "long_name" => route.route_long_name
          }
        end)

      candidates(scope, "route_candidates", "Route candidates", "routes", "routes", rows, total,
        resources: Enum.map(rows, &%{kind: "route", id: &1["route_id"], label: &1["route_id"]})
      )
    end
  end

  defp find_stops(args, %Scope{} = scope) do
    with {:ok, query} <- parse_query(args) do
      page =
        FareZones.list_stops(scope.organization_id, scope.gtfs_version_id,
          q: query,
          per_page: @candidate_limit
        )

      rows =
        Enum.map(page.entries, fn stop ->
          %{
            "stop_id" => stop.stop_id,
            "stop_name" => stop.stop_name,
            "zone_id" => stop.zone_id,
            "parent_station" => stop.parent_station
          }
        end)

      candidates(
        scope,
        "stop_candidates",
        "Stop candidates",
        "stops",
        "stops",
        rows,
        page.total_count
      )
    end
  end

  defp query_zone_targets(args, %Scope{} = scope) do
    with {:ok, predicate} <- parse_predicate(args),
         {:ok, selection} <- resolve_selection(scope, predicate) do
      sample =
        selection.stops
        |> Enum.take(@sample_limit)
        |> Enum.map(&sample_row(&1, selection, predicate))

      shared = shared_routes(selection, predicate)
      reason = sample_reason(sample, selection)

      result =
        %{
          "routes" => Enum.map(selection.routes, &route_row/1),
          "selected_count" => length(selection.stops),
          "served_count" => selection.served_count,
          "already_zoned_count" => selection.already_zoned_count,
          "excluded" =>
            Enum.map(selection.excluded, &%{"stop_id" => &1.stop_id, "stop_name" => &1.stop_name}),
          "unmatched_exclusions" => selection.unmatched_exclusions,
          "sample" => sample,
          "shared_routes" => shared
        }
        |> Map.merge(completeness_fields(reason))

      evidence =
        FareEvidence.build(scope, %{
          kind: "zone_targets",
          title: "Stops to assign",
          total: length(selection.stops),
          total_label: "stops selected",
          completeness: if(reason, do: :incomplete, else: :complete),
          completeness_reason: reason,
          facts: [
            %{
              label: "Stops these routes serve",
              value: Integer.to_string(selection.served_count)
            },
            %{
              label: "Already in a zone",
              value: Integer.to_string(selection.already_zoned_count)
            },
            %{label: "Excluded", value: Integer.to_string(length(selection.excluded))},
            %{
              label: "Also served by other routes",
              value:
                Integer.to_string(
                  Enum.count(selection.stops, &(other_route_ids(&1, predicate) != []))
                )
            }
          ],
          source_ref: @source_ref,
          digest: selection.fingerprint,
          resources:
            Enum.map(
              selection.routes,
              &%{kind: "route", id: &1.route_id, label: &1.route_short_name || &1.route_id}
            )
        })

      {:ok, result, evidence}
    end
  end

  defp prepare_zone_assignment(args, %Scope{} = scope) do
    with {:ok, predicate} <- parse_predicate(args),
         {:ok, zone_id} <- parse_zone_id(args),
         {:ok, selection} <- resolve_selection(scope, predicate),
         :ok <- require_stops(selection),
         {:ok, review} <- preview(scope, selection, zone_id),
         :ok <- require_change(review, zone_id) do
      prepared_assignment(scope, predicate, selection, review, zone_id)
    end
  end

  defp parse_zone_id(%{"zone_id" => zone_id}) when is_binary(zone_id) and zone_id != "",
    do: {:ok, zone_id}

  defp parse_zone_id(_args), do: {:error, "Give the zone_id from list_zones."}

  defp require_stops(%{stops: []}), do: {:error, "No stops match."}
  defp require_stops(_selection), do: :ok

  defp preview(scope, selection, zone_id) do
    stop_ids = Enum.map(selection.stops, & &1.id)

    case FareZones.preview_assignment(
           scope.organization_id,
           scope.gtfs_version_id,
           stop_ids,
           zone_id
         ) do
      {:ok, review} ->
        {:ok, review}

      {:error, :unknown_zone} ->
        {:error, "Zone #{zone_id} is not in this version. Use list_zones."}

      {:error, :invalid_selection} ->
        {:error, "The selection changed. Ask again."}
    end
  end

  defp require_change(%{changed_count: 0}, zone_id),
    do: {:error, "Nothing would change: every selected stop is already in zone #{zone_id}."}

  defp require_change(_review, _zone_id), do: :ok

  # Nothing is written here. The command is the only handoff: the host re-resolves
  # the predicate and the apply recomputes it again under the version lock, so the
  # stop UUIDs this carries are a fixed set to be checked, never trusted.
  defp prepared_assignment(scope, predicate, selection, review, zone_id) do
    zone_name = zone_name(scope, zone_id)
    stop_ids = Enum.map(selection.stops, & &1.id)

    prepared = %{
      command:
        {:zone_assignment,
         %{
           target: zone_id,
           predicate: predicate,
           stop_ids: stop_ids,
           fingerprint: selection.fingerprint
         }},
      summary: %{
        title: "Assign #{Wording.count_noun(length(stop_ids), "stop")} to #{zone_name}",
        detail:
          "Review the stops, shared routes and export effect, then save in the zone review.",
        lines: summary_lines(scope, predicate, selection, review, zone_name)
      }
    }

    result = %{
      "prepared" => true,
      "zone_id" => zone_id,
      "zone_name" => zone_name,
      "selected_count" => length(stop_ids),
      "added_count" => review.added_count,
      "moved_count" => review.moved_count,
      "already_in_zone_count" => review.unchanged_count,
      "excluded" =>
        Enum.map(selection.excluded, &%{"stop_id" => &1.stop_id, "stop_name" => &1.stop_name}),
      "shared_routes" => shared_routes(selection, predicate)
    }

    evidence =
      FareEvidence.build(scope, %{
        kind: "zone_assignment",
        title: "Zone assignment",
        total: length(stop_ids),
        total_label: "stops to assign",
        facts: [
          %{label: "Gain a zone", value: Integer.to_string(review.added_count)},
          %{label: "Move from another zone", value: Integer.to_string(review.moved_count)},
          %{label: "Already in the zone", value: Integer.to_string(review.unchanged_count)}
        ],
        source_ref: @source_ref,
        digest: selection.fingerprint,
        resources:
          Enum.map(
            selection.routes,
            &%{kind: "route", id: &1.route_id, label: &1.route_short_name || &1.route_id}
          )
      })

    {:prepared, prepared, result, evidence}
  end

  defp zone_name(scope, zone_id) do
    scope.organization_id
    |> FareZones.inventory(scope.gtfs_version_id)
    |> Map.fetch!(:zones)
    |> Enum.find_value(zone_id, &(&1.zone_id == zone_id && &1.name))
  end

  defp summary_lines(scope, predicate, selection, review, zone_name) do
    [
      "Routes: " <> Enum.map_join(selection.routes, ", ", &(&1.route_short_name || &1.route_id)),
      if(predicate.only_unzoned?,
        do: "Stops with no zone only",
        else: "Includes stops already in another zone"
      ),
      "#{review.added_count} #{Wording.noun(review.added_count, "gains", "gain")} a zone, #{review.moved_count} #{Wording.noun(review.moved_count, "moves", "move")} from another zone, #{review.unchanged_count} already in #{zone_name}",
      exclusion_line(selection),
      shared_route_line(selection, predicate),
      export_line(scope)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp exclusion_line(%{excluded: []}), do: nil

  defp exclusion_line(%{excluded: excluded}),
    do:
      "Excluded: " <>
        Enum.map_join(excluded, ", ", &"#{&1.stop_name || &1.stop_id} (#{&1.stop_id})")

  defp shared_route_line(selection, predicate) do
    case shared_routes(selection, predicate) do
      [] -> nil
      shared -> "Also served by " <> Enum.map_join(shared, ", ", &shared_route_phrase/1)
    end
  end

  defp shared_route_phrase(%{"route_short_name" => name, "stop_count" => 1}),
    do: "route #{name} (1 stop)"

  defp shared_route_phrase(%{"route_short_name" => name, "stop_count" => count}),
    do: "route #{name} (#{count} stops)"

  defp export_line(scope) do
    if Fares.managed?(scope.organization_id, scope.gtfs_version_id) do
      "This version's areas and stop areas export from these zones."
    else
      "These zones export in the stops.txt zone column; fare rules keep their zone references."
    end
  end

  # The one place a tool turns arguments into a selection predicate. The routes,
  # stops and flag are the model's words; what they mean is decided by
  # `FareZones.route_selection/3`, never here.
  defp parse_predicate(%{
         "route_ids" => route_ids,
         "only_unzoned" => only_unzoned,
         "exclude_stop_ids" => exclude_stop_ids
       })
       when is_list(route_ids) and is_boolean(only_unzoned) and is_list(exclude_stop_ids) do
    if Enum.all?(route_ids ++ exclude_stop_ids, &(is_binary(&1) and &1 != "")) do
      {:ok,
       %{
         route_ids: Enum.uniq(route_ids),
         only_unzoned?: only_unzoned,
         exclude_stop_ids: Enum.uniq(exclude_stop_ids)
       }}
    else
      {:error, "Route IDs and stop IDs must be non-empty strings."}
    end
  end

  defp parse_predicate(_args),
    do: {:error, "Give route_ids, only_unzoned and exclude_stop_ids."}

  defp resolve_selection(%Scope{} = scope, predicate) do
    case FareZones.route_selection(scope.organization_id, scope.gtfs_version_id, predicate) do
      {:ok, selection} -> {:ok, selection}
      {:error, reason} -> {:error, selection_error(reason)}
    end
  end

  defp selection_error(:no_routes), do: "Name at least one route."
  defp selection_error(:too_many_routes), do: "Name at most 5 routes."
  defp selection_error(:too_many_exclusions), do: "Exclude at most 100 stops."

  defp selection_error({:unknown_route, id}),
    do: "Route #{id} is not in this version. Use find_routes."

  defp selection_error({:unknown_stop, id}),
    do: "Stop #{id} is not a boardable stop of this version. Use find_stops."

  defp selection_error({:too_many_stops, _count}),
    do: "These routes serve more than 1,000 stops. Name fewer routes."

  defp route_row(route),
    do: %{"route_id" => route.route_id, "short_name" => route.route_short_name}

  # The serving routes of a stop other than the ones the person named, by name.
  defp other_route_ids(stop, predicate), do: stop.route_ids -- predicate.route_ids

  defp sample_row(stop, selection, predicate) do
    %{
      "stop_id" => stop.stop_id,
      "stop_name" => stop.stop_name,
      "zone_id" => stop.zone_id,
      "other_routes" => stop |> other_route_ids(predicate) |> Enum.map(&selection.route_names[&1])
    }
  end

  defp shared_routes(selection, predicate) do
    selection.stops
    |> Enum.flat_map(&other_route_ids(&1, predicate))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {route_id, count} -> {-count, route_id} end)
    |> Enum.take(@shared_route_limit)
    |> Enum.map(fn {route_id, count} ->
      %{
        "route_id" => route_id,
        "route_short_name" => selection.route_names[route_id],
        "stop_count" => count
      }
    end)
  end

  defp sample_reason(sample, selection) do
    if length(sample) < length(selection.stops),
      do: "Showing #{length(sample)} of #{length(selection.stops)} selected stops."
  end

  # One answer shape for both candidate tools. The title never repeats the model's
  # query, because evidence carries server facts and no model text.
  defp candidates(scope, kind, title, key, label, rows, total, opts \\ []) do
    reason =
      if total > length(rows),
        do: "Showing #{length(rows)} of #{total}. Search again with more of the name."

    result = Map.merge(%{key => rows, "total" => total}, completeness_fields(reason))

    evidence =
      FareEvidence.build(scope, %{
        kind: kind,
        title: title,
        total: total,
        total_label: label,
        completeness: if(reason, do: :incomplete, else: :complete),
        completeness_reason: reason,
        source_ref: @source_ref,
        digest: FareEvidence.digest({kind, 1, rows, total}),
        resources: Keyword.get(opts, :resources, [])
      })

    {:ok, result, evidence}
  end

  defp parse_query(%{"query" => query}) when is_binary(query) do
    case String.trim(query) do
      "" -> {:error, "Give a name or ID to search for."}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_query(_args), do: {:error, "Give a name or ID to search for."}

  defp completeness_fields(nil), do: %{"completeness" => "complete"}

  defp completeness_fields(reason),
    do: %{"completeness" => "incomplete", "reason" => reason}
end
