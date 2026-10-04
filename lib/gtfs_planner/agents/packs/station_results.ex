defmodule GtfsPlanner.Agents.Packs.StationResults do
  @moduledoc """
  The station result helper pack: bounded, read-only answers about one station's
  recorded reachability check and the station's current report facts.

  Every tool reads the organization, service version, station and selected run from
  the server-built `station_results` source snapshot the host attached to the
  conversation's own context. Identity, SQL and paths never come from an argument,
  so no tool can be pointed at another station, another run or another
  organization (AC-1).

  Three tools, and nothing that changes anything:

    * `get_station_result` reports the **recorded** run: its state, engine,
      engine reference, preferences, counts, diagnostics, recorded provenance
      digest and its data-equality verdict against today's input. It never reroutes
      a pair or recomputes a graph.
    * `list_station_result_pairs` pages the same recorded pairs for a question
      about particular stops rather than the run as a whole.
    * `get_station_report_facts` reports the station's **current** deterministic
      report facts with their own capture time and digest.

  The two sources are never blended. A recorded `no_path` is the router's stored
  verdict between two stops for that run and names no elevator, pathway or outage;
  a current disconnect is a present-tense fact and is never offered as the cause
  of a historical result. A result recorded before provenance existed reads as
  `freshness: unknown`, never as `match`. `data_equality` compares the stored
  execution input with today's input; it does not certify physical accessibility
  and does not evaluate selected-time closures, which this engine never evaluates.

  A source with no selected run - the report page with nothing chosen - still has
  current report facts: `get_station_result` and `list_station_result_pairs`
  report that no check is selected, and the facts remain readable (AC-2).

  Every answer returns the server evidence the panel trusts beside the model's
  result, and the evidence is built from the same read as the result it describes.
  No tool launches a check, prepares a change or writes anything (INV-2).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationAnswer
  alias GtfsPlanner.Gtfs.StationAssistant
  alias GtfsPlanner.Reachability

  @source_kind "station_results"

  @skill_path Path.expand("../../../../priv/agents/packs/station_results/SKILL.md", __DIR__)
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

  @filter_properties %{
    "offset" => %{"type" => "integer", "minimum" => 0},
    "mode" => %{"type" => "string", "maxLength" => 16},
    "outcome" => %{"type" => "string", "maxLength" => 16},
    "pair_index" => %{"type" => "integer", "minimum" => 0}
  }

  @impl true
  def id, do: "station_results"

  @impl true
  def title, do: "Station result helper"

  @impl true
  def intro do
    "I can explain the recorded station check on this page and the station's current report facts. I can't run a check, change pathways or change any data."
  end

  @impl true
  def examples do
    [
      "What did the recorded check say about the platform, and why?",
      "Does the current station report show anything that changed since that check?"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "get_station_result",
        description:
          "Report the recorded station check as it was stored: its state, engine, preferences, totals, diagnostics, recorded input digest and whether that digest still matches today's station input. Call this for \"what did the check say\" and \"is it still current\". It never reruns the check and never recomputes a path. When no check is selected on this page it says so, and get_station_report_facts still works.",
        activity: "Read the recorded station check",
        parameters: %{
          "type" => "object",
          "properties" => @filter_properties,
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_station_report_facts",
        description:
          "Report the station's current data-quality checks and connectivity summaries, as captured now. These are current facts with their own capture time, not an explanation of an earlier recorded check. Call this when the person asks what is true of the station today.",
        activity: "Read the current station report facts",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "list_station_result_pairs",
        description:
          "List the recorded stop-to-stop pairs of the selected check, one bounded page at a time. Use mode, outcome or pair_index to narrow to the pair the person means, and follow next_offset until completeness is complete before claiming you have seen them all.",
        activity: "Listed recorded station check pairs",
        parameters: %{
          "type" => "object",
          "properties" => @filter_properties,
          "required" => [],
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
         :ok <- scoped_run(scope, source) do
      :ok
    else
      _other -> {:error, :unavailable}
    end
  end

  @impl true
  def call("get_station_result", args, %Scope{} = scope),
    do: answer(scope, args, &StationAssistant.result/2)

  def call("list_station_result_pairs", args, %Scope{} = scope),
    do: answer(scope, args, &StationAssistant.result_pairs/2)

  def call("get_station_report_facts", _args, %Scope{} = scope) do
    case StationAssistant.report_facts(scope) do
      {:ok, result, evidence} -> {:ok, result, evidence}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def call(_name, _args, _scope),
    do: {:error, "That request is not available for recorded station checks."}

  # -- tools ------------------------------------------------------------------

  # The only arguments are bounded filters over the already-selected recorded
  # run. The filters themselves are the domain's to validate, so an unknown mode
  # or outcome is refused rather than silently ignored.
  defp answer(%Scope{} = scope, args, read) do
    case read.(scope, filters(args)) do
      {:ok, result, evidence} -> {:ok, result, evidence}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  defp filters(args) do
    %{
      offset: Map.get(args, "offset", 0),
      mode: Map.get(args, "mode"),
      outcome: Map.get(args, "outcome"),
      pair_index: Map.get(args, "pair_index")
    }
  end

  # -- scoping ----------------------------------------------------------------

  # The station and the selected run come from the server-built snapshot. A
  # snapshot of another kind, a malformed identifier or a missing payload is one
  # refusal, exactly as an absent station is.
  defp station_source(%Scope{} = scope) do
    with %{kind: @source_kind, payload: payload} <- Scope.source_snapshot(scope),
         station_id when is_binary(station_id) <- payload_key(payload, "station_id"),
         {:ok, station_id} <- Ecto.UUID.cast(station_id),
         station_stop_id when is_binary(station_stop_id) and station_stop_id != "" <-
           payload_key(payload, "station_stop_id"),
         {:ok, run_id} <- optional_uuid(Map.get(payload, "run_id")) do
      {:ok, %{station_id: station_id, station_stop_id: station_stop_id, run_id: run_id}}
    else
      _other -> {:error, :unavailable}
    end
  end

  defp payload_key(payload, key) when is_map(payload) and is_map_key(payload, key),
    do: Map.get(payload, key)

  defp payload_key(_payload, _key), do: nil

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp optional_uuid(_value), do: {:error, :unavailable}

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

  # The report page may hold no selected run; the result tools then report that,
  # and the current facts stay available. A run that is selected must still
  # resolve inside this organization, version, station and reachability kind.
  defp scoped_run(_scope, %{run_id: nil}), do: :ok

  defp scoped_run(%Scope{} = scope, source) do
    case Reachability.get_station_run(
           scope.organization_id,
           scope.gtfs_version_id,
           source.station_stop_id,
           source.run_id
         ) do
      {:ok, _run} -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  # -- refusals ---------------------------------------------------------------

  defp error_message(:no_selected_run),
    do:
      "No station check is selected on this page, so there is no recorded result to read. The current report facts are still available."

  defp error_message(:invalid_selection),
    do:
      "That request cannot be answered as asked. Use mode walking or wheelchair, a recorded outcome, or a pair index."

  defp error_message(:forbidden), do: "This station is not available to you."
  defp error_message(_reason), do: "This station is not available."
end
