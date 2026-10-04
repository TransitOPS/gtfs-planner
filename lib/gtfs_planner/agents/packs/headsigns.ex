defmodule GtfsPlanner.Agents.Packs.Headsigns do
  @moduledoc """
  The Headsign helper pack: read how a pattern's or timing's trips use their
  headsigns, so an editor can plan a rename.

  Every tool reads the one pattern, and the one timing when the page named one,
  that the Pattern page admitted in its server-held source snapshot of kind
  `headsign_scope`. No tool declares an organization, version, route, pattern or
  timing argument, so the model names values (text, trip IDs) and never the
  target; `authorize_context/1` re-resolves the admitted pattern and timing inside
  the conversation's organization and version before every provider request, tool
  read, delivered result and prepared lookup (AC-1, CR-2).

  Eligibility is the native headsign rule. The pack reads
  `GtfsPlanner.Gtfs.headsign_usage/5` and reports its groups and counts; it never
  compares headsign strings itself (CR-3). Nothing in this module writes (CR-1).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Values

  @snapshot_kind "headsign_scope"
  @source_ref "gtfs_headsign_usage"
  @listed_limit 10

  @stop_level_note "Stop-level headsigns are never changed by a headsign rename."

  @skill_path Path.expand("../../../../priv/agents/packs/headsigns/SKILL.md", __DIR__)
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
  def id, do: "headsigns"

  @impl true
  def title, do: "Headsign helper"

  @impl true
  def intro do
    "I can read how the trips on this pattern use their headsigns and prepare a rename for " <>
      "you to review and save. I cannot save anything myself."
  end

  @impl true
  def examples do
    [
      "Which trips follow this headsign?",
      "Rename this headsign to Downtown Terminal"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "summarize_headsigns",
        description:
          "Summarize the headsigns of the trips on this page's pattern or timing: the " <>
            "effective default and which row owns it, how many trips follow it and how many " <>
            "differ, the timings that carry their own headsign, and the differing exact-text " <>
            "groups. It takes no arguments, so it can only describe the target the page opened.",
        activity: "Summarized the headsigns",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      }
    ]
  end

  @doc """
  The pack's own precondition: the pattern, and timing, the page admitted still
  resolve in this route, organization and version.

  Every other case, including a missing, malformed or oversized snapshot, is the
  single `{:error, :unavailable}`.
  """
  @impl true
  def authorize_context(%Scope{} = scope) do
    case bound(scope) do
      {:ok, _bound} -> :ok
      :error -> {:error, :unavailable}
    end
  end

  @impl true
  def call("summarize_headsigns", _args, %Scope{} = scope), do: summarize_headsigns(scope)

  # -- summarize_headsigns ----------------------------------------------------

  defp summarize_headsigns(scope) do
    with {:ok, bound} <- require_bound(scope),
         {:ok, usage} <- read_usage(scope, bound, []) do
      result = summary_result(bound, usage)
      {:ok, result, summary_evidence(result, scope)}
    end
  end

  defp summary_result(bound, usage) do
    %{
      "scope" => if(bound.timing, do: "timing", else: "pattern"),
      "pattern_name" => bound.pattern.route_pattern_name,
      "timing_name" => bound.timing && bound.timing.name,
      "default" => usage.default,
      "default_owner" => default_owner(bound),
      "total" => usage.total,
      "same" => usage.same,
      "differ" => usage.differ,
      "shielded" => usage.shielded |> Enum.take(@listed_limit) |> Enum.map(&timing_row/1),
      "shielded_total" => length(usage.shielded),
      "timings_carry" =>
        usage.timings_carry |> Enum.take(@listed_limit) |> Enum.map(&timing_row/1),
      "timings_carry_total" => length(usage.timings_carry),
      "groups" => usage.groups |> Enum.take(@listed_limit) |> Enum.map(&group_row/1),
      "groups_total" => length(usage.groups),
      "stop_level_note" => @stop_level_note
    }
  end

  # The timing's own nonblank headsign, else the pattern's, else none: the same
  # order `Headsigns.effective_default/2` applies, reported as the row that owns it.
  defp default_owner(%{timing: timing, pattern: pattern}) do
    cond do
      timing && Headsigns.normalize(timing.headsign) -> "timing"
      Headsigns.normalize(pattern.headsign) -> "pattern"
      true -> "none"
    end
  end

  defp timing_row(row),
    do: %{"timing" => row.name, "headsign" => row.headsign, "trips" => row.trip_count}

  defp group_row(group),
    do: %{
      "value" => group.value,
      "kind" => Atom.to_string(group.kind),
      "trips" => length(group.trips)
    }

  defp summary_evidence(result, scope) do
    cut? = result["groups_total"] > @listed_limit or result["shielded_total"] > @listed_limit

    %{
      kind: "headsign_summary",
      title: result["timing_name"] || result["pattern_name"] || "Pattern headsigns",
      total: result["total"],
      total_label: "trips in scope",
      completeness: if(cut?, do: :incomplete, else: :complete),
      completeness_reason:
        if(cut?, do: "Showing the first #{@listed_limit} groups and timings.", else: nil),
      facts: [
        %{label: "Default headsign", value: result["default"] || "none"},
        %{label: "Default owner", value: result["default_owner"]},
        %{label: "Following the default", value: Integer.to_string(result["same"])},
        %{label: "Differing", value: Integer.to_string(result["differ"])}
      ],
      source_ref: @source_ref,
      digest: digest(result),
      source_revision: nil,
      scope: Pack.evidence_scope(scope),
      exclusions: [],
      resources: []
    }
  end

  defp digest(result) do
    result
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- the host-bound target --------------------------------------------------

  defp require_bound(scope) do
    case bound(scope) do
      {:ok, bound} -> {:ok, bound}
      :error -> {:error, "This helper's pattern is not available."}
    end
  end

  # The admitted snapshot names the pattern and timing; the scope's route identity
  # is resolved first and the pattern is read through it, so a pattern of another
  # route, version or organization is not found. The UUIDs are checked before any
  # query because an invalid string raises in the Ecto cast.
  defp bound(%Scope{} = scope) do
    with %{kind: @snapshot_kind, payload: payload} <- Scope.source_snapshot(scope),
         {:ok, pattern_id, timing_id} <- decode(payload),
         {:route, route_uuid} <- Scope.identity(scope),
         true <- Values.uuid?(route_uuid),
         {:ok, route} <-
           Gtfs.get_route_in_version(scope.organization_id, scope.gtfs_version_id, route_uuid),
         {:ok, native} <-
           Gtfs.get_pattern(
             scope.organization_id,
             scope.gtfs_version_id,
             route.route_id,
             pattern_id,
             timing_id
           ) do
      {:ok,
       %{
         route: route,
         pattern: native.pattern,
         timing: native.selected_timing,
         native: native
       }}
    else
      _other -> :error
    end
  end

  defp decode(%{"schema_version" => 1, "pattern_id" => pattern_id} = payload) do
    timing_id = Map.get(payload, "timing_id")

    if Values.uuid?(pattern_id) and (is_nil(timing_id) or Values.uuid?(timing_id)) do
      {:ok, pattern_id, timing_id}
    else
      :error
    end
  end

  defp decode(_payload), do: :error

  defp read_usage(scope, bound, opts) do
    usage_scope = if bound.timing, do: {:timing, bound.timing.id}, else: :pattern

    case Gtfs.headsign_usage(
           scope.organization_id,
           scope.gtfs_version_id,
           bound.pattern.id,
           usage_scope,
           opts
         ) do
      {:ok, usage} -> {:ok, usage}
      {:error, :not_found} -> {:error, "This helper's pattern is not available."}
    end
  end
end
