defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.Frequency do
  @moduledoc """
  Plans adding and editing frequency service — `:add_frequency` and
  `:update_frequency` — as one change set (R8, R9).

  `:add_frequency` creates one linked trip on the command's pattern and service:
  the named timing of that pattern materialized at the first window's start, one
  full stop-time row per occurrence, the command's windows as its frequency rows
  with the `exact_times` choice stored on every row, and a trip ID allocated with
  `TripChanges.allocate_trip_ids/5` against `state.existing_trip_ids`. The insert
  carries no `block_id` (R7) and the windows are validated with
  `FrequencyWindows.validate/1` first, so an overlapping or malformed window list is
  an `{:error, {:invalid_windows, errors}}` consequence and no trip is planned. The
  pattern's trips are then checked with `ServiceMix.check/3` including the planned
  frequency trip, so adding frequency service to a pattern whose listed trips run on
  a shared date is an `{:error, {:mixed_service, details}}` consequence the engine
  refuses before any write (R9, FH-10, AC-20); the planned insert still travels with
  the refused review, as `TripChanges.Copy` does.

  `:update_frequency` replaces the trip's frequency rows with the command's windows
  and moves its template by the first-window start change as one R1 `:anchor` move,
  so a linked trip stays linked to its timing and dwell is kept. With
  `exact_times: :keep` every submitted row copies the stored row at its index and a
  row past the stored ones copies the first stored row's value, so an unrelated window
  edit leaves a blank stored `exact_times` blank (FH-9, AC-18). A template that would
  move below 00:00 is an `{:error, :negative_time}` consequence and writes nothing.

  The planner is pure (CR-1): it reads only its arguments and never calls `Repo`, the
  clock or process state.
  """

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.Schedules.FrequencyWindows
  alias GtfsPlanner.Gtfs.Schedules.ServiceMix
  alias GtfsPlanner.Gtfs.Schedules.StopTimeEdit
  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  @doc """
  Plans one `:add_frequency` or `:update_frequency` command against the loaded
  review state (R8).

  The loader provides the target pattern under the pattern's natural
  `route_pattern_id` key with its occurrences and timings, `state.existing_trip_ids`,
  `state.pattern_trips`, `state.service_dates` and the route; an `:add_frequency`
  command names the pattern and timing by UUID, so the entry is found by the pattern
  row's `id`. An `:update_frequency` command names a trip loaded in `state.trips`
  with its stored frequency rows; a missing trip is `{:error, :not_found}`, and a
  trip with no stored frequency rows or a pattern/timing the state does not hold is
  `{:error, :invalid_command}`/`{:error, :not_found}`.
  """
  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :not_found | :invalid_command}
  def plan({:add_frequency, attrs}, state) when is_map(attrs), do: add_frequency(attrs, state)

  def plan({:update_frequency, trip_id, params}, state) when is_map(params),
    do: update_frequency(trip_id, params, state)

  def plan(_command, _state), do: {:error, :invalid_command}

  # --- adding frequency service ---------------------------------------------

  defp add_frequency(attrs, state) do
    windows = List.wrap(value(attrs, :windows))

    case FrequencyWindows.validate(windows) do
      {:error, errors} ->
        {:ok, empty_change_set([{:error, {:invalid_windows, errors}}])}

      :ok ->
        with {:ok, first_start} <- first_window_start(windows),
             {:ok, entry} <- loaded_pattern(state, value(attrs, :pattern_id)),
             {:ok, timing} <- pattern_timing(entry, value(attrs, :timed_pattern_id)),
             {:ok, stop_times} <- template_rows(first_start, entry, timing) do
          service_id = value(attrs, :service_id)
          pattern_id = value(value(entry, :pattern), :route_pattern_id)

          insert = %{
            source_id: nil,
            attrs: insert_attrs(state, entry, timing, service_id, first_start),
            stop_times: stop_times,
            frequencies: frequency_rows(windows, value(attrs, :exact_times), [])
          }

          {:ok,
           %{
             updates: [],
             inserts: [insert],
             deletes: [],
             consequences: mixed_service_errors(state, pattern_id, service_id)
           }}
        end
    end
  end

  # The template follows the earliest window, so a row list submitted out of order
  # still starts the trip at its first departure.
  defp first_window_start([]), do: {:error, :invalid_command}

  defp first_window_start(windows) do
    {:ok, windows |> Enum.map(&value(&1, :start_secs)) |> Enum.min()}
  end

  # `state.patterns` is keyed by the pattern's natural `route_pattern_id` (the engine
  # loads trips and timings by it), while an `:add_frequency` command names the
  # pattern by UUID, as `change_pattern_ids!/4` does.
  defp loaded_pattern(state, pattern_id) do
    patterns = value(state, :patterns)

    if is_map(patterns), do: find_pattern(patterns, pattern_id), else: {:error, :not_found}
  end

  defp find_pattern(patterns, pattern_id) do
    patterns
    |> Enum.find_value(fn {_key, entry} ->
      if value(value(entry, :pattern), :id) == pattern_id, do: entry
    end)
    |> case do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp pattern_timing(entry, timing_id) do
    entry
    |> value(:timings)
    |> List.wrap()
    |> Enum.find_value(fn timing_entry ->
      timing = value(timing_entry, :timing)

      if value(timing, :id) == timing_id do
        %{
          timing_id: value(timing, :id),
          headsign: value(timing, :headsign),
          rows: List.wrap(value(timing_entry, :rows))
        }
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      timing -> {:ok, timing}
    end
  end

  defp template_rows(start_secs, entry, timing) do
    occurrences = List.wrap(value(entry, :occurrences))

    case Materializer.materialize(start_secs, occurrences, timing.rows) do
      {:ok, rows} ->
        {:ok, insert_stop_times(rows, occurrences, value(value(entry, :pattern), :shape_id))}

      {:error, _reason} ->
        {:error, :invalid_command}
    end
  end

  # A created trip's stop rows are full rows: the materialized timing values plus the
  # occurrence's shape distance, the same shape `Schedules.create_trips/3` writes for
  # a linked trip (a pattern without a shape contributes nil distances, R15).
  defp insert_stop_times(rows, occurrences, shape_id) do
    rows
    |> Enum.zip(occurrences)
    |> Enum.map(fn {row, occurrence} ->
      %{
        stop_id: value(row, :stop_id),
        stop_sequence: value(row, :stop_sequence),
        arrival_time: value(row, :arrival_time),
        departure_time: value(row, :departure_time),
        stop_headsign: value(row, :stop_headsign),
        pickup_type: value(row, :pickup_type),
        drop_off_type: value(row, :drop_off_type),
        continuous_pickup: nil,
        continuous_drop_off: nil,
        shape_dist_traveled: shape_distance(occurrence, shape_id),
        timepoint: value(row, :timepoint)
      }
    end)
  end

  defp shape_distance(_occurrence, shape_id) when not is_binary(shape_id), do: nil
  defp shape_distance(occurrence, _shape_id), do: value(occurrence, :shape_dist_traveled)

  # The new trip mirrors `create_trips/3`'s batch: the pattern's direction and shape,
  # the timing's headsign over the pattern's, and the linkage fields the applier
  # writes from the loaded records (never a block).
  defp insert_attrs(state, entry, timing, service_id, start_secs) do
    pattern = value(entry, :pattern)
    route_id = value(value(state, :route), :route_id)
    direction_id = value(pattern, :direction_id)

    [trip_id] =
      TripChanges.allocate_trip_ids(
        route_id,
        direction_id,
        service_id,
        [start_secs],
        List.wrap(value(state, :existing_trip_ids))
      )

    %{
      trip_id: trip_id,
      route_id: route_id,
      service_id: service_id,
      direction_id: direction_id,
      trip_headsign: value(timing, :headsign) || value(pattern, :headsign),
      shape_id: value(pattern, :shape_id),
      route_pattern_id: value(pattern, :route_pattern_id),
      timed_pattern_id: timing.timing_id,
      pattern_derivation_state: "linked",
      pattern_derivation_reason: nil
    }
  end

  # R9 is checked on the pattern this command writes to, with the planned frequency
  # trip added; the other patterns the loader holds are untouched by the command.
  defp mixed_service_errors(state, pattern_id, service_id) do
    before_trips = Enum.map(pattern_trips(state, pattern_id), &trip_kind/1)
    after_trips = before_trips ++ [%{service_id: service_id, frequency?: true}]

    case ServiceMix.check(before_trips, after_trips, value(state, :service_dates) || %{}) do
      :ok -> []
      {:error, error} -> [{:error, error}]
    end
  end

  defp pattern_trips(state, pattern_id) do
    case value(state, :pattern_trips) do
      %{} = pattern_trips -> List.wrap(Map.get(pattern_trips, pattern_id))
      _pattern_trips -> []
    end
  end

  defp trip_kind(trip) do
    %{service_id: value(trip, :service_id), frequency?: value(trip, :frequency?) == true}
  end

  # --- editing frequency service --------------------------------------------

  defp update_frequency(trip_id, params, state) do
    with {:ok, loaded} <- load_trip(trip_id, state),
         {:ok, stored} <- stored_frequencies(loaded) do
      windows = value(params, :windows)
      choice = value(params, :exact_times)

      case FrequencyWindows.validate(List.wrap(windows)) do
        {:error, errors} ->
          {:ok, empty_change_set([{:error, {:invalid_windows, errors}}])}

        :ok ->
          planned_update(trip_id, List.wrap(windows), choice, stored, loaded)
      end
    end
  end

  defp planned_update(trip_id, windows, choice, stored, loaded) do
    case template_shift(ordered_stop_times(loaded), stored, windows) do
      {:ok, stop_times} ->
        {:ok,
         %{
           updates: [
             %{
               trip_id: trip_id,
               fields: %{},
               stop_times: stop_times,
               frequencies: frequency_rows(windows, choice, stored)
             }
           ],
           inserts: [],
           deletes: [],
           consequences: []
         }}

      {:error, :invalid_command} = error ->
        error

      {:error, reason} ->
        {:ok, empty_change_set([{:error, reason}])}
    end
  end

  # An update replaces the rows of a trip that already runs on a frequency; a trip
  # with no stored rows has nothing to replace.
  defp stored_frequencies(loaded) do
    case ordered_frequencies(loaded) do
      [] -> {:error, :invalid_command}
      stored -> {:ok, stored}
    end
  end

  # Stored clocks may be unpadded ("9:00:00"), so rows sort by their parsed start;
  # an unreadable start sorts last.
  defp ordered_frequencies(loaded) do
    loaded
    |> value(:frequencies)
    |> List.wrap()
    |> Enum.sort_by(fn row ->
      start = value(row, :start_time)

      case secs(start) do
        nil -> {1, 0, to_string(start)}
        seconds -> {0, seconds, ""}
      end
    end)
  end

  # The template moves by the first window's start change; a command that leaves the
  # first window where it is keeps the stored stop times untouched, and dropping every
  # window leaves the template as the listed trip's stop times.
  defp template_shift(_rows, _stored, []), do: {:ok, :unchanged}

  defp template_shift(rows, stored, windows) do
    with {:ok, stored_start} <- stored_first_start(stored),
         {:ok, new_start} <- first_window_start(windows) do
      delta = new_start - stored_start
      if delta == 0, do: {:ok, :unchanged}, else: shift_template(rows, delta)
    end
  end

  # The earliest stored window's start: the clock a template shift is measured from.
  defp stored_first_start(stored) do
    stored
    |> Enum.map(&secs(value(&1, :start_time)))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> {:error, :invalid_command}
      secs -> {:ok, secs}
    end
  end

  # R1's whole-trip `:anchor` move: every clock of the template moves by the same
  # amount, dwell and per-stop values are kept, and a result below 00:00 is refused.
  defp shift_template(rows, delta) do
    anchor = anchor_secs(rows)

    cond do
      not is_integer(anchor) -> {:error, :invalid_command}
      anchor + delta < 0 -> {:error, :negative_time}
      true -> move_stops(rows, anchor + delta)
    end
  end

  defp move_stops(rows, new_anchor) do
    case StopTimeEdit.apply(stops(rows), 1, new_anchor, :anchor, :all) do
      {:ok, moved} -> {:ok, stop_time_values(rows, moved)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The anchor rule of the first stop: its departure, or its arrival when only one
  # clock is stored.
  defp anchor_secs([first | _rest]) do
    secs(value(first, :departure_time)) || secs(value(first, :arrival_time))
  end

  defp anchor_secs(_rows), do: nil

  defp stops(rows) do
    Enum.map(rows, fn row ->
      %{
        arrival: secs(value(row, :arrival_time)),
        departure: secs(value(row, :departure_time)),
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
        arrival_time: clock(stop.arrival),
        departure_time: clock(stop.departure),
        timepoint: value(row, :timepoint),
        pickup_type: value(row, :pickup_type),
        drop_off_type: value(row, :drop_off_type),
        stop_headsign: value(row, :stop_headsign)
      }
    end)
  end

  # --- frequency rows -------------------------------------------------------

  defp frequency_rows(windows, choice, stored) do
    windows
    |> Enum.with_index()
    |> Enum.map(fn {window, index} ->
      %{
        start_time: GtfsTime.format(value(window, :start_secs)),
        end_time: GtfsTime.format(value(window, :end_secs)),
        headway_secs: value(window, :headway_secs),
        exact_times: row_exact_times(choice, index, stored)
      }
    end)
  end

  defp row_exact_times(choice, _index, _stored) when choice in [0, 1], do: choice

  defp row_exact_times(:keep, index, stored) do
    row = Enum.at(stored, index) || List.first(stored)
    value(row, :exact_times)
  end

  # --- helpers --------------------------------------------------------------

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

  defp ordered_stop_times(loaded) do
    loaded
    |> value(:stop_times)
    |> List.wrap()
    |> Enum.sort_by(&{value(&1, :stop_sequence), value(&1, :id)})
  end

  defp empty_change_set(consequences) do
    %{updates: [], inserts: [], deletes: [], consequences: consequences}
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
