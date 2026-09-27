defmodule GtfsPlanner.Gtfs.Export.TransfersValidatorTest do
  @moduledoc """
  Judges the exported `transfers.txt` against the tracked MobilityData validator CLI (EV-6,
  AC-10).

  The seeded feed is the one the operations validator test uses — agency, two stops, one route,
  the calendar service the trips name, and two trips with ordered stop times — plus a stopless
  type 4 in-seat transfer between the trips and a type 2 stop-to-stop transfer with a minimum
  transfer time. Both must export without an ERROR notice naming `transfers.txt`. A third transfer
  naming a trip that does not exist in `trips.txt` is the negative control: the validator must
  report it as an ERROR `foreign_key_violation` for `transfers.txt`, the failure a feed carries
  when a trip is deleted without the transfers naming it.

  The module writes both ZIPs and both validator reports to a temporary directory removed after
  the test, and makes no network calls (`--skip_validator_update`). It shells out to the configured
  JDK and the tracked 39 MB jar, so `@moduletag :validator_cli` excludes it from the default suite
  (see `test/test_helper.exs`); branch review runs it explicitly:

      mix test --only validator_cli test/gtfs_planner/gtfs/export/transfers_validator_test.exs

  The single test runs the CLI twice inside one 300-second ExUnit timeout, the prepared EV-6
  deadline.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.GtfsValidatorCli

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @validator_version "7.1.0"

  test "the validator accepts stopless in-seat transfers and reports a dangling trip" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_feed(organization.id, version.id)

    tmp_dir =
      Path.join(System.tmp_dir!(), "transfers_validator_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    clean_zip = export_zip!(tmp_dir, organization.id, version.id, "clean")

    # The export omits empty tables, so the file must be present for the notice assertion below
    # to mean anything.
    assert "transfers.txt" in zip_entries(clean_zip)

    clean_report = GtfsValidatorCli.run!(Path.join(tmp_dir, "clean-report"), clean_zip)

    assert clean_report["summary"]["validatorVersion"] == @validator_version

    print_observation("clean", clean_report)

    assert transfers_error_notices(clean_report) == [],
           "the validator rejects the exported transfers.txt: " <>
             inspect(Enum.map(transfers_error_notices(clean_report), & &1["code"]))

    transfer_fixture(organization.id, version.id, %{
      transfer_type: 0,
      from_stop_id: "STOP2",
      to_stop_id: "STOP1",
      from_trip_id: "GHOST_TRIP"
    })

    dangling_zip = export_zip!(tmp_dir, organization.id, version.id, "dangling")
    dangling_report = GtfsValidatorCli.run!(Path.join(tmp_dir, "dangling-report"), dangling_zip)

    print_observation("dangling", dangling_report)

    foreign_key =
      Enum.find(
        transfers_error_notices(dangling_report),
        &(&1["code"] == "foreign_key_violation")
      )

    assert foreign_key,
           "no foreign_key_violation ERROR names transfers.txt: " <>
             inspect(transfers_error_notices(dangling_report))

    assert Enum.any?(foreign_key["sampleNotices"], fn sample ->
             sample["childFilename"] == "transfers.txt" and
               sample["childFieldName"] == "from_trip_id" and
               sample["fieldValue"] == "GHOST_TRIP"
           end),
           "the foreign-key sample does not name the dangling trip: " <>
             inspect(foreign_key["sampleNotices"])
  end

  # A feed the validator accepts: agency, two stops, a route, the calendar service both trips
  # name, the two trips with their ordered stop times, and the two transfers AC-10 describes.
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

    trip_fixture(organization_id, version_id, "ROUTE1",
      trip_id: "TRIP1",
      service_id: "SVC1",
      trip_headsign: "Downtown"
    )

    trip_fixture(organization_id, version_id, "ROUTE1",
      trip_id: "TRIP2",
      service_id: "SVC1",
      trip_headsign: "Uptown"
    )

    stop_time_fixture(organization_id, version_id, "TRIP1", "STOP1",
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    )

    stop_time_fixture(organization_id, version_id, "TRIP1", "STOP2",
      stop_sequence: 2,
      arrival_time: "08:10:00",
      departure_time: "08:10:00"
    )

    stop_time_fixture(organization_id, version_id, "TRIP2", "STOP2",
      stop_sequence: 1,
      arrival_time: "08:15:00",
      departure_time: "08:15:00"
    )

    stop_time_fixture(organization_id, version_id, "TRIP2", "STOP1",
      stop_sequence: 2,
      arrival_time: "08:25:00",
      departure_time: "08:25:00"
    )

    transfer_fixture(organization_id, version_id, %{
      transfer_type: 4,
      from_trip_id: "TRIP1",
      to_trip_id: "TRIP2"
    })

    transfer_fixture(organization_id, version_id, %{
      transfer_type: 2,
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      min_transfer_time: 120
    })
  end

  defp export_zip!(tmp_dir, organization_id, version_id, name) do
    {:ok, zip_binary} = Export.export_to_zip(organization_id, version_id, :full)

    path = Path.join(tmp_dir, "#{name}.zip")
    File.write!(path, zip_binary)
    path
  end

  defp zip_entries(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])
    Enum.map(entries, fn {name, _content} -> List.to_string(name) end)
  end

  # The 7.1.0 report gives every notice code one entry with "code", "severity", "totalNotices" and
  # "sampleNotices"; a sample's keys are the notice's own field names, so a file-scoped notice
  # carries "filename" and a foreign-key violation carries "childFilename".
  defp error_codes(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.filter(&(GtfsValidatorCli.severity(&1) == "ERROR"))
    |> Enum.map(& &1["code"])
    |> MapSet.new()
  end

  defp transfers_error_notices(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.filter(fn notice ->
      GtfsValidatorCli.severity(notice) == "ERROR" and "transfers.txt" in sample_files(notice)
    end)
  end

  defp sample_files(notice) do
    notice
    |> Map.get("sampleNotices", [])
    |> Enum.flat_map(&[&1["filename"], &1["childFilename"]])
    |> Enum.reject(&is_nil/1)
  end

  defp print_observation(label, report) do
    codes = report |> error_codes() |> MapSet.to_list() |> Enum.sort()

    IO.puts("EV-6 #{label} export ERROR codes: #{inspect(codes)}")

    case transfers_error_notices(report) do
      [] ->
        IO.puts("EV-6 #{label} export transfers.txt ERROR notices: none")

      notices ->
        for notice <- notices do
          IO.puts(
            "EV-6 #{label} export transfers.txt ERROR notice: " <>
              "code=#{notice["code"]} totalNotices=#{notice["totalNotices"]}"
          )
        end
    end
  end
end
