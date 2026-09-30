# Step 006 — Check filled feeds with the validator CLI
#
# Independent-oracle test (EV-6): a version holding three imported trips with
# timepoint-only times (one with no last time), exported with
# `estimate: :distance`, keeps no stop-time ERROR notice beyond the single
# `missing_trip_edge` ERROR for the known unfilled trip (validator 8.0.1 names
# it through `tripId` samples without a `stop_times.txt` filename).

defmodule GtfsPlanner.Gtfs.Export.MissingTimesValidatorTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.GtfsValidatorCli

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @validator_version "8.0.1"

  # Trip ids under test; ETU is the known unfilled trip (no last time).
  @filled_trips ["ETA", "ETB"]
  @unfilled_trip "ETU"

  test "estimated trips pass the validator and only the unfilled trip keeps missing_trip_edge" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_feed(organization.id, version.id)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "missing_times_validator_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    zip = export_zip!(tmp_dir, organization.id, version.id)

    # The notice assertions below are vacuous unless the filled and unfilled
    # trips all export their stop times.
    assert stop_time_trips(zip) == ["ETA", "ETB", "ETU"]
    assert_zip_shapes!(zip)

    report = GtfsValidatorCli.run!(Path.join(tmp_dir, "report"), zip)

    assert report["summary"]["validatorVersion"] == @validator_version

    codes = notice_codes(report)

    for code <- [
          "stop_time_with_arrival_before_previous_departure_time",
          "stop_time_with_only_arrival_or_departure_time",
          "stop_time_timepoint_without_times",
          "decreasing_or_equal_stop_time_distance"
        ] do
      refute code in codes, "validator reports #{code}: #{inspect(codes)}"
    end

    # Validator 8.0.1 reports missing_trip_edge for the unfilled trip without
    # naming stop_times.txt in its samples (tripId/stopSequence/specifiedField
    # only), so the oracle reads that notice directly: exactly one, an ERROR,
    # and naming only the known unfilled trip. ETU keeps its blanks (R6 holds
    # per assert_zip_shapes!/1 above); the oracle never fills it.
    edge_notices =
      report
      |> GtfsValidatorCli.notices()
      |> Enum.filter(&(&1["code"] == "missing_trip_edge"))

    assert length(edge_notices) == 1,
           "validator reports no missing_trip_edge notice for the unfilled trip: " <>
             inspect(codes)

    assert GtfsValidatorCli.severity(hd(edge_notices)) == "ERROR"

    assert error_trip_ids(edge_notices) == [@unfilled_trip],
           "missing_trip_edge samples name trips beyond #{@unfilled_trip}: " <>
             inspect(error_trip_ids(edge_notices))

    maybe_write_summary!(report)
    print_observation(report)
  end

  # A feed the validator accepts: agency, the calendar service every trip
  # names, one route, stops with coordinates, and three imported trips whose
  # times sit at timepoints only. ETA carries stored distances (distance
  # shares), ETB carries coordinates only (straight-line shares), ETU has no
  # last time and cannot be estimated.
  defp seed_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id, %{agency_id: "INTERP_AGENCY"})
    calendar_fixture(organization_id, version_id, %{service_id: "SVC"})
    route_fixture(organization_id, version_id, %{route_id: "IR"})

    for {stop_id, lat, lon} <- [
          {"A1", "40.712800", "-74.006000"},
          {"A2", "40.713800", "-74.005000"},
          {"A3", "40.714800", "-74.004000"},
          {"A4", "40.715800", "-74.003000"},
          {"A5", "40.716800", "-74.002000"},
          {"B1", "40.722800", "-74.016000"},
          {"B2", "40.723800", "-74.015000"},
          {"B3", "40.724800", "-74.014000"},
          {"B4", "40.725800", "-74.013000"},
          {"B5", "40.726800", "-74.012000"},
          {"U1", "40.732800", "-74.026000"},
          {"U2", "40.733800", "-74.025000"},
          {"U3", "40.734800", "-74.024000"}
        ] do
      stop_fixture(organization_id, version_id, %{
        stop_id: stop_id,
        stop_name: "Stop #{stop_id}",
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })
    end

    # ETA: anchors 08:00/08:10 over stored distances 0/200/400/2400/3000, so
    # distance shares are exactly 40/80/480 s (spec §4.2 R4 worked example).
    trip_fixture(organization_id, version_id, "IR", %{trip_id: "ETA", service_id: "SVC"})
    seed_distance_blanks(organization_id, version_id, "ETA", "A", "08:00:00", "08:10:00")

    # ETB: no stored distances anywhere in the span, so the whole span falls
    # back to the straight line between stop coordinates (spec §4.2 R5).
    trip_fixture(organization_id, version_id, "IR", %{trip_id: "ETB", service_id: "SVC"})
    seed_coordinate_blanks(organization_id, version_id, "ETB", "B", "09:00:00", "09:10:00")

    # ETU: timed first row, blanks after, no last time — R6 leaves it
    # untouched and the validator keeps missing_trip_edge for it.
    trip_fixture(organization_id, version_id, "IR", %{trip_id: "ETU", service_id: "SVC"})

    stop_time_fixture(organization_id, version_id, "ETU", "U1",
      stop_sequence: 1,
      arrival_time: "10:00:00",
      departure_time: "10:00:00",
      timepoint: 1
    )

    for {stop_id, sequence} <- [{"U2", 2}, {"U3", 3}] do
      stop_time_fixture(organization_id, version_id, "ETU", stop_id,
        stop_sequence: sequence,
        arrival_time: nil,
        departure_time: nil
      )
    end
  end

  defp seed_distance_blanks(organization_id, version_id, trip_id, prefix, first, last) do
    distances = ["0", "200", "400", "2400", "3000"]

    rows =
      for sequence <- 1..5 do
        distance_row_attrs(sequence, first, last, Enum.at(distances, sequence - 1))
      end

    Enum.each(rows, fn attrs ->
      stop_time_fixture(
        organization_id,
        version_id,
        trip_id,
        "#{prefix}#{attrs.stop_sequence}",
        attrs
      )
    end)
  end

  defp distance_row_attrs(1, first, _last, distance) do
    %{
      stop_sequence: 1,
      arrival_time: first,
      departure_time: first,
      timepoint: nil,
      shape_dist_traveled: Decimal.new(distance)
    }
  end

  defp distance_row_attrs(5, _first, last, distance) do
    %{
      stop_sequence: 5,
      arrival_time: last,
      departure_time: last,
      timepoint: 1,
      shape_dist_traveled: Decimal.new(distance)
    }
  end

  defp distance_row_attrs(sequence, _first, _last, distance) do
    %{
      stop_sequence: sequence,
      arrival_time: nil,
      departure_time: nil,
      shape_dist_traveled: Decimal.new(distance)
    }
  end

  defp seed_coordinate_blanks(organization_id, version_id, trip_id, prefix, first, last) do
    rows =
      for sequence <- 1..5 do
        coordinate_row_attrs(sequence, first, last)
      end

    Enum.each(rows, fn attrs ->
      stop_time_fixture(
        organization_id,
        version_id,
        trip_id,
        "#{prefix}#{attrs.stop_sequence}",
        attrs
      )
    end)
  end

  defp coordinate_row_attrs(1, first, _last) do
    %{stop_sequence: 1, arrival_time: first, departure_time: first, timepoint: nil}
  end

  defp coordinate_row_attrs(5, _first, last) do
    %{stop_sequence: 5, arrival_time: last, departure_time: last, timepoint: 1}
  end

  defp coordinate_row_attrs(sequence, _first, _last) do
    %{stop_sequence: sequence, arrival_time: nil, departure_time: nil}
  end

  defp export_zip!(tmp_dir, organization_id, version_id) do
    {:ok, zip_binary} =
      Export.export_to_zip(organization_id, version_id, :full, estimate: :distance)

    path = Path.join(tmp_dir, "missing_times.zip")
    File.write!(path, zip_binary)
    path
  end

  defp stop_time_trips(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])

    {_, content} =
      Enum.find(entries, fn {name, _} -> List.to_string(name) == "stop_times.txt" end)

    [header | lines] = content |> to_string() |> String.split("\n", trim: true)
    columns = String.split(header, ",")

    lines
    |> Enum.map(fn line -> columns |> Enum.zip(String.split(line, ",")) |> Map.new() end)
    |> Enum.map(& &1["trip_id"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Structural shape of the estimated feed: ETA matches the hand-derived R4
  # shares, ETB is fully timed via the straight line, ETU keeps its blanks.
  defp assert_zip_shapes!(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])

    {_, content} =
      Enum.find(entries, fn {name, _} -> List.to_string(name) == "stop_times.txt" end)

    [header | lines] = content |> to_string() |> String.split("\n", trim: true)
    columns = String.split(header, ",")

    rows =
      Enum.map(lines, fn line ->
        columns |> Enum.zip(String.split(line, ",")) |> Map.new()
      end)

    assert trip_rows(rows, "ETA") == [
             {"A1", "08:00:00", "08:00:00", "1"},
             {"A2", "08:00:40", "08:00:40", "0"},
             {"A3", "08:01:20", "08:01:20", "0"},
             {"A4", "08:08:00", "08:08:00", "0"},
             {"A5", "08:10:00", "08:10:00", "1"}
           ]

    for row <- Enum.filter(rows, &(&1["trip_id"] == "ETB")) do
      assert row["arrival_time"] != "", "ETB row #{row["stop_id"]} kept a blank arrival"
      assert row["departure_time"] != "", "ETB row #{row["stop_id"]} kept a blank departure"
    end

    assert trip_rows(rows, "ETU") == [
             {"U1", "10:00:00", "10:00:00", "1"},
             {"U2", "", "", ""},
             {"U3", "", "", ""}
           ]
  end

  defp trip_rows(rows, trip_id) do
    rows
    |> Enum.filter(&(&1["trip_id"] == trip_id))
    |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
    |> Enum.map(fn row ->
      {row["stop_id"], row["arrival_time"], row["departure_time"], row["timepoint"]}
    end)
  end

  # The 8.0.1 report holds one entry per notice code:
  # %{"code" => ..., "severity" => "ERROR" | "WARNING" | "INFO",
  #   "totalNotices" => n, "sampleNotices" => [%{"filename" => ...}, ...]}
  defp notice_codes(report) do
    report |> GtfsValidatorCli.notices() |> Enum.map(& &1["code"])
  end

  # Sample notices name trips under version-dependent keys, so collect every
  # trip-id-like value instead of assuming one key.
  defp error_trip_ids(errors) do
    known = @filled_trips ++ [@unfilled_trip]

    errors
    |> Enum.flat_map(&Map.get(&1, "sampleNotices", []))
    |> Enum.flat_map(&Map.values/1)
    |> Enum.filter(&(&1 in known))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Branch review sets INTERP23_EVIDENCE_DIR to the canonical spec folder; the
  # summary then lands at
  # .specs/23-stop-time-interpolation/evidence/validator-summary.txt. Local
  # runs without the variable still assert everything above and write nothing.
  defp maybe_write_summary!(report) do
    case System.get_env("INTERP23_EVIDENCE_DIR") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "validator-summary.txt"), summary(report))
    end
  end

  defp summary(report) do
    lines =
      report
      |> GtfsValidatorCli.notices()
      |> Enum.map(fn notice ->
        "#{notice["code"]} #{GtfsValidatorCli.severity(notice)} total=#{notice["totalNotices"]}"
      end)
      |> Enum.sort()

    Enum.join(
      [
        "# Missing-times validator summary (EV-6, AC-15)",
        "validator_version=#{report["summary"]["validatorVersion"]}",
        "trips=#{Enum.join(@filled_trips ++ [@unfilled_trip], ",")}"
        | lines
      ],
      "\n"
    ) <> "\n"
  end

  defp print_observation(report) do
    edge =
      report
      |> GtfsValidatorCli.notices()
      |> Enum.filter(&(&1["code"] == "missing_trip_edge"))

    IO.puts(
      "EV-6 missing_trip_edge notices=#{length(edge)} " <>
        "notice codes=#{inspect(notice_codes(report))}"
    )
  end
end
