defmodule GtfsPlanner.Gtfs.PatternComparison.OverviewRowsTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.PatternComparison.Alignment

  describe "overview_rows/1" do
    test "lays a short turn and a deviation out against the reference pattern" do
      result =
        Alignment.overview_rows([
          {"full", ~w(S1 S2 S3 S4 S5 S6)},
          {"short", ~w(S1 S2 S3 S4)},
          {"deviation", ~w(S1 S2 X Y S4 S5 S6)}
        ])

      assert stop_ids(result.rows) == ~w(S1 S2 S3 X Y S4 S5 S6)

      assert served(result.rows) == [
               %{"full" => 1, "short" => 1, "deviation" => 1},
               %{"full" => 2, "short" => 2, "deviation" => 2},
               %{"full" => 3, "short" => 3},
               %{"deviation" => 3},
               %{"deviation" => 4},
               %{"full" => 4, "short" => 4, "deviation" => 5},
               %{"full" => 5, "deviation" => 6},
               %{"full" => 6, "deviation" => 7}
             ]

      assert visits(result.rows, "full") == [1, 2, 3, 4, 5, 6]
      assert visits(result.rows, "short") == [1, 2, 3, 4]
      assert visits(result.rows, "deviation") == [1, 2, 3, 4, 5, 6, 7]

      assert result.spans == %{"full" => {0, 7}, "short" => {0, 5}, "deviation" => {0, 7}}
    end

    test "keeps one row per visit of a repeated stop" do
      result =
        Alignment.overview_rows([
          {"loop", ~w(S1 S2 S3 S1)},
          {"loop-short", ~w(S1 S3 S1)}
        ])

      assert stop_ids(result.rows) == ~w(S1 S2 S3 S1)

      assert served(result.rows) == [
               %{"loop" => 1, "loop-short" => 1},
               %{"loop" => 2},
               %{"loop" => 3, "loop-short" => 2},
               %{"loop" => 4, "loop-short" => 3}
             ]

      assert visits(result.rows, "loop") == [1, 2, 3, 4]
      assert visits(result.rows, "loop-short") == [1, 2, 3]
      assert result.spans == %{"loop" => {0, 3}, "loop-short" => {0, 3}}
    end

    test "spans each pattern from its first to its last served row" do
      result =
        Alignment.overview_rows([
          {"full", ~w(S1 S2 S3 S4 S5 S6)},
          {"late", ~w(S2 S3 S4 S5 S6)},
          {"short", ~w(S1 S2 S3 S4)}
        ])

      assert stop_ids(result.rows) == ~w(S1 S2 S3 S4 S5 S6)
      assert visits(result.rows, "late") == [1, 2, 3, 4, 5]
      assert visits(result.rows, "short") == [1, 2, 3, 4]

      assert result.spans == %{"full" => {0, 5}, "late" => {1, 5}, "short" => {0, 3}}
    end
  end

  defp stop_ids(rows), do: Enum.map(rows, & &1.stop_id)

  defp served(rows), do: Enum.map(rows, & &1.served)

  # Visits arrive in row order, so the positions each pattern serves read low to high.
  defp visits(rows, id) do
    Enum.flat_map(rows, fn row -> List.wrap(row.served[id]) end)
  end
end
