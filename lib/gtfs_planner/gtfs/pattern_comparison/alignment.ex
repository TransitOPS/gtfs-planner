defmodule GtfsPlanner.Gtfs.PatternComparison.Alignment do
  @moduledoc """
  Pure stop-visit alignment for the pattern comparison read (`R1`-`R5`).

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
  - `R5` Running times. An anchor is a `:same` row whose timing rows on both sides carry an
    arrival and a departure offset. A segment runs from one anchor to the next; its time per side
    is the arrival offset at the end anchor minus the departure offset at the start anchor, so
    time stopped in between counts and a wait at either anchor does not. A `:same` row missing a
    time on either side is untimed and is not an anchor. Waits at an anchor that is neither the
    first nor the last visit of either pattern are reported when they differ.
  - `AC-18` Differences. `differences/2` derives the ordered summary items: stop stretches with
    their bounding anchors and segment, moved pairs (collapsed above three), boarding changes and
    the largest timing changes, plus the count of smaller timing differences. `detail` stays
    data-only; the components render the sentences.

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

  @type timing_row :: %{
          position: pos_integer(),
          arrival_offset: integer() | nil,
          departure_offset: integer() | nil,
          timepoint: integer() | nil,
          pickup_type: integer() | nil,
          drop_off_type: integer() | nil
        }

  @type segment :: %{
          from: non_neg_integer(),
          to: non_neg_integer(),
          a_secs: integer() | nil,
          b_secs: integer() | nil,
          diff: integer() | nil,
          same_stops?: boolean()
        }

  @type difference :: %{
          kind: :stops | :moved | :boarding | :time,
          rows: [non_neg_integer()],
          frame: [non_neg_integer()],
          detail: map()
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

  @doc """
  Computes running-time segments, waits and untimed shared stops for aligned `rows` (`R5`).

  An anchor is a `:same` row whose timing rows on both sides carry an arrival and a departure
  offset. A segment runs from one anchor to the next: its `a_secs`/`b_secs` are the arrival offset
  at the end anchor minus the departure offset at the start anchor, so time stopped in between
  counts and a wait at either anchor does not. A `:same` row missing a time on either side is
  collected in `untimed` and is not an anchor.

  `from`/`to`, the entries of `untimed` and the keys of `waits` are zero-based indexes into `rows`.
  `waits` holds `{a_wait, b_wait}` for anchors that are neither the first nor the last visit of
  either pattern and whose waits differ. Nil timing rows on either side return empty results. The
  timing rows are indexed by the rows' `a_pos`/`b_pos`; a missing timing row reads as untimed
  rather than raising.
  """
  @spec segments([row()], [timing_row()] | nil, [timing_row()] | nil) :: %{
          segments: [segment()],
          untimed: MapSet.t(non_neg_integer()),
          waits: %{non_neg_integer() => {integer(), integer()}}
        }
  def segments(rows, rows_a, rows_b) when is_list(rows) do
    if is_nil(rows_a) or is_nil(rows_b) do
      %{segments: [], untimed: MapSet.new(), waits: %{}}
    else
      build_segments(rows, List.to_tuple(rows_a), List.to_tuple(rows_b))
    end
  end

  @doc """
  Derives the ordered difference items for the comparison summary (`AC-18`).

  `segments` is the segment list from `segments/3`; `a_rows`/`b_rows` are the chosen timing rows
  per side. A `nil` timing side also disables boarding items, which compare pickup/drop-off types
  and so need both timing rows.

  - `:stops` for each maximal non-`:same` stretch, excluding moved rows. `detail` carries the
    bounding anchor stop ids (`before`/`after`, `nil` at an end), the own stops of the stretch
    (`a_only`/`b_only`) and the segment between the anchors (`segment`).
  - `:moved` for each pair, or one collapsed item with `detail.count` pairs when there are more
    than three; the collapsed item's rows cover both rows of every pair.
  - `:boarding` for each `:same` row whose pickup or drop-off type differs between the timing
    rows, with both sides' values in `detail`.
  - `:time` for the largest three same-stop segments with `abs(diff) >= 60`. `smaller_timing`
    counts the remaining non-zero timing differences: sub-minute ones and qualifying ones beyond
    the largest three.

  Items are sorted by their smallest row index; `frame` holds the rows to highlight and frame on
  the map. `detail` is data-only: the components render the sentences.
  """
  @spec differences([row()], %{
          segments: [segment()],
          a_rows: [timing_row()] | nil,
          b_rows: [timing_row()] | nil
        }) :: %{items: [difference()], smaller_timing: non_neg_integer()}
  def differences(rows, %{segments: segments, a_rows: a_rows, b_rows: b_rows})
      when is_list(rows) do
    stops = stop_items(Enum.with_index(rows), segments)
    moved = moved_items(rows)
    boarding = boarding_items(rows, timing_tuple(a_rows), timing_tuple(b_rows))
    {timing, smaller_timing} = timing_items(segments)

    %{
      items: sort_by_first_row(stops ++ moved ++ boarding ++ timing),
      smaller_timing: smaller_timing
    }
  end

  defp same_count(rows), do: Enum.count(rows, &(&1.type == :same))

  defp timing_tuple(nil), do: nil
  defp timing_tuple(rows), do: List.to_tuple(rows)

  defp sort_by_first_row(items), do: Enum.sort_by(items, fn item -> Enum.min(item.rows) end)

  defp stop_items(indexed, segments) do
    last = length(indexed) - 1

    indexed
    |> non_same_stretches()
    |> Enum.flat_map(&stop_item(&1, indexed, last, segments))
  end

  defp non_same_stretches(indexed) do
    indexed
    |> Enum.chunk_by(fn {row, _index} -> row.type == :same end)
    |> Enum.reject(fn [{row, _index} | _] -> row.type == :same end)
  end

  defp stop_item(stretch, indexed, last, segments) do
    indexes = Enum.map(stretch, &elem(&1, 1))
    a_only = own_stops(stretch, :a)
    b_only = own_stops(stretch, :b)

    if a_only == [] and b_only == [] do
      []
    else
      before = hd(indexes) - 1
      after_ = List.last(indexes) + 1

      [
        %{
          kind: :stops,
          rows: indexes,
          frame: frame_indexes(before, indexes, after_, last),
          detail: %{
            before: stop_id_at(indexed, before),
            after: stop_id_at(indexed, after_),
            a_only: a_only,
            b_only: b_only,
            segment: find_segment(segments, before, after_)
          }
        }
      ]
    end
  end

  defp own_stops(stretch, type) do
    for {row, _index} <- stretch, row.type == type and is_nil(row.moved_to), do: row.stop_id
  end

  defp frame_indexes(before, indexes, after_, last) do
    ([before | indexes] ++ [after_])
    |> Enum.filter(&(&1 >= 0 and &1 <= last))
  end

  defp stop_id_at(indexed, index) when index >= 0 do
    case Enum.at(indexed, index) do
      {row, _index} -> row.stop_id
      nil -> nil
    end
  end

  defp stop_id_at(_indexed, _index), do: nil

  defp find_segment(segments, from, to) when from >= 0 do
    Enum.find(segments, &(&1.from == from and &1.to == to))
  end

  defp find_segment(_segments, _from, _to), do: nil

  defp moved_items(rows) do
    pairs =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{type: :a, moved_to: to}, index} when is_integer(to) -> [{index, to}]
        _row -> []
      end)

    collapse_moves(pairs, length(rows))
  end

  defp collapse_moves([], _row_count), do: []

  defp collapse_moves(pairs, row_count) when length(pairs) > 3 do
    indexes = pairs |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.uniq() |> Enum.sort()

    [
      %{
        kind: :moved,
        rows: indexes,
        frame: Enum.to_list(0..(row_count - 1)//1),
        detail: %{count: length(pairs)}
      }
    ]
  end

  defp collapse_moves(pairs, _row_count) do
    Enum.map(pairs, fn {a, b} ->
      pair = Enum.sort([a, b])
      %{kind: :moved, rows: pair, frame: pair, detail: %{count: 1}}
    end)
  end

  defp boarding_items(_rows, nil, _b_rows), do: []
  defp boarding_items(_rows, _a_rows, nil), do: []

  defp boarding_items(rows, a_rows, b_rows) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(&boarding_item(&1, a_rows, b_rows))
  end

  defp boarding_item({%{type: :same} = row, index}, a_rows, b_rows) do
    a_row = at(a_rows, row.a_pos)
    b_row = at(b_rows, row.b_pos)

    if is_nil(a_row) or is_nil(b_row) or same_boarding?(a_row, b_row) do
      []
    else
      [
        %{
          kind: :boarding,
          rows: [index],
          frame: [index],
          detail: %{
            a: %{pickup_type: a_row.pickup_type, drop_off_type: a_row.drop_off_type},
            b: %{pickup_type: b_row.pickup_type, drop_off_type: b_row.drop_off_type}
          }
        }
      ]
    end
  end

  defp boarding_item(_row, _a_rows, _b_rows), do: []

  defp same_boarding?(a_row, b_row) do
    a_row.pickup_type == b_row.pickup_type and a_row.drop_off_type == b_row.drop_off_type
  end

  defp timing_items(segments) do
    same_stops = Enum.filter(segments, & &1.same_stops?)

    listed =
      same_stops
      |> Enum.filter(&(is_integer(&1.diff) and abs(&1.diff) >= 60))
      |> Enum.sort_by(&abs(&1.diff), :desc)
      |> Enum.take(3)

    smaller = Enum.count(same_stops, &(is_integer(&1.diff) and &1.diff != 0)) - length(listed)

    {Enum.map(listed, &timing_item/1), smaller}
  end

  defp timing_item(segment) do
    %{
      kind: :time,
      rows: [segment.to],
      frame: [segment.from, segment.to],
      detail: %{segment: segment}
    }
  end

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

  defp build_segments(rows, rows_a, rows_b) do
    {last_a, last_b} = {last_visit(rows, :a_pos), last_visit(rows, :b_pos)}

    {anchors, untimed} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {row, index}, {anchors, untimed} ->
        case anchor(row, rows_a, rows_b) do
          {:ok, a_row, b_row} -> {[{index, row, a_row, b_row} | anchors], untimed}
          :untimed -> {anchors, MapSet.put(untimed, index)}
          :skip -> {anchors, untimed}
        end
      end)

    anchors = Enum.reverse(anchors)

    %{
      segments: segments_between(anchors),
      untimed: untimed,
      waits: waits_at(anchors, last_a, last_b)
    }
  end

  # Only a :same row with a full arrival/departure pair on both sides is an anchor; a shared row
  # without one is untimed (R5), and non-shared rows never anchor a segment.
  defp anchor(%{type: :same} = row, rows_a, rows_b) do
    with a_row when not is_nil(a_row) <- at(rows_a, row.a_pos),
         b_row when not is_nil(b_row) <- at(rows_b, row.b_pos),
         true <- timed?(a_row) and timed?(b_row) do
      {:ok, a_row, b_row}
    else
      _ -> :untimed
    end
  end

  defp anchor(_row, _rows_a, _rows_b), do: :skip

  defp segments_between(anchors) do
    anchors
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{from, _from_row, from_a, from_b}, {to, _to_row, to_a, to_b}] ->
      a_secs = to_a.arrival_offset - from_a.departure_offset
      b_secs = to_b.arrival_offset - from_b.departure_offset

      %{
        from: from,
        to: to,
        a_secs: a_secs,
        b_secs: b_secs,
        diff: b_secs - a_secs,
        same_stops?: to == from + 1
      }
    end)
  end

  defp waits_at(anchors, last_a, last_b) do
    Enum.reduce(anchors, %{}, fn {index, row, a_row, b_row}, waits ->
      a_wait = a_row.departure_offset - a_row.arrival_offset
      b_wait = b_row.departure_offset - b_row.arrival_offset

      if terminal?(row, last_a, last_b) or a_wait == b_wait do
        waits
      else
        Map.put(waits, index, {a_wait, b_wait})
      end
    end)
  end

  defp terminal?(row, last_a, last_b) do
    row.a_pos in [1, last_a] or row.b_pos in [1, last_b]
  end

  defp timed?(row), do: not is_nil(row.arrival_offset) and not is_nil(row.departure_offset)

  defp last_visit(rows, key) do
    rows
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  defp at(rows, pos) when is_integer(pos) and pos >= 1 and pos <= tuple_size(rows),
    do: elem(rows, pos - 1)

  defp at(_rows, _pos), do: nil
end
