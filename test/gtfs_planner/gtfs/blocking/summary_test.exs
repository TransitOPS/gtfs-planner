defmodule GtfsPlanner.Gtfs.Blocking.SummaryTest do
  @moduledoc """
  Merge evidence (EV-5) for the pure block summaries, sorting, peak vehicles out
  and 15-minute bins:

  - Blocks spanning 06:00-10:00, 08:01-08:06 and 10:00-12:00 give a peak of 2 at
    08:01, and the two blocks touching at 10:00 count once.
  - A block whose trips run 06:00-08:00 and 10:00-12:00 is still active at 09:00,
    so its span includes the gap between its trips; a block with an overlap counts
    once.
  - A block without a plottable, non-frequency trip has no span, no hours and no
    bins, and is left out of the peak.
  - The 08:00 bin of the three-block day reports 2 even though one block covers
    08:00, because the 08:01-08:06 block starts inside it; the 10:00 bin reports 1
    for the touching pair.
  - Natural order is `2 < 10 < 101 < A1`; status sorting puts errors first and
    breaks ties by natural block ID; `nil` values sort last in both directions.
    The timeline sorts by `:garage` (the garage's name, then the type's name) and
    by `:out` (the platform start), the two keys AC-32 gives the timeline; the
    removed Trips, Start and End columns are not keys.
  - A block's status is the worst severity of its own findings with the first code
    of that severity in the fixed order, and hours are one decimal. AC-16's order
    puts the errors Overlap, Can't reach and Wrong type ahead of the warnings
    Short layover, In-seat row, Too long, No operator change, Route switch and
    Garage differs, and puts the notices last.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/summary_test.exs`. Every expected value
  is hand-computed from the AC-8 examples in integer clock seconds; the module
  reads no database, clock, files or network.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.{Checks, Context}
  alias GtfsPlanner.Gtfs.Blocking.Summary

  describe "block_summary/3" do
    test "summarizes a block whose only finding is a short layover" do
      trips = [
        trip("a", at(6, 0), at(8, 0), last_stop: stop("S1")),
        trip("b", at(8, 2), at(10, 0), first_stop: stop("S1"))
      ]

      # A two-minute gap against the five-minute minimum, with a handoff at one
      # stop, is a short layover and nothing else.
      assert [%{code: :short_layover, severity: :warning}] =
               Checks.block_findings("7", trips, Context.layover_only(5))

      assert Summary.block_summary(
               "7",
               trips,
               Checks.block_findings("7", trips, Context.layover_only(5))
             ) == %{
               block_id: "7",
               trip_count: 2,
               start_secs: 21_600,
               end_secs: 36_000,
               hours: 4.0,
               status: :warning,
               status_code: :short_layover,
               route_ids: ["R1"],
               garage_name: nil,
               type_name: nil,
               conflict?: false
             }
    end

    test "reports hours to one decimal" do
      summary = Summary.block_summary("7", [trip("a", at(6, 0), at(7, 20))], [])

      assert summary.start_secs == 21_600
      assert summary.end_secs == 26_400
      assert summary.hours == 1.3
      assert summary.status == :ok
      assert summary.status_code == nil
    end

    test "lists the block's routes sorted and once each" do
      trips = [
        trip("a", at(6, 0), at(7, 0), route_id: "R9"),
        trip("b", at(7, 10), at(8, 0), route_id: "R2"),
        trip("c", at(8, 10), at(9, 0), route_id: "R9")
      ]

      summary = Summary.block_summary("7", trips, [])

      assert summary.route_ids == ["R2", "R9"]
      assert summary.trip_count == 3
    end

    test "reports no span and a frequency notice for a block of one frequency trip" do
      frequency = trip("f", at(8, 30), at(9, 30), frequency?: true, headway_secs: 1200)

      summary =
        Summary.block_summary(
          "7",
          [frequency],
          Checks.block_findings("7", [frequency], Context.layover_only(5))
        )

      assert summary == %{
               block_id: "7",
               trip_count: 1,
               start_secs: nil,
               end_secs: nil,
               hours: nil,
               status: :notice,
               status_code: :frequency_trip,
               route_ids: ["R1"],
               garage_name: nil,
               type_name: nil,
               conflict?: false
             }
    end

    test "reports no span and a time-missing notice for a block of one unplottable trip" do
      unplottable = trip("u", nil, nil)

      summary =
        Summary.block_summary(
          "7",
          [unplottable],
          Checks.block_findings("7", [unplottable], Context.layover_only(5))
        )

      assert summary == %{
               block_id: "7",
               trip_count: 1,
               start_secs: nil,
               end_secs: nil,
               hours: nil,
               status: :notice,
               status_code: :unplottable,
               route_ids: ["R1"],
               garage_name: nil,
               type_name: nil,
               conflict?: false
             }
    end

    test "reports ok and no code when the block has no finding" do
      trips = [
        trip("a", at(6, 0), at(8, 0), last_stop: stop("S1")),
        trip("b", at(8, 10), at(10, 0), first_stop: stop("S1"))
      ]

      assert Checks.block_findings("7", trips, Context.layover_only(5)) == []

      summary = Summary.block_summary("7", trips, [])

      assert summary.status == :ok
      assert summary.status_code == nil
    end

    test "reports the first code of the worst severity in the fixed order" do
      assert status([finding(:frequency_trip, :notice), finding(:repositions, :notice)]) ==
               {:notice, :repositions}

      assert status([finding(:in_seat_stale, :warning), finding(:short_layover, :warning)]) ==
               {:warning, :short_layover}

      assert status([finding(:unplottable, :notice), finding(:in_seat_unconfirmed, :notice)]) ==
               {:notice, :unplottable}

      assert status([finding(:in_seat_unconfirmed, :notice), finding(:overlap, :error)]) ==
               {:error, :overlap}
    end

    test "ignores findings naming another block" do
      summary =
        Summary.block_summary("7", [trip("a", at(6, 0), at(8, 0))], [
          finding(:overlap, :error, "9")
        ])

      assert {summary.status, summary.status_code} == {:ok, nil}
    end

    # AC-16 and Copy: the errors are Overlap, Can't reach and Wrong type; the
    # warnings follow in Copy order (Short layover, In-seat row, Too long, No
    # operator change, Route switch, Garage differs); the notices come last.
    test "orders the two errors of R9 after Overlap and before any warning" do
      assert status([finding(:type_mismatch, :error), finding(:cannot_reach, :error)]) ==
               {:error, :cannot_reach}

      assert status([finding(:type_mismatch, :error), finding(:overlap, :error)]) ==
               {:error, :overlap}

      assert status([finding(:cannot_reach, :error), finding(:too_long, :warning)]) ==
               {:error, :cannot_reach}
    end

    test "orders the warnings in Copy order" do
      warnings = [
        finding(:block_attributes_conflict, :warning),
        finding(:interlining_not_allowed, :warning),
        finding(:no_relief_opportunity, :warning),
        finding(:too_long, :warning)
      ]

      assert status(warnings ++ [finding(:in_seat_stale, :warning)]) ==
               {:warning, :in_seat_stale}

      assert status(warnings ++ [finding(:short_layover, :warning)]) ==
               {:warning, :short_layover}

      assert status([
               finding(:block_attributes_conflict, :warning),
               finding(:too_long, :warning)
             ]) == {:warning, :too_long}

      assert status([
               finding(:interlining_not_allowed, :warning),
               finding(:no_relief_opportunity, :warning)
             ]) == {:warning, :no_relief_opportunity}

      assert status([
               finding(:block_attributes_conflict, :warning),
               finding(:interlining_not_allowed, :warning)
             ]) == {:warning, :interlining_not_allowed}

      assert status([
               finding(:block_attributes_conflict, :warning),
               finding(:repositions, :notice)
             ]) == {:warning, :block_attributes_conflict}
    end

    test "reports a block with only a Garage differs conflict as a warning" do
      summary =
        Summary.block_summary("7", [trip("a", at(6, 0), at(8, 0))], [
          finding(:block_attributes_conflict, :warning)
        ])

      assert {summary.status, summary.status_code} == {:warning, :block_attributes_conflict}
    end
  end

  describe "natural_key/1" do
    test "splits an ID into digit and text runs and appends the raw ID" do
      assert Summary.natural_key("2") == [{0, 2}, "2"]
      assert Summary.natural_key("10") == [{0, 10}, "10"]
      assert Summary.natural_key("101") == [{0, 101}, "101"]
      assert Summary.natural_key("A1") == [{1, "a"}, {0, 1}, "A1"]
      assert Summary.natural_key("101A") == [{0, 101}, {1, "a"}, "101A"]
      assert Summary.natural_key("13A-4") == [{0, 13}, {1, "a-"}, {0, 4}, "13A-4"]
      assert Summary.natural_key("") == [""]
    end

    test "orders 2 before 10 before 101 before A1" do
      assert Enum.sort_by(["101", "A1", "10", "2"], &Summary.natural_key/1) ==
               ["2", "10", "101", "A1"]
    end
  end

  describe "sort_blocks/3" do
    test "sorts block IDs naturally in both directions" do
      blocks = [summary("101"), summary("2"), summary("A1"), summary("10")]

      assert ids(Summary.sort_blocks(blocks, :block, :asc)) == ["2", "10", "101", "A1"]
      assert ids(Summary.sort_blocks(blocks, :block, :desc)) == ["A1", "101", "10", "2"]
    end

    test "puts the worst status first and breaks ties by natural block ID" do
      blocks = [
        summary("10", status: :ok),
        summary("2", status: :error),
        summary("101", status: :error),
        summary("A1", status: :warning)
      ]

      assert ids(Summary.sort_blocks(blocks, :status, :asc)) == ["2", "101", "A1", "10"]
      assert ids(Summary.sort_blocks(blocks, :status, :desc)) == ["10", "A1", "2", "101"]
    end

    test "sorts a nil platform start last in both directions" do
      blocks = [
        summary("a", start_secs: 28_800),
        summary("b", start_secs: nil),
        summary("c", start_secs: 21_600)
      ]

      assert ids(Summary.sort_blocks(blocks, :out, :asc)) == ["c", "a", "b"]
      assert ids(Summary.sort_blocks(blocks, :out, :desc)) == ["a", "c", "b"]
    end

    test "sorts by the garage name and then the type name, with no-garage blocks last" do
      blocks = [
        summary("2", garage_name: "North", type_name: "Cutaway"),
        summary("10", garage_name: "Main", type_name: "Cutaway"),
        summary("1", garage_name: "Main", type_name: "Any type"),
        summary("101", garage_name: "Main", type_name: "35-ft diesel"),
        summary("A1")
      ]

      assert ids(Summary.sort_blocks(blocks, :garage, :asc)) ==
               ["1", "101", "10", "2", "A1"]

      assert ids(Summary.sort_blocks(blocks, :garage, :desc)) ==
               ["2", "10", "101", "1", "A1"]
    end

    test "sorts hours descending with hours-less blocks last" do
      blocks = [
        summary("a", hours: 1.3),
        summary("b", hours: nil),
        summary("c", hours: 4.5)
      ]

      assert ids(Summary.sort_blocks(blocks, :hours, :desc)) == ["c", "a", "b"]
      assert ids(Summary.sort_blocks(blocks, :hours, :asc)) == ["a", "c", "b"]
    end
  end

  describe "peak/1" do
    test "counts the maximum overlap and the earliest instant it is reached" do
      assert Summary.peak(three_block_day()) == %{count: 2, at_secs: 28_860}
    end

    test "counts two blocks touching at one instant once" do
      [six_to_ten, _five_minute, ten_to_twelve] = three_block_day()

      assert Summary.peak([six_to_ten, ten_to_twelve]) == %{count: 1, at_secs: 21_600}
    end

    test "counts a block with a gap between its trips as active across the gap" do
      gapped =
        block("3", [
          trip("a", at(6, 0), at(8, 0)),
          trip("b", at(10, 0), at(12, 0))
        ])

      mid = block("4", [trip("c", at(8, 30), at(9, 30))])

      assert {gapped.start_secs, gapped.end_secs} == {21_600, 43_200}

      assert Summary.peak([gapped, mid]) == %{count: 2, at_secs: 30_600}
    end

    test "counts a block with an overlap once" do
      overlapped =
        block("5", [
          trip("a", at(8, 0), at(9, 0)),
          trip("b", at(8, 30), at(9, 30))
        ])

      assert {overlapped.start_secs, overlapped.end_secs} == {28_800, 34_200}
      assert Summary.peak([overlapped]) == %{count: 1, at_secs: 28_800}
    end

    test "leaves a block without a span out of the peak" do
      frequency =
        block("6", [trip("f", at(8, 30), at(9, 30), frequency?: true, headway_secs: 1200)])

      [six_to_ten | _] = three_block_day()

      assert frequency.start_secs == nil
      assert Summary.peak([frequency]) == %{count: 0, at_secs: nil}
      assert Summary.peak([six_to_ten, frequency]) == %{count: 1, at_secs: 21_600}
    end

    test "returns zero for no blocks" do
      assert Summary.peak([]) == %{count: 0, at_secs: nil}
    end
  end

  describe "bins/2" do
    test "reports the maximum inside each 15-minute bin" do
      frequency =
        block("6", [trip("f", at(8, 30), at(9, 30), frequency?: true, headway_secs: 1200)])

      assert Summary.bins(three_block_day() ++ [frequency], 900) == [
               %{start_secs: 21_600, count: 1},
               %{start_secs: 22_500, count: 1},
               %{start_secs: 23_400, count: 1},
               %{start_secs: 24_300, count: 1},
               %{start_secs: 25_200, count: 1},
               %{start_secs: 26_100, count: 1},
               %{start_secs: 27_000, count: 1},
               %{start_secs: 27_900, count: 1},
               %{start_secs: 28_800, count: 2},
               %{start_secs: 29_700, count: 1},
               %{start_secs: 30_600, count: 1},
               %{start_secs: 31_500, count: 1},
               %{start_secs: 32_400, count: 1},
               %{start_secs: 33_300, count: 1},
               %{start_secs: 34_200, count: 1},
               %{start_secs: 35_100, count: 1},
               %{start_secs: 36_000, count: 1},
               %{start_secs: 36_900, count: 1},
               %{start_secs: 37_800, count: 1},
               %{start_secs: 38_700, count: 1},
               %{start_secs: 39_600, count: 1},
               %{start_secs: 40_500, count: 1},
               %{start_secs: 41_400, count: 1},
               %{start_secs: 42_300, count: 1}
             ]
    end

    test "covers the floor hour of the earliest start to the ceiling hour of the latest end" do
      five_minute = block("11", [trip("a", at(8, 1), at(8, 6))])

      # The block covers no bin start and runs entirely inside the 08:00 bin, so
      # its count comes from the start and end strictly inside that bin.
      assert Summary.bins([five_minute], 900) == [
               %{start_secs: 28_800, count: 1},
               %{start_secs: 29_700, count: 0},
               %{start_secs: 30_600, count: 0},
               %{start_secs: 31_500, count: 0}
             ]
    end

    test "returns no bins for blocks without a span" do
      frequency =
        block("6", [trip("f", at(8, 30), at(9, 30), frequency?: true, headway_secs: 1200)])

      assert Summary.bins([frequency], 900) == []
      assert Summary.bins([], 900) == []
    end
  end

  # Three blocks of one morning: 06:00-10:00, 08:01-08:06 and 10:00-12:00. The
  # first and third touch at 10:00.
  defp three_block_day do
    [
      block("10", [trip("10-a", at(6, 0), at(10, 0))]),
      block("11", [trip("11-a", at(8, 1), at(8, 6))]),
      block("12", [trip("12-a", at(10, 0), at(12, 0))])
    ]
  end

  defp block(block_id, trips), do: Summary.block_summary(block_id, trips, [])

  defp status(findings) do
    summary = Summary.block_summary("7", [trip("a", at(6, 0), at(8, 0))], findings)
    {summary.status, summary.status_code}
  end

  defp ids(blocks), do: Enum.map(blocks, & &1.block_id)

  defp summary(block_id, opts \\ []) do
    %{
      block_id: block_id,
      trip_count: Keyword.get(opts, :trip_count, 1),
      start_secs: Keyword.get(opts, :start_secs),
      end_secs: Keyword.get(opts, :end_secs),
      hours: Keyword.get(opts, :hours),
      status: Keyword.get(opts, :status, :ok),
      status_code: Keyword.get(opts, :status_code),
      route_ids: Keyword.get(opts, :route_ids, ["R1"]),
      garage_name: Keyword.get(opts, :garage_name),
      type_name: Keyword.get(opts, :type_name),
      conflict?: Keyword.get(opts, :conflict?, false)
    }
  end

  defp finding(code, severity, block_id \\ "7") do
    %{
      code: code,
      severity: severity,
      block_id: block_id,
      trip_ids: ["a"],
      transfer_id: nil,
      detail: %{}
    }
  end

  # Integer seconds, never parsed from a string (CR-3).
  defp at(hours, minutes), do: hours * 3600 + minutes * 60

  defp trip(id, from_secs, to_secs, opts \\ []) do
    %{
      id: id,
      trip_id: Keyword.get(opts, :trip_id, id),
      route_id: Keyword.get(opts, :route_id, "R1"),
      service_id: "W",
      block_id: Keyword.get(opts, :block_id, "7"),
      trip_headsign: nil,
      route_pattern_id: nil,
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: Keyword.get(opts, :frequency?, false),
      headway_secs: Keyword.get(opts, :headway_secs),
      first_arrival: Keyword.get(opts, :first_arrival, from_secs),
      first_departure: Keyword.get(opts, :first_departure, from_secs),
      last_arrival: Keyword.get(opts, :last_arrival, to_secs),
      last_departure: Keyword.get(opts, :last_departure, to_secs),
      first_stop: Keyword.get(opts, :first_stop),
      last_stop: Keyword.get(opts, :last_stop),
      plottable?: Keyword.get(opts, :plottable?, is_integer(from_secs) and is_integer(to_secs))
    }
  end

  defp stop(stop_id, opts \\ []) do
    %{
      stop_id: stop_id,
      name: Keyword.get(opts, :name, stop_id),
      parent_station: Keyword.get(opts, :parent_station),
      lat: Keyword.get(opts, :lat),
      lon: Keyword.get(opts, :lon)
    }
  end
end
