defmodule GtfsPlanner.Gtfs.Calendars.ImportExportTest do
  @moduledoc """
  Merge evidence (EV-3) for calendar metadata round trips:
  - Real import, full-export, and re-import preserve weekly, exception-only, and metadata-only records,
    quoted/comma-containing names, typicality 6, native dates, and pattern-linked trip fields;
    missing/duplicate names and unchanged all-zero weekly rows are accepted.
  - RowParser rejects typicality 7, unsupported type, and malformed/reversed optional dates;
    blank optional fields remain nil and blank typicality defaults to 0.
  - Inventory and run counts include metadata; owned failed-import recovery removes it while
    preserving another version; pathways output stays unchanged.
  - Each public full-export path using Snapshot.Repo and separate committing sessions emits
    all three calendar files from one snapshot during a multi-table change; normal configured
    entry remains covered without override.
  """
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo

  alias GtfsPlanner.Gtfs.Import.Failure

  alias GtfsPlanner.Gtfs.{
    Agency,
    Calendar,
    CalendarAttribute,
    CalendarDate,
    ChangeLog,
    Export,
    Route,
    RoutePattern,
    RoutePatternStop,
    Stop,
    StopTime,
    TimedPattern,
    TimedPatternStop,
    Trip
  }

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.Export.FileSpec
  alias GtfsPlanner.Gtfs.Export.Snapshot
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.Import.Recovery
  alias GtfsPlanner.Gtfs.Import.RowParser
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions.GtfsVersion

  describe "RowParser calendar attribute validations" do
    test "accepts valid rows, typicality 0..6, supported types, ordered dates, and defaults" do
      org_id = Ecto.UUID.generate()
      ver_id = Ecto.UUID.generate()

      valid_row = %{
        "service_id" => "SVC_1",
        "service_description" => "Regular Weekday",
        "service_schedule_name" => "Weekday",
        "service_schedule_type" => "Weekday",
        "service_schedule_typicality" => "6",
        "rating_start_date" => "20260101",
        "rating_end_date" => "20260630",
        "rating_description" => "Spring 2026"
      }

      assert {:ok, attrs} = RowParser.calendar_attribute_row_to_attrs(valid_row, org_id, ver_id)
      assert attrs.service_id == "SVC_1"
      assert attrs.service_description == "Regular Weekday"
      assert attrs.service_schedule_name == "Weekday"
      assert attrs.service_schedule_type == "Weekday"
      assert attrs.service_schedule_typicality == 6
      assert attrs.rating_start_date == ~D[2026-01-01]
      assert attrs.rating_end_date == ~D[2026-06-30]
      assert attrs.rating_description == "Spring 2026"

      # Blank optional fields become nil, blank typicality defaults to 0
      minimal_row = %{
        "service_id" => "SVC_2",
        "service_description" => "",
        "service_schedule_name" => "",
        "service_schedule_type" => "",
        "service_schedule_typicality" => "",
        "rating_start_date" => "",
        "rating_end_date" => "",
        "rating_description" => ""
      }

      assert {:ok, min_attrs} =
               RowParser.calendar_attribute_row_to_attrs(minimal_row, org_id, ver_id)

      assert min_attrs.service_id == "SVC_2"
      assert is_nil(min_attrs.service_description)
      assert is_nil(min_attrs.service_schedule_name)
      assert is_nil(min_attrs.service_schedule_type)
      assert min_attrs.service_schedule_typicality == 0
      assert is_nil(min_attrs.rating_start_date)
      assert is_nil(min_attrs.rating_end_date)
      assert is_nil(min_attrs.rating_description)

      # All supported schedule types
      for type <- ~w(Weekday Weekend Saturday Sunday Other) do
        row = Map.put(minimal_row, "service_schedule_type", type)

        assert {:ok, %{service_schedule_type: ^type}} =
                 RowParser.calendar_attribute_row_to_attrs(row, org_id, ver_id)
      end
    end

    test "rejects typicality 7, unsupported type, malformed date, reversed dates, and missing service_id" do
      org_id = Ecto.UUID.generate()
      ver_id = Ecto.UUID.generate()

      base = %{"service_id" => "SVC_1"}

      # Typicality 7 out of range
      row_typ7 = Map.put(base, "service_schedule_typicality", "7")
      assert {:error, _} = RowParser.calendar_attribute_row_to_attrs(row_typ7, org_id, ver_id)

      # Negative typicality
      row_typ_neg = Map.put(base, "service_schedule_typicality", "-1")
      assert {:error, _} = RowParser.calendar_attribute_row_to_attrs(row_typ_neg, org_id, ver_id)

      # Unsupported schedule type
      row_type_bad = Map.put(base, "service_schedule_type", "Holiday")
      assert {:error, _} = RowParser.calendar_attribute_row_to_attrs(row_type_bad, org_id, ver_id)

      # Malformed date
      row_date_mal = Map.put(base, "rating_start_date", "2026-01-01")
      assert {:error, _} = RowParser.calendar_attribute_row_to_attrs(row_date_mal, org_id, ver_id)

      # Reversed rating dates
      row_reversed =
        Map.merge(base, %{
          "rating_start_date" => "20261231",
          "rating_end_date" => "20260101"
        })

      assert {:error, _} = RowParser.calendar_attribute_row_to_attrs(row_reversed, org_id, ver_id)

      # Missing service_id
      assert {:error, _} =
               RowParser.calendar_attribute_row_to_attrs(%{"service_id" => ""}, org_id, ver_id)
    end
  end

  describe "import, full-export, and re-import round trips" do
    test "preserves weekly, exception-only, metadata-only, quoted names, typicality 6, and pattern links" do
      org = new_org("cal-roundtrip")
      on_exit(fn -> cleanup([org.id]) end)

      version_a = new_version(org)

      agency_csv = """
      agency_id,agency_name,agency_url,agency_timezone
      AGENCY_1,Test Agency,https://example.com,America/New_York
      """

      routes_csv = """
      route_id,agency_id,route_short_name,route_long_name,route_type
      ROUTE_1,AGENCY_1,R1,Main Route,3
      """

      stops_csv = """
      stop_id,stop_name,stop_lat,stop_lon
      STOP_1,Station Alpha,42.3601,-71.0589
      STOP_2,Station Beta,42.3610,-71.0570
      """

      # Includes:
      # - WEEKLY_1: standard weekly service
      # - LEGACY_ZERO: all-zero legacy weekly row
      # - WEEKLY_2: another weekly service with duplicate description
      calendar_csv = """
      service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
      WEEKLY_1,1,1,1,1,1,0,0,20260101,20261231
      LEGACY_ZERO,0,0,0,0,0,0,0,20260101,20261231
      WEEKLY_2,1,0,0,0,0,1,1,20260601,20260831
      """

      # Includes:
      # - WEEKLY_1 exception (type 2 removal)
      # - DATES_ONLY: exception-only service (type 1 additions, no calendar.txt row!)
      calendar_dates_csv = """
      service_id,date,exception_type
      WEEKLY_1,20260704,2
      DATES_ONLY,20261126,1
      DATES_ONLY,20261127,1
      """

      # Includes:
      # - WEEKLY_1: quoted description with comma
      # - DATES_ONLY: quoted description with quotes/commas, typicality 6
      # - LEGACY_ZERO: blank description (missing name accepted)
      # - META_ONLY: metadata-only service (no row in calendar.txt or calendar_dates.txt!)
      # - WEEKLY_2: duplicate description matching WEEKLY_1 (duplicate name accepted)
      calendar_attributes_csv = """
      service_id,service_description,service_schedule_name,service_schedule_type,service_schedule_typicality,rating_start_date,rating_end_date,rating_description
      WEEKLY_1,"Weekly, Regular",Weekday Regular,Weekday,1,20260101,20260630,Spring 2026
      DATES_ONLY,"Holiday ""Special"", Winter",Thanksgiving,Other,6,,,
      LEGACY_ZERO,,,Weekend,0,,,
      META_ONLY,"Metadata Only",Planning Anchor,Other,0,20260101,20261231,Future Rating
      WEEKLY_2,"Weekly, Regular",Summer Weekend,Weekend,2,20260601,20260831,Summer 2026
      """

      route_patterns_csv = """
      route_pattern_id,route_id,direction_id,route_pattern_name,route_pattern_time_desc,route_pattern_typicality,route_pattern_sort_order,representative_trip_id,canonical_route_pattern
      RP_1,ROUTE_1,0,Main Line,Weekday,1,1,TRIP_LINKED,1
      """

      trips_csv = """
      route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed,route_pattern_id
      ROUTE_1,WEEKLY_1,TRIP_LINKED,Downtown,101,0,B1,,1,1,RP_1
      ROUTE_1,DATES_ONLY,TRIP_DATES,Holiday Outbound,102,0,B1,,1,1,RP_1
      """

      stop_times_csv = """
      trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
      TRIP_LINKED,08:00:00,08:00:00,STOP_1,1,0,0
      TRIP_LINKED,08:10:00,08:10:00,STOP_2,2,0,0
      TRIP_DATES,09:00:00,09:00:00,STOP_1,1,0,0
      TRIP_DATES,09:10:00,09:10:00,STOP_2,2,0,0
      """

      files_to_import = [
        %{filename: "agency.txt", content: agency_csv},
        %{filename: "routes.txt", content: routes_csv},
        %{filename: "stops.txt", content: stops_csv},
        %{filename: "calendar.txt", content: calendar_csv},
        %{filename: "calendar_dates.txt", content: calendar_dates_csv},
        %{filename: "calendar_attributes.txt", content: calendar_attributes_csv},
        %{filename: "route_patterns.txt", content: route_patterns_csv},
        %{filename: "trips.txt", content: trips_csv},
        %{filename: "stop_times.txt", content: stop_times_csv}
      ]

      # 1. Import files into version_a
      assert {:ok, result} =
               unboxed(fn -> StagedImport.import_files(org.id, version_a.id, files_to_import) end)

      assert result.counts[:calendar_attributes] == 5
      assert result.counts[:calendars] == 3
      assert result.counts[:calendar_dates] == 3

      # 2. Export full ZIP from version_a
      assert {:ok, zip} = unboxed(fn -> Export.export_to_zip(org.id, version_a.id, :full) end)

      zip_files = unzip(zip)
      names = filenames(zip_files)

      assert "calendar.txt" in names
      assert "calendar_dates.txt" in names
      assert "calendar_attributes.txt" in names

      # Verify calendar_attributes.txt content in export
      attr_rows = parsed_csv_rows(zip_files, "calendar_attributes.txt")
      assert length(attr_rows) == 5

      w1_attr = Enum.find(attr_rows, &(&1["service_id"] == "WEEKLY_1"))
      assert w1_attr["service_description"] == "Weekly, Regular"
      assert w1_attr["service_schedule_name"] == "Weekday Regular"
      assert w1_attr["service_schedule_type"] == "Weekday"
      assert w1_attr["service_schedule_typicality"] == "1"
      assert w1_attr["rating_start_date"] == "20260101"
      assert w1_attr["rating_end_date"] == "20260630"
      assert w1_attr["rating_description"] == "Spring 2026"

      do_attr = Enum.find(attr_rows, &(&1["service_id"] == "DATES_ONLY"))
      assert do_attr["service_description"] == "Holiday \"Special\", Winter"
      assert do_attr["service_schedule_typicality"] == "6"
      assert do_attr["rating_start_date"] == ""

      meta_attr = Enum.find(attr_rows, &(&1["service_id"] == "META_ONLY"))
      assert meta_attr["service_description"] == "Metadata Only"

      # 3. Re-import into version_b
      version_b = new_version(org)

      reimport_files =
        Enum.map(zip_files, fn {name, content} ->
          %{filename: to_string(name), content: content}
        end)

      assert {:ok, reimport_result} =
               unboxed(fn -> StagedImport.import_files(org.id, version_b.id, reimport_files) end)

      assert reimport_result.counts[:calendar_attributes] == 5

      # Verify persistence in version_b
      unboxed(fn ->
        attrs =
          Repo.all(
            from(ca in CalendarAttribute,
              where: ca.organization_id == ^org.id and ca.gtfs_version_id == ^version_b.id,
              order_by: ca.service_id
            )
          )

        assert length(attrs) == 5
        w1 = Enum.find(attrs, &(&1.service_id == "WEEKLY_1"))
        assert w1.service_description == "Weekly, Regular"
        assert w1.service_schedule_typicality == 1
        assert w1.rating_start_date == ~D[2026-01-01]

        do_rec = Enum.find(attrs, &(&1.service_id == "DATES_ONLY"))
        assert do_rec.service_description == "Holiday \"Special\", Winter"
        assert do_rec.service_schedule_typicality == 6

        # Check native calendars in version_b
        calendars =
          Repo.all(
            from(c in Calendar,
              where: c.organization_id == ^org.id and c.gtfs_version_id == ^version_b.id,
              order_by: c.service_id
            )
          )

        assert length(calendars) == 3
        # Legacy all-zero row preserved
        lz = Enum.find(calendars, &(&1.service_id == "LEGACY_ZERO"))
        assert lz.monday == 0 and lz.sunday == 0

        # Check native calendar dates in version_b
        dates =
          Repo.all(
            from(cd in CalendarDate,
              where: cd.organization_id == ^org.id and cd.gtfs_version_id == ^version_b.id,
              order_by: [cd.service_id, cd.date]
            )
          )

        assert length(dates) == 3
        do_dates = Enum.filter(dates, &(&1.service_id == "DATES_ONLY"))
        assert length(do_dates) == 2

        # Pattern-linked trip fields survive
        trips =
          Repo.all(
            from(t in Trip,
              where: t.organization_id == ^org.id and t.gtfs_version_id == ^version_b.id,
              order_by: t.trip_id
            )
          )

        assert length(trips) == 2
        trip_linked = Enum.find(trips, &(&1.trip_id == "TRIP_LINKED"))
        assert trip_linked.route_pattern_id == "RP_1"
        assert trip_linked.service_id == "WEEKLY_1"
      end)
    end
  end

  describe "inventory, run counts, recovery cleanup, and pathways export" do
    test "inventory counts include metadata; pathways export remains unchanged" do
      org = new_org("cal-inv")
      on_exit(fn -> cleanup([org.id]) end)

      version = new_version(org)

      unboxed(fn ->
        calendar_fixture(org.id, version.id, service_id: "CAL_1")
        calendar_date_fixture(org.id, version.id, service_id: "CAL_1")
        calendar_attribute_fixture(org.id, version.id, service_id: "CAL_1")
        stop_fixture(org.id, version.id, stop_id: "STOP_PW")
      end)

      # Full inventory includes calendar_attributes.txt
      full_inv = unboxed(fn -> Gtfs.get_file_inventory(org.id, version.id, :full) end)
      assert {"calendar_attributes.txt", 1} in full_inv
      assert {"calendar.txt", 1} in full_inv
      assert {"calendar_dates.txt", 1} in full_inv

      # Pathways inventory does NOT include calendar_attributes.txt
      pathways_inv = unboxed(fn -> Gtfs.get_file_inventory(org.id, version.id, :pathways) end)
      refute Enum.any?(pathways_inv, fn {file, _} -> file == "calendar_attributes.txt" end)
      refute Enum.any?(pathways_inv, fn {file, _} -> file == "calendar.txt" end)

      # Pathways export does not include calendar_attributes.txt
      {:ok, zip} = unboxed(fn -> Export.export_to_zip(org.id, version.id, :pathways) end)
      pathways_files = unzip(zip) |> filenames()
      refute "calendar_attributes.txt" in pathways_files
      refute "calendar.txt" in pathways_files
      refute "calendar_dates.txt" in pathways_files
    end

    test "failed import recovery cleans up calendar_attributes while preserving other version" do
      org = new_org("cal-recov")
      on_exit(fn -> cleanup([org.id]) end)

      # Version 1: good version with calendar_attributes
      v1 = new_version(org)

      unboxed(fn ->
        calendar_attribute_fixture(org.id, v1.id, service_id: "SVC_KEEP")
      end)

      {claimed_run, token} =
        unboxed(fn ->
          # Creating a target and claiming a cleanup reauthorize their actor, so both are
          # active editors of the organization. `cleanup/1` removes them with it.
          operator = editor_fixture(org)
          cleaner = editor_fixture(org)
          actor = %{id: operator.id, email: operator.email}
          cleanup_actor = %{id: cleaner.id, email: cleaner.email}

          {:ok, %{run: run, version: v2}} =
            ImportRuns.create_pending_target(org.id, actor, %{name: "Failed Version"})

          calendar_attribute_fixture(org.id, v2.id, service_id: "SVC_DROP")

          {:ok, _, _, import_token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

          failure =
            Failure.from_error(:unknown,
              phase: :phase_1,
              outcome: :failed,
              committed_counts: %{calendar_attributes: 1}
            )

          {:ok, _, _} = ImportRuns.fail_import(org.id, run.id, import_token, failure)

          {:ok, claimed, _version, cleanup_token} =
            ImportRuns.claim_cleanup(org.id, run.id, cleanup_actor)

          {claimed, cleanup_token}
        end)

      # Run Recovery
      assert {:ok, _} =
               unboxed(fn -> Recovery.run(org.id, claimed_run.id, token) end)

      # Verify v2 calendar_attributes are gone, v1 preserved
      unboxed(fn ->
        refute Repo.exists?(
                 from(ca in CalendarAttribute,
                   where: ca.organization_id == ^org.id and ca.service_id == "SVC_DROP"
                 )
               )

        assert Repo.exists?(
                 from(ca in CalendarAttribute,
                   where: ca.organization_id == ^org.id and ca.gtfs_version_id == ^v1.id
                 )
               )
      end)
    end
  end

  describe "snapshot isolation across all three calendar files" do
    test "export_to_zip with Snapshot.Repo reads all calendar files from one snapshot during concurrent write" do
      test_snapshot_isolation(:zip)
    end

    test "export_specs_to_directory with Snapshot.Repo reads all calendar files from one snapshot during concurrent write" do
      test_snapshot_isolation(:directory)
    end

    test "normal configured export succeeds without override" do
      org = new_org("cal-normal-export")
      on_exit(fn -> cleanup([org.id]) end)

      version = new_version(org)

      unboxed(fn ->
        calendar_fixture(org.id, version.id, service_id: "SVC_NORMAL")
        calendar_date_fixture(org.id, version.id, service_id: "SVC_NORMAL")
        calendar_attribute_fixture(org.id, version.id, service_id: "SVC_NORMAL")
      end)

      # Test default export_to_zip
      assert {:ok, zip} =
               unboxed(fn -> Export.export_to_zip(org.id, version.id, :full) end)

      assert "calendar_attributes.txt" in filenames(unzip(zip))

      # Test default export_specs_to_directory
      tmp_dir =
        Path.join(System.tmp_dir!(), "cal_normal_export_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      assert {:ok, files} =
               unboxed(fn ->
                 Export.export_specs_to_directory(
                   org.id,
                   version.id,
                   FileSpec.get_specs(:full),
                   tmp_dir
                 )
               end)

      assert Enum.any?(files, &String.ends_with?(&1, "calendar_attributes.txt"))
    end
  end

  # --- snapshot isolation test helper ----------------------------------------

  defp test_snapshot_isolation(mode) do
    original_snapshot = Application.get_env(:gtfs_planner, :gtfs_export_snapshot)
    Application.put_env(:gtfs_planner, :gtfs_export_snapshot, Snapshot.Repo)

    on_exit(fn ->
      Application.put_env(:gtfs_planner, :gtfs_export_snapshot, original_snapshot)
    end)

    org = new_org("cal-snap-#{mode}")
    on_exit(fn -> cleanup([org.id]) end)

    version = new_version(org)
    seed_snapshot_fixture(org.id, version.id)

    parent = self()

    task =
      Task.async(fn ->
        receive do
          :start_export -> :ok
        end

        unboxed(fn ->
          %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:exporter_backend, self(), backend_pid})
          perform_export(mode, org.id, version.id)
        end)
      end)

    exporter_pid = task.pid
    handler_id = {__MODULE__, :calendar_export_race, mode}
    attach_export_pause(parent, exporter_pid, handler_id)

    send(exporter_pid, :start_export)
    assert_receive {:exporter_backend, ^exporter_pid, exporter_backend}, 10_000
    assert_receive {:export_paused, ^exporter_pid}, 10_000

    writer_backend =
      unboxed(fn ->
        %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        backend_pid
      end)

    assert writer_backend != exporter_backend
    assert {:ok, _} = unboxed(fn -> mutate_calendar_tables(org.id) end)

    send(exporter_pid, :resume_export)
    files = await_export_files(task)

    assert_snapshot_before_state(files)
  end

  defp seed_snapshot_fixture(org_id, version_id) do
    unboxed(fn ->
      calendar_fixture(org_id, version_id,
        service_id: "CONC_SVC",
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-06-30]
      )

      calendar_date_fixture(org_id, version_id,
        service_id: "CONC_SVC",
        date: ~D[2026-03-15],
        exception_type: 1
      )

      calendar_attribute_fixture(org_id, version_id,
        service_id: "CONC_SVC",
        service_description: "Before Edit Description"
      )
    end)
  end

  defp perform_export(:zip, org_id, version_id) do
    Export.export_to_zip(org_id, version_id, :full)
  end

  defp perform_export(:directory, org_id, version_id) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cal_snap_dir_#{System.unique_integer([:positive])}"
      )

    res =
      Export.export_specs_to_directory(
        org_id,
        version_id,
        FileSpec.get_specs(:full),
        tmp_dir
      )

    files_map =
      case res do
        {:ok, paths} -> read_exported_directory(paths)
        other -> other
      end

    File.rm_rf(tmp_dir)
    {:ok, files_map}
  end

  defp read_exported_directory(paths) do
    Enum.map(paths, fn p -> {Path.basename(p), File.read!(p)} end)
  end

  defp attach_export_pause(parent, exporter_pid, handler_id) do
    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, exporter} ->
        query = to_string(metadata[:query])

        if self() == exporter and
             (metadata[:source] in ["agencies", "stops"] or
                String.contains?(query, "calendars")) do
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

  defp mutate_calendar_tables(org_id) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(c in Calendar,
          where: c.organization_id == ^org_id and c.service_id == "CONC_SVC"
        ),
        set: [start_date: ~D[2026-07-01], end_date: ~D[2026-12-31]]
      )

      Repo.update_all(
        from(cd in CalendarDate,
          where: cd.organization_id == ^org_id and cd.service_id == "CONC_SVC"
        ),
        set: [date: ~D[2026-10-31], exception_type: 2]
      )

      Repo.update_all(
        from(ca in CalendarAttribute,
          where: ca.organization_id == ^org_id and ca.service_id == "CONC_SVC"
        ),
        set: [service_description: "AFTER EDIT DESCRIPTION"]
      )
    end)
  end

  defp await_export_files(task) do
    case Task.await(task, 15_000) do
      {:ok, zip_bin} when is_binary(zip_bin) -> unzip(zip_bin)
      {:ok, files_list} when is_list(files_list) -> files_list
    end
  end

  defp assert_snapshot_before_state(files) do
    cal_rows = parsed_csv_rows(files, "calendar.txt")
    c_row = Enum.find(cal_rows, &(&1["service_id"] == "CONC_SVC"))
    assert c_row["start_date"] == "20260101"
    assert c_row["end_date"] == "20260630"

    date_rows = parsed_csv_rows(files, "calendar_dates.txt")
    cd_row = Enum.find(date_rows, &(&1["service_id"] == "CONC_SVC"))
    assert cd_row["date"] == "20260315"
    assert cd_row["exception_type"] == "1"

    attr_rows = parsed_csv_rows(files, "calendar_attributes.txt")
    ca_row = Enum.find(attr_rows, &(&1["service_id"] == "CONC_SVC"))
    assert ca_row["service_description"] == "Before Edit Description"
  end

  # --- helpers -------------------------------------------------------------

  defp new_org(prefix) do
    unboxed(fn ->
      organization_fixture(%{alias: "#{prefix}-#{System.system_time(:nanosecond)}"})
    end)
  end

  defp new_version(org) do
    unboxed(fn -> gtfs_version_fixture(org.id) end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    entries
  end

  defp filenames(files), do: Enum.map(files, fn {name, _} -> to_string(name) end)

  defp parsed_csv_rows(files, name) do
    case Enum.find(files, fn {entry_name, _} -> to_string(entry_name) == name end) do
      nil ->
        flunk("expected #{name} in export; got #{inspect(filenames(files))}")

      {_, content} ->
        {:ok, parsed} = CsvParser.stream(name, to_string(content))

        Enum.map(parsed.events, fn {:ok, _row_num, row_map} -> row_map end)
    end
  end

  defp cleanup(organization_ids) do
    unboxed(fn ->
      editor_ids =
        Repo.all(
          from(m in UserOrgMembership,
            where: m.organization_id in ^organization_ids,
            select: m.user_id
          )
        )

      timing_ids =
        Repo.all(
          from(t in TimedPattern, where: t.organization_id in ^organization_ids, select: t.id)
        )

      Repo.delete_all(from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids))
      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(r in RoutePatternStop, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id in ^organization_ids))

      Repo.delete_all(
        from(ca in CalendarAttribute, where: ca.organization_id in ^organization_ids)
      )

      Repo.delete_all(from(cd in CalendarDate, where: cd.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      delete_versions!(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^editor_ids))
    end)
  end
end
