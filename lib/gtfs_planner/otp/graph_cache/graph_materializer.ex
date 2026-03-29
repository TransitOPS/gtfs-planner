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
  @type cache_identity :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:gtfs_input_sha256) => String.t(),
          required(:scope_key) => scope_key()
        }

  @type scope_key :: GraphPath.scope_key()

  @spec get_or_build_graph(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, String.t(), meta()} | {:error, issues()}
  def get_or_build_graph(organization_id, gtfs_version_id, opts \\ []) when is_list(opts) do
    status_callback = Keyword.get(opts, :status_callback)
    cache_lookup_fun = Keyword.get(opts, :cache_lookup_fun, &cache_hit/1)
    preflight_fun = Keyword.get(opts, :preflight_fun, &GraphPreflight.run/3)
    build_fun = Keyword.get(opts, :build_fun, &GraphBuilder.build/2)
    persist_fun = Keyword.get(opts, :persist_fun, &persist_manifest/4)
    stage_fun = Keyword.get(opts, :stage_fun, &stage_inputs/4)

    gtfs_input_sha256_resolver_fun =
      Keyword.get(opts, :gtfs_input_sha256_resolver_fun, &resolve_gtfs_input_sha256/3)

    build_opts =
      opts
      |> Keyword.get(:build_opts, [])
      |> Keyword.put_new(:gtfs_zip_path, Keyword.get(opts, :gtfs_zip_path))
      |> Keyword.put_new(:gtfs_meta, Keyword.get(opts, :gtfs_meta, %{}))

    force_rebuild? = Keyword.get(opts, :force_rebuild, false)
    runtime_scope = Keyword.get(opts, :runtime_scope, :default)

    with {:ok, gtfs_input_sha256} <-
           resolve_expected_gtfs_input_sha256(
             gtfs_input_sha256_resolver_fun,
             organization_id,
             gtfs_version_id,
             build_opts
           ),
         scope_key <- derive_scope_key(runtime_scope, gtfs_input_sha256),
         cache_identity <-
           build_cache_identity(organization_id, gtfs_version_id, gtfs_input_sha256, scope_key) do
      build_opts =
        build_opts
        |> Keyword.put(:gtfs_input_sha256, gtfs_input_sha256)
        |> Keyword.put(:scope_key, scope_key)

      if force_rebuild? do
        emit_status(status_callback, %{phase: :preflight})

        case preflight_fun.(organization_id, gtfs_version_id, opts) do
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
      else
        emit_status(status_callback, %{phase: :cache_check})

        case cache_lookup(cache_lookup_fun, cache_identity) do
          {:ok, graph_path, manifest_path, manifest_json} ->
            emit_status(status_callback, %{phase: :done, reused: true})

            {:ok, graph_path,
             %{reused: true, manifest_path: manifest_path, manifest_json: manifest_json}}

          :miss ->
            emit_status(status_callback, %{phase: :preflight})

            case preflight_fun.(organization_id, gtfs_version_id, opts) do
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
    else
      {:error, reason} ->
        emit_status(status_callback, %{phase: :failed, reason: :gtfs_input_fingerprint_failed})

        {:error,
         [
           build_issue(
             :gtfs_input_fingerprint_failed,
             map_gtfs_input_fingerprint_error(reason)
           )
         ]}
    end
  end

  @spec resolve_gtfs_input_sha256(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_gtfs_input_sha256(organization_id, gtfs_version_id, build_opts \\ [])
      when is_list(build_opts) do
    with {:ok, gtfs_source_zip_path} <-
           resolve_gtfs_source_zip_path(organization_id, gtfs_version_id, build_opts),
         {:ok, gtfs_input_sha256} <- file_sha256(gtfs_source_zip_path) do
      {:ok, gtfs_input_sha256}
    end
  end

  @spec derive_scope_key(atom() | String.t(), String.t()) :: scope_key()
  def derive_scope_key(runtime_scope, gtfs_input_sha256)
      when (is_atom(runtime_scope) or is_binary(runtime_scope)) and is_binary(gtfs_input_sha256) and
             gtfs_input_sha256 != "" do
    %{
      runtime_scope: normalize_runtime_scope(runtime_scope),
      gtfs_input_sha256: normalize_gtfs_input_sha256_segment(gtfs_input_sha256)
    }
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

    scope_key = Keyword.fetch!(build_opts, :scope_key)
    data_dir = GraphPath.data_dir(organization_id, gtfs_version_id, scope_key)

    case stage_inputs(stage_fun, organization_id, gtfs_version_id, data_dir, build_opts) do
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

  defp resolve_expected_gtfs_input_sha256(
         gtfs_input_sha256_resolver_fun,
         organization_id,
         gtfs_version_id,
         build_opts
       )
       when is_function(gtfs_input_sha256_resolver_fun, 3) do
    gtfs_input_sha256_resolver_fun.(organization_id, gtfs_version_id, build_opts)
  end

  defp resolve_expected_gtfs_input_sha256(
         gtfs_input_sha256_resolver_fun,
         organization_id,
         gtfs_version_id,
         _build_opts
       )
       when is_function(gtfs_input_sha256_resolver_fun, 2) do
    gtfs_input_sha256_resolver_fun.(organization_id, gtfs_version_id)
  end

  defp build_cache_identity(organization_id, gtfs_version_id, gtfs_input_sha256, scope_key) do
    %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      gtfs_input_sha256: gtfs_input_sha256,
      scope_key: scope_key
    }
  end

  defp cache_lookup(cache_lookup_fun, cache_identity) when is_function(cache_lookup_fun, 1) do
    cache_lookup_fun.(cache_identity)
  end

  defp cache_hit(%{
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id,
         gtfs_input_sha256: expected_gtfs_input_sha256,
         scope_key: scope_key
       }) do
    graph_path = GraphPath.graph_obj_path(organization_id, gtfs_version_id, scope_key)
    manifest_path = GraphPath.manifest_path(organization_id, gtfs_version_id, scope_key)

    with {:ok, artifact} <- Otp.fetch_artifact(organization_id, gtfs_version_id),
         true <- File.regular?(graph_path),
         true <- File.regular?(manifest_path),
         {:ok, manifest_json} <- read_manifest(manifest_path),
         true <- manifest_json["schema_version"] == GraphManifest.schema_version(),
         true <- manifest_json["gtfs_content_hash"] == artifact.content_hash,
         true <- manifest_json["gtfs_input_sha256"] == expected_gtfs_input_sha256,
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

  defp stage_inputs(stage_fun, organization_id, gtfs_version_id, data_dir, build_opts)
       when is_function(stage_fun, 4) do
    stage_fun.(organization_id, gtfs_version_id, data_dir, build_opts)
  end

  defp stage_inputs(stage_fun, organization_id, gtfs_version_id, data_dir, _build_opts)
       when is_function(stage_fun, 3) do
    stage_fun.(organization_id, gtfs_version_id, data_dir)
  end

  defp stage_inputs(organization_id, gtfs_version_id, data_dir, build_opts) do
    scope_key = Keyword.fetch!(build_opts, :scope_key)

    with :ok <- File.mkdir_p(data_dir),
         {:ok, gtfs_path} <-
           resolve_gtfs_source_zip_path(organization_id, gtfs_version_id, build_opts),
         {:ok, osm_path} <- OsmPath.resolve(),
         gtfs_staged_path <-
           GraphPath.staged_gtfs_zip_path(organization_id, gtfs_version_id, scope_key),
         osm_staged_path <-
           GraphPath.staged_osm_path(organization_id, gtfs_version_id, scope_key, osm_path),
         :ok <- copy_file(:gtfs, gtfs_path, gtfs_staged_path),
         :ok <- copy_file(:osm, osm_path, osm_staged_path) do
      :ok
    end
  end

  defp resolve_gtfs_source_zip_path(organization_id, gtfs_version_id, build_opts) do
    case Keyword.get(build_opts, :gtfs_zip_path) do
      gtfs_zip_path when is_binary(gtfs_zip_path) and gtfs_zip_path != "" ->
        {:ok, gtfs_zip_path}

      _ ->
        with {:ok, artifact} <- Otp.fetch_artifact(organization_id, gtfs_version_id) do
          {:ok, artifact.zip_path}
        end
    end
  end

  defp copy_file(file_type, source_path, destination_path) do
    case File.mkdir_p(Path.dirname(destination_path)) do
      :ok ->
        case File.copy(source_path, destination_path) do
          {:ok, _bytes_copied} ->
            :ok

          {:error, file_error} ->
            {:error, {:file_copy_failed, file_type, source_path, destination_path, file_error}}
        end

      {:error, reason} ->
        {:error, reason}
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

  defp map_gtfs_input_fingerprint_error(reason) do
    case reason do
      {:error, atom_reason} when is_atom(atom_reason) ->
        %{reason_code: atom_reason}

      atom_reason when is_atom(atom_reason) ->
        %{reason_code: atom_reason}

      other_reason ->
        %{reason_code: :unknown_gtfs_input_fingerprint_error, reason: inspect(other_reason)}
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

  defp persist_manifest(organization_id, gtfs_version_id, build_result, build_opts) do
    scope_key = Keyword.fetch!(build_opts, :scope_key)

    with {:ok, gtfs_content_hash} <-
           resolve_gtfs_content_hash(organization_id, gtfs_version_id, build_opts),
         {:ok, gtfs_input_sha256} <-
           resolve_manifest_gtfs_input_sha256(organization_id, gtfs_version_id, build_opts),
         {:ok, osm_path} <- OsmPath.resolve(),
         {:ok, osm_fingerprint} <- file_sha256(osm_path),
         manifest_path <- GraphPath.manifest_path(organization_id, gtfs_version_id, scope_key),
         manifest_json <-
           GraphManifest.build(
             gtfs_content_hash,
             gtfs_input_sha256,
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

  defp resolve_manifest_gtfs_input_sha256(organization_id, gtfs_version_id, build_opts) do
    case Keyword.get(build_opts, :gtfs_input_sha256) do
      gtfs_input_sha256 when is_binary(gtfs_input_sha256) and gtfs_input_sha256 != "" ->
        {:ok, gtfs_input_sha256}

      _ ->
        resolve_gtfs_input_sha256(organization_id, gtfs_version_id, build_opts)
    end
  end

  defp resolve_gtfs_content_hash(organization_id, gtfs_version_id, build_opts) do
    case Keyword.get(build_opts, :gtfs_meta, %{}) do
      %{content_hash: content_hash} when is_binary(content_hash) and content_hash != "" ->
        {:ok, content_hash}

      _ ->
        with {:ok, artifact} <- Otp.fetch_artifact(organization_id, gtfs_version_id) do
          {:ok, artifact.content_hash}
        end
    end
  end

  defp normalize_runtime_scope(runtime_scope) do
    runtime_scope
    |> runtime_scope_to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "default"
      normalized_scope -> normalized_scope
    end
  end

  defp runtime_scope_to_string(runtime_scope) when is_atom(runtime_scope),
    do: Atom.to_string(runtime_scope)

  defp runtime_scope_to_string(runtime_scope) when is_binary(runtime_scope), do: runtime_scope

  defp normalize_gtfs_input_sha256_segment(gtfs_input_sha256) do
    normalized_sha =
      gtfs_input_sha256
      |> String.trim()
      |> String.downcase()

    if normalized_sha != "" and String.match?(normalized_sha, ~r/^[a-f0-9]+$/) do
      normalized_sha
    else
      :crypto.hash(:sha256, normalized_sha)
      |> Base.encode16(case: :lower)
    end
  end

  defp file_sha256(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io_device} ->
        try do
          digest =
            io_device
            |> IO.binstream(2_097_152)
            |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
            |> :crypto.hash_final()
            |> Base.encode16(case: :lower)

          {:ok, digest}
        rescue
          error in File.Error -> {:error, error.reason}
        after
          File.close(io_device)
        end

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
