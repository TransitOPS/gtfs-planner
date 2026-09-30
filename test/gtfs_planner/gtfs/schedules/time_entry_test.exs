defmodule GtfsPlanner.Gtfs.Schedules.TimeEntryTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Schedules.TimeEntry

  # Every expected value below is literal, hand-derived from the R2 examples in
  # spec.md §4.2 and the GTFS reference. Nothing here calls the parser to build
  # its own expectation.

  defp reading(secs, reading, note \\ nil), do: {:ok, %{secs: secs, reading: reading, note: note}}

  describe "parse/2 documented R2 examples" do
    test "reads an ambiguous time 12 hours later than the previous stop" do
      assert TimeEntry.parse("705", previous: 18 * 3_600 + 50 * 60) ==
               reading(19 * 3_600 + 5 * 60, "19:05", :plus_12h)
    end

    test "reads a suffixed early-morning time onto the next service day" do
      assert TimeEntry.parse("12:05a", previous: 23 * 3_600 + 56 * 60) ==
               reading(24 * 3_600 + 5 * 60, "24:05", :next_day)
    end

    test "keeps a leading-zero reading literal when it is earlier than the previous stop" do
      assert TimeEntry.parse("0605", previous: 18 * 3_600 + 50 * 60) ==
               reading(6 * 3_600 + 5 * 60, "06:05")
    end

    test "keeps an hour past one day literal" do
      assert TimeEntry.parse("25:10") == reading(25 * 3_600 + 10 * 60, "25:10")
    end

    test "adds and subtracts whole minutes from the cell's current time" do
      assert TimeEntry.parse("+3", current: 7 * 3_600 + 26 * 60) ==
               reading(7 * 3_600 + 29 * 60, "07:29")

      assert TimeEntry.parse("-10", current: 5 * 60) == {:error, :negative_time}
      assert TimeEntry.parse("+3", []) == {:error, :invalid_time}
      assert TimeEntry.parse("+3", current: nil) == {:error, :invalid_time}
    end
  end

  describe "parse/2 literal forms" do
    test "reads an hour on its own as whole hours" do
      assert TimeEntry.parse("6") == reading(6 * 3_600, "06:00")
      assert TimeEntry.parse("18") == reading(18 * 3_600, "18:00")
    end

    test "reads three digits as H MM" do
      assert TimeEntry.parse("605") == reading(6 * 3_600 + 5 * 60, "06:05")
      assert TimeEntry.parse("005") == reading(5 * 60, "00:05")
    end

    test "reads four digits as HH MM" do
      assert TimeEntry.parse("0605") == reading(6 * 3_600 + 5 * 60, "06:05")
      assert TimeEntry.parse("1805") == reading(18 * 3_600 + 5 * 60, "18:05")
      assert TimeEntry.parse("2510") == reading(25 * 3_600 + 10 * 60, "25:10")
    end

    test "reads colon forms with a one- or two-digit hour and optional seconds" do
      assert TimeEntry.parse("6:05") == reading(6 * 3_600 + 5 * 60, "06:05")
      assert TimeEntry.parse("06:05") == reading(6 * 3_600 + 5 * 60, "06:05")
      assert TimeEntry.parse("6:05:30") == reading(6 * 3_600 + 5 * 60 + 30, "06:05:30")
      assert TimeEntry.parse("25:10") == reading(25 * 3_600 + 10 * 60, "25:10")
      assert TimeEntry.parse("0:00") == reading(0, "00:00")
      assert TimeEntry.parse("59:59:59") == reading(59 * 3_600 + 59 * 60 + 59, "59:59:59")
    end

    test "reads a 12-hour suffix in any case with an optional space" do
      assert TimeEntry.parse("6:05p") == reading(18 * 3_600 + 5 * 60, "18:05")
      assert TimeEntry.parse("6:05P") == reading(18 * 3_600 + 5 * 60, "18:05")
      assert TimeEntry.parse("6p") == reading(18 * 3_600, "18:00")
      assert TimeEntry.parse("6 p") == reading(18 * 3_600, "18:00")
      assert TimeEntry.parse("6:05pm") == reading(18 * 3_600 + 5 * 60, "18:05")
      assert TimeEntry.parse("6:05 am") == reading(6 * 3_600 + 5 * 60, "06:05")
      assert TimeEntry.parse("12:05a") == reading(5 * 60, "00:05")
      assert TimeEntry.parse("12:05p") == reading(12 * 3_600 + 5 * 60, "12:05")
      assert TimeEntry.parse("1a") == reading(1 * 3_600, "01:00")
    end

    test "trims surrounding whitespace" do
      assert TimeEntry.parse("  7:05  ") == reading(7 * 3_600 + 5 * 60, "07:05")
    end
  end

  describe "parse/2 service-day adjustment" do
    test "adjusts an ambiguous reading only when it falls before the previous stop" do
      assert TimeEntry.parse("6:05", previous: 10 * 3_600) ==
               reading(18 * 3_600 + 5 * 60, "18:05", :plus_12h)

      assert TimeEntry.parse("6:05", previous: 6 * 3_600) ==
               reading(6 * 3_600 + 5 * 60, "06:05")

      assert TimeEntry.parse("6:05", previous: nil) == reading(6 * 3_600 + 5 * 60, "06:05")
      assert TimeEntry.parse("6:05", []) == reading(6 * 3_600 + 5 * 60, "06:05")
    end

    test "takes the next day when 12 hours is still before the previous stop" do
      assert TimeEntry.parse("6:05", previous: 23 * 3_600 + 56 * 60) ==
               reading(30 * 3_600 + 5 * 60, "30:05", :next_day)
    end

    test "adjusts a suffixed reading by 24 hours" do
      assert TimeEntry.parse("6:05p", previous: 23 * 3_600 + 56 * 60) ==
               reading(42 * 3_600 + 5 * 60, "42:05", :next_day)

      assert TimeEntry.parse("12:05p", previous: 23 * 3_600 + 56 * 60) ==
               reading(36 * 3_600 + 5 * 60, "36:05", :next_day)

      assert TimeEntry.parse("12:05a", previous: 10 * 3_600) ==
               reading(24 * 3_600 + 5 * 60, "24:05", :next_day)
    end

    test "keeps the literal value when neither candidate reaches the previous stop" do
      assert TimeEntry.parse("6:05", previous: 40 * 3_600) ==
               reading(6 * 3_600 + 5 * 60, "06:05")
    end

    test "keeps a leading-zero or past-midnight reading literal before the previous stop" do
      assert TimeEntry.parse("0605", previous: 18 * 3_600 + 50 * 60) ==
               reading(6 * 3_600 + 5 * 60, "06:05")

      assert TimeEntry.parse("25:10", previous: 30 * 3_600) ==
               reading(25 * 3_600 + 10 * 60, "25:10")
    end
  end

  describe "parse/2 relative forms" do
    test "adds whole minutes to the cell's current time" do
      assert TimeEntry.parse("+3", current: 7 * 3_600 + 26 * 60) ==
               reading(7 * 3_600 + 29 * 60, "07:29")

      assert TimeEntry.parse("+999", current: 24 * 3_600) ==
               reading(40 * 3_600 + 39 * 60, "40:39")
    end

    test "subtracts whole minutes from the cell's current time" do
      assert TimeEntry.parse("-10", current: 10 * 3_600) == reading(9 * 3_600 + 50 * 60, "09:50")
      assert TimeEntry.parse("-999", current: 0) == {:error, :negative_time}
    end

    test "refuses relative readings with no current time or outside 1..999 minutes" do
      assert TimeEntry.parse("+3", current: nil) == {:error, :invalid_time}
      assert TimeEntry.parse("+3", []) == {:error, :invalid_time}
      assert TimeEntry.parse("+0", current: 0) == {:error, :invalid_time}
      assert TimeEntry.parse("-0", current: 0) == {:error, :invalid_time}
      assert TimeEntry.parse("+1000", current: 0) == {:error, :invalid_time}
      assert TimeEntry.parse("+", current: 0) == {:error, :invalid_time}
      assert TimeEntry.parse("+3.5", current: 0) == {:error, :invalid_time}
      assert TimeEntry.parse("+-3", current: 0) == {:error, :invalid_time}
    end
  end

  describe "parse/2 invalid forms" do
    test "refuses minutes and seconds at or above 60" do
      assert TimeEntry.parse("7:75") == {:error, :invalid_time}
      assert TimeEntry.parse("24:60") == {:error, :invalid_time}
      assert TimeEntry.parse("6:05:60") == {:error, :invalid_time}
      assert TimeEntry.parse("6060") == {:error, :invalid_time}
    end

    test "refuses a 12-hour suffix outside hours 1..12" do
      assert TimeEntry.parse("13p") == {:error, :invalid_time}
      assert TimeEntry.parse("0:30p") == {:error, :invalid_time}
      assert TimeEntry.parse("13:05pm") == {:error, :invalid_time}
    end

    test "refuses empty, whitespace and malformed text" do
      for text <- [
            "",
            "   ",
            "abc",
            "6:5",
            "6:5:30",
            "6:",
            ":05",
            "6:05:",
            "6.05",
            "1,5",
            "12:05x",
            "6:05aa",
            "-6:05",
            "6:05-2"
          ] do
        assert TimeEntry.parse(text) == {:error, :invalid_time},
               "expected #{inspect(text)} to be invalid"
      end
    end

    test "refuses non-binary input" do
      assert TimeEntry.parse(nil) == {:error, :invalid_time}
      assert TimeEntry.parse(605) == {:error, :invalid_time}
    end
  end
end
