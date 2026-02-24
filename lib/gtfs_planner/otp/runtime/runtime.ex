defmodule GtfsPlanner.Otp.Runtime do
  @moduledoc """
  OTP runtime orchestration boundary for Phase 1 and Phase 2 materialization.
  """

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

  defp scoped_status_callback(nil, _scope), do: nil

  defp scoped_status_callback(status_callback, scope) when is_function(status_callback, 1) do
    fn payload when is_map(payload) ->
      status_callback.(Map.put(payload, :scope, scope))
    end
  end
end
