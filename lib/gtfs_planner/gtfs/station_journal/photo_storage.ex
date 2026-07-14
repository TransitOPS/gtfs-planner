defmodule GtfsPlanner.Gtfs.StationJournal.PhotoStorage do
  @moduledoc false

  import Kernel, except: [inspect: 1]

  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.StationJournal.Scope

  @max_bytes 25 * 1024 * 1024
  @chunk_size 64 * 1024
  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @png_end <<0, 0, 0, 0, "IEND", 174, 66, 96, 130>>

  @type inspected :: %{
          path: String.t(),
          final_path: String.t(),
          filename: String.t(),
          content_type: String.t(),
          byte_size: pos_integer(),
          sha256: binary(),
          lock: term()
        }

  @spec stage(Scope.t(), Ecto.UUID.t(), %{path: String.t()}) ::
          {:ok, inspected()} | {:error, atom()}
  def stage(%Scope{} = scope, photo_id, %{path: source_path}) when is_binary(source_path) do
    with {:ok, base_path, id} <- final_path(scope, photo_id),
         :ok <- ensure_directory(Path.dirname(base_path)) do
      lock = acquire_lock(scope, id)
      cleanup_stale_path(base_path)

      case stage_file(source_path, base_path, photo_id, id) do
        {:ok, staged} ->
          {:ok, Map.put(staged, :lock, lock)}

        {:error, reason} ->
          cleanup_stale_path(base_path)
          release_lock(lock)
          {:error, reason}
      end
    end
  end

  def stage(_scope, _photo_id, _upload), do: {:error, :invalid_upload}

  @spec discard(inspected()) :: :ok
  def discard(%{path: path} = staged) do
    try do
      _ = File.rm(path)
      :ok
    after
      release_lock(staged.lock)
    end
  end

  @spec finalize(inspected()) :: :ok | {:error, term()}
  def finalize(%{path: path, final_path: final_path} = staged) do
    try do
      case File.rename(path, final_path) do
        :ok -> :ok
        {:error, _reason} -> {:error, :rename_failed}
      end
    after
      release_lock(staged.lock)
    end
  end

  @spec final_matches?(inspected()) :: boolean()
  def final_matches?(%{final_path: path} = staged) do
    case inspect(path) do
      {:ok, current} ->
        current.sha256 == staged.sha256 and current.content_type == staged.content_type

      {:error, _reason} ->
        false
    end
  end

  @spec canonical_conflict?(inspected()) :: boolean()
  def canonical_conflict?(%{final_path: final_path} = staged) do
    base_path = Path.rootname(final_path)

    Enum.any?([".jpg", ".png"], fn extension ->
      candidate = base_path <> extension
      File.exists?(candidate) and (candidate != final_path or not final_matches?(staged))
    end)
  end

  @spec inspect(String.t()) ::
          {:ok, %{content_type: String.t(), byte_size: pos_integer(), sha256: binary()}}
          | {:error, atom()}
  def inspect(path) when is_binary(path), do: inspect_file(path)

  @spec public_path(Scope.t(), %{filename: String.t()}) :: String.t()
  def public_path(%Scope{} = scope, %{filename: filename}) do
    station_dir = PathSafety.stop_storage_dir(scope.station_stop_id)
    "/uploads/field-captures/#{scope.organization_id}/#{station_dir}/#{filename}"
  end

  defp final_path(%Scope{} = scope, photo_id) do
    with true <- PathSafety.safe_path_component?(scope.organization_id),
         station_dir when is_binary(station_dir) <-
           PathSafety.stop_storage_dir(scope.station_stop_id),
         true <- PathSafety.safe_path_component?(station_dir),
         {:ok, id} <- Ecto.UUID.cast(photo_id) do
      root = Application.fetch_env!(:gtfs_planner, :uploads_path)
      field_root = Path.join(root, "field-captures")
      path = Path.join([field_root, scope.organization_id, station_dir, id])

      if PathSafety.ensure_within_root(field_root, path) == :ok,
        do: {:ok, path, id},
        else: {:error, :unsafe_path}
    else
      _ -> {:error, :unsafe_path}
    end
  end

  defp temporary_path(final_path, photo_id) do
    temp = final_path <> ".#{photo_id}.#{System.unique_integer([:positive])}.tmp"

    if PathSafety.ensure_within_root(Path.dirname(final_path), temp) == :ok,
      do: {:ok, temp},
      else: {:error, :unsafe_path}
  end

  defp ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :storage_error}
    end
  end

  defp stage_file(source_path, base_path, photo_id, id) do
    with {:ok, staged_path} <- temporary_path(base_path, photo_id),
         {:ok, result} <- copy_and_inspect(source_path, staged_path) do
      filename = id <> result.extension

      {:ok,
       Map.merge(result, %{
         path: staged_path,
         final_path: base_path <> result.extension,
         filename: filename
       })}
    end
  end

  defp acquire_lock(scope, photo_id) do
    lock = {{__MODULE__, scope.organization_id, scope.station_id, photo_id}, self()}
    true = :global.set_lock(lock)
    lock
  end

  defp release_lock(lock) do
    :global.del_lock(lock)
    :ok
  end

  defp cleanup_stale_path(base_path) do
    id = Path.basename(base_path)
    pattern = Path.join(Path.dirname(base_path), "#{id}.*.tmp")

    Enum.each(Path.wildcard(pattern), fn path ->
      _ = File.rm(path)
    end)

    :ok
  end

  defp copy_and_inspect(source, staged) do
    case File.open(source, [:read, :binary]) do
      {:ok, input} ->
        case File.open(staged, [:write, :binary]) do
          {:ok, output} ->
            result = copy_chunks(input, output, :crypto.hash_init(:sha256), 0, <<>>, <<>>)
            File.close(output)
            File.close(input)

            case result do
              {:ok, inspected} ->
                case detected_type(inspected.prefix, inspected.tail) do
                  {:ok, content_type, extension} ->
                    {:ok,
                     Map.put(inspected, :content_type, content_type)
                     |> Map.put(:extension, extension)}

                  :error ->
                    File.rm(staged)
                    {:error, :invalid_image}
                end

              {:error, reason} ->
                File.rm(staged)
                {:error, reason}
            end

          {:error, _reason} ->
            File.close(input)
            {:error, :storage_error}
        end

      {:error, _reason} ->
        {:error, :invalid_upload}
    end
  end

  defp copy_chunks(input, output, hash, size, prefix, tail) do
    case IO.binread(input, @chunk_size) do
      :eof when size == 0 ->
        {:error, :empty_file}

      :eof ->
        {:ok, %{byte_size: size, sha256: :crypto.hash_final(hash), prefix: prefix, tail: tail}}

      {:error, _reason} ->
        {:error, :invalid_upload}

      chunk when is_binary(chunk) ->
        next_size = size + byte_size(chunk)

        if next_size > @max_bytes do
          {:error, :payload_too_large}
        else
          :ok = IO.binwrite(output, chunk)

          copy_chunks(
            input,
            output,
            :crypto.hash_update(hash, chunk),
            next_size,
            take_prefix(prefix, chunk),
            take_tail(tail, chunk)
          )
        end
    end
  end

  defp inspect_file(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, input} ->
        result = inspect_chunks(input, :crypto.hash_init(:sha256), 0, <<>>, <<>>)
        File.close(input)
        result

      {:error, _reason} ->
        {:error, :missing_file}
    end
  end

  defp inspect_chunks(input, hash, size, prefix, tail) do
    case IO.binread(input, @chunk_size) do
      :eof when size == 0 ->
        {:error, :empty_file}

      :eof ->
        case detected_type(prefix, tail) do
          {:ok, content_type, _extension} ->
            {:ok,
             %{content_type: content_type, byte_size: size, sha256: :crypto.hash_final(hash)}}

          :error ->
            {:error, :invalid_image}
        end

      chunk when is_binary(chunk) ->
        inspect_chunks(
          input,
          :crypto.hash_update(hash, chunk),
          size + byte_size(chunk),
          take_prefix(prefix, chunk),
          take_tail(tail, chunk)
        )

      {:error, _reason} ->
        {:error, :invalid_upload}
    end
  end

  defp detected_type(<<0xFF, 0xD8, _::binary>>, tail)
       when byte_size(tail) >= 2 and binary_part(tail, byte_size(tail) - 2, 2) == <<0xFF, 0xD9>>,
       do: {:ok, "image/jpeg", ".jpg"}

  defp detected_type(@png_signature <> _rest, tail)
       when byte_size(tail) >= byte_size(@png_end) and
              binary_part(tail, byte_size(tail) - byte_size(@png_end), byte_size(@png_end)) ==
                @png_end,
       do: {:ok, "image/png", ".png"}

  defp detected_type(_prefix, _tail), do: :error

  defp take_prefix(prefix, chunk),
    do: binary_part(prefix <> chunk, 0, min(8, byte_size(prefix <> chunk)))

  defp take_tail(tail, chunk) do
    combined = tail <> chunk
    binary_part(combined, max(byte_size(combined) - 12, 0), min(12, byte_size(combined)))
  end
end
