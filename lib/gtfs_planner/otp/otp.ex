defmodule GtfsPlanner.Otp do
  @moduledoc """
  Public OTP context boundary.

  OTP-specific GTFS materialization and validation orchestration modules live
  under `GtfsPlanner.Otp` to keep OTP concerns isolated from other GTFS
  contexts.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Otp.Artifact
  alias GtfsPlanner.Repo

  @doc """
  Fetches the OTP GTFS artifact for an organization/version scope.
  """
  @spec fetch_artifact(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Artifact.t()} | {:error, :not_found}
  def fetch_artifact(organization_id, gtfs_version_id) do
    case get_artifact_by_scope(organization_id, gtfs_version_id) do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  @doc """
  Upserts the OTP GTFS artifact for an organization/version scope.
  """
  @spec upsert_artifact(map()) :: {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def upsert_artifact(attrs) when is_map(attrs) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert(
      conflict_target: [:organization_id, :gtfs_version_id],
      on_conflict:
        {:replace,
         [
           :zip_path,
           :content_hash,
           :file_size_bytes,
           :manifest_json,
           :updated_at
         ]},
      returning: true
    )
  end

  @doc """
  Deletes the OTP GTFS artifact for an organization/version scope.
  """
  @spec delete_artifact(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Artifact.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_artifact(organization_id, gtfs_version_id) do
    case get_artifact_by_scope(organization_id, gtfs_version_id) do
      nil -> {:error, :not_found}
      artifact -> Repo.delete(artifact)
    end
  end

  defp get_artifact_by_scope(organization_id, gtfs_version_id) do
    from(a in Artifact,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end
end
