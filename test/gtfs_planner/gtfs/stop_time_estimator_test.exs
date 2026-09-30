defmodule GtfsPlanner.Gtfs.StopTimeEstimatorTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StopTimeEstimator

  defp row(arrival, departure, timepoint \\ nil, distance \\ nil, coord \\ nil) do
    %{
      arrival: arrival,
      departure: departure,
      timepoint: timepoint,
      distance: distance,
      coord: coord
    }
  end

  defp arrivals(result), do: Enum.map(result.rows, & &1.arrival)

  describe "AC-4 worked example" do
    test ":distance spreads 480 s by cumulative share: 32, 64, 384" do
      rows = [
        row(0, 0, 1, 0),
        row(nil, nil, nil, 200),
        row(nil, nil, nil, 400),
        row(nil, nil, nil, 2_400),
        row(480, 480, 1, 3_000)
      ]

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert arrivals(%{rows: out}) == [0, 32, 64, 384, 480]
      assert Enum.map(out, & &1.departure) == [0, 32, 64, 384, 480]
      assert Enum.map(out, & &1.estimated?) == [false, true, true, true, false]
      assert Enum.at(out, 1).previous == {nil, nil}

      assert span.from == 0
      assert span.to == 4
      assert span.seconds == 480
      assert span.source == :distance
      assert span.metres == 3_000.0
      assert span.error == nil
      # Stored units are unit-agnostic under :strict, so no pace is reported.
      assert span.mph == nil
    end

    test ":even spreads 480 s in equal shares: 120, 240, 360" do
      rows = [
        row(0, 0, 1, 0),
        row(nil, nil, nil, 200),
        row(nil, nil, nil, 400),
        row(nil, nil, nil, 2_400),
        row(480, 480, 1, 3_000)
      ]

      assert %{rows: out, spans: [span], problems: []} =
               StopTimeEstimator.estimate(rows, method: :even)

      assert arrivals(%{rows: out}) == [0, 120, 240, 360, 480]
      assert span.source == :even
      assert span.metres == nil
      assert span.mph == nil
    end

    test ":non_decreasing reports metres and pace for stored distances" do
      rows = [
        row(0, 0, 1, 0),
        row(nil, nil, nil, 200),
        row(nil, nil, nil, 400),
        row(nil, nil, nil, 2_400),
        row(480, 480, 1, 3_000)
      ]

      assert %{spans: [span]} = StopTimeEstimator.estimate(rows, distances: :non_decreasing)

      assert span.source == :distance
      assert span.metres == 3_000.0
      # 3000 m / 480 s = 6.25 m/s.
      assert_in_delta span.mph, 13.980875, 1.0e-9
    end

    test "Decimal stored distances are converted before use" do
      rows = [
        row(0, 0, 1, Decimal.new("0")),
        row(nil, nil, nil, Decimal.new("1000")),
        row(600, 600, 1, Decimal.new("2000"))
      ]

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert arrivals(%{rows: out}) == [0, 300, 600]
      assert span.source == :distance
    end
  end

  describe "R1 anchors with scope :missing" do
    test "blank runs between timed rows are filled; anchors are kept exactly" do
      rows = [row(0, 0), row(nil, nil), row(nil, nil), row(600, 600)]

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert arrivals(%{rows: out}) == [0, 200, 400, 600]
      assert Enum.map(out, & &1.estimated?) == [false, true, true, false]
      assert span.from == 0
      assert span.to == 3
      assert span.source == :even
    end

    test "a row with only an arrival copies it to departure and is kept" do
      rows = [row(0, 0), row(300, nil), row(nil, nil), row(600, 600)]

      assert %{rows: out, problems: []} = StopTimeEstimator.estimate(rows)

      copied = Enum.at(out, 1)
      assert copied.arrival == 300
      assert copied.departure == 300
      assert copied.estimated? == false
      assert copied.previous == {300, nil}
      assert arrivals(%{rows: out}) == [0, 300, 450, 600]
    end

    test "a row with only a departure copies it to arrival and is kept" do
      rows = [row(0, 0), row(nil, nil), row(nil, 450), row(600, 600)]

      assert %{rows: out, problems: []} = StopTimeEstimator.estimate(rows)

      copied = Enum.at(out, 2)
      assert {copied.arrival, copied.departure} == {450, 450}
      assert copied.estimated? == false
      assert copied.previous == {nil, 450}
    end
  end

  describe "R2 anchors with scope :between" do
    @between_rows [
      %{arrival: 0, departure: 0, timepoint: 1, distance: nil, coord: nil},
      %{arrival: 960, departure: 960, timepoint: 0, distance: nil, coord: nil},
      %{arrival: 600, departure: 600, timepoint: 1, distance: nil, coord: nil},
      %{arrival: 1000, departure: 1000, timepoint: 0, distance: nil, coord: nil},
      %{arrival: 1200, departure: 1200, timepoint: 1, distance: nil, coord: nil},
      %{arrival: 1500, departure: 1500, timepoint: 0, distance: nil, coord: nil},
      %{arrival: 1800, departure: 1800, timepoint: 1, distance: nil, coord: nil}
    ]

    test "typed non-timepoint rows are recalculated; timepoints and ends never change" do
      assert %{rows: out, problems: []} =
               StopTimeEstimator.estimate(@between_rows, scope: :between)

      assert arrivals(%{rows: out}) == [0, 300, 600, 900, 1200, 1500, 1800]

      recalculated = Enum.at(out, 1)
      assert recalculated.estimated? == true
      assert recalculated.previous == {960, 960}

      for index <- [0, 2, 4, 6] do
        anchored = Enum.at(out, index)
        assert anchored.estimated? == false
        assert {anchored.arrival, anchored.departure} == anchored.previous
      end
    end

    test "only_anchor recalculates touching spans and leaves the rest unchanged" do
      assert %{rows: out, problems: []} =
               StopTimeEstimator.estimate(@between_rows, scope: :between, only_anchor: 2)

      assert arrivals(%{rows: out}) == [0, 300, 600, 900, 1200, 1500, 1800]

      untouched = Enum.at(out, 5)
      assert {untouched.arrival, untouched.departure} == {1500, 1500}
      assert untouched.estimated? == false
      assert Enum.at(out, 1).estimated? == true
      assert Enum.at(out, 3).estimated? == true
    end
  end

  describe "R3 span and dwell" do
    test "an anchor wait is kept and the next span starts at departure" do
      rows = [row(600, 660, 1), row(nil, nil), row(1260, 1260, 1)]

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert arrivals(%{rows: out}) == [600, 960, 1260]

      anchor = hd(out)
      assert {anchor.arrival, anchor.departure} == {600, 660}
      assert anchor.estimated? == false
      assert span.seconds == 600
    end

    test "filled rows have arrival equal to departure" do
      rows = [row(0, 0), row(nil, nil), row(600, 600)]

      assert %{rows: out} = StopTimeEstimator.estimate(rows)

      filled = Enum.at(out, 1)
      assert filled.arrival == filled.departure
    end
  end

  describe "monotonicity" do
    test "outputs never decrease and never exceed the next anchor arrival" do
      rows = [
        row(0, 0, 1, 0),
        row(nil, nil, nil, 200),
        row(nil, nil, nil, 400),
        row(nil, nil, nil, 600),
        row(800, 800, 1, 800),
        row(nil, nil, nil, 1000),
        row(nil, nil, nil, 1200),
        row(nil, nil, nil, 1400),
        row(1600, 1680, 1, 1600),
        row(nil, nil, nil, 2000),
        row(nil, nil, nil, 2400),
        row(nil, nil, nil, 2800),
        row(3200, 3200, 1, 3200)
      ]

      assert %{rows: out, problems: []} = StopTimeEstimator.estimate(rows)

      times = Enum.map(out, & &1.arrival)
      assert times == Enum.sort(times)
      assert Enum.at(times, 3) <= 800
      assert Enum.at(times, 7) <= 1600
      assert Enum.at(times, 11) <= 3200

      assert times ==
               [0, 200, 400, 600, 800, 1000, 1200, 1400, 1600, 2060, 2440, 2820, 3200]
    end
  end

  describe "R5 distance source" do
    @coords [{0.0, 0.0}, {0.0, 0.005}, {0.0, 0.02}, {0.0, 0.03}]

    defp coord_rows(distances) do
      @coords
      |> Enum.with_index()
      |> Enum.map(fn {coord, index} ->
        case index do
          0 -> row(0, 0, 1, Enum.at(distances, 0), coord)
          3 -> row(600, 600, 1, Enum.at(distances, 3), coord)
          _ -> row(nil, nil, nil, Enum.at(distances, index), coord)
        end
      end)
    end

    test "one nil stored distance uses the straight line for the whole span" do
      rows = coord_rows([0, nil, 1500, 3000])

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert span.source == :straight_line
      assert arrivals(%{rows: out}) == [0, 100, 400, 600]
      assert_in_delta span.metres, 3_335.8524070059875, 1.0e-9
      assert_in_delta span.mph, 12.436836138879958, 1.0e-9
    end

    test ":strict equal stored distances fall back to the straight line" do
      rows = coord_rows([0, 1000, 1000, 3000])

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert span.source == :straight_line
      assert arrivals(%{rows: out}) == [0, 100, 400, 600]
    end

    test ":non_decreasing accepts a zero-metre hop with a positive total" do
      rows = coord_rows([0, 0, 100, 300]) |> Enum.map(&Map.put(&1, :coord, nil))

      assert %{rows: out, spans: [span], problems: []} =
               StopTimeEstimator.estimate(rows, distances: :non_decreasing)

      assert span.source == :distance
      assert span.metres == 300.0
      assert arrivals(%{rows: out}) == [0, 0, 200, 600]
      assert_in_delta span.mph, 1.11847, 1.0e-9
    end

    test "the same hop under :strict falls back to equal shares" do
      rows =
        [0, 0, 100, 300]
        |> Enum.with_index()
        |> Enum.map(fn
          {d, 0} -> row(0, 0, 1, d)
          {d, 3} -> row(600, 600, 1, d)
          {d, _} -> row(nil, nil, nil, d)
        end)

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert span.source == :even
      assert arrivals(%{rows: out}) == [0, 200, 400, 600]
    end

    test "identical coordinates with zero total fall back to equal shares" do
      rows =
        Enum.map(0..3, fn
          0 -> row(0, 0, 1, nil, {0.0, 0.0})
          3 -> row(600, 600, 1, nil, {0.0, 0.0})
          _ -> row(nil, nil, nil, nil, {0.0, 0.0})
        end)

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      assert span.source == :even
      assert span.metres == nil
      assert span.mph == nil
      assert arrivals(%{rows: out}) == [0, 200, 400, 600]
    end
  end

  describe "R6 never guess or extrapolate" do
    test "an untimed last row fills nothing" do
      rows = [row(0, 0), row(nil, nil), row(nil, nil), row(nil, nil)]

      assert %{rows: out, spans: [], problems: [{:no_last_time, 3}]} =
               StopTimeEstimator.estimate(rows)

      assert Enum.all?(out, &(&1.estimated? == false))
      assert arrivals(%{rows: out}) == [0, nil, nil, nil]
    end

    test "an untimed first row fills nothing" do
      rows = [row(nil, nil), row(nil, nil), row(600, 600)]

      assert %{rows: out, spans: [], problems: [{:no_first_time, 0}]} =
               StopTimeEstimator.estimate(rows)

      assert Enum.all?(out, &(&1.estimated? == false))
    end

    test "a span with an untimed timepoint is skipped" do
      rows = [row(0, 0, 1), row(nil, nil, 1), row(nil, nil, 0), row(600, 600, 1)]

      assert %{rows: out, spans: [span], problems: [{:timepoint_without_time, 1}]} =
               StopTimeEstimator.estimate(rows)

      assert span.error == :timepoint_without_time
      assert arrivals(%{rows: out}) == [0, nil, nil, 600]
    end

    test "an out-of-order anchor blocks both adjacent spans" do
      rows = [row(0, 500), row(nil, nil), row(200, 200), row(nil, nil), row(800, 800)]

      assert %{rows: out, spans: spans, problems: [{:order, 0, 2}]} =
               StopTimeEstimator.estimate(rows)

      assert Enum.map(spans, & &1.error) == [:order, :after_order]
      assert arrivals(%{rows: out}) == [0, nil, 200, nil, 800]
    end
  end

  describe "loops and overnight values" do
    test "loop A, B, A measures each visit's own section" do
      rows = [
        row(0, 0, 1, nil, {0.0, 0.0}),
        row(nil, nil, nil, nil, {0.0, 0.01}),
        row(nil, nil, nil, nil, {0.0, 0.0}),
        row(600, 600, 1, nil, {0.0, 0.0})
      ]

      assert %{rows: out, spans: [span], problems: []} = StopTimeEstimator.estimate(rows)

      # Per-hop sections halve the span; an endpoint-to-endpoint measure would
      # total zero and fall back to equal shares (200, 400).
      assert span.source == :straight_line
      assert arrivals(%{rows: out}) == [0, 300, 600, 600]
    end

    test "times past 24:00:00 fill without wrapping" do
      rows = [row(90_600, 90_600, 1), row(nil, nil), row(91_200, 91_200, 1)]

      assert %{rows: out, problems: []} = StopTimeEstimator.estimate(rows)

      assert arrivals(%{rows: out}) == [90_600, 90_900, 91_200]
    end
  end
end
