defmodule GtfsPlanner.Gtfs.Export.Worker do
  @moduledoc """
  Concrete, fenced export-build worker.

  Preflight warnings become durable before the exporter creates bytes.  Export
  warnings lead a non-empty operations export's durable warnings inside the
  100-entry limit.  The generated ZIPs are then published through the private
  artifact store and only become ready when `ExportRuns` verifies and commits
  their metadata: the main zip and, when the run includes flex, the flex zip
  published beside it.  A pair whose bytes exceed the configured run budget
  closes the run before either file is written.  A garage/stop ID collision is
  durable as one warning per conflicting garage and closes the run with its own
  failure code.
  """

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns

  @max_warnings 100
  @conflict_code "garage_stop_id_conflict"
  @conflict_file "stops_supplement.txt"
  @max_detail 4_096
  # The per-run artifact budget `ArtifactStorage.publish/6` enforces per file;
  # the same default is applied here to the run's combined bytes.
  @default_max_run_bytes 150 * 1024 * 1024

  @spec build(struct(), pos_integer(), Ecto.UUID.t(), String.t()) :: :ok
  def build(run, generation, token, _topic) do
    with :ok <- renew(run, generation, token),
         {:ok, warnings} <- preflight(run),
         {:ok, _run} <- persist_warnings(run, generation, token, warnings),
         :ok <- renew(run, generation, token) do
      build_artifact(run, generation, token, warnings)
    else
      # A cancellation uses the same fenced boundary as lease loss.  The
      # current owner is still responsible for turning its requested
      # cancellation into a terminal row; a stale owner is fenced out by
      # `fail_build/5`.
      {:error, :lease_lost} -> close(run, generation, token, "cancelled")
      {:error, reason} -> close(run, generation, token, failure_code(reason))
    end
  rescue
    error ->
      require Logger
      Logger.error(Exception.format(:error, error, __STACKTRACE__))
      close(run, generation, token, "export_failed")
  end

  # Builds from the warnings the export module returns.  The preflight warnings
  # stay in scope here so a collision can persist its own details ahead of them.
  defp build_artifact(run, generation, token, preflight_warnings) do
    case build_export(run) do
      {:ok, zips, export_warnings} ->
        with {:ok, _run} <-
               persist_export_warnings(
                 run,
                 generation,
                 token,
                 export_warnings,
                 preflight_warnings
               ),
             :ok <- renew(run, generation, token),
             :ok <- within_run_capacity(zips),
             {:ok, artifacts} <- publish_artifacts(run, zips),
             {:ok, _ready} <-
               ExportRuns.mark_ready(
                 run.organization_id,
                 run.id,
                 generation,
                 token,
                 artifacts
               ) do
          :ok
        else
          {:error, :lease_lost} -> close(run, generation, token, "cancelled")
          {:error, reason} -> close(run, generation, token, failure_code(reason))
        end

      {:error, {:garage_stop_id_conflict, conflicts}} ->
        fail_conflict(run, generation, token, conflicts, preflight_warnings)

      {:error, reason} ->
        close(run, generation, token, failure_code(reason))
    end
  end

  # `:full` and `:operations` build both zips from one snapshot, with the flex
  # zip only when the run recorded the switch; `:pathways` never carries flex
  # and keeps its single-zip path.
  defp build_export(%{export_type: :pathways} = run) do
    case export_module().build_zip(run.organization_id, run.gtfs_version_id, :pathways) do
      {:ok, zip_bytes, export_warnings} -> {:ok, %{main: zip_bytes, flex: nil}, export_warnings}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_export(run) do
    export_module().build_zips(run.organization_id, run.gtfs_version_id, run.export_type,
      include_flex: run.include_flex
    )
  end

  # Export warnings lead the persisted list inside the 100-entry limit.  An
  # export without warnings keeps the preflight warnings already stored.
  defp persist_export_warnings(_run, _generation, _token, [], _preflight_warnings),
    do: {:ok, nil}

  defp persist_export_warnings(run, generation, token, export_warnings, preflight_warnings) do
    persist_warnings(
      run,
      generation,
      token,
      Enum.take(export_warnings ++ preflight_warnings, @max_warnings)
    )
  end

  # A collision has no artifact to publish, so its warning write cannot change
  # the outcome; `close/4` is fenced the same way and records the named code for
  # the current owner.
  defp fail_conflict(run, generation, token, conflicts, preflight_warnings) do
    _ =
      persist_warnings(
        run,
        generation,
        token,
        Enum.take(conflict_warnings(conflicts) ++ preflight_warnings, @max_warnings)
      )

    close(run, generation, token, @conflict_code)
  end

  # One detail per conflicting garage, ordered by garage ID.  Above the warning
  # limit the first 99 stay actionable and one bounded notice names the rest.
  defp conflict_warnings(conflicts) do
    ordered = Enum.sort_by(conflicts, & &1.garage_id)

    if length(ordered) > @max_warnings do
      Enum.map(Enum.take(ordered, @max_warnings - 1), &conflict_warning/1) ++
        [remaining_conflicts_warning(length(ordered) - (@max_warnings - 1))]
    else
      Enum.map(ordered, &conflict_warning/1)
    end
  end

  defp conflict_warning(conflict) do
    %{
      code: @conflict_code,
      detail: conflict_detail(conflict),
      file: @conflict_file,
      entity_type: "garage"
    }
  end

  # Names the garage, its ID and the stop, which is the detail the Export page
  # shows for each conflict.
  defp conflict_detail(%{garage_id: garage_id, garage_name: garage_name, stop_name: stop_name}) do
    stop =
      if is_binary(stop_name) and String.trim(stop_name) != "" do
        "the stop \"#{stop_name}\""
      else
        "the stop \"#{garage_id}\""
      end

    String.slice(
      "Garage \"#{garage_name}\" (#{garage_id}) matches #{stop} in this exported version. Change the garage ID before exporting operations data.",
      0,
      @max_detail
    )
  end

  defp remaining_conflicts_warning(remaining) do
    %{
      code: @conflict_code,
      detail:
        "#{remaining} more garages match stop IDs in this exported version. Open Garages to review all current conflicts.",
      file: @conflict_file,
      entity_type: "garage"
    }
  end

  defp preflight(run) do
    warnings =
      case preflight_module() do
        nil ->
          []

        module ->
          case module.run(run.organization_id, run.gtfs_version_id, run.export_type) do
            :ok -> []
            {:error, issues} when is_list(issues) -> Enum.map(issues, &warning_from_issue/1)
            _ -> []
          end
      end

    {:ok, Enum.take(warnings, @max_warnings)}
  end

  defp persist_warnings(run, generation, token, warnings) do
    ExportRuns.persist_warnings(run.organization_id, run.id, generation, token, warnings)
  end

  defp renew(run, generation, token) do
    ExportRuns.renew_lease(run.organization_id, run.id, generation, token)
  end

  # The published pair shares one run budget: a main zip and a flex zip that
  # each fit can still exceed the configured per-run limit together.
  defp within_run_capacity(%{main: main, flex: flex}) do
    total_bytes = byte_size(main || <<>>) + byte_size(flex || <<>>)

    if total_bytes <= configured_max_run_bytes(),
      do: :ok,
      else: {:error, :artifact_capacity_exceeded}
  end

  defp configured_max_run_bytes do
    Application.get_env(:gtfs_planner, :gtfs_task_artifacts_max_run_bytes, @default_max_run_bytes)
  end

  # A version without fixed routes answers the flex zip as the whole feed (R15),
  # so those bytes take the primary artifact slot under the flex file's name.
  defp publish_artifacts(run, %{main: nil, flex: flex}) when is_binary(flex) do
    with {:ok, artifact} <- publish(run, flex_filename(run), flex) do
      {:ok, %{main: artifact, flex: nil}}
    end
  end

  defp publish_artifacts(run, %{main: main} = zips) when is_binary(main) do
    with {:ok, main_artifact} <- publish(run, "gtfs-#{run.id}.zip", main),
         {:ok, flex_artifact} <- publish_flex(run, Map.get(zips, :flex)) do
      {:ok, %{main: main_artifact, flex: flex_artifact}}
    end
  end

  defp publish_artifacts(_run, _zips), do: {:error, :no_data}

  defp publish_flex(_run, nil), do: {:ok, nil}

  defp publish_flex(run, flex_bytes) when is_binary(flex_bytes),
    do: publish(run, flex_filename(run), flex_bytes)

  defp flex_filename(run), do: "gtfs-flex-#{run.id}.zip"

  defp publish(run, filename, zip_bytes) do
    ArtifactStorage.publish(
      run.organization_id,
      run.gtfs_version_id,
      run.id,
      filename,
      zip_bytes,
      storage_options()
    )
  end

  defp storage_options do
    []
    |> maybe_put(:max_run_bytes, :gtfs_task_artifacts_max_run_bytes)
    |> maybe_put(:max_total_bytes, :gtfs_task_artifacts_max_total_bytes)
  end

  defp maybe_put(opts, option, config_key) do
    case Application.get_env(:gtfs_planner, config_key) do
      nil -> opts
      value -> Keyword.put(opts, option, value)
    end
  end

  defp warning_from_issue(issue) when is_map(issue) do
    %{
      code: issue |> Map.get(:code, Map.get(issue, "code", "preflight_warning")) |> to_string(),
      detail:
        issue
        |> Map.get(:message, Map.get(issue, "message", "Preflight reported an issue"))
        |> to_string()
        |> String.slice(0, 4_096)
    }
  end

  defp warning_from_issue(_),
    do: %{code: "preflight_warning", detail: "Preflight reported an issue"}

  defp close(run, generation, token, code) do
    _ = ExportRuns.fail_build(run.organization_id, run.id, generation, token, code)
    :ok
  end

  defp failure_code(:no_data), do: "no_data"
  defp failure_code(:artifact_storage_unavailable), do: "artifact_storage_unavailable"
  defp failure_code(:artifact_capacity_exceeded), do: "artifact_capacity_exceeded"
  defp failure_code(_), do: "export_failed"

  defp export_module,
    do: Application.get_env(:gtfs_planner, :gtfs_export_module, Export)

  defp preflight_module,
    do: Application.get_env(:gtfs_planner, :otp_preflight_module)
end
