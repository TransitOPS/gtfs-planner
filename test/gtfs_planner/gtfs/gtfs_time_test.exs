defmodule GtfsPlanner.Gtfs.GtfsTimeTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.GtfsTime

  describe "parse/1" do
    test "parses hour values beyond one day and preserves second precision" do
      assert GtfsTime.parse("25:00:00") == {:ok, 90_000}
      assert GtfsTime.parse("01:02:03") == {:ok, 3_723}
    end

    test "formats and parses the nonnegative integer-second domain" do
      for seconds <- [0, 1, 59, 60, 3_723, 86_400, 90_000, 2_147_483_647] do
        assert seconds |> GtfsTime.format() |> GtfsTime.parse() == {:ok, seconds}
      end

      assert GtfsTime.parse("596523:24:08") == {:error, :invalid_time}
    end

    test "rejects invalid clock fields and malformed input" do
      for value <- ["12:60:00", "12:00:60", "8:4:2", "ab:cd", "-01:00", ""] do
        assert GtfsTime.parse(value) == {:error, :invalid_time}
      end
    end
  end

  describe "parse_offset/1" do
    test "parses signed elapsed values and hours beyond one day" do
      assert GtfsTime.parse_offset("-01:00") == {:ok, -60}
      assert GtfsTime.parse_offset("25:00:00") == {:ok, 90_000}
      assert GtfsTime.parse_offset("01:02:03") == {:ok, 3_723}
    end

    test "formats and parses the signed integer-second domain" do
      for seconds <- [-2_147_483_647, -90_000, -3_723, -60, -1, 0, 1, 60, 3_723, 90_000] do
        assert seconds |> GtfsTime.format_offset() |> GtfsTime.parse_offset() ==
                 {:ok, seconds}
      end

      assert GtfsTime.parse_offset("596523:24:08") == {:error, :invalid_time}
    end

    test "rejects invalid clock fields and malformed signs" do
      for value <- ["12:60:00", "8:4:2", "ab:cd", "--01:00", "+01:00", "-"] do
        assert GtfsTime.parse_offset(value) == {:error, :invalid_time}
      end
    end
  end

  describe "display/1" do
    test "keeps GTFS hours and adds seconds only when nonzero" do
      assert GtfsTime.display(25_500) == "07:05"
      assert GtfsTime.display(25_530) == "07:05:30"
      assert GtfsTime.display(90_600) == "25:10"
      assert GtfsTime.display(86_460) == "24:01"
      assert GtfsTime.display(0) == "00:00"
      assert GtfsTime.display(86_399) == "23:59:59"
    end

    test "wraps negative values with a day count and a true minus sign" do
      assert GtfsTime.display(-600) == "23:50 −1d"
      assert GtfsTime.display(-900) == "23:45 −1d"
      assert GtfsTime.display(-30) == "23:59:30 −1d"
      assert GtfsTime.display(-86_400) == "00:00 −1d"
    end

    test "renders nil as an em dash" do
      assert GtfsTime.display(nil) == "—"
    end
  end

  describe "coerce/1" do
    test "returns non-negative integers and parsed HH:MM:SS strings as seconds" do
      assert GtfsTime.coerce(25_200) == 25_200
      assert GtfsTime.coerce(0) == 0
      assert GtfsTime.coerce("07:00:30") == 25_230
      assert GtfsTime.coerce("25:00:00") == 90_000
    end

    test "returns nil for values that are not non-negative service seconds" do
      assert GtfsTime.coerce(-1) == nil
      assert GtfsTime.coerce("7am") == nil
      assert GtfsTime.coerce("12:60:00") == nil
      assert GtfsTime.coerce(1.5) == nil
      assert GtfsTime.coerce(nil) == nil
    end
  end

  describe "parse_hhmm/1" do
    test "converts H:MM and HH:MM to minutes" do
      assert GtfsTime.parse_hhmm("4:30") == 270
      assert GtfsTime.parse_hhmm("16:05") == 965
      assert GtfsTime.parse_hhmm("25:10") == 1_510
    end

    test "returns nil unless the value is exactly two integer parts" do
      assert GtfsTime.parse_hhmm("4:30:00") == nil
      assert GtfsTime.parse_hhmm("4:30pm") == nil
      assert GtfsTime.parse_hhmm(nil) == nil
    end

    test "does not bound the minutes field" do
      assert GtfsTime.parse_hhmm("4:70") == 310
    end
  end
end
