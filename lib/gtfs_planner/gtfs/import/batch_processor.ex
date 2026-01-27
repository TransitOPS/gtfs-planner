defmodule GtfsPlanner.Gtfs.Import.BatchProcessor do
  @moduledoc """
  Generic batch processing logic for GTFS imports.

  Processes large datasets in configurable batch sizes to avoid memory exhaustion
  and atom table limits. All inserts are meant to be wrapped in a single transaction
  for atomicity.
  """

  require Logger
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
    total_rows = Keyword.get(opts, :total_rows, 0)

    # Process stream directly in chunks without materializing entire file
    # This reduces memory pressure for large files (e.g., stop_times.txt with millions of rows)
    rows_stream
    |> Stream.chunk_every(batch_size)
    |> Stream.with_index()
    |> Enum.reduce_while({:ok, 0, 0}, fn {chunk, batch_index}, {:ok, acc_count, _} ->
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
             total_rows
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
  Inserts rows in batches with each batch wrapped in its own transaction.
  
  This variant prevents long-running transactions by committing each batch separately.
  Useful for very large files (e.g., stop_times.txt with millions of rows) where
  a single transaction would timeout or hold connections for too long.

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

  Each batch is committed immediately. If an error occurs mid-import, partial data
  will remain in the database. The caller should handle cleanup if needed.

  Progress events are broadcast via PubSub as:
  `{:import_progress, %{file: file_name, processed: count, total: total}}`
  """
  def insert_batched_with_transactions(repo, schema, rows_stream, row_to_attrs_fn, opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    gtfs_version_id = Keyword.fetch!(opts, :gtfs_version_id)
    file_name = Keyword.fetch!(opts, :file_name)
    topic = Keyword.fetch!(opts, :topic)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    total_rows = Keyword.get(opts, :total_rows, 0)

    # Process stream in chunks, wrapping each batch in its own transaction
    rows_stream
    |> Stream.chunk_every(batch_size)
    |> Stream.with_index()
    |> Enum.reduce_while({:ok, 0, 0}, fn {chunk, batch_index}, {:ok, acc_count, _} ->
      # Wrap this batch in its own transaction
      result =
        repo.transaction(fn ->
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
                 total_rows
               ) do
            {:ok, batch_count} ->
              batch_count

            {:error, reason} ->
              repo.rollback(reason)
          end
        end)

      case result do
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
    batch_number = div(processed_count, length(chunk)) + 1
    
    Logger.debug(
      "Processing batch #{batch_number} for #{file_name}: rows #{processed_count + 1}-#{processed_count + length(chunk)} of #{total_rows}"
    )

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
        case insert_batch(repo, schema, attrs_with_timestamps, file_name, processed_count) do
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

  defp insert_batch(repo, schema, attrs_list, file_name, processed_count) do
    try do
      {count, _} = repo.insert_all(schema, attrs_list, returning: false)
      {:ok, count}
    rescue
      e in Ecto.ConstraintError ->
        error_msg = Exception.message(e)
        
        Logger.error("""
        ===== GTFS Import Error: Constraint Violation =====
        File: #{file_name}
        Schema: #{inspect(schema)}
        Batch starting at row: #{processed_count + 1}
        Constraint: #{e.constraint}
        Error: #{error_msg}
        
        Stacktrace:
        #{Exception.format_stacktrace(__STACKTRACE__)}
        ===================================================
        """)

        {:error, %{file: file_name, constraint: e.constraint, message: error_msg}}

      e in Postgrex.Error ->
        constraint_name = extract_constraint_name(e)
        error_msg = Exception.message(e)
        
        Logger.error("""
        ===== GTFS Import Error: Database Error =====
        File: #{file_name}
        Schema: #{inspect(schema)}
        Batch starting at row: #{processed_count + 1}
        Postgres Error Code: #{e.postgres.code}
        Constraint: #{inspect(constraint_name)}
        Error Message: #{error_msg}
        
        Full Postgres Error:
        #{inspect(e.postgres, pretty: true, limit: :infinity)}
        
        Stacktrace:
        #{Exception.format_stacktrace(__STACKTRACE__)}
        ==============================================
        """)

        {:error,
         %{
           file: file_name,
           postgres_error: e.postgres.code,
           constraint: constraint_name,
           message: error_msg
         }}

      e ->
        error_msg = Exception.message(e)
        
        Logger.error("""
        ===== GTFS Import Error: Unexpected Exception =====
        File: #{file_name}
        Schema: #{inspect(schema)}
        Batch starting at row: #{processed_count + 1}
        Exception Type: #{inspect(e.__struct__)}
        Error Message: #{error_msg}
        
        Full Exception:
        #{inspect(e, pretty: true, limit: :infinity)}
        
        Sample of attrs (first 3 records):
        #{inspect(Enum.take(attrs_list, 3), pretty: true, limit: :infinity)}
        
        Stacktrace:
        #{Exception.format_stacktrace(__STACKTRACE__)}
        ====================================================
        """)

        {:error, %{file: file_name, error: error_msg}}
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