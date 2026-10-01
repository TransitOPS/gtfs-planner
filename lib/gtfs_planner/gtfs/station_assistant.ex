defmodule GtfsPlanner.Gtfs.StationAssistant do
  @moduledoc """
  Bounded, provider-safe projections of one station's recorded reachability
  result and its current report facts.

  Two reads, two sources, never one blended answer (INV-3, CL-2):

    * `result/2` and `result_pairs/2` describe a **recorded** run. They return
      what was stored - engine, engine reference, preferences, pair indices and
      ids, counts, recorded reasons and the recorded provenance digest - and they
      never reroute a pair or recompute a graph. A `no_path` reason is the
      router's recorded verdict between two stops; it names no elevator, pathway
      or outage, and this projection adds no cause to it. A run recorded before
      provenance existed reads as `freshness: unknown`, never as `match`.

    * `report_facts/1` describes the **current** station. It is derived only from
      the existing deterministic builders (`DataQuality.build/1` and
      `Connectivity.build_summaries/1`) over one repeatable-read snapshot, and it
      carries its own capture time and its own digest. Current facts are a
      present-tense description of the station; they are never presented as the
      cause of a historical result.

  Equality between the two is reported only when the recorded result carries a
  provenance digest, and only over the same canonical input fields
  (`Envelope.input_provenance/1`). That equality means the stored input still
  matches today's input. It does not certify physical accessibility and it does
  not evaluate selected-time closures, which this engine never evaluates (CR-5).

  ## Scoping

  Identity comes from `Scope.source_snapshot/1`, never from a tool argument, and
  the snapshot's station is re-resolved inside this organization and version: its
  database UUID, its top-level `location_type` 1 and its `stop_id` must all be the
  ones the host resolved. The recorded run is then read through
  `Reachability.get_station_run/4`, which scopes by organization, version, station
  and reachability kind. Membership is re-authorized here as well as in the pack,
  so a revoked editor reads nothing.

  ## Bounds

  A projection reports exact totals for what was recorded, what the filter
  matched, what it excluded and how many rows this answer returns, and whether
  the answer is complete. A page holds at most #{100} pairs, and the encoded
  result plus evidence stays inside the existing 32 KiB tool limit: an oversized
  prefix is shortened to the rows that fit, and a single row that cannot fit
  returns zero rows with narrowing guidance rather than a truncated row that looks
  whole.

    * `import_review/2` describes one **computed native import run**, read
      without changing anything: the run's own state, serializer version, base
      source files, and the decisions that are wholly attributable to the
      selected station. Membership is decided from the current and uploaded
      parent chain, endpoints and level references, never from a matching
      natural key, and every excluded decision is counted rather than projected
      (CL-1, CL-3, INV-2). Reading an import run approves nothing.

  ## Accepted observations and prepared selection

  `normalize_observations/2` validates and converts the measurements staff have
  already accepted, and `prepare_import_selection/2` matches them against a
  fresh read of the same run. Neither writes anything: no GTFS row, no journal
  entry, no decision status and no run metadata changes (INV-2, AC-8). Preparing
  a selection is not approving it - only the native confirmation in
  `ChangeRuns` may do that.

  An observation carries its own provenance: an explicit source reference, the
  original value and unit, the captured date, the meaning of the measurement and
  whether staff accepted it or recorded a conflict. Only `min_width` measured as
  `minimum_clear_width` in `m`, `cm` or `mm` converts, through exact `Decimal`
  multiplication, so 105 cm is 1.05 m rather than a rounded approximation. A
  journal-backed source reference is resolved through `StationJournal`'s own
  scope and frozen as a revision and a digest of identity metadata; the entry's
  body, its photos and its author never leave the server (AC-13).

  Selection is deliberately narrow. A decision is a candidate only when it is a
  pending `:modify` pathway whose **complete** changed-field set is exactly
  `min_width`, whose record still matches its stored fingerprint, whose
  dependencies are already natively approved or applied, and whose uploaded
  value equals the accepted measurement exactly. A width acceptance never carries
  an accompanying endpoint, direction or any other edit into a selection, and a
  mismatched upload stays mismatched: the answer names it unresolved instead of
  rewriting the file. A disputed or unaccepted observation is reported, never
  applied.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.ServiceQueries
  alias GtfsPlanner.Gtfs.StationJournal
  alias GtfsPlanner.Gtfs.StationReport2.Connectivity
  alias GtfsPlanner.Gtfs.StationReport2.DataQuality
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Reachability.Envelope
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  import Ecto.Query

  @source_kind "station_results"
  @import_source_kind "station_imports"
  @source_ref "gtfs_station_assistant"

  @max_rows 100
  @max_encoded_bytes 32 * 1024
  @recorded_schema_version 1

  @modes ["walking", "wheelchair"]
  @outcomes ["reachable", "unreachable", "invalid"]

  @narrowing_guidance "This answer is too large for one response. Narrow it by mode, outcome or a single pair index."
  @import_narrowing_guidance "This answer is too large for one response. Ask for a narrower page of the run."

  # One measurement may change exactly one field of one pathway, and only this
  # width slice converts. Everything else a staff member accepted stays a native
  # review edit rather than becoming a prepared selection.
  @observation_field "min_width"
  @observation_meaning "minimum_clear_width"
  @observation_keys ~w(source_ref source_revision target field original_value unit captured_date meaning accepted conflict)
  @observation_units %{
    "m" => Decimal.new(1),
    "cm" => Decimal.new("0.01"),
    "mm" => Decimal.new("0.001")
  }
  @max_source_ref_bytes 512
  @max_source_revision_bytes 128
  @max_pathway_id_bytes 255
  @max_original_value_bytes 64

  # A computed review and everything that follows it: the run holds decisions a
  # station may read. A pending compute, a computing run, a failure, a
  # cancellation or an expiry holds none.
  @computed_review_states [:review, :pending_apply, :applying, :partial, :completed]
  @approved_statuses [:approved, :applied]

  @typedoc "One station/run selection read from the scope's source snapshot."
  @type selection :: %{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_id: Ecto.UUID.t(),
          station_stop_id: String.t(),
          run_id: Ecto.UUID.t() | nil,
          actor_id: Ecto.UUID.t() | nil,
          source_snapshot: map()
        }

  @typedoc "Bounded pair filters accepted by `result/2` and `result_pairs/2`."
  @type filters :: %{
          optional(:offset) => non_neg_integer(),
          optional(:mode) => String.t() | nil,
          optional(:outcome) => String.t() | nil,
          optional(:pair_index) => non_neg_integer() | nil
        }

  @typedoc "Why a read refused, before any recorded row was disclosed."
  @type error ::
          :forbidden | :unavailable | :no_selected_run | :no_computed_review | :invalid_selection

  @typedoc """
  One validated, converted measurement, as the string-key row it is.

  `normalized_value` is the measurement in metres. `source_revision` and
  `source_digest` are set only for a journal-backed reference, whose entry's
  identity metadata is frozen; the entry's body and photos are never part of it.
  """
  @type observation :: map()

  @doc """
  Projects the recorded result of the scope's selected run.

  `filters` accepts `offset` (a zero-based page start), `mode`
  (`"walking"`/`"wheelchair"`), `outcome` (a recorded pair outcome) and a stable
  `pair_index`. An unknown filter value is `{:error, :invalid_selection}` rather
  than a silently ignored filter.

  A source without a selected run answers `{:error, :no_selected_run}`; the
  report facts in `report_facts/1` stay available for it.
  """
  @spec result(Scope.t(), filters()) :: {:ok, map(), map()} | {:error, error()}
  def result(scope, filters \\ %{})

  def result(%Scope{} = scope, filters) when is_map(filters) do
    with {:ok, page} <- filters(filters),
         {:ok, selection} <- selection(scope, :require_run),
         {:ok, snapshot} <- current_snapshot(selection),
         {:ok, run} <- selected_run(selection) do
      recorded = recorded_facts(run, snapshot)
      matched = matched_pairs(recorded_pairs(run), page)
      base = base_result(selection, run, recorded)

      result =
        base
        |> Map.put("filters", json_filters(page))
        |> put_page(matched, page)

      bounded(result, selection, recorded, matched, page, "recorded_result")
    end
  end

  def result(_scope, _filters), do: {:error, :invalid_selection}

  @doc """
  Projects one bounded page of the recorded result's pairs.

  Same identity, same recorded source and same bounds as `result/2`; only the
  pair rows are returned, for a question about specific pairs rather than the run
  as a whole.
  """
  @spec result_pairs(Scope.t(), filters()) :: {:ok, map(), map()} | {:error, error()}
  def result_pairs(%Scope{} = scope, filters) when is_map(filters) do
    with {:ok, page} <- filters(filters),
         {:ok, selection} <- selection(scope, :require_run),
         {:ok, snapshot} <- current_snapshot(selection),
         {:ok, run} <- selected_run(selection) do
      recorded = recorded_facts(run, snapshot)
      matched = matched_pairs(recorded_pairs(run), page)

      result =
        %{
          "station_stop_id" => selection.station_stop_id,
          "run_id" => run.id,
          "state" => recorded.state,
          "engine" => recorded.engine,
          "result_schema_version" => recorded.schema_version,
          "recorded_provenance" => recorded.provenance,
          "data_equality" => recorded.equality,
          "filters" => json_filters(page),
          "notes" => recorded.notes
        }
        |> put_page(matched, page)

      bounded(result, selection, recorded, matched, page, "recorded_result_pairs")
    end
  end

  def result_pairs(_scope, _filters), do: {:error, :invalid_selection}

  @doc """
  Projects the station's current report facts.

  Reads one repeatable-read snapshot of the current station and derives its facts
  only from the existing deterministic report builders. The answer carries its
  own capture time and digest, independent of any recorded result's provenance: a
  current disconnect is a present-tense fact, never the asserted cause of a
  historical one.
  """
  @spec report_facts(Scope.t()) :: {:ok, map(), map()} | {:error, error()}
  def report_facts(%Scope{} = scope) do
    with {:ok, selection} <- selection(scope, :optional_run),
         {:ok, snapshot} <- current_snapshot(selection) do
      quality = Enum.map(DataQuality.build(snapshot), &quality_projection/1)
      connectivity = connectivity_projection(snapshot)

      facts = %{
        "station_stop_id" => selection.station_stop_id,
        "capture_time" => capture_time(),
        "data_quality" => quality,
        "connectivity" => connectivity,
        "counts" => %{
          "checks" => length(quality),
          "failing_checks" => Enum.count(quality, &(&1["status"] == "fail")),
          "warning_checks" => Enum.count(quality, &(&1["status"] == "warn")),
          "dimensions" => length(connectivity)
        }
      }

      digest = digest(facts)
      result = Map.put(facts, "digest", digest)

      evidence = %{
        kind: "station_report_facts",
        title: "Current station report facts",
        total: length(quality),
        total_label: "current data quality checks",
        completeness: :complete,
        source_ref: @source_ref,
        digest: digest,
        source_revision: nil,
        scope: scope_field(selection),
        exclusions: [],
        resources: station_resources(selection),
        facts: [
          %{label: "Captured at", value: facts["capture_time"]},
          %{
            label: "Checks failing",
            value: "#{facts["counts"]["failing_checks"]} of #{length(quality)}"
          },
          %{
            label: "Separate source",
            value: "current facts, not an explanation of an earlier recorded result"
          }
        ]
      }

      {:ok, result, evidence}
    end
  end

  @doc """
  Projects one computed native import run as it stands, scoped to one station.

  `filters` accepts only a zero-based `offset`. The answer is a read: it never
  approves, rejects, prepares or applies a decision, and it never changes the
  run, its manifest or its statuses (INV-2).

  Only decisions wholly attributable to the selected station are projected. The
  counts - `version_total`, `station_total`, `excluded_total` and
  `existing_approved` - describe the rest of the version-wide run, which stays
  visible in the native review and is never pulled into this answer.
  """
  @spec import_review(Scope.t(), %{optional(:offset) => non_neg_integer()}) ::
          {:ok, map(), map()} | {:error, error()}
  def import_review(scope, filters \\ %{})

  def import_review(%Scope{} = scope, filters) when is_map(filters) do
    with {:ok, offset} <- page_offset(filters),
         {:ok, selection} <- import_selection(scope),
         {:ok, snapshot} <- import_snapshot(selection) do
      import_answer(snapshot, offset)
    end
  end

  def import_review(_scope, _filters), do: {:error, :invalid_selection}

  @doc """
  Validates and converts accepted field observations without persisting them.

  `observations` is the server's own list of string-key rows - the typed
  observations the host froze into the scope's `station_imports` source
  snapshot, never a model's. Every row states its source reference, the original
  value and unit, the captured date, what the measurement means, and whether
  staff accepted it or recorded a conflict against it.

  Only `min_width` measured as `minimum_clear_width` converts, through exact
  `Decimal` multiplication by 1, 0.01 or 0.001, so 105 cm is exactly 1.05 m. A
  missing meaning, an unsupported unit, a nonpositive or unparseable value, a
  malformed row, a foreign journal reference, or two accepted rows that disagree
  about the same target fails **that row only**; the other measurements are still
  reported.

  A `source_ref` that is a UUID is resolved through `StationJournal`'s own
  station scope and frozen as the entry's revision and a digest of its identity
  metadata. The entry's body, its photos and its author stay on the server
  (AC-13), and a later edit to that same entry is a new observation rather than a
  silent rewrite of this one, so the row is reported as changed instead.

  The answer is a read: nothing is written, and this function approves nothing
  (INV-2).
  """
  @spec normalize_observations(Scope.t(), [map()]) :: {:ok, map(), map()} | {:error, error()}
  def normalize_observations(%Scope{} = scope, observations) when is_list(observations) do
    with :ok <- observation_batch(observations),
         {:ok, selection} <- import_selection(scope),
         {:ok, run} <- scoped_run(selection) do
      normalized = normalize_rows(selection, observations)

      {:ok, normalized, observation_evidence(selection, run, normalized)}
    end
  end

  def normalize_observations(_scope, _observations), do: {:error, :invalid_selection}

  @doc """
  The digest a host records beside the observations it freezes.

  A host that stores `observations_digest` in its `station_imports` source
  snapshot gets that value from here, and `prepare_import_selection/2` refuses
  observations whose digest no longer matches the snapshot it reads. A snapshot
  without the key is still bound by `Scope`'s own envelope digest, so the check
  tightens the frozen evidence rather than replacing it.
  """
  @spec observations_digest([map()]) :: String.t()
  def observations_digest(observations) when is_list(observations), do: digest(observations)

  @doc """
  Prepares a native review selection from accepted observations, writing nothing.

  `decision_ids` names at most #{@max_rows} distinct decisions of the scope's
  selected station. The accepted observations come from the scope's **frozen**
  source snapshot, never from the caller, and they are matched against a fresh
  read of the same computed import run: an observation captured against a run
  that has since changed describes a different run.

  A decision is selected only when all of these hold:

    * it is a pending `:modify` **pathway** whose complete changed-field set is
      exactly `min_width`, so no endpoint, direction or other edit rides along;
    * its record still matches the stored fingerprint and nobody hand-edited it;
    * every decision it depends on is already natively approved or applied, and a
      dependency that is still pending leaves the whole decision unresolved;
    * an accepted, unconflicted observation targets the same pathway and its
      converted value equals the uploaded value exactly.

  Everything else is reported, never repaired: a disputed observation, a mixed
  edit, a tainted or drifted record, a mismatched upload and a decision outside
  this station all appear in `unresolved` or `excluded` with the reason, and the
  uploaded file is left exactly as it was. Already approved rows are listed
  separately under `existing_approved` and are never implicitly selected.

  `input_digest` binds the frozen source snapshot, the fresh import digest, the
  observations and every requested decision's outcome, so a later confirmation
  can recompute it and refuse a stale selection. The returned `command` carries
  no approval operation of any kind: preparing a selection and approving it stay
  separate native steps (INV-2).
  """
  @spec prepare_import_selection(Scope.t(), [String.t()]) ::
          {:ok, map(), map()} | {:error, error()}
  def prepare_import_selection(%Scope{} = scope, decision_ids) when is_list(decision_ids) do
    with {:ok, ids} <- selection_ids(decision_ids),
         {:ok, selection} <- import_selection(scope),
         {:ok, snapshot} <- import_snapshot(selection) do
      prepare_answer(snapshot, ids)
    end
  end

  def prepare_import_selection(_scope, _decision_ids), do: {:error, :invalid_selection}

  ## Scoping and authorization

  defp selection(%Scope{} = scope, run_requirement) do
    selection_source(scope, @source_kind, "run_id", run_requirement)
  end

  defp selection_source(%Scope{} = scope, kind, run_key, run_requirement) do
    with :ok <- Scope.authorized_context(scope),
         snapshot = %{kind: ^kind, payload: payload} <- Scope.source_snapshot(scope),
         {:ok, station_id} <- Ecto.UUID.cast(Map.get(payload, "station_id")),
         {:ok, gtfs_version_id} <- Ecto.UUID.cast(scope.gtfs_version_id),
         {:ok, organization_id} <- Ecto.UUID.cast(scope.organization_id),
         station_stop_id when is_binary(station_stop_id) and station_stop_id != "" <-
           Map.get(payload, "station_stop_id"),
         {:ok, run_id} <- run_id(Map.get(payload, run_key), run_requirement) do
      {:ok,
       %{
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id,
         station_id: station_id,
         station_stop_id: station_stop_id,
         run_id: run_id,
         actor_id: scope.user_id,
         source_snapshot: snapshot
       }}
    else
      {:error, reason} when reason in [:forbidden, :unavailable, :no_selected_run] ->
        {:error, reason}

      _other ->
        {:error, :unavailable}
    end
  end

  defp run_id(nil, :require_run), do: {:error, :no_selected_run}
  defp run_id(nil, :optional_run), do: {:ok, nil}
  defp run_id(value, _requirement) when is_binary(value), do: Ecto.UUID.cast(value)
  defp run_id(_value, _requirement), do: {:error, :unavailable}

  # One read-only repeatable-read snapshot per answer, following the existing
  # `ServiceQueries` boundary: a controlled writer between two of this module's
  # reads is invisible to every part of the answer.
  defp current_snapshot(selection) do
    Repo.transaction(
      fn ->
        snapshot_module().begin_read()

        with {:ok, snapshot} <-
               Gtfs.get_station_report_snapshot(
                 selection.organization_id,
                 selection.gtfs_version_id,
                 selection.station_stop_id
               ),
             true <- owned_station?(snapshot, selection) do
          {:ok, snapshot}
        else
          _other -> {:error, :unavailable}
        end
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_module do
    Application.get_env(
      :gtfs_planner,
      :gtfs_service_query_snapshot,
      ServiceQueries.Snapshot.Repo
    )
  end

  # The snapshot's station must be the one the host resolved: the same database
  # row, a top-level station row, and the same GTFS stop id.
  defp owned_station?(%{station: station}, selection) do
    station.id == selection.station_id and station.location_type == 1 and
      station.stop_id == selection.station_stop_id
  end

  defp owned_station?(_snapshot, _selection), do: false

  ## The recorded run

  defp selected_run(selection) do
    Reachability.get_station_run(
      selection.organization_id,
      selection.gtfs_version_id,
      selection.station_stop_id,
      selection.run_id
    )
  end

  # The snapshot read above already proved this organization and version still
  # hold the selected station; the run is then read through the scoped accessor,
  # which resolves the station and the reachability kind in the same statement.
  defp recorded_facts(%ValidationRun{} = run, snapshot) do
    state = run_state(run)

    base = %{
      state: state,
      run_id: run.id,
      engine: run.engine,
      schema_version: run.result_schema_version,
      provenance: unknown_provenance(),
      equality: "unknown",
      notes: state_notes(state)
    }

    if state == "recorded" do
      Map.merge(base, recorded_result_facts(run, snapshot))
    else
      base
    end
  end

  defp recorded_result_facts(run, snapshot) do
    envelope = run.result_json || %{}
    provenance = envelope["input_provenance"]

    %{
      provenance: projection_provenance(provenance),
      equality: data_equality(provenance, snapshot),
      engine: envelope["engine"],
      schema_version: envelope["result_schema_version"],
      notes: [
        "A recorded no_path is the router's verdict between two stops for that run; it names no specific cause.",
        "Recorded provenance equality compares the stored execution input with today's input; it is not an accessibility certification and does not evaluate selected-time closures."
      ]
    }
  end

  defp run_state(%ValidationRun{status: status}) when status in ["pending", "started", "running"],
    do: "pending"

  defp run_state(%ValidationRun{status: "failed"}), do: "failed"

  # No writer cancels a reachability run today; the projection still keeps a
  # cancelled run distinct from a failed one, because they are different facts.
  defp run_state(%ValidationRun{status: status}) when status in ["cancelled", "canceled"],
    do: "cancelled"

  defp run_state(%ValidationRun{status: "completed", engine: nil}), do: "legacy"

  defp run_state(%ValidationRun{status: "completed", result_schema_version: version})
       when version != @recorded_schema_version,
       do: "unsupported_schema"

  defp run_state(%ValidationRun{status: "completed", result_json: %{"pairs" => pairs}})
       when is_list(pairs),
       do: "recorded"

  defp run_state(%ValidationRun{}), do: "unsupported_state"

  defp state_notes("pending"),
    do: ["This check has not finished, so there are no recorded pairs to report."]

  defp state_notes("failed"),
    do: [
      "This check failed. No pairs were recorded, so no reachability claim can be made from it."
    ]

  defp state_notes("cancelled"),
    do: ["This check was cancelled before it finished. No pairs were recorded."]

  defp state_notes("legacy"),
    do: [
      "This result predates the recorded schema, so its pairs, counts and provenance cannot be read."
    ]

  defp state_notes("unsupported_schema"),
    do: [
      "This result uses a schema this reader does not support, so nothing is reported from it."
    ]

  defp state_notes("unsupported_state"),
    do: [
      "This result is in a state this reader cannot interpret, so nothing is reported from it."
    ]

  defp state_notes(_state), do: []

  defp unknown_provenance do
    %{"digest" => nil, "closure_evaluation" => nil, "freshness" => "unknown"}
  end

  # A result recorded before provenance existed stays readable as unknown; only a
  # recorded digest can be compared, and then only over the same canonical input
  # fields.
  defp projection_provenance(%{"digest" => digest, "closure_evaluation" => evaluation})
       when is_binary(digest) do
    %{"digest" => digest, "closure_evaluation" => evaluation, "freshness" => "recorded"}
  end

  defp projection_provenance(_provenance), do: unknown_provenance()

  # Equality is decided over the same canonical input fields `Runner` digested,
  # through the one canonicalizer, and only when the recorded result carries a
  # digest at all.
  defp data_equality(%{"digest" => recorded}, snapshot) when is_binary(recorded) do
    if Envelope.input_provenance(snapshot)["digest"] == recorded,
      do: "match",
      else: "mismatch"
  end

  defp data_equality(_provenance, _snapshot), do: "unknown"

  defp recorded_pairs(%ValidationRun{result_json: %{"pairs" => pairs}}) when is_list(pairs),
    do: pairs

  defp recorded_pairs(_run), do: []

  ## Filters, counts and paging

  defp filters(filters) do
    with true <- valid_offset(Map.get(filters, :offset, 0)),
         {:ok, mode} <- optional_member(Map.get(filters, :mode), @modes),
         {:ok, outcome} <- optional_member(Map.get(filters, :outcome), @outcomes),
         {:ok, pair_index} <- optional_index(Map.get(filters, :pair_index)) do
      {:ok,
       %{
         offset: Map.get(filters, :offset, 0),
         mode: mode,
         outcome: outcome,
         pair_index: pair_index
       }}
    else
      _other -> {:error, :invalid_selection}
    end
  end

  defp valid_offset(offset), do: is_integer(offset) and offset >= 0

  defp optional_member(nil, _allowed), do: {:ok, nil}

  defp optional_member(value, allowed) when is_binary(value) or is_integer(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_selection}
  end

  defp optional_member(_value, _allowed), do: {:error, :invalid_selection}

  defp optional_index(nil), do: {:ok, nil}
  defp optional_index(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_index(_value), do: {:error, :invalid_selection}

  defp matched_pairs(pairs, %{mode: mode, outcome: outcome, pair_index: index}) do
    Enum.filter(pairs, &matches?(&1, mode, outcome, index))
  end

  defp matches?(pair, mode, outcome, index) do
    (is_nil(mode) or pair["mode"] == mode) and
      (is_nil(outcome) or pair["outcome"] == outcome) and
      (is_nil(index) or pair["index"] == index)
  end

  # A page is at most `@max_rows` pairs starting at `offset`. The next offset is
  # present only while more matched pairs remain, so a caller paging forward
  # always knows whether the answer is whole.
  defp put_page(result, matched, %{offset: offset}) do
    rows = Enum.drop(matched, offset) |> Enum.take(@max_rows)
    more? = length(matched) > offset + length(rows)

    result
    |> Map.put("pairs", Enum.map(rows, &pair_projection/1))
    |> Map.put("counts", counts(matched, rows, offset))
    |> Map.put("next_offset", if(more?, do: offset + length(rows), else: nil))
    |> Map.put("completeness", if(more?, do: "incomplete", else: "complete"))
  end

  defp json_filters(%{offset: offset, mode: mode, outcome: outcome, pair_index: pair_index}) do
    %{
      "offset" => offset,
      "mode" => mode,
      "outcome" => outcome,
      "pair_index" => pair_index
    }
  end

  defp counts(matched, rows, offset) do
    %{
      "matched_pairs" => length(matched),
      "returned_pairs" => length(rows),
      "offset" => offset
    }
  end

  ## Size bound and evidence

  # The encoded result plus evidence must stay inside the existing tool limit. An
  # oversized prefix is shortened to the rows that fit; a single row that cannot
  # fit returns zero rows with narrowing guidance rather than a partial row that
  # looks whole.
  defp bounded(result, selection, recorded, matched, page, kind) do
    builder = fn bounded -> evidence(bounded, selection, recorded, matched, page, kind) end

    bounded_result =
      shrink(result, "pairs", "returned_pairs", @narrowing_guidance, builder)

    {:ok, bounded_result, builder.(bounded_result)}
  end

  defp shrink(result, rows_key, counts_key, guidance, builder) do
    if encoded_bytes(result, builder.(result)) <= @max_encoded_bytes do
      result
    else
      case result[rows_key] do
        [] ->
          result
          |> Map.put(rows_key, [])
          |> Map.put("completeness", "incomplete")
          |> Map.put("narrowing", guidance)

        rows ->
          # The tail goes first, so the page keeps the rows that begin at this
          # answer's offset and the next offset continues from where it stopped.
          shortened = Enum.drop(rows, -1)

          result
          |> Map.put(rows_key, shortened)
          |> Map.put("counts", adjust_counts(result["counts"], counts_key, length(shortened)))
          # A shortened page continues where it actually stopped, so a caller
          # paging by this offset never steps over the rows the size bound
          # removed from this answer.
          |> Map.put("next_offset", offset_of(result["counts"]) + length(shortened))
          |> Map.put("completeness", "incomplete")
          |> Map.put("narrowing", guidance)
          |> shrink(rows_key, counts_key, guidance, builder)
      end
    end
  end

  defp offset_of(counts) when is_map(counts), do: Map.get(counts, "offset", 0)
  defp offset_of(_counts), do: 0

  defp adjust_counts(counts, counts_key, returned) do
    Map.put(counts, counts_key, returned)
  end

  defp evidence(result, selection, recorded, matched, page, kind) do
    complete? = result["completeness"] == "complete"

    %{
      kind: kind,
      title: "Recorded station check",
      total: length(matched),
      total_label: "pairs in this answer",
      completeness: if(complete?, do: :complete, else: :incomplete),
      completeness_reason: completeness_reason(result, matched, page),
      source_ref: @source_ref,
      digest: evidence_digest(recorded),
      source_revision: nil,
      scope: scope_field(selection),
      exclusions: exclusion_labels(result),
      resources: run_resources(selection),
      facts: [
        %{label: "Run state", value: recorded.state},
        %{label: "Recorded input digest", value: digest_label(recorded.provenance)},
        %{label: "Data equality", value: recorded.equality},
        %{
          label: "Pairs in this answer",
          value: "#{result["counts"]["returned_pairs"]} of #{length(matched)}"
        }
      ]
    }
  end

  # The recorded provenance digest is the recorded source's own identity. A result
  # that recorded none gets this answer's content digest, and its freshness stays
  # unknown in the facts beside it.
  defp evidence_digest(recorded) do
    case recorded.provenance["digest"] do
      digest when is_binary(digest) ->
        digest

      _absent ->
        digest(%{
          "run_id" => recorded.run_id,
          "state" => recorded.state,
          "recorded_provenance" => recorded.provenance
        })
    end
  end

  defp encoded_bytes(result, evidence) do
    Jason.encode!(%{result: result, evidence: evidence}) |> byte_size()
  end

  defp digest_label(%{"digest" => digest}) when is_binary(digest), do: digest
  defp digest_label(_provenance), do: "unknown"

  defp completeness_reason(%{"narrowing" => guidance}, _matched, _page), do: guidance

  defp completeness_reason(result, matched, page) do
    counts = result["counts"]

    cond do
      result["completeness"] == "complete" and counts["returned_pairs"] == length(matched) and
          filtered?(page) ->
        "One filtered page of #{length(matched)} matching recorded pairs."

      result["completeness"] == "complete" ->
        nil

      true ->
        "#{counts["returned_pairs"]} of #{length(matched)} matching recorded pairs are in this answer; narrow the selection to see the rest."
    end
  end

  defp filtered?(%{mode: mode, outcome: outcome, pair_index: pair_index}) do
    not is_nil(mode) or not is_nil(outcome) or not is_nil(pair_index)
  end

  defp exclusion_labels(result) do
    case result["counts"] do
      %{"matched_pairs" => matched, "returned_pairs" => returned} when matched < returned ->
        ["#{matched - returned} matching pairs were left out by this answer's size bound"]

      %{"returned_pairs" => returned, "matched_pairs" => matched} when returned < matched ->
        ["#{matched - returned} matching recorded pairs are in later pages"]

      _other ->
        []
    end
  end

  defp scope_field(selection) do
    %{
      organization_id: selection.organization_id,
      gtfs_version_id: selection.gtfs_version_id,
      identity: "station:#{selection.station_stop_id}"
    }
  end

  defp run_resources(selection) do
    case selection.run_id do
      nil -> station_resources(selection)
      run_id -> [%{kind: "station_reachability_run", id: run_id}] ++ station_resources(selection)
    end
  end

  defp station_resources(selection) do
    [%{kind: "station", id: selection.station_stop_id, label: selection.station_stop_id}]
  end

  ## Projections

  defp base_result(selection, run, recorded) do
    envelope = run.result_json || %{}

    %{
      "station_stop_id" => selection.station_stop_id,
      "run_id" => run.id,
      "state" => recorded.state,
      "engine" => recorded.engine,
      "engine_ref" => envelope["engine_ref"],
      "preferences" => envelope["preferences"],
      "result_schema_version" => recorded.schema_version,
      "outcome" => envelope["outcome"],
      "totals" => envelope["totals"],
      "topology" => envelope["topology"],
      "diagnostics" => Enum.map(envelope["diagnostics"] || [], &diagnostic_projection/1),
      "recorded_provenance" => recorded.provenance,
      "data_equality" => recorded.equality,
      "started_at" => envelope["started_at"],
      "completed_at" => envelope["completed_at"],
      "duration_ms" => envelope["duration_ms"],
      "notes" => recorded.notes
    }
  end

  # Recorded reasons are kept verbatim; the free-text diagnostic message is not,
  # because the panel renders the code and entity id instead.
  defp pair_projection(pair) do
    %{
      "index" => pair["index"],
      "kind" => pair["kind"],
      "mode" => pair["mode"],
      "from_stop_id" => pair["from_stop_id"],
      "from_stop_name" => pair["from_stop_name"],
      "to_stop_id" => pair["to_stop_id"],
      "to_stop_name" => pair["to_stop_name"],
      "outcome" => pair["outcome"],
      "reason" => pair["reason"],
      "duration_seconds" => pair["duration_seconds"],
      "distance_meters" => pair["distance_meters"],
      "step_count" => pair["step_count"]
    }
  end

  defp diagnostic_projection(diagnostic) do
    %{
      "severity" => diagnostic["severity"],
      "code" => diagnostic["code"],
      "entity_type" => diagnostic["entity_type"],
      "entity_id" => diagnostic["entity_id"]
    }
  end

  # Item labels, identifiers, statuses and counts survive; the builder's
  # description and per-entity reason prose do not.
  defp quality_projection(item) do
    %{
      "id" => item.id,
      "label" => item.label,
      "status" => Atom.to_string(item.status),
      "value" => json_value(item.value),
      "value_format" => Atom.to_string(item.value_format),
      "affected_count" => affected_count(item)
    }
  end

  defp json_value(value) when is_binary(value) or is_integer(value) or is_boolean(value),
    do: value

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), json_value(inner)} end)

  defp json_value(_value), do: nil

  defp affected_count(%{value_format: :count, details: details}) when is_list(details),
    do: length(details)

  defp affected_count(_item), do: nil

  defp connectivity_projection(snapshot) do
    snapshot
    |> Connectivity.build_summaries()
    |> Enum.map(fn {dimension, summary} ->
      %{
        "dimension" => to_string(dimension),
        "label" => summary.title,
        "status" => Atom.to_string(summary.status),
        "stats" => %{
          "total_pairs" => summary.stats.total_pairs,
          "connected_pairs" => summary.stats.connected_pairs,
          "source_count" => summary.stats.source_count,
          "target_count" => summary.stats.target_count
        },
        "sources" =>
          Enum.map(summary.summary_rows, fn row ->
            %{
              "source_stop_id" => row.source_stop_id,
              "status" => Atom.to_string(row.status),
              "reachable_count" => length(row.reachable),
              "unreachable_count" => length(row.unreachable)
            }
          end)
      }
    end)
  end

  ## The computed import run

  defp page_offset(filters) do
    case Map.get(filters, :offset, 0) do
      offset when is_integer(offset) and offset >= 0 -> {:ok, offset}
      _other -> {:error, :invalid_selection}
    end
  end

  defp import_selection(%Scope{} = scope) do
    selection_source(scope, @import_source_kind, "change_run_id", :require_run)
  end

  # One repeatable-read snapshot of everything the answer describes: the run, its
  # persisted decisions, the current rows those decisions speak about and the
  # stops this run proposes. A writer between two reads cannot make the projected
  # rows and the reported counts describe different database states.
  defp import_snapshot(selection) do
    Repo.transaction(
      fn ->
        snapshot_module().begin_read()

        with {:ok, station_snapshot} <-
               Gtfs.get_station_report_snapshot(
                 selection.organization_id,
                 selection.gtfs_version_id,
                 selection.station_stop_id
               ),
             true <- owned_station?(station_snapshot, selection) do
          computed_run(selection)
        else
          _other -> {:error, :unavailable}
        end
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # A foreign, deleted or uncomputed run is one refusal: this scope has no
  # computed review to read, whatever the run holds.
  defp computed_run(selection) do
    with {:ok, run} <- scoped_run(selection) do
      decisions = ChangeRuns.list_decisions(selection.organization_id, run.id)

      {:ok,
       %{
         selection: selection,
         run: run,
         decisions: decisions,
         version_total: length(decisions),
         version_approved: Enum.count(decisions, &(&1.status in @approved_statuses)),
         world: station_world(selection, decisions)
       }}
    end
  end

  defp scoped_run(selection) do
    case ChangeRuns.get_for_version(
           selection.organization_id,
           selection.gtfs_version_id,
           selection.run_id
         ) do
      %ChangeRun{kind: :station_diff, state: state} = run
      when state in @computed_review_states ->
        {:ok, run}

      _other ->
        {:error, :no_computed_review}
    end
  end

  # Membership follows real parent chains, so the whole scoped stop table is read
  # rather than only the stops a decision names: a chain two levels up is still
  # evidence. Proposed stops are layered on top, because their uploaded parent
  # and level are what those stops become once the decision is applied.
  defp station_world(selection, decisions) do
    stops =
      from(s in Stop,
        where:
          s.organization_id == ^selection.organization_id and
            s.gtfs_version_id == ^selection.gtfs_version_id
      )
      |> Repo.all()
      |> Map.new(&{&1.stop_id, &1})

    levels =
      from(l in Level,
        where:
          l.organization_id == ^selection.organization_id and
            l.gtfs_version_id == ^selection.gtfs_version_id
      )
      |> Repo.all()
      |> Map.new(&{&1.level_id, &1})

    pathways = pathways_in_scope(selection, decisions)

    %{
      stops: stops,
      levels: levels,
      pathways: pathways,
      proposed: proposed_stops(decisions, stops)
    }
  end

  defp pathways_in_scope(selection, decisions) do
    case Enum.flat_map(decisions, &decision_natural_keys/1) |> Enum.uniq() do
      [] ->
        %{}

      pathway_ids ->
        from(p in Pathway,
          where:
            p.organization_id == ^selection.organization_id and
              p.gtfs_version_id == ^selection.gtfs_version_id and
              p.pathway_id in ^pathway_ids
        )
        |> Repo.all()
        |> Map.new(&{&1.pathway_id, &1})
    end
  end

  defp decision_natural_keys(%{entity_type: :pathway, natural_key: key}), do: [key]
  defp decision_natural_keys(_decision), do: []

  defp proposed_stops(decisions, stops) do
    Enum.reduce(decisions, %{}, fn decision, acc ->
      case proposed_stop(decision, stops) do
        nil -> acc
        stop -> Map.put_new(acc, stop.stop_id, stop)
      end
    end)
  end

  defp proposed_stop(%{entity_type: :stop, action: action} = decision, stops)
       when action in [:add, :modify, :conflict] do
    key = blank_to_nil(decision.natural_key)
    uploaded = decision.uploaded_values || %{}
    current = Map.get(stops, key)

    if is_nil(key) do
      nil
    else
      %{
        stop_id: key,
        parent: blank_to_nil(Map.get(uploaded, "parent_station")) || entry_parent(current),
        level: blank_to_nil(Map.get(uploaded, "level_id")) || entry_level(current)
      }
    end
  end

  defp proposed_stop(_decision, _stops), do: nil

  ## Membership

  # The parent chain decides membership. A stop is the station's own when it is
  # the station row, and otherwise when following its parents reaches the
  # station. A chain that lands on another station, breaks at a missing row or
  # loops is unresolvable, so the row is excluded rather than guessed at.
  defp resolve_stop(_world, _station, stop_id, _visited) when stop_id in [nil, ""],
    do: :unresolvable

  defp resolve_stop(world, station, stop_id, visited) do
    cond do
      stop_id == station -> {:station, stop_id}
      stop_id in visited -> :unresolvable
      true -> resolve_parent(world, station, stop_id, visited)
    end
  end

  defp resolve_parent(world, station, stop_id, visited) do
    case world_entry(world, stop_id) do
      nil -> :unresolvable
      entry -> resolve_stop(world, station, entry_parent(entry), [stop_id | visited])
    end
  end

  defp world_entry(world, stop_id) do
    Map.get(world.proposed, stop_id) || Map.get(world.stops, stop_id)
  end

  defp entry_parent(%{parent_station: parent}), do: blank_to_nil(parent)
  defp entry_parent(%{parent: parent}), do: blank_to_nil(parent)
  defp entry_parent(_entry), do: nil

  defp entry_level(%{level_id: level}), do: blank_to_nil(level)
  defp entry_level(%{level: level}), do: blank_to_nil(level)
  defp entry_level(_entry), do: nil

  defp entry_stop_id(%{stop_id: stop_id}), do: stop_id

  defp station_stop?(world, station, stop_id) do
    match?({:station, _stop_id}, resolve_stop(world, station, stop_id, []))
  end

  # A stop belongs to the station when its current parent chain and its uploaded
  # parent chain both resolve to it. The station row itself is a member of its
  # own review.
  defp station_attributed?(%{entity_type: type} = decision, world, station) do
    case type do
      :stop -> stop_attributed?(decision, world, station)
      :pathway -> pathway_attributed?(decision, world, station)
      :level -> level_attributed?(decision, world, station)
      _other -> false
    end
  end

  defp stop_attributed?(decision, world, station) do
    key = blank_to_nil(decision.natural_key)
    uploaded = decision.uploaded_values || %{}

    not is_nil(key) and
      current_stop_resolves?(world, station, key, decision.current_values) and
      uploaded_stop_resolves?(world, station, key, uploaded)
  end

  defp current_stop_resolves?(_world, _station, _key, values) when map_size(values) == 0,
    do: true

  defp current_stop_resolves?(world, station, key, _values),
    do: station_stop?(world, station, key)

  defp uploaded_stop_resolves?(_world, _station, _key, uploaded) when map_size(uploaded) == 0,
    do: true

  # An uploaded row that does not restate a parent keeps the one the decided
  # record already has, so the effective parent - uploaded over current - is what
  # has to resolve.
  defp uploaded_stop_resolves?(world, station, key, uploaded) do
    effective_parent =
      Map.get(uploaded, "parent_station") || entry_parent(world_entry(world, key))

    station_stop?(world, station, effective_parent)
  end

  # A pathway belongs to the station only when every endpoint it has - current
  # and uploaded alike - resolves wholly to it. One endpoint on another station,
  # or one endpoint that resolves to nothing, excludes the whole pathway.
  defp pathway_attributed?(decision, world, station) do
    case decision_endpoints(decision) do
      [] -> false
      endpoints -> Enum.all?(endpoints, &station_stop?(world, station, &1))
    end
  end

  defp decision_endpoints(decision) do
    endpoint_pairs(decision.current_values || %{}) ++
      endpoint_pairs(decision.uploaded_values || %{})
  end

  defp endpoint_pairs(values) when map_size(values) == 0, do: []

  defp endpoint_pairs(values),
    do: [Map.get(values, "from_stop_id"), Map.get(values, "to_stop_id")]

  # A level is shared by every stop that references it, current or proposed in
  # this run. It belongs to the station only when all of them resolve to this
  # station: a foreign or unresolvable reference makes it shared or unknown, and
  # no reference at all attributes it to nobody.
  defp level_attributed?(decision, world, station) do
    case blank_to_nil(decision.natural_key) do
      nil ->
        false

      level_id ->
        case level_members(world, level_id) do
          [] -> false
          members -> Enum.all?(members, &station_stop?(world, station, &1))
        end
    end
  end

  defp level_members(world, level_id) do
    current =
      world.stops
      |> Map.values()
      |> Enum.filter(&(entry_level(&1) == level_id))
      |> Enum.map(&entry_stop_id/1)

    proposed =
      world.proposed
      |> Map.values()
      |> Enum.filter(&(entry_level(&1) == level_id))
      |> Enum.map(&entry_stop_id/1)

    Enum.uniq(current ++ proposed)
  end

  ## The answer

  defp import_answer(snapshot, offset) do
    %{selection: selection, run: run} = snapshot
    {station_rows, excluded} = station_rows(snapshot)
    import_digest = import_digest(run, station_rows)

    result = import_result(snapshot, station_rows, excluded, offset, import_digest)

    bounded_import(result, selection, run, station_rows, offset, import_digest)
  end

  # The station-attributed rows and the exclusion histogram behind them. Both the
  # read and the preparation project the same rows from the same snapshot, so a
  # prepared selection can never describe a different station membership than the
  # diff a host is looking at.
  defp station_rows(%{selection: selection, decisions: decisions, world: world}) do
    attributed =
      Enum.map(decisions, &{&1, station_attributed?(&1, world, selection.station_stop_id)})

    rows = for {decision, true} <- attributed, do: decision_row(decision, world)

    excluded =
      Enum.frequencies_by(attributed, fn {decision, attributed?} ->
        exclusion_reason(attributed?, decision)
      end)

    {rows, excluded}
  end

  defp import_result(snapshot, station_rows, excluded, offset, import_digest) do
    selection = snapshot.selection
    run = snapshot.run
    rows = Enum.drop(station_rows, offset) |> Enum.take(@max_rows)
    more? = length(station_rows) > offset + length(rows)

    %{
      "station_stop_id" => selection.station_stop_id,
      "run_id" => run.id,
      "state" => to_string(run.state),
      "serializer_version" => run.serializer_version,
      "source_files" => source_files(run.source_manifest),
      "import_digest" => import_digest,
      "diagnostics" => run_diagnostics(run),
      "counts" => import_counts(snapshot, station_rows, excluded, length(rows), offset),
      "excluded" => excluded,
      "decisions" => rows,
      "filters" => %{"offset" => offset},
      "next_offset" => if(more?, do: offset + length(rows), else: nil),
      "completeness" => if(more?, do: "incomplete", else: "complete"),
      "notes" => import_notes()
    }
  end

  defp exclusion_reason(true, _decision), do: :none
  defp exclusion_reason(false, %{entity_type: :stop}), do: :unresolvable_or_other_stop
  defp exclusion_reason(false, %{entity_type: :pathway}), do: :unresolvable_or_other_endpoint
  defp exclusion_reason(false, %{entity_type: :level}), do: :shared_or_unknown_level

  defp import_counts(snapshot, station_rows, excluded, returned, offset) do
    %{
      "version_total" => snapshot.version_total,
      "station_total" => length(station_rows),
      "excluded_total" => excluded |> Map.delete(:none) |> Map.values() |> Enum.sum(),
      "existing_approved" => Enum.count(station_rows, &approved_status?/1),
      "version_approved" => snapshot.version_approved,
      "returned_decisions" => returned,
      "offset" => offset
    }
  end

  defp approved_status?(row), do: row["status"] in Enum.map(@approved_statuses, &to_string/1)

  defp import_notes do
    [
      "This is a read of one computed native import run. Nothing here approves, rejects, prepares or applies a decision.",
      "Decisions outside this station stay in the native version-wide review, including the ones already approved there.",
      "A decision is excluded when its stop, its pathway endpoints or its level references are not wholly inside this station."
    ]
  end

  defp decision_row(decision, world) do
    %{
      "decision_id" => decision.decision_id,
      "entity_type" => to_string(decision.entity_type),
      "natural_key" => decision.natural_key,
      "action" => to_string(decision.action),
      "status" => to_string(decision.status),
      "current_values" => decision.current_values || %{},
      "uploaded_values" => decision.uploaded_values || %{},
      "changed_fields" => decision.changed_fields || [],
      "dependency_keys" => decision.dependency_keys || [],
      "current_fingerprint" => decision.current_fingerprint,
      "user_edited" => decision.user_edited == true,
      "live_fingerprint" => live_fingerprint(decision, world),
      "fingerprint_state" => fingerprint_state(decision, world),
      "apply_failure_code" => decision.apply_failure_code
    }
  end

  # The stored fingerprint is recomputed from the live record the same way the
  # fenced apply computes it, so drift is visible while reading rather than only
  # at apply time. A decision with no current record has nothing to compare.
  defp live_fingerprint(decision, world) do
    with %{current_values: current_values} when map_size(current_values) > 0 <- decision,
         entity when not is_nil(entity) <- live_entity(decision, world) do
      fingerprint(decision, entity)
    else
      _other -> nil
    end
  end

  defp fingerprint_state(decision, world) do
    live = live_fingerprint(decision, world)

    cond do
      map_size(decision.current_values || %{}) == 0 -> "unrecorded"
      is_nil(decision.current_fingerprint) -> "unrecorded"
      is_nil(live) -> "no_current_record"
      live == decision.current_fingerprint -> "match"
      true -> "drifted"
    end
  end

  defp fingerprint(decision, entity) do
    case ChangeDecisionSerializer.record_fingerprint(
           decision.entity_type,
           entity,
           Map.keys(decision.current_values || %{})
         ) do
      {:ok, fingerprint} -> fingerprint
      _error -> nil
    end
  end

  defp live_entity(%{action: :add}, _world), do: nil

  defp live_entity(decision, world) do
    case decision.entity_type do
      :stop -> Map.get(world.stops, decision.natural_key)
      :pathway -> Map.get(world.pathways, decision.natural_key)
      :level -> Map.get(world.levels, decision.natural_key)
    end
  end

  # The run's own base source files, by name, size and content hash. Other
  # manifest namespaces and the storage keys inside file entries are hashed into
  # the digest but never projected, so no storage key or review history reaches
  # the answer.
  defp source_files(manifest) when is_map(manifest) do
    files =
      manifest
      |> Map.get(:files, Map.get(manifest, "files"))
      |> List.wrap()
      |> Enum.map(&stringify_keys/1)
      |> Enum.map(&Map.take(&1, ["name", "size", "sha256"]))

    %{
      "files" => files,
      "total_bytes" => manifest |> Map.get(:total_bytes, Map.get(manifest, "total_bytes"))
    }
  end

  defp source_files(_manifest), do: %{"files" => [], "total_bytes" => nil}

  defp stringify_keys(nil), do: nil

  defp stringify_keys(values) when is_map(values),
    do: Map.new(values, fn {key, inner} -> {to_string(key), inner} end)

  defp stringify_keys(values),
    do: Enum.map(values, &stringify_keys/1)

  # The run's own native diagnostics, without the builder's free-text detail.
  defp run_diagnostics(run) do
    run.diagnostics
    |> List.wrap()
    |> Enum.map(fn diagnostic ->
      diagnostic
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(["code", "entity_type", "natural_key"])
    end)
  end

  # The import digest is this run's current state: identity, lifecycle, serializer
  # version and base source files, plus every projected decision's status,
  # dependencies, values and live fingerprint. Review history is deliberately not
  # part of it, so appending reviewed evidence does not invalidate the very
  # confirmation that appended it.
  defp import_digest(run, rows) do
    digest(%{
      "run_id" => run.id,
      "state" => to_string(run.state),
      "serializer_version" => run.serializer_version,
      "base_source_files" => base_source_files(run.source_manifest),
      "decisions" => Enum.map(rows, &digest_row/1)
    })
  end

  defp digest_row(row) do
    Map.take(row, [
      "decision_id",
      "entity_type",
      "natural_key",
      "action",
      "status",
      "current_values",
      "uploaded_values",
      "changed_fields",
      "dependency_keys",
      "current_fingerprint",
      "live_fingerprint"
    ])
  end

  defp base_source_files(manifest) when is_map(manifest),
    do: Map.take(manifest, [:files, :total_bytes, "files", "total_bytes"])

  defp base_source_files(_manifest), do: %{}

  ## Import size bound and evidence

  defp bounded_import(result, selection, run, rows, offset, import_digest) do
    builder =
      fn bounded -> evidence_for(bounded, selection, run, rows, offset, import_digest) end

    bounded_result =
      shrink(result, "decisions", "returned_decisions", @import_narrowing_guidance, builder)

    {:ok, bounded_result, builder.(bounded_result)}
  end

  defp evidence_for(result, selection, run, rows, offset, import_digest) do
    complete? = result["completeness"] == "complete"
    counts = result["counts"]

    %{
      kind: "station_import_diff",
      title: "Station import decisions",
      total: counts["station_total"],
      total_label: "decisions attributable to this station",
      completeness: if(complete?, do: :complete, else: :incomplete),
      completeness_reason: import_completeness_reason(result, counts, length(rows)),
      source_ref: @source_ref,
      digest: import_digest,
      source_revision: nil,
      scope: scope_field(selection),
      exclusions: import_exclusion_labels(counts, result),
      resources: import_resources(selection, run),
      facts: [
        %{label: "Run state", value: to_string(run.state)},
        %{label: "Version-wide decisions", value: counts["version_total"]},
        %{label: "This station", value: counts["station_total"]},
        %{label: "Excluded", value: counts["excluded_total"]},
        %{label: "Already approved here", value: counts["existing_approved"]},
        %{
          label: "Returned",
          value: "#{counts["returned_decisions"]} of #{length(rows)} at offset #{offset}"
        }
      ]
    }
  end

  defp import_completeness_reason(%{"narrowing" => guidance}, _counts, _total), do: guidance

  defp import_completeness_reason(_result, counts, total) do
    if counts["returned_decisions"] == total,
      do: nil,
      else:
        "#{counts["returned_decisions"]} of #{total} station decisions are in this answer; the rest are in later pages."
  end

  defp import_exclusion_labels(counts, result) do
    labels =
      result
      |> Map.get("excluded", %{})
      |> Enum.sort()
      |> Enum.map(fn {reason, count} ->
        "#{count} decisions excluded as #{String.replace(to_string(reason), "_", " ")}"
      end)

    if counts["version_approved"] > 0,
      do:
        labels ++
          [
            "#{counts["version_approved"]} decisions in this run are already approved and stay in the native review"
          ],
      else: labels
  end

  defp import_resources(selection, run) do
    [
      %{kind: "station_import_run", id: run.id},
      %{kind: "station", id: selection.station_stop_id, label: selection.station_stop_id}
    ]
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  ## Accepted observations

  # A frozen observation list is bounded exactly like a page of decisions: the
  # whole-context admission already limits the bytes, and this refuses the shape
  # rather than truncating staff's evidence.
  defp observation_batch(observations) do
    if length(observations) <= @max_rows, do: :ok, else: {:error, :invalid_selection}
  end

  defp normalize_rows(selection, observations) do
    journal = journal_scope(selection)

    {accepted, rejected} =
      observations
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {row, index}, {accepted, rejected} ->
        case normalize_row(journal, row, index) do
          {:ok, observation} -> {[observation | accepted], rejected}
          {:error, rejection} -> {accepted, [rejection | rejected]}
        end
      end)

    accepted = accepted |> Enum.reverse()
    distinct = dedupe_observations(accepted)
    conflicting = conflicting_rejections(accepted)

    %{
      "observations" => distinct,
      "rejected" =>
        Enum.sort_by(
          Enum.reverse(rejected) ++ conflicting,
          &{&1["source_ref"] || "", &1["reason"]}
        ),
      "counts" => %{
        "submitted" => length(observations),
        "accepted" => length(distinct),
        "rejected" => length(rejected) + length(conflicting)
      }
    }
  end

  # Two accepted rows that disagree about the same target and field are both
  # dropped: neither is authoritative, and choosing one would silently resolve a
  # conflict staff have not resolved. Identical duplicates collapse to one row,
  # because they say the same thing twice and are not a disagreement.
  defp dedupe_observations(observations) do
    observations
    |> Enum.group_by(&{&1["target"]["pathway_id"], &1["field"], &1["normalized_value"]})
    |> Enum.map(fn {_key, rows} -> hd(rows) end)
    |> Enum.reject(&conflicting?(&1, observations))
  end

  defp conflicting?(observation, observations) do
    key = {observation["target"]["pathway_id"], observation["field"]}

    observations
    |> Enum.filter(&({&1["target"]["pathway_id"], &1["field"]} == key))
    |> Enum.map(& &1["normalized_value"])
    |> Enum.uniq()
    |> length() > 1
  end

  defp conflicting_rejections(observations) do
    observations
    |> Enum.filter(&conflicting?(&1, observations))
    |> Enum.map(&%{"source_ref" => &1["source_ref"], "reason" => "conflicting_duplicate"})
  end

  defp normalize_row(journal, row, index) when is_map(row) do
    with :ok <- known_keys(row),
         {:ok, source_ref} <- source_ref(Map.get(row, "source_ref")),
         {:ok, target} <- observation_target(Map.get(row, "target")),
         :ok <- observation_field(Map.get(row, "field")),
         {:ok, {original_text, original}} <- original_value(Map.get(row, "original_value")),
         {:ok, unit} <- unit(Map.get(row, "unit")),
         {:ok, normalized} <- convert(original, unit),
         {:ok, captured_date} <- captured_date(Map.get(row, "captured_date")),
         :ok <- meaning(Map.get(row, "meaning")),
         {:ok, accepted} <- boolean(Map.get(row, "accepted")),
         {:ok, conflict} <- boolean(Map.get(row, "conflict")),
         {:ok, revision} <- source_revision(Map.get(row, "source_revision")),
         {:ok, source} <- source_capture(journal, source_ref, revision) do
      {:ok,
       %{
         "source_ref" => source_ref,
         "source_revision" => source.revision,
         "source_digest" => source.digest,
         "journal_backed" => source.journal_backed,
         "target" => target,
         "field" => @observation_field,
         "original_value" => original_text,
         "unit" => unit,
         "normalized_value" => normalized,
         "captured_date" => captured_date,
         "meaning" => @observation_meaning,
         "accepted" => accepted,
         "conflict" => conflict
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reject(index, row, reason)}
      {:error, reason} when is_binary(reason) -> {:error, reject(index, row, reason)}
    end
  end

  defp normalize_row(_journal, row, index),
    do: {:error, reject(index, row, :not_a_row)}

  defp reject(index, row, reason) do
    %{
      "source_ref" => row |> Map.get("source_ref") |> bounded_ref(),
      "reason" => to_string(reason)
    }
    |> Map.put("index", index)
  end

  defp bounded_ref(ref) when is_binary(ref) and byte_size(ref) <= @max_source_ref_bytes, do: ref
  defp bounded_ref(_ref), do: nil

  # An unexpected key is a row this reader does not understand, and an
  # unrecognised field is refused rather than ignored: silently dropping a
  # measurement attribute would report an acceptance staff did not give.
  defp known_keys(row) do
    if Enum.all?(Map.keys(row), &is_binary/1) and
         Enum.all?(Map.keys(row), &(&1 in @observation_keys)) do
      :ok
    else
      {:error, :unknown_field}
    end
  end

  defp source_ref(ref)
       when is_binary(ref) and byte_size(ref) > 0 and byte_size(ref) <= @max_source_ref_bytes,
       do: {:ok, ref}

  defp source_ref(_ref), do: {:error, :invalid_source_ref}

  defp source_revision(nil), do: {:ok, nil}

  defp source_revision(revision)
       when is_binary(revision) and byte_size(revision) <= @max_source_revision_bytes,
       do: {:ok, revision}

  defp source_revision(_revision), do: {:error, :invalid_source_revision}

  defp observation_target(%{"pathway_id" => pathway_id})
       when is_binary(pathway_id) and byte_size(pathway_id) > 0 and
              byte_size(pathway_id) <= @max_pathway_id_bytes,
       do: {:ok, %{"pathway_id" => pathway_id}}

  defp observation_target(_target), do: {:error, :invalid_target}

  defp observation_field(@observation_field), do: :ok
  defp observation_field(_field), do: {:error, :unsupported_field}

  defp meaning(@observation_meaning), do: :ok
  defp meaning(_meaning), do: {:error, :missing_meaning}

  defp original_value(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_original_value_bytes do
    # The original text is kept verbatim beside the conversion, so the answer
    # shows what staff measured and not only what it became.
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, {value, decimal}}
      _other -> {:error, :invalid_value}
    end
  end

  defp original_value(_value), do: {:error, :invalid_value}

  defp unit(value) when is_binary(value) do
    if Map.has_key?(@observation_units, value),
      do: {:ok, value},
      else: {:error, :unsupported_unit}
  end

  defp unit(_value), do: {:error, :unsupported_unit}

  # Exact decimal multiplication, never a float: 105 cm is 1.05 m, and a width
  # that rounds to the uploaded value is not the width staff measured.
  defp convert(value, unit) do
    converted = Decimal.mult(value, Map.fetch!(@observation_units, unit))

    if Decimal.positive?(converted) do
      {:ok, Decimal.to_string(Decimal.normalize(converted), :normal)}
    else
      {:error, :nonpositive_value}
    end
  end

  defp captured_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_captured_date}
    end
  end

  defp captured_date(_value), do: {:error, :invalid_captured_date}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :invalid_boolean}

  # A UUID source reference names a journal entry, and it is resolved through
  # `StationJournal`'s own scoped read. A reference that is not a journal entry
  # of this station - including one belonging to another station - is refused,
  # and no other station's entry metadata can be observed through the failure.
  defp source_capture(journal, source_ref, revision) do
    if journal_backed?(source_ref) do
      capture_journal_entry(journal, source_ref, revision)
    else
      {:ok, %{revision: revision, digest: nil, journal_backed: false}}
    end
  end

  defp capture_journal_entry(journal, source_ref, revision) do
    with {:ok, scope} <- journal,
         [entry] <- StationJournal.list_entries(scope, id: source_ref, limit: 1),
         frozen = freeze_entry(entry),
         true <- is_nil(revision) or frozen.revision == revision do
      {:ok, frozen}
    else
      _other -> {:error, :foreign_journal_reference}
    end
  end

  defp journal_backed?(source_ref) do
    match?({:ok, _uuid}, Ecto.UUID.cast(source_ref))
  end

  # Only identity and timing metadata is frozen. The entry's body, its photos
  # and its author are evidence for a person, not a measurement, and they never
  # leave the server (AC-13).
  defp freeze_entry(entry) do
    %{
      revision: DateTime.to_iso8601(entry.updated_at),
      journal_backed: true,
      digest:
        digest(%{
          "entry_id" => entry.id,
          "target_type" => entry.target_type,
          "target_id" => entry.target_id,
          "captured_at" => entry.captured_at,
          "updated_at" => entry.updated_at
        })
    }
  end

  defp journal_scope(selection) do
    case selection.actor_id do
      nil ->
        {:error, :unavailable}

      actor_id ->
        StationJournal.resolve_scope(
          selection.organization_id,
          selection.gtfs_version_id,
          selection.station_id,
          actor_id
        )
    end
  end

  defp observation_evidence(selection, run, normalized) do
    counts = normalized["counts"]

    %{
      kind: "station_observation_provenance",
      title: "Accepted field observations",
      total: counts["accepted"],
      total_label: "accepted observations ready to match a decision",
      completeness: :complete,
      source_ref: @source_ref,
      digest: digest(normalized["observations"]),
      source_revision: nil,
      scope: scope_field(selection),
      exclusions: observation_exclusions(normalized, run),
      resources: import_resources(selection, run),
      facts: [
        %{label: "Submitted", value: counts["submitted"]},
        %{label: "Accepted and converted", value: counts["accepted"]},
        %{label: "Unresolved rows", value: counts["rejected"]},
        %{
          label: "Converted units",
          value: "m, cm and mm as exact decimals; only min_width minimum clear width converts"
        },
        %{
          label: "Writes",
          value: "none - reading accepted observations changes no row, status or run"
        }
      ]
    }
  end

  defp observation_exclusions(normalized, run) do
    rejected =
      normalized["rejected"]
      |> Enum.frequencies_by(& &1["reason"])
      |> Enum.sort()
      |> Enum.map(fn {reason, count} -> "#{count} observations unresolved as #{reason}" end)

    rejected ++
      ["Base source files are bound to run #{run.id}; a changed upload is a different run"]
  end

  ## Prepared selection

  defp selection_ids(ids) do
    valid? =
      length(ids) <= @max_rows and Enum.all?(ids, &selection_id?/1) and
        length(Enum.uniq(ids)) == length(ids)

    if valid?, do: {:ok, ids}, else: {:error, :invalid_selection}
  end

  defp selection_id?(id), do: is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 512

  # The accepted observations are the ones the host froze into the source
  # snapshot, never anything a caller or a model supplied, and their recorded
  # digest must still match the snapshot's own envelope. They are matched against
  # a *fresh* read of the run, so an observation captured against a run that has
  # since changed never selects anything.
  defp prepare_answer(snapshot, ids) do
    selection = snapshot.selection
    run = snapshot.run
    {station_rows, _excluded} = station_rows(snapshot)
    {rows_by_id, run_rows_by_id} = decision_indexes(station_rows, snapshot.decisions)
    observations = frozen_observations(selection)
    run_digest = import_digest(run, station_rows)

    selected =
      Enum.flat_map(ids, fn id ->
        case select_decision(rows_by_id, run_rows_by_id, observations, id) do
          {:selected, row} -> [row]
          _other -> []
        end
      end)

    unresolved =
      for id <- ids,
          reason = unresolved_reason(rows_by_id, run_rows_by_id, observations, id),
          do: %{"decision_id" => id, "reason" => to_string(reason)}

    # A requested id this station's projection does not contain is reported in
    # one bucket, whether the run holds it elsewhere or nowhere: this answer must
    # not become a way to probe another station's decisions.
    excluded =
      for id <- ids,
          not Map.has_key?(rows_by_id, id),
          do: %{"decision_id" => id, "reason" => "not_a_station_decision"}

    existing_approved =
      station_rows
      |> Enum.filter(&approved_status?/1)
      |> Enum.map(&%{"decision_id" => &1["decision_id"], "status" => &1["status"]})

    input_digest = input_digest(selection, run, run_digest, observations, ids)

    result = %{
      "station_stop_id" => selection.station_stop_id,
      "run_id" => run.id,
      "import_digest" => run_digest,
      "selected" => selected,
      "unresolved" => unresolved,
      "excluded" => excluded,
      "existing_approved" => existing_approved,
      "counts" => %{
        "requested" => length(ids),
        "selected" => length(selected),
        "unresolved" => length(unresolved),
        "excluded" => length(excluded),
        "existing_approved" => length(existing_approved),
        "observations" => observations["counts"]
      },
      "input_digest" => input_digest,
      "notes" => selection_notes()
    }

    {:ok, result, selection_evidence(selection, run, result, input_digest)}
  end

  defp select_decision(rows_by_id, run_rows_by_id, observations, id) do
    case Map.fetch(rows_by_id, id) do
      {:ok, row} -> select_station_row(row, run_rows_by_id, observations)
      :error -> {:error, :not_a_station_decision}
    end
  end

  defp select_station_row(row, run_rows_by_id, observations) do
    with :ok <- eligible_row?(row, run_rows_by_id),
         {:ok, observation} <- matching_observation(observations, row) do
      {:selected,
       %{
         "decision_id" => row["decision_id"],
         "natural_key" => row["natural_key"],
         "action" => row["action"],
         "current_value" => row["current_values"]["min_width"],
         "uploaded_value" => row["uploaded_values"]["min_width"],
         "field" => @observation_field,
         "observation" => observation
       }}
    end
  end

  # Every gate a complete, unmodified, still-current width decision has to pass.
  # The first failure is the reported reason, so a host shows staff the one thing
  # that is actually blocking the row.
  defp eligible_row?(row, run_rows_by_id) do
    cond do
      row["action"] != "modify" -> {:error, :not_a_modification}
      row["entity_type"] != "pathway" -> {:error, :not_a_pathway}
      changed_fields(row) != [@observation_field] -> {:error, :incomplete_field_coverage}
      row["user_edited"] -> {:error, :user_edited}
      row["status"] != "pending" -> {:error, :not_pending}
      row["fingerprint_state"] != "match" -> {:error, :fingerprint_drift}
      true -> dependencies_approved?(row, run_rows_by_id)
    end
  end

  defp changed_fields(row) do
    row["changed_fields"]
    |> List.wrap()
    |> Enum.map(& &1["field"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A dependency that is still pending makes the whole decision unresolved: an
  # approval that arrived before its dependency would apply a width change to a
  # pathway whose endpoints are themselves being changed. A dependency key with
  # no decision in this run is satisfied by the current record, which is what an
  # unchanged endpoint produces.
  defp dependencies_approved?(row, run_rows_by_id) do
    pending =
      Enum.find(row["dependency_keys"] || [], fn key ->
        case Map.fetch(run_rows_by_id, key) do
          {:ok, dependency} -> dependency.status not in @approved_statuses
          :error -> false
        end
      end)

    if pending, do: {:error, :dependency_not_approved}, else: :ok
  end

  # Decimal equality, not string equality: the serializer normalizes an uploaded
  # `1.20` to `1.2`, and an accepted 120 cm is the same width. String comparison
  # would call a measured width a mismatch and refuse a row staff did accept.
  defp matching_observation(observations, row) do
    candidates =
      Enum.filter(observations["observations"], fn observation ->
        observation["target"]["pathway_id"] == row["natural_key"] and
          observation["field"] == @observation_field and observation["accepted"] and
          not observation["conflict"]
      end)

    cond do
      candidates == [] ->
        {:error, :no_accepted_observation}

      Enum.any?(candidates, &same_width?(&1["normalized_value"], row)) ->
        {:ok, candidate(candidates, row)}

      true ->
        {:error, :uploaded_value_mismatch}
    end
  end

  defp same_width?(normalized, row) do
    with {measured, ""} <- Decimal.parse(normalized),
         {uploaded, ""} <- Decimal.parse(to_string(row["uploaded_values"]["min_width"])) do
      Decimal.equal?(measured, uploaded)
    else
      _other -> false
    end
  end

  # The provenancing fields only: what staff measured, in what unit, when, from
  # which source, and the frozen revision of a journal entry when there is one.
  defp candidate(candidates, row) do
    candidates
    |> Enum.find(&same_width?(&1["normalized_value"], row))
    |> Map.take([
      "source_ref",
      "source_revision",
      "source_digest",
      "journal_backed",
      "original_value",
      "unit",
      "normalized_value",
      "captured_date",
      "meaning",
      "field"
    ])
  end

  defp unresolved_reason(rows_by_id, run_rows_by_id, observations, id) do
    case select_decision(rows_by_id, run_rows_by_id, observations, id) do
      {:selected, _row} -> nil
      {:error, reason} -> reason
    end
  end

  defp decision_indexes(station_rows, decisions) do
    {Map.new(station_rows, &{&1["decision_id"], &1}), Map.new(decisions, &{&1.decision_id, &1})}
  end

  # The observations the host froze. Their recorded digest must still match the
  # snapshot envelope, so a payload edited after admission is refused rather than
  # read.
  defp frozen_observations(selection) do
    payload = Map.get(selection.source_snapshot, :payload, %{})
    rows = Map.get(payload, "observations", [])
    digest = Map.get(payload, "observations_digest")

    if is_list(rows) and (is_nil(digest) or digest == digest(rows)) do
      normalize_rows(selection, rows)
    else
      empty_observations()
    end
  end

  defp empty_observations do
    %{
      "observations" => [],
      "rejected" => [],
      "counts" => %{"submitted" => 0, "accepted" => 0, "rejected" => 0}
    }
  end

  # The input digest binds everything a later native confirmation must recheck:
  # the frozen source envelope, the run's own base source files, every projected
  # decision it might approve and the observations it would approve them with. A
  # stale selection cannot recompute to the same value.
  defp input_digest(selection, run, run_digest, observations, ids) do
    digest(%{
      "source_snapshot_digest" => Map.get(selection.source_snapshot, :digest),
      "station_stop_id" => selection.station_stop_id,
      "run_id" => run.id,
      "base_source_files" => base_source_files(run.source_manifest),
      "import_digest" => run_digest,
      "observations" => observations["observations"],
      "requested" => ids
    })
  end

  defp selection_evidence(selection, run, result, input_digest) do
    counts = result["counts"]

    %{
      kind: "station_import_selection",
      title: "Accepted width decisions prepared for review",
      total: counts["selected"],
      total_label: "complete matching decisions prepared for native review",
      completeness: :complete,
      source_ref: @source_ref,
      digest: input_digest,
      source_revision: nil,
      scope: scope_field(selection),
      exclusions: selection_exclusions(counts, result),
      resources: import_resources(selection, run),
      facts: [
        %{label: "Run state", value: to_string(run.state)},
        %{label: "Requested", value: counts["requested"]},
        %{label: "Prepared", value: counts["selected"]},
        %{label: "Unresolved", value: counts["unresolved"]},
        %{label: "Not this station", value: counts["excluded"]},
        %{label: "Already approved here", value: counts["existing_approved"]},
        %{label: "Accepted observations", value: counts["observations"]["accepted"]}
      ]
    }
  end

  defp selection_exclusions(counts, result) do
    labels =
      result["unresolved"]
      |> Enum.frequencies_by(& &1["reason"])
      |> Enum.sort()
      |> Enum.map(fn {reason, count} -> "#{count} decisions unresolved as #{reason}" end)

    labels ++
      if counts["existing_approved"] > 0 do
        [
          "#{counts["existing_approved"]} decisions in this station are already approved and are never selected implicitly"
        ]
      else
        []
      end
  end

  defp selection_notes do
    [
      "This is a preparation, not an approval. No decision status, run metadata, GTFS row or journal entry was changed.",
      "Only a complete min_width-only pending pathway change whose uploaded value equals an accepted measurement exactly can be prepared.",
      "A width acceptance never carries an accompanying endpoint, direction or other edit into the prepared set.",
      "A mismatched uploaded value is reported, never rewritten; correct the upload and compute again instead."
    ]
  end

  ## Digests and time

  defp capture_time, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
