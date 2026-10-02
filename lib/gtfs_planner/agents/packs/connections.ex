defmodule GtfsPlanner.Agents.Packs.Connections do
  @moduledoc """
  The Schedule connections helper pack: the read-only helper bound to the route
  whose Schedules page approved a connection set.

  The pack is registered here because `RouteSchedulesLive` offers it beside
  `service_queries` and the panel refuses to mount a selector naming a pack the
  application does not ship. What it owns today is the admission rule: this
  helper reads nothing but the immutable snapshot the Schedules page admitted
  through `GtfsPlanner.Agents.Scope.with_source_snapshot/2`, so a conversation
  without an approved `connections` source is refused before any request, tool
  read, delivered result or prepared lookup (INV-1, INV-2).

  `tools/0` is empty. The comparison tool and its server-owned evidence arrive
  with the connections read step; until then the helper can restate what the
  page approved and states no margin, no available time and no total, because a
  number no tool returned is never said (CR-4).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope

  @source_kind "connections"
  @schema_version 1

  @skill_path Path.expand("../../../../priv/agents/packs/connections/SKILL.md", __DIR__)
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
  def id, do: @source_kind

  @impl true
  def title, do: "Connection helper"

  @impl true
  def intro do
    "I can explain the connections you approved on this page, and the exact date, routes and minimum they carry. I can't change trips, calendars, stops or transfers."
  end

  @impl true
  def examples,
    do: [
      "What did I approve for 26 November?",
      "Which routes and stops are in the connection I selected?"
    ]

  @impl true
  def skill, do: @skill

  @impl true
  def tools, do: []

  # No tool is registered, so a name can only reach here from a client or a
  # stale request; it is refused rather than answered from the source.
  @impl true
  def call(_name, _args, %Scope{}), do: {:error, "This helper has no such tool."}

  @impl true
  def authorize_context(%Scope{} = scope) do
    with {:route, _route_id} <- Scope.identity(scope),
         %{
           kind: @source_kind,
           payload: %{"schema_version" => @schema_version, "pairs" => pairs}
         } <- Scope.source_snapshot(scope),
         true <- is_list(pairs) do
      :ok
    else
      _other -> {:error, :unavailable}
    end
  end
end
