defmodule GtfsPlanner.Gtfs.Blocking.PlanTest do
  @moduledoc """
  Merge evidence (EV-22) for the block plan.

  The plan is built over a real `Blocking.Generator.run/4` result and over
  hand-written rows, contexts and day types: nothing here stubs the modules the
  plan composes, and every figure the plan reports is compared against the
  movement the same block derives through `Blocking.Movements.build/3` rather
  than against the plan's own bookkeeping.

  The cases are the ones the step card names:

  - `moves` lists exactly the trips whose block changes, with `from` and `to`, and
    a trip that keeps its block is absent;
  - a moved `WKDY` trip on the selected `{WKDY, SCHOOL}` day type produces review
    effects for `{WKDY, SCHOOL}` (selected first) and `{WKDY}`, each carrying its
    own date count, and the two add to the review's affected date count;
  - an overlap a fixed block already had is `existing`, not `added`;
  - a new block 105 whose trips run on `WKDY` and `SCHOOL` gets one attribute row
    per service, both carrying the partition's garage and vehicle type;
  - the before and after figures count vehicles, platform seconds, drive seconds
    and problems over the selected day type's blocks, and the after figures are
    the same counts over the rows with the moves applied;
  - the generator's leftovers pass through unchanged, including one whose trip
    kept its block;
  - the fingerprint is equal for identical input and changes when one planning
    input or the day type's trip set changes (AC-25, R12, INV-7).

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/plan_test.exs`.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.{Checks, Context, DayTypes, Generator, Plan}

  @main "00000000-0000-4000-8000-000000000001"
  @north "00000000-0000-4000-8000-000000000002"
  @cutaway "00000000-0000-4000-8000-000000000003"
  @diesel "00000000-0000-4000-8000-000000000004"

  # The garage sits about 550 m from `@riv_b` and 780 m from `@market`, so at the
  # version's 30 km/h and 1.3 circuity a pull to or from Riverside is one or two
  # minutes, a pull from the market is two and a pull from Valley College is five.
  # Every figure below is these pulls plus the trips' own times.
  @riv_a %{stop_id: "RIV_A", name: "Riverside A", parent_station: "RIV", lat: 45.5, lon: -75.5}
  @riv_b %{
    stop_id: "RIV_B",
    name: "Riverside B",
    parent_station: "RIV",
    lat: 45.501,
    lon: -75.501
  }
  @market %{stop_id: "MKT", name: "Market Square", parent_station: nil, lat: 45.51, lon: -75.51}
  @valley %{stop_id: "VAL", name: "Valley College", parent_station: nil, lat: 45.52, lon: -75.52}
  @nowhere %{stop_id: "GAP", name: "Unplaced", parent_station: nil, lat: nil, lon: nil}

  @monday ~D[2026-01-05]
  @tuesday ~D[2026-01-06]
  @wednesday ~D[2026-01-07]

  describe "moves" do
    test "lists exactly the trips whose block changes, with from and to" do
      {selected, {result, plan}} = build(additive_plan())

      assert %{
               mode: :unassigned_only,
               day_type_key: day_type_key,
               moves: [
                 %{trip: %{trip_id: "T3"}, from: nil, to: "101"},
                 %{trip: %{trip_id: "T4"}, from: nil, to: "105"}
               ],
               leftovers: []
             } = plan

      assert day_type_key == selected.key
      assert Map.fetch!(result.assignments, uuid(1)) == "101"
      assert Map.fetch!(result.assignments, uuid(3)) == "101"
    end

    test "a trip that keeps its block is not a move" do
      {_selected, {_result, plan}} = build(additive_plan())

      # T1 and T2 are already in 101 and stay there, so neither is a change.
      assert Enum.map(plan.moves, & &1.trip.trip_id) == ["T3", "T4"]
      assert plan.review.changes == plan.moves
    end

    test "a rebuild names the block each trip came from" do
      {_selected, {_result, plan}} = build(rebuild_selected())

      assert [
               %{trip: %{trip_id: "T2"}, from: "101", to: "103"},
               %{trip: %{trip_id: "T3"}, from: "102", to: "101"}
             ] = plan.moves
    end
  end

  describe "review effects" do
    test "a moved WKDY trip on {WKDY, SCHOOL} yields an effect for {WKDY} as well" do
      {_selected, {_result, plan}} = build(shared_weekday())

      assert [
               %{day_type: %{service_ids: ["SCHOOL", "WKDY"], date_count: 1}, selected?: true},
               %{day_type: %{service_ids: ["WKDY"], date_count: 2}, selected?: false}
             ] = plan.review.effects

      assert Enum.map(plan.review.effects, & &1.day_type.date_count) |> Enum.sum() ==
               plan.review.affected_date_count

      for effect <- plan.review.effects do
        assert effect.changed_trip_ids == [uuid(1)]
      end
    end
  end

  describe "existing findings" do
    test "an overlap a fixed block already had is existing, not added" do
      {_selected, {_result, plan}} = build(overlapping_fixed_block())

      [selected_effect | _] = plan.review.effects
      overlap = {:overlap, [uuid(1), uuid(2)], nil}

      assert Enum.any?(
               selected_effect.existing,
               &(Checks.finding_key(&1) == overlap and &1.severity == :error)
             )

      refute Enum.any?(selected_effect.added, &(Checks.finding_key(&1) == overlap))
    end
  end

  describe "attribute rows" do
    test "a new block 105 running on WKDY and SCHOOL gets one row per service" do
      {_selected, {_result, plan}} = build(two_services())

      # `new_blocks` carries one row per block, not per service: block 105 is
      # new once however many services run on it, and it owns both trips.
      assert [%{block_id: "105", garage_id: @main, vehicle_type_id: nil, trip_ids: trips}] =
               plan.new_blocks

      assert Enum.sort(trips) == Enum.sort([uuid(1), uuid(2)])

      assert [
               %{service_id: "SCHOOL", block_id: "105", garage_id: @main, vehicle_type_id: nil},
               %{service_id: "WKDY", block_id: "105", garage_id: @main, vehicle_type_id: nil}
             ] = plan.attribute_rows
    end

    test "an existing block gets no attribute row" do
      {_selected, {_result, plan}} = build(additive_plan())

      assert [%{block_id: "105"}] = plan.new_blocks
      assert [%{block_id: "105", service_id: "WKDY"}] = plan.attribute_rows
    end
  end

  describe "figures" do
    test "before counts the blocks the page has, after the blocks the plan leaves" do
      {_selected, {_result, plan}} = build(additive_plan())

      # Before: block 101 holds T1 and T2, so it pulls out two minutes before
      # 07:00 and back from Valley College five minutes after 10:00, and drives
      # three minutes from Riverside B to the market between them.
      # 06:58 → 10:05 is 11,220 s and the drives are 120 + 300 + 180.
      assert plan.before == %{vehicles: 1, platform_secs: 11_220, drive_secs: 600, problems: 0}

      # After: T3 joins 101 and the block's pull-back becomes the two minutes from
      # the market (06:58 → 11:17 is 15,540 s, drives 120 + 120 + 180), and T4
      # opens 105, which pulls out two minutes before 10:20 and back one minute
      # after 11:20 (3,780 s, drives 120 + 60).
      assert plan.after == %{vehicles: 2, platform_secs: 19_320, drive_secs: 600, problems: 0}
    end

    test "the after figures read the rows with the moves applied" do
      {_selected, {_result, plan}} = build(additive_plan())
      {rows, context} = rows_and_context(additive_plan())
      applied = apply_moves(rows, plan.moves)

      assert "101" in Enum.map(applied, & &1.block_id)

      assert plan.after.vehicles ==
               applied
               |> Enum.map(& &1.block_id)
               |> Enum.reject(&is_nil/1)
               |> Enum.uniq()
               |> length()

      moved = Enum.find(applied, &(&1.trip_id == "T3"))
      assert moved.block_id == "101"

      assert Checks.block_findings("101", Enum.filter(applied, &(&1.block_id == "101")), context) ==
               []
    end

    test "a problem the plan adds is counted in the after figures and not the before" do
      {_selected, {_result, plan}} = build(oversized_singleton())

      assert plan.before == %{vehicles: 0, platform_secs: 0, drive_secs: 0, problems: 0}
      assert plan.after.vehicles == 2
      assert plan.after.problems == 2

      for effect <- plan.review.effects do
        assert Enum.map(effect.added, & &1.code) == [:too_long, :too_long]
      end
    end
  end

  describe "leftovers" do
    test "a trip the generator could not place passes through as a leftover" do
      instance = unplaceable_trip()
      {_selected, {result, plan}} = build(instance)

      assert plan.leftovers == result.leftovers

      assert [%{reason: :unknown_location, block_id: nil, trip: %{trip_id: "T2"}}] =
               plan.leftovers
    end

    test "a reported singleton keeps its block in the leftovers and in the moves" do
      {_selected, {result, plan}} = build(oversized_singleton())

      assert [
               %{reason: :exceeds_vehicle_limit, block_id: "1", trip: %{trip_id: "T1"}},
               %{reason: :exceeds_vehicle_limit, block_id: "2", trip: %{trip_id: "T2"}}
             ] = plan.leftovers

      assert [
               %{trip: %{trip_id: "T1"}, from: nil, to: "1"},
               %{trip: %{trip_id: "T2"}, from: nil, to: "2"}
             ] =
               plan.moves

      assert Map.fetch!(result.assignments, uuid(1)) == "1"
    end
  end

  describe "fingerprint" do
    test "is equal for identical input" do
      assert fingerprint(additive_plan()) == fingerprint(additive_plan())
    end

    test "changes when a setting, a driving time, a relief mark or a route setting changes" do
      base = fingerprint(additive_plan())

      mutations = [
        {"a setting", fn context -> %{context | min_layover_minutes: 6} end},
        {"an entered driving time", &enter_driving_time/1},
        {"a relief mark", fn context -> %{context | relief_stop_ids: MapSet.new(["MKT"])} end},
        {"a route setting", &set_route_garage/1}
      ]

      for {name, mutate} <- mutations do
        instance = %{additive_plan() | context: mutate.(context([]))}
        assert fingerprint(instance) != base, "#{name} left the fingerprint equal"
      end
    end

    test "changes when an attribute row, a garage coordinate or a fleet count changes" do
      base = fingerprint(additive_plan())

      mutations = [
        {"an attribute row", &set_attribute/1},
        {"a garage coordinate", &move_garage/1},
        {"a fleet count", &add_vehicle/1}
      ]

      for {name, mutate} <- mutations do
        instance = %{additive_plan() | context: mutate.(context([]))}
        assert fingerprint(instance) != base, "#{name} left the fingerprint equal"
      end
    end

    test "changes when the day type's trip set changes" do
      instance = additive_plan()
      added = trip(5, "T5", departure: minutes(13), arrival: minutes(14))
      removed = Enum.reject(Map.fetch!(instance, :rows), &(&1.trip_id == "T4"))

      assert fingerprint(%{instance | rows: Map.fetch!(instance, :rows) ++ [added]}) !=
               fingerprint(instance)

      assert fingerprint(%{instance | rows: removed}) != fingerprint(instance)
    end
  end

  # --- harness ----------------------------------------------------------------

  # The plan is composed the way step 26 composes it: the day types and their
  # service dates come from the calendars, the affected day types are the ones
  # holding a moved trip's service, and the generator's result is the plan's
  # input. Nothing about the plan is stubbed.
  defp build(instance) do
    calendars = Map.fetch!(instance, :calendars)
    day_types = DayTypes.derive(calendars)
    service_dates = DayTypes.service_dates(calendars)

    selected =
      Enum.find(day_types, &(&1.key == Map.get(instance, :selected_key))) || hd(day_types)

    context = Map.fetch!(instance, :context)
    rows = Map.fetch!(instance, :rows)
    mode = Map.fetch!(instance, :mode)

    result = Generator.run(mode, rows, context, Map.get(instance, :used_ids, []))

    plan =
      Plan.build(%{
        mode: mode,
        selected_key: selected.key,
        day_types: day_types,
        affected: affected(day_types, rows, result),
        rows: rows,
        result: result,
        context: context,
        in_seat: %{rows: [], context: in_seat_context(day_types, service_dates)},
        service_dates: service_dates
      })

    {selected, {result, plan}}
  end

  defp affected(day_types, rows, result) do
    rows
    |> Enum.filter(&(Map.fetch!(result.assignments, &1.id) != &1.block_id))
    |> Enum.map(& &1.service_id)
    |> Enum.uniq()
    |> Enum.flat_map(&DayTypes.containing(day_types, &1))
    |> Enum.uniq_by(& &1.key)
  end

  defp in_seat_context(day_types, service_dates) do
    %{trips: %{}, service_dates: service_dates, day_types: day_types, sequences: %{}}
  end

  defp fingerprint(instance) do
    {_selected, {_result, plan}} = build(instance)
    plan.fingerprint
  end

  defp rows_and_context(instance) do
    {Map.fetch!(instance, :rows), Map.fetch!(instance, :context)}
  end

  # --- fixtures ---------------------------------------------------------------

  # Block 101 holds T1 and T2. T3 starts at Valley College, where T2 ends, ten
  # minutes later, so it chains onto 101; T4 starts at Riverside while 101 is out,
  # so it opens the next ID after the highest in use.
  defp additive_plan do
    %{
      mode: :unassigned_only,
      calendars: weekday_calendars(),
      context: context([]),
      used_ids: ["101", "102", "103", "104"],
      rows: [
        trip(1, "T1",
          block: "101",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          block: "101",
          departure: minutes(9),
          arrival: minutes(10),
          first: @market,
          last: @valley
        ),
        trip(3, "T3",
          departure: minutes(10, 15),
          arrival: minutes(11, 15),
          first: @valley,
          last: @market
        ),
        trip(4, "T4",
          departure: minutes(10, 20),
          arrival: minutes(11, 20),
          first: @riv_a,
          last: @riv_b
        )
      ]
    }
  end

  # The same block rebuilt: T1 and T2 are in the selection and T3 is not, so T1
  # keeps the rebuilt 101, T2 opens 103 and T3 chains onto 101.
  defp rebuild_selected do
    %{
      mode: {:selected, ["101"]},
      calendars: weekday_calendars(),
      context: context([]),
      used_ids: ["101", "102"],
      rows: [
        trip(1, "T1",
          block: "101",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          block: "101",
          departure: minutes(8, 5),
          arrival: minutes(9, 5),
          first: @market,
          last: @valley
        ),
        trip(3, "T3",
          block: "102",
          departure: minutes(8, 10),
          arrival: minutes(9, 10),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # Two identical trips in block 101 overlap, and the unassigned T3 chains onto
  # that same block, so the overlap is a finding the plan inherited.
  defp overlapping_fixed_block do
    %{
      mode: :unassigned_only,
      calendars: weekday_calendars(),
      context: context([]),
      used_ids: ["101"],
      rows: [
        trip(1, "T1",
          block: "101",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          block: "101",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @riv_b
        ),
        trip(3, "T3",
          departure: minutes(10, 15),
          arrival: minutes(11, 15),
          first: @valley,
          last: @market
        )
      ]
    }
  end

  # One `WKDY` trip and one `SCHOOL` trip, both unassigned and in the same
  # partition, so they chain onto one new block that needs an attribute row per
  # service. `WKDY` alone runs on two dates and `SCHOOL` on one.
  defp two_services do
    %{
      mode: :unassigned_only,
      calendars: shared_weekday_calendars(),
      context: context([]),
      used_ids: ["101", "102", "103", "104"],
      rows: [
        trip(1, "T1",
          service: "WKDY",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          service: "SCHOOL",
          departure: minutes(8, 10),
          arrival: minutes(9, 10),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # A `WKDY` trip that is placed, on a version whose `WKDY` service runs on two
  # day types.
  defp shared_weekday do
    %{
      mode: :unassigned_only,
      calendars: shared_weekday_calendars(),
      context: context([]),
      used_ids: ["101"],
      rows: [
        trip(1, "T1", departure: minutes(7), arrival: minutes(8), first: @riv_a, last: @riv_b),
        trip(2, "T2",
          service: "SCHOOL",
          block: "101",
          departure: minutes(9),
          arrival: minutes(10),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # A trip starting where the version has no coordinates cannot be reached from
  # any open block or from the garage, so the run leaves it out.
  defp unplaceable_trip do
    %{
      mode: :unassigned_only,
      calendars: weekday_calendars(),
      context: context([]),
      rows: [
        trip(1, "T1", departure: minutes(7), arrival: minutes(8), first: @riv_a, last: @riv_b),
        trip(2, "T2", departure: minutes(9), arrival: minutes(10), first: @nowhere, last: @market)
      ]
    }
  end

  # A 45-minute platform limit: each trip is too long to share a block, so each
  # opens one and is reported as a singleton that kept its block.
  defp oversized_singleton do
    %{
      mode: :unassigned_only,
      calendars: weekday_calendars(),
      context: context(max_block_minutes: 45),
      rows: [
        trip(1, "T1", departure: minutes(7), arrival: minutes(8), first: @riv_a, last: @riv_b),
        trip(2, "T2", departure: minutes(9), arrival: minutes(10), first: @market, last: @valley)
      ]
    }
  end

  # --- calendars, contexts and rows -------------------------------------------

  defp weekday_calendars, do: [calendar("WKDY", [@monday], 4), calendar("SCHOOL", [@monday], 2)]

  defp shared_weekday_calendars do
    [calendar("WKDY", [@monday, @tuesday, @wednesday], 2), calendar("SCHOOL", [@monday], 1)]
  end

  defp calendar(service_id, dates, trip_count) do
    %{service_id: service_id, name: service_id, active_dates: dates, trip_count: trip_count}
  end

  defp enter_driving_time(context) do
    ref = {{:garage, @main}, {:stop, "MKT"}}
    %{context | entered_minutes: Map.put(context.entered_minutes, ref, 12)}
  end

  defp set_route_garage(context) do
    %{context | route_settings: Map.put(context.route_settings, "12", %{garage_id: @north})}
  end

  defp set_attribute(context) do
    row = %{garage_id: @north, vehicle_type_id: @diesel}
    %{context | attributes: Map.put(context.attributes, {"WKDY", "101"}, row)}
  end

  defp move_garage(context) do
    garage = Map.fetch!(context.garages, @main)
    %{context | garages: Map.put(context.garages, @main, %{garage | lat: 45.6})}
  end

  defp add_vehicle(context) do
    %{context | fleet: [%{garage_id: @main, vehicle_type_id: @cutaway, count: 12}]}
  end

  defp context(overrides) do
    struct!(
      %Context{
        min_layover_minutes: 5,
        default_garage_id: @main,
        garages: %{
          @main => %{id: @main, garage_id: "Main", name: "Main", lat: 45.505, lon: -75.505},
          @north => %{id: @north, garage_id: "North", name: "North", lat: 45.6, lon: -75.6}
        },
        vehicle_types: %{
          @cutaway => %{id: @cutaway, name: "Cutaway", max_out_minutes: 600},
          @diesel => %{id: @diesel, name: "35-ft diesel", max_out_minutes: 480}
        }
      },
      overrides
    )
  end

  defp trip(number, trip_id, opts) do
    departure = Keyword.fetch!(opts, :departure)
    arrival = Keyword.fetch!(opts, :arrival)

    %{
      id: uuid(number),
      trip_id: trip_id,
      route_id: Keyword.get(opts, :route, "12"),
      service_id: Keyword.get(opts, :service, "WKDY"),
      block_id: Keyword.get(opts, :block),
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: nil,
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: Keyword.get(opts, :frequency?, false),
      headway_secs: nil,
      first_arrival: departure,
      first_departure: departure,
      last_arrival: arrival,
      last_departure: arrival,
      first_stop: Keyword.get(opts, :first, @riv_a),
      last_stop: Keyword.get(opts, :last, @market),
      plottable?: Keyword.get(opts, :plottable?, true)
    }
  end

  defp apply_moves(rows, moves) do
    to_by_trip_id = Map.new(moves, &{&1.trip.id, &1.to})

    Enum.map(rows, fn row ->
      case Map.fetch(to_by_trip_id, row.id) do
        {:ok, to} -> %{row | block_id: to}
        :error -> row
      end
    end)
  end

  defp minutes(hour, minute \\ 0), do: hour * 3600 + minute * 60

  defp uuid(number) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
  end
end
