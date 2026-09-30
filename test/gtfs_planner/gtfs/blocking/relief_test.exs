defmodule GtfsPlanner.Gtfs.Blocking.ReliefTest do
  @moduledoc """
  The instants a relief change may happen in a block, and the unrelieved stretches
  between the changes taken.

  Windows and stretches are pure functions of the block's movements and the
  version's marked relief points, so these cases run in the local ExUnit process
  with no sandbox, no fixtures and no cleanup. The module under test calls no
  repository, clock, file or network.

  The independent check is the last describe block: an
  exhaustive oracle that enumerates one instant per window or none, at 60-second
  steps, and takes the smallest longest stretch any of those plans can achieve.
  It is written from the relief rules directly and shares no code with the search, so
  agreement is evidence rather than a tautology. Blocks come from a fixed seed,
  so a failure reproduces.

  ## A note on the greedy rule

  A greedy that takes "the latest change instant reachable within the limit" is not
  optimal for "can every stretch be within the limit", and the test pins the case
  that shows it -- see
  "a schedule the latest-reachable greedy would strand" below. The implementation
  therefore returns the best schedule available, which is what this
  oracle holds it to. The difference matters to a planner: the greedy reports
  "No operator change" for blocks that are perfectly staffable.

  Run with:
  `mix test test/gtfs_planner/gtfs/blocking/relief_test.exs`. This test
  establishes the window and stretch arithmetic. It says nothing about whether
  the relief limit, the marked stops or the day load are correct, which is
  covered by the day load and relief settings tests.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief

  @minute 60

  @garage_uuid "11111111-2222-4333-8444-555555555555"
  @type_uuid "22222222-3333-4444-8555-666666666666"

  @bay_a %{stop_id: "S1", name: "Bay A", parent_station: nil, lat: 42.0, lon: -71.0}
  @bay_b %{
    stop_id: "S2",
    name: "Bay B",
    parent_station: "Riverside Station",
    lat: 42.00108,
    lon: -71.0
  }
  @college %{stop_id: "S3", name: "Valley College", parent_station: nil, lat: 42.0475, lon: -71.0}
  @market %{
    stop_id: "S4",
    name: "Market Square",
    parent_station: "Market Yard",
    lat: 42.03,
    lon: -71.02
  }
  @far %{stop_id: "S9", name: "Northgate", parent_station: nil, lat: 42.0475, lon: -71.0}
  @far_other %{stop_id: "S10", name: "Hilltop", parent_station: nil, lat: 42.0475, lon: -71.001}

  describe "windows/3: layovers" do
    test "a same-location wait at a marked stop opens the whole gap" do
      movements = movements([gap(0, 0, 600, :layover, 0, true)])

      assert [%{side: :same, start_secs: 0, end_secs: 600, drive_secs: 0, stop_id: "S1"} = window] =
               Relief.windows(
                 trips([@bay_a, @college]),
                 movements,
                 relief_context([@bay_a.stop_id])
               )

      assert window.gap_index == 0
    end

    test "a stop is marked through its parent station, and the window names the stop" do
      movements = movements([gap(0, 0, 600, :layover, 0, true)])

      assert [%{side: :same, stop_id: "S2"}] =
               Relief.windows(
                 trips([@bay_b, @college]),
                 movements,
                 relief_context(["Riverside Station"])
               )
    end

    test "a wait at a location nobody marked offers nothing" do
      movements = movements([gap(0, 0, 600, :layover, 0, true)])

      assert Relief.windows(trips([@bay_a, @college]), movements, relief_context([])) == []
    end
  end

  describe "windows/3: drives" do
    test "only the origin marked gives the change-then-drive window" do
      movements = movements([gap(0, 0, 1_200, :drive, 14 * @minute, true)])

      assert [%{side: :origin, start_secs: 0, end_secs: 360}] =
               Relief.windows(
                 trips([@bay_a, @college]),
                 movements,
                 relief_context([@bay_a.stop_id])
               )
    end

    test "only the destination marked gives the drive-then-change window" do
      movements = movements([gap(0, 0, 1_200, :drive, 14 * @minute, true)])

      assert [%{side: :destination, start_secs: 840, end_secs: 1_200}] =
               Relief.windows(
                 trips([@bay_a, @college]),
                 movements,
                 relief_context([@college.stop_id])
               )
    end

    test "both ends marked gives two disjoint windows, the origin first" do
      movements = movements([gap(0, 0, 1_200, :drive, 14 * @minute, true)])

      assert [origin, destination] =
               Relief.windows(
                 trips([@bay_a, @college]),
                 movements,
                 relief_context([@bay_a.stop_id, @college.stop_id])
               )

      assert origin.side == :origin
      assert destination.side == :destination
      # The two windows: the origin change happens at trip n's stop before the
      # drive, the destination change at trip n+1's stop after it.
      assert origin.start_secs == 0
      assert origin.end_secs == 1_200 - 14 * @minute
      assert destination.start_secs == 14 * @minute
      assert destination.end_secs == 1_200
      # Disjoint, so the two placements of the wait are genuinely exclusive and
      # a change can never be planned twice for one gap.
      assert origin.end_secs <= destination.start_secs
    end

    test "an infeasible gap offers no window" do
      movements = movements([gap(0, 0, 600, :drive, 14 * @minute, false)])

      assert Relief.windows(
               trips([@bay_a, @college]),
               movements,
               relief_context([@bay_a.stop_id, @college.stop_id])
             ) == []
    end

    test "an unknown drive offers no window" do
      movements = movements([gap(0, 0, 600, :drive, 0, false)])

      assert Relief.windows(
               trips([@bay_a, @college]),
               movements,
               relief_context([@bay_a.stop_id, @college.stop_id])
             ) == []
    end
  end

  describe "stretches/3" do
    test "no window and platform 06:05 gives one stretch equal to the platform span" do
      assert [%{from_secs: 21_300, to_secs: 21_900, secs: 600}] =
               Relief.stretches(platform(21_300, 21_900), [], 300)
    end

    test "a limit exactly equal to the only stretch is not over the limit" do
      # No window at all, so the whole platform is one stretch and the limit sits
      # exactly on it. "Longer than" is strict, so this is within the contract.
      stretches = Relief.stretches(platform(0, 600), [], 600)

      assert Enum.max(Enum.map(stretches, & &1.secs)) == 600
      refute Enum.any?(stretches, &(&1.secs > 600))
    end

    test "one window spanning the platform is split as evenly as the grid allows" do
      # A change anywhere in [0, 600] is available, so the best schedule puts it
      # in the middle and both stretches are 300 rather than one long 600.
      movements = platform(0, 600)
      windows = [window(0, :same, "S1", 0, 600, 0)]

      assert [%{secs: 300}, %{secs: 300}] = Relief.stretches(movements, windows, 600)
    end

    test "counterexample: 100-minute gap, 80-minute drive, both marked, limit 60" do
      # The worked example. A change at the origin and one at the
      # destination are a whole drive apart, so the stretch that must span the
      # drive is 80 minutes: over the limit, and exactly what should be reported.
      movements = platform(0, 10_800)

      windows = [
        window(0, :origin, "S1", 2_400, 3_600, 4_800),
        window(0, :destination, "S3", 7_200, 8_400, 4_800)
      ]

      stretches = Relief.stretches(movements, windows, 60 * @minute)

      assert div(Enum.max(Enum.map(stretches, & &1.secs)), @minute) == 80
      assert Enum.any?(stretches, &(&1.secs > 60 * @minute))
    end

    test "a nil limit uses every window's start and the caller raises no finding" do
      movements = platform(0, 3_600)
      windows = [window(0, :same, "S1", 600, 1_200, 0), window(1, :same, "S3", 2_400, 3_000, 0)]

      stretches = Relief.stretches(movements, windows, nil)

      assert Enum.map(stretches, & &1.from_secs) == [0, 600, 2_400]
      assert Enum.map(stretches, & &1.to_secs) == [600, 2_400, 3_600]
    end

    test "a block with no platform span has no stretch" do
      assert Relief.stretches(%{platform_start_secs: nil, platform_end_secs: nil}, [], 300) == []
    end

    test "a change never lands inside a drive" do
      # The origin window closes a full drive before the destination window
      # opens, so no plan can put a change in between.
      movements = platform(0, 10_800)

      windows = [
        window(0, :origin, "S1", 2_400, 3_600, 4_800),
        window(0, :destination, "S3", 7_200, 8_400, 4_800)
      ]

      instants = movements |> Relief.stretches(windows, 60 * @minute) |> Enum.map(& &1.to_secs)

      # The drive runs from 3_600 to 7_200 and no change may fall inside it.
      refute Enum.any?(instants, &(&1 > 3_600 and &1 < 7_200))
    end

    test "a schedule the latest-reachable greedy would strand" do
      # The greedy takes the latest instant reachable within the limit.
      # Taking 1920 here spends the last window near its far end and strands a
      # 2040 s tail, so that greedy calls the block uncoverable. Changing at 120
      # and 2040 keeps every stretch within the limit, so the block is
      # staffable and must not be reported as having no operator change.
      movements = platform(0, 3_960)

      windows = [
        window(0, :destination, "S3", 120, 1_260, 120),
        window(1, :destination, "S4", 1_620, 2_040, 360)
      ]

      limit = 1_920
      stretches = Relief.stretches(movements, windows, limit)

      assert Enum.max(Enum.map(stretches, & &1.secs)) <= limit
      refute Enum.any?(stretches, &(&1.secs > limit))
    end
  end

  describe "stretches/3 against Movements.build/3 output" do
    test "windows line up with a real layover gap and the stretches tile the platform" do
      context = planning_context([@bay_a.stop_id], %{})

      block = trips([@bay_a, @bay_a])
      movements = Movements.build(block, resolved(), context)

      assert [gap] = movements.gaps
      assert gap.kind == :layover

      windows = Relief.windows(block, movements, relief_context([@bay_a.stop_id]))

      assert [%{side: :same, start_secs: start, end_secs: finish}] = windows
      assert start == gap.arrival_secs
      assert finish == gap.departure_secs

      stretches = Relief.stretches(movements, windows, 10 * @minute)

      assert hd(stretches).from_secs == movements.platform_start_secs
      assert List.last(stretches).to_secs == movements.platform_end_secs

      assert Enum.sum(Enum.map(stretches, & &1.secs)) ==
               movements.platform_end_secs - movements.platform_start_secs
    end

    test "a real deadhead with both ends marked never puts a change inside the drive" do
      context =
        planning_context([@bay_a.stop_id, @college.stop_id], %{{:stop, "S1"}, {:stop, "S3"} => 14})

      block = trips([@bay_a, @college])
      movements = Movements.build(block, resolved(), context)

      assert [gap] = movements.gaps
      assert gap.kind == :drive
      assert gap.drive_secs == 14 * @minute

      windows =
        Relief.windows(block, movements, relief_context([@bay_a.stop_id, @college.stop_id]))

      assert [origin, destination] = windows
      assert origin.side == :origin
      assert destination.side == :destination
      # The bounds against the real gap: the origin window closes a drive
      # before the gap ends and the destination window opens a drive after it
      # starts. The two overlap whenever the wait outlasts the drive, which is
      # why the invariant that matters is the spacing rule rather than disjoint
      # windows -- see the 100-minute counterexample above.
      assert origin.start_secs == gap.arrival_secs
      assert origin.end_secs == gap.departure_secs - gap.drive_secs
      assert destination.start_secs == gap.arrival_secs + gap.drive_secs
      assert destination.end_secs == gap.departure_secs
    end
  end

  describe "the schedule equals the exhaustive optimum" do
    @tag :relief_oracle
    test "the smallest longest stretch any plan achieves is the one returned, over 300 seeded blocks" do
      :rand.seed(:exsss, {20_250_917, 7, 3})

      {checked, over_limit} =
        Enum.reduce(1..300, {0, 0}, fn _case, {checked, over_limit} ->
          block = block(:rand.uniform(3))
          windows = Relief.windows(block.trips, block.movements, block.context)
          limit = :rand.uniform(30) * @minute

          returned =
            block.movements
            |> Relief.stretches(windows, limit)
            |> Enum.map(& &1.secs)
            |> Enum.max(fn -> 0 end)

          best = exhaustive(block.movements, windows)

          assert returned == best, """
          returned #{returned}s, exhaustive optimum #{best}s
          windows: #{inspect(windows)}
          limit: #{limit}s
          """

          {checked + 1, over_limit + if(returned > limit, do: 1, else: 0)}
        end)

      assert checked == 300
      # The seeded blocks include over-limit cases, so the flagging path the
      # checks rely on is exercised rather than assumed.
      assert over_limit > 0
    end
  end

  # --- exhaustive oracle -----------------------------------------------------
  #
  # Written from the relief rules, not from the implementation: for every window
  # independently choose one 60-second-step instant or none, keep the plans that
  # respect the same-gap spacing, and take the smallest longest stretch any of
  # them achieves. The generated blocks are kept small precisely so this stays a
  # complete enumeration rather than a sample.

  defp exhaustive(movements, windows) do
    start = movements.platform_start_secs
    finish = movements.platform_end_secs

    windows
    |> plans()
    |> Enum.filter(&spaced?/1)
    |> Enum.map(&span(&1, start, finish))
    |> Enum.min(fn -> finish - start end)
  end

  # A plan is a list of `{instant, window}`. Each window independently takes one
  # instant or none, so this is the full space the rules allow.
  defp plans(windows), do: plans(windows, [])

  defp plans([], acc), do: [acc]

  defp plans([window | rest], acc) do
    taken = Enum.map(window.start_secs..window.end_secs//@minute, &{&1, window})

    # Each window independently takes one instant or none, so every plan already
    # built from the later windows is paired with each choice here. Concatenating
    # the two sets instead would only ever place a single change and would
    # quietly make the oracle weaker than the thing it is checking.
    Enum.flat_map(plans(rest, acc), fn tail ->
      [tail | Enum.map(taken, &[&1 | tail])]
    end)
  end

  # A `:destination` change of a gap whose `:origin` change was also taken
  # must be at least the drive later, because the vehicle is driving between.
  defp spaced?(plan) do
    plan
    |> Enum.group_by(fn {_instant, window} -> window.gap_index end)
    |> Enum.all?(fn {_gap_index, entries} -> gap_spaced?(entries) end)
  end

  # A `:destination` change of a gap whose `:origin` change was also taken must
  # be at least the drive later, because the vehicle is driving between. A gap
  # missing either side has nothing to compare.
  defp gap_spaced?(entries) do
    origin = Enum.find_value(entries, fn {i, w} -> if w.side == :origin, do: {i, w} end)

    destination =
      Enum.find_value(entries, fn {i, w} -> if w.side == :destination, do: {i, w} end)

    case {origin, destination} do
      {{origin_instant, %{drive_secs: drive}}, {destination_instant, _}} ->
        destination_instant >= origin_instant + drive

      _ ->
        true
    end
  end

  defp span(plan, start, finish) do
    instants = plan |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    ([start | instants] ++ [finish])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.max(fn -> 0 end)
  end

  # --- generated blocks ------------------------------------------------------

  # One to three gaps, each a layover or a drive, with a random subset of the
  # stops marked. Gaps are contiguous (one ends where the next begins), which is
  # what `Movements.build/3` guarantees, and short so the oracle above stays an
  # exhaustive enumeration. Seeded, so a failure reproduces.
  defp block(gap_count) do
    {gaps, _finish} =
      Enum.map_reduce(0..(gap_count - 1), 0, fn index, arrival ->
        kind = if :rand.uniform(2) == 1, do: :layover, else: :drive
        drive = if kind == :drive, do: :rand.uniform(3) * @minute, else: 0
        wait = :rand.uniform(5) * @minute
        feasible = :rand.uniform(10) > 1

        # Contiguous: one gap ends exactly where the next begins, which is what
        # `Movements.build/3` guarantees and what keeps the windows of one gap
        # from overlapping the next.
        gap_secs = drive + wait

        gap =
          gap(
            index,
            arrival,
            arrival + gap_secs,
            kind,
            if(feasible, do: drive, else: drive + 1),
            feasible
          )

        {gap, arrival + gap_secs}
      end)

    marked =
      [@bay_a.stop_id, @bay_b.stop_id, @college.stop_id, @market.stop_id]
      |> Enum.filter(fn _ -> :rand.uniform(2) == 1 end)

    %{
      trips:
        trips(Enum.take([@bay_a, @far, @college, @market, @bay_b, @far_other], gap_count + 1)),
      movements: movements(gaps),
      context: relief_context(marked)
    }
  end

  # --- fixtures --------------------------------------------------------------

  defp gap(index, arrival, departure, kind, drive, feasible?) do
    %{
      index: index,
      arrival_secs: arrival,
      departure_secs: departure,
      kind: kind,
      drive_secs: drive,
      feasible?: feasible?
    }
  end

  defp window(gap_index, side, stop_id, start_secs, end_secs, drive_secs) do
    %{
      gap_index: gap_index,
      side: side,
      stop_id: stop_id,
      start_secs: start_secs,
      end_secs: end_secs,
      drive_secs: drive_secs
    }
  end

  defp movements(gaps) do
    %{
      gaps: gaps,
      platform_start_secs: 0,
      platform_end_secs: gaps |> List.last() |> Map.fetch!(:departure_secs)
    }
  end

  defp platform(start, finish) do
    %{gaps: [], platform_start_secs: start, platform_end_secs: finish}
  end

  # `Relief` only reads `relief_stop_ids`, so the checks and generated cases use
  # the bare map rather than building a full context.
  defp relief_context(marked) do
    %{relief_stop_ids: MapSet.new(marked)}
  end

  defp planning_context(marked, entered) do
    struct!(
      Context,
      min_layover_minutes: 0,
      pull_out_buffer_minutes: 0,
      deadhead_speed_kmh: 30,
      deadhead_circuity: 1.3,
      entered_minutes: entered,
      trip_km: %{},
      garages: %{@garage_uuid => garage()},
      relief_stop_ids: MapSet.new(marked)
    )
  end

  defp garage do
    %{id: @garage_uuid, garage_id: "MAIN", name: "Main Garage", lat: 42.0, lon: -71.05}
  end

  defp resolved do
    %{
      garage_id: @garage_uuid,
      vehicle_type_id: @type_uuid,
      garage_source: :attribute,
      conflict: nil
    }
  end

  defp trip(departure_secs, first_stop, last_stop) do
    %{
      id: Ecto.UUID.generate(),
      trip_id: "T#{departure_secs}",
      route_id: "R1",
      service_id: "WKDY",
      block_id: "101",
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: "SH1",
      updated_at: DateTime.utc_now(),
      frequency?: false,
      headway_secs: nil,
      first_arrival: departure_secs,
      first_departure: departure_secs,
      last_arrival: departure_secs + @minute,
      last_departure: departure_secs + @minute,
      first_stop: first_stop,
      last_stop: last_stop,
      plottable?: true
    }
  end

  # Trips in `Checks.sequence/1` order, one per entry in `stops`, each starting
  # and ending at its own stop. Gap `n` therefore joins `stops[n]` to
  # `stops[n + 1]`, so a case that cares which stop a gap ends at names those
  # stops here rather than relying on a default.
  defp trips(stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.map(fn {stop, index} -> trip(index * 3_600, stop, stop) end)
  end
end
