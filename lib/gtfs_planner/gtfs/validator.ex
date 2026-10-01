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

  `validate/3` only returns a result; it never writes the run row. The run's
  claim, lease, completion and failure belong to `GtfsPlanner.Validations.Runner`,
  which calls it in a supervised task and reports progress to LiveViews through
  Phoenix.PubSub.

  `validate_artifact/3` is the same validator over one already-exported artifact:
  it feeds the CLI the exact bytes a publication pin holds instead of exporting
  current database state a second time, so a report can only describe the bytes
  its run recorded in `artifact_sha256`.
  """

  @behaviour GtfsPlanner.Gtfs.ValidatorBehaviour

  alias GtfsPlanner.Gtfs.{Export, ExportDefaults, ExportRuns, Validator.Result}
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

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

  # Matches the ValidationRun validator_version bound, so a captured version
  # always survives the same server-owned validation the lease write performs.
  @max_validator_version_bytes 128

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
      or an export or configuration error.

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
      broadcast_progress(run.id, :exporting, 10, "Generating GTFS export...")

      with {:ok, input} <-
             export_to_temp_file(
               organization_id,
               gtfs_version_id,
               export_profile(run.run_type)
             ) do
        # Store temp_dir for cleanup
        Process.put(temp_dir_ref, input.temp_dir)

        broadcast_progress(run.id, :exporting, 30, "Export complete")
        broadcast_progress(run.id, :validating, 50, "Running MobilityData validator...")

        case run_validator_cli(input.zip_path, input.temp_dir) do
          {:ok, output_dir} ->
            broadcast_progress(run.id, :validating, 90, "Validation complete")
            broadcast_progress(run.id, :processing, 95, "Processing results...")

            with {:ok, validation_result} <- parse_report(output_dir, start_time) do
              broadcast_progress(run.id, :processing, 100, "Done")
              {:ok, record_checked_input(validation_result, input)}
            end

          {:error, reason} = error ->
            Logger.error("Validator CLI failed: #{inspect(reason)}")
            error
        end
      end
    after
      # Cleanup temp directory if it was created
      case Process.get(temp_dir_ref) do
        nil -> :ok
        temp_dir -> File.rm_rf(temp_dir)
      end
    end
  end

  @doc """
  Validates the exact artifact bytes one artifact-bound validation run selected.

  The run's stored `artifact_sha256`, export run and slot are the only input: the
  pinned bytes are read through `ExportRuns.pinned_artifact/4`, re-hashed by the
  same ready-artifact verification a download claim uses, and handed to the CLI
  without a second export. A hash that no longer matches the run's record is
  refused rather than reported on.

  Returns the same `{:ok, %Result{}}` / `{:error, reason}` shapes as `validate/3`
  and, like it, never writes the run row.
  """
  @spec validate_artifact(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def validate_artifact(organization_id, validation_run_id, opts \\ []) do
    _opts = opts
    start_time = System.monotonic_time(:millisecond)

    with %ValidationRun{organization_id: ^organization_id} = run <-
           Validations.get_validation_run(validation_run_id),
         true <- ValidationRun.artifact_run?(run),
         {:ok, artifact} <- pinned_artifact_for(run),
         :ok <- expect_hash(run, artifact) do
      run_artifact_cli(run, artifact, start_time)
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_artifact_run}
      {:error, _reason} = error -> error
    end
  end

  defp pinned_artifact_for(run) do
    ExportRuns.pinned_artifact(
      run.organization_id,
      run.artifact_export_run_id,
      run.artifact_slot,
      Validations.artifact_pin_claim(run)
    )
  end

  # The pin reader returns the run's recorded metadata only after re-hashing the
  # file, so a mismatch means these are not the bytes this run reviewed.
  defp expect_hash(run, artifact) do
    if artifact.sha256 == run.artifact_sha256,
      do: :ok,
      else: {:error, :artifact_hash_mismatch}
  end

  defp run_artifact_cli(run, artifact, start_time) do
    temp_dir =
      Path.join(System.tmp_dir!(), "gtfs_validation_#{System.unique_integer([:positive])}")

    try do
      :ok = File.mkdir_p(temp_dir)

      broadcast_progress(run.id, :validating, 50, "Running MobilityData validator...")

      case run_validator_cli(artifact.path, temp_dir) do
        {:ok, output_dir} ->
          broadcast_progress(run.id, :processing, 95, "Processing results...")

          with {:ok, _result} = parsed <- parse_report(output_dir, start_time) do
            broadcast_progress(run.id, :processing, 100, "Done")
            parsed
          end

        {:error, reason} = error ->
          Logger.error("Validator CLI failed for artifact validation: #{inspect(reason)}")
          error
      end
    after
      File.rm_rf(temp_dir)
    end
  end

  @doc """
  Stops the validator CLI started by the process `pid` that is running `validate/3`
  or `validate_artifact/3`.

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
  # Reads the estimate exactly once and carries that value, the profile it was
  # exported under and the digest of the written bytes forward, so the run can
  # record the input it was actually given without a second export or a second
  # defaults read (INV-2).
  defp export_to_temp_file(organization_id, gtfs_version_id, export_profile) do
    unique_id = :erlang.unique_integer([:positive])
    temp_dir = System.tmp_dir!() |> Path.join("gtfs_validation_#{unique_id}")
    estimate = estimate_option(organization_id)

    with :ok <- File.mkdir_p(temp_dir),
         {:ok, zip_binary} <-
           export_module().export_to_zip(organization_id, gtfs_version_id, export_profile,
             estimate: estimate
           ) do
      write_checked_input(zip_binary, temp_dir, export_profile, estimate)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_checked_input(zip_binary, temp_dir, export_profile, estimate) do
    zip_path = Path.join(temp_dir, "gtfs.zip")

    case File.write(zip_path, zip_binary) do
      :ok ->
        {:ok,
         %{
           zip_path: zip_path,
           temp_dir: temp_dir,
           zip_sha256: sha256(zip_binary),
           export_profile: checked_export_profile(export_profile, estimate)
         }}

      {:error, reason} ->
        {:error, {:file_write_failed, reason}}
    end
  end

  defp sha256(binary) do
    :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
  end

  # A `:flex` run checks the companion artifact of a full export; every other
  # run checks the primary artifact, which never carries flex.
  defp checked_export_profile(:flex, estimate) do
    %{
      schema_version: 1,
      export_type: "full",
      include_flex: true,
      artifact_kind: "flex",
      estimate_method: estimate && Atom.to_string(estimate)
    }
  end

  defp checked_export_profile(_export_profile, estimate) do
    %{
      schema_version: 1,
      export_type: "full",
      include_flex: false,
      artifact_kind: "primary",
      estimate_method: estimate && Atom.to_string(estimate)
    }
  end

  @doc false
  # The returned result describes the exact input the validator read: the digest
  # and profile come from the captured export, never from a fresh export or a
  # fresh defaults read. The validator version was set by `parse_report/2` from
  # the report's own metadata and is nil when the report carried none.
  defp record_checked_input(%Result{} = result, %{zip_sha256: digest, export_profile: profile}) do
    %{result | checked_zip_sha256: digest, checked_export_profile: profile}
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
         {:ok, groups} <- normalize_report(report_data) do
      {:ok, build_result(groups, report_validator_version(report_data), start_time)}
    else
      {:error, :report_too_large} = error -> error
      {:error, reason} -> {:error, {:invalid_report, reason}}
    end
  end

  defp build_result(groups, validator_version, start_time) do
    %Result{
      summary: summarize(groups),
      notices: groups,
      duration_ms: System.monotonic_time(:millisecond) - start_time,
      validated_at: DateTime.utc_now(),
      validator_version: validator_version
    }
  end

  # The validator emits one grouped `{code, severity, totalNotices,
  # sampleNotices}` object per code and severity; retained reports and the flat
  # adapter form emit one object per notice. Both are normalized to Result
  # groups, and a report mixing the two forms is ambiguous rather than clean.
  defp normalize_report(%{"notices" => notices}) when is_list(notices) do
    if Enum.all?(notices, &is_map/1) do
      with :ok <- single_notice_form(notices),
           {:ok, entries} <- notice_entries(notices) do
        {:ok, merge_entries(entries)}
      end
    else
      {:error, :malformed_notices}
    end
  end

  defp normalize_report(_report), do: {:error, :missing_notices}

  defp single_notice_form([]), do: :ok

  defp single_notice_form([%{} = first | rest]) do
    if Enum.all?([first | rest], &(grouped_notice?(&1) == grouped_notice?(first))),
      do: :ok,
      else: {:error, :mixed_notice_forms}
  end

  defp grouped_notice?(notice) do
    Map.has_key?(notice, "totalNotices") or Map.has_key?(notice, "sampleNotices")
  end

  defp notice_entries(notices) do
    notices
    |> Enum.map(&notice_entry/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, entry}, {:ok, acc} -> {:cont, {:ok, [entry | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp notice_entry(notice) do
    with {:ok, code} <- notice_code(notice),
         {:ok, severity} <- notice_severity(notice) do
      if grouped_notice?(notice) do
        grouped_entry(notice, code, severity)
      else
        {:ok, %{code: code, severity: severity, total: 1, notices: [notice]}}
      end
    end
  end

  # A group keeps the upstream total and the retained samples as separate facts:
  # the sample never replaces the count it was cut from.
  defp grouped_entry(notice, code, severity) do
    with {:ok, total} <- total_notices(notice),
         {:ok, samples} <- sample_notices(notice) do
      if total >= length(samples) do
        {:ok, %{code: code, severity: severity, total: total, notices: samples}}
      else
        {:error, {:fewer_totals_than_samples, code, severity}}
      end
    end
  end

  defp notice_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp notice_code(_notice), do: {:error, :malformed_code}

  defp notice_severity(%{"severity" => severity}) when is_binary(severity), do: {:ok, severity}
  defp notice_severity(_notice), do: {:error, :malformed_severity}

  defp total_notices(%{"totalNotices" => total}) when is_integer(total) and total >= 0,
    do: {:ok, total}

  defp total_notices(_notice), do: {:error, :malformed_total}

  defp sample_notices(%{"sampleNotices" => samples}) when is_list(samples) do
    if Enum.all?(samples, &is_map/1), do: {:ok, samples}, else: {:error, :malformed_samples}
  end

  defp sample_notices(_notice), do: {:error, :malformed_samples}

  # Groups are keyed by code *and* severity, so one code reported at two
  # severities stays two groups with their own totals.
  defp merge_entries(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.update(
        acc,
        {entry.code, entry.severity},
        entry,
        &%{&1 | total: &1.total + entry.total, notices: &1.notices ++ entry.notices}
      )
    end)
    |> Enum.map(fn {{code, severity}, entry} ->
      %{
        code: code,
        severity: severity,
        total_notices: entry.total,
        notices: entry.notices,
        retained_notices: length(entry.notices),
        sample_completeness: completeness(entry)
      }
    end)
  end

  defp completeness(%{total: total, notices: notices}) do
    if length(notices) == total, do: :complete, else: :sampled
  end

  # Only metadata the report actually carried is recorded. An absent, blank,
  # non-string or oversized value leaves the run's version metadata unknown
  # rather than guessed.
  defp report_validator_version(%{"summary" => %{"validatorVersion" => version}})
       when is_binary(version) and byte_size(version) <= @max_validator_version_bytes,
       do: if(String.trim(version) == "", do: nil, else: version)

  defp report_validator_version(_report), do: nil

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
end
