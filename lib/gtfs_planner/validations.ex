defmodule GtfsPlanner.Validations do
  @moduledoc """
  The Validations context for managing GTFS validation runs.
  """

  import Ecto.Query

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.PathwaysTripTestRunner
  alias GtfsPlanner.Validations.ValidationRun
  alias GtfsPlanner.Validations.WalkabilityTestRunResult
  alias GtfsPlanner.Validations.WalkabilityTest

  @pathways_report_version 1

  @doc """
  Creates a new validation run with status "started".

  ## Examples

      iex> create_validation_run(org_id, version_id, "mobility_data")
      {:ok, %ValidationRun{}}

      iex> create_validation_run(nil, version_id, "mobility_data")
      {:error, %Ecto.Changeset{}}

  """
  def create_validation_run(organization_id, gtfs_version_id, run_type) do
    %ValidationRun{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      started_at: DateTime.utc_now()
    }
    |> ValidationRun.changeset(%{
      run_type: run_type,
      status: "started"
    })
    |> Repo.insert()
  end

  @doc """
  Creates a pathways validation run with status `started`.
  """
  @spec create_pathways_validation_run(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t()}
  def create_pathways_validation_run(organization_id, gtfs_version_id) do
    create_validation_run(organization_id, gtfs_version_id, "pathways_tests")
  end

  @doc """
  Creates a station reachability validation run with status `pending`.

  The station identifier is persisted in station run metadata so downstream
  station-scoped execution can read it deterministically.
  """
  @spec create_station_reachability_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t()}
  def create_station_reachability_run(organization_id, gtfs_version_id, station_stop_id)
      when is_binary(station_stop_id) do
    run_metadata = station_reachability_run_metadata(station_stop_id)

    %ValidationRun{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      started_at: DateTime.utc_now()
    }
    |> ValidationRun.changeset(%{
      run_type: "station_reachability",
      status: "pending",
      result_json: %{
        "metadata" => run_metadata
      }
    })
    |> Repo.insert()
  end

  @spec station_reachability_run_metadata(String.t()) :: map()
  defp station_reachability_run_metadata(station_stop_id) do
    %{"station_stop_id" => station_stop_id}
  end

  @doc """
  Returns the newest active pathways trip test run for an organization/version.

  Active means status is `started` or `running`.
  """
  @spec get_active_pathways_trip_test(Ecto.UUID.t(), Ecto.UUID.t()) :: ValidationRun.t() | nil
  def get_active_pathways_trip_test(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.run_type == "pathways_tests")
    |> where([run], run.status in ["started", "running"])
    |> order_by([run], desc: run.started_at, desc: run.inserted_at, desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns the newest active station reachability run for an organization,
  GTFS version, and station stop id.

  Active means status is `pending`, `started`, or `running`.
  """
  @spec get_active_station_reachability_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          ValidationRun.t() | nil
  def get_active_station_reachability_run(organization_id, gtfs_version_id, station_stop_id)
      when is_binary(station_stop_id) and station_stop_id != "" do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.run_type == "station_reachability")
    |> where([run], run.status in ["pending", "started", "running"])
    |> where(
      [run],
      fragment(
        "COALESCE((?->'metadata'->>'station_stop_id'), (?->>'station_stop_id')) = ?",
        run.result_json,
        run.result_json,
        ^station_stop_id
      )
    )
    |> order_by([run], desc: run.started_at, desc: run.inserted_at, desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  def get_active_station_reachability_run(_organization_id, _gtfs_version_id, _station_stop_id),
    do: nil

  @doc """
  Returns the current station reachability run reuse decision.

  - `{:ok, run}` when an active run exists.
  - `:none` when no active run exists.
  """
  @spec reusable_station_reachability_run(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, ValidationRun.t()} | :none
  def reusable_station_reachability_run(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        _opts \\ []
      ) do
    case get_active_station_reachability_run(organization_id, gtfs_version_id, station_stop_id) do
      nil ->
        :none

      %ValidationRun{} = run ->
        {:ok, run}
    end
  end

  @doc """
  Returns the latest completed pathways trip test run for an organization/version.

  Selection is scoped to `pathways_tests` runs with `completed` status and
  ordered deterministically by `completed_at` then `started_at` (newest first).
  """
  @spec get_latest_completed_pathways_trip_test(Ecto.UUID.t(), Ecto.UUID.t()) ::
          ValidationRun.t() | nil
  def get_latest_completed_pathways_trip_test(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.run_type == "pathways_tests")
    |> where([run], run.status == "completed")
    |> order_by([run],
      desc: run.completed_at,
      desc: run.started_at,
      desc: run.inserted_at,
      desc: run.id
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Starts a pathways trip test run for the given organization and GTFS version.

  Always creates a new run, transitions it to `running`, and spawns the
  dedicated runner process under `GtfsPlanner.TaskSupervisor`.
  """
  @spec start_pathways_trip_test(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ValidationRun.t()} | {:error, term()}
  def start_pathways_trip_test(organization_id, gtfs_version_id, opts \\ [])

  def start_pathways_trip_test(organization_id, gtfs_version_id, opts) do
    start_new_pathways_trip_test(organization_id, gtfs_version_id, opts)
  end

  @doc """
  Starts a station reachability test run for the given organization,
  GTFS version, and station stop id.

  Creates a station-scoped run, transitions it to `running`, then spawns the
  existing pathways trip test runner under `GtfsPlanner.TaskSupervisor`.
  """
  @spec start_station_reachability_test(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, ValidationRun.t()} | {:error, term()}
  def start_station_reachability_test(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        opts \\ []
      ) do
    opts =
      Keyword.update(
        opts,
        :pathways_validity_opts,
        [station_stop_id: station_stop_id],
        fn pathways_validity_opts ->
          Keyword.put(pathways_validity_opts, :station_stop_id, station_stop_id)
        end
      )

    opts =
      Keyword.update(
        opts,
        :runtime_opts,
        station_reachability_runtime_opts(station_stop_id),
        fn runtime_opts ->
          runtime_opts
          |> Keyword.put(:runtime_scope, :station_reachability)
          |> Keyword.put(:gtfs_materializer_fun, station_gtfs_materializer_fun())
          |> Keyword.put(:gtfs_opts, station_stop_id: station_stop_id)
        end
      )

    with {:ok, pending_run} <-
           create_station_reachability_run(organization_id, gtfs_version_id, station_stop_id),
         {:ok, running_run} <- mark_running(pending_run),
         :ok <-
           spawn_pathways_trip_test_runner(running_run, organization_id, gtfs_version_id, opts) do
      {:ok, running_run}
    else
      {:error, {:runner_spawn_failed, reason, running_run}} ->
        _ =
          mark_failed(running_run, %{
            reason: :pathways_runner_spawn_failed,
            details: %{error: inspect(reason)}
          })

        {:error, {:pathways_runner_spawn_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec station_reachability_runtime_opts(String.t()) :: keyword()
  defp station_reachability_runtime_opts(station_stop_id) do
    [
      runtime_scope: :station_reachability,
      gtfs_materializer_fun: station_gtfs_materializer_fun(),
      gtfs_opts: [station_stop_id: station_stop_id],
      return_runtime_meta: true
    ]
  end

  @spec station_gtfs_materializer_fun() ::
          (Ecto.UUID.t(), Ecto.UUID.t(), keyword() -> {:ok, String.t(), map()} | {:error, term()})
  defp station_gtfs_materializer_fun do
    fn organization_id, gtfs_version_id, gtfs_opts ->
      apply(
        GtfsPlanner.Otp.StationMaterializer,
        :get_or_build_gtfs_zip,
        [organization_id, gtfs_version_id, gtfs_opts]
      )
    end
  end

  @spec start_new_pathways_trip_test(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ValidationRun.t()} | {:error, term()}
  defp start_new_pathways_trip_test(organization_id, gtfs_version_id, opts) do
    with {:ok, started_run} <- create_pathways_validation_run(organization_id, gtfs_version_id),
         {:ok, running_run} <- mark_pathways_running(started_run),
         :ok <-
           spawn_pathways_trip_test_runner(running_run, organization_id, gtfs_version_id, opts) do
      {:ok, running_run}
    else
      {:error, {:runner_spawn_failed, reason, running_run}} ->
        failure_reason = %{
          reason: :pathways_runner_spawn_failed,
          details: %{error: inspect(reason)}
        }

        _ = mark_pathways_failed(running_run, failure_reason)

        {:error, {:pathways_runner_spawn_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a single validation run, raising if not found.

  ## Examples

      iex> get_validation_run!(id)
      %ValidationRun{}

      iex> get_validation_run!("invalid")
      ** (Ecto.NoResultsError)

  """
  def get_validation_run!(id) do
    Repo.get!(ValidationRun, id)
  end

  @doc """
  Gets a single validation run, returning nil if not found.

  ## Examples

      iex> get_validation_run(id)
      %ValidationRun{}

      iex> get_validation_run("invalid")
      nil

  """
  def get_validation_run(id) do
    Repo.get(ValidationRun, id)
  end

  @doc """
  Lists validation runs for a given organization and GTFS version.
  Results are ordered by started_at descending and limited to 20.

  ## Examples

      iex> list_validation_runs(org_id, version_id)
      [%ValidationRun{}, ...]

  """
  def list_validation_runs(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([vr], vr.organization_id == ^organization_id)
    |> where([vr], vr.gtfs_version_id == ^gtfs_version_id)
    |> order_by([vr], desc: vr.started_at)
    |> limit(20)
    |> Repo.all()
  end

  @doc """
  Lists recent completed or failed validation runs for a given organization and GTFS version.
  Results are ordered by started_at descending and limited to the specified number.

  ## Examples

      iex> list_recent_validation_runs(org_id, version_id, 5)
      [%ValidationRun{}, ...]

  """
  def list_recent_validation_runs(organization_id, gtfs_version_id, limit \\ 5) do
    ValidationRun
    |> where([vr], vr.organization_id == ^organization_id)
    |> where([vr], vr.gtfs_version_id == ^gtfs_version_id)
    |> where([vr], vr.status in ["completed", "failed"])
    |> order_by([vr], desc: vr.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists recent station reachability runs scoped to organization, GTFS version,
  and station stop id.

  Results include terminal runs (`completed` and `failed`) only and are ordered
  newest-first with deterministic tie-breaking.
  """
  @spec list_recent_station_reachability_runs(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          pos_integer()
        ) :: [ValidationRun.t()]
  def list_recent_station_reachability_runs(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        limit \\ 5
      ) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.run_type == "station_reachability")
    |> where([run], run.status in ["completed", "failed"])
    |> where(
      [run],
      fragment(
        "COALESCE((?->'metadata'->>'station_stop_id'), (?->>'station_stop_id')) = ?",
        run.result_json,
        run.result_json,
        ^station_stop_id
      )
    )
    |> order_by([run], desc: run.started_at, desc: run.inserted_at, desc: run.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists persisted walkability test case results for a pathways validation run.

  Results are ordered deterministically by `order_index` ascending.
  """
  @spec list_walkability_test_run_results(Ecto.UUID.t()) :: [WalkabilityTestRunResult.t()]
  def list_walkability_test_run_results(validation_run_id) do
    WalkabilityTestRunResult
    |> where([result], result.validation_run_id == ^validation_run_id)
    |> preload([:walkability_test])
    |> order_by([result], asc: result.order_index, asc: result.walkability_test_id)
    |> Repo.all()
  end

  @doc """
  Returns persisted pathways report payload for a validation run.

  Only pathways runs are returned. Non-pathways runs return `nil`.
  """
  @spec get_pathways_run_report(Ecto.UUID.t()) :: map() | nil
  def get_pathways_run_report(validation_run_id) do
    ValidationRun
    |> where([run], run.id == ^validation_run_id and run.run_type == "pathways_tests")
    |> select([run], run.result_json)
    |> Repo.one()
  end

  @doc """
  Returns normalized status data for a pathways trip test run.

  The response includes run identity, status, timing fields, aggregate counters,
  and a decoded structured error payload when the run is failed.
  """
  @spec get_pathways_trip_test_status(Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found | :invalid_run_type}
  def get_pathways_trip_test_status(validation_run_id) do
    case get_validation_run(validation_run_id) do
      nil ->
        {:error, :not_found}

      %ValidationRun{run_type: run_type} = run
      when run_type in ["pathways_tests", "station_reachability"] ->
        {:ok,
         %{
           id: run.id,
           run_type: run.run_type,
           status: run.status,
           started_at: run.started_at,
           completed_at: run.completed_at,
           duration_ms: run.duration_ms,
           errors_count: run.errors_count,
           warnings_count: run.warnings_count,
           infos_count: run.infos_count,
           error_payload: decode_pathways_error_payload(run.status, run.error_details)
         }}

      %ValidationRun{} ->
        {:error, :invalid_run_type}
    end
  end

  @doc """
  Returns persisted pathways trip test results for a completed pathways run.

  The response includes the run-level report envelope (`result_json`) and
  deterministically ordered per-case rows (`walkability_test_run_results`).
  """
  @spec get_pathways_trip_test_results(Ecto.UUID.t()) ::
          {:ok,
           %{
             id: Ecto.UUID.t(),
             run_type: String.t(),
             status: String.t(),
             result_json: map() | nil,
             walkability_test_run_results: [WalkabilityTestRunResult.t()]
           }}
          | {:error, :not_found | :invalid_run_type | :run_not_completed}
  def get_pathways_trip_test_results(validation_run_id) do
    case get_validation_run(validation_run_id) do
      nil ->
        {:error, :not_found}

      %ValidationRun{run_type: run_type, status: "completed"} = run
      when run_type in ["pathways_tests", "station_reachability"] ->
        {:ok,
         %{
           id: run.id,
           run_type: run.run_type,
           status: run.status,
           result_json: run.result_json,
           walkability_test_run_results: list_walkability_test_run_results(run.id)
         }}

      %ValidationRun{run_type: run_type}
      when run_type in ["pathways_tests", "station_reachability"] ->
        {:error, :run_not_completed}

      %ValidationRun{} ->
        {:error, :invalid_run_type}
    end
  end

  @doc """
  Marks a validation run as running.

  ## Examples

      iex> mark_running(run)
      {:ok, %ValidationRun{status: "running"}}

  """
  def mark_running(run) do
    run
    |> ValidationRun.changeset(%{status: "running"})
    |> Repo.update()
  end

  @doc """
  Marks a pathways validation run as running.
  """
  @spec mark_pathways_running(ValidationRun.t()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t() | :invalid_status_transition}
  def mark_pathways_running(%ValidationRun{run_type: "pathways_tests", status: "started"} = run),
    do: mark_running(run)

  def mark_pathways_running(%ValidationRun{}), do: {:error, :invalid_status_transition}

  @doc """
  Marks a validation run as completed and stores the result.

  ## Examples

      iex> mark_completed(run, result)
      {:ok, %ValidationRun{status: "completed"}}

  """
  def mark_completed(run, result) do
    result_json = %{
      "notices" => result.notices
    }

    run
    |> ValidationRun.changeset(%{
      status: "completed",
      errors_count: result.summary.errors,
      warnings_count: result.summary.warnings,
      infos_count: result.summary.infos,
      duration_ms: result.duration_ms,
      result_json: result_json,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Marks a validation run as failed and stores the error details.

  ## Examples

      iex> mark_failed(run, reason)
      {:ok, %ValidationRun{status: "failed"}}

  """
  def mark_failed(run, reason) do
    run
    |> ValidationRun.changeset(%{
      status: "failed",
      error_details: inspect(reason),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Marks a pathways or station reachability run as failed and stores structured
  error details.

  ## Examples

      iex> mark_pathways_failed(run, %{reason: :otp_runtime_failed})
      {:ok, %ValidationRun{status: "failed"}}

  """
  @spec mark_pathways_failed(ValidationRun.t(), term()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t() | :invalid_run_type}
  def mark_pathways_failed(%ValidationRun{run_type: run_type} = run, reason)
      when run_type in ["pathways_tests", "station_reachability"] do
    result_json = station_terminal_result_json(run, reason)

    run
    |> ValidationRun.changeset(%{
      status: "failed",
      error_details: serialize_pathways_error(reason),
      result_json: result_json,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def mark_pathways_failed(%ValidationRun{}, _reason), do: {:error, :invalid_run_type}

  @doc """
  Marks a pathways or station reachability validation run as completed and
  persists run-level report data and per-case result rows in a single database
  transaction.

  Returns `{:error, :invalid_run_type}` when called for an unsupported run type.
  """
  @spec mark_pathways_completed(ValidationRun.t(), map(), non_neg_integer()) ::
          {:ok, ValidationRun.t()} | {:error, term()}
  def mark_pathways_completed(
        %ValidationRun{run_type: run_type} = run,
        run_result,
        duration_ms
      )
      when run_type in ["pathways_tests", "station_reachability"] do
    %{result_json: result_json, case_row_attrs: case_row_attrs} =
      transform_pathways_run_result(run_result)

    summary = run_result.summary
    now = DateTime.utc_now()

    result_json =
      Map.put(result_json, "stage_timestamps", %{
        "started_at" => DateTime.to_iso8601(run.started_at),
        "completed_at" => DateTime.to_iso8601(now)
      })

    result_json = station_terminal_result_json(run, run_result, result_json)

    Repo.transaction(fn ->
      with {:ok, completed_run} <-
             update_pathways_completed_run(run, summary, result_json, duration_ms, now),
           {:ok, _inserted_count} <-
             insert_walkability_test_run_results(completed_run.id, case_row_attrs, now) do
        completed_run
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def mark_pathways_completed(%ValidationRun{}, _run_result, _duration_ms),
    do: {:error, :invalid_run_type}

  @spec station_terminal_result_json(ValidationRun.t(), term(), map()) :: map()
  defp station_terminal_result_json(
         %ValidationRun{run_type: "station_reachability"} = run,
         source_payload,
         base_result_json
       )
       when is_map(base_result_json) do
    existing_result_json = run.result_json || %{}
    existing_metadata = normalize_station_metadata(Map.get(existing_result_json, "metadata"))

    station_stop_id =
      payload_value(existing_metadata, :station_stop_id) ||
        payload_value(existing_result_json, :station_stop_id)

    station_feed_summary =
      extract_station_feed_summary(source_payload) ||
        payload_value(existing_result_json, :station_feed_summary) || %{}

    metadata =
      existing_metadata
      |> Map.put("station_stop_id", station_stop_id)

    base_result_json
    |> Map.put("metadata", metadata)
    |> Map.put("station_stop_id", station_stop_id)
    |> Map.put("station_feed_summary", normalize_pathways_json_term(station_feed_summary))
  end

  defp station_terminal_result_json(%ValidationRun{}, _source_payload, base_result_json)
       when is_map(base_result_json),
       do: base_result_json

  @spec station_terminal_result_json(ValidationRun.t(), term()) :: map() | nil
  defp station_terminal_result_json(
         %ValidationRun{run_type: "station_reachability"} = run,
         reason
       ) do
    station_terminal_result_json(run, reason, run.result_json || %{})
  end

  defp station_terminal_result_json(%ValidationRun{}, _reason), do: nil

  @spec normalize_station_metadata(term()) :: map()
  defp normalize_station_metadata(metadata) when is_map(metadata),
    do: normalize_pathways_json_term(metadata)

  defp normalize_station_metadata(_metadata), do: %{}

  @spec extract_station_feed_summary(term()) :: map() | nil
  defp extract_station_feed_summary(%{} = payload) do
    payload_value(payload, :station_feed_summary) ||
      payload
      |> payload_value(:suite_meta)
      |> payload_value(:station_feed_summary) ||
      payload
      |> payload_value(:details)
      |> payload_value(:station_feed_summary)
  end

  defp extract_station_feed_summary(_payload), do: nil

  @doc """
  Transforms an in-memory pathways runtime result into persistence-ready payloads.

  Returns:
  - `result_json`: run-level report envelope for `gtfs_validation_runs.result_json`
  - `case_row_attrs`: normalized per-case attrs for `walkability_test_run_results`
  """
  @spec transform_pathways_run_result(%{
          required(:suite_meta) => map(),
          required(:selected_test_case_ids) => [Ecto.UUID.t()],
          optional(:selection) => map(),
          required(:summary) => %{
            required(:total) => non_neg_integer(),
            required(:passed) => non_neg_integer(),
            required(:failed) => non_neg_integer(),
            required(:query_failure) => non_neg_integer(),
            required(:scoring_failure) => non_neg_integer()
          },
          required(:cases) => [map()]
        }) :: %{result_json: map(), case_row_attrs: [map()]}
  def transform_pathways_run_result(
        %{
          suite_meta: suite_meta,
          selected_test_case_ids: selected_test_case_ids,
          summary: summary,
          cases: cases
        } = run_result
      ) do
    selection = normalize_pathways_selection(Map.get(run_result, :selection))

    %{
      result_json: %{
        "report_version" => @pathways_report_version,
        "suite_meta" => suite_meta,
        "selected_test_case_ids" => selected_test_case_ids,
        "selection" => selection,
        "summary" => normalize_pathways_summary(summary),
        "top_failure_categories" => top_failure_categories(summary)
      },
      case_row_attrs: normalize_pathways_case_rows(cases)
    }
  end

  @spec normalize_pathways_selection(term()) :: map()
  defp normalize_pathways_selection(selection) when is_map(selection) do
    normalized_selection = normalize_pathways_json_term(selection)

    %{
      "total_candidates" =>
        normalize_non_negative_integer(payload_value(normalized_selection, :total_candidates)),
      "in_scope_candidates" =>
        normalize_non_negative_integer(payload_value(normalized_selection, :in_scope_candidates)),
      "selected_count" =>
        normalize_non_negative_integer(payload_value(normalized_selection, :selected_count)),
      "invalid_count" =>
        normalize_non_negative_integer(payload_value(normalized_selection, :invalid_count)),
      "scope_label" => normalize_scope_label(payload_value(normalized_selection, :scope_label)),
      "selected_test_case_ids" =>
        normalize_selection_id_list(payload_value(normalized_selection, :selected_test_case_ids)),
      "invalid_test_case_ids" =>
        normalize_selection_id_list(payload_value(normalized_selection, :invalid_test_case_ids)),
      "invalid_cases" =>
        normalize_selection_invalid_cases(payload_value(normalized_selection, :invalid_cases))
    }
  end

  defp normalize_pathways_selection(_selection) do
    %{
      "total_candidates" => 0,
      "in_scope_candidates" => 0,
      "selected_count" => 0,
      "invalid_count" => 0,
      "scope_label" => nil,
      "selected_test_case_ids" => [],
      "invalid_test_case_ids" => [],
      "invalid_cases" => []
    }
  end

  @spec normalize_scope_label(term()) :: String.t() | nil
  defp normalize_scope_label(scope_label) when is_binary(scope_label) do
    scope_label = String.trim(scope_label)

    if scope_label == "" do
      nil
    else
      scope_label
    end
  end

  defp normalize_scope_label(_scope_label), do: nil

  @spec normalize_non_negative_integer(term()) :: non_neg_integer()
  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(_value), do: 0

  @spec normalize_selection_id_list(term()) :: [String.t()]
  defp normalize_selection_id_list(selection_ids) when is_list(selection_ids) do
    Enum.map(selection_ids, &normalize_pathways_error_value/1)
  end

  defp normalize_selection_id_list(_selection_ids), do: []

  @spec normalize_selection_invalid_cases(term()) :: [map()]
  defp normalize_selection_invalid_cases(invalid_cases) when is_list(invalid_cases) do
    Enum.map(invalid_cases, fn invalid_case ->
      normalized_invalid_case = normalize_pathways_json_term(invalid_case)

      %{
        "test_case_id" =>
          payload_value(normalized_invalid_case, :test_case_id) ||
            payload_value(normalized_invalid_case, :walkability_test_id),
        "walkability_test_id" => payload_value(normalized_invalid_case, :walkability_test_id),
        "reason_code" =>
          payload_value(normalized_invalid_case, :reason_code)
          |> case do
            nil -> nil
            value -> normalize_pathways_error_value(value)
          end,
        "stop_id" => payload_value(normalized_invalid_case, :stop_id),
        "address" => payload_value(normalized_invalid_case, :address)
      }
    end)
  end

  defp normalize_selection_invalid_cases(_invalid_cases), do: []

  # --- Walkability Tests ---

  @doc """
  Lists walkability tests for a given organization and GTFS version.
  Results are ordered deterministically by stop_id, address, and id ascending.

  ## Examples

      iex> list_walkability_tests(org_id, version_id)
      [%WalkabilityTest{}, ...]

  """
  def list_walkability_tests(organization_id, gtfs_version_id) do
    WalkabilityTest
    |> where([wt], wt.organization_id == ^organization_id)
    |> where([wt], wt.gtfs_version_id == ^gtfs_version_id)
    |> order_by([wt], asc: wt.stop_id, asc: wt.address, asc: wt.id)
    |> Repo.all()
  end

  @doc """
  Lists walkability tests for a given organization, GTFS version, and stop ids.
  Results are ordered by inserted_at descending.
  """
  def list_walkability_tests_for_stop_ids(_organization_id, _gtfs_version_id, []), do: []

  def list_walkability_tests_for_stop_ids(organization_id, gtfs_version_id, stop_ids) do
    WalkabilityTest
    |> where(
      [wt],
      wt.organization_id == ^organization_id and wt.gtfs_version_id == ^gtfs_version_id and
        wt.stop_id in ^stop_ids
    )
    |> order_by([wt], desc: wt.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single walkability test, raising if not found.

  ## Examples

      iex> get_walkability_test!(id)
      %WalkabilityTest{}

      iex> get_walkability_test!("invalid")
      ** (Ecto.NoResultsError)

  """
  def get_walkability_test!(id) do
    Repo.get!(WalkabilityTest, id)
  end

  @doc """
  Gets a single walkability test, returning nil if not found.
  """
  def get_walkability_test(id) do
    Repo.get(WalkabilityTest, id)
  end

  @doc """
  Creates a walkability test for a given organization and GTFS version.

  ## Examples

      iex> create_walkability_test(org_id, version_id, %{stop_id: "stop_123", address: "123 Main St", address_lat: "40.7128", address_lon: "-74.0060"})
      {:ok, %WalkabilityTest{}}

      iex> create_walkability_test(org_id, version_id, %{})
      {:error, %Ecto.Changeset{}}

  """
  def create_walkability_test(organization_id, gtfs_version_id, attrs) do
    %WalkabilityTest{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
    |> WalkabilityTest.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a walkability test.

  ## Examples

      iex> update_walkability_test(walkability_test, %{address: "456 Oak Ave"})
      {:ok, %WalkabilityTest{}}

      iex> update_walkability_test(walkability_test, %{stop_id: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_walkability_test(walkability_test, attrs) do
    walkability_test
    |> WalkabilityTest.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a walkability test.

  ## Examples

      iex> delete_walkability_test(walkability_test)
      {:ok, %WalkabilityTest{}}

      iex> delete_walkability_test(walkability_test)
      {:error, %Ecto.Changeset{}}

  """
  def delete_walkability_test(walkability_test) do
    Repo.delete(walkability_test)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking walkability test changes.

  ## Examples

      iex> change_walkability_test(walkability_test)
      %Ecto.Changeset{data: %WalkabilityTest{}}

  """
  def change_walkability_test(walkability_test, attrs \\ %{}) do
    WalkabilityTest.changeset(walkability_test, attrs)
  end

  @doc """
  Returns a map of stop_id => test count for stops that have walkability tests.
  """
  def stop_ids_with_walkability_tests(_organization_id, []), do: %{}

  def stop_ids_with_walkability_tests(organization_id, stop_ids) do
    WalkabilityTest
    |> where([wt], wt.organization_id == ^organization_id and wt.stop_id in ^stop_ids)
    |> group_by([wt], wt.stop_id)
    |> select([wt], {wt.stop_id, count(wt.id)})
    |> Repo.all()
    |> Map.new()
  end

  @spec normalize_pathways_summary(%{
          required(:total) => non_neg_integer(),
          required(:passed) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:query_failure) => non_neg_integer(),
          required(:scoring_failure) => non_neg_integer()
        }) :: map()
  defp normalize_pathways_summary(summary) do
    total = summary.total
    passed = summary.passed

    %{
      "total" => total,
      "passed" => passed,
      "failed" => summary.failed,
      "query_failure" => summary.query_failure,
      "scoring_failure" => summary.scoring_failure,
      "pass_rate" => pass_rate_percent(passed, total)
    }
  end

  @spec top_failure_categories(%{
          required(:query_failure) => non_neg_integer(),
          required(:scoring_failure) => non_neg_integer()
        }) :: [map()]
  defp top_failure_categories(summary) do
    [
      %{category: "query_failure", count: summary.query_failure},
      %{category: "scoring_failure", count: summary.scoring_failure}
    ]
    |> Enum.filter(&(&1.count > 0))
    |> Enum.sort_by(fn category -> {-category.count, category.category} end)
    |> Enum.map(fn category ->
      %{"category" => category.category, "count" => category.count}
    end)
  end

  @spec normalize_pathways_case_rows([map()]) :: [map()]
  defp normalize_pathways_case_rows(cases) do
    cases
    |> Enum.with_index()
    |> Enum.map(fn {pathways_case, index} ->
      route_output = Map.get(pathways_case, :route_output)
      wheelchair_output = Map.get(pathways_case, :wheelchair_output)

      %{
        walkability_test_id: pathways_case.test_case_id,
        order_index: index,
        status: normalize_case_status(pathways_case),
        failure_category: normalize_failure_category(pathways_case),
        route_exists: route_field(route_output, :route_exists),
        duration_seconds: route_float_field(route_output, :duration_seconds),
        distance_meters: route_float_field(route_output, :distance_meters),
        itinerary_start_time: route_datetime_field(route_output, :itinerary_start_time),
        itinerary_end_time: route_datetime_field(route_output, :itinerary_end_time),
        leg_count: route_non_negative_integer_field(route_output, :leg_count),
        step_count: route_non_negative_integer_field(route_output, :step_count),
        itinerary_steps_json: route_map_field(route_output, :itinerary_steps),
        wheelchair_route_exists: route_field(wheelchair_output, :route_exists),
        wheelchair_duration_seconds: route_float_field(wheelchair_output, :duration_seconds),
        wheelchair_distance_meters: route_float_field(wheelchair_output, :distance_meters),
        details_json: Map.get(pathways_case, :details)
      }
    end)
  end

  @spec normalize_case_status(map()) :: String.t()
  defp normalize_case_status(%{status: :passed}), do: "passed"
  defp normalize_case_status(%{status: :failed}), do: "failed"

  defp normalize_case_status(%{status: status}) do
    raise ArgumentError,
          "invalid pathways case status: #{inspect(status)}; expected :passed or :failed"
  end

  defp normalize_case_status(_pathways_case) do
    raise ArgumentError,
          "invalid pathways case status: missing :status; expected :passed or :failed"
  end

  @spec normalize_failure_category(map()) :: String.t() | nil
  defp normalize_failure_category(%{failure_category: nil}), do: nil

  defp normalize_failure_category(%{failure_category: :query_failure}), do: "query_failure"
  defp normalize_failure_category(%{failure_category: :scoring_failure}), do: "scoring_failure"

  defp normalize_failure_category(%{failure_category: failure_category}) do
    raise ArgumentError,
          "invalid pathways case failure_category: #{inspect(failure_category)}; expected :query_failure, :scoring_failure, or nil"
  end

  defp normalize_failure_category(_pathways_case), do: nil

  @spec route_field(map() | nil, atom()) :: term()
  defp route_field(nil, _field), do: nil
  defp route_field(route_output, field), do: Map.get(route_output, field)

  @spec route_float_field(map() | nil, atom()) :: float() | nil
  defp route_float_field(route_output, field) do
    route_output
    |> route_field(field)
    |> normalize_optional_float(field)
  end

  @spec route_datetime_field(map() | nil, atom()) :: DateTime.t() | nil
  defp route_datetime_field(route_output, field) do
    route_output
    |> route_field(field)
    |> normalize_optional_datetime(field)
  end

  @spec route_non_negative_integer_field(map() | nil, atom()) :: non_neg_integer() | nil
  defp route_non_negative_integer_field(route_output, field) do
    route_output
    |> route_field(field)
    |> normalize_optional_non_negative_integer(field)
  end

  @spec route_map_field(map() | nil, atom()) :: map() | nil
  defp route_map_field(route_output, field) do
    route_output
    |> route_field(field)
    |> normalize_optional_map(field)
  end

  @spec normalize_optional_float(term(), atom()) :: float() | nil
  defp normalize_optional_float(nil, _field), do: nil
  defp normalize_optional_float(value, _field) when is_float(value), do: value
  defp normalize_optional_float(value, _field) when is_integer(value), do: value * 1.0

  defp normalize_optional_float(value, field) do
    raise ArgumentError,
          "invalid pathways route field #{inspect(field)}: #{inspect(value)}; expected float, integer, or nil"
  end

  @spec normalize_optional_datetime(term(), atom()) :: DateTime.t() | nil
  defp normalize_optional_datetime(nil, _field), do: nil

  defp normalize_optional_datetime(%DateTime{} = value, _field) do
    {microsecond, _precision} = value.microsecond
    %{value | microsecond: {microsecond, 6}}
  end

  defp normalize_optional_datetime(value, field) do
    raise ArgumentError,
          "invalid pathways route field #{inspect(field)}: #{inspect(value)}; expected DateTime or nil"
  end

  @spec normalize_optional_non_negative_integer(term(), atom()) :: non_neg_integer() | nil
  defp normalize_optional_non_negative_integer(nil, _field), do: nil

  defp normalize_optional_non_negative_integer(value, _field)
       when is_integer(value) and value >= 0,
       do: value

  defp normalize_optional_non_negative_integer(value, field) do
    raise ArgumentError,
          "invalid pathways route field #{inspect(field)}: #{inspect(value)}; expected non-negative integer or nil"
  end

  @spec normalize_optional_map(term(), atom()) :: map() | nil
  defp normalize_optional_map(nil, _field), do: nil
  defp normalize_optional_map(value, _field) when is_map(value), do: value

  defp normalize_optional_map(value, field) do
    raise ArgumentError,
          "invalid pathways route field #{inspect(field)}: #{inspect(value)}; expected map or nil"
  end

  @spec pass_rate_percent(non_neg_integer(), non_neg_integer()) :: float()
  defp pass_rate_percent(_passed, 0), do: 0.0

  defp pass_rate_percent(passed, total) do
    passed
    |> Kernel.*(100.0)
    |> Kernel./(total)
    |> Float.round(2)
  end

  @spec update_pathways_completed_run(
          ValidationRun.t(),
          %{
            required(:passed) => non_neg_integer(),
            required(:failed) => non_neg_integer(),
            required(:query_failure) => non_neg_integer()
          },
          map(),
          non_neg_integer(),
          DateTime.t()
        ) :: {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t()}
  defp update_pathways_completed_run(run, summary, result_json, duration_ms, now) do
    run
    |> ValidationRun.changeset(%{
      status: "completed",
      errors_count: summary.failed,
      warnings_count: summary.query_failure,
      infos_count: summary.passed,
      duration_ms: duration_ms,
      result_json: result_json,
      completed_at: now
    })
    |> Repo.update()
  end

  @spec insert_walkability_test_run_results(Ecto.UUID.t(), [map()], DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp insert_walkability_test_run_results(_validation_run_id, [], _now), do: {:ok, 0}

  defp insert_walkability_test_run_results(validation_run_id, case_row_attrs, now) do
    rows =
      Enum.map(case_row_attrs, fn case_row ->
        Map.merge(case_row, %{
          validation_run_id: validation_run_id,
          inserted_at: now,
          updated_at: now
        })
      end)

    {inserted_count, _rows} = Repo.insert_all(WalkabilityTestRunResult, rows)
    {:ok, inserted_count}
  end

  @spec serialize_pathways_error(term()) :: String.t()
  defp serialize_pathways_error(reason) do
    %{
      "scope" => "pathways_tests",
      "reason" => pathways_error_reason_code(reason),
      "details" => pathways_error_details(reason),
      "issues" => pathways_error_issues(reason)
    }
    |> Jason.encode!()
  end

  @spec pathways_error_reason_code(term()) :: String.t()
  defp pathways_error_reason_code(%{} = reason) do
    reason
    |> payload_value(:reason)
    |> normalize_pathways_error_value()
  end

  defp pathways_error_reason_code(reason), do: normalize_pathways_error_value(reason)

  @spec pathways_error_details(term()) :: map() | String.t() | nil
  defp pathways_error_details(%{} = reason) do
    reason
    |> payload_value(:details)
    |> normalize_pathways_error_details()
  end

  defp pathways_error_details(_reason), do: nil

  @spec pathways_error_issues(term()) :: [term()] | nil
  defp pathways_error_issues(%{} = reason) do
    case payload_value(reason, :issues) do
      issues when is_list(issues) -> Enum.map(issues, &normalize_pathways_json_term/1)
      _issues -> nil
    end
  end

  defp pathways_error_issues(_reason), do: nil

  @spec normalize_pathways_error_details(term()) :: map() | String.t() | nil
  defp normalize_pathways_error_details(nil), do: nil

  defp normalize_pathways_error_details(details) when is_map(details),
    do: normalize_pathways_json_term(details)

  defp normalize_pathways_error_details(details), do: normalize_pathways_error_value(details)

  @spec normalize_pathways_error_value(term()) :: String.t()
  defp normalize_pathways_error_value(value) when is_binary(value), do: value
  defp normalize_pathways_error_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_pathways_error_value(value), do: inspect(value)

  @spec normalize_pathways_json_term(term()) :: term()
  defp normalize_pathways_json_term(value)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
       do: value

  defp normalize_pathways_json_term(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_pathways_json_term(value) when is_list(value),
    do: Enum.map(value, &normalize_pathways_json_term/1)

  defp normalize_pathways_json_term(%_struct{} = value), do: inspect(value)

  defp normalize_pathways_json_term(value) when is_map(value) do
    Map.new(value, fn {key, map_value} ->
      {normalize_pathways_error_value(key), normalize_pathways_json_term(map_value)}
    end)
  end

  defp normalize_pathways_json_term(value), do: inspect(value)

  @spec payload_value(map() | nil, atom()) :: term()
  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_value(_payload, _key), do: nil

  @spec decode_pathways_error_payload(String.t(), String.t() | nil) :: map() | nil
  defp decode_pathways_error_payload("failed", nil), do: nil

  defp decode_pathways_error_payload("failed", error_details) when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        normalize_decoded_pathways_error_payload(payload, error_details)

      {:ok, _payload} ->
        legacy_pathways_error_payload("invalid_error_payload", error_details)

      {:error, _reason} ->
        legacy_pathways_error_payload("legacy_error_details", error_details)
    end
  end

  defp decode_pathways_error_payload(_status, _error_details), do: nil

  @spec normalize_decoded_pathways_error_payload(map(), String.t()) :: map()
  defp normalize_decoded_pathways_error_payload(payload, error_details) do
    normalized_payload = normalize_pathways_json_term(payload)

    required_fields = %{
      "scope" => payload_value(normalized_payload, :scope) || "pathways_tests",
      "reason" =>
        payload_value(normalized_payload, :reason) ||
          payload_value(normalized_payload, :reason_code) || "unknown_pathways_failure",
      "details" => normalize_pathways_error_details(payload_value(normalized_payload, :details)),
      "issues" => normalize_decoded_pathways_issues(payload_value(normalized_payload, :issues))
    }

    normalized_payload
    |> Map.merge(required_fields)
    |> maybe_put_raw_error_details(error_details)
  end

  @spec normalize_decoded_pathways_issues(term()) :: [term()]
  defp normalize_decoded_pathways_issues(issues) when is_list(issues),
    do: Enum.map(issues, &normalize_pathways_json_term/1)

  defp normalize_decoded_pathways_issues(_issues), do: []

  @spec maybe_put_raw_error_details(map(), String.t()) :: map()
  defp maybe_put_raw_error_details(payload, error_details) do
    if payload_value(payload, :raw_error_details) do
      payload
    else
      Map.put(payload, "raw_error_details", error_details)
    end
  end

  @spec legacy_pathways_error_payload(String.t(), String.t()) :: map()
  defp legacy_pathways_error_payload(reason, error_details) do
    %{
      "scope" => "pathways_tests",
      "reason" => reason,
      "details" => nil,
      "issues" => [],
      "raw_error_details" => error_details
    }
  end

  @spec spawn_pathways_trip_test_runner(
          ValidationRun.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          keyword()
        ) ::
          :ok | {:error, {:runner_spawn_failed, term(), ValidationRun.t()}}
  defp spawn_pathways_trip_test_runner(validation_run, organization_id, gtfs_version_id, opts) do
    runner_module =
      Application.get_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysTripTestRunner
      )

    task_supervisor =
      Application.get_env(
        :gtfs_planner,
        :pathways_trip_test_task_supervisor,
        GtfsPlanner.TaskSupervisor
      )

    try do
      case Task.Supervisor.start_child(task_supervisor, fn ->
             runner_module.run(validation_run, organization_id, gtfs_version_id, opts)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          {:error, {:runner_spawn_failed, reason, validation_run}}
      end
    catch
      :exit, reason ->
        {:error, {:runner_spawn_failed, reason, validation_run}}
    end
  end
end
