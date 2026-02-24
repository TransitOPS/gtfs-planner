defmodule GtfsPlanner.Otp.Materializer do
  @moduledoc """
  Builds or reuses an OTP-ready GTFS zip artifact for an org/version scope.
  """

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Otp.Hasher
  alias GtfsPlanner.Otp.Manifest
  alias GtfsPlanner.Otp.Packager
  alias GtfsPlanner.Otp.Preflight

  @type issues :: [map()]
  @type preflight_mode :: :strict | :lenient
  @type status_phase ::
          :cache_check | :preflight | :exporting | :packaging | :persisting | :done | :failed
  @type status_payload :: %{required(:phase) => status_phase(), optional(atom()) => term()}
  @type meta :: %{
          reused: boolean(),
          content_hash: String.t(),
          file_size_bytes: non_neg_integer(),
          manifest_json: map()
        }

  @spec get_or_build_gtfs_zip(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, String.t(), meta()} | {:error, issues()}
  def get_or_build_gtfs_zip(organization_id, gtfs_version_id, opts) when is_list(opts) do
    status_callback = Keyword.get(opts, :status_callback)
    preflight_mode = Keyword.get(opts, :preflight_mode, :strict)
    force_rebuild? = Keyword.get(opts, :force_rebuild, false)

    emit_status(status_callback, %{phase: :cache_check})

    case if(force_rebuild?, do: :miss, else: cache_hit(organization_id, gtfs_version_id)) do
      {:ok, zip_path, meta} ->
        emit_status(status_callback, %{phase: :done, reused: true})
        {:ok, zip_path, meta}

      :miss ->
        emit_status(status_callback, %{phase: :preflight})
        build_and_persist(organization_id, gtfs_version_id, status_callback, preflight_mode)
    end
  end

  @spec get_or_build_gtfs_zip(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, String.t(), meta()} | {:error, issues()}
  def get_or_build_gtfs_zip(organization_id, gtfs_version_id) do
    get_or_build_gtfs_zip(organization_id, gtfs_version_id, [])
  end

  defp cache_hit(organization_id, gtfs_version_id) do
    case Otp.fetch_artifact(organization_id, gtfs_version_id) do
      {:ok, artifact} ->
        expected_zip_path = ArtifactPath.artifact_zip_path(organization_id, gtfs_version_id)

        if reusable_artifact?(artifact, expected_zip_path) do
          {:ok, artifact.zip_path, artifact_meta(artifact, true)}
        else
          :miss
        end

      {:error, :not_found} ->
        :miss
    end
  end

  defp reusable_artifact?(artifact, expected_zip_path) do
    artifact.zip_path == expected_zip_path and
      File.regular?(artifact.zip_path) and
      file_size_matches?(artifact)
  end

  defp file_size_matches?(artifact) do
    case File.stat(artifact.zip_path) do
      {:ok, stat} -> stat.size == artifact.file_size_bytes
      {:error, _reason} -> false
    end
  end

  defp build_and_persist(organization_id, gtfs_version_id, status_callback, preflight_mode) do
    case Preflight.run(organization_id, gtfs_version_id) do
      :ok ->
        do_build_and_persist(organization_id, gtfs_version_id, status_callback)

      {:error, issues} ->
        handle_preflight_issues(
          organization_id,
          gtfs_version_id,
          status_callback,
          preflight_mode,
          issues
        )
    end
  end

  defp handle_preflight_issues(
         organization_id,
         gtfs_version_id,
         status_callback,
         :lenient,
         issues
       ) do
    emit_status(status_callback, %{phase: :preflight, preflight_issues_count: length(issues)})
    do_build_and_persist(organization_id, gtfs_version_id, status_callback)
  end

  defp handle_preflight_issues(
         _organization_id,
         _gtfs_version_id,
         status_callback,
         :strict,
         issues
       ) do
    emit_status(status_callback, %{phase: :failed, reason: :preflight_failed})
    {:error, issues}
  end

  defp do_build_and_persist(organization_id, gtfs_version_id, status_callback) do
    staging_dir = build_staging_dir(organization_id, gtfs_version_id)
    specs = build_specs()

    try do
      emit_status(status_callback, %{phase: :exporting})

      with {:ok, file_paths} <-
             Export.export_specs_to_directory(
               organization_id,
               gtfs_version_id,
               specs,
               staging_dir
             ),
           manifest_files <- manifest_files(specs, file_paths),
           zip_path <- ArtifactPath.artifact_zip_path(organization_id, gtfs_version_id),
           _ = emit_status(status_callback, %{phase: :packaging}),
           {:ok, ^zip_path, file_size_bytes} <-
             Packager.package_staging_dir(staging_dir, zip_path),
           {:ok, content_hash} <- Hasher.sha256_for_filenames(manifest_files, staging_dir),
           manifest_json = %{"files" => manifest_files},
           _ = emit_status(status_callback, %{phase: :persisting}),
           {:ok, artifact} <-
             Otp.upsert_artifact(%{
               organization_id: organization_id,
               gtfs_version_id: gtfs_version_id,
               zip_path: zip_path,
               content_hash: content_hash,
               file_size_bytes: file_size_bytes,
               manifest_json: manifest_json
             }) do
        emit_status(status_callback, %{phase: :done, reused: false})
        {:ok, zip_path, artifact_meta(artifact, false)}
      else
        {:error, reason} ->
          emit_status(status_callback, %{phase: :failed, reason: :materialization_failed})
          {:error, [build_issue(:materialization_failed, reason)]}
      end
    after
      File.rm_rf(staging_dir)
    end
  end

  defp emit_status(nil, _payload), do: :ok

  defp emit_status(status_callback, payload) when is_function(status_callback, 1) do
    status_callback.(payload)
  end

  defp build_specs do
    Manifest.required_base_specs() ++
      Manifest.calendar_alternative_specs() ++ Manifest.optional_specs()
  end

  defp manifest_files(specs, file_paths) do
    exported_files =
      file_paths
      |> Enum.map(&Path.basename/1)
      |> MapSet.new()

    specs
    |> Enum.map(& &1.filename)
    |> Enum.filter(&MapSet.member?(exported_files, &1))
  end

  defp build_staging_dir(organization_id, gtfs_version_id) do
    unique_id = :erlang.unique_integer([:positive])

    Path.join([
      ArtifactPath.artifact_dir(organization_id, gtfs_version_id),
      "staging",
      Integer.to_string(unique_id)
    ])
  end

  defp artifact_meta(artifact, reused?) do
    %{
      reused: reused?,
      content_hash: artifact.content_hash,
      file_size_bytes: artifact.file_size_bytes,
      manifest_json: artifact.manifest_json
    }
  end

  defp build_issue(code, details) do
    %{
      code: code,
      severity: :error,
      message: "OTP GTFS materialization failed",
      details: %{reason: inspect(details)}
    }
  end
end
