defmodule GtfsPlanner.Otp.GraphLifecycleTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Otp.GraphLifecycle
  alias GtfsPlanner.Otp.GraphPath

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "purge_graph_on_success/2" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      runtime_path =
        Path.join(System.tmp_dir!(), "graph-lifecycle-test-#{System.unique_integer([:positive])}")

      previous_runtime_path = Application.get_env(:gtfs_planner, :otp_runtime_path)
      Application.put_env(:gtfs_planner, :otp_runtime_path, runtime_path)

      on_exit(fn ->
        if previous_runtime_path do
          Application.put_env(:gtfs_planner, :otp_runtime_path, previous_runtime_path)
        else
          Application.delete_env(:gtfs_planner, :otp_runtime_path)
        end

        File.rm_rf(runtime_path)
      end)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "purges existing graph workspace", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      workspace_path = GraphPath.workspace_dir(organization.id, gtfs_version.id)
      graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id)
      build_log_path = GraphPath.build_log_path(organization.id, gtfs_version.id)

      File.mkdir_p!(Path.dirname(graph_path))
      File.write!(graph_path, "graph")
      File.write!(build_log_path, "build output")

      assert File.exists?(workspace_path)

      assert {:ok, :purged} =
               GraphLifecycle.purge_graph_on_success(organization.id, gtfs_version.id)

      refute File.exists?(workspace_path)
    end

    test "returns not_found when graph workspace does not exist", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      workspace_path = GraphPath.workspace_dir(organization.id, gtfs_version.id)

      refute File.exists?(workspace_path)

      assert {:ok, :not_found} =
               GraphLifecycle.purge_graph_on_success(organization.id, gtfs_version.id)
    end

    test "returns error when graph workspace deletion fails", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      workspace_path = GraphPath.workspace_dir(organization.id, gtfs_version.id)
      workspace_parent = Path.dirname(workspace_path)

      File.mkdir_p!(workspace_path)
      File.write!(Path.join(workspace_path, "Graph.obj"), "graph")

      # Remove write permission from parent so workspace entry cannot be removed.
      File.chmod!(workspace_parent, 0o500)

      on_exit(fn ->
        File.chmod(workspace_parent, 0o700)
      end)

      assert {:error, {:graph_workspace_delete_failed, ^workspace_path, _reason}} =
               GraphLifecycle.purge_graph_on_success(organization.id, gtfs_version.id)

      assert File.exists?(workspace_path)
    end
  end
end
