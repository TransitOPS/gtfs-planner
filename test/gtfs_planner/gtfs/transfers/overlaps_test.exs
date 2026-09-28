defmodule GtfsPlanner.Gtfs.Transfers.OverlapsTest do
  @moduledoc """
  Merge evidence (EV-3) for witnessed equal-specificity transfer competition.

  `Transfers.Overlaps.evaluate/2` must agree with an independent brute-force oracle
  written from the GTFS text for every pair of distinct six-field rule shapes in
  the forward and reverse shape sets and for every triple of distinct keys in the
  reduced set, and the named cases must produce their literal verdicts, including
  the four-rule joint-shadowing counterexample and its restoration.

  The universe is a two-platform station S (P1, P2) reaching destination D, served
  by two trips of route R1 (T11 at P1, T12 at P2) and two of route R2 (T21 at P1,
  T22 at P2). Expected values in the named cases are hand-derived from R6; the
  oracle comparison is what rejects missing station coverage, wrong selector
  compatibility, single-cover-only shadowing, over-applied shadowing, direction
  confusion and flags invented for rules that witness no shared trip pair.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers.Overlaps
  alias GtfsPlanner.TransferOverlapOracle

  # The station S covers itself and its two child platforms; each platform and the
  # destination cover only themselves.
  @coverage %{
    "S" => ["S", "P1", "P2"],
    "P1" => ["P1"],
    "P2" => ["P2"],
    "D" => ["D"]
  }

  # stop_time incidence as {trip_id, route_id}. S has no stop_time, because valid
  # GTFS names a station only through its children.
  @incidence %{
    "P1" => [{"T11", "R1"}, {"T21", "R2"}],
    "P2" => [{"T12", "R1"}, {"T22", "R2"}],
    "D" => [{"T11", "R1"}, {"T12", "R1"}, {"T21", "R2"}, {"T22", "R2"}]
  }

  @stops ["S", "P1", "P2"]
  @from_selectors [:any, {:route, "R1"}, {:route, "R2"}, {:trip, "T11"}, {:trip, "T12"}]
  @to_selectors [:any, {:route, "R1"}, {:trip, "T21"}]
  @reduced_from_selectors [:any, {:route, "R1"}, {:trip, "T11"}]
  @reduced_to_selectors [:any, {:route, "R2"}]
  @effects [{0, nil}, {3, nil}]

  describe "rank/1" do
    test "ranks every selector combination from the most to the least specific" do
      assert Overlaps.rank(
               rule({"S", "D"}, id: "both_trips", from_trip: "T11", to_trip: "T21", type: 0)
             ) == 1

      assert Overlaps.rank(
               rule({"S", "D"}, id: "trip_then_route", from_trip: "T11", to_route: "R2", type: 0)
             ) == 2

      assert Overlaps.rank(
               rule({"S", "D"}, id: "route_then_trip", from_route: "R1", to_trip: "T21", type: 0)
             ) == 2

      assert Overlaps.rank(rule({"S", "D"}, id: "one_trip_from", from_trip: "T11", type: 0)) == 3
      assert Overlaps.rank(rule({"S", "D"}, id: "one_trip_to", to_trip: "T21", type: 0)) == 3

      assert Overlaps.rank(
               rule({"S", "D"}, id: "both_routes", from_route: "R1", to_route: "R2", type: 0)
             ) == 4

      assert Overlaps.rank(rule({"S", "D"}, id: "one_route_from", from_route: "R1", type: 0)) == 5
      assert Overlaps.rank(rule({"S", "D"}, id: "one_route_to", to_route: "R2", type: 0)) == 5
      assert Overlaps.rank(rule({"S", "D"}, id: "no_selectors", type: 0)) == 6
    end

    test "counts a side that sets both a trip and a route as a trip" do
      assert Overlaps.rank(
               rule({"S", "D"},
                 id: "trip_with_route",
                 from_trip: "T11",
                 from_route: "R1",
                 type: 0
               )
             ) == 3

      assert Overlaps.rank(
               rule({"S", "D"},
                 id: "trip_with_route_both_sides",
                 from_trip: "T11",
                 from_route: "R1",
                 to_trip: "T21",
                 to_route: "R2",
                 type: 0
               )
             ) == 1

      assert Overlaps.rank(%Transfer{from_trip_id: "T11", to_trip_id: "T21"}) == 1
    end
  end

  describe "evaluate/2" do
    test "returns no edges when fewer than two rules are given" do
      assert Overlaps.evaluate([], @incidence) == %{}

      assert Overlaps.evaluate([rule({"S", "D"}, id: "A", type: 0)], @incidence) == %{}
    end

    test "flags the station-level rules that disagree on a witnessed trip pair" do
      a = rule({"S", "D"}, id: "A", from_route: "R1", type: 2, min_time: 120)
      b = rule({"S", "D"}, id: "B", to_route: "R2", type: 3)

      assert Overlaps.evaluate([a, b], @incidence) == %{"A" => ["B"], "B" => ["A"]}
    end

    test "a rank-4 rule covering the same witness pairs removes the flag" do
      a = rule({"S", "D"}, id: "A", from_route: "R1", type: 2, min_time: 120)
      b = rule({"S", "D"}, id: "B", to_route: "R2", type: 3)
      c = rule({"S", "D"}, id: "C", from_route: "R1", to_route: "R2", type: 2, min_time: 300)

      assert Overlaps.evaluate([a, b, c], @incidence) == %{}
    end

    test "two better platform rules shadow the flag jointly and one removal restores it" do
      a = rule({"S", "D"}, id: "A", from_route: "R1", type: 2, min_time: 120)
      b = rule({"S", "D"}, id: "B", to_route: "R2", type: 3)
      p1 = rule({"P1", "D"}, id: "P1", from_route: "R1", to_route: "R2", type: 2, min_time: 120)
      p2 = rule({"P2", "D"}, id: "P2", from_route: "R1", to_route: "R2", type: 2, min_time: 120)

      assert Overlaps.evaluate([a, b, p1, p2], @incidence) == %{}

      # P2's arrival trip witnesses the conflict again once its shadowing rule is gone.
      assert Overlaps.evaluate([a, b, p1], @incidence) == %{"A" => ["B"], "B" => ["A"]}
    end

    test "opposite directions and agreeing effects never compete" do
      forward = rule({"S", "D"}, id: "A", type: 0)
      backward = rule({"D", "S"}, id: "B", type: 3)

      assert Overlaps.evaluate([forward, backward], @incidence) == %{}

      agreeing_from = rule({"S", "D"}, id: "A", from_route: "R1", type: 3)
      agreeing_to = rule({"S", "D"}, id: "B", to_route: "R2", type: 3)

      assert Overlaps.evaluate([agreeing_from, agreeing_to], @incidence) == %{}
    end

    test "equal specificity with different minimum times competes" do
      short = rule({"S", "D"}, id: "A", from_route: "R1", type: 2, min_time: 120)
      long = rule({"S", "D"}, id: "B", from_route: "R1", type: 2, min_time: 180)

      assert Overlaps.evaluate([short, long], @incidence) == %{"A" => ["B"], "B" => ["A"]}
    end

    test "a station rule competes with a platform rule of equal rank" do
      station = rule({"S", "D"}, id: "A", from_route: "R1", type: 0)
      platform = rule({"P1", "D"}, id: "B", from_route: "R1", type: 3)

      assert Overlaps.evaluate([station, platform], @incidence) == %{"A" => ["B"], "B" => ["A"]}
    end

    test "mixed trip and route selectors of rank 2 compete" do
      trip_then_route = rule({"S", "D"}, id: "A", from_trip: "T11", to_route: "R2", type: 0)
      route_then_trip = rule({"S", "D"}, id: "B", from_route: "R1", to_trip: "T21", type: 3)

      assert Overlaps.evaluate([trip_then_route, route_then_trip], @incidence) ==
               %{"A" => ["B"], "B" => ["A"]}
    end

    test "rules that witness no shared trip pair compete with nothing" do
      unknown_trip = rule({"S", "D"}, id: "A", from_trip: "T99", type: 0)
      trip_not_at_stop = rule({"P1", "D"}, id: "B", from_trip: "T12", type: 3)

      mismatched_trip_and_route =
        rule({"S", "D"}, id: "C", from_route: "R2", from_trip: "T11", type: 3)

      assert Overlaps.evaluate(
               [unknown_trip, trip_not_at_stop, mismatched_trip_and_route],
               @incidence
             ) ==
               %{}
    end

    test "rules that witness no shared trip pair never shadow a real conflict" do
      a = rule({"S", "D"}, id: "A", from_route: "R1", type: 2, min_time: 120)
      b = rule({"S", "D"}, id: "B", to_route: "R2", type: 3)
      unknown_trip = rule({"S", "D"}, id: "C", from_trip: "T99", type: 0)
      trip_not_at_stop = rule({"P1", "D"}, id: "D", from_trip: "T12", type: 3)

      mismatched_trip_and_route =
        rule({"S", "D"}, id: "E", from_route: "R2", from_trip: "T11", type: 3)

      rules = [a, b, unknown_trip, trip_not_at_stop, mismatched_trip_and_route]

      assert Overlaps.evaluate(rules, @incidence) == %{"A" => ["B"], "B" => ["A"]}
    end

    test "a station on the to side competes with a platform rule of equal rank" do
      station = rule({"D", "S"}, id: "A", to_route: "R2", type: 0)
      platform = rule({"D", "P2"}, id: "B", to_route: "R2", type: 3)

      assert Overlaps.evaluate([station, platform], @incidence) == %{"A" => ["B"], "B" => ["A"]}
    end
  end

  describe "evaluate/2 against the independent oracle" do
    test "matches the oracle for every pair of distinct-key shapes in the forward and reverse sets" do
      shapes = forward_shapes() ++ reverse_shapes()

      for [left, right] <- combinations(shapes, 2), left.key != right.key do
        rules = [rule_for(left, 1), rule_for(right, 2)]

        assert Overlaps.evaluate(rules, @incidence) ==
                 TransferOverlapOracle.competitors(rules, @incidence),
               "rule pair #{inspect(left)} and #{inspect(right)}"
      end
    end

    test "matches the oracle for every triple of distinct keys in the reduced set" do
      shapes = reduced_shapes()

      for [first, second, third] <- combinations(shapes, 3),
          distinct_keys?([first, second, third]) do
        rules = [rule_for(first, 1), rule_for(second, 2), rule_for(third, 3)]

        assert Overlaps.evaluate(rules, @incidence) ==
                 TransferOverlapOracle.competitors(rules, @incidence),
               "rule triple #{inspect(first)} with #{inspect(second)} with #{inspect(third)}"
      end
    end
  end

  # One shape is a six-field key plus the selector keywords that build its rule.
  defp shape(from_stop, to_stop, from_selector, to_selector, {transfer_type, min_transfer_time}) do
    {from_route, from_trip} = selector_fields(from_selector)
    {to_route, to_trip} = selector_fields(to_selector)

    %{
      key: {from_stop, to_stop, from_route, to_route, from_trip, to_trip},
      stops: {from_stop, to_stop},
      selectors: [
        from_route: from_route,
        to_route: to_route,
        from_trip: from_trip,
        to_trip: to_trip,
        type: transfer_type,
        min_time: min_transfer_time
      ]
    }
  end

  defp forward_shapes do
    for from_stop <- @stops,
        from_selector <- @from_selectors,
        to_selector <- @to_selectors,
        effect <- @effects do
      shape(from_stop, "D", from_selector, to_selector, effect)
    end
  end

  defp reverse_shapes do
    for to_stop <- @stops,
        from_selector <- @to_selectors,
        to_selector <- @from_selectors,
        effect <- @effects do
      shape("D", to_stop, from_selector, to_selector, effect)
    end
  end

  defp reduced_shapes do
    for from_stop <- @stops,
        from_selector <- @reduced_from_selectors,
        to_selector <- @reduced_to_selectors,
        effect <- @effects do
      shape(from_stop, "D", from_selector, to_selector, effect)
    end
  end

  defp rule_for(shape, id), do: rule(shape.stops, [id: id] ++ shape.selectors)

  # Builds one general rule over the fixture coverage from a stop pair and
  # keyword selectors, for example
  # `rule({"S", "D"}, id: "A", from_route: "R1", type: 2, min_time: 120)`.
  defp rule({from_stop, to_stop}, selectors) do
    %{
      id: Keyword.fetch!(selectors, :id),
      from_coverage: Map.fetch!(@coverage, from_stop),
      to_coverage: Map.fetch!(@coverage, to_stop),
      from_route_id: Keyword.get(selectors, :from_route),
      to_route_id: Keyword.get(selectors, :to_route),
      from_trip_id: Keyword.get(selectors, :from_trip),
      to_trip_id: Keyword.get(selectors, :to_trip),
      transfer_type: Keyword.fetch!(selectors, :type),
      min_transfer_time: Keyword.get(selectors, :min_time)
    }
  end

  defp selector_fields(:any), do: {nil, nil}
  defp selector_fields({:route, route_id}), do: {route_id, nil}
  defp selector_fields({:trip, trip_id}), do: {nil, trip_id}

  defp combinations(shapes, 2) do
    indexed = Enum.with_index(shapes)

    for {left, index} <- indexed, {right, other} <- indexed, other > index, do: [left, right]
  end

  defp combinations(shapes, 3) do
    indexed = Enum.with_index(shapes)

    for {first, first_index} <- indexed,
        {second, second_index} <- indexed,
        second_index > first_index,
        {third, third_index} <- indexed,
        third_index > second_index do
      [first, second, third]
    end
  end

  defp distinct_keys?(shapes), do: shapes |> Enum.uniq_by(& &1.key) |> length() == 3
end
