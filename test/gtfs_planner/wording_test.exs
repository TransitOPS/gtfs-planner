defmodule GtfsPlanner.WordingTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Wording

  describe "count/1" do
    test "groups thousands for positive, negative and million-sized integers" do
      assert Wording.count(1234) == "1,234"
      assert Wording.count(-1234) == "-1,234"
      assert Wording.count(-123) == "-123"
      assert Wording.count(1_000_000) == "1,000,000"
      assert Wording.count(1000) == "1,000"
      assert Wording.count(999) == "999"
      assert Wording.count(0) == "0"
      assert Wording.count(1_204_338) == "1,204,338"
      assert Wording.count(812) == "812"
    end

    test "falls back to to_string/1 for non-integers" do
      assert Wording.count(nil) == ""
      assert Wording.count("1234") == "1234"
      assert Wording.count(12.5) == "12.5"
    end
  end

  describe "noun/3" do
    test "uses an explicit plural for irregular nouns" do
      assert Wording.noun(2, "person", "people") == "people"
      assert Wording.noun(1, "person", "people") == "person"
      assert Wording.noun(2, "agency", "agencies") == "agencies"
    end

    test "appends an s for a regular noun" do
      assert Wording.noun(3, "trip") == "trips"
      assert Wording.noun(0, "trip") == "trips"
      assert Wording.noun(1, "trip") == "trip"
      assert Wording.noun(1, "trip", "trips") == "trip"
    end
  end

  describe "count_noun/3" do
    test "joins the grouped count and its noun" do
      assert Wording.count_noun(1, "trip") == "1 trip"
      assert Wording.count_noun(2, "trip") == "2 trips"
      assert Wording.count_noun(0, "trip") == "0 trips"
      assert Wording.count_noun(1234, "trip") == "1,234 trips"
      assert Wording.count_noun(2, "agency", "agencies") == "2 agencies"
    end

    test "uses the given plural when the word does not take s" do
      assert Wording.count_noun(3, "day off", "days off") == "3 days off"
    end
  end

  describe "percent/2" do
    test "multiplies before dividing so exact halves round up" do
      assert Wording.percent(23, 40) == 58
      assert Wording.percent(29, 200) == 15
      assert Wording.percent(1, 3) == 33
      assert Wording.percent(1, 2) == 50
    end

    test "returns zero when the whole is not positive" do
      assert Wording.percent(5, 0) == 0
      assert Wording.percent(5, -10) == 0
      assert Wording.percent(5, nil) == 0
    end
  end

  describe "duration/1" do
    test "renders minutes, whole hours and hours with minutes" do
      assert Wording.duration(2700) == "45 min"
      assert Wording.duration(3600) == "1 h"
      assert Wording.duration(3900) == "1 h 5 min"
      assert Wording.duration(7200) == "2 h"
      assert Wording.duration(0) == "0 min"
    end

    test "truncates partial minutes" do
      assert Wording.duration(59) == "0 min"
      assert Wording.duration(3659) == "1 h"
    end
  end

  describe "date/1" do
    test "formats a Date" do
      assert Wording.date(~D[2026-10-01]) == "Oct 1, 2026"
    end

    test "formats a DateTime and a NaiveDateTime by their own date" do
      assert Wording.date(~U[2026-10-01 14:05:00Z]) == "Oct 1, 2026"
      assert Wording.date(~N[2026-09-27 14:18:00]) == "Sep 27, 2026"
    end
  end

  describe "short_date/1" do
    test "formats a Date without the year" do
      assert Wording.short_date(~D[2026-10-01]) == "Oct 1"
    end

    test "formats a NaiveDateTime without the year" do
      assert Wording.short_date(~N[2026-09-27 14:18:00]) == "Sep 27"
    end
  end

  describe "weekday_date/1" do
    test "formats the weekday and day" do
      assert Wording.weekday_date(~D[2026-10-01]) == "Thu, Oct 1"
    end
  end

  describe "weekday_date_with_year/1" do
    test "formats the weekday, day and year" do
      assert Wording.weekday_date_with_year(~D[2026-10-01]) == "Thu, Oct 1, 2026"
    end
  end

  describe "capitalize_first/1" do
    test "upcases the first grapheme and leaves the rest" do
      assert Wording.capitalize_first("éa") == "Éa"
      assert Wording.capitalize_first("main st") == "Main st"
      assert Wording.capitalize_first("") == ""
    end
  end
end
