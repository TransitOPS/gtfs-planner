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
  alias GtfsPlanner.Gtfs.StopPlacement
  alias GtfsPlanner.Values

  @snapshot_kind "stop_focus"
  @source_ref "gtfs_stop_references"
  @listed_labels 10
  @no_pin "No pin is placed. Move the pin on the map, then ask again."

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
      },
      %{
        name: "preview_stop_move",
        description:
          "Say what moving the stop open on this page to the pin placed on the map would " <>
            "affect: the distance and the native band, the weekday trips and patterns using " <>
            "the stop, each transfer's walking distance before and after, relief points and " <>
            "every other kind of row that names the stop. It takes no arguments: the stop and " <>
            "the pin are the page's, and it makes no routing request and prepares nothing.",
        activity: "Previewed what moving the stop affects",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_stop_move",
        description:
          "Prepare a pointer to the native move review for the stop open on this page at the " <>
            "pin placed on the map, keeping the stop's ID. Use it only when the person " <>
            "explicitly asks to keep the stop and prepare the move; a question about what a " <>
            "move affects is never such a request. It takes no arguments and saves nothing: " <>
            "the editor reviews and applies the move on the map.",
        activity: "Prepared the move for review",
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
  def call("preview_stop_move", _args, %Scope{} = scope), do: preview_stop_move(scope)
  def call("prepare_stop_move", _args, %Scope{} = scope), do: prepare_stop_move(scope)

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
      "details" => item.details |> first_listed(& &1.label) |> Enum.map(& &1.label),
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

  # -- preview_stop_move ------------------------------------------------------

  # Answers from `StopEditing.move_impact/3` at the pin the host admitted: no routing
  # request, no lock and no write. The pin is never an argument (CR-2).
  defp preview_stop_move(scope) do
    with {:ok, %{stop: stop, candidate: candidate}} <- require_bound(scope),
         {:ok, point} <- require_pin(candidate),
         {:ok, impact} <- StopEditing.move_impact(stop.id, point, Scope.audit_context(scope)) do
      result = move_result(stop, impact)
      {:ok, result, move_evidence(stop, impact, result, scope)}
    else
      {:error, :forbidden} -> {:error, "Your access to this service version has changed."}
      {:error, reason} when is_atom(reason) -> {:error, "This stop's move could not be read."}
      {:error, message} -> {:error, message}
    end
  end

  defp require_pin(nil), do: {:error, @no_pin}
  defp require_pin(point), do: {:ok, point}

  defp move_result(stop, impact) do
    %{
      "stop" => %{
        "stop_id" => stop.stop_id,
        "stop_name" => stop.stop_name,
        "location_type" => stop.location_type
      },
      "distance_m" => Float.round(impact.distance_m, 1),
      "band" => Atom.to_string(impact.band),
      "band_note" => band_note(impact.band),
      "served" => impact.served?,
      "weekday_trips" => impact.weekday_trips,
      "patterns" =>
        impact.patterns
        |> Enum.take(@listed_labels)
        |> Enum.map(&%{"label" => &1.label, "weekday_trips" => &1.weekday_trips}),
      "patterns_omitted" => omitted(impact.patterns),
      "transfers" => impact.transfers |> first_listed(& &1.label) |> Enum.map(&transfer_row/1),
      "transfers_omitted" => omitted(impact.transfers),
      "relief_points" => first_listed(impact.relief_points, & &1),
      "relief_points_omitted" => omitted(impact.relief_points),
      "references" =>
        Enum.map(impact.references, fn reference ->
          %{
            "key" => Atom.to_string(reference.key),
            "label" => reference.label,
            "kind" => Atom.to_string(reference.kind),
            "count" => reference.count
          }
        end),
      "unchecked" => Enum.map(impact.unmodeled, &unmodeled_sentence/1)
    }
  end

  defp omitted(rows), do: max(length(rows) - @listed_labels, 0)

  # The reads return rows in no stated order, so the cut is made over a sorted list:
  # two reads of the same stop list the same labels and carry the same digest.
  defp first_listed(rows, key), do: rows |> Enum.sort_by(key) |> Enum.take(@listed_labels)

  defp transfer_row(transfer) do
    %{
      "label" => transfer.label,
      "before_m" => round_metres(transfer.before_m),
      "after_m" => round_metres(transfer.after_m),
      "min_transfer_time" => transfer.min_transfer_time
    }
  end

  defp round_metres(nil), do: nil
  defp round_metres(metres), do: Float.round(metres, 1)

  defp band_note(:correction), do: "A correction: the editor can save it without a move review."
  defp band_note(:review), do: "The native move review is required before this move is saved."

  defp band_note(:far),
    do: "The native move review asks whether this is the same stop before it is saved."

  defp unmodeled_sentence(:street_path),
    do: "The street path is decided by the native move review, not here."

  defp unmodeled_sentence(:pattern_lines),
    do: "Which pattern lines would be redrawn is decided by the native move review."

  defp unmodeled_sentence(:boarding_safety),
    do: "Boarding safety at the new position is not checked."

  defp unmodeled_sentence(:accessibility),
    do: "Accessibility at the new position is not checked."

  defp unmodeled_sentence(:alerts),
    do: "Organization alerts that name this stop's ID are not checked."

  defp move_evidence(stop, impact, result, scope) do
    cut =
      for {name, key} <- [
            {"patterns", "patterns_omitted"},
            {"transfers", "transfers_omitted"},
            {"relief points", "relief_points_omitted"}
          ],
          result[key] > 0,
          do: name

    %{
      kind: "stop_move_impact",
      title: stop.stop_name || stop.stop_id,
      total: impact.references |> Enum.map(& &1.count) |> Enum.sum(),
      total_label: "rows that name this stop",
      completeness: if(cut == [], do: :complete, else: :incomplete),
      completeness_reason:
        if(cut == [],
          do: nil,
          else: "Lists are cut to #{@listed_labels} for: " <> Enum.join(cut, ", ")
        ),
      facts: [
        %{label: "Distance", value: "#{result["distance_m"]} m"},
        %{label: "Band", value: result["band"]},
        %{label: "Weekday trips", value: Integer.to_string(result["weekday_trips"])}
      ],
      source_ref: "gtfs_stop_move_impact",
      digest: digest(result),
      source_revision: nil,
      scope: Pack.evidence_scope(scope),
      exclusions: [],
      resources: [%{kind: "stop", id: stop.stop_id, label: stop.stop_name}]
    }
  end

  # -- prepare_stop_move ------------------------------------------------------

  # The prepared command is only a pointer: the host re-checks the stop and pin and
  # opens the native move review, which keeps its own routing request and band
  # choices. Coordinates are 6-decimal strings so the host can rebuild the identical
  # term. No tool here applies, deletes or replaces anything (CR-1, CR-4).
  defp prepare_stop_move(scope) do
    with {:ok, %{stop: stop, candidate: candidate}} <- require_bound(scope),
         {:ok, {lon, lat}} <- require_pin(candidate),
         :ok <- require_move(stop, {lon, lat}) do
      command =
        {:stop_move,
         %{
           stop_uuid: stop.id,
           lat: coordinate_text(lat),
           lon: coordinate_text(lon)
         }}

      {:prepared, move_summary(stop, command), move_prepared_result(stop, command),
       move_prepared_evidence(stop, command, scope)}
    end
  end

  @doc """
  A coordinate as the 6-decimal string a prepared move carries.

  The Stops map formats its own draft point with this function to compare it with the
  prepared command, so the pack and its host agree on one spelling.
  """
  @spec coordinate_text(float()) :: String.t()
  def coordinate_text(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 6)

  # A pin on top of the saved position is not a move; a stop with no saved position
  # has nothing to compare and is movable.
  defp require_move(stop, point) do
    with lon when not is_nil(lon) <- float(stop.stop_lon),
         lat when not is_nil(lat) <- float(stop.stop_lat),
         false <- StopPlacement.moved?(StopPlacement.distance({lon, lat}, point)) do
      {:error, "The pin is on the stop's saved position, so there is no move to prepare."}
    else
      _movable -> :ok
    end
  end

  defp float(%Decimal{} = value), do: Decimal.to_float(value)
  defp float(value) when is_number(value), do: value * 1.0
  defp float(_value), do: nil

  defp move_summary(stop, command) do
    %{
      command: command,
      summary: %{
        title: "Move #{stop.stop_id} to the selected point",
        detail: "Same stop ID, new position",
        lines: [
          "Nothing is saved",
          "The native move review checks the street path and asks for your choices",
          "Retirement and replacement stay native actions"
        ]
      }
    }
  end

  defp move_prepared_result(stop, {:stop_move, %{lat: lat, lon: lon}}) do
    %{
      "prepared" => true,
      "stop_id" => stop.stop_id,
      "lat" => lat,
      "lon" => lon,
      "note" =>
        "Prepared a pointer to the native move review only. Nothing is saved until the " <>
          "editor reviews and applies the move on the map."
    }
  end

  defp move_prepared_evidence(stop, {:stop_move, %{lat: lat, lon: lon}}, scope) do
    %{
      kind: "stop_move_prepared",
      title: "Move #{stop.stop_id}",
      total: 1,
      total_label: "stop move to review",
      completeness: :complete,
      completeness_reason: nil,
      facts: [
        %{label: "New position", value: "#{lat}, #{lon}"},
        %{label: "Prepared", value: "A pointer to the native move review; nothing is saved"}
      ],
      source_ref: "gtfs_stop_move_prepared",
      digest: digest(%{stop_uuid: stop.id, lat: lat, lon: lon}),
      source_revision: nil,
      scope: Pack.evidence_scope(scope),
      exclusions: [],
      resources: [%{kind: "stop", id: stop.stop_id, label: stop.stop_name}]
    }
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
