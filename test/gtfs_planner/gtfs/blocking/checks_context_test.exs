defmodule GtfsPlanner.Gtfs.Blocking.ChecksContextTest do
  @moduledoc """
  Merge evidence (EV-13) for the checks a planning context adds: R9's findings
  over `Blocking.Movements` and `Blocking.Relief`.

  The cases follow R9 one at a time:

  - a 14-minute drive into an 8-minute gap is one `:cannot_reach` error carrying
    `drive_secs` 840 and `gap_secs` 480, and no `:repositions`
  - the same gap with an entered 7-minute drive raises neither, and its 1-minute
    wait is a `:short_layover`
  - a stop without coordinates keeps the `:repositions` notice with
    `drive: :unknown`
  - a 601-minute platform against a Cutaway's `max_out_minutes` 600 is
    `:too_long`, and `max_block_minutes` 480 lowers the limit that is compared
  - a 366-minute block with a 330-minute relief limit and no marked stop is one
    `:no_relief_opportunity` carrying `from_secs`, `to_secs`, `secs` and
    `limit_secs`; an unset limit raises none
  - route 30 requiring the 35-ft diesel is a `:type_mismatch` on each of its trips
    when the block is a Cutaway
  - attribute rows that disagree for the block's services are one
    `:block_attributes_conflict` warning
  - a route switch across a drive is `:interlining_not_allowed` under
    `:same_stop` and not at a `:same_station` handoff, and `:none` forbids
    every switch
  - a layover-only context still answers exactly as spec 05 did, the same answer
    `checks_test.exs` and the other two unchanged files assert

  Every expected time is derived here from R1 and R3 rather than from the module
  under test. The great-circle distance is computed in this file from the
  haversine formula with the same 6 371 000 m earth radius the production helper
  uses, and the expected drive is R1's formula over that independently computed
  distance at the version defaults, so a change to the estimate cannot quietly
  redefine the expectation:

    * 0.0475° ≈ 5 281.8 m, and 5 281.8 × 1.3 ÷ 500 = 14 min (the deadhead)
    * 0.00108° ≈ 120.1 m, inside `Checks`' 200 m nearby threshold (a layover)

  The module under test is pure: it reads its arguments and touches no database,
  clock, file or network (CR-1), so these cases need no sandbox and no fixtures.

  The gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/checks_test.exs test/gtfs_planner/gtfs/blocking/review_test.exs test/gtfs_planner/gtfs/blocking/problems_test.exs test/gtfs_planner/gtfs/blocking/checks_context_test.exs`.
  The first three files are spec 05's, unchanged since #706, and are the
  regression oracle for CR-2; the fourth establishes the new findings.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.{Checks, Context}

  @earth_radius_m 6_371_000.0
  @circuity 1.3
  @metres_per_minute 500.0

  @depot {42.0415, -71.0}
  @bay_a {42.0, -71.0}
  @northgate {42.0475, -71.0}

  @garage_uuid "0f2b3a4c-5d6e-4f70-8a91-b2c3d4e5f607"
  @other_garage_uuid "3a4b5c6d-7e8f-4091-8a2b-3c4d5e6f7081"
  @cutaway_uuid "1a2b3c4d-5e6f-4a70-8b91-c2d3e4f50617"
  @diesel_uuid "4b5c6d7e-8f90-4a1b-92c3-d4e5f6071829"

  @bay_a_stop %{
    stop_id: "S1",
    name: "Riverside Bay A",
    parent_station: nil,
    lat: 42.0,
    lon: -71.0
  }
  @bay_b_stop %{
    stop_id: "S1B",
    name: "Riverside Bay B",
    parent_station: "S1P",
    lat: 42.0,
    lon: -71.0
  }
  @bay_c_stop %{
    stop_id: "S1C",
    name: "Riverside Bay C",
    parent_station: "S1P",
    lat: 42.0,
    lon: -71.0
  }
  @northgate_stop %{
    stop_id: "S2",
    name: "Northgate",
    parent_station: nil,
    lat: 42.0475,
    lon: -71.0
  }
  @unplaced_stop %{stop_id: "S9", name: "Unplaced", parent_station: nil, lat: nil, lon: nil}

  describe "an unreachable gap" do
    test "is a :cannot_reach error with the drive and the gap, and no :repositions" do
      findings = Checks.block_findings("101", unreachable_pair(), context())

      assert %{code: :cannot_reach, severity: :error, detail: detail} =
               only(findings, :cannot_reach)

      assert detail == %{drive_secs: 840, gap_secs: 480}
      assert codes(findings) == [:cannot_reach]
      assert northgate_minutes() == 14
    end

    test "an entered drive that fits raises neither a reach nor a reposition" do
      context = context(entered_minutes: %{{{:stop, "S1"}, {:stop, "S2"}} => 7})

      findings = Checks.block_findings("101", unreachable_pair(), context)

      refute :cannot_reach in codes(findings)
      refute :repositions in codes(findings)
    end

    test "an entered drive that fits leaves a short wait as a :short_layover" do
      context = context(entered_minutes: %{{{:stop, "S1"}, {:stop, "S2"}} => 7})

      findings = Checks.block_findings("101", unreachable_pair(), context)

      assert %{code: :short_layover, severity: :warning, detail: detail} =
               only(findings, :short_layover)

      assert detail == %{gap_secs: 480, wait_secs: 60}
    end

    test "a gap whose drive is unknown keeps the :repositions notice" do
      pair = [
        trip("t1", "R1", at(7, 0), at(8, 0), last_stop: @bay_a_stop),
        trip("t2", "R1", at(8, 8), at(9, 0), first_stop: @unplaced_stop)
      ]

      findings = Checks.block_findings("101", pair, context())

      assert %{code: :repositions, severity: :notice, detail: detail} =
               only(findings, :repositions)

      assert detail == %{gap_secs: 480, meters: nil, drive: :unknown}
    end
  end

  describe "platform time" do
    test "over the vehicle type's max_out_minutes is a :too_long" do
      findings = Checks.block_findings("101", [oversize_trip()], cutaway_context())

      assert %{code: :too_long, severity: :warning, detail: detail} = only(findings, :too_long)

      assert detail == %{platform_secs: 601 * 60, limit_minutes: 600, limit_source: :vehicle_type}
    end

    test "max_block_minutes lowers the limit that is compared" do
      context = cutaway_context(max_block_minutes: 480)

      findings = Checks.block_findings("101", [oversize_trip()], context)

      assert %{code: :too_long, detail: detail} = only(findings, :too_long)
      assert detail.limit_minutes == 480
      assert detail.limit_source == :max_block_minutes
    end

    test "at the limit is not too long" do
      trip = trip("t1", "R1", at(5, 0), at(15, 0))

      findings = Checks.block_findings("101", [trip], cutaway_context())

      assert findings == []
    end

    test "no vehicle type and no block limit is never too long" do
      findings = Checks.block_findings("101", [oversize_trip()], context())

      assert findings == []
    end
  end

  describe "relief stretches" do
    test "a stretch over the limit is a :no_relief_opportunity with its numbers" do
      findings = Checks.block_findings("101", [long_trip()], context(max_piece_minutes: 330))

      assert %{
               code: :no_relief_opportunity,
               severity: :warning,
               trip_ids: trip_ids,
               detail: detail
             } =
               only(findings, :no_relief_opportunity)

      assert detail == %{
               from_secs: at(5, 0),
               to_secs: at(11, 6),
               secs: 366 * 60,
               limit_secs: 330 * 60
             }

      assert trip_ids == ["t1"]
    end

    test "an unset relief limit raises no finding" do
      findings = Checks.block_findings("101", [long_trip()], context(max_piece_minutes: nil))

      assert findings == []
    end

    test "a marked stop in the block's own gap keeps the stretch inside the limit" do
      first = trip("t1", "R1", at(5, 0), at(8, 0))
      second = trip("t2", "R1", at(8, 6), at(11, 6))

      context = context(max_piece_minutes: 330, relief_stop_ids: MapSet.new(["S1"]))
      findings = Checks.block_findings("101", [first, second], context)

      refute :no_relief_opportunity in codes(findings)
    end

    test "two stretches of one block are two findings with distinct keys" do
      first = trip("t1", "R1", at(5, 0), at(8, 0))
      second = trip("t2", "R1", at(9, 0), at(12, 0))

      context = context(max_piece_minutes: 120, relief_stop_ids: MapSet.new(["S1"]))
      findings = Checks.block_findings("101", [first, second], context)

      stretches = Enum.filter(findings, &(&1.code == :no_relief_opportunity))

      assert Enum.map(stretches, & &1.detail) == [
               %{from_secs: at(5, 0), to_secs: at(8, 30), secs: 12_600, limit_secs: 7200},
               %{from_secs: at(8, 30), to_secs: at(12, 0), secs: 12_600, limit_secs: 7200}
             ]

      assert Enum.map(stretches, & &1.trip_ids) == [["t1"], ["t2"]]
      assert Checks.finding_key(hd(stretches)) != Checks.finding_key(List.last(stretches))
    end
  end

  describe "vehicle type" do
    test "a route requiring another type is a :type_mismatch on each of its trips" do
      context =
        context(
          vehicle_types: types(),
          route_settings: %{"R30" => %{required_vehicle_type_id: @diesel_uuid}},
          attributes: %{{"WKDY", "101"} => %{garage_id: nil, vehicle_type_id: @cutaway_uuid}}
        )

      trips = [
        trip("t1", "R1", at(6, 0), at(7, 0)),
        trip("t2", "R30", at(8, 0), at(9, 0)),
        trip("t3", "R30", at(10, 0), at(11, 0))
      ]

      mismatches =
        Checks.block_findings("101", trips, context) |> Enum.filter(&(&1.code == :type_mismatch))

      assert Enum.map(mismatches, & &1.trip_ids) == [["t2"], ["t3"]]
      assert Enum.map(mismatches, & &1.severity) == [:error, :error]

      assert Enum.map(mismatches, & &1.detail) == [
               %{vehicle_type_id: @cutaway_uuid, required_vehicle_type_id: @diesel_uuid},
               %{vehicle_type_id: @cutaway_uuid, required_vehicle_type_id: @diesel_uuid}
             ]
    end

    test "a route requiring the block's own type raises nothing" do
      context =
        context(
          vehicle_types: types(),
          route_settings: %{"R30" => %{required_vehicle_type_id: @cutaway_uuid}},
          attributes: %{{"WKDY", "101"} => %{garage_id: nil, vehicle_type_id: @cutaway_uuid}}
        )

      findings = Checks.block_findings("101", [trip("t1", "R30", at(6, 0), at(7, 0))], context)

      assert findings == []
    end
  end

  describe "attribute conflicts" do
    test "rows naming different garages are one :block_attributes_conflict" do
      context =
        context(
          garages: garages(),
          attributes: %{
            {"SAT", "101"} => %{garage_id: @other_garage_uuid, vehicle_type_id: nil},
            {"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil}
          }
        )

      trips = [
        trip("t1", "R1", at(6, 0), at(7, 0), service_id: "WKDY"),
        trip("t2", "R1", at(8, 0), at(9, 0), service_id: "SAT")
      ]

      conflict = only(Checks.block_findings("101", trips, context), :block_attributes_conflict)

      assert conflict.severity == :warning
      assert Enum.sort(conflict.trip_ids) == ["t1", "t2"]

      assert conflict.detail.rows == [
               %{service_id: "SAT", garage_id: @other_garage_uuid, vehicle_type_id: nil},
               %{service_id: "WKDY", garage_id: @garage_uuid, vehicle_type_id: nil}
             ]
    end

    test "rows agreeing on every value raise nothing" do
      context =
        context(
          garages: garages(),
          attributes: %{
            {"SAT", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil},
            {"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil}
          }
        )

      trips = [
        trip("t1", "R1", at(6, 0), at(7, 0), service_id: "WKDY"),
        trip("t2", "R1", at(8, 0), at(9, 0), service_id: "SAT")
      ]

      assert Checks.block_findings("101", trips, context) == []
    end
  end

  describe "interlining" do
    test ":same_stop reports a switch across a drive" do
      findings = Checks.block_findings("101", switch_pair(), context(interlining: :same_stop))

      assert %{code: :interlining_not_allowed, severity: :warning, detail: detail} =
               only(findings, :interlining_not_allowed)

      assert detail == %{
               from_route_id: "R1",
               to_route_id: "R30",
               handoff: :moves,
               gap_secs: 480,
               interlining: :same_stop
             }
    end

    test ":same_stop allows a switch at one station" do
      pair = [
        trip("t1", "R1", at(7, 0), at(8, 0), last_stop: @bay_b_stop),
        trip("t2", "R30", at(8, 8), at(9, 0), first_stop: @bay_c_stop)
      ]

      findings = Checks.block_findings("101", pair, context(interlining: :same_stop))

      refute :interlining_not_allowed in codes(findings)
    end

    test ":none reports a switch at one stop" do
      pair = [
        trip("t1", "R1", at(7, 0), at(8, 0)),
        trip("t2", "R30", at(8, 8), at(9, 0))
      ]

      findings = Checks.block_findings("101", pair, context(interlining: :none))

      assert %{code: :interlining_not_allowed, detail: detail} =
               only(findings, :interlining_not_allowed)

      assert detail.handoff == :same_stop
    end

    test ":any reports no switch at all" do
      findings = Checks.block_findings("101", switch_pair(), context(interlining: :any))

      refute :interlining_not_allowed in codes(findings)
    end

    test "no route change is never a switch" do
      pair = [
        trip("t1", "R1", at(7, 0), at(8, 0), last_stop: @bay_a_stop),
        trip("t2", "R1", at(8, 8), at(9, 0), first_stop: @northgate_stop)
      ]

      findings = Checks.block_findings("101", pair, context(interlining: :none))

      refute :interlining_not_allowed in codes(findings)
    end
  end

  describe "CR-2: a layover-only context" do
    test "answers exactly as spec 05 did for the unreachable block" do
      findings = Checks.block_findings("101", unreachable_pair(), Context.layover_only(5))

      assert findings == [
               %{
                 code: :repositions,
                 severity: :notice,
                 block_id: "101",
                 trip_ids: ["t1", "t2"],
                 transfer_id: nil,
                 detail: %{gap_secs: 480, meters: northgate_meters()}
               }
             ]
    end

    test "answers exactly as spec 05 did for a short gap" do
      pair = [
        trip("t1", "R1", at(7, 0), at(8, 0)),
        trip("t2", "R1", at(8, 4), at(9, 0))
      ]

      assert Checks.block_findings("101", pair, Context.layover_only(5)) == [
               %{
                 code: :short_layover,
                 severity: :warning,
                 block_id: "101",
                 trip_ids: ["t1", "t2"],
                 transfer_id: nil,
                 detail: %{gap_secs: 240}
               }
             ]
    end
  end

  # --- fixtures --------------------------------------------------------------

  # Two trips whose deadhead is the R1 estimate between @bay_a and @northgate, in
  # a gap shorter than that estimate.
  defp unreachable_pair do
    [
      trip("t1", "R1", at(7, 0), at(8, 0), last_stop: @bay_a_stop),
      trip("t2", "R1", at(8, 8), at(9, 0), first_stop: @northgate_stop)
    ]
  end

  # The same two trips with a route change across that drive.
  defp switch_pair do
    [
      trip("t1", "R1", at(7, 0), at(8, 0), last_stop: @bay_a_stop),
      trip("t2", "R30", at(8, 8), at(9, 0), first_stop: @northgate_stop)
    ]
  end

  # 366 minutes on platform: over a 330-minute relief limit, under a 480-minute
  # block limit, and long enough that no inter-trip gap falls below the minimum
  # layover.
  defp long_trip, do: trip("t1", "R1", at(5, 0), at(11, 6))

  # 601 minutes on platform, one minute over a Cutaway's `max_out_minutes`.
  defp oversize_trip, do: trip("t1", "R1", at(5, 0), at(15, 1))

  defp context(overrides \\ []) do
    defaults = [
      min_layover_minutes: 5,
      max_block_minutes: nil,
      max_piece_minutes: nil,
      interlining: :any,
      entered_minutes: %{},
      relief_stop_ids: MapSet.new(),
      garages: %{},
      vehicle_types: %{},
      route_settings: %{},
      attributes: %{},
      trip_km: %{}
    ]

    struct!(Context, Keyword.merge(defaults, overrides))
  end

  # A block whose type is the Cutaway, resolved from its route's requirement.
  defp cutaway_context(overrides \\ []) do
    context(
      Keyword.merge(
        [
          vehicle_types: types(),
          route_settings: %{"R1" => %{required_vehicle_type_id: @cutaway_uuid}}
        ],
        overrides
      )
    )
  end

  defp garages do
    %{
      @garage_uuid => garage(@garage_uuid, "MAIN", "Main Garage", @depot),
      @other_garage_uuid => garage(@other_garage_uuid, "NORTH", "North Garage", @northgate)
    }
  end

  defp garage(id, garage_id, name, {lat, lon}) do
    %{id: id, garage_id: garage_id, name: name, lat: lat, lon: lon}
  end

  defp types do
    %{
      @cutaway_uuid => %{id: @cutaway_uuid, name: "Cutaway", max_out_minutes: 600},
      @diesel_uuid => %{id: @diesel_uuid, name: "35-ft diesel", max_out_minutes: nil}
    }
  end

  # A trip row in the shape `Blocking.Queries.trip_rows/3` produces, including the
  # `shape_id` the context measures from. Times are integer seconds (CR-3), and
  # a trip starts and ends at Riverside Bay A unless a case says otherwise.
  defp trip(id, route_id, first_departure, last_arrival, opts \\ []) do
    %{
      id: id,
      trip_id: Keyword.get(opts, :trip_id, id),
      route_id: route_id,
      service_id: Keyword.get(opts, :service_id, "WKDY"),
      block_id: "101",
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: "SH1",
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: false,
      headway_secs: nil,
      first_arrival: Keyword.get(opts, :first_arrival, first_departure),
      first_departure: first_departure,
      last_arrival: last_arrival,
      last_departure: Keyword.get(opts, :last_departure, last_arrival),
      first_stop: Keyword.get(opts, :first_stop, @bay_a_stop),
      last_stop: Keyword.get(opts, :last_stop, @bay_a_stop),
      plottable?: true
    }
  end

  defp at(hours, minutes), do: hours * 3600 + minutes * 60

  # The expected R1 estimate, computed here from the haversine distance rather
  # than from `DeadheadTimes`, so this file does not agree with the module under
  # test by construction.
  defp northgate_minutes do
    round(haversine_m(@bay_a, @northgate) * @circuity / @metres_per_minute)
  end

  defp northgate_meters, do: round(haversine_m(@bay_a, @northgate))

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

  defp codes(findings), do: Enum.map(findings, & &1.code)

  defp only(findings, code) do
    assert [finding] = Enum.filter(findings, &(&1.code == code))
    finding
  end
end
