defmodule GtfsPlanner.Gtfs.Export do
  @moduledoc """
  Context module for exporting GTFS data to ZIP archives.

  Provides memory-safe streaming export of GTFS data from the database
  to standards-compliant CSV files packaged in a ZIP archive.

  ## Features

  - Streams database records in batches to avoid memory exhaustion
  - Writes GTFS-compliant CSV files with proper escaping
  - Resolves UUID foreign keys to GTFS string identifiers
  - Creates ZIP archives using Erlang's `:zip` module
  - Runs within database transaction for consistent snapshot

  ## Export Types

  - `:full` - All GTFS files (agency, stops, routes, trips, etc.)
  - `:pathways` - Pathways subset (stops, levels, pathways only)
  """

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Export.{FileSpec, CsvWriter, StreamBuilder}

  require Logger

  @doc """
  Exports GTFS data to a ZIP archive binary.

  ## Parameters

  - `organization_id` - UUID of the organization
  - `gtfs_version_id` - UUID of the GTFS version to export
  - `export_type` - Either `:full` or `:pathways`
  - `opts` - Optional keyword list (reserved for future use)

  ## Returns

  - `{:ok, zip_binary}` - ZIP file as binary
  - `{:error, reason}` - Error tuple with reason

  ## Examples

      Export.export_to_zip(org_id, version_id, :pathways)
      # => {:ok, <<binary zip data>>}

      Export.export_to_zip(org_id, version_id, :full)
      # => {:ok, <<binary zip data>>}
  """
  def export_to_zip(organization_id, gtfs_version_id, export_type, _opts \\ []) do
    # Generate unique temp directory
    temp_dir = generate_temp_dir()

    try do
      # Create temp directory
      File.mkdir_p!(temp_dir)

      # Build lookup maps for foreign key resolution
      lookup_maps = build_lookup_maps(organization_id, gtfs_version_id)

      # Get file specifications for export type
      file_specs = FileSpec.get_specs(export_type)

      # Export within transaction for consistent snapshot
      result =
        Repo.transaction(
          fn ->
            export_files(temp_dir, file_specs, organization_id, gtfs_version_id, lookup_maps)
          end,
          timeout: :infinity
        )

      case result do
        {:ok, file_paths} ->
          # Create ZIP from exported files
          zip_binary = create_zip_archive(file_paths)
          {:ok, zip_binary}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("GTFS export failed: #{inspect(e)}")
        {:error, "Export failed: #{Exception.message(e)}"}
    after
      # Always clean up temp directory
      File.rm_rf(temp_dir)
    end
  end

  # Generates unique temporary directory path
  defp generate_temp_dir do
    unique_id = :erlang.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "gtfs_export_#{unique_id}")
  end

  # Builds lookup maps for foreign key resolution
  defp build_lookup_maps(organization_id, gtfs_version_id) do
    %{
      stop: StreamBuilder.build_stop_lookup(Repo, organization_id, gtfs_version_id),
      level: StreamBuilder.build_level_lookup(Repo, organization_id, gtfs_version_id)
    }
  end

  # Exports all files for the given specs
  defp export_files(temp_dir, file_specs, organization_id, gtfs_version_id, lookup_maps) do
    file_paths =
      file_specs
      |> Enum.filter(fn spec ->
        has_records?(spec.schema, organization_id, gtfs_version_id)
      end)
      |> Enum.map(fn spec ->
        export_file(temp_dir, spec, organization_id, gtfs_version_id, lookup_maps)
      end)

    if Enum.empty?(file_paths) do
      Repo.rollback(:no_data)
    else
      file_paths
    end
  end

  # Checks if schema has any records for the given org/version
  defp has_records?(schema, organization_id, gtfs_version_id) do
    import Ecto.Query

    schema
    |> where([s], s.organization_id == ^organization_id)
    |> where([s], s.gtfs_version_id == ^gtfs_version_id)
    |> Repo.exists?()
  end

  # Exports a single GTFS file
  defp export_file(temp_dir, spec, organization_id, gtfs_version_id, lookup_maps) do
    file_path = Path.join(temp_dir, spec.filename)
    file = File.open!(file_path, [:write, :utf8])

    try do
      # Write CSV header
      CsvWriter.write_header(file, spec)

      # Stream and write records
      StreamBuilder.stream_records(Repo, spec.schema, organization_id, gtfs_version_id)
      |> Enum.each(fn record ->
        CsvWriter.write_row(file, record, spec, lookup_maps)
      end)

      file_path
    after
      File.close(file)
    end
  end

  # Creates ZIP archive from file paths and returns binary
  defp create_zip_archive(file_paths) do
    # Convert file paths to charlist tuples for :zip.create
    files =
      Enum.map(file_paths, fn path ->
        filename = Path.basename(path) |> String.to_charlist()
        file_content = File.read!(path)
        {filename, file_content}
      end)

    # Create ZIP in memory, with explicit error handling
    case :zip.create(~c"gtfs.zip", files, [:memory]) do
      {:ok, {_zip_name, zip_binary}} ->
        zip_binary

      {:error, reason} ->
        raise "Failed to create GTFS ZIP archive: #{inspect(reason)}"
    end
  end
end
