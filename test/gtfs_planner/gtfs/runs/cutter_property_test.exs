defmodule GtfsPlanner.Gtfs.Runs.CutterPropertyTest do
  @moduledoc """
  Merge evidence (EV-10) for CL-7: a seeded property sweep of `Cutter.run/5`, so
  FH-10 and FH-11 stay rejected.

  300 generated days, each built through the real `Movements.build/3` and
  `Relief.windows/3` and then **checked with `Runs.Day.derive/4`**, which the
  cutter does not use for its own bookkeeping. That is what the gate names as its
  independence: agreement between the two is evidence, not a tautology.

  It is a plain loop over a fixed `:rand` seed rather than `ExUnitProperties`,
  which is not a dependency of this project and was not added for this. The
  seed is `:exsss` with `{8, 8, 8}` and the case count is 300, both fixed by the
  card, so a failure reproduces exactly — the case index is in the message.

  ## What each case asserts

  - every sequence trip is assigned **exactly once** afterwards
  - the suggestion introduces no `:not_at_relief`, `:too_many_pieces` or
    `:cannot_reach_piece` finding that the day did not already have
  - every **two-piece** run's spread is within the limit
  - `:uncovered_only` leaves every pre-existing assignment untouched
  - and, for determinism, the same day built again in a shuffled order gives the
    same assignments and the same run IDs

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_runs08 mix test test/gtfs_planner/gtfs/runs/cutter_property_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief
  alias GtfsPlanner.Gtfs.Runs.Cutter
  alias GtfsPlanner.Gtfs.Runs.Day

  @garage_uuid "11111111-2222-4333-8444-555555555555"
  @cases 300
  @seed {8, 8, 8}

  # The generated days draw on four stops: two bays inside the marked station and
  # two unmarked stops to the north, so a generated day sometimes has relief
  # windows and sometimes does not.
  @bay_a %{stop_id: "BAY_A", name: "Bay A", parent_station: "RIV", lat: 42.0, lon: -71.0}
  @bay_b %{stop_id: "BAY_B", name: "Bay B", parent_station: "RIV", lat: 42.0, lon: -71.0}
  @college %{stop_id: "VC", name: "Valley College", parent_station: nil, lat: 42.0475, lon: -71.0}
  @market %{stop_id: "MS", name: "Market Square", parent_station: nil, lat: 42.03, lon: -71.0}
  @stops [@bay_a, @bay_b, @college, @market]
  @markable ["RIV", "VC", "MS"]

  @minute 60

  setup do
    # Seeded once for the module: every case draws from the same sequence, so
    # case 137 is the same day on every run and on every machine.
    :rand.seed(:exsss, @seed)
    :ok
  end

  test "every generated day is covered exactly once and adds no bad finding" do
    Enum.each(1..@cases, fn index -> check_case(index, :replace_all) end)
  end

  test "uncovered-only changes no existing assignment across the sweep" do
    Enum.each(1..@cases, fn index -> check_case(index, :uncovered_only) end)
  end

  defp check_case(index, scope) do
    world = generate()
    blocks = world.blocks
    context = world.context
    crew = world.crew
    existing = existing_assignments(world, scope)

    # The day as it stands before any suggestion.
    before = Day.derive(blocks, existing, context, crew)
    before_codes = Enum.map(before.findings, & &1.code)

    result = Cutter.run(scope, blocks, existing, context, crew)
    where = "case #{index} of #{@cases}, scope #{inspect(scope)}, #{world.label}"

    assert_every_trip_assigned_once(blocks, result.assignments, where)

    if scope == :uncovered_only do
      # Nothing already assigned may move.
      for {trip_id, run_id} <- existing do
        assert Map.get(result.assignments, trip_id) == run_id,
               "#{where} moved an existing assignment of #{trip_id} from #{run_id} to #{Map.get(result.assignments, trip_id)}"
      end
    end

    after_day = Day.derive(blocks, result.assignments, context, crew)

    # A suggestion must not introduce these three; the day may already have had
    # them from a hand-made assignment.
    introduced = Enum.map(after_day.findings, & &1.code) -- before_codes

    for code <- [:not_at_relief, :too_many_pieces, :cannot_reach_piece] do
      refute code in introduced, "#{where} introduced #{inspect(code)}"
    end

    # Every two-piece run the suggestion made fits the limit.
    for run <- after_day.runs, length(run.pieces) == 2 do
      assert run.work.spread_secs <= crew.max_spread_minutes * @minute,
             "#{where} produced a two-piece run spreading #{div(run.work.spread_secs, @minute)} minutes"
    end

    # And the same day, built in another order, gives the same answer.
    shuffled = Enum.shuffle(blocks)
    again = Cutter.run(scope, shuffled, existing, context, crew)

    assert again.assignments == result.assignments, "#{where} was not order-independent"
    assert again.new_run_ids == result.new_run_ids, "#{where} numbered differently when reordered"
  end

  defp assert_every_trip_assigned_once(blocks, assignments, where) do
    for block <- blocks, trip <- block.trips do
      assert Map.has_key?(assignments, trip.id),
             "#{where} left trip #{trip.trip_id} of block #{block.block_id} unassigned"
    end

    # Nothing is assigned that is not a trip of this day, and no trip carries
    # two run IDs (a map makes that impossible, so this is about extra keys).
    known = MapSet.new(for block <- blocks, trip <- block.trips, do: trip.id)

    for trip_id <- Map.keys(assignments) do
      assert MapSet.member?(known, trip_id), "#{where} assigned unknown trip #{trip_id}"
    end
  end

  # A generated day: a few blocks of a few trips, some stops marked as relief
  # points, a piece limit that may be unset, and crew rules inside the spec's
  # ranges.
  defp generate do
    block_count = :rand.uniform(6)
    marked = Enum.filter(@markable, fn _ -> :rand.uniform(3) == 1 end)
    # One limit or none, never a list: a list would reach `Checks` as a
    # `max_piece_minutes` and be multiplied.
    limits = [nil, nil, 120, 180, 240, 360, 480]
    max_piece = Enum.at(limits, :rand.uniform(length(limits)) - 1)

    crew = %{
      report_pull_out_minutes: :rand.uniform(16) - 1,
      report_relief_minutes: :rand.uniform(8) - 1,
      sign_off_minutes: :rand.uniform(11) - 1,
      paid_break_max_minutes: :rand.uniform(46) - 1,
      max_spread_minutes: 240 + :rand.uniform(841)
    }

    context = context(marked, max_piece)

    blocks =
      Enum.map(1..block_count, fn n ->
        build_block("B#{n}", context, 6 * 3600 + n * 3600)
      end)

    %{
      blocks: blocks,
      context: context,
      crew: crew,
      label:
        "#{block_count} blocks, marked #{inspect(marked)}, piece limit #{inspect(max_piece)}, " <>
          "pull-out #{crew.report_pull_out_minutes}, relief #{crew.report_relief_minutes}, " <>
          "sign-off #{crew.sign_off_minutes}, paid break #{crew.paid_break_max_minutes}, " <>
          "spread #{crew.max_spread_minutes}"
    }
  end

  defp build_block(block_id, context, base) do
    trip_count = :rand.uniform(8)
    trips = Enum.map(1..trip_count, fn n -> build_trip(block_id, n, base + (n - 1) * 1800) end)
    sequence = Checks.sequence(trips)
    movements = Movements.build(trips, resolution(), context)

    %{
      block_id: block_id,
      trips: sequence,
      movements: movements,
      windows: Relief.windows(trips, movements, context)
    }
  end

  # Trips start and end at randomly chosen stops, so a generated day has drives,
  # layovers and unknown gaps all mixed together.
  defp build_trip(block_id, n, start) do
    first = Enum.random(@stops)
    last = Enum.random(@stops)
    duration = :rand.uniform(7) * 300

    %{
      id: Ecto.UUID.generate(),
      trip_id: "#{block_id}-#{n}",
      route_id: "R1",
      service_id: "WKDY",
      block_id: block_id,
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: "SH1",
      updated_at: DateTime.utc_now(),
      frequency?: false,
      headway_secs: nil,
      first_arrival: start,
      first_departure: start,
      last_arrival: start + duration,
      last_departure: start + duration,
      first_stop: first,
      last_stop: last,
      plottable?: true
    }
  end

  defp context(marked, max_piece) do
    garage = %{id: @garage_uuid, garage_id: "MAIN", name: "Main Garage", lat: 42.0, lon: -71.0}

    struct!(Context,
      min_layover_minutes: :rand.uniform(11) - 1,
      pull_out_buffer_minutes: :rand.uniform(21) - 1,
      deadhead_speed_kmh: 30,
      deadhead_circuity: 1.3,
      entered_minutes: %{},
      trip_km: %{},
      default_garage_id: @garage_uuid,
      garages: %{@garage_uuid => garage},
      max_piece_minutes: max_piece,
      relief_stop_ids: MapSet.new(marked)
    )
  end

  defp resolution do
    %{garage_id: @garage_uuid, vehicle_type_id: nil, garage_source: :default, conflict: nil}
  end

  # `:uncovered_only` is given a day where some trips are already assigned, so
  # the sweep actually exercises "keeps every existing assignment".
  defp existing_assignments(%{blocks: blocks}, :uncovered_only) do
    trips = for block <- blocks, trip <- block.trips, do: trip
    assigned = Enum.filter(trips, fn _ -> :rand.uniform(2) == 1 end)

    assigned
    |> Enum.with_index(1)
    |> Map.new(fn {trip, n} -> {trip.id, "900#{n}"} end)
  end

  defp existing_assignments(_world, :replace_all), do: %{}
end
