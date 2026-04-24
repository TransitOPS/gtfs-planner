defmodule GtfsPlanner.Otp.GraphPath do
  @moduledoc """
  Deterministic storage path policy for OTP graph build workspace.
  """

  @default_dirname "gtfs_planner_otp_runtime"

  @type scope_key :: %{
          required(:runtime_scope) => String.t(),
          required(:gtfs_input_sha256) => String.t()
        }

  @spec base_dir() :: String.t()
  def base_dir do
    Application.get_env(:gtfs_planner, :otp_runtime_path) ||
      Path.join(System.tmp_dir!(), @default_dirname)
  end

  @spec workspace_root_dir(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def workspace_root_dir(organization_id, gtfs_version_id) do
    Path.join([base_dir(), organization_id, gtfs_version_id, "graph"])
  end

  @spec workspace_dir(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def workspace_dir(organization_id, gtfs_version_id) do
    workspace_root_dir(organization_id, gtfs_version_id)
  end

  @spec workspace_dir(Ecto.UUID.t(), Ecto.UUID.t(), scope_key()) :: String.t()
  def workspace_dir(organization_id, gtfs_version_id, %{
        runtime_scope: runtime_scope,
        gtfs_input_sha256: gtfs_input_sha256
      })
      when is_binary(runtime_scope) and runtime_scope != "" and is_binary(gtfs_input_sha256) and
             gtfs_input_sha256 != "" do
    Path.join([
      workspace_root_dir(organization_id, gtfs_version_id),
      runtime_scope,
      gtfs_input_sha256
    ])
  end

  @spec data_dir(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def data_dir(organization_id, gtfs_version_id) do
    Path.join(workspace_dir(organization_id, gtfs_version_id), "data")
  end

  @spec data_dir(Ecto.UUID.t(), Ecto.UUID.t(), scope_key()) :: String.t()
  def data_dir(organization_id, gtfs_version_id, scope_key) do
    Path.join(workspace_dir(organization_id, gtfs_version_id, scope_key), "data")
  end

  @spec graph_obj_path(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def graph_obj_path(organization_id, gtfs_version_id) do
    Path.join(data_dir(organization_id, gtfs_version_id), "Graph.obj")
  end

  @spec graph_obj_path(Ecto.UUID.t(), Ecto.UUID.t(), scope_key()) :: String.t()
  def graph_obj_path(organization_id, gtfs_version_id, scope_key) do
    Path.join(data_dir(organization_id, gtfs_version_id, scope_key), "Graph.obj")
  end

  @spec build_log_path(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def build_log_path(organization_id, gtfs_version_id) do
    Path.join(workspace_dir(organization_id, gtfs_version_id), "build.log")
  end

  @spec build_log_path(Ecto.UUID.t(), Ecto.UUID.t(), scope_key()) :: String.t()
  def build_log_path(organization_id, gtfs_version_id, scope_key) do
    Path.join(workspace_dir(organization_id, gtfs_version_id, scope_key), "build.log")
  end

  @spec manifest_path(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def manifest_path(organization_id, gtfs_version_id) do
    Path.join(workspace_dir(organization_id, gtfs_version_id), "manifest.json")
  end

  @spec manifest_path(Ecto.UUID.t(), Ecto.UUID.t(), scope_key()) :: String.t()
  def manifest_path(organization_id, gtfs_version_id, scope_key) do
    Path.join(workspace_dir(organization_id, gtfs_version_id, scope_key), "manifest.json")
  end

  @spec staged_gtfs_zip_path(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def staged_gtfs_zip_path(organization_id, gtfs_version_id) do
    Path.join(data_dir(organization_id, gtfs_version_id), "gtfs.zip")
  end

  @spec staged_gtfs_zip_path(Ecto.UUID.t(), Ecto.UUID.t(), scope_key()) :: String.t()
  def staged_gtfs_zip_path(organization_id, gtfs_version_id, scope_key) do
    Path.join(data_dir(organization_id, gtfs_version_id, scope_key), "gtfs.zip")
  end

  @spec staged_osm_path(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: String.t()
  def staged_osm_path(organization_id, gtfs_version_id, osm_source_path) do
    osm_filename = Path.basename(osm_source_path)
    Path.join(data_dir(organization_id, gtfs_version_id), osm_filename)
  end

  @spec staged_osm_path(Ecto.UUID.t(), Ecto.UUID.t(), scope_key(), String.t()) :: String.t()
  def staged_osm_path(organization_id, gtfs_version_id, scope_key, osm_source_path) do
    osm_filename = Path.basename(osm_source_path)
    Path.join(data_dir(organization_id, gtfs_version_id, scope_key), osm_filename)
  end
end
