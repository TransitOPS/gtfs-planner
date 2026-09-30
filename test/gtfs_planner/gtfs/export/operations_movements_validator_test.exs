defmodule GtfsPlanner.Gtfs.Export.OperationsMovementsValidatorTest do
  @moduledoc """
  Judges the `:operations` ZIP carrying movements against the unchanged `:full`
  ZIP of the same version with the tracked MobilityData validator CLI.

  The feed is a blocked day rather than the plain one `operations_validator_test`
  uses: the question here is whether the four movement supplements — their
  service, route, trips and stop times — add anything the validator reports as an
  error that the `:full` ZIP of the same snapshot does not already report. A
  validator that accepted a deadhead file with a stop no stop file has, a trip on
  a service no calendar file has, or a stop time out of order would say so here
  and not in the plain-feed case.

  The module writes both exports and both validator reports to a temporary
  directory removed after the test, and makes no network calls
  (`--skip_validator_update`). It shells out to the configured JDK and the tracked
  39 MB jar, so `@moduletag :validator_cli` excludes it from the default suite
  (see `test/test_helper.exs`); run it explicitly:

      mix test --only validator_cli test/gtfs_planner/gtfs/export/operations_movements_validator_test.exs

  The 300-second deadline covers both CLI invocations together; the single test's
  ExUnit timeout enforces it.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.GtfsValidatorCli

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @movement_files [
    "calendar_dates_supplement.txt",
    "routes_supplement.txt",
    "trips_supplement.txt",
    "stop_times_supplement.txt"
  ]
  @validator_version "7.1.0"

  test "the operations ZIP with movements adds no error-severity notice the full ZIP lacks" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_blocked_feed(organization.id, version.id)

    tmp_dir =
      Path.join(System.tmp_dir!(), "validator_movements_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    full_zip = export_zip!(tmp_dir, organization.id, version.id, :full)
    operations_zip = export_zip!(tmp_dir, organization.id, version.id, :operations)

    full_entries = zip_entries(full_zip)
    operations_entries = zip_entries(operations_zip)

    for file <- @movement_files do
      refute file in full_entries
      assert file in operations_entries
    end

    assert Enum.sort(operations_entries) ==
             Enum.sort(full_entries ++ @movement_files ++ tods_files(operations_entries))

    full_report = GtfsValidatorCli.run!(Path.join(tmp_dir, "full-report"), full_zip)

    operations_report =
      GtfsValidatorCli.run!(Path.join(tmp_dir, "operations-report"), operations_zip)

    assert report_summary(full_report)["validatorVersion"] == @validator_version
    assert report_summary(operations_report)["validatorVersion"] == @validator_version
    assert report_summary(full_report)["gtfsInput"] =~ "full.zip"
    assert report_summary(operations_report)["gtfsInput"] =~ "operations.zip"

    full_errors = error_codes(full_report)
    operations_errors = error_codes(operations_report)
    movement_notices = movement_file_notices(operations_report)

    print_observation(full_errors, operations_errors, movement_notices)

    assert MapSet.subset?(operations_errors, full_errors),
           "operations-only ERROR codes: " <>
             inspect(MapSet.difference(operations_errors, full_errors))

    assert Enum.all?(movement_notices, fn {_file, _code, severity} -> severity != "ERROR" end),
           "movement supplements carry ERROR notices: " <> inspect(movement_notices)
  end

  # A feed the validator accepts, with one blocked day behind it: a garage the
  # vehicle pulls out of, a garage-to-stop driving time, and two trips whose
  # handoff is a deadhead between two stops a kilometre apart, so the export
  # writes a pull-out, a deadhead and a pull-back.
  defp seed_blocked_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id, agency_id: "AG1", agency_name: "Metro Transit")

    route_fixture(organization_id, version_id,
      route_id: "ROUTE1",
      route_short_name: "1",
      route_long_name: "Harbor Line"
    )

    for {stop_id, lat} <- [{"S1", "40.0000"}, {"S2", "40.0100"}] do
      stop_with_coordinates_fixture(organization_id, version_id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "SVC1",
      name: "Every day"
    })

    main =
      garage_fixture(organization_id, %{
        "garage_id" => "garage_main",
        "name" => "Main Garage",
        "lat" => Decimal.new("40.0400"),
        "lon" => Decimal.new("-74.0")
      })

    block_attribute_fixture(organization_id, version_id, %{
      service_id: "SVC1",
      block_id: "101",
      garage_id: main.id
    })

    deadhead_time_fixture(organization_id, version_id, %{
      from_ref: {:garage, main.id},
      to_ref: {:stop, "S1"},
      minutes: 20
    })

    blocked_trip(organization_id, version_id, "a", "101", "06:00:00", "06:50:00", "S1", "S2")
    blocked_trip(organization_id, version_id, "b", "101", "08:00:00", "09:00:00", "S1", "S2")

    vehicle_fixture(organization_id, %{
      "vehicle_id" => "bus-1",
      "vehicle_label" => "Old Reliable",
      "license_plate" => "OR-E285104",
      "garage_id" => main.id
    })
  end

  defp blocked_trip(organization_id, version_id, trip_id, block_id, first, last, from, to) do
    trip =
      trip_fixture(organization_id, version_id, "ROUTE1", %{
        trip_id: trip_id,
        service_id: "SVC1",
        block_id: block_id
      })

    stop_time_fixture(organization_id, version_id, trip_id, from, %{
      stop_sequence: 1,
      arrival_time: first,
      departure_time: first
    })

    stop_time_fixture(organization_id, version_id, trip_id, to, %{
      stop_sequence: 2,
      arrival_time: last,
      departure_time: last
    })

    trip
  end

  # `entries` is the ZIP's own file-name list, so the TODS files are read out of
  # it directly rather than out of a map this module never builds.
  defp tods_files(entries) do
    Enum.filter(entries, &(&1 in ["stops_supplement.txt", "vehicles.txt"]))
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

  defp movement_file_notices(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.flat_map(fn notice ->
      notice
      |> mentioned_files()
      |> Enum.filter(&(&1 in @movement_files))
      |> Enum.map(&{&1, notice["code"], GtfsValidatorCli.severity(notice)})
    end)
  end

  defp mentioned_files(notice) do
    notice
    |> Map.get("sampleNotices", [])
    |> Enum.map(& &1["filename"])
    |> Enum.reject(&is_nil/1)
  end

  defp print_observation(full_errors, operations_errors, movement_notices) do
    IO.puts(
      "validator: full ZIP ERROR codes: #{inspect(full_errors |> MapSet.to_list() |> Enum.sort())}"
    )

    IO.puts(
      "validator: operations ZIP ERROR codes: #{inspect(operations_errors |> MapSet.to_list() |> Enum.sort())}"
    )

    case movement_notices do
      [] ->
        IO.puts("validator: movement file notices: none reported")

      notices ->
        for {file, code, severity} <- notices do
          IO.puts("validator: movement file notice: #{file} code=#{code} severity=#{severity}")
        end
    end
  end
end
