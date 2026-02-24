defmodule GtfsPlanner.Otp.GraphMaterializer do
  @moduledoc """
  Builds or reuses an OTP graph artifact for an org/version scope.
  """

  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.GraphBuilder
  alias GtfsPlanner.Otp.GraphManifest
  alias GtfsPlanner.Otp.GraphPath
  alias GtfsPlanner.Otp.GraphPreflight
  alias GtfsPlanner.Otp.OsmPath

  @type issues :: [map()]
  @type status_phase :: :cache_check | :preflight | :building | :persisting | :done | :failed
  @type status_payload :: %{required(:phase) => status_phase(), optional(atom()) => term()}
  @type meta :: %{
          reused: boolean(),
          manifest_path: String.t(),
          manifest_json: map()
        }

  @spec get_or_build_graph(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, String.t(), meta()} | {:error, issues()}
  def get_or_build_graph(organization_id, gtfs_version_id, opts \\ []) when is_list(opts) do
    status_callback = Keyword.get(opts, :status_callback)
    cache_lookup_fun = Keyword.get(opts, :cache_lookup_fun, &cache_hit/2)
    preflight_fun = Keyword.get(opts, :preflight_fun, &GraphPreflight.run/2)
    build_fun = Keyword.get(opts, :build_fun, &GraphBuilder.build/2)
    persist_fun = Keyword.get(opts, :persist_fun, &persist_manifest/4)
    stage_fun = Keyword.get(opts, :stage_fun, &stage_inputs/3)
    build_opts = Keyword.get(opts, :build_opts, [])
    force_rebuild? = Keyword.get(opts, :force_rebuild, false)

    emit_status(status_callback, %{phase: :cache_check})

    case if(force_rebuild?, do: :miss, else: cache_lookup_fun.(organization_id, gtfs_version_id)) do
      {:ok, graph_path, manifest_path, manifest_json} ->
        emit_status(status_callback, %{phase: :done, reused: true})

        {:ok, graph_path,
         %{reused: true, manifest_path: manifest_path, manifest_json: manifest_json}}

      :miss ->
        emit_status(status_callback, %{phase: :preflight})

        case preflight_fun.(organization_id, gtfs_version_id) do
          :ok ->
            do_build_and_persist(
              organization_id,
              gtfs_version_id,
              status_callback,
              build_fun,
              persist_fun,
              stage_fun,
              build_opts
            )

          {:error, issues} ->
            emit_status(status_callback, %{phase: :failed, reason: :preflight_failed})
            {:error, issues}
        end
    end
  end

  defp do_build_and_persist(
         organization_id,
         gtfs_version_id,
         status_callback,
         build_fun,
         persist_fun,
         stage_fun,
         build_opts
       ) do
    emit_status(status_callback, %{phase: :building})

    data_dir = GraphPath.data_dir(organization_id, gtfs_version_id)

    case stage_fun.(organization_id, gtfs_version_id, data_dir) do
      :ok ->
        case build_fun.(data_dir, build_opts) do
          {:ok, build_result} ->
            emit_status(status_callback, %{phase: :persisting})

            case persist_fun.(organization_id, gtfs_version_id, build_result, build_opts) do
              {:ok, manifest_path, manifest_json} ->
                emit_status(status_callback, %{phase: :done, reused: false})

                {:ok, build_result.graph_path,
                 %{reused: false, manifest_path: manifest_path, manifest_json: manifest_json}}

              {:error, reason} ->
                emit_status(status_callback, %{phase: :failed, reason: :persist_failed})
                {:error, [build_issue(:persist_failed, map_persist_error(reason))]}
            end

          {:error, reason} ->
            emit_status(status_callback, %{phase: :failed, reason: :build_failed})
            {:error, [build_issue(:build_failed, map_build_error(reason))]}
        end

      {:error, reason} ->
        emit_status(status_callback, %{phase: :failed, reason: :staging_failed})
        {:error, [build_issue(:staging_failed, map_staging_error(reason))]}
    end
  end

  defp emit_status(nil, _payload), do: :ok

  defp emit_status(status_callback, payload) when is_function(status_callback, 1) do
    status_callback.(payload)
  end

  defp cache_hit(organization_id, gtfs_version_id) do
    graph_path = GraphPath.graph_obj_path(organization_id, gtfs_version_id)
    manifest_path = GraphPath.manifest_path(organization_id, gtfs_version_id)

    with {:ok, artifact} <- Otp.fetch_artifact(organization_id, gtfs_version_id),
         true <- File.regular?(graph_path),
         true <- File.regular?(manifest_path),
         {:ok, manifest_json} <- read_manifest(manifest_path),
         true <- manifest_json["schema_version"] == GraphManifest.schema_version(),
         true <- manifest_json["gtfs_content_hash"] == artifact.content_hash,
         {:ok, osm_path} <- OsmPath.resolve(),
         {:ok, osm_fingerprint} <- file_sha256(osm_path),
         true <- manifest_json["osm_fingerprint"] == osm_fingerprint,
         true <- jar_fingerprint_match?(manifest_json) do
      {:ok, graph_path, manifest_path, manifest_json}
    else
      _reason -> :miss
    end
  end

  defp read_manifest(manifest_path) do
    with {:ok, manifest_body} <- File.read(manifest_path),
         {:ok, manifest_json} <- Jason.decode(manifest_body),
         true <- GraphManifest.valid?(manifest_json) do
      {:ok, manifest_json}
    else
      _reason -> {:error, :invalid_manifest}
    end
  end

  defp jar_fingerprint_match?(manifest_json) do
    case Application.get_env(:gtfs_planner, :otp_jar_sha256) do
      nil -> true
      configured_fingerprint -> manifest_json["otp_jar_sha256"] == configured_fingerprint
    end
  end

  defp stage_inputs(organization_id, gtfs_version_id, data_dir) do
    with :ok <- File.mkdir_p(data_dir),
         {:ok, artifact} <- Otp.fetch_artifact(organization_id, gtfs_version_id),
         {:ok, osm_path} <- OsmPath.resolve(),
         gtfs_staged_path <- GraphPath.staged_gtfs_zip_path(organization_id, gtfs_version_id),
         osm_staged_path <- GraphPath.staged_osm_path(organization_id, gtfs_version_id, osm_path),
         :ok <- copy_file(artifact.zip_path, gtfs_staged_path),
         :ok <- copy_file(osm_path, osm_staged_path) do
      :ok
    end
  end

  defp copy_file(source_path, destination_path) do
    with :ok <- File.mkdir_p(Path.dirname(destination_path)),
         {:ok, _bytes_copied} <- File.copy(source_path, destination_path) do
      :ok
    end
  end

  defp map_staging_error(reason) do
    case reason do
      {:file_copy_failed, file_type, source_path, destination_path, file_error} ->
        %{
          reason_code: :file_copy_failed,
          file_type: file_type,
          source_path: source_path,
          destination_path: destination_path,
          file_error: inspect(file_error)
        }

      {:error, atom_reason} when is_atom(atom_reason) ->
        %{reason_code: atom_reason}

      atom_reason when is_atom(atom_reason) ->
        %{reason_code: atom_reason}

      other_reason ->
        %{reason_code: :unknown_staging_error, reason: inspect(other_reason)}
    end
  end

  defp map_build_error(reason) when is_map(reason) do
    %{
      reason_code: Map.get(reason, :code, :build_command_failed),
      exit_status: Map.get(reason, :exit_status),
      graph_path: Map.get(reason, :graph_path),
      build_log_path: Map.get(reason, :build_log_path)
    }
  end

  defp map_build_error(reason) when is_atom(reason), do: %{reason_code: reason}
  defp map_build_error(reason), do: %{reason_code: :unknown_build_error, reason: inspect(reason)}

  defp map_persist_error(reason) when is_atom(reason), do: %{reason_code: reason}

  defp map_persist_error(reason),
    do: %{reason_code: :unknown_persist_error, reason: inspect(reason)}

  defp persist_manifest(organization_id, gtfs_version_id, build_result, _build_opts) do
    with {:ok, artifact} <- Otp.fetch_artifact(organization_id, gtfs_version_id),
         {:ok, osm_path} <- OsmPath.resolve(),
         {:ok, osm_fingerprint} <- file_sha256(osm_path),
         manifest_path <- GraphPath.manifest_path(organization_id, gtfs_version_id),
         manifest_json <-
           GraphManifest.build(
             artifact.content_hash,
             osm_fingerprint,
             Application.get_env(:gtfs_planner, :otp_jar_sha256),
             %{
               "command" => build_result.command,
               "args" => build_result.args,
               "graph_path" => build_result.graph_path,
               "build_log_path" => build_result.build_log_path
             },
             DateTime.utc_now()
           ),
         :ok <- File.mkdir_p(Path.dirname(manifest_path)),
         {:ok, encoded_manifest} <- Jason.encode(manifest_json),
         :ok <- File.write(manifest_path, encoded_manifest) do
      {:ok, manifest_path, manifest_json}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_sha256(path) do
    case File.read(path) do
      {:ok, content} ->
        digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
        {:ok, digest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_issue(code, details) when is_map(details) do
    %{
      code: code,
      severity: :error,
      message: "OTP graph materialization failed",
      details: details
    }
  end

  defp build_issue(code, details), do: build_issue(code, %{reason: inspect(details)})
end
