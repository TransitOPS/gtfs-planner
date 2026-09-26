defmodule GtfsPlanner.Gtfs.RoutePatterns.Materializer do
  @moduledoc "Pure stop-time calculations for reviewed route-pattern edits."

  alias GtfsPlanner.Gtfs.GtfsTime

  @max_seconds 2_147_483_647

  @doc "Builds absolute GTFS stop times from a trip start, pattern occurrences and relative rows."
  def materialize(start_seconds, occurrences, timing_rows)
      when is_integer(start_seconds) and start_seconds >= 0 and is_list(occurrences) and
             is_list(timing_rows) do
    with true <- start_seconds <= @max_seconds,
         true <- length(occurrences) >= 2,
         true <- length(occurrences) == length(timing_rows),
         {:ok, values} <- absolute_rows(start_seconds, occurrences, timing_rows),
         :ok <- valid_chronology(values) do
      {:ok, values}
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  def materialize(_, _, _), do: {:error, :invalid_input}

  @doc "Reviews a new occurrence order and rebases all timing rows around its first departure."
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
      with {:ok, arrival_offset} <- integer_field(row, :arrival_offset),
           {:ok, departure_offset} <- integer_field(row, :departure_offset),
           arrival = start + arrival_offset,
           departure = start + departure_offset,
           true <-
             arrival >= 0 and departure >= 0 and arrival <= @max_seconds and
               departure <= @max_seconds do
        value =
          row
          |> row_attrs()
          |> Map.merge(%{
            stop_id: field(occurrence, :stop_id),
            stop_sequence: sequence,
            arrival_time: GtfsTime.format(arrival),
            departure_time: GtfsTime.format(departure)
          })

        {:cont, {:ok, [value | acc]}}
      else
        false -> {:halt, {:error, :negative_time}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp valid_chronology([first | rest]) do
    case parsed_clocks(first) do
      {:ok, arrival, departure} when departure >= arrival ->
        validate_remaining_chronology(rest, departure)

      _ ->
        {:error, :invalid_chronology}
    end
  end

  defp validate_remaining_chronology(rows, first_departure) do
    Enum.reduce_while(rows, {:ok, first_departure}, fn row, {:ok, preceding} ->
      case parsed_clocks(row) do
        {:ok, arrival, departure} when arrival >= preceding and departure >= arrival ->
          {:cont, {:ok, departure}}

        _ ->
          {:halt, {:error, :invalid_chronology}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp parsed_clocks(row) do
    with {:ok, arrival} <- GtfsTime.parse(row.arrival_time),
         {:ok, departure} <- GtfsTime.parse(row.departure_time) do
      {:ok, arrival, departure}
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
      with {:ok, result} <- review_timing(old, new, rows, Map.get(added_values, id, %{})) do
        {:ok, if(is_nil(id), do: result, else: Map.put(result, :timing_id, id))}
      end
    end
  end

  defp review_timing(old, new, rows, supplied) do
    old_rows =
      Map.new(Enum.zip(old, rows), fn {occurrence, row} -> {field(occurrence, :id), row} end)

    retained = Enum.filter(new, &(not is_nil(field(&1, :id))))
    first_row = row_for(new |> hd(), old_rows, supplied)

    with true <- not is_nil(first_row),
         {:ok, first_departure} <- integer_field(first_row, :departure_offset),
         {:ok, {raw_rows, estimates}} <- build_raw_rows(new, old_rows, supplied),
         {:ok, normalized} <- normalize_rows(raw_rows, first_departure),
         :ok <- validate_relative_chronology(normalized) do
      if length(retained) != MapSet.size(MapSet.new(Enum.map(retained, &field(&1, :id)))) do
        {:error, :invalid_input}
      else
        {:ok, %{start_shift: first_departure, rows: normalized, estimates: estimates}}
      end
    else
      false -> {:error, :explicit_terminal_values_required}
      {:error, _} = error -> error
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
    bracketed? = previous != nil and following != nil

    with {:ok, row} <- estimated_or_supplied(previous, following, added, bracketed?) do
      estimate =
        if bracketed? and is_nil(added) do
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

  defp estimated_or_supplied(previous, following, added, true) when is_nil(added) do
    previous_departure = integer!(field(previous.row, :departure_offset))
    following_arrival = integer!(field(following.row, :arrival_offset))
    count = 1
    time = previous_departure + div(following_arrival - previous_departure, count + 1)
    {:ok, default_new_row(time, time)}
  end

  defp estimated_or_supplied(_previous, _following, nil, false),
    do: {:error, :explicit_terminal_values_required}

  defp estimated_or_supplied(_previous, _following, added, _bracketed?) when is_map(added) do
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

  defp row_for(occurrence, rows, supplied) do
    if field(occurrence, :id),
      do: Map.get(rows, field(occurrence, :id)),
      else: supplied_value(supplied, occurrence)
  end

  defp timing_parts(%{rows: rows} = timing, _index), do: {Map.get(timing, :timing_id), rows}
  defp timing_parts(rows, _index) when is_list(rows), do: {nil, rows}
  defp timing_parts(_, _index), do: {nil, []}

  defp normalize_rows(rows, base) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      with {:ok, arrival} <- integer_field(row, :arrival_offset),
           {:ok, departure} <- integer_field(row, :departure_offset) do
        {:cont,
         {:ok,
          [
            %{row_attrs(row) | arrival_offset: arrival - base, departure_offset: departure - base}
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

  defp validate_relative_chronology(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil}, fn {row, index}, {:ok, preceding} ->
      arrival = row.arrival_offset
      departure = row.departure_offset
      validate_relative_row(index, arrival, departure, preceding)
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_relative_row(index, arrival, departure, preceding) do
    if departure >= arrival and (index == 0 or arrival >= preceding),
      do: {:cont, {:ok, departure}},
      else: {:halt, {:error, :invalid_chronology}}
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

      Enum.map(Enum.filter(new, &field(&1, :id)), &field(&1, :id)) !=
          Enum.filter(old_ids, &(&1 in new_ids)) ->
        {:error, :invalid_occurrence_order}

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

  defp integer_field(map, key) do
    case field(map, key) do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, :invalid_time}
    end
  end

  defp integer!(value) when is_integer(value), do: value
  defp integer!(map), do: Map.fetch!(map, :departure_offset)

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
end
