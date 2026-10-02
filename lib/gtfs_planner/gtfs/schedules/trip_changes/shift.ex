defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.Shift do
  @moduledoc """
  Plans an R4 Shift — Shift times and the direct nudges built from it — as a change set.

  Every selected trip moves by `delta` seconds. Without `from_position` the whole trip
  moves: a trip already linked to a timing keeps that linkage and its stored rows are the
  timing materialized at the new first departure, while any other trip is compared with
  the pattern's timings through `TripChanges.relink/3` and stays or becomes custom
  (reason `edited_in_schedules`) when none matches (R1). With `from_position`, only that
  occurrence and every later one move (`StopTimeEdit.apply/5`, `:later`, All stops) and
  the same relink rule decides the result. Frequency trips move their windows and
  template instead, and a `from_position` shift excludes them because frequency service
  moves as a whole (R4).

  Consequences are emitted in the order the review renders them: the `:negative_time`
  refusal, the block findings `Blocking.project_trip_changes/2` reports as added, the
  trips that now start at or after 24:00, a listed trip that already leaves at the
  shifted first departure on the same pattern and service, the trips that become custom,
  the frequency windows that moved and the excluded frequency trips. A refused trip
  produces no update; the engine refuses the whole command when any `{:error, _}`
  consequence is present (INV-3). No update carries `block_id`, so a shift keeps blocks
  (FH-19).

  The planner is pure (CR-1): it reads only its arguments and never calls `Repo`, the
  clock or process state.
  """

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.StopTimeEdit
  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  @day_seconds 86_400
  @frequency_exclusion :frequency_whole

  @doc """
  Plans one `:shift` command against the loaded review state (R4 and R1's whole-trip
  rule).

  Every command trip must be loaded in `state.trips`; a missing one is
  `{:error, :not_found}`. A `from_position` past a trip's last stop is
  `{:error, :invalid_command}`.
  """
  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :not_found | :invalid_command}
  def plan({:shift, trip_ids, delta, from_position}, state)
      when is_list(trip_ids) and is_integer(delta) do
    with {:ok, loaded} <- load_trips(trip_ids, state),
         planned = Enum.map(loaded, &plan_trip(&1, delta, from_position, state)),
         :ok <- valid_plans(planned) do
      {:ok,
       %{
         updates: planned |> Enum.map(& &1.update) |> Enum.reject(&is_nil/1),
         inserts: [],
         deletes: [],
         consequences: consequences(planned, state)
       }}
    end
  end

  def plan(_command, _state), do: {:error, :invalid_command}

  # --- one trip ------------------------------------------------------------

  defp plan_trip({id, loaded}, delta, from_position, state) do
    trip = value(loaded, :trip)
    rows = ordered_stop_times(loaded)
    frequencies = List.wrap(value(loaded, :frequencies))

    if frequencies == [] do
      plan_listed(id, trip, rows, delta, from_position, state)
    else
      plan_frequency(id, trip, rows, frequencies, delta, from_position)
    end
  end

  defp plan_listed(id, trip, rows, delta, from_position, state) do
    case shift_rows(rows, delta, from_position) do
      {:ok, new_rows} ->
        {fields, linked_after?} = linkage(trip, new_rows, from_position, state)
        linked_before? = linked?(trip)

        base(id, trip, rows)
        |> Map.merge(%{
          new_rows: new_rows,
          became_custom?: linked_before? and not linked_after?,
          update: %{
            trip_id: id,
            fields: fields,
            stop_times: new_rows,
            frequencies: :unchanged
          }
        })

      {:error, reason} ->
        base(id, trip, rows) |> Map.put(:error, reason)
    end
  end

  # A structural refusal (a `from_position` past a trip's rows, or an unreadable stored
  # window) refuses the whole command before any consequence is built; R1's own refusals
  # travel as consequences so the review can render them.
  defp valid_plans(planned) do
    if Enum.any?(planned, &(&1.error == :invalid_command)) do
      {:error, :invalid_command}
    else
      :ok
    end
  end

  defp plan_frequency(id, trip, rows, frequencies, delta, from_position) do
    plan = base(id, trip, rows) |> Map.put(:frequency?, true)

    if is_integer(from_position) do
      Map.put(plan, :excluded?, true)
    else
      case shift_frequency(frequencies, rows, delta) do
        {:ok, new_rows, windows} ->
          Map.merge(plan, %{
            new_rows: new_rows,
            windows_moved?: true,
            update: %{
              trip_id: id,
              fields: %{},
              stop_times: new_rows,
              frequencies: windows
            }
          })

        {:error, reason} ->
          Map.put(plan, :error, reason)
      end
    end
  end

  defp shift_frequency(frequencies, rows, delta) do
    with {:ok, new_rows} <- shift_rows(rows, delta, nil),
         {:ok, windows} <- shift_windows(frequencies, delta) do
      {:ok, new_rows, windows}
    end
  end

  # --- the R1 move ---------------------------------------------------------

  defp shift_rows(rows, delta, from_position) do
    position = from_position || 1
    anchor = anchor_secs(rows, position)

    cond do
      position > length(rows) ->
        {:error, :invalid_command}

      is_nil(anchor) ->
        {:error, :invalid_command}

      anchor + delta < 0 ->
        {:error, :negative_time}

      true ->
        mode = if from_position, do: :later, else: :anchor

        case StopTimeEdit.apply(stops(rows), position, anchor + delta, mode, :all) do
          {:ok, moved} -> {:ok, stop_time_values(rows, moved)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The anchor rule `StopTimeEdit.anchor_value/2` uses: the last stop edits arrival,
  # every other stop its departure.
  defp anchor_secs(rows, position) do
    row = Enum.at(rows, position - 1)

    if position == length(rows) do
      GtfsTime.coerce(value(row, :arrival_time)) || GtfsTime.coerce(value(row, :departure_time))
    else
      GtfsTime.coerce(value(row, :departure_time)) || GtfsTime.coerce(value(row, :arrival_time))
    end
  end

  defp stops(rows) do
    Enum.map(rows, fn row ->
      %{
        arrival: GtfsTime.coerce(value(row, :arrival_time)),
        departure: GtfsTime.coerce(value(row, :departure_time)),
        timepoint: value(row, :timepoint)
      }
    end)
  end

  defp stop_time_values(rows, moved) do
    rows
    |> Enum.zip(moved)
    |> Enum.with_index(1)
    |> Enum.map(fn {{row, stop}, position} ->
      %{
        position: position,
        arrival_time: stop.arrival && GtfsTime.format(stop.arrival),
        departure_time: stop.departure && GtfsTime.format(stop.departure),
        timepoint: value(row, :timepoint),
        pickup_type: value(row, :pickup_type),
        drop_off_type: value(row, :drop_off_type),
        stop_headsign: value(row, :stop_headsign)
      }
    end)
  end

  defp shift_windows(frequencies, delta) do
    frequencies
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case shifted_window(row, delta) do
        {:ok, window} -> {:cont, {:ok, [window | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      {:error, _reason} = error -> error
    end
  end

  defp shifted_window(row, delta) do
    with {:ok, start_secs} <- GtfsTime.parse(value(row, :start_time)),
         {:ok, end_secs} <- GtfsTime.parse(value(row, :end_time)),
         true <- start_secs + delta >= 0 and end_secs + delta >= 0 do
      {:ok,
       %{
         start_time: GtfsTime.format(start_secs + delta),
         end_time: GtfsTime.format(end_secs + delta),
         headway_secs: value(row, :headway_secs),
         exact_times: value(row, :exact_times)
       }}
    else
      false -> {:error, :negative_time}
      _error -> {:error, :invalid_command}
    end
  end

  # --- linkage (R1) --------------------------------------------------------

  defp linkage(trip, new_rows, from_position, state) do
    if is_nil(from_position) and linked?(trip) do
      {%{}, true}
    else
      case relink(new_rows, trip, state) do
        {:linked, timing_id} ->
          {%{
             timed_pattern_id: timing_id,
             pattern_derivation_state: "linked",
             pattern_derivation_reason: nil
           }, true}

        :custom ->
          {%{
             timed_pattern_id: nil,
             pattern_derivation_state: "custom",
             pattern_derivation_reason: "edited_in_schedules"
           }, false}
      end
    end
  end

  defp relink(new_rows, trip, state) do
    pattern = pattern_state(state, value(trip, :route_pattern_id))

    TripChanges.relink(
      new_rows,
      value(pattern, :occurrences) || [],
      value(pattern, :timings) || []
    )
  end

  defp pattern_state(state, pattern_id) do
    case value(state, :patterns) do
      %{} = patterns -> Map.get(patterns, pattern_id, %{})
      _patterns -> %{}
    end
  end

  defp linked?(trip), do: value(trip, :pattern_derivation_state) == "linked"

  # --- consequences --------------------------------------------------------

  defp consequences(planned, state) do
    errors =
      planned
      |> Enum.map(& &1.error)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&{:error, &1})

    errors ++
      block_findings(planned, state) ++
      crosses_midnight(planned) ++
      duplicate_departures(planned, state) ++
      becomes_custom(planned) ++
      windows_moved(planned) ++
      excluded(planned)
  end

  defp block_findings(planned, state) do
    inputs = value(state, :block_inputs)
    rows = if is_map(inputs), do: List.wrap(value(inputs, :trips)), else: []

    with true <- is_map(inputs),
         changed when changed != [] <- changed_trip_rows(planned, rows) do
      projection = Blocking.project_trip_changes(inputs, changed)
      added = added_findings(projection.before_findings, projection.after_findings)

      if added == [], do: [], else: [{:warning, {:block_findings, added}}]
    else
      _none -> []
    end
  end

  # One projection carries every moved trip, with each row's endpoints read from the
  # result's new clocks (excluded trips keep their loaded row).
  defp changed_trip_rows(planned, rows) do
    planned
    |> Enum.filter(& &1.new_rows)
    |> Enum.flat_map(fn plan ->
      case Enum.find(rows, &(value(&1, :id) == plan.id)) do
        nil ->
          []

        row ->
          {first_arrival, first_departure, last_arrival, last_departure} =
            endpoints(plan.new_rows)

          [
            Map.merge(row, %{
              first_arrival: first_arrival,
              first_departure: first_departure,
              last_arrival: last_arrival,
              last_departure: last_departure
            })
          ]
      end
    end)
  end

  defp added_findings(before, after_findings) do
    before_keys = MapSet.new(before, &Checks.finding_key/1)

    Enum.reject(after_findings, &MapSet.member?(before_keys, Checks.finding_key(&1)))
  end

  defp crosses_midnight(planned) do
    ids = for plan <- planned, crossed_midnight?(plan), do: plan.id

    if ids == [], do: [], else: [{:note, {:crosses_midnight, ids}}]
  end

  defp crossed_midnight?(plan) do
    old = first_time(plan.rows)
    new = first_time(plan.new_rows)

    is_integer(old) and is_integer(new) and old < @day_seconds and new >= @day_seconds
  end

  defp duplicate_departures(planned, state) do
    candidates = duplicate_candidates(state)
    selected = MapSet.new(Enum.map(planned, & &1.id))

    planned
    |> Enum.filter(&(&1.new_rows && not &1.frequency?))
    |> Enum.flat_map(&duplicate_warning(&1, candidates, selected))
  end

  defp duplicate_warning(plan, candidates, selected) do
    case first_departure(plan.new_rows) do
      nil ->
        []

      departure ->
        if duplicate_departure?(candidates, plan, departure, selected) do
          [{:warning, {:duplicate_departure, plan.id, GtfsTime.format(departure)}}]
        else
          []
        end
    end
  end

  # Every trip the review state holds, as `{id, service_id, pattern, listed?, first
  # departure}`; the block inputs add the trips a block projection loaded. The same-time
  # check reads both, so it fires whichever set the loader filled.
  defp duplicate_candidates(state) do
    (loaded_trip_candidates(state) ++ block_trip_candidates(state))
    |> Enum.uniq_by(& &1.id)
  end

  defp loaded_trip_candidates(state) do
    case value(state, :trips) do
      %{} = trips ->
        for {id, loaded} <- trips do
          trip = value(loaded, :trip)

          %{
            id: id,
            service_id: value(trip, :service_id),
            route_pattern_id: value(trip, :route_pattern_id),
            frequency?: List.wrap(value(loaded, :frequencies)) != [],
            first_departure: first_departure(ordered_stop_times(loaded))
          }
        end

      _trips ->
        []
    end
  end

  defp block_trip_candidates(state) do
    state
    |> block_trip_rows()
    |> Enum.map(fn row ->
      %{
        id: value(row, :id),
        service_id: value(row, :service_id),
        route_pattern_id: value(row, :route_pattern_id),
        frequency?: value(row, :frequency?) == true,
        first_departure: value(row, :first_departure)
      }
    end)
  end

  defp duplicate_departure?(candidates, plan, departure, selected) do
    trip = plan.trip

    Enum.any?(candidates, fn candidate ->
      candidate.frequency? == false and
        candidate.service_id == value(trip, :service_id) and
        candidate.route_pattern_id == value(trip, :route_pattern_id) and
        candidate.first_departure == departure and
        not MapSet.member?(selected, candidate.id)
    end)
  end

  defp becomes_custom(planned) do
    ids = for plan <- planned, plan.became_custom?, do: plan.id

    if ids == [], do: [], else: [{:note, {:becomes_custom, ids}}]
  end

  defp windows_moved(planned) do
    ids = for plan <- planned, plan.windows_moved?, do: plan.id

    if ids == [], do: [], else: [{:note, {:windows_moved, ids}}]
  end

  defp excluded(planned) do
    for plan <- planned, plan.excluded?, do: {:note, {:excluded, plan.id, @frequency_exclusion}}
  end

  defp block_trip_rows(state) do
    inputs = value(state, :block_inputs)

    if is_map(inputs), do: List.wrap(value(inputs, :trips)), else: []
  end

  # --- helpers -------------------------------------------------------------

  defp load_trips(trip_ids, state) do
    case value(state, :trips) do
      %{} = trips -> load_each(trip_ids, trips)
      _trips -> {:error, :not_found}
    end
  end

  defp load_each(trip_ids, trips) do
    loaded = Enum.map(trip_ids, &{&1, Map.get(trips, &1)})

    if Enum.any?(loaded, fn {_id, trip} -> is_nil(trip) end) do
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

  defp first_time(rows) when is_list(rows) do
    case rows do
      [first | _rest] ->
        GtfsTime.coerce(value(first, :departure_time)) ||
          GtfsTime.coerce(value(first, :arrival_time))

      [] ->
        nil
    end
  end

  defp first_time(_rows), do: nil

  defp first_departure(rows) when is_list(rows) do
    case rows do
      [first | _rest] -> GtfsTime.coerce(value(first, :departure_time))
      [] -> nil
    end
  end

  defp first_departure(_rows), do: nil

  defp endpoints(rows) when is_list(rows) do
    first = List.first(rows)
    last = List.last(rows)

    {GtfsTime.coerce(value(first, :arrival_time)), GtfsTime.coerce(value(first, :departure_time)),
     GtfsTime.coerce(value(last, :arrival_time)), GtfsTime.coerce(value(last, :departure_time))}
  end

  defp endpoints(_rows), do: {nil, nil, nil, nil}

  defp base(id, trip, rows) do
    %{
      id: id,
      trip: trip,
      rows: rows,
      new_rows: nil,
      update: nil,
      error: nil,
      excluded?: false,
      frequency?: false,
      windows_moved?: false,
      became_custom?: false
    }
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
