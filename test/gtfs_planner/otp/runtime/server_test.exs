defmodule GtfsPlanner.Otp.Runtime.ServerTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.Runtime.Server
  alias GtfsPlanner.Otp.Runtime.Session

  setup do
    previous_java_path = Application.get_env(:gtfs_planner, :java_path)
    previous_otp_jar_path = Application.get_env(:gtfs_planner, :otp_jar_path)

    Application.put_env(:gtfs_planner, :java_path, "java-test")
    Application.put_env(:gtfs_planner, :otp_jar_path, "/opt/otp/otp.jar")

    on_exit(fn ->
      restore_env(:java_path, previous_java_path)
      restore_env(:otp_jar_path, previous_otp_jar_path)
    end)

    :ok
  end

  test "start/2 assembles command args and session metadata" do
    parent = self()

    runner = fn command, args, opts ->
      send(parent, {:start_called, command, args, opts})
      {:ok, %{port: make_ref(), os_pid: 12_345}}
    end

    graph_path = "/tmp/runtime/org-1/default/Graph.obj"

    assert {:ok, %Session{} = session} =
             Server.start(graph_path,
               runner: runner,
               runner_opts: [startup_grace_ms: 200],
               host: "127.0.0.1",
               port: 8099,
               heap: "8G",
               graphql_path: "graphql"
             )

    assert_receive {:start_called, "java-test", args, [startup_grace_ms: 200]}

    data_dir = "/tmp/runtime/org-1/default"

    assert args == [
             "-Xmx8G",
             "-jar",
             "/opt/otp/otp.jar",
             "--load",
             data_dir,
             "--serve",
             "--port",
             "8099"
           ]

    assert session.command == "java-test"
    assert session.args == args
    assert session.host == "127.0.0.1"
    assert session.port == 8099
    assert session.base_url == "http://127.0.0.1:8099"
    assert session.graphql_url == "http://127.0.0.1:8099/graphql"
    assert session.graph_workspace_dir == "/tmp/runtime/org-1"
    assert session.runtime_log_path == "/tmp/runtime/org-1/runtime.log"
  end

  test "start/2 maps startup failures to structured start_failed issue" do
    runner = fn _command, _args, _opts ->
      {:error, %{reason: :start_failed, details: :enoent}}
    end

    assert {:error, issue} =
             Server.start("/tmp/runtime/org-1/default/Graph.obj",
               runner: runner,
               host: "localhost",
               port: 8080
             )

    assert issue.reason == :start_failed
    assert issue.command == "java-test"
    assert issue.graph_workspace_dir == "/tmp/runtime/org-1"
    assert issue.runtime_log_path == "/tmp/runtime/org-1/runtime.log"
    assert issue.details == %{reason: :start_failed, details: :enoent}
  end

  test "stop/2 returns ok for graceful stop" do
    parent = self()

    runner = fn process_handle, opts ->
      send(parent, {:stop_called, process_handle, opts})
      :ok
    end

    session = %Session{
      command: "java-test",
      args: ["-jar", "/opt/otp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime/org-1",
      process: %{port: make_ref(), os_pid: 123},
      runtime_log_path: "/tmp/runtime/org-1/runtime.log"
    }

    assert {:ok, ^session} =
             Server.stop(session,
               runner: runner,
               shutdown_timeout_ms: 3_000,
               runner_opts: [force_kill_wait_ms: 250]
             )

    assert_receive {:stop_called, %{os_pid: 123}, stop_opts}
    assert stop_opts[:shutdown_timeout_ms] == 3_000
    assert stop_opts[:force_kill_wait_ms] == 250
  end

  test "stop/2 maps forced-stop failure to structured stop_failed issue" do
    runner = fn _process_handle, _opts ->
      {:error, %{reason: :stop_timeout, timeout_ms: 5_000}}
    end

    session = %Session{
      command: "java-test",
      args: ["-jar", "/opt/otp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime/org-1",
      process: %{port: make_ref(), os_pid: 123},
      runtime_log_path: "/tmp/runtime/org-1/runtime.log"
    }

    assert {:error, issue} =
             Server.stop(session,
               runner: runner,
               shutdown_timeout_ms: 5_000
             )

    assert issue.reason == :stop_failed
    assert issue.command == "java-test"
    assert issue.args == ["-jar", "/opt/otp/otp.jar"]
    assert issue.graph_workspace_dir == "/tmp/runtime/org-1"
    assert issue.runtime_log_path == "/tmp/runtime/org-1/runtime.log"
    assert issue.details == %{reason: :stop_timeout, timeout_ms: 5_000}
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
