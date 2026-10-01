defmodule GtfsPlanner.Gtfs.Validator do
  @moduledoc """
  Context module for GTFS validation using the MobilityData GTFS Validator.

  This module handles the complete validation workflow:
  1. Exporting GTFS data to a temporary ZIP file
  2. Executing the Java-based validator CLI
  3. Parsing and structuring the validation results
  4. Broadcasting progress updates via PubSub

  The validation run's `run_type` selects the exported feed: a
  `"mobility_data_flex"` run validates the flex zip, every other run the full
  export.

  The validation process runs asynchronously and communicates progress
  through Phoenix.PubSub, allowing LiveViews to display real-time updates.
  """

  @behaviour GtfsPlanner.Gtfs.ValidatorBehaviour

  alias GtfsPlanner.Gtfs.{Export, ExportDefaults, Validator.Result}
  alias GtfsPlanner.Validations

  require Logger

  @pubsub GtfsPlanner.PubSub
  @phases [:exporting, :validating, :processing]

  # The CLI keeps only the last 64 KiB of its output, and `report.json` is read
  # only up to 64 MiB: a runaway validator cannot grow either without bound.
  @output_limit 65_536
  @report_limit 67_108_864

  # How long to wait for the kernel to report a killed process before giving up
  # on the exit status and closing the port anyway.
  @kill_wait_ms 5_000

  @cancel_message :gtfs_validator_cancel

  @doc """
  Validates GTFS data for a specific organization and version.

  ## Parameters
    - `organization_id` - The organization ID
    - `gtfs_version_id` - The GTFS version ID to validate
    - `opts` - Options keyword list, must include `:validation_run_id` for PubSub topic

  ## Returns
    - `{:ok, %Result{}}` on successful validation
    - `{:error, reason}` on failure, where `reason` is one of `:timeout` (the CLI
      outlived `:validator_timeout_ms`), `:cancelled` (see `cancel/1`),
      `:report_too_large`, `{:invalid_report, term}`, `{:cli_failed, exit_code, output}`,
      `{:persistence_failed, :mark_running | :mark_completed | :mark_failed}`, or
      an export or configuration error. A run whose terminal write failed is left
      `running` and is never reported as completed.

  ## Examples

      iex> validate(1, 2, validation_run_id: "uuid-here")
      {:ok, %Result{summary: %{errors: 0, warnings: 5, infos: 10}, ...}}

  """
  def validate(organization_id, gtfs_version_id, opts \\ []) do
    validation_run_id = Keyword.fetch!(opts, :validation_run_id)
    run = Validations.get_validation_run!(validation_run_id)
    start_time = System.monotonic_time(:millisecond)
    temp_dir_ref = make_ref()

    try do
      with :ok <- persist(:mark_running, fn -> Validations.mark_running(run) end) do
        broadcast_progress(run.id, :exporting, 10, "Generating GTFS export...")

        result =
          with {:ok, zip_path, temp_dir} <-
                 export_to_temp_file(
                   organization_id,
                   gtfs_version_id,
                   export_profile(run.run_type)
                 ) do
            # Store temp_dir for cleanup
            Process.put(temp_dir_ref, temp_dir)

            broadcast_progress(run.id, :exporting, 30, "Export complete")
            broadcast_progress(run.id, :validating, 50, "Running MobilityData validator...")

            case run_validator_cli(zip_path, temp_dir) do
              {:ok, output_dir} ->
                broadcast_progress(run.id, :validating, 90, "Validation complete")
                broadcast_progress(run.id, :processing, 95, "Processing results...")

                with {:ok, _validation_result} = parsed <- parse_report(output_dir, start_time) do
                  broadcast_progress(run.id, :processing, 100, "Done")
                  parsed
                end

              {:error, reason} = error ->
                Logger.error("Validator CLI failed: #{inspect(reason)}")
                error
            end
          end

        record_result(run, result)
      end
    rescue
      exception ->
        # The exception propagates, so a failed write here is only logged.
        persist(:mark_failed, fn -> Validations.mark_failed(run, exception) end)

        reraise exception, __STACKTRACE__
    after
      # Cleanup temp directory if it was created
      case Process.get(temp_dir_ref) do
        nil -> :ok
        temp_dir -> File.rm_rf(temp_dir)
      end
    end
  end

  @doc """
  Stops the validator CLI started by the process `pid` that is running `validate/3`.

  If the CLI is running, it is killed and `validate/3` returns `{:error, :cancelled}`.
  If the CLI has not started yet, it is never launched. The request is consumed by
  the next CLI launch in `pid`, so call this only for a process that is running or
  about to run `validate/3`. Only the process the port started is killed.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, @cancel_message)
    :ok
  end

  # Persists the outcome of the pipeline. A failed terminal write returns
  # `{:persistence_failed, operation}` instead of the pipeline's own result, and
  # a failed `mark_completed` leaves the run `running` for lease recovery.
  defp record_result(run, {:ok, validation_result}) do
    with :ok <-
           persist(:mark_completed, fn -> Validations.mark_completed(run, validation_result) end) do
      {:ok, validation_result}
    end
  end

  defp record_result(run, {:error, _reason} = error) do
    with :ok <- persist(:mark_failed, fn -> Validations.mark_failed(run, error) end) do
      error
    end
  end

  # Runs one run-status write and turns any failure, including a stale row, into
  # an explicit error instead of continuing as if it had been saved.
  defp persist(operation, write) do
    case write.() do
      {:ok, _row} -> :ok
      {:error, reason} -> persistence_failed(operation, reason)
    end
  rescue
    exception -> persistence_failed(operation, exception)
  end

  defp persistence_failed(operation, reason) do
    Logger.error("Failed to persist #{operation}: #{inspect(reason)}")
    {:error, {:persistence_failed, operation}}
  end

  @doc false
  defp broadcast_progress(validation_id, phase, percent, message) do
    unless phase in @phases do
      raise ArgumentError, "Invalid phase: #{inspect(phase)}. Must be one of #{inspect(@phases)}"
    end

    Phoenix.PubSub.broadcast(
      @pubsub,
      "validation:#{validation_id}",
      {:validation_progress, %{phase: phase, percent: percent, message: message}}
    )
  end

  @doc false
  defp export_profile("mobility_data_flex"), do: :flex
  defp export_profile(_run_type), do: :full

  @doc false
  defp export_module,
    do: Application.get_env(:gtfs_planner, :gtfs_export_module, Export)

  @doc false
  defp export_to_temp_file(organization_id, gtfs_version_id, export_profile) do
    unique_id = :erlang.unique_integer([:positive])
    temp_dir = System.tmp_dir!() |> Path.join("gtfs_validation_#{unique_id}")

    with :ok <- File.mkdir_p(temp_dir),
         {:ok, zip_binary} <-
           export_module().export_to_zip(organization_id, gtfs_version_id, export_profile,
             estimate: estimate_option(organization_id)
           ) do
      zip_path = Path.join(temp_dir, "gtfs.zip")

      case File.write(zip_path, zip_binary) do
        :ok -> {:ok, zip_path, temp_dir}
        {:error, reason} -> {:error, {:file_write_failed, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Validation estimates exactly what the current defaults say: unlike an
  # export run it has no recorded setting to read (INV-3), so current defaults
  # are the right source. A non-estimating organization passes nil and the
  # stored rows validate unchanged.
  defp estimate_option(organization_id) do
    defaults = ExportDefaults.get(organization_id)

    if defaults.estimate_missing_times, do: defaults.estimate_method, else: nil
  end

  @doc false
  # Runs `java -jar <validator>` through a port owned by the calling process.
  #
  # Options (all default from application config): `:java_path`,
  # `:validator_path` and `:timeout_ms` (`:validator_timeout_ms`, the deadline
  # for the whole CLI run). Returns `{:ok, output_dir}` on exit status 0,
  # `{:error, :timeout}` when the deadline passes, `{:error, :cancelled}` after
  # `cancel/1`, and `{:error, {:cli_failed, exit_code, last_output}}` otherwise,
  # where `last_output` holds at most the final 65,536 bytes.
  def run_validator_cli(zip_path, temp_dir, opts \\ []) do
    validator_path =
      Keyword.get(opts, :validator_path, Application.get_env(:gtfs_planner, :gtfs_validator_path))

    java_path =
      Keyword.get(opts, :java_path, Application.get_env(:gtfs_planner, :java_path, "java"))

    timeout_ms =
      Keyword.get_lazy(opts, :timeout_ms, fn ->
        Application.fetch_env!(:gtfs_planner, :validator_timeout_ms)
      end)

    # `:spawn_executable` does not search PATH, so resolve a bare `java` first.
    case {validator_path, System.find_executable(java_path)} do
      {nil, _java} ->
        {:error, :validator_path_not_configured}

      {_validator_path, nil} ->
        {:error, {:java_not_found, java_path}}

      {validator_path, java} ->
        if cancel_requested?() do
          {:error, :cancelled}
        else
          output_dir = Path.join(temp_dir, "output")
          File.mkdir_p!(output_dir)

          args = [
            "-jar",
            validator_path,
            "-i",
            zip_path,
            "-o",
            output_dir,
            "--skip_validator_update"
          ]

          deadline = System.monotonic_time(:millisecond) + timeout_ms

          port =
            Port.open(
              {:spawn_executable, java},
              [:binary, :exit_status, :stderr_to_stdout, args: args]
            )

          await_exit(port, deadline, "", output_dir)
        end
    end
  end

  defp cancel_requested? do
    receive do
      @cancel_message -> true
    after
      0 -> false
    end
  end

  # The deadline is absolute, so output arriving continuously cannot extend it.
  defp await_exit(port, deadline, output, output_dir) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining <= 0 ->
        stop_process(port, :timeout)

      remaining ->
        receive do
          {^port, {:data, data}} ->
            await_exit(port, deadline, retain_tail(output, data), output_dir)

          {^port, {:exit_status, 0}} ->
            {:ok, output_dir}

          {^port, {:exit_status, exit_code}} ->
            Logger.error("Validator CLI exited with code #{exit_code}: #{output}")
            {:error, {:cli_failed, exit_code, output}}

          @cancel_message ->
            stop_process(port, :cancelled)
        after
          remaining -> stop_process(port, :timeout)
        end
    end
  end

  # Keeps the last `@output_limit` bytes of everything the CLI wrote.
  defp retain_tail(output, data) do
    combined = output <> data
    excess = byte_size(combined) - @output_limit

    if excess > 0, do: binary_part(combined, excess, @output_limit), else: combined
  end

  # Kills the process the port started, waits for its exit status so the caller
  # can rely on it being gone, then closes the port. Descendants of that
  # process are not tracked: the MobilityData CLI is a single JVM.
  defp stop_process(port, reason) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      System.cmd("/bin/sh", ["-c", "kill -KILL " <> Integer.to_string(os_pid)],
        stderr_to_stdout: true
      )
    end

    await_killed(port)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    {:error, reason}
  end

  defp await_killed(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> await_killed(port)
    after
      @kill_wait_ms -> :ok
    end
  end

  @doc false
  # Reads `report.json` from `output_dir` into a `%Result{}`. A report over
  # `@report_limit` bytes is rejected from its size alone, without being read;
  # an unreadable, malformed or wrongly shaped report is `{:invalid_report, _}`.
  def parse_report(output_dir, start_time) do
    report_path = Path.join(output_dir, "report.json")

    with :ok <- check_report_size(report_path),
         {:ok, report_json} <- File.read(report_path),
         {:ok, report_data} <- Jason.decode(report_json),
         {:ok, notices} <- report_notices(report_data) do
      {:ok, build_result(notices, start_time)}
    else
      {:error, :report_too_large} = error -> error
      {:error, reason} -> {:error, {:invalid_report, reason}}
    end
  end

  defp build_result(notices, start_time) do
    notices_by_code = group_notices(notices)

    %Result{
      summary: summarize(notices_by_code),
      notices: notices_by_code,
      duration_ms: System.monotonic_time(:millisecond) - start_time,
      validated_at: DateTime.utc_now()
    }
  end

  # Group notices by code and severity
  defp group_notices(notices) do
    notices
    |> Enum.group_by(& &1["code"])
    |> Enum.reduce([], fn {code, code_notices}, acc ->
      case code_notices do
        [%{} = first | _] ->
          # All notices with same code should have same severity
          severity = first["severity"]

          notice_group = %{
            code: code,
            severity: severity,
            total_notices: length(code_notices),
            notices: code_notices
          }

          [notice_group | acc]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  # Calculate summary by severity
  defp summarize(notices_by_code) do
    Enum.reduce(notices_by_code, %{errors: 0, warnings: 0, infos: 0}, fn notice_group, acc ->
      count = notice_group.total_notices

      case String.downcase(notice_group.severity) do
        "error" -> %{acc | errors: acc.errors + count}
        "warning" -> %{acc | warnings: acc.warnings + count}
        "info" -> %{acc | infos: acc.infos + count}
        _ -> acc
      end
    end)
  end

  defp check_report_size(report_path) do
    case File.stat(report_path) do
      {:ok, %File.Stat{size: size}} when size > @report_limit -> {:error, :report_too_large}
      {:ok, _stat} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # A report the validator wrote always has a `notices` list of objects; any
  # other shape is a broken report, not a clean one.
  defp report_notices(%{"notices" => notices}) when is_list(notices) do
    if Enum.all?(notices, &is_map/1), do: {:ok, notices}, else: {:error, :malformed_notices}
  end

  defp report_notices(_report), do: {:error, :missing_notices}
end
