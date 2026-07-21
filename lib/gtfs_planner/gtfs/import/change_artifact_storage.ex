defmodule GtfsPlanner.Gtfs.Import.ChangeArtifactStorage do
  @moduledoc """
  Immutable, run-scoped source staging for station change reviews.

  The filesystem is deliberately not a publication authority. Callers persist
  the returned manifest through `ChangeRuns` only after the final file bytes
  have been read back and verified.
  """

  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.TaskArtifactCapacity

  @max_files 3
  @max_file_bytes 50_000_000
  @max_total_bytes 150 * 1024 * 1024

  @type staged_file :: %{
          required(:name) => String.t(),
          required(:key) => String.t(),
          required(:size) => non_neg_integer(),
          required(:sha256) => String.t()
        }

  @spec stage(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), [map()], keyword()) ::
          {:ok, [staged_file()]} | {:error, term()}
  def stage(organization_id, version_id, run_id, files, opts \\ [])

  def stage(organization_id, version_id, run_id, files, opts) when is_list(files) do
    with :ok <- validate_scope(organization_id, version_id, run_id),
         {:ok, incoming_bytes} <- validate_files(files),
         {:ok, root} <- root(opts) do
      stage_with_capacity(root, incoming_bytes, organization_id, version_id, run_id, files, opts)
    end
  end

  def stage(_, _, _, _, _), do: {:error, :invalid_staged_files}

  defp stage_with_capacity(root, incoming_bytes, organization_id, version_id, run_id, files, opts) do
    TaskArtifactCapacity.within_limit(
      root,
      incoming_bytes,
      configured_max_total_bytes(),
      fn -> stage_validated_files(root, organization_id, version_id, run_id, files, opts) end
    )
  end

  defp stage_validated_files(root, organization_id, version_id, run_id, files, opts) do
    with :ok <- ensure_run_directory(root, organization_id, version_id, run_id) do
      root
      |> stage_files(organization_id, version_id, run_id, files)
      |> finalize_staged_files(organization_id, version_id, run_id, opts)
    end
  end

  defp finalize_staged_files({:ok, staged}, _organization_id, _version_id, _run_id, _opts),
    do: {:ok, Enum.reverse(staged)}

  defp finalize_staged_files({:error, reason}, organization_id, version_id, run_id, opts) do
    _ = remove(organization_id, version_id, run_id, opts)
    {:error, reason}
  end

  @spec read(ChangeRun.t(), keyword()) :: {:ok, [map()]} | {:error, :missing_or_corrupt_artifact}
  def read(%ChangeRun{} = run, opts \\ []) do
    with {:ok, root} <- root(opts),
         files when is_list(files) <- manifest_files(run.source_manifest),
         true <- files != [],
         {:ok, contents} <- read_files(root, run, files) do
      {:ok, contents}
    else
      _ -> {:error, :missing_or_corrupt_artifact}
    end
  end

  @spec remove(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def remove(organization_id, version_id, run_id, opts \\ []) do
    with :ok <- validate_scope(organization_id, version_id, run_id),
         {:ok, root} <- root(opts) do
      case File.rm_rf(run_directory(root, organization_id, version_id, run_id)) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    end
  end

  @doc "Remove directories not owned by an active run."
  @spec reconcile([ChangeRun.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(runs, opts \\ []) when is_list(runs) do
    with {:ok, root} <- root(opts),
         {:ok, entries} <- File.ls(Path.join(root, "change-runs")) do
      active =
        MapSet.new(runs, fn run ->
          Path.join([run.organization_id, run.gtfs_version_id, run.id])
        end)

      grace_seconds = Keyword.get(opts, :orphan_grace_seconds, 0)

      removed =
        reconcile_organizations(Path.join(root, "change-runs"), entries, active, grace_seconds, 0)

      {:ok, removed}
    else
      {:error, :enoent} -> {:ok, 0}
      error -> error
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

  defp validate_scope(organization_id, version_id, run_id) do
    if Enum.all?([organization_id, version_id, run_id], &uuid?/1),
      do: :ok,
      else: {:error, :invalid_scope}
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_), do: false

  defp validate_files(files) do
    cond do
      files == [] or length(files) > @max_files ->
        {:error, :invalid_file_count}

      Enum.any?(files, &(not valid_file?(&1))) ->
        {:error, :invalid_staged_files}

      Enum.sum(Enum.map(files, &byte_size(&1.content))) > configured_max_run_bytes() ->
        {:error, :artifact_capacity_exceeded}

      true ->
        {:ok, Enum.sum(Enum.map(files, &byte_size(&1.content)))}
    end
  end

  defp valid_file?(%{filename: filename, content: content})
       when is_binary(filename) and is_binary(content) do
    byte_size(content) <= @max_file_bytes and safe_filename?(filename)
  end

  defp valid_file?(_), do: false

  defp configured_max_run_bytes do
    Application.get_env(:gtfs_planner, :gtfs_task_artifacts_max_run_bytes, @max_total_bytes)
  end

  defp configured_max_total_bytes do
    Application.get_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes, 1024 * 1024 * 1024)
  end

  defp safe_filename?(filename) do
    basename = Path.basename(filename)
    basename == filename and basename not in ["", ".", ".."] and byte_size(basename) <= 255
  end

  defp stage_file(root, organization_id, version_id, run_id, %{filename: name, content: content}) do
    directory = run_directory(root, organization_id, version_id, run_id)
    key = Ecto.UUID.generate() <> ".source"
    temporary = Path.join(directory, ".#{key}.tmp")
    final = Path.join(directory, key)
    digest = digest(content)

    with :ok <- File.write(temporary, content, [:binary]),
         :ok <- File.rename(temporary, final),
         {:ok, ^content} <- File.read(final),
         {:ok, %{size: size, sha256: ^digest}} <- verify(final) do
      {:ok, %{name: Path.basename(name), key: key, size: size, sha256: digest}}
    else
      _ ->
        _ = File.rm(temporary)
        _ = File.rm(final)
        {:error, :artifact_verification_failed}
    end
  end

  defp stage_files(root, organization_id, version_id, run_id, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, staged} ->
      case stage_file(root, organization_id, version_id, run_id, file) do
        {:ok, manifest} -> {:cont, {:ok, [manifest | staged]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_files(root, run, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      with {:ok, path} <- artifact_path(root, run, file),
           {:ok, content} <- File.read(path),
           true <- byte_size(content) == file_size(file),
           true <- digest(content) == file_digest(file) do
        {:cont, {:ok, [%{filename: file_name(file), content: content} | acc]}}
      else
        _ -> {:halt, {:error, :missing_or_corrupt_artifact}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp artifact_path(root, run, file) do
    key = file_key(file)

    if is_binary(key) and safe_filename?(key) do
      {:ok, Path.join(run_directory(root, run.organization_id, run.gtfs_version_id, run.id), key)}
    else
      {:error, :missing_or_corrupt_artifact}
    end
  end

  defp verify(path) do
    with {:ok, content} <- File.read(path) do
      {:ok, %{size: byte_size(content), sha256: digest(content)}}
    end
  end

  defp manifest_files(manifest), do: Map.get(manifest, :files) || Map.get(manifest, "files")
  defp file_key(file), do: Map.get(file, :key) || Map.get(file, "key")
  defp file_name(file), do: Map.get(file, :name) || Map.get(file, "name")
  defp file_size(file), do: Map.get(file, :size) || Map.get(file, "size")
  defp file_digest(file), do: Map.get(file, :sha256) || Map.get(file, "sha256")
  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp run_directory(root, organization_id, version_id, run_id) do
    Path.join([root, "change-runs", organization_id, version_id, run_id])
  end

  defp reconcile_organizations(_base, [], _active, _grace_seconds, count), do: count

  defp reconcile_organizations(base, [organization | rest], active, grace_seconds, count) do
    organization_path = Path.join(base, organization)

    count = reconcile_organization(organization_path, organization, active, grace_seconds, count)

    reconcile_organizations(base, rest, active, grace_seconds, count)
  end

  defp reconcile_organization(organization_path, organization, active, grace_seconds, count) do
    case File.ls(organization_path) do
      {:ok, versions} ->
        Enum.reduce(versions, count, fn version, acc ->
          reconcile_version(
            Path.join(organization_path, version),
            organization,
            version,
            active,
            grace_seconds,
            acc
          )
        end)

      _ ->
        count
    end
  end

  defp reconcile_version(version_path, organization, version, active, grace_seconds, count) do
    case File.ls(version_path) do
      {:ok, runs} ->
        Enum.reduce(
          runs,
          count,
          &reconcile_run(version_path, organization, version, active, grace_seconds, &1, &2)
        )

      _ ->
        count
    end
  end

  defp reconcile_run(version_path, organization, version, active, grace_seconds, run, count) do
    run_path = Path.join(version_path, run)

    if MapSet.member?(active, Path.join([organization, version, run])) or
         within_orphan_grace?(run_path, grace_seconds) do
      count
    else
      case File.rm_rf(run_path) do
        {:ok, _} -> count + 1
        _ -> count
      end
    end
  end

  defp within_orphan_grace?(_path, grace_seconds) when grace_seconds <= 0, do: false

  defp within_orphan_grace?(path, grace_seconds) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: modified_at}} -> System.os_time(:second) - modified_at < grace_seconds
      _ -> false
    end
  end
end
