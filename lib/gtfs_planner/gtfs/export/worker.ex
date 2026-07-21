defmodule GtfsPlanner.Gtfs.Export.Worker do
  @moduledoc """
  Concrete, fenced export-build worker.

  Preflight warnings become durable before the exporter creates bytes.  The
  generated ZIP is then published through the private artifact store and only
  becomes ready when `ExportRuns` verifies and commits its metadata.
  """

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Otp.Preflight

  @spec build(struct(), pos_integer(), Ecto.UUID.t(), String.t()) :: :ok
  def build(run, generation, token, _topic) do
    with :ok <- renew(run, generation, token),
         {:ok, warnings} <- preflight(run),
         {:ok, _run} <- persist_warnings(run, generation, token, warnings),
         :ok <- renew(run, generation, token),
         {:ok, zip_bytes} <-
           export_module().export_to_zip(
             run.organization_id,
             run.gtfs_version_id,
             run.export_type
           ),
         :ok <- renew(run, generation, token),
         {:ok, artifact} <- publish(run, zip_bytes),
         {:ok, _ready} <-
           ExportRuns.mark_ready(run.organization_id, run.id, generation, token, artifact) do
      :ok
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

  defp preflight(run) do
    warnings =
      case preflight_module().run(run.organization_id, run.gtfs_version_id) do
        :ok -> []
        {:error, issues} when is_list(issues) -> Enum.map(issues, &warning_from_issue/1)
        _ -> []
      end

    {:ok, Enum.take(warnings, 100)}
  end

  defp persist_warnings(run, generation, token, warnings) do
    ExportRuns.persist_warnings(run.organization_id, run.id, generation, token, warnings)
  end

  defp renew(run, generation, token) do
    ExportRuns.renew_lease(run.organization_id, run.id, generation, token)
  end

  defp publish(run, zip_bytes) do
    ArtifactStorage.publish(
      run.organization_id,
      run.gtfs_version_id,
      run.id,
      "gtfs-#{run.id}.zip",
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
    do: Application.get_env(:gtfs_planner, :otp_preflight_module, Preflight)
end
