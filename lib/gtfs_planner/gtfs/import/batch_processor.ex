defmodule GtfsPlanner.Gtfs.Import.BatchProcessor do
  @moduledoc """
  Generic batch processing logic for GTFS imports.

  Processes large datasets in configurable batch sizes to avoid memory exhaustion
  and atom table limits. All inserts are meant to be wrapped in a single transaction
  for atomicity.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.Stop

  @default_batch_size 1000

  @doc """
  Inserts rows in batches using `Repo.insert_all/3`.

  ## Parameters

    * `repo` - The Ecto repository module
    * `schema` - The Ecto schema module to insert into
    * `rows_stream` - A stream of row maps to process
    * `row_to_attrs_fn` - Function to convert row map to attrs map. Should accept
      (row, organization_id, gtfs_version_id) and return `{:ok, attrs}` or `{:error, reason}`
    * `opts` - Keyword list of options:
      * `:organization_id` (required) - Organization ID to associate records with
      * `:gtfs_version_id` (required) - GTFS version ID to associate records with
      * `:file_name` (required) - Name of file being processed (for error reporting)
      * `:topic` (required) - PubSub topic for progress broadcasts
      * `:batch_size` (optional) - Number of rows per batch (default: #{@default_batch_size})

  ## Returns

    * `{:ok, total_inserted}` - On success, returns count of inserted rows
    * `{:error, reason}` - On failure, returns error details

  ## Notes

  This function does NOT wrap operations in a transaction. The caller must handle
  transaction management to ensure atomicity across multiple batches and files.

  Progress events are broadcast via PubSub as:
  `{:import_progress, %{file: file_name, processed: count, total: total}}`
  """
  def insert_batched(repo, schema, rows_stream, row_to_attrs_fn, opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    gtfs_version_id = Keyword.fetch!(opts, :gtfs_version_id)
    file_name = Keyword.fetch!(opts, :file_name)
    topic = Keyword.fetch!(opts, :topic)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    # Process stream directly in chunks without materializing entire file
    # This reduces memory pressure for large files (e.g., stop_times.txt with millions of rows)
    rows_stream
    |> Stream.chunk_every(batch_size)
    |> Stream.with_index()
    |> Enum.reduce_while({:ok, 0, 0}, fn {chunk, batch_index}, {:ok, acc_count, _} ->
      # Calculate approximate total based on batches processed
      # We don't know total upfront since we're streaming, so we estimate
      processed_so_far = acc_count
      estimated_total = max(processed_so_far + length(chunk), processed_so_far + batch_size)

      case process_batch(
             repo,
             schema,
             chunk,
             row_to_attrs_fn,
             organization_id,
             gtfs_version_id,
             file_name,
             topic,
             acc_count,
             estimated_total
           ) do
        {:ok, batch_count} ->
          {:cont, {:ok, acc_count + batch_count, batch_index + 1}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, total_count, _batch_count} -> {:ok, total_count}
      {:error, _} = error -> error
    end
  end

  @doc """
  Builds a lookup map of stop_id -> UUID for all stops in an organization/version.

  This is used for pathways which reference stops by GTFS string ID but need
  the internal UUID for foreign key relationships.

  ## Parameters

    * `repo` - The Ecto repository module
    * `organization_id` - Organization ID to query stops for
    * `gtfs_version_id` - GTFS version ID to query stops for

  ## Returns

  A map of `%{stop_id_string => uuid}` for all stops in the organization/version.
  """
  def build_stop_lookup_map(repo, organization_id, gtfs_version_id) do
    query =
      from(s in Stop,
        where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
        select: {s.stop_id, s.id}
      )

    query
    |> repo.all()
    |> Map.new()
  end

  # Private Functions

  defp process_batch(
         repo,
         schema,
         chunk,
         row_to_attrs_fn,
         organization_id,
         gtfs_version_id,
         file_name,
         topic,
         processed_count,
         total_rows
       ) do
    # Convert rows to attrs (pass processed_count as batch_start for accurate row indexing)
    case convert_rows_to_attrs(
           chunk,
           row_to_attrs_fn,
           organization_id,
           gtfs_version_id,
           file_name,
           processed_count
         ) do
      {:ok, attrs_list} ->
        # Add timestamps since insert_all doesn't auto-generate them
        now = DateTime.utc_now()

        attrs_with_timestamps =
          Enum.map(attrs_list, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

        # Insert batch
        case insert_batch(repo, schema, attrs_with_timestamps, file_name) do
          {:ok, batch_count} ->
            # Broadcast progress
            new_processed = processed_count + batch_count
            broadcast_progress(topic, file_name, new_processed, total_rows)
            {:ok, batch_count}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_rows_to_attrs(
         rows,
         row_to_attrs_fn,
         organization_id,
         gtfs_version_id,
         file_name,
         batch_start
       ) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case row_to_attrs_fn.(row, organization_id, gtfs_version_id) do
        {:ok, attrs} ->
          {:cont, {:ok, [attrs | acc]}}

        {:error, reason} ->
          # Report global row index: batch_start + index_in_batch + 1 (1-indexed for users)
          {:halt, {:error, %{file: file_name, row: batch_start + index + 1, reason: reason}}}
      end
    end)
    |> case do
      {:ok, attrs_list} -> {:ok, Enum.reverse(attrs_list)}
      {:error, _} = error -> error
    end
  end

  defp insert_batch(repo, schema, attrs_list, file_name) do
    try do
      {count, _} = repo.insert_all(schema, attrs_list, returning: false)
      {:ok, count}
    rescue
      e in Ecto.ConstraintError ->
        {:error, %{file: file_name, constraint: e.constraint, message: Exception.message(e)}}

      e in Postgrex.Error ->
        constraint_name = extract_constraint_name(e)

        {:error,
         %{
           file: file_name,
           postgres_error: e.postgres.code,
           constraint: constraint_name,
           message: Exception.message(e)
         }}

      e ->
        {:error, %{file: file_name, error: Exception.message(e)}}
    end
  end

  defp extract_constraint_name(%Postgrex.Error{postgres: %{constraint: constraint}}),
    do: constraint

  defp extract_constraint_name(_), do: nil

  defp broadcast_progress(topic, file_name, processed, total) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      topic,
      {:import_progress, %{file: file_name, processed: processed, total: total}}
    )
  end
end
