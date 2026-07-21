defmodule GtfsPlanner.Gtfs.Import.ChangeRuns do
  @moduledoc """
  Durable, fenced state transitions for organization/version-scoped change reviews.

  This context is the only owner of `gtfs_change_runs` lifecycle fields. Workers
  receive a generation and opaque token at claim time; all later worker writes
  check both against PostgreSQL time before they can alter durable review state.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @type actor :: %{required(:id) => Ecto.UUID.t(), required(:email) => String.t()}
  @type staged_file :: %{required(:name) => String.t(), required(:size) => non_neg_integer()}

  @lease_seconds Application.compile_env(:gtfs_planner, :change_run_lease_seconds, 300)
  @terminal_states [:partial, :completed, :failed, :interrupted, :cancelled, :expired]
  @decision_statuses [:pending, :approved, :rejected, :preview, :applied, :failed, :stale]
  @decision_actions [:add, :modify, :remove, :conflict]

  @spec create_pending_compute(Ecto.UUID.t(), Ecto.UUID.t(), actor(), [staged_file()]) ::
          {:ok, ChangeRun.t()} | {:error, term()}
  def create_pending_compute(organization_id, gtfs_version_id, actor, staged_files)
      when is_list(staged_files) do
    create_pending_compute(organization_id, gtfs_version_id, actor, staged_files, nil)
  end

  def create_pending_compute(_, _, _, _), do: {:error, :invalid_staged_files}

  @doc "Creates a pending run with a preallocated ID for immutable file staging."
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
        lock_scope(organization_id, gtfs_version_id)

        case lock_active_run(organization_id, gtfs_version_id) do
          %ChangeRun{} = run ->
            {{:ok, run}, []}

          nil ->
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
      else
        {{:error, :not_found}, []}
      end
    end)
  end

  def create_pending_compute(_, _, _, _, _), do: {:error, :invalid_staged_files}

  @spec claim(Ecto.UUID.t(), Ecto.UUID.t(), :compute | :apply) ::
          {:ok, ChangeRun.t(), pos_integer(), Ecto.UUID.t()} | {:error, term()}
  def claim(organization_id, run_id, operation) when operation in [:compute, :apply] do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {{:error, :not_found}, []}

        run ->
          if claimable?(run, operation) do
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
          else
            {{:error, :invalid_transition}, []}
          end
      end
    end)
  end

  def claim(_, _, _), do: {:error, :invalid_operation}

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
      case lock_run(organization_id, run_id) do
        %ChangeRun{} = run
        when run.state == :computing and run.lease_generation == generation and
               run.lease_token == token ->
          state = if is_nil(run.cancel_requested_at), do: :failed, else: :cancelled

          attrs = %{
            state: state,
            phase: :cleanup,
            lease_token: nil,
            lease_expires_at: nil,
            failure_code: String.slice(code, 0, 128),
            finished_at: DateTime.utc_now()
          }

          case Repo.update(ChangeRun.system_changeset(run, attrs)) do
            {:ok, closed} -> {{:ok, closed}, [run.id]}
            {:error, _} -> {{:error, :lease_lost}, []}
          end

        _ ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

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

  @spec request_apply(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, ChangeRun.t()} | {:error, term()}
  def request_apply(organization_id, run_id) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {{:error, :not_found}, []}

        %ChangeRun{state: :review} = run ->
          if run.serializer_version == ChangeDecisionSerializer.serializer_version() do
            {:ok, pending} =
              Repo.update(
                ChangeRun.system_changeset(run, %{
                  state: :pending_apply,
                  phase: :preflight,
                  progress_current: 0,
                  progress_total: approved_decision_count(run.id)
                })
              )

            {{:ok, pending}, [run.id]}
          else
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

        _run ->
          {{:error, :invalid_transition}, []}
      end
    end)
  end

  @doc "Applies one approved decision in the caller-owned mutation/audit/checkpoint transaction."
  @spec apply_decision(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          pos_integer(),
          Ecto.UUID.t(),
          term()
        ) ::
          {:ok, ChangeDecision.t()} | {:error, term()}
  def apply_decision(organization_id, run_id, decision_id, generation, token, opts)
      when is_binary(decision_id) and is_list(opts) do
    transaction_with_broadcast(fn ->
      with {:ok, run} <- fenced_run(organization_id, run_id, generation, token, [:applying]),
           %ChangeDecision{} = decision <- lock_decision(run.id, decision_id) do
        case decision.status do
          :applied -> {{:ok, decision}, []}
          _ -> apply_locked_decision(run, decision, generation, token, opts)
        end
      else
        nil -> Repo.rollback(:not_found)
        {:error, :lease_lost} -> Repo.rollback(:lease_lost)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def apply_decision(_, _, _, _, _, _), do: {:error, :invalid_apply_decision}

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
      case lock_run(organization_id, run_id) do
        %ChangeRun{} = run
        when run.state == :applying and run.lease_generation == generation and
               run.lease_token == token ->
          if lease_current?(run.id) do
            summary = apply_summary(run.id, run.summary)
            state = terminal_apply_state(run, summary)

            attrs = %{
              state: state,
              phase: :cleanup,
              lease_token: nil,
              lease_expires_at: nil,
              summary: summary,
              failure_code: if(state == :partial, do: "decision_failures", else: nil),
              finished_at: DateTime.utc_now()
            }

            case Repo.update(ChangeRun.system_changeset(run, attrs)) do
              {:ok, closed} -> {{:ok, closed}, [run.id]}
              {:error, _} -> {{:error, :lease_lost}, []}
            end
          else
            {{:error, :lease_lost}, []}
          end

        _ ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

  @doc false
  @spec fail_apply(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), String.t()) ::
          {:ok, ChangeRun.t()} | {:error, :lease_lost}
  def fail_apply(organization_id, run_id, generation, token, code) when is_binary(code) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        %ChangeRun{} = run
        when run.state == :applying and run.lease_generation == generation and
               run.lease_token == token ->
          summary = apply_summary(run.id, run.summary)
          state = if is_nil(run.cancel_requested_at), do: :partial, else: :cancelled

          attrs = %{
            state: state,
            phase: :cleanup,
            lease_token: nil,
            lease_expires_at: nil,
            summary: summary,
            failure_code: String.slice(code, 0, 128),
            finished_at: DateTime.utc_now()
          }

          case Repo.update(ChangeRun.system_changeset(run, attrs)) do
            {:ok, closed} -> {{:ok, closed}, [run.id]}
            {:error, _} -> {{:error, :lease_lost}, []}
          end

        _ ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

  @spec request_cancel(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, ChangeRun.t()} | {:error, term()}
  def request_cancel(organization_id, run_id) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
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

  @spec retry(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, ChangeRun.t()} | {:error, term()}
  def retry(organization_id, run_id) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {{:error, :not_found}, []}

        %ChangeRun{state: :partial} = run ->
          {:ok, pending} =
            Repo.update(
              ChangeRun.system_changeset(run, %{
                state: :pending_apply,
                phase: :preflight,
                finished_at: nil,
                cancel_requested_at: nil,
                failure_code: nil
              })
            )

          {{:ok, pending}, [run.id]}

        %ChangeRun{state: state} = run
        when state in [:failed, :interrupted, :cancelled, :expired] ->
          lock_scope(run.organization_id, run.gtfs_version_id)

          case lock_active_run(run.organization_id, run.gtfs_version_id) do
            nil ->
              attrs = %{
                organization_id: run.organization_id,
                gtfs_version_id: run.gtfs_version_id,
                actor_id: run.actor_id,
                actor_email: run.actor_email,
                state: :pending_compute,
                phase: :staging,
                source_manifest: run.source_manifest,
                serializer_version: ChangeDecisionSerializer.serializer_version()
              }

              case Repo.insert(ChangeRun.system_changeset(%ChangeRun{}, attrs)) do
                {:ok, retry_run} -> {{:ok, retry_run}, [retry_run.id]}
                {:error, changeset} -> {{:error, changeset}, []}
              end

            %ChangeRun{} ->
              {{:error, :invalid_transition}, []}
          end

        _run ->
          {{:error, :invalid_transition}, []}
      end
    end)
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

  @doc "Returns the most recent durable review for one immutable route-version scope."
  @spec latest_for_version(Ecto.UUID.t(), Ecto.UUID.t()) :: ChangeRun.t() | nil
  def latest_for_version(organization_id, gtfs_version_id) do
    from(r in ChangeRun,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
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
        Enum.flat_map(expired, fn run ->
          state = if is_nil(run.cancel_requested_at), do: :interrupted, else: :cancelled

          {count, _} =
            from(r in ChangeRun,
              where:
                r.id == ^run.id and r.organization_id == ^organization_id and
                  r.lease_generation == ^run.lease_generation and
                  r.lease_token == ^run.lease_token and
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
        end)

      {length(ids), ids}
    end)
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
        decisions
        |> Enum.reduce_while({:ok, []}, fn decision, {:ok, acc} ->
          case ChangeDecisionSerializer.deserialize(decision) do
            {:ok, deserialized} ->
              case ChangeDecisionSerializer.serialize(deserialized) do
                {:ok, serialized} -> {:cont, {:ok, [serialized | acc]}}
                {:error, reason} -> {:halt, {:error, {:invalid_decision, reason}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:invalid_decision, reason}}}

            :error ->
              {:halt, {:error, {:invalid_decision, :invalid_serialized_decision}}}
          end
        end)
        |> case do
          {:ok, decisions} -> {:ok, Enum.reverse(decisions)}
          error -> error
        end

      _ ->
        {:error, :invalid_review}
    end
  end

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

  defp apply_locked_decision(run, decision, generation, token, opts) do
    with :ok <- applicable_decision?(decision),
         :ok <- invoke_step(opts, :before_fingerprint),
         {:ok, current} <- current_entity(run, decision),
         :ok <- fingerprint_matches?(decision, current),
         :ok <- dependencies_satisfied?(run, decision),
         :ok <- invoke_step(opts, :before_mutation),
         {:ok, entity} <- apply_mutation(run, decision, current),
         :ok <- invoke_step(opts, :before_audit),
         {:ok, _audit} <- record_audit(run, decision, current, entity),
         :ok <- invoke_step(opts, :before_checkpoint),
         {:ok, applied} <- checkpoint_decision(decision),
         :ok <- invoke_step(opts, :before_progress),
         {:ok, _run} <- increment_progress(run, generation, token) do
      {{:ok, applied}, [run.id]}
    else
      {:error, reason} -> Repo.rollback(reason)
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
    fingerprint =
      decision.entity_type
      |> Gtfs.entity_snapshot(entity)
      |> Map.take(Map.keys(decision.current_values))
      |> ChangeDecisionSerializer.current_fingerprint()

    if fingerprint == decision.current_fingerprint, do: :ok, else: {:error, :drifted}
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

  defp record_audit(run, decision, current, _entity) do
    action = audit_action(decision.action)

    context = %AuditContext{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      station_stop_id: decision.natural_key,
      actor_id: run.actor_id,
      actor_email: run.actor_email
    }

    attrs = Map.merge(decision.uploaded_values, identity_attrs(run, decision))
    Gtfs.record_change_in_transaction(context, decision.entity_type, current, action, attrs)
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
  end

  defp approved_decision_count(run_id) do
    from(d in ChangeDecision,
      where: d.change_run_id == ^run_id and d.status == :approved,
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

  defp failure_code(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.slice(0, 128)

  defp failure_code(reason) when is_binary(reason), do: String.slice(reason, 0, 128)
  defp failure_code(_reason), do: "apply_failed"
  defp failure_status(:drifted), do: :stale
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
