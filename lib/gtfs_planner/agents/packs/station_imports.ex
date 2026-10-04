defmodule GtfsPlanner.Agents.Packs.StationImports do
  @moduledoc """
  The station import helper pack: one station's computed native change run, the
  accepted field observations behind it, and one **prepared** review selection.

  This pack prepares; it never approves. The organization, service version,
  station, change run and the typed observations all come from the server-built
  `station_imports` source snapshot the host froze into the conversation's own
  context, never from a model argument, so a tool cannot be pointed at another
  station, another run, another upload or an observation the editor never
  accepted (AC-1, AC-13).

  Three tools:

    * `get_station_import_diff` reports the run as it stands, scoped to the
      decisions wholly attributable to this station: status, action, current and
      uploaded values, changed fields, dependencies, the stored and live
      fingerprints and the run's own counts. Cross-station pathways, shared or
      unknown level membership and unresolvable endpoints are counted as excluded,
      never projected.
    * `get_observation_provenance` reports the accepted observations staff already
      captured, converted to metres: their original value and unit, the captured
      date, what the measurement means and whether it is accepted or disputed. The
      entry's body, its photos and its author never leave the server.
    * `prepare_station_import_decisions` prepares a native review selection from
      those accepted observations.

  ## What preparation may select

  Only a pending `:modify` pathway decision whose **complete** changed-field set
  is exactly `min_width`, whose record still matches its stored fingerprint and
  was not hand-edited, whose dependencies are already natively approved or
  applied, and whose uploaded value equals the accepted measurement exactly. A
  width acceptance never carries an accompanying endpoint, direction or any other
  edit with it, a mismatched upload is reported rather than rewritten, and rows
  that already pass are never selected implicitly. With no accepted observations
  the answer is a summary of the run and nothing is prepared.

  The prepared command carries the run, the station, the preparation's own
  `input_digest` and each selected decision's `decision_digest`. It names no
  approval operation: a person confirms and then applies through the native
  review, in two separate deliberate steps (INV-2). Nothing here changes a GTFS
  row, a journal entry, a decision status or any run metadata.

  Every answer returns the server evidence the panel trusts beside the model's
  result, built from the same read as the result it describes.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRunReview
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Gtfs.StationAnswer
  alias GtfsPlanner.Gtfs.StationAssistant

  @source_kind "station_imports"

  # The same bound the projection itself enforces, so the fence and the read
  # cannot disagree about how many decisions one request may name.
  @max_decision_ids 100

  @skill_path Path.expand("../../../../priv/agents/packs/station_imports/SKILL.md", __DIR__)
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
  def id, do: "station_imports"

  @impl true
  def title, do: "Import helper"

  @impl true
  def intro do
    "I can read this station's computed import run and prepare a review of the width measurements staff already accepted. I can't approve, apply or change anything."
  end

  @impl true
  def examples do
    [
      "Which pathways in this import changed width, and what do the accepted measurements say?",
      "Prepare a review of the width decisions the measured 105 cm supports."
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "get_station_import_diff",
        description:
          "Report this station's computed import run as it stands: each decision's status, action, current and uploaded values, changed fields, dependencies and fingerprint state, plus the version, station and excluded counts. It reads; it never approves or applies. Follow next_offset until completeness is complete before claiming you have seen every decision.",
        activity: "Read this station's import decisions",
        parameters: %{
          "type" => "object",
          "properties" => %{"offset" => %{"type" => "integer", "minimum" => 0}},
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_observation_provenance",
        description:
          "Report the width measurements staff already accepted for this station: the original value and unit, the captured date, what the measurement means, and whether it is accepted or disputed, converted to metres. Call this before preparing anything. The source notes, photos and names stay on the server and are never returned.",
        activity: "Read accepted measurement provenance",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_station_import_decisions",
        description:
          "Prepare a native review of the named decisions of this run that the accepted measurements fully support, and report the rest as unresolved with the reason. Only a pending min_width-only pathway change whose uploaded value matches an accepted measurement exactly can be prepared. You are preparing a review for the person to confirm; nothing is approved or applied.",
        activity: "Prepared accepted width decisions for review",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "decision_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string", "maxLength" => 512},
              "minItems" => 1,
              "maxItems" => @max_decision_ids
            }
          },
          "required" => ["decision_ids"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def authorize_context(%Scope{} = scope) do
    with :ok <- Scope.authorized_context(scope),
         {:ok, source} <- station_source(scope),
         :ok <- owned_station(scope, source),
         :ok <- computed_review_run(scope, source) do
      :ok
    else
      _other -> {:error, :unavailable}
    end
  end

  def call("get_station_import_diff", args, %Scope{} = scope) do
    case StationAssistant.import_review(scope, %{offset: Map.get(args, "offset", 0)}) do
      {:ok, result, evidence} -> {:ok, result, evidence}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def call("get_observation_provenance", _args, %Scope{} = scope) do
    # The observations are the server's: the ones the host froze into this
    # conversation's own source snapshot, read back through the public accessor,
    # so no model argument can supply or edit a measurement.
    with {:ok, snapshot} <- frozen_source(scope),
         {:ok, result, evidence} <-
           StationAssistant.normalize_observations(scope, observations(snapshot)) do
      {:ok, result, evidence}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def call("prepare_station_import_decisions", args, %Scope{} = scope) do
    with {:ok, decision_ids} <- decision_ids(Map.get(args, "decision_ids")),
         {:ok, snapshot} <- frozen_source(scope),
         {:ok, result, evidence} <- StationAssistant.prepare_import_selection(scope, decision_ids) do
      prepared(snapshot, result, evidence)
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  @impl true
  def call(_name, _args, _scope),
    do: {:error, "That request is not available for this station's import run."}

  # -- tools ------------------------------------------------------------------

  # A run with no accepted observation prepares nothing: the answer is the run's
  # own summary, so the panel shows counts rather than an empty review the person
  # would have nothing to confirm.
  defp prepared(_snapshot, %{"counts" => %{"selected" => 0}} = result, evidence) do
    {:ok, result, evidence}
  end

  defp prepared(snapshot, result, evidence) do
    command = %{
      kind: :station_import_selection,
      run_id: result["run_id"],
      station_id: payload_station_id(snapshot),
      input_digest: result["input_digest"],
      source_digest: Map.get(snapshot, :digest),
      decisions:
        Enum.map(result["selected"], fn row ->
          %{"decision_id" => row["decision_id"], "decision_digest" => row["decision_digest"]}
        end)
    }

    {:prepared, %{summary: summary(result), command: command}, result, evidence}
  end

  defp summary(result) do
    counts = result["counts"]

    %{
      title: "Accepted width decisions prepared for review",
      detail:
        "#{counts["selected"]} of #{counts["requested"]} requested decisions are prepared for native review.",
      lines:
        Enum.map(result["selected"], fn row ->
          "#{row["decision_id"]}: min_width #{row["current_value"]} -> #{row["uploaded_value"]}"
        end)
    }
  end

  defp decision_ids(ids) when is_list(ids) do
    if length(ids) <= @max_decision_ids and Enum.all?(ids, &decision_id?/1) and
         length(Enum.uniq(ids)) == length(ids) do
      {:ok, ids}
    else
      {:error, :invalid_selection}
    end
  end

  defp decision_ids(_values), do: {:error, :invalid_selection}

  defp decision_id?(id), do: is_binary(id) and id != "" and byte_size(id) <= 512

  # -- scoping ----------------------------------------------------------------

  # The station and the selected change run come from the server-built snapshot.
  # A snapshot of another kind, a malformed identifier or a missing payload is one
  # refusal, exactly as an absent run is.
  defp station_source(%Scope{} = scope) do
    with %{kind: @source_kind, payload: payload} <- Scope.source_snapshot(scope),
         payload when is_map(payload) <- payload,
         station_id when is_binary(station_id) <- payload_key(payload, "station_id"),
         {:ok, station_id} <- Ecto.UUID.cast(station_id),
         station_stop_id when is_binary(station_stop_id) and station_stop_id != "" <-
           payload_key(payload, "station_stop_id"),
         change_run_id when is_binary(change_run_id) <- payload_key(payload, "change_run_id"),
         {:ok, change_run_id} <- Ecto.UUID.cast(change_run_id) do
      {:ok,
       %{
         station_id: station_id,
         station_stop_id: station_stop_id,
         run_id: change_run_id
       }}
    else
      _other -> {:error, :unavailable}
    end
  end

  defp payload_key(payload, key) when is_map_key(payload, key), do: Map.get(payload, key)
  defp payload_key(_payload, _key), do: nil

  defp payload_station_id(%{payload: payload}) when is_map(payload),
    do: payload_key(payload, "station_id")

  # The snapshot in the scope is the server's own envelope, whose digest
  # `Scope.source_snapshot/1` has already re-verified; `Dispatch` has refused the
  # request before this point if it did not.
  defp frozen_source(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{kind: @source_kind} = snapshot -> {:ok, snapshot}
      _other -> {:error, :unavailable}
    end
  end

  defp observations(%{payload: payload}) when is_map(payload) do
    case Map.get(payload, "observations", []) do
      observations when is_list(observations) -> observations
      _other -> []
    end
  end

  defp observations(_snapshot), do: []

  # The station in the snapshot must still be this organization and version's own
  # top-level station row with that GTFS stop id - the same ownership rule every
  # bounded station answer uses.
  defp owned_station(%Scope{} = scope, source) do
    stop =
      Gtfs.get_stop_by_stop_id(
        scope.organization_id,
        scope.gtfs_version_id,
        source.station_stop_id
      )

    if not is_nil(stop) and StationAnswer.owned_station?(%{station: stop}, source) do
      :ok
    else
      {:error, :unavailable}
    end
  end

  # This pack reads a computed review, so a run that is still computing, failed or
  # cancelled holds no decisions to review and is one refusal here rather than a
  # provider request about nothing.
  defp computed_review_run(%Scope{} = scope, source) do
    run = ChangeRuns.get_for_version(scope.organization_id, scope.gtfs_version_id, source.run_id)

    case run do
      %ChangeRun{} = run ->
        if ChangeRunReview.computed_review_run?(run), do: :ok, else: {:error, :unavailable}

      _other ->
        {:error, :unavailable}
    end
  end

  # -- refusals ---------------------------------------------------------------

  defp error_message(:no_computed_review),
    do: "This import has no computed review to read yet. Compute the run first, then ask again."

  defp error_message(:no_selected_run),
    do: "No import run is selected on this page, so there is nothing to read."

  defp error_message(:invalid_selection),
    do:
      "That request cannot be answered as asked. Name at most #{@max_decision_ids} distinct decision ids of this run."

  defp error_message(:forbidden), do: "This import is not available to you."
  defp error_message(_reason), do: "This import is not available."
end
