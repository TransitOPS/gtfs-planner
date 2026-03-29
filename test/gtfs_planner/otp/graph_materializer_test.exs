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
               gtfs_input_sha256_resolver_fun: fn "org-1", "ver-1", _build_opts ->
                 {:ok, "gtfs-input-sha"}
               end,
               cache_lookup_fun: fn %{
                                      organization_id: "org-1",
                                      gtfs_version_id: "ver-1",
                                      gtfs_input_sha256: "gtfs-input-sha"
                                    } ->
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
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, "gtfs-input-sha"}
               end,
               cache_lookup_fun: fn %{gtfs_input_sha256: "gtfs-input-sha"} -> :miss end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
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
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, "gtfs-input-sha"}
               end,
               cache_lookup_fun: fn %{gtfs_input_sha256: "gtfs-input-sha"} -> :miss end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               preflight_fun: fn _org, _ver, _opts -> {:error, issues} end
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
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, "gtfs-input-sha"}
               end,
               cache_lookup_fun: fn _cache_identity ->
                 send(self(), :cache_lookup_called)

                 {:ok, "/tmp/graph/Graph.obj", "/tmp/graph/manifest.json",
                  %{"schema_version" => 1}}
               end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
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

    gtfs_content_hash = "gtfs-hash-match"
    gtfs_input_sha256 = "gtfs-input-sha-match"
    scope_key = GraphMaterializer.derive_scope_key(:default, gtfs_input_sha256)
    graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id, scope_key)
    manifest_path = GraphPath.manifest_path(organization.id, gtfs_version.id, scope_key)

    :ok = File.mkdir_p(Path.dirname(graph_path))
    :ok = File.write(graph_path, "graph-binary")

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
        gtfs_input_sha256,
        osm_fingerprint,
        nil,
        %{"command" => "java", "args" => [], "graph_path" => graph_path, "build_log_path" => ""},
        DateTime.utc_now()
      )

    :ok = File.mkdir_p(Path.dirname(manifest_path))
    :ok = File.write(manifest_path, Jason.encode!(manifest_json))

    assert {:ok, ^graph_path, meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, gtfs_input_sha256}
               end
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

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: "/tmp/gtfs.zip",
               content_hash: "gtfs-hash-current",
               file_size_bytes: 123,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    gtfs_input_sha256 = "gtfs-input-sha"
    scope_key = GraphMaterializer.derive_scope_key(:default, gtfs_input_sha256)
    graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id, scope_key)
    manifest_path = GraphPath.manifest_path(organization.id, gtfs_version.id, scope_key)

    :ok = File.mkdir_p(Path.dirname(graph_path))
    :ok = File.write(graph_path, "graph-binary")

    osm_fingerprint =
      :crypto.hash(:sha256, File.read!(osm_path))
      |> Base.encode16(case: :lower)

    stale_manifest =
      GraphManifest.build(
        "gtfs-hash-stale",
        gtfs_input_sha256,
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
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, gtfs_input_sha256}
               end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
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

  test "get_or_build_graph/3 rebuilds when gtfs_input_sha256 differs", %{
    organization: organization,
    gtfs_version: gtfs_version,
    osm_path: osm_path
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    gtfs_content_hash = "gtfs-hash-current"
    stale_gtfs_input_sha256 = "stale-input-sha"
    stale_scope_key = GraphMaterializer.derive_scope_key(:default, stale_gtfs_input_sha256)
    graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id, stale_scope_key)
    manifest_path = GraphPath.manifest_path(organization.id, gtfs_version.id, stale_scope_key)

    :ok = File.mkdir_p(Path.dirname(graph_path))
    :ok = File.write(graph_path, "graph-binary")

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

    stale_manifest =
      GraphManifest.build(
        gtfs_content_hash,
        stale_gtfs_input_sha256,
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

    new_manifest =
      Map.put(stale_manifest, "gtfs_input_sha256", "current-input-sha")

    assert {:ok, ^graph_path, meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, "current-input-sha"}
               end,
               stage_fun: fn _org, _ver, _data_dir -> :ok end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
               build_fun: fn _data_dir, _opts -> {:ok, build_result} end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 {:ok, manifest_path, new_manifest}
               end
             )

    refute meta.reused
    assert meta.manifest_json["gtfs_input_sha256"] == "current-input-sha"

    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :persisting}}
    assert_receive {:phase, %{phase: :done, reused: false}}
  end

  test "get_or_build_graph/3 does not reuse station scoped graph for default runtime scope", %{
    organization: organization,
    gtfs_version: gtfs_version,
    osm_path: osm_path
  } do
    status_callback = fn payload -> send(self(), {:phase, payload}) end

    shared_gtfs_input_sha256 = "shared-input-sha"
    gtfs_content_hash = "feed-content-hash"

    station_scope_key =
      GraphMaterializer.derive_scope_key(:station_reachability, shared_gtfs_input_sha256)

    station_graph_path =
      GraphPath.graph_obj_path(organization.id, gtfs_version.id, station_scope_key)

    station_manifest_path =
      GraphPath.manifest_path(organization.id, gtfs_version.id, station_scope_key)

    default_scope_key =
      GraphMaterializer.derive_scope_key(:default, shared_gtfs_input_sha256)

    default_graph_path =
      GraphPath.graph_obj_path(organization.id, gtfs_version.id, default_scope_key)

    default_manifest_path =
      GraphPath.manifest_path(organization.id, gtfs_version.id, default_scope_key)

    :ok = File.mkdir_p(Path.dirname(station_graph_path))
    :ok = File.write(station_graph_path, "station-graph-binary")

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

    station_manifest =
      GraphManifest.build(
        gtfs_content_hash,
        shared_gtfs_input_sha256,
        osm_fingerprint,
        nil,
        %{
          "command" => "java",
          "args" => [],
          "graph_path" => station_graph_path,
          "build_log_path" => ""
        },
        DateTime.utc_now()
      )

    :ok = File.mkdir_p(Path.dirname(station_manifest_path))
    :ok = File.write(station_manifest_path, Jason.encode!(station_manifest))

    build_result = %{
      command: "java",
      args: ["-jar", "otp.jar"],
      graph_path: default_graph_path,
      build_log_path: Path.join(Path.dirname(default_graph_path), "build.log"),
      output: "rebuilt"
    }

    rebuilt_manifest = %{"schema_version" => 1, "gtfs_input_sha256" => shared_gtfs_input_sha256}

    assert {:ok, ^default_graph_path, meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               status_callback: status_callback,
               runtime_scope: :default,
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, shared_gtfs_input_sha256}
               end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
               stage_fun: fn _org, _ver, _data_dir, _opts ->
                 send(self(), :stage_called)
                 :ok
               end,
               build_fun: fn _data_dir, _opts ->
                 send(self(), :build_called)
                 {:ok, build_result}
               end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 send(self(), :persist_called)
                 {:ok, default_manifest_path, rebuilt_manifest}
               end
             )

    refute meta.reused
    assert meta.manifest_path == default_manifest_path
    assert meta.manifest_json == rebuilt_manifest
    assert station_graph_path != default_graph_path

    assert_receive :stage_called
    assert_receive :build_called
    assert_receive :persist_called
    assert_receive {:phase, %{phase: :cache_check}}
    assert_receive {:phase, %{phase: :preflight}}
    assert_receive {:phase, %{phase: :building}}
    assert_receive {:phase, %{phase: :persisting}}
    assert_receive {:phase, %{phase: :done, reused: false}}
  end

  test "get_or_build_graph/3 does not cross-reuse cache between different custom gtfs_zip_path inputs", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    source_dir =
      Path.join(System.tmp_dir!(), "graph-custom-zip-isolation-#{System.unique_integer([:positive])}")

    custom_zip_path_a = Path.join(source_dir, "custom-a.zip")
    custom_zip_path_b = Path.join(source_dir, "custom-b.zip")

    File.mkdir_p!(source_dir)
    File.write!(custom_zip_path_a, "custom-a-content")
    File.write!(custom_zip_path_b, "custom-b-content")

    on_exit(fn -> File.rm_rf(source_dir) end)

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: custom_zip_path_a,
               content_hash: "feed-content-hash",
               file_size_bytes: 16,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    build_fun = fn data_dir, _opts ->
      graph_path = Path.join(data_dir, "Graph.obj")
      build_log_path = Path.join(Path.dirname(data_dir), "build.log")

      :ok = File.mkdir_p(data_dir)
      :ok = File.write(graph_path, "graph-content")

      {:ok,
       %{
         command: "java",
         args: ["-jar", "otp.jar"],
         graph_path: graph_path,
         build_log_path: build_log_path,
         output: "built"
       }}
    end

    preflight_fun = fn _org, _ver, _opts -> :ok end

    assert {:ok, graph_path_a, meta_a} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               preflight_fun: preflight_fun,
               stage_fun: fn _org, _ver, _data_dir, _opts -> :ok end,
               build_fun: build_fun,
               gtfs_zip_path: custom_zip_path_a,
               gtfs_meta: %{content_hash: "feed-content-hash"}
             )

    assert {:ok, graph_path_b, meta_b} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               preflight_fun: preflight_fun,
               stage_fun: fn _org, _ver, _data_dir, _opts -> :ok end,
               build_fun: build_fun,
               gtfs_zip_path: custom_zip_path_b,
               gtfs_meta: %{content_hash: "feed-content-hash"}
             )

    scope_key_a =
      custom_zip_path_a
      |> sha256_of!()
      |> then(&GraphMaterializer.derive_scope_key(:default, &1))

    scope_key_b =
      custom_zip_path_b
      |> sha256_of!()
      |> then(&GraphMaterializer.derive_scope_key(:default, &1))

    assert graph_path_a == GraphPath.graph_obj_path(organization.id, gtfs_version.id, scope_key_a)
    assert graph_path_b == GraphPath.graph_obj_path(organization.id, gtfs_version.id, scope_key_b)

    assert meta_a.manifest_path ==
             GraphPath.manifest_path(organization.id, gtfs_version.id, scope_key_a)

    assert meta_b.manifest_path ==
             GraphPath.manifest_path(organization.id, gtfs_version.id, scope_key_b)

    assert meta_a.manifest_json["gtfs_input_sha256"] == sha256_of!(custom_zip_path_a)
    assert meta_b.manifest_json["gtfs_input_sha256"] == sha256_of!(custom_zip_path_b)

    refute meta_a.reused
    refute meta_b.reused
    refute graph_path_a == graph_path_b
    refute meta_a.manifest_path == meta_b.manifest_path
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

    gtfs_input_sha256 = sha256_of!(gtfs_source_path)
    scope_key = GraphMaterializer.derive_scope_key(:default, gtfs_input_sha256)

    expected_data_dir = GraphPath.data_dir(organization.id, gtfs_version.id, scope_key)
    expected_staged_gtfs = GraphPath.staged_gtfs_zip_path(organization.id, gtfs_version.id, scope_key)
    expected_staged_osm = GraphPath.staged_osm_path(organization.id, gtfs_version.id, scope_key, osm_path)
    expected_graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id, scope_key)

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
               cache_lookup_fun: fn _cache_identity -> :miss end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
               build_fun: fn data_dir, _opts ->
                 send(self(), {:build_data_dir, data_dir})
                 {:ok, build_result}
               end,
               persist_fun: fn _org, _ver, ^build_result, _opts ->
                 {:ok, GraphPath.manifest_path(organization.id, gtfs_version.id, scope_key),
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

  test "get_or_build_graph/3 persists manifest gtfs_input_sha256 from resolved build input", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    source_dir =
      Path.join(System.tmp_dir!(), "graph-manifest-input-sha-#{System.unique_integer([:positive])}")

    custom_zip_path = Path.join(source_dir, "custom.zip")

    File.mkdir_p!(source_dir)
    File.write!(custom_zip_path, "custom-gtfs-content")

    on_exit(fn -> File.rm_rf(source_dir) end)

    scope_key =
      custom_zip_path
      |> sha256_of!()
      |> then(&GraphMaterializer.derive_scope_key(:default, &1))

    graph_path = GraphPath.graph_obj_path(organization.id, gtfs_version.id, scope_key)
    manifest_path = GraphPath.manifest_path(organization.id, gtfs_version.id, scope_key)

    build_result = %{
      command: "java",
      args: ["-jar", "otp.jar"],
      graph_path: graph_path,
      build_log_path: Path.join(Path.dirname(graph_path), "build.log"),
      output: "ok"
    }

    assert {:ok, ^graph_path, meta} =
             GraphMaterializer.get_or_build_graph(organization.id, gtfs_version.id,
               cache_lookup_fun: fn _cache_identity -> :miss end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
               build_fun: fn _data_dir, _opts -> {:ok, build_result} end,
               gtfs_zip_path: custom_zip_path,
               gtfs_meta: %{content_hash: "feed-content-hash"}
             )

    assert meta.manifest_path == manifest_path
    assert File.exists?(manifest_path)
    assert meta.manifest_json["gtfs_content_hash"] == "feed-content-hash"
    assert meta.manifest_json["gtfs_input_sha256"] == sha256_of!(custom_zip_path)
    refute meta.manifest_json["gtfs_input_sha256"] == meta.manifest_json["gtfs_content_hash"]
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
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, "gtfs-input-sha"}
               end,
               cache_lookup_fun: fn %{gtfs_input_sha256: "gtfs-input-sha"} -> :miss end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
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
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, "gtfs-input-sha"}
               end,
               cache_lookup_fun: fn %{gtfs_input_sha256: "gtfs-input-sha"} -> :miss end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
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
               gtfs_input_sha256_resolver_fun: fn _org, _ver, _build_opts ->
                 {:ok, "gtfs-input-sha"}
               end,
               cache_lookup_fun: fn %{gtfs_input_sha256: "gtfs-input-sha"} -> :miss end,
               preflight_fun: fn _org, _ver, _opts -> :ok end,
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

  test "resolve_gtfs_input_sha256/3 hashes custom gtfs_zip_path when provided", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    source_dir =
      Path.join(
        System.tmp_dir!(),
        "graph-input-sha-custom-#{System.unique_integer([:positive])}"
      )

    artifact_zip_path = Path.join(source_dir, "artifact.zip")
    custom_zip_path = Path.join(source_dir, "custom.zip")

    File.mkdir_p!(source_dir)
    File.write!(artifact_zip_path, "artifact-content")
    File.write!(custom_zip_path, "custom-content")

    on_exit(fn -> File.rm_rf(source_dir) end)

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: artifact_zip_path,
               content_hash: "artifact-hash",
               file_size_bytes: 16,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    assert {:ok, gtfs_input_sha256} =
             GraphMaterializer.resolve_gtfs_input_sha256(organization.id, gtfs_version.id,
               gtfs_zip_path: custom_zip_path
             )

    assert gtfs_input_sha256 == sha256_of!(custom_zip_path)
    refute gtfs_input_sha256 == sha256_of!(artifact_zip_path)
  end

  test "resolve_gtfs_input_sha256/3 hashes artifact zip path when custom path is missing", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    source_dir =
      Path.join(
        System.tmp_dir!(),
        "graph-input-sha-artifact-#{System.unique_integer([:positive])}"
      )

    artifact_zip_path = Path.join(source_dir, "artifact.zip")

    File.mkdir_p!(source_dir)
    File.write!(artifact_zip_path, "artifact-content")

    on_exit(fn -> File.rm_rf(source_dir) end)

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: artifact_zip_path,
               content_hash: "artifact-hash",
               file_size_bytes: 16,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    assert {:ok, gtfs_input_sha256} =
             GraphMaterializer.resolve_gtfs_input_sha256(organization.id, gtfs_version.id, [])

    assert gtfs_input_sha256 == sha256_of!(artifact_zip_path)
  end

  test "derive_scope_key/2 normalizes runtime scope and preserves hex sha" do
    assert GraphMaterializer.derive_scope_key(:station_reachability, "AbC123") == %{
             runtime_scope: "station_reachability",
             gtfs_input_sha256: "abc123"
           }

    assert GraphMaterializer.derive_scope_key(" Station Reachability ", "abcdef") == %{
             runtime_scope: "station-reachability",
             gtfs_input_sha256: "abcdef"
           }
  end

  test "derive_scope_key/2 hashes non-hex fingerprint into path-safe segment" do
    non_hex_fingerprint = "sha256:feed/input"

    assert GraphMaterializer.derive_scope_key("  ", non_hex_fingerprint) == %{
             runtime_scope: "default",
             gtfs_input_sha256: sha256_of_binary(non_hex_fingerprint)
           }
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

  defp sha256_of!(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256_of_binary(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
