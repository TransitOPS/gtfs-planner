defmodule Mix.Tasks.Gtfs.ImportStops do
  @moduledoc """
  Import GTFS stops.txt data into the database.

  ## Usage

      mix gtfs.import_stops <organization_id> <path/to/stops.txt>

  ## Arguments

  - `organization_id`: UUID of the organization
  - `file_path`: Path to the stops.txt CSV file

  ## Examples

      mix gtfs.import_stops 123e4567-e89b-12d3-a456-426614174000 /path/to/stops.txt

  ## CSV Format

  The stops.txt file must follow GTFS specification with header row.
  Required fields: stop_id
  Optional fields: stop_name, stop_desc, platform_code, stop_lat, stop_lon,
                   location_type, wheelchair_boarding, level_id, parent_station
  """
  use Mix.Task

  @shortdoc "Import GTFS stops.txt data"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case parse_args(args) do
      {:ok, organization_id, file_path} ->
        import_stops(organization_id, file_path)

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        Mix.shell().info(@moduledoc)
        System.halt(1)
    end
  end

  # Step 2: Implement argument parsing
  defp parse_args([organization_id, file_path]) do
    with {:ok, org_uuid} <- validate_uuid(organization_id),
         :ok <- validate_file(file_path) do
      {:ok, org_uuid, file_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_args(_) do
    {:error, "Expected 2 arguments: organization_id, file_path"}
  end

  defp validate_uuid(string) do
    case Ecto.UUID.cast(string) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "Invalid UUID: #{string}"}
    end
  end

  defp validate_file(file_path) do
    if File.exists?(file_path) do
      :ok
    else
      {:error, "File not found: #{file_path}"}
    end
  end

  # Step 3: Create main import function
  defp import_stops(organization_id, file_path) do
    Mix.shell().info("Starting import of #{file_path}")
    Mix.shell().info("Organization: #{organization_id}")

    # Get the latest GTFS version for this organization
    case GtfsPlanner.Versions.get_latest_gtfs_version(organization_id) do
      {:ok, gtfs_version} ->
        Mix.shell().info("GTFS Version: #{gtfs_version.id} (#{gtfs_version.name})")
        do_import_stops(organization_id, gtfs_version.id, file_path)

      {:error, :no_versions} ->
        Mix.shell().error("Error: No GTFS versions found for organization #{organization_id}")
        Mix.shell().info("Please create a GTFS version first using the web interface or API.")
        System.halt(1)
    end
  end

  defp do_import_stops(organization_id, gtfs_version_id, file_path) do
    try do
      stream = parse_csv_file(file_path)

      {total, success, failure} =
        stream
        |> Enum.reduce({0, 0, 0}, fn row_map, {total, success, failure} ->
          case process_row(row_map, organization_id, gtfs_version_id) do
            {:ok, stop} ->
              Mix.shell().info("  ✓ Created stop: #{stop.stop_id}")
              {total + 1, success + 1, failure}

            {:error, changeset} ->
              errors = Enum.map(changeset.errors, fn {field, {msg, _}} -> "#{field}: #{msg}" end)
              Mix.shell().error("  ✗ Failed to create stop #{row_map["stop_id"] || "unknown"}: #{Enum.join(errors, ", ")}")
              {total + 1, success, failure + 1}
          end
        end)

      Mix.shell().info("")
      Mix.shell().info("Import complete:")
      Mix.shell().info("  Total rows: #{total}")
      Mix.shell().info("  Success: #{success}")
      Mix.shell().info("  Failure: #{failure}")

      if success == 0 do
        System.halt(1)
      else
        :ok
      end
    rescue
      error in File.Error ->
        Mix.shell().error("File error: #{error.reason}")
        System.halt(1)
    end
  end

  # Step 4: Implement header-aware CSV parsing
  defp parse_csv_file(file_path) do
    file_path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.filter(&(&1 != ""))
    |> Stream.transform({:no_header, nil}, fn
      line, {:no_header, nil} ->
        # First line is header
        case parse_csv_line(line) do
          {:ok, header} ->
            {[], {:has_header, header}}

          {:error, reason} ->
            Mix.shell().error("  ⚠ Failed to parse header: #{reason}")
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

          {:ok, fields} ->
            Mix.shell().error("  ⚠ Skipping malformed line: expected #{length(header)} fields, got #{length(fields)}")
            {[], {:has_header, header}}

          {:error, reason} ->
            Mix.shell().error("  ⚠ Skipping malformed line: #{reason}")
            {[], {:has_header, header}}
        end
    end)
    |> Stream.filter(fn
      row_map when is_map(row_map) -> true
      _ -> false
    end)
  end

  defp parse_csv_line(line) do
    parse_csv_fields(line)
  end

  # Reuse CSV parsing from import_levels
  defp parse_csv_fields(line) do
    parse_csv_fields(line, [], "", false, 0)
  end

  defp parse_csv_fields("", fields, current, _in_quotes, _pos) do
    {:ok, Enum.reverse([current | fields])}
  end

  defp parse_csv_fields(<<char::utf8, rest::binary>>, fields, current, in_quotes, pos) do
    case {char, in_quotes} do
      {?", false} ->
        parse_csv_fields(rest, fields, current, true, pos + 1)

      {?", true} ->
        case rest do
          <<?", rest2::binary>> ->
            parse_csv_fields(rest2, fields, current <> <<?">>, true, pos + 2)
          _ ->
            parse_csv_fields(rest, fields, current, false, pos + 1)
        end

      {44, false} ->
        parse_csv_fields(rest, [current | fields], "", false, pos + 1)

      {char, true} ->
        parse_csv_fields(rest, fields, current <> <<char>>, true, pos + 1)

      {char, false} ->
        parse_csv_fields(rest, fields, current <> <<char>>, false, pos + 1)
    end
  end

  # Step 5: Create row processing function
  defp process_row(row_map, organization_id, gtfs_version_id) do
    with {:ok, stop_id} <- extract_required(row_map, "stop_id"),
         {:ok, stop_lat} <- parse_decimal(row_map["stop_lat"]),
         {:ok, stop_lon} <- parse_decimal(row_map["stop_lon"]),
         {:ok, location_type} <- parse_location_type(row_map["location_type"]),
         {:ok, wheelchair_boarding} <- parse_wheelchair_boarding(row_map["wheelchair_boarding"]),
         {:ok, level_id} <- resolve_level_id(row_map["level_id"], organization_id, gtfs_version_id),
         {:ok, parent_station_id} <- resolve_parent_station_id(row_map["parent_station"], organization_id, gtfs_version_id) do
      attrs = %{
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

      GtfsPlanner.Gtfs.create_stop(attrs)
    else
      {:error, reason} ->
        {:error, %Ecto.Changeset{errors: [stop_id: {reason, []}]}}
    end
  end

  defp extract_required(row_map, field) do
    case row_map[field] do
      nil -> {:error, "missing required field: #{field}"}
      "" -> {:error, "empty required field: #{field}"}
      value -> {:ok, value}
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(value), do: value

  # Step 10: Add comprehensive error handling for type conversions
  # Updated to handle ArgumentError as suggested by Copilot
  defp parse_decimal(nil), do: {:ok, nil}
  defp parse_decimal(""), do: {:ok, nil}
  defp parse_decimal(string) do
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

  defp parse_location_type(nil), do: {:ok, 0}
  defp parse_location_type(""), do: {:ok, 0}
  defp parse_location_type(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..4 -> {:ok, int}
      {int, ""} -> {:error, "location_type out of range 0-4: #{int}"}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid location_type: #{string}"}
  end

  defp parse_wheelchair_boarding(nil), do: {:ok, nil}
  defp parse_wheelchair_boarding(""), do: {:ok, nil}
  defp parse_wheelchair_boarding(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..2 -> {:ok, int}
      {int, ""} -> {:error, "wheelchair_boarding out of range 0-2: #{int}"}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid wheelchair_boarding: #{string}"}
  end

  # Step 6: Implement foreign key resolution for level_id
  defp resolve_level_id(nil, _organization_id, _gtfs_version_id), do: {:ok, nil}
  defp resolve_level_id("", _organization_id, _gtfs_version_id), do: {:ok, nil}
  defp resolve_level_id(level_id_string, organization_id, gtfs_version_id) do
    case GtfsPlanner.Gtfs.get_level_by_level_id(organization_id, gtfs_version_id, level_id_string) do
      nil ->
        Mix.shell().info("  ⚠ Level not found: #{level_id_string}, setting level_id to nil")
        {:ok, nil}
      level ->
        {:ok, level.id}
    end
  end

  # Step 7: Implement foreign key resolution for parent_station
  defp resolve_parent_station_id(nil, _organization_id, _gtfs_version_id), do: {:ok, nil}
  defp resolve_parent_station_id("", _organization_id, _gtfs_version_id), do: {:ok, nil}
  defp resolve_parent_station_id(parent_station_string, organization_id, gtfs_version_id) do
    case GtfsPlanner.Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, parent_station_string) do
      nil ->
        Mix.shell().info("  ⚠ Parent station not found: #{parent_station_string}, setting parent_station_id to nil")
        {:ok, nil}
      stop ->
        {:ok, stop.id}
    end
  end
end
