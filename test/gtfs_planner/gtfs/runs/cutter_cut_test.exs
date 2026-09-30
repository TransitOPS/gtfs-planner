defmodule GtfsPlanner.Gtfs.Runs.Cutter.CutTest do
  @moduledoc """
  Where the cutter cuts a segment into pieces: at the latest handover whose piece
  stays within `max_piece_minutes`, else the earliest handover after it.

  The windows here are hand-placed rather than built by
  `Blocking.Relief.windows/3`, so the cases stay independent of the movement
  build. The subject is this module's choice of cut point, and a window list that
  a movement build produced would already encode a judgement this test is meant to
  make.

  ## The greedy ceiling, on the numbers

  A segment starting at 08:00 with a 330-minute limit:

  - Handovers at 3 h and 5 h after the start are 180 and 300 minutes
    after it. Both fit, and the rule takes the latest, so the cut is at 5 h. An
    earliest-fit cut would be at 3 h, and the test asserts it is not.
  - Handovers at 6 h and 8 h are 360 and 480 minutes, both over the
    limit. Nothing fits, so the rule takes the earliest and the first piece runs
    6 h — 360 minutes, thirty over the limit. The test asserts the over-length
    explicitly rather than treating it as a failure of the cut.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/cutter_cut_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Runs.Cutter

  @relief "RIV"

  defp hms(h, m), do: h * 3600 + m * 60

  defp trip(index) do
    %{
      id: Ecto.UUID.generate(),
      trip_id: "t#{index}",
      route_id: "R1",
      service_id: "WKDY",
      block_id: "101",
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: "SH1",
      updated_at: DateTime.utc_now(),
      frequency?: false,
      headway_secs: nil,
      first_arrival: 0,
      first_departure: 0,
      last_arrival: 0,
      last_departure: 0,
      first_stop: %{
        stop_id: "BAY_A",
        name: "Bay A",
        parent_station: @relief,
        lat: 42.0,
        lon: -71.0
      },
      last_stop: %{
        stop_id: "BAY_A",
        name: "Bay A",
        parent_station: @relief,
        lat: 42.0,
        lon: -71.0
      },
      plottable?: true
    }
  end

  # A segment of `count` consecutive trips, each departing `step` after the
  # previous arrives, with a gap of `gap_index` between trips *i* and *i*+1 and
  # therefore a `Movements.gap()` carrying that index and that trip pair.
  defp segment(opts) do
    count = Keyword.get(opts, :count, 5)
    gap_indices = Keyword.get(opts, :gaps, [1, 2, 3])
    trips = Enum.map(1..count, &trip/1)

    gaps =
      Enum.flat_map(gap_indices, fn index ->
        case {Enum.at(trips, index - 1), Enum.at(trips, index)} do
          {nil, _} -> []
          {_, nil} -> []
          {from, to} -> [%{index: index, from_id: from.id, to_id: to.id}]
        end
      end)

    %{
      run_id: nil,
      block_id: "101",
      garage_id: nil,
      route_id: "R1",
      trips: trips,
      start_secs: Keyword.get(opts, :start, hms(8, 0)),
      end_secs: Keyword.get(opts, :end, hms(18, 0)),
      start_kind: :block_start,
      end_kind: :block_end,
      start_ref: {:stop, "BAY_A"},
      end_ref: {:stop, "BAY_A"},
      start_stop: nil,
      end_stop: nil,
      start_boundary: nil,
      end_boundary: nil,
      gaps: gaps
    }
  end

  # A window at `at` on gap `gap_index` — a hand-placed handover instant.
  defp window(gap_index, at) do
    %{
      gap_index: gap_index,
      side: :origin,
      stop_id: @relief,
      start_secs: at,
      end_secs: at + 600,
      drive_secs: 0
    }
  end

  describe "handovers that fit inside the limit" do
    test "the latest one is chosen, not the earliest" do
      start = hms(8, 0)
      # 3 h and 5 h after the start: 180 and 300 minutes, both within 330.
      windows = [window(1, start + hms(3, 0)), window(2, start + hms(5, 0))]

      assert [first, second] = Cutter.cut(segment([]), windows, 330)

      # The greedy ceiling: the operator stays on duty as long as the limit
      # allows, so the first piece runs to the 5-hour handover.
      assert first.end_secs == start + hms(5, 0)
      assert second.start_secs == start + hms(5, 0)
      # The cut is at gap 2, which is between the second and third trips, so two
      # trips stay and three go.
      assert length(first.trips) == 2
      assert length(second.trips) == 3
    end
  end

  describe "handovers that do not fit" do
    test "the earliest is chosen and the first piece runs over the limit" do
      start = hms(8, 0)
      # 6 h and 8 h after the start: 360 and 480 minutes, both over 330.
      windows = [window(1, start + hms(6, 0)), window(2, start + hms(8, 0))]

      assert [first, second] = Cutter.cut(segment([]), windows, 330)

      # Nothing fits, so the ceiling gives up and takes the earliest. The first
      # piece is 360 minutes against a 330 limit: over-length, and reported as
      # such later rather than avoided by refusing to cut.
      assert first.end_secs == start + hms(6, 0)
      assert first.end_secs - first.start_secs == hms(6, 0)
      assert first.end_secs - first.start_secs > 330 * 60
      assert second.start_secs == start + hms(6, 0)
    end
  end

  describe "a segment with nothing to cut at" do
    test "no internal window returns the segment as one piece" do
      original = segment([])
      assert [^original] = Cutter.cut(original, [], 330)
    end

    test "a window on a gap the segment does not contain is not a candidate" do
      # Gap 9 is not one of the segment's gaps 1, 2 and 3, so a window there is
      # a handover somewhere else in the block.
      windows = [window(9, hms(8, 0) + hms(3, 0))]
      original = segment([])

      assert [^original] = Cutter.cut(original, windows, 330)
    end

    test "a nil limit returns the segment as one piece" do
      # No limit, no ceiling, and therefore nothing to cut for.
      windows = [window(1, hms(8, 0) + hms(3, 0))]
      original = segment([])

      assert [^original] = Cutter.cut(original, windows, nil)
    end
  end

  describe "a segment that starts mid-block" do
    test "the limit is measured from the segment's own start" do
      # The same windows and the same limit, but the segment starts at 14:00
      # rather than 08:00, so the 3 h handover is only 180 minutes into it
      # rather than into the block.
      start = hms(14, 0)
      late = segment(start: start, end: start + hms(4, 0))
      windows = [window(1, start + hms(1, 0)), window(2, start + hms(3, 0))]

      assert [first, _second] = Cutter.cut(late, windows, 330)

      # Measured from the block's 08:00 the 1 h handover would be 7 h in and
      # nothing would fit, cutting at the earliest. Measured from 14:00 both fit
      # and the latest wins, which is the rule.
      assert first.end_secs == start + hms(3, 0)
    end
  end

  describe "how many candidates a gap contributes" do
    test "only its first window, so two windows on one gap are one handover" do
      start = hms(8, 0)

      windows = [
        window(1, start + hms(1, 0)),
        # The same gap again, 4 hours later and a different side. Counting this
        # as a second candidate would make 5 h look like a choice.
        %{window(1, start + hms(4, 0)) | side: :destination}
      ]

      assert [first, _second] = Cutter.cut(segment([]), windows, 330)
      assert first.end_secs == start + hms(1, 0)
    end

    test "each internal gap contributes its own candidate" do
      start = hms(8, 0)
      windows = [window(1, start + hms(1, 0)), window(3, start + hms(2, 0))]

      assert [first, _second] = Cutter.cut(segment([]), windows, 330)
      assert first.end_secs == start + hms(2, 0)
    end
  end

  describe "what the two pieces say about the handover" do
    test "the first ends where the second starts, both at the relief stop" do
      start = hms(8, 0)
      at = start + hms(3, 0)

      assert [first, second] = Cutter.cut(segment([]), [window(1, at)], 330)

      assert first.end_secs == second.start_secs
      assert first.end_kind == :relief
      assert second.start_kind == :relief
      assert first.end_ref == {:stop, @relief}
      assert second.start_ref == {:stop, @relief}

      # The cut gap is neither piece's: it is the boundary between them, and the
      # internal gaps are partitioned around it.
      assert Enum.map(first.gaps, & &1.index) == [1]
      assert Enum.map(second.gaps, & &1.index) == [2, 3]
    end

    test "every trip is kept exactly once" do
      start = hms(8, 0)
      original = segment([])

      assert [first, second] = Cutter.cut(original, [window(2, start + hms(2, 0))], 330)
      assert first.trips ++ second.trips == original.trips
    end
  end
end
