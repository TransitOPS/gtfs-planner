defmodule GtfsPlanner.Gtfs.TimetablePaste.ColumnMatcherTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.TimetablePaste.ColumnMatcher

  # Shared fixture: names are pairwise distant except the Main pair, which
  # exists to prove the uniqueness rule (see the "no unique close match"
  # test for the measured jaro scores).
  @stops %{
    "STOP_MILL" => %{stop_code: "1001", stop_name: "Mill Street"},
    "STOP_CENTRAL" => %{stop_code: "1002", stop_name: "Central Station"},
    "STOP_HOSPITAL" => %{stop_code: "4521", stop_name: "Hospital"},
    "STOP_MAIN_1ST" => %{stop_code: "2001", stop_name: "Main St & 1st"},
    "STOP_MAIN_AVE" => %{stop_code: "2002", stop_name: "Main St & 1st Ave"},
    "STOP_DEPOT" => %{stop_code: "9001", stop_name: "Depot Yard"},
    "STOP_CASE" => %{stop_code: "9002", stop_name: "Harbor View"}
  }

  describe "normalize/1" do
    test "expands abbreviations and collapses punctuation" do
      assert ColumnMatcher.normalize("Mill St") == "mill street"
      assert ColumnMatcher.normalize("Main St & 1st Ave") == "main street and 1st ave"
      assert ColumnMatcher.normalize("Centrl Sta.") == "centrl station"
      assert ColumnMatcher.normalize("Riverside Term") == "riverside terminal"
    end

    test "folds diacritics through NFD" do
      assert ColumnMatcher.normalize("Café Sta") == "cafe station"
    end

    test "leaves ordinals alone" do
      assert ColumnMatcher.normalize("1st Ave") == "1st ave"
    end
  end

  describe "match_header/2 — stop code rung" do
    test "a header equal to a stop code matches by code" do
      assert ColumnMatcher.match_header("4521", @stops) ==
               {:stop, "STOP_HOSPITAL", :stop_code, :exact, nil}
    end
  end

  describe "match_header/2 — stop ID rung" do
    test "a header equal to a stop ID matches exactly" do
      stops = %{"HOSP-A" => %{stop_code: "4521", stop_name: "Hospital"}}

      assert ColumnMatcher.match_header("HOSP-A", stops) ==
               {:stop, "HOSP-A", :stop_id, :exact, nil}
    end

    test "a stop ID differing only by case does not match" do
      stops = %{"HOSP-A" => %{stop_code: "4521", stop_name: "Hospital"}}

      assert ColumnMatcher.match_header("hosp-a", stops) == :none
    end
  end

  describe "match_header/2 — stop name rung" do
    test "'Mill St' matches Mill Street exactly by name" do
      assert ColumnMatcher.match_header("Mill St", @stops) ==
               {:stop, "STOP_MILL", :stop_name, :exact, nil}
    end

    test "abbreviated and punctuated variants still match exactly" do
      assert ColumnMatcher.match_header("Central Sta", @stops) ==
               {:stop, "STOP_CENTRAL", :stop_name, :exact, nil}

      assert ColumnMatcher.match_header("central station", @stops) ==
               {:stop, "STOP_CENTRAL", :stop_name, :exact, nil}
    end
  end

  describe "match_header/2 — close name rung" do
    test "'Centrl Station' is a close match for Central Station" do
      # jaro("centrl station", "central station") is 0.9182; the next best
      # fixture name scores 0.6312, so the best is unique.
      assert ColumnMatcher.match_header("Centrl Station", @stops) ==
               {:stop, "STOP_CENTRAL", :similar_name, :close, nil}
    end

    test "'Main St & 1st' and 'Main St & 1st Ave' leave no unique close match" do
      # "Main St & 1st A" normalizes to "main street and 1st a": jaro 0.9710
      # against "... 1st ave" and 0.9683 against "... 1st", a gap of 0.0028,
      # well under the 0.02 uniqueness margin.
      assert ColumnMatcher.match_header("Main St & 1st A", @stops) == :none
    end

    test "exact names still win when similar names exist" do
      assert ColumnMatcher.match_header("Main St & 1st", @stops) ==
               {:stop, "STOP_MAIN_1ST", :stop_name, :exact, nil}

      assert ColumnMatcher.match_header("Main St & 1st Ave", @stops) ==
               {:stop, "STOP_MAIN_AVE", :stop_name, :exact, nil}
    end
  end

  describe "match_header/2 — trip-field keywords" do
    test "trip number variants map to trip_short_name" do
      for header <- ["Trip", "Trip #", "Trip no", "Trip number", "Train"] do
        assert ColumnMatcher.match_header(header, @stops) == {:field, :trip_short_name},
               "expected #{inspect(header)} to map to trip_short_name"
      end
    end

    test "block variants map to block_id" do
      for header <- ["Block", "Block #", "Block ID"] do
        assert ColumnMatcher.match_header(header, @stops) == {:field, :block_id},
               "expected #{inspect(header)} to map to block_id"
      end
    end

    test "headsign variants map to trip_headsign" do
      for header <- ["Headsign", "Destination"] do
        assert ColumnMatcher.match_header(header, @stops) == {:field, :trip_headsign},
               "expected #{inspect(header)} to map to trip_headsign"
      end
    end

    test "'Run' is never a trip-number keyword" do
      assert ColumnMatcher.match_header("Run", @stops) == :none
      assert ColumnMatcher.match_header("run", @stops) == :none
    end
  end

  describe "match_header/2 — arrival/departure side" do
    test "'Hospital arr' marks the arrival side of Hospital" do
      assert ColumnMatcher.match_header("Hospital arr", @stops) ==
               {:stop, "STOP_HOSPITAL", :stop_name, :exact, :arrival}
    end

    test "dep and the full words mark the departure side" do
      assert ColumnMatcher.match_header("Hospital dep", @stops) ==
               {:stop, "STOP_HOSPITAL", :stop_name, :exact, :departure}

      assert ColumnMatcher.match_header("Hospital departure", @stops) ==
               {:stop, "STOP_HOSPITAL", :stop_name, :exact, :departure}

      assert ColumnMatcher.match_header("Hospital arrival", @stops) ==
               {:stop, "STOP_HOSPITAL", :stop_name, :exact, :arrival}
    end

    test "a genuine name ending in a side word keeps a nil side" do
      stops = %{"DT-DEP" => %{stop_code: "9010", stop_name: "Downtown Dep"}}

      # "Downtown" alone is not close enough (jaro 0.8889 < 0.9), so the
      # stripped base matches nothing and the whole header retries cleanly.
      assert ColumnMatcher.match_header("Downtown Dep", stops) ==
               {:stop, "DT-DEP", :stop_name, :exact, nil}
    end
  end

  describe "match_header/2 — no match" do
    test "an unknown header is :none" do
      assert ColumnMatcher.match_header("Zzz Top", @stops) == :none
      assert ColumnMatcher.match_header("", @stops) == :none
    end
  end

  # Step 4 fixtures: occurrence lists joined with their stop display fields,
  # the shape `match/4`, `orient/2` and `match_headerless/2` take. Ids are
  # opaque literals (no UUID validation); only equality matters.
  @loop_occs [
    %{id: "occ-a1", stop_id: "STOP_A", position: 1, stop_code: "A1", stop_name: "Alpha"},
    %{id: "occ-b2", stop_id: "STOP_B", position: 2, stop_code: "B1", stop_name: "Beta"},
    %{id: "occ-a3", stop_id: "STOP_A", position: 3, stop_code: "A1", stop_name: "Alpha"}
  ]

  @ab_occs [
    %{id: "occ-a1", stop_id: "STOP_A", position: 1, stop_code: "A1", stop_name: "Alpha"},
    %{id: "occ-b2", stop_id: "STOP_B", position: 2, stop_code: "B1", stop_name: "Beta"}
  ]

  @hosp_occs [
    %{
      id: "occ-hosp",
      stop_id: "STOP_HOSPITAL",
      position: 1,
      stop_code: "4521",
      stop_name: "Hospital"
    }
  ]

  @pair_occs [
    %{
      id: "occ-central",
      stop_id: "STOP_CENTRAL",
      position: 1,
      stop_code: "1002",
      stop_name: "Central Station"
    },
    %{
      id: "occ-mill",
      stop_id: "STOP_MILL",
      position: 2,
      stop_code: "1001",
      stop_name: "Mill Street"
    }
  ]

  describe "orient/2" do
    @describetag :orientation

    test "detects stops down the side" do
      grid = [
        ["", "Trip 101", "Trip 102"],
        ["Hospital", "8:00", "9:00"],
        ["Central Station", "8:10", "9:10"]
      ]

      occurrences = @hosp_occs ++ @pair_occs

      assert ColumnMatcher.orient(grid, occurrences) == :stops_in_rows
    end

    test "keeps trips in rows when the header row matches more stops" do
      grid = [
        ["Trip", "Hospital", "Central Station"],
        ["101", "8:00", "8:10"]
      ]

      occurrences = @hosp_occs ++ @pair_occs

      assert ColumnMatcher.orient(grid, occurrences) == :trips_in_rows
    end

    test "ties keep trips in rows" do
      grid = [
        ["Hospital", "8:00"],
        ["8:05", "8:10"]
      ]

      assert ColumnMatcher.orient(grid, @hosp_occs) == :trips_in_rows
    end
  end

  describe "match/4 occurrence assignment (R4)" do
    @describetag :occurrence_assignment

    test "a loop A-B-A maps the second A column to position 3" do
      grid = [
        ["Alpha", "Beta", "Alpha"],
        ["8:00", "8:10", "8:20"],
        ["9:00", "9:10", "9:20"]
      ]

      assert [
               %{
                 col: 0,
                 header: "Alpha",
                 target: {:occurrence, "occ-a1", :departure},
                 status: :exact,
                 by: :stop_name
               },
               %{
                 col: 1,
                 header: "Beta",
                 target: {:occurrence, "occ-b2", :departure},
                 status: :exact,
                 by: :stop_name
               },
               %{
                 col: 2,
                 header: "Alpha",
                 target: {:occurrence, "occ-a3", :departure},
                 status: :exact,
                 by: :stop_name
               }
             ] = ColumnMatcher.match(grid, @loop_occs, %{}, MapSet.new())
    end

    test "'Hospital arr' and 'Hospital dep' share one occurrence as arrival then departure" do
      grid = [
        ["Hospital arr", "Hospital dep"],
        ["8:00", "8:01"]
      ]

      columns = ColumnMatcher.match(grid, @hosp_occs, %{}, MapSet.new())

      assert [
               %{col: 0, target: {:occurrence, "occ-hosp", :arrival}, status: :exact},
               %{col: 1, target: {:occurrence, "occ-hosp", :departure}, status: :exact}
             ] = columns

      assert ColumnMatcher.issues(columns) == []
    end

    test "a third column for one occurrence is out of order" do
      grid = [
        ["Hospital", "Hospital", "Hospital"],
        ["8:00", "8:01", "8:02"]
      ]

      columns = ColumnMatcher.match(grid, @hosp_occs, %{}, MapSet.new())

      assert [
               {:occurrence, "occ-hosp", :arrival},
               {:occurrence, "occ-hosp", :departure},
               {:occurrence, "occ-hosp", :departure}
             ] = Enum.map(columns, & &1.target)

      assert [:exact, :exact, :out_of_order] = Enum.map(columns, & &1.status)
      assert ColumnMatcher.issues(columns) == [%{col: 2, kind: :out_of_order}]
    end

    test "a column whose stop has no later occurrence is out of order" do
      grid = [
        ["Beta", "Alpha"],
        ["8:00", "8:05"]
      ]

      assert [
               %{status: :exact, target: {:occurrence, "occ-b2", :departure}},
               %{status: :out_of_order, target: {:occurrence, "occ-a1", :departure}}
             ] = ColumnMatcher.match(grid, @ab_occs, %{}, MapSet.new())
    end
  end

  describe "match/4 overrides and confirmations" do
    @describetag :column_overrides

    test "an override to an earlier occurrence is out of order" do
      grid = [
        ["Alpha", "Beta", "Alpha"],
        ["8:00", "8:10", "8:20"]
      ]

      columns = ColumnMatcher.match(grid, @loop_occs, %{2 => "occ:occ-a1"}, MapSet.new())

      assert %{
               col: 2,
               target: {:occurrence, "occ-a1", :departure},
               status: :out_of_order,
               by: nil
             } = Enum.at(columns, 2)

      assert %{col: 2, kind: :out_of_order} in ColumnMatcher.issues(columns)
    end

    test "an override can map a column to a trip field" do
      grid = [
        ["Alpha", "Beta", "Block"],
        ["8:00", "8:10", "B12"]
      ]

      columns = ColumnMatcher.match(grid, @ab_occs, %{2 => "block_id"}, MapSet.new())

      assert %{col: 2, target: :block_id, status: :chosen, by: nil} = Enum.at(columns, 2)
      assert ColumnMatcher.issues(columns) == []
    end

    test "an ignore override marks the column unused and skips order checks" do
      grid = [
        ["Beta", "Beta", "Beta"],
        ["8:00", "8:05", "8:10"]
      ]

      auto = ColumnMatcher.match(grid, @ab_occs, %{}, MapSet.new())
      assert :out_of_order in Enum.map(auto, & &1.status)

      columns = ColumnMatcher.match(grid, @ab_occs, %{2 => "ignore"}, MapSet.new())

      assert %{col: 2, target: :ignore, status: :unused, by: nil} = Enum.at(columns, 2)
      assert ColumnMatcher.issues(columns) == []
    end

    test "an override to an unknown occurrence stays unmatched" do
      grid = [
        ["Alpha", "Beta"],
        ["8:00", "8:10"]
      ]

      columns = ColumnMatcher.match(grid, @ab_occs, %{1 => "occ:nope"}, MapSet.new())

      assert %{col: 1, target: nil, status: :unmatched} = Enum.at(columns, 1)

      assert ColumnMatcher.issues(columns) == [
               %{col: 1, kind: :unmatched},
               %{col: nil, kind: :too_few}
             ]
    end
  end

  describe "match/4 close matches and keywords (R5)" do
    @describetag :close_matches

    test "'Centrl Station' blocks until confirmed" do
      grid = [
        ["Centrl Station", "Mill Street"],
        ["8:00", "8:05"]
      ]

      columns = ColumnMatcher.match(grid, @pair_occs, %{}, MapSet.new())

      assert %{
               col: 0,
               target: {:occurrence, "occ-central", :departure},
               status: :close,
               by: :similar_name
             } = Enum.at(columns, 0)

      assert %{col: 0, kind: :close} in ColumnMatcher.issues(columns)

      confirmed = ColumnMatcher.match(grid, @pair_occs, %{}, MapSet.new([0]))

      assert %{col: 0, status: :confirmed, by: :similar_name} = Enum.at(confirmed, 0)
      refute Enum.any?(ColumnMatcher.issues(confirmed), &(&1.kind == :close))
    end

    test "'Run' stays unmatched" do
      grid = [
        ["Alpha", "Run", "Beta"],
        ["8:00", "101", "8:10"]
      ]

      columns = ColumnMatcher.match(grid, @ab_occs, %{}, MapSet.new())

      assert %{col: 1, header: "Run", target: nil, status: :unmatched, by: nil} =
               Enum.at(columns, 1)

      assert %{col: 1, kind: :unmatched} in ColumnMatcher.issues(columns)
    end

    test "trip-field keywords map with an exact status" do
      grid = [
        ["Trip", "Alpha", "Beta"],
        ["101", "8:00", "8:10"]
      ]

      columns = ColumnMatcher.match(grid, @ab_occs, %{}, MapSet.new())

      assert %{col: 0, target: :trip_short_name, status: :exact, by: :keyword} =
               Enum.at(columns, 0)

      assert ColumnMatcher.issues(columns) == []
    end
  end

  describe "match_headerless/2" do
    @describetag :headerless

    test "assigns columns to occurrences in order when counts are equal" do
      grid = [
        ["8:00", "8:10"],
        ["9:00", "9:10"]
      ]

      columns = ColumnMatcher.match_headerless(grid, @ab_occs)

      assert [
               %{
                 col: 0,
                 header: "",
                 target: {:occurrence, "occ-a1", :departure},
                 status: :chosen,
                 by: nil
               },
               %{
                 col: 1,
                 header: "",
                 target: {:occurrence, "occ-b2", :departure},
                 status: :chosen,
                 by: nil
               }
             ] = columns

      assert ColumnMatcher.issues(columns) == []
    end

    test "leaves every column unmatched when counts differ" do
      grid = [
        ["8:00", "8:10", "8:20"]
      ]

      columns = ColumnMatcher.match_headerless(grid, @ab_occs)

      assert [%{status: :unmatched}, %{status: :unmatched}, %{status: :unmatched}] = columns

      assert %{col: nil, kind: :too_few} in ColumnMatcher.issues(columns)
    end
  end

  describe "issues/1" do
    @describetag :column_issues

    test "returns per-column issues in column order without :too_few" do
      columns = [
        %{
          col: 0,
          header: "A",
          target: {:occurrence, "x", :departure},
          status: :exact,
          by: :stop_name
        },
        %{col: 1, header: "Trip", target: :trip_short_name, status: :exact, by: :keyword},
        %{col: 2, header: "Run", target: nil, status: :unmatched, by: nil},
        %{
          col: 3,
          header: "Centrl",
          target: {:occurrence, "y", :departure},
          status: :close,
          by: :similar_name
        },
        %{
          col: 4,
          header: "B",
          target: {:occurrence, "z", :departure},
          status: :out_of_order,
          by: :stop_name
        },
        %{col: 5, header: "Notes", target: :ignore, status: :unused, by: nil}
      ]

      assert ColumnMatcher.issues(columns) == [
               %{col: 2, kind: :unmatched},
               %{col: 3, kind: :close},
               %{col: 4, kind: :out_of_order}
             ]
    end

    test "reports :too_few when fewer than two stop columns exist" do
      assert ColumnMatcher.issues([]) == [%{col: nil, kind: :too_few}]

      single = [
        %{
          col: 0,
          header: "A",
          target: {:occurrence, "x", :departure},
          status: :exact,
          by: :stop_name
        }
      ]

      assert ColumnMatcher.issues(single) == [%{col: nil, kind: :too_few}]
    end
  end
end
