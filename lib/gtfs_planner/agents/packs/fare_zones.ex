defmodule GtfsPlanner.Agents.Packs.FareZones do
  @moduledoc """
  The Fare zone helper pack: bounded, read-only answers about the fare zones of
  the service version the conversation is bound to.

  Every tool takes its organization and version from the scope, never from an
  argument, so a tool can only read the version the person is looking at (INV-1).
  `list_zones` lists the version's inventory zones with their exact stop and rule
  counts. `find_routes` and `find_stops` return at most 20 candidates by name or
  ID, with the exact total and an incomplete marker, so an ambiguous name produces
  candidates for the person to choose from and never a guess. Each answer returns the server evidence the panel trusts beside the
  model's result. No tool writes anything and none accepts an organization, a
  version, a stop UUID or an "all" flag.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Packs.FareEvidence
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.FareZones

  @source_ref "gtfs_fare_zones"
  @zone_limit 50
  @candidate_limit 20
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
          "List the fare zones of this version with their zone ID, name, stop count and rule count. At most #{@zone_limit} zones are returned with the exact total.",
        activity: "Listed fare zones",
        parameters: %{
          "type" => "object",
          "properties" => %{},
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
      )
    ]
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

  defp run("list_zones", _args, scope), do: list_zones(scope)
  defp run("find_routes", args, scope), do: find_routes(args, scope)
  defp run("find_stops", args, scope), do: find_stops(args, scope)

  # -- tools ------------------------------------------------------------------

  defp list_zones(%Scope{} = scope) do
    inventory = FareZones.inventory(scope.organization_id, scope.gtfs_version_id)
    total = length(inventory.zones)

    rows =
      inventory.zones
      |> Enum.take(@zone_limit)
      |> Enum.map(fn zone ->
        %{
          "zone_id" => zone.zone_id,
          "name" => zone.name,
          "stop_count" => zone.stop_count,
          "rule_count" => zone.rule_count
        }
      end)

    reason = if total > @zone_limit, do: "Showing #{@zone_limit} of #{total} zones."

    result =
      %{"zones" => rows, "total" => total}
      |> Map.merge(completeness_fields(reason))

    evidence =
      FareEvidence.build(scope, %{
        kind: "fare_zones",
        title: "Fare zones",
        total: total,
        total_label: "zones",
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
