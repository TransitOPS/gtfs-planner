defmodule GtfsPlanner.Gtfs.Runs.PiecesTest do
  @moduledoc """
  Merge evidence (EV-3) for CL-3: pieces, handovers and uncovered segments follow
  the relief-window rule, the deadhead sides and service-day arithmetic, so FH-3
  and FH-4 stay rejected.

  Every block here is built by the real `Blocking.Movements.build/3` and
  `Blocking.Relief.windows/3` over hand-built `Checks.trip_row` maps, so the
  movements and windows under test are spec 07's own, not a restatement of them:
  a change of this module's rule about which window a gap has would be caught
  here rather than hidden behind a fixture. The module under test calls no
  repository, clock, file or network, so these cases need no sandbox and no
  cleanup.

  The independence EV-3 names is the first case: the hand-computed 6104 → 8106
  example from `context.md`, where 6104 ends 07:40 at an unmarked Valley College,
  the entered drive to the marked Market Square takes 14 minutes and 8106 leaves
  08:20, so the only window is `:destination` [07:54, 08:20]. The vehicle can only
  be at Market Square at 07:54 if the operator who held it at Valley College drove
  it, which is what the case asserts about gap ownership.

  ## A discrepancy this test records

  The side-to-gap-ownership mapping here is the card's, and it is the physically
  coherent one, but `spec.md` states it the other way round in three places — rule
  3 ("`:origin` → the incoming operator drives"), AC-3 ("with an `:origin` window
  the incoming piece owns the drive") and the step 4 description ("`:origin`/
  `:same` puts the boundary gap in the incoming piece's `gaps`, `:destination` in
  the outgoing piece's"). The 6104 → 8106 times settle it: a `:destination`
  handover at 07:54 at Market Square cannot happen unless the incoming operator
  drove, so `:destination` is the incoming piece's gap and `:origin` is the
  outgoing piece's — the reverse of all three sentences. This is raised for
  correction in the step 4 learning; the test pins the coherent behaviour so a
  later step cannot quietly pick up the prose.

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_runs08 mix test test/gtfs_planner/gtfs/runs/pieces_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief
  alias GtfsPlanner.Gtfs.Runs.Pieces

  @garage_uuid "11111111-2222-4333-8444-555555555555"

  @bay_a %{stop_id: "BAY_A", name: "Bay A", parent_station: "RIV", lat: 42.0, lon: -71.0}
  @bay_b %{stop_id: "BAY_B", name: "Bay B", parent_station: "RIV", lat: 42.0, lon: -71.0}
  @college %{stop_id: "VC", name: "Valley College", parent_station: nil, lat: 42.0475, lon: -71.0}
  @market %{
    stop_id: "MS",
    name: "Market Square",
    parent_station: nil,
    lat: 42.03,
    lon: -71.0
  }

  describe "the 6104 to 8106 example" do
    test "a destination handover is the incoming piece's drive" do
      # 07:00–07:40 at Valley College, then 08:20–08:50 at Market Square, with a
      # 14-minute entered drive between them.
      {incoming, outgoing} = two_trip_block()

      context = context(marked: ["MS"], entered: %{{{:stop, "VC"}, {:stop, "MS"}} => 14})
      block = block([incoming, outgoing], context)

      %{pieces: pieces, boundaries: [boundary]} =
        Pieces.derive([block], %{incoming.id => "A", outgoing.id => "B"})

      assert [a, b] = pieces

      # The only window is `:destination` [07:54, 08:20] at Market Square, and
      # `Relief.windows/3` lists origin before destination, so the first match is
      # the one the change happens at.
      assert boundary.at_relief?
      assert boundary.side == :destination
      assert boundary.at_secs == 7 * 3600 + 54 * 60
      assert boundary.stop == @market
      assert {boundary.from_run, boundary.to_run} == {"A", "B"}
      assert {boundary.from_trip_id, boundary.to_trip_id} == {incoming.id, outgoing.id}

      # The drive is in the incoming piece's gaps: the vehicle is at Valley
      # College when 6104 ends and can only be at Market Square at 07:54 if
      # A drove it. B picks it up there and waits for 08:20.
      assert [gap] = a.gaps
      assert gap.index == 0
      assert gap.kind == :drive
      assert gap.drive_secs == 14 * 60
      assert b.gaps == []
    end

    test "an origin handover is the outgoing piece's drive" do
      {incoming, outgoing} = two_trip_block()

      # Both ends marked, so the gap has an origin window at Valley College
      # first; the change happens there and B drives on to Market Square.
      context = context(marked: ["VC", "MS"], entered: %{{{:stop, "VC"}, {:stop, "MS"}} => 14})
      block = block([incoming, outgoing], context)

      %{pieces: [a, b], boundaries: [boundary]} =
        Pieces.derive([block], %{incoming.id => "A", outgoing.id => "B"})

      assert boundary.side == :origin
      assert boundary.at_secs == 7 * 3600 + 40 * 60
      assert boundary.stop == @college

      assert a.gaps == []
      assert [gap] = b.gaps
      assert gap.index == 0
      assert gap.kind == :drive
    end
  end

  describe "handover at a layover" do
    test "a same-location wait at a marked stop hands over at the window start" do
      first = trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a)
      second = trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b)

      context = context(marked: ["RIV"])
      block = block([first, second], context)

      %{pieces: pieces, boundaries: [boundary]} =
        Pieces.derive([block], %{first.id => "A", second.id => "B"})

      assert boundary.side == :same
      assert boundary.at_relief?
      # A layover opens the whole gap, so the change may happen as soon as the
      # vehicle stands there.
      assert boundary.at_secs == 6 * 3600
      assert boundary.stop == @bay_a

      assert length(pieces) == 2
    end

    test "a change at an unmarked layover falls back to the trip's last arrival" do
      first = trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a)
      second = trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b)

      # Nothing marked, so the gap has no window and the change is flagged.
      block = block([first, second], context(marked: []))

      %{pieces: [a, b], boundaries: [boundary]} =
        Pieces.derive([block], %{first.id => "A", second.id => "B"})

      refute boundary.at_relief?
      assert boundary.side == nil
      assert boundary.at_secs == 6 * 3600
      assert boundary.stop == @bay_a
      # The vehicle never moves, and the gap belongs to the piece that ends here.
      assert [%{kind: :layover}] = a.gaps
      assert b.gaps == []
    end

    test "an infeasible drive gap has no window, so the change is not at a relief" do
      # The drive needs 20 minutes and the gap is 5, so `Movements` calls the gap
      # infeasible and `Relief` opens no window on it at all.
      first = trip("a", "101", 8 * 3600, 8 * 3600 + 30 * 60, @college, @college)
      second = trip("b", "101", 8 * 3600 + 35 * 60, 9 * 3600, @market, @market)

      context = context(marked: ["MS"], entered: %{{{:stop, "VC"}, {:stop, "MS"}} => 20})
      block = block([first, second], context)
      %{boundaries: [boundary]} = Pieces.derive([block], %{first.id => "A", second.id => "B"})

      assert %{feasible?: false} = Enum.find(block.movements.gaps, &(&1.index == 0))
      refute boundary.at_relief?
      assert boundary.at_secs == 8 * 3600 + 30 * 60
      assert boundary.stop == @college
    end
  end

  describe "block ends" do
    test "a garage-less block starts at the first departure and ends at the last arrival" do
      first = trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a)
      second = trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b)

      block = block([first, second], context(garage: nil))

      %{pieces: [piece], boundaries: []} =
        Pieces.derive([block], %{first.id => "A", second.id => "A"})

      assert piece.start_kind == :block_start
      assert piece.start_secs == 5 * 3600
      assert piece.start_ref == {:stop, "BAY_A"}
      assert piece.start_stop == @bay_a
      assert piece.start_boundary == nil

      assert piece.end_kind == :block_end
      assert piece.end_secs == 8 * 3600
      assert piece.end_ref == {:stop, "BAY_B"}
      assert piece.garage_id == nil
    end

    test "a garage block starts at the pull-out and ends at the pull-back" do
      first = trip("a", "101", 6 * 3600, 7 * 3600, @bay_a, @bay_a)

      block = block([first], context())
      %{pieces: [piece]} = Pieces.derive([block], %{first.id => "A"})

      assert piece.start_kind == :block_start
      assert piece.start_secs == block.movements.pull_out.start_secs
      assert piece.start_ref == {:garage, @garage_uuid}
      # The first stop is where service begins; the drive from the garage is the
      # travel in, which is step 5's work, not this module's.
      assert piece.start_stop == @bay_a

      assert piece.end_kind == :block_end
      assert piece.end_secs == block.movements.pull_back.end_secs
      assert piece.end_ref == {:garage, @garage_uuid}
    end
  end

  describe "service-day arithmetic" do
    test "a pull-out before midnight is an ordinary negative start" do
      first = trip("a", "101", 5 * 60, 6 * 3600, @bay_a, @bay_a)

      context = context(pull_out_buffer_minutes: 20)
      block = block([first], context)
      %{pieces: [piece]} = Pieces.derive([block], %{first.id => "A"})

      # 00:05 departure behind a 20-minute pull-out starts at −900, which is
      # fifteen minutes before the service day opens, and is carried through
      # unchanged rather than wrapped to 23:45.
      assert block.movements.pull_out.start_secs == -900
      assert piece.start_secs == -900
    end

    test "an arrival at 25:10 is an ordinary end of a garage-less block" do
      first = trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a)
      last = trip("b", "101", 24 * 3600 + 50 * 60, 25 * 3600 + 10 * 60, @bay_a, @bay_a)

      block = block([first, last], context(garage: nil))
      %{pieces: [piece]} = Pieces.derive([block], %{first.id => "A", last.id => "A"})

      # 25:10 is 91,000 seconds of service-day arithmetic only if the day were
      # measured from one; it is 25 h 10 m, so 90,600, and it is kept as it is
      # rather than wrapped to the next day.
      assert piece.end_secs == 90_600
      assert piece.end_secs == 25 * 3600 + 10 * 60
    end
  end

  describe "grouping" do
    test "one block cut A, B, A gives two pieces of A and one of B" do
      trips = [
        trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a),
        trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b),
        trip("c", "101", 9 * 3600, 10 * 3600, @bay_a, @bay_a)
      ]

      block = block(trips, context(marked: ["RIV"]))
      [a1, b2, a3] = trips

      %{pieces: pieces, boundaries: boundaries} =
        Pieces.derive([block], %{a1.id => "A", b2.id => "B", a3.id => "A"})

      assert Enum.map(pieces, & &1.run_id) == ["A", "B", "A"]
      assert length(boundaries) == 2

      # The two pieces of A are the same run in the same block, and the middle
      # piece of B carries only its own trip.
      assert [%{trips: [^a1]}, %{trips: [^b2]}, %{trips: [^a3]}] = pieces
    end

    test "a piece holds the gaps between its own trips" do
      trips = [
        trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a),
        trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b),
        trip("c", "101", 9 * 3600, 10 * 3600, @bay_a, @bay_a)
      ]

      block = block(trips, context(marked: ["RIV"]))
      [a1, b2, a3] = trips

      %{pieces: [first, middle, last]} =
        Pieces.derive([block], %{a1.id => "A", b2.id => "B", a3.id => "A"})

      # A, B and C: the layover at the marked station is a `:same` window, so the
      # incoming piece of each change holds the gap and the last piece holds none.
      assert Enum.map(first.gaps, & &1.index) == [0]
      assert Enum.map(middle.gaps, & &1.index) == [1]
      assert last.gaps == []
    end
  end

  describe "uncovered work" do
    test "unassigned consecutive trips form one uncovered segment with no run" do
      trips = [
        trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a),
        trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b),
        trip("c", "101", 9 * 3600, 10 * 3600, @bay_a, @bay_a)
      ]

      block = block(trips, context(marked: ["RIV"]))
      [a1, _b2, c3] = trips

      %{pieces: pieces, uncovered: uncovered, boundaries: boundaries} =
        Pieces.derive([block], %{a1.id => "A", c3.id => "A"})

      # The middle trip is unassigned, so it is uncovered work and is not part of
      # any run: it comes back in its own list, not among the pieces.
      assert Enum.map(pieces, & &1.run_id) == ["A", "A"]
      assert [segment] = uncovered
      assert segment.run_id == nil
      assert Enum.map(segment.trips, & &1.trip_id) == ["b"]

      # The change into uncovered work and out of it are both real boundaries.
      assert length(boundaries) == 2
      assert Enum.map(boundaries, & &1.to_run) == [nil, "A"]
    end

    test "consecutive unassigned trips are one segment, not two" do
      trips = [
        trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a),
        trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b),
        trip("c", "101", 9 * 3600, 10 * 3600, @bay_a, @bay_a)
      ]

      block = block(trips, context(marked: ["RIV"]))
      [a1, b2, c3] = trips

      %{uncovered: [segment]} =
        Pieces.derive([block], %{a1.id => "A", b2.id => nil, c3.id => nil})

      assert Enum.map(segment.trips, & &1.trip_id) == ["b", "c"]
      assert [%{index: 1}] = segment.gaps
    end

    test "a block with nothing assigned is all uncovered and yields no piece" do
      trips = [
        trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a),
        trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b)
      ]

      block = block(trips, context(marked: ["RIV"]))

      assert %{pieces: [], uncovered: [segment], boundaries: []} = Pieces.derive([block], %{})
      assert Enum.map(segment.trips, & &1.trip_id) == ["a", "b"]
    end
  end

  describe "trips that can never be in a run" do
    test "a frequency trip and an unplottable trip appear in no piece" do
      first = trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a)

      frequency = %{
        trip("f", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b)
        | frequency?: true,
          headway_secs: 600
      }

      unplottable = %{trip("u", "101", 9 * 3600, 10 * 3600, @bay_a, @bay_a) | plottable?: false}
      last = trip("b", "101", 11 * 3600, 12 * 3600, @bay_b, @bay_b)

      block = block([first, frequency, unplottable, last], context(marked: ["RIV"]))

      %{pieces: pieces, uncovered: uncovered, boundaries: boundaries} =
        Pieces.derive([block], %{
          first.id => "A",
          frequency.id => "B",
          unplottable.id => "B",
          last.id => "A"
        })

      # Neither row is a sequence trip, so neither is in a piece, and the two
      # remaining trips are one run: no boundary was created for them.
      assert [%{trips: served}] = pieces
      assert Enum.map(served, & &1.trip_id) == ["a", "b"]
      assert uncovered == []
      assert boundaries == []
    end

    test "a block of only unusable trips yields nothing at all" do
      frequency = %{trip("f", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b) | frequency?: true}
      unplottable = %{trip("u", "101", 9 * 3600, 10 * 3600, @bay_a, @bay_a) | plottable?: false}

      block = block([frequency, unplottable], context(marked: ["RIV"]))

      assert Pieces.derive([block], %{frequency.id => "A", unplottable.id => "A"}) ==
               %{pieces: [], uncovered: [], boundaries: []}
    end
  end

  describe "several blocks" do
    test "each block is cut on its own and the boundaries are all returned" do
      first_block = [
        trip("a", "101", 5 * 3600, 6 * 3600, @bay_a, @bay_a),
        trip("b", "101", 7 * 3600, 8 * 3600, @bay_b, @bay_b)
      ]

      second_block = [
        trip("c", "102", 12 * 3600, 12 * 3600 + 30 * 60, @bay_a, @bay_a),
        trip("d", "102", 12 * 3600 + 40 * 60, 13 * 3600, @bay_b, @bay_b)
      ]

      context = context(marked: ["RIV"])
      [a1, b2, c3, d4] = first_block ++ second_block

      blocks = [
        block(first_block, context, "101"),
        block(second_block, context, "102")
      ]

      %{pieces: pieces, boundaries: boundaries} =
        Pieces.derive(blocks, %{a1.id => "A", b2.id => "B", c3.id => "A", d4.id => "B"})

      assert Enum.map(pieces, & &1.block_id) == ["101", "101", "102", "102"]
      assert Enum.map(boundaries, & &1.block_id) == ["101", "102"]
    end
  end

  describe "derive/2 on nothing" do
    test "no blocks is no pieces, no uncovered work and no boundaries" do
      assert Pieces.derive([], %{}) == %{pieces: [], uncovered: [], boundaries: []}
    end
  end

  # 6104 → 8106: an unmarked Valley College origin and a marked Market Square
  # destination, 40 minutes apart with a 14-minute entered drive between. The
  # garage is put on Market Square so neither trip is near it and the block's
  # pull-out cannot affect the handover being asserted.
  defp two_trip_block do
    {trip("6104", "101", 7 * 3600, 7 * 3600 + 40 * 60, @college, @college),
     trip("8106", "101", 8 * 3600 + 20 * 60, 8 * 3600 + 50 * 60, @market, @market)}
  end

  # A block built the way `Blocking.load_day/3` builds one: the trips, the
  # movements over them, and the relief windows over those movements.
  defp block(trips, context, block_id \\ "101") do
    sequence = Checks.sequence(trips)
    movements = Movements.build(trips, resolved(context), context)
    windows = Relief.windows(trips, movements, context)

    %{block_id: block_id, trips: sequence, movements: movements, windows: windows}
  end

  defp resolved(%{garages: %{@garage_uuid => _garage}}), do: resolution(@garage_uuid)
  defp resolved(_context), do: resolution(nil)

  defp resolution(garage_id) do
    %{
      garage_id: garage_id,
      vehicle_type_id: nil,
      garage_source: if(garage_id, do: :default, else: :none),
      conflict: nil
    }
  end

  defp context(opts \\ []) do
    # The garage stands at Bay A's own point unless a case moves it, so the
    # pull-out's drive is zero and the pull-out start is exactly the departure
    # less the buffer — the arithmetic the service-day case pins.
    {lat, lon} = Keyword.get(opts, :garage_at, {42.0, -71.0})

    garage = %{
      id: @garage_uuid,
      garage_id: "MAIN",
      name: "Main Garage",
      lat: lat,
      lon: lon
    }

    struct!(Context,
      min_layover_minutes: 0,
      pull_out_buffer_minutes: Keyword.get(opts, :pull_out_buffer_minutes, 0),
      deadhead_speed_kmh: 30,
      deadhead_circuity: 1.3,
      entered_minutes: Keyword.get(opts, :entered, %{}),
      trip_km: %{},
      garages: if(Keyword.get(opts, :garage, true), do: %{@garage_uuid => garage}, else: %{}),
      relief_stop_ids: MapSet.new(Keyword.get(opts, :marked, []))
    )
  end

  defp trip(trip_id, block_id, first_departure, last_arrival, first_stop, last_stop) do
    %{
      id: Ecto.UUID.generate(),
      trip_id: trip_id,
      route_id: "R1",
      service_id: "WKDY",
      block_id: block_id,
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: "SH1",
      updated_at: DateTime.utc_now(),
      frequency?: false,
      headway_secs: nil,
      first_arrival: first_departure,
      first_departure: first_departure,
      last_arrival: last_arrival,
      last_departure: last_arrival,
      first_stop: first_stop,
      last_stop: last_stop,
      plottable?: true
    }
  end
end
