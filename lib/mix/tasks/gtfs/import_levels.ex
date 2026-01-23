defmodule Mix.Tasks.Gtfs.ImportLevels do
  @moduledoc """
  Import GTFS levels.txt data into the database.

  ## Usage

      mix gtfs.import_levels <organization_id> <path/to/levels.txt>

  ## Arguments

  - `organization_id`: UUID of the organization
  - `file_path`: Path to the levels.txt CSV file

  ## Examples

      mix gtfs.import_levels 123e4567-e89b-12d3-a456-426614174000 /path/to/levels.txt

  ## CSV Format

  The levels.txt file must follow GTFS specification:
  - Required fields: level_id, level_index
  - Optional fields: level_name
  - Header row is expected and skipped
  """
  use Mix.Task

  @shortdoc "Import GTFS levels.txt data"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case parse_args(args) do
      {:ok, organization_id, file_path} ->
        import_levels(organization_id, file_path)

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        Mix.shell().info(@moduledoc)
        System.halt(1)
    end
  end

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

  defp import_levels(organization_id, file_path) do
    Mix.shell().info("Starting import of #{file_path}")
    Mix.shell().info("Organization: #{organization_id}")

    # Get the latest GTFS version for this organization
    case GtfsPlanner.Versions.get_latest_gtfs_version(organization_id) do
      {:ok, gtfs_version} ->
        Mix.shell().info("GTFS Version: #{gtfs_version.id} (#{gtfs_version.name})")
        do_import_levels(organization_id, gtfs_version.id, file_path)

      {:error, :no_versions} ->
        Mix.shell().error("Error: No GTFS versions found for organization #{organization_id}")
        Mix.shell().info("Please create a GTFS version first using the web interface or API.")
        System.halt(1)
    end
  end

  defp do_import_levels(organization_id, gtfs_version_id, file_path) do
    stream = parse_csv_file(file_path)

    {total, success, failure} =
      stream
      |> Enum.reduce({0, 0, 0}, fn row_data, {total, success, failure} ->
        case process_row(row_data, organization_id, gtfs_version_id) do
          {:ok, level} ->
            Mix.shell().info("  ✓ Created level: #{level.level_id}")
            {total + 1, success + 1, failure}

          {:error, changeset} ->
            # Improved error formatting to match stops importer style
            errors = Enum.map(changeset.errors, fn {field, {msg, _}} -> "#{field}: #{msg}" end)
            level_id = if row_data, do: row_data[:level_id] || "unknown", else: "unknown"
            Mix.shell().error("  ✗ Failed to create level #{level_id}: #{Enum.join(errors, ", ")}")
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
  end

  defp parse_csv_file(file_path) do
    file_path
    |> File.stream!()
    |> Stream.drop(1) # Skip header
    |> Stream.map(&String.trim/1)
    |> Stream.filter(&(&1 != ""))
    |> Stream.map(&parse_csv_line/1)
    |> Stream.filter(& &1)
  end

  defp parse_csv_line(line) do
    case parse_csv_fields(line) do
      {:ok, fields} ->
        # Handle rows with insufficient fields
        case fields do
          [level_id, level_index_str | rest] ->
            level_name =
              case rest do
                [name | _] -> if name == "", do: nil, else: String.trim(name, "\"")
                [] -> nil
              end

            %{
              level_id: String.trim(level_id, "\""),
              level_index_str: String.trim(level_index_str, "\""),
              level_name: level_name
            }

          _ ->
            Mix.shell().error("  ⚠ Skipping malformed line: expected at least 2 fields, got #{length(fields)}")
            nil
        end

      {:error, reason} ->
        Mix.shell().error("  ⚠ Skipping malformed line: #{reason}")
        nil
    end
  end

  defp parse_csv_fields(line) do
    parse_csv_fields(line, [], "", false, 0)
  end

  defp parse_csv_fields("", fields, current, _in_quotes, _pos) do
    {:ok, Enum.reverse([current | fields])}
  end

  defp parse_csv_fields(<<char::utf8, rest::binary>>, fields, current, in_quotes, pos) do
    case {char, in_quotes} do
      {?", false} ->
        # Start quoted field
        parse_csv_fields(rest, fields, current, true, pos + 1)

      {?", true} ->
        # Check if this is an escaped quote or end of quoted field
        case rest do
          <<?", rest2::binary>> ->
            # Escaped quote: add quote and skip next char
            parse_csv_fields(rest2, fields, current <> <<?">>, true, pos + 2)
          _ ->
            # End of quoted field
            parse_csv_fields(rest, fields, current, false, pos + 1)
        end

      {44, false} ->
        # End of field (not in quotes) - 44 is ASCII for comma
        parse_csv_fields(rest, [current | fields], "", false, pos + 1)

      {char, true} ->
        # Inside quotes, add any character
        parse_csv_fields(rest, fields, current <> <<char>>, true, pos + 1)

      {char, false} ->
        # Regular character outside quotes
        parse_csv_fields(rest, fields, current <> <<char>>, false, pos + 1)
    end
  end

  defp process_row(%{level_id: level_id, level_index_str: level_index_str, level_name: level_name},
        organization_id, gtfs_version_id) do
    with {:ok, level_index} <- parse_float(level_index_str) do
      attrs = %{
        level_id: level_id,
        level_index: level_index,
        level_name: level_name,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      }

      GtfsPlanner.Gtfs.create_level(attrs)
    else
      {:error, reason} ->
        {:error, %Ecto.Changeset{errors: [level_index: {reason, []}]}}
    end
  end

  defp parse_float(string) do
    case Float.parse(string) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "invalid float: #{string}"}
    end
  end
end
