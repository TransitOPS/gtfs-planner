defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.Convert do
  @moduledoc """
  Plans converting one frequency trip into listed trips — `:convert_frequency` (R8, R10).

  The one command trip must be a trip with stored frequency rows. Its stored windows
  are expanded with `FrequencyWindows.departures/1`, window by window in their stored
  order, and the departures are put in time order; every departure becomes one insert
  of the source's service, pattern and rider-facing detail with a trip ID allocated by
  `TripChanges.allocate_trip_ids/5`, no block and no trip number (one conversion
  creates several trips on one service day, and a trip number is unique within it).
  The frequency trip itself is deleted, so the engine also removes its stop times, its
  frequency rows and every transfer naming it, and `{:note, {:transfers_removed, n}}`
  states the transfer count the review read from `state.transfer_counts` (AC-19).
  Convert is not undoable, so an apply returns no restore payload (R10).

  A linked trip whose stored stops match its pattern's occurrences follows its
  timing: each insert is that timing materialized at the departure, keeps the
  source's stored continuous flags and shape distance (the occurrence's distance
  fills a blank one), and stays linked to the timing (R1's whole-trip rule).
  Every other source — a custom trip, a trip with no followable linkage, or one whose
  stored stops differ — offsets its stored template by the difference between the
  departure and the template's first departure, keeping each stored clock, flag and
  shape distance and leaving a cleared stop cleared. Such a converted trip keeps the
  source's own linkage, except a source that claimed a linkage it cannot follow: its
  converted trips are custom with reason `edited_in_schedules`, as R1 states for any
  result that matches no timing. A template offset that would put a clock below 00:00
  is an `{:error, :negative_time}` consequence and plans no change at all, and a
  stored clock the planner cannot read is `{:error, :invalid_command}`.

  A stored window list that violates R8 — `Until` not after `From`, an overlap, or a
  headway that is not a whole number of minutes — is an
  `{:error, {:invalid_windows, errors}}` consequence and the review plans nothing, so
  a source whose windows cannot be followed is never deleted in exchange for trips the
  planner guessed at.

  The planner is pure (CR-1): it reads only its arguments and never calls `Repo`, the
  clock or process state.
  """

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.Schedules.FrequencyWindows
  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  @doc """
  Plans one `:convert_frequency` command against the loaded review state (R8, AC-19).

  The command trip must be loaded in `state.trips` and carry stored frequency rows; a
  missing trip is `{:error, :not_found}` and a trip with no stored rows is
  `{:error, :invalid_command}`, as is a source whose stored stop times or windows the
  planner cannot read. For this command the loader provides `state.patterns` (the
  trip's pattern with its occurrences and timings), `state.existing_trip_ids` and
  `state.transfer_counts`.
  """
  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :not_found | :invalid_command}
  def plan({:convert_frequency, trip_id}, state) do
    with {:ok, loaded} <- load_trip(trip_id, state),
         {:ok, windows} <- stored_windows(loaded) do
      plan_conversion(loaded, windows, state)
    end
  end

  def plan(_command, _state), do: {:error, :invalid_command}

  # --- planning -------------------------------------------------------------

  defp plan_conversion(loaded, windows, state) do
    case FrequencyWindows.validate(windows) do
      {:error, errors} ->
        {:ok, refused([{:error, {:invalid_windows, errors}}])}

      :ok ->
        departures = departures(windows)

        case source(loaded, state, hd(departures)) do
          {:ok, source} -> planned_change_set(source, departures, value(loaded, :trip), state)
          {:error, :invalid_command} = error -> error
        end
    end
  end

  defp planned_change_set(source, departures, trip, state) do
    case inserted_trips(source, departures, trip, state) do
      {:ok, inserts} -> {:ok, change_set(trip, inserts, state)}
      {:error, :invalid_command} = error -> error
      {:error, :negative_time} -> {:ok, refused([{:error, :negative_time}])}
    end
  end

  defp change_set(trip, inserts, state) do
    %{
      updates: [],
      inserts: inserts,
      deletes: [value(trip, :id)],
      consequences: [{:note, {:transfers_removed, transfer_count(trip, state)}}]
    }
  end

  # The number of transfer rows naming the trip, which is exactly the set the
  # engine's delete removes; the loader keys them by natural `trip_id` and always
  # includes the trip, so a trip with no transfer reads zero (R10, AC-19).
  defp transfer_count(trip, state) do
    case value(state, :transfer_counts) do
      %{} = counts -> Map.get(counts, value(trip, :trip_id), 0)
      _counts -> 0
    end
  end

  defp refused(consequences),
    do: %{updates: [], inserts: [], deletes: [], consequences: consequences}

  # --- the source's stop times ----------------------------------------------

  # The probe departure decides the whole conversion: `Materializer.materialize/3`
  # and a template offset differ by a constant shift, so what works at the first
  # departure works at every later one.
  defp source(loaded, state, first_departure) do
    case linked_timing(loaded, state, first_departure) do
      {:ok, timing} -> {:ok, {:linked, timing}}
      :custom -> custom_source(value(loaded, :trip), ordered_stop_times(loaded))
    end
  end

  # A linked trip follows its timing only when the timing is loaded for its own
  # pattern, its stored stops are the pattern's occurrences and the timing
  # materializes at the first departure; anything else keeps the stored template.
  defp linked_timing(loaded, state, first_departure) do
    trip = value(loaded, :trip)
    rows = ordered_stop_times(loaded)

    with "linked" <- value(trip, :pattern_derivation_state),
         timing_id when is_binary(timing_id) <- value(trip, :timed_pattern_id),
         {:ok, entry} <- loaded_pattern(state, value(trip, :route_pattern_id)),
         occurrences = List.wrap(value(entry, :occurrences)),
         true <- compatible_stops?(rows, occurrences),
         {:ok, timing} <- pattern_timing(entry, timing_id),
         {:ok, _probe} <- Materializer.materialize(first_departure, occurrences, timing.rows) do
      {:ok,
       %{
         timing_id: timing.timing_id,
         occurrences: occurrences,
         rows: timing.rows,
         source_rows: rows
       }}
    else
      _other -> :custom
    end
  end

  defp custom_source(trip, rows) do
    case first_departure(rows) do
      nil ->
        {:error, :invalid_command}

      start_secs ->
        {:ok, {:custom, %{rows: rows, start_secs: start_secs, linkage: custom_linkage(trip)}}}
    end
  end

  # The converted trips are copies of the source's template, so they keep its own
  # linkage; a source that claimed a linkage the planner cannot follow becomes custom
  # with R1's reason for a result that matches no timing.
  defp custom_linkage(trip) do
    if value(trip, :pattern_derivation_state) == "linked" do
      %{
        timed_pattern_id: nil,
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "edited_in_schedules"
      }
    else
      %{
        timed_pattern_id: value(trip, :timed_pattern_id),
        pattern_derivation_state: value(trip, :pattern_derivation_state),
        pattern_derivation_reason: value(trip, :pattern_derivation_reason)
      }
    end
  end

  # --- inserts --------------------------------------------------------------

  defp inserted_trips(source, departures, trip, state) do
    trip_ids =
      TripChanges.allocate_trip_ids(
        value(trip, :route_id),
        value(trip, :direction_id),
        value(trip, :service_id),
        departures,
        List.wrap(value(state, :existing_trip_ids))
      )

    departures
    |> Enum.zip(trip_ids)
    |> Enum.reduce_while({:ok, []}, fn {departure, trip_id}, {:ok, acc} ->
      case insert(source, trip, departure, trip_id) do
        {:ok, insert} -> {:cont, {:ok, [insert | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finish()
  end

  defp insert({:linked, timing}, trip, departure, trip_id) do
    case Materializer.materialize(departure, timing.occurrences, timing.rows) do
      {:ok, rows} ->
        linkage = %{
          timed_pattern_id: timing.timing_id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil
        }

        {:ok, insert_map(trip, trip_id, linkage, linked_stop_times(rows, timing, trip))}

      {:error, _reason} ->
        {:error, :invalid_command}
    end
  end

  defp insert({:custom, template}, trip, departure, trip_id) do
    case offset_rows(template.rows, departure - template.start_secs) do
      {:ok, rows} -> {:ok, insert_map(trip, trip_id, template.linkage, rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_map(trip, trip_id, linkage, stop_times) do
    %{
      source_id: value(trip, :id),
      attrs: attrs(trip, trip_id, linkage),
      stop_times: stop_times,
      frequencies: []
    }
  end

  # A materialized timing row is the timing's own row: its clocks, timepoint and
  # per-stop values. The source's stored continuous flags and shape distance are not
  # timing values, so each converted row keeps the source row's at the same position;
  # a source row with no stored distance takes the occurrence's for a drawn pattern
  # (a pattern without a shape contributes nil distances, R15).
  defp linked_stop_times(rows, timing, trip) do
    shape_id = value(trip, :shape_id)

    [rows, timing.occurrences, timing.source_rows]
    |> Enum.zip()
    |> Enum.map(fn {row, occurrence, source} ->
      %{
        stop_id: value(row, :stop_id),
        stop_sequence: value(row, :stop_sequence),
        arrival_time: value(row, :arrival_time),
        departure_time: value(row, :departure_time),
        stop_headsign: value(row, :stop_headsign),
        pickup_type: value(row, :pickup_type),
        drop_off_type: value(row, :drop_off_type),
        continuous_pickup: value(source, :continuous_pickup),
        continuous_drop_off: value(source, :continuous_drop_off),
        shape_dist_traveled:
          value(source, :shape_dist_traveled) || shape_distance(occurrence, shape_id),
        timepoint: value(row, :timepoint)
      }
    end)
  end

  defp shape_distance(_occurrence, shape_id) when not is_binary(shape_id), do: nil
  defp shape_distance(occurrence, _shape_id), do: value(occurrence, :shape_dist_traveled)

  # The template's own rows moved by one offset: every stored clock moves, a cleared
  # stop stays cleared, and every other column travels unchanged (R7's copy shape).
  defp offset_rows(rows, offset) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      with {:ok, arrival} <- offset_clock(value(row, :arrival_time), offset),
           {:ok, departure} <- offset_clock(value(row, :departure_time), offset) do
        {:cont, {:ok, [template_row(row, arrival, departure) | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finish()
  end

  defp offset_clock(nil, _offset), do: {:ok, nil}

  defp offset_clock(secs, offset) when is_integer(secs) and secs >= 0 do
    if secs + offset >= 0,
      do: {:ok, GtfsTime.format(secs + offset)},
      else: {:error, :negative_time}
  end

  defp offset_clock(clock, offset) when is_binary(clock) do
    case GtfsTime.parse(clock) do
      {:ok, secs} -> offset_clock(secs, offset)
      {:error, :invalid_time} -> {:error, :invalid_command}
    end
  end

  defp offset_clock(_clock, _offset), do: {:error, :invalid_command}

  defp template_row(row, arrival, departure) do
    %{
      stop_id: value(row, :stop_id),
      stop_sequence: value(row, :stop_sequence),
      arrival_time: arrival,
      departure_time: departure,
      stop_headsign: value(row, :stop_headsign),
      pickup_type: value(row, :pickup_type),
      drop_off_type: value(row, :drop_off_type),
      continuous_pickup: value(row, :continuous_pickup),
      continuous_drop_off: value(row, :continuous_drop_off),
      shape_dist_traveled: value(row, :shape_dist_traveled),
      timepoint: value(row, :timepoint)
    }
  end

  # The converted trip keeps the source's service, pattern and rider-facing detail,
  # and the linkage its branch decided, but never a block and never a trip number.
  defp attrs(trip, trip_id, linkage) do
    %{
      trip_id: trip_id,
      route_id: value(trip, :route_id),
      service_id: value(trip, :service_id),
      direction_id: value(trip, :direction_id),
      trip_headsign: value(trip, :trip_headsign),
      trip_short_name: nil,
      wheelchair_accessible: value(trip, :wheelchair_accessible),
      bikes_allowed: value(trip, :bikes_allowed),
      cars_allowed: value(trip, :cars_allowed),
      shape_id: value(trip, :shape_id),
      route_pattern_id: value(trip, :route_pattern_id)
    }
    |> Map.merge(linkage)
  end

  # --- stored windows --------------------------------------------------------

  # The stored rows in the order the page lists them (`start_time`), so a validation
  # error's `index` names the row the editor shows; the departures are put in time
  # order later.
  defp stored_windows(loaded) do
    loaded
    |> ordered_frequencies()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case stored_window(row) do
        {:ok, window} -> {:cont, {:ok, [window | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :invalid_command}
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      {:error, _reason} = error -> error
    end
  end

  defp stored_window(row) do
    start_secs = secs(value(row, :start_time))
    end_secs = secs(value(row, :end_time))
    headway_secs = value(row, :headway_secs)

    if is_integer(start_secs) and is_integer(end_secs) and is_integer(headway_secs) and
         headway_secs > 0 do
      {:ok, %{start_secs: start_secs, end_secs: end_secs, headway_secs: headway_secs}}
    else
      {:error, :invalid_command}
    end
  end

  # Every departure the windows produce, in time order: each window is half-open, so
  # a departure exactly at `Until` never appears (R8, FH-8).
  defp departures(windows) do
    windows
    |> Enum.sort_by(&{&1.start_secs, &1.end_secs})
    |> Enum.flat_map(&FrequencyWindows.departures/1)
    |> Enum.sort()
  end

  # --- helpers ---------------------------------------------------------------

  defp load_trip(trip_id, state) do
    case value(state, :trips) do
      %{} = trips ->
        case Map.get(trips, trip_id) do
          %{} = loaded -> {:ok, loaded}
          _missing -> {:error, :not_found}
        end

      _trips ->
        {:error, :not_found}
    end
  end

  defp loaded_pattern(state, pattern_id) when is_binary(pattern_id) do
    case value(state, :patterns) do
      %{} = patterns ->
        case Map.fetch(patterns, pattern_id) do
          {:ok, entry} -> {:ok, entry}
          :error -> {:error, :not_found}
        end

      _patterns ->
        {:error, :not_found}
    end
  end

  defp loaded_pattern(_state, _pattern_id), do: {:error, :not_found}

  defp pattern_timing(entry, timing_id) do
    entry
    |> value(:timings)
    |> List.wrap()
    |> Enum.find_value(fn timing_entry ->
      timing = value(timing_entry, :timing)

      if value(timing, :id) == timing_id do
        %{timing_id: value(timing, :id), rows: List.wrap(value(timing_entry, :rows))}
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      timing -> {:ok, timing}
    end
  end

  defp compatible_stops?(rows, occurrences) do
    rows != [] and
      Enum.map(rows, &value(&1, :stop_id)) == Enum.map(occurrences, &value(&1, :stop_id))
  end

  defp ordered_stop_times(loaded) do
    loaded
    |> value(:stop_times)
    |> List.wrap()
    |> Enum.sort_by(&{value(&1, :stop_sequence), value(&1, :id)})
  end

  defp ordered_frequencies(loaded) do
    loaded
    |> value(:frequencies)
    |> List.wrap()
    |> Enum.sort_by(&value(&1, :start_time))
  end

  # The template's anchor is the first row's departure, or its arrival at a stop that
  # stores only one clock (the same anchor a copy uses).
  defp first_departure([first | _rest]) do
    secs(value(first, :departure_time)) || secs(value(first, :arrival_time))
  end

  defp first_departure(_rows), do: nil

  defp secs(value) when is_integer(value) and value >= 0, do: value

  defp secs(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> nil
    end
  end

  defp secs(_value), do: nil

  defp finish({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp finish({:error, _reason} = error), do: error

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
