defmodule GtfsPlanner.Gtfs.Runs.CutterTest do
  @moduledoc """
  How the cutter pairs pieces into runs, which assignments each scope may change,
  and how the runs it creates are numbered.

  The blocks here are built by the real `Blocking.Movements.build/3` and
  `Blocking.Relief.windows/3` over hand-built `Checks.trip_row` maps, exactly as
  `pieces_test.exs` and `day_test.exs` build theirs, so the movements and windows
  under the cutter's feet are the Blocks page's own. Results are then read back
  through `Runs.Day.derive/4` rather than through this module's own return value:
  the cutter does not use `Day` for its bookkeeping, so agreeing with it is
  evidence rather than tautology.

  ## The worked day

  Three blocks over one garage standing at the station, so every drive is zero
  and every figure is pure duty.

      101  06:00–07:00
      102  17:00–17:40
      103  20:00–21:00

  A two-piece run signs on 15 minutes early and signs off 5 minutes late, so its
  spread is `last end − first start + 20` minutes. For 101 and 102 that is
  11 h 40 + 20 = 720 minutes exactly — the limit, not past it — so they pair, and their
  165-minute break is far over the paid maximum, so the run is a split. 103 is
  three hours past 102's end, which puts the pair past 720 minutes, so it stays a
  one-piece run of its own.

  Moving 102 one minute later makes the spread 721 and the pair is refused.
  That boundary is the point of the pairing rule, so it is the centre of these
  tests.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief
  alias GtfsPlanner.Gtfs.Runs.Cutter
  alias GtfsPlanner.Gtfs.Runs.Day

  @garage_uuid "11111111-2222-4333-8444-555555555555"
  @bay_a %{stop_id: "BAY_A", name: "Bay A", parent_station: "RIV", lat: 42.0, lon: -71.0}

  @crew %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  defp hms(h, m), do: h * 3600 + m * 60

  defp context(opts \\ []) do
    garage = %{id: @garage_uuid, garage_id: "MAIN", name: "Main Garage", lat: 42.0, lon: -71.0}

    struct!(Context,
      min_layover_minutes: 0,
      pull_out_buffer_minutes: 0,
      deadhead_speed_kmh: 30,
      deadhead_circuity: 1.3,
      entered_minutes: Keyword.get(opts, :entered, %{}),
      trip_km: %{},
      default_garage_id: @garage_uuid,
      garages: %{@garage_uuid => garage},
      max_piece_minutes: Keyword.get(opts, :max_piece_minutes, nil),
      relief_stop_ids: MapSet.new(Keyword.get(opts, :marked, []))
    )
  end

  defp crew(opts), do: Map.merge(@crew, Map.new(opts))

  # One block, one trip, departing `departure` and arriving `arrival`.
  defp block(block_id, departure, arrival) do
    [%{id: _} | _] = trips = [trip(block_id, departure, arrival, @bay_a, @bay_a)]

    context = context()
    sequence = Checks.sequence(trips)
    movements = Movements.build(trips, resolution(), context)

    %{
      block_id: block_id,
      trips: sequence,
      movements: movements,
      windows: Relief.windows(trips, movements, context)
    }
  end

  defp trip(block_id, departure, arrival, first, last) do
    %{
      id: Ecto.UUID.generate(),
      trip_id: "#{block_id}-1",
      route_id: "R1",
      service_id: "WKDY",
      block_id: block_id,
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: "SH1",
      updated_at: DateTime.utc_now(),
      frequency?: false,
      headway_secs: nil,
      first_arrival: departure,
      first_departure: departure,
      last_arrival: arrival,
      last_departure: arrival,
      first_stop: first,
      last_stop: last,
      plottable?: true
    }
  end

  defp resolution do
    %{garage_id: @garage_uuid, vehicle_type_id: nil, garage_source: :default, conflict: nil}
  end

  # The three-block day described in the moduledoc.
  defp day_blocks do
    [
      block("101", hms(6, 0), hms(7, 0)),
      block("102", hms(17, 0), hms(17, 40)),
      block("103", hms(20, 0), hms(21, 0))
    ]
  end

  defp trip_ids(blocks) do
    Enum.flat_map(blocks, fn block -> Enum.map(block.trips, & &1.id) end)
  end

  describe "the uncovered-only scope" do
    test "keeps every existing assignment and numbers above the highest in use" do
      blocks = day_blocks()
      [existing_trip | _rest] = trip_ids(blocks)
      existing = %{existing_trip => "1013"}

      result = Cutter.run(:uncovered_only, blocks, existing, context(), @crew)

      # The one assigned trip keeps its run and its ID.
      assert result.assignments[existing_trip] == "1013"
      assert "1013" not in result.new_run_ids

      # The other two blocks are uncovered and pair into one run numbered above
      # 1013, not from the rebuild prefix.
      covered = trip_ids(blocks) -- [existing_trip]
      assert Enum.all?(covered, &Map.has_key?(result.assignments, &1))
      assert result.new_run_ids == ["1014"]
      assert result.assignments[Enum.at(covered, 0)] == "1014"
      assert result.assignments[Enum.at(covered, 1)] == "1014"
    end

    test "leaves the existing map's keys alone when nothing is uncovered" do
      blocks = day_blocks()
      existing = blocks |> trip_ids() |> Map.new(&{&1, "A"})

      result = Cutter.run(:uncovered_only, blocks, existing, context(), @crew)
      assert result.assignments == existing
      assert result.new_run_ids == []
    end
  end

  describe "the replace-all scope" do
    test "numbers from the rebuild prefix in sign-on order" do
      blocks = day_blocks()
      [existing_trip | _] = trip_ids(blocks)
      existing = %{existing_trip => "1013"}

      result = Cutter.run(:replace_all, blocks, existing, context(), @crew)

      # `rebuild_prefix(["1013"])` is 1000, so the rebuild starts at 1001 — not
      # at 1014, and not continuing from 1013.
      assert result.new_run_ids == ["1001", "1002"]

      # The earlier assignment is replaced, not merged: a rebuild recuts every
      # sequence trip, so the trip is still covered — by a new run instead.
      assert result.assignments[existing_trip] == "1001"
      refute "1013" in Map.values(result.assignments)
      assert Enum.sort(Map.keys(result.assignments)) == Enum.sort(trip_ids(blocks))
    end

    test "starts from 0 when the day type has no numeric run" do
      blocks = day_blocks()
      result = Cutter.run(:replace_all, blocks, %{}, context(), @crew)
      assert result.new_run_ids == ["1", "2"]
    end
  end

  describe "pairing" do
    test "pairs a morning and an afternoon block when the spread is exactly 720" do
      blocks = day_blocks()
      result = Cutter.run(:replace_all, blocks, %{}, context(), @crew)

      day = Day.derive(blocks, result.assignments, context(), @crew)
      assert [split, one_piece] = split_first(day.runs)

      # 101 and 102 pair: their spread is the limit itself, not past it.
      assert split.pieces |> Enum.map(& &1.block_id) |> Enum.sort() == ["101", "102"]
      assert split.work.spread_secs == hms(12, 0)
      assert minutes(split.work.spread_secs) == 720
      assert split.work.type == :split
      # 17:00 − 15 − 07:00 = 9 h 45 = 585 minutes, far over the paid maximum.
      assert [%{secs: 35_100, paid?: false}] = split.work.breaks

      # 103 is past 102's end by enough to break the limit, so it is alone.
      assert one_piece.work.type == :one_piece
      assert one_piece.pieces |> Enum.map(& &1.block_id) == ["103"]
    end

    test "does not pair when doing so would give 721 minutes of spread" do
      # 102 one minute later: 11 h 41 + 20 = 721, which is over the limit.
      blocks = [block("101", hms(6, 0), hms(7, 0)), block("102", hms(17, 1), hms(17, 41))]

      result = Cutter.run(:replace_all, blocks, %{}, context(), @crew)
      day = Day.derive(blocks, result.assignments, context(), @crew)

      assert length(day.runs) == 2
      assert Enum.all?(day.runs, &(&1.work.type == :one_piece))

      # The pair it refused would have spread 721 minutes: 11 h 41 between the
      # first departure and the last arrival, plus 15 in and 5 out.
      assert minutes(span(blocks)) + 20 == 721
    end

    defp span(blocks) do
      last =
        blocks |> List.last() |> Map.fetch!(:trips) |> List.last() |> Map.fetch!(:last_arrival)

      first = blocks |> hd() |> Map.fetch!(:trips) |> hd() |> Map.fetch!(:first_departure)
      last - first
    end

    test "a lower limit refuses one pair and the greedy takes the next" do
      blocks = day_blocks()

      generous = Cutter.run(:replace_all, blocks, %{}, context(), crew(max_spread_minutes: 720))
      tight = Cutter.run(:replace_all, blocks, %{}, context(), crew(max_spread_minutes: 719))

      generous_day =
        Day.derive(blocks, generous.assignments, context(), crew(max_spread_minutes: 720))

      tight_day = Day.derive(blocks, tight.assignments, context(), crew(max_spread_minutes: 719))

      # At 720 the pair is 101 + 102 and 103 is alone.
      assert [first | _] = generous_day.runs
      assert first.pieces |> Enum.map(& &1.block_id) |> Enum.sort() == ["101", "102"]

      # At 719 that pair is refused, and 101 — having passed on 102 — takes 103
      # instead... except 103 is too far from 101 to fit, so 101 is left alone and
      # 102 pairs with 103. The day is still two runs, but not the same two.
      assert [alone, pair] = Enum.sort_by(tight_day.runs, &length(&1.pieces))
      assert length(alone.pieces) == 1
      assert alone.pieces |> Enum.map(& &1.block_id) == ["101"]
      assert pair.pieces |> Enum.map(& &1.block_id) |> Enum.sort() == ["102", "103"]
    end
  end

  describe "which partner is chosen" do
    test "the shorter break wins, which is the one that makes a straight run" do
      # Three blocks: a close pair (13:00, 14:45) and a far one (13:00, 20:00).
      # The 13:00 piece has two partners; the shorter break is the 30-minute one
      # to 14:45, and a 30-minute break is paid, so the run is straight.
      blocks = [
        block("101", hms(13, 0), hms(14, 0)),
        block("102", hms(14, 45), hms(15, 45)),
        block("103", hms(20, 0), hms(21, 0))
      ]

      result = Cutter.run(:replace_all, blocks, %{}, context(), @crew)
      day = Day.derive(blocks, result.assignments, context(), @crew)

      assert [straight, far] = split_first(day.runs)

      assert straight.work.type == :straight
      assert straight.pieces |> Enum.map(& &1.block_id) |> Enum.sort() == ["101", "102"]
      assert [%{secs: 1800, paid?: true}] = straight.work.breaks

      # The far block could have paired with either, but 13:00 was taken and the
      # remaining candidate's break is seven hours.
      assert far.work.type == :one_piece
      assert far.pieces |> Enum.map(& &1.block_id) == ["103"]
    end
  end

  describe "determinism" do
    test "shuffling the blocks and the trips gives identical output" do
      blocks = day_blocks()
      context = context()

      result = Cutter.run(:replace_all, blocks, %{}, context, @crew)
      shuffled = Enum.shuffle(blocks)
      result_shuffled = Cutter.run(:replace_all, shuffled, %{}, context, @crew)

      assert result.assignments == result_shuffled.assignments
      assert result.new_run_ids == result_shuffled.new_run_ids
    end
  end

  describe "a version with no relief setup" do
    test "no windows and no limit leaves every block as exactly one piece" do
      # With nothing to cut at, a segment is one piece. That is the cut rule;
      # whether two such pieces later pair into one run is the pairing rule's
      # question, and is a separate test below.
      blocks = day_blocks()
      bare = Enum.map(blocks, &%{&1 | windows: []})
      result = Cutter.run(:replace_all, bare, %{}, context(marked: []), @crew)

      day = Day.derive(bare, result.assignments, context(marked: []), @crew)
      pieces = day.runs |> Enum.flat_map(& &1.pieces)

      assert length(pieces) == 3
      assert pieces |> Enum.map(& &1.block_id) |> Enum.sort() == ["101", "102", "103"]

      # Every piece is the whole block: no cut happened anywhere.
      assert Enum.all?(pieces, &(&1.trips |> length() == 1))
    end

    test "without relief setup the far-apart blocks stay separate runs" do
      blocks = [block("101", hms(6, 0), hms(7, 0)), block("102", hms(20, 0), hms(21, 0))]
      bare = Enum.map(blocks, &%{&1 | windows: []})

      result = Cutter.run(:replace_all, blocks, %{}, context(marked: []), @crew)
      day = Day.derive(bare, result.assignments, context(marked: []), @crew)

      assert length(day.runs) == 2
      assert Enum.all?(day.runs, &(&1.work.type == :one_piece))
    end
  end

  defp minutes(secs), do: div(secs, 60)

  # `:one_piece` sorts before `:split` alphabetically, which is the wrong way
  # round for a test that wants to talk about the split first.
  defp split_first(runs) do
    Enum.sort_by(runs, fn run -> if run.work.type == :split, do: 0, else: 1 end)
  end
end
