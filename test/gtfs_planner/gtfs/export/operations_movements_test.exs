defmodule GtfsPlanner.Gtfs.Export.OperationsMovementsTest do
  @moduledoc """
  The `:operations` ZIP carries the four movement supplements beside the garages and
  vehicles, leaves every public file byte-identical to `:full`, and resolves every
  reference it writes.

  The cases go through `Export.build_zip/3` and `Export.Worker.build/4` — the
  production composition behind the export page's “GTFS + operations (TODS)”
  option — on rows created inside the SQL Sandbox transaction and rolled back.
  Nothing here builds a movement, a context or a supplement row by hand: a deadhead
  a consumer cannot run is exactly a reference that does not
  resolve, and only the real export can say whether it does.

  The one thing the cases do build themselves is the expectation that each
  movement is on one service of one date, and it is built from the day types' own
  dates rather than from the file, so the assertion cannot read the
  implementation back.

  Run with:
  `mix test test/gtfs_planner/gtfs/export/operations_movements_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.{Run, Worker}
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  @movement_files [
    "calendar_dates_supplement.txt",
    "routes_supplement.txt",
    "trips_supplement.txt",
    "stop_times_supplement.txt"
  ]

  # Every public file the operations ZIP shares with `:full`, asserted as a set so
  # a file the export stops writing cannot pass unnoticed.
  @public_files [
    "calendar.txt",
    "calendar_attributes.txt",
    "routes.txt",
    "stop_times.txt",
    "stops.txt",
    "trips.txt"
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "export-movements-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    route_fixture(organization.id, version.id, route_id: "R1", route_short_name: "1")

    for {stop_id, lat} <- [{"S1", "40.0000"}, {"S2", "40.0100"}, {"S3", "40.0200"}] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    main =
      garage_fixture(organization.id, %{
        "garage_id" => "garage_main",
        "name" => "Main",
        "lat" => Decimal.new("40.0400"),
        "lon" => Decimal.new("-74.0")
      })

    vehicle_fixture(organization.id, %{"garage_id" => main.id})

    %{organization: organization, version: version, main: main, root: root}
  end

  describe "the operations ZIP's movement files" do
    test "sit beside the garages and vehicles, with every reference resolved", context do
      %{organization: organization, version: version} = context
      blocked_day(context)

      {:ok, zip, warnings} = Export.build_zip(organization.id, version.id, :operations)
      entries = zip_entries(zip)

      assert Enum.sort(Map.keys(entries)) ==
               Enum.sort(
                 @movement_files ++ @public_files ++ ["stops_supplement.txt", "vehicles.txt"]
               )

      # The two files a consumer reads a movement out of: the trips it runs as
      # and the two stops it drives between.
      assert entries["trips_supplement.txt"] =~ "pull_out"
      assert entries["trips_supplement.txt"] =~ "pull_back"
      assert entries["trips_supplement.txt"] =~ "deadhead"
      assert entries["routes_supplement.txt"] =~ "deadheads"

      assert warnings == []
      assert_resolved(entries)
    end

    test "leave every public file byte-identical to the full export", context do
      %{organization: organization, version: version} = context
      blocked_day(context)

      operations = operations_entries(context)
      {:ok, full_zip, []} = Export.build_zip(organization.id, version.id, :full)
      full = zip_entries(full_zip)

      for {filename, content} <- full do
        assert Map.get(operations, filename) == content,
               "#{filename} changed between the :full and :operations exports"
      end
    end
  end

  describe "a movement's own service and date" do
    test "a service pair spanning two calendars never writes one movement twice", context do
      %{organization: organization, version: version} = context

      # A second service on the same weekdays is in the same day type, so the
      # block runs on both and the one day type must still describe one service
      # per date, not one per calendar.
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK2", name: "Extra"})

      blocked_day(context)
      trip!(context, "c", "101", "10:00:00", "10:30:00", "S1", "S1", service_id: "WK2")

      entries = operations_entries(context)

      dates = csv_rows(entries["calendar_dates_supplement.txt"])
      movements = csv_rows(entries["trips_supplement.txt"])

      # The expectation is rebuilt from the day types' own dates, not read back
      # out of the file: one service listing the day type's dates, and its
      # `_prev` partner listing each of them a day earlier.
      {:ok, [day_type]} = blocking_day_types(organization.id, version.id)

      expected =
        day_type.dates
        |> Enum.uniq()
        |> Enum.map(&csv_date/1)
        |> Enum.sort()

      {service_id, _prev} = services(dates)

      assert dates_of(dates, service_id) == expected
      assert dates_of(dates, service_id <> "_prev") == Enum.map(expected, &previous_day/1)

      # Every movement is on one of those two services, and none is written
      # twice: a service pair spanning two calendars still describes one day's
      # movements once.
      assert MapSet.new(Enum.map(movements, & &1["service_id"])) ==
               MapSet.new([service_id, service_id <> "_prev"])

      pairs = Enum.map(movements, &{&1["trip_id"], &1["service_id"]})
      assert pairs == Enum.uniq(pairs)
    end

    test "a 00:05 first trip behind a 20-minute pull-out lands on the previous date", context do
      %{organization: organization, version: version} = context
      blocked_day(context)

      entries = operations_entries(context)

      trips = csv_rows(entries["trips_supplement.txt"])
      stop_times = csv_rows(entries["stop_times_supplement.txt"])
      dates = csv_rows(entries["calendar_dates_supplement.txt"])

      pull_out = Enum.find(trips, &(&1["TODS_trip_type"] == "pull_out"))

      assert String.ends_with?(pull_out["service_id"], "_prev")

      assert [from, to] =
               stop_times
               |> Enum.filter(&(&1["trip_id"] == pull_out["trip_id"]))
               |> Enum.sort_by(& &1["stop_sequence"])

      assert {from["arrival_time"], from["stop_id"]} == {"23:45:00", "garage_main"}
      assert {to["arrival_time"], to["stop_id"]} == {"00:05:00", "S1"}

      # The previous service day is a real date of the feed, one day before a
      # date this day type runs, rather than a date invented beside it.
      {:ok, [day_type]} = blocking_day_types(organization.id, version.id)

      day_type_dates = day_type.dates |> Enum.uniq() |> Enum.sort()

      written = dates |> Enum.filter(&(&1["service_id"] == pull_out["service_id"]))
      written = written |> Enum.map(& &1["date"]) |> Enum.sort()

      expected =
        day_type_dates
        |> Enum.map(&(&1 |> Date.add(-1) |> csv_date()))
        |> Enum.sort()

      assert written == expected
    end
  end

  describe "what the export leaves out" do
    test "an organization with no garage omits the movement files and says so" do
      # Garages belong to the organization, not the version, so a version with no
      # garage is an organization with none: it is built in its own.
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      route_fixture(organization.id, version.id, route_id: "R1", route_short_name: "1")

      for {stop_id, lat} <- [{"S1", "40.0000"}, {"S2", "40.0100"}] do
        stop_with_coordinates_fixture(organization.id, version.id, %{
          stop_id: stop_id,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new("-74.0")
        })
      end

      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      blocked = %{
        organization: organization,
        version: version
      }

      # With no garage there is no pull, and a handoff at the same stop is a
      # layover rather than a movement, so this block has nothing to write.
      trip!(blocked, "a", "101", "06:00:00", "06:50:00", "S1", "S1")
      trip!(blocked, "b", "101", "07:00:00", "07:30:00", "S1", "S1")

      {:ok, zip, warnings} = Export.build_zip(organization.id, version.id, :operations)
      entries = zip_entries(zip)

      for file <- @movement_files do
        refute Map.has_key?(entries, file), "#{file} was written with nothing in it"
      end

      omitted =
        Enum.filter(warnings, &(&1.code == "tods_file_omitted" && &1.entity_type == "movement"))

      assert Enum.map(omitted, & &1.file) == @movement_files
      assert Enum.all?(omitted, &(&1.detail =~ "no movements"))
    end

    test "a movement with no driving time is counted, not written", context do
      %{organization: organization, version: version} = context

      # A stop the feed places but does not locate: a handoff from it is a move
      # whose drive can be neither entered nor estimated.
      stop_fixture(organization.id, version.id, stop_id: "NOWHERE", stop_lat: nil, stop_lon: nil)

      blocked_day(context, last_stop: "NOWHERE")
      trip!(context, "c", "101", "10:00:00", "10:30:00", "S1", "S1")

      {:ok, zip, warnings} = Export.build_zip(organization.id, version.id, :operations)
      entries = zip_entries(zip)

      assert [warning] = Enum.filter(warnings, &(&1.code == "tods_movements_omitted"))
      assert warning.detail == "1 movements have no driving time and were left out."

      # The movements a consumer can run are still written: one unknown drive is
      # not the whole day's file.
      assert Enum.all?(@movement_files, &Map.has_key?(entries, &1))
      assert csv_rows(entries["trips_supplement.txt"]) != []
    end

    test "an unpublished version keeps its public files and says the movements are out of reach" do
      organization = organization_fixture()

      {:ok, staging} =
        GtfsPlanner.Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      version = Repo.get!(GtfsPlanner.Versions.GtfsVersion, staging.id)

      route_fixture(organization.id, version.id, route_id: "R1", route_short_name: "1")
      stop_fixture(organization.id, version.id, stop_id: "S1")
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      # A staging version has no day types to this application at all — the day
      # load and the Blocks page refuse one — so the movements are left out and
      # the fact is warned about rather than rolling back an export the caller
      # could always make before.
      {:ok, zip, warnings} = Export.build_zip(organization.id, version.id, :operations)
      entries = zip_entries(zip)

      assert Map.has_key?(entries, "stops.txt")

      for file <- @movement_files do
        refute Map.has_key?(entries, file)
      end

      assert [warning | _rest] = warnings
      assert warning.code == "tods_movements_unavailable"
      assert warning.detail =~ "not published"
    end
  end

  describe "the export run" do
    test "an operations run reaches ready carrying the four movement files", context do
      %{organization: organization, version: version, root: root} = context
      blocked_day(context)

      {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :operations)
      {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

      # The default composition is the concrete `Export` adapter, so this is the
      # run the export page starts rather than a stand-in for it.
      assert Application.get_env(:gtfs_planner, :gtfs_export_module) == nil
      assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

      assert %Run{state: :ready, warnings: []} = Repo.get!(Run, run.id)

      entries = published_zip_entries(root)

      for file <- @movement_files do
        assert Map.has_key?(entries, file), "#{file} was not published"
      end

      assert entries["trips_supplement.txt"] =~ "pull_out"
    end
  end

  # Every reference a consumer must be able to follow, resolved against the files
  # this ZIP itself wrote. A stop resolves to a public stop or a garage; a service
  # resolves through a public calendar or the supplement calendar; a movement's
  # route resolves to a route the export wrote.
  defp assert_resolved(entries) do
    stop_ids =
      ["stops.txt", "stops_supplement.txt"]
      |> Enum.flat_map(fn file -> entries[file] |> csv_rows() |> Enum.map(& &1["stop_id"]) end)
      |> MapSet.new()

    service_ids =
      ["calendar.txt", "calendar_dates.txt", "calendar_dates_supplement.txt"]
      |> Enum.flat_map(fn file ->
        entries[file] |> csv_rows() |> Enum.map(& &1["service_id"]) |> Enum.reject(&is_nil/1)
      end)
      |> MapSet.new()

    route_ids =
      ["routes.txt", "routes_supplement.txt"]
      |> Enum.flat_map(fn file -> entries[file] |> csv_rows() |> Enum.map(& &1["route_id"]) end)
      |> MapSet.new()

    for row <- csv_rows(entries["stop_times_supplement.txt"]) do
      assert MapSet.member?(stop_ids, row["stop_id"]),
             "stop_times_supplement names #{row["stop_id"]}, which no stop file has"
    end

    for row <- csv_rows(entries["trips_supplement.txt"]) do
      assert MapSet.member?(service_ids, row["service_id"]),
             "trips_supplement names #{row["service_id"]}, which no calendar file has"

      assert MapSet.member?(route_ids, row["route_id"])
    end
  end

  # The one service of a day type and its `_prev` partner, matched by suffix so
  # the cases do not recompute the digest.
  defp services(dates) do
    ids = dates |> Enum.map(& &1["service_id"]) |> Enum.uniq() |> Enum.sort()

    {Enum.find(ids, &(not String.ends_with?(&1, "_prev"))),
     Enum.find(ids, &String.ends_with?(&1, "_prev"))}
  end

  defp dates_of(dates, service_id) do
    dates
    |> Enum.filter(&(&1["service_id"] == service_id))
    |> Enum.map(&csv_date(&1["date"]))
    |> Enum.sort()
  end

  # One block with a garage and an entered pull-out, and two trips whose handoff
  # is a drive: the pull-out from the garage, the deadhead between the trips and
  # the pull-back to the garage. The first trip departs at 00:05, so the
  # 20-minute pull-out starts at 23:45 on the previous service day.
  defp blocked_day(context, opts \\ []) do
    %{organization: organization, version: version, main: main} = context
    last_stop = Keyword.get(opts, :last_stop, "S1")

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WK",
      block_id: "101",
      garage_id: main.id
    })

    deadhead_time_fixture(organization.id, version.id, %{
      from_ref: {:garage, main.id},
      to_ref: {:stop, "S1"},
      minutes: 20
    })

    trip!(context, "a", "101", "00:05:00", "06:50:00", "S1", "S2")
    trip!(context, "b", "101", "08:00:00", "09:00:00", "S3", last_stop)
  end

  defp trip!(context, trip_id, block_id, first, last, first_stop, last_stop, opts \\ []) do
    %{organization: organization, version: version} = context
    service_id = Keyword.get(opts, :service_id, "WK")

    trip =
      trip_fixture(organization.id, version.id, "R1", %{
        trip_id: trip_id,
        service_id: service_id,
        block_id: block_id
      })

    stop_time_fixture(organization.id, version.id, trip_id, first_stop, %{
      stop_sequence: 1,
      arrival_time: first,
      departure_time: first
    })

    stop_time_fixture(organization.id, version.id, trip_id, last_stop, %{
      stop_sequence: 2,
      arrival_time: last,
      departure_time: last
    })

    trip
  end

  defp operations_entries(context) do
    %{organization: organization, version: version} = context

    {:ok, zip, _warnings} = Export.build_zip(organization.id, version.id, :operations)
    zip_entries(zip)
  end

  defp zip_entries(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  # The artifact store nests a published ZIP under its organization, version and
  # run directories, so the one regular file under the root is the published ZIP.
  defp published_zip_entries(root) do
    [path] =
      root
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    zip_entries(File.read!(path))
  end

  # The supplement files hold no quoted field and no embedded comma, so their
  # rows split on the delimiter. `GtfsPlanner.Gtfs.Import.CsvParser` is the
  # import path's reader and is not needed to read a file this export wrote.
  defp csv_rows(nil), do: []

  defp csv_rows(content) do
    [header | lines] =
      content
      |> String.trim_trailing("\n")
      |> String.split("\n")

    keys = String.split(header, ",")

    Enum.map(lines, fn line ->
      keys |> Enum.zip(String.split(line, ",")) |> Map.new()
    end)
  end

  defp csv_date(%Date{} = date), do: date |> Date.to_string() |> csv_date()
  defp csv_date(date) when is_binary(date), do: String.replace(date, "-", "")

  # `csv_date/1` compacts to `YYYYMMDD`, so the year, month and day are read back
  # out of that eight-character shape rather than out of a separator the value no
  # longer has.
  defp previous_day(<<year::binary-size(4), month::binary-size(2), day::binary-size(2)>>) do
    Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day))
    |> Date.add(-1)
    |> csv_date()
  end

  defp blocking_day_types(organization_id, gtfs_version_id) do
    {:ok, day} = GtfsPlanner.Gtfs.load_blocking_day(organization_id, gtfs_version_id, nil)
    {:ok, day.day_types}
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
