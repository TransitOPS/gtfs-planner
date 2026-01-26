defmodule GtfsPlanner.Gtfs.Validator do
  @moduledoc """
  Context module for GTFS validation using the MobilityData GTFS Validator.

  This module handles the complete validation workflow:
  1. Exporting GTFS data to a temporary ZIP file
  2. Executing the Java-based validator CLI
  3. Parsing and structuring the validation results
  4. Broadcasting progress updates via PubSub

  The validation process runs asynchronously and communicates progress
  through Phoenix.PubSub, allowing LiveViews to display real-time updates.
  """

  @behaviour GtfsPlanner.Gtfs.ValidatorBehaviour

  alias GtfsPlanner.Gtfs.{Export, Validator.Result}
  alias GtfsPlanner.Validations

  require Logger

  @pubsub GtfsPlanner.PubSub
  @phases [:exporting, :validating, :processing]

  @doc """
  Validates GTFS data for a specific organization and version.

  ## Parameters
    - `organization_id` - The organization ID
    - `gtfs_version_id` - The GTFS version ID to validate
    - `opts` - Options keyword list, must include `:validation_run_id` for PubSub topic

  ## Returns
    - `{:ok, %Result{}}` on successful validation
    - `{:error, reason}` on failure

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
      handle_db_operation(
        "mark validation run as running",
        fn -> Validations.mark_running(run) end
      )

      broadcast_progress(run.id, :exporting, 10, "Generating GTFS export...")

      result =
        with {:ok, zip_path, temp_dir} <- export_to_temp_file(organization_id, gtfs_version_id) do
          # Store temp_dir for cleanup
          Process.put(temp_dir_ref, temp_dir)

          broadcast_progress(run.id, :exporting, 30, "Export complete")
          broadcast_progress(run.id, :validating, 50, "Running MobilityData validator...")

          case run_validator_cli(zip_path, temp_dir) do
            {:ok, output_dir} ->
              broadcast_progress(run.id, :validating, 90, "Validation complete")
              broadcast_progress(run.id, :processing, 95, "Processing results...")

              result = parse_report(output_dir, start_time)

              broadcast_progress(run.id, :processing, 100, "Done")
              {:ok, result}

            {:error, reason} = error ->
              Logger.error("Validator CLI failed: #{inspect(reason)}")
              error
          end
        end

      case result do
        {:ok, validation_result} ->
          handle_db_operation(
            "mark validation run as completed",
            fn -> Validations.mark_completed(run, validation_result) end
          )

          {:ok, validation_result}

        {:error, _reason} = error ->
          handle_db_operation(
            "mark validation run as failed",
            fn -> Validations.mark_failed(run, error) end
          )

          error
      end
    rescue
      exception ->
        handle_db_operation(
          "mark validation run as failed",
          fn -> Validations.mark_failed(run, exception) end
        )

        reraise exception, __STACKTRACE__
    after
      # Cleanup temp directory if it was created
      case Process.get(temp_dir_ref) do
        nil -> :ok
        temp_dir -> File.rm_rf(temp_dir)
      end
    end
  end

  @doc false
  # Executes a database operation and handles any errors gracefully.
  #
  # This function ensures that validation can proceed even if database
  # operations fail due to connection issues or other errors. It logs
  # all failures but always returns :ok to allow the validation flow
  # to continue.
  #
  # ## Parameters
  #   - operation_name: A descriptive name for the operation (used in logs)
  #   - operation_fn: A zero-arity function that performs the database operation
  #
  # ## Returns
  #   Always returns :ok, regardless of success or failure
  #
  defp handle_db_operation(operation_name, operation_fn) when is_function(operation_fn, 0) do
    try do
      case operation_fn.() do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to #{operation_name}: #{inspect(reason)}")
          :ok
      end
    rescue
      exception ->
        Logger.error("Exception while trying to #{operation_name}: #{inspect(exception)}")
        :ok
    end
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
  defp export_to_temp_file(organization_id, gtfs_version_id) do
    unique_id = :erlang.unique_integer([:positive])
    temp_dir = System.tmp_dir!() |> Path.join("gtfs_validation_#{unique_id}")

    with :ok <- File.mkdir_p(temp_dir),
         {:ok, zip_binary} <- Export.export_to_zip(organization_id, gtfs_version_id, :full, []) do
      zip_path = Path.join(temp_dir, "gtfs.zip")

      case File.write(zip_path, zip_binary) do
        :ok -> {:ok, zip_path, temp_dir}
        {:error, reason} -> {:error, {:file_write_failed, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  defp run_validator_cli(zip_path, temp_dir) do
    validator_path = Application.get_env(:gtfs_planner, :gtfs_validator_path)
    java_path = Application.get_env(:gtfs_planner, :java_path, "java")

    unless validator_path do
      {:error, :validator_path_not_configured}
    else
      output_dir = Path.join(temp_dir, "output")
      File.mkdir_p!(output_dir)

      args = [
        "-jar",
        validator_path,
        "-i",
        zip_path,
        "-o",
        output_dir
      ]

      case System.cmd(java_path, args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, output_dir}

        {output, exit_code} ->
          Logger.error("Validator CLI exited with code #{exit_code}: #{output}")
          {:error, {:cli_failed, exit_code, output}}
      end
    end
  end

  @doc false
  defp parse_report(output_dir, start_time) do
    report_path = Path.join(output_dir, "report.json")

    with {:ok, report_json} <- File.read(report_path),
         {:ok, report_data} <- Jason.decode(report_json) do
      notices =
        case report_data do
          %{} -> Map.get(report_data, "notices", [])
          _ -> []
        end

      notices =
        case notices do
          list when is_list(list) -> list
          _ -> []
        end

      # Group notices by code and severity
      notices_by_code =
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

      # Calculate summary by severity
      summary =
        notices_by_code
        |> Enum.reduce(%{errors: 0, warnings: 0, infos: 0}, fn notice_group, acc ->
          count = notice_group.total_notices

          case String.downcase(notice_group.severity) do
            "error" -> %{acc | errors: acc.errors + count}
            "warning" -> %{acc | warnings: acc.warnings + count}
            "info" -> %{acc | infos: acc.infos + count}
            _ -> acc
          end
        end)

      duration_ms = System.monotonic_time(:millisecond) - start_time

      %Result{
        summary: summary,
        notices: notices_by_code,
        duration_ms: duration_ms,
        validated_at: DateTime.utc_now()
      }
    else
      {:error, reason} ->
        {:error, {:invalid_report, reason}}
    end
  end
end