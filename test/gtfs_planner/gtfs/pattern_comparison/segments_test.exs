defmodule GtfsPlanner.Gtfs.PatternComparison.SegmentsTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.PatternComparison.Alignment

  describe "segments/3" do
    test "times a segment from the start departure to the end arrival" do
      # Otter Rock dep 1500 -> Depoe Bay arr 2070 dep 2130 (A); B's short turn is the same
      # stretch but arrives at 2010 and ends there, so its arrival is also its departure.
      rows = [same(1, 1, "otter-rock"), same(2, 2, "depoe-bay")]
      a_rows = timing_rows([{1500, 1500}, {2070, 2130}])
      b_rows = timing_rows([{1500, 1500}, {2010, 2010}])

      result = Alignment.segments(rows, a_rows, b_rows)

      assert result.untimed == MapSet.new()
      assert result.waits == %{}

      assert result.segments == [
               %{from: 0, to: 1, a_secs: 570, b_secs: 510, diff: -60, same_stops?: true}
             ]
    end

    test "spans extra stops between the anchors and reports them as not adjacent" do
      rows = [same(1, 1, "s1"), only_b(2, "x"), same(2, 3, "s2")]
      a_rows = timing_rows([{1000, 1000}, {1400, 1450}])
      b_rows = timing_rows([{1000, 1000}, {1250, 1300}, {1300, 1300}])

      result = Alignment.segments(rows, a_rows, b_rows)

      assert result.untimed == MapSet.new()
      assert result.waits == %{}

      assert result.segments == [
               %{from: 0, to: 2, a_secs: 400, b_secs: 300, diff: -100, same_stops?: false}
             ]
    end

    test "treats a shared stop without a scheduled time as untimed and spans it" do
      rows = [same(1, 1, "s1"), same(2, 2, "s2"), same(3, 3, "s3")]
      a_rows = timing_rows([{600, 600}, {900, 1200}, {1500, 1500}])
      b_rows = timing_rows([{600, 600}, {nil, nil}, {1400, 1400}])

      result = Alignment.segments(rows, a_rows, b_rows)

      assert result.untimed == MapSet.new([1])
      assert result.waits == %{}

      assert result.segments == [
               %{from: 0, to: 2, a_secs: 900, b_secs: 800, diff: -100, same_stops?: false}
             ]
    end

    test "records only differing waits at interior anchors" do
      rows = [same(1, 1, "s1"), same(2, 2, "s2"), same(3, 3, "s3"), same(4, 4, "s4")]
      # A waits 10, 60, 30, 30; B waits 0, 30, 30, 0.
      a_rows = timing_rows([{0, 10}, {100, 160}, {300, 330}, {400, 430}])
      b_rows = timing_rows([{0, 0}, {100, 130}, {300, 330}, {400, 400}])

      result = Alignment.segments(rows, a_rows, b_rows)

      assert result.untimed == MapSet.new()
      assert result.waits == %{1 => {60, 30}}

      assert result.segments == [
               %{from: 0, to: 1, a_secs: 90, b_secs: 100, diff: 10, same_stops?: true},
               %{from: 1, to: 2, a_secs: 140, b_secs: 170, diff: 30, same_stops?: true},
               %{from: 2, to: 3, a_secs: 70, b_secs: 70, diff: 0, same_stops?: true}
             ]
    end

    test "returns empty results when either side has no timing rows" do
      rows = [same(1, 1, "s1"), same(2, 2, "s2")]
      a_rows = timing_rows([{0, 0}, {60, 60}])

      assert Alignment.segments(rows, nil, a_rows) ==
               %{segments: [], untimed: MapSet.new(), waits: %{}}

      assert Alignment.segments(rows, a_rows, nil) ==
               %{segments: [], untimed: MapSet.new(), waits: %{}}
    end
  end

  defp same(a_pos, b_pos, stop_id) do
    %{type: :same, a_pos: a_pos, b_pos: b_pos, stop_id: stop_id, moved_to: nil}
  end

  defp only_b(b_pos, stop_id) do
    %{type: :b, a_pos: nil, b_pos: b_pos, stop_id: stop_id, moved_to: nil}
  end

  # Positions run 1..n, so a visit at a_pos/b_pos reads the list entry at that position - 1.
  defp timing_rows(offsets) do
    offsets
    |> Enum.with_index(1)
    |> Enum.map(fn {{arrival, departure}, position} ->
      %{
        position: position,
        arrival_offset: arrival,
        departure_offset: departure,
        timepoint: nil,
        pickup_type: nil,
        drop_off_type: nil
      }
    end)
  end
end
