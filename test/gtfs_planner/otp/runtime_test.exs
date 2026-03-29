defmodule GtfsPlanner.Otp.RuntimeTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.Runtime
  alias GtfsPlanner.Otp.Runtime.Session

  test "prepare_runtime/3 composes GTFS and graph materializers" do
    status_callback = fn payload -> send(self(), {:status, payload}) end

    gtfs_fun = fn "org-1", "ver-1", opts ->
      opts[:status_callback].(%{phase: :done, reused: false})

      {:ok, "/tmp/otp/gtfs.zip",
       %{reused: false, content_hash: "gtfs-hash", file_size_bytes: 100, manifest_json: %{}}}
    end

    graph_fun = fn "org-1", "ver-1", opts ->
      send(self(), {:graph_opts, opts})
      opts[:status_callback].(%{phase: :done, reused: true})

      {:ok, "/tmp/otp/Graph.obj",
       %{reused: true, manifest_path: "/tmp/otp/manifest.json", manifest_json: %{}}}
    end

    assert {:ok, result} =
             Runtime.prepare_runtime("org-1", "ver-1",
               status_callback: status_callback,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert result.gtfs_zip_path == "/tmp/otp/gtfs.zip"
    assert result.graph_path == "/tmp/otp/Graph.obj"
    assert result.meta.gtfs.content_hash == "gtfs-hash"
    assert result.meta.graph.reused

    assert_receive {:graph_opts, graph_opts}
    assert graph_opts[:gtfs_zip_path] == "/tmp/otp/gtfs.zip"
    assert graph_opts[:runtime_scope] == :default

    assert graph_opts[:gtfs_meta] == %{
             reused: false,
             content_hash: "gtfs-hash",
             file_size_bytes: 100,
             manifest_json: %{}
           }

    assert_receive {:status, %{scope: :gtfs, phase: :done, reused: false}}
    assert_receive {:status, %{scope: :graph, phase: :done, reused: true}}
  end

  test "prepare_runtime/3 forwards preflight_mode to GTFS materializer when missing from gtfs_opts" do
    gtfs_fun = fn "org-1", "ver-1", opts ->
      send(self(), {:gtfs_opts, opts})
      {:ok, "/tmp/otp/gtfs.zip", %{}}
    end

    graph_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:ok, _result} =
             Runtime.prepare_runtime("org-1", "ver-1",
               preflight_mode: :lenient,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert_receive {:gtfs_opts, gtfs_opts}
    assert gtfs_opts[:preflight_mode] == :lenient
  end

  test "prepare_runtime/3 selects station_zip_path for station_reachability runtime scope" do
    station_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-runtime-test.zip"
      )

    write_runtime_gtfs_zip!(station_zip_path, ["32095"], ["32095"])
    on_exit(fn -> File.rm(station_zip_path) end)

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/source.zip",
       %{content_hash: "hash", station_stop_id: "32095", station_zip_path: station_zip_path}}
    end

    graph_fun = fn "org-1", "ver-1", opts ->
      send(self(), {:graph_opts, opts})
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:ok, result} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert result.gtfs_zip_path == station_zip_path

    assert_receive {:graph_opts, graph_opts}
    assert graph_opts[:gtfs_zip_path] == station_zip_path
    assert graph_opts[:runtime_scope] == :station_reachability
  end

  test "prepare_runtime/3 ignores out-of-scope source stop_times by prechecking station-scoped artifact" do
    source_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-source-out-of-scope-runtime-test.zip"
      )

    station_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-scoped-out-of-scope-runtime-test.zip"
      )

    write_runtime_gtfs_zip!(source_zip_path, ["32095", "15910"], ["15910"])
    write_runtime_gtfs_zip!(station_zip_path, ["32095"], ["32095"])

    on_exit(fn ->
      File.rm(source_zip_path)
      File.rm(station_zip_path)
    end)

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, source_zip_path,
       %{content_hash: "hash", station_stop_id: "32095", station_zip_path: station_zip_path}}
    end

    graph_fun = fn "org-1", "ver-1", opts ->
      send(self(), {:graph_opts, opts})
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:ok, result} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert result.gtfs_zip_path == station_zip_path

    assert_receive {:graph_opts, graph_opts}
    assert graph_opts[:gtfs_zip_path] == station_zip_path
    assert graph_opts[:runtime_scope] == :station_reachability
  end

  test "prepare_runtime/3 returns deterministic error when station scoped referential precheck fails" do
    station_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-precheck-fail-runtime-test.zip"
      )

    write_runtime_gtfs_zip!(station_zip_path, ["32095"], ["15910"])
    on_exit(fn -> File.rm(station_zip_path) end)

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/source.zip",
       %{content_hash: "hash", station_stop_id: "32095", station_zip_path: station_zip_path}}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, [issue]} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert issue.code == :station_runtime_precheck_stop_times_stop_id_missing_stop
    assert issue.severity == :error
    assert issue.details.runtime_scope == :station_reachability
    assert_station_runtime_boundary_details(issue.details)
    assert issue.details.source_file == "stop_times.txt"
    assert issue.details.source_field == "stop_id"
    assert issue.details.target_file == "stops.txt"
    assert issue.details.target_field == "stop_id"
    assert issue.details.invalid_count == 1
    assert issue.details.sample_values == ["15910"]
    refute_received :graph_called
  end

  test "prepare_runtime/3 returns deterministic error when station scoped precheck cannot read artifact" do
    station_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-precheck-read-fail-runtime-test.zip"
      )

    File.write!(station_zip_path, "not-a-zip")
    on_exit(fn -> File.rm(station_zip_path) end)

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/source.zip",
       %{content_hash: "hash", station_stop_id: "32095", station_zip_path: station_zip_path}}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, [issue]} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert issue.code == :station_runtime_precheck_artifact_read_failed
    assert issue.severity == :error
    assert issue.details.runtime_scope == :station_reachability
    assert_station_runtime_boundary_details(issue.details)
    assert issue.details.source_file == "runtime_input_gtfs_zip_path"
    assert issue.details.source_field == "path"
    assert issue.details.target_file == nil
    assert issue.details.target_field == nil
    assert issue.details.artifact_path == station_zip_path
    assert is_integer(issue.details.issue_count)
    assert issue.details.issue_count > 0
    refute_received :graph_called
  end

  test "prepare_runtime/3 returns deterministic error when station_stop_id missing for station scope" do
    station_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-missing-stop-id-runtime-test.zip"
      )

    File.write!(station_zip_path, "station-zip")
    on_exit(fn -> File.rm(station_zip_path) end)

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/source.zip", %{content_hash: "hash", station_zip_path: station_zip_path}}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, [issue]} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert issue.code == :station_runtime_input_missing_station_stop_id
    assert issue.severity == :error
    assert issue.details.runtime_scope == :station_reachability
    assert_station_runtime_boundary_details(issue.details)
    refute_received :graph_called
  end

  test "prepare_runtime/3 returns deterministic error when station_zip_path unreadable for station scope" do
    station_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-missing-runtime-test.zip"
      )

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/source.zip",
       %{content_hash: "hash", station_stop_id: "32095", station_zip_path: station_zip_path}}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, [issue]} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert issue.code == :station_runtime_input_station_zip_path_unreadable
    assert issue.severity == :error
    assert issue.details.runtime_scope == :station_reachability
    assert_station_runtime_boundary_details(issue.details)
    assert issue.details.source_file == "station_zip_path"
    assert issue.details.source_field == "path"
    assert issue.details.target_file == nil
    assert issue.details.target_field == nil
    assert issue.details.invalid_count == 1
    assert issue.details.sample_values == [station_zip_path]
    assert issue.details.station_zip_path == station_zip_path
    refute_received :graph_called
  end

  test "prepare_runtime/3 returns deterministic error when station_zip_path missing for station scope" do
    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/source.zip", %{content_hash: "hash"}}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, [issue]} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert issue.code == :station_runtime_input_missing_station_zip_path
    assert issue.severity == :error
    assert issue.details.runtime_scope == :station_reachability
    assert_station_runtime_boundary_details(issue.details)
    refute_received :graph_called
  end

  test "prepare_runtime/3 returns deterministic error when runtime input lineage mismatches station zip" do
    source_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-source-lineage-runtime-test.zip"
      )

    station_zip_path =
      Path.join(
        System.tmp_dir!(),
        "station-#{System.unique_integer([:positive])}-station-lineage-runtime-test.zip"
      )

    write_runtime_gtfs_zip!(source_zip_path, ["32095"], ["32095"])
    write_runtime_gtfs_zip!(station_zip_path, ["32095"], ["32095"])

    on_exit(fn ->
      File.rm(source_zip_path)
      File.rm(station_zip_path)
    end)

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:ok, source_zip_path,
       %{content_hash: "hash", station_stop_id: "32095", station_zip_path: station_zip_path}}
    end

    runtime_input_selector = fn :station_reachability, _gtfs_zip_path, _gtfs_meta ->
      {:ok, source_zip_path}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, [issue]} =
             Runtime.prepare_runtime("org-1", "ver-1",
               runtime_scope: :station_reachability,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun,
               runtime_input_gtfs_zip_path_fun: runtime_input_selector
             )

    assert issue.code == :station_runtime_input_lineage_mismatch
    assert issue.severity == :error
    assert issue.details.runtime_scope == :station_reachability
    assert_station_runtime_boundary_details(issue.details)
    assert issue.details.source_file == "runtime_input_gtfs_zip_path"
    assert issue.details.source_field == "path"
    assert issue.details.target_file == "station_zip_path"
    assert issue.details.target_field == "path"
    assert issue.details.invalid_count == 1
    assert issue.details.runtime_input_gtfs_zip_path == source_zip_path
    assert issue.details.station_zip_path == station_zip_path

    assert Enum.sort(issue.details.sample_values) ==
             Enum.sort([source_zip_path, station_zip_path])

    refute_received :graph_called
  end

  test "prepare_runtime/3 returns GTFS errors without invoking graph materializer" do
    gtfs_issues = [%{code: :preflight_failed}]

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:error, gtfs_issues}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, ^gtfs_issues} =
             Runtime.prepare_runtime("org-1", "ver-1",
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    refute_received :graph_called
  end

  test "run_with_otp/4 orchestrates prepare, start, readiness, callback, and stop" do
    parent = self()
    status_callback = fn payload -> send(parent, {:status, payload}) end

    prepare_runtime_fun = fn "org-1", "ver-1", _opts ->
      send(parent, :prepared)

      {:ok,
       %{
         gtfs_zip_path: "/tmp/otp/gtfs.zip",
         graph_path: "/tmp/otp/Graph.obj",
         meta: %{gtfs: %{}, graph: %{}}
       }}
    end

    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    start_server_fun = fn "/tmp/otp/Graph.obj", _opts ->
      send(parent, :started)
      {:ok, session}
    end

    wait_ready_fun = fn ^session, _opts ->
      send(parent, :ready)
      :ok
    end

    callback = fn ^session ->
      send(parent, :callback_called)
      {:ok, %{suite: :complete}}
    end

    stop_server_fun = fn ^session, _opts ->
      send(parent, :stopped)
      {:ok, session}
    end

    assert {:ok, %{suite: :complete}} =
             Runtime.run_with_otp("org-1", "ver-1", callback,
               status_callback: status_callback,
               prepare_runtime_fun: prepare_runtime_fun,
               start_server_fun: start_server_fun,
               wait_ready_fun: wait_ready_fun,
               stop_server_fun: stop_server_fun
             )

    assert_receive {:status, %{scope: :otp, phase: :starting}}
    assert_receive {:status, %{scope: :otp, phase: :waiting_ready}}
    assert_receive {:status, %{scope: :otp, phase: :ready}}
    assert_receive {:status, %{scope: :otp, phase: :stopping}}
    assert_receive {:status, %{scope: :otp, phase: :stopped}}

    assert_receive :prepared
    assert_receive :started
    assert_receive :ready
    assert_receive :callback_called
    assert_receive :stopped
  end

  test "run_with_otp/4 preserves gtfs/graph statuses and emits ordered otp phases" do
    parent = self()
    status_callback = fn payload -> send(parent, {:status, payload}) end

    prepare_runtime_fun = fn "org-1", "ver-1", opts ->
      opts[:status_callback].(%{scope: :gtfs, phase: :done, reused: false})
      opts[:status_callback].(%{scope: :graph, phase: :done, reused: true})

      {:ok,
       %{
         gtfs_zip_path: "/tmp/otp/gtfs.zip",
         graph_path: "/tmp/otp/Graph.obj",
         meta: %{gtfs: %{}, graph: %{}}
       }}
    end

    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    assert {:ok, :done} =
             Runtime.run_with_otp("org-1", "ver-1", fn ^session -> {:ok, :done} end,
               status_callback: status_callback,
               prepare_runtime_fun: prepare_runtime_fun,
               start_server_fun: fn _graph_path, _opts -> {:ok, session} end,
               wait_ready_fun: fn ^session, _opts -> :ok end,
               stop_server_fun: fn ^session, _opts -> {:ok, session} end
             )

    assert_receive {:status, %{scope: :gtfs, phase: :done, reused: false}}
    assert_receive {:status, %{scope: :graph, phase: :done, reused: true}}
    assert_receive {:status, %{scope: :otp, phase: :starting}}
    assert_receive {:status, %{scope: :otp, phase: :waiting_ready}}
    assert_receive {:status, %{scope: :otp, phase: :ready}}
    assert_receive {:status, %{scope: :otp, phase: :stopping}}
    assert_receive {:status, %{scope: :otp, phase: :stopped}}
  end

  test "run_with_otp/4 returns prepare runtime error and does not start OTP" do
    parent = self()

    prepare_runtime_fun = fn "org-1", "ver-1", _opts ->
      {:error, [%{code: :prepare_failed}]}
    end

    start_server_fun = fn _graph_path, _opts ->
      send(parent, :started)
      {:ok, :unexpected}
    end

    assert {:error, [%{code: :prepare_failed}]} =
             Runtime.run_with_otp("org-1", "ver-1", fn _session -> {:ok, :noop} end,
               prepare_runtime_fun: prepare_runtime_fun,
               start_server_fun: start_server_fun
             )

    refute_received :started
  end

  test "run_with_otp/4 short-circuits before OTP start on station preflight blockers" do
    parent = self()

    blocking_issue = %{
      code: :station_stop_lat_missing,
      severity: :blocking,
      context: %{file: "stops.txt", field: "stop_lat", station_stop_id: "station-1"}
    }

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:error, [blocking_issue]}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(parent, :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    start_server_fun = fn _graph_path, _opts ->
      send(parent, :started)
      {:ok, :unexpected}
    end

    assert {:error, [returned_issue]} =
             Runtime.run_with_otp(
               "org-1",
               "ver-1",
               fn _session ->
                 send(parent, :callback_called)
                 {:ok, :unexpected}
               end,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun,
               start_server_fun: start_server_fun
             )

    assert returned_issue == blocking_issue
    refute_received :graph_called
    refute_received :started
    refute_received :callback_called
  end

  test "run_with_otp/4 stops OTP when readiness fails" do
    parent = self()
    status_callback = fn payload -> send(parent, {:status, payload}) end

    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    stop_calls = :counters.new(1, [:atomics])

    assert {:error, [issue]} =
             Runtime.run_with_otp(
               "org-1",
               "ver-1",
               fn _session ->
                 send(parent, :callback_called)
                 {:ok, :unexpected}
               end,
               status_callback: status_callback,
               prepare_runtime_fun: fn _org, _ver, _opts ->
                 {:ok,
                  %{
                    gtfs_zip_path: "/tmp/otp/gtfs.zip",
                    graph_path: "/tmp/otp/Graph.obj",
                    meta: %{}
                  }}
               end,
               start_server_fun: fn _graph_path, _opts ->
                 {:ok, session}
               end,
               wait_ready_fun: fn ^session, _opts ->
                 {:error, %{reason: :ready_timeout}}
               end,
               stop_server_fun: fn ^session, _opts ->
                 :ok = :counters.add(stop_calls, 1, 1)
                 send(parent, :stopped)
                 {:ok, session}
               end
             )

    assert issue.code == :otp_ready_timeout
    assert issue.details.reason == :ready_timeout

    assert_receive {:status, %{scope: :otp, phase: :starting}}
    assert_receive {:status, %{scope: :otp, phase: :waiting_ready}}
    assert_receive {:status, %{scope: :otp, phase: :stopping}}
    assert_receive {:status, %{scope: :otp, phase: :stopped}}
    assert_receive {:status, %{scope: :otp, phase: :failed}}

    refute_received :callback_called
    assert_receive :stopped
    assert :counters.get(stop_calls, 1) == 1
  end

  test "run_with_otp/4 stops OTP when callback returns error" do
    parent = self()

    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    stop_calls = :counters.new(1, [:atomics])

    assert {:error, %{reason: :suite_failed}} =
             Runtime.run_with_otp(
               "org-1",
               "ver-1",
               fn ^session ->
                 send(parent, :callback_called)
                 {:error, %{reason: :suite_failed}}
               end,
               prepare_runtime_fun: fn _org, _ver, _opts ->
                 {:ok,
                  %{
                    gtfs_zip_path: "/tmp/otp/gtfs.zip",
                    graph_path: "/tmp/otp/Graph.obj",
                    meta: %{}
                  }}
               end,
               start_server_fun: fn _graph_path, _opts ->
                 {:ok, session}
               end,
               wait_ready_fun: fn ^session, _opts ->
                 :ok
               end,
               stop_server_fun: fn ^session, _opts ->
                 :ok = :counters.add(stop_calls, 1, 1)
                 send(parent, :stopped)
                 {:ok, session}
               end
             )

    assert_receive :callback_called
    assert_receive :stopped
    assert :counters.get(stop_calls, 1) == 1
  end

  test "run_with_otp/4 maps start failure to runtime issue taxonomy" do
    parent = self()

    assert {:error, [issue]} =
             Runtime.run_with_otp(
               "org-1",
               "ver-1",
               fn _session ->
                 send(parent, :callback_called)
                 {:ok, :noop}
               end,
               prepare_runtime_fun: fn _org, _ver, _opts ->
                 {:ok,
                  %{
                    gtfs_zip_path: "/tmp/otp/gtfs.zip",
                    graph_path: "/tmp/otp/Graph.obj",
                    meta: %{}
                  }}
               end,
               start_server_fun: fn _graph_path, _opts ->
                 {:error, %{reason: :start_failed, details: :enoent}}
               end
             )

    assert issue.code == :otp_start_failed
    assert issue.details.reason == :start_failed
    refute_received :callback_called
  end

  test "run_with_otp/4 guarantees stop invocation when callback crashes" do
    parent = self()

    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    stop_calls = :counters.new(1, [:atomics])

    assert_raise RuntimeError, "suite crashed", fn ->
      Runtime.run_with_otp(
        "org-1",
        "ver-1",
        fn ^session ->
          raise "suite crashed"
        end,
        prepare_runtime_fun: fn _org, _ver, _opts ->
          {:ok,
           %{gtfs_zip_path: "/tmp/otp/gtfs.zip", graph_path: "/tmp/otp/Graph.obj", meta: %{}}}
        end,
        start_server_fun: fn _graph_path, _opts ->
          {:ok, session}
        end,
        wait_ready_fun: fn ^session, _opts ->
          :ok
        end,
        stop_server_fun: fn ^session, _opts ->
          :ok = :counters.add(stop_calls, 1, 1)
          send(parent, :stopped)
          {:ok, session}
        end
      )
    end

    assert_receive :stopped
    assert :counters.get(stop_calls, 1) == 1
  end

  test "run_with_otp/4 maps stop failure to runtime issue taxonomy" do
    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    assert {:error, [issue]} =
             Runtime.run_with_otp("org-1", "ver-1", fn ^session -> {:ok, :done} end,
               prepare_runtime_fun: fn _org, _ver, _opts ->
                 {:ok,
                  %{
                    gtfs_zip_path: "/tmp/otp/gtfs.zip",
                    graph_path: "/tmp/otp/Graph.obj",
                    meta: %{}
                  }}
               end,
               start_server_fun: fn _graph_path, _opts ->
                 {:ok, session}
               end,
               wait_ready_fun: fn ^session, _opts ->
                 :ok
               end,
               stop_server_fun: fn ^session, _opts ->
                 {:error, %{reason: :stop_failed, details: :timeout}}
               end
             )

    assert issue.code == :otp_stop_failed
    assert issue.details.reason == :stop_failed
    assert match?(%Session{}, issue.details.session)
  end

  test "run_with_otp/4 returns otp_runtime_already_running when org lock is held" do
    parent = self()

    assert {:error, [issue]} =
             Runtime.run_with_otp("org-1", "ver-1", fn _session -> {:ok, :noop} end,
               acquire_lock_fun: fn "org-1" -> {:error, %{reason: :runtime_already_running}} end,
               release_lock_fun: fn _org_id ->
                 send(parent, :released)
                 :ok
               end,
               prepare_runtime_fun: fn _org, _ver, _opts ->
                 send(parent, :prepared)

                 {:ok,
                  %{
                    gtfs_zip_path: "/tmp/otp/gtfs.zip",
                    graph_path: "/tmp/otp/Graph.obj",
                    meta: %{}
                  }}
               end
             )

    assert issue.code == :otp_runtime_already_running
    assert issue.details.reason == :runtime_already_running
    refute_received :prepared
    refute_received :released
  end

  test "run_with_otp/4 releases org lock after successful run" do
    parent = self()

    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    assert {:ok, :done} =
             Runtime.run_with_otp("org-1", "ver-1", fn ^session -> {:ok, :done} end,
               acquire_lock_fun: fn "org-1" ->
                 send(parent, :lock_acquired)
                 :ok
               end,
               release_lock_fun: fn "org-1" ->
                 send(parent, :lock_released)
                 :ok
               end,
               prepare_runtime_fun: fn _org, _ver, _opts ->
                 {:ok,
                  %{
                    gtfs_zip_path: "/tmp/otp/gtfs.zip",
                    graph_path: "/tmp/otp/Graph.obj",
                    meta: %{}
                  }}
               end,
               start_server_fun: fn _graph_path, _opts -> {:ok, session} end,
               wait_ready_fun: fn ^session, _opts -> :ok end,
               stop_server_fun: fn ^session, _opts -> {:ok, session} end
             )

    assert_receive :lock_acquired
    assert_receive :lock_released
  end

  test "run_with_otp/4 releases org lock when callback crashes" do
    parent = self()

    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    assert_raise RuntimeError, "suite crashed", fn ->
      Runtime.run_with_otp(
        "org-1",
        "ver-1",
        fn ^session ->
          raise "suite crashed"
        end,
        acquire_lock_fun: fn "org-1" ->
          send(parent, :lock_acquired)
          :ok
        end,
        release_lock_fun: fn "org-1" ->
          send(parent, :lock_released)
          :ok
        end,
        prepare_runtime_fun: fn _org, _ver, _opts ->
          {:ok,
           %{gtfs_zip_path: "/tmp/otp/gtfs.zip", graph_path: "/tmp/otp/Graph.obj", meta: %{}}}
        end,
        start_server_fun: fn _graph_path, _opts -> {:ok, session} end,
        wait_ready_fun: fn ^session, _opts -> :ok end,
        stop_server_fun: fn ^session, _opts -> {:ok, session} end
      )
    end

    assert_receive :lock_acquired
    assert_receive :lock_released
  end

  defp write_runtime_gtfs_zip!(zip_path, stop_ids, stop_time_stop_ids) do
    stops_body =
      stop_ids
      |> Enum.uniq()
      |> Enum.map_join("\n", fn stop_id -> "#{stop_id},Station,1" end)

    stop_times_body =
      stop_time_stop_ids
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {stop_id, sequence} -> "trip-#{sequence},#{stop_id}" end)

    stops_csv =
      ["stop_id,stop_name,location_type", stops_body]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    stop_times_csv =
      ["trip_id,stop_id", stop_times_body]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    files = [
      {~c"stops.txt", stops_csv},
      {~c"stop_times.txt", stop_times_csv}
    ]

    {:ok, _zip_path} = :zip.create(String.to_charlist(zip_path), files)
  end

  defp assert_station_runtime_boundary_details(details) when is_map(details) do
    assert Map.has_key?(details, :source_file)
    assert Map.has_key?(details, :source_field)
    assert Map.has_key?(details, :target_file)
    assert Map.has_key?(details, :target_field)
    assert Map.has_key?(details, :invalid_count)
    assert Map.has_key?(details, :sample_values)
    assert is_integer(details.invalid_count)
    assert details.invalid_count >= 0
    assert is_list(details.sample_values)
  end
end
