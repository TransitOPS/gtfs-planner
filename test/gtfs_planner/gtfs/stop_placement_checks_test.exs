defmodule GtfsPlanner.Gtfs.StopPlacementChecksTest do
  @moduledoc """
  The version-wide placement checks, as a table of literal cases (EV-12, AC-11).

  `version_checks/1` is what the map's checks disclosure lists, so these cases are
  written as the rows an editor would read: a pair that is or is not a duplicate,
  a stop that is or is not on the wrong side, a stop nothing serves.

  Each threshold is checked either side of its boundary rather than at a
  comfortable distance from it. Three point two metres apart is a pair and six
  metres apart is not; four metres left of the line warns and the same stop
  against a connector does not. A test with round numbers would not notice a
  threshold that drifts, and a drifting threshold changes which stops an editor
  is told to look at.

  No database and no network: `version_checks/1` is a pure function over the map
  model, so these are literal maps of the shape `StopsMap.load/2` returns.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StopPlacement

  # Where every fixture sits. A degree of longitude here is about 79.6 km, so
  # the metre offsets below are small enough to write by hand.
  @origin {-124.053, 44.637}

  defp east_of(origin, metres) do
    {elem(origin, 0) + metres / (111_320.0 * :math.cos(:math.pi() * elem(origin, 1) / 180)),
     elem(origin, 1)}
  end

  defp north_of(origin, metres) do
    {elem(origin, 0), elem(origin, 1) + metres / 111_320.0}
  end

  # The `StopsMap` stop row. The defaults are an ordinary served street stop: a
  # located point, no parent, and one pattern visiting it.
  defp stop(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        stop_id: id,
        name: "Stop #{id}",
        point: @origin,
        location_type: 0,
        parent_station: nil,
        served?: true,
        pattern_ids: [Ecto.UUID.generate()]
      },
      attrs
    )
  end

  # The `StopsMap` line row.
  defp line(pattern_id, points, source \\ :shape) do
    %{
      pattern_id: pattern_id,
      route_id: "R1",
      direction_id: 0,
      headsign: "To Town",
      source: source,
      points: points
    }
  end

  # A northbound line at a stop's longitude: the vehicle runs up the given
  # longitude, so a stop east of it is on the pavement it serves.
  defp northbound_at(point) do
    [north_of(point, -100.0), north_of(point, 100.0)]
  end

  # How far east of `point` the next ten-metre grid cell boundary lies, in
  # metres. `version_checks/1` buckets on the same projection this reproduces, so
  # a fixture that wants to straddle a seam can ask where the seam is instead of
  # guessing and hoping the origin happens to fall on one.
  defp metres_to_cell_edge(point) do
    {lon, lat} = point
    x = lon * 111_320.0 * :math.cos(:math.pi() * lat / 180)
    # The same `floor(x / cell)` bucketing the module does, expressed as the
    # distance from `x` to the next multiple of the cell width. `rem/2` is
    # integer-only, so this is `x - floor(x / 10) * 10` in metres.
    10.0 - (x - Float.floor(x / 10.0) * 10.0)
  end

  describe "duplicate pairs" do
    test "stops 3.2 m apart are one pair, reported once" do
      first = stop("A")
      second = stop("B", %{point: east_of(@origin, 3.2)})

      assert %{duplicates: [{left, right, metres}]} =
               StopPlacement.version_checks(%{stops: [first, second], lines: []})

      assert left.stop_id == "A"
      assert right.stop_id == "B"
      assert_in_delta metres, 3.2, 0.05
    end

    test "stops 6 m apart are not a pair" do
      first = stop("A")
      second = stop("B", %{point: east_of(@origin, 6.0)})

      assert %{duplicates: []} =
               StopPlacement.version_checks(%{stops: [first, second], lines: []})
    end

    test "the pair is reported from the reverse order too, not twice" do
      first = stop("A")
      second = stop("B", %{point: east_of(@origin, 3.2)})

      assert %{duplicates: [{_, _, _}]} =
               StopPlacement.version_checks(%{stops: [second, first], lines: []})

      assert %{duplicates: [{_, _, _}]} =
               StopPlacement.version_checks(%{stops: [first, second], lines: []})
    end

    test "two bays of one station 2 m apart are not a pair" do
      first = stop("A", %{parent_station: "ST1"})
      second = stop("B", %{point: east_of(@origin, 2.0), parent_station: "ST1"})

      assert %{duplicates: []} =
               StopPlacement.version_checks(%{stops: [first, second], lines: []})
    end

    test "a station 2 m from an ordinary stop is not a pair" do
      station = stop("ST1", %{location_type: 1})
      other = stop("A", %{point: east_of(@origin, 2.0)})

      assert %{duplicates: []} =
               StopPlacement.version_checks(%{stops: [station, other], lines: []})
    end

    test "an unlocated stop is never in a pair" do
      # `load/2` returns `point: nil` for a stop with no coordinates. Comparing
      # it would either crash or invent a position at the origin.
      located = stop("A")
      unlocated = stop("B", %{point: nil})

      assert %{duplicates: []} =
               StopPlacement.version_checks(%{stops: [located, unlocated], lines: []})
    end

    test "a pair is found across a cell boundary, not just inside one cell" do
      # The pair straddles a ten-metre cell edge — the first stop 1.6 m west of
      # it, the second 1.6 m east — so the two land in different buckets while
      # still being 3.2 m apart. If the scan only compared a cell to itself it
      # would miss exactly the pairs on the seam, which is what this case is
      # here to catch. `metres_to_cell_edge/1` finds the seam from the same
      # projection the scan buckets on, so the fixture does not depend on where
      # the origin happens to fall within a cell.
      seam = metres_to_cell_edge(@origin)
      first = stop("A", %{point: east_of(@origin, seam - 1.6)})
      second = stop("B", %{point: east_of(@origin, seam + 1.6)})

      assert %{duplicates: [{left, right, metres}]} =
               StopPlacement.version_checks(%{stops: [first, second], lines: []})

      assert {left.stop_id, right.stop_id} == {"A", "B"}
      assert_in_delta metres, 3.2, 0.05
    end
  end

  describe "wrong side" do
    test "a stop 4 m left of its own northbound shape line is listed" do
      pattern_id = Ecto.UUID.generate()
      west = east_of(@origin, -4.0)
      stop = stop("A", %{point: west, pattern_ids: [pattern_id]})

      assert %{wrong_side: [{listed, line}]} =
               StopPlacement.version_checks(%{
                 stops: [stop],
                 lines: [line(pattern_id, northbound_at(@origin))]
               })

      assert listed.stop_id == "A"
      assert line.source == :shape
    end

    test "the same stop against a connector line is not listed" do
      pattern_id = Ecto.UUID.generate()
      stop = stop("A", %{point: east_of(@origin, -4.0), pattern_ids: [pattern_id]})

      assert %{wrong_side: []} =
               StopPlacement.version_checks(%{
                 stops: [stop],
                 lines: [line(pattern_id, northbound_at(@origin), :connector)]
               })
    end

    test "a line that does not serve the stop is not its line" do
      other_pattern = Ecto.UUID.generate()
      stop = stop("A", %{point: east_of(@origin, -4.0)})

      assert %{wrong_side: []} =
               StopPlacement.version_checks(%{
                 stops: [stop],
                 lines: [line(other_pattern, northbound_at(@origin))]
               })
    end

    test "a stop on the served side of the line is not listed" do
      pattern_id = Ecto.UUID.generate()
      stop = stop("A", %{point: east_of(@origin, 4.0), pattern_ids: [pattern_id]})

      assert %{wrong_side: []} =
               StopPlacement.version_checks(%{
                 stops: [stop],
                 lines: [line(pattern_id, northbound_at(@origin))]
               })
    end

    test "an unserved stop is not judged on side" do
      # Nothing runs past it, so there is no direction for it to be wrong of.
      pattern_id = Ecto.UUID.generate()

      stop =
        stop("A", %{point: east_of(@origin, -4.0), served?: false, pattern_ids: [pattern_id]})

      assert %{wrong_side: []} =
               StopPlacement.version_checks(%{
                 stops: [stop],
                 lines: [line(pattern_id, northbound_at(@origin))]
               })
    end

    test "a stop wrong of two of its lines is listed once" do
      first_pattern = Ecto.UUID.generate()
      second_pattern = Ecto.UUID.generate()

      stop =
        stop("A", %{point: east_of(@origin, -4.0), pattern_ids: [first_pattern, second_pattern]})

      assert %{wrong_side: [{_listed, _line}]} =
               StopPlacement.version_checks(%{
                 stops: [stop],
                 lines: [
                   line(first_pattern, northbound_at(@origin)),
                   line(second_pattern, northbound_at(@origin))
                 ]
               })
    end
  end

  describe "not served" do
    test "an unserved type-0 stop is listed" do
      stop = stop("A", %{served?: false})

      assert %{not_served: [listed]} = StopPlacement.version_checks(%{stops: [stop], lines: []})
      assert listed.stop_id == "A"
    end

    test "an unserved station is not listed" do
      # A station with no served children is a container awaiting platforms, not
      # a stop a rider is standing at.
      station = stop("ST1", %{served?: false, location_type: 1})

      assert %{not_served: []} = StopPlacement.version_checks(%{stops: [station], lines: []})
    end

    test "a served stop is not listed" do
      assert %{not_served: []} = StopPlacement.version_checks(%{stops: [stop("A")], lines: []})
    end
  end

  describe "the whole model" do
    test "each of the three lists is computed from the same model" do
      # Laid out so that exactly one pair falls inside five metres and each stop
      # has one intended finding. The far-pavement stop is the awkward one: to
      # be on the wrong side it must sit more than three metres west of its
      # line, which would put it inside the duplicate threshold of any stop on
      # that same line. So it gets its own line a quarter of a kilometre west,
      # and no other stop is near either.
      near_pattern = Ecto.UUID.generate()
      far_pattern = Ecto.UUID.generate()
      west_line = east_of(@origin, -250.0)

      on_line = stop("A", %{point: @origin, pattern_ids: [near_pattern]})
      twin = stop("B", %{point: east_of(@origin, 3.0), pattern_ids: [near_pattern]})
      far_side = stop("C", %{point: east_of(west_line, -4.0), pattern_ids: [far_pattern]})
      idle = stop("D", %{point: east_of(@origin, 50.0), served?: false})
      further = stop("E", %{point: east_of(@origin, 100.0)})

      assert %{duplicates: duplicates, wrong_side: wrong_side, not_served: not_served} =
               StopPlacement.version_checks(%{
                 stops: [on_line, twin, far_side, idle, further],
                 lines: [
                   line(near_pattern, northbound_at(@origin)),
                   line(far_pattern, northbound_at(west_line))
                 ]
               })

      assert Enum.map(duplicates, fn {a, b, _} -> {a.stop_id, b.stop_id} end) == [{"A", "B"}]
      assert Enum.map(wrong_side, fn {s, _} -> s.stop_id end) == ["C"]
      assert Enum.map(not_served, & &1.stop_id) == ["D"]
    end

    test "an empty version has three empty lists rather than an error" do
      assert StopPlacement.version_checks(%{stops: [], lines: []}) == %{
               duplicates: [],
               wrong_side: [],
               not_served: []
             }
    end
  end
end
