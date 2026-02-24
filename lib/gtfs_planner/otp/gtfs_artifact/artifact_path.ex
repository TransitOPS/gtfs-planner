defmodule GtfsPlanner.Otp.ArtifactPath do
  @moduledoc """
  Deterministic storage path policy for OTP GTFS artifacts.

  Artifacts are stored under a configured base directory, scoped by
  organization/version.
  """

  @default_dirname "gtfs_planner_otp_artifacts"

  @spec base_dir() :: String.t()
  def base_dir do
    Application.get_env(:gtfs_planner, :otp_artifacts_path) ||
      Path.join(System.tmp_dir!(), @default_dirname)
  end

  @spec artifact_dir(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def artifact_dir(organization_id, gtfs_version_id) do
    Path.join([
      base_dir(),
      organization_id,
      gtfs_version_id
    ])
  end

  @spec artifact_zip_path(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def artifact_zip_path(organization_id, gtfs_version_id) do
    Path.join(artifact_dir(organization_id, gtfs_version_id), "gtfs.zip")
  end
end
