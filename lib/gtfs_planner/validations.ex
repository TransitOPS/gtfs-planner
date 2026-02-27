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

      %ValidationRun{run_type: "pathways_tests"} = run ->
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

      %ValidationRun{run_type: "pathways_tests", status: "completed"} = run ->
        {:ok,
         %{
           id: run.id,
           run_type: run.run_type,
           status: run.status,
           result_json: run.result_json,
           walkability_test_run_results: list_walkability_test_run_results(run.id)
         }}

      %ValidationRun{run_type: "pathways_tests"} ->
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
  Marks a pathways validation run as failed and stores structured error details.

  ## Examples

      iex> mark_pathways_failed(run, %{reason: :otp_runtime_failed})
      {:ok, %ValidationRun{status: "failed"}}

  """
  @spec mark_pathways_failed(ValidationRun.t(), term()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t() | :invalid_run_type}
  def mark_pathways_failed(%ValidationRun{run_type: "pathways_tests"} = run, reason) do
    run
    |> ValidationRun.changeset(%{
      status: "failed",
      error_details: serialize_pathways_error(reason),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def mark_pathways_failed(%ValidationRun{}, _reason), do: {:error, :invalid_run_type}

  @doc """
  Marks a pathways validation run as completed and persists run-level
  report data and per-case result rows in a single database transaction.

  Returns `{:error, :invalid_run_type}` when called for a non-pathways run.
  """
  @spec mark_pathways_completed(ValidationRun.t(), map(), non_neg_integer()) ::
          {:ok, ValidationRun.t()} | {:error, term()}
  def mark_pathways_completed(
        %ValidationRun{run_type: "pathways_tests"} = run,
        run_result,
        duration_ms
      ) do
    %{result_json: result_json, case_row_attrs: case_row_attrs} =
      transform_pathways_run_result(run_result)

    summary = run_result.summary
    now = DateTime.utc_now()

    result_json =
      Map.put(result_json, "stage_timestamps", %{
        "started_at" => DateTime.to_iso8601(run.started_at),
        "completed_at" => DateTime.to_iso8601(now)
      })

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

  @doc """
  Transforms an in-memory pathways runtime result into persistence-ready payloads.

  Returns:
  - `result_json`: run-level report envelope for `gtfs_validation_runs.result_json`
  - `case_row_attrs`: normalized per-case attrs for `walkability_test_run_results`
  """
  @spec transform_pathways_run_result(%{
          required(:suite_meta) => map(),
          required(:selected_test_case_ids) => [Ecto.UUID.t()],
          required(:summary) => %{
            required(:total) => non_neg_integer(),
            required(:passed) => non_neg_integer(),
            required(:failed) => non_neg_integer(),
            required(:query_failure) => non_neg_integer(),
            required(:scoring_failure) => non_neg_integer()
          },
          required(:cases) => [map()]
        }) :: %{result_json: map(), case_row_attrs: [map()]}
  def transform_pathways_run_result(%{
        suite_meta: suite_meta,
        selected_test_case_ids: selected_test_case_ids,
        summary: summary,
        cases: cases
      }) do
    %{
      result_json: %{
        "report_version" => @pathways_report_version,
        "suite_meta" => suite_meta,
        "selected_test_case_ids" => selected_test_case_ids,
        "summary" => normalize_pathways_summary(summary),
        "top_failure_categories" => top_failure_categories(summary)
      },
      case_row_attrs: normalize_pathways_case_rows(cases)
    }
  end

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
  Lists walkability tests for a given organization and stop ids.
  Results are ordered by inserted_at descending.
  """
  def list_walkability_tests_for_stop_ids(_organization_id, []), do: []

  def list_walkability_tests_for_stop_ids(organization_id, stop_ids) do
    WalkabilityTest
    |> where([wt], wt.organization_id == ^organization_id and wt.stop_id in ^stop_ids)
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
      "reason" => inspect(reason)
    }
    |> Jason.encode!()
  end

  @spec decode_pathways_error_payload(String.t(), String.t() | nil) :: map() | nil
  defp decode_pathways_error_payload("failed", nil), do: nil

  defp decode_pathways_error_payload("failed", error_details) when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        payload

      {:ok, _payload} ->
        %{"reason" => "invalid_error_payload", "raw_error_details" => error_details}

      {:error, _reason} ->
        %{"reason" => "unparsed_error_details", "raw_error_details" => error_details}
    end
  end

  defp decode_pathways_error_payload(_status, _error_details), do: nil

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
