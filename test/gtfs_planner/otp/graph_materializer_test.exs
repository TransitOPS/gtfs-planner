defmodule GtfsPlanner.Otp.GraphMaterializerTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.GraphManifest
  alias GtfsPlanner.Otp.GraphPath
  alias GtfsPlanner.Otp.GraphMaterializer

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    runtime_path =
      Path.join(
        System.tmp_dir!(),
        "graph-materializer-test-#{System.unique_integer([:positive])}"
      )

    osm_path = Path.join(runtime_path, "region.osm.pbf")

    previous_env = %{
      otp_runtime_path: Application.get_env(:gtfs_planner, :otp_runtime_path),
      otp_osm_path: Application.get_env(:gtfs_planner, :otp_osm_path),
      otp_jar_sha256: Application.get_env(:gtfs_planner, :otp_jar_sha256)
    }

    File.mkdir_p!(runtime_path)
    File.write!(osm_path, "osm-content")

    Application.put_env(:gtfs_planner, :otp_runtime_path, runtime_path)
    Application.put_env(:gtfs_planner, :otp_osm_path, osm_path)
    Application.delete_env(:gtfs_planner, :otp_jar_sha256)

    on_exit(fn ->
      restore_env(:otp_runtime_path, previous_env.otp_runtime_path)
      restore_env(:otp_osm_path, previous_env.otp_osm_path)
      restore_env(:otp_jar_sha256, previous_env.otp_jar_sha256)

      File.rm_rf(runtime_path)
    end)

    %{
      organization: organization,
      gtfs_version: gtfs_version,
      runtime_path: runtime_path,
      osm_path: osm_path
    }
  end

  test "get_or_build_graph/3 returns cached graph and emits cache phases" do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    manifest_json = %{"schema_version" => 1}

    assert {:ok, "/tmp/graph/Graph.obj", meta} =
             GraphMaterializer.get_or_build_graph("org-1", "ver-1",
               status_callback: status_callback,
               cache_lookup_fun: fn "org-1", "ver-1" ->
                 {:ok, "/tmp/graph/Graph.obj", "/tmp/graph/manifest.json", manifest_json}
               end
             )

    assert meta == %{
             reused: true,
             manifest_path: "/tmp/graph/manifest.json",
             manifest_json: manifest_json
           }

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :done, reused: true}}
  end

  test "get_or_build_graph/3 builds and persists graph on cache miss" do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    build_result = %{
      command: "java",
      args: ["-jar", "otp.jar"],
      graph_path: "/tmp/runtime/data/Graph.obj",
      build_log_path: "/tmp/runtime/build.log",
      output: "ok"
    }

    manifest_json = %{"schema_version" => 1, "gtfs_content_hash" => "abc"}

    assert {:ok, "/tmp/runtime/data/Graph.obj", meta} =
             GraphMaterializer.get_or_build_graph("org-1", "ver-1",
               status_callback: status_callback,
               cache_lookup_fun: fn _org, _ver -> :miss end,
               preflight_fun: fn _org, _ver -> :ok end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               build_fun: fn _data_dir, _opts -> {:ok, build_result} end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 {:ok, "/tmp/runtime/manifest.json", manifest_json}
               end
             )

    assert meta == %{
             reused: false,
             manifest_path: "/tmp/runtime/manifest.json",
             manifest_json: manifest_json
           }

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :persisting}}
    assert_receive {:phase, %{phase: :done, reused: false}}
  end

  test "get_or_build_graph/3 returns preflight issues on cache miss preflight failure" do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    issues = [
      %{code: :missing_otp_jar_path, severity: :error, message: "missing jar", details: %{}}
    ]

    assert {:error, ^issues} =
             GraphMaterializer.get_or_build_graph("org-1", "ver-1",
               status_callback: status_callback,
               cache_lookup_fun: fn _org, _ver -> :miss end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               preflight_fun: fn _org, _ver -> {:error, issues} end
             )

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :failed, reason: :preflight_failed}}
  end

  test "get_or_build_graph/3 force_rebuild ignores cache and builds graph", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    build_result = %{
      command: "java",
      args: ["-jar", "otp.jar"],
      graph_path: "/tmp/runtime/data/Graph.obj",
      build_log_path: "/tmp/runtime/build.log",
      output: "ok"
    }

    assert {:ok, "/tmp/runtime/data/Graph.obj", meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               force_rebuild: true,
               cache_lookup_fun: fn _org, _ver ->
                 send(self(), :cache_lookup_called)

                 {:ok, "/tmp/graph/Graph.obj", "/tmp/graph/manifest.json",
                  %{"schema_version" => 1}}
               end,
               preflight_fun: fn _org, _ver -> :ok end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               build_fun: fn _data_dir, _opts -> {:ok, build_result} end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 {:ok, "/tmp/runtime/manifest.json", %{"schema_version" => 1}}
               end
             )

    refute_received :cache_lookup_called
    refute meta.reused
    refute_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :persisting}}
    assert_receive {:phase, %{phase: :done, reused: false}}
  end

  test "get_or_build_graph/3 reuses graph when manifest and fingerprints match", %{
    organization: organization,
    gtfs_version: gtfs_version,
    osm_path: osm_path
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id)
    manifest_path = GraphPath.manifest_path(organization.id, gtfs_version.id)

    :ok = File.mkdir_p(Path.dirname(graph_path))
    :ok = File.write(graph_path, "graph-binary")

    gtfs_content_hash = "gtfs-hash-match"

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: "/tmp/gtfs.zip",
               content_hash: gtfs_content_hash,
               file_size_bytes: 123,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    osm_fingerprint =
      :crypto.hash(:sha256, File.read!(osm_path))
      |> Base.encode16(case: :lower)

    manifest_json =
      GraphManifest.build(
        gtfs_content_hash,
        osm_fingerprint,
        nil,
        %{"command" => "java", "args" => [], "graph_path" => graph_path, "build_log_path" => ""},
        DateTime.utc_now()
      )

    :ok = File.mkdir_p(Path.dirname(manifest_path))
    :ok = File.write(manifest_path, Jason.encode!(manifest_json))

    assert {:ok, ^graph_path, meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback
             )

    assert meta.reused
    assert meta.manifest_path == manifest_path
    assert meta.manifest_json["gtfs_content_hash"] == gtfs_content_hash

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :done, reused: true}}
  end

  test "get_or_build_graph/3 rebuilds on manifest mismatch", %{
    organization: organization,
    gtfs_version: gtfs_version,
    osm_path: osm_path
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id)
    manifest_path = GraphPath.manifest_path(organization.id, gtfs_version.id)

    :ok = File.mkdir_p(Path.dirname(graph_path))
    :ok = File.write(graph_path, "graph-binary")

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: "/tmp/gtfs.zip",
               content_hash: "gtfs-hash-current",
               file_size_bytes: 123,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    osm_fingerprint =
      :crypto.hash(:sha256, File.read!(osm_path))
      |> Base.encode16(case: :lower)

    stale_manifest =
      GraphManifest.build(
        "gtfs-hash-stale",
        osm_fingerprint,
        nil,
        %{"command" => "java", "args" => [], "graph_path" => graph_path, "build_log_path" => ""},
        DateTime.utc_now()
      )

    :ok = File.mkdir_p(Path.dirname(manifest_path))
    :ok = File.write(manifest_path, Jason.encode!(stale_manifest))

    build_result = %{
      command: "java",
      args: ["-jar", "otp.jar"],
      graph_path: graph_path,
      build_log_path:
        Path.dirname(graph_path)
        |> Path.join("..")
        |> Path.join("build.log")
        |> Path.expand(),
      output: "rebuilt"
    }

    new_manifest = %{"schema_version" => 1, "gtfs_content_hash" => "gtfs-hash-current"}

    assert {:ok, ^graph_path, meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               preflight_fun: fn _org, _ver -> :ok end,
               build_fun: fn _data_dir, _opts -> {:ok, build_result} end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 {:ok, manifest_path, new_manifest}
               end
             )

    refute meta.reused
    assert meta.manifest_json == new_manifest

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :persisting}}
    assert_receive {:phase, %{phase: :done, reused: false}}
  end

  test "get_or_build_graph/3 stages gtfs zip and osm into data_dir before build", %{
    organization: organization,
    gtfs_version: gtfs_version,
    osm_path: osm_path
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    source_dir =
      Path.join(System.tmp_dir!(), "graph-staging-source-#{System.unique_integer([:positive])}")

    gtfs_source_path = Path.join(source_dir, "gtfs-source.zip")

    File.mkdir_p!(source_dir)
    File.write!(gtfs_source_path, "gtfs-content")

    on_exit(fn -> File.rm_rf(source_dir) end)

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: gtfs_source_path,
               content_hash: "gtfs-hash-stage",
               file_size_bytes: 12,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    expected_data_dir = GraphPath.data_dir(organization.id, gtfs_version.id)
    expected_staged_gtfs = GraphPath.staged_gtfs_zip_path(organization.id, gtfs_version.id)
    expected_staged_osm = GraphPath.staged_osm_path(organization.id, gtfs_version.id, osm_path)
    expected_graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id)

    build_result = %{
      command: "java",
      args: ["-jar", "otp.jar"],
      graph_path: expected_graph_path,
      build_log_path: Path.join(Path.dirname(expected_data_dir), "build.log"),
      output: "built"
    }

    assert {:ok, ^expected_graph_path, _meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               cache_lookup_fun: fn _org, _ver -> :miss end,
               preflight_fun: fn _org, _ver -> :ok end,
               build_fun: fn data_dir, _opts ->
                 send(self(), {:build_data_dir, data_dir})
                 {:ok, build_result}
               end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 {:ok, GraphPath.manifest_path(organization.id, gtfs_version.id),
                  %{"schema_version" => 1}}
               end
             )

    assert_receive {:build_data_dir, ^expected_data_dir}
    assert File.read!(expected_staged_gtfs) == "gtfs-content"
    assert File.read!(expected_staged_osm) == "osm-content"

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :persisting}}
    assert_receive {:phase, %{phase: :done, reused: false}}
  end

  test "get_or_build_graph/3 returns deterministic mapped error on build failure", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    build_reason = %{
      code: :graph_obj_missing,
      exit_status: 0,
      graph_path: "/tmp/runtime/data/Graph.obj",
      build_log_path: "/tmp/runtime/build.log"
    }

    assert {:error, [issue]} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               cache_lookup_fun: fn _org, _ver -> :miss end,
               preflight_fun: fn _org, _ver -> :ok end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               build_fun: fn _data_dir, _opts -> {:error, build_reason} end
             )

    assert issue.code == :build_failed
    assert issue.severity == :error
    assert issue.details.reason_code == :graph_obj_missing
    assert issue.details.exit_status == 0
    assert issue.details.graph_path == "/tmp/runtime/data/Graph.obj"
    assert issue.details.build_log_path == "/tmp/runtime/build.log"

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :failed, reason: :build_failed}}
  end

  test "get_or_build_graph/3 returns deterministic mapped error on persist failure", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    build_result = %{
      command: "java",
      args: ["-jar", "otp.jar"],
      graph_path: "/tmp/runtime/data/Graph.obj",
      build_log_path: "/tmp/runtime/build.log",
      output: "ok"
    }

    assert {:error, [issue]} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               cache_lookup_fun: fn _org, _ver -> :miss end,
               preflight_fun: fn _org, _ver -> :ok end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               build_fun: fn _data_dir, _opts -> {:ok, build_result} end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 {:error, :manifest_write_failed}
               end
             )

    assert issue.code == :persist_failed
    assert issue.severity == :error
    assert issue.details.reason_code == :manifest_write_failed

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :persisting}}
    assert_receive {:phase, %{phase: :failed, reason: :persist_failed}}
  end

  test "get_or_build_graph/3 returns deterministic mapped error on staging failure", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    assert {:error, [issue]} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               cache_lookup_fun: fn _org, _ver -> :miss end,
               preflight_fun: fn _org, _ver -> :ok end,
               stage_fun: fn _org, _ver, _data_dir -> {:error, :missing_gtfs_artifact} end
             )

    assert issue.code == :staging_failed
    assert issue.severity == :error
    assert issue.details.reason_code == :missing_gtfs_artifact

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :failed, reason: :staging_failed}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
