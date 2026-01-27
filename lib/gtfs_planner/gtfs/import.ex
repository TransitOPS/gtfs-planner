defmodule GtfsPlanner.Gtfs.Import do
  @moduledoc """
  Context module for importing GTFS data files.

  Handles parsing and importing GTFS data from uploaded CSV files including:
  - `routes.txt` - Transit routes
  - `calendar.txt` - Service periods
  - `calendar_dates.txt` - Service exceptions
  - `route_patterns.txt` - Route patterns (MBTA extension)
  - `trips.txt` - Trips
  - `levels.txt` - Level/floor definitions for stations
  - `stops.txt` - Stop/station locations and metadata
  - `stop_times.txt` - Stop times for trips
  - `pathways.txt` - Pathways connecting stops within stations

  All imports are executed within a single database transaction to ensure
  data consistency. Files are processed in dependency order to satisfy
  foreign key constraints.

  Uses batch processing to avoid Erlang atom table exhaustion and memory
  issues with large files.

  ## Usage

      files = [
        %{filename: "routes.txt", content: binary_content},
        %{filename: "stops.txt", content: binary_content},
        %{filename: "pathways.txt", content: binary_content}
      ]

      case Import.import_files(org_id, version_id, files) do
        {:ok, {counts, unrecognized, topic}} ->
          # Import successful, topic can be used to subscribe to progress
        {:error, reason} ->
          # Import failed, transaction rolled back
      end
  """

  alias GtfsPlanner.{Repo, Gtfs}
  alias GtfsPlanner.Gtfs.Import.{BatchProcessor, RowParser}

  @batch_size Application.compile_env(:gtfs_planner, :import_batch_size, 1000)

  @doc """
  Imports GTFS data files with optimized transaction handling.

  Small files are processed in a single transaction for atomicity.
  Large files (stop_times) are processed separately with batch-level
  transactions to prevent long-running transactions and connection timeouts.

  Progress is broadcast via PubSub on the returned topic for LiveView consumption.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version to associate records with
    - `files` - List of `%{filename: string, content: binary}` maps
    - `topic` - (optional) PubSub topic for progress updates. If not provided, one will be generated.

  ## Returns

    - `{:ok, {counts, unrecognized_files, topic}}` on success
      - `counts` - map with keys for each file type containing import counts
      - `unrecognized_files` - list of unrecognized filenames
      - `topic` - PubSub topic for progress updates
    - `{:error, reason}` on failure

  ## Examples

      iex> files = [%{filename: "routes.txt", content: "route_id,route_type\\nR1,3"}]
      iex> import_files(org_id, version_id, files)
      {:ok, {%{routes: 1, stops: 0, ...}, [], "import:123456"}}
  """
  def import_files(organization_id, gtfs_version_id, files, topic \\ nil) do
    # Categorize files by filename (case-insensitive)
    {categorized, unrecognized_files} = categorize_files(files)

    # Generate unique progress topic for PubSub if not provided
    topic = topic || "import:#{:erlang.unique_integer()}"

    # Phase 1: Import all files EXCEPT stop_times in a single transaction
    # This maintains atomicity for the core data (routes, stops, trips, etc.)
    result =
      Repo.transaction(fn ->
        counts = %{}

        # Process routes
        counts =
          case process_file_category(
                 categorized[:routes] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :routes,
                 Gtfs.Route,
                 &RowParser.route_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :routes, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # Process calendars
        counts =
          case process_file_category(
                 categorized[:calendars] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :calendars,
                 Gtfs.Calendar,
                 &RowParser.calendar_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :calendars, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # Process calendar_dates
        counts =
          case process_file_category(
                 categorized[:calendar_dates] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :calendar_dates,
                 Gtfs.CalendarDate,
                 &RowParser.calendar_date_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :calendar_dates, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # Process route_patterns
        counts =
          case process_file_category(
                 categorized[:route_patterns] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :route_patterns,
                 Gtfs.RoutePattern,
                 &RowParser.route_pattern_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :route_patterns, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # Process trips
        counts =
          case process_file_category(
                 categorized[:trips] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :trips,
                 Gtfs.Trip,
                 &RowParser.trip_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :trips, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # Process levels
        counts =
          case process_file_category(
                 categorized[:levels] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :levels,
                 Gtfs.Level,
                 &RowParser.level_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :levels, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # Process stops
        counts =
          case process_file_category(
                 categorized[:stops] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :stops,
                 Gtfs.Stop,
                 &RowParser.stop_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :stops, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # NOTE: stop_times are NOT processed here - they're handled separately below

        # Process pathways
        counts =
          case process_file_category(
                 categorized[:pathways] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :pathways,
                 Gtfs.Pathway,
                 &RowParser.pathway_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :pathways, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        counts
      end)

    # Check if Phase 1 succeeded
    case result do
      {:ok, counts} ->
        # Phase 2: Process stop_times separately with batch-level transactions
        # This prevents long-running transactions that can timeout
        case process_stop_times_batched(
               categorized[:stop_times] || [],
               organization_id,
               gtfs_version_id,
               topic
             ) do
          {:ok, stop_times_count} ->
            # Merge stop_times count with other counts
            counts = Map.put(counts, :stop_times, stop_times_count)

            # Fill in zeros for any file types not imported
            counts =
              [
                :agencies,
                :areas,
                :attributions,
                :booking_rules,
                :calendars,
                :calendar_dates,
                :fare_attributes,
                :fare_leg_join_rules,
                :fare_leg_rules,
                :fare_media,
                :fare_products,
                :fare_rules,
                :fare_transfer_rules,
                :feed_info,
                :frequencies,
                :levels,
                :locations,
                :networks,
                :pathways,
                :rider_categories,
                :route_networks,
                :route_patterns,
                :routes,
                :shapes,
                :stop_areas,
                :stop_times,
                :stops,
                :timeframes,
                :transfers,
                :translations,
                :trips
              ]
              |> Enum.reduce(counts, fn key, acc -> Map.put_new(acc, key, 0) end)

            {:ok, {counts, unrecognized_files, topic}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Processes stop_times files with batch-level transactions
  # Each batch gets its own transaction to prevent long-running transactions
  defp process_stop_times_batched(files, organization_id, gtfs_version_id, topic) do
    total_count =
      Enum.reduce_while(files, 0, fn file, acc ->
        {rows_stream, total_rows} = parse_csv_content_with_count(file.content)

        case BatchProcessor.insert_batched_with_transactions(
               Repo,
               Gtfs.StopTime,
               rows_stream,
               &RowParser.stop_time_row_to_attrs/3,
               organization_id: organization_id,
               gtfs_version_id: gtfs_version_id,
               file_name: file.filename,
               topic: topic,
               batch_size: @batch_size,
               total_rows: total_rows
             ) do
          {:ok, count} ->
            {:cont, acc + count}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case total_count do
      {:error, _} = error -> error
      count -> {:ok, count}
    end
  end

  # Processes a category of files using batch insertion
  defp process_file_category(
         files,
         organization_id,
         gtfs_version_id,
         topic,
         _file_type,
         schema,
         row_to_attrs_fn
       ) do
    total_count =
      Enum.reduce_while(files, 0, fn file, acc ->
        {rows_stream, total_rows} = parse_csv_content_with_count(file.content)

        case BatchProcessor.insert_batched(
               Repo,
               schema,
               rows_stream,
               row_to_attrs_fn,
               organization_id: organization_id,
               gtfs_version_id: gtfs_version_id,
               file_name: file.filename,
               topic: topic,
               batch_size: @batch_size,
               total_rows: total_rows
             ) do
          {:ok, count} ->
            {:cont, acc + count}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case total_count do
      {:error, _} = error -> error
      count -> {:ok, count}
    end
  end

  # Categorizes files by filename into file type buckets
  defp categorize_files(files) do
    initial_acc =
      {%{
         routes: [],
         route_patterns: [],
         calendars: [],
         calendar_dates: [],
         trips: [],
         levels: [],
         stops: [],
         stop_times: [],
         pathways: []
       }, []}

    {categorized, unrecognized} =
      Enum.reduce(files, initial_acc, fn file, {acc, unrecognized_acc} ->
        case String.downcase(file.filename) do
          "routes.txt" ->
            {Map.update!(acc, :routes, &[file | &1]), unrecognized_acc}

          "route_patterns.txt" ->
            {Map.update!(acc, :route_patterns, &[file | &1]), unrecognized_acc}

          "calendar.txt" ->
            {Map.update!(acc, :calendars, &[file | &1]), unrecognized_acc}

          "calendar_dates.txt" ->
            {Map.update!(acc, :calendar_dates, &[file | &1]), unrecognized_acc}

          "trips.txt" ->
            {Map.update!(acc, :trips, &[file | &1]), unrecognized_acc}

          "levels.txt" ->
            {Map.update!(acc, :levels, &[file | &1]), unrecognized_acc}

          "stops.txt" ->
            {Map.update!(acc, :stops, &[file | &1]), unrecognized_acc}

          "stop_times.txt" ->
            {Map.update!(acc, :stop_times, &[file | &1]), unrecognized_acc}

          "pathways.txt" ->
            {Map.update!(acc, :pathways, &[file | &1]), unrecognized_acc}

          _ ->
            {acc, [file.filename | unrecognized_acc]}
        end
      end)

    categorized =
      Map.new(categorized, fn {key, files_list} -> {key, Enum.reverse(files_list)} end)

    {categorized, Enum.reverse(unrecognized)}
  end

  @doc """
  Parses CSV content into a stream of row maps with total row count.

  Takes binary CSV content with a header row and returns a tuple with the stream
  and the total number of data rows (excluding header).

  ## Parameters

    - `content` - Binary string containing CSV data with header row

  ## Returns

  `{stream, total_rows}` - Tuple with stream of row maps and total count

  ## Examples

      iex> content = "level_id,level_name\\nL1,Ground Floor\\nL2,Platform"
      iex> {stream, total} = parse_csv_content_with_count(content)
      iex> {Enum.to_list(stream), total}
      {[%{"level_id" => "L1", ...}], 2}
  """
  def parse_csv_content_with_count(content) when is_binary(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))

    # Count total data rows (subtract 1 for header)
    total_rows = max(length(lines) - 1, 0)

    # Create stream from lines
    stream =
      lines
      |> Stream.transform({:no_header, nil}, fn
        line, {:no_header, nil} ->
          # First line is header
          case parse_csv_line(line) do
            {:ok, header} ->
              {[], {:has_header, header}}

            {:error, _reason} ->
              {[], {:has_header, []}}
          end

        _line, {:has_header, header} when header == [] ->
          # No valid header, skip all rows
          {[], {:has_header, []}}

        line, {:has_header, header} ->
          case parse_csv_line(line) do
            {:ok, fields} when length(fields) == length(header) ->
              row_map = Enum.zip(header, fields) |> Map.new()
              {[row_map], {:has_header, header}}

            {:ok, _fields} ->
              # Skip malformed lines silently
              {[], {:has_header, header}}

            {:error, _reason} ->
              # Skip malformed lines silently
              {[], {:has_header, header}}
          end
      end)
      |> Stream.filter(fn
        row_map when is_map(row_map) -> true
        _ -> false
      end)

    {stream, total_rows}
  end

  @doc """
  Parses CSV content into a stream of row maps.

  Takes binary CSV content with a header row and returns a stream where each
  element is a map with header names as keys and row values as values.

  Handles GTFS CSV format including:
  - Quoted fields with embedded commas
  - Escaped quotes (double quotes within quoted fields)
  - Empty fields

  ## Parameters

    - `content` - Binary string containing CSV data with header row

  ## Returns

  Stream of maps where keys are header field names and values are field values.

  ## Examples

      iex> content = "level_id,level_name\\nL1,Ground Floor\\nL2,Platform"
      iex> parse_csv_content(content) |> Enum.to_list()
      [
        %{"level_id" => "L1", "level_name" => "Ground Floor"},
        %{"level_id" => "L2", "level_name" => "Platform"}
      ]
  """
  def parse_csv_content(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Stream.map(&String.trim/1)
    |> Stream.filter(&(&1 != ""))
    |> Stream.transform({:no_header, nil}, fn
      line, {:no_header, nil} ->
        # First line is header
        case parse_csv_line(line) do
          {:ok, header} ->
            {[], {:has_header, header}}

          {:error, _reason} ->
            {[], {:has_header, []}}
        end

      _line, {:has_header, header} when header == [] ->
        # No valid header, skip all rows
        {[], {:has_header, []}}

      line, {:has_header, header} ->
        case parse_csv_line(line) do
          {:ok, fields} when length(fields) == length(header) ->
            row_map = Enum.zip(header, fields) |> Map.new()
            {[row_map], {:has_header, header}}

          {:ok, _fields} ->
            # Skip malformed lines silently
            {[], {:has_header, header}}

          {:error, _reason} ->
            # Skip malformed lines silently
            {[], {:has_header, header}}
        end
    end)
    |> Stream.filter(fn
      row_map when is_map(row_map) -> true
      _ -> false
    end)
  end

  @doc """
  Parses a single CSV line into a list of field values.

  Handles quoted fields and escaped quotes per GTFS specification.

  ## Parameters

    - `line` - String containing a single CSV line

  ## Returns

    - `{:ok, fields}` - List of field values
    - `{:error, reason}` - Parse error

  ## Examples

      iex> parse_csv_line("value1,value2,value3")
      {:ok, ["value1", "value2", "value3"]}

      iex> parse_csv_line(~s(value1,"quoted,value",value3))
      {:ok, ["value1", "quoted,value", "value3"]}
  """
  def parse_csv_line(line) do
    parse_csv_fields(line)
  end

  # Recursive CSV field parser that handles quoted fields and escaped quotes
  defp parse_csv_fields(line) do
    parse_csv_fields(line, [], "", false, 0)
  end

  defp parse_csv_fields("", fields, current, _in_quotes, _pos) do
    {:ok, Enum.reverse([current | fields])}
  end

  defp parse_csv_fields(<<char::utf8, rest::binary>>, fields, current, in_quotes, pos) do
    case {char, in_quotes} do
      # Start quote
      {?", false} ->
        parse_csv_fields(rest, fields, current, true, pos + 1)

      # End quote or escaped quote
      {?", true} ->
        case rest do
          # Escaped quote (double quote)
          <<?\", rest2::binary>> ->
            parse_csv_fields(rest2, fields, current <> <<"\"">>, true, pos + 2)

          # End quote
          _ ->
            parse_csv_fields(rest, fields, current, false, pos + 1)
        end

      # Comma outside quotes (field separator)
      {?,, false} ->
        parse_csv_fields(rest, [current | fields], "", false, pos + 1)

      # Any character inside quotes
      {char, true} ->
        parse_csv_fields(rest, fields, current <> <<char>>, true, pos + 1)

      # Any character outside quotes
      {char, false} ->
        parse_csv_fields(rest, fields, current <> <<char>>, false, pos + 1)
    end
  end
end
