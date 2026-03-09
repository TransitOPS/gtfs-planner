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
end
