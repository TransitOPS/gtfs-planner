defmodule GtfsPlanner.Otp.Runtime do
  @moduledoc """
  OTP runtime orchestration boundary for Phase 1 and Phase 2 materialization.
  """

  alias GtfsPlanner.Otp.Runtime.Readiness
  alias GtfsPlanner.Otp.Runtime.Server
  alias GtfsPlanner.Otp.Runtime.Session
  alias GtfsPlanner.Otp.GraphLifecycle
  alias GtfsPlanner.Otp.GraphMaterializer
  alias GtfsPlanner.Otp.Lifecycle
  alias GtfsPlanner.Otp.Materializer

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

    gtfs_materializer_fun =
      Keyword.get(opts, :gtfs_materializer_fun, &Materializer.get_or_build_gtfs_zip/3)

    graph_materializer_fun =
      Keyword.get(opts, :graph_materializer_fun, &GraphMaterializer.get_or_build_graph/3)

    gtfs_opts =
      opts
      |> Keyword.get(:gtfs_opts, [])
      |> Keyword.put_new(:preflight_mode, preflight_mode)
      |> Keyword.put_new(:force_rebuild, force_rebuild?)
      |> Keyword.put(:status_callback, scoped_status_callback(status_callback, :gtfs))

    graph_opts =
      opts
      |> Keyword.get(:graph_opts, [])
      |> Keyword.put_new(:force_rebuild, force_rebuild?)
      |> Keyword.put(:status_callback, scoped_status_callback(status_callback, :graph))

    with {:ok, gtfs_zip_path, gtfs_meta} <-
           gtfs_materializer_fun.(organization_id, gtfs_version_id, gtfs_opts),
         {:ok, graph_path, graph_meta} <-
           graph_materializer_fun.(organization_id, gtfs_version_id, graph_opts) do
      {:ok,
       %{
         gtfs_zip_path: gtfs_zip_path,
         graph_path: graph_path,
         meta: %{
           gtfs: gtfs_meta,
           graph: graph_meta
         }
       }}
    end
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
          {:ok, term()} | {:ok, %{result: term(), runtime_meta: prepare_meta()}} | {:error, term()}
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
                {:ok, maybe_attach_runtime_meta(result, prepared_runtime.meta, return_runtime_meta?)}
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
