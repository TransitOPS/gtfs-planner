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
end
