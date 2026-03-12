defmodule GtfsPlanner.Otp.Runtime do
  @moduledoc """
  OTP runtime orchestration boundary for Phase 1 and Phase 2 materialization.
  """

  alias GtfsPlanner.Otp.Runtime.Readiness
  alias GtfsPlanner.Otp.Runtime.Server
  alias GtfsPlanner.Otp.Runtime.Session
  alias GtfsPlanner.Otp.StationMaterializer.GtfsZipReader
  alias GtfsPlanner.Otp.GraphLifecycle
  alias GtfsPlanner.Otp.GraphMaterializer
  alias GtfsPlanner.Otp.Lifecycle
  alias GtfsPlanner.Otp.Materializer

  @station_runtime_precheck_sample_limit 5
  @station_runtime_boundary_details %{
    source_file: nil,
    source_field: nil,
    target_file: nil,
    target_field: nil,
    invalid_count: 0,
    sample_values: []
  }

  @type issues :: [map()]
  @type status_payload :: %{optional(atom()) => term()}
  @type status_callback :: (status_payload() -> term())

  @type prepare_meta :: %{
          gtfs: map(),
          graph: map()
        }

  @type prepare_result :: %{
          gtfs_zip_path: String.t(),
          graph_path: String.t(),
          meta: prepare_meta()
        }

  @type cleanup_result :: %{
          graph: :purged | :not_found,
          gtfs: :purged | :not_found
        }

  @type run_callback_result :: {:ok, term()} | {:error, term()}
  @type run_callback :: (Session.t() -> run_callback_result())
  @type runtime_issue_code ::
          :otp_start_failed
          | :otp_ready_timeout
          | :otp_readiness_probe_failed
          | :otp_process_crashed
          | :otp_stop_failed
          | :otp_runtime_already_running

  @spec prepare_runtime(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, prepare_result()} | {:error, issues()}
  def prepare_runtime(organization_id, gtfs_version_id, opts \\ []) when is_list(opts) do
    status_callback = Keyword.get(opts, :status_callback)
    preflight_mode = Keyword.get(opts, :preflight_mode, :strict)
    force_rebuild? = Keyword.get(opts, :force_rebuild, false)
    runtime_scope = Keyword.get(opts, :runtime_scope, :default)

    gtfs_materializer_fun =
      Keyword.get(opts, :gtfs_materializer_fun, &Materializer.get_or_build_gtfs_zip/3)

    graph_materializer_fun =
      Keyword.get(opts, :graph_materializer_fun, &GraphMaterializer.get_or_build_graph/3)

    runtime_input_gtfs_zip_path_fun =
      Keyword.get(opts, :runtime_input_gtfs_zip_path_fun, &runtime_input_gtfs_zip_path/3)

    gtfs_opts =
      opts
      |> Keyword.get(:gtfs_opts, [])
      |> Keyword.put_new(:preflight_mode, preflight_mode)
      |> Keyword.put_new(:force_rebuild, force_rebuild?)
      |> Keyword.put(:status_callback, scoped_status_callback(status_callback, :gtfs))

    base_graph_opts =
      opts
      |> Keyword.get(:graph_opts, [])
      |> Keyword.put_new(:force_rebuild, force_rebuild?)
      |> Keyword.put(:status_callback, scoped_status_callback(status_callback, :graph))

    with {:ok, gtfs_zip_path, gtfs_meta} <-
           gtfs_materializer_fun.(organization_id, gtfs_version_id, gtfs_opts),
         {:ok, runtime_input_gtfs_zip_path} <-
           runtime_input_gtfs_zip_path_fun.(runtime_scope, gtfs_zip_path, gtfs_meta),
         :ok <-
           ensure_station_runtime_lineage(
             runtime_scope,
             gtfs_meta,
             runtime_input_gtfs_zip_path
           ),
         :ok <-
           ensure_station_scoped_referential_precheck(
             runtime_scope,
             runtime_input_gtfs_zip_path
           ),
         graph_opts <-
           graph_opts_for_gtfs_input(base_graph_opts, runtime_input_gtfs_zip_path, gtfs_meta),
         {:ok, graph_path, graph_meta} <-
           graph_materializer_fun.(organization_id, gtfs_version_id, graph_opts) do
      {:ok,
       %{
         gtfs_zip_path: runtime_input_gtfs_zip_path,
         graph_path: graph_path,
         meta: %{
           gtfs: gtfs_meta,
           graph: graph_meta
         }
       }}
    end
  end

  defp runtime_input_gtfs_zip_path(
         :station_reachability,
         _gtfs_zip_path,
         %{station_zip_path: station_zip_path}
       )
       when is_binary(station_zip_path) and station_zip_path != "" do
    {:ok, station_zip_path}
  end

  defp runtime_input_gtfs_zip_path(:station_reachability, _gtfs_zip_path, _gtfs_meta) do
    {:error,
     [
       %{
         code: :station_runtime_input_missing_station_zip_path,
         severity: :error,
         message: "Station runtime input requires station_zip_path",
         details:
           station_runtime_boundary_details(%{
             runtime_scope: :station_reachability
           })
       }
     ]}
  end

  defp runtime_input_gtfs_zip_path(_runtime_scope, gtfs_zip_path, _gtfs_meta),
    do: {:ok, gtfs_zip_path}

  defp ensure_station_runtime_lineage(
         :station_reachability,
         gtfs_meta,
         runtime_input_gtfs_zip_path
       ) do
    station_stop_id = runtime_meta_value(gtfs_meta, :station_stop_id)
    station_zip_path = runtime_meta_value(gtfs_meta, :station_zip_path)

    cond do
      not present_runtime_value?(station_stop_id) ->
        {:error,
         [
           %{
             code: :station_runtime_input_missing_station_stop_id,
             severity: :error,
             message: "Station runtime input requires station_stop_id",
             details:
               station_runtime_boundary_details(%{
                 runtime_scope: :station_reachability
               })
           }
         ]}

      not station_zip_path_readable?(station_zip_path) ->
        {:error,
         [
           %{
             code: :station_runtime_input_station_zip_path_unreadable,
             severity: :error,
             message: "Station runtime input requires readable station_zip_path",
             details:
               station_runtime_boundary_details(%{
                 runtime_scope: :station_reachability,
                 source_file: "station_zip_path",
                 source_field: "path",
                 invalid_count: 1,
                 sample_values: station_runtime_sample_values([station_zip_path]),
                 station_zip_path: station_zip_path
               })
           }
         ]}

      runtime_input_gtfs_zip_path != station_zip_path ->
        {:error,
         [
           %{
             code: :station_runtime_input_lineage_mismatch,
             severity: :error,
             message: "Station runtime input must match station_zip_path",
             details:
               station_runtime_boundary_details(%{
                 runtime_scope: :station_reachability,
                 source_file: "runtime_input_gtfs_zip_path",
                 source_field: "path",
                 target_file: "station_zip_path",
                 target_field: "path",
                 invalid_count: 1,
                 sample_values:
                   station_runtime_sample_values([
                     runtime_input_gtfs_zip_path,
                     station_zip_path
                   ]),
                 station_zip_path: station_zip_path,
                 runtime_input_gtfs_zip_path: runtime_input_gtfs_zip_path
               })
           }
         ]}

      true ->
        :ok
    end
  end

  defp ensure_station_runtime_lineage(_runtime_scope, _gtfs_meta, _runtime_input_gtfs_zip_path),
    do: :ok

  defp runtime_meta_value(meta, key) when is_map(meta) and is_atom(key) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
  end

  defp runtime_meta_value(_meta, _key), do: nil

  defp present_runtime_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_runtime_value?(_value), do: false

  defp station_zip_path_readable?(station_zip_path) when is_binary(station_zip_path) do
    case File.stat(station_zip_path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.open(station_zip_path, [:read]) do
          {:ok, file_device} ->
            _ = File.close(file_device)
            true

          {:error, _reason} ->
            false
        end

      _ ->
        false
    end
  end

  defp station_zip_path_readable?(_station_zip_path), do: false

  defp ensure_station_scoped_referential_precheck(
         :station_reachability,
         runtime_input_gtfs_zip_path
       ) do
    case GtfsZipReader.read_tables(runtime_input_gtfs_zip_path) do
      {:ok, tables} ->
        stops_rows =
          tables
          |> Map.get("stops.txt", %{rows: []})
          |> Map.get(:rows, [])

        stop_times_rows =
          tables
          |> Map.get("stop_times.txt", %{rows: []})
          |> Map.get(:rows, [])

        stop_ids =
          stops_rows
          |> Enum.map(&(Map.get(&1.values, "stop_id") || ""))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()

        missing_stop_ids =
          stop_times_rows
          |> Enum.map(&(Map.get(&1.values, "stop_id") || ""))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.filter(&(not MapSet.member?(stop_ids, &1)))

        case missing_stop_ids do
          [] ->
            :ok

          _ ->
            {:error,
             [
               %{
                 code: :station_runtime_precheck_stop_times_stop_id_missing_stop,
                 severity: :error,
                 message: "Station runtime artifact failed scoped referential precheck",
                 details:
                   station_runtime_boundary_details(%{
                     runtime_scope: :station_reachability,
                     source_file: "stop_times.txt",
                     source_field: "stop_id",
                     target_file: "stops.txt",
                     target_field: "stop_id",
                     invalid_count: length(missing_stop_ids),
                     sample_values:
                       missing_stop_ids
                       |> Enum.uniq()
                       |> Enum.sort()
                       |> Enum.take(@station_runtime_precheck_sample_limit)
                   })
               }
             ]}
        end

      {:error, issues} ->
        {:error,
         [
           %{
             code: :station_runtime_precheck_artifact_read_failed,
             severity: :error,
             message: "Station runtime artifact precheck could not read GTFS tables",
             details:
               station_runtime_boundary_details(%{
                 runtime_scope: :station_reachability,
                 source_file: "runtime_input_gtfs_zip_path",
                 source_field: "path",
                 invalid_count: length(issues),
                 sample_values: station_runtime_sample_values([runtime_input_gtfs_zip_path]),
                 artifact_path: runtime_input_gtfs_zip_path,
                 issue_count: length(issues)
               })
           }
         ]}
    end
  end

  defp ensure_station_scoped_referential_precheck(_runtime_scope, _runtime_input_gtfs_zip_path),
    do: :ok

  defp station_runtime_boundary_details(overrides) when is_map(overrides) do
    Map.merge(@station_runtime_boundary_details, overrides)
  end

  defp station_runtime_sample_values(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@station_runtime_precheck_sample_limit)
  end

  defp graph_opts_for_gtfs_input(graph_opts, gtfs_zip_path, gtfs_meta)
       when is_list(graph_opts) and is_binary(gtfs_zip_path) and is_map(gtfs_meta) do
    graph_opts
    |> Keyword.put(:gtfs_zip_path, gtfs_zip_path)
    |> Keyword.put(:gtfs_meta, gtfs_meta)
  end

  @spec cleanup_on_success(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, cleanup_result()} | {:error, term()}
  def cleanup_on_success(organization_id, gtfs_version_id) do
    with {:ok, graph_result} <-
           GraphLifecycle.purge_graph_on_success(organization_id, gtfs_version_id),
         {:ok, gtfs_result} <-
           Lifecycle.purge_artifact_on_success(organization_id, gtfs_version_id) do
      {:ok, %{graph: graph_result, gtfs: gtfs_result}}
    end
  end

  @spec run_with_otp(Ecto.UUID.t(), Ecto.UUID.t(), run_callback(), keyword()) ::
          {:ok, term()}
          | {:ok, %{result: term(), runtime_meta: prepare_meta()}}
          | {:error, term()}
  def run_with_otp(organization_id, gtfs_version_id, callback, opts \\ [])
      when is_function(callback, 1) and is_list(opts) do
    status_callback = Keyword.get(opts, :status_callback)
    otp_status_callback = scoped_status_callback(status_callback, :otp)
    acquire_lock_fun = Keyword.get(opts, :acquire_lock_fun, &acquire_org_lock/1)
    release_lock_fun = Keyword.get(opts, :release_lock_fun, &release_org_lock/1)

    prepare_runtime_fun = Keyword.get(opts, :prepare_runtime_fun, &prepare_runtime/3)
    start_server_fun = Keyword.get(opts, :start_server_fun, &Server.start/2)
    wait_ready_fun = Keyword.get(opts, :wait_ready_fun, &Readiness.wait_until_ready/2)
    stop_server_fun = Keyword.get(opts, :stop_server_fun, &Server.stop/2)

    return_runtime_meta? = Keyword.get(opts, :return_runtime_meta, false)

    result =
      with :ok <- acquire_lock_fun.(organization_id) do
        try do
          with {:ok, prepared_runtime} <-
                 prepare_runtime_fun.(organization_id, gtfs_version_id, opts),
               :ok <- emit_runtime_status(otp_status_callback, :starting),
               {:ok, session} <- start_server_fun.(prepared_runtime.graph_path, opts) do
            try do
              with :ok <- emit_runtime_status(otp_status_callback, :waiting_ready),
                   :ok <- wait_ready_fun.(session, opts),
                   :ok <- emit_runtime_status(otp_status_callback, :ready),
                   {:ok, result} <- callback.(session) do
                {:ok,
                 maybe_attach_runtime_meta(result, prepared_runtime.meta, return_runtime_meta?)}
              end
            after
              _ = emit_runtime_status(otp_status_callback, :stopping)

              case stop_server_fun.(session, opts) do
                {:ok, _session} ->
                  _ = emit_runtime_status(otp_status_callback, :stopped)
                  :ok

                {:error, stop_reason} ->
                  _ = emit_runtime_status(otp_status_callback, :failed)
                  throw({:otp_stop_failed, stop_reason, session})
              end
            end
          end
        catch
          :throw, {:otp_stop_failed, stop_reason, session} ->
            {:error, [runtime_issue(:otp_stop_failed, stop_reason, session)]}
        after
          _ = release_lock_fun.(organization_id)
        end
      end

    normalize_runtime_result(result, otp_status_callback)
  end

  defp acquire_org_lock(organization_id) do
    lock_key = {:gtfs_planner_otp_runtime_lock, organization_id}

    if :global.set_lock(lock_key, [node()], 0) do
      :ok
    else
      {:error, %{reason: :runtime_already_running, organization_id: organization_id}}
    end
  end

  defp release_org_lock(organization_id) do
    lock_key = {:gtfs_planner_otp_runtime_lock, organization_id}
    _ = :global.del_lock(lock_key)
    :ok
  end

  defp scoped_status_callback(nil, _scope), do: nil

  defp scoped_status_callback(status_callback, scope) when is_function(status_callback, 1) do
    fn payload when is_map(payload) ->
      status_callback.(Map.put(payload, :scope, scope))
    end
  end

  defp emit_runtime_status(nil, _phase), do: :ok

  defp emit_runtime_status(status_callback, phase) when is_function(status_callback, 1) do
    status_callback.(%{phase: phase})
    :ok
  end

  defp normalize_runtime_result({:ok, _result} = ok, _status_callback), do: ok

  defp normalize_runtime_result({:error, issues} = error, _status_callback) when is_list(issues),
    do: error

  defp normalize_runtime_result({:error, reason}, status_callback) do
    case maybe_runtime_issue(reason) do
      {:ok, issue} ->
        _ = emit_runtime_status(status_callback, :failed)
        {:error, [issue]}

      :error ->
        _ = emit_runtime_status(status_callback, :failed)
        {:error, reason}
    end
  end

  defp maybe_runtime_issue(%{reason: :start_failed} = details),
    do: {:ok, runtime_issue(:otp_start_failed, details, nil)}

  defp maybe_runtime_issue(%{reason: :ready_timeout} = details),
    do: {:ok, runtime_issue(:otp_ready_timeout, details, nil)}

  defp maybe_runtime_issue(%{reason: :readiness_probe_failed} = details),
    do: {:ok, runtime_issue(:otp_readiness_probe_failed, details, nil)}

  defp maybe_runtime_issue(%{reason: :process_crashed} = details),
    do: {:ok, runtime_issue(:otp_process_crashed, details, nil)}

  defp maybe_runtime_issue(%{reason: :stop_failed} = details),
    do: {:ok, runtime_issue(:otp_stop_failed, details, nil)}

  defp maybe_runtime_issue(%{reason: :runtime_already_running} = details),
    do: {:ok, runtime_issue(:otp_runtime_already_running, details, nil)}

  defp maybe_runtime_issue(_), do: :error

  defp runtime_issue(code, details, nil) when is_atom(code) do
    %{code: code, details: details}
  end

  defp runtime_issue(code, details, %Session{} = session) when is_atom(code) do
    %{
      code: code,
      details: Map.merge(%{session: session}, normalize_issue_details(details))
    }
  end

  defp normalize_issue_details(details) when is_map(details), do: details
  defp normalize_issue_details(details), do: %{reason: details}

  defp maybe_attach_runtime_meta(result, _runtime_meta, false), do: result

  defp maybe_attach_runtime_meta(result, runtime_meta, true) do
    %{result: result, runtime_meta: runtime_meta}
  end
end
