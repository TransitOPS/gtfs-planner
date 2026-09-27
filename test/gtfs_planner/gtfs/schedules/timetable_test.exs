defmodule GtfsPlanner.Gtfs.Schedules.TimetableTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Gtfs.Schedules.Timetable

  @pattern %{headsign: "Downtown"}
  @stops %{
    "A" => %{stop_name: "Alpha", stop_code: "1"},
    "B" => %{stop_name: "Beta", stop_code: "2"}
  }

  describe "build/5 row ordering" do
    test "sorts numerically with missing or unparseable starts last and labelled" do
      occurrences = [occurrence(1, "A")]

      trips = [
        trip_fields("12-0-WKD-1000", %{stop_times: stop_times(["A"], ["10:00:00"])}),
        trip_fields("12-0-WKD-0900", %{stop_times: stop_times(["A"], ["09:00:00"])}),
        trip_fields("12-0-WKD-2510", %{stop_times: stop_times(["A"], ["25:10:00"])}),
        trip_fields("12-0-WKD-0500", %{stop_times: stop_times(["A"], ["05:00:00"])}),
        trip_fields("12-0-WKD-NONE", %{stop_times: stop_times(["A"], [nil])}),
        trip_fields("12-0-WKD-BAD", %{stop_times: stop_times(["A"], ["not-a-time"])})
      ]

      section = Timetable.build(@pattern, occurrences, @stops, [], trips)

      assert Enum.map(section.rows, & &1.trip_id) == [
               "12-0-WKD-0500",
               "12-0-WKD-0900",
               "12-0-WKD-1000",
               "12-0-WKD-2510",
               "12-0-WKD-BAD",
               "12-0-WKD-NONE"
             ]

      assert Enum.map(section.rows, & &1.start_secs) ==
               [18_000, 32_400, 36_000, 90_600, nil, nil]

      missing_rows = Enum.filter(section.rows, &is_nil(&1.start_secs))
      assert Enum.map(missing_rows, & &1.start_cell.text) == ["No time", "No time"]
      refute Enum.any?(section.rows, &(&1.start_cell.text == "00:00"))
    end
  end

  describe "build/5 cell formatting" do
    test "shows the departure per column and the arrival at the last column" do
      occurrences = [occurrence(1, "A"), occurrence(2, "B")]

      trips = [
        trip_fields("T1", %{
          stop_times: [
            stop_time_pair(1, "A", "25:10:00", "25:10:00"),
            stop_time_pair(2, "B", "25:45:00", "25:45:00")
          ]
        })
      ]

      [row] = Timetable.build(@pattern, occurrences, @stops, [], trips).rows

      assert row.cells[1] == %{
               text: "25:10",
               marker: "+1",
               title: "1:10 AM, next day",
               missing?: false
             }

      assert row.cells[2] == %{
               text: "25:45",
               marker: "+1",
               title: "1:45 AM, next day",
               missing?: false
             }
    end

    test "computes the day marker from the seconds, not a fixed plus one" do
      occurrences = [occurrence(1, "A"), occurrence(2, "B")]

      trips = [
        trip_fields("T1", %{
          stop_times: [
            stop_time_pair(1, "A", "49:05:00", "49:05:00"),
            stop_time_pair(2, "B", "49:35:00", "49:35:00")
          ]
        })
      ]

      [row] = Timetable.build(@pattern, occurrences, @stops, [], trips).rows

      assert row.cells[1] == %{
               text: "49:05",
               marker: "+2",
               title: "1:05 AM, 2 days later",
               missing?: false
             }
    end

    test "appends seconds only when they are nonzero and omits the marker before midnight" do
      occurrences = [occurrence(1, "A")]

      trips = [
        trip_fields("T-seconds", %{stop_times: stop_times(["A"], ["06:05:30"])}),
        trip_fields("T-before-midnight", %{stop_times: stop_times(["A"], ["23:59:00"])})
      ]

      section = Timetable.build(@pattern, occurrences, @stops, [], trips)
      seconds_row = Enum.find(section.rows, &(&1.trip_id == "T-seconds"))
      midnight_row = Enum.find(section.rows, &(&1.trip_id == "T-before-midnight"))

      assert seconds_row.cells[1] ==
               %{text: "06:05:30", marker: nil, title: nil, missing?: false}

      assert midnight_row.cells[1] == %{text: "23:59", marker: nil, title: nil, missing?: false}
    end

    test "shows a missing value as a dash and never as midnight" do
      occurrences = [occurrence(1, "A"), occurrence(2, "B")]

      trips = [
        trip_fields("T-missing", %{
          stop_times: [
            stop_time_pair(1, "A", nil, nil),
            stop_time_pair(2, "B", "06:10:00", "06:10:00")
          ]
        })
      ]

      [row] = Timetable.build(@pattern, occurrences, @stops, [], trips).rows

      assert row.cells[1] == %{text: "—", marker: nil, title: nil, missing?: true}
      refute Enum.any?(Map.values(row.cells), &(&1.text == "00:00"))
    end
  end

  describe "build/5 columns" do
    test "keeps loop occurrences as separate columns in position order" do
      occurrences = [occurrence(1, "A"), occurrence(2, "B"), occurrence(3, "A")]

      timings = [
        timing("t1", "Standard", [
          timing_row(1, 0, 0, 1),
          timing_row(2, 300, 300, 0),
          timing_row(3, 600, 600, 1)
        ])
      ]

      trips = [linked_trip("T1", "t1", ["A", "B", "A"], ["06:00:00", "06:05:00", "06:10:00"])]

      section = Timetable.build(@pattern, occurrences, @stops, timings, trips)

      assert Enum.map(section.columns, &{&1.position, &1.stop_id}) == [{1, "A"}, {3, "A"}]
      assert Enum.map(section.all_columns, & &1.stop_id) == ["A", "B", "A"]
      assert section.omitted_stop_count == 1
    end

    test "falls back to the first eleven positions plus the last when nothing is flagged" do
      occurrences = for position <- 1..13, do: occurrence(position, "S#{position}")

      timings = [
        timing("t1", "Standard", for(position <- 1..13, do: timing_row(position, 0, 0, 0)))
      ]

      section = Timetable.build(@pattern, occurrences, %{}, timings, [])

      assert Enum.map(section.columns, & &1.position) ==
               [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13]

      assert Enum.map(section.all_columns, & &1.position) == Enum.to_list(1..13)
      assert section.omitted_stop_count == 1
    end

    test "shows every occurrence when the fallback fits" do
      occurrences = for position <- 1..12, do: occurrence(position, "S#{position}")

      section = Timetable.build(@pattern, occurrences, %{}, [], [])

      assert length(section.columns) == 12
      assert length(section.all_columns) == 12
      assert section.omitted_stop_count == 0
    end

    test "keeps the first and last occurrence when only a middle stop is flagged" do
      occurrences = for position <- 1..4, do: occurrence(position, "S#{position}")

      timings = [
        timing("t1", "Standard", [
          timing_row(1, 0, 0, 0),
          timing_row(2, 300, 300, 1),
          timing_row(3, 600, 600, 0),
          timing_row(4, 900, 900, 0)
        ])
      ]

      section = Timetable.build(@pattern, occurrences, %{}, timings, [])

      assert Enum.map(section.columns, & &1.position) == [1, 2, 4]
      assert section.omitted_stop_count == 1
    end
  end

  describe "build/5 modal timing" do
    test "picks the timing with the most linked trips" do
      occurrences = for position <- 1..4, do: occurrence(position, "S#{position}")

      timings = [
        timing("peak", "Peak", [
          timing_row(1, 0, 0, 0),
          timing_row(2, 60, 60, 1),
          timing_row(3, 120, 120, 0),
          timing_row(4, 180, 180, 0)
        ]),
        timing("standard", "Standard", [
          timing_row(1, 0, 0, 0),
          timing_row(2, 60, 60, 0),
          timing_row(3, 120, 120, 1),
          timing_row(4, 180, 180, 0)
        ])
      ]

      trips = [
        linked_trip("T1", "peak"),
        linked_trip("T2", "peak"),
        linked_trip("T3", "standard")
      ]

      section = Timetable.build(@pattern, occurrences, %{}, timings, trips)

      assert Enum.map(section.columns, & &1.position) == [1, 2, 4]
    end

    test "breaks a count tie by case-insensitive name and then id" do
      occurrences = for position <- 1..4, do: occurrence(position, "S#{position}")

      timings = [
        timing("zzzz", "Peak", [
          timing_row(1, 0, 0, 0),
          timing_row(2, 60, 60, 1),
          timing_row(3, 120, 120, 0),
          timing_row(4, 180, 180, 0)
        ]),
        timing("aaaa", "peak", [
          timing_row(1, 0, 0, 0),
          timing_row(2, 60, 60, 0),
          timing_row(3, 120, 120, 1),
          timing_row(4, 180, 180, 0)
        ])
      ]

      trips = [linked_trip("T1", "zzzz"), linked_trip("T2", "aaaa")]

      section = Timetable.build(@pattern, occurrences, %{}, timings, trips)

      assert Enum.map(section.columns, & &1.position) == [1, 3, 4]
    end

    test "falls back to the first timing by name when the section has no linked trips" do
      occurrences = for position <- 1..4, do: occurrence(position, "S#{position}")

      timings = [
        timing("standard", "Standard", [
          timing_row(1, 0, 0, 0),
          timing_row(2, 60, 60, 0),
          timing_row(3, 120, 120, 1),
          timing_row(4, 180, 180, 0)
        ]),
        timing("peak", "Peak", [
          timing_row(1, 0, 0, 0),
          timing_row(2, 60, 60, 1),
          timing_row(3, 120, 120, 0),
          timing_row(4, 180, 180, 0)
        ])
      ]

      section = Timetable.build(@pattern, occurrences, %{}, timings, [])

      assert Enum.map(section.columns, & &1.position) == [1, 2, 4]
    end
  end

  describe "build/5 custom and frequency rows" do
    test "maps a compatible custom trip positionally and marks it custom" do
      occurrences = [occurrence(1, "A"), occurrence(2, "B")]

      trips = [
        trip_fields("T-custom", %{stop_times: stop_times(["A", "B"], ["06:00:00", "06:12:00"])})
      ]

      section = Timetable.build(@pattern, occurrences, @stops, [], trips)
      [row] = section.rows

      assert row.custom?
      refute row.stops_differ?
      assert row.timing == :custom
      assert map_size(row.cells) == 2
      assert section.custom_trip_count == 1
    end

    test "flags an incompatible custom trip with stops_differ and no cells" do
      occurrences = [occurrence(1, "A"), occurrence(2, "B")]

      trips = [
        trip_fields("T-other", %{stop_times: stop_times(["A", "X"], ["06:00:00", "06:12:00"])})
      ]

      section = Timetable.build(@pattern, occurrences, @stops, [], trips)
      [row] = section.rows

      assert row.custom?
      assert row.stops_differ?
      assert row.cells == %{}
      assert section.custom_trip_count == 1
    end

    test "lists every frequency window in start order" do
      occurrences = [occurrence(1, "A"), occurrence(2, "B")]

      frequencies = [
        %{start_time: "12:00:00", end_time: "15:00:00", headway_secs: 1_800, exact_times: 0},
        %{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1_200, exact_times: 1}
      ]

      trips = [
        trip_fields("T-freq", %{
          frequencies: frequencies,
          stop_times: stop_times(["A", "B"], ["06:00:00", "06:12:00"])
        })
      ]

      [row] = Timetable.build(@pattern, occurrences, @stops, [], trips).rows

      assert row.frequency?
      assert row.frequency_label == "Every 20 min, 09:00–12:00; Every 30 min, 12:00–15:00"
    end
  end

  describe "build/5 entrypoints" do
    test "builds the timepoints and all-columns views from plain parsed data" do
      assert {:ok, 21_600} = GtfsTime.parse("06:00:00")

      occurrences = [occurrence(1, "A"), occurrence(2, "B")]

      timings = [timing("t1", "Standard", [timing_row(1, 0, 0, 1), timing_row(2, 720, 720, 1)])]

      trips = [
        trip_fields("12-0-WKD-0600", %{
          timed_pattern_id: "t1",
          pattern_derivation_state: "linked",
          stop_times: [
            stop_time_pair(1, "A", "06:00:00", "06:00:00"),
            stop_time_pair(2, "B", "06:12:00", "06:12:00")
          ]
        }),
        trip_fields("12-0-WKD-0730", %{
          timed_pattern_id: "t1",
          pattern_derivation_state: "linked",
          stop_times: [
            stop_time_pair(1, "A", "07:30:00", "07:30:00"),
            stop_time_pair(2, "B", "07:42:00", "07:42:00")
          ]
        })
      ]

      section = Timetable.build(@pattern, occurrences, @stops, timings, trips)

      assert Enum.map(section.columns, & &1.position) == [1, 2]
      assert Enum.map(section.all_columns, & &1.position) == [1, 2]

      assert Enum.map(section.rows, &{&1.trip_id, &1.start_secs}) == [
               {"12-0-WKD-0600", 21_600},
               {"12-0-WKD-0730", 27_000}
             ]

      assert [%{name: "Standard", trip_count: 2, segments: [720], total_secs: 720}] =
               section.timing_lines

      assert [%{kind: :irregular, trip_count: 2}] = section.bands
      assert Summary.peak_vehicles([%{start_secs: 21_600, end_secs: 22_320}]).count == 1
    end
  end

  defp occurrence(position, stop_id) do
    %{id: "occ-#{position}", position: position, stop_id: stop_id}
  end

  defp timing(id, name, rows), do: %{id: id, name: name, headsign: nil, rows: rows}

  defp timing_row(position, arrival_offset, departure_offset, timepoint) do
    %{
      position: position,
      arrival_offset: arrival_offset,
      departure_offset: departure_offset,
      timepoint: timepoint
    }
  end

  defp stop_time_pair(sequence, stop_id, arrival_time, departure_time) do
    %{
      id: "st-#{sequence}",
      stop_sequence: sequence,
      stop_id: stop_id,
      arrival_time: arrival_time,
      departure_time: departure_time
    }
  end

  defp stop_times(stop_ids, departures) do
    stop_ids
    |> Enum.with_index()
    |> Enum.map(fn {stop_id, index} ->
      departure_time = Enum.at(departures, index)
      stop_time_pair(index + 1, stop_id, departure_time, departure_time)
    end)
  end

  defp trip_fields(trip_id, attrs) do
    defaults = %{
      id: "uuid-" <> trip_id,
      trip_id: trip_id,
      timed_pattern_id: nil,
      pattern_derivation_state: "custom",
      trip_headsign: nil,
      trip_short_name: nil,
      block_id: nil,
      updated_at: nil,
      frequencies: [],
      stop_times: []
    }

    Map.merge(defaults, attrs)
  end

  defp linked_trip(trip_id, timed_pattern_id, stop_ids, times) do
    trip_fields(trip_id, %{
      timed_pattern_id: timed_pattern_id,
      pattern_derivation_state: "linked",
      stop_times: stop_times(stop_ids, times)
    })
  end

  defp linked_trip(trip_id, timed_pattern_id) do
    linked_trip(trip_id, timed_pattern_id, ["A", "B", "C", "D"], [
      "06:00:00",
      "06:05:00",
      "06:10:00",
      "06:15:00"
    ])
  end
end
