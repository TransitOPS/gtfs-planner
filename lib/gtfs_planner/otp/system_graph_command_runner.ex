defmodule GtfsPlanner.Otp.SystemGraphCommandRunner do
  @moduledoc """
  Default graph command runner backed by `System.cmd/3`.
  """

  @behaviour GtfsPlanner.Otp.GraphCommandRunner

  @impl true
  def run(command, args, options \\ []) do
    configured_timeout_ms = Application.get_env(:gtfs_planner, :otp_graph_build_timeout_ms, 600_000)
    {timeout_ms, cmd_options} = Keyword.pop(options, :timeout, configured_timeout_ms)

    default_options = [stderr_to_stdout: true]
    merged_cmd_options = Keyword.merge(default_options, cmd_options)

    task = Task.async(fn -> System.cmd(command, args, merged_cmd_options) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {"Command timed out after #{timeout_ms}ms", 124}
    end
  end
end
