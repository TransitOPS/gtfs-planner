defmodule GtfsPlanner.Gtfs.Import.BatchProcessor do
  @moduledoc """
  Generic batch processing logic for GTFS imports.

  Processes large datasets in configurable batch sizes to avoid memory exhaustion
  and atom table limits. All inserts are meant to be wrapped in a single transaction
  for atomicity.
  """

  @default_batch_size 1000

  alias GtfsPlanner.Gtfs.Import.ParseError

  @doc """
  Inserts rows in batches using `Repo.insert_all/3`.

  ## Parameters

    * `repo` - The Ecto repository module
    * `schema` - The Ecto schema module to insert into
    * `rows_stream` - A stream of `CsvParser.row_event()` values to process
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

    process_events(
      repo,
      schema,
      rows_stream,
      row_to_attrs_fn,
      organization_id,
      gtfs_version_id,
      file_name,
      topic,
      batch_size,
      total_rows,
      false
    )
  end

  @doc """
  Inserts rows in batches with each batch wrapped in its own transaction.

  This variant prevents long-running transactions by committing each batch separately.
  Useful for very large files (e.g., stop_times.txt with millions of rows) where
  a single transaction would timeout or hold connections for too long.

  ## Parameters

    * `repo` - The Ecto repository module
    * `schema` - The Ecto schema module to insert into
    * `rows_stream` - A stream of `CsvParser.row_event()` values to process
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

    process_events(
      repo,
      schema,
      rows_stream,
      row_to_attrs_fn,
      organization_id,
      gtfs_version_id,
      file_name,
      topic,
      batch_size,
      total_rows,
      true
    )
  end

  # Private Functions

  defp process_events(
         repo,
         schema,
         rows_stream,
         row_to_attrs_fn,
         organization_id,
         gtfs_version_id,
         file_name,
         topic,
         batch_size,
         total_rows,
         transactional?
       ) do
    rows_stream
    |> Enum.reduce_while({:ok, 0, [], 0}, fn event, {:ok, inserted, attrs, attrs_count} ->
      case convert_event(event, row_to_attrs_fn, organization_id, gtfs_version_id, file_name) do
        {:ok, attr} when attrs_count + 1 == batch_size ->
          case flush_batch(
                 repo,
                 schema,
                 Enum.reverse([attr | attrs]),
                 file_name,
                 topic,
                 inserted,
                 total_rows,
                 transactional?
               ) do
            {:ok, batch_count} -> {:cont, {:ok, inserted + batch_count, [], 0}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, attr} ->
          {:cont, {:ok, inserted, [attr | attrs], attrs_count + 1}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, inserted, [], 0} ->
        {:ok, inserted}

      {:ok, inserted, attrs, _attrs_count} ->
        case flush_batch(
               repo,
               schema,
               Enum.reverse(attrs),
               file_name,
               topic,
               inserted,
               total_rows,
               transactional?
             ) do
          {:ok, batch_count} -> {:ok, inserted + batch_count}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_event(
         {:ok, row_number, row_map},
         row_to_attrs_fn,
         organization_id,
         gtfs_version_id,
         file_name
       ) do
    case row_to_attrs_fn.(row_map, organization_id, gtfs_version_id) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, reason} -> {:error, %{file: file_name, row: row_number, reason: reason}}
    end
  end

  defp convert_event(
         {:error, %ParseError{} = parse_error},
         _row_to_attrs_fn,
         _organization_id,
         _gtfs_version_id,
         _file_name
       ),
       do: {:error, parse_error}

  defp flush_batch(
         repo,
         schema,
         attrs,
         file_name,
         topic,
         processed_count,
         total_rows,
         transactional?
       ) do
    insert = fn -> insert_converted_batch(repo, schema, attrs, file_name) end

    result =
      if transactional? do
        repo.transaction(fn ->
          case insert.() do
            {:ok, batch_count} -> batch_count
            {:error, reason} -> repo.rollback(reason)
          end
        end)
      else
        insert.()
      end

    case result do
      {:ok, batch_count} when transactional? ->
        broadcast_progress(topic, file_name, processed_count + batch_count, total_rows)
        {:ok, batch_count}

      {:ok, batch_count} ->
        broadcast_progress(topic, file_name, processed_count + batch_count, total_rows)
        {:ok, batch_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_converted_batch(repo, schema, attrs, file_name) do
    now = DateTime.utc_now()
    attrs = Enum.map(attrs, &Map.merge(&1, %{inserted_at: now, updated_at: now}))
    insert_batch(repo, schema, attrs, file_name)
  end

  defp insert_batch(repo, schema, attrs_list, file_name) do
    try do
      {count, _} = repo.insert_all(schema, attrs_list, returning: false)
      {:ok, count}
    rescue
      e in Ecto.ConstraintError ->
        error_msg = Exception.message(e)

        {:error, %{file: file_name, constraint: e.constraint, message: error_msg}}

      e in Postgrex.Error ->
        constraint_name = extract_constraint_name(e)
        error_msg = Exception.message(e)

        {:error,
         %{
           file: file_name,
           postgres_error: e.postgres.code,
           constraint: constraint_name,
           message: error_msg
         }}

      e ->
        error_msg = Exception.message(e)

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
