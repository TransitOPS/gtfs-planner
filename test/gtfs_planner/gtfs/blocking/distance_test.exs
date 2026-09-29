defmodule GtfsPlanner.Gtfs.Blocking.DistanceTest do
  @moduledoc """
  Merge evidence (EV-11) for CL-11 / AC-7: a path length is the sum of the
  great-circle legs between consecutive points, in kilometres, and it is measured
  from coordinates alone.

  Every expectation is derived independently of the module under test. The
  expected leg length is computed here from the haversine formula with the same
  6 371 000 m earth radius the production helper uses, never by calling
  `StationReport2.Helpers.haversine/4`, and the expected path length is the sum
  of those legs. The fixed points sit 0.01° apart on one meridian, so each leg is
  `6 371 000 × 0.01 × π / 180 / 1000 ≈ 1.1119 km` — a value checkable by hand
  from the published formula.

  The module under test is pure: it reads its arguments and touches no database,
  clock, file or network, so these cases run in the local ExUnit process with no
  sandbox, no fixtures and no cleanup.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/distance_test.exs`. This test
  establishes the arithmetic and the coordinates-only contract; it says nothing
  about how accurate a straight-line path is against real roads, which stays out
  of scope, nor about the per-shape and per-trip aggregation of steps 7 and 9.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Distance

  @earth_radius_m 6_371_000.0

  # One hundredth of a degree of latitude along a meridian, in kilometres.
  @leg_km 1.1119

  # Three points, 0.01° apart, northbound on one meridian.
  @path [{42.0, -71.0}, {42.01, -71.0}, {42.02, -71.0}]
  @two_legs_km 2.2238

  describe "path_km/1" do
    test "sums the legs of a three-point path" do
      assert_in_delta Distance.path_km(@path), @two_legs_km, 0.001
      assert_in_delta Distance.path_km(@path), 2 * @leg_km, 0.001
    end

    test "agrees with a haversine computed in the test" do
      expected = leg_km({42.0, -71.0}, {42.01, -71.0}) + leg_km({42.01, -71.0}, {42.02, -71.0})

      assert_in_delta Distance.path_km(@path), expected, 1.0e-9
    end

    test "one leg per consecutive pair, not one per point" do
      four_points = [{42.0, -71.0}, {42.01, -71.0}, {42.02, -71.0}, {42.03, -71.0}]

      assert_in_delta Distance.path_km(four_points), 3 * @leg_km, 0.001

      assert_in_delta Distance.path_km(four_points),
                      leg_km({42.0, -71.0}, {42.01, -71.0}) +
                        leg_km({42.01, -71.0}, {42.02, -71.0}) +
                        leg_km({42.02, -71.0}, {42.03, -71.0}),
                      1.0e-9
    end

    test "is 0.0 for a single point and for no points at all" do
      assert Distance.path_km([]) == 0.0
      assert Distance.path_km([{42.0, -71.0}]) == 0.0
    end

    test "a repeated consecutive point adds nothing" do
      repeated = [{42.0, -71.0}, {42.0, -71.0}, {42.01, -71.0}]
      without = [{42.0, -71.0}, {42.01, -71.0}]

      assert Distance.path_km(repeated) == Distance.path_km(without)
      assert_in_delta Distance.path_km(repeated), @leg_km, 0.001

      all_repeated = List.duplicate({42.0, -71.0}, 4)
      assert Distance.path_km(all_repeated) == 0.0
    end

    test "sums a path that turns, whichever end it is walked from" do
      turning = [{42.0, -71.0}, {42.01, -71.0}, {42.02, -71.01}]
      expected = leg_km({42.0, -71.0}, {42.01, -71.0}) + leg_km({42.01, -71.0}, {42.02, -71.01})

      # The second leg is a diagonal, longer than the meridian's leg, so the
      # total is not two times one leg.
      assert_in_delta Distance.path_km(turning), expected, 1.0e-9
      assert Distance.path_km(turning) > 2 * @leg_km

      # A path's total length does not depend on which end is walked from.
      assert Distance.path_km(Enum.reverse(turning)) == Distance.path_km(turning)
    end

    test "never reads shape_dist_traveled: coordinates are the only input" do
      # `shape_dist_traveled` is a publisher's cumulative distance, absent on
      # many feeds and with no equivalent for a trip's stop path. The only
      # argument is a list of `{lat, lon}` pairs, so a point that also carries a
      # distance cannot be measured at all — the accumulated column is not a
      # second, competing source of the same number.
      assert_raise FunctionClauseError, fn ->
        Distance.path_km([{42.0, -71.0, 0.0}, {42.01, -71.0, 1.1119}])
      end
    end
  end

  defp leg_km({from_lat, from_lon}, {to_lat, to_lon}) do
    dlat = :math.pi() / 180 * (to_lat - from_lat)
    dlon = :math.pi() / 180 * (to_lon - from_lon)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(:math.pi() / 180 * from_lat) * :math.cos(:math.pi() / 180 * to_lat) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @earth_radius_m * c / 1000
  end
end
