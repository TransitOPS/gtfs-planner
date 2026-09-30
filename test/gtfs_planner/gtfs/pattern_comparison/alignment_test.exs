defmodule GtfsPlanner.Gtfs.PatternComparison.AlignmentTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.PatternComparison.Alignment

  describe "align/2" do
    test "keeps one :same row per stop for identical stop lists" do
      stops = Enum.map(1..13, &"S#{&1}")

      rows = Alignment.align(stops, stops)

      assert shape(rows) == Enum.map(1..13, &{:same, &1, &1, "S#{&1}", nil})
    end

    test "reports a replaced stop as one :a row before two :b rows" do
      a = ~w(S1 S2 S3 S4 S5 S6)
      b = ~w(S1 S2 X Y S4 S5 S6)

      assert shape(Alignment.align(a, b)) == [
               {:same, 1, 1, "S1", nil},
               {:same, 2, 2, "S2", nil},
               {:a, 3, nil, "S3", nil},
               {:b, nil, 3, "X", nil},
               {:b, nil, 4, "Y", nil},
               {:same, 4, 5, "S4", nil},
               {:same, 5, 6, "S5", nil},
               {:same, 6, 7, "S6", nil}
             ]
    end

    test "reports a short turn as :same rows followed by the extra :a rows" do
      a = ~w(S1 S2 S3 S4 S5 S6)
      b = ~w(S1 S2 S3 S4)

      assert shape(Alignment.align(a, b)) == [
               {:same, 1, 1, "S1", nil},
               {:same, 2, 2, "S2", nil},
               {:same, 3, 3, "S3", nil},
               {:same, 4, 4, "S4", nil},
               {:a, 5, nil, "S5", nil},
               {:a, 6, nil, "S6", nil}
             ]
    end

    test "reports an extension as :same rows followed by the extra :b rows" do
      a = ~w(S1 S2 S3 S4)
      b = ~w(S1 S2 S3 S4 S5 S6)

      assert shape(Alignment.align(a, b)) == [
               {:same, 1, 1, "S1", nil},
               {:same, 2, 2, "S2", nil},
               {:same, 3, 3, "S3", nil},
               {:same, 4, 4, "S4", nil},
               {:b, nil, 5, "S5", nil},
               {:b, nil, 6, "S6", nil}
             ]
    end

    test "reports skipped stops as interspersed :a rows" do
      a = ~w(S1 S2 S3 S4 S5 S6)
      b = ~w(S1 S3 S5)

      assert shape(Alignment.align(a, b)) == [
               {:same, 1, 1, "S1", nil},
               {:a, 2, nil, "S2", nil},
               {:same, 3, 2, "S3", nil},
               {:a, 4, nil, "S4", nil},
               {:same, 5, 3, "S5", nil},
               {:a, 6, nil, "S6", nil}
             ]
    end

    test "keeps every visit of a loop against a shuttle and matches both S1 visits" do
      a = ~w(S1 S2 S3 S4 S5 S1)
      b = ~w(S1 S2 S3 S2 S1)

      assert shape(Alignment.align(a, b)) == [
               {:same, 1, 1, "S1", nil},
               {:same, 2, 2, "S2", nil},
               {:same, 3, 3, "S3", nil},
               {:a, 4, nil, "S4", nil},
               {:a, 5, nil, "S5", nil},
               {:b, nil, 4, "S2", nil},
               {:same, 6, 5, "S1", nil}
             ]
    end

    test "prefers the earlier A position when a swapped unique pair ties" do
      a = ~w(T X Y T)
      b = ~w(T Y X T)

      assert shape(Alignment.align(a, b)) == [
               {:same, 1, 1, "T", nil},
               {:b, nil, 2, "Y", 3},
               {:same, 2, 3, "X", nil},
               {:a, 3, nil, "Y", 1},
               {:same, 4, 4, "T", nil}
             ]
    end

    test "pairs a stop served at different points as a linked moved pair" do
      a = ~w(S1 S2 S3 S4 S5 S1)
      b = ~w(S1 S4 S2 S3 S5 S1)

      assert shape(Alignment.align(a, b)) == [
               {:same, 1, 1, "S1", nil},
               {:b, nil, 2, "S4", 4},
               {:same, 2, 3, "S2", nil},
               {:same, 3, 4, "S3", nil},
               {:a, 4, nil, "S4", 1},
               {:same, 5, 5, "S5", nil},
               {:same, 6, 6, "S1", nil}
             ]
    end

    test "reports disjoint stop lists as all :a rows then all :b rows" do
      rows = Alignment.align(~w(S1 S2 S3), ~w(S4 S5 S6))

      assert shape(rows) == [
               {:a, 1, nil, "S1", nil},
               {:a, 2, nil, "S2", nil},
               {:a, 3, nil, "S3", nil},
               {:b, nil, 1, "S4", nil},
               {:b, nil, 2, "S5", nil},
               {:b, nil, 3, "S6", nil}
             ]

      refute Enum.any?(rows, &(&1.type == :same))
    end

    test "reports an empty B as only :a rows" do
      assert shape(Alignment.align(~w(S1 S2 S3), [])) == [
               {:a, 1, nil, "S1", nil},
               {:a, 2, nil, "S2", nil},
               {:a, 3, nil, "S3", nil}
             ]

      assert Alignment.align([], []) == []
    end
  end

  describe "opposite?/2" do
    test "detects a pattern and its own reverse" do
      a = Enum.map(1..13, &"S#{&1}")

      assert Alignment.opposite?(a, Enum.reverse(a))
      refute Alignment.opposite?(a, a)
    end

    test "does not call a short shared order opposite" do
      a = Enum.map(1..13, &"S#{&1}")
      b = ~w(X1 S2 X2 X3 S4 X4 X5 X6 X7 X8 X9 X10 X11)

      refute Alignment.opposite?(a, b)
      refute Alignment.opposite?(b, a)
    end

    test "requires the reversed share to reach 60% of the shorter pattern" do
      a = Enum.map(1..13, &"S#{&1}")
      b = ~w(S3 Z1 S2 Z2 Z3 Z4 Z5 Z6 Z7 Z8 Z9)

      # Reversed B shares two rows (S2, S3) against one forward, below ceil(0.6 * 11) = 7.
      refute Alignment.opposite?(a, b)
    end
  end

  describe "properties" do
    test "alignment invariants hold over the literal cases and 200 seeded random pairs" do
      :rand.seed(:exsss, {19, 19, 19})

      pairs = literal_pairs() ++ for(_ <- 1..200, do: {random_stops(), random_stops()})

      Enum.each(pairs, fn {a, b} ->
        rows = Alignment.align(a, b)

        assert_visits_present_once_in_order(rows, a, b)
        assert_same_rows_increasing(rows, a, b)
        assert_unique_matches_are_same(rows, a, b)
        assert_moved_links_are_symmetric(rows)
        assert Alignment.align(a, b) == rows, "align/2 is not deterministic"
      end)
    end
  end

  defp shape(rows), do: Enum.map(rows, &{&1.type, &1.a_pos, &1.b_pos, &1.stop_id, &1.moved_to})

  defp literal_pairs do
    thirteen = Enum.map(1..13, &"S#{&1}")

    [
      {thirteen, thirteen},
      {~w(S1 S2 S3 S4 S5 S6), ~w(S1 S2 X Y S4 S5 S6)},
      {~w(S1 S2 S3 S4 S5 S6), ~w(S1 S2 S3 S4)},
      {~w(S1 S2 S3 S4), ~w(S1 S2 S3 S4 S5 S6)},
      {~w(S1 S2 S3 S4 S5 S6), ~w(S1 S3 S5)},
      {~w(S1 S2 S3 S4 S5 S1), ~w(S1 S2 S3 S2 S1)},
      {~w(T X Y T), ~w(T Y X T)},
      {~w(S1 S2 S3 S4 S5 S1), ~w(S1 S4 S2 S3 S5 S1)},
      {~w(S1 S2 S3), ~w(S4 S5 S6)},
      {~w(S1 S2 S3), []},
      {thirteen, Enum.reverse(thirteen)}
    ]
  end

  defp random_stops do
    count = :rand.uniform(31) - 1

    for _ <- 1..count//1, do: "S#{:rand.uniform(12)}"
  end

  defp assert_visits_present_once_in_order(rows, a, b) do
    a_rows = Enum.filter(rows, &(&1.type in [:same, :a]))
    b_rows = Enum.filter(rows, &(&1.type in [:same, :b]))

    assert Enum.map(a_rows, & &1.stop_id) == a,
           "A visits changed for #{inspect(a)} / #{inspect(b)}: #{inspect(rows)}"

    assert Enum.map(b_rows, & &1.stop_id) == b,
           "B visits changed for #{inspect(a)} / #{inspect(b)}: #{inspect(rows)}"

    assert Enum.map(a_rows, & &1.a_pos) == Enum.to_list(1..length(a)//1)
    assert Enum.map(b_rows, & &1.b_pos) == Enum.to_list(1..length(b)//1)
  end

  defp assert_same_rows_increasing(rows, a, b) do
    same = Enum.filter(rows, &(&1.type == :same))

    Enum.each(same, fn row ->
      assert row.stop_id == Enum.at(a, row.a_pos - 1), "same row does not match its A visit"
      assert row.stop_id == Enum.at(b, row.b_pos - 1), "same row does not match its B visit"
    end)

    a_positions = Enum.map(same, & &1.a_pos)
    b_positions = Enum.map(same, & &1.b_pos)

    assert a_positions == Enum.sort(a_positions) and a_positions == Enum.uniq(a_positions)
    assert b_positions == Enum.sort(b_positions) and b_positions == Enum.uniq(b_positions)
  end

  # The anchor invariant, in the form the R2 score enforces: a stop occurring exactly once in
  # each pattern is always matched unless some matched row crosses it (promoting an uncrossed
  # pair gains a match while splitting at most one gap run per side, so an optimal alignment
  # cannot leave it unmatched).
  defp assert_unique_matches_are_same(rows, a, b) do
    matches = Enum.filter(rows, &(&1.type == :same))
    matched = MapSet.new(Enum.map(matches, & &1.stop_id))

    for {a_pos, b_pos, stop_id} <- unique_pairs(a, b), not MapSet.member?(matched, stop_id) do
      assert Enum.any?(matches, &crosses?(&1, a_pos, b_pos)),
             "unique stop #{stop_id} at A#{a_pos}/B#{b_pos} is unmatched with no crossing match"
    end
  end

  defp unique_pairs(a, b) do
    for stop_id <- Enum.uniq(a),
        Enum.count(a, &(&1 == stop_id)) == 1,
        Enum.count(b, &(&1 == stop_id)) == 1 do
      {Enum.find_index(a, &(&1 == stop_id)) + 1, Enum.find_index(b, &(&1 == stop_id)) + 1,
       stop_id}
    end
  end

  defp crosses?(row, a_pos, b_pos) do
    (row.a_pos < a_pos and row.b_pos > b_pos) or (row.a_pos > a_pos and row.b_pos < b_pos)
  end

  defp assert_moved_links_are_symmetric(rows) do
    Enum.each(Enum.with_index(rows), fn {row, index} ->
      if row.type == :same do
        assert is_nil(row.moved_to), "a :same row must not carry moved_to"
      end

      if row.moved_to do
        other = Enum.at(rows, row.moved_to)

        assert other, "moved_to #{row.moved_to} is outside the row list"
        assert other.stop_id == row.stop_id
        assert other.type != row.type
        assert other.moved_to == index, "moved_to is not symmetric"
      end
    end)
  end
end
