defmodule GtfsPlanner.Gtfs.Export.TransfersValidatorTest do
  @moduledoc """
  Judges the exported `transfers.txt` against the tracked MobilityData validator CLI (EV-6,
  AC-10; EV-14, AC-3 and AC-24).

  The first test's seeded feed is the one the operations validator test uses — agency, two stops,
  one route, the calendar service the trips name, and two trips with ordered stop times — plus a
  stopless type 4 in-seat transfer between the trips and a type 2 stop-to-stop transfer with a
  minimum transfer time. Both must export without an ERROR notice naming `transfers.txt`. A third
  transfer naming a trip that does not exist in `trips.txt` is the negative control: the validator
  must report it as an ERROR `foreign_key_violation` for `transfers.txt`, the failure a feed
  carries when a trip is deleted without the transfers naming it.

  The second test judges the rules the editor writes. Its own organization and version hold an
  agency, a weekly calendar, station `VCEN` with the child platforms `VCEN-A` and `VCEN-C`, the
  standalone stops `VMKT` and `VHBR`, routes `V1`/`V2` and three trips with stop times. Three rules
  are created through `Gtfs.create_general_transfer/2` — a type 2 station-to-station rule, a type 1
  route pair between the two platforms, and a type 0 rule naming `from_trip_id V1-0800`, which
  stops at the station's child platform `VCEN-A`, with both routes — and `transfers.txt` must carry
  exactly the literal CSV rows those rules describe, so an export that drops a created row, renames
  a column or stores the wrong type is rejected here. The report must then carry no ERROR for any
  `transfer_` notice code, which is what the validator's own transfers rules are: the station
  endpoint is what makes the app's transfer-stop coverage match the validator's station expansion.
  The same test refuses `VMKT → VHBR` with `from_trip_id V2-0815`, a trip that never stops at
  `VMKT`, and then inserts that exact row through `transfer_fixture/3` and requires the report to
  carry `transfer_with_invalid_trip_and_stop` as an ERROR, so the refusal is proved to be the
  validator's rule and not a convention of this application.

  The module writes the ZIPs and validator reports of each test to a temporary directory removed
  after the test, and makes no network calls (`--skip_validator_update`). It shells out to the
  configured JDK and the tracked 39 MB jar, so `@moduletag :validator_cli` excludes it from the
  default suite (see `test/test_helper.exs`); branch review runs it explicitly:

      mix test --only validator_cli test/gtfs_planner/gtfs/export/transfers_validator_test.exs

  The third test (EV-7, AC-2, AC-6) judges the record the Blocks authoring command writes: a feed
  with two blocked, consecutive trips is given a `:stay_on_board` connection through
  `Gtfs.set_in_seat_connection/5`, and `transfers.txt` must carry that row with the from-trip's
  last and the to-trip's first stop and no ERROR whose code starts with `transfer_`. The negative
  control is the same pair with a `to_stop_id` the to-trip never visits: the row must reach the
  export whole, the report must carry `transfer_with_invalid_trip_and_stop` as an ERROR, and the
  same row's state through `Gtfs.load_blocking_day/3` must be `{:stale, :stops_changed}`, so the
  validator's rule and the editor's review note are one fact read twice.

  Each test runs the CLI twice inside its own 300-second ExUnit timeout, the prepared EV-6, EV-7
  and EV-14 deadlines.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.GtfsValidatorCli
  alias GtfsPlanner.Repo

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @validator_version "8.0.1"

  @transfers_header "from_stop_id,to_stop_id,from_route_id,to_route_id,from_trip_id,to_trip_id," <>
                      "transfer_type,min_transfer_time"

  # The three editor-created rules as `transfers.txt` must carry them. A nil field is an empty
  # CSV field, so a rule without a selector ends in a comma after its type.
  @editor_transfer_rows [
    "VCEN,VCEN,,,,,2,180",
    "VCEN,VHBR,V1,V2,V1-0800,,0,",
    "VCEN-A,VCEN-C,V1,V2,,,1,"
  ]

  test "the validator accepts stopless in-seat transfers and reports a dangling trip" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_feed(organization.id, version.id)

    tmp_dir = tmp_dir!()

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

  test "the validator accepts the editor's rules and reports the refused trip-and-stop pair" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_editor_feed(organization.id, version.id)

    audit = audit_context(organization.id, version.id)

    assert {:ok, _station_rule} =
             Gtfs.create_general_transfer(
               %{
                 from_stop_id: "VCEN",
                 to_stop_id: "VCEN",
                 transfer_type: 2,
                 min_transfer_time: 180
               },
               audit
             )

    assert {:ok, _route_pair_rule} =
             Gtfs.create_general_transfer(
               %{
                 from_stop_id: "VCEN-A",
                 to_stop_id: "VCEN-C",
                 from_route_id: "V1",
                 to_route_id: "V2",
                 transfer_type: 1
               },
               audit
             )

    assert {:ok, _trip_rule} =
             Gtfs.create_general_transfer(
               %{
                 from_stop_id: "VCEN",
                 to_stop_id: "VHBR",
                 from_route_id: "V1",
                 from_trip_id: "V1-0800",
                 to_route_id: "V2",
                 transfer_type: 0
               },
               audit
             )

    tmp_dir = tmp_dir!()

    clean_zip = export_zip!(tmp_dir, organization.id, version.id, "editor-clean")

    assert {header, rows} = transfers_csv(clean_zip)
    assert header == @transfers_header

    assert rows == Enum.sort(@editor_transfer_rows),
           "the editor-created rules did not export as expected: #{inspect(rows)}"

    clean_report = GtfsValidatorCli.run!(Path.join(tmp_dir, "editor-clean-report"), clean_zip)

    assert clean_report["summary"]["validatorVersion"] == @validator_version

    print_editor_observation("editor-clean", clean_report)

    assert transfers_error_notices(clean_report) == [],
           "the validator rejects the exported transfers.txt: " <>
             inspect(Enum.map(transfers_error_notices(clean_report), & &1["code"]))

    # `transfers_error_notices/1` sees a notice through its sample's filename fields, and the
    # validator's own transfers rules (trip-and-stop, trip-and-route, stop location type) carry
    # only `csvRowNumber` and id fields, so this asserts their whole ERROR family instead.
    assert transfer_rule_error_notices(clean_report) == [],
           "the validator reports a transfers.txt rule ERROR: " <>
             inspect(Enum.map(transfer_rule_error_notices(clean_report), & &1["code"]))

    assert {:error, %Ecto.Changeset{} = changeset} =
             Gtfs.create_general_transfer(
               %{
                 from_stop_id: "VMKT",
                 to_stop_id: "VHBR",
                 from_trip_id: "V2-0815",
                 transfer_type: 0
               },
               audit
             )

    assert [from_trip_id: {message, _opts}] = changeset.errors
    assert message == "This trip doesn't stop here"

    transfer_fixture(organization.id, version.id, %{
      transfer_type: 0,
      from_stop_id: "VMKT",
      to_stop_id: "VHBR",
      from_trip_id: "V2-0815"
    })

    refused_zip = export_zip!(tmp_dir, organization.id, version.id, "editor-refused")

    refused_report =
      GtfsValidatorCli.run!(Path.join(tmp_dir, "editor-refused-report"), refused_zip)

    print_editor_observation("editor-refused", refused_report)

    # The refused row reaches the export whole, so the ERROR below cannot come from an export
    # that silently dropped the row the editor was not allowed to write.
    assert {@transfers_header, refused_rows} = transfers_csv(refused_zip)
    assert "VMKT,VHBR,,,V2-0815,,0," in refused_rows

    notice =
      Enum.find(
        GtfsValidatorCli.notices(refused_report),
        &(&1["code"] == "transfer_with_invalid_trip_and_stop")
      )

    assert notice,
           "the validator did not report transfer_with_invalid_trip_and_stop: " <>
             inspect(Enum.map(transfer_rule_error_notices(refused_report), & &1["code"]))

    assert GtfsValidatorCli.severity(notice) == "ERROR"

    IO.puts(
      "EV-14 editor-refused transfer_with_invalid_trip_and_stop: " <>
        "severity=#{GtfsValidatorCli.severity(notice)} totalNotices=#{notice["totalNotices"]}"
    )
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

  test "the validator accepts a written in-seat record and reports a drifted one" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_block_feed(organization.id, version.id)

    audit = audit_context(organization.id, version.id)

    # A record written through the Blocks authoring command, not a fixture row: the
    # handoff stops are the trips' own endpoints, which is what OpenTripPlanner's
    # `TransferMapper` dereferences.
    assert {:ok, %{choice: :stay_on_board, transfer: written}} =
             Gtfs.set_in_seat_connection("BC-0700", "BC-0800", :stay_on_board, [], audit)

    assert written.from_stop_id == "BSTOP-2"
    assert written.to_stop_id == "BSTOP-3"

    tmp_dir = tmp_dir!()

    written_zip = export_zip!(tmp_dir, organization.id, version.id, "in-seat-written")

    written_report =
      GtfsValidatorCli.run!(Path.join(tmp_dir, "in-seat-written-report"), written_zip)

    print_block_observation("in-seat-written", written_report)

    assert {_, written_rows} = transfers_csv(written_zip)

    assert "BSTOP-2,BSTOP-3,,,BC-0700,BC-0800,4," in written_rows

    # No `transfer_*` ERROR of any kind: the written row is a valid in-seat record
    # for a feed whose trips really are consecutive.
    assert transfer_rule_error_notices(written_report) == [],
           "the validator rejects the written record: " <>
             inspect(Enum.map(transfer_rule_error_notices(written_report), & &1["code"]))

    # The negative control is the same pair with a `to_stop_id` the to-trip never
    # visits — the drift R2 repairs. It reaches the export whole, so the ERROR
    # cannot come from an export that dropped the row. The stop has to be a real
    # exported stop: `BSTOP-1` is one the feed declares and only `BC-0700`
    # visits, so the row trips the trip-and-stop rule rather than the foreign
    # key rule, which a stop id the feed never declares would fire instead.
    transfer_fixture(organization.id, version.id, %{
      transfer_type: 4,
      from_trip_id: "BC-0700",
      to_trip_id: "BC-0800",
      from_stop_id: "BSTOP-2",
      to_stop_id: "BSTOP-1"
    })

    drifted_zip = export_zip!(tmp_dir, organization.id, version.id, "in-seat-drifted")

    drifted_report =
      GtfsValidatorCli.run!(Path.join(tmp_dir, "in-seat-drifted-report"), drifted_zip)

    print_block_observation("in-seat-drifted", drifted_report)

    assert {_, drifted_rows} = transfers_csv(drifted_zip)
    assert "BSTOP-2,BSTOP-1,,,BC-0700,BC-0800,4," in drifted_rows

    notice =
      Enum.find(
        GtfsValidatorCli.notices(drifted_report),
        &(&1["code"] == "transfer_with_invalid_trip_and_stop")
      )

    assert notice,
           "the validator did not report transfer_with_invalid_trip_and_stop: " <>
             inspect(Enum.map(transfer_rule_error_notices(drifted_report), & &1["code"]))

    assert GtfsValidatorCli.severity(notice) == "ERROR"

    IO.puts(
      "EV-7 in-seat-drifted transfer_with_invalid_trip_and_stop: " <>
        "severity=#{GtfsValidatorCli.severity(notice)} totalNotices=#{notice["totalNotices"]}"
    )

    # The same drifted row is the application's own `{:stale, :stops_changed}`: the
    # validator's ERROR and the editor's review note are one fact read twice, and
    # the save repairs it by rewriting the stops.
    assert drifted_state(organization.id, version.id, "BC-0700", "BC-0800") ==
             {:stale, :stops_changed}
  end

  # The state the Blocks day load reports for the pair's one record, from the
  # production read and the one `InSeat.state/2` rule (INV-2).
  defp drifted_state(organization_id, version_id, from_trip_id, to_trip_id) do
    assert {:ok, day} = Gtfs.load_blocking_day(organization_id, version_id, nil)

    state =
      day.in_seat
      |> Map.values()
      |> List.flatten()
      |> Enum.find(fn entry ->
        entry.row.from_trip_id == from_trip_id and entry.row.to_trip_id == to_trip_id and
          entry.row.to_stop_id == "BSTOP-1"
      end)

    assert state, "the day load lists no in-seat record for the drifted pair"

    state.state
  end

  # A feed a Blocks connection can be authored against: agency, one weekly
  # calendar, four stops, one route and two blocked trips whose stop times make
  # them consecutive in block BC-1 with the from-trip ending at `BSTOP-2` and the
  # to-trip starting at `BSTOP-3`.
  defp seed_block_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id,
      agency_id: "BAG",
      agency_name: "Block Transit",
      agency_timezone: "America/Los_Angeles"
    )

    calendar_fixture(organization_id, version_id,
      service_id: "BWK",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    )

    for {stop_id, index} <- Enum.with_index(["BSTOP-1", "BSTOP-2", "BSTOP-3", "BSTOP-4"], 0) do
      stop_fixture(organization_id, version_id,
        stop_id: stop_id,
        stop_name: "Block Stop #{index + 1}",
        stop_lat: "#{40.0 + index / 100.0}",
        stop_lon: "-75.0"
      )
    end

    route_fixture(organization_id, version_id,
      route_id: "BRT",
      route_short_name: "B",
      route_long_name: "Block Route",
      agency_id: "BAG"
    )

    blocked_trip_fixture(organization_id, version_id, "BRT", %{
      trip_id: "BC-0700",
      service_id: "BWK",
      block_id: "BC-1",
      first_stop: "BSTOP-1",
      last_stop: "BSTOP-2",
      first_arrival: "07:00:00",
      last_arrival: "07:30:00"
    })

    blocked_trip_fixture(organization_id, version_id, "BRT", %{
      trip_id: "BC-0800",
      service_id: "BWK",
      block_id: "BC-1",
      first_stop: "BSTOP-3",
      last_stop: "BSTOP-4",
      first_arrival: "08:00:00",
      last_arrival: "08:30:00"
    })
  end

  # A feed the editor path can write against and the validator accepts: agency, weekly calendar,
  # the station `VCEN` with its two child platforms, the two standalone stops, two routes and the
  # three trips whose stop times give every side of the three rules a real witness. `V1-0800`
  # stops at the station's child platform `VCEN-A`, while nothing named `V2-0815` ever stops at
  # `VMKT`, which is what the refusal case and the validator's station expansion are about.
  defp seed_editor_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id,
      agency_id: "VAG",
      agency_name: "Valley Transit",
      agency_timezone: "America/Los_Angeles"
    )

    calendar_fixture(organization_id, version_id,
      service_id: "WKDY",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    )

    stop_fixture(organization_id, version_id,
      stop_id: "VCEN",
      stop_name: "Valley Central",
      location_type: 1,
      stop_lat: "40.0000",
      stop_lon: "-75.0000"
    )

    station_child_fixture(organization_id, version_id, "VCEN-A",
      stop_name: "Valley Central · Bay A",
      platform_code: "A",
      stop_lat: "40.0001",
      stop_lon: "-75.0002"
    )

    station_child_fixture(organization_id, version_id, "VCEN-C",
      stop_name: "Valley Central · Bay C",
      platform_code: "C",
      stop_lat: "40.0002",
      stop_lon: "-74.9998"
    )

    stop_fixture(organization_id, version_id,
      stop_id: "VMKT",
      stop_name: "Market Street",
      stop_lat: "40.0100",
      stop_lon: "-75.0100"
    )

    stop_fixture(organization_id, version_id,
      stop_id: "VHBR",
      stop_name: "Harbor",
      stop_lat: "39.9900",
      stop_lon: "-74.9900"
    )

    route_fixture(organization_id, version_id,
      route_id: "V1",
      route_short_name: "1",
      route_long_name: "Crosstown",
      agency_id: "VAG"
    )

    route_fixture(organization_id, version_id,
      route_id: "V2",
      route_short_name: "2",
      route_long_name: "Harbor Line",
      agency_id: "VAG"
    )

    trip_fixture(organization_id, version_id, "V1",
      trip_id: "V1-0800",
      service_id: "WKDY",
      trip_headsign: "Harbor"
    )

    trip_fixture(organization_id, version_id, "V2",
      trip_id: "V2-0815",
      service_id: "WKDY",
      trip_headsign: "Harbor"
    )

    trip_fixture(organization_id, version_id, "V1",
      trip_id: "V1-0900",
      service_id: "WKDY",
      trip_headsign: "Harbor"
    )

    stop_time_fixture(organization_id, version_id, "V1-0800", "VCEN-A",
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    )

    stop_time_fixture(organization_id, version_id, "V1-0800", "VMKT",
      stop_sequence: 2,
      arrival_time: "08:10:00",
      departure_time: "08:10:00"
    )

    stop_time_fixture(organization_id, version_id, "V2-0815", "VCEN-C",
      stop_sequence: 1,
      arrival_time: "08:15:00",
      departure_time: "08:15:00"
    )

    stop_time_fixture(organization_id, version_id, "V2-0815", "VHBR",
      stop_sequence: 2,
      arrival_time: "08:30:00",
      departure_time: "08:30:00"
    )

    stop_time_fixture(organization_id, version_id, "V1-0900", "VMKT",
      stop_sequence: 1,
      arrival_time: "09:00:00",
      departure_time: "09:00:00"
    )

    stop_time_fixture(organization_id, version_id, "V1-0900", "VHBR",
      stop_sequence: 2,
      arrival_time: "09:10:00",
      departure_time: "09:10:00"
    )
  end

  # A child platform cannot go through `Stop.changeset/2`, which requires a `level_id` for any
  # stop naming a parent station; `Stop.import_changeset/2` is the permissive path the import
  # workflow and `TransfersFixtures` use for the same shape.
  defp station_child_fixture(organization_id, version_id, stop_id, attrs) do
    attrs =
      %{
        stop_id: stop_id,
        parent_station: "VCEN",
        organization_id: organization_id,
        gtfs_version_id: version_id
      }
      |> Map.merge(Map.new(attrs))

    %Stop{}
    |> Stop.import_changeset(attrs)
    |> Repo.insert!()
  end

  defp audit_context(organization_id, version_id) do
    actor = user_fixture()
    organization_membership_fixture(actor, %{id: organization_id})

    %AuditContext{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp tmp_dir! do
    tmp_dir =
      Path.join(System.tmp_dir!(), "transfers_validator_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    tmp_dir
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

  # Reads `transfers.txt` out of an exported ZIP and returns its header line and its data rows
  # sorted, so the comparison against the literal expectations does not depend on row order.
  defp transfers_csv(zip_path) do
    [header | rows] = zip_path |> zip_entry!("transfers.txt") |> String.split("\n", trim: true)

    {header, Enum.sort(rows)}
  end

  defp zip_entry!(zip_path, entry_name) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])

    case Enum.find(entries, fn {name, _content} -> List.to_string(name) == entry_name end) do
      {_name, content} -> content
      nil -> flunk("the export has no #{entry_name}: #{inspect(zip_entries(zip_path))}")
    end
  end

  # The 8.0.1 report gives every notice code one entry with "code", "severity", "totalNotices" and
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

  # The captured output of this module is EV-6's and EV-14's evidence, so each test prints its own
  # gate's observation lines; the rules this test judges are the validator's transfers rules.
  defp print_editor_observation(label, report) do
    codes = report |> error_codes() |> MapSet.to_list() |> Enum.sort()

    IO.puts("EV-14 #{label} export ERROR codes: #{inspect(codes)}")

    case transfer_rule_error_notices(report) do
      [] ->
        IO.puts("EV-14 #{label} export transfers.txt rule ERROR notices: none")

      notices ->
        for notice <- notices do
          IO.puts(
            "EV-14 #{label} export transfers.txt rule ERROR notice: " <>
              "code=#{notice["code"]} totalNotices=#{notice["totalNotices"]}"
          )
        end
    end
  end

  # The captured output of this module is EV-6's, EV-7's and EV-14's evidence, so
  # each test prints its own gate's observation lines; the rules this test judges
  # are the validator's transfers rules.
  defp print_block_observation(label, report) do
    codes = report |> error_codes() |> MapSet.to_list() |> Enum.sort()

    IO.puts("EV-7 #{label} export ERROR codes: #{inspect(codes)}")

    case transfer_rule_error_notices(report) do
      [] ->
        IO.puts("EV-7 #{label} export transfers.txt rule ERROR notices: none")

      notices ->
        for notice <- notices do
          IO.puts(
            "EV-7 #{label} export transfers.txt rule ERROR notice: " <>
              "code=#{notice["code"]} totalNotices=#{notice["totalNotices"]}"
          )
        end
    end
  end

  # Validator 8.0.1's transfers rules are `transfer_with_invalid_trip_and_stop`,
  # `transfer_with_invalid_trip_and_route` and `transfer_with_invalid_stop_location_type` (all
  # ERROR); their samples carry `csvRowNumber` and ids but no filename, so looking for the file in
  # the sample, as `transfers_error_notices/1` does, cannot see them.
  defp transfer_rule_error_notices(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.filter(fn notice ->
      GtfsValidatorCli.severity(notice) == "ERROR" and
        String.starts_with?(notice["code"], "transfer_")
    end)
  end
end
