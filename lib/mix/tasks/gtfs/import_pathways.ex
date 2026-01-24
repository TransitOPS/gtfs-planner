defmodule Mix.Tasks.Gtfs.ImportPathways do
  @moduledoc """
  Import GTFS pathways.txt data into the database.

  ## Usage

      mix gtfs.import_pathways <organization_id> <path/to/pathways.txt>

  ## Arguments

  - `organization_id`: UUID of the organization
  - `file_path`: Path to the pathways.txt CSV file

  ## Examples

      mix gtfs.import_pathways 123e4567-e89b-12d3-a456-426614174000 /path/to/pathways.txt

  ## CSV Format

  The pathways.txt file must follow GTFS specification with header row.
  Required fields: pathway_id, from_stop_id, to_stop_id, pathway_mode, is_bidirectional
  Optional fields: traversal_time, length, stair_count, max_slope, min_width,
                   signposted_as, reversed_signposted_as
  """
  use Mix.Task

  @shortdoc "Import GTFS pathways.txt data"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case parse_args(args) do
      {:ok, organization_id, file_path} ->
        import_pathways(organization_id, file_path)

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

  defp import_pathways(organization_id, file_path) do
    Mix.shell().info("Starting import of #{file_path}")
    Mix.shell().info("Organization: #{organization_id}")

    case GtfsPlanner.Versions.get_latest_gtfs_version(organization_id) do
      {:ok, gtfs_version} ->
        Mix.shell().info("GTFS Version: #{gtfs_version.id} (#{gtfs_version.name})")
        do_import_pathways(organization_id, gtfs_version.id, file_path)

      {:error, :no_versions} ->
        Mix.shell().error("Error: No GTFS versions found for organization #{organization_id}")
        Mix.shell().info("Please create a GTFS version first using the web interface or API.")
        System.halt(1)
    end
  end

  defp do_import_pathways(organization_id, gtfs_version_id, file_path) do
    try do
      stream = parse_csv_file(file_path)

      multi =
        stream
        |> Stream.with_index()
        |> Enum.reduce(Ecto.Multi.new(), fn {row_map, index}, multi ->
          case row_to_attrs(row_map, organization_id, gtfs_version_id) do
            {:ok, attrs} ->
              changeset = GtfsPlanner.Gtfs.Pathway.changeset(%GtfsPlanner.Gtfs.Pathway{}, attrs)
              Ecto.Multi.insert(multi, "pathway_#{index}", changeset)

            {:error, reason} ->
              raise "Row #{index + 1}: #{reason}"
          end
        end)

      case GtfsPlanner.Repo.transaction(multi) do
        {:ok, _results} ->
          log_success("Successfully imported #{map_size(multi.operations)} pathways")
          :ok

        {:error, operation, changeset, _changes_so_far} ->
          errors = Enum.map(changeset.errors, fn {field, {msg, _}} -> "#{field}: #{msg}" end)

          log_error(
            "Failed to import pathway at operation #{operation}: #{Enum.join(errors, ", ")}"
          )

          System.halt(1)
      end
    rescue
      error in RuntimeError ->
        log_error(error.message)
        System.halt(1)

      error in File.Error ->
        log_error("File error: #{error.reason}")
        System.halt(1)
    end
  end

  defp parse_csv_file(file_path) do
    file_path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.filter(&(&1 != ""))
    |> Stream.transform({:no_header, nil}, fn
      line, {:no_header, nil} ->
        case parse_csv_line(line) do
          {:ok, header} ->
            {[], {:has_header, header}}

          {:error, reason} ->
            Mix.shell().error("  ⚠ Failed to parse header: #{reason}")
            {[], {:has_header, []}}
        end

      _line, {:has_header, header} when header == [] ->
        {[], {:has_header, []}}

      line, {:has_header, header} ->
        case parse_csv_line(line) do
          {:ok, fields} when length(fields) == length(header) ->
            row_map = Enum.zip(header, fields) |> Map.new()
            {[row_map], {:has_header, header}}

          {:ok, fields} ->
            Mix.shell().error(
              "  ⚠ Skipping malformed line: expected #{length(header)} fields, got #{length(fields)}"
            )

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

  defp row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, pathway_id} <- extract_required(row_map, "pathway_id"),
         {:ok, from_stop_id} <- extract_required(row_map, "from_stop_id"),
         {:ok, to_stop_id} <- extract_required(row_map, "to_stop_id"),
         {:ok, pathway_mode} <- parse_pathway_mode(row_map["pathway_mode"]),
         {:ok, is_bidirectional} <- parse_is_bidirectional(row_map["is_bidirectional"]),
         {:ok, from_stop} <- resolve_stop_id(from_stop_id, organization_id, gtfs_version_id),
         {:ok, to_stop} <- resolve_stop_id(to_stop_id, organization_id, gtfs_version_id),
         {:ok, traversal_time} <- parse_integer(row_map["traversal_time"]),
         {:ok, length} <- parse_decimal(row_map["length"]),
         {:ok, stair_count} <- parse_integer(row_map["stair_count"]),
         {:ok, max_slope} <- parse_decimal(row_map["max_slope"]),
         {:ok, min_width} <- parse_decimal(row_map["min_width"]) do
      attrs = %{
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

      {:ok, attrs}
    else
      {:error, reason} -> {:error, reason}
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

  defp parse_pathway_mode(nil), do: {:error, "pathway_mode is required"}
  defp parse_pathway_mode(""), do: {:error, "pathway_mode is required"}

  defp parse_pathway_mode(string) do
    case Integer.parse(string) do
      {int, ""} when int in 1..7 -> {:ok, int}
      {int, ""} -> {:error, "pathway_mode out of range 1-7: #{int}"}
      _ -> {:error, "invalid pathway_mode: #{string}"}
    end
  rescue
    _ -> {:error, "invalid pathway_mode: #{string}"}
  end

  defp parse_is_bidirectional(nil), do: {:ok, true}
  defp parse_is_bidirectional(""), do: {:ok, true}
  defp parse_is_bidirectional("1"), do: {:ok, true}
  defp parse_is_bidirectional("0"), do: {:ok, false}

  defp parse_is_bidirectional(string) do
    case String.downcase(string) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "invalid is_bidirectional: #{string}"}
    end
  end

  defp parse_integer(nil), do: {:ok, nil}
  defp parse_integer(""), do: {:ok, nil}

  defp parse_integer(string) do
    case Integer.parse(string) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid integer: #{string}"}
  end

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

  defp resolve_stop_id(stop_id_string, organization_id, gtfs_version_id) do
    case GtfsPlanner.Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id_string) do
      nil -> {:error, "stop not found: #{stop_id_string}"}
      stop -> {:ok, stop}
    end
  end

  defp log_success(message) do
    Mix.shell().info([IO.ANSI.green(), "✓ ", message, IO.ANSI.reset()])
  end

  defp log_error(message) do
    Mix.shell().error([IO.ANSI.red(), "✗ ", message, IO.ANSI.reset()])
  end
end
