defmodule GtfsPlanner.Otp.GraphBuilder do
  @moduledoc """
  Assembles and executes the OTP graph build command.
  """

  alias GtfsPlanner.Otp.SystemGraphCommandRunner

  @type build_result :: %{
          command: String.t(),
          args: [String.t()],
          graph_path: String.t(),
          build_log_path: String.t(),
          output: String.t()
        }

  @type build_error :: %{
          code: :build_command_failed | :graph_obj_missing,
          exit_status: non_neg_integer(),
          command: String.t(),
          args: [String.t()],
          graph_path: String.t(),
          build_log_path: String.t(),
          output: String.t()
        }

  @spec build(String.t(), keyword()) :: {:ok, build_result()} | {:error, build_error()}
  def build(data_dir, opts \\ []) when is_binary(data_dir) and is_list(opts) do
    runner = Keyword.get(opts, :runner, SystemGraphCommandRunner)
    runner_options = Keyword.get(opts, :runner_options, [])

    java_path = Application.get_env(:gtfs_planner, :java_path, "java")
    otp_jar_path = Application.get_env(:gtfs_planner, :otp_jar_path)
    heap = Application.get_env(:gtfs_planner, :otp_graph_build_heap, "4G")
    graph_path = Path.join(data_dir, "Graph.obj")
    build_log_path = build_log_path(data_dir)

    args = ["-Xmx#{heap}", "-jar", otp_jar_path, "--build", "--save", data_dir]

    {output, exit_status} = execute(runner, java_path, args, runner_options)
    :ok = persist_build_log(build_log_path, output)

    case {exit_status, File.regular?(graph_path)} do
      {0, true} ->
        {:ok,
         %{
           command: java_path,
           args: args,
           graph_path: graph_path,
           build_log_path: build_log_path,
           output: output
         }}

      {0, false} ->
        {:error,
         %{
           code: :graph_obj_missing,
           exit_status: exit_status,
           command: java_path,
           args: args,
           graph_path: graph_path,
           build_log_path: build_log_path,
           output: output
         }}

      {status, _graph_exists?} ->
        {:error,
         %{
           code: :build_command_failed,
           exit_status: status,
           command: java_path,
           args: args,
           graph_path: graph_path,
           build_log_path: build_log_path,
           output: output
         }}
    end
  end

  defp execute(runner, command, args, options) when is_atom(runner) do
    runner.run(command, args, options)
  end

  defp execute(runner, command, args, options) when is_function(runner, 3) do
    runner.(command, args, options)
  end

  defp build_log_path(data_dir) do
    workspace_dir = Path.dirname(data_dir)
    Path.join(workspace_dir, "build.log")
  end

  defp persist_build_log(build_log_path, output) do
    build_log_dir = Path.dirname(build_log_path)

    with :ok <- File.mkdir_p(build_log_dir),
         :ok <- File.write(build_log_path, output) do
      :ok
    end
  end

  @spec runner_module() :: module()
  def runner_module, do: SystemGraphCommandRunner
end
