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
  - Reads every GTFS file from one repeatable-read database snapshot

  ## Export Types

  - `:full` - All GTFS files (agency, stops, routes, trips, etc.)
  - `:pathways` - Pathways subset (stops, levels, pathways only)
  - `:operations` - The full GTFS files plus the TODS `stops_supplement.txt` and
    `vehicles.txt` files, with omission warnings and a garage/stop ID collision
    check
  """

  alias GtfsPlanner.Gtfs.Export.{CsvWriter, FileSpec, Snapshot, StreamBuilder}
  alias GtfsPlanner.Gtfs.Extensions
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Repo

  require Logger

  @type warning :: %{
          code: String.t(),
          detail: String.t(),
          file: String.t(),
          entity_type: String.t()
        }

  @doc """
  Exports GTFS data to a ZIP archive binary.

  ## Parameters

  - `organization_id` - UUID of the organization
  - `gtfs_version_id` - UUID of the GTFS version to export
  - `export_type` - `:full`, `:pathways` or `:operations`
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
    case build_zip(organization_id, gtfs_version_id, export_type) do
      {:ok, zip_binary, _warnings} -> {:ok, zip_binary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exports GTFS data to a ZIP archive binary and returns its export warnings.

  `:full` and `:pathways` take the unchanged export path and return `[]`
  warnings. `:operations` adds the TODS `stops_supplement.txt` and
  `vehicles.txt` files to the unchanged full export:

  1. the organization's garages and vehicles are loaded once;
  2. their garage IDs are checked against the exported version's `stops.stop_id`
     and a collision rolls back before any file is written;
  3. the full file specs are exported, checking every stop record actually
     written against the loaded garage IDs so a collision that appears after the
     preliminary check cannot reach a ZIP;
  4. the TODS files are written from the same loaded rows;
  5. each TODS file whose table is empty is omitted with a `tods_file_omitted`
     warning.

  ## Returns

  - `{:ok, zip_binary, warnings}` on success
  - `{:error, :no_data}` for a version without GTFS records
  - `{:error, {:garage_stop_id_conflict, conflicts}}` when a garage ID equals an
    emitted `stop_id`; no ZIP is produced
  """
  @spec build_zip(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways | :operations) ::
          {:ok, binary(), [warning()]}
          | {:error, :no_data | {:garage_stop_id_conflict, [Operations.conflict()]} | term()}
  def build_zip(organization_id, gtfs_version_id, export_type) do
    # Generate unique temp directory
    temp_dir = generate_temp_dir()

    try do
      # Create temp directory
      File.mkdir_p!(temp_dir)

      # Export every file from one read snapshot
      result =
        with_read_snapshot(fn ->
          build_export(temp_dir, organization_id, gtfs_version_id, export_type)
        end)

      case result do
        {:ok, {zip_binary, warnings}} -> {:ok, zip_binary, warnings}
        {:error, reason} -> {:error, reason}
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

  @doc """
  Exports selected GTFS file specs to an existing output directory.

  This is a disk-targeted export path used by OTP materialization workflows.

  ## Parameters

  - `organization_id` - UUID of the organization
  - `gtfs_version_id` - UUID of the GTFS version to export
  - `file_specs` - List of GTFS file specs to export
  - `output_dir` - Target directory for generated `*.txt` files

  ## Returns

  - `{:ok, file_paths}` - List of written file paths
  - `{:error, reason}` - Error tuple with reason
  """
  @spec export_specs_to_directory(Ecto.UUID.t(), Ecto.UUID.t(), [map()], String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def export_specs_to_directory(organization_id, gtfs_version_id, file_specs, output_dir)
      when is_list(file_specs) and is_binary(output_dir) do
    try do
      File.mkdir_p!(output_dir)

      with_read_snapshot(fn ->
        lookup_maps = build_lookup_maps(organization_id, gtfs_version_id)

        {file_paths, _conflicts} =
          export_files(output_dir, file_specs, organization_id, gtfs_version_id, lookup_maps)

        file_paths
      end)
    rescue
      e ->
        Logger.error("GTFS disk export failed: #{inspect(e)}")
        {:error, "Export failed: #{Exception.message(e)}"}
    end
  end

  # Builds the export inside its read snapshot. The operations path keeps the
  # public files untouched and adds the TODS files beside them.
  defp build_export(temp_dir, organization_id, gtfs_version_id, :operations) do
    %{garages: garages, vehicles: vehicles} = Operations.tods_export_rows(organization_id)

    conflict_rollback(
      Operations.garage_stop_id_conflicts(organization_id, gtfs_version_id, garages)
    )

    garage_map = Map.new(garages, &{&1.garage_id, &1.name})

    {file_paths, emitted_conflicts} =
      export_files(
        temp_dir,
        FileSpec.get_specs(:full),
        organization_id,
        gtfs_version_id,
        %{},
        garage_map
      )

    conflict_rollback(emitted_conflicts)

    file_paths = file_paths ++ export_tods_files(temp_dir, garages, vehicles)

    zip_binary = create_zip_archive(file_paths, organization_id, gtfs_version_id)

    {zip_binary, tods_omission_warnings(garages, vehicles)}
  end

  defp build_export(temp_dir, organization_id, gtfs_version_id, export_type) do
    {file_paths, _conflicts} =
      export_files(
        temp_dir,
        FileSpec.get_specs(export_type),
        organization_id,
        gtfs_version_id,
        %{}
      )

    {create_zip_archive(file_paths, organization_id, gtfs_version_id), []}
  end

  defp conflict_rollback([]), do: :ok
  defp conflict_rollback(conflicts), do: Repo.rollback({:garage_stop_id_conflict, conflicts})

  # Runs the whole GTFS read inside one transaction whose snapshot is established
  # before the first query, so route patterns, trips and stop times describe a
  # single committed revision. A caller-owned transaction cannot change its own
  # isolation (for example the SQL sandbox), so the boundary owns the decision.
  defp with_read_snapshot(fun) do
    Repo.transaction(
      fn ->
        snapshot_module().begin_read()
        fun.()
      end,
      timeout: :infinity
    )
  end

  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_export_snapshot, Snapshot.Repo)
  end

  # Generates unique temporary directory path
  defp generate_temp_dir do
    unique_id = :erlang.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "gtfs_export_#{unique_id}")
  end

  # Builds lookup maps for foreign key resolution
  defp build_lookup_maps(_organization_id, _gtfs_version_id) do
    %{}
  end

  # Exports all files for the given specs. Returns the written file paths and the
  # garage/stop collisions seen in the records actually written, ordered by
  # garage ID. `garage_map` holds the organization's garage IDs and names; it is
  # empty for exports that check no collisions.
  defp export_files(
         temp_dir,
         file_specs,
         organization_id,
         gtfs_version_id,
         lookup_maps,
         garage_map \\ %{}
       ) do
    specs =
      Enum.filter(file_specs, fn spec ->
        has_records?(spec.schema, organization_id, gtfs_version_id)
      end)

    if Enum.empty?(specs) do
      Repo.rollback(:no_data)
    else
      results =
        Enum.map(specs, fn spec ->
          export_file(temp_dir, spec, organization_id, gtfs_version_id, lookup_maps, garage_map)
        end)

      file_paths = Enum.map(results, &elem(&1, 0))
      conflicts = results |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort_by(& &1.garage_id)

      {file_paths, conflicts}
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

  # Exports a single GTFS file and returns its path with the garage/stop
  # collisions among the records it wrote. The garage map is checked against the
  # exact streamed stop records, so a stop ID that changed after the preliminary
  # conflict query is still caught before any ZIP can be returned.
  defp export_file(temp_dir, spec, organization_id, gtfs_version_id, lookup_maps, garage_map) do
    file_path = Path.join(temp_dir, spec.filename)
    file = File.open!(file_path, [:write, :utf8])

    try do
      # Write CSV header
      CsvWriter.write_header(file, spec)

      # Stream and write records
      conflicts =
        StreamBuilder.stream_records(Repo, spec.schema, organization_id, gtfs_version_id)
        |> Enum.reduce([], fn record, acc ->
          CsvWriter.write_row(file, record, spec, lookup_maps)
          collect_garage_conflict(acc, record, garage_map)
        end)

      {file_path, conflicts}
    after
      File.close(file)
    end
  end

  # Keeps only the garages whose ID is written as a stop ID, using that stop's
  # name. Other records never match the garage IDs.
  defp collect_garage_conflict(conflicts, %Stop{} = stop, garage_map) do
    case Map.fetch(garage_map, stop.stop_id) do
      {:ok, garage_name} ->
        [
          %{garage_id: stop.stop_id, garage_name: garage_name, stop_name: stop.stop_name}
          | conflicts
        ]

      :error ->
        conflicts
    end
  end

  defp collect_garage_conflict(conflicts, _record, _garage_map), do: conflicts

  # Writes the TODS files whose table is not empty and returns their paths.
  defp export_tods_files(temp_dir, garages, vehicles) do
    [
      {Tods.stops_supplement_spec(), garages, &Tods.garage_export_row/1},
      {Tods.vehicles_spec(), vehicles, &Tods.vehicle_export_row/1}
    ]
    |> Enum.reject(fn {_spec, rows, _mapper} -> rows == [] end)
    |> Enum.map(fn {spec, rows, mapper} ->
      write_tods_file(temp_dir, spec, Enum.map(rows, mapper))
    end)
  end

  defp write_tods_file(temp_dir, spec, rows) do
    file_path = Path.join(temp_dir, spec.filename)
    file = File.open!(file_path, [:write, :utf8])

    try do
      CsvWriter.write_header(file, spec)
      Enum.each(rows, &CsvWriter.write_row(file, &1, spec, %{}))
      file_path
    after
      File.close(file)
    end
  end

  # An empty table omits its file rather than exporting an empty one.
  defp tods_omission_warnings(garages, vehicles) do
    [
      {Tods.stops_supplement_spec().filename, garages, "garage", "garages"},
      {Tods.vehicles_spec().filename, vehicles, "vehicle", "vehicles"}
    ]
    |> Enum.reject(fn {_filename, rows, _entity_type, _label} -> rows != [] end)
    |> Enum.map(fn {filename, _rows, entity_type, label} ->
      %{
        code: "tods_file_omitted",
        detail: "#{filename} was not included because this organization has no #{label}.",
        file: filename,
        entity_type: entity_type
      }
    end)
  end

  # Creates ZIP archive from file paths and returns binary
  defp create_zip_archive(file_paths, organization_id, gtfs_version_id) do
    # Convert file paths to charlist tuples for :zip.create
    files =
      Enum.map(file_paths, fn path ->
        filename = Path.basename(path) |> String.to_charlist()
        file_content = File.read!(path)
        {filename, file_content}
      end)

    # Append extensions entries (diagram coordinates, stop levels, route flags, images)
    files = files ++ extensions_zip_entries(organization_id, gtfs_version_id)

    # Create ZIP in memory, with explicit error handling
    case :zip.create(~c"gtfs.zip", files, [:memory]) do
      {:ok, {_zip_name, zip_binary}} ->
        zip_binary

      {:error, reason} ->
        raise "Failed to create GTFS ZIP archive: #{inspect(reason)}"
    end
  end

  defp extensions_zip_entries(organization_id, gtfs_version_id) do
    {:ok, entries} = Extensions.Export.build_zip_entries(organization_id, gtfs_version_id)
    entries
  rescue
    e ->
      Logger.warning(
        "Extensions export failed, continuing without extensions: #{Exception.message(e)}"
      )

      []
  end
end
