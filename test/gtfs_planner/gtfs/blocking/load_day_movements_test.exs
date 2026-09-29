defmodule GtfsPlanner.Gtfs.Blocking.LoadDayMovementsTest do
  @moduledoc """
  EV-14, rejecting FH-14 for CL-14: the day load returns each block's resolution,
  movements and stretches, the day's figures and fleet rows, and a peak taken
  over platform spans — at a query count that does not grow with the day.

  The cases go through the ordinary `Gtfs.load_blocking_day/3` entry on the
  production `CatalogReadAdapter.Repo` and the scoped `Blocking` context, on rows
  created inside the SQL Sandbox transaction and rolled back. Nothing here builds
  a context or a movement by hand: the only way to know the day load hands the
  page a platform span rather than a trip span is to read the day the page reads,
  and FH-14 is exactly "figures use trip spans".

  The numbers the cases assert are the ones the real load produces for the
  fixture's coordinates and times: the entered two-minute pull-out is exact, and
  the estimated drives are the production estimate over stops a hundredth of a
  degree apart on one meridian. Figures are asserted both against those literals
  and against the sum of the day's own movements, so a figure that stopped being
  a sum would fail even where the arithmetic happened to agree.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/load_day_test.exs test/gtfs_planner/gtfs/blocking/load_day_movements_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  # 05:48 and 05:50 in seconds: the entered pull-out's start and the first
  # departure it serves. A day load that measured the peak over trip spans could
  # not report 20_880, because no trip of the day begins then.
  @pull_out_start 20_880
  @first_departure 21_000

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    # Four stops on one meridian, a hundredth of a degree apart, so every trip is
    # plottable and every drive between them has a real distance to estimate.
    for {stop_id, lat} <- [
          {"S1", "40.0000"},
          {"S2", "40.0100"},
          {"S3", "40.0200"},
          {"S4", "40.0300"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    main =
      garage_fixture(organization.id, %{
        "name" => "Main",
        "lat" => Decimal.new("40.0400"),
        "lon" => Decimal.new("-74.0")
      })

    cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

    %{
      organization: organization,
      version: version,
      route: route,
      main: main,
      cutaway: cutaway
    }
  end

  describe "a block's resolution, movements and stretches" do
    test "come off the day the page loads, for a block with a garage", context do
      %{organization: organization, version: version, main: main, cutaway: cutaway} = context

      planning_block(context, "101")
      planning_block(context, "102")
      entered_pull_out(context)

      a = trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      _b = trip!(context, "b", "101", "08:00:00", "09:00:00", "S3", "S1")
      _c = trip!(context, "c", "102", "06:00:00", "07:00:00", "S2", "S4")

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      # This is the first day load that plans rather than measures layovers, and
      # everything below is read off that one context.
      assert day.context.planning? == true

      first = block(day, "101")

      assert first.resolution == %{
               garage_id: main.id,
               vehicle_type_id: cutaway.id,
               garage_source: :attribute,
               conflict: nil
             }

      assert first.movements.pull_out == %{
               source: :entered,
               from: {:garage, main.id},
               to: {:stop, "S1"},
               start_secs: @pull_out_start,
               end_secs: @first_departure,
               drive_secs: 120,
               km: nil
             }

      assert first.movements.pull_back.source == :estimated
      assert first.movements.pull_back.from == {:stop, "S1"}
      assert first.movements.pull_back.to == {:garage, main.id}
      assert first.movements.pull_back.end_secs == first.movements.platform_end_secs

      assert [gap] = first.movements.gaps
      assert gap.index == 0
      assert gap.kind == :drive
      assert gap.source == :estimated
      assert gap.feasible? == true
      assert gap.from_id == a.id
      assert gap.arrival_secs == 24_600
      assert gap.departure_secs == 28_800
      assert gap.drive_secs == 180

      assert first.movements.platform_start_secs == @pull_out_start
      assert first.movements.platform_end_secs == 33_120

      # No relief mark and no `max_piece_minutes`, so R6's answer is the one
      # unrelieved stretch over the whole platform span.
      assert first.stretches == [%{from_secs: @pull_out_start, to_secs: 33_120, secs: 12_240}]
      assert block(day, "102").stretches == [%{from_secs: 21_060, to_secs: 25_380, secs: 4_320}]
    end

    test "a block with no garage has no pull and keeps its trip span", context do
      %{organization: organization, version: version} = context

      trip!(context, "d", "103", "10:00:00", "11:00:00", "S4", "S1")

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      lonely = block(day, "103")

      assert lonely.resolution == %{
               garage_id: nil,
               vehicle_type_id: nil,
               garage_source: :none,
               conflict: nil
             }

      assert lonely.movements.pull_out == nil
      assert lonely.movements.pull_back == nil
      assert lonely.movements.platform_start_secs == 36_000
      assert lonely.movements.platform_end_secs == 39_600

      # With no garage there is no platform span to move the summary's edges, so
      # the trip span stands and the block measures one hour.
      assert lonely.summary.start_secs == 36_000
      assert lonely.summary.end_secs == 39_600
      assert lonely.summary.hours == 1.0
      assert lonely.stretches == [%{from_secs: 36_000, to_secs: 39_600, secs: 3_600}]
    end

    test "rows naming different garages conflict and the day reports the conflict", context do
      %{organization: organization, version: version, main: main, cutaway: cutaway} = context

      # A second service on the same dates is in the same day type, so the block
      # runs on both and both of its rows are read.
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "WK2",
        name: "Weekday 2"
      })

      north =
        garage_fixture(organization.id, %{
          "name" => "North",
          "lat" => Decimal.new("41.0"),
          "lon" => Decimal.new("-74.0")
        })

      planning_block(context, "101")

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "WK2",
        block_id: "101",
        garage_id: north.id,
        vehicle_type_id: cutaway.id
      })

      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      trip!(context, "d", "101", "10:00:00", "11:00:00", "S2", "S1", service_id: "WK2")

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      assert Enum.map(day.day_types, & &1.service_ids) == [["WK", "WK2"]]

      conflicted = block(day, "101")

      assert conflicted.resolution.garage_id == main.id
      assert conflicted.resolution.garage_source == :attribute

      # Every row for the block's services, in `service_id` order, not only the
      # two that disagree.
      assert conflicted.resolution.conflict == [
               %{service_id: "WK", garage_id: main.id, vehicle_type_id: cutaway.id},
               %{service_id: "WK2", garage_id: north.id, vehicle_type_id: cutaway.id}
             ]

      assert [finding] = Enum.filter(day.findings, &(&1.code == :block_attributes_conflict))
      assert finding.severity == :warning
      assert finding.block_id == "101"
      assert finding.detail == %{rows: conflicted.resolution.conflict}

      # A warning is a problem, and a conflict is never silently dropped.
      assert day.counts.problems == 1
      assert day.figures.problems == 1
    end
  end

  describe "the day's figures" do
    setup context do
      planning_block(context, "101")
      planning_block(context, "102")
      entered_pull_out(context)

      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      trip!(context, "b", "101", "08:00:00", "09:00:00", "S3", "S1")
      trip!(context, "c", "102", "06:00:00", "07:00:00", "S2", "S4")
      trip!(context, "d", "103", "10:00:00", "11:00:00", "S4", "S1")

      :ok
    end

    test "are the sums of the day's own movements", context do
      %{organization: organization, version: version} = context

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      movements = Enum.map(day.blocks, & &1.movements)

      assert day.figures.vehicles == length(day.blocks)
      assert day.figures.platform_secs == Enum.sum(Enum.map(movements, &platform_length/1))
      assert day.figures.service_secs == Enum.sum(Enum.map(movements, & &1.service_secs))
      assert day.figures.layover_secs == Enum.sum(Enum.map(movements, & &1.layover_secs))
      assert day.figures.drive_secs == Enum.sum(Enum.map(movements, & &1.drive_secs))

      assert day.figures.service_km ==
               Float.round(Enum.sum(Enum.map(movements, & &1.service_km)), 3)

      assert day.figures.deadhead_km ==
               Float.round(Enum.sum(Enum.map(movements, & &1.deadhead_km)), 3)

      assert day.figures.problems == day.counts.problems
      assert day.figures.problems == 0
    end

    test "count vehicles, the schedule's minimum and the share of time with riders", context do
      %{organization: organization, version: version} = context

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.figures.vehicles == 3

      # R8 over the day's own trips: 05:50-06:55 and 06:00-07:05 overlap, and
      # nothing else does, so two vehicles is the schedule's own minimum.
      assert day.figures.minimum == 2

      assert day.figures.platform_secs == 20_160
      assert day.figures.service_secs == 14_400
      assert day.figures.layover_secs == 4_020
      assert day.figures.drive_secs == 1_740
      assert day.figures.service_km == 8.896
      assert day.figures.deadhead_km == 13.01

      assert day.figures.riders ==
               round(day.figures.service_secs / day.figures.platform_secs * 100)

      assert day.figures.riders == 71
    end
  end

  describe "a day with nothing in it" do
    test "carries empty figures, no fleet row and no stretch", context do
      %{organization: organization, version: version} = context

      # The setup's version has a calendar and therefore a day type, but no trip
      # at all, so this is the day the page shows before anything is blocked.
      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.blocks == []
      assert day.figures.vehicles == 0
      assert day.figures.minimum == 0
      assert day.figures.platform_secs == 0
      assert day.figures.service_secs == 0

      # No platform time to divide by is zero riders, not a crash.
      assert day.figures.riders == 0
      assert day.fleet == []
      assert day.longest_stretch == nil
      assert day.estimated_pairs == 0
      assert day.peak == %{count: 0, at_secs: nil, excluded_unassigned: 0, excluded_frequency: 0}
    end
  end

  describe "the day's peak" do
    test "counts a vehicle from its pull-out, not from its first trip", context do
      %{organization: organization, version: version} = context

      planning_block(context, "101")
      entered_pull_out(context)

      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      _b = trip!(context, "b", "101", "08:00:00", "09:00:00", "S3", "S1")

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      first = block(day, "101")

      # The block's own row of the plan summary and the peak that counts it both
      # start at the pull-out.
      assert first.summary.start_secs == @pull_out_start
      assert hd(first.trips).first_departure == @first_departure
      assert day.peak.count == 1
      assert day.peak.at_secs == @pull_out_start
      assert day.peak.at_secs == first.movements.platform_start_secs

      # The chart is drawn over the same span: the 05:45 bin carries the vehicle
      # two minutes before the trip itself starts, and the 09:00 bin carries it
      # after the trip has ended.
      assert Enum.find(day.bins, &(&1.start_secs == 20_700)) == %{start_secs: 20_700, count: 1}
      assert Enum.find(day.bins, &(&1.start_secs == 32_400)) == %{start_secs: 32_400, count: 1}

      assert day.bins |> Enum.take_while(&(&1.start_secs < 20_700)) |> Enum.all?(&(&1.count == 0))
      assert first.summary.trip_count == 2
    end

    test "counts a block with no garage from its own trip span", context do
      %{organization: organization, version: version} = context

      trip!(context, "d", "103", "10:00:00", "11:00:00", "S4", "S1")

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.peak == %{
               count: 1,
               at_secs: 36_000,
               excluded_unassigned: 0,
               excluded_frequency: 0
             }
    end
  end

  describe "the day's fleet" do
    test "a garage short of its listing raises one page-level problem", context do
      %{organization: organization, version: version, main: main, cutaway: cutaway} = context

      planning_block(context, "101")
      planning_block(context, "102")
      entered_pull_out(context)

      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      trip!(context, "c", "102", "06:00:00", "07:00:00", "S2", "S4")

      # One Cutaway and one untyped vehicle are listed at Main. Two Cutaway blocks
      # run at once, so the typed listing is short and the garage's whole listing
      # is not.
      vehicle_fixture(organization.id, %{"garage_id" => main.id, "vehicle_type_id" => cutaway.id})
      vehicle_fixture(organization.id, %{"garage_id" => main.id, "vehicle_type_id" => nil})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert [typed, whole] = day.fleet
      assert typed.status == :short
      assert typed.vehicle_type_id == cutaway.id
      assert typed.needed == 2
      assert typed.listed == 1
      assert typed.at_secs == 21_060
      assert whole.vehicle_type_id == :all
      assert whole.status == :enough

      assert [finding] = Enum.filter(day.findings, &(&1.code == :fleet_shortfall))

      # A shortfall belongs to the garage and the time, not to one block, so the
      # finding names neither a block nor a trip.
      assert finding.severity == :error
      assert finding.block_id == nil
      assert finding.trip_ids == []
      assert finding.transfer_id == nil

      assert finding.detail == %{
               garage_id: main.id,
               vehicle_type_id: cutaway.id,
               needed: 2,
               listed: 1,
               at_secs: 21_060
             }

      assert day.counts.problems == 1
      assert day.figures.problems == 1
    end

    test "a garage with no vehicles listed is not short", context do
      %{organization: organization, version: version, cutaway: cutaway} = context

      planning_block(context, "101")
      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert [typed, _whole] = day.fleet
      assert typed.status == :not_checked
      assert typed.vehicle_type_id == cutaway.id
      assert typed.needed == 1
      assert typed.listed == 0

      # Nothing is listed at all, so there is no shortfall to report and no
      # problem to count.
      assert Enum.filter(day.findings, &(&1.code == :fleet_shortfall)) == []
      assert day.counts.problems == 0
    end
  end

  describe "the day's estimates and stretches" do
    test "count each estimated pair once and name the block of the longest stretch", context do
      %{organization: organization, version: version} = context

      planning_block(context, "101")
      planning_block(context, "102")
      entered_pull_out(context)

      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      trip!(context, "b", "101", "08:00:00", "09:00:00", "S3", "S1")
      trip!(context, "c", "102", "06:00:00", "07:00:00", "S2", "S4")
      trip!(context, "d", "103", "10:00:00", "11:00:00", "S4", "S1")

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      # The four estimated pairs of the day: 101's S2 → S3 drive and S1 → garage
      # return, 102's garage → S2 pull-out and S4 → garage return. The entered
      # garage → S1 pull-out is measured rather than estimated and is not one of
      # them, and a pair nobody drove is not counted either.
      assert day.estimated_pairs == 4

      assert day.longest_stretch == %{
               block_id: "101",
               from_secs: @pull_out_start,
               to_secs: 33_120,
               secs: 12_240
             }
    end
  end

  describe "scope" do
    test "another organization's attribute rows are not this version's", context do
      %{organization: organization, version: version, main: main, cutaway: cutaway} = context

      planning_block(context, "101")
      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")

      foreign = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign.id)
      foreign_garage = garage_fixture(foreign.id, %{"name" => "Foreign"})

      block_attribute_fixture(foreign.id, foreign_version.id, %{
        service_id: "WK",
        block_id: "101",
        garage_id: foreign_garage.id,
        vehicle_type_id: cutaway.id
      })

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert block(day, "101").resolution == %{
               garage_id: main.id,
               vehicle_type_id: cutaway.id,
               garage_source: :attribute,
               conflict: nil
             }

      refute Map.has_key?(day.context.garages, foreign_garage.id)

      assert day.context.attributes == %{
               {"WK", "101"} => %{garage_id: main.id, vehicle_type_id: cutaway.id}
             }
    end
  end

  # The block's own attribute row: Main and the Cutaway, which is what R4's first
  # rule reads. A block without one is the no-garage case.
  defp planning_block(context, block_id) do
    %{organization: organization, version: version, main: main, cutaway: cutaway} = context

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WK",
      block_id: block_id,
      garage_id: main.id,
      vehicle_type_id: cutaway.id
    })
  end

  # An entered driving time from the garage to the first block's first stop, so
  # the pull-out's own start is exact rather than a function of the distance
  # estimate, and so one pair of the day is measured rather than estimated.
  defp entered_pull_out(context) do
    %{organization: organization, version: version, main: main} = context

    deadhead_time_fixture(organization.id, version.id, %{
      from_ref: {:garage, main.id},
      to_ref: {:stop, "S1"},
      minutes: 2
    })
  end

  # One trip from `first_stop` at `first` to `last_stop` at `last`, so a case can
  # name the endpoints that make the handoff a drive.
  defp trip!(context, trip_id, block_id, first, last, first_stop, last_stop, opts \\ []) do
    %{organization: organization, version: version, route: route} = context
    service_id = Keyword.get(opts, :service_id, "WK")

    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
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

  defp block(day, block_id), do: Enum.find(day.blocks, &(&1.summary.block_id == block_id))

  defp platform_length(%{platform_start_secs: start_secs, platform_end_secs: end_secs}),
    do: end_secs - start_secs
end
