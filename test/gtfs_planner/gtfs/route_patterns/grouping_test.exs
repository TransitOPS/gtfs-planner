defmodule GtfsPlanner.Gtfs.RoutePatterns.GroupingTest do
  @moduledoc """
  The grouping review's rules are pure, so these cases are literals taken from
  the North Coast Transit scenario in the trip-grouping prototype: the
  September 2026 supplement's 18 full-length trips and 6 short turns, and the
  June 2026 service's four undirected stop orders.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.RoutePatterns.Grouping

  # Route 1 Coast Highway, Newport Transit Center to Lincoln City Transit
  # Center via Depoe Bay, as 13 stop IDs in A's order.
  @full_stops ~w(newport_tc bay_c agate_beach_oc alder_ave neahkahnie_shelter
                 beach way little_sitka rocky_creek_depoe otter_rock
                 gleneden_beach_killick_sunset_tavern lincoln_city_tc)
  @short_stops Enum.take(@full_stops, 7)

  @pattern_a "00000000-0000-4000-8000-00000000000a"
  @pattern_copy "00000000-0000-4000-8000-00000000000b"

  defp vector(number, opts \\ []) do
    %{
      id: "trip-#{number}",
      trip_id: "T-#{number}",
      direction_id: Keyword.get(opts, :direction_id),
      route_pattern_id: Keyword.get(opts, :route_pattern_id),
      service_id: Keyword.get(opts, :service_id, "Summer weekday supplement"),
      shape_id: Keyword.get(opts, :shape_id, "S-101-N"),
      stop_ids: Keyword.get(opts, :stop_ids, @full_stops)
    }
  end

  defp pattern(id, opts) do
    %{
      id: id,
      route_pattern_id: Keyword.get(opts, :route_pattern_id, id),
      direction_id: Keyword.get(opts, :direction_id, 0),
      stop_ids: Keyword.get(opts, :stop_ids, @full_stops),
      derivation_key: Keyword.get(opts, :derivation_key, "k-" <> id),
      linked_trip_count: Keyword.get(opts, :linked_trip_count, 0),
      label_pattern_id: Keyword.get(opts, :label_pattern_id)
    }
  end

  # The 18 undirected supplement trips run A's stops, so A decides the direction.
  test "18 vectors with A's stop list take A's direction as same endpoints" do
    vectors = Enum.map(1..18, &vector(&1))
    [group] = Grouping.group(vectors)
    patterns = [pattern(@pattern_a, linked_trip_count: 38)]

    assert group.stop_ids == @full_stops
    assert group.direction_id == nil
    assert group.trip_ids == Enum.map(1..18, &"trip-#{&1}")
    assert group.services == %{"Summer weekday supplement" => 18}

    assert Grouping.suggest_direction(group, [group], patterns) ==
             {:suggested, 0, {:same_endpoints, @pattern_a}}
  end

  # The 6 short turns are the first 7 stops of A's order, so the same pattern
  # answers with the weaker "within" reason.
  test "6 vectors on A's first 7 stops take A's direction as within" do
    vectors = Enum.map(1..6, &vector(&1, stop_ids: @short_stops, shape_id: "S-101-N-DB"))
    [group] = Grouping.group(vectors)
    patterns = [pattern(@pattern_a, linked_trip_count: 38)]

    assert group.shapes == %{"S-101-N-DB" => 6}

    assert Grouping.suggest_direction(group, [group], patterns) ==
             {:suggested, 0, {:within, @pattern_a}}
  end

  # June 2026: four undirected stop orders, no patterns. The two full orders and
  # the two short orders each pair up, so one "Which way is Direction 0?"
  # question settles each pair.
  test "four undirected stop orders and no patterns produce two matching pairs" do
    orders = [
      {"N", @full_stops},
      {"N-rev", Enum.reverse(@full_stops)},
      {"S", @short_stops},
      {"S-rev", Enum.reverse(@short_stops)}
    ]

    vectors =
      for {label, stops} <- orders, number <- 1..4 do
        vector("#{label}#{number}", stop_ids: stops, service_id: "Weekday", shape_id: "S-101-N")
      end

    groups = Grouping.group(vectors)
    assert length(groups) == 4

    suggestions = Map.new(groups, &{&1.stop_ids, Grouping.suggest_direction(&1, groups, [])})

    assert {:paired, full_key} = suggestions[@full_stops]
    assert suggestions[Enum.reverse(@full_stops)] == {:paired, full_key}

    assert {:paired, short_key} = suggestions[@short_stops]
    assert suggestions[Enum.reverse(@short_stops)] == {:paired, short_key}
    refute full_key == short_key
  end

  # A group that shares only the Newport terminal with A answers neither rule, so
  # the editor is asked rather than given a guess.
  test "a group sharing only its first stop with A gets no suggestion" do
    stops = ["newport_tc", "bay_c", "depoe_bay_market"]
    [group] = Grouping.group([vector(1, stop_ids: stops)])
    patterns = [pattern(@pattern_a, linked_trip_count: 38)]

    assert Grouping.suggest_direction(group, [group], patterns) == :none
  end

  # A hand-made copy is a real second choice, never the target.
  test "candidates prefer the derived pattern over the hand-made copy" do
    [group] = Grouping.group([vector(1)])

    copy =
      pattern(@pattern_copy,
        derivation_key: nil,
        linked_trip_count: 0,
        route_pattern_id: "B-copy"
      )

    original = pattern(@pattern_a, linked_trip_count: 38, route_pattern_id: "A")

    assert Grouping.candidates(group, 0, [copy, original]) == [original, copy]
  end

  test "candidates are empty for another direction and are a stable order" do
    [group] = Grouping.group([vector(1)])

    original = pattern(@pattern_a, linked_trip_count: 38, route_pattern_id: "A")

    other_direction =
      pattern(@pattern_copy, direction_id: 1, derivation_key: nil, route_pattern_id: "B")

    assert Grouping.candidates(group, 1, [original, other_direction]) == [other_direction]
  end

  test "a label child is answered by its owner" do
    stops = Enum.take(@full_stops, 11)
    [group] = Grouping.group([vector(1, stop_ids: stops)])

    owner = pattern(@pattern_a, linked_trip_count: 38, stop_ids: stops)

    child =
      pattern(@pattern_copy, linked_trip_count: 6, stop_ids: stops, label_pattern_id: @pattern_a)

    assert Grouping.suggest_direction(group, [group], [child, owner]) ==
             {:suggested, 0, {:same_endpoints, @pattern_a}}
  end

  describe "timing_name/2" do
    test "names a timing after its one service, adding a number when taken" do
      assert Grouping.timing_name(["Summer weekday supplement"], MapSet.new()) ==
               "Summer weekday supplement"

      assert Grouping.timing_name(
               ["Summer weekday supplement"],
               MapSet.new(["Summer weekday supplement"])
             ) ==
               "Summer weekday supplement 2"

      taken = MapSet.new(["Summer weekday supplement", "Summer weekday supplement 2"])

      assert Grouping.timing_name(["Summer weekday supplement"], taken) ==
               "Summer weekday supplement 3"
    end

    test "joins exactly two services and falls back otherwise" do
      assert Grouping.timing_name(["Weekday", "Saturday"], MapSet.new()) == "Weekday and Saturday"

      assert Grouping.timing_name(["Weekday", "Saturday"], MapSet.new(["Weekday and Saturday"])) ==
               "Weekday and Saturday 2"

      assert Grouping.timing_name([], MapSet.new()) == :fallback

      assert Grouping.timing_name(["Weekday", "Saturday", "Sunday"], MapSet.new()) == :fallback
    end
  end

  describe "fingerprint/1" do
    defp row(id, opts \\ []) do
      %{
        id: id,
        pattern_derivation_state: "left_out",
        route_pattern_id: Keyword.get(opts, :route_pattern_id),
        timed_pattern_id: Keyword.get(opts, :timed_pattern_id),
        direction_id: Keyword.get(opts, :direction_id),
        updated_at: ~U[2026-09-02 00:00:00Z]
      }
    end

    test "ignores row order" do
      rows = [row("a"), row("b"), row("c")]

      assert Grouping.fingerprint(rows) == Grouping.fingerprint(Enum.shuffle(rows))
    end

    test "changes when a linkage field changes with updated_at unchanged" do
      base = Grouping.fingerprint([row("a"), row("b")])

      assert Grouping.fingerprint([row("a", route_pattern_id: "A"), row("b")]) != base
      assert Grouping.fingerprint([row("a", direction_id: 0), row("b")]) != base
      assert Grouping.fingerprint([row("a", timed_pattern_id: @pattern_a), row("b")]) != base

      assert Grouping.fingerprint([row("a", pattern_derivation_state: "linked"), row("b")]) !=
               base
    end
  end
end
