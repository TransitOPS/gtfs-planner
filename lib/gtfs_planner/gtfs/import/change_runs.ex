defmodule GtfsPlanner.Gtfs.Import.ChangeRuns do
  @moduledoc """
  Durable, fenced state transitions for organization/version-scoped change reviews.

  This context is the only owner of `gtfs_change_runs` lifecycle fields. Workers
  receive a generation and opaque token at claim time; all later worker writes
  check both against PostgreSQL time before they can alter durable review state.

  Requests made by a user (`create_pending_compute/4,5`, `request_apply/3`,
  `request_cancel/3`, `retry/3`, `start_over/3`) reauthorize that user inside their
  transaction, taking the run row first and the user's editor membership next
  (INV-1). A refused user gets `{:error, :forbidden}` and the run is unchanged.
  `request_apply/3` and a partial-run `retry/3` also record the requesting user as the
  run's actor, because that actor is reauthorized for every decision the worker
  applies and named in its change log.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Import.ChangeArtifactStorage
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRunReview
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @type actor :: %{required(:id) => Ecto.UUID.t(), required(:email) => String.t()}
  @type staged_file :: %{required(:name) => String.t(), required(:size) => non_neg_integer()}

  @lease_seconds Application.compile_env(:gtfs_planner, :change_run_lease_seconds, 300)
  @terminal_states [:partial, :completed, :failed, :interrupted, :cancelled, :expired]
  @decision_statuses [:pending, :approved, :rejected, :preview, :applied, :failed, :stale]
  # A confirmation names at most one bounded page of decisions, the same page a
  # prepared selection can hold.
  @max_confirmed_decisions 100
  @approved_decision_statuses [:approved, :applied]
  @decision_actions [:add, :modify, :remove, :conflict]
  @started_over_code "started_over"

  @spec create_pending_compute(Ecto.UUID.t(), Ecto.UUID.t(), actor(), [staged_file()]) ::
          {:ok, ChangeRun.t()} | {:error, term()}
  def create_pending_compute(organization_id, gtfs_version_id, actor, staged_files)
      when is_list(staged_files) do
    create_pending_compute(organization_id, gtfs_version_id, actor, staged_files, nil)
  end

  def create_pending_compute(_, _, _, _), do: {:error, :invalid_staged_files}

  @doc """
  Creates a pending run with a preallocated ID for immutable file staging.

  Returns `{:error, :forbidden}` without creating or returning a run when `actor` no
  longer has an active editor membership in the organization.
  """
  @spec create_pending_compute(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          actor(),
          [staged_file()],
          Ecto.UUID.t() | nil
        ) ::
          {:ok, ChangeRun.t()} | {:error, term()}
  def create_pending_compute(organization_id, gtfs_version_id, actor, staged_files, run_id)
      when is_list(staged_files) and (is_nil(run_id) or is_binary(run_id)) do
    transaction_with_broadcast(fn ->
      if version_in_scope?(organization_id, gtfs_version_id) do
        create_pending_in_scope(organization_id, gtfs_version_id, actor, staged_files, run_id)
      else
        {{:error, :not_found}, []}
      end
    end)
  end

  def create_pending_compute(_, _, _, _, _), do: {:error, :invalid_staged_files}

  # The scope advisory lock and the active run row come first, then the actor's membership
  # (INV-1), so a refused actor neither adopts the active run nor inserts one.
  defp create_pending_in_scope(organization_id, gtfs_version_id, actor, staged_files, run_id) do
    lock_scope(organization_id, gtfs_version_id)
    active = lock_active_run(organization_id, gtfs_version_id)
    lock_actor!(organization_id, actor)

    case active do
      %ChangeRun{} = run -> {{:ok, run}, []}
      nil -> insert_pending_compute(organization_id, gtfs_version_id, actor, staged_files, run_id)
    end
  end

  defp insert_pending_compute(organization_id, gtfs_version_id, actor, staged_files, run_id) do
    attrs = %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      actor_id: actor.id,
      actor_email: actor.email,
      state: :pending_compute,
      phase: :staging,
      source_manifest: %{
        files: staged_files,
        total_bytes: Enum.sum(Enum.map(staged_files, &Map.get(&1, :size, 0)))
      },
      serializer_version: ChangeDecisionSerializer.serializer_version()
    }

    run = if is_nil(run_id), do: %ChangeRun{}, else: %ChangeRun{id: run_id}

    case Repo.insert(ChangeRun.system_changeset(run, attrs)) do
      {:ok, run} -> {{:ok, run}, [run.id]}
      {:error, changeset} -> {{:error, changeset}, []}
    end
  end

  @spec claim(Ecto.UUID.t(), Ecto.UUID.t(), :compute | :apply) ::
          {:ok, ChangeRun.t(), pos_integer(), Ecto.UUID.t()} | {:error, term()}
  def claim(organization_id, run_id, operation) when operation in [:compute, :apply] do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        nil -> {{:error, :not_found}, []}
        run -> claim_locked_run(run, organization_id, operation)
      end
    end)
  end

  def claim(_, _, _), do: {:error, :invalid_operation}

  defp claim_locked_run(run, organization_id, operation) do
    if claimable?(run, operation) do
      persist_claim(run, organization_id, operation)
    else
      {{:error, :invalid_transition}, []}
    end
  end

  defp persist_claim(run, organization_id, operation) do
    generation = run.lease_generation + 1
    token = Ecto.UUID.generate()
    state = if operation == :compute, do: :computing, else: :applying
    phase = if operation == :compute, do: :parsing, else: :applying

    {1, _} =
      from(r in ChangeRun,
        where: r.id == ^run.id and r.organization_id == ^organization_id,
        update: [
          set: [
            state: ^state,
            phase: ^phase,
            lease_generation: ^generation,
            lease_token: ^token,
            lease_expires_at:
              fragment("CURRENT_TIMESTAMP + (? * interval '1 second')", ^@lease_seconds),
            started_at: fragment("COALESCE(?, CURRENT_TIMESTAMP)", r.started_at),
            updated_at: fragment("CURRENT_TIMESTAMP")
          ]
        ]
      )
      |> Repo.update_all([])

    claimed = Repo.get!(ChangeRun, run.id)
    {{:ok, claimed, generation, token}, [run.id]}
  end

  @spec renew_lease(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t()) ::
          :ok | {:error, :lease_lost}
  def renew_lease(organization_id, run_id, generation, token) do
    transaction_with_broadcast(fn ->
      case fenced_run(organization_id, run_id, generation, token, [:computing, :applying]) do
        {:ok, run} ->
          {1, _} =
            from(r in ChangeRun,
              where:
                r.id == ^run.id and r.organization_id == ^organization_id and
                  r.lease_generation == ^generation and r.lease_token == ^token and
                  is_nil(r.cancel_requested_at) and
                  r.lease_expires_at >= fragment("CURRENT_TIMESTAMP"),
              update: [
                set: [
                  lease_expires_at:
                    fragment("CURRENT_TIMESTAMP + (? * interval '1 second')", ^@lease_seconds),
                  updated_at: fragment("CURRENT_TIMESTAMP")
                ]
              ]
            )
            |> Repo.update_all([])

          {:ok, []}

        {:error, _} ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

  @spec persist_review(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), map()) ::
          {:ok, ChangeRun.t()} | {:error, term()}
  def persist_review(organization_id, run_id, generation, token, review) when is_map(review) do
    transaction_with_broadcast(fn ->
      with {:ok, run} <- fenced_run(organization_id, run_id, generation, token, [:computing]),
           {:ok, decisions} <- review_decisions(review),
           :ok <- insert_decisions(run.id, decisions),
           {:ok, review_run} <- close_review(run, review) do
        {{:ok, review_run}, [run.id]}
      else
        {:error, :lease_lost} -> {{:error, :lease_lost}, []}
        {:error, reason} -> {{:error, reason}, []}
      end
    end)
  end

  def persist_review(_, _, _, _, _), do: {:error, :invalid_review}

  @doc "Closes a fenced compute attempt without allowing a stale executor to overwrite a newer lease."
  @spec fail_compute(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), String.t()) ::
          {:ok, ChangeRun.t()} | {:error, :lease_lost}
  def fail_compute(organization_id, run_id, generation, token, code) when is_binary(code) do
    transaction_with_broadcast(fn ->
      organization_id
      |> lock_run(run_id)
      |> fail_locked_compute(generation, token, code)
    end)
  end

  defp fail_locked_compute(
         %ChangeRun{state: :computing, lease_generation: generation, lease_token: token} = run,
         generation,
         token,
         code
       ) do
    if lease_current?(run.id), do: close_failed_compute(run, code), else: lease_lost()
  end

  defp fail_locked_compute(_run, _generation, _token, _code), do: lease_lost()

  defp close_failed_compute(run, code) do
    state = if is_nil(run.cancel_requested_at), do: :failed, else: :cancelled

    attrs = %{
      state: state,
      phase: :cleanup,
      lease_token: nil,
      lease_expires_at: nil,
      failure_code: String.slice(code, 0, 128),
      finished_at: DateTime.utc_now()
    }

    update_closed_run(run, attrs)
  end

  @doc """
  Closes a pending run whose runner was refused because the supervisor was at
  capacity (`ChangeRunner.start_compute/4` or `start_apply/4` returned
  `{:error, :busy}`).

  `generation` is the run's `lease_generation` when the caller started it. A
  `pending_compute` or `pending_apply` run still at that generation was never
  claimed; it becomes `failed` with `failure_code` `busy`. A run that was claimed,
  closed or cancelled in the meantime returns `{:error, :invalid_transition}` and
  nothing changes. The staged files and any decisions stay, so `retry/3` can run
  the review again. This is a system closure and does not reauthorize the actor.
  """
  @spec fail_unstarted(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, ChangeRun.t()} | {:error, :not_found | :invalid_transition}
  def fail_unstarted(organization_id, run_id, generation) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        nil -> {{:error, :not_found}, []}
        run -> close_unstarted(run, generation)
      end
    end)
  end

  defp close_unstarted(
         %ChangeRun{state: state, lease_generation: generation, cancel_requested_at: nil} = run,
         generation
       )
       when state in [:pending_compute, :pending_apply] do
    now = DateTime.utc_now()

    attrs = %{
      state: :failed,
      phase: :cleanup,
      failure_code: "busy",
      started_at: run.started_at || now,
      finished_at: now
    }

    {:ok, failed} = Repo.update(ChangeRun.system_changeset(run, attrs))
    {{:ok, failed}, [run.id]}
  end

  defp close_unstarted(_run, _generation), do: {{:error, :invalid_transition}, []}

  @spec set_decision_status(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), :approved | :rejected) ::
          {:ok, ChangeDecision.t()} | {:error, term()}
  def set_decision_status(organization_id, run_id, decision_id, status)
      when is_binary(decision_id) and status in [:approved, :rejected] do
    transaction_with_broadcast(fn ->
      with %ChangeRun{state: :review} = run <- lock_run(organization_id, run_id),
           %ChangeDecision{} = decision <- lock_decision(run.id, decision_id),
           true <-
             decision.status in [:pending, :approved, :rejected] and decision.status != status,
           {:ok, updated} <-
             Repo.update(ChangeDecision.system_changeset(decision, %{status: status})) do
        {{:ok, updated}, [run.id]}
      else
        nil -> {{:error, :not_found}, []}
        %ChangeRun{} -> {{:error, :invalid_transition}, []}
        false -> {{:error, :invalid_transition}, []}
        {:error, changeset} -> {{:error, changeset}, []}
      end
    end)
  end

  def set_decision_status(_, _, _, _), do: {:error, :invalid_decision_status}

  @doc """
  Confirms selected native decisions and their captured provenance atomically.

  This is the only writer for a prepared accepted-width selection, and it is
  native-only: nothing a model, tool argument or client payload names reaches it.
  The station, the run and the accepted observations come from `frozen_source`,
  the server-frozen `station_imports` source snapshot a host read through
  `GtfsPlanner.Agents.Scope.source_snapshot/1`; the organization, version and
  actor come from the server context calling it (AC-1).

  `selection` is what a host shows staff before it asks: the run and station the
  selection was prepared for, the preparation's own `input_digest`, and the
  selected rows themselves, each carrying the `decision_digest` the projection
  gave that row:

      %{
        "run_id" => run_id,
        "station_stop_id" => station_stop_id,
        "input_digest" => input_digest,
        "decisions" => [%{"decision_id" => "pathway:PW_W14", "decision_digest" => digest}]
      }

  Every transaction attempt follows INV-1: the scoped run row is locked first, the
  actor's current editor membership is re-read next, and only then come the
  version, the decision rows and the stale comparison. A revoked membership, a
  run that is no longer in `:review`, another version's run, a changed source
  file, a changed decision value, a changed status or an observation the frozen
  snapshot no longer describes all refuse **every** selected write: the answer is
  `{:error, :forbidden}`, `:unavailable`, `:stale` or `:invalid_selection`, and
  the run, its manifest and every decision are exactly as they were.

  On success the selected decisions become `:approved` and one history entry per
  decision is appended to the run's `source_manifest` under `reviewed_evidence`,
  in the same transaction. The base source files and their total bytes are never
  rewritten. Reconfirming identical decision and source digests is idempotent: it
  approves nothing new and appends no history. A different confirmation appends,
  and no confirmation ever erases an earlier entry. At the history bound the
  confirmation is refused as `{:error, :evidence_limit}` before any status or
  manifest write, so the host keeps its draft (INV-1, AC-9).
  """
  @spec confirm_observation_selection(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          actor(),
          map(),
          map()
        ) ::
          {:ok, %{decisions: [ChangeDecision.t()], run: ChangeRun.t()}} | {:error, term()}
  def confirm_observation_selection(
        organization_id,
        gtfs_version_id,
        actor,
        frozen_source,
        selection
      )
      when is_map(frozen_source) and is_map(selection) and is_map(actor) do
    transaction_with_broadcast(fn ->
      with {:ok, source} <-
             ChangeRunReview.source(frozen_source, organization_id, gtfs_version_id, actor.id),
           {:ok, requested} <- requested_selection(selection, source),
           %ChangeRun{} = run <- lock_run(organization_id, source.run_id),
           _membership <- lock_actor!(organization_id, actor),
           :ok <- version_in_scope_for_confirmation(organization_id, gtfs_version_id),
           _version <- Versions.lock_for_input_write!(organization_id, gtfs_version_id),
           :ok <- confirmable_run(run, gtfs_version_id),
           {:ok, fresh, _evidence} <- ChangeRunReview.confirm_selection(source, requested.ids),
           {:ok, plan} <- confirmation_plan(run, source, requested, fresh, actor) do
        persist_confirmation(run, plan)
      else
        nil -> {{:error, :unavailable}, []}
        %ChangeRun{} = run -> {{:error, :unavailable}, [run.id]}
        {:error, reason} -> {{:error, reason}, []}
      end
    end)
  end

  def confirm_observation_selection(_, _, _, _, _), do: {:error, :invalid_selection}

  # The selection a host is confirming: the run and station it was prepared for,
  # the preparation's own digest, and at most 100 distinct decisions, each naming
  # the digest its projected row carried. Anything else is one invalid selection,
  # and no foreign run, station or decision is named back.
  defp requested_selection(selection, source) do
    rows = Map.get(selection, "decisions")
    ids = Enum.map(List.wrap(rows), &Map.get(&1, "decision_id"))

    valid? =
      is_list(rows) and rows != [] and length(rows) <= @max_confirmed_decisions and
        Enum.all?(rows, &requested_row?/1) and length(Enum.uniq(ids)) == length(ids) and
        selection_matches_source?(selection, source) and
        digest?(Map.get(selection, "input_digest"))

    if valid? do
      {:ok, %{ids: ids, input_digest: selection["input_digest"], rows: rows}}
    else
      {:error, :invalid_selection}
    end
  end

  defp requested_row?(row) when is_map(row) do
    is_binary(Map.get(row, "decision_id")) and
      byte_size(Map.get(row, "decision_id")) in 1..512 and
      digest?(Map.get(row, "decision_digest"))
  end

  defp requested_row?(_row), do: false

  # The selection must be the one this frozen source prepared, and the station it
  # names must be the station in that source.
  defp selection_matches_source?(selection, source) do
    Map.get(selection, "run_id") == source.run_id and
      case Map.get(selection, "station_stop_id") do
        nil -> true
        station_stop_id -> station_stop_id == source.station_stop_id
      end
  end

  defp digest?(value) when is_binary(value), do: value =~ ~r/\A[0-9a-f]{64}\z/
  defp digest?(_value), do: false

  defp confirmable_run(%ChangeRun{gtfs_version_id: version_id} = run, version_id)
       when run.kind == :station_diff and run.state == :review,
       do: :ok

  defp confirmable_run(_run, _version_id), do: {:error, :unavailable}

  # A version this organization does not hold is this command's one unavailable
  # refusal, checked before the version lock so a foreign or deleted version
  # discloses nothing at all (AC-1). The lock itself still runs inside the
  # transaction, after the run row and the membership, in the existing order.
  defp version_in_scope_for_confirmation(organization_id, gtfs_version_id) do
    if version_in_scope?(organization_id, gtfs_version_id),
      do: :ok,
      else: {:error, :unavailable}
  end

  # Each decision is confirmed now, already confirmed identically, or refused.
  # Nothing in between is approved, and a decision is never approved because
  # another one next to it was.
  defp confirmation_plan(run, source, requested, fresh, actor) do
    with {:ok, selected} <- freshly_selected(requested, fresh),
         {:ok, selected} <- refresh_decisions(run, selected),
         {:ok, confirmed} <- already_confirmed(run, source, requested, selected),
         :ok <- unchanged_inputs(fresh, requested, selected) do
      {:ok,
       %{
         decisions: Enum.map(selected, & &1.decision) ++ Enum.map(confirmed, & &1.decision),
         entries: Enum.map(selected, &evidence_entry(&1.row, run, source, actor))
       }}
    end
  end

  # Anything the fresh projection still selects is approved by this very
  # selection, so a preparation digest that no longer recomputes means the source,
  # the run or the decisions changed under the host. A reconfirmation that
  # approves nothing new recomputes nothing, so it is not stale for that reason.
  defp unchanged_inputs(fresh, requested, selected) do
    if selected == [] or fresh["input_digest"] == requested.input_digest,
      do: :ok,
      else: {:error, :stale}
  end

  # A freshly selected row must be exactly the row the host showed: same decision
  # id, same decision digest. A requested decision the fresh projection does not
  # select is left to `already_confirmed/5`, which tells an idempotent
  # reconfirmation apart from a refusal; only a row whose digest disagrees is a
  # stale request for a decision that is still selected under other values.
  defp freshly_selected(requested, fresh) do
    selected = Map.new(fresh["selected"], &{&1["decision_id"], &1})

    requested.rows
    |> Enum.reduce_while({:ok, []}, &freshly_selected_step(&1, &2, selected))
    |> reverse_result()
  end

  defp freshly_selected_step(row, {:ok, acc}, selected) do
    case Map.get(selected, row["decision_id"]) do
      %{"decision_digest" => decision_digest} = projected when is_map(projected) ->
        if decision_digest == row["decision_digest"] do
          {:cont, {:ok, [%{row: projected, request: row} | acc]}}
        else
          {:halt, {:error, :stale}}
        end

      _other ->
        {:cont, {:ok, acc}}
    end
  end

  # Each selected row is then locked, and it must still be pending: a decision
  # whose status changed while this transaction waited is stale, not approved.
  defp refresh_decisions(run, selected) do
    selected
    |> Enum.reduce_while({:ok, []}, &refresh_decision_step(&1, &2, run))
    |> reverse_result()
  end

  defp refresh_decision_step(entry, {:ok, acc}, run) do
    case lock_decision(run.id, entry.row["decision_id"]) do
      %ChangeDecision{status: :pending} = decision ->
        {:cont, {:ok, [Map.put(entry, :decision, decision) | acc]}}

      _other ->
        {:halt, {:error, :stale}}
    end
  end

  # A decision that is no longer selected but already carries this confirmation's
  # own decision, source and snapshot digests was confirmed by this very
  # selection, so reconfirming it writes nothing and adds no history. The same
  # decision approved by somebody else, with no matching evidence of ours, is
  # stale: this confirmation may not lend its provenance to somebody else's
  # approval.
  defp already_confirmed(run, source, requested, selected) do
    approved = Enum.map(selected, & &1.row["decision_id"])

    requested.rows
    |> Enum.reduce_while({:ok, []}, &already_confirmed_step(&1, &2, run, source, approved))
    |> reverse_result()
  end

  defp already_confirmed_step(row, {:ok, acc}, run, source, approved) do
    if row["decision_id"] in approved do
      {:cont, {:ok, acc}}
    else
      step_confirmed_decision(confirmed_decision(run, source, row), acc)
    end
  end

  defp step_confirmed_decision({:ok, decision}, acc),
    do: {:cont, {:ok, [%{decision: decision} | acc]}}

  defp step_confirmed_decision({:error, reason}, _acc), do: {:halt, {:error, reason}}

  defp reverse_result({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp reverse_result({:error, reason}), do: {:error, reason}

  defp confirmed_decision(run, source, row) do
    case lock_decision(run.id, row["decision_id"]) do
      %ChangeDecision{status: status} = decision when status in @approved_decision_statuses ->
        if matching_entry(run, row, source) do
          {:ok, decision}
        else
          {:error, :stale}
        end

      _other ->
        {:error, :invalid_selection}
    end
  end

  # The latest history entry for this decision that binds the same decision,
  # source and snapshot digests. A different binding is not a match: it is a
  # different observation, never a retroactive edit of this one.
  defp matching_entry(run, row, source) do
    run.source_manifest
    |> reviewed_manifest()
    |> reviewed_entries()
    |> Enum.find(fn entry ->
      entry["decision_id"] == row["decision_id"] and
        entry["decision_digest"] == row["decision_digest"] and
        entry["source_digest"] == ChangeRunReview.base_source_digest(run) and
        entry["snapshot_digest"] == source.source_snapshot.digest
    end)
  end

  # One history entry: what was measured, from which source, in which frozen
  # snapshot, by which editor, for which decision values. The journal body, its
  # photos, the actor's email and every storage key stay out of it (AC-13).
  defp evidence_entry(row, run, source, actor) do
    observation = Map.get(row, "observation") || %{}

    %{
      "decision_id" => row["decision_id"],
      "decision_digest" => row["decision_digest"],
      "source_digest" => ChangeRunReview.base_source_digest(run),
      "snapshot_digest" => source.source_snapshot.digest,
      "station_id" => source.station_id,
      "actor_id" => actor.id,
      "confirmed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "observations" => [
        %{
          "target" => %{"pathway_id" => row["natural_key"]},
          "field" => Map.get(observation, "field"),
          "original_value" => Map.get(observation, "original_value"),
          "normalized_value" => Map.get(observation, "normalized_value"),
          "unit" => Map.get(observation, "unit"),
          "meaning" => Map.get(observation, "meaning"),
          "captured_date" => Map.get(observation, "captured_date"),
          "source_ref" => Map.get(observation, "source_ref"),
          "source_revision" => Map.get(observation, "source_revision"),
          "source_digest" => Map.get(observation, "source_digest")
        }
      ]
    }
  end

  # The manifest first, then the statuses: either the whole confirmation lands or
  # neither does. The history bound is checked before the first write, so a full
  # history refuses with every selected decision still pending.
  defp persist_confirmation(run, plan) do
    case append_reviewed_evidence(run, plan.entries) do
      :ok -> approve_locked(run, plan.decisions)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp append_reviewed_evidence(_run, []), do: :ok

  defp append_reviewed_evidence(run, entries) do
    manifest = reviewed_manifest(run.source_manifest)
    limits = ChangeRun.reviewed_evidence_limits()
    namespace = %{"version" => 1, "entries" => reviewed_entries(manifest) ++ entries}
    updated = Map.put(manifest, "reviewed_evidence", namespace)

    if length(namespace["entries"]) <= limits.max_entries and
         Jason.encode!(namespace) |> byte_size() <= limits.max_bytes do
      case Repo.update(ChangeRun.system_changeset(run, %{source_manifest: updated})) do
        {:ok, _run} -> :ok
        {:error, _changeset} -> {:error, :invalid_reviewed_evidence}
      end
    else
      {:error, :evidence_limit}
    end
  end

  defp approve_locked(run, decisions) do
    Enum.reduce_while(decisions, {:ok, []}, fn decision, {:ok, acc} ->
      case Repo.update(ChangeDecision.system_changeset(decision, %{status: :approved})) do
        {:ok, approved} -> {:cont, {:ok, acc ++ [approved]}}
        {:error, _changeset} -> {:halt, {:error, :invalid_transition}}
      end
    end)
    |> case do
      {:ok, approved} ->
        reloaded = Repo.get!(ChangeRun, run.id)

        {{:ok, %{decisions: Enum.sort_by(approved, & &1.decision_id), run: reloaded}}, [run.id]}

      {:error, reason} ->
        {{:error, reason}, []}
    end
  end

  # The manifest tolerates a legacy map that never carried the namespace, and both
  # key conventions a stored manifest may use.
  defp reviewed_manifest(manifest) when is_map(manifest), do: manifest
  defp reviewed_manifest(_manifest), do: %{}

  defp reviewed_entries(manifest) do
    case manifest do
      %{"reviewed_evidence" => %{"entries" => entries}} when is_list(entries) -> entries
      %{reviewed_evidence: %{entries: entries}} when is_list(entries) -> entries
      _other -> []
    end
  end

  @doc false
  @spec approve_all(Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def approve_all(organization_id, run_id, action) when action in @decision_actions do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        %ChangeRun{state: :review} = run ->
          {count, _} =
            from(d in ChangeDecision,
              where:
                d.change_run_id == ^run.id and d.action == ^action and
                  d.status in [:pending, :rejected],
              update: [set: [status: :approved, updated_at: fragment("CURRENT_TIMESTAMP")]]
            )
            |> Repo.update_all([])

          {{:ok, count}, if(count > 0, do: [run.id], else: [])}

        nil ->
          {{:error, :not_found}, []}

        _run ->
          {{:error, :invalid_transition}, []}
      end
    end)
  end

  def approve_all(_, _, _), do: {:error, :invalid_decision_action}

  @doc """
  Moves a reviewed run to `:pending_apply` on behalf of `actor`.

  `actor` must hold an active editor membership, otherwise the result is
  `{:error, :forbidden}` and the run is unchanged. The run's actor becomes `actor`, so the
  worker reauthorizes, and the change log names, the user who asked for the apply.
  """
  @spec request_apply(Ecto.UUID.t(), Ecto.UUID.t(), actor()) ::
          {:ok, ChangeRun.t()} | {:error, term()}
  def request_apply(organization_id, run_id, actor) do
    transaction_with_broadcast(fn ->
      case lock_run_as_editor(organization_id, run_id, actor) do
        nil -> {{:error, :not_found}, []}
        %ChangeRun{state: :review} = run -> request_apply_for_review(run, actor)
        _run -> {{:error, :invalid_transition}, []}
      end
    end)
  end

  defp request_apply_for_review(run, actor) do
    if run.serializer_version == ChangeDecisionSerializer.serializer_version() do
      move_to_pending_apply(run, actor)
    else
      expire_incompatible_review(run)
    end
  end

  defp move_to_pending_apply(run, actor) do
    {:ok, pending} =
      Repo.update(
        ChangeRun.system_changeset(run, %{
          state: :pending_apply,
          phase: :preflight,
          progress_current: 0,
          progress_total: approved_decision_count(run.id),
          actor_id: actor.id,
          actor_email: actor.email
        })
      )

    {{:ok, pending}, [run.id]}
  end

  defp expire_incompatible_review(run) do
    {:ok, expired} =
      Repo.update(
        ChangeRun.system_changeset(run, %{
          state: :expired,
          phase: :cleanup,
          failure_code: "incompatible_review",
          finished_at: DateTime.utc_now()
        })
      )

    {{:error, :incompatible_review}, [expired.id]}
  end

  @doc """
  Applies one approved decision in its own mutation/audit/checkpoint transaction.

  The run's actor must still hold an active editor membership when the transaction
  starts; otherwise it returns `{:error, :forbidden}` and writes nothing.
  """
  @spec apply_decision(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          pos_integer(),
          Ecto.UUID.t(),
          AuditContext.t()
        ) ::
          {:ok, ChangeDecision.t()} | {:error, term()}
  def apply_decision(
        organization_id,
        run_id,
        decision_id,
        generation,
        token,
        %AuditContext{} = context
      )
      when is_binary(decision_id) do
    apply_decision_with_options(
      organization_id,
      run_id,
      decision_id,
      generation,
      token,
      context,
      []
    )
  end

  def apply_decision(_, _, _, _, _, _), do: {:error, :invalid_apply_decision}

  @doc false
  def apply_decision_with_hook(
        organization_id,
        run_id,
        decision_id,
        generation,
        token,
        %AuditContext{} = context,
        opts
      )
      when is_binary(decision_id) and is_list(opts) do
    # `:before_transaction` lets a test pause between decisions, after the previous one committed.
    with :ok <- invoke_step(opts, :before_transaction) do
      apply_decision_with_options(
        organization_id,
        run_id,
        decision_id,
        generation,
        token,
        context,
        opts
      )
    end
  end

  # Applying one decision publishes stop/pathway/level rows of the run's version, a combination
  # input, so the transaction follows INV-1: the fenced run row first (it also rechecks state,
  # lease and cancellation after the wait), then the run actor's editor membership `FOR SHARE`,
  # then the version `FOR SHARE`, then the decision and entity rows. The run is first because
  # lease renewal and `reconcile_expired/1` lock only the run row, and a run-owned
  # version-exclusive command takes its run before the version; locking the version first made
  # that pair a lock cycle. The actor comes from the locked run, never from the caller's audit
  # context, and `valid_audit_context?/2` then requires the context to match the run. A revoked
  # actor rolls back with `:forbidden`, so the worker stops without marking the decision failed.
  defp apply_decision_with_options(
         organization_id,
         run_id,
         decision_id,
         generation,
         token,
         context,
         opts
       ) do
    transaction_with_broadcast(fn ->
      with {:ok, run} <- fenced_run(organization_id, run_id, generation, token, [:applying]),
           _membership <-
             Authorization.lock_editor!(%{
               actor_id: run.actor_id,
               organization_id: run.organization_id
             }),
           _version <- Versions.lock_for_input_write!(run.organization_id, run.gtfs_version_id),
           :ok <- valid_audit_context?(run, context),
           %ChangeDecision{} = decision <- lock_decision(run.id, decision_id) do
        apply_or_return_decision(run, decision, generation, token, context, opts)
      else
        nil -> Repo.rollback(:not_found)
        {:error, :lease_lost} -> Repo.rollback(:lease_lost)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if closure_reference_violation?(e) do
        {:error, :pathway_in_use}
      else
        reraise(e, __STACKTRACE__)
      end
  end

  # Step-6 deletion boundary: a closure inserted after the apply precheck
  # trips the step-1 ON DELETE RESTRICT FK. The per-decision transaction has
  # already rolled back at this outer boundary, so only the named violation
  # maps to :pathway_in_use for the ChangeWorker mark_apply_failure flow.
  # The code allowlist covers both historic 23503 and the newer 23001
  # restrict_violation that ON DELETE RESTRICT now reports.
  defp closure_reference_violation?(%Ecto.ConstraintError{
         type: :foreign_key,
         constraint: constraint
       }),
       do: to_string(constraint) == "pathway_evolutions_pathway_fkey"

  defp closure_reference_violation?(%Postgrex.Error{postgres: postgres}),
    do:
      Map.get(postgres, :constraint) == "pathway_evolutions_pathway_fkey" and
        to_string(Map.get(postgres, :code)) in [
          "restrict_violation",
          "foreign_key_violation",
          "23001",
          "23503"
        ]

  defp closure_reference_violation?(_other), do: false

  defp apply_or_return_decision(_run, %ChangeDecision{status: :applied} = decision, _, _, _, _),
    do: {{:ok, decision}, []}

  defp apply_or_return_decision(run, decision, generation, token, context, opts),
    do: apply_locked_decision(run, decision, generation, token, context, opts)

  @doc false
  @spec applyable_decisions(Ecto.UUID.t(), Ecto.UUID.t()) :: [ChangeDecision.t()]
  def applyable_decisions(organization_id, run_id) do
    from(d in ChangeDecision,
      join: r in ChangeRun,
      on: r.id == d.change_run_id,
      where:
        d.change_run_id == ^run_id and r.organization_id == ^organization_id and
          d.status in [:approved, :failed],
      order_by: [asc: d.decision_id]
    )
    |> Repo.all()
  end

  @doc false
  @spec mark_apply_failure(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          pos_integer(),
          Ecto.UUID.t(),
          term()
        ) ::
          {:ok, ChangeDecision.t()} | {:error, :lease_lost | term()}
  def mark_apply_failure(organization_id, run_id, decision_id, generation, token, reason)
      when is_binary(decision_id) do
    transaction_with_broadcast(fn ->
      with {:ok, run} <- fenced_run(organization_id, run_id, generation, token, [:applying]),
           %ChangeDecision{} = decision <- lock_decision(run.id, decision_id),
           true <- decision.status in [:approved, :failed],
           {:ok, failed} <-
             Repo.update(
               ChangeDecision.system_changeset(decision, %{
                 status: failure_status(reason),
                 apply_failure_code: failure_code(reason)
               })
             ) do
        {{:ok, failed}, [run.id]}
      else
        {:error, :lease_lost} -> {{:error, :lease_lost}, []}
        nil -> {{:error, :not_found}, []}
        false -> {{:error, :invalid_transition}, []}
        {:error, reason} -> {{:error, reason}, []}
      end
    end)
  end

  @doc false
  @spec finish_apply(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t()) ::
          {:ok, ChangeRun.t()} | {:error, :lease_lost}
  def finish_apply(organization_id, run_id, generation, token) do
    transaction_with_broadcast(fn ->
      organization_id
      |> lock_run(run_id)
      |> finish_locked_apply(generation, token)
    end)
  end

  defp finish_locked_apply(
         %ChangeRun{state: :applying, lease_generation: generation, lease_token: token} = run,
         generation,
         token
       ) do
    if lease_current?(run.id), do: close_finished_apply(run), else: lease_lost()
  end

  defp finish_locked_apply(_run, _generation, _token), do: lease_lost()

  defp close_finished_apply(run) do
    summary = apply_summary(run.id, run.summary)
    state = terminal_apply_state(run, summary)

    update_closed_run(run, %{
      state: state,
      phase: :cleanup,
      lease_token: nil,
      lease_expires_at: nil,
      summary: summary,
      failure_code: if(state == :partial, do: "decision_failures", else: nil),
      finished_at: DateTime.utc_now()
    })
  end

  @doc false
  @spec fail_apply(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), String.t()) ::
          {:ok, ChangeRun.t()} | {:error, :lease_lost}
  def fail_apply(organization_id, run_id, generation, token, code) when is_binary(code) do
    transaction_with_broadcast(fn ->
      organization_id
      |> lock_run(run_id)
      |> fail_locked_apply(generation, token, code)
    end)
  end

  defp fail_locked_apply(
         %ChangeRun{state: :applying, lease_generation: generation, lease_token: token} = run,
         generation,
         token,
         code
       ) do
    if lease_current?(run.id), do: close_failed_apply(run, code), else: lease_lost()
  end

  defp fail_locked_apply(_run, _generation, _token, _code), do: lease_lost()

  defp close_failed_apply(run, code) do
    summary = apply_summary(run.id, run.summary)

    update_closed_run(run, %{
      state: failed_apply_state(run, summary),
      phase: :cleanup,
      lease_token: nil,
      lease_expires_at: nil,
      summary: summary,
      failure_code: String.slice(code, 0, 128),
      finished_at: DateTime.utc_now()
    })
  end

  defp update_closed_run(run, attrs) do
    case Repo.update(ChangeRun.system_changeset(run, attrs)) do
      {:ok, closed} -> {{:ok, closed}, [run.id]}
      {:error, _changeset} -> lease_lost()
    end
  end

  defp lease_lost, do: {{:error, :lease_lost}, []}

  @doc """
  Cancels a run that has not started work, or flags a running one for cancellation.

  `actor` must hold an active editor membership, otherwise the result is
  `{:error, :forbidden}` and the run is unchanged.
  """
  @spec request_cancel(Ecto.UUID.t(), Ecto.UUID.t(), actor()) ::
          {:ok, ChangeRun.t()} | {:error, term()}
  def request_cancel(organization_id, run_id, actor) do
    transaction_with_broadcast(fn ->
      case lock_run_as_editor(organization_id, run_id, actor) do
        nil ->
          {{:error, :not_found}, []}

        %ChangeRun{state: state, cancel_requested_at: nil} = run
        when state in [:computing, :applying] ->
          {1, _} =
            from(r in ChangeRun,
              where:
                r.id == ^run.id and r.organization_id == ^organization_id and
                  is_nil(r.cancel_requested_at),
              update: [
                set: [
                  cancel_requested_at: fragment("CURRENT_TIMESTAMP"),
                  updated_at: fragment("CURRENT_TIMESTAMP")
                ]
              ]
            )
            |> Repo.update_all([])

          {{:ok, Repo.get!(ChangeRun, run.id)}, [run.id]}

        %ChangeRun{state: state} = run
        when state in [:pending_compute, :review, :pending_apply] ->
          {1, _} =
            from(r in ChangeRun,
              where: r.id == ^run.id and r.organization_id == ^organization_id,
              update: [
                set: [
                  state: :cancelled,
                  phase: :cleanup,
                  cancel_requested_at: fragment("CURRENT_TIMESTAMP"),
                  started_at: fragment("COALESCE(?, CURRENT_TIMESTAMP)", r.started_at),
                  finished_at: fragment("CURRENT_TIMESTAMP"),
                  updated_at: fragment("CURRENT_TIMESTAMP")
                ]
              ]
            )
            |> Repo.update_all([])

          {{:ok, Repo.get!(ChangeRun, run.id)}, [run.id]}

        _run ->
          {{:error, :invalid_transition}, []}
      end
    end)
  end

  @doc """
  Returns a stopped run to the step that can continue it.

  `actor` must hold an active editor membership, otherwise the result is
  `{:error, :forbidden}` and the run is unchanged. A partial run goes back to
  `:pending_apply` under `actor`, so a run closed with `"forbidden"` can be applied by
  another editor.
  """
  @spec retry(Ecto.UUID.t(), Ecto.UUID.t(), actor()) :: {:ok, ChangeRun.t()} | {:error, term()}
  def retry(organization_id, run_id, actor) do
    case ChangeArtifactStorage.with_root_lock(fn ->
           retry_with_artifacts(organization_id, run_id, actor)
         end) do
      {:error, :artifact_storage_unavailable} ->
        retry_without_artifact_storage_transaction(organization_id, run_id, actor)

      result ->
        result
    end
  end

  defp retry_with_artifacts(organization_id, run_id, actor) do
    transaction_with_broadcast(fn -> retry_locked_run(organization_id, run_id, actor) end)
  end

  defp retry_without_artifact_storage_transaction(organization_id, run_id, actor) do
    transaction_with_broadcast(fn ->
      retry_without_artifact_storage(organization_id, run_id, actor)
    end)
  end

  defp retry_locked_run(organization_id, run_id, actor) do
    case lock_run_as_editor(organization_id, run_id, actor) do
      nil ->
        {{:error, :not_found}, []}

      %ChangeRun{state: :partial} = run ->
        retry_partial_run(run, actor)

      %ChangeRun{state: state} = run
      when state in [:failed, :interrupted, :cancelled, :expired] ->
        retry_terminal_run(run)

      _run ->
        {{:error, :invalid_transition}, []}
    end
  end

  defp retry_without_artifact_storage(organization_id, run_id, actor) do
    case lock_run_as_editor(organization_id, run_id, actor) do
      nil ->
        {{:error, :not_found}, []}

      %ChangeRun{state: :partial} = run ->
        retry_partial_run(run, actor)

      %ChangeRun{state: state}
      when state in [:failed, :interrupted, :cancelled, :expired] ->
        {{:error, :missing_or_corrupt_artifact}, []}

      _run ->
        {{:error, :invalid_transition}, []}
    end
  end

  defp retry_partial_run(run, actor) do
    {:ok, pending} =
      Repo.update(
        ChangeRun.system_changeset(run, %{
          state: :pending_apply,
          phase: :preflight,
          progress_current: 0,
          progress_total: retryable_decision_count(run.id),
          finished_at: nil,
          cancel_requested_at: nil,
          failure_code: nil,
          actor_id: actor.id,
          actor_email: actor.email
        })
      )

    {{:ok, pending}, [run.id]}
  end

  defp retry_terminal_run(run) do
    lock_scope(run.organization_id, run.gtfs_version_id)

    case lock_active_run(run.organization_id, run.gtfs_version_id) do
      nil -> persist_terminal_retry(run)
      %ChangeRun{} -> {{:error, :invalid_transition}, []}
    end
  end

  defp persist_terminal_retry(run) do
    decision_count =
      Repo.aggregate(from(d in ChangeDecision, where: d.change_run_id == ^run.id), :count)

    case retry_source_available(run, decision_count) do
      :ok -> update_terminal_retry(run, decision_count)
      {:error, reason} -> {{:error, reason}, []}
    end
  end

  defp retry_source_available(_run, decision_count) when decision_count > 0, do: :ok

  defp retry_source_available(run, _decision_count) do
    case ChangeArtifactStorage.read(run) do
      {:ok, _files} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_terminal_retry(run, decision_count) do
    case Repo.update(ChangeRun.system_changeset(run, retry_attrs(decision_count))) do
      {:ok, retry_run} -> {{:ok, retry_run}, [retry_run.id]}
      {:error, changeset} -> {{:error, changeset}, []}
    end
  end

  defp retry_attrs(decision_count) when decision_count > 0 do
    %{
      state: :review,
      phase: :diffing,
      progress_current: decision_count,
      progress_total: decision_count,
      lease_token: nil,
      lease_expires_at: nil,
      cancel_requested_at: nil,
      failure_code: nil,
      finished_at: nil
    }
  end

  defp retry_attrs(_decision_count) do
    %{
      state: :pending_compute,
      phase: :staging,
      progress_current: nil,
      progress_total: nil,
      lease_token: nil,
      lease_expires_at: nil,
      cancel_requested_at: nil,
      failure_code: nil,
      started_at: nil,
      finished_at: nil,
      serializer_version: ChangeDecisionSerializer.serializer_version()
    }
  end

  @doc """
  Retires a run that ended without completing so the version can review a new upload.

  The run becomes `:cancelled` with a marker that `latest_for_version/2` reads as "no run",
  so the page stays on the upload step after a reload. Decisions the run already applied
  stay applied; only its remaining review state is abandoned. `actor` must hold an active
  editor membership, otherwise the result is `{:error, :forbidden}` and the run is unchanged.
  """
  @spec start_over(Ecto.UUID.t(), Ecto.UUID.t(), actor()) ::
          {:ok, ChangeRun.t()} | {:error, term()}
  def start_over(organization_id, run_id, actor) do
    case transaction_with_broadcast(fn ->
           start_over_locked_run(organization_id, run_id, actor)
         end) do
      {:ok, run} = result ->
        _ = ChangeArtifactStorage.remove(organization_id, run.gtfs_version_id, run.id)
        result

      error ->
        error
    end
  end

  defp start_over_locked_run(organization_id, run_id, actor) do
    case lock_run_as_editor(organization_id, run_id, actor) do
      nil ->
        {{:error, :not_found}, []}

      %ChangeRun{state: state} = run when state in @terminal_states and state != :completed ->
        attrs = %{state: :cancelled, phase: :cleanup, failure_code: @started_over_code}

        case Repo.update(ChangeRun.system_changeset(run, attrs)) do
          {:ok, started_over} -> {{:ok, started_over}, [run.id]}
          {:error, changeset} -> {{:error, changeset}, []}
        end

      _run ->
        {{:error, :invalid_transition}, []}
    end
  end

  @spec get_for_version(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: ChangeRun.t() | nil
  def get_for_version(organization_id, gtfs_version_id, run_id) do
    from(r in ChangeRun,
      where:
        r.id == ^run_id and r.organization_id == ^organization_id and
          r.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  @doc """
  Returns the most recent durable review for one immutable route-version scope,
  or nil when that run was started over.
  """
  @spec latest_for_version(Ecto.UUID.t(), Ecto.UUID.t()) :: ChangeRun.t() | nil
  def latest_for_version(organization_id, gtfs_version_id) do
    from(r in ChangeRun,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      %ChangeRun{failure_code: @started_over_code} -> nil
      run -> run
    end
  end

  @spec list_decisions(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: [ChangeDecision.t()]
  def list_decisions(organization_id, run_id, opts \\ []) do
    query =
      from(d in ChangeDecision,
        join: r in ChangeRun,
        on: r.id == d.change_run_id,
        where: d.change_run_id == ^run_id and r.organization_id == ^organization_id,
        order_by: [asc: d.decision_id]
      )

    query
    |> maybe_filter_decisions(:status, Keyword.get(opts, :status), @decision_statuses)
    |> maybe_filter_decisions(:action, Keyword.get(opts, :action), @decision_actions)
    |> Repo.all()
  end

  @spec reconcile_expired(Ecto.UUID.t()) :: non_neg_integer()
  def reconcile_expired(organization_id) do
    transaction_with_broadcast(fn ->
      expired =
        from(r in ChangeRun,
          where: r.organization_id == ^organization_id and r.state in [:computing, :applying],
          where: r.lease_expires_at < fragment("CURRENT_TIMESTAMP"),
          lock: "FOR UPDATE"
        )
        |> Repo.all()

      ids =
        Enum.flat_map(expired, &reconcile_expired_run(&1, organization_id))

      {length(ids), ids}
    end)
  end

  defp reconcile_expired_run(run, organization_id) do
    state = if is_nil(run.cancel_requested_at), do: :interrupted, else: :cancelled

    {count, _} =
      from(r in ChangeRun,
        where:
          r.id == ^run.id and r.organization_id == ^organization_id and
            r.lease_generation == ^run.lease_generation and r.lease_token == ^run.lease_token and
            r.lease_expires_at < fragment("CURRENT_TIMESTAMP"),
        update: [
          set: [
            state: ^state,
            phase: :cleanup,
            lease_token: nil,
            lease_expires_at: nil,
            finished_at: fragment("CURRENT_TIMESTAMP"),
            failure_code: "lease_expired",
            updated_at: fragment("CURRENT_TIMESTAMP")
          ]
        ]
      )
      |> Repo.update_all([])

    if count == 1, do: [run.id], else: []
  end

  @spec topic(ChangeRun.t() | Ecto.UUID.t()) :: String.t()
  def topic(%ChangeRun{id: id}), do: topic(id)
  def topic(run_id) when is_binary(run_id), do: "change-run:" <> run_id

  defp transaction_with_broadcast(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, run_ids}} ->
        Enum.uniq(run_ids)
        |> Enum.each(
          &Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, topic(&1), {:change_run_changed, &1})
        )

        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_active_run(organization_id, gtfs_version_id) do
    from(r in ChangeRun,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: r.state not in ^@terminal_states,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp lock_scope(organization_id, gtfs_version_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [organization_id <> gtfs_version_id])
  end

  defp version_in_scope?(organization_id, gtfs_version_id) do
    from(v in GtfsVersion,
      where: v.id == ^gtfs_version_id and v.organization_id == ^organization_id
    )
    |> Repo.exists?()
  end

  defp lock_run(organization_id, run_id) do
    from(r in ChangeRun,
      where: r.id == ^run_id and r.organization_id == ^organization_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  # INV-1: the run row is locked first, then the requesting user's editor membership.
  # A missing run is `nil` before any membership is read.
  defp lock_run_as_editor(organization_id, run_id, actor) do
    case lock_run(organization_id, run_id) do
      nil ->
        nil

      run ->
        lock_actor!(organization_id, actor)
        run
    end
  end

  # Rolls the transaction back with `:forbidden` unless `actor` holds an active editor
  # membership in the organization.
  defp lock_actor!(organization_id, %{id: actor_id}),
    do: Authorization.lock_editor!(%{actor_id: actor_id, organization_id: organization_id})

  defp lock_decision(run_id, decision_id) do
    from(d in ChangeDecision,
      where: d.change_run_id == ^run_id and d.decision_id == ^decision_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp claimable?(%ChangeRun{state: :pending_compute, cancel_requested_at: nil}, :compute),
    do: true

  defp claimable?(%ChangeRun{state: :pending_apply, cancel_requested_at: nil}, :apply), do: true

  defp claimable?(%ChangeRun{state: state, cancel_requested_at: nil} = run, operation)
       when {state, operation} in [{:computing, :compute}, {:applying, :apply}] do
    lease_expired?(run.id)
  end

  defp claimable?(_, _), do: false

  defp fenced_run(organization_id, run_id, generation, token, expected_states) do
    case lock_run(organization_id, run_id) do
      %ChangeRun{} = run ->
        if run.state in expected_states and run.lease_generation == generation and
             run.lease_token == token and is_nil(run.cancel_requested_at) and
             lease_current?(run.id),
           do: {:ok, run},
           else: {:error, :lease_lost}

      nil ->
        {:error, :not_found}
    end
  end

  defp lease_current?(run_id) do
    from(r in ChangeRun,
      where: r.id == ^run_id and r.lease_expires_at >= fragment("CURRENT_TIMESTAMP")
    )
    |> Repo.exists?()
  end

  defp lease_expired?(run_id) do
    from(r in ChangeRun,
      where: r.id == ^run_id and r.lease_expires_at < fragment("CURRENT_TIMESTAMP")
    )
    |> Repo.exists?()
  end

  defp review_decisions(review) do
    case Map.fetch(review, :decisions) do
      {:ok, decisions} when is_list(decisions) ->
        validate_review_decisions(decisions)

      _ ->
        {:error, :invalid_review}
    end
  end

  defp validate_review_decisions(decisions) do
    decisions
    |> Enum.reduce_while({:ok, []}, &validate_review_decision/2)
    |> reverse_review_decisions()
  end

  defp validate_review_decision(decision, {:ok, acc}) do
    decision
    |> ChangeDecisionSerializer.deserialize()
    |> serialize_review_decision(acc)
  end

  defp serialize_review_decision({:ok, deserialized}, acc) do
    case ChangeDecisionSerializer.serialize(deserialized) do
      {:ok, serialized} -> {:cont, {:ok, [serialized | acc]}}
      {:error, reason} -> invalid_review_decision(reason)
    end
  end

  defp serialize_review_decision({:error, reason}, _acc), do: invalid_review_decision(reason)

  defp serialize_review_decision(:error, _acc),
    do: invalid_review_decision(:invalid_serialized_decision)

  defp invalid_review_decision(reason), do: {:halt, {:error, {:invalid_decision, reason}}}

  defp reverse_review_decisions({:ok, decisions}), do: {:ok, Enum.reverse(decisions)}
  defp reverse_review_decisions(error), do: error

  defp insert_decisions(run_id, decisions) do
    Enum.reduce_while(decisions, :ok, fn decision, :ok ->
      attrs =
        decision
        |> Map.take([
          :decision_id,
          :entity_type,
          :action,
          :status,
          :natural_key,
          :current_values,
          :uploaded_values,
          :changed_fields,
          :dependency_keys,
          :current_fingerprint,
          :user_edited
        ])
        |> Map.put(:change_run_id, run_id)

      case Repo.insert(ChangeDecision.system_changeset(%ChangeDecision{}, attrs)) do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp close_review(run, review) do
    attrs = %{
      state: :review,
      phase: :diffing,
      lease_token: nil,
      lease_expires_at: nil,
      progress_current: length(review.decisions),
      progress_total: length(review.decisions),
      summary: Map.get(review, :summary, %{}),
      diagnostics: Map.get(review, :diagnostics, [])
    }

    case Repo.update(ChangeRun.system_changeset(run, attrs)) do
      {:ok, review_run} -> {:ok, review_run}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp applicable_decision?(%ChangeDecision{status: status}) when status in [:approved, :failed],
    do: :ok

  defp applicable_decision?(_), do: {:error, :invalid_transition}

  defp apply_locked_decision(run, decision, generation, token, audit_context, opts) do
    with :ok <- applicable_decision?(decision),
         :ok <- invoke_step(opts, :before_fingerprint),
         {:ok, current} <- current_entity(run, decision),
         :ok <- fingerprint_matches?(decision, current),
         :ok <- reviewed_binding_current?(run, decision),
         :ok <- dependencies_satisfied?(run, decision),
         :ok <- no_dependents?(run, decision),
         :ok <- invoke_step(opts, :before_mutation),
         {:ok, entity} <- apply_mutation(run, decision, current),
         :ok <- invoke_step(opts, :before_audit),
         {:ok, _audit} <- record_audit(run, decision, current, entity, audit_context),
         :ok <- invoke_step(opts, :before_checkpoint),
         {:ok, applied} <- checkpoint_decision(decision),
         :ok <- invoke_step(opts, :before_progress),
         {:ok, _run} <- increment_progress(run, generation, token) do
      {{:ok, applied}, [run.id]}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A decision a native confirmation captured provenance for is applied only
  # against the values, source, station and frozen observation that confirmation
  # recorded. The check reads the locked run's own manifest and the locked
  # decision, so it sees the same rows every later step of this transaction sees,
  # and it runs before any entity, audit or status write: a stale binding rolls
  # the transaction back with the ordinary failure path and the recorded evidence
  # stays exactly as it was.
  #
  # The captured snapshot digest is checked for presence and shape rather than
  # recomputed: the server-frozen snapshot is not persisted with the entry, and
  # the metadata explicitly records an immutable captured observation rather than
  # claiming current journal freshness (CR-3). The existing `current_fingerprint`
  # comparison continues to own live database drift.
  defp reviewed_binding_current?(run, decision) do
    case latest_reviewed_entry(run, decision.decision_id) do
      nil -> :ok
      entry -> binding_current?(run, decision, entry)
    end
  end

  # The last entry recorded for this decision is the one that binds the current
  # approval. An entry for another decision never speaks for this one.
  defp latest_reviewed_entry(run, decision_id) do
    run.source_manifest
    |> reviewed_manifest()
    |> reviewed_entries()
    |> Enum.reverse()
    |> Enum.find(&(&1["decision_id"] == decision_id))
  end

  defp binding_current?(run, decision, entry) do
    if entry["decision_digest"] == ChangeRunReview.confirmed_digest(decision) and
         entry["source_digest"] == ChangeRunReview.base_source_digest(run) and
         digest?(entry["snapshot_digest"]) and
         ChangeRunReview.station_attribution(
           run.organization_id,
           run.gtfs_version_id,
           entry["station_id"],
           decision
         ) do
      :ok
    else
      {:error, :stale_reviewed_evidence}
    end
  end

  defp current_entity(run, %ChangeDecision{
         action: :add,
         entity_type: type,
         natural_key: natural_key
       }) do
    case Gtfs.lock_import_entity(type, run.organization_id, run.gtfs_version_id, natural_key) do
      nil -> {:ok, nil}
      _entity -> {:error, :drifted}
    end
  end

  defp current_entity(run, %ChangeDecision{entity_type: type, natural_key: natural_key}) do
    case Gtfs.lock_import_entity(type, run.organization_id, run.gtfs_version_id, natural_key) do
      nil -> {:error, :drifted}
      entity -> {:ok, entity}
    end
  end

  defp fingerprint_matches?(%ChangeDecision{action: :add}, nil), do: :ok

  defp fingerprint_matches?(%ChangeDecision{current_fingerprint: nil}, _entity), do: :ok

  defp fingerprint_matches?(%ChangeDecision{} = decision, entity) do
    case ChangeDecisionSerializer.record_fingerprint(
           decision.entity_type,
           entity,
           Map.keys(decision.current_values)
         ) do
      {:ok, fingerprint} when fingerprint == decision.current_fingerprint -> :ok
      _ -> {:error, :drifted}
    end
  end

  defp dependencies_satisfied?(run, %ChangeDecision{dependency_keys: dependencies}) do
    if Enum.all?(dependencies, &dependency_satisfied?(run, &1)),
      do: :ok,
      else: {:error, :dependencies_unmet}
  end

  defp dependency_satisfied?(run, dependency) do
    case String.split(dependency, ":", parts: 2) do
      [type, natural_key] ->
        case dependency_entity_type(type) do
          entity_type when entity_type in [:level, :stop, :pathway] ->
            not is_nil(
              Gtfs.lock_import_entity(
                entity_type,
                run.organization_id,
                run.gtfs_version_id,
                natural_key
              )
            )

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp dependency_entity_type("level"), do: :level
  defp dependency_entity_type("stop"), do: :stop
  defp dependency_entity_type("pathway"), do: :pathway
  defp dependency_entity_type(_), do: :unknown

  # A removal never cascades: stop times, transfers and other records that name the stop or
  # level are outside a station review, so the decision fails while any of them remain. A
  # dependent removed earlier in this apply is already gone when this runs.
  defp no_dependents?(run, %ChangeDecision{action: :remove} = decision) do
    dependents =
      Gtfs.import_dependent_counts(
        decision.entity_type,
        run.organization_id,
        run.gtfs_version_id,
        [decision.natural_key]
      )

    if dependents == %{}, do: :ok, else: {:error, :has_dependents}
  end

  defp no_dependents?(_run, _decision), do: :ok

  defp apply_mutation(run, decision, current) do
    attrs =
      decision.uploaded_values
      |> atomize_allowed_keys()
      |> Map.merge(identity_attrs(run, decision))

    Gtfs.apply_import_entity(decision.action, decision.entity_type, current, attrs)
  end

  defp identity_attrs(run, %ChangeDecision{entity_type: :level, natural_key: natural_key}),
    do: %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      level_id: natural_key
    }

  defp identity_attrs(run, %ChangeDecision{entity_type: :stop, natural_key: natural_key}),
    do: %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      stop_id: natural_key
    }

  defp identity_attrs(run, %ChangeDecision{entity_type: :pathway, natural_key: natural_key}),
    do: %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      pathway_id: natural_key
    }

  defp record_audit(run, decision, current, entity, audit_context) do
    action = audit_action(decision.action)

    context = %{
      audit_context
      | station_stop_id: station_scope(run, decision, current, entity)
    }

    attrs = Map.merge(decision.uploaded_values, identity_attrs(run, decision))
    Audit.record_change_in_transaction(context, decision.entity_type, current, action, attrs)
  end

  defp valid_audit_context?(run, %AuditContext{} = context) do
    if context.organization_id == run.organization_id and
         context.gtfs_version_id == run.gtfs_version_id and context.actor_id == run.actor_id and
         context.actor_email == run.actor_email,
       do: :ok,
       else: {:error, :invalid_audit_context}
  end

  defp station_scope(_run, %ChangeDecision{entity_type: :stop}, current, entity) do
    stop = entity || current
    Map.get(stop, :parent_station) || Map.get(stop, :stop_id)
  end

  defp station_scope(run, %ChangeDecision{entity_type: :pathway}, current, entity) do
    pathway = entity || current
    stop_id = Map.get(pathway, :from_stop_id) || Map.get(pathway, :to_stop_id)

    case Gtfs.lock_import_entity(:stop, run.organization_id, run.gtfs_version_id, stop_id) do
      nil -> nil
      stop -> Map.get(stop, :parent_station) || Map.get(stop, :stop_id)
    end
  end

  defp station_scope(
         run,
         %ChangeDecision{entity_type: :level, natural_key: level_id},
         _current,
         _entity
       ) do
    from(stop in GtfsPlanner.Gtfs.Stop,
      where:
        stop.organization_id == ^run.organization_id and
          stop.gtfs_version_id == ^run.gtfs_version_id and stop.level_id == ^level_id,
      order_by: [asc: stop.stop_id],
      limit: 1,
      select: {stop.parent_station, stop.stop_id}
    )
    |> Repo.one()
    |> case do
      {parent_station, stop_id} -> parent_station || stop_id
      nil -> nil
    end
  end

  defp audit_action(:add), do: "created"
  defp audit_action(:remove), do: "deleted"
  defp audit_action(_), do: "updated"

  defp checkpoint_decision(decision) do
    Repo.update(
      ChangeDecision.system_changeset(decision, %{
        status: :applied,
        apply_failure_code: nil,
        applied_at: DateTime.utc_now()
      })
    )
  end

  defp increment_progress(run, generation, token) do
    case Repo.update(
           ChangeRun.system_changeset(run, %{
             progress_current: min(run.progress_current + 1, run.progress_total)
           })
         ) do
      {:ok, %ChangeRun{lease_generation: ^generation, lease_token: ^token} = updated} ->
        {:ok, updated}

      {:ok, _} ->
        {:error, :lease_lost}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp apply_summary(run_id, previous_summary) do
    counts =
      from(d in ChangeDecision,
        where: d.change_run_id == ^run_id,
        group_by: d.status,
        select: {d.status, count(d.id)}
      )
      |> Repo.all()
      |> Map.new()

    previous_summary
    |> Map.put("applied", Map.get(counts, :applied, 0))
    |> Map.put("failed", Map.get(counts, :failed, 0) + Map.get(counts, :stale, 0))
    |> Map.put("unapplied", Map.get(counts, :approved, 0))
  end

  defp approved_decision_count(run_id) do
    from(d in ChangeDecision,
      where: d.change_run_id == ^run_id and d.status == :approved,
      select: count(d.id)
    )
    |> Repo.one()
  end

  defp retryable_decision_count(run_id) do
    from(d in ChangeDecision,
      where: d.change_run_id == ^run_id and d.status in [:approved, :failed],
      select: count(d.id)
    )
    |> Repo.one()
  end

  defp terminal_apply_state(%ChangeRun{cancel_requested_at: value}, _summary)
       when not is_nil(value),
       do: :cancelled

  defp terminal_apply_state(_run, summary) do
    if Map.get(summary, "failed", 0) > 0, do: :partial, else: :completed
  end

  defp failed_apply_state(%ChangeRun{cancel_requested_at: value}, _summary)
       when not is_nil(value),
       do: :cancelled

  defp failed_apply_state(_run, %{"applied" => applied}) when applied > 0, do: :partial
  defp failed_apply_state(_run, _summary), do: :interrupted

  defp failure_code(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.slice(0, 128)

  defp failure_code(reason) when is_binary(reason), do: String.slice(reason, 0, 128)
  defp failure_code(_reason), do: "apply_failed"
  defp failure_status(:drifted), do: :stale
  # A captured binding that no longer describes this decision is stale for the
  # same reason a drifted record is: what would be applied is not what was
  # reviewed. It is a separate code so a host can say which one happened.
  defp failure_status(:stale_reviewed_evidence), do: :stale
  defp failure_status(_reason), do: :failed

  defp invoke_step(opts, step) do
    case Keyword.get(opts, :on_step) do
      fun when is_function(fun, 1) -> fun.(step)
      _ -> :ok
    end
  end

  defp atomize_allowed_keys(values) do
    Enum.reduce(values, %{}, fn {key, value}, attrs ->
      case key do
        key when is_atom(key) ->
          Map.put(attrs, key, value)

        key when is_binary(key) ->
          try do
            Map.put(attrs, String.to_existing_atom(key), value)
          rescue
            ArgumentError -> attrs
          end
      end
    end)
  end

  defp maybe_filter_decisions(query, _field, nil, _allowed), do: query

  defp maybe_filter_decisions(query, :status, status, allowed) do
    if status in allowed, do: where(query, [d], d.status == ^status), else: where(query, false)
  end

  defp maybe_filter_decisions(query, :action, action, allowed) do
    if action in allowed, do: where(query, [d], d.action == ^action), else: where(query, false)
  end

  defp maybe_filter_decisions(query, _field, _value, _allowed), do: where(query, false)
end
