defmodule GtfsPlanner.Gtfs.TimetablePaste.RowResolverTest do
  use ExUnit.Case, async: true

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
                 start_secs: nil,
                 timing_rows: nil,
                 key: nil,
                 pasted: [1, 2, 3, 4],
                 trip_short_name: "101",
                 block_id: "12",
                 trip_headsign: "Downtown",
                 rolled?: false,
                 shift: 0
               }
             ] = RowResolver.resolve(grid, @main_columns, scope([@full, @short]), %{}, nil)
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
end
