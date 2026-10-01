defmodule GtfsPlanner.Reachability do
  @moduledoc """
  Public context for station reachability runs. Owns run creation,
  supervised execution, terminal persistence, and PubSub notification.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability.{Battery, Runner, Scoring}
  alias GtfsPlanner.Repo
  alias GtfsPlanner.RunnerAdmission
  alias GtfsPlanner.Routing
  alias GtfsPlanner.Routing.{Route, StationGraph}
  alias GtfsPlanner.Validations.ValidationRun

  @pubsub GtfsPlanner.PubSub
  @runner_supervisor GtfsPlanner.Reachability.RunnerSupervisor

  # A run still active after this long is treated as orphaned by a restart or
  # deploy. Ceiling: a run that legitimately outlasts it is failed while still
  # working. Upgrade path: a heartbeat column the run task refreshes.
  @stale_run_after_seconds 15 * 60

  @interrupted_message "The run was interrupted before it finished."

  @spec start_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, ValidationRun.t()}
          | {:error,
             :station_not_found
             | :run_in_progress
             | :battery_too_large
             | :busy
             | Ecto.Changeset.t()}
  def start_run(organization_id, gtfs_version_id, station_stop_id, opts \\ []) do
    runner = Keyword.get(opts, :runner, Runner)

    with {:ok, station} <- fetch_station(organization_id, gtfs_version_id, station_stop_id),
         snapshot <- build_snapshot(organization_id, gtfs_version_id, station),
         :ok <- check_battery_size(snapshot),
         :ok <- fail_stale_runs(organization_id, gtfs_version_id, station_stop_id),
         {:ok, run} <- insert_run(organization_id, gtfs_version_id, station_stop_id) do
      case spawn_run(run, station, snapshot, runner) do
        {:ok, _pid} ->
          {:ok, Repo.reload!(run)}

        # The runner supervisor refuses at its :runner_limits cap before the task
        # starts, so a busy run has read nothing. Its failure frees the station's
        # active-run slot for the next attempt.
        {:error, reason} ->
          fail_run(run.id, if(reason == :busy, do: "busy", else: inspect(reason)))

          Phoenix.PubSub.broadcast(
            @pubsub,
            topic(run.id),
            {:reachability_run_failed, run.id, reason}
          )

          {:error, reason}
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
        r.started_at >= ^stale_run_cutoff() and
        fragment("result_json -> 'metadata' ->> 'station_stop_id' = ?", ^station_stop_id)
    )
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  # A run refused at capacity never started, so it is not a result to show.
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
        fragment("result_json -> 'metadata' ->> 'station_stop_id' = ?", ^station_stop_id) and
        (is_nil(r.error_details) or r.error_details != "busy")
    )
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @latest_station_run_ids_sql """
  SELECT s.id AS station_stop_id, r.id
  FROM unnest($3::text[]) AS s(id)
  CROSS JOIN LATERAL (
    SELECT id
    FROM gtfs_validation_runs
    WHERE organization_id = $1
      AND gtfs_version_id = $2
      AND run_type = 'station_reachability'
      AND status = 'completed'
      AND (result_json -> 'metadata' ->> 'station_stop_id') = s.id
    ORDER BY inserted_at DESC
    LIMIT 1
  ) AS r
  """

  @run_results_sql """
  SELECT id, completed_at, result_json ->> 'outcome',
         (result_json -> 'totals' ->> 'reachable')::int,
         (result_json -> 'totals' ->> 'pair_count')::int
  FROM gtfs_validation_runs
  WHERE id = ANY($1::uuid[])
  """

  @outcomes %{
    "passed" => :passed,
    "warning" => :warning,
    "failed" => :failed,
    "not_applicable" => :not_applicable
  }

  @type latest :: %{
          run_id: Ecto.UUID.t(),
          outcome: :passed | :warning | :failed | :not_applicable,
          reachable: non_neg_integer(),
          pair_count: non_neg_integer(),
          completed_at: DateTime.t()
        }

  @doc """
  Returns the newest completed reachability result per requested station.

  The map is keyed by station `stop_id`. A station without a completed run and a
  stored outcome outside the known outcomes are omitted.
  """
  @spec latest_by_station(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
          %{String.t() => latest()}
  def latest_by_station(_organization_id, _gtfs_version_id, []), do: %{}

  def latest_by_station(organization_id, gtfs_version_id, station_stop_ids) do
    %{rows: station_run_rows} =
      Repo.query!(@latest_station_run_ids_sql, [
        Ecto.UUID.dump!(organization_id),
        Ecto.UUID.dump!(gtfs_version_id),
        station_stop_ids
      ])

    run_ids = Enum.map(station_run_rows, fn [_station_stop_id, run_id] -> run_id end)
    results_by_run_id = run_results(run_ids)

    Enum.reduce(station_run_rows, %{}, fn [station_stop_id, run_id], latest ->
      with %{outcome: outcome_string} = result <- Map.get(results_by_run_id, run_id),
           {:ok, outcome} <- Map.fetch(@outcomes, outcome_string) do
        Map.put(latest, station_stop_id, %{
          run_id: Ecto.UUID.load!(run_id),
          outcome: outcome,
          reachable: result.reachable,
          pair_count: result.pair_count,
          completed_at: DateTime.from_naive!(result.completed_at, "Etc/UTC")
        })
      else
        _ -> latest
      end
    end)
  end

  # The EXPLAIN assertion in latest_by_station_test.exs plans the statement this
  # module runs, instead of a drifting copy of it.
  @doc false
  def latest_station_run_ids_sql, do: @latest_station_run_ids_sql

  defp run_results([]), do: %{}

  defp run_results(run_ids) do
    %{rows: rows} = Repo.query!(@run_results_sql, [run_ids])

    Map.new(rows, fn [run_id, completed_at, outcome, reachable, pair_count] ->
      {run_id,
       %{
         completed_at: completed_at,
         outcome: outcome,
         reachable: reachable,
         pair_count: pair_count
       }}
    end)
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

  @doc """
  Builds the routable station graph for on-demand planning.

  Results pages call this once and hold the graph, so expanding a pair costs a
  search rather than a rebuild. The graph is built exactly as `Runner` builds
  it, so an expanded trip matches the stored run.
  """
  @spec station_graph(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, StationGraph.t()} | {:error, :station_not_found}
  def station_graph(organization_id, gtfs_version_id, station_stop_id) do
    with {:ok, station} <- fetch_station(organization_id, gtfs_version_id, station_stop_id) do
      organization_id
      |> build_snapshot(gtfs_version_id, station)
      |> Routing.build_station_graph()
    end
  end

  @doc """
  Plans one origin/destination pair in both modes.

  The run stores per-pair totals but not the itineraries; this recovers the
  turn-by-turn detail for a single pair when someone asks for it.
  """
  @spec plan_pair(StationGraph.t(), String.t(), String.t()) :: %{
          walking: {:ok, Route.t()} | {:error, term()},
          wheelchair: {:ok, Route.t()} | {:error, term()}
        }
  def plan_pair(%StationGraph{} = graph, from_stop_id, to_stop_id) do
    %{
      walking: Routing.plan(graph, from_stop_id, to_stop_id, wheelchair: false),
      wheelchair: Routing.plan(graph, from_stop_id, to_stop_id, wheelchair: true)
    }
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

  # The task that would finish an active run dies with the node, so a row left
  # active past the timeout would otherwise block every later start.
  defp fail_stale_runs(organization_id, gtfs_version_id, station_stop_id) do
    now = DateTime.utc_now()

    ValidationRun
    |> where(
      [r],
      r.organization_id == ^organization_id and
        r.gtfs_version_id == ^gtfs_version_id and
        r.run_type == "station_reachability" and
        r.status in ["pending", "started", "running"] and
        r.started_at < ^stale_run_cutoff() and
        fragment("result_json -> 'metadata' ->> 'station_stop_id' = ?", ^station_stop_id)
    )
    |> Repo.update_all(
      set: [
        status: "failed",
        error_details: @interrupted_message,
        completed_at: now,
        updated_at: now
      ]
    )

    :ok
  end

  defp stale_run_cutoff, do: DateTime.add(DateTime.utc_now(), -@stale_run_after_seconds, :second)

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

  # The task holds one slot under the bounded supervisor until it exits, whatever
  # its result; a start at the cap returns `{:error, :busy}` and runs nothing.
  defp spawn_run(run, _station, snapshot, runner) do
    RunnerAdmission.start_child(
      @runner_supervisor,
      Supervisor.child_spec({Task, fn -> execute_run(run, snapshot, runner) end},
        restart: :temporary
      )
    )
  end

  defp execute_run(run, snapshot, runner) do
    run_id = run.id
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
