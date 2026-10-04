defmodule GtfsPlanner.Agents.Packs.StopImpact do
  @moduledoc """
  The Stop impact helper pack: say what a stop's references and a stop move would
  affect, from the stops map.

  Every tool reads the one stop, and the one pin when the map has one, that the Stops
  map admitted in its server-held source snapshot of kind `stop_focus`. No tool
  declares a stop, coordinate, organization or version argument, so the model asks
  and the page decides the target; `authorize_context/1` re-resolves the stop inside
  the conversation's organization and version before every provider request, tool
  read, delivered result and prepared lookup (AC-8, CR-2).

  The reads are the native ones: `StopEditing.delete_review/2` for the reference
  inventory, and later `StopEditing.move_impact/3` for a move, neither of which routes,
  locks or writes (CR-5). Nothing in this module applies, deletes or replaces a stop
  (CR-1).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Values

  @snapshot_kind "stop_focus"
  @source_ref "gtfs_stop_references"
  @listed_labels 10

  # What a dependency answer does not check, always stated, never guessed.
  @unchecked [
    "Organization alerts that name this stop's ID are kept, and need repair after a retirement or replacement.",
    "Boarding safety and the street path are not checked.",
    "Accessibility facts at this stop are not checked."
  ]

  @skill_path Path.expand("../../../../priv/agents/packs/stop_impact/SKILL.md", __DIR__)
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
  def id, do: "stop_impact"

  @impl true
  def title, do: "Stop impact helper"

  @impl true
  def intro do
    "I can tell you what refers to the stop you have open and what moving it to the pin " <>
      "would affect. I cannot change, retire or replace a stop."
  end

  @impl true
  def examples do
    [
      "What uses this stop?",
      "What would moving this stop affect?"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "get_stop_dependencies",
        description:
          "List everything that refers to the stop open on this page, grouped by kind, with " <>
            "exact counts and the first few labels of each: the kinds that make a native delete " <>
            "refuse, and the rows a native delete would remove. It takes no arguments, so it " <>
            "can only describe the stop the page opened.",
        activity: "Checked what uses the stop",
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
  The pack's own precondition: the stop, and pin when present, the page admitted still
  resolve in this organization and version.

  Every other case, including a missing, malformed or oversized snapshot, is the single
  `{:error, :unavailable}`.
  """
  @impl true
  def authorize_context(%Scope{} = scope) do
    case bound(scope) do
      {:ok, _bound} -> :ok
      :error -> {:error, :unavailable}
    end
  end

  @impl true
  def call("get_stop_dependencies", _args, %Scope{} = scope), do: get_stop_dependencies(scope)

  # -- get_stop_dependencies --------------------------------------------------

  defp get_stop_dependencies(scope) do
    with {:ok, %{stop: stop}} <- require_bound(scope),
         {:ok, review} <- StopEditing.delete_review(stop.id, Scope.audit_context(scope)) do
      result = dependencies_result(stop, review)
      {:ok, result, dependencies_evidence(stop, result, scope)}
    else
      {:error, :forbidden} ->
        {:error, "Your access to this service version has changed."}

      {:error, reason} when is_atom(reason) ->
        {:error, "This stop's references could not be read."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp dependencies_result(stop, %{blocking: blocking, descriptive: descriptive}) do
    %{
      "stop" => %{
        "stop_id" => stop.stop_id,
        "stop_name" => stop.stop_name,
        "location_type" => stop.location_type
      },
      "blocking" => Enum.map(blocking, &class_row/1),
      "descriptive" => Enum.map(descriptive, &class_row/1),
      "blocking_total" => rows(blocking),
      "descriptive_total" => rows(descriptive),
      "delete_outcome" => delete_outcome(blocking, descriptive),
      "unchecked" => @unchecked
    }
  end

  # `count` is the exact number of rows; the labels are bounded, and only a class that
  # had more labels than it lists is `details_omitted`. A class with no labels by design
  # (stop times, for one) omits nothing.
  defp class_row(item) do
    %{
      "key" => Atom.to_string(item.key),
      "label" => item.label,
      "count" => item.count,
      "details" => item.details |> Enum.take(@listed_labels) |> Enum.map(& &1.label),
      "details_omitted" => max(length(item.details) - @listed_labels, 0)
    }
  end

  defp rows(items), do: items |> Enum.map(& &1.count) |> Enum.sum()

  # A native delete is refused while any blocking class exists, naming those classes;
  # otherwise it removes the descriptive rows, which are named too.
  defp delete_outcome([_ | _] = blocking, _descriptive),
    do: %{"result" => "refused", "labels" => Enum.map(blocking, & &1.label)}

  defp delete_outcome([], descriptive),
    do: %{"result" => "allowed", "labels" => Enum.map(descriptive, & &1.label)}

  defp dependencies_evidence(stop, result, scope) do
    omitted =
      (result["blocking"] ++ result["descriptive"])
      |> Enum.filter(&(&1["details_omitted"] > 0))
      |> Enum.map(& &1["label"])

    %{
      kind: "stop_dependencies",
      title: stop.stop_name || stop.stop_id,
      total: result["blocking_total"] + result["descriptive_total"],
      total_label: "rows that name this stop",
      completeness: if(omitted == [], do: :complete, else: :incomplete),
      completeness_reason:
        if(omitted == [],
          do: nil,
          else: "Labels are cut to #{@listed_labels} per kind for: " <> Enum.join(omitted, ", ")
        ),
      facts: [
        %{label: "Blocking rows", value: Integer.to_string(result["blocking_total"])},
        %{
          label: "Rows a delete would remove",
          value: Integer.to_string(result["descriptive_total"])
        },
        %{label: "Native delete", value: result["delete_outcome"]["result"]}
      ],
      source_ref: @source_ref,
      digest: digest(result),
      source_revision: nil,
      scope: Pack.evidence_scope(scope),
      exclusions: [],
      resources: [%{kind: "stop", id: stop.stop_id, label: stop.stop_name}]
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
      :error -> {:error, "This helper's stop is not available."}
    end
  end

  defp bound(%Scope{} = scope) do
    with %{kind: @snapshot_kind, payload: %{"schema_version" => 1, "stop_uuid" => uuid} = payload} <-
           Scope.source_snapshot(scope),
         true <- Values.uuid?(uuid),
         {:ok, candidate} <- candidate(Map.get(payload, "candidate")),
         %{} = stop <- Gtfs.get_stop_by_id(scope.organization_id, scope.gtfs_version_id, uuid) do
      {:ok, %{stop: stop, candidate: candidate}}
    else
      _other -> :error
    end
  end

  # The pin is optional; when present it is a finite latitude within 90 and longitude
  # within 180. A string, a missing half or a value out of range is no pin at all.
  defp candidate(nil), do: {:ok, nil}

  defp candidate(%{"lat" => lat, "lon" => lon})
       when is_number(lat) and is_number(lon) and lat >= -90 and lat <= 90 and lon >= -180 and
              lon <= 180,
       do: {:ok, {lon * 1.0, lat * 1.0}}

  defp candidate(_other), do: :error
end
