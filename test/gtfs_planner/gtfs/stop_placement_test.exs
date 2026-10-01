defmodule GtfsPlanner.Gtfs.StopPlacementTest do
  @moduledoc """
  The stop editor's placement judgements, as a table of literal cases.

  These are the thresholds the whole placement UI is built on, so each
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

  # Four collinear stops on one line, a hundred metres apart running north. The
  # gap between them is a fifth of the line, so "halfway between the second and
  # the third" is fifty metres past a whole number and not a rounding artefact.
  defp collinear_row do
    for step <- 0..3 do
      {elem(@origin, 0), elem(@origin, 1) + step * 100.0 / 111_320.0}
    end
  end

  # Halfway between the stop at `index` and the next one along the row.
  defp midway(row, index) do
    {lon, here} = Enum.at(row, index)
    {_next_lon, next} = Enum.at(row, index + 1)

    {lon, (here + next) / 2}
  end

  defp north_of({lon, lat}, metres), do: {lon, lat + metres / 111_320.0}
  defp south_of({lon, lat}, metres), do: {lon, lat - metres / 111_320.0}

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

  describe "insertion_index/2" do
    test "a point halfway between the second and third of four collinear stops belongs at 2" do
      row = collinear_row()

      assert StopPlacement.insertion_index(midway(row, 1), row) == 2
    end

    test "a point before the first stop belongs at 0" do
      row = collinear_row()

      assert StopPlacement.insertion_index(south_of(hd(row), 50.0), row) == 0
    end

    test "a point past the end of the line belongs after its last stop" do
      row = collinear_row()

      # Appending is cheaper than putting the stop between the last stop and
      # the end of the line, so the answer is the length. `along_m/2` clamps
      # the projection at the terminal vertex, so a plain count of the stops
      # that measure before this point would place it before the last stop
      # instead — see the `past_the_last?/2` branch below the function.
      assert StopPlacement.insertion_index(north_of(List.last(row), 50.0), row) == 4
    end

    test "a point on a stop's own place is not before that stop" do
      row = collinear_row()

      assert StopPlacement.insertion_index(Enum.at(row, 2), row) == 2
    end

    test "a row with no stops puts everything at 0" do
      assert StopPlacement.insertion_index(@origin, []) == 0
    end
  end

  describe "order_stops/2" do
    test "a pattern's stops come back in the order a vehicle meets them, whatever order they arrive in" do
      row = collinear_row()
      [first, second, third] = Enum.take(row, 3)

      stops = [
        %{stop_id: "B", point: third},
        %{stop_id: "A", point: first},
        %{stop_id: "C", point: second}
      ]

      assert StopPlacement.order_stops(stops, row) |> Enum.map(& &1.stop_id) == ["A", "C", "B"]
    end

    test "two stops on the same point of the line keep the id's order, so the answer is stable" do
      row = collinear_row()

      stops = [
        %{stop_id: "B", point: Enum.at(row, 1)},
        %{stop_id: "A", point: Enum.at(row, 1)}
      ]

      assert StopPlacement.order_stops(stops, row) |> Enum.map(& &1.stop_id) == ["A", "B"]
    end
  end

  describe "passing_patterns/2" do
    test "a point east of a northbound shape passes it, and the same point east of a southbound one does not" do
      north = %{pattern_id: "nb", source: :shape, points: northbound(@origin)}
      south = %{pattern_id: "sb", source: :shape, points: Enum.reverse(northbound(@origin))}
      connector = %{pattern_id: "c", source: :connector, points: northbound(@origin)}

      model = %{lines: [north, south, connector]}

      assert StopPlacement.passing_patterns(east_of(@origin, 8.0), model)
             |> Enum.map(& &1.pattern_id) ==
               ["nb"]

      # The same kerb, read the other way up: a bus running south stops on the
      # west side, so the east point is the far pavement for it.
      assert StopPlacement.passing_patterns(east_of(@origin, -8.0), model)
             |> Enum.map(& &1.pattern_id) ==
               ["sb"]
    end

    test "a model with no lines passes nothing" do
      assert StopPlacement.passing_patterns(@origin, %{lines: []}) == []
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
