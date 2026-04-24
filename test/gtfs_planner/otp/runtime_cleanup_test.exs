defmodule GtfsPlanner.Otp.RuntimeCleanupTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Otp.GraphPath
  alias GtfsPlanner.Otp.Runtime

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "cleanup_on_success/2" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      runtime_path =
        Path.join(
          System.tmp_dir!(),
          "runtime-cleanup-graph-#{System.unique_integer([:positive])}"
        )

      artifacts_path =
        Path.join(
          System.tmp_dir!(),
          "runtime-cleanup-artifacts-#{System.unique_integer([:positive])}"
        )

      previous_runtime_path = Application.get_env(:gtfs_planner, :otp_runtime_path)
      previous_artifacts_path = Application.get_env(:gtfs_planner, :otp_artifacts_path)

      Application.put_env(:gtfs_planner, :otp_runtime_path, runtime_path)
      Application.put_env(:gtfs_planner, :otp_artifacts_path, artifacts_path)

      on_exit(fn ->
        restore_env(:otp_runtime_path, previous_runtime_path)
        restore_env(:otp_artifacts_path, previous_artifacts_path)
        File.rm_rf(runtime_path)
        File.rm_rf(artifacts_path)
      end)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "purges graph root scopes then GTFS artifact on success", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      workspace_root_path = GraphPath.workspace_root_dir(organization.id, gtfs_version.id)

      default_scope = %{runtime_scope: "default", gtfs_input_sha256: "hash-default"}
      station_scope = %{runtime_scope: "station_reachability", gtfs_input_sha256: "hash-station"}

      default_graph_path =
        GraphPath.graph_obj_path(organization.id, gtfs_version.id, default_scope)

      station_graph_path =
        GraphPath.graph_obj_path(organization.id, gtfs_version.id, station_scope)

      zip_path = ArtifactPath.artifact_zip_path(organization.id, gtfs_version.id)

      File.mkdir_p!(Path.dirname(default_graph_path))
      File.write!(default_graph_path, "graph-default")

      File.mkdir_p!(Path.dirname(station_graph_path))
      File.write!(station_graph_path, "graph-station")

      File.mkdir_p!(Path.dirname(zip_path))
      File.write!(zip_path, "gtfs")

      assert {:ok, _artifact} =
               Otp.upsert_artifact(%{
                 organization_id: organization.id,
                 gtfs_version_id: gtfs_version.id,
                 zip_path: zip_path,
                 content_hash: "hash-1",
                 file_size_bytes: 4,
                 manifest_json: %{"files" => ["agency.txt"]}
               })

      assert {:ok, %{graph: :purged, gtfs: :purged}} =
               Runtime.cleanup_on_success(organization.id, gtfs_version.id)

      refute File.exists?(workspace_root_path)
      refute File.exists?(zip_path)
      assert {:error, :not_found} = Otp.fetch_artifact(organization.id, gtfs_version.id)
    end

    test "returns not_found statuses when graph workspace and artifact are absent", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, %{graph: :not_found, gtfs: :not_found}} =
               Runtime.cleanup_on_success(organization.id, gtfs_version.id)
    end

    test "prepare_runtime then cleanup_on_success purges graph workspace and GTFS artifact", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      status_callback = fn payload -> send(self(), {:status, payload}) end
      organization_id = organization.id
      gtfs_version_id = gtfs_version.id
      scope_key = %{runtime_scope: "default", gtfs_input_sha256: "hash-default"}

      graph_path = GraphPath.graph_obj_path(organization_id, gtfs_version_id, scope_key)
      zip_path = ArtifactPath.artifact_zip_path(organization_id, gtfs_version_id)
      workspace_root_path = GraphPath.workspace_root_dir(organization_id, gtfs_version_id)

      gtfs_fun = fn ^organization_id, ^gtfs_version_id, opts ->
        opts[:status_callback].(%{phase: :done, reused: false})

        File.mkdir_p!(Path.dirname(zip_path))
        File.write!(zip_path, "gtfs")

        assert {:ok, _artifact} =
                 Otp.upsert_artifact(%{
                   organization_id: organization_id,
                   gtfs_version_id: gtfs_version_id,
                   zip_path: zip_path,
                   content_hash: "hash-2",
                   file_size_bytes: 4,
                   manifest_json: %{"files" => ["agency.txt"]}
                 })

        {:ok, zip_path,
         %{reused: false, content_hash: "hash-2", file_size_bytes: 4, manifest_json: %{}}}
      end

      graph_fun = fn ^organization_id, ^gtfs_version_id, opts ->
        opts[:status_callback].(%{phase: :done, reused: false})

        File.mkdir_p!(Path.dirname(graph_path))
        File.write!(graph_path, "graph")

        {:ok, graph_path,
         %{
           reused: false,
           manifest_path: GraphPath.manifest_path(organization_id, gtfs_version_id, scope_key),
           manifest_json: %{}
         }}
      end

      assert {:ok, prepared} =
               Runtime.prepare_runtime(organization_id, gtfs_version_id,
                 status_callback: status_callback,
                 gtfs_materializer_fun: gtfs_fun,
                 graph_materializer_fun: graph_fun
               )

      assert prepared.gtfs_zip_path == zip_path
      assert prepared.graph_path == graph_path
      assert File.exists?(zip_path)
      assert File.exists?(graph_path)
      assert File.exists?(workspace_root_path)

      assert_receive {:status, %{scope: :gtfs, phase: :done, reused: false}}
      assert_receive {:status, %{scope: :graph, phase: :done, reused: false}}

      assert {:ok, %{graph: :purged, gtfs: :purged}} =
               Runtime.cleanup_on_success(organization_id, gtfs_version_id)

      refute File.exists?(workspace_root_path)
      refute File.exists?(zip_path)
      assert {:error, :not_found} = Otp.fetch_artifact(organization_id, gtfs_version_id)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
