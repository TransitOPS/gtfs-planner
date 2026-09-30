defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.SetTiming do
  @moduledoc """
  Plans one R5 timing change (`:set_timing`) as a change set.

  The command names the selected trips and one timing of a route pattern. A trip
  is eligible when it belongs to that timing's pattern and its ordered stops match
  the pattern's occurrences: its stop times are re-materialized with
  `Materializer.materialize/3` at its current first departure and its update links
  it to the chosen timing (state `linked`, the timing's id, reason nil). A trip
  whose stops differ — including a trip on another pattern — is listed as
  `{:note, {:excluded, id, :stops_differ}}` and not written, and a selection in
  which no trip is eligible carries `{:error, :no_eligible_trips}` so the engine
  refuses the whole command. Every eligible trip that was not linked before the
  change is named once in `{:note, {:loses_custom_times, ids}}`, because the
  timing's clocks and per-stop values replace its stored custom times. A frequency
  trip takes the timing as its template the same way and keeps its frequency
  windows (`frequencies: :unchanged`).

  The planner is pure (CR-1): it reads only its arguments and never calls `Repo`,
  the clock or process state.
  """

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  @doc """
  Plans one `:set_timing` command against the loaded review state (R5).

  Every command trip must be loaded in `state.trips`; a missing one is
  `{:error, :not_found}`. A target timing that names none of the loaded patterns is
  also `{:error, :not_found}`, and an eligible trip without a readable first
  departure (or a timing the materializer cannot expand) is
  `{:error, :invalid_command}`.
  """
  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :not_found | :invalid_command}
  def plan({:set_timing, trip_ids, timing_id}, state) when is_list(trip_ids) do
    with {:ok, loaded} <- load_trips(trip_ids, state),
         {:ok, target} <- target_timing(state, timing_id) do
      loaded
      |> Enum.map(&plan_trip(&1, target))
      |> planned_change_set()
    end
  end

  def plan(_command, _state), do: {:error, :invalid_command}

  # One unplannable trip refuses the command structurally; otherwise every
  # eligible trip is an update and every ineligible one an exclusion note.
  defp planned_change_set(planned) do
    case Enum.find(planned, &match?({:error, _}, &1)) do
      nil -> {:ok, change_set(planned)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp change_set(planned) do
    updates = for {:update, update, _loses?} <- planned, do: update
    loses_ids = for {:update, update, true} <- planned, do: update.trip_id
    excluded_ids = for {:excluded, id} <- planned, do: id

    %{
      updates: updates,
      inserts: [],
      deletes: [],
      consequences: consequences(updates, loses_ids, excluded_ids)
    }
  end

  # --- one trip ------------------------------------------------------------

  defp plan_trip({id, loaded}, target) do
    if eligible?(loaded, target) do
      rematerialize(id, loaded, target, not linked?(loaded))
    else
      {:excluded, id}
    end
  end

  # R5's eligibility: the trip must be on the timing's pattern and its ordered
  # stops must match the pattern's occurrences. `:stops_differ` is the exclusion
  # reason for either mismatch, so the review names every ineligible trip.
  defp eligible?(loaded, target) do
    trip = value(loaded, :trip)

    value(trip, :route_pattern_id) == target.pattern_id and
      compatible_stops?(ordered_stop_times(loaded), target.occurrences)
  end

  defp rematerialize(id, loaded, target, loses_custom_times?) do
    rows = ordered_stop_times(loaded)

    with departure when is_integer(departure) <- first_departure(rows),
         {:ok, materialized} <-
           Materializer.materialize(departure, target.occurrences, target.rows) do
      {:update,
       %{
         trip_id: id,
         fields: %{
           timed_pattern_id: target.timing_id,
           pattern_derivation_state: "linked",
           pattern_derivation_reason: nil
         },
         stop_times: stop_time_values(materialized, target.occurrences),
         frequencies: :unchanged
       }, loses_custom_times?}
    else
      _unreadable_or_unexpandable -> {:error, :invalid_command}
    end
  end

  # --- consequences ---------------------------------------------------------

  defp consequences(updates, loses_ids, excluded_ids) do
    no_eligible(updates) ++ loses_custom_times(loses_ids) ++ excluded(excluded_ids)
  end

  defp no_eligible([]), do: [{:error, :no_eligible_trips}]
  defp no_eligible(_updates), do: []

  defp loses_custom_times([]), do: []
  defp loses_custom_times(ids), do: [{:note, {:loses_custom_times, ids}}]

  defp excluded(ids), do: Enum.map(ids, &{:note, {:excluded, &1, :stops_differ}})

  # --- the target timing ----------------------------------------------------

  defp target_timing(state, timing_id) do
    case find_target(state, timing_id) do
      nil -> {:error, :not_found}
      target -> {:ok, target}
    end
  end

  defp find_target(state, timing_id) do
    state
    |> loaded_patterns()
    |> Enum.find_value(&timing_in_pattern(&1, timing_id))
  end

  defp loaded_patterns(state) do
    case value(state, :patterns) do
      %{} = patterns -> patterns
      _patterns -> %{}
    end
  end

  defp timing_in_pattern({pattern_id, entry}, timing_id) do
    entry
    |> value(:timings)
    |> List.wrap()
    |> Enum.find_value(fn timing_entry ->
      timing = value(timing_entry, :timing)

      if value(timing, :id) == timing_id do
        %{
          pattern_id: pattern_id,
          timing_id: value(timing, :id),
          occurrences: entry |> value(:occurrences) |> List.wrap(),
          rows: timing_entry |> value(:rows) |> List.wrap()
        }
      end
    end)
  end

  # --- stop-time values and state helpers ------------------------------------

  # The materialized row is the timing's own row: clocks, timepoint and the three
  # per-stop values all come from the chosen timing, so a custom trip's stored
  # values are replaced too (R5's re-materialization).
  defp stop_time_values(rows, occurrences) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} ->
      %{
        position: occurrence_position(occurrences, index),
        arrival_time: value(row, :arrival_time),
        departure_time: value(row, :departure_time),
        timepoint: value(row, :timepoint),
        pickup_type: value(row, :pickup_type),
        drop_off_type: value(row, :drop_off_type),
        stop_headsign: value(row, :stop_headsign)
      }
    end)
  end

  defp compatible_stops?(rows, occurrences) do
    rows != [] and
      Enum.map(rows, &value(&1, :stop_id)) == Enum.map(occurrences, &value(&1, :stop_id))
  end

  defp occurrence_position(occurrences, index) do
    case Enum.at(occurrences, index - 1) do
      nil -> index
      occurrence -> value(occurrence, :position) || index
    end
  end

  defp load_trips(trip_ids, state) do
    case value(state, :trips) do
      %{} = trips -> load_each(trip_ids, trips)
      _trips -> {:error, :not_found}
    end
  end

  defp load_each(trip_ids, trips) do
    loaded = Enum.map(trip_ids, &{&1, Map.get(trips, &1)})

    if Enum.any?(loaded, fn {_id, loaded} -> is_nil(loaded) end) do
      {:error, :not_found}
    else
      {:ok, loaded}
    end
  end

  defp ordered_stop_times(loaded) do
    loaded
    |> value(:stop_times)
    |> List.wrap()
    |> Enum.sort_by(&{value(&1, :stop_sequence), value(&1, :id)})
  end

  defp first_departure([first | _rest]) do
    case secs(value(first, :departure_time)) do
      departure when is_integer(departure) -> departure
      _unreadable -> nil
    end
  end

  defp first_departure(_rows), do: nil

  defp linked?(loaded), do: value(value(loaded, :trip), :pattern_derivation_state) == "linked"

  defp secs(value) when is_integer(value) and value >= 0, do: value

  defp secs(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> nil
    end
  end

  defp secs(_value), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
