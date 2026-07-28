defmodule GtfsPlanner.Reachability do
  @moduledoc """
  Public context for station reachability runs. Owns run creation,
  supervised execution, terminal persistence, and PubSub notification.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability.{Battery, Runner, Scoring}
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  @pubsub GtfsPlanner.PubSub

  @spec start_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, ValidationRun.t()}
          | {:error,
             :station_not_found | :run_in_progress | :battery_too_large | Ecto.Changeset.t()}
  def start_run(organization_id, gtfs_version_id, station_stop_id, opts \\ []) do
    runner = Keyword.get(opts, :runner, Runner)

    with {:ok, station} <- fetch_station(organization_id, gtfs_version_id, station_stop_id),
         snapshot <- build_snapshot(organization_id, gtfs_version_id, station),
         :ok <- check_battery_size(snapshot),
         {:ok, run} <- insert_run(organization_id, gtfs_version_id, station_stop_id) do
      case spawn_run(run, station, snapshot, runner) do
        {:ok, _pid} ->
          {:ok, Repo.reload!(run)}

        {:error, reason} ->
          fail_run(run.id, inspect(reason))

          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(run.id),
            {:reachability_run_failed, run.id, reason}
          )

          {:ok, Repo.reload!(run)}
      end
    end
  end

  @spec get_run(Ecto.UUID.t()) :: ValidationRun.t() | nil
  def get_run(run_id) do
    Repo.get(ValidationRun, run_id)
  end

  @spec get_active_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: ValidationRun.t() | nil
  def get_active_run(organization_id, gtfs_version_id, station_stop_id) do
    ValidationRun
    |> where(
      [r],
      r.organization_id == ^organization_id and
        r.gtfs_version_id == ^gtfs_version_id and
        r.run_type == "station_reachability" and
        r.status in ["pending", "started", "running"] and
        fragment("result_json -> 'metadata' ->> 'station_stop_id' = ?", ^station_stop_id)
    )
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec list_recent_runs(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), pos_integer()) :: [
          ValidationRun.t()
        ]
  def list_recent_runs(organization_id, gtfs_version_id, station_stop_id, limit \\ 10) do
    ValidationRun
    |> where(
      [r],
      r.organization_id == ^organization_id and
        r.gtfs_version_id == ^gtfs_version_id and
        r.run_type == "station_reachability" and
        fragment("result_json -> 'metadata' ->> 'station_stop_id' = ?", ^station_stop_id)
    )
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec topology_summary(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, :station_not_found}
  def topology_summary(organization_id, gtfs_version_id, station_stop_id) do
    with {:ok, station} <- fetch_station(organization_id, gtfs_version_id, station_stop_id) do
      snapshot = build_snapshot(organization_id, gtfs_version_id, station)
      pairs = Battery.derive(snapshot)

      {:ok,
       %{
         entrance_count: Enum.count(snapshot.child_stops, &(&1.location_type == 2)),
         platform_count: Enum.count(snapshot.child_stops, &(&1.location_type == 0)),
         pathway_count: length(snapshot.pathways),
         level_count: length(snapshot.levels),
         pair_count: length(pairs)
       }}
    end
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(run_id), do: "validation:#{run_id}"

  defp fetch_station(organization_id, gtfs_version_id, station_stop_id) do
    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, station_stop_id) do
      nil -> {:error, :station_not_found}
      station -> {:ok, station}
    end
  end

  defp build_snapshot(organization_id, gtfs_version_id, station) do
    child_stops = Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)
    pathways = Gtfs.list_pathways_for_station(organization_id, gtfs_version_id, station.id)
    levels = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

    %{station: station, child_stops: child_stops, pathways: pathways, levels: levels}
  end

  defp check_battery_size(snapshot) do
    pairs = Battery.derive(snapshot)

    if length(pairs) > Battery.max_pairs() do
      {:error, :battery_too_large}
    else
      :ok
    end
  end

  defp insert_run(organization_id, gtfs_version_id, station_stop_id) do
    now = DateTime.utc_now()

    %ValidationRun{}
    |> ValidationRun.changeset(%{
      run_type: "station_reachability",
      status: "running",
      engine: "pathways_router",
      result_schema_version: 1,
      started_at: now,
      result_json: %{
        "metadata" => %{"station_stop_id" => station_stop_id}
      }
    })
    |> Ecto.Changeset.put_change(:organization_id, organization_id)
    |> Ecto.Changeset.put_change(:gtfs_version_id, gtfs_version_id)
    |> Repo.insert()
    |> case do
      {:ok, run} ->
        {:ok, run}

      {:error, changeset} ->
        if active_run_conflict?(changeset) do
          {:error, :run_in_progress}
        else
          {:error, changeset}
        end
    end
  end

  defp active_run_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:result_json,
       {_,
        [
          constraint: :unique,
          constraint_name: "gtfs_validation_runs_active_station_reachability_index"
        ]}} ->
        true

      {:organization_id,
       {_,
        [
          constraint: :unique,
          constraint_name: "gtfs_validation_runs_active_station_reachability_index"
        ]}} ->
        true

      _ ->
        false
    end)
  end

  defp spawn_run(run, _station, snapshot, runner) do
    run_id = run.id

    Task.Supervisor.start_child(GtfsPlanner.TaskSupervisor, fn ->
      started_at = run.started_at

      try do
        case runner.run(snapshot, started_at) do
          {:ok, envelope} ->
            complete_run(run_id, envelope)

            Phoenix.PubSub.broadcast(
              @pubsub,
              topic(run_id),
              {:reachability_run_completed, run_id}
            )

          {:error, reason} ->
            fail_run(run_id, inspect(reason))

            Phoenix.PubSub.broadcast(
              @pubsub,
              topic(run_id),
              {:reachability_run_failed, run_id, reason}
            )
        end
      rescue
        e ->
          fail_run(run_id, Exception.message(e))

          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(run_id),
            {:reachability_run_failed, run_id, Exception.message(e)}
          )
      catch
        kind, reason ->
          fail_run(run_id, "#{kind}: #{inspect(reason)}")

          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(run_id),
            {:reachability_run_failed, run_id, reason}
          )
      end
    end)
  end

  defp complete_run(run_id, envelope) do
    counts =
      Scoring.counts(
        Enum.map(envelope["pairs"], fn p ->
          %{
            mode: String.to_existing_atom(p["mode"]),
            outcome: String.to_existing_atom(p["outcome"])
          }
        end)
      )

    run = Repo.get!(ValidationRun, run_id)

    run
    |> ValidationRun.changeset(%{
      status: "completed",
      result_json: envelope,
      errors_count: counts.errors,
      warnings_count: counts.warnings,
      infos_count: counts.infos,
      duration_ms: envelope["duration_ms"],
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp fail_run(run_id, reason) do
    run = Repo.get!(ValidationRun, run_id)

    run
    |> ValidationRun.changeset(%{
      status: "failed",
      error_details: reason,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end
end
