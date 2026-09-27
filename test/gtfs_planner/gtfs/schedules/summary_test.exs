defmodule GtfsPlanner.Gtfs.Schedules.SummaryTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.Summary

  describe "peak_vehicles/1" do
    test "counts the maximum overlap and reports the earliest instant it is reached" do
      spans = [%{start_secs: 21_600, end_secs: 90_600}, %{start_secs: 23_400, end_secs: 27_600}]

      assert Summary.peak_vehicles(spans) == %{count: 2, at_secs: 23_400}
    end

    test "counts back-to-back half-open spans as one vehicle" do
      spans = [%{start_secs: 0, end_secs: 3_600}, %{start_secs: 3_600, end_secs: 7_200}]

      assert Summary.peak_vehicles(spans) == %{count: 1, at_secs: 0}
    end

    test "returns zero for an empty list" do
      assert Summary.peak_vehicles([]) == %{count: 0, at_secs: nil}
    end

    test "expands a frequency template to start plus each headway until the window end" do
      template = %{start_secs: 32_400, end_secs: 36_000, headway_secs: 900, until_secs: 36_000}

      # Departures 32_400, 33_300, 34_200, 35_100 each lasting 3_600 seconds.
      assert Summary.peak_vehicles([template]) == %{count: 4, at_secs: 35_100}
    end

    test "expands a frequency template the same way with either exact_times value" do
      template = %{start_secs: 21_600, end_secs: 24_000, headway_secs: 1_200, until_secs: 25_200}

      assert Summary.peak_vehicles([Map.put(template, :exact_times, 0)]) ==
               Summary.peak_vehicles([Map.put(template, :exact_times, 1)])
    end

    test "keeps after-midnight spans on the unwrapped second scale" do
      {:ok, start_secs} = GtfsTime.parse("25:00:00")
      {:ok, end_secs} = GtfsTime.parse("25:30:00")

      assert Summary.peak_vehicles([%{start_secs: start_secs, end_secs: end_secs}]) ==
               %{count: 1, at_secs: 90_000}
    end

    test "equals a greedy interval-chaining count over generated span sets" do
      for spans <- generated_span_sets() do
        assert Summary.peak_vehicles(spans).count == greedy_vehicle_count(spans)
      end
    end
  end

  describe "headway_bands/2" do
    test "reproduces the worked example exactly" do
      departures = [
        21_600,
        22_500,
        23_400,
        24_240,
        25_200,
        27_000,
        28_800,
        30_600,
        31_020,
        34_200
      ]

      assert Summary.headway_bands(departures, []) == [
               %{
                 kind: :scheduled,
                 first_secs: 21_600,
                 last_secs: 25_200,
                 trip_count: 5,
                 min_headway_minutes: 14,
                 max_headway_minutes: 16
               },
               %{
                 kind: :scheduled,
                 first_secs: 27_000,
                 last_secs: 30_600,
                 trip_count: 3,
                 min_headway_minutes: 30,
                 max_headway_minutes: 30
               },
               %{
                 kind: :irregular,
                 first_secs: 31_020,
                 last_secs: 34_200,
                 trip_count: 2,
                 min_headway_minutes: nil,
                 max_headway_minutes: nil
               }
             ]
    end

    test "is independent of the input order" do
      departures = [
        21_600,
        22_500,
        23_400,
        24_240,
        25_200,
        27_000,
        28_800,
        30_600,
        31_020,
        34_200
      ]

      assert Summary.headway_bands(departures, []) ==
               Summary.headway_bands(Enum.reverse(departures), [])
    end

    test "merges consecutive irregular departures into one band" do
      departures = [21_600, 21_700, 22_900, 23_000, 24_200]

      assert Summary.headway_bands(departures, []) == [
               %{
                 kind: :irregular,
                 first_secs: 21_600,
                 last_secs: 24_200,
                 trip_count: 5,
                 min_headway_minutes: nil,
                 max_headway_minutes: nil
               }
             ]
    end

    test "keeps a run of fewer than three departures irregular" do
      assert Summary.headway_bands([21_600, 21_660], []) == [
               %{
                 kind: :irregular,
                 first_secs: 21_600,
                 last_secs: 21_660,
                 trip_count: 2,
                 min_headway_minutes: nil,
                 max_headway_minutes: nil
               }
             ]
    end

    test "lists a frequency window as its own band in time order" do
      departures = [
        21_600,
        22_500,
        23_400,
        24_240,
        25_200,
        27_000,
        28_800,
        30_600,
        31_020,
        34_200
      ]

      frequencies = [%{start_secs: 25_200, until_secs: 36_000, headway_secs: 900}]

      assert Enum.map(Summary.headway_bands(departures, frequencies), & &1.kind) ==
               [:scheduled, :frequency, :scheduled, :irregular]

      assert Enum.find(Summary.headway_bands(departures, frequencies), &(&1.kind == :frequency)) ==
               %{
                 kind: :frequency,
                 first_secs: 25_200,
                 last_secs: 36_000,
                 trip_count: 12,
                 min_headway_minutes: 15,
                 max_headway_minutes: 15
               }
    end

    test "partitions the scheduled departures across its scheduled and irregular bands" do
      departures = [
        21_600,
        22_500,
        23_400,
        24_240,
        25_200,
        27_000,
        28_800,
        30_600,
        31_020,
        34_200
      ]

      trip_count =
        departures
        |> Summary.headway_bands([])
        |> Enum.reject(&(&1.kind == :frequency))
        |> Enum.map(& &1.trip_count)
        |> Enum.sum()

      assert trip_count == length(departures)
    end
  end

  describe "trips_per_hour/2" do
    test "returns no rows for no departures" do
      assert Summary.trips_per_hour([], []) == []
    end

    test "emits every hour from the first to the last with zeros included" do
      departures = [21_600, 25_200]
      frequencies = [%{start_secs: 90_000, until_secs: 91_800, headway_secs: 900}]

      rows = Summary.trips_per_hour(departures, frequencies)

      assert length(rows) == 20
      assert Enum.at(rows, 0) == {6, 1, false}
      assert Enum.at(rows, 2) == {8, 0, false}
      assert List.last(rows) == {25, 2, true}
    end

    test "marks an hour approximate when any departure in it is frequency-based" do
      departures = [90_000]
      frequencies = [%{start_secs: 90_000, until_secs: 90_900, headway_secs: 300}]

      assert Summary.trips_per_hour(departures, frequencies) == [{25, 4, true}]
    end
  end

  describe "timing_segments/2" do
    @timing_rows [
      %{position: 1, arrival_offset: 0, departure_offset: 0},
      %{position: 2, arrival_offset: 300, departure_offset: 360},
      %{position: 3, arrival_offset: 720, departure_offset: 720}
    ]

    test "excludes dwell at the earlier column while the total keeps it" do
      columns = [%{position: 1}, %{position: 2}, %{position: 3}]

      assert Summary.timing_segments(@timing_rows, columns) ==
               %{segments: [300, 360], total_secs: 720}
    end

    test "follows the displayed columns" do
      columns = [%{position: 1}, %{position: 3}]

      assert Summary.timing_segments(@timing_rows, columns) == %{segments: [720], total_secs: 720}
    end

    test "returns an empty segment list for no columns" do
      assert Summary.timing_segments(@timing_rows, []) == %{segments: [], total_secs: 0}
    end
  end

  # Generated outside the assertions so the fixed-seed sets are visible as inputs,
  # not as expected values.
  defp generated_span_sets do
    :rand.seed(:exsss, {7, 11, 13})

    for _set <- 1..25 do
      for _span <- 1..:rand.uniform(8) do
        start_secs = :rand.uniform(60)
        duration = :rand.uniform(20)
        %{start_secs: start_secs, end_secs: start_secs + duration}
      end
    end
  end

  # Greedy interval chaining: sort by start, reuse the earliest free vehicle whose
  # previous span ended at or before the next departure, otherwise add one.
  defp greedy_vehicle_count(spans) do
    spans
    |> Enum.map(fn %{start_secs: start_secs, end_secs: end_secs} -> {start_secs, end_secs} end)
    |> Enum.sort()
    |> Enum.reduce([], fn {start_secs, end_secs}, vehicles ->
      vehicles = Enum.sort(vehicles)

      case Enum.find(vehicles, &(&1 <= start_secs)) do
        nil -> vehicles ++ [end_secs]
        available -> List.delete(vehicles, available) ++ [end_secs]
      end
    end)
    |> length()
  end
end
