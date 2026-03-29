defmodule GtfsPlanner.Otp.GraphLifecycle do
  @moduledoc """
  OTP graph workspace lifecycle operations.

  Handles post-success cleanup of transient graph build artifacts.
  """

  alias GtfsPlanner.Otp.GraphPath

  @spec purge_graph_on_success(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :purged | :not_found} | {:error, term()}
  def purge_graph_on_success(organization_id, gtfs_version_id) do
    workspace_root_path = GraphPath.workspace_root_dir(organization_id, gtfs_version_id)

    if File.exists?(workspace_root_path) do
      case File.rm_rf(workspace_root_path) do
        {:ok, _paths} ->
          {:ok, :purged}

        {:error, reason, _path} ->
          {:error, {:graph_workspace_delete_failed, workspace_root_path, reason}}
      end
    else
      {:ok, :not_found}
    end
  end
end
