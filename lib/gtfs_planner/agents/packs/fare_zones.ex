defmodule GtfsPlanner.Agents.Packs.FareZones do
  @moduledoc """
  The Fare zone helper pack: bounded, read-only answers about the fare zones of
  the service version the conversation is bound to.

  Every tool takes its organization and version from the scope, never from an
  argument, so a tool can only read the version the person is looking at (INV-1).
  `list_zones` lists the version's inventory zones with their exact stop and rule
  counts. Each answer returns the server evidence the panel trusts beside the
  model's result. No tool writes anything and none accepts an organization, a
  version, a stop UUID or an "all" flag.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Packs.FareEvidence
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.FareZones

  @source_ref "gtfs_fare_zones"
  @zone_limit 50
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
      }
    ]
  end

  @impl true
  def call(name, args, %Scope{} = scope) do
    case Scope.identity(scope) do
      {:version, version_id} when version_id == scope.gtfs_version_id -> run(name, args, scope)
      _other -> {:error, @unavailable}
    end
  end

  defp run("list_zones", _args, scope), do: list_zones(scope)

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

  defp completeness_fields(nil), do: %{"completeness" => "complete"}

  defp completeness_fields(reason),
    do: %{"completeness" => "incomplete", "reason" => reason}
end
