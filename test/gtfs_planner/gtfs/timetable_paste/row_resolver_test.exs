defmodule GtfsPlanner.Gtfs.TimetablePaste.RowResolverTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.TimetablePaste.RowResolver

  # Literal fixtures: a full route, a Hospital short turn, a Riverside
  # express (skips Hospital), a school deviation and a Central–Market–Central
  # loop. Occurrence ids are opaque strings; positions belong to each
  # pattern's own order and are never copied across patterns.
  @full %{
    id: "pattern-full",
    occurrences: [
      %{id: "occ-full-central", stop_id: "STOP_CENTRAL", position: 1},
      %{id: "occ-full-market", stop_id: "STOP_MARKET", position: 2},
      %{id: "occ-full-hospital", stop_id: "STOP_HOSPITAL", position: 3},
      %{id: "occ-full-riverside", stop_id: "STOP_RIVERSIDE", position: 4}
    ]
  }

  @short %{
    id: "pattern-short",
    occurrences: [
      %{id: "occ-short-central", stop_id: "STOP_CENTRAL", position: 1},
      %{id: "occ-short-market", stop_id: "STOP_MARKET", position: 2},
      %{id: "occ-short-hospital", stop_id: "STOP_HOSPITAL", position: 3}
    ]
  }

  @express %{
    id: "pattern-express",
    occurrences: [
      %{id: "occ-express-central", stop_id: "STOP_CENTRAL", position: 1},
      %{id: "occ-express-market", stop_id: "STOP_MARKET", position: 2},
      %{id: "occ-express-riverside", stop_id: "STOP_RIVERSIDE", position: 3}
    ]
  }

  @short_a %{
    id: "pattern-short-a",
    occurrences: [
      %{id: "occ-a-central", stop_id: "STOP_CENTRAL", position: 1},
      %{id: "occ-a-market", stop_id: "STOP_MARKET", position: 2},
      %{id: "occ-a-hospital", stop_id: "STOP_HOSPITAL", position: 3}
    ]
  }

  @short_b %{
    id: "pattern-short-b",
    occurrences: [
      %{id: "occ-b-central", stop_id: "STOP_CENTRAL", position: 1},
      %{id: "occ-b-hospital", stop_id: "STOP_HOSPITAL", position: 2}
    ]
  }

  @loop %{
    id: "pattern-loop",
    occurrences: [
      %{id: "occ-loop-central-1", stop_id: "STOP_CENTRAL", position: 1},
      %{id: "occ-loop-market", stop_id: "STOP_MARKET", position: 2},
      %{id: "occ-loop-central-2", stop_id: "STOP_CENTRAL", position: 3}
    ]
  }

  # Columns as ColumnMatcher.match/4 reports them for the chosen full
  # pattern: four stop columns plus Trip/Block/Headsign field columns.
  @main_columns [
    %{
      col: 0,
      header: "Central Station",
      target: {:occurrence, "occ-full-central", :departure},
      status: :exact,
      by: :stop_name
    },
    %{
      col: 1,
      header: "Market Street",
      target: {:occurrence, "occ-full-market", :departure},
      status: :exact,
      by: :stop_name
    },
    %{
      col: 2,
      header: "Hospital",
      target: {:occurrence, "occ-full-hospital", :departure},
      status: :exact,
      by: :stop_name
    },
    %{
      col: 3,
      header: "Riverside Terminal",
      target: {:occurrence, "occ-full-riverside", :departure},
      status: :exact,
      by: :stop_name
    },
    %{col: 4, header: "Trip", target: :trip_short_name, status: :exact, by: :keyword},
    %{col: 5, header: "Block", target: :block_id, status: :exact, by: :keyword},
    %{col: 6, header: "Headsign", target: :trip_headsign, status: :exact, by: :keyword}
  ]

  @loop_columns [
    %{
      col: 0,
      header: "Central Station",
      target: {:occurrence, "occ-loop-central-1", :departure},
      status: :exact,
      by: :stop_name
    },
    %{
      col: 1,
      header: "Market Street",
      target: {:occurrence, "occ-loop-market", :departure},
      status: :exact,
      by: :stop_name
    },
    %{
      col: 2,
      header: "Central Station",
      target: {:occurrence, "occ-loop-central-2", :departure},
      status: :exact,
      by: :stop_name
    }
  ]

  defp scope(patterns, chosen \\ "pattern-full") do
    %{pattern_id: chosen, patterns: patterns}
  end

  describe "full rows stay on the chosen pattern" do
    @describetag :pattern_assignment

    test "a full row stays on the chosen pattern as :default" do
      grid = [["7:00", "7:15", "7:30", "7:45", "101", "12", "Downtown"]]

      assert [
               %{
                 row: 1,
                 status: :ready,
                 issue: nil,
                 pattern_id: "pattern-full",
                 how: :default,
                 start_secs: start_secs,
                 timing_rows: timing_rows,
                 key: key,
                 pasted: [1, 2, 3, 4],
                 trip_short_name: "101",
                 block_id: "12",
                 trip_headsign: "Downtown",
                 rolled?: false,
                 shift: 0
               }
             ] = RowResolver.resolve(grid, @main_columns, scope([@full, @short]), %{}, nil)

      # No timings in scope: offsets are exact with default attributes.
      assert start_secs == 7 * 3_600

      assert timing_rows == [
               %{
                 arrival_offset: 0,
                 departure_offset: 0,
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 arrival_offset: 900,
                 departure_offset: 900,
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 arrival_offset: 1_800,
                 departure_offset: 1_800,
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 arrival_offset: 2_700,
                 departure_offset: 2_700,
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               }
             ]

      assert is_binary(key)

      assert [%{key: ^key}] =
               RowResolver.resolve(grid, @main_columns, scope([@full, @short]), %{}, nil)
    end

    test "a full row whose times roll past noon still keeps the chosen pattern" do
      grid = [["11:50 PM", "12:10", "12:25", "12:40", "102", "", ""]]

      assert [%{status: :ready, pattern_id: "pattern-full", how: :default, rolled?: true}] =
               RowResolver.resolve(grid, @main_columns, scope([@full, @short]), %{}, nil)
    end

    test "blank trip fields read as nil" do
      grid = [["7:00", "7:15", "7:30", "7:45", "", "", ""]]

      assert [%{trip_short_name: nil, block_id: nil, trip_headsign: nil}] =
               RowResolver.resolve(grid, @main_columns, scope([@full]), %{}, nil)
    end
  end

  describe "short turns and deviations" do
    @describetag :pattern_assignment

    test "a row ending at Hospital with one fitting pattern is assigned :auto" do
      grid = [["7:00", "7:15", "7:30", "", "103", "", ""]]

      assert [%{status: :ready, pattern_id: "pattern-short", how: :auto, pasted: [1, 2, 3]}] =
               RowResolver.resolve(grid, @main_columns, scope([@full, @short]), %{}, nil)
    end

    test "an explicit not-served marker excludes patterns that call there" do
      # Hospital is explicitly "-" so the full pattern and the Hospital short
      # turn cannot fit; the Riverside express does. Riverside sits at
      # position 4 on the chosen pattern but position 3 on the express, so
      # pasted [1, 2, 3] proves the mapping went through occurrences.
      grid = [["7:00", "7:15", "-", "8:00", "104", "", ""]]

      assert [%{status: :ready, pattern_id: "pattern-express", how: :auto, pasted: [1, 2, 3]}] =
               RowResolver.resolve(
                 grid,
                 @main_columns,
                 scope([@full, @short, @express]),
                 %{},
                 nil
               )
    end

    test "an interior omission still fits the short turn" do
      # Market is blank but the served endpoints are the short turn's own:
      # correspondence skips the omission (step 6 interpolates it).
      grid = [["7:00", "", "7:30", "", "105", "", ""]]

      assert [%{status: :ready, pattern_id: "pattern-short", how: :auto, pasted: [1, 3]}] =
               RowResolver.resolve(grid, @main_columns, scope([@full, @short]), %{}, nil)
    end
  end

  describe "pattern decisions" do
    @describetag :pattern_assignment

    test "a row fitting two patterns returns {:pattern, ids} without offsets" do
      grid = [["7:00", "", "7:30", "", "106", "", ""]]

      assert [
               %{
                 row: 1,
                 status: :decision,
                 issue: {:pattern, ["pattern-short-a", "pattern-short-b"]},
                 pattern_id: nil,
                 how: nil,
                 start_secs: nil,
                 timing_rows: nil,
                 key: nil,
                 pasted: [],
                 trip_short_name: "106",
                 shift: 0
               }
             ] =
               RowResolver.resolve(
                 grid,
                 @main_columns,
                 scope([@full, @short_a, @short_b]),
                 %{},
                 nil
               )
    end

    test "a row serving stops no pattern has is :no_pattern" do
      # First served stop Market matches no pattern's first endpoint.
      grid = [["", "7:15", "7:30", "", "107", "", ""]]

      assert [%{status: :decision, issue: :no_pattern, pattern_id: nil, how: nil}] =
               RowResolver.resolve(grid, @main_columns, scope([@full, @short]), %{}, nil)
    end

    test "a decision choosing a pattern resolves the row as :chosen" do
      grid = [["7:00", "", "7:30", "", "106", "", ""]]
      scope = scope([@full, @short_a, @short_b])

      assert [%{status: :ready, pattern_id: "pattern-short-b", how: :chosen, pasted: [1, 2]}] =
               RowResolver.resolve(
                 grid,
                 @main_columns,
                 scope,
                 %{1 => %{pattern_id: "pattern-short-b"}},
                 nil
               )

      # String keys survive the LiveView JSON round-trip.
      assert [%{status: :ready, pattern_id: "pattern-short-b", how: :chosen, pasted: [1, 2]}] =
               RowResolver.resolve(
                 grid,
                 @main_columns,
                 scope,
                 %{"1" => %{"pattern_id" => "pattern-short-b"}},
                 nil
               )
    end

    test "a decision naming an unknown pattern is ignored" do
      grid = [["7:00", "", "7:30", "", "106", "", ""]]

      assert [%{status: :decision, issue: {:pattern, ["pattern-short-a", "pattern-short-b"]}}] =
               RowResolver.resolve(
                 grid,
                 @main_columns,
                 scope([@full, @short_a, @short_b]),
                 %{1 => %{pattern_id: "pattern-missing"}},
                 nil
               )
    end
  end

  describe "time errors and empty rows" do
    @describetag :pattern_assignment

    test "an unrecognized cell is a cell decision naming the column" do
      grid = [["7:00", "12:1O", "7:30", "7:45", "108", "", ""]]

      assert [%{status: :decision, issue: {:cell, 1, "12:1O"}}] =
               RowResolver.resolve(grid, @main_columns, scope([@full]), %{}, nil)
    end

    test "a cell correction decision repairs the row" do
      grid = [["7:00", "12:1O", "7:30", "7:45", "108", "", ""]]

      assert [%{status: :ready, pattern_id: "pattern-full", how: :default}] =
               RowResolver.resolve(
                 grid,
                 @main_columns,
                 scope([@full]),
                 %{1 => %{cells: %{1 => "7:15"}}},
                 nil
               )
    end

    test "a time that cannot roll forward is a backwards decision" do
      grid = [["25:10", "25:20", "1:00", "1:10", "109", "", ""]]

      assert [%{status: :decision, issue: {:backwards, 2, "1:00"}}] =
               RowResolver.resolve(grid, @main_columns, scope([@full]), %{}, nil)
    end

    test "rows with no times are skipped as empty" do
      grid = [
        ["", "", "", "", "", "", ""],
        ["-", "-", "-", "-", "", "", ""],
        ["", "", "", "", "110", "", ""]
      ]

      assert [
               %{row: 1, status: :skipped, issue: :empty},
               %{row: 2, status: :skipped, issue: :empty},
               %{row: 3, status: :skipped, issue: :empty}
             ] = RowResolver.resolve(grid, @main_columns, scope([@full]), %{}, nil)
    end

    test "a skip decision skips the row" do
      grid = [["7:00", "7:15", "7:30", "7:45", "101", "", ""]]

      assert [%{status: :skipped, issue: nil, pattern_id: nil}] =
               RowResolver.resolve(
                 grid,
                 @main_columns,
                 scope([@full, @short]),
                 %{1 => %{skip: true}},
                 nil
               )
    end
  end

  describe "twelve-hour rows" do
    @describetag :pattern_assignment

    @evening_grid [
      ["23:05", "23:15", "23:25", "23:35", "201", "", ""],
      ["23:45", "23:55", "24:05", "24:15", "202", "", ""],
      ["24:30", "24:40", "24:50", "25:00", "203", "", ""],
      ["1:15", "1:25", "1:35", "1:45", "204", "", ""]
    ]

    test "an early ambiguous first time in an evening paste needs a decision" do
      assert [
               %{status: :ready, how: :default},
               %{status: :ready, how: :default},
               %{status: :ready, how: :default},
               %{row: 4, status: :decision, issue: {:twelve_hour, 4_500}}
             ] =
               RowResolver.resolve(
                 @evening_grid,
                 @main_columns,
                 scope([@full, @short]),
                 %{},
                 nil
               )
    end

    test "a shift decision answers the twelve-hour question" do
      rows = RowResolver.resolve(@evening_grid, @main_columns, scope([@full]), %{}, nil)
      assert %{row: 4, status: :decision, issue: {:twelve_hour, 4_500}} = Enum.at(rows, 3)

      # With the after-midnight reading chosen the owl row resolves fully.
      assert [
               %{status: :ready},
               %{status: :ready},
               %{status: :ready},
               %{status: :ready, how: :default, shift: 86_400}
             ] =
               RowResolver.resolve(
                 @evening_grid,
                 @main_columns,
                 scope([@full]),
                 %{4 => %{shift: 86_400}},
                 nil
               )
    end

    test "keeping the early reading answers the twelve-hour question" do
      assert [
               %{status: :ready},
               %{status: :ready},
               %{status: :ready},
               %{status: :ready, how: :default, shift: 0}
             ] =
               RowResolver.resolve(
                 @evening_grid,
                 @main_columns,
                 scope([@full]),
                 %{4 => %{keep_early: true}},
                 nil
               )
    end
  end

  describe "loop patterns" do
    @describetag :pattern_assignment

    test "a second visit of a loop maps to the later occurrence" do
      grid = [
        ["7:00", "7:15", "7:30"],
        ["8:00", "", "8:30"]
      ]

      # Row 2 serves Central twice: the correspondence takes the next Central
      # occurrence after the previous one, so the loop is the single fitting
      # pattern and pasted positions are [1, 3], not [1, 1].
      assert [
               %{status: :ready, pattern_id: "pattern-loop", how: :default, pasted: [1, 2, 3]},
               %{status: :ready, pattern_id: "pattern-loop", how: :auto, pasted: [1, 3]}
             ] =
               RowResolver.resolve(
                 grid,
                 @loop_columns,
                 scope([@loop, @short], "pattern-loop"),
                 %{},
                 nil
               )
    end
  end

  describe "first-departure anchors" do
    @describetag :estimation

    @pair_columns [
      %{
        col: 0,
        header: "Central arr",
        target: {:occurrence, "occ-pattern-pair-1", :arrival},
        status: :exact,
        by: :stop_name
      },
      %{
        col: 1,
        header: "Central dep",
        target: {:occurrence, "occ-pattern-pair-1", :departure},
        status: :exact,
        by: :stop_name
      },
      %{
        col: 2,
        header: "Market",
        target: {:occurrence, "occ-pattern-pair-2", :departure},
        status: :exact,
        by: :stop_name
      }
    ]

    test "arrive 06:00, depart 06:05 at the first stop gives start 06:05 and arrival offset -300" do
      grid = [["6:00:45", "6:05:10", "6:20:33"]]
      scope = %{pattern_id: "pattern-pair", patterns: [line_pattern("pattern-pair", 2, [])]}

      assert [
               %{
                 status: :ready,
                 how: :default,
                 start_secs: start_secs,
                 timing_rows: timing_rows,
                 pasted: [1, 2]
               }
             ] = RowResolver.resolve(grid, @pair_columns, scope, %{}, nil)

      # Pasted times are stored exactly, to the second: no rounding.
      assert start_secs == 6 * 3_600 + 5 * 60 + 10

      assert timing_rows == [
               %{
                 arrival_offset: -265,
                 departure_offset: 0,
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 arrival_offset: 923,
                 departure_offset: 923,
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               }
             ]
    end
  end

  describe "template-scaled estimates" do
    @describetag :estimation

    test "the worked example yields 07:17:04, 07:19:35 and 07:22:01" do
      timing =
        template_timing("timing-worked", [{0, 0}, {23, 23}, {51, 51}, {78, 78}, {100, 100}], 5)

      scope = %{pattern_id: "pattern-five", patterns: [line_pattern("pattern-five", 5, [timing])]}
      grid = [["7:15", "", "", "", "7:24"]]

      assert [
               %{
                 status: :ready,
                 how: :auto,
                 start_secs: start_secs,
                 timing_rows: timing_rows,
                 key: key
               }
             ] =
               RowResolver.resolve(
                 grid,
                 line_columns("pattern-five", 5),
                 scope,
                 %{},
                 "timing-worked"
               )

      assert start_secs == 7 * 3_600 + 15 * 60
      assert Enum.map(timing_rows, & &1.arrival_offset) == [0, 124, 275, 421, 540]
      assert Enum.map(timing_rows, & &1.departure_offset) == [0, 124, 275, 421, 540]

      assert Enum.map(timing_rows, &GtfsTime.format(start_secs + &1.arrival_offset)) == [
               "07:15:00",
               "07:17:04",
               "07:19:35",
               "07:22:01",
               "07:24:00"
             ]

      assert is_binary(key)
    end

    test "a template with nil pickup/drop_off attributes keys as 0 so timing reuse can match" do
      # Stored stop_times may carry NULL pickup_type/drop_off_type; GTFS reads
      # those as 0. The timing key must normalize nil to 0, otherwise a
      # pasted row never matches an existing timing and always creates a
      # duplicate "Pasted" timing (step 17 regression).
      timing =
        template_timing("timing-held", [{0, 0}, {23, 23}, {51, 51}, {78, 78}, {100, 100}], 5)

      rows_with_nils =
        Enum.map(timing.rows, fn row ->
          %{row | pickup_type: nil, drop_off_type: nil}
        end)

      nil_timing = %{timing | rows: rows_with_nils}

      scope = %{
        pattern_id: "pattern-five",
        patterns: [line_pattern("pattern-five", 5, [nil_timing])]
      }

      grid = [["7:15", "", "", "", "7:24"]]

      assert [%{status: :ready, timing_rows: timing_rows, key: nil_key}] =
               RowResolver.resolve(
                 grid,
                 line_columns("pattern-five", 5),
                 scope,
                 %{},
                 "timing-held"
               )

      assert is_binary(nil_key)
      assert Enum.map(timing_rows, & &1.pickup_type) == [0, 0, 0, 0, 0]
      assert Enum.map(timing_rows, & &1.drop_off_type) == [0, 0, 0, 0, 0]

      zero_timing =
        template_timing("timing-zero", [{0, 0}, {23, 23}, {51, 51}, {78, 78}, {100, 100}], 5)

      zero_scope = %{
        pattern_id: "pattern-five",
        patterns: [line_pattern("pattern-five", 5, [zero_timing])]
      }

      assert [%{key: zero_key}] =
               RowResolver.resolve(
                 grid,
                 line_columns("pattern-five", 5),
                 zero_scope,
                 %{},
                 "timing-zero"
               )

      # Same template times, same effective attributes: the keys must match so
      # Plan can reuse the existing timing instead of duplicating it.
      assert nil_key == zero_key
    end

    test "a zero-length template segment spaces estimates evenly" do
      timing = template_timing("timing-flat", [{0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0}], 5)
      scope = %{pattern_id: "pattern-five", patterns: [line_pattern("pattern-five", 5, [timing])]}
      grid = [["7:00", "", "", "", "7:10"]]

      assert [%{start_secs: start_secs, timing_rows: timing_rows}] =
               RowResolver.resolve(
                 grid,
                 line_columns("pattern-five", 5),
                 scope,
                 %{},
                 "timing-flat"
               )

      assert start_secs == 7 * 3_600
      # div(j * 600, k + 1) with k = 3 gives 150/300/450; without the rule
      # the zero-length template segment would divide by zero or stack
      # every estimate on one time.
      assert Enum.map(timing_rows, & &1.arrival_offset) == [0, 150, 300, 450, 600]
      assert Enum.map(timing_rows, & &1.departure_offset) == [0, 150, 300, 450, 600]
    end

    test "estimates never cross a pasted time and keep dwell only when it fits" do
      tight = template_timing("timing-tight", [{0, 0}, {99, 129}, {100, 100}], 4)
      fits = template_timing("timing-fits", [{0, 0}, {99, 100}, {100, 100}], 1)

      scope = %{
        pattern_id: "pattern-dwell",
        patterns: [line_pattern("pattern-dwell", 3, [tight, fits])]
      }

      columns = line_columns("pattern-dwell", 3)
      grid = [["7:00", "", "7:01:54"]]

      # floor(99 * 114 / 100) = 112; a 30-second dwell past 114 does not fit.
      assert [%{timing_rows: [first, middle, last]}] =
               RowResolver.resolve(grid, columns, scope, %{}, "timing-tight")

      assert first == %{
               arrival_offset: 0,
               departure_offset: 0,
               timepoint: 1,
               pickup_type: 0,
               drop_off_type: 0,
               stop_headsign: nil
             }

      assert middle.arrival_offset == 112
      assert middle.departure_offset == 112
      assert middle.timepoint == 0
      assert last == %{first | arrival_offset: 114, departure_offset: 114}

      # A 1-second dwell fits before the next pasted time and is kept.
      assert [%{timing_rows: [_first, middle, _last]}] =
               RowResolver.resolve(grid, columns, scope, %{}, "timing-fits")

      assert middle.arrival_offset == 112
      assert middle.departure_offset == 113
    end

    test "estimated rows carry timepoint 0 and pasted rows timepoint 1" do
      timing =
        template_timing("timing-worked", [{0, 0}, {23, 23}, {51, 51}, {78, 78}, {100, 100}], 5)

      scope = %{pattern_id: "pattern-five", patterns: [line_pattern("pattern-five", 5, [timing])]}
      grid = [["7:15", "", "", "", "7:24"]]

      assert [%{timing_rows: timing_rows}] =
               RowResolver.resolve(
                 grid,
                 line_columns("pattern-five", 5),
                 scope,
                 %{},
                 "timing-worked"
               )

      assert Enum.map(timing_rows, & &1.timepoint) == [1, 0, 0, 0, 1]
      refute Enum.any?(timing_rows, &is_nil(&1.timepoint))
    end
  end

  describe "template selection and timing keys" do
    @describetag :estimation

    test "the input template timing wins when it belongs to the row's pattern" do
      scope = two_timing_scope()
      grid = [["7:15", "", "", "", "7:24"]]

      assert [%{timing_rows: timing_rows}] =
               RowResolver.resolve(grid, line_columns("pattern-five", 5), scope, %{}, "timing-a")

      assert Enum.map(timing_rows, & &1.stop_headsign) == ["A", "A", "A", "A", "A"]
    end

    test "otherwise the pattern's most-used timing is used" do
      scope = two_timing_scope()
      grid = [["7:15", "", "", "", "7:24"]]

      for template_id <- [nil, "timing-missing"] do
        assert [%{timing_rows: timing_rows}] =
                 RowResolver.resolve(
                   grid,
                   line_columns("pattern-five", 5),
                   scope,
                   %{},
                   template_id
                 )

        assert Enum.map(timing_rows, & &1.stop_headsign) == ["B", "B", "B", "B", "B"]
      end
    end

    test "the key covers the full final vector" do
      scope = two_timing_scope()
      columns = line_columns("pattern-five", 5)
      grid = [["7:15", "", "", "", "7:24"]]

      assert [%{key: key}] = RowResolver.resolve(grid, columns, scope, %{}, "timing-a")
      assert [%{key: same}] = RowResolver.resolve(grid, columns, scope, %{}, "timing-a")
      assert same == key

      assert [%{key: other_time}] =
               RowResolver.resolve(
                 [["7:15", "", "", "", "7:25"]],
                 columns,
                 scope,
                 %{},
                 "timing-a"
               )

      assert other_time != key

      assert [%{key: other_attrs}] = RowResolver.resolve(grid, columns, scope, %{}, "timing-b")
      assert other_attrs != key
    end
  end

  describe "KCM real-feed oracle" do
    @describetag :estimation

    @oracle_path Path.expand("../../../fixtures/timetable_paste/kcm_route_100224.json", __DIR__)

    test "six timepoints pasted over the template stay exact and estimates fall between neighbours" do
      oracle = @oracle_path |> File.read!() |> Jason.decode!()
      stops = oracle["stops"]

      anchors =
        stops
        |> Enum.with_index()
        |> Enum.flat_map(fn {stop, i} -> if stop["timepoint"] == 1, do: [i], else: [] end)

      assert anchors == [0, 5, 11, 14, 23, 26]

      occurrences =
        Enum.with_index(stops, 1)
        |> Enum.map(fn {stop, position} ->
          %{id: "occ-kcm-#{position}", stop_id: stop["stop_id"], position: position}
        end)

      template_rows =
        Enum.map(oracle["template"]["offsets"], fn [arrival, departure] ->
          %{
            arrival_offset: arrival,
            departure_offset: departure,
            pickup_type: 0,
            drop_off_type: 0,
            stop_headsign: nil
          }
        end)

      timing = %{id: "timing-kcm-template", rows: template_rows, trip_count: 8}

      scope = %{
        pattern_id: "pattern-kcm",
        patterns: [%{id: "pattern-kcm", occurrences: occurrences, timings: [timing]}]
      }

      columns =
        Enum.with_index(anchors)
        |> Enum.map(fn {stop_index, col} ->
          %{
            col: col,
            header: Enum.at(stops, stop_index)["stop_name"],
            target: {:occurrence, "occ-kcm-#{stop_index + 1}", :departure},
            status: :exact,
            by: :stop_name
          }
        end)

      target_arrivals = Enum.map(oracle["target"]["arrival_time"], &parse_clock!/1)
      target_departures = Enum.map(oracle["target"]["departure_time"], &parse_clock!/1)

      grid = [
        Enum.map(anchors, fn i ->
          String.slice(Enum.at(oracle["target"]["departure_time"], i), 0, 5)
        end)
      ]

      assert [
               %{
                 status: :ready,
                 how: :default,
                 start_secs: start_secs,
                 timing_rows: timing_rows,
                 pasted: pasted,
                 key: key
               }
             ] = RowResolver.resolve(grid, columns, scope, %{}, "timing-kcm-template")

      # A 42-minute trip (16:45-17:27) pasted over the 33-minute template.
      assert start_secs == 16 * 3_600 + 45 * 60
      assert length(timing_rows) == 27
      assert pasted == [1, 6, 12, 15, 24, 27]
      assert is_binary(key)

      # The six pasted timepoints are exact.
      for i <- anchors do
        row = Enum.at(timing_rows, i)
        assert start_secs + row.arrival_offset == Enum.at(target_arrivals, i)
        assert start_secs + row.departure_offset == Enum.at(target_departures, i)
        assert row.timepoint == 1
      end

      # Every estimate lies between its neighbouring pasted times.
      for {a, b} <- Enum.zip(anchors, tl(anchors)), b - a > 1, j <- (a + 1)..(b - 1) do
        row = Enum.at(timing_rows, j)
        assert row.timepoint == 0
        assert start_secs + row.arrival_offset >= Enum.at(target_departures, a)
        assert start_secs + row.departure_offset <= Enum.at(target_arrivals, b)
      end

      # The whole vector is non-decreasing.
      absolutes =
        Enum.map(timing_rows, &{start_secs + &1.arrival_offset, start_secs + &1.departure_offset})

      assert absolutes
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [{_a1, d1}, {a2, d2}] -> a2 >= d1 and d2 >= a2 end)

      # Per-stop error of the template-scaled estimates against the actual
      # trip, written to the test output for the EV-5 oracle comparison.
      errors =
        Enum.with_index(stops)
        |> Enum.map(fn {stop, i} ->
          actual = Enum.at(target_departures, i)
          estimated = start_secs + Enum.at(timing_rows, i).departure_offset
          error = actual - estimated

          IO.puts(
            "oracle #{stop["stop_id"]} actual=#{GtfsTime.format(actual)} " <>
              "estimated=#{GtfsTime.format(estimated)} err=#{format_error(error)}"
          )

          error
        end)

      max_error = errors |> Enum.map(&abs/1) |> Enum.max()
      IO.puts("oracle max abs error: #{max_error}s over #{length(stops)} stops")
      # The fixture's template profile tracks the actual trip within a
      # second; the bound rejects minute-rounding regressions (which err by
      # up to ~59 s and stack identical consecutive times) without pinning
      # exact fixture values.
      assert max_error <= 5
    end
  end

  defp line_pattern(id, count, timings) do
    %{
      id: id,
      occurrences:
        Enum.map(1..count, fn i ->
          %{id: "occ-#{id}-#{i}", stop_id: "STOP_#{id}_#{i}", position: i}
        end),
      timings: timings
    }
  end

  defp line_columns(id, count) do
    Enum.map(0..(count - 1), fn i ->
      %{
        col: i,
        header: "Stop #{i + 1}",
        target: {:occurrence, "occ-#{id}-#{i + 1}", :departure},
        status: :exact,
        by: :stop_name
      }
    end)
  end

  defp template_timing(id, pairs, trip_count, headsign \\ nil) do
    %{
      id: id,
      rows:
        Enum.map(pairs, fn {arrival, departure} ->
          %{
            arrival_offset: arrival,
            departure_offset: departure,
            pickup_type: 0,
            drop_off_type: 0,
            stop_headsign: headsign
          }
        end),
      trip_count: trip_count
    }
  end

  defp two_timing_scope do
    pairs = [{0, 0}, {23, 23}, {51, 51}, {78, 78}, {100, 100}]

    %{
      pattern_id: "pattern-five",
      patterns: [
        line_pattern("pattern-five", 5, [
          template_timing("timing-a", pairs, 2, "A"),
          template_timing("timing-b", pairs, 9, "B")
        ])
      ]
    }
  end

  defp parse_clock!(clock) do
    [hours, minutes, seconds] = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    hours * 3_600 + minutes * 60 + seconds
  end

  defp format_error(0), do: "+0s"
  defp format_error(error) when error > 0, do: "+#{error}s"
  defp format_error(error), do: "#{error}s"
end
