defmodule GtfsPlanner.Gtfs.Blocking.MovementsTest do
  @moduledoc """
  Merge evidence (EV-40) for CL-40 / R2 and R3: pulls, gaps, the platform span,
  the totals and the distances of one block.

  Every expected movement time is derived here from the R1/R3 rules rather than
  from the module under test. The expected great-circle distance is computed in
  this file from the haversine formula with the same 6 371 000 m earth radius the
  production helper uses, and the expected minutes are R1's formula over that
  independently computed distance, so a change to the estimate or to the movement
  arithmetic cannot quietly redefine the expectation. One degree of latitude
  measures about 111 194.9 m on this sphere, and at the version defaults 30 km/h
  is 500 m per minute with 1.3 circuity.

  The geometries below are each chosen to land on a whole-minute answer, and each
  is asserted against its own literal as well as the formula:

    * 0.0415° ≈ 4 614.6 m ≈ 4614.6 × 1.3 ÷ 500 = 12 min (the garage pull)
    * 0.0475° ≈ 5 281.8 m ≈ 5281.8 × 1.3 ÷ 500 = 14 min (the 8-minute gap)
    * 0.00108° ≈ 120.1 m, inside `Checks`' 200 m nearby threshold (a layover)
    * a 20-minute pull-out is *entered*, so the negative-start case does not
      depend on a coordinate guess

  The module under test is pure: it reads its arguments and touches no database,
  clock, file or network, so these cases run in the local ExUnit process with no
  sandbox, no fixtures and no cleanup.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/movements_test.exs`. This test
  establishes the movement arithmetic, the gap classification and the totals. It
  says nothing about whether a version's entered driving times or garages are
  correct: those are read from the database and are EV-14's subject.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements

  @earth_radius_m 6_371_000.0
  @circuity 1.3
  @metres_per_minute 500.0

  @garage_uuid "0f2b3a4c-5d6e-4f70-8a91-b2c3d4e5f607"
  @type_uuid "1a2b3c4d-5e6f-4a70-8b91-c2d3e4f50617"
  @t1_id "2c3d4e5f-6071-4a82-93a4-b5c6d7e8f901"
  @t2_id "3d4e5f60-7182-4a93-84b5-c6d7e8f90112"

  # Main Garage sits 4 614.6 m from Riverside Bay A, a 12-minute pull.
  @depot {42.0415, -71.0}
  @bay_a {42.0, -71.0}
  # Northgate is 5 281.8 m away, a 14-minute drive.
  @northgate {42.0475, -71.0}

  # Stop references in the shape `Blocking.Queries.trip_rows/3` hands over,
  # including the parent station's substituted coordinates for a stop that has
  # none of its own. They are written out as literals because a module attribute
  # cannot call a function defined further down the module.
  @default_last_stop %{stop_id: "S1", name: "S1", parent_station: nil, lat: 42.0, lon: -71.0}
  @last_stop @default_last_stop
  @first_stop %{stop_id: "S2", name: "S2", parent_station: nil, lat: 42.00108, lon: -71.0}
  @station_stop %{
    stop_id: "S3",
    name: "S3",
    parent_station: "Riverside Station",
    lat: 42.00108,
    lon: -71.0
  }
  @stationized %{
    stop_id: "S1",
    name: "S1",
    parent_station: "Riverside Station",
    lat: 42.0,
    lon: -71.0
  }
  @far_first_stop %{stop_id: "S9", name: "S9", parent_station: nil, lat: 42.0475, lon: -71.0}
  @far_last_stop %{stop_id: "S10", name: "S10", parent_station: nil, lat: 42.0475, lon: -71.0}
  @no_coords %{stop_id: "NX", name: "NX", parent_station: nil, lat: nil, lon: nil}
  @night_first_stop %{stop_id: "N1", name: "N1", parent_station: nil, lat: 42.0, lon: -71.0}
  @night_last_stop %{stop_id: "N2", name: "N2", parent_station: nil, lat: 42.0, lon: -71.0}

  describe "pull-out" do
    test "ends at the first departure less the buffer and starts one drive earlier" do
      movements = Movements.build([trip("06:00")], resolved(), context())

      pull = movements.pull_out
      assert pull.end_secs == 21_600
      assert pull.start_secs == 21_600 - 12 * 60
      assert pull.drive_secs == 12
      assert pull.source == :estimated
      assert pull.from == {:garage, @garage_uuid}
      assert pull.to == {:stop, "S1"}
      assert movements.garage_id == @garage_uuid
      assert movements.vehicle_type_id == @type_uuid
    end

    test "the estimated pull is R1's formula over the garage-to-stop distance" do
      movements = Movements.build([trip("06:00")], resolved(), context())

      metres = haversine_m(@depot, @bay_a)
      assert_in_delta metres, 4_614.6, 0.1
      assert round(metres * @circuity / @metres_per_minute) == 12
      assert movements.pull_out.drive_secs == 12
    end

    test "a five-minute buffer moves the end back and the start with it" do
      movements =
        Movements.build([trip("06:00")], resolved(), context(pull_out_buffer_minutes: 5))

      assert movements.pull_out.end_secs == 21_600 - 300
      assert movements.pull_out.start_secs == 21_600 - 300 - 12 * 60
      assert clock(21_600 - 300) == "05:55"
      assert clock(21_600 - 300 - 12 * 60) == "05:43"
    end

    test "a 00:05 departure behind a 20-minute pull-out starts at -900 s, not 23:45" do
      context =
        context(entered_minutes: %{{{:garage, @garage_uuid}, {:stop, "N1"}} => 20})

      movements =
        Movements.build(
          [trip("00:05", first_stop: @night_first_stop, last_stop: @night_last_stop)],
          resolved(),
          context
        )

      pull = movements.pull_out
      assert pull.drive_secs == 20
      assert pull.source == :entered
      assert pull.end_secs == 300
      assert pull.start_secs == -900

      # The negative start is a real instant before 00:00 rather than wrapped
      # into the same day, so the UI's "−1d" is presentation only.
      assert clock(pull.start_secs) == "-00:15"
      assert clock(86_400 + pull.start_secs) == "23:45"
    end
  end

  describe "pull-back" do
    test "starts one buffer after the last arrival and ends one drive later" do
      movements =
        Movements.build([trip("06:00")], resolved(), context(pull_out_buffer_minutes: 3))

      pull = movements.pull_back
      assert pull.from == {:stop, "S1"}
      assert pull.to == {:garage, @garage_uuid}
      assert pull.start_secs == 21_900 + 180
      assert pull.end_secs == 21_900 + 180 + 12 * 60
      assert pull.drive_secs == 12
      assert pull.source == :estimated
    end

    test "a 25:10 last arrival ends above 86,400 s rather than wrapping" do
      movements =
        Movements.build(
          [trip("06:00", last_arrival: 91_800)],
          resolved(),
          context(pull_out_buffer_minutes: 5)
        )

      pull = movements.pull_back
      assert pull.start_secs == 91_800 + 300
      assert pull.end_secs == 92_100 + 720
      assert pull.end_secs > 86_400
      assert clock(pull.end_secs) == "25:47"
    end
  end

  describe "gaps" do
    test "a same-stop handoff is a layover whose wait is the whole gap" do
      movements =
        Movements.build(
          [trip("06:00"), trip("06:30", first_stop: @last_stop, last_stop: @first_stop)],
          resolved(),
          context()
        )

      gap = only_gap(movements)
      assert gap.kind == :layover
      assert gap.gap_secs == 1_800
      assert gap.wait_secs == 1_800
      assert gap.drive_secs == nil
      assert gap.source == nil
      assert gap.feasible? == true
      assert gap.km == nil
    end

    test "a same-station handoff is a layover" do
      movements =
        Movements.build(
          [
            trip("06:00", last_stop: @stationized),
            trip("06:30", first_stop: @station_stop, last_stop: @far_last_stop)
          ],
          resolved(),
          context()
        )

      assert only_gap(movements).kind == :layover
    end

    test "a 120 m nearby handoff is a layover, per R2" do
      movements =
        Movements.build(
          [trip("06:00"), trip("06:30", first_stop: @first_stop, last_stop: @far_last_stop)],
          resolved(),
          context()
        )

      gap = only_gap(movements)
      assert gap.kind == :layover
      assert gap.wait_secs == gap.gap_secs
      assert gap.drive_secs == nil
    end

    test "a move with a 14-minute drive in an 8-minute gap is infeasible with wait -6" do
      movements =
        Movements.build(
          [
            trip("06:00", last_arrival: 21_600),
            zero_length_trip("06:08", @far_first_stop, @far_last_stop)
          ],
          resolved(),
          context()
        )

      gap = only_gap(movements)
      assert gap.gap_secs == 480
      assert gap.drive_secs == 14 * 60
      assert gap.kind == :drive
      assert gap.source == :estimated
      assert gap.wait_secs == -360
      assert gap.feasible? == false
    end

    test "the same gap with an entered 7-minute drive waits 1 minute and is feasible" do
      movements =
        Movements.build(
          [
            trip("06:00", last_arrival: 21_600),
            zero_length_trip("06:08", @far_first_stop, @far_last_stop)
          ],
          resolved(),
          context(entered_minutes: %{{{:stop, "S1"}, {:stop, "S9"}} => 7})
        )

      gap = only_gap(movements)
      assert gap.drive_secs == 7 * 60
      assert gap.source == :entered
      assert gap.wait_secs == 60
      assert gap.feasible? == true
    end

    test "an entered value is directional: the reverse pair still estimates" do
      movements =
        Movements.build(
          [
            trip("06:00", last_arrival: 21_600, last_stop: @far_first_stop),
            zero_length_trip("06:08", @last_stop, @first_stop)
          ],
          resolved(),
          context(entered_minutes: %{{{:stop, "S1"}, {:stop, "S9"}} => 7})
        )

      gap = only_gap(movements)
      assert gap.kind == :drive
      assert gap.source == :estimated
      assert gap.drive_secs == 14 * 60
    end

    test "a stop without coordinates is unknown, never a zero-minute drive" do
      movements =
        Movements.build(
          [
            trip("06:00", last_arrival: 21_600),
            zero_length_trip("06:08", @no_coords, @far_last_stop)
          ],
          resolved(),
          context()
        )

      gap = only_gap(movements)
      assert gap.kind == :unknown
      assert gap.drive_secs == nil
      assert gap.source == :unknown
      assert gap.wait_secs == nil
      assert gap.feasible? == nil
      assert gap.km == nil
    end

    test "an endpoint the feed does not describe leaves that gap unknown" do
      movements =
        Movements.build(
          [trip("06:00", last_arrival: 21_600, last_stop: nil), zero_length_trip("06:08")],
          resolved(),
          context()
        )

      assert only_gap(movements).kind == :unknown
    end

    test "gap indexes are consecutive from zero and each gap names its pair" do
      [one, two, three] = [
        trip("06:00", id: @t1_id),
        trip("06:30", id: @t2_id, first_stop: @first_stop, last_stop: @station_stop),
        trip("07:00",
          id: "4e5f6071-8293-4ba4-95c6-d7e8f9011223",
          first_stop: @far_first_stop,
          last_stop: @far_last_stop
        )
      ]

      movements = Movements.build([one, two, three], resolved(), context())

      assert [first, second] = movements.gaps
      assert Enum.map(movements.gaps, & &1.index) == [0, 1]
      assert first.arrival_secs == 21_900
      assert first.departure_secs == 22_800
      assert second.arrival_secs == 23_100
      assert second.departure_secs == 25_200
      assert {first.from_id, first.to_id} == {one.id, two.id}
      assert {second.from_id, second.to_id} == {two.id, three.id}
    end
  end

  describe "no resolvable garage" do
    test "has no pulls and spans the first departure to the last arrival" do
      movements =
        Movements.build(
          [trip("06:00"), trip("06:30", first_stop: @first_stop, last_stop: @far_last_stop)],
          %{resolved() | garage_id: nil, garage_source: :none},
          context()
        )

      assert movements.pull_out == nil
      assert movements.pull_back == nil
      assert movements.garage_id == nil
      assert movements.platform_start_secs == 21_600
      assert movements.platform_end_secs == 23_100
      assert movements.drive_secs == 0
      assert movements.deadhead_km == 0.0
    end

    test "an endpoint stop the feed does not describe also leaves the pull out" do
      movements = Movements.build([trip("06:00", first_stop: nil)], resolved(), context())

      assert movements.pull_out == nil
      assert movements.pull_back == nil
      assert movements.platform_start_secs == 21_600
      assert movements.platform_end_secs == 21_900
    end

    test "an empty block has no pulls, no gaps, no span and zero totals" do
      movements = Movements.build([], resolved(), context())

      assert movements.pull_out == nil
      assert movements.pull_back == nil
      assert movements.gaps == []
      assert movements.platform_start_secs == nil
      assert movements.platform_end_secs == nil
      assert movements.service_secs == 0
      assert movements.layover_secs == 0
      assert movements.drive_secs == 0
      assert movements.service_km == 0.0
      assert movements.service_km_estimated? == false
      assert movements.deadhead_km == 0.0
    end
  end

  describe "totals" do
    test "service, layover and drive add up over the block's legs" do
      movements =
        Movements.build(
          [
            trip("06:00"),
            trip("06:30", first_stop: @first_stop, last_stop: @last_stop),
            trip("07:00", first_stop: @far_first_stop, last_stop: @last_stop)
          ],
          resolved(),
          context()
        )

      # Three trips of five minutes each.
      assert movements.service_secs == 900

      # Gap 1 is a 15-minute nearby layover; gap 2 is 35 minutes against a
      # 14-minute drive, so 21 minutes of wait.
      assert movements.gaps |> Enum.map(& &1.gap_secs) == [900, 2_100]
      assert movements.layover_secs == 900 + 1_260

      # Two 12-minute pulls and one 14-minute drive.
      assert movements.drive_secs == 12 * 60 + 12 * 60 + 14 * 60
      assert movements.drive_secs == 2_280
    end

    test "a negative wait is an infeasibility, not time spent parked" do
      movements =
        Movements.build(
          [
            trip("06:00", last_arrival: 21_600),
            zero_length_trip("06:08", @far_first_stop, @far_last_stop)
          ],
          resolved(),
          context()
        )

      assert only_gap(movements).wait_secs == -360
      assert movements.layover_secs == 0
    end

    test "every gap is counted, not only the first" do
      movements =
        Movements.build(
          [
            trip("06:00", last_arrival: 21_600),
            zero_length_trip("06:08", @far_first_stop),
            zero_length_trip("06:16", @far_first_stop),
            zero_length_trip("06:24", @far_first_stop)
          ],
          resolved(),
          context()
        )

      assert length(movements.gaps) == 3
      assert Enum.map(movements.gaps, & &1.gap_secs) == [480, 480, 480]

      # Each 8-minute gap cannot take a 14-minute drive, so none of them parks.
      assert movements.layover_secs == 0

      # Three inter-trip drives, not one: the pulls alone would give 1 440.
      assert movements.drive_secs == 12 * 60 + 12 * 60 + 3 * 14 * 60
      assert movements.drive_secs == 3_960
    end

    test "the platform span runs from the pull-out start to the pull-back end" do
      movements =
        Movements.build([trip("06:00")], resolved(), context(pull_out_buffer_minutes: 5))

      assert movements.platform_start_secs == movements.pull_out.start_secs
      assert movements.platform_end_secs == movements.pull_back.end_secs
      assert movements.platform_start_secs == 21_600 - 300 - 720
    end
  end

  describe "distances" do
    test "service km comes from the context and the estimated flag follows :path" do
      t1 = trip("06:00", id: @t1_id)

      shaped = Movements.build([t1], resolved(), context(trip_km: %{@t1_id => {4.5, :shape}}))
      assert shaped.service_km == 4.5
      assert shaped.service_km_estimated? == false

      pathed = Movements.build([t1], resolved(), context(trip_km: %{@t1_id => {4.5, :path}}))
      assert pathed.service_km == 4.5
      assert pathed.service_km_estimated? == true
    end

    test "one shapeless trip marks the whole block estimated" do
      movements =
        Movements.build(
          [trip("06:00", id: @t1_id), trip("07:00", id: @t2_id)],
          resolved(),
          context(trip_km: %{@t1_id => {4.5, :shape}, @t2_id => {2.0, :path}})
        )

      assert movements.service_km == 6.5
      assert movements.service_km_estimated? == true
    end

    test "a trip the context never measured contributes no kilometres" do
      movements = Movements.build([trip("06:00", id: @t1_id)], resolved(), context(trip_km: %{}))

      assert movements.service_km == 0.0
      assert movements.service_km_estimated? == false
    end

    test "deadhead km sums the estimated legs only" do
      movements =
        Movements.build(
          [trip("06:00"), trip("06:30", first_stop: @far_first_stop, last_stop: @last_stop)],
          resolved(),
          context()
        )

      pull_km = haversine_m(@depot, @bay_a) * @circuity / 1000
      drive_km = haversine_m(@bay_a, @northgate) * @circuity / 1000

      # Two pulls at the garage and one inter-trip drive, each a straight line
      # scaled by the circuity factor.
      assert_in_delta movements.deadhead_km, 2 * pull_km + drive_km, 0.001
      assert_in_delta movements.deadhead_km, 2 * 4_614.6 * 1.3 / 1000 + 5_281.8 * 1.3 / 1000, 0.01
    end

    test "an entered drive adds no kilometres" do
      pair = [
        trip("06:00"),
        trip("06:30", first_stop: @far_first_stop, last_stop: @last_stop)
      ]

      estimated = Movements.build(pair, resolved(), context())

      entered =
        Movements.build(
          pair,
          resolved(),
          context(entered_minutes: %{{{:stop, "S1"}, {:stop, "S9"}} => 20})
        )

      assert only_gap(entered).source == :entered
      assert only_gap(entered).km == nil

      # The same leg either way, but an entered time is a real route whose length
      # the version does not carry, so the day loses exactly that leg's km.
      drive_km = haversine_m(@bay_a, @northgate) * @circuity / 1000
      assert_in_delta estimated.deadhead_km - entered.deadhead_km, drive_km, 0.001
    end
  end

  # A trip row in the shape `Blocking.Queries.trip_rows/3` produces, including the
  # `shape_id` the context measures from. Times are written as "HH:MM" so a case
  # reads as the timetable it describes; `last_arrival` defaults to five minutes
  # after departure.
  defp trip(departure, opts \\ []) do
    first_departure = to_secs(departure)
    last_arrival = Keyword.get(opts, :last_arrival, first_departure + 300)

    %{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      trip_id: Keyword.get(opts, :trip_id, "T1"),
      route_id: "R1",
      service_id: "WKDY",
      block_id: "101",
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: Keyword.get(opts, :shape_id, "SH1"),
      updated_at: DateTime.utc_now(),
      frequency?: false,
      headway_secs: nil,
      first_arrival: first_departure,
      first_departure: first_departure,
      last_arrival: last_arrival,
      last_departure: Keyword.get(opts, :last_departure, last_arrival),
      first_stop: Keyword.get(opts, :first_stop, @default_last_stop),
      last_stop: Keyword.get(opts, :last_stop, @default_last_stop),
      plottable?: true
    }
  end

  # A trip that arrives and leaves at the same second, so the gap that follows it
  # is exactly the difference between the two departures named.
  defp zero_length_trip(
         departure,
         first_stop \\ @default_last_stop,
         last_stop \\ @default_last_stop
       ) do
    secs = to_secs(departure)
    trip(departure, first_stop: first_stop, last_stop: last_stop, last_arrival: secs)
  end

  defp resolved do
    %{
      garage_id: @garage_uuid,
      vehicle_type_id: @type_uuid,
      garage_source: :attribute,
      conflict: nil
    }
  end

  defp context(overrides \\ []) do
    defaults = [
      min_layover_minutes: 5,
      pull_out_buffer_minutes: 0,
      deadhead_speed_kmh: 30,
      deadhead_circuity: 1.3,
      entered_minutes: %{},
      trip_km: %{},
      garages: %{@garage_uuid => garage()}
    ]

    struct!(Context, Keyword.merge(defaults, overrides))
  end

  defp garage do
    %{
      id: @garage_uuid,
      garage_id: "MAIN",
      name: "Main Garage",
      lat: elem(@depot, 0),
      lon: elem(@depot, 1)
    }
  end

  defp only_gap(movements) do
    assert [gap] = movements.gaps
    gap
  end

  defp to_secs(clock) do
    [hours, minutes] = String.split(clock, ":")
    String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
  end

  defp haversine_m({lat1, lon1}, {lat2, lon2}) do
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(radians(lat1)) * :math.cos(radians(lat2)) * :math.sin(dlon / 2) *
          :math.sin(dlon / 2)

    2 * @earth_radius_m * :math.asin(:math.sqrt(a))
  end

  defp radians(degrees), do: degrees * :math.pi() / 180

  defp clock(secs) do
    sign = if secs < 0, do: "-", else: ""
    total = abs(secs)
    "#{sign}#{total |> div(3600) |> pad()}:#{total |> rem(3600) |> div(60) |> pad()}"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
