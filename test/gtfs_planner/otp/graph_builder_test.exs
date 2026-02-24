defmodule GtfsPlanner.Otp.GraphBuilderTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Otp.GraphBuilder

  setup do
    previous_env = %{
      java_path: Application.get_env(:gtfs_planner, :java_path),
      otp_jar_path: Application.get_env(:gtfs_planner, :otp_jar_path),
      otp_graph_build_heap: Application.get_env(:gtfs_planner, :otp_graph_build_heap)
    }

    on_exit(fn ->
      restore_env(:java_path, previous_env.java_path)
      restore_env(:otp_jar_path, previous_env.otp_jar_path)
      restore_env(:otp_graph_build_heap, previous_env.otp_graph_build_heap)
    end)

    :ok
  end

  test "build/2 assembles command args and returns ok on zero exit" do
    Application.put_env(:gtfs_planner, :java_path, "java-cmd")
    Application.put_env(:gtfs_planner, :otp_jar_path, "/opt/otp.jar")
    Application.put_env(:gtfs_planner, :otp_graph_build_heap, "6G")

    workspace_dir =
      Path.join(System.tmp_dir!(), "graph-builder-test-#{System.unique_integer([:positive])}")

    data_dir = Path.join(workspace_dir, "data")
    File.mkdir_p!(data_dir)

    on_exit(fn -> File.rm_rf(workspace_dir) end)

    runner = fn command, args, options ->
      graph_path = Path.join(List.last(args), "Graph.obj")
      File.write!(graph_path, "graph")

      send(self(), {:runner_called, command, args, options})
      {"graph build ok", 0}
    end

    assert {:ok, result} = GraphBuilder.build(data_dir, runner: runner)

    assert result.command == "java-cmd"
    assert result.args == ["-Xmx6G", "-jar", "/opt/otp.jar", "--build", "--save", data_dir]
    assert result.graph_path == Path.join(data_dir, "Graph.obj")
    assert result.build_log_path == Path.join(workspace_dir, "build.log")
    assert result.output == "graph build ok"
    assert File.read!(result.build_log_path) == "graph build ok"

    assert_receive {:runner_called, "java-cmd", args, []}
    assert args == ["-Xmx6G", "-jar", "/opt/otp.jar", "--build", "--save", data_dir]
  end

  test "build/2 returns structured error on non-zero exit" do
    Application.put_env(:gtfs_planner, :java_path, "java-cmd")
    Application.put_env(:gtfs_planner, :otp_jar_path, "/opt/otp.jar")
    Application.put_env(:gtfs_planner, :otp_graph_build_heap, "4G")

    workspace_dir =
      Path.join(System.tmp_dir!(), "graph-builder-test-#{System.unique_integer([:positive])}")

    data_dir = Path.join(workspace_dir, "data")
    File.mkdir_p!(data_dir)

    on_exit(fn -> File.rm_rf(workspace_dir) end)

    runner = fn _command, _args, _options ->
      {"graph build failed", 2}
    end

    assert {:error, error} = GraphBuilder.build(data_dir, runner: runner)
    assert error.code == :build_command_failed
    assert error.exit_status == 2
    assert error.command == "java-cmd"
    assert error.args == ["-Xmx4G", "-jar", "/opt/otp.jar", "--build", "--save", data_dir]
    assert error.graph_path == Path.join(data_dir, "Graph.obj")
    assert error.build_log_path == Path.join(workspace_dir, "build.log")
    assert error.output == "graph build failed"
    assert File.read!(error.build_log_path) == "graph build failed"
  end

  test "build/2 returns structured error on timeout exit status" do
    Application.put_env(:gtfs_planner, :java_path, "java-cmd")
    Application.put_env(:gtfs_planner, :otp_jar_path, "/opt/otp.jar")
    Application.put_env(:gtfs_planner, :otp_graph_build_heap, "4G")

    workspace_dir =
      Path.join(System.tmp_dir!(), "graph-builder-test-#{System.unique_integer([:positive])}")

    data_dir = Path.join(workspace_dir, "data")
    File.mkdir_p!(data_dir)

    on_exit(fn -> File.rm_rf(workspace_dir) end)

    runner = fn _command, _args, _options ->
      {"graph build timed out", 124}
    end

    assert {:error, error} = GraphBuilder.build(data_dir, runner: runner)
    assert error.code == :build_command_failed
    assert error.exit_status == 124
    assert error.command == "java-cmd"
    assert error.args == ["-Xmx4G", "-jar", "/opt/otp.jar", "--build", "--save", data_dir]
    assert error.graph_path == Path.join(data_dir, "Graph.obj")
    assert error.build_log_path == Path.join(workspace_dir, "build.log")
    assert error.output == "graph build timed out"
    assert File.read!(error.build_log_path) == "graph build timed out"
  end

  test "build/2 returns graph_obj_missing when exit is zero but Graph.obj is absent" do
    Application.put_env(:gtfs_planner, :java_path, "java-cmd")
    Application.put_env(:gtfs_planner, :otp_jar_path, "/opt/otp.jar")
    Application.put_env(:gtfs_planner, :otp_graph_build_heap, "4G")

    workspace_dir =
      Path.join(System.tmp_dir!(), "graph-builder-test-#{System.unique_integer([:positive])}")

    data_dir = Path.join(workspace_dir, "data")
    File.mkdir_p!(data_dir)

    on_exit(fn -> File.rm_rf(workspace_dir) end)

    runner = fn _command, _args, _options ->
      {"graph build reported success", 0}
    end

    assert {:error, error} = GraphBuilder.build(data_dir, runner: runner)

    assert error.code == :graph_obj_missing
    assert error.exit_status == 0
    assert error.command == "java-cmd"
    assert error.args == ["-Xmx4G", "-jar", "/opt/otp.jar", "--build", "--save", data_dir]
    assert error.graph_path == Path.join(data_dir, "Graph.obj")
    assert error.build_log_path == Path.join(workspace_dir, "build.log")
    assert error.output == "graph build reported success"
    assert File.read!(error.build_log_path) == "graph build reported success"
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
