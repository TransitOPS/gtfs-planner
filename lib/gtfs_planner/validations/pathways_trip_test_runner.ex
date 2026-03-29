defmodule GtfsPlanner.Validations.PathwaysTripTestRunner do
  @moduledoc """
  Imperative runner boundary for pathways trip test orchestration.

  The runner executes the OTP runtime callback flow and persists terminal run
  outcomes through the `GtfsPlanner.Validations` context.
  """

  alias GtfsPlanner.Otp.PathwaysValidity
  alias GtfsPlanner.Otp.Runtime
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @typedoc "Optional callback used to emit progress payloads to callers."
  @type status_callback :: (map() -> term())

  @typedoc "Runner options reserved for runtime and validity integration."
  @type run_option ::
          {:status_callback, status_callback()}
          | {:otp_runtime_module, module()}
          | {:otp_pathways_validity_module, module()}
          | {:validations_module, module()}
          | {:pathways_validity_opts, keyword()}
          | {:runtime_opts, keyword()}

  @type run_opts :: [run_option()]

  @typedoc "Canonical runner return contract."
  @type run_result :: {:ok, ValidationRun.t() | term()} | {:error, map()}

  @doc """
  Executes a pathways trip test run by orchestrating OTP runtime execution and
  in-session pathways validity checks.
  """
  @spec run(ValidationRun.t(), Ecto.UUID.t(), Ecto.UUID.t(), run_opts()) :: run_result()
  def run(
        %ValidationRun{} = validation_run,
        organization_id,
        gtfs_version_id,
        opts
      ) do
    status_callback = Keyword.get(opts, :status_callback)
    pathways_validity_opts = Keyword.get(opts, :pathways_validity_opts, [])
    runtime_module = otp_runtime_module(opts)
    pathways_validity_module = otp_pathways_validity_module(opts)
    validations_module = validations_module(opts)
    started_at_ms = System.monotonic_time(:millisecond)

    callback = fn session ->
      pathways_validity_module.run_in_session(
        session,
        organization_id,
        gtfs_version_id,
        pathways_validity_opts
        |> Keyword.put(:status_callback, status_callback)
      )
    end

    case runtime_module.run_with_otp(
           organization_id,
           gtfs_version_id,
           callback,
           runtime_opts(opts, status_callback)
         ) do
      {:ok, runtime_result} ->
        run_result = hydrate_run_result_with_runtime_meta(runtime_result)
        duration_ms = System.monotonic_time(:millisecond) - started_at_ms

        case validations_module.mark_pathways_completed(validation_run, run_result, duration_ms) do
          {:ok, persisted_run} ->
            {:ok, persisted_run}

          {:error, persistence_reason} ->
            failure_reason = %{
              reason: :pathways_persistence_failed,
              details: %{error: inspect(persistence_reason)}
            }

            persist_failed_run(validations_module, validation_run, failure_reason)
        end

      {:error, issues} when is_list(issues) ->
        persist_failed_run(validations_module, validation_run, %{
          reason: :otp_runtime_failed,
          issues: issues
        })

      {:error, reason} ->
        persist_failed_run(validations_module, validation_run, normalize_failure_reason(reason))
    end
  end

  @spec normalize_failure_reason(term()) :: map()
  defp normalize_failure_reason(%{reason: reason} = failure) do
    details =
      cond do
        Map.has_key?(failure, :details) ->
          Map.get(failure, :details)

        true ->
          case Map.drop(failure, [:reason, :issues]) do
            details_map when map_size(details_map) == 0 -> nil
            details_map -> details_map
          end
      end

    %{reason: reason}
    |> maybe_put_failure_component(:details, details)
    |> maybe_put_failure_component(:issues, Map.get(failure, :issues))
  end

  defp normalize_failure_reason(reason),
    do: %{reason: :pathways_trip_test_failed, details: %{error: inspect(reason)}}

  @spec maybe_put_failure_component(map(), atom(), term()) :: map()
  defp maybe_put_failure_component(failure_reason, _key, nil), do: failure_reason

  defp maybe_put_failure_component(failure_reason, key, value),
    do: Map.put(failure_reason, key, value)

  @spec persist_failed_run(module(), ValidationRun.t(), map()) :: {:error, map()}
  defp persist_failed_run(validations_module, validation_run, failure_reason) do
    case validations_module.mark_pathways_failed(validation_run, failure_reason) do
      {:ok, _failed_run} ->
        {:error, failure_reason}

      {:error, persistence_reason} ->
        {:error,
         %{
           reason: :pathways_failure_persistence_failed,
           details: %{
             error: inspect(persistence_reason),
             original_failure: failure_reason
           }
         }}
    end
  end

  @spec runtime_opts(run_opts(), status_callback() | nil) :: keyword()
  defp runtime_opts(opts, status_callback) do
    opts
    |> Keyword.get(:runtime_opts, [])
    |> Keyword.merge(
      status_callback: status_callback,
      preflight_mode: :strict,
      force_rebuild: true
    )
  end

  @spec otp_runtime_module(run_opts()) :: module()
  defp otp_runtime_module(opts) do
    Keyword.get(
      opts,
      :otp_runtime_module,
      Application.get_env(:gtfs_planner, :otp_runtime_module, Runtime)
    )
  end

  @spec otp_pathways_validity_module(run_opts()) :: module()
  defp otp_pathways_validity_module(opts) do
    Keyword.get(
      opts,
      :otp_pathways_validity_module,
      Application.get_env(:gtfs_planner, :otp_pathways_validity_module, PathwaysValidity)
    )
  end

  @spec validations_module(run_opts()) :: module()
  defp validations_module(opts) do
    Keyword.get(opts, :validations_module, Validations)
  end

  @spec hydrate_run_result_with_runtime_meta(term()) :: term()
  defp hydrate_run_result_with_runtime_meta(%{result: run_result, runtime_meta: runtime_meta})
       when is_map(run_result) and is_map(runtime_meta) do
    station_feed_summary =
      runtime_meta
      |> Map.get(:gtfs, %{})
      |> Map.get(:station_feed_summary)

    if is_map(station_feed_summary) do
      Map.update(
        run_result,
        :suite_meta,
        %{station_feed_summary: station_feed_summary},
        fn suite_meta ->
          Map.put(suite_meta, :station_feed_summary, station_feed_summary)
        end
      )
    else
      run_result
    end
  end

  defp hydrate_run_result_with_runtime_meta(runtime_result), do: runtime_result
end
