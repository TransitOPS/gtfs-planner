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
end
