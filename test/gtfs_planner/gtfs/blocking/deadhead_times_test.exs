defmodule GtfsPlanner.Gtfs.Blocking.DeadheadTimesTest do
  @moduledoc """
  Merge evidence (EV-6) for CL-6 / R1: a driving-time lookup answers the entered
  value for exactly one direction, the estimate follows the R1 formula, and a
  missing coordinate gives `:unknown` rather than `0`.

  Every expectation is derived independently of the module under test. The
  expected great-circle distance is computed here from the haversine formula with
  the same 6 371 000 m earth radius the production helper uses, never by calling
  `StationReport2.Helpers.haversine/4`, and the expected minutes are R1's formula
  over that independently computed distance. The two fixed points are about
  5.0038 km apart, so the default 30 km/h and 1.3 circuity give
  `round(5003.772 × 1.3 ÷ 500) = 13` minutes — a value checkable by hand from the
  published formula.

  The module under test is pure: it reads its arguments and touches no database,
  clock, file or network, so these cases run in the local ExUnit process with no
  sandbox, no fixtures and no cleanup.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/deadhead_times_test.exs`. This test
  establishes the formula, the lookup precedence and the ref encoding; it says
  nothing about how accurate a straight-line estimate is against real roads.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes

  # Two fixed points on one meridian, about 5.0038 km apart.
  @a {42.0, -71.0}
  @b {42.045, -71.0}
  @straight_line_m 5003.772

  # R1 at the version defaults: 30 km/h is 500 m per minute, circuity 1.3. The
  # speed reaches the module as `Context.deadhead_speed_kmh`, whose default is 30.
  @circuity 1.3
  @metres_per_minute 500.0
  @estimated_minutes 13

  @garage_uuid "0f2b3a4c-5d6e-4f70-8a91-b2c3d4e5f607"
  @earth_radius_m 6_371_000.0

  describe "estimate_minutes/3" do
    test "estimates the R1 minutes for two points about 5 km apart" do
      assert_in_delta haversine_m(@a, @b), @straight_line_m, 0.01

      assert DeadheadTimes.estimate_minutes(@a, @b, context()) ==
               round(haversine_m(@a, @b) * @circuity / @metres_per_minute)

      assert DeadheadTimes.estimate_minutes(@a, @b, context()) == @estimated_minutes
    end

    test "is symmetric: the estimate does not depend on direction" do
      forward = DeadheadTimes.estimate_minutes(@a, @b, context())
      backward = DeadheadTimes.estimate_minutes(@b, @a, context())

      assert forward == backward
      assert forward == @estimated_minutes
    end

    test "halves the unrounded estimate at double the speed and scales with circuity" do
      twice_as_fast = context(deadhead_speed_kmh: 60)
      double_circuity = context(deadhead_circuity: 2.0)

      # 1000 m per minute at 60 km/h: exactly half of 13, and 6.5 rounds to 7.
      assert DeadheadTimes.estimate_minutes(@a, @b, twice_as_fast) ==
               round(haversine_m(@a, @b) * @circuity / (@metres_per_minute * 2))

      assert DeadheadTimes.estimate_minutes(@a, @b, twice_as_fast) == 7

      assert DeadheadTimes.estimate_minutes(@a, @b, double_circuity) ==
               round(haversine_m(@a, @b) * 2.0 / @metres_per_minute)

      assert DeadheadTimes.estimate_minutes(@a, @b, double_circuity) == 20
    end

    test "is :unknown without a point at either end, never 0" do
      for {from, to} <- [{nil, @b}, {@a, nil}, {nil, nil}] do
        assert DeadheadTimes.estimate_minutes(from, to, context()) == :unknown
      end
    end
  end

  describe "lookup/5" do
    test "prefers the entered value for the exact direction and estimates the reverse" do
      from_ref = {:stop, "A"}
      to_ref = {:stop, "B"}
      garage_ref = {:garage, @garage_uuid}

      # Two entered pairs, read by the exact ordered key: the garage pair must
      # never answer a stop pair.
      entered =
        context(entered_minutes: %{{from_ref, to_ref} => 9, {garage_ref, from_ref} => 4})

      assert DeadheadTimes.lookup(from_ref, @a, to_ref, @b, entered) ==
               %{minutes: 9, source: :entered}

      # The reverse direction has no entered value, so the symmetric estimate
      # answers: an entered 9 for A→B never answers B→A.
      assert DeadheadTimes.lookup(to_ref, @b, from_ref, @a, entered) ==
               %{minutes: @estimated_minutes, source: :estimated}
    end

    test "estimates both directions when nothing is entered" do
      context = context()

      assert DeadheadTimes.lookup({:stop, "A"}, @a, {:stop, "B"}, @b, context) ==
               %{minutes: @estimated_minutes, source: :estimated}

      assert DeadheadTimes.lookup({:garage, @garage_uuid}, @a, {:stop, "B"}, @b, context) ==
               %{minutes: @estimated_minutes, source: :estimated}
    end

    test "returns an entered 0 as entered rather than treating it as missing" do
      from_ref = {:stop, "A"}
      to_ref = {:stop, "B"}
      entered = context(entered_minutes: %{{from_ref, to_ref} => 0})

      assert DeadheadTimes.lookup(from_ref, @a, to_ref, @b, entered) ==
               %{minutes: 0, source: :entered}

      # Still directional: the zero does not become the reverse direction's answer
      # either, and the reverse direction keeps its own estimate.
      assert DeadheadTimes.lookup(to_ref, @b, from_ref, @a, entered) ==
               %{minutes: @estimated_minutes, source: :estimated}
    end

    test "is unknown without a point at either end, never 0" do
      from_ref = {:stop, "A"}
      to_ref = {:stop, "B"}
      context = context()

      assert DeadheadTimes.lookup(from_ref, nil, to_ref, @b, context) ==
               %{minutes: nil, source: :unknown}

      assert DeadheadTimes.lookup(from_ref, @a, to_ref, nil, context) ==
               %{minutes: nil, source: :unknown}
    end
  end

  describe "encode_ref/1 and decode_ref/1" do
    test "round-trips a stop ID containing a colon and a garage UUID" do
      for ref <- [{:stop, "A:1"}, {:stop, "Route Stop"}, {:garage, @garage_uuid}] do
        assert DeadheadTimes.decode_ref(DeadheadTimes.encode_ref(ref)) == {:ok, ref}
      end
    end

    test "encodes the two stored forms" do
      assert DeadheadTimes.encode_ref({:stop, "A:1"}) == "stop:A:1"
      assert DeadheadTimes.encode_ref({:garage, @garage_uuid}) == "garage:#{@garage_uuid}"
    end

    test "refuses anything that is not one of the two forms" do
      for ref <- ["garage:not-a-uuid", "bus:1", "stop:", "", "A:1", "garage:"] do
        assert DeadheadTimes.decode_ref(ref) == :error
      end
    end

    test "refuses to encode a garage that is not a UUID" do
      # A garage's public `garage_id` is correctable, so it must never become a
      # stored driving-time reference (CR-7).
      assert_raise ArgumentError, fn -> DeadheadTimes.encode_ref({:garage, "GAR-1"}) end
    end
  end

  describe "estimate_km/3" do
    test "returns the straight line scaled by circuity, in kilometres" do
      assert_in_delta DeadheadTimes.estimate_km(@a, @b, context()),
                      haversine_m(@a, @b) * @circuity / 1000,
                      1.0e-9

      assert_in_delta DeadheadTimes.estimate_km(@a, @b, context()), 6.5049, 0.001
    end

    test "scales with circuity and is symmetric" do
      double_circuity = context(deadhead_circuity: 2.0)

      # Circuity scales the straight line, so 2.0 is 2.0/1.3 of the 1.3 value.
      # Compared with a tolerance: the two routes to that ratio are not
      # bit-identical in binary floating point.
      assert_in_delta DeadheadTimes.estimate_km(@a, @b, double_circuity),
                      2.0 / @circuity * DeadheadTimes.estimate_km(@a, @b, context()),
                      1.0e-9

      assert DeadheadTimes.estimate_km(@b, @a, context()) ==
               DeadheadTimes.estimate_km(@a, @b, context())
    end

    test "is nil without a point at either end" do
      assert DeadheadTimes.estimate_km(nil, @b, context()) == nil
      assert DeadheadTimes.estimate_km(@a, nil, context()) == nil
    end
  end

  defp context(overrides \\ []) do
    struct!(Context, Keyword.merge([min_layover_minutes: 5], overrides))
  end

  # The haversine formula, restated here so the expected distance is derived
  # independently of `StationReport2.Helpers.haversine/4`.
  defp haversine_m({lat1, lon1}, {lat2, lon2}) do
    dlat = to_radians(lat2 - lat1)
    dlon = to_radians(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(to_radians(lat1)) * :math.cos(to_radians(lat2)) * :math.sin(dlon / 2) *
          :math.sin(dlon / 2)

    a = min(max(a, 0.0), 1.0)

    2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a)) * @earth_radius_m
  end

  defp to_radians(degrees), do: degrees * :math.pi() / 180
end
