defmodule GtfsPlanner.Gtfs.Export.OperationsValidatorTest do
  @moduledoc """
  Judges the `:operations` ZIP against the unchanged `:full` ZIP of the same
  version with the tracked MobilityData validator CLI (EV-9, AC-17).

  The module writes both exports and both validator reports to a temporary
  directory removed after the test, and makes no network calls
  (`--skip_validator_update`). It shells out to the configured JDK and the
  tracked 39 MB jar, so `@moduletag :validator_cli` excludes it from the default
  suite (see `test/test_helper.exs`); branch review runs it explicitly:

      mix test --only validator_cli test/gtfs_planner/gtfs/export/operations_validator_test.exs

  The prepared EV-9 deadline covers both CLI invocations together; the single
  test's ExUnit timeout enforces the 300-second process deadline.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.GtfsValidatorCli

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @tods_files ["stops_supplement.txt", "vehicles.txt"]
  @validator_version "7.1.0"

  test "the operations ZIP adds no error-severity notice the full ZIP lacks" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_feed(organization.id, version.id)

    tmp_dir =
      Path.join(System.tmp_dir!(), "validator_compare_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    full_zip = export_zip!(tmp_dir, organization.id, version.id, :full)
    operations_zip = export_zip!(tmp_dir, organization.id, version.id, :operations)

    full_entries = zip_entries(full_zip)
    operations_entries = zip_entries(operations_zip)

    for file <- @tods_files do
      refute file in full_entries
      assert file in operations_entries
    end

    assert Enum.sort(operations_entries) == Enum.sort(full_entries ++ @tods_files)

    full_report = GtfsValidatorCli.run!(Path.join(tmp_dir, "full-report"), full_zip)

    operations_report =
      GtfsValidatorCli.run!(Path.join(tmp_dir, "operations-report"), operations_zip)

    assert report_summary(full_report)["validatorVersion"] == @validator_version
    assert report_summary(operations_report)["validatorVersion"] == @validator_version
    assert report_summary(full_report)["gtfsInput"] =~ "full.zip"
    assert report_summary(operations_report)["gtfsInput"] =~ "operations.zip"

    full_errors = error_codes(full_report)
    operations_errors = error_codes(operations_report)
    tods_notices = tods_file_notices(operations_report)

    print_observation(full_errors, operations_errors, tods_notices)

    assert MapSet.subset?(operations_errors, full_errors),
           "operations-only ERROR codes: " <>
             inspect(MapSet.difference(operations_errors, full_errors))

    assert Enum.all?(tods_notices, fn {_file, _code, severity} -> severity != "ERROR" end),
           "TODS files carry ERROR notices: " <>
             inspect(
               Enum.filter(tods_notices, fn {_file, _code, severity} ->
                 severity == "ERROR"
               end)
             )
  end

  # A feed the validator accepts: agency, two stops, a route, the calendar
  # service the trip names, that trip and its two ordered stop times, plus the
  # operations records the TODS files are written from. The garage ID differs
  # from every stop ID so the export publishes a ZIP.
  defp seed_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id, agency_id: "AG1", agency_name: "Metro Transit")

    stop_fixture(organization_id, version_id, stop_id: "STOP1", stop_name: "First Stop")
    stop_fixture(organization_id, version_id, stop_id: "STOP2", stop_name: "Second Stop")

    route_fixture(organization_id, version_id,
      route_id: "ROUTE1",
      route_short_name: "1",
      route_long_name: "Harbor Line"
    )

    calendar_fixture(organization_id, version_id,
      service_id: "SVC1",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    )

    trip =
      trip_fixture(organization_id, version_id, "ROUTE1",
        trip_id: "TRIP1",
        service_id: "SVC1",
        trip_headsign: "Downtown"
      )

    stop_time_fixture(organization_id, version_id, trip.trip_id, "STOP1",
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    )

    stop_time_fixture(organization_id, version_id, trip.trip_id, "STOP2",
      stop_sequence: 2,
      arrival_time: "08:10:00",
      departure_time: "08:10:00"
    )

    garage_fixture(organization_id, garage_id: "garage_main", name: "Main Garage")

    vehicle_fixture(organization_id,
      vehicle_id: "bus-1",
      vehicle_label: "Old Reliable",
      license_plate: "OR-E285104"
    )
  end

  defp export_zip!(tmp_dir, organization_id, version_id, export_type) do
    {:ok, zip_binary} = Export.export_to_zip(organization_id, version_id, export_type)

    path = Path.join(tmp_dir, "#{export_type}.zip")
    File.write!(path, zip_binary)
    path
  end

  defp zip_entries(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])
    Enum.map(entries, fn {name, _content} -> List.to_string(name) end)
  end

  defp report_summary(report), do: report["summary"]

  # The 7.1.0 report holds one entry per notice code:
  # %{"code" => ..., "severity" => "ERROR" | "WARNING" | "INFO",
  #   "totalNotices" => n, "sampleNotices" => [%{"filename" => ...}, ...]}
  defp error_codes(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.filter(&(GtfsValidatorCli.severity(&1) == "ERROR"))
    |> Enum.map(& &1["code"])
    |> MapSet.new()
  end

  defp tods_file_notices(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.flat_map(fn notice ->
      notice
      |> mentioned_files()
      |> Enum.filter(&(&1 in @tods_files))
      |> Enum.map(fn file -> {file, notice["code"], GtfsValidatorCli.severity(notice)} end)
    end)
  end

  defp mentioned_files(notice) do
    notice
    |> Map.get("sampleNotices", [])
    |> Enum.map(& &1["filename"])
    |> Enum.reject(&is_nil/1)
  end

  defp print_observation(full_errors, operations_errors, tods_notices) do
    IO.puts("EV-9 full ZIP ERROR codes: #{inspect(MapSet.to_list(full_errors) |> Enum.sort())}")

    IO.puts(
      "EV-9 operations ZIP ERROR codes: #{inspect(MapSet.to_list(operations_errors) |> Enum.sort())}"
    )

    case tods_notices do
      [] ->
        IO.puts("EV-9 TODS file notices: none reported")

      notices ->
        for {file, code, severity} <- notices do
          IO.puts("EV-9 TODS file notice: #{file} code=#{code} severity=#{severity}")
        end
    end
  end
end
