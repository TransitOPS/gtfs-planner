defmodule GtfsPlanner.Gtfs.TaskArtifactMaintenance do
  @moduledoc """
  Periodically reconciles durable task leases and their private filesystem artifacts.

  Database rows remain the authority: active/retained run IDs are read first, then
  storage reconciliation removes only directories that no durable retained row owns.
  """

  use GenServer

  import Ecto.Query, warn: false

  require Logger

  alias GtfsPlanner.Gtfs.Export.{ArtifactStorage, Run}
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Import.{ChangeArtifactStorage, ChangeDecision, ChangeRun, ChangeRuns}
  alias GtfsPlanner.Repo

  @default_interval_ms :timer.minutes(5)
  @change_active_states [
    :pending_compute,
    :computing,
    :review,
    :pending_apply,
    :applying,
    :partial
  ]
  @change_retryable_states [:failed, :interrupted, :cancelled, :expired]
  @export_retained_states [:pending, :building, :ready]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, configured_interval_ms())
    send(self(), :maintain)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:maintain, state) do
    maintain()
    Process.send_after(self(), :maintain, state.interval_ms)
    {:noreply, state}
  end

  @doc false
  @spec maintain(keyword()) :: :ok
  def maintain(opts \\ []) do
    organization_ids()
    |> Enum.each(fn organization_id ->
      safely(fn -> ChangeRuns.reconcile_expired(organization_id) end)
      safely(fn -> ExportRuns.reconcile_expired(organization_id) end)
      safely(fn -> ExportRuns.cleanup_expired(organization_id) end)
    end)

    safely(fn -> reconcile_change_artifacts(opts) end)

    safely(fn -> ArtifactStorage.reconcile(retained_export_run_ids()) end)
    safely(&cleanup_terminal_change_decisions/0)
    :ok
  end

  defp reconcile_change_artifacts(opts) do
    ChangeArtifactStorage.with_root_lock(fn ->
      runs = retained_change_runs()
      after_change_snapshot(opts)

      ChangeArtifactStorage.reconcile(runs,
        orphan_grace_seconds: orphan_grace_seconds()
      )
    end)
  end

  defp after_change_snapshot(opts) do
    case Keyword.get(opts, :after_change_snapshot) do
      hook when is_function(hook, 0) -> hook.()
      nil -> :ok
    end
  end

  defp organization_ids do
    change_ids = Repo.all(from r in ChangeRun, select: r.organization_id, distinct: true)
    export_ids = Repo.all(from r in Run, select: r.organization_id, distinct: true)
    Enum.uniq(change_ids ++ export_ids)
  end

  defp retained_change_runs do
    ttl_seconds = artifact_ttl_seconds()

    Repo.all(
      from r in ChangeRun,
        where:
          r.state in ^@change_active_states or
            (r.state in ^@change_retryable_states and
               r.finished_at >=
                 fragment("CURRENT_TIMESTAMP - (? * interval '1 second')", ^ttl_seconds))
    )
  end

  defp retained_export_run_ids do
    Repo.all(from r in Run, where: r.state in ^@export_retained_states, select: r.id)
  end

  defp cleanup_terminal_change_decisions do
    ttl_seconds = artifact_ttl_seconds()

    from(d in ChangeDecision,
      join: r in ChangeRun,
      on: r.id == d.change_run_id,
      where: r.state not in ^@change_active_states,
      where:
        r.finished_at <
          fragment("CURRENT_TIMESTAMP - (? * interval '1 second')", ^ttl_seconds)
    )
    |> Repo.delete_all()
  end

  defp safely(fun) do
    case fun.() do
      {:error, reason} -> Logger.warning("Task artifact maintenance failed: #{inspect(reason)}")
      _ -> :ok
    end
  rescue
    error -> Logger.error("Task artifact maintenance crashed: #{Exception.message(error)}")
  end

  defp configured_interval_ms do
    Application.get_env(
      :gtfs_planner,
      :task_artifact_maintenance_interval_ms,
      @default_interval_ms
    )
  end

  defp artifact_ttl_seconds do
    Application.get_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, 86_400)
  end

  defp orphan_grace_seconds do
    Application.get_env(:gtfs_planner, :gtfs_task_artifacts_orphan_grace_seconds, 300)
  end
end
