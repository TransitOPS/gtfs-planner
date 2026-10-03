defmodule GtfsPlanner.Gtfs.ExportTest do
  use GtfsPlanner.DataCase

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.ConcurrencyHelpers
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  setup do
    user = user_fixture()
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id
    }
  end

  describe "export_to_zip/3 with :pathways type" do
    test "generates ZIP with stops.txt, levels.txt, and pathways.txt", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create test data
      stop1 = stop_fixture(org_id, version_id, stop_id: "STOP1")

      stop2 =
        stop_fixture(org_id, version_id, stop_id: "STOP2")

      _level1 =
        level_fixture(org_id, version_id, level_id: "LEVEL1")

      pathway_fixture(
        org_id,
        version_id,
        stop1.id,
        stop2.id,
        pathway_id: "PATH1"
      )

      # Export
      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)
      assert is_binary(zip_binary)

      # Unzip and verify files
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _content} -> to_string(name) end)

      assert "stops.txt" in filenames
      assert "levels.txt" in filenames
      assert "pathways.txt" in filenames

      # Verify stops.txt content
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_lines = String.split(to_string(stops_content), "\n", trim: true)
      assert length(stops_lines) >= 2
      assert hd(stops_lines) =~ "stop_id"

      # Verify levels.txt content
      {_, levels_content} = Enum.find(files, fn {name, _} -> to_string(name) == "levels.txt" end)
      levels_lines = String.split(to_string(levels_content), "\n", trim: true)
      assert length(levels_lines) >= 2
      assert hd(levels_lines) =~ "level_id"

      # Verify pathways.txt content
      {_, pathways_content} =
        Enum.find(files, fn {name, _} -> to_string(name) == "pathways.txt" end)

      pathways_lines = String.split(to_string(pathways_content), "\n", trim: true)
      assert length(pathways_lines) >= 2
      assert hd(pathways_lines) =~ "pathway_id"
    end

    test "excludes other GTFS files", %{organization_id: org_id, gtfs_version_id: version_id} do
      # Create stops and levels for pathways export
      stop_fixture(org_id, version_id, stop_id: "STOP1")
      level_fixture(org_id, version_id, level_id: "LEVEL1")

      # Create data for files that should NOT be in pathways export
      agency_fixture(org_id, version_id, agency_id: "AGENCY1")

      route_fixture(
        org_id,
        version_id,
        route_id: "ROUTE1",
        route_short_name: "1"
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _content} -> to_string(name) end)

      # Should NOT include agency, routes, etc.
      refute "agency.txt" in filenames
      refute "routes.txt" in filenames
      refute "trips.txt" in filenames
    end
  end

  describe "export_to_zip/3 with :full type" do
    test "generates ZIP with all GTFS files that have data", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create test data for various file types
      agency_fixture(org_id, version_id, agency_id: "AGENCY1")
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      route_fixture(
        org_id,
        version_id,
        route_id: "ROUTE1",
        route_short_name: "1"
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :full)
      assert is_binary(zip_binary)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _content} -> to_string(name) end)

      # Should include files with data
      assert "agency.txt" in filenames
      assert "stops.txt" in filenames
      assert "routes.txt" in filenames
    end

    test "returns error when no data exists", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Don't create any data
      assert {:error, :no_data} = Export.export_to_zip(org_id, version_id, :full)
    end
  end

  describe "CSV format compliance" do
    test "excludes internal fields from exported CSV", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)
      header = stops_csv |> String.split("\n") |> hd()

      # Should NOT include internal fields
      columns = String.split(header, ",")
      refute "id" in columns
      refute "organization_id" in columns
      refute "gtfs_version_id" in columns
      refute "inserted_at" in columns
      refute "updated_at" in columns
      refute "diagram_coordinate" in columns

      # Should include GTFS fields
      assert header =~ "stop_id"
    end

    test "resolves UUID foreign keys to GTFS string IDs", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create parent station
      parent_station =
        stop_fixture(
          org_id,
          version_id,
          stop_id: "PARENT_STATION",
          location_type: 1
        )

      # Create level
      level =
        level_fixture(org_id, version_id, level_id: "LEVEL1")

      # Create child stop with parent_station and level references
      stop_fixture(
        org_id,
        version_id,
        stop_id: "CHILD_STOP",
        parent_station: parent_station.stop_id,
        level_id: level.level_id,
        location_type: 0
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)

      # Find the child stop row
      child_row =
        stops_csv
        |> String.split("\n", trim: true)
        |> Enum.find(fn line -> line =~ "CHILD_STOP" end)

      # Should contain GTFS string IDs, not UUIDs
      assert child_row =~ "PARENT_STATION"
      assert child_row =~ "LEVEL1"

      # Should NOT contain UUID format
      refute child_row =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
    end

    test "properly escapes CSV fields with special characters", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create stop with special characters in name
      stop_fixture(
        org_id,
        version_id,
        stop_id: "STOP1",
        stop_name: "Station, Platform \"A\""
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)

      # Find the stop row
      stop_row =
        stops_csv
        |> String.split("\n", trim: true)
        |> Enum.find(fn line -> line =~ "STOP1" end)

      # Field with comma and quotes should be quoted and quotes should be doubled
      assert stop_row =~ ~s("Station, Platform ""A""")
    end
  end

  describe "edge cases" do
    test "handles empty version (no data)", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      assert {:error, :no_data} = Export.export_to_zip(org_id, version_id, :pathways)
    end

    test "filters data by organization and version", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create data for this version
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      # Create data for a different organization
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      stop_fixture(
        other_org.id,
        other_version.id,
        stop_id: "OTHER_STOP"
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)

      # Should include only this version's data
      assert stops_csv =~ "STOP1"
      refute stops_csv =~ "OTHER_STOP"
    end
  end

  describe "build_zip/3 with the :operations type" do
    test "keeps every :full entry byte-for-byte and adds exactly the TODS files", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      agency_fixture(org_id, version_id, agency_id: "AGENCY1")
      stop_fixture(org_id, version_id, stop_id: "STOP1")
      garage_fixture(org_id, garage_id: "garage_main", name: "Main garage")
      vehicle_fixture(org_id, vehicle_id: "bus-1")

      assert {:ok, full_zip} = Export.export_to_zip(org_id, version_id, :full)

      # This version has a garage and a vehicle but no blocked day, so only the
      # four movement files are omitted, and each omission carries a warning.
      assert {:ok, operations_zip, warnings} = Export.build_zip(org_id, version_id, :operations)

      assert warnings == movement_omitted_warnings()

      full = zip_entries(full_zip)
      operations = zip_entries(operations_zip)

      assert Enum.sort(Map.keys(operations) -- Map.keys(full)) == [
               "stops_supplement.txt",
               "vehicles.txt"
             ]

      assert Map.keys(full) -- Map.keys(operations) == []

      for {filename, content} <- full do
        assert operations[filename] == content
      end

      # Garages never enter the public stop file.
      refute operations["stops.txt"] =~ "garage_main"
    end

    test "writes stops_supplement.txt with the prepared columns in garage ID order", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      garage_fixture(org_id,
        garage_id: "garage_b",
        name: "Depot, North",
        lat: Decimal.new("44.4759"),
        lon: Decimal.new("-73.2121")
      )

      garage_fixture(org_id, garage_id: "garage_a", name: "Alpha depot")

      assert {:ok, zip_binary, warnings} = Export.build_zip(org_id, version_id, :operations)

      assert warnings ==
               movement_omitted_warnings() ++
                 [tods_omitted_warning("vehicles.txt", "vehicle", "vehicles")]

      assert zip_entries(zip_binary)["stops_supplement.txt"] ==
               """
               stop_id,stop_name,stop_lat,stop_lon,location_type,TODS_location_type
               garage_a,Alpha depot,40.7128,-74.0060,0,garage
               garage_b,"Depot, North",44.4759,-73.2121,0,garage
               """
    end

    test "writes vehicles.txt ordered by ID length then value with escaped labels", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      vehicle_fixture(org_id,
        vehicle_id: "bus-2",
        vehicle_label: "Buster, Jr.",
        license_plate: "OR-E251432"
      )

      vehicle_fixture(org_id, vehicle_id: "10", vehicle_label: "Ten")
      vehicle_fixture(org_id, vehicle_id: "9", vehicle_label: "Nine")

      assert {:ok, zip_binary, warnings} = Export.build_zip(org_id, version_id, :operations)

      assert warnings ==
               movement_omitted_warnings() ++
                 [tods_omitted_warning("stops_supplement.txt", "garage", "garages")]

      assert zip_entries(zip_binary)["vehicles.txt"] ==
               """
               vehicle_id,vehicle_label,license_plate
               9,Nine,
               10,Ten,
               bus-2,"Buster, Jr.",OR-E251432
               """
    end

    test "omits both TODS files with one warning each when nothing is stored", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      assert {:ok, zip_binary, warnings} = Export.build_zip(org_id, version_id, :operations)
      files = zip_entries(zip_binary)

      refute Map.has_key?(files, "stops_supplement.txt")
      refute Map.has_key?(files, "vehicles.txt")

      assert warnings ==
               movement_omitted_warnings() ++
                 [
                   tods_omitted_warning("stops_supplement.txt", "garage", "garages"),
                   tods_omitted_warning("vehicles.txt", "vehicle", "vehicles")
                 ]
    end

    test "keeps the TODS file whose table has rows", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "STOP1")
      garage_fixture(org_id, garage_id: "garage_main")

      assert {:ok, zip_binary, warnings} = Export.build_zip(org_id, version_id, :operations)
      files = zip_entries(zip_binary)

      assert Map.has_key?(files, "stops_supplement.txt")
      refute Map.has_key?(files, "vehicles.txt")

      assert warnings ==
               movement_omitted_warnings() ++
                 [tods_omitted_warning("vehicles.txt", "vehicle", "vehicles")]
    end

    test "export_to_zip/4 returns the operations ZIP bytes", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "STOP1")
      garage_fixture(org_id, garage_id: "garage_main")
      vehicle_fixture(org_id, vehicle_id: "bus-1")

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :operations)
      assert is_binary(zip_binary)

      files = zip_entries(zip_binary)
      assert Map.has_key?(files, "stops_supplement.txt")
      assert Map.has_key?(files, "vehicles.txt")
    end

    test "reports the TODS file inventory counts of the organization", %{
      organization_id: org_id
    } do
      garage_fixture(org_id, garage_id: "garage_main")
      vehicle_fixture(org_id, vehicle_id: "bus-1")
      vehicle_fixture(org_id, vehicle_id: "bus-2")

      other_organization = organization_fixture()
      garage_fixture(other_organization.id, garage_id: "garage_other")

      assert Operations.tods_file_inventory(org_id) == [
               {"stops_supplement.txt", 1},
               {"vehicles.txt", 2}
             ]
    end

    test "rejects a garage ID equal to a stop ID with no ZIP", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      garage_fixture(org_id, garage_id: "STOP1", name: "Main garage")
      stop_fixture(org_id, version_id, stop_id: "STOP1", stop_name: "Main St")

      assert {:error, {:garage_stop_id_conflict, conflicts}} =
               Export.build_zip(org_id, version_id, :operations)

      assert conflicts == [
               %{garage_id: "STOP1", garage_name: "Main garage", stop_name: "Main St"}
             ]

      assert {:error, {:garage_stop_id_conflict, [_conflict]}} =
               Export.export_to_zip(org_id, version_id, :operations)
    end

    test "rejects a stop ID that starts colliding after the preliminary check" do
      temp_dirs_before = export_temp_dirs()

      organization = unboxed(fn -> organization_fixture() end)
      version = unboxed(fn -> gtfs_version_fixture(organization.id) end)
      on_exit(fn -> cleanup_export_fixtures([organization.id]) end)

      stop =
        unboxed(fn ->
          stop_fixture(organization.id, version.id, stop_id: "STOP_LATE", stop_name: "Late stop")
        end)

      unboxed(fn ->
        garage_fixture(organization.id, garage_id: "garage_late", name: "Late garage")
      end)

      # The same call succeeds while nothing collides.
      assert {:ok, zip_binary} =
               unboxed(fn -> Export.export_to_zip(organization.id, version.id, :operations) end)

      assert Map.has_key?(zip_entries(zip_binary), "stops_supplement.txt")

      parent = self()

      task =
        Task.async(fn ->
          receive do
            :start_export -> :ok
          end

          unboxed(fn ->
            %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:exporter_backend, self(), backend_pid})

            Export.build_zip(organization.id, version.id, :operations)
          end)
        end)

      handler_id = {__MODULE__, :operations_export_race}
      attach_stop_barrier(handler_id, parent, task.pid)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      send(task.pid, :start_export)

      assert_receive {:exporter_backend, exporter_pid, exporter_backend}, 10_000
      assert exporter_pid == task.pid
      assert_receive {:export_paused, ^exporter_pid}, 10_000

      writer_backend =
        unboxed(fn ->
          %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          backend_pid
        end)

      assert writer_backend != exporter_backend

      assert {1, nil} =
               unboxed(fn ->
                 Repo.update_all(from(s in Stop, where: s.id == ^stop.id),
                   set: [stop_id: "garage_late"]
                 )
               end)

      send(exporter_pid, :resume_export)

      assert {:error, {:garage_stop_id_conflict, conflicts}} = Task.await(task, 15_000)

      assert conflicts == [
               %{garage_id: "garage_late", garage_name: "Late garage", stop_name: "Late stop"}
             ]

      assert_no_export_temp_dir_leak(temp_dirs_before)
    end
  end

  # --- operations export helpers ---------------------------------------------

  defp zip_entries(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp tods_omitted_warning(filename, entity_type, label) do
    %{
      code: "tods_file_omitted",
      detail: "#{filename} was not included because this organization has no #{label}.",
      file: filename,
      entity_type: entity_type
    }
  end

  # The four movement files are omitted for the same reason as the two TODS
  # files and share their code, but a version with no blocked day has no
  # movements at all rather than no garage or vehicle.
  @movement_files ~w(
    calendar_dates_supplement.txt
    routes_supplement.txt
    trips_supplement.txt
    stop_times_supplement.txt
  )

  defp movement_omitted_warnings do
    Enum.map(@movement_files, fn filename ->
      %{
        code: "tods_file_omitted",
        detail: "#{filename} was not included because this version has no movements.",
        file: filename,
        entity_type: "movement"
      }
    end)
  end

  # The first `stops` query of the operations export is the preliminary conflict
  # SELECT. Pausing there lets the writer commit a new stop ID after that check
  # and before the stop stream reads the row.
  defp attach_stop_barrier(handler_id, parent, exporter_pid) do
    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, exporter} ->
        if self() == exporter and metadata[:source] == "stops" do
          :telemetry.detach(handler_id)
          send(owner, {:export_paused, self()})

          receive do
            :resume_export -> :ok
          after
            30_000 -> :ok
          end
        end
      end,
      {parent, exporter_pid}
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp export_temp_dirs do
    Path.wildcard(Path.join(System.tmp_dir!(), "gtfs_export_*"))
  end

  # Export cases in this partition share the system temp root, so a directory
  # seen right after the call may belong to another module's in-flight export.
  # Poll briefly for the root to settle back to its earlier state.
  defp assert_no_export_temp_dir_leak(before, attempts \\ 20) do
    leaked = export_temp_dirs() -- before

    cond do
      leaked == [] ->
        :ok

      attempts == 0 ->
        flunk("temporary export directories were left behind: #{inspect(leaked)}")

      true ->
        Process.sleep(50)
        assert_no_export_temp_dir_leak(before, attempts - 1)
    end
  end

  # The race case commits its own rows so a second connection can see them, including
  # the editor `garage_fixture/2` creates for the organization.
  defp cleanup_export_fixtures(organization_ids) do
    unboxed(fn ->
      ConcurrencyHelpers.delete_committed_members!(organization_ids)
      Repo.delete_all(from(v in Vehicle, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(g in Garage, where: g.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      delete_versions!(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))
    end)
  end
end
