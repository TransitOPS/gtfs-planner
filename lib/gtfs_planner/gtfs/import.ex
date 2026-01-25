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
  Imports GTFS data files within a single database transaction.

  Accepts a list of file maps containing filename and binary content.
  Files are categorized by filename and processed in the correct order
  to satisfy foreign key dependencies.

  Progress is broadcast via PubSub on the returned topic for LiveView consumption.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version to associate records with
    - `files` - List of `%{filename: string, content: binary}` maps

  ## Returns

    - `{:ok, {counts, unrecognized_files, topic}}` on success
      - `counts` - map with keys for each file type containing import counts
      - `unrecognized_files` - list of unrecognized filenames
      - `topic` - PubSub topic for progress updates
    - `{:error, reason}` on failure (transaction is rolled back)

  ## Examples

      iex> files = [%{filename: "routes.txt", content: "route_id,route_type\\nR1,3"}]
      iex> import_files(org_id, version_id, files)
      {:ok, {%{routes: 1, stops: 0, ...}, [], "import:123456"}}
  """
  def import_files(organization_id, gtfs_version_id, files) do
    # Categorize files by filename (case-insensitive)
    {categorized, unrecognized_files} = categorize_files(files)

    # Generate unique progress topic for PubSub
    topic = "import:#{:erlang.unique_integer()}"

    # Execute all imports within a single transaction
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

        # Process stop_times
        counts =
          case process_file_category(
                 categorized[:stop_times] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 :stop_times,
                 Gtfs.StopTime,
                 &RowParser.stop_time_row_to_attrs/3
               ) do
            {:ok, count} -> Map.put(counts, :stop_times, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        # Build stop lookup map for pathways
        stop_map = BatchProcessor.build_stop_lookup_map(Repo, organization_id, gtfs_version_id)

        # Process pathways (using stop lookup map)
        counts =
          case process_pathways(
                 categorized[:pathways] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 stop_map
               ) do
            {:ok, count} -> Map.put(counts, :pathways, count)
            {:error, reason} -> Repo.rollback(reason)
          end

        counts =
          [:routes, :calendar, :calendar_dates, :route_patterns, :trips, :levels, :stops, :stop_times, :pathways]
          |> Enum.reduce(counts, fn key, acc -> Map.put_new(acc, key, 0) end)
        counts
      end)

    case result do
      {:ok, counts} ->
        {:ok, {counts, unrecognized_files, topic}}

      {:error, reason} ->
        {:error, reason}
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
        rows_stream = parse_csv_content(file.content)

        case BatchProcessor.insert_batched(
               Repo,
               schema,
               rows_stream,
               row_to_attrs_fn,
               organization_id: organization_id,
               gtfs_version_id: gtfs_version_id,
               file_name: file.filename,
               topic: topic,
               batch_size: @batch_size
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

  # Processes pathway files using the stop lookup map
  defp process_pathways(files, organization_id, gtfs_version_id, topic, stop_map) do
    total_count =
      Enum.reduce_while(files, 0, fn file, acc ->
        rows_stream = parse_csv_content(file.content)

        # Create a wrapper function that includes the stop_map
        row_to_attrs_fn = fn row, org_id, version_id ->
          RowParser.pathway_row_to_attrs(row, org_id, version_id, stop_map)
        end

        case BatchProcessor.insert_batched(
               Repo,
               Gtfs.Pathway,
               rows_stream,
               row_to_attrs_fn,
               organization_id: organization_id,
               gtfs_version_id: gtfs_version_id,
               file_name: file.filename,
               topic: topic,
               batch_size: @batch_size
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

    categorized = Map.new(categorized, fn {key, files_list} -> {key, Enum.reverse(files_list)} end)
    {categorized, Enum.reverse(unrecognized)}
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