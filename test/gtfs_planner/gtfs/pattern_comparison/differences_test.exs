defmodule GtfsPlanner.Gtfs.PatternComparison.DifferencesTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.PatternComparison.Alignment

  describe "differences/2" do
    test "lists a replacement stretch with its anchors, own stops and segment" do
      # A: S1 S2 S3 S4 S5 S6, B: S1 S2 X Y S4 S5 S6. The stretch S3 -> X, Y sits between
      # the shared anchors S2 (row 1) and S4 (row 5), which the segment runs between.
      rows = [
        same(1, 1, "S1"),
        same(2, 2, "S2"),
        only_a(3, "S3"),
        only_b(3, "X"),
        only_b(4, "Y"),
        same(4, 5, "S4"),
        same(5, 6, "S5"),
        same(6, 7, "S6")
      ]

      segment = %{from: 1, to: 5, a_secs: 450, b_secs: 1170, diff: 720, same_stops?: false}

      a_rows =
        timing_rows([
          {300, 300},
          {400, 600},
          {700, 700},
          {1050, 1050},
          {1200, 1200},
          {1300, 1300}
        ])

      b_rows =
        timing_rows([
          {300, 300},
          {400, 600},
          {700, 700},
          {800, 800},
          {1770, 1770},
          {1900, 1900},
          {2000, 2000}
        ])

      result = Alignment.differences(rows, %{segments: [segment], a_rows: a_rows, b_rows: b_rows})

      assert [item] = result.items
      assert item.kind == :stops
      assert item.rows == [2, 3, 4]
      assert item.frame == [1, 2, 3, 4, 5]

      assert item.detail == %{
               before: "S2",
               after: "S4",
               a_only: ["S3"],
               b_only: ["X", "Y"],
               segment: segment
             }

      assert result.smaller_timing == 0
    end

    test "lists a short turn with no trailing anchor" do
      rows = [
        same(1, 1, "S1"),
        same(2, 2, "S2"),
        same(3, 3, "S3"),
        same(4, 4, "S4"),
        only_a(5, "S5"),
        only_a(6, "S6")
      ]

      a_rows =
        timing_rows([
          {0, 0},
          {600, 600},
          {1200, 1200},
          {1800, 1800},
          {2400, 2400},
          {3000, 3000}
        ])

      b_rows = timing_rows([{0, 0}, {600, 600}, {1200, 1200}, {1800, 1800}])

      result = Alignment.differences(rows, %{segments: [], a_rows: a_rows, b_rows: b_rows})

      assert [item] = result.items
      assert item.kind == :stops
      assert item.rows == [4, 5]
      assert item.frame == [3, 4, 5]

      assert item.detail == %{
               before: "S4",
               after: nil,
               a_only: ["S5", "S6"],
               b_only: [],
               segment: nil
             }

      assert result.smaller_timing == 0
    end

    test "collapses four moved pairs into one item covering both rows of every pair" do
      rows = [
        moved(only_a(1, "S1"), 1),
        moved(only_b(1, "S1"), 0),
        moved(only_a(2, "S2"), 3),
        moved(only_b(2, "S2"), 2),
        moved(only_a(3, "S3"), 5),
        moved(only_b(3, "S3"), 4),
        moved(only_a(4, "S4"), 7),
        moved(only_b(4, "S4"), 6)
      ]

      result = Alignment.differences(rows, %{segments: [], a_rows: nil, b_rows: nil})

      assert [item] = result.items
      assert item.kind == :moved
      assert item.rows == [0, 1, 2, 3, 4, 5, 6, 7]
      assert item.frame == [0, 1, 2, 3, 4, 5, 6, 7]
      assert item.detail == %{count: 4}
      assert result.smaller_timing == 0
    end

    test "lists a boarding change on a shared row" do
      rows = [same(1, 1, "S1"), same(2, 2, "S2")]

      a_rows = timing_rows([{0, 0}, {600, 600}])
      b_rows = boarding(timing_rows([{0, 0}, {600, 600}]), 1, 1, 0)

      result = Alignment.differences(rows, %{segments: [], a_rows: a_rows, b_rows: b_rows})

      assert [item] = result.items
      assert item.kind == :boarding
      assert item.rows == [0]
      assert item.frame == [0]

      assert item.detail == %{
               a: %{pickup_type: 0, drop_off_type: 0},
               b: %{pickup_type: 1, drop_off_type: 0}
             }

      assert result.smaller_timing == 0
    end

    test "lists only timing differences of a minute or more and counts the smaller ones" do
      rows = [same(1, 1, "S1"), same(2, 2, "S2"), same(3, 3, "S3")]

      # A: 300 s for both stretches; B: 330 s (30 s longer) then 360 s (60 s longer).
      smaller = %{from: 0, to: 1, a_secs: 300, b_secs: 330, diff: 30, same_stops?: true}
      listed = %{from: 1, to: 2, a_secs: 300, b_secs: 360, diff: 60, same_stops?: true}

      result =
        Alignment.differences(rows, %{
          segments: [smaller, listed],
          a_rows: timing_rows([{0, 0}, {600, 600}, {1200, 1200}]),
          b_rows: timing_rows([{0, 0}, {630, 630}, {1290, 1290}])
        })

      assert [item] = result.items
      assert item.kind == :time
      assert item.rows == [2]
      assert item.frame == [1, 2]
      assert item.detail == %{segment: listed}
      assert result.smaller_timing == 1
    end

    test "counts qualifying timing differences beyond the largest three" do
      rows = Enum.map(1..7, &same(&1, &1, "S#{&1}"))

      segments = [
        %{from: 0, to: 1, a_secs: 0, b_secs: 240, diff: 240, same_stops?: true},
        %{from: 1, to: 2, a_secs: 0, b_secs: 180, diff: 180, same_stops?: true},
        %{from: 2, to: 3, a_secs: 0, b_secs: 120, diff: 120, same_stops?: true},
        %{from: 3, to: 4, a_secs: 0, b_secs: 60, diff: 60, same_stops?: true},
        %{from: 4, to: 5, a_secs: 0, b_secs: 30, diff: 30, same_stops?: true},
        %{from: 5, to: 6, a_secs: 0, b_secs: 0, diff: 0, same_stops?: true}
      ]

      a_rows = timing_rows(List.duplicate({0, 0}, 7))
      b_rows = timing_rows(List.duplicate({0, 0}, 7))

      result = Alignment.differences(rows, %{segments: segments, a_rows: a_rows, b_rows: b_rows})

      assert Enum.map(result.items, & &1.kind) == [:time, :time, :time]
      assert Enum.map(result.items, & &1.detail.segment.diff) == [240, 180, 120]
      assert Enum.map(result.items, & &1.rows) == [[1], [2], [3]]
      assert result.smaller_timing == 2
    end

    test "orders items by their smallest row index" do
      # Generation order is stops, moved, boarding; row order puts the moved pair first.
      rows = [
        moved(only_b(1, "X"), 1),
        moved(only_a(1, "X"), 0),
        same(2, 2, "S1"),
        only_a(3, "S3"),
        only_b(3, "Y"),
        same(4, 4, "S4")
      ]

      a_rows = timing_rows([{0, 0}, {600, 600}, {1200, 1200}, {1800, 1800}])
      b_rows = boarding(timing_rows([{0, 0}, {600, 600}, {1200, 1200}, {1800, 1800}]), 4, 1, 0)
      segment = %{from: 2, to: 5, a_secs: 1200, b_secs: 1200, diff: 0, same_stops?: false}

      result = Alignment.differences(rows, %{segments: [segment], a_rows: a_rows, b_rows: b_rows})

      assert Enum.map(result.items, &{&1.kind, &1.rows, &1.frame}) == [
               {:moved, [0, 1], [0, 1]},
               {:stops, [3, 4], [2, 3, 4, 5]},
               {:boarding, [5], [5]}
             ]

      assert result.smaller_timing == 0
    end
  end

  defp same(a_pos, b_pos, stop_id) do
    %{type: :same, a_pos: a_pos, b_pos: b_pos, stop_id: stop_id, moved_to: nil}
  end

  defp only_a(a_pos, stop_id) do
    %{type: :a, a_pos: a_pos, b_pos: nil, stop_id: stop_id, moved_to: nil}
  end

  defp only_b(b_pos, stop_id) do
    %{type: :b, a_pos: nil, b_pos: b_pos, stop_id: stop_id, moved_to: nil}
  end

  defp moved(row, to), do: %{row | moved_to: to}

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
        pickup_type: 0,
        drop_off_type: 0
      }
    end)
  end

  defp boarding(rows, position, pickup_type, drop_off_type) do
    Enum.map(rows, fn
      %{position: ^position} = row ->
        %{row | pickup_type: pickup_type, drop_off_type: drop_off_type}

      row ->
        row
    end)
  end
end
