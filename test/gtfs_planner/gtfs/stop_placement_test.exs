defmodule GtfsPlanner.Gtfs.StopPlacementTest do
  @moduledoc """
  The stop editor's placement judgements, as a table of literal cases.

  These are the thresholds the whole placement UI is built on (INV-3), so each
  one is checked either side of its boundary rather than at a comfortable
  distance from it. A threshold that drifts by a metre changes which stops an
  editor is warned about, and a test with round numbers would not notice.

  No database and no network: every case is a pure function over coordinates.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StopPlacement

  # A point roughly one degree east of the origin, where a degree of longitude
  # is short enough that small metre offsets are easy to write by hand.
  @origin {-124.053, 44.637}

  # The same point pushed east by a number of metres. At this latitude a degree
  # of longitude is about 79.6 km.
  defp east_of(origin, metres) do
    {elem(origin, 0) + metres / (111_320.0 * :math.cos(:math.pi() * elem(origin, 1) / 180)),
     elem(origin, 1)}
  end

  # A northbound line: constant longitude, running north.
  defp northbound(origin) do
    [{elem(origin, 0), elem(origin, 1) - 0.001}, {elem(origin, 0), elem(origin, 1) + 0.001}]
  end

  describe "classify/2" do
    test "4.9 m apart is the same stop placed twice" do
      assert StopPlacement.classify(@origin, east_of(@origin, 4.9)) == :duplicate
    end

    test "5.1 m apart is nearby rather than a duplicate" do
      assert StopPlacement.classify(@origin, east_of(@origin, 5.1)) == :nearby
    end

    test "30.1 m apart is a distinct place" do
      assert StopPlacement.classify(@origin, east_of(@origin, 30.1)) == :distinct
    end

    test "a point on top of another is a duplicate" do
      assert StopPlacement.classify(@origin, @origin) == :duplicate
    end
  end

  describe "classify_shared_station/2" do
    test "two child stops of one station are never duplicates" do
      # Two levels of one station can be a metre apart and are still two places.
      assert {classification, metres} =
               StopPlacement.classify_shared_station(@origin, east_of(@origin, 1.0))

      assert classification == :distinct
      assert_in_delta metres, 1.0, 0.1
    end
  end

  describe "warn/3 against a shape" do
    test "3.1 m west of a northbound line is the wrong side" do
      assert StopPlacement.warn(east_of(@origin, -3.1), northbound(@origin), :shape) ==
               :wrong_side
    end

    test "2.9 m west of a northbound line is in the middle of the street instead" do
      # Close enough that "wrong pavement" would be the wrong thing to say: the
      # stop is on the right side, just not at the kerb.
      assert StopPlacement.warn(east_of(@origin, -2.9), northbound(@origin), :shape) ==
               :middle_of_street
    end

    test "3.1 m east of a northbound line is the served kerb and draws no warning" do
      assert StopPlacement.warn(east_of(@origin, 3.1), northbound(@origin), :shape) == nil
    end

    test "a point on the line itself is in the middle of the street" do
      assert StopPlacement.warn(@origin, northbound(@origin), :shape) == :middle_of_street
    end
  end

  describe "warn/3 against a connector" do
    test "a connector produces neither side warning" do
      # A connector joins two shapes and describes no kerb, so the same distances
      # that warn on a shape are silent here.
      assert StopPlacement.warn(east_of(@origin, -3.1), northbound(@origin), :connector) == nil
      assert StopPlacement.warn(east_of(@origin, -2.9), northbound(@origin), :connector) == nil
    end

    test "a connector can still be off line" do
      # Distance means the same thing whichever kind of line it is.
      assert StopPlacement.warn(east_of(@origin, 100.1), northbound(@origin), :connector) ==
               :off_line
    end
  end

  describe "off line" do
    test "100.1 m from the only serving line is off the shape" do
      assert StopPlacement.warn(east_of(@origin, 100.1), northbound(@origin), :shape) ==
               :off_line
    end

    test "99.9 m from the only serving line is not" do
      assert StopPlacement.warn(east_of(@origin, 99.9), northbound(@origin), :shape) == nil
    end

    test "an empty line is never off line, it is simply nothing to measure against" do
      assert StopPlacement.warn(@origin, [], :shape) == nil
    end
  end

  describe "across_street/2" do
    test "reflects 8 m east of a northbound line to 8 m west of it" do
      line = northbound(@origin)
      across = StopPlacement.across_street(east_of(@origin, 8.0), line)

      {metres, side} = StopPlacement.offset_m(across, line)

      assert_in_delta metres, 8.0, 0.1
      assert side == :west
    end

    test "reflecting twice returns the original point" do
      line = northbound(@origin)
      there = east_of(@origin, 8.0)

      assert StopPlacement.across_street(StopPlacement.across_street(there, line), line) ==
               there
    end

    test "a point on the line reflects to itself" do
      assert StopPlacement.across_street(@origin, northbound(@origin)) == @origin
    end

    test "a line with one point has no direction to reflect in" do
      assert StopPlacement.across_street(@origin, [@origin]) == @origin
    end
  end

  describe "move_band/2" do
    test "8.0 m on a served stop is a coordinate correction" do
      assert StopPlacement.move_band(8.0, true) == :correction
    end

    test "8.1 m on a served stop is worth a review, because intent is unclear" do
      assert StopPlacement.move_band(8.1, true) == :review
    end

    test "100.1 m on a served stop is far" do
      assert StopPlacement.move_band(100.1, true) == :far
    end

    test "400 m on an unserved stop is a correction, because nothing contradicts it" do
      # `served?` is the second argument, not "confirmed". A stop no route names
      # can move anywhere: there is no timetable to contradict the new position.
      assert StopPlacement.move_band(400.0, false) == :correction
    end

    test "a small move on an unserved stop is a correction" do
      assert StopPlacement.move_band(0.5, false) == :correction
    end

    test "a served move past the correction band needs a review" do
      assert StopPlacement.move_band(20.0, true) == :review
    end
  end
end
