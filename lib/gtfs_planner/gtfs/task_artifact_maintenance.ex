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
  @change_retained_states [
    :pending_compute,
    :computing,
    :review,
    :pending_apply,
    :applying,
    :partial
  ]
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
  @spec maintain() :: :ok
  def maintain do
    organization_ids()
    |> Enum.each(fn organization_id ->
      safely(fn -> ChangeRuns.reconcile_expired(organization_id) end)
      safely(fn -> ExportRuns.reconcile_expired(organization_id) end)
      safely(fn -> ExportRuns.cleanup_expired(organization_id) end)
    end)

    safely(fn -> ChangeArtifactStorage.reconcile(retained_change_runs()) end)
    safely(fn -> ArtifactStorage.reconcile(retained_export_run_ids()) end)
    safely(&cleanup_terminal_change_decisions/0)
    :ok
  end

  defp organization_ids do
    change_ids = Repo.all(from r in ChangeRun, select: r.organization_id, distinct: true)
    export_ids = Repo.all(from r in Run, select: r.organization_id, distinct: true)
    Enum.uniq(change_ids ++ export_ids)
  end

  defp retained_change_runs do
    Repo.all(from r in ChangeRun, where: r.state in ^@change_retained_states)
  end

  defp retained_export_run_ids do
    Repo.all(from r in Run, where: r.state in ^@export_retained_states, select: r.id)
  end

  defp cleanup_terminal_change_decisions do
    ttl_seconds = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, 86_400)

    from(d in ChangeDecision,
      join: r in ChangeRun,
      on: r.id == d.change_run_id,
      where: r.state not in ^@change_retained_states,
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
end
