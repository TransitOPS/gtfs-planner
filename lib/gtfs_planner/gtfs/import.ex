defmodule GtfsPlanner.Gtfs.Import do
  @moduledoc """
  Context module for importing GTFS data files.

  Handles parsing and importing GTFS data from uploaded CSV files including:
  - `levels.txt` - Level/floor definitions for stations
  - `stops.txt` - Stop/station locations and metadata
  - `pathways.txt` - Pathways connecting stops within stations

  All imports are executed within a single database transaction to ensure
  data consistency. Files are processed in dependency order (levels → stops → pathways)
  to satisfy foreign key constraints.

  ## Usage

      files = [
        %{filename: "levels.txt", content: binary_content},
        %{filename: "stops.txt", content: binary_content},
        %{filename: "pathways.txt", content: binary_content}
      ]

      case Import.import_files(org_id, version_id, files) do
        {:ok, {%{levels: 5, stops: 20, pathways: 15}, _unrecognized}} ->
          # Import successful
        {:error, failed_operation, failed_value, changes_so_far} ->
          # Import failed, transaction rolled back
      end
  """

  alias GtfsPlanner.{Repo, Gtfs}
  alias Ecto.Multi

  @doc """
  Imports GTFS data files within a single database transaction.

  Accepts a list of file maps containing filename and binary content.
  Files are categorized by filename and processed in the correct order
  to satisfy foreign key dependencies.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version to associate records with
    - `files` - List of `%{filename: string, content: binary}` maps

  ## Returns

    - `{:ok, {counts, unrecognized_files}}` on success
      - `counts` - map with keys `:levels`, `:stops`, `:pathways` containing import counts
      - `unrecognized_files` - list of unrecognized filenames
    - `{:error, failed_operation, failed_value, changes_so_far}` on failure (transaction is rolled back)
      - `failed_operation` - atom name of the operation that failed
      - `failed_value` - the error value (typically an Ecto.Changeset)
      - `changes_so_far` - map of successful operations before the failure

  ## Examples

      iex> files = [%{filename: "levels.txt", content: "level_id,level_name\\nL1,Ground"}]
      iex> import_files(org_id, version_id, files)
      {:ok, {%{levels: 1, stops: 0, pathways: 0}, []}}
  """
  def import_files(organization_id, gtfs_version_id, files) do
    # Categorize files by filename (case-insensitive)
    {categorized, unrecognized_files} = categorize_files(files)

    # Build Ecto.Multi transaction processing in dependency order
    multi =
      Multi.new()
      |> add_route_imports(categorized[:routes] || [], organization_id, gtfs_version_id)
      |> add_calendar_imports(categorized[:calendars] || [], organization_id, gtfs_version_id)
      |> add_calendar_date_imports(categorized[:calendar_dates] || [], organization_id, gtfs_version_id)
      |> add_route_pattern_imports(categorized[:route_patterns] || [], organization_id, gtfs_version_id)
      |> add_trip_imports(categorized[:trips] || [], organization_id, gtfs_version_id)
      |> add_level_imports(categorized[:levels] || [], organization_id, gtfs_version_id)
      |> add_stop_imports(categorized[:stops] || [], organization_id, gtfs_version_id)
      |> add_stop_time_imports(categorized[:stop_times] || [], organization_id, gtfs_version_id)
      |> add_pathway_imports(categorized[:pathways] || [], organization_id, gtfs_version_id)

    # Execute transaction
    case Repo.transaction(multi) do
      {:ok, results} ->
        # Count successful imports per category
        counts = %{
          routes: count_category(results, "route_"),
          calendars: count_calendars(results),
          calendar_dates: count_category(results, "calendar_date_"),
          route_patterns: count_category(results, "route_pattern_"),
          trips: count_category(results, "trip_"),
          levels: count_category(results, "level_"),
          stops: count_category(results, "stop_"),
          stop_times: count_category(results, "stop_time_"),
          pathways: results[:pathways] || 0
        }

        {:ok, {counts, unrecognized_files}}

      {:error, failed_operation, failed_value, changes_so_far} ->
        {:error, failed_operation, failed_value, changes_so_far}
    end
  end

  # Categorizes files by filename into :routes, :route_patterns, :calendars, :calendar_dates, :trips, :levels, :stops, :stop_times, :pathways buckets
  defp categorize_files(files) do
    initial_acc = {%{routes: [], route_patterns: [], calendars: [], calendar_dates: [], trips: [], levels: [], stops: [], stop_times: [], pathways: []}, []}

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

  # Adds route imports to Ecto.Multi
  defp add_route_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_routes_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  # Adds route pattern imports to Ecto.Multi
  defp add_route_pattern_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_route_patterns_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  # Adds level imports to Ecto.Multi
  defp add_level_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_levels_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  # Adds stop imports to Ecto.Multi
  defp add_stop_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_stops_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  # Adds pathway imports to Ecto.Multi using Multi.run to solve intra-transaction dependencies
  defp add_pathway_imports(multi, files, organization_id, gtfs_version_id) do
    if files == [] do
      multi
    else
      Multi.run(multi, :pathways, fn repo, changes ->
        # Create a map of stop_id -> Stop struct from the transaction changes
        stop_map =
          changes
          |> Enum.filter(fn {key, _value} ->
            key |> Atom.to_string() |> String.starts_with?("stop_")
          end)
          |> Enum.map(fn {_key, stop} -> {stop.stop_id, stop} end)
          |> Map.new()

        pathway_rows =
          files
          |> Enum.flat_map(&(&1.content |> parse_csv_content()))

        result =
          pathway_rows
          |> Stream.with_index(1)
          |> Enum.reduce_while([], fn {row_map, line_number}, acc ->
            changeset =
              pathway_row_to_changeset(
                row_map,
                organization_id,
                gtfs_version_id,
                stop_map
              )

            case repo.insert(changeset) do
              {:ok, pathway} ->
                {:cont, [pathway | acc]}

              {:error, failed_changeset} ->
                {:halt, {:error, {failed_changeset, line_number}}}
            end
          end)

        case result do
          {:error, {failed_changeset, line_number}} ->
            {:error, {failed_changeset, line_number}}

          inserted_pathways ->
            {:ok, length(inserted_pathways)}
        end
      end)
    end
  end

  # Counts successful operations for a category by operation name prefix
  defp count_category(results, prefix) when is_binary(prefix) do
    results
    |> Enum.filter(fn {key, _value} ->
      key_str = Atom.to_string(key)
      String.starts_with?(key_str, prefix)
    end)
    |> length()
  end

  # Counts calendar operations excluding calendar_date operations
  defp count_calendars(results) do
    results
    |> Enum.filter(fn {key, _value} ->
      key_str = Atom.to_string(key)
      String.starts_with?(key_str, "calendar_") and not String.starts_with?(key_str, "calendar_date_")
    end)
    |> length()
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
          <<?", rest2::binary>> ->
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

  @doc """
  Imports routes from CSV content and returns changeset tuples for Ecto.Multi.

  Parses routes.txt CSV content and creates changesets for each valid route.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.
  """
  def import_routes_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = route_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"route_#{index}", changeset}
    end)
  end

  @doc """
  Imports route patterns from CSV content and returns changeset tuples for Ecto.Multi.

  Parses route_patterns.txt CSV content and creates changesets for each valid route pattern.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.
  """
  def import_route_patterns_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = route_pattern_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"route_pattern_#{index}", changeset}
    end)
  end

  # Converts a CSV row map to a Route changeset
  defp route_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    attrs =
      with {:ok, route_id} <- extract_required(row_map, "route_id"),
       {:ok, route_type} <- parse_route_type(row_map["route_type"]),
       {:ok, route_sort_order} <- parse_integer(row_map["route_sort_order"]),
       {:ok, continuous_pickup} <- parse_continuous_value(row_map["continuous_pickup"]),
       {:ok, continuous_drop_off} <- parse_continuous_value(row_map["continuous_drop_off"]) do
        %{
          route_id: route_id,
          route_type: route_type,
          route_short_name: empty_to_nil(row_map["route_short_name"]),
          route_long_name: empty_to_nil(row_map["route_long_name"]),
          agency_id: empty_to_nil(row_map["agency_id"]),
          route_desc: empty_to_nil(row_map["route_desc"]),
          route_url: empty_to_nil(row_map["route_url"]),
          route_color: empty_to_nil(row_map["route_color"]) || "FFFFFF",
          route_text_color: empty_to_nil(row_map["route_text_color"]) || "000000",
          route_sort_order: route_sort_order,
          continuous_pickup: continuous_pickup || 1,
          continuous_drop_off: continuous_drop_off || 1,
          network_id: empty_to_nil(row_map["network_id"]),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        }
      else
        {:error, _reason} ->
          %{
            route_id: row_map["route_id"] || "",
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.Route.changeset(%Gtfs.Route{}, attrs)
  end

  # Converts a CSV row map to a RoutePattern changeset
  defp route_pattern_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    # Always parse all fields, collecting results
    route_pattern_id_result = extract_required(row_map, "route_pattern_id")
    route_id_result = extract_required(row_map, "route_id")
    direction_id_result = parse_direction_id(row_map["direction_id"])
    typicality_result = parse_typicality(row_map["route_pattern_typicality"])
    sort_order_result = parse_integer(row_map["route_pattern_sort_order"])
    canonical_result = parse_canonical_route_pattern(row_map["canonical_route_pattern"])

    # Build attrs from successful parses or use values that will fail validation
    attrs = %{
      route_pattern_id: unwrap_or_default(route_pattern_id_result, ""),
      route_id: unwrap_or_default(route_id_result, ""),
      direction_id: unwrap_or_invalid(direction_id_result),
      route_pattern_name: empty_to_nil(row_map["route_pattern_name"]),
      route_pattern_time_desc: empty_to_nil(row_map["route_pattern_time_desc"]),
      route_pattern_typicality: unwrap_or_invalid(typicality_result),
      route_pattern_sort_order: unwrap_or_invalid(sort_order_result),
      representative_trip_id: empty_to_nil(row_map["representative_trip_id"]),
      canonical_route_pattern: unwrap_or_invalid(canonical_result),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    Gtfs.RoutePattern.changeset(%Gtfs.RoutePattern{}, attrs)
  end

  # Unwraps {:ok, value} or returns the default
  defp unwrap_or_default({:ok, value}, _default), do: value
  defp unwrap_or_default({:error, _}, default), do: default

  # Unwraps {:ok, value} or returns a value that will fail validation
  # For integer fields with range constraints, we return a clearly invalid value
  defp unwrap_or_invalid({:ok, value}), do: value
  defp unwrap_or_invalid({:error, _}), do: -999

  @doc """
  Imports levels from CSV content and returns changeset tuples for Ecto.Multi.

  Parses levels.txt CSV content and creates changesets for each valid level.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.

  ## Examples

      iex> content = "level_id,level_index,level_name\\nL1,0.0,Ground Floor"
      iex> import_levels_from_content(org_id, version_id, content)
      [{:insert, :level_0, %Ecto.Changeset{}}]
  """
  def import_levels_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = level_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"level_#{index}", changeset}
    end)
  end

  # Converts a CSV row map to a Level changeset
  defp level_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    level_id = row_map["level_id"] || ""
    level_index_str = row_map["level_index"] || ""
    level_name = empty_to_nil(row_map["level_name"])

    attrs =
      case parse_float(level_index_str) do
        {:ok, level_index} ->
          %{
            level_id: level_id,
            level_index: level_index,
            level_name: level_name,
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }

        {:error, _reason} ->
          # Invalid level_index will be caught by changeset validation
          %{
            level_id: level_id,
            level_index: nil,
            level_name: level_name,
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.Level.changeset(%Gtfs.Level{}, attrs)
  end

  # Parses a string to a float
  defp parse_float(nil), do: {:error, "nil value"}
  defp parse_float(""), do: {:error, "empty value"}

  defp parse_float(string) when is_binary(string) do
    case Float.parse(string) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "invalid float: #{string}"}
    end
  end

  # Converts empty strings to nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(value), do: value

  @doc """
  Imports stops from CSV content and returns changeset tuples for Ecto.Multi.

  Parses stops.txt CSV content and creates changesets for each valid stop.
  Resolves foreign key references (level_id, parent_station_id) to internal UUIDs.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.

  ## Examples

      iex> content = "stop_id,stop_name,stop_lat,stop_lon\\nS1,Station,40.7,-74.0"
      iex> import_stops_from_content(org_id, version_id, content)
      [{:insert, :stop_0, %Ecto.Changeset{}}]
  """
  def import_stops_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = stop_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"stop_#{index}", changeset}
    end)
  end

  # Converts a CSV row map to a Stop changeset
  defp stop_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    attrs =
      with {:ok, stop_id} <- extract_required(row_map, "stop_id"),
           {:ok, stop_lat} <- parse_decimal(row_map["stop_lat"]),
           {:ok, stop_lon} <- parse_decimal(row_map["stop_lon"]),
           {:ok, location_type} <- parse_location_type(row_map["location_type"]),
           {:ok, wheelchair_boarding} <- parse_wheelchair_boarding(row_map["wheelchair_boarding"]),
           {:ok, level_id} <-
             resolve_level_id(row_map["level_id"], organization_id, gtfs_version_id),
           {:ok, parent_station_id} <-
             resolve_parent_station_id(
               row_map["parent_station"],
               organization_id,
               gtfs_version_id
             ) do
        %{
          stop_id: stop_id,
          stop_name: empty_to_nil(row_map["stop_name"]),
          stop_desc: empty_to_nil(row_map["stop_desc"]),
          platform_code: empty_to_nil(row_map["platform_code"]),
          stop_lat: stop_lat,
          stop_lon: stop_lon,
          location_type: location_type,
          wheelchair_boarding: wheelchair_boarding,
          level_id: level_id,
          parent_station_id: parent_station_id,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        }
      else
        {:error, _reason} ->
          # Invalid data will be caught by changeset validation
          %{
            stop_id: row_map["stop_id"] || "",
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.Stop.changeset(%Gtfs.Stop{}, attrs)
  end


  # Converts a CSV row map to a Pathway changeset
  defp pathway_row_to_changeset(row_map, organization_id, gtfs_version_id, stop_map) do
    pathway_id = row_map["pathway_id"] || ""

    attrs =
      with {:ok, from_stop_id_str} <- extract_required(row_map, "from_stop_id"),
           {:ok, to_stop_id_str} <- extract_required(row_map, "to_stop_id"),
           {:ok, pathway_mode} <- parse_pathway_mode(row_map["pathway_mode"]),
           {:ok, is_bidirectional} <- parse_is_bidirectional(row_map["is_bidirectional"]),
           from_stop when is_map(from_stop) <- Map.get(stop_map, from_stop_id_str),
           to_stop when is_map(to_stop) <- Map.get(stop_map, to_stop_id_str) do
        # Parse optional fields individually, defaulting to nil on error
        traversal_time =
          case parse_integer(row_map["traversal_time"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        length =
          case parse_decimal(row_map["length"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        stair_count =
          case parse_integer(row_map["stair_count"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        max_slope =
          case parse_decimal(row_map["max_slope"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        min_width =
          case parse_decimal(row_map["min_width"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        %{
          pathway_id: pathway_id,
          pathway_mode: pathway_mode,
          is_bidirectional: is_bidirectional,
          traversal_time: traversal_time,
          length: length,
          stair_count: stair_count,
          max_slope: max_slope,
          min_width: min_width,
          signposted_as: empty_to_nil(row_map["signposted_as"]),
          reversed_signposted_as: empty_to_nil(row_map["reversed_signposted_as"]),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          from_stop_id: from_stop.id,
          to_stop_id: to_stop.id
        }
      else
        # Handle cases where stops are not found in the map (will result in a `nil` from with)
        nil ->
          %{
            pathway_id: pathway_id,
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id,
            from_stop_id: nil, # Explicitly set to nil to trigger validation
            to_stop_id: nil
          }
        {:error, _reason} ->
          # Invalid data will be caught by changeset validation
          %{
            pathway_id: pathway_id,
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.Pathway.changeset(%Gtfs.Pathway{}, attrs)
  end

  # Extracts a required field from a row map
  defp extract_required(row_map, field) do
    case row_map[field] do
      nil -> {:error, "missing required field: #{field}"}
      "" -> {:error, "empty required field: #{field}"}
      value -> {:ok, value}
    end
  end

  # Parses a string to a Decimal
  defp parse_decimal(nil), do: {:ok, nil}
  defp parse_decimal(""), do: {:ok, nil}

  defp parse_decimal(string) when is_binary(string) do
    try do
      case Decimal.new(string) do
        %Decimal{} = decimal -> {:ok, decimal}
        _ -> {:error, "invalid decimal: #{string}"}
      end
    rescue
      Decimal.Error -> {:error, "invalid decimal format: #{string}"}
      ArgumentError -> {:error, "invalid decimal value: #{string}"}
    end
  end

  # Parses location_type (0-4, default 0)
  defp parse_location_type(nil), do: {:ok, 0}
  defp parse_location_type(""), do: {:ok, 0}

  defp parse_location_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..4 -> {:ok, int}
      {int, ""} -> {:error, "location_type out of range 0-4: #{int}"}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid location_type: #{string}"}
  end

  # Parses wheelchair_boarding (0-2, optional)
  defp parse_wheelchair_boarding(nil), do: {:ok, nil}
  defp parse_wheelchair_boarding(""), do: {:ok, nil}

  defp parse_wheelchair_boarding(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..2 -> {:ok, int}
      {int, ""} -> {:error, "wheelchair_boarding out of range 0-2: #{int}"}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid wheelchair_boarding: #{string}"}
  end

  # Resolves a level_id string to internal UUID
  defp resolve_level_id(nil, _organization_id, _gtfs_version_id), do: {:ok, nil}
  defp resolve_level_id("", _organization_id, _gtfs_version_id), do: {:ok, nil}

  defp resolve_level_id(level_id_string, organization_id, gtfs_version_id) do
    case Gtfs.get_level_by_level_id(organization_id, gtfs_version_id, level_id_string) do
      nil -> {:ok, nil}
      level -> {:ok, level.id}
    end
  end

  # Resolves a parent_station string to internal UUID
  defp resolve_parent_station_id(nil, _organization_id, _gtfs_version_id), do: {:ok, nil}
  defp resolve_parent_station_id("", _organization_id, _gtfs_version_id), do: {:ok, nil}

  defp resolve_parent_station_id(parent_station_string, organization_id, gtfs_version_id) do
    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, parent_station_string) do
      nil -> {:ok, nil}
      stop -> {:ok, stop.id}
    end
  end

  # Parses route_type (0-7, 11, 12, required)
  defp parse_route_type(nil), do: {:error, "route_type is required"}
  defp parse_route_type(""), do: {:error, "route_type is required"}

  defp parse_route_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in [0, 1, 2, 3, 4, 5, 6, 7, 11, 12] -> {:ok, int}
      {int, ""} -> {:error, "route_type invalid value: #{int}"}
      _ -> {:error, "invalid route_type: #{string}"}
    end
  end

  # Parses continuous_pickup/continuous_drop_off (0-3, optional, default 1)
  defp parse_continuous_value(nil), do: {:ok, nil}
  defp parse_continuous_value(""), do: {:ok, nil}

  defp parse_continuous_value(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..3 -> {:ok, int}
      {int, ""} -> {:error, "continuous value out of range 0-3: #{int}"}
      _ -> {:error, "invalid continuous value: #{string}"}
    end
  end

  # Parses pathway_mode (1-7, required)
  defp parse_pathway_mode(nil), do: {:error, "pathway_mode is required"}
  defp parse_pathway_mode(""), do: {:error, "pathway_mode is required"}

  defp parse_pathway_mode(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 1..7 -> {:ok, int}
      {int, ""} -> {:error, "pathway_mode out of range 1-7: #{int}"}
      _ -> {:error, "invalid pathway_mode: #{string}"}
    end
  rescue
    _ -> {:error, "invalid pathway_mode: #{string}"}
  end

  # Parses is_bidirectional (0/1/true/false, default true)
  defp parse_is_bidirectional(nil), do: {:ok, true}
  defp parse_is_bidirectional(""), do: {:ok, true}
  defp parse_is_bidirectional("1"), do: {:ok, true}
  defp parse_is_bidirectional("0"), do: {:ok, false}

  defp parse_is_bidirectional(string) when is_binary(string) do
    case String.downcase(string) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "invalid is_bidirectional: #{string}"}
    end
  end

  # Parses direction_id (0-1, required)
  defp parse_direction_id(nil), do: {:error, "direction_id is required"}
  defp parse_direction_id(""), do: {:error, "direction_id is required"}

  defp parse_direction_id(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in [0, 1] -> {:ok, int}
      {int, ""} -> {:error, "direction_id out of range 0-1: #{int}"}
      _ -> {:error, "invalid direction_id: #{string}"}
    end
  end

  # Parses route_pattern_typicality (0-5, blank = 0 per MBTA spec)
  defp parse_typicality(nil), do: {:ok, 0}
  defp parse_typicality(""), do: {:ok, 0}

  defp parse_typicality(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..5 -> {:ok, int}
      {int, ""} -> {:error, "route_pattern_typicality out of range 0-5: #{int}"}
      _ -> {:error, "invalid route_pattern_typicality: #{string}"}
    end
  end

  # Parses canonical_route_pattern (0-2, blank = 0 per MBTA spec)
  defp parse_canonical_route_pattern(nil), do: {:ok, 0}
  defp parse_canonical_route_pattern(""), do: {:ok, 0}

  defp parse_canonical_route_pattern(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..2 -> {:ok, int}
      {int, ""} -> {:error, "canonical_route_pattern out of range 0-2: #{int}"}
      _ -> {:error, "invalid canonical_route_pattern: #{string}"}
    end
  end

  # Parses a string to an integer
  defp parse_integer(nil), do: {:ok, nil}
  defp parse_integer(""), do: {:ok, nil}

  defp parse_integer(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid integer: #{string}"}
  end

  # Parses GTFS date format YYYYMMDD to Date.t()
  defp parse_gtfs_date(nil), do: {:ok, nil}
  defp parse_gtfs_date(""), do: {:ok, nil}

  defp parse_gtfs_date(string) when is_binary(string) and byte_size(string) == 8 do
    year = String.slice(string, 0, 4)
    month = String.slice(string, 4, 2)
    day = String.slice(string, 6, 2)

    with {year_int, ""} <- Integer.parse(year),
         {month_int, ""} <- Integer.parse(month),
         {day_int, ""} <- Integer.parse(day),
         {:ok, date} <- Date.new(year_int, month_int, day_int) do
      {:ok, date}
    else
      _ -> {:error, "invalid GTFS date format: #{string}"}
    end
  end

  defp parse_gtfs_date(string) when is_binary(string) do
    {:error, "invalid GTFS date format (expected YYYYMMDD): #{string}"}
  end

  # Parses day flag (0 or 1)
  defp parse_day_flag(nil), do: {:error, "required"}
  defp parse_day_flag(""), do: {:error, "required"}
  defp parse_day_flag("0"), do: {:ok, 0}
  defp parse_day_flag("1"), do: {:ok, 1}

  defp parse_day_flag(string) when is_binary(string) do
    {:error, "invalid day flag (expected 0 or 1): #{string}"}
  end

  # Parses exception_type (1 or 2)
  defp parse_exception_type(nil), do: {:error, "required"}
  defp parse_exception_type(""), do: {:error, "required"}
  defp parse_exception_type("1"), do: {:ok, 1}
  defp parse_exception_type("2"), do: {:ok, 2}

  defp parse_exception_type(string) when is_binary(string) do
    {:error, "invalid exception_type (expected 1 or 2): #{string}"}
  end

  # Parses GTFS time format HH:MM:SS (supports times > 24:00:00)
  defp parse_gtfs_time(nil), do: {:ok, nil}
  defp parse_gtfs_time(""), do: {:ok, nil}

  defp parse_gtfs_time(string) when is_binary(string) do
    if String.match?(string, ~r/^\d{1,2}:\d{2}:\d{2}$/) do
      {:ok, string}
    else
      {:error, "invalid GTFS time format (expected HH:MM:SS): #{string}"}
    end
  end

  # Converts a CSV row map to a Calendar changeset
  defp calendar_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    attrs =
      with {:ok, service_id} <- extract_required(row_map, "service_id"),
           {:ok, monday} <- parse_day_flag(row_map["monday"]),
           {:ok, tuesday} <- parse_day_flag(row_map["tuesday"]),
           {:ok, wednesday} <- parse_day_flag(row_map["wednesday"]),
           {:ok, thursday} <- parse_day_flag(row_map["thursday"]),
           {:ok, friday} <- parse_day_flag(row_map["friday"]),
           {:ok, saturday} <- parse_day_flag(row_map["saturday"]),
           {:ok, sunday} <- parse_day_flag(row_map["sunday"]),
           {:ok, start_date} <- parse_gtfs_date(row_map["start_date"]),
           {:ok, end_date} <- parse_gtfs_date(row_map["end_date"]) do
        %{
          service_id: service_id,
          monday: monday,
          tuesday: tuesday,
          wednesday: wednesday,
          thursday: thursday,
          friday: friday,
          saturday: saturday,
          sunday: sunday,
          start_date: start_date,
          end_date: end_date,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        }
      else
        {:error, _reason} ->
          %{
            service_id: row_map["service_id"] || "",
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.Calendar.changeset(%Gtfs.Calendar{}, attrs)
  end

  @doc """
  Imports calendars from CSV content and returns changeset tuples for Ecto.Multi.

  Parses calendar.txt CSV content and creates changesets for each valid calendar.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.
  """
  def import_calendars_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = calendar_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"calendar_#{index}", changeset}
    end)
  end

  # Adds calendar imports to Ecto.Multi
  defp add_calendar_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_calendars_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  # Converts a CSV row map to a CalendarDate changeset
  defp calendar_date_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    attrs =
      with {:ok, service_id} <- extract_required(row_map, "service_id"),
           {:ok, date} <- parse_gtfs_date(row_map["date"]),
           {:ok, exception_type} <- parse_exception_type(row_map["exception_type"]) do
        %{
          service_id: service_id,
          date: date,
          exception_type: exception_type,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        }
      else
        {:error, _reason} ->
          %{
            service_id: row_map["service_id"] || "",
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.CalendarDate.changeset(%Gtfs.CalendarDate{}, attrs)
  end

  @doc """
  Imports calendar dates from CSV content and returns changeset tuples for Ecto.Multi.

  Parses calendar_dates.txt CSV content and creates changesets for each valid calendar date.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.
  """
  def import_calendar_dates_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = calendar_date_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"calendar_date_#{index}", changeset}
    end)
  end

  # Adds calendar date imports to Ecto.Multi
  defp add_calendar_date_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_calendar_dates_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  # Converts a CSV row map to a Trip changeset
  defp trip_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    attrs =
      with {:ok, trip_id} <- extract_required(row_map, "trip_id"),
           {:ok, route_id} <- extract_required(row_map, "route_id"),
           {:ok, service_id} <- extract_required(row_map, "service_id") do
        # Parse optional direction_id
        direction_id =
          case parse_direction_id(row_map["direction_id"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        # Parse optional accessibility fields
        wheelchair_accessible =
          case parse_integer(row_map["wheelchair_accessible"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        bikes_allowed =
          case parse_integer(row_map["bikes_allowed"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        cars_allowed =
          case parse_integer(row_map["cars_allowed"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        %{
          trip_id: trip_id,
          route_id: route_id,
          service_id: service_id,
          trip_headsign: empty_to_nil(row_map["trip_headsign"]),
          trip_short_name: empty_to_nil(row_map["trip_short_name"]),
          direction_id: direction_id,
          block_id: empty_to_nil(row_map["block_id"]),
          shape_id: empty_to_nil(row_map["shape_id"]),
          wheelchair_accessible: wheelchair_accessible,
          bikes_allowed: bikes_allowed,
          cars_allowed: cars_allowed,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        }
      else
        {:error, _reason} ->
          %{
            trip_id: row_map["trip_id"] || "",
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.Trip.changeset(%Gtfs.Trip{}, attrs)
  end

  @doc """
  Imports trips from CSV content and returns changeset tuples for Ecto.Multi.

  Parses trips.txt CSV content and creates changesets for each valid trip.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.
  """
  def import_trips_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = trip_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"trip_#{index}", changeset}
    end)
  end

  # Adds trip imports to Ecto.Multi
  defp add_trip_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_trips_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  @doc """
  Imports stop times from CSV content and returns changeset tuples for Ecto.Multi.

  Parses stop_times.txt CSV content and creates changesets for each valid stop time.
  Returns a list of `{:insert, name, changeset}` tuples that can be added
  to an Ecto.Multi transaction.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `content` - Binary CSV content with header row

  ## Returns

  List of `{:insert, name, changeset}` tuples for Ecto.Multi.
  """
  def import_stop_times_from_content(organization_id, gtfs_version_id, content) do
    content
    |> parse_csv_content()
    |> Stream.with_index()
    |> Enum.map(fn {row_map, index} ->
      changeset = stop_time_row_to_changeset(row_map, organization_id, gtfs_version_id)
      {:insert, :"stop_time_#{index}", changeset}
    end)
  end

  # Adds stop time imports to Ecto.Multi
  defp add_stop_time_imports(multi, files, organization_id, gtfs_version_id) do
    Enum.reduce(files, multi, fn file, multi_acc ->
      operations = import_stop_times_from_content(organization_id, gtfs_version_id, file.content)

      Enum.reduce(operations, multi_acc, fn {:insert, name, changeset}, multi_inner ->
        Multi.insert(multi_inner, name, changeset)
      end)
    end)
  end

  # Converts a CSV row map to a StopTime changeset
  defp stop_time_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    attrs =
      with {:ok, trip_id} <- extract_required(row_map, "trip_id"),
           {:ok, stop_id} <- extract_required(row_map, "stop_id"),
           {:ok, stop_sequence} <- parse_integer(row_map["stop_sequence"]) do
        # Parse optional time fields
        arrival_time =
          case parse_gtfs_time(row_map["arrival_time"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        departure_time =
          case parse_gtfs_time(row_map["departure_time"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        # Parse optional integer fields
        pickup_type =
          case parse_integer(row_map["pickup_type"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        drop_off_type =
          case parse_integer(row_map["drop_off_type"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        continuous_pickup =
          case parse_integer(row_map["continuous_pickup"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        continuous_drop_off =
          case parse_integer(row_map["continuous_drop_off"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        timepoint =
          case parse_integer(row_map["timepoint"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        # Parse optional decimal field
        shape_dist_traveled =
          case parse_decimal(row_map["shape_dist_traveled"]) do
            {:ok, value} -> value
            {:error, _} -> nil
          end

        %{
          trip_id: trip_id,
          stop_id: stop_id,
          stop_sequence: stop_sequence,
          arrival_time: arrival_time,
          departure_time: departure_time,
          stop_headsign: empty_to_nil(row_map["stop_headsign"]),
          pickup_type: pickup_type,
          drop_off_type: drop_off_type,
          continuous_pickup: continuous_pickup,
          continuous_drop_off: continuous_drop_off,
          shape_dist_traveled: shape_dist_traveled,
          timepoint: timepoint,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        }
      else
        {:error, _reason} ->
          %{
            trip_id: row_map["trip_id"] || "",
            stop_id: row_map["stop_id"] || "",
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }
      end

    Gtfs.StopTime.changeset(%Gtfs.StopTime{}, attrs)
  end

end
