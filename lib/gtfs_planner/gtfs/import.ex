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
  alias GtfsPlanner.Gtfs.Import.{Result, BatchProcessor, RowParser}
  alias GtfsPlanner.Gtfs.Extensions

  require Logger

  @batch_size Application.compile_env(:gtfs_planner, :import_batch_size, 1000)

  @import_specs [
    # Phase 1
    {:agencies, "agency.txt", Gtfs.Agency, &RowParser.agency_row_to_attrs/3, :phase_1},
    {:feed_info, "feed_info.txt", Gtfs.FeedInfo, &RowParser.feed_info_row_to_attrs/3, :phase_1},
    {:levels, "levels.txt", Gtfs.Level, &RowParser.level_row_to_attrs/3, :phase_1},
    {:areas, "areas.txt", Gtfs.Area, &RowParser.area_row_to_attrs/3, :phase_1},
    {:networks, "networks.txt", Gtfs.Network, &RowParser.network_row_to_attrs/3, :phase_1},
    {:fare_media, "fare_media.txt", Gtfs.FareMedia, &RowParser.fare_media_row_to_attrs/3,
     :phase_1},
    {:rider_categories, "rider_categories.txt", Gtfs.RiderCategory,
     &RowParser.rider_category_row_to_attrs/3, :phase_1},
    {:booking_rules, "booking_rules.txt", Gtfs.BookingRule,
     &RowParser.booking_rule_row_to_attrs/3, :phase_1},
    {:locations, "locations.txt", Gtfs.Location, &RowParser.location_row_to_attrs/3, :phase_1},
    {:routes, "routes.txt", Gtfs.Route, &RowParser.route_row_to_attrs/3, :phase_1},
    {:calendars, "calendar.txt", Gtfs.Calendar, &RowParser.calendar_row_to_attrs/3, :phase_1},
    {:calendar_dates, "calendar_dates.txt", Gtfs.CalendarDate,
     &RowParser.calendar_date_row_to_attrs/3, :phase_1},
    {:route_patterns, "route_patterns.txt", Gtfs.RoutePattern,
     &RowParser.route_pattern_row_to_attrs/3, :phase_1},
    {:route_networks, "route_networks.txt", Gtfs.RouteNetwork,
     &RowParser.route_network_row_to_attrs/3, :phase_1},
    {:fare_attributes, "fare_attributes.txt", Gtfs.FareAttribute,
     &RowParser.fare_attribute_row_to_attrs/3, :phase_1},
    {:fare_rules, "fare_rules.txt", Gtfs.FareRule, &RowParser.fare_rule_row_to_attrs/3, :phase_1},
    {:fare_products, "fare_products.txt", Gtfs.FareProduct,
     &RowParser.fare_product_row_to_attrs/3, :phase_1},
    {:timeframes, "timeframes.txt", Gtfs.Timeframe, &RowParser.timeframe_row_to_attrs/3,
     :phase_1},
    {:trips, "trips.txt", Gtfs.Trip, &RowParser.trip_row_to_attrs/3, :phase_1},
    {:stops, "stops.txt", Gtfs.Stop, &RowParser.stop_row_to_attrs/3, :phase_1},
    {:pathways, "pathways.txt", Gtfs.Pathway, &RowParser.pathway_row_to_attrs/3, :phase_1},
    {:transfers, "transfers.txt", Gtfs.Transfer, &RowParser.transfer_row_to_attrs/3, :phase_1},
    {:stop_areas, "stop_areas.txt", Gtfs.StopArea, &RowParser.stop_area_row_to_attrs/3, :phase_1},
    {:frequencies, "frequencies.txt", Gtfs.Frequency, &RowParser.frequency_row_to_attrs/3,
     :phase_1},
    {:attributions, "attributions.txt", Gtfs.Attribution, &RowParser.attribution_row_to_attrs/3,
     :phase_1},
    {:fare_leg_rules, "fare_leg_rules.txt", Gtfs.FareLegRule,
     &RowParser.fare_leg_rule_row_to_attrs/3, :phase_1},
    {:fare_leg_join_rules, "fare_leg_join_rules.txt", Gtfs.FareLegJoinRule,
     &RowParser.fare_leg_join_rule_row_to_attrs/3, :phase_1},
    {:fare_transfer_rules, "fare_transfer_rules.txt", Gtfs.FareTransferRule,
     &RowParser.fare_transfer_rule_row_to_attrs/3, :phase_1},
    {:translations, "translations.txt", Gtfs.Translation, &RowParser.translation_row_to_attrs/3,
     :phase_1},
    # Phase 2
    {:stop_times, "stop_times.txt", Gtfs.StopTime, &RowParser.stop_time_row_to_attrs/3, :phase_2},
    {:shapes, "shapes.txt", Gtfs.Shape, &RowParser.shape_row_to_attrs/3, :phase_2}
  ]

  @filename_to_spec Map.new(@import_specs, fn {_key, filename, _schema, _parser_fun, _phase} =
                                                spec ->
                      {String.downcase(filename), spec}
                    end)
  @phase_1_specs Enum.filter(@import_specs, fn {_k, _f, _s, _p, phase} -> phase == :phase_1 end)
  @phase_2_specs Enum.filter(@import_specs, fn {_k, _f, _s, _p, phase} -> phase == :phase_2 end)
  @supported_count_keys Enum.map(@import_specs, fn {key, _f, _s, _p, _phase} -> key end)

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

    - `{:ok, %Import.Result{}}` on success
      - `counts` - map with keys for each file type containing import counts
      - `unrecognized_files` - list of unrecognized filenames
      - `topic` - PubSub topic for progress updates
      - `archive_warnings` - list of `%{filename, reason, detail}` maps for archives that could not be expanded
      - `extensions` - `:not_present` when no extension manifest was supplied, or `:complete` when the extension phase finished fully
    - `{:error, reason}` on failure

  ## Examples

      iex> files = [%{filename: "routes.txt", content: "route_id,route_type\\nR1,3"}]
      iex> import_files(org_id, version_id, files)
      {:ok, %Import.Result{counts: %{routes: 1, stops: 0, ...}, unrecognized_files: [], topic: "import:123456", archive_warnings: [], extensions: :not_present}}
  """
  def import_files(organization_id, gtfs_version_id, files, topic \\ nil) do
    # Expand any uploaded .zip archives into individual file entries
    {files, archive_warnings} = expand_archives(files)

    # Categorize files by filename (case-insensitive)
    {categorized, unrecognized_files, extensions} = categorize_files(files)

    # Generate unique progress topic for PubSub if not provided
    topic = topic || "import:#{:erlang.unique_integer()}"

    # Phase 1: Import core files in a single transaction for atomicity.
    result =
      Repo.transaction(fn ->
        Enum.reduce_while(@phase_1_specs, %{}, fn {key, _filename, schema, parser_fun, _phase},
                                                  counts ->
          case process_file_category(
                 categorized[key] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 key,
                 schema,
                 parser_fun
               ) do
            {:ok, count} -> {:cont, Map.put(counts, key, count)}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)

    # Check if Phase 1 succeeded
    case result do
      {:ok, counts} ->
        phase_2_result =
          Enum.reduce_while(@phase_2_specs, {:ok, counts}, fn
            {key, _filename, schema, parser_fun, _phase}, {:ok, acc_counts} ->
              case process_phase_2_category(
                     categorized[key] || [],
                     organization_id,
                     gtfs_version_id,
                     topic,
                     schema,
                     parser_fun
                   ) do
                {:ok, count} -> {:cont, {:ok, Map.put(acc_counts, key, count)}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
          end)

        case phase_2_result do
          {:ok, counts} ->
            counts = Enum.reduce(@supported_count_keys, counts, &Map.put_new(&2, &1, 0))

            case import_extensions_phase(organization_id, gtfs_version_id, extensions, counts) do
              {:ok, extensions_status, counts} ->
                {:ok,
                 %Result{
                   counts: counts,
                   unrecognized_files: unrecognized_files,
                   topic: topic,
                   archive_warnings: archive_warnings,
                   extensions: extensions_status
                 }}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Processes phase 2 files with batch-level transactions
  # Each batch gets its own transaction to prevent long-running transactions
  defp process_phase_2_category(
         files,
         organization_id,
         gtfs_version_id,
         topic,
         schema,
         row_to_attrs_fn
       ) do
    total_count =
      Enum.reduce_while(files, 0, fn file, acc ->
        {rows_stream, total_rows} = parse_csv_content_with_count(file.content)

        case BatchProcessor.insert_batched_with_transactions(
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

  # Categorizes files by filename into file type buckets.
  # Returns {categorized, unrecognized, extensions} where extensions is a map
  # with optional :json and :images keys for _pathways_extensions data.
  defp categorize_files(files) do
    initial_categorized = Map.new(@supported_count_keys, fn key -> {key, []} end)
    initial_acc = {initial_categorized, [], %{}}

    {categorized, unrecognized, extensions} =
      Enum.reduce(files, initial_acc, fn file, {acc, unrecognized_acc, ext_acc} ->
        normalized_filename = normalize_uploaded_filename(file.filename)
        lower = String.downcase(normalized_filename)
        basename = Path.basename(lower)

        cond do
          Map.has_key?(@filename_to_spec, basename) ->
            {key, _filename, _schema, _parser_fun, _phase} =
              Map.fetch!(@filename_to_spec, basename)

            normalized_file = %{file | filename: basename}
            {Map.update!(acc, key, &[normalized_file | &1]), unrecognized_acc, ext_acc}

          basename == "_pathways_extensions.json" ->
            {acc, unrecognized_acc, Map.put(ext_acc, :json, file.content)}

          is_binary(extract_extensions_image_zip_path(normalized_filename)) ->
            image_zip_path = extract_extensions_image_zip_path(normalized_filename)
            images = Map.get(ext_acc, :images, %{})
            images = Map.put(images, image_zip_path, file.content)
            {acc, unrecognized_acc, Map.put(ext_acc, :images, images)}

          true ->
            {acc, [normalized_filename | unrecognized_acc], ext_acc}
        end
      end)

    categorized =
      Map.new(categorized, fn {key, files_list} -> {key, Enum.reverse(files_list)} end)

    {categorized, Enum.reverse(unrecognized), extensions}
  end

  @doc """
  Returns all supported import filenames.
  """
  def supported_filenames do
    Enum.map(@import_specs, fn {_key, filename, _schema, _parser_fun, _phase} -> filename end)
  end

  @doc """
  Returns all supported import count keys.
  """
  def supported_count_keys do
    @supported_count_keys
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

  @max_zip_entries 10_000
  @default_max_zip_uncompressed_bytes 500 * 1024 * 1024
  @default_max_zip_entry_uncompressed_bytes 500 * 1024 * 1024

  @doc false
  def zip_limits do
    max_total_bytes =
      configured_zip_limit(
        :import_max_zip_uncompressed_bytes,
        @default_max_zip_uncompressed_bytes
      )

    max_entry_bytes =
      configured_zip_limit(
        :import_max_zip_entry_uncompressed_bytes,
        min(max_total_bytes, @default_max_zip_entry_uncompressed_bytes)
      )

    %{
      max_entries: @max_zip_entries,
      max_total_bytes: max_total_bytes,
      max_entry_bytes: min(max_entry_bytes, max_total_bytes)
    }
  end

  @doc """
  Expands uploaded `.zip` archives into individual file entries.

  Returns `{expanded_files, archive_warnings}` where `archive_warnings` is a list
  of `%{filename: String.t(), reason: atom(), detail: String.t()}` maps describing
  archives that could not be expanded.

  Non-zip entries pass through unchanged.

  Safety behavior:
  - ignores hidden/system zip entries
  - rejects nested archives inside archives
  - enforces entry-count and total-uncompressed-size limits
  - emits a structured warning when expansion fails (instead of passing the raw archive through)
  """
  def expand_archives(files) do
    {files_acc, warnings_acc} =
      Enum.reduce(files, {[], []}, fn file, {files_acc, warnings_acc} ->
        if String.ends_with?(String.downcase(file.filename), ".zip") do
          limits = zip_limits()

          case check_zip_archive_metadata_against_limits(file, limits) do
            :ok ->
              case :zip.unzip(file.content, [:memory]) do
                {:ok, entries} ->
                  entry_sizes = Enum.map(entries, fn {_name, content} -> byte_size(content) end)

                  case check_zip_entry_sizes_against_limits(entry_sizes, limits) do
                    {:ok, _entries_count, _total_bytes} ->
                      normalized_entries =
                        Enum.flat_map(entries, fn {name, content} ->
                          filename = normalize_uploaded_filename(to_string(name))

                          cond do
                            ignore_zip_entry?(filename) ->
                              []

                            String.ends_with?(String.downcase(filename), ".zip") ->
                              Logger.warning(
                                "Rejecting nested zip entry #{filename} in archive #{file.filename}"
                              )

                              []

                            true ->
                              [%{filename: filename, content: content}]
                          end
                        end)

                      files_acc =
                        Enum.reduce(normalized_entries, files_acc, fn entry, acc ->
                          [entry | acc]
                        end)

                      {files_acc, warnings_acc}

                    {:error, reason, entries_count, total_bytes, entry_bytes} ->
                      Logger.warning(
                        "Zip archive #{file.filename} exceeds safety limits after expansion " <>
                          "(reason=#{reason}, entries=#{entries_count}, bytes=#{total_bytes}, " <>
                          "entry_bytes=#{entry_bytes}, max_entries=#{limits.max_entries}, " <>
                          "max_total_bytes=#{limits.max_total_bytes}, " <>
                          "max_entry_bytes=#{limits.max_entry_bytes}), skipping expansion"
                      )

                      warning = %{
                        filename: file.filename,
                        reason: :archive_too_large,
                        detail:
                          "exceeds safety limits (#{reason}: #{entries_count} entries, #{total_bytes} bytes uncompressed)"
                      }

                      {files_acc, [warning | warnings_acc]}
                  end

                {:error, reason} ->
                  Logger.warning(
                    "Failed to expand zip archive #{file.filename}: #{inspect(reason)}"
                  )

                  warning = %{
                    filename: file.filename,
                    reason: :unzip_failed,
                    detail: "archive could not be read (#{inspect(reason)})"
                  }

                  {files_acc, [warning | warnings_acc]}
              end

            {:error, reason, entries_count, total_bytes, entry_bytes} ->
              Logger.warning(
                "Zip archive #{file.filename} exceeds safety limits " <>
                  "(reason=#{reason}, entries=#{entries_count}, bytes=#{total_bytes}, " <>
                  "entry_bytes=#{entry_bytes}, max_entries=#{limits.max_entries}, " <>
                  "max_total_bytes=#{limits.max_total_bytes}, " <>
                  "max_entry_bytes=#{limits.max_entry_bytes}), skipping expansion"
              )

              warning = %{
                filename: file.filename,
                reason: :archive_too_large,
                detail:
                  "exceeds safety limits (#{reason}: #{entries_count} entries, #{total_bytes} bytes uncompressed)"
              }

              {files_acc, [warning | warnings_acc]}

            {:error, reason} ->
              Logger.warning(
                "Failed to preflight zip archive #{file.filename}: #{inspect(reason)}"
              )

              warning = %{
                filename: file.filename,
                reason: :unzip_failed,
                detail: "archive could not be read (#{inspect(reason)})"
              }

              {files_acc, [warning | warnings_acc]}
          end
        else
          {[file | files_acc], warnings_acc}
        end
      end)

    {Enum.reverse(files_acc), Enum.reverse(warnings_acc)}
  end

  @doc false
  def zip_entry_sizes_within_limits?(entry_sizes, limits)
      when is_list(entry_sizes) and is_map(limits) do
    match?({:ok, _, _}, check_zip_entry_sizes_against_limits(entry_sizes, limits))
  end

  defp check_zip_entry_sizes_against_limits(entry_sizes, limits) do
    Enum.reduce_while(entry_sizes, {:ok, 0, 0}, fn entry_bytes, {:ok, count, total} ->
      next_count = count + 1
      next_total = total + entry_bytes

      cond do
        next_count > limits.max_entries ->
          {:halt, {:error, :too_many_entries, next_count, next_total, entry_bytes}}

        entry_bytes > limits.max_entry_bytes ->
          {:halt, {:error, :entry_too_large, next_count, next_total, entry_bytes}}

        next_total > limits.max_total_bytes ->
          {:halt, {:error, :total_too_large, next_count, next_total, entry_bytes}}

        true ->
          {:cont, {:ok, next_count, next_total}}
      end
    end)
  end

  defp check_zip_archive_metadata_against_limits(file, limits) do
    with_temp_file(file.content, ".zip", fn path ->
      case :zip.list_dir(String.to_charlist(path)) do
        {:ok, entries} ->
          entry_sizes =
            Enum.flat_map(entries, fn
              {:zip_file, name, file_info, _comment, _offset, _comp_size} ->
                filename = normalize_uploaded_filename(to_string(name))

                if String.ends_with?(String.downcase(filename), ".zip") do
                  Logger.warning(
                    "Rejecting nested zip entry #{filename} in archive #{file.filename}"
                  )
                end

                [zip_entry_uncompressed_size(file_info)]

              _ ->
                []
            end)

          case check_zip_entry_sizes_against_limits(entry_sizes, limits) do
            {:ok, _, _} = ok -> ok
            {:error, _, _, _, _} = error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> case do
      {:ok, _entries_count, _total_bytes} -> :ok
      other -> other
    end
  end

  defp with_temp_file(binary, extension, fun) when is_binary(binary) and is_binary(extension) do
    filename =
      "gtfs-import-#{System.unique_integer([:positive, :monotonic])}#{extension}"

    path = Path.join(System.tmp_dir!(), filename)

    case File.write(path, binary) do
      :ok ->
        try do
          fun.(path)
        after
          File.rm(path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp zip_entry_uncompressed_size({:file_info, size, _, _, _, _, _, _, _, _, _, _, _, _})
       when is_integer(size) and size >= 0 do
    size
  end

  defp zip_entry_uncompressed_size(_), do: 0

  defp configured_zip_limit(key, default) do
    case Application.get_env(:gtfs_planner, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_uploaded_filename(filename) when is_binary(filename) do
    filename
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
    |> String.trim_leading("/")
  end

  defp ignore_zip_entry?(filename) do
    lower = String.downcase(filename)
    basename = Path.basename(lower)

    filename == "" or
      String.ends_with?(filename, "/") or
      String.starts_with?(lower, "__macosx/") or
      String.starts_with?(basename, "._") or
      basename == ".ds_store" or
      basename == "thumbs.db"
  end

  defp extract_extensions_image_zip_path(filename) do
    marker = "_pathways_extensions/"
    lower = String.downcase(filename)

    case :binary.match(lower, marker) do
      {idx, _len} -> binary_part(filename, idx, byte_size(filename) - idx)
      :nomatch -> nil
    end
  end

  # Runs the extensions import phase after standard GTFS phases complete.
  # When no extension manifest is present the phase is absent and counts are
  # returned unchanged. On extension failure the error is propagated so the
  # overall import result is an error rather than a silently incomplete import.
  defp import_extensions_phase(_organization_id, _gtfs_version_id, extensions, counts)
       when not is_map_key(extensions, :json) do
    {:ok, :not_present, counts}
  end

  defp import_extensions_phase(organization_id, gtfs_version_id, extensions, counts) do
    image_files = Map.get(extensions, :images, %{})

    case Extensions.Import.import_extensions(
           organization_id,
           gtfs_version_id,
           extensions.json,
           image_files
         ) do
      {:ok, ext_counts} ->
        {:ok, :complete, Map.merge(counts, ext_counts)}

      {:error, reason} ->
        {:error, reason}
    end
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
