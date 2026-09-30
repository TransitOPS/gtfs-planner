defmodule GtfsPlanner.Gtfs.PatternComparison.Alignment do
  @moduledoc """
  Pure stop-visit alignment for the pattern comparison read (`R1`-`R4`).

  - `R1` Rows are visits. Every visit of each pattern appears exactly once, in that pattern's
    order; repeated stops are never collapsed by stop id.
  - `R2` Matching and order. Only equal stop ids share a row; there is no substitution. The score
    is match `+10`, same visit ordinal `+1`, gap open `-3`, gap extend `0`. The traceback is
    deterministic: in a stretch where both patterns have their own rows, A's rows come first,
    then B's. Among equal-score alignments the earlier A position is preferred, so a stop that
    occurs once in each pattern in compatible order is matched.
  - `R3` Moved. After the traceback, each unmatched A visit is paired with the first unpaired
    unmatched B visit of the same stop id, in A order. Both rows carry `moved_to`, a zero-based
    index into the returned rows, pointing at each other.
  - `R4` Opposite direction. `opposite?/2` is true when aligning A with reversed B shares more
    rows than aligning A with B, and that is at least 60% of `min(length(a), length(b))`, rounded
    up. Callers reverse B only when the URL asks for it; this module only reports the flag.

  Alignment costs O(n*m) over three integer matrices (match, A-only row, B-only row). The assumed
  ceiling is 200 x 200 visits; beyond that the upgrade path is banded alignment. The module is
  pure: it touches no Repo, Ecto query, or process state.
  """

  @match 10
  @visit_match 1
  @gap_open {-3, 0}
  @negative {-1_000_000, 0}

  @type row :: %{
          type: :same | :a | :b,
          a_pos: pos_integer() | nil,
          b_pos: pos_integer() | nil,
          stop_id: String.t(),
          moved_to: non_neg_integer() | nil
        }

  @doc """
  Aligns two ordered lists of stop visits into rows as described by `R1`-`R3`.
  """
  @spec align([String.t()], [String.t()]) :: [row()]
  def align(a, b) when is_list(a) and is_list(b) do
    a = List.to_tuple(a)
    b = List.to_tuple(b)
    n = tuple_size(a)
    m = tuple_size(b)

    matrices = score_matrices(a, b)
    state = start_state(matrices, n, m)
    rows = traceback(n, m, state, matrices, a, b, [])

    pair_moves(rows)
  end

  @doc """
  Reports whether `b` is `a` in the opposite direction as described by `R4`.
  """
  @spec opposite?([String.t()], [String.t()]) :: boolean()
  def opposite?(a, b) when is_list(a) and is_list(b) do
    reversed_matches = a |> align(Enum.reverse(b)) |> same_count()
    forward_matches = a |> align(b) |> same_count()
    threshold = div(3 * min(length(a), length(b)) + 4, 5)

    reversed_matches > forward_matches and reversed_matches >= threshold
  end

  defp same_count(rows), do: Enum.count(rows, &(&1.type == :same))

  # Scores are {primary, secondary} integer tuples. The primary component is the R2 score; the
  # secondary component prefers matching earlier A positions among equal-score alignments. Only
  # the traceback chooses between candidates, so the secondary only decides primary ties.
  defp score_matrices(a, b) do
    n = tuple_size(a)
    m = tuple_size(b)
    ord_a = ordinals(a)
    ord_b = ordinals(b)

    m0 = List.duplicate(@negative, m + 1) |> List.replace_at(0, {0, 0}) |> List.to_tuple()
    x0 = List.duplicate(@negative, m + 1) |> List.to_tuple()
    y0 = build_row(List.duplicate(@gap_open, m), @negative)

    {m_rows, x_rows, y_rows} =
      Enum.reduce(1..n//1, {[m0], [x0], [y0]}, fn i, {m_rows, x_rows, y_rows} ->
        previous = {hd(m_rows), hd(x_rows), hd(y_rows)}
        {m_row, x_row, y_row} = score_row(i, a, b, ord_a, ord_b, previous)
        {[m_row | m_rows], [x_row | x_rows], [y_row | y_rows]}
      end)

    {
      to_matrix(m_rows),
      to_matrix(x_rows),
      to_matrix(y_rows)
    }
  end

  defp to_matrix(reversed_rows), do: reversed_rows |> Enum.reverse() |> List.to_tuple()

  defp score_row(i, a, b, ord_a, ord_b, {previous_m, previous_x, previous_y}) do
    a_stop = elem(a, i - 1)
    a_ordinal = elem(ord_a, i - 1)
    m = tuple_size(b)
    visit_position = tuple_size(a) - i + 1

    {m_values, x_values, y_values, _left} =
      Enum.reduce(1..m//1, {[], [], [], {@negative, @gap_open, @negative}}, fn j,
                                                                               {m_values,
                                                                                x_values,
                                                                                y_values,
                                                                                {m_left, x_left,
                                                                                 y_left}} ->
        neighbours = {elem(previous_m, j - 1), elem(previous_x, j - 1), elem(previous_y, j - 1)}
        above = {elem(previous_m, j), elem(previous_x, j), elem(previous_y, j)}

        m_value =
          match_value(
            a_stop,
            elem(b, j - 1),
            a_ordinal == elem(ord_b, j - 1),
            visit_position,
            neighbours
          )

        x_value = a_gap_value(above)
        y_value = b_gap_value({m_left, x_left, y_left})

        {[m_value | m_values], [x_value | x_values], [y_value | y_values],
         {m_value, x_value, y_value}}
      end)

    {build_row(m_values, @negative), build_row(x_values, @gap_open),
     build_row(y_values, @negative)}
  end

  defp match_value(a_stop, b_stop, visit_ordinal?, visit_position, {m, x, y}) do
    if a_stop == b_stop do
      bonus = if visit_ordinal?, do: @match + @visit_match, else: @match
      add(max_of_three(m, x, y), {bonus, visit_position})
    else
      @negative
    end
  end

  defp a_gap_value({m, x, y}), do: max_of_three(add(m, @gap_open), x, add(y, @gap_open))

  defp b_gap_value({m, x, y}), do: max_of_three(add(m, @gap_open), y, add(x, @gap_open))

  defp build_row(reversed_values, edge),
    do: [edge | Enum.reverse(reversed_values)] |> List.to_tuple()

  defp start_state({m_mat, x_mat, y_mat}, n, m) do
    best_state([
      {:match, get(m_mat, n, m)},
      {:b_only, get(y_mat, n, m)},
      {:a_only, get(x_mat, n, m)}
    ])
  end

  defp traceback(0, 0, _state, _matrices, _a, _b, rows), do: rows

  defp traceback(i, j, :match, {m_mat, x_mat, y_mat} = matrices, a, b, rows) do
    row = %{type: :same, a_pos: i, b_pos: j, stop_id: elem(a, i - 1), moved_to: nil}

    state =
      best_state([
        {:match, get(m_mat, i - 1, j - 1)},
        {:b_only, get(y_mat, i - 1, j - 1)},
        {:a_only, get(x_mat, i - 1, j - 1)}
      ])

    traceback(i - 1, j - 1, state, matrices, a, b, [row | rows])
  end

  defp traceback(i, j, :a_only, {m_mat, x_mat, y_mat} = matrices, a, b, rows) do
    row = %{type: :a, a_pos: i, b_pos: nil, stop_id: elem(a, i - 1), moved_to: nil}

    state =
      best_state([
        {:a_only, get(x_mat, i - 1, j)},
        {:match, add(get(m_mat, i - 1, j), @gap_open)},
        {:b_only, add(get(y_mat, i - 1, j), @gap_open)}
      ])

    traceback(i - 1, j, state, matrices, a, b, [row | rows])
  end

  defp traceback(i, j, :b_only, {m_mat, x_mat, y_mat} = matrices, a, b, rows) do
    row = %{type: :b, a_pos: nil, b_pos: j, stop_id: elem(b, j - 1), moved_to: nil}

    state =
      best_state([
        {:b_only, get(y_mat, i, j - 1)},
        {:a_only, add(get(x_mat, i, j - 1), @gap_open)},
        {:match, add(get(m_mat, i, j - 1), @gap_open)}
      ])

    traceback(i, j - 1, state, matrices, a, b, [row | rows])
  end

  # The candidate list is ordered by traceback preference; the first candidate with the greatest
  # score wins, so exact ties keep the prepared order.
  defp best_state([{state, value} | rest]) do
    rest
    |> Enum.reduce({state, value}, fn {candidate, candidate_value}, {best, best_value} ->
      if candidate_value > best_value, do: {candidate, candidate_value}, else: {best, best_value}
    end)
    |> elem(0)
  end

  defp pair_moves(rows) do
    indexed = Enum.with_index(rows)
    b_only = for {row, index} <- indexed, row.type == :b, do: {row.stop_id, index}
    a_only = for {row, index} <- indexed, row.type == :a, do: {row.stop_id, index}

    {pairs, _taken} = Enum.reduce(a_only, {%{}, MapSet.new()}, &pair_a_visit(&1, &2, b_only))

    Enum.map(indexed, fn {row, index} -> %{row | moved_to: Map.get(pairs, index)} end)
  end

  defp pair_a_visit({stop_id, index}, {pairs, taken}, b_only) do
    case Enum.find(b_only, &match_b_visit?(&1, stop_id, taken)) do
      nil ->
        {pairs, taken}

      {_stop_id, b_index} ->
        {pairs |> Map.put(index, b_index) |> Map.put(b_index, index), MapSet.put(taken, b_index)}
    end
  end

  defp match_b_visit?({b_stop_id, b_index}, stop_id, taken) do
    b_stop_id == stop_id and not MapSet.member?(taken, b_index)
  end

  defp ordinals(sequence) do
    {ordinals, _counts} =
      Enum.reduce(Tuple.to_list(sequence), {[], %{}}, fn stop_id, {ordinals, counts} ->
        ordinal = Map.get(counts, stop_id, 0) + 1
        {[ordinal | ordinals], Map.put(counts, stop_id, ordinal)}
      end)

    ordinals |> Enum.reverse() |> List.to_tuple()
  end

  defp get(matrix, i, j), do: matrix |> elem(i) |> elem(j)

  defp add({primary, secondary}, {delta_primary, delta_secondary}) do
    {primary + delta_primary, secondary + delta_secondary}
  end

  defp max_of_three(a, b, c), do: max(max(a, b), c)
end
