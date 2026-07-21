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
end
