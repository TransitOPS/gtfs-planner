defmodule GtfsPlanner.Otp.GraphPathTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Otp.GraphPath

  setup do
    previous_value = Application.get_env(:gtfs_planner, :otp_runtime_path)

    on_exit(fn ->
      if is_nil(previous_value) do
        Application.delete_env(:gtfs_planner, :otp_runtime_path)
      else
        Application.put_env(:gtfs_planner, :otp_runtime_path, previous_value)
      end
    end)

    :ok
  end

  test "returns deterministic graph workspace paths" do
    runtime_base = Path.join(System.tmp_dir!(), "otp-runtime-test")
    organization_id = "org-123"
    gtfs_version_id = "ver-456"
    scope_key = %{runtime_scope: "station_reachability", gtfs_input_sha256: "abc123"}
    osm_source_path = "/mnt/osm/us-northeast.osm.pbf"

    Application.put_env(:gtfs_planner, :otp_runtime_path, runtime_base)

    workspace_dir = Path.join([runtime_base, organization_id, gtfs_version_id, "graph"])
    scoped_workspace_dir = Path.join([workspace_dir, "station_reachability", "abc123"])
    data_dir = Path.join(workspace_dir, "data")
    scoped_data_dir = Path.join(scoped_workspace_dir, "data")

    assert GraphPath.base_dir() == runtime_base
    assert GraphPath.workspace_root_dir(organization_id, gtfs_version_id) == workspace_dir
    assert GraphPath.workspace_dir(organization_id, gtfs_version_id) == workspace_dir
    assert GraphPath.workspace_dir(organization_id, gtfs_version_id, scope_key) == scoped_workspace_dir
    assert GraphPath.data_dir(organization_id, gtfs_version_id) == data_dir
    assert GraphPath.data_dir(organization_id, gtfs_version_id, scope_key) == scoped_data_dir

    assert GraphPath.graph_obj_path(organization_id, gtfs_version_id) ==
             Path.join(data_dir, "Graph.obj")

    assert GraphPath.graph_obj_path(organization_id, gtfs_version_id, scope_key) ==
             Path.join(scoped_data_dir, "Graph.obj")

    assert GraphPath.build_log_path(organization_id, gtfs_version_id) ==
             Path.join(workspace_dir, "build.log")

    assert GraphPath.build_log_path(organization_id, gtfs_version_id, scope_key) ==
             Path.join(scoped_workspace_dir, "build.log")

    assert GraphPath.manifest_path(organization_id, gtfs_version_id) ==
             Path.join(workspace_dir, "manifest.json")

    assert GraphPath.manifest_path(organization_id, gtfs_version_id, scope_key) ==
             Path.join(scoped_workspace_dir, "manifest.json")

    assert GraphPath.staged_gtfs_zip_path(organization_id, gtfs_version_id) ==
             Path.join(data_dir, "gtfs.zip")

    assert GraphPath.staged_gtfs_zip_path(organization_id, gtfs_version_id, scope_key) ==
             Path.join(scoped_data_dir, "gtfs.zip")

    assert GraphPath.staged_osm_path(organization_id, gtfs_version_id, osm_source_path) ==
             Path.join(data_dir, "us-northeast.osm.pbf")

    assert GraphPath.staged_osm_path(organization_id, gtfs_version_id, scope_key, osm_source_path) ==
             Path.join(scoped_data_dir, "us-northeast.osm.pbf")
  end
end
