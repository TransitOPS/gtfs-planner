defmodule GtfsPlanner.Gtfs.RoutePatterns.Materializer do
  @moduledoc "Pure stop-time calculations for reviewed route-pattern edits."

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePatterns.TimingRules

  @max_seconds 2_147_483_647
  @slot_keys [:arrival_offset, :departure_offset]

  @doc """
  Builds absolute GTFS stop times from a trip start, pattern occurrences and relative rows.

  A row whose two offsets are nil is a blank stop: it materializes to nil
  `arrival_time` and `departure_time`, so a blank stays the absence of a time and
  is never `0` or an estimate. The rows are checked against the one timing rule
  before they are materialized, so chronology is decided over the timed rows only.
  """
  def materialize(start_seconds, occurrences, timing_rows)
      when is_integer(start_seconds) and start_seconds >= 0 and is_list(occurrences) and
             is_list(timing_rows) do
    with true <- start_seconds <= @max_seconds,
         true <- length(occurrences) >= 2,
         true <- length(occurrences) == length(timing_rows),
         :ok <- valid_timing(timing_rows),
         {:ok, values} <- absolute_rows(start_seconds, occurrences, timing_rows) do
      {:ok, values}
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  def materialize(_, _, _), do: {:error, :invalid_input}

  @doc """
  Reviews a new occurrence order and rebases all timing rows around its first departure.

  When the retained occurrences change relative order, each timing keeps its times by
  position and its other row values move with the stop; the rows whose times change come
  back in `estimates` flagged `resequenced: true`, because the running time between the
  stops that are now adjacent is only the old slot spacing.

  A row whose two offsets are nil is a blank stop. An inserted stop beside a blank
  neighbour has no running time to divide, so it is left blank too and reported as no
  estimate; the resulting rows are then decided by `TimingRules.validate/1`, so a blank
  that lands on the first or last stop is the review's
  `{:error, :explicit_terminal_values_required}` and every other violation keeps its
  existing reason.
  """
  def review_stops(old_occurrences, new_occurrences, timing_rows, added_values)
      when is_list(old_occurrences) and is_list(new_occurrences) and is_list(timing_rows) and
             is_map(added_values) do
    with :ok <- validate_occurrences(old_occurrences, new_occurrences),
         true <- length(new_occurrences) >= 2,
         {:ok, timing_results} <-
           review_each_timing(old_occurrences, new_occurrences, timing_rows, added_values) do
      shifts = Enum.map(timing_results, & &1.start_shift)

      {:ok,
       %{
         start_shift: if(length(Enum.uniq(shifts)) <= 1, do: List.first(shifts) || 0, else: nil),
         timing_rows: Enum.map(timing_results, &Map.drop(&1, [:start_shift, :estimates])),
         shifts: Enum.map(timing_results, &Map.take(&1, [:timing_id, :start_shift])),
         estimates: Enum.flat_map(timing_results, & &1.estimates)
       }}
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  def review_stops(_, _, _, _), do: {:error, :invalid_input}

  defp absolute_rows(start, occurrences, rows) do
    occurrences
    |> Enum.zip(rows)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{occurrence, row}, sequence}, {:ok, acc} ->
      case absolute_clocks(start, row) do
        {:ok, clocks} ->
          {:cont,
           {:ok,
            [
              row
              |> row_attrs()
              |> Map.merge(%{
                stop_id: field(occurrence, :stop_id),
                stop_sequence: sequence,
                arrival_time: clocks.arrival,
                departure_time: clocks.departure
              })
              | acc
            ]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # A blank pair is the absence of a time, so it formats to nil rather than to
  # midnight. A half pair is malformed and never reaches this function: the
  # timing rule has already rejected it.
  defp absolute_clocks(start, row) do
    arrival_offset = field(row, :arrival_offset)
    departure_offset = field(row, :departure_offset)

    cond do
      is_nil(arrival_offset) and is_nil(departure_offset) ->
        {:ok, %{arrival: nil, departure: nil}}

      is_integer(arrival_offset) and is_integer(departure_offset) ->
        clock_pair(start + arrival_offset, start + departure_offset)

      true ->
        {:error, :invalid_time}
    end
  end

  defp clock_pair(arrival, departure) do
    if arrival >= 0 and departure >= 0 and arrival <= @max_seconds and departure <= @max_seconds do
      {:ok, %{arrival: GtfsTime.format(arrival), departure: GtfsTime.format(departure)}}
    else
      {:error, :negative_time}
    end
  end

  # The one timing rule decides validity, so a half pair, a blank end, a blank
  # timepoint and a backwards timed row are all refused here rather than in a
  # second chronology check of the formatted values.
  defp valid_timing(rows) do
    case TimingRules.validate(rows) do
      :ok -> :ok
      {:error, _violations} -> {:error, :invalid_chronology}
    end
  end

  defp review_each_timing(old, new, timings, added_values) do
    timings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {timing, index}, {:ok, acc} ->
      {id, rows} = timing_parts(timing, index)

      case review_one_timing(old, new, id, rows, added_values) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp review_one_timing(old, new, id, rows, added_values) do
    if length(rows) != length(old) do
      {:error, :invalid_input}
    else
      with {:ok, result} <- review_timing(old, new, id, rows, Map.get(added_values, id, %{})) do
        {:ok, if(is_nil(id), do: result, else: Map.put(result, :timing_id, id))}
      end
    end
  end

  defp review_timing(old, new, timing_id, rows, supplied) do
    {old_rows, resequenced} =
      old
      |> Enum.zip(rows)
      |> Map.new(fn {occurrence, row} -> {field(occurrence, :id), row} end)
      |> resequence(old, new, timing_id)

    retained = Enum.filter(new, &(not is_nil(field(&1, :id))))

    with {:ok, reviewed} <- review_rows(new, old_rows, supplied),
         :ok <- distinct_retained(retained) do
      {:ok, %{reviewed | estimates: resequenced ++ reviewed.estimates}}
    end
  end

  defp review_rows(new, old_rows, supplied) do
    with {:ok, {raw_rows, estimates}} <- build_raw_rows(new, old_rows, supplied),
         base = base_offset(raw_rows),
         {:ok, rows} <- normalize_rows(raw_rows, base),
         :ok <- validate_rows(rows) do
      {:ok, %{start_shift: base, rows: rows, estimates: estimates}}
    end
  end

  defp distinct_retained(retained) do
    if length(retained) == MapSet.size(MapSet.new(Enum.map(retained, &field(&1, :id)))) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  # Every row is rebased around the first stop's departure, so that departure is
  # also the shift a linked trip's start moves by. A first row with no departure
  # is a blank end, which the timing rule refuses below, so the base it needs in
  # order to reach that refusal is not the value it reports.
  defp base_offset([first | _]) do
    case field(first, :departure_offset) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp base_offset([]), do: 0

  # Times stay with positions: the retained stops' rows in their old order are
  # chronological time slots, and each slot goes to the retained stop now at that
  # position. The remaining row values describe the stop, so they stay with it.
  defp resequence(old_rows, old, new, timing_id) do
    new_ids = for occurrence <- new, id = field(occurrence, :id), do: id
    old_ids = for occurrence <- old, id = field(occurrence, :id), id in new_ids, do: id

    if new_ids == old_ids do
      {old_rows, []}
    else
      slots = Enum.map(old_ids, &Map.take(Map.fetch!(old_rows, &1), @slot_keys))
      moved = Enum.zip(new_ids, slots)

      rows =
        Map.new(moved, fn {id, slot} ->
          {id, Map.merge(row_attrs(Map.fetch!(old_rows, id)), slot)}
        end)

      estimates =
        for {id, slot} <- moved, slot != Map.take(Map.fetch!(old_rows, id), @slot_keys) do
          Map.merge(slot, %{id: id, timing_id: timing_id, resequenced: true})
        end

      {Map.merge(old_rows, rows), estimates}
    end
  end

  defp build_raw_rows(new, old_map, supplied) do
    Enum.with_index(new)
    |> Enum.reduce_while({:ok, [], []}, fn {occurrence, index}, {:ok, rows, estimates} ->
      case raw_row_for(new, occurrence, index, old_map, supplied) do
        {:ok, row, estimate} ->
          next_estimates = prepend_estimate(estimate, estimates)
          {:cont, {:ok, [row | rows], next_estimates}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, values, estimates} -> {:ok, {Enum.reverse(values), Enum.reverse(estimates)}}
      error -> error
    end
  end

  defp prepend_estimate(nil, estimates), do: estimates
  defp prepend_estimate(estimate, estimates), do: [estimate | estimates]

  defp raw_row_for(new, occurrence, index, old_map, supplied) do
    case field(occurrence, :id) do
      nil -> inserted_row(new, index, old_map, supplied_value(supplied, occurrence))
      id -> retained_row(old_map, id)
    end
  end

  defp retained_row(old_map, id) do
    case Map.fetch(old_map, id) do
      {:ok, row} -> {:ok, row_attrs(row), nil}
      :error -> {:error, :invalid_input}
    end
  end

  defp inserted_row(new, index, old_rows, added) do
    previous = nearest_retained(new, index, -1, old_rows)
    following = nearest_retained(new, index, 1, old_rows)

    # The run of k inserted stops between two retained anchors divides that
    # interval: the j-th insertion sits at floor(j * gap / (k + 1)).
    run =
      if previous && following, do: {index - previous.index, following.index - previous.index - 1}

    with {:ok, row} <- estimated_or_supplied(previous, following, added, run) do
      estimate =
        if run && is_nil(added) && is_integer(row.arrival_offset) do
          %{
            key: field(Enum.at(new, index), :key),
            arrival_offset: row.arrival_offset,
            departure_offset: row.departure_offset,
            timepoint: 0,
            pickup_type: 0,
            drop_off_type: 0,
            stop_headsign: nil
          }
        end

      {:ok, row, estimate}
    end
  end

  # A blank anchor carries no time to interpolate from, so an inserted stop beside
  # one is left blank and reported as no estimate. A blank inserted at either end
  # is the same absence; the timing rule is what decides that it is not allowed.
  defp estimated_or_supplied(%{row: previous}, %{row: following}, nil, {j, k}) do
    if timed_row?(previous) and timed_row?(following) do
      previous_departure = field(previous, :departure_offset)
      following_arrival = field(following, :arrival_offset)
      time = previous_departure + div(j * (following_arrival - previous_departure), k + 1)
      {:ok, default_new_row(time, time)}
    else
      {:ok, default_new_row(nil, nil)}
    end
  end

  defp estimated_or_supplied(_previous, _following, nil, nil),
    do: {:ok, default_new_row(nil, nil)}

  defp estimated_or_supplied(_previous, _following, added, _run) when is_map(added) do
    with {:ok, arrival} <- input_offset(added, :arrival_offset, :arrival_time),
         {:ok, departure} <- input_offset(added, :departure_offset, :departure_time),
         true <- departure >= arrival do
      {:ok, Map.merge(default_new_row(arrival, departure), row_attrs(added))}
    else
      false -> {:error, :invalid_chronology}
      {:error, _} = error -> error
    end
  end

  defp nearest_retained(new, index, direction, old_rows) do
    indexes =
      if direction < 0 do
        last = index - 1
        if last < 0, do: [], else: Enum.to_list(0..last) |> Enum.reverse()
      else
        first = index + 1
        if first >= length(new), do: [], else: Enum.to_list(first..(length(new) - 1))
      end

    Enum.find_value(indexes, fn i ->
      item = Enum.at(new, i)

      if field(item, :id),
        do: %{item: item, index: i, row: Map.fetch!(old_rows, field(item, :id))},
        else: nil
    end)
  end

  defp supplied_value(values, occurrence) do
    key = field(occurrence, :key)
    rows = field(values, :rows)

    Map.get(values, key) || Map.get(values, to_string(key)) ||
      Map.get(values, field(occurrence, :stop_id)) ||
      if is_list(rows) do
        Enum.find(rows, fn row ->
          field(row, :key) == key or field(row, :stop_id) == field(occurrence, :stop_id)
        end) ||
          if(length(rows) == 1, do: hd(rows), else: nil)
      end
  end

  defp timed_row?(row) do
    is_integer(field(row, :arrival_offset)) and is_integer(field(row, :departure_offset))
  end

  defp timing_parts(%{rows: rows} = timing, _index), do: {Map.get(timing, :timing_id), rows}
  defp timing_parts(rows, _index) when is_list(rows), do: {nil, rows}
  defp timing_parts(_, _index), do: {nil, []}

  # A blank stays blank through the rebase: absence is not zero, so nothing is
  # subtracted from it and no time appears where the stop had none.
  defp normalize_rows(rows, base) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      with {:ok, arrival} <- rebased(field(row, :arrival_offset), base),
           {:ok, departure} <- rebased(field(row, :departure_offset), base) do
        {:cont,
         {:ok,
          [
            %{row_attrs(row) | arrival_offset: arrival, departure_offset: departure}
            | acc
          ]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp rebased(nil, _base), do: {:ok, nil}
  defp rebased(value, base) when is_integer(value), do: {:ok, value - base}
  defp rebased(_value, _base), do: {:error, :invalid_time}

  # Timing validity has one owner, so a blank end, a blank timepoint, a half pair
  # and a backwards timed row are all decided here rather than in a second
  # chronology check of the rebased rows. A blank end is the one the review
  # already reports as :explicit_terminal_values_required, because the editor
  # asks the user to enter that stop's times and review again.
  defp validate_rows(rows) do
    case TimingRules.validate(rows) do
      :ok -> :ok
      {:error, violations} -> {:error, review_violation(violations)}
    end
  end

  defp review_violation(violations) do
    cond do
      Enum.any?(violations, &match?({_index, :terminal_blank}, &1)) ->
        :explicit_terminal_values_required

      Enum.any?(violations, &match?({_index, :half_timed}, &1)) ->
        :invalid_time

      true ->
        :invalid_chronology
    end
  end

  defp validate_occurrences(old, new) do
    old_ids = Enum.map(old, &field(&1, :id))
    new_ids = Enum.map(new, &field(&1, :id)) |> Enum.reject(&is_nil/1)
    keys = Enum.map(new, &field(&1, :key)) |> Enum.reject(&is_nil/1)

    cond do
      Enum.any?(old_ids, &is_nil/1) ->
        {:error, :invalid_input}

      length(old_ids) != length(Enum.uniq(old_ids)) ->
        {:error, :invalid_input}

      length(new_ids) != length(Enum.uniq(new_ids)) ->
        {:error, :invalid_input}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :invalid_input}

      Enum.any?(new_ids, &(&1 not in old_ids)) ->
        {:error, :invalid_input}

      adjacent_duplicate_stops?(new) ->
        {:error, :adjacent_duplicate_stops}

      true ->
        :ok
    end
  end

  defp adjacent_duplicate_stops?(items) do
    items
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] -> field(a, :stop_id) == field(b, :stop_id) end)
  end

  defp input_offset(map, offset_key, time_key) do
    case field(map, offset_key) do
      value when is_integer(value) ->
        {:ok, value}

      nil ->
        case field(map, time_key) do
          value when is_binary(value) -> GtfsTime.parse_offset(value)
          _ -> {:error, :explicit_terminal_values_required}
        end

      _ ->
        {:error, :invalid_time}
    end
  end

  defp default_new_row(arrival, departure),
    do: %{
      arrival_offset: arrival,
      departure_offset: departure,
      timepoint: 0,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    }

  defp row_attrs(row) when is_map(row),
    do:
      Map.take(row, [
        :arrival_offset,
        :departure_offset,
        :timepoint,
        :pickup_type,
        :drop_off_type,
        :stop_headsign
      ])

  defp row_attrs(_), do: %{}

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
end
