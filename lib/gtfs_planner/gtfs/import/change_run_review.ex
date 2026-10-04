defmodule GtfsPlanner.Gtfs.Import.ChangeRunReview do
  @moduledoc """
  The station-scoped, read-only projection of one computed native change run.

  This is the half of the station assistance slice that describes an import:
  `import_review/2` reads the diff of one computed run as it stands, and
  `normalize_observations/2` and `prepare_import_selection/2` turn the field
  observations staff already accepted into a **prepared** review selection.

      GtfsPlanner.Gtfs.StationAssistant
        └── ChangeRunReview          (this module: reads and preparation)
              └── ChangeRuns        (the only owner of run and decision writes)

  The split is deliberate. `StationAssistant` builds a selection from a
  `GtfsPlanner.Agents.Scope` and authorizes it; the native confirmation in
  `ChangeRuns` builds the same selection from a server-frozen source snapshot and
  must recompute the very same answer inside its own transaction before it can
  approve anything. Both sides therefore project through this one module instead
  of keeping a second copy of the projection, so a prepared selection can never
  describe a different station membership, digest or status than the confirmation
  that checks it (CL-5).

  Three rules hold for everything here:

    * **Reading is never writing.** No function below approves, rejects, prepares
      or applies a decision, and none changes the run, its manifest or any GTFS
      row (INV-2). Preparation is a prepared selection; only
      `ChangeRuns.confirm_observation_selection/5` may approve.
    * **The observations are the server's.** They come from the frozen source
      snapshot, never from a caller, and their recorded digest must still match
      the snapshot's own envelope.
    * **One answer per snapshot.** `import_review/2`,
      `normalize_observations/2` and `prepare_import_selection/2` read through one
      repeatable-read snapshot. `confirm_selection/2` is the same projection
      without its own transaction, for a caller that already owns one.

  ## Selection and bounds

  Only decisions wholly attributable to the selected station are projected, and
  every excluded decision is counted rather than projected. A page holds at most
  #{100} rows, and the encoded result plus evidence stays inside the existing
  32 KiB tool limit through `GtfsPlanner.Gtfs.StationAnswer`.
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationAnswer
  alias GtfsPlanner.Gtfs.StationJournal
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  import Ecto.Query

  @source_kind "station_imports"
  @source_ref "gtfs_station_assistant"

  @max_rows 100
  # The only status and live fingerprint state a captured confirmation can record:
  # it approves pending, unmodified, fingerprint-matched decisions and nothing else.
  @confirmed_status "pending"
  @confirmed_fingerprint_state "match"
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
  # A measurement is a plain number: at most 12 significant digits with its
  # exponent within +-12. Nothing a person writes down needs more, and a parsed
  # exponent is never expanded into digits before it is checked against this.
  @max_value_coefficient 1_000_000_000_000
  @max_value_exponent 12

  # A computed review and everything that follows it: the run holds decisions a
  # station may read. A pending compute, a computing run, a failure, a
  # cancellation or an expiry holds none.
  @computed_review_states [:review, :pending_apply, :applying, :partial, :completed]
  @approved_statuses [:approved, :applied]

  @typedoc "One station/run selection, built by a host or by the native confirmation."
  @type selection :: StationAnswer.selection()

  @typedoc "Why a read refused, before any recorded row was disclosed."
  @type error ::
          :forbidden | :unavailable | :no_selected_run | :no_computed_review | :invalid_selection

  @doc """
  Projects the recorded diff of the selection's computed run, scoped to its station.

  `offset` is a zero-based page start. The answer is a read: it never approves,
  rejects, prepares or applies a decision, and it never changes the run, its
  manifest or any status.
  """
  @spec import_review(selection(), non_neg_integer() | term()) ::
          {:ok, map(), map()} | {:error, error()}
  def import_review(selection, offset) do
    case page_offset(offset) do
      {:ok, offset} ->
        read_isolated(fn -> with_snapshot(selection, &import_answer(&1, offset)) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates and converts accepted field observations without persisting them.

  Only `min_width` measured as `minimum_clear_width` converts, through exact
  `Decimal` multiplication by 1, 0.01 or 0.001, so 105 cm is exactly 1.05 m. A
  malformed row, an unsupported unit, a nonpositive or unparseable value, a
  foreign journal reference, or two accepted rows that disagree about the same
  target fails **that row only**; the other measurements are still reported.
  """
  @spec normalize_observations(selection(), [map()]) :: {:ok, map(), map()} | {:error, error()}
  def normalize_observations(selection, observations) when is_list(observations) do
    with :ok <- observation_batch(observations),
         {:ok, run} <- scoped_run(selection) do
      normalized = normalize_rows(selection, observations)

      {:ok, normalized, observation_evidence(selection, run, normalized)}
    end
  end

  def normalize_observations(_selection, _observations), do: {:error, :invalid_selection}

  @doc """
  Prepares a native review selection from accepted observations, writing nothing.

  A decision is selected only when it is a pending `:modify` pathway whose
  complete changed-field set is exactly `min_width`, whose record still matches
  its stored fingerprint and was not hand-edited, whose dependencies are already
  natively approved or applied, and whose uploaded value equals the accepted
  measurement exactly. Everything else is reported with one reason and never
  repaired.

  Each selected row carries its own `decision_digest` over exactly the decision
  values it names, so a native confirmation can be asked to approve a specific
  set of decisions as they stood, and `input_digest` binds the frozen source
  snapshot, the run's base source files, the fresh import digest, the
  observations and the ids of the decisions it selects.
  """
  @spec prepare_import_selection(selection(), [String.t()]) ::
          {:ok, map(), map()} | {:error, error()}
  def prepare_import_selection(selection, decision_ids) when is_list(decision_ids) do
    with {:ok, ids} <- selection_ids(decision_ids) do
      read_isolated(fn -> with_snapshot(selection, &prepare_answer(&1, ids)) end)
    end
  end

  def prepare_import_selection(_selection, _decision_ids), do: {:error, :invalid_selection}

  @doc """
  The same preparation, projected inside a transaction the caller already owns.

  `ChangeRuns.confirm_observation_selection/5` holds the run row, the actor's
  membership and the version before it calls this, so it reads the run and its
  decisions under those locks instead of opening a second, read-only one. The
  answer is identical to `prepare_import_selection/2` for the same state.
  """
  @spec confirm_selection(selection(), [String.t()]) :: {:ok, map(), map()} | {:error, error()}
  def confirm_selection(selection, decision_ids) when is_list(decision_ids) do
    with {:ok, ids} <- selection_ids(decision_ids) do
      with_snapshot(selection, &prepare_answer(&1, ids))
    end
  end

  def confirm_selection(_selection, _decision_ids), do: {:error, :invalid_selection}

  @doc """
  The selection a server-frozen `station_imports` source snapshot describes.

  `frozen_source` is the envelope a host read through
  `GtfsPlanner.Agents.Scope.source_snapshot/1`: a `kind`, a string-key `payload`
  and the server's own `digest`. Only the organization, version and actor the
  native host already holds are taken from the caller's context; the station, the
  run and the observations come from that frozen payload, never from a tool
  argument (AC-1).
  """
  @spec source(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, selection()} | {:error, error()}
  def source(
        %{kind: @source_kind, payload: payload, digest: digest},
        organization_id,
        gtfs_version_id,
        actor_id
      )
      when is_map(payload) and is_binary(digest) do
    with true <- uuid?(organization_id) and uuid?(gtfs_version_id),
         station_stop_id when is_binary(station_stop_id) and station_stop_id != "" <-
           payload["station_stop_id"],
         {:ok, station_id} <- Ecto.UUID.cast(payload["station_id"]),
         {:ok, run_id} <- Ecto.UUID.cast(payload["change_run_id"]) do
      {:ok,
       %{
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id,
         station_id: station_id,
         station_stop_id: station_stop_id,
         run_id: run_id,
         actor_id: actor_id,
         source_snapshot: %{kind: @source_kind, payload: payload, digest: digest}
       }}
    else
      _other -> {:error, :unavailable}
    end
  end

  def source(_frozen_source, _organization_id, _gtfs_version_id, _actor_id),
    do: {:error, :unavailable}

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  @doc """
  Whether `run` is a computed station diff whose decisions this projection reads.

  A pending compute, a computing run, a failure or a cancellation holds no
  decisions a station could read, so a pack that checks its own precondition asks
  here rather than keeping a second copy of the state list.
  """
  @spec computed_review_run?(ChangeRun.t()) :: boolean()
  def computed_review_run?(%ChangeRun{kind: :station_diff, state: state}),
    do: state in @computed_review_states

  def computed_review_run?(_run), do: false

  @doc """
  The digest of a run's own base source files.

  The base files - their names, sizes and content hashes, and the total - are the
  part of a run's source that no decision status can change. A captured
  provenance entry binds this digest rather than the whole import digest, so
  recording evidence never invalidates the digest it records, and a later
  confirmation or a fenced apply of the same upload still matches it.
  """
  @spec base_source_digest(ChangeRun.t()) :: String.t()
  def base_source_digest(%ChangeRun{} = run) do
    StationAnswer.digest(base_source_files(run.source_manifest))
  end

  @doc """
  The digest of one projected decision row.

  It covers exactly the decision values a confirmation would approve: its
  identity, action, status, current and uploaded values, changed fields,
  dependencies, stored fingerprint, hand-edit flag and live fingerprint state. It
  deliberately does not cover the run's reviewed evidence, so recording evidence
  about a decision never invalidates that decision's own digest.
  """
  @spec decision_digest(map()) :: String.t()
  def decision_digest(row) do
    digest =
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
        "user_edited",
        "fingerprint_state"
      ])

    StationAnswer.digest(digest)
  end

  @doc """
  The digest a captured confirmation recorded for `decision`, recomputed from the
  persisted decision at apply time.

  A confirmation only ever captures a decision that is `:pending`, unmodified by
  hand and fingerprint-matched, so `status` and `fingerprint_state` are pinned to
  the values any capture necessarily had: apply legitimately moves the first and
  the second is what `current_fingerprint` already protects. Every other field is
  the decision's own persisted value, so a decision whose identity, current or
  uploaded values, changed fields, dependencies, stored fingerprint or hand-edit
  flag moved after the confirmation no longer recomputes to the recorded digest.
  """
  @spec confirmed_digest(ChangeDecision.t()) :: String.t()
  def confirmed_digest(%ChangeDecision{} = decision) do
    %{
      "decision_id" => decision.decision_id,
      "entity_type" => to_string(decision.entity_type),
      "natural_key" => decision.natural_key,
      "action" => to_string(decision.action),
      "status" => @confirmed_status,
      "current_values" => decision.current_values || %{},
      "uploaded_values" => decision.uploaded_values || %{},
      "changed_fields" => decision.changed_fields || [],
      "dependency_keys" => decision.dependency_keys || [],
      "current_fingerprint" => decision.current_fingerprint,
      "user_edited" => decision.user_edited == true,
      "fingerprint_state" => @confirmed_fingerprint_state
    }
    |> decision_digest()
  end

  @doc """
  Whether `decision` is wholly attributable to the station `station_id` names.

  The same projection rule the confirmation used, over the same scoped read, so an
  apply cannot accept a decision the confirmation itself would have excluded. A
  station outside this organization or version, or a station row that is not a
  top-level station, is no attribution at all.
  """
  @spec station_attribution(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t() | String.t() | nil,
          ChangeDecision.t()
        ) :: boolean()
  def station_attribution(
        organization_id,
        gtfs_version_id,
        station_id,
        %ChangeDecision{} = decision
      ) do
    with {:ok, station_id} <- Ecto.UUID.cast(station_id),
         %Stop{} = station <- scoped_station(organization_id, gtfs_version_id, station_id) do
      world =
        station_world(
          %{
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id,
            station_id: station.id,
            station_stop_id: station.stop_id
          },
          [decision]
        )

      station_attributed?(decision, world, station.stop_id)
    else
      _other -> false
    end
  end

  # One repeatable-read transaction per answer. A writer between two of this
  # module's reads is invisible to every part of the answer.
  defp read_isolated(fun) do
    Repo.transaction(
      fn ->
        StationAnswer.snapshot_module().begin_read()
        fun.()
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp page_offset(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}
  defp page_offset(_offset), do: {:error, :invalid_selection}

  # One snapshot of everything the answer describes: the run, its persisted
  # decisions, the current rows those decisions speak about and the stops this run
  # proposes. A writer between two reads cannot make the projected rows and the
  # reported counts describe different database states.
  #
  # `read_isolated/1` puts this behind one repeatable-read transaction for a read
  # answer. A caller that already owns a transaction - the native confirmation,
  # which has the run, membership and version locked - calls this directly, so the
  # same projection is read under those locks rather than through a second one.
  defp import_snapshot(selection) do
    with {:ok, station_snapshot} <-
           Gtfs.get_station_report_snapshot(
             selection.organization_id,
             selection.gtfs_version_id,
             selection.station_stop_id
           ),
         true <- StationAnswer.owned_station?(station_snapshot, selection) do
      read_run_snapshot(selection)
    else
      _other -> {:error, :unavailable}
    end
  end

  defp read_run_snapshot(selection) do
    case computed_run(selection) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> {:error, reason}
    end
  end

  # One caller-owned snapshot, or the one refusal that produced it.
  defp with_snapshot(selection, fun) do
    case import_snapshot(selection) do
      snapshot when is_map(snapshot) -> fun.(snapshot)
      {:error, reason} -> {:error, reason}
    end
  end

  # The run this selection names, read inside the organization's own version. A
  # foreign, deleted or uncomputed run is one refusal: this scope has no computed
  # review to read, whatever the run holds (AC-1).
  defp scoped_change_run(selection) do
    from(r in ChangeRun,
      where:
        r.id == ^selection.run_id and r.organization_id == ^selection.organization_id and
          r.gtfs_version_id == ^selection.gtfs_version_id
    )
    |> Repo.one()
  end

  defp run_decisions(organization_id, run_id) do
    from(d in ChangeDecision,
      join: r in ChangeRun,
      on: r.id == d.change_run_id,
      where: d.change_run_id == ^run_id and r.organization_id == ^organization_id,
      order_by: [asc: d.decision_id]
    )
    |> Repo.all()
  end

  # A foreign, deleted or uncomputed run is one refusal: this scope has no
  # computed review to read, whatever the run holds.
  defp computed_run(selection) do
    with {:ok, run} <- scoped_run(selection) do
      decisions = run_decisions(selection.organization_id, run.id)

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

  defp scoped_station(organization_id, gtfs_version_id, station_id) do
    from(s in Stop,
      where:
        s.id == ^station_id and s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and s.location_type == 1
    )
    |> Repo.one()
  end

  defp scoped_run(selection) do
    case scoped_change_run(selection) do
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
      "excluded" => Map.new(excluded, fn {reason, count} -> {to_string(reason), count} end),
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
    StationAnswer.digest(%{
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
      StationAnswer.shrink(
        result,
        "decisions",
        "returned_decisions",
        @import_narrowing_guidance,
        builder
      )

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
      scope: StationAnswer.scope_field(selection),
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
    |> Enum.uniq_by(&{&1["target"]["pathway_id"], &1["field"], &1["normalized_value"]})
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
      {%Decimal{coef: coef, exp: exp} = decimal, ""}
      when is_integer(coef) and coef < @max_value_coefficient and
             exp >= -@max_value_exponent and exp <= @max_value_exponent ->
        {:ok, {value, decimal}}

      # Infinity and NaN carry a non-integer coefficient, so they land here with
      # every value whose precision or exponent is out of bounds.
      _other ->
        {:error, :invalid_value}
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
        StationAnswer.digest(%{
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
      digest: StationAnswer.digest(normalized["observations"]),
      source_revision: nil,
      scope: StationAnswer.scope_field(selection),
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

    # Bound to the decisions that would be approved, so preparing again from
    # the stored selection recomputes the same digest even when other requested
    # decisions were left unresolved.
    selected_ids = Enum.map(selected, & &1["decision_id"])
    input_digest = input_digest(selection, run, run_digest, observations, selected_ids)

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
      selected = %{
        "decision_id" => row["decision_id"],
        "natural_key" => row["natural_key"],
        "action" => row["action"],
        "current_value" => row["current_values"]["min_width"],
        "uploaded_value" => row["uploaded_values"]["min_width"],
        "field" => @observation_field,
        "observation" => observation
      }

      # The digest is over the whole projected decision row, not over this
      # summary, so a native confirmation can be asked to approve exactly the
      # values this row named and refuse any other version of the decision.
      {:selected, Map.put(selected, "decision_digest", decision_digest(row))}
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

    if is_list(rows) and (is_nil(digest) or digest == StationAnswer.digest(rows)) do
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
    StationAnswer.digest(%{
      "source_snapshot_digest" => Map.get(selection.source_snapshot, :digest),
      "station_stop_id" => selection.station_stop_id,
      "run_id" => run.id,
      "base_source_files" => base_source_files(run.source_manifest),
      "import_digest" => run_digest,
      "observations" => observations["observations"],
      "selected" => ids
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
      scope: StationAnswer.scope_field(selection),
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
end
