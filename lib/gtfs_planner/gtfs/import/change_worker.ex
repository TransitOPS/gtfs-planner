defmodule GtfsPlanner.Gtfs.Import.ChangeWorker do
  @moduledoc """
  Concrete compute adapter for a staged station change review.

  It reads only the manifest attached to the fenced run, persists the complete
  review before deleting sources, and reduces corrupt/missing input to a
  terminal, non-applicable outcome.
  """

  alias GtfsPlanner.Gtfs.Import.{
    ChangeArtifactStorage,
    ChangeDecisionSerializer,
    ChangeReview,
    ChangeRuns
  }

  alias GtfsPlanner.Gtfs.AuditContext

  @spec compute(struct(), pos_integer(), Ecto.UUID.t(), String.t()) :: :ok
  def compute(run, generation, token, _topic) do
    with {:ok, files} <- ChangeArtifactStorage.read(run),
         {:ok, review} <- build_review(run, files) do
      persist_review(run, generation, token, review)
    else
      {:error, :missing_or_corrupt_artifact} ->
        close(run, generation, token, "missing_or_corrupt_artifact")

      {:error, _reason} ->
        close(run, generation, token, "compute_failed")
    end
  rescue
    error ->
      require Logger
      Logger.error(Exception.format(:error, error, __STACKTRACE__))
      close(run, generation, token, "compute_failed")
  end

  @doc "Applies approved or previously failed decisions through fenced per-row transactions."
  @spec apply(struct(), pos_integer(), Ecto.UUID.t(), AuditContext.t(), String.t()) :: :ok
  def apply(run, generation, token, %AuditContext{} = audit_context, _topic) do
    apply_with_options(run, generation, token, audit_context, [])
  end

  @doc false
  def apply_with_hook(run, generation, token, %AuditContext{} = audit_context, topic, opts)
      when is_list(opts) do
    _ = topic
    apply_with_options(run, generation, token, audit_context, opts)
  end

  defp apply_with_options(run, generation, token, audit_context, opts) do
    _outcome =
      run.organization_id
      |> ChangeRuns.applyable_decisions(run.id)
      |> order_for_apply()
      |> Enum.reduce_while(:ok, &apply_one(&1, &2, run, generation, token, audit_context, opts))

    _ = ChangeRuns.finish_apply(run.organization_id, run.id, generation, token)
    :ok
  rescue
    error ->
      require Logger
      Logger.error(Exception.format(:error, error, __STACKTRACE__))
      _ = ChangeRuns.fail_apply(run.organization_id, run.id, generation, token, "apply_failed")
      :ok
  end

  defp apply_one(decision, :ok, run, generation, token, audit_context, opts) do
    result = apply_decision(run, decision, generation, token, audit_context, opts)
    continue_after_apply(result, run, decision, generation, token)
  end

  defp apply_decision(run, decision, generation, token, audit_context, []) do
    ChangeRuns.apply_decision(
      run.organization_id,
      run.id,
      decision.decision_id,
      generation,
      token,
      audit_context
    )
  end

  defp apply_decision(run, decision, generation, token, audit_context, opts) do
    ChangeRuns.apply_decision_with_hook(
      run.organization_id,
      run.id,
      decision.decision_id,
      generation,
      token,
      audit_context,
      opts
    )
  end

  defp continue_after_apply({:ok, _applied}, _run, _decision, _generation, _token),
    do: {:cont, :ok}

  defp continue_after_apply({:error, :lease_lost}, _run, _decision, _generation, _token),
    do: {:halt, :lease_lost}

  defp continue_after_apply({:error, reason}, run, decision, generation, token) do
    run.organization_id
    |> ChangeRuns.mark_apply_failure(run.id, decision.decision_id, generation, token, reason)
    |> continue_after_failure()
  end

  defp continue_after_failure({:ok, _failed}), do: {:cont, :ok}
  defp continue_after_failure({:error, _reason}), do: {:halt, :lease_lost}

  defp close(run, generation, token, code) do
    _ = ChangeRuns.fail_compute(run.organization_id, run.id, generation, token, code)
    :ok
  end

  defp build_review(run, files) do
    review = ChangeReview.compute(run.organization_id, run.gtfs_version_id, files)

    review
    |> Map.fetch!(:decisions)
    |> Enum.reduce_while({:ok, []}, fn decision, {:ok, serialized} ->
      case ChangeDecisionSerializer.serialize(decision) do
        {:ok, item} -> {:cont, {:ok, [item | serialized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decisions} -> {:ok, Map.put(review, :decisions, Enum.reverse(decisions))}
      error -> error
    end
  end

  defp persist_review(run, generation, token, review) do
    case ChangeRuns.persist_review(run.organization_id, run.id, generation, token, review) do
      {:ok, _review} ->
        _ = ChangeArtifactStorage.remove(run.organization_id, run.gtfs_version_id, run.id)
        :ok

      {:error, :lease_lost} ->
        :ok

      {:error, _reason} ->
        close(run, generation, token, "review_persistence_failed")
    end
  end

  defp order_for_apply(decisions) do
    Enum.sort_by(decisions, fn decision ->
      {action_rank(decision.action), entity_rank(decision.action, decision.entity_type),
       decision.natural_key, decision.decision_id}
    end)
  end

  defp action_rank(:add), do: 0
  defp action_rank(:modify), do: 1
  defp action_rank(:conflict), do: 1
  defp action_rank(:remove), do: 2

  defp entity_rank(action, entity_type) when action in [:add, :modify, :conflict] do
    case entity_type do
      :level -> 0
      :stop -> 1
      :pathway -> 2
    end
  end

  defp entity_rank(:remove, entity_type) do
    case entity_type do
      :pathway -> 0
      :stop -> 1
      :level -> 2
    end
  end
end
