defmodule GtfsPlanner.Gtfs.Blocking.ValidatorParityTest do
  @moduledoc """
  Judges the Blocks `:overlap` rule against the MobilityData validator CLI on the same
  exported feed (EV-8, AC-4, R4; the external oracle for CL-2).

  The oracle is the validator's own `block_trips_with_overlapping_stop_times` notice: the
  module exports the version with `Export.export_to_zip/3`, runs the tracked 7.1.0 jar with
  `--skip_validator_update`, and compares its reported `{tripIdA, tripIdB}` pairs with the
  `:overlap` findings of every day type through the ordinary `Gtfs.load_blocking_day/3`
  entry, mapped back to natural trip IDs.

  One block per shape EV-8 names, on three services so the feed has three day types:

  | block | shape | expected |
  |---|---|---|
  | `NEST` | triple nest: A spans B and C | A–B, A–C, B–C |
  | `EXEMPT` | both exemption equalities hold (A last 09:00/09:05, B first 09:00/09:05, different stops) | none |
  | `DEPARTURE` | only the departure equality holds (A last 09:00/09:00, B first 08:55/09:00) | A–B |
  | `TOUCH` | touching trips (A last departure 10:30 = B first arrival 10:30) | none |
  | `DWELL` | terminal dwell: A's last departure is after B's first arrival while A's last arrival is before it | A–B |
  | `NIGHT` | after-midnight pair in a block that also holds a 05:00 trip | N–A, not the 05:00 trip |
  | `DISJOINT` | the same block ID on a Wednesday service and a Saturday service | none |

  `DEPARTURE` and `DWELL` are the two counterexamples to the exact-equality exemption that
  must still be reported, and `DISJOINT` exercises R2's day-type scoping: the two trips never
  meet in one day type, and the validator finds no shared service date.

  Because the call starts a JVM, the module carries `@moduletag :validator_cli`, which
  `test/test_helper.exs` excludes from the default suite, plus a 300-second ExUnit timeout (the
  card's deadline). Branch review runs it explicitly:

      mix test --only validator_cli test/gtfs_planner/gtfs/blocking/validator_parity_test.exs

  A skipped run is a failed gate, so `GtfsValidatorCli.run!/2` fails loudly with the configured
  `:java_path` or `:gtfs_validator_path` when either is missing. The exported ZIP and the
  report live in one temporary directory removed after the test, and no network request is made.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.GtfsValidatorCli

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @validator_version "7.1.0"
  @overlap_code "block_trips_with_overlapping_stop_times"

  # Mon-Fri, Wednesday and Saturday services over the fixture's 2026 window: WKDY and MID
  # share every Wednesday, and both are disjoint from SAT.
  @weekday "WKDY"
  @midweek "MID"
  @saturday "SAT"

  # {trip_id, service_id, block_id, first_arrival, first_departure, last_arrival,
  # last_departure}. Every trip gets its own first and last stop, so the exempt block's
  # equal times are at different stops.
  @trips [
    {"nest_a", @weekday, "NEST", "06:00:00", "06:00:00", "08:00:00", "08:00:00"},
    {"nest_b", @weekday, "NEST", "06:10:00", "06:10:00", "07:00:00", "07:00:00"},
    {"nest_c", @weekday, "NEST", "06:20:00", "06:20:00", "07:30:00", "07:30:00"},
    {"exempt_a", @weekday, "EXEMPT", "08:00:00", "08:00:00", "09:00:00", "09:05:00"},
    {"exempt_b", @weekday, "EXEMPT", "09:00:00", "09:05:00", "10:00:00", "10:00:00"},
    {"departure_a", @weekday, "DEPARTURE", "08:00:00", "08:00:00", "09:00:00", "09:00:00"},
    {"departure_b", @weekday, "DEPARTURE", "08:55:00", "09:00:00", "09:30:00", "09:30:00"},
    {"touch_a", @weekday, "TOUCH", "10:00:00", "10:00:00", "10:30:00", "10:30:00"},
    {"touch_b", @weekday, "TOUCH", "10:30:00", "10:30:00", "11:00:00", "11:00:00"},
    {"dwell_a", @weekday, "DWELL", "11:00:00", "11:00:00", "11:30:00", "11:40:00"},
    {"dwell_b", @weekday, "DWELL", "11:35:00", "11:35:00", "12:00:00", "12:00:00"},
    {"night_day", @weekday, "NIGHT", "05:00:00", "05:00:00", "06:00:00", "06:00:00"},
    {"night_a", @weekday, "NIGHT", "24:30:00", "24:30:00", "25:10:00", "25:10:00"},
    {"night_b", @weekday, "NIGHT", "25:00:00", "25:00:00", "25:30:00", "25:30:00"},
    {"disjoint_mid", @midweek, "DISJOINT", "13:00:00", "13:00:00", "14:00:00", "14:00:00"},
    {"disjoint_sat", @saturday, "DISJOINT", "13:00:00", "13:00:00", "14:00:00", "14:00:00"}
  ]

  # R4 applied by hand to @trips: the six reported pairs. EXEMPT, TOUCH and DISJOINT
  # contribute none, which the assertions below state separately.
  @expected_pairs [
    {"nest_a", "nest_b"},
    {"nest_a", "nest_c"},
    {"nest_b", "nest_c"},
    {"departure_a", "departure_b"},
    {"dwell_a", "dwell_b"},
    {"night_a", "night_b"}
  ]

  test "the validator reports exactly the Blocks overlap pairs on this feed" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id,
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Harbor Line"
      )

    seed_feed(organization.id, version.id, route.route_id)

    days = loaded_days(organization.id, version.id)
    blocks_pairs = days |> Enum.flat_map(&day_overlap_pairs/1) |> MapSet.new()
    validator_pairs = validator_overlap_pairs(organization.id, version.id)

    assert validator_pairs == blocks_pairs,
           "the validator and Blocks disagree on the overlap pairs: " <>
             inspect(pair_set_diff(validator_pairs, blocks_pairs))

    expected = MapSet.new(@expected_pairs)

    assert blocks_pairs == expected,
           "the loaded day types do not hold the pairs R4 derives from this fixture: " <>
             inspect(pair_set_diff(blocks_pairs, expected))

    # The three shapes that must contribute no pair, asserted on both sides so a fixture
    # that stopped exercising them cannot pass by producing the same set twice.
    for {left, right} <- [
          {"exempt_a", "exempt_b"},
          {"touch_a", "touch_b"},
          {"disjoint_mid", "disjoint_sat"}
        ] do
      pair = sorted_pair(left, right)

      refute MapSet.member?(validator_pairs, pair),
             "the validator reported #{left}–#{right}, which this fixture declares non-overlapping"

      refute MapSet.member?(blocks_pairs, pair),
             "Blocks reported #{left}–#{right}, which this fixture declares non-overlapping"
    end

    # Three day types: the shared Wednesday service makes WKDY and MID run together there.
    day_type_services = days |> Enum.map(& &1.day_type.service_ids) |> Enum.sort()
    assert day_type_services == Enum.sort([[@weekday], [@midweek, @weekday], [@saturday]])

    # After-midnight ordering through the real load: 24:30 and 25:00 sequence after the
    # block's 05:00 trip rather than by clock string.
    weekday = weekday_day(days)
    assert weekday, "no WKDY-only day type was loaded"

    night = Enum.find(weekday.blocks, &(&1.summary.block_id == "NIGHT"))
    assert night, "the WKDY day type holds no NIGHT block"
    assert Enum.map(night.trips, & &1.trip_id) == ["night_day", "night_a", "night_b"]
  end

  defp seed_feed(organization_id, version_id, route_id) do
    agency_fixture(organization_id, version_id, agency_id: "AG1", agency_name: "Metro Transit")

    calendar_service_fixture(organization_id, version_id, %{service_id: @weekday, name: "Weekday"})

    calendar_service_fixture(organization_id, version_id, %{
      service_id: @midweek,
      name: "Midweek",
      monday: 0,
      tuesday: 0,
      wednesday: 1,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: @saturday,
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0
    })

    for {trip_id, service_id, block_id, first_arrival, first_departure, last_arrival,
         last_departure} <- @trips do
      blocked_trip_fixture(organization_id, version_id, route_id, %{
        trip_id: trip_id,
        service_id: service_id,
        block_id: block_id,
        first_arrival: first_arrival,
        first_departure: first_departure,
        last_arrival: last_arrival,
        last_departure: last_departure
      })
    end
  end

  # Loads the day the way the page does: once to learn the day types, then once per day
  # type key so every day type's pairs are collected.
  defp loaded_days(organization_id, version_id) do
    assert {:ok, day} = Gtfs.load_blocking_day(organization_id, version_id, nil)
    assert day.day_types != []

    Enum.map(day.day_types, fn day_type ->
      assert {:ok, loaded} = Gtfs.load_blocking_day(organization_id, version_id, day_type.key)
      loaded
    end)
  end

  defp weekday_day(days) do
    Enum.find(days, &(&1.day_type.service_ids == [@weekday]))
  end

  # The day's `:overlap` errors as natural trip ID pairs. Findings carry trip UUIDs, so
  # they are mapped through the day's own rows; an overlap always comes from a block, and
  # every block trip is loaded.
  defp day_overlap_pairs(day) do
    natural_ids = Map.new(all_rows(day), &{&1.id, &1.trip_id})

    day.findings
    |> Enum.filter(&(&1.code == :overlap))
    |> Enum.map(fn %{trip_ids: [a, b]} ->
      sorted_pair(Map.fetch!(natural_ids, a), Map.fetch!(natural_ids, b))
    end)
  end

  defp all_rows(day), do: Enum.flat_map(day.blocks, & &1.trips) ++ day.pool

  defp validator_overlap_pairs(organization_id, version_id) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "blocking_parity_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, zip} = Export.export_to_zip(organization_id, version_id, :full)
    zip_path = Path.join(tmp_dir, "full.zip")
    File.write!(zip_path, zip)

    report = GtfsValidatorCli.run!(Path.join(tmp_dir, "report"), zip_path)

    assert report["summary"]["validatorVersion"] == @validator_version

    notice = Enum.find(GtfsValidatorCli.notices(report), &(&1["code"] == @overlap_code))

    assert notice,
           "the report has no #{@overlap_code} notice; reported codes: " <>
             inspect(Enum.map(GtfsValidatorCli.notices(report), & &1["code"]) |> Enum.sort())

    assert GtfsValidatorCli.severity(notice) == "ERROR"

    samples = notice["sampleNotices"]

    # The fixture is far below the sample limit, so every reported pair must be sampled.
    assert notice["totalNotices"] == length(samples),
           "#{@overlap_code} reported #{notice["totalNotices"]} notices but sampled #{length(samples)}"

    samples
    |> Enum.map(&sorted_pair(Map.fetch!(&1, "tripIdA"), Map.fetch!(&1, "tripIdB")))
    |> MapSet.new()
  end

  defp sorted_pair(left, right), do: Enum.min_max([left, right])

  defp pair_set_diff(left, right) do
    %{
      only_left: left |> MapSet.difference(right) |> Enum.sort(),
      only_right: right |> MapSet.difference(left) |> Enum.sort()
    }
  end
end
