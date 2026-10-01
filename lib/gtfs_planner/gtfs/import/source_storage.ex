defmodule GtfsPlanner.Gtfs.Import.SourceStorage do
  @moduledoc """
  Private, run-scoped storage for the uploaded source files of a full import.

  Uploads are copied into `<root>/import-runs/<organization_id>/<run_id>/source/`
  without reading a whole file into memory, so workers receive descriptors
  (`filename`, `path`, `size`, `sha256`) instead of file contents. The run
  directory also holds anything derived from the sources, such as an expanded
  ZIP, so `remove/3` and `reconcile/2` release a run's files as one unit.

  The filesystem is not a publication authority; `ImportRuns` rows decide which
  runs are active, and `reconcile/2` takes that set from the caller.

  Capacity: a `stage/4` call is bounded by `ImportLive`'s upload limits (50 files,
  200,000,000 bytes each), by `:max_run_bytes` (default
  `:gtfs_task_artifacts_max_run_bytes`) for the call's total, and by
  `:max_total_bytes` (default `:gtfs_task_artifacts_max_total_bytes`) for the
  artifact root as a whole.
  """

  alias GtfsPlanner.Gtfs.TaskArtifactCapacity

  @max_files 50
  @max_file_bytes 200_000_000
  @chunk_bytes 64 * 1024
  @default_max_run_bytes 150 * 1024 * 1024
  @default_max_total_bytes 1024 * 1024 * 1024
  @default_orphan_grace_seconds 300

  @type upload :: %{required(:path) => Path.t(), required(:filename) => String.t()}

  @type staged_file :: %{
          required(:filename) => String.t(),
          required(:path) => Path.t(),
          required(:size) => non_neg_integer(),
          required(:sha256) => String.t()
        }

  @doc """
  Copies `uploads` into the run's source directory and returns one descriptor per
  upload, in input order.

  All uploads are validated before anything is written. A failure after writing
  starts removes the run directory, so no partial file remains. Each staged file
  is stored under a generated name; `filename` is the validated client name and
  may repeat across uploads.
  """
  @spec stage(Ecto.UUID.t(), Ecto.UUID.t(), [upload()], keyword()) ::
          {:ok, [staged_file()]}
          | {:error,
             :invalid_scope
             | :invalid_file
             | :artifact_capacity_exceeded
             | :artifact_storage_unavailable
             | File.posix()}
  def stage(organization_id, run_id, uploads, opts \\ [])

  def stage(organization_id, run_id, uploads, opts) when is_list(uploads) do
    with {:ok, organization_id, run_id} <- scope(organization_id, run_id),
         {:ok, root} <- root(opts),
         {:ok, sizes} <- measure(uploads),
         incoming_bytes = Enum.sum(sizes),
         :ok <- within_run_limit(incoming_bytes, opts) do
      TaskArtifactCapacity.within_limit(root, incoming_bytes, max_total_bytes(opts), fn ->
        run_directory = run_directory(root, organization_id, run_id)
        stage_into(run_directory, Enum.zip(uploads, sizes))
      end)
    end
  end

  def stage(_organization_id, _run_id, _uploads, _opts), do: {:error, :invalid_file}

  @doc "Returns the run's private directory, which holds `source/` and anything derived from it."
  @spec run_dir(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Path.t()} | {:error, :invalid_scope | :artifact_storage_unavailable}
  def run_dir(organization_id, run_id, opts \\ []) do
    with {:ok, organization_id, run_id} <- scope(organization_id, run_id),
         {:ok, root} <- root(opts) do
      {:ok, run_directory(root, organization_id, run_id)}
    end
  end

  @doc "Deletes the run's directory and nothing else. Succeeds when it is already absent."
  @spec remove(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def remove(organization_id, run_id, opts \\ []) do
    with {:ok, directory} <- run_dir(organization_id, run_id, opts) do
      case File.rm_rf(directory) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  @doc """
  Removes run directories whose id is not in `active_run_ids` and whose directory
  is older than the orphan grace, and returns how many were removed.

  The grace (`:orphan_grace_seconds`, default
  `:gtfs_task_artifacts_orphan_grace_seconds` or 300) protects a directory created
  after the caller read the active set.
  """
  @spec reconcile([Ecto.UUID.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(active_run_ids, opts \\ []) when is_list(active_run_ids) do
    with {:ok, root} <- root(opts) do
      base = Path.join(root, "import-runs")
      active = MapSet.new(active_run_ids)
      grace_seconds = Keyword.get_lazy(opts, :orphan_grace_seconds, &orphan_grace_seconds/0)

      case File.ls(base) do
        {:ok, organizations} ->
          {:ok,
           Enum.reduce(organizations, 0, fn organization, count ->
             reconcile_organization(Path.join(base, organization), active, grace_seconds, count)
           end)}

        {:error, :enoent} ->
          {:ok, 0}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp stage_into(run_directory, uploads) do
    source_directory = Path.join(run_directory, "source")

    result =
      case File.mkdir_p(source_directory) do
        :ok -> copy_all(source_directory, uploads, [])
        {:error, _reason} -> {:error, :artifact_storage_unavailable}
      end

    with {:error, _reason} <- result do
      _ = File.rm_rf(run_directory)
      result
    end
  end

  defp copy_all(_directory, [], staged), do: {:ok, Enum.reverse(staged)}

  defp copy_all(directory, [{upload, size} | rest], staged) do
    with {:ok, file} <- copy_one(directory, upload, size) do
      copy_all(directory, rest, [file | staged])
    end
  end

  defp copy_one(directory, %{path: source, filename: filename}, size) do
    key = Ecto.UUID.generate() <> ".source"
    temporary = Path.join(directory, ".#{key}.tmp")
    final = Path.join(directory, key)

    # The copy stops one byte past the measured size, so a source that grew after
    # measurement is detected without writing beyond the budget that was checked.
    # The recorded checksum comes from the private copy, not the upload.
    with {:ok, ^size} <- File.copy(source, temporary, size + 1),
         {:ok, ^size, sha256} <- hash_file(temporary),
         :ok <- File.rename(temporary, final) do
      {:ok, %{filename: filename, path: final, size: size, sha256: sha256}}
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}

      _source_changed ->
        _ = File.rm(temporary)
        {:error, :invalid_file}
    end
  end

  defp hash_file(path) do
    with {:ok, device} <- File.open(path, [:read, :binary]) do
      try do
        hash_chunks(device, :crypto.hash_init(:sha256), 0)
      after
        File.close(device)
      end
    end
  end

  defp hash_chunks(device, state, size) do
    case IO.binread(device, @chunk_bytes) do
      data when is_binary(data) ->
        hash_chunks(device, :crypto.hash_update(state, data), size + byte_size(data))

      :eof ->
        {:ok, size, state |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp measure(uploads) when uploads == [] or length(uploads) > @max_files,
    do: {:error, :invalid_file}

  defp measure(uploads) do
    results = Enum.map(uploads, &upload_size/1)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, size} -> size end)}
      error -> error
    end
  end

  defp upload_size(%{path: path, filename: filename})
       when is_binary(path) and is_binary(filename) do
    with true <- safe_filename?(filename),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path) do
      if size <= @max_file_bytes, do: {:ok, size}, else: {:error, :artifact_capacity_exceeded}
    else
      _invalid -> {:error, :invalid_file}
    end
  end

  defp upload_size(_upload), do: {:error, :invalid_file}

  defp safe_filename?(filename) do
    String.valid?(filename) and not String.contains?(filename, <<0>>) and
      Path.basename(filename) == filename and filename not in ["", ".", ".."] and
      byte_size(filename) <= 255
  end

  defp within_run_limit(incoming_bytes, opts) do
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

    if incoming_bytes <= max_run_bytes, do: :ok, else: {:error, :artifact_capacity_exceeded}
  end

  defp max_total_bytes(opts) do
    Keyword.get(
      opts,
      :max_total_bytes,
      Application.get_env(
        :gtfs_planner,
        :gtfs_task_artifacts_max_total_bytes,
        @default_max_total_bytes
      )
    )
  end

  defp orphan_grace_seconds do
    Application.get_env(
      :gtfs_planner,
      :gtfs_task_artifacts_orphan_grace_seconds,
      @default_orphan_grace_seconds
    )
  end

  defp root(opts) do
    case Keyword.get(opts, :root) || Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :artifact_storage_unavailable}
    end
  end

  # Casting normalizes the ids, so directory names match the ids stored on run rows.
  defp scope(organization_id, run_id) do
    with {:ok, organization_id} <- Ecto.UUID.cast(organization_id),
         {:ok, run_id} <- Ecto.UUID.cast(run_id) do
      {:ok, organization_id, run_id}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  defp run_directory(root, organization_id, run_id) do
    Path.join([root, "import-runs", organization_id, run_id])
  end

  defp reconcile_organization(organization_path, active, grace_seconds, count) do
    case File.ls(organization_path) do
      {:ok, runs} ->
        Enum.reduce(runs, count, fn run, count ->
          reconcile_run(Path.join(organization_path, run), run, active, grace_seconds, count)
        end)

      {:error, _reason} ->
        count
    end
  end

  defp reconcile_run(run_path, run, active, grace_seconds, count) do
    if MapSet.member?(active, run) or within_orphan_grace?(run_path, grace_seconds) do
      count
    else
      case File.rm_rf(run_path) do
        {:ok, _removed} -> count + 1
        {:error, _reason, _path} -> count
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
