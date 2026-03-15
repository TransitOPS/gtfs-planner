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
  alias GtfsPlanner.Validations.PathwaysPreflight

  @type issues :: [map()]
  @type preflight_mode :: :strict | :lenient
  @type status_phase ::
          :cache_check | :preflight | :exporting | :packaging | :persisting | :done | :failed
  @type status_payload :: %{required(:phase) => status_phase(), optional(atom()) => term()}
  @type meta :: %{
          reused: boolean(),
          content_hash: String.t(),
          file_size_bytes: non_neg_integer(),
          manifest_json: map(),
          preflight_warnings: issues()
        }

  @spec get_or_build_gtfs_zip(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, String.t(), meta()} | {:error, issues()}
  def get_or_build_gtfs_zip(organization_id, gtfs_version_id, opts) when is_list(opts) do
    status_callback = Keyword.get(opts, :status_callback)
    preflight_mode = Keyword.get(opts, :preflight_mode, :strict)
    force_rebuild? = Keyword.get(opts, :force_rebuild, false)

    if force_rebuild? do
      emit_status(status_callback, %{phase: :preflight})
      build_and_persist(organization_id, gtfs_version_id, status_callback, preflight_mode, opts)
    else
      emit_status(status_callback, %{phase: :cache_check})

      case cache_hit(organization_id, gtfs_version_id) do
        {:ok, zip_path, meta} ->
          emit_status(status_callback, %{phase: :done, reused: true})
          {:ok, zip_path, meta}

        :miss ->
          emit_status(status_callback, %{phase: :preflight})

          build_and_persist(
            organization_id,
            gtfs_version_id,
            status_callback,
            preflight_mode,
            opts
          )
      end
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

  defp build_and_persist(organization_id, gtfs_version_id, status_callback, preflight_mode, opts) do
    case Preflight.run(organization_id, gtfs_version_id) do
      :ok ->
        do_build_and_persist(
          organization_id,
          gtfs_version_id,
          status_callback,
          preflight_mode,
          [],
          opts
        )

      {:error, issues} ->
        handle_preflight_issues(
          organization_id,
          gtfs_version_id,
          status_callback,
          preflight_mode,
          issues,
          opts
        )
    end
  end

  defp handle_preflight_issues(
         organization_id,
         gtfs_version_id,
         status_callback,
         :lenient,
         issues,
         opts
       ) do
    emit_status(status_callback, %{phase: :preflight, preflight_issues_count: length(issues)})

    do_build_and_persist(
      organization_id,
      gtfs_version_id,
      status_callback,
      :lenient,
      issues,
      opts
    )
  end

  defp handle_preflight_issues(
         _organization_id,
         _gtfs_version_id,
         status_callback,
         :strict,
         issues,
         _opts
       ) do
    emit_status(status_callback, %{phase: :failed, reason: :preflight_failed})
    {:error, issues}
  end

  defp do_build_and_persist(
         organization_id,
         gtfs_version_id,
         status_callback,
         preflight_mode,
         otp_preflight_issues,
         opts
       ) do
    pathways_preflight_outcome = run_pathways_preflight(organization_id, gtfs_version_id, opts)
    preflight_warnings = preflight_warnings(pathways_preflight_outcome)
    blocking_errors = normalize_blocking_errors(pathways_preflight_outcome)

    if preflight_warnings != [] do
      emit_status(status_callback, %{
        phase: :preflight,
        preflight_warnings_count: length(preflight_warnings)
      })
    end

    case gate_pathways_preflight(blocking_errors, preflight_mode, status_callback) do
      {:ok, demoted_warnings} ->
        merged_warnings = preflight_warnings ++ demoted_warnings

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
            {:ok, zip_path, artifact_meta(artifact, false, merged_warnings, otp_preflight_issues)}
          else
            {:error, reason} ->
              emit_status(status_callback, %{phase: :failed, reason: :materialization_failed})
              {:error, [build_issue(:materialization_failed, reason)]}
          end
        after
          File.rm_rf(staging_dir)
        end

      {:error, blocking_errors} ->
        {:error, blocking_errors}
    end
  end

  defp gate_pathways_preflight([], _preflight_mode, _status_callback) do
    {:ok, []}
  end

  defp gate_pathways_preflight(blocking_errors, :lenient, status_callback) do
    demoted =
      Enum.map(blocking_errors, fn issue ->
        %{issue | severity: :warning}
      end)

    emit_status(status_callback, %{
      phase: :preflight,
      demoted_blocking_errors_count: length(demoted)
    })

    {:ok, demoted}
  end

  defp gate_pathways_preflight(blocking_errors, :strict, status_callback) do
    emit_status(status_callback, %{
      phase: :failed,
      reason: :pathways_preflight_failed,
      blocking_errors_count: length(blocking_errors)
    })

    {:error, blocking_errors}
  end

  defp normalize_blocking_errors({status, payload})
       when status in [:ok, :error] and is_map(payload) do
    blocking_errors = Map.get(payload, :blocking_errors, Map.get(payload, "blocking_errors"))

    case normalize_issue_list(blocking_errors) do
      [] when status == :error ->
        [
          build_blocking_issue(
            :pathways_preflight_invalid_payload,
            "Pathways preflight failed with invalid blocking_errors payload",
            %{payload: inspect(payload)}
          )
        ]

      issues ->
        issues
    end
  end

  defp normalize_blocking_errors({status, payload}) when status in [:ok, :error] do
    [
      build_blocking_issue(
        :pathways_preflight_invalid_payload,
        "Pathways preflight returned malformed payload",
        %{payload: inspect(payload)}
      )
    ]
  end

  defp normalize_blocking_errors(outcome) do
    [
      build_blocking_issue(
        :pathways_preflight_invalid_outcome,
        "Pathways preflight returned unsupported outcome",
        %{outcome: inspect(outcome)}
      )
    ]
  end

  defp normalize_issue_list(blocking_errors) when is_list(blocking_errors) do
    Enum.map(blocking_errors, &normalize_issue/1)
  end

  defp normalize_issue_list(nil), do: []

  defp normalize_issue_list(blocking_errors) do
    [
      build_blocking_issue(
        :pathways_preflight_invalid_blocking_errors,
        "Pathways preflight returned invalid blocking_errors value",
        %{blocking_errors: inspect(blocking_errors)}
      )
    ]
  end

  defp normalize_issue(issue) when is_map(issue) do
    code = Map.get(issue, :code, Map.get(issue, "code", :pathways_preflight_blocking_issue))

    message =
      Map.get(
        issue,
        :message,
        Map.get(issue, "message", "Pathways preflight reported a blocking issue")
      )

    context = Map.get(issue, :context, Map.get(issue, "context", %{}))

    severity =
      case Map.get(issue, :severity, Map.get(issue, "severity", :blocking)) do
        value when value in [:blocking, :error, :warning, :info] -> value
        "blocking" -> :blocking
        "error" -> :error
        "warning" -> :warning
        "info" -> :info
        _value -> :blocking
      end

    %{
      code: code,
      severity: severity,
      message: message,
      context: context
    }
  end

  defp normalize_issue(issue) do
    build_blocking_issue(
      :pathways_preflight_invalid_issue,
      "Pathways preflight returned malformed blocking issue",
      %{issue: inspect(issue)}
    )
  end

  defp build_blocking_issue(code, message, context) do
    %{
      code: code,
      severity: :blocking,
      message: message,
      context: context
    }
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
    artifact_meta(artifact, reused?, [], [])
  end

  defp artifact_meta(artifact, reused?, preflight_warnings, otp_preflight_issues) do
    %{
      reused: reused?,
      content_hash: artifact.content_hash,
      file_size_bytes: artifact.file_size_bytes,
      manifest_json: artifact.manifest_json,
      preflight_warnings: preflight_warnings,
      otp_preflight_issues: otp_preflight_issues
    }
  end

  defp preflight_warnings({_status, %{warnings: warnings}}) when is_list(warnings), do: warnings
  defp preflight_warnings(_outcome), do: []

  defp build_issue(code, details) do
    %{
      code: code,
      severity: :error,
      message: "OTP GTFS materialization failed",
      details: %{reason: inspect(details)}
    }
  end

  defp run_pathways_preflight(organization_id, gtfs_version_id, opts) do
    pathways_preflight_fun = Keyword.get(opts, :pathways_preflight_fun, &PathwaysPreflight.run/3)
    pathways_preflight_fun.(organization_id, gtfs_version_id, [])
  end
end
