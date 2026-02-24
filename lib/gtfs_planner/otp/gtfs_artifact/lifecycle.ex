defmodule GtfsPlanner.Otp.Lifecycle do
  @moduledoc """
  OTP artifact lifecycle operations.

  Handles post-success cleanup of transient GTFS zip artifacts.
  """

  alias GtfsPlanner.Otp

  @spec purge_artifact_on_success(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :purged | :not_found} | {:error, term()}
  def purge_artifact_on_success(organization_id, gtfs_version_id) do
    case Otp.fetch_artifact(organization_id, gtfs_version_id) do
      {:ok, artifact} ->
        with :ok <- delete_zip_file(artifact.zip_path),
             {:ok, _deleted} <- Otp.delete_artifact(organization_id, gtfs_version_id) do
          {:ok, :purged}
        end

      {:error, :not_found} ->
        {:ok, :not_found}
    end
  end

  defp delete_zip_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file_delete_failed, path, reason}}
    end
  end
end
