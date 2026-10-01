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
  - Doubles the `stop_sequence` of trips on an active detour service's route in
    every `stop_times.txt` it writes (R3, through `Flex.Export.sequence_mapper/2`)
  - Builds the flex zip (fixed routes plus flex rows) beside the main zip from
    the same snapshot when `include_flex` is set and the version has an active
    flex service; a flex build failure leaves the main zip intact

  ## Export Types

  - `:full` - All GTFS files (agency, stops, routes, trips, etc.)
  - `:pathways` - Pathways subset (stops, levels, pathways only)
  - `:operations` - The full GTFS files plus the TODS `stops_supplement.txt` and
    `vehicles.txt` files and the four movement supplements, with omission
    warnings and a garage/stop ID collision check
  - `:flex` - The flex zip alone, as `Validator` validates it (step 18)
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.TodsExport
  alias GtfsPlanner.Gtfs.Export.{CsvWriter, FileSpec, MissingTimes, Snapshot, StreamBuilder}
  alias GtfsPlanner.Gtfs.Extensions
  alias GtfsPlanner.Gtfs.Flex.Export, as: FlexExport
  alias GtfsPlanner.Gtfs.Flex.Export.FileSpecs, as: FlexFileSpecs
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.Rosters
  alias GtfsPlanner.Gtfs.Rosters.AssignmentsExport
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.Runs.TodsExport, as: RunsTodsExport
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  require Logger

  @default_snapshot_timeout_ms 600_000

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
  - `export_type` - `:full`, `:pathways`, `:operations` or `:flex`
  - `opts` - Optional keyword list (reserved for future use)

  ## Returns

  - `{:ok, zip_binary}` - ZIP file as binary
  - `{:error, reason}` - Error tuple with reason

  ## Examples

      Export.export_to_zip(org_id, version_id, :pathways)
      # => {:ok, <<binary zip data>>}

      Export.export_to_zip(org_id, version_id, :full)
      # => {:ok, <<binary zip data>>}

      Export.export_to_zip(org_id, version_id, :flex)
      # => {:ok, <<binary flex zip data>>}
  """
  def export_to_zip(organization_id, gtfs_version_id, export_type, opts \\ [])

  def export_to_zip(organization_id, gtfs_version_id, :flex, opts) do
    case build_zips(organization_id, gtfs_version_id, :full,
           include_flex: true,
           estimate: Keyword.get(opts, :estimate)
         ) do
      {:ok, %{flex: flex}, _warnings} when is_binary(flex) -> {:ok, flex}
      {:ok, %{flex: nil}, _warnings} -> {:error, :no_data}
      {:error, reason} -> {:error, reason}
    end
  end

  def export_to_zip(organization_id, gtfs_version_id, export_type, opts) do
    case build_zip(organization_id, gtfs_version_id, export_type,
           estimate: Keyword.get(opts, :estimate)
         ) do
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

  Every profile's `stop_times.txt` runs the R3 sequence mapper, so a trip on an
  active detour service's route keeps its doubled `stop_sequence` whether or
  not flex is included.

  ## Returns

  - `{:ok, zip_binary, warnings}` on success
  - `{:error, :no_data}` for a version without GTFS records
  - `{:error, {:garage_stop_id_conflict, conflicts}}` when a garage ID equals an
    emitted `stop_id`; no ZIP is produced

  The operations ZIP carries the movements, but never in a public file:
  the four supplement files are written beside `stops_supplement.txt` and
  `vehicles.txt` from `Blocking.TodsExport.rows/1`, over the same snapshot the
  public files were read in. A supplement file with no rows is omitted with a
  `tods_file_omitted` warning, and a movement left out for want of a driving time
  is reported as a `tods_movements_omitted` warning rather than dropped silently.
  """
  @spec build_zip(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways | :operations) ::
          {:ok, binary(), [warning()]}
          | {:error, :no_data | {:garage_stop_id_conflict, [Operations.conflict()]} | term()}
  def build_zip(organization_id, gtfs_version_id, export_type) do
    build_zip(organization_id, gtfs_version_id, export_type, [])
  end

  @doc """
  Builds one ZIP like `build_zip/3` with options.

  `estimate: :distance | :even` fills missing stop times per trip through
  `MissingTimes.fill_trip/3` before the R3 sequence mapper; any other value
  (including the default nil) writes stored rows unchanged. `run_id` is the
  option `build_zips/4` documents.
  """
  @spec build_zip(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways | :operations, keyword()) ::
          {:ok, binary(), [warning()]}
          | {:error, :no_data | {:garage_stop_id_conflict, [Operations.conflict()]} | term()}
  def build_zip(organization_id, gtfs_version_id, export_type, opts) do
    case build_zips(organization_id, gtfs_version_id, export_type,
           include_flex: false,
           estimate: Keyword.get(opts, :estimate),
           run_id: Keyword.get(opts, :run_id)
         ) do
      {:ok, %{main: main}, warnings} when is_binary(main) -> {:ok, main, warnings}
      {:ok, %{main: nil, flex: flex}, warnings} when is_binary(flex) -> {:ok, flex, warnings}
      {:ok, _zips, _warnings} -> {:error, :no_data}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the main zip and, when `include_flex` is set, the flex zip from one
  repeatable-read snapshot.

  The flex zip is the full file set written again with the R3 mapper, the flex
  rows appended to `routes.txt`, `trips.txt`, `stop_times.txt` and
  `booking_rules.txt`, and the extra files `Flex.Export.build_entries/2`
  returns (`locations.geojson`, `location_groups.txt`,
  `location_group_stops.txt`). A service with a readiness error or failed
  derived geometry is left out with a warning and never changes the main zip
  (R4); a version with no fixed routes and at least one exportable flex service
  answers `%{main: nil, flex: zip}` with a `main_feed_not_produced` warning
  (R15). A version without an active flex service answers `flex: nil`, and a
  flex build that raises answers `flex: nil` with a `flex_build_failed` warning
  and the main zip unchanged. Include `include_flex: false` for a main zip only.

  `:operations` keeps its TODS files in the main zip only: the flex zip carries
  the main feed's files plus the flex files.

  `estimate: :distance | :even` fills missing stop times per trip (spec
  23-stop-time-interpolation R8–R9) in every `stop_times.txt` the build writes,
  before the R3 sequence mapper; the main zip carries one
  `missing_times_not_estimated` warning per unfilled trip, last and uncapped
  (the export worker fits them into its 100-entry limit), while the flex zip's
  fixed rows are estimated silently. Any other estimate
  value (including the default nil) writes stored rows unchanged.

  `run_id: id` builds the files under that run's private artifact directory,
  `<root>/export-runs/<organization>/<version>/<run>/.build/`, so
  `ArtifactStorage.reconcile/2` removes what a killed build leaves behind when
  the run is not retained. A build without a run (validation, direct callers)
  has no run directory and writes under the system temporary directory.

  The whole build runs inside `with_read_snapshot/1`, so it shares that
  function's deadline.

  ## Returns

  - `{:ok, %{main: zip | nil, flex: zip | nil}, warnings}` on success
  - `{:error, :snapshot_timeout}` when the snapshot deadline passed
  - `{:error, :artifact_storage_unavailable}` when `run_id` is given and the
    artifact root is not configured or cannot be written
  - `{:error, reason}` for a version with nothing to export or a build failure
  """
  @spec build_zips(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways | :operations, keyword()) ::
          {:ok, %{main: binary() | nil, flex: binary() | nil}, [warning()]} | {:error, term()}
  def build_zips(organization_id, gtfs_version_id, export_type, opts \\ []) do
    with {:ok, build_parent} <-
           build_parent(organization_id, gtfs_version_id, Keyword.get(opts, :run_id)) do
      build_zips_in(build_parent, organization_id, gtfs_version_id, export_type, opts)
    end
  end

  defp build_zips_in(build_parent, organization_id, gtfs_version_id, export_type, opts) do
    include_flex = Keyword.get(opts, :include_flex, false) and export_type != :pathways
    estimate = normalize_estimate(Keyword.get(opts, :estimate))

    temp_dir = generate_temp_dir(build_parent)
    flex_dir = generate_temp_dir(build_parent)

    try do
      File.mkdir_p!(temp_dir)
      File.mkdir_p!(flex_dir)

      result =
        with_read_snapshot(fn ->
          # R3's one mapper is bound to this snapshot before any stop_times
          # writer runs, so the main and flex files share one answer.
          mapper = FlexExport.sequence_mapper(organization_id, gtfs_version_id)

          # Stop coordinates are read once per estimating build inside the
          # same snapshot, so every trip fills against one revision.
          coords =
            if estimate do
              MissingTimes.stop_coordinates(organization_id, gtfs_version_id)
            else
              %{}
            end

          main_result =
            build_main(
              temp_dir,
              organization_id,
              gtfs_version_id,
              export_type,
              mapper,
              estimate,
              coords
            )

          {flex_zip, flex_entries, flex_warnings} =
            build_flex_result(
              include_flex and flex_services?(organization_id, gtfs_version_id),
              flex_dir,
              organization_id,
              gtfs_version_id,
              mapper,
              estimate,
              coords
            )

          main_zip = main_zip(main_result, flex_entries)

          {%{main: main_zip, flex: flex_zip}, main_warnings(main_result) ++ flex_warnings}
        end)

      case result do
        {:ok, {zips, warnings}} -> {:ok, zips, warnings}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("GTFS export failed: #{inspect(e)}")
        {:error, "Export failed: #{Exception.message(e)}"}
    after
      # Always clean up both temp directories. The run's `.build` directory goes
      # too once nothing else builds in it; `rmdir` refuses a non-empty one.
      File.rm_rf(temp_dir)
      File.rm_rf(flex_dir)
      if build_parent, do: File.rmdir(build_parent)
    end
  end

  # An estimate option other than the two known methods writes stored rows
  # unchanged; this keeps a `false` run flag and an unknown value on one path.
  defp normalize_estimate(:distance), do: :distance
  defp normalize_estimate(:even), do: :even
  defp normalize_estimate(_), do: nil

  # R15: a version without routes answers a flex zip and no main zip once at
  # least one service is exported; otherwise a main that could not be built is
  # the whole export's error.
  defp main_zip({:ok, _zip, _warnings}, %{main_feed_not_produced: true}), do: nil
  defp main_zip({:ok, zip, _warnings}, _flex_entries), do: zip
  defp main_zip({:error, :no_data}, %{main_feed_not_produced: true}), do: nil
  defp main_zip({:error, reason}, _flex_entries), do: Repo.rollback(reason)

  defp main_warnings({:ok, _zip, warnings}), do: warnings
  defp main_warnings({:error, _reason}), do: []

  # Builds the flex zip and its warnings when flex is included and the version
  # has an active flex service, and the empty answer otherwise: without a
  # service the flex zip would repeat the main zip. A flex zip with no content
  # at all is nil.
  #
  # The main zip is already built when this runs, and a flex failure must not
  # take it down (R4). The build runs under a savepoint, so a raise, including
  # a PostgreSQL error that aborts the statement, rolls back to it and leaves
  # the snapshot usable; the run then has no flex zip and a `flex_build_failed`
  # warning. The savepoint keeps the outer repeatable-read snapshot, so both
  # zips still read one committed revision.
  defp build_flex_result(
         false,
         _flex_dir,
         _organization_id,
         _gtfs_version_id,
         _mapper,
         _estimate,
         _coords
       ) do
    {nil, nil, []}
  end

  defp build_flex_result(
         true,
         flex_dir,
         organization_id,
         gtfs_version_id,
         mapper,
         estimate,
         coords
       ) do
    Repo.query!("SAVEPOINT gtfs_flex_build")

    try do
      result = build_flex(flex_dir, organization_id, gtfs_version_id, mapper, estimate, coords)
      Repo.query!("RELEASE SAVEPOINT gtfs_flex_build")
      result
    rescue
      error ->
        Repo.query!("ROLLBACK TO SAVEPOINT gtfs_flex_build")

        Logger.error(
          "GTFS flex export failed: " <> Exception.format(:error, error, __STACKTRACE__)
        )

        {nil, nil, [flex_build_failed_warning()]}
    end
  end

  defp build_flex(flex_dir, organization_id, gtfs_version_id, mapper, estimate, coords) do
    {:ok, entries, warnings} =
      FlexExport.build_entries(organization_id, gtfs_version_id,
        estimate: estimate,
        coordinates: coords
      )

    case write_flex_zip(
           flex_dir,
           organization_id,
           gtfs_version_id,
           mapper,
           entries,
           estimate,
           coords
         ) do
      {:ok, zip} -> {zip, entries, warnings}
      {:error, :no_data} -> {nil, entries, warnings}
    end
  end

  defp flex_build_failed_warning do
    %{
      code: "flex_build_failed",
      detail:
        "The flex file could not be built, so this run has no flex file. The main feed " <>
          "was built as usual.",
      file: "gtfs-flex.zip",
      entity_type: "feed"
    }
  end

  defp flex_services?(organization_id, gtfs_version_id) do
    import Ecto.Query

    FlexService
    |> where([s], s.organization_id == ^organization_id)
    |> where([s], s.gtfs_version_id == ^gtfs_version_id)
    |> where([s], s.active)
    |> Repo.exists?()
  end

  @doc """
  Exports selected GTFS file specs to an existing output directory.

  This is a disk-targeted export path used by OTP materialization workflows.
  It writes the specs it is given and applies no flex sequence mapping.

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

        case export_files(output_dir, file_specs, organization_id, gtfs_version_id, lookup_maps) do
          {:ok, {file_paths, _conflicts, _missing_warnings}} -> file_paths
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    rescue
      e ->
        Logger.error("GTFS disk export failed: #{inspect(e)}")
        {:error, "Export failed: #{Exception.message(e)}"}
    end
  end

  # Builds the main zip inside its read snapshot. The operations path keeps the
  # public files untouched and adds the TODS files beside them. An estimating
  # build fills missing stop times and carries one uncapped
  # `missing_times_not_estimated` warning per unfilled trip after the movement
  # and TODS omission notices; the worker fits them into its warning limit.
  defp build_main(
         temp_dir,
         organization_id,
         gtfs_version_id,
         :operations,
         mapper,
         estimate,
         coords
       ) do
    %{garages: garages, vehicles: vehicles} = Operations.tods_export_rows(organization_id)

    conflict_rollback(
      Operations.garage_stop_id_conflicts(organization_id, gtfs_version_id, garages)
    )

    garage_map = Map.new(garages, &{&1.garage_id, &1.name})

    with {:ok, {file_paths, emitted_conflicts, missing_warnings}} <-
           export_files(
             temp_dir,
             FileSpec.get_specs(:full),
             organization_id,
             gtfs_version_id,
             %{},
             garage_map,
             mapper,
             %{appended_rows: %{}, estimate: estimate, coords: coords}
           ) do
      conflict_rollback(emitted_conflicts)

      movements = movement_rows(organization_id, gtfs_version_id)

      file_paths =
        file_paths ++
          export_tods_files(temp_dir, garages, vehicles) ++
          export_movement_files(temp_dir, movements)

      warnings =
        movement_warnings(movements) ++
          run_warnings(movements) ++
          assignment_warnings(movements) ++
          tods_omission_warnings(garages, vehicles) ++ missing_warnings

      {:ok, create_zip_archive(file_paths, organization_id, gtfs_version_id), warnings}
    end
  end

  defp build_main(
         temp_dir,
         organization_id,
         gtfs_version_id,
         export_type,
         mapper,
         estimate,
         coords
       ) do
    with {:ok, {file_paths, _conflicts, missing_warnings}} <-
           export_files(
             temp_dir,
             FileSpec.get_specs(export_type),
             organization_id,
             gtfs_version_id,
             %{},
             %{},
             mapper,
             %{appended_rows: %{}, estimate: estimate, coords: coords}
           ) do
      {:ok, create_zip_archive(file_paths, organization_id, gtfs_version_id), missing_warnings}
    end
  end

  # The flex zip: the full specs written from the same snapshot with the R3
  # mapper, the flex rows appended after the stored rows (so an imported
  # booking rule and a flex one share one `booking_rules.txt`), then the extra
  # flex files. A spec is written when the version has records for it or the
  # flex row list is not empty, so an area service's generated route reaches a
  # version without fixed routes (R15).
  defp write_flex_zip(
         temp_dir,
         organization_id,
         gtfs_version_id,
         mapper,
         entries,
         estimate,
         coords
       ) do
    appended_rows = %{
      "routes.txt" => entries.rows.routes,
      "trips.txt" => entries.rows.trips,
      "stop_times.txt" => entries.rows.stop_times,
      "booking_rules.txt" => entries.rows.booking_rules
    }

    file_paths =
      FileSpec.get_specs(:full)
      |> Enum.filter(fn spec ->
        has_records?(spec.schema, organization_id, gtfs_version_id) or
          Map.get(appended_rows, spec.filename, []) != []
      end)
      |> Enum.map(fn spec ->
        spec = flex_spec(spec)
        rows = Map.get(appended_rows, spec.filename, [])

        {file_path, _conflicts, _missing_warnings} =
          export_file(
            temp_dir,
            spec,
            organization_id,
            gtfs_version_id,
            %{},
            %{},
            mapper,
            %{appended_rows: rows, estimate: estimate, coords: coords}
          )

        file_path
      end)

    entry_paths =
      Enum.map(entries.entries, fn {filename, content} ->
        path = Path.join(temp_dir, to_string(filename))
        File.write!(path, content)
        path
      end)

    if file_paths == [] and entry_paths == [] do
      {:error, :no_data}
    else
      {:ok, create_zip_archive(file_paths ++ entry_paths, organization_id, gtfs_version_id)}
    end
  end

  defp flex_spec(%{filename: "stop_times.txt"}), do: FlexFileSpecs.stop_times_spec()
  defp flex_spec(spec), do: spec

  defp conflict_rollback([]), do: :ok
  defp conflict_rollback(conflicts), do: Repo.rollback({:garage_stop_id_conflict, conflicts})

  @doc """
  Runs `fun` inside one repeatable-read read transaction.

  The snapshot is established before the first query, so every read inside `fun`
  describes a single committed revision: a concurrent committed edit is either
  entirely visible or entirely invisible. A caller-owned transaction cannot change
  its own isolation (for example the SQL sandbox), so this boundary owns the
  decision and the configured `GtfsPlanner.Gtfs.Export.Snapshot` adapter; this
  function does not change either one.

  `fun`'s return value is passed through: `Repo.transaction/2` only fails when
  `fun` rolls the transaction back.

  The transaction has a deadline, `:export_snapshot_timeout_ms` (default 600000).
  When it passes, the pool closes and releases the database connection and the
  call returns `{:error, :snapshot_timeout}` instead of `fun`'s result. The
  deadline cannot interrupt `fun` between database calls: `fun` ends at its next
  query, and a `fun` that makes none ends when the transaction is rolled back at
  commit.
  """
  @spec with_read_snapshot((-> term())) :: {:ok, term()} | {:error, term()}
  def with_read_snapshot(fun) when is_function(fun, 0) do
    timeout = snapshot_timeout_ms()
    started = System.monotonic_time(:millisecond)

    result =
      try do
        Repo.transaction(
          fn ->
            snapshot_module().begin_read()
            fun.()
          end,
          timeout: timeout
        )
      rescue
        # The pool closes the connection at the deadline, and the caller sees
        # only a generic closed-connection error on its next query.
        error in DBConnection.ConnectionError ->
          if deadline_passed?(started, timeout) do
            {:error, :rollback}
          else
            reraise error, __STACKTRACE__
          end
      end

    # A closed connection also reaches the caller as a plain rollback: when `fun`
    # rescued the error from its last query, or made no further query and the
    # commit found the connection gone. A rollback after the deadline is that
    # expiry; `fun` is never reported as having succeeded.
    case result do
      {:error, :rollback} ->
        if deadline_passed?(started, timeout), do: {:error, :snapshot_timeout}, else: result

      other ->
        other
    end
  end

  defp deadline_passed?(started, timeout),
    do: System.monotonic_time(:millisecond) - started >= timeout

  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_export_snapshot, Snapshot.Repo)
  end

  defp snapshot_timeout_ms do
    Application.get_env(:gtfs_planner, :export_snapshot_timeout_ms, @default_snapshot_timeout_ms)
  end

  # A run-scoped build writes under the run's private artifact directory, which
  # `ArtifactStorage` lays out as `<root>/export-runs/<org>/<version>/<run>` and
  # reconciles, so the files of a build that never reached its cleanup go with a
  # run that is not retained. `nil` means no run: the system temporary directory.
  defp build_parent(_organization_id, _gtfs_version_id, nil), do: {:ok, nil}

  defp build_parent(organization_id, gtfs_version_id, run_id) do
    root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)

    cond do
      not Enum.all?([organization_id, gtfs_version_id, run_id], &canonical_uuid?/1) ->
        {:error, :invalid_scope}

      not (is_binary(root) and root != "") ->
        {:error, :artifact_storage_unavailable}

      true ->
        parent =
          Path.join([
            Path.expand(root),
            "export-runs",
            organization_id,
            gtfs_version_id,
            run_id,
            ".build"
          ])

        # An unusable root is the storage failure the run page explains, not a
        # generic build error.
        case File.mkdir_p(parent) do
          :ok -> {:ok, parent}
          {:error, _reason} -> {:error, :artifact_storage_unavailable}
        end
    end
  end

  defp canonical_uuid?(value),
    do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))

  # A unique directory path under the run's `.build` directory, or the system
  # temporary directory when the build has no run. Unique per build, so two
  # builds of one run never share files.
  defp generate_temp_dir(parent) do
    Path.join(parent || System.tmp_dir!(), "gtfs_export_#{Ecto.UUID.generate()}")
  end

  # Builds lookup maps for foreign key resolution
  defp build_lookup_maps(_organization_id, _gtfs_version_id) do
    %{}
  end

  # Exports all files for the given specs. Returns the written file paths, the
  # garage/stop collisions seen in the records actually written, ordered by
  # garage ID, and the missing-times warnings from estimated `stop_times.txt`
  # files in trip order. `garage_map` holds the organization's garage IDs and names; it is
  # empty for exports that check no collisions. `opts` carries the optional tail:
  # `:appended_rows` adds flex rows after the streamed records, keyed by filename
  # (a map here); `:estimate` fills missing stop times per trip against `:coords`;
  # nil writes stored rows unchanged.
  # A version with no records for
  # any spec and no appended rows answers `{:error, :no_data}` without rolling
  # the snapshot back, so a caller that still has flex files can keep building.
  defp export_files(
         temp_dir,
         file_specs,
         organization_id,
         gtfs_version_id,
         lookup_maps,
         garage_map \\ %{},
         mapper \\ & &1,
         opts \\ %{}
       ) do
    appended_rows = Map.get(opts, :appended_rows, %{})
    estimate = Map.get(opts, :estimate)
    coords = Map.get(opts, :coords, %{})

    specs =
      Enum.filter(file_specs, fn spec ->
        has_records?(spec.schema, organization_id, gtfs_version_id) or
          Map.get(appended_rows, spec.filename, []) != []
      end)

    if Enum.empty?(specs) do
      {:error, :no_data}
    else
      results =
        Enum.map(specs, fn spec ->
          export_file(
            temp_dir,
            spec,
            organization_id,
            gtfs_version_id,
            lookup_maps,
            garage_map,
            mapper,
            %{
              appended_rows: Map.get(appended_rows, spec.filename, []),
              estimate: estimate,
              coords: coords
            }
          )
        end)

      file_paths = Enum.map(results, &elem(&1, 0))
      conflicts = results |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort_by(& &1.garage_id)
      missing_warnings = Enum.flat_map(results, &elem(&1, 2))

      {:ok, {file_paths, conflicts, missing_warnings}}
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

  # Exports a single GTFS file and returns its path, the garage/stop
  # collisions among the records it wrote, and the missing-times warnings from
  # estimated stop-time trips in trip order. The garage map is checked against the
  # exact streamed stop records, so a stop ID that changed after the preliminary
  # conflict query is still caught before any ZIP can be returned. The R3 mapper
  # is applied to stop time records only; `:appended_rows` in `opts` follow the
  # streamed records through the file's own spec (a list here). An estimating
  # `stop_times.txt` chunks
  # its trip-ordered stream by trip through `MissingTimes.fill_trip/3` before
  # the mapper, so filled rows on a detour route keep their doubled sequence.
  defp export_file(
         temp_dir,
         spec,
         organization_id,
         gtfs_version_id,
         lookup_maps,
         garage_map,
         mapper,
         opts
       ) do
    appended_rows = Map.get(opts, :appended_rows, [])
    estimate = Map.get(opts, :estimate)
    coords = Map.get(opts, :coords, %{})

    file_path = Path.join(temp_dir, spec.filename)
    file = File.open!(file_path, [:write, :utf8])

    try do
      # Write CSV header
      CsvWriter.write_header(file, spec)

      # Stream and write records
      {conflicts, missing_warnings} =
        StreamBuilder.stream_records(Repo, spec.schema, organization_id, gtfs_version_id)
        |> write_records(file, spec, lookup_maps, garage_map, mapper, estimate, coords)

      Enum.each(appended_rows, &CsvWriter.write_row(file, &1, spec, %{}))

      {file_path, conflicts, missing_warnings}
    after
      File.close(file)
    end
  end

  # Fills one trip at a time: the stream is ordered by `trip_id, stop_sequence`,
  # so `chunk_by/2` hands `fill_trip/3` whole trips. Fill runs before the R3
  # mapper doubles sequences on detour routes.
  defp write_records(
         stream,
         file,
         %{schema: StopTime} = spec,
         lookup_maps,
         garage_map,
         mapper,
         estimate,
         coords
       )
       when estimate in [:distance, :even] do
    stream
    |> Stream.chunk_by(& &1.trip_id)
    |> Enum.reduce({[], []}, fn chunk, {conflicts, missing} ->
      {filled, status} = MissingTimes.fill_trip(chunk, estimate, coords)

      missing =
        case status do
          {:not_estimated, warning} -> [warning | missing]
          _ -> missing
        end

      conflicts =
        Enum.reduce(filled, conflicts, fn record, acc ->
          CsvWriter.write_row(file, apply_mapper(spec, mapper, record), spec, lookup_maps)
          collect_garage_conflict(acc, record, garage_map)
        end)

      {conflicts, missing}
    end)
    |> then(fn {conflicts, missing} -> {Enum.reverse(conflicts), Enum.reverse(missing)} end)
  end

  defp write_records(stream, file, spec, lookup_maps, garage_map, mapper, _estimate, _coords) do
    conflicts =
      Enum.reduce(stream, [], fn record, acc ->
        CsvWriter.write_row(file, apply_mapper(spec, mapper, record), spec, lookup_maps)
        collect_garage_conflict(acc, record, garage_map)
      end)

    {Enum.reverse(conflicts), []}
  end

  # INV-3: only a stop time record carries a sequence the mapper may double; a
  # trip's equal `trip_id` field must not be passed to it.
  defp apply_mapper(%{schema: StopTime}, mapper, record), do: mapper.(record)
  defp apply_mapper(_spec, _mapper, record), do: record

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

  # The four movement supplements, built from the same snapshot the public files
  # were just read in. `Blocking.export_movements/2` runs inside this read rather
  # than opening a transaction of its own, so the movements, the public IDs they
  # must not collide with and the files beside them all describe one committed
  # revision: a supplement identifier can never be handed out against a public
  # file this ZIP has not actually read.
  #
  # A version that is not published has no day types to this application at all —
  # the Blocks page, the day load and `Calendars.list_calendars/3` all refuse one
  # — so its movements are left out and the fact is warned about, rather than
  # rolling the whole export back over a file the caller could always produce
  # before.
  defp movement_rows(organization_id, gtfs_version_id) do
    if Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
      movements = Blocking.export_movements(organization_id, gtfs_version_id)

      # The saved half of each day beside the derived half the movements already
      # carry. Both come from the same `Blocking.export_movements/2` result, so
      # the blocks a run was cut from and the blocks the movements were derived
      # from are one snapshot, not two reads that might disagree.
      run_days =
        Runs.derive_version(
          movements,
          Runs.assignments_by_day_type(organization_id, gtfs_version_id),
          Runs.get_crew_settings(organization_id, gtfs_version_id)
        )

      rows =
        TodsExport.rows(%{
          day_types: movements.day_types,
          blocks_by_day_type: movements.blocks_by_day_type,
          garages_by_id: movements.garages_by_id,
          public_ids: public_ids(organization_id, gtfs_version_id),
          run_day_types: RunsTodsExport.run_day_types(run_days)
        })

      ids = Map.get(rows, :ids, %{service_ids: %{}, movement_trip_ids: %{}})

      %{
        rows: rows,
        # `ids` is absent when no day type survived `collect/4` — with no day type
        # there is no service and no movement to name, and nothing to refer back
        # to. The default keeps a run row's lookup of a service or a movement
        # trip from raising on a version whose movements produced no file.
        run_rows:
          RunsTodsExport.rows(%{
            day_types: movements.day_types,
            run_days: run_days,
            ids: ids,
            garages_by_id: movements.garages_by_id
          }),
        # The planned assignments, expanded over the very `movements` and
        # `run_days` the run rows were just built from and hung on the very
        # `service_ids` those rows used, so `employee_run_dates.txt` can never
        # name a `(service_id, date)` the same ZIP's supplement does not list or a
        # run its `run_events.txt` does not carry (INV-14). `nil` when the version
        # has no roster line, which is what keeps the file and its warnings off a
        # version that has never been rostered (AC-23).
        assignment_rows:
          assignment_rows(organization_id, gtfs_version_id, movements, run_days, ids),
        published?: true
      }
    else
      %{
        rows: empty_movement_rows(),
        run_rows: %{run_events: [], left_out: 0, uncovered: []},
        assignment_rows: nil,
        published?: false
      }
    end
  end

  # `Rosters.export_roster/4` composes the roster from the movements and runs
  # this export already holds rather than deriving them a second time, and it
  # answers `nil` for a version with no line (INV-11, INV-15).
  defp assignment_rows(organization_id, gtfs_version_id, movements, run_days, ids) do
    case Rosters.export_roster(organization_id, gtfs_version_id, movements, run_days) do
      nil ->
        nil

      roster ->
        AssignmentsExport.rows(%{
          roster: roster,
          day_types: movements.day_types,
          run_days: run_days,
          services: ids.service_ids
        })
    end
  end

  defp empty_movement_rows do
    %{calendar_dates: [], routes: [], trips: [], stop_times: [], omitted: 0}
  end

  # The public trip, route and service IDs of this version, which is the set a
  # generated supplement identifier is kept clear of. A service is public
  # in either of the two calendar files, so both are read.
  defp public_ids(organization_id, gtfs_version_id) do
    %{
      trip_ids: public_ids(Gtfs.Trip, :trip_id, organization_id, gtfs_version_id),
      route_ids: public_ids(Gtfs.Route, :route_id, organization_id, gtfs_version_id),
      service_ids:
        public_ids(Gtfs.Calendar, :service_id, organization_id, gtfs_version_id) ++
          public_ids(Gtfs.CalendarDate, :service_id, organization_id, gtfs_version_id)
    }
  end

  defp public_ids(schema, field, organization_id, gtfs_version_id) do
    import Ecto.Query

    schema
    |> where([s], s.organization_id == ^organization_id)
    |> where([s], s.gtfs_version_id == ^gtfs_version_id)
    |> select([s], field(s, ^field))
    |> Repo.all()
  end

  # Writes the supplement files that have rows and omits the ones that have none,
  # exactly as the garage and vehicle files are treated: an empty file tells a
  # consumer nothing that its absence does not.
  defp export_movement_files(temp_dir, movements) do
    rows = movements.rows

    [
      {Tods.calendar_dates_supplement_spec(), rows.calendar_dates},
      {Tods.routes_supplement_spec(), rows.routes},
      {Tods.trips_supplement_spec(), rows.trips},
      {Tods.stop_times_supplement_spec(), rows.stop_times},
      {Tods.run_events_spec(), movements.run_rows.run_events},
      {Tods.employee_run_dates_spec(), employee_run_date_rows(movements)}
    ]
    |> Enum.reject(fn {_spec, rows} -> rows == [] end)
    |> Enum.map(fn {spec, rows} -> write_tods_file(temp_dir, spec, rows) end)
  end

  # The movement warnings, in the order a reader meets them: why the files are
  # missing at all, what was left out of them, then each omitted file. A version
  # with a driving time a consumer cannot run gets one warning naming the count,
  # not one per movement.
  defp movement_warnings(%{rows: rows, published?: published?}) do
    unpublished =
      if published? do
        []
      else
        [
          %{
            code: "tods_movements_unavailable",
            detail: "The movement files were left out because this version is not published.",
            file: "trips_supplement.txt",
            entity_type: "movement"
          }
        ]
      end

    omitted =
      if rows.omitted == 0 do
        []
      else
        [
          %{
            code: "tods_movements_omitted",
            detail: "#{rows.omitted} movements have no driving time and were left out.",
            file: "trips_supplement.txt",
            entity_type: "movement"
          }
        ]
      end

    unpublished ++
      omitted ++
      Enum.flat_map(
        [
          {Tods.calendar_dates_supplement_spec().filename, rows.calendar_dates},
          {Tods.routes_supplement_spec().filename, rows.routes},
          {Tods.trips_supplement_spec().filename, rows.trips},
          {Tods.stop_times_supplement_spec().filename, rows.stop_times}
        ],
        fn {filename, rows} ->
          if rows == [] do
            [
              %{
                code: "tods_file_omitted",
                detail: "#{filename} was not included because this version has no movements.",
                file: filename,
                entity_type: "movement"
              }
            ]
          else
            []
          end
        end
      )
  end

  # The run warnings, in the order a reader meets them: what the file is missing,
  # what was left out of it, and then each day type's uncovered work. One warning
  # naming a count, never one per run or per trip.
  defp run_warnings(%{run_rows: run_rows, published?: published?}) do
    filename = Tods.run_events_spec().filename

    # No "file omitted" warning for an empty `run_events.txt`. The four movement
    # supplements warn when they are absent, and it was tempting to match them —
    # but a version with movements and no runs exports with no warnings at all,
    # and that export is exactly this one plus a run file. The
    # absence of a file a caller knows is optional needs no announcement; the two
    # warnings below are about work that exists and was dropped.
    unpublished =
      if published? do
        []
      else
        [
          %{
            # Its own code, not the movements' `tods_movements_unavailable`. Both
            # fire for an unpublished version, and a consumer reading the movement
            # code would not know a run file was also missing.
            code: "tods_runs_unavailable",
            detail: "The run files were left out because this version is not published.",
            file: filename,
            entity_type: "run"
          }
        ]
      end

    left_out =
      if run_rows.left_out == 0 do
        []
      else
        [
          %{
            code: "tods_runs_left_out",
            detail: "#{run_rows.left_out} runs have errors and were left out.",
            file: filename,
            entity_type: "run"
          }
        ]
      end

    uncovered =
      Enum.map(run_rows.uncovered, fn %{day_type: day_type, trips: trips} ->
        %{
          code: "tods_runs_uncovered",
          detail: "#{trips} trips are not in a run for #{day_type.label}.",
          file: filename,
          entity_type: "run"
        }
      end)

    unpublished ++ left_out ++ uncovered
  end

  # The planned assignments' rows, or none at all. A version with no roster line
  # has no roster to expand, and a roster whose every line is open or stale has
  # nothing to write: either way the file is omitted rather than written empty,
  # and the warnings below say which of the two it was.
  defp employee_run_date_rows(%{assignment_rows: nil}), do: []
  defp employee_run_date_rows(%{assignment_rows: %{rows: rows}}), do: rows

  # The roster-line warnings, in the order a reader meets them: what the file is,
  # what it deliberately leaves out, and what could not be exported. They appear
  # only for a version that has roster lines — a version nobody has rostered owes
  # a consumer no announcement (AC-23).
  #
  # The sentences are `AssignmentsExport.sentences/2`'s, the same ones the
  # Rosters page lists, so a warning a reader has already read on the page cannot
  # read differently in the ZIP's own report (INV-14).
  defp assignment_warnings(%{assignment_rows: nil}), do: []

  defp assignment_warnings(%{assignment_rows: assignments}) do
    file = Tods.employee_run_dates_spec().filename

    for {code, detail} <- AssignmentsExport.sentences(assignments),
        do: warning(code, detail, file)
  end

  @roster_line_warning %{
    code: nil,
    detail: nil,
    file: nil,
    entity_type: "roster_line"
  }

  defp warning(code, detail, file) do
    %{@roster_line_warning | code: code, detail: detail, file: file}
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

    # Append extensions entries (diagram coordinates, stop levels, images)
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
