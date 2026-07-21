defmodule GtfsPlanner.Gtfs.Export.ArtifactStorage do
  @moduledoc """
  Private immutable storage for exported GTFS ZIP artifacts.

  A file in this root is never itself a published export. `ExportRuns` stores the
  verified metadata in the database before any caller may claim it for download.
  """

  @default_max_run_bytes 150 * 1024 * 1024

  @type artifact :: %{
          required(:key) => String.t(),
          required(:filename) => String.t(),
          required(:sha256) => String.t(),
          required(:size) => non_neg_integer(),
          required(:path) => String.t(),
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:run_id) => Ecto.UUID.t()
        }

  @spec publish(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t(), binary(), keyword()) ::
          {:ok, artifact()} | {:error, term()}
  def publish(organization_id, version_id, run_id, filename, bytes, opts \\ [])

  def publish(organization_id, version_id, run_id, filename, bytes, opts)
      when is_binary(filename) and is_binary(bytes) do
    with :ok <- validate_scope(organization_id, version_id, run_id),
         true <- safe_filename?(filename),
         {:ok, root} <- root(opts),
         :ok <- capacity_available?(root, bytes, opts),
         :ok <- ensure_run_directory(root, organization_id, version_id, run_id) do
      publish_bytes(root, organization_id, version_id, run_id, filename, bytes)
    else
      false -> {:error, :invalid_artifact_filename}
      {:error, _} = error -> error
    end
  end

  def publish(_, _, _, _, _, _), do: {:error, :invalid_artifact}

  @spec verify(map(), keyword()) :: {:ok, String.t()} | {:error, :missing_or_corrupt_artifact}
  def verify(artifact, opts \\ [])

  def verify(artifact, opts) when is_map(artifact) do
    with {:ok, root} <- root(opts),
         {:ok, path} <- artifact_path(root, artifact),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) == artifact_size(artifact),
         true <- digest(bytes) == artifact_digest(artifact) do
      {:ok, path}
    else
      _ -> {:error, :missing_or_corrupt_artifact}
    end
  end

  def verify(_, _), do: {:error, :missing_or_corrupt_artifact}

  @spec remove(map(), keyword()) :: :ok | {:error, term()}
  def remove(artifact, opts \\ []) when is_map(artifact) do
    with {:ok, root} <- root(opts),
         {:ok, path} <- artifact_path(root, artifact) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Removes run directories whose UUID is not represented by a durable retained row."
  @spec reconcile([Ecto.UUID.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(kept_run_ids, opts \\ []) when is_list(kept_run_ids) do
    with {:ok, root} <- root(opts) do
      base = Path.join(root, "export-runs")

      case File.ls(base) do
        {:ok, organizations} ->
          kept = MapSet.new(kept_run_ids)
          {:ok, reconcile_organizations(base, organizations, kept, 0)}

        {:error, :enoent} ->
          {:ok, 0}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp publish_bytes(root, organization_id, version_id, run_id, filename, bytes) do
    directory = run_directory(root, organization_id, version_id, run_id)
    key = Ecto.UUID.generate() <> ".zip"
    temporary = Path.join(directory, ".#{key}.tmp")
    final = Path.join(directory, key)
    expected_digest = digest(bytes)

    with :ok <- File.write(temporary, bytes, [:binary]),
         :ok <- File.rename(temporary, final),
         {:ok, final_bytes} <- File.read(final),
         true <- byte_size(final_bytes) == byte_size(bytes),
         true <- digest(final_bytes) == expected_digest do
      {:ok,
       %{
         key: key,
         filename: Path.basename(filename),
         sha256: expected_digest,
         size: byte_size(final_bytes),
         path: final,
         organization_id: organization_id,
         gtfs_version_id: version_id,
         run_id: run_id
       }}
    else
      _ ->
        _ = File.rm(temporary)
        _ = File.rm(final)
        {:error, :artifact_verification_failed}
    end
  end

  defp capacity_available?(root, bytes, opts) do
    max_run_bytes =
      Keyword.get(
        opts,
        :max_run_bytes,
        Application.get_env(
          :gtfs_planner,
          :gtfs_task_artifacts_max_run_bytes,
          @default_max_run_bytes
        )
      )

    max_total_bytes =
      Keyword.get(
        opts,
        :max_total_bytes,
        Application.get_env(
          :gtfs_planner,
          :gtfs_task_artifacts_max_total_bytes,
          1024 * 1024 * 1024
        )
      )

    with :ok <- valid_capacity?(max_run_bytes, max_total_bytes),
         :ok <- within_capacity?(byte_size(bytes), max_run_bytes) do
      within_total_capacity?(root, byte_size(bytes), max_total_bytes)
    end
  end

  defp valid_capacity?(max_run_bytes, max_total_bytes)
       when is_integer(max_run_bytes) and max_run_bytes >= 0 and
              (max_total_bytes == :infinity or
                 (is_integer(max_total_bytes) and max_total_bytes >= 0)),
       do: :ok

  defp valid_capacity?(_, _), do: {:error, :invalid_capacity}

  defp within_capacity?(size, limit) when size <= limit, do: :ok
  defp within_capacity?(_, _), do: {:error, :artifact_capacity_exceeded}

  defp within_total_capacity?(root, size, limit) do
    if stored_bytes(root) + size <= limit, do: :ok, else: {:error, :artifact_capacity_exceeded}
  end

  defp stored_bytes(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&file_size/1)
    |> Enum.sum()
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  defp root(opts) do
    case Keyword.get(opts, :root) || Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :artifact_storage_unavailable}
    end
  end

  defp ensure_run_directory(root, organization_id, version_id, run_id) do
    case File.mkdir_p(run_directory(root, organization_id, version_id, run_id)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :artifact_storage_unavailable}
    end
  end

  defp artifact_path(root, artifact) do
    organization_id = Map.get(artifact, :organization_id)
    version_id = Map.get(artifact, :gtfs_version_id)
    run_id = Map.get(artifact, :run_id)
    key = artifact_key(artifact)

    if valid_scope?(organization_id, version_id, run_id) and safe_filename?(key) do
      {:ok, Path.join(run_directory(root, organization_id, version_id, run_id), key)}
    else
      {:error, :missing_or_corrupt_artifact}
    end
  end

  defp validate_scope(organization_id, version_id, run_id) do
    if valid_scope?(organization_id, version_id, run_id), do: :ok, else: {:error, :invalid_scope}
  end

  defp valid_scope?(organization_id, version_id, run_id) do
    Enum.all?([organization_id, version_id, run_id], &uuid?/1)
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_), do: false

  defp safe_filename?(value) when is_binary(value) do
    Path.basename(value) == value and value not in ["", ".", ".."] and byte_size(value) <= 255
  end

  defp safe_filename?(_), do: false

  defp artifact_key(artifact), do: Map.get(artifact, :key) || Map.get(artifact, :artifact_key)

  defp artifact_size(artifact),
    do: Map.get(artifact, :size) || Map.get(artifact, :artifact_size_bytes)

  defp artifact_digest(artifact),
    do: Map.get(artifact, :sha256) || Map.get(artifact, :artifact_sha256)

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp run_directory(root, organization_id, version_id, run_id) do
    Path.join([root, "export-runs", organization_id, version_id, run_id])
  end

  defp reconcile_organizations(_base, [], _kept, count), do: count

  defp reconcile_organizations(base, [organization | rest], kept, count) do
    count = reconcile_versions(Path.join(base, organization), kept, count)
    reconcile_organizations(base, rest, kept, count)
  end

  defp reconcile_versions(path, kept, count) do
    case File.ls(path) do
      {:ok, versions} ->
        Enum.reduce(versions, count, fn version, acc ->
          reconcile_runs(Path.join(path, version), kept, acc)
        end)

      _ ->
        count
    end
  end

  defp reconcile_runs(path, kept, count) do
    case File.ls(path) do
      {:ok, runs} ->
        Enum.reduce(runs, count, &reconcile_run(path, kept, &1, &2))

      _ ->
        count
    end
  end

  defp reconcile_run(path, kept, run_id, count) do
    if MapSet.member?(kept, run_id), do: count, else: remove_run(path, run_id, count)
  end

  defp remove_run(path, run_id, count) do
    case File.rm_rf(Path.join(path, run_id)) do
      {:ok, _} -> count + 1
      _ -> count
    end
  end
end
