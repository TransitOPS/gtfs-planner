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
        {:ok, %{levels: 5, stops: 20, pathways: 15}} ->
          # Import successful
        {:error, reason} ->
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

    - `{:ok, %{levels: n, stops: n, pathways: n}}` on success with record counts
    - `{:error, reason}` on failure (transaction is rolled back)

  ## Examples

      iex> files = [%{filename: "levels.txt", content: "level_id,level_name\\nL1,Ground"}]
      iex> import_files(org_id, version_id, files)
      {:ok, %{levels: 1, stops: 0, pathways: 0}}
  """
  def import_files(organization_id, gtfs_version_id, files) do
    # Categorize files by filename (case-insensitive)
    {categorized, unrecognized_files} = categorize_files(files)

    # Build Ecto.Multi transaction processing levels → stops → pathways
    multi =
      Multi.new()
      |> add_level_imports(categorized[:levels] || [], organization_id, gtfs_version_id)
      |> add_stop_imports(categorized[:stops] || [], organization_id, gtfs_version_id)
      |> add_pathway_imports(categorized[:pathways] || [], organization_id, gtfs_version_id)

    # Execute transaction
    case Repo.transaction(multi) do
      {:ok, results} ->
        # Count successful imports per category
        counts = %{
          levels: count_category(results, "level_"),
          stops: count_category(results, "stop_"),
          pathways: results[:pathways] || 0
        }

        {:ok, {counts, unrecognized_files}}

      {:error, failed_operation, failed_value, changes_so_far} ->
        {:error, failed_operation, failed_value, changes_so_far}
    end
  end

  # Categorizes files by filename into :levels, :stops, :pathways buckets
  defp categorize_files(files) do
    initial_acc = {%{levels: [], stops: [], pathways: []}, []}

    {categorized, unrecognized} =
      Enum.reduce(files, initial_acc, fn file, {acc, unrecognized_acc} ->
        case String.downcase(file.filename) do
          "levels.txt" ->
            {Map.update!(acc, :levels, &[file | &1]), unrecognized_acc}

          "stops.txt" ->
            {Map.update!(acc, :stops, &[file | &1]), unrecognized_acc}

          "pathways.txt" ->
            {Map.update!(acc, :pathways, &[file | &1]), unrecognized_acc}

          _ ->
            {acc, [file.filename | unrecognized_acc]}
        end
      end)

    categorized = Map.new(categorized, fn {key, files_list} -> {key, Enum.reverse(files_list)} end)
    {categorized, Enum.reverse(unrecognized)}
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
      Multi.run(multi, :pathways, fn repo, _changes ->
        pathway_rows =
          files
          |> Enum.flat_map(&(&1.content |> parse_csv_content()))

        result =
          Enum.reduce_while(pathway_rows, [], fn row_map, acc ->
            changeset = pathway_row_to_changeset(row_map, organization_id, gtfs_version_id)

            case repo.insert(changeset) do
              {:ok, pathway} -> {:cont, [pathway | acc]}
              {:error, failed_changeset} -> {:halt, {:error, failed_changeset}}
            end
          end)

        case result do
          {:error, failed_changeset} ->
            {:error, failed_changeset}

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
          <<?"::utf8, rest2::binary>> ->
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
  defp pathway_row_to_changeset(row_map, organization_id, gtfs_version_id) do
    attrs =
      with {:ok, pathway_id} <- extract_required(row_map, "pathway_id"),
           {:ok, from_stop_id_str} <- extract_required(row_map, "from_stop_id"),
           {:ok, to_stop_id_str} <- extract_required(row_map, "to_stop_id"),
           {:ok, pathway_mode} <- parse_pathway_mode(row_map["pathway_mode"]),
           {:ok, is_bidirectional} <- parse_is_bidirectional(row_map["is_bidirectional"]),
           {:ok, from_stop} <- resolve_stop_id(from_stop_id_str, organization_id, gtfs_version_id),
           {:ok, to_stop} <- resolve_stop_id(to_stop_id_str, organization_id, gtfs_version_id),
           {:ok, traversal_time} <- parse_integer(row_map["traversal_time"]),
           {:ok, length} <- parse_decimal(row_map["length"]),
           {:ok, stair_count} <- parse_integer(row_map["stair_count"]),
           {:ok, max_slope} <- parse_decimal(row_map["max_slope"]),
           {:ok, min_width} <- parse_decimal(row_map["min_width"]) do
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
        {:error, _reason} ->
          # Invalid data will be caught by changeset validation
          %{
            pathway_id: row_map["pathway_id"] || "",
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

  # Resolves a stop_id string to the Stop struct
  defp resolve_stop_id(stop_id_string, organization_id, gtfs_version_id) do
    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id_string) do
      nil -> {:error, "stop not found: #{stop_id_string}"}
      stop -> {:ok, stop}
    end
  end
end
