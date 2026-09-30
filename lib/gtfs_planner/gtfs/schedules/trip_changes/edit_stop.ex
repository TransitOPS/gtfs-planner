defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.EditStop do
  @moduledoc """
  Plans one R1 stop-time edit (`:edit_stop`) as a change set.

  The command names one trip, one pattern occurrence position, the typed seconds (or
  `:clear`), the edit mode and the positions the grid shows. The planner maps the
  position through the pattern occurrences onto the trip's ordered stop times, refuses
  a frequency trip (`:frequency_trip`) or a trip whose ordered stops differ from its
  pattern (`:stops_differ`), applies the R1 time rules with `StopTimeEdit.apply/5` or
  `StopTimeEdit.clear/2`, and turns R1's own refusals (`{:out_of_order, position}`,
  `:negative_time`, `:clear_not_allowed`) into `{:error, _}` consequences, so the
  engine writes nothing for them.

  Linkage follows R1: a whole-trip move of an already linked trip (the first stop in
  any mode, or `:anchor`) rematerializes on its own timing and stays linked, so its
  update carries no linkage fields. Every other result is compared with the pattern's
  timings through `TripChanges.relink/3` and either links to the first equal timing or
  becomes custom with reason `edited_in_schedules`; a linked trip that becomes custom
  is reported as `{:note, {:becomes_custom, [trip_id]}}`. No update carries `block_id`.

  The planner is pure (CR-1): it reads only its arguments and never calls `Repo`, the
  clock or process state.
  """

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.StopTimeEdit
  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  @doc """
  Plans one `:edit_stop` command against the loaded review state (R1).

  The trip must be loaded in `state.trips` with its pattern's occurrences; a missing
  trip is `{:error, :not_found}`. A position that names no occurrence of the trip's
  pattern is `{:error, :invalid_command}`; the R1 refusals travel as consequences.
  """
  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :not_found | :invalid_command}
  def plan({:edit_stop, trip_id, params}, state) when is_map(params) do
    case loaded_trip(state, trip_id) do
      %{trip: trip} = loaded -> plan_trip(trip_id, trip, loaded, params, state)
      _missing -> {:error, :not_found}
    end
  end

  def plan(_command, _state), do: {:error, :invalid_command}

  defp plan_trip(id, trip, loaded, params, state) do
    rows = ordered_stop_times(loaded)
    occurrences = pattern_occurrences(state, trip)

    cond do
      frequency_trip?(loaded) ->
        refused(:frequency_trip)

      not matching_stops?(rows, occurrences) ->
        refused(:stops_differ)

      true ->
        plan_edit(id, trip, rows, occurrences, params, state)
    end
  end

  defp plan_edit(id, trip, rows, occurrences, params, state) do
    with {:ok, index} <- position_index(value(params, :position), occurrences),
         {:ok, moved} <- edit_rows(rows, index, params) do
      new_rows = stop_time_values(rows, moved, occurrences)
      {fields, became_custom?} = linkage(trip, new_rows, whole_trip?(params, index), state)

      {:ok,
       %{
         updates: [
           %{trip_id: id, fields: fields, stop_times: new_rows, frequencies: :unchanged}
         ],
         inserts: [],
         deletes: [],
         consequences: consequences(id, became_custom?)
       }}
    else
      {:error, :invalid_command} -> {:error, :invalid_command}
      {:error, reason} -> refused(refusal_reason(reason, occurrences))
    end
  end

  # R1's refusals are consequences, not planner errors: the engine refuses the whole
  # command for any `{:error, _}` consequence without writing a row.
  defp refused(reason) do
    {:ok, %{updates: [], inserts: [], deletes: [], consequences: [{:error, reason}]}}
  end

  # `StopTimeEdit` indexes its list; R1 names the pattern occurrence position.
  defp refusal_reason({:out_of_order, index}, occurrences),
    do: {:out_of_order, occurrence_position(occurrences, index)}

  defp refusal_reason(reason, _occurrences), do: reason

  defp consequences(_id, false), do: []
  defp consequences(id, true), do: [{:note, {:becomes_custom, [id]}}]

  # --- position mapping (R1) ------------------------------------------------

  # A position is an occurrence position of the trip's pattern; the index of the
  # trip's ordered stop times is the occurrence's own index in the ordered list.
  defp position_index(position, occurrences) when is_integer(position) do
    case Enum.find_index(occurrences, &(value(&1, :position) == position)) do
      nil -> {:error, :invalid_command}
      index -> {:ok, index + 1}
    end
  end

  defp position_index(_position, _occurrences), do: {:error, :invalid_command}

  defp occurrence_position(occurrences, index) do
    case Enum.at(occurrences, index - 1) do
      nil -> index
      occurrence -> value(occurrence, :position) || index
    end
  end

  # A trip whose ordered stops differ from its pattern's occurrences cannot be
  # edited positionally; the established rule-table meaning (spec 03's
  # `compatible_stops?/2`) is an exact stop-id list match.
  defp matching_stops?(rows, occurrences) do
    rows != [] and
      Enum.map(rows, &value(&1, :stop_id)) == Enum.map(occurrences, &value(&1, :stop_id))
  end

  # --- the R1 edit ----------------------------------------------------------

  defp edit_rows(rows, index, params) do
    case value(params, :value) do
      :clear ->
        StopTimeEdit.clear(stops(rows), index)

      typed ->
        StopTimeEdit.apply(
          stops(rows),
          index,
          typed,
          value(params, :mode),
          value(params, :shown_positions)
        )
    end
  end

  defp stops(rows) do
    Enum.map(rows, fn row ->
      %{
        arrival: secs(value(row, :arrival_time)),
        departure: secs(value(row, :departure_time)),
        timepoint: value(row, :timepoint)
      }
    end)
  end

  # The stored row keeps its identity flags; the moved stop owns arrival, departure
  # and timepoint, so an `:only` timepoints edit persists the re-spaced stops with
  # `timepoint: 0`.
  defp stop_time_values(rows, moved, occurrences) do
    rows
    |> Enum.zip(moved)
    |> Enum.with_index(1)
    |> Enum.map(fn {{row, stop}, index} ->
      %{
        position: occurrence_position(occurrences, index),
        arrival_time: clock(stop.arrival),
        departure_time: clock(stop.departure),
        timepoint: stop.timepoint,
        pickup_type: value(row, :pickup_type),
        drop_off_type: value(row, :drop_off_type),
        stop_headsign: value(row, :stop_headsign)
      }
    end)
  end

  # --- linkage (R1) ---------------------------------------------------------

  # A whole-trip move of a linked trip rematerializes on its own timing: the shifted
  # rows are the timing at the new first departure, so the linkage fields stay.
  defp linkage(trip, new_rows, true, state) do
    if linked?(trip), do: {%{}, false}, else: relink(trip, new_rows, state)
  end

  defp linkage(trip, new_rows, false, state), do: relink(trip, new_rows, state)

  defp relink(trip, new_rows, state) do
    pattern = pattern_state(state, value(trip, :route_pattern_id))

    case TripChanges.relink(
           new_rows,
           value(pattern, :occurrences) || [],
           value(pattern, :timings) || []
         ) do
      {:linked, timing_id} ->
        {%{
           timed_pattern_id: timing_id,
           pattern_derivation_state: "linked",
           pattern_derivation_reason: nil
         }, false}

      :custom ->
        {%{
           timed_pattern_id: nil,
           pattern_derivation_state: "custom",
           pattern_derivation_reason: "edited_in_schedules"
         }, linked?(trip)}
    end
  end

  defp linked?(trip), do: value(trip, :pattern_derivation_state) == "linked"

  defp whole_trip?(params, index) do
    value(params, :value) != :clear and (value(params, :mode) == :anchor or index == 1)
  end

  # --- state helpers --------------------------------------------------------

  defp loaded_trip(state, trip_id) do
    case value(state, :trips) do
      %{} = trips -> Map.get(trips, trip_id)
      _trips -> nil
    end
  end

  defp pattern_state(state, pattern_id) do
    case value(state, :patterns) do
      %{} = patterns -> Map.get(patterns, pattern_id, %{})
      _patterns -> %{}
    end
  end

  defp pattern_occurrences(state, trip) do
    state
    |> pattern_state(value(trip, :route_pattern_id))
    |> value(:occurrences)
    |> List.wrap()
  end

  defp frequency_trip?(loaded), do: List.wrap(value(loaded, :frequencies)) != []

  defp ordered_stop_times(loaded) do
    loaded
    |> value(:stop_times)
    |> List.wrap()
    |> Enum.sort_by(&{value(&1, :stop_sequence), value(&1, :id)})
  end

  defp clock(nil), do: nil
  defp clock(seconds), do: GtfsTime.format(seconds)

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
