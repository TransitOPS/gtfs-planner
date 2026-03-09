defmodule GtfsPlanner.Otp.Runtime.Server do
  @moduledoc """
  Assembles and starts the OTP runtime server process from a prepared graph.
  """

  alias GtfsPlanner.Otp.Runtime.Session
  alias GtfsPlanner.Otp.Runtime.SystemCommandRunner

  @default_host "127.0.0.1"
  @default_port 8080
  @default_heap "4G"
  @default_graphql_path "/otp/routers/default/index/graphql"

  @type start_error :: %{
          reason: :start_failed,
          command: String.t(),
          args: [String.t()],
          graph_workspace_dir: String.t(),
          runtime_log_path: String.t(),
          details: term()
        }

  @type stop_error :: %{
          reason: :stop_failed,
          command: String.t(),
          args: [String.t()],
          graph_workspace_dir: String.t(),
          runtime_log_path: String.t(),
          details: term()
        }

  @spec start(String.t(), keyword()) :: {:ok, Session.t()} | {:error, start_error()}
  def start(graph_path, opts \\ []) when is_binary(graph_path) and is_list(opts) do
    runner = Keyword.get(opts, :runner, SystemCommandRunner)
    runner_opts = Keyword.get(opts, :runner_opts, [])

    host =
      Keyword.get(
        opts,
        :host,
        Application.get_env(:gtfs_planner, :otp_server_host, @default_host)
      )

    port =
      Keyword.get(
        opts,
        :port,
        Application.get_env(:gtfs_planner, :otp_server_port, @default_port)
      )

    heap =
      Keyword.get(
        opts,
        :heap,
        Application.get_env(:gtfs_planner, :otp_server_heap, @default_heap)
      )

    graphql_path =
      Keyword.get(
        opts,
        :graphql_path,
        Application.get_env(:gtfs_planner, :otp_graphql_path, @default_graphql_path)
      )

    command = Application.get_env(:gtfs_planner, :java_path, "java")
    otp_jar_path = Application.fetch_env!(:gtfs_planner, :otp_jar_path)

    data_dir = Path.dirname(graph_path)
    graph_workspace_dir = Path.dirname(data_dir)
    runtime_log_path = Path.join(graph_workspace_dir, "runtime.log")

    port = normalize_port(port)
    graphql_path = normalize_graphql_path(graphql_path)
    base_url = "http://#{host}:#{port}"

    args = [
      "-Xmx#{heap}",
      "-jar",
      otp_jar_path,
      "--load",
      data_dir,
      "--serve",
      "--port",
      to_string(port)
    ]

    case execute_start(runner, command, args, runner_opts) do
      {:ok, process} ->
        {:ok,
         %Session{
           command: command,
           args: args,
           host: host,
           port: port,
           base_url: base_url,
           graphql_url: base_url <> graphql_path,
           graph_workspace_dir: graph_workspace_dir,
           process: process,
           runtime_log_path: runtime_log_path
         }}

      {:error, details} ->
        {:error,
         %{
           reason: :start_failed,
           command: command,
           args: args,
           graph_workspace_dir: graph_workspace_dir,
           runtime_log_path: runtime_log_path,
           details: details
         }}
    end
  end

  @spec stop(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, stop_error()}
  def stop(%Session{} = session, opts \\ []) when is_list(opts) do
    runner = Keyword.get(opts, :runner, SystemCommandRunner)

    shutdown_timeout_ms =
      Keyword.get(
        opts,
        :shutdown_timeout_ms,
        Application.get_env(:gtfs_planner, :otp_server_shutdown_timeout_ms, 5_000)
      )

    runner_opts =
      opts
      |> Keyword.get(:runner_opts, [])
      |> Keyword.put_new(:shutdown_timeout_ms, shutdown_timeout_ms)

    case execute_stop(runner, session.process, runner_opts) do
      :ok ->
        {:ok, session}

      {:error, details} ->
        {:error,
         %{
           reason: :stop_failed,
           command: session.command,
           args: session.args,
           graph_workspace_dir: session.graph_workspace_dir,
           runtime_log_path: session.runtime_log_path,
           details: details
         }}
    end
  end

  defp execute_start(runner, command, args, opts) when is_atom(runner) do
    runner.start(command, args, opts)
  end

  defp execute_start(runner, command, args, opts) when is_function(runner, 3) do
    runner.(command, args, opts)
  end

  defp execute_stop(runner, process_handle, opts) when is_atom(runner) do
    runner.stop(process_handle, opts)
  end

  defp execute_stop(runner, process_handle, opts) when is_function(runner, 2) do
    runner.(process_handle, opts)
  end

  defp normalize_port(port) when is_integer(port), do: port
  defp normalize_port(port) when is_binary(port), do: String.to_integer(port)

  defp normalize_graphql_path(path) when is_binary(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end
end
