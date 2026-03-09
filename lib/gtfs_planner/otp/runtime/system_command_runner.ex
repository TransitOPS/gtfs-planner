defmodule GtfsPlanner.Otp.Runtime.SystemCommandRunner do
  @moduledoc """
  Default runtime command runner backed by OS process primitives.
  """

  @behaviour GtfsPlanner.Otp.Runtime.CommandRunner

  @default_startup_grace_ms 100
  @default_shutdown_timeout_ms 5_000
  @default_force_kill_wait_ms 1_000

  @impl true
  def start(command, args, opts \\ []) do
    startup_grace_ms = Keyword.get(opts, :startup_grace_ms, @default_startup_grace_ms)

    port_options =
      opts
      |> Keyword.get(:port_options, [])
      |> Keyword.merge(args: args)
      |> then(&[:binary, :exit_status, :use_stdio, :stderr_to_stdout | &1])

    with {:ok, port} <- open_port(command, port_options),
         :running <- wait_for_startup_exit(port, startup_grace_ms) do
      {:ok, %{port: port, os_pid: os_pid(port)}}
    else
      {:error, _} = error ->
        error

      {:exited, status} ->
        {:error,
         %{
           reason: :start_failed,
           command: command,
           args: args,
           exit_status: status
         }}
    end
  end

  @impl true
  def stop(process_handle, opts \\ [])

  def stop(%{port: port} = process_handle, opts) when is_port(port) do
    shutdown_timeout_ms = Keyword.get(opts, :shutdown_timeout_ms, @default_shutdown_timeout_ms)
    force_kill_wait_ms = Keyword.get(opts, :force_kill_wait_ms, @default_force_kill_wait_ms)
    os_pid = Map.get(process_handle, :os_pid) || os_pid(port)
    monitor_ref = Port.monitor(port)

    case terminate_and_wait(port, os_pid, monitor_ref, shutdown_timeout_ms) do
      :ok ->
        :ok

      :timeout ->
        with :ok <- send_signal(os_pid, "-KILL"),
             :ok <- await_down(monitor_ref, port, force_kill_wait_ms) do
          :ok
        else
          {:error, _} = error -> error
          :timeout -> {:error, %{reason: :stop_timeout, timeout_ms: shutdown_timeout_ms}}
        end

      {:error, _} = error ->
        error
    end
  end

  def stop(_process_handle, _opts), do: {:error, %{reason: :invalid_process_handle}}

  defp open_port(command, port_options) do
    try do
      port = Port.open({:spawn_executable, String.to_charlist(command)}, port_options)
      {:ok, port}
    rescue
      error in ArgumentError ->
        {:error, %{reason: :start_failed, details: Exception.message(error)}}
    end
  end

  defp wait_for_startup_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> {:exited, status}
    after
      timeout_ms -> :running
    end
  end

  defp terminate_and_wait(_port, nil, monitor_ref, timeout_ms) do
    await_down(monitor_ref, nil, timeout_ms)
  end

  defp terminate_and_wait(port, os_pid, monitor_ref, timeout_ms) do
    with :ok <- send_signal(os_pid, "-TERM"),
         :ok <- await_down(monitor_ref, port, timeout_ms) do
      :ok
    else
      :timeout -> :timeout
      {:error, _} = error -> error
    end
  end

  defp await_down(monitor_ref, port, timeout_ms) do
    receive do
      {:DOWN, ^monitor_ref, :port, _port, _reason} -> :ok
      {^port, {:exit_status, _status}} -> await_down(monitor_ref, port, timeout_ms)
    after
      timeout_ms -> :timeout
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp send_signal(nil, _signal), do: :ok

  defp send_signal(os_pid, signal) when is_integer(os_pid) do
    args = [signal, Integer.to_string(os_pid)]

    case System.cmd("kill", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, 1} ->
        :ok

      {output, exit_code} ->
        {:error, %{reason: :signal_failed, output: output, exit_code: exit_code}}
    end
  end
end
