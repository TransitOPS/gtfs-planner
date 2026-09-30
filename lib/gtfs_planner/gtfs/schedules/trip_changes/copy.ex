defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.Copy do
  @moduledoc """
  Plans an R7 copy — Copy to calendar, Duplicate trips and a pasted copy — as a
  change set of inserts.

  Every selected trip becomes one insert: a new `trip_id` allocated with
  `TripChanges.allocate_trip_ids/5` against `state.existing_trip_ids`, the source's
  pattern and linkage, its rider-facing metadata (headsign, accessibility, bikes and
  shape), every stop-time clock moved by the offset with its stop, sequence, flags
  and shape distance copied from the source row, and the source's frequency windows
  moved by the offset. The insert carries no `block_id` and the command writes no
  transfer row, so a copy starts unblocked with no in-seat records (R7, FH-23,
  CR-8). The trip number (`trip_short_name`) is copied only when the target service
  differs from the source's, because a trip number is unique within a service day
  (FH-25).

  "Skip trips that already leave at the same time" is on by default: a copy whose
  target pattern and service already has a listed trip at the same first departure —
  whether that trip was loaded or planned earlier in this same command — is skipped
  and reported as `{:note, {:skipped_existing, id, clock}}` (R7, FH-24). A source
  service that shares dates with the target is stated once per source service as
  `{:warning, {:shared_dates, service, dates}}` (AC-14). Every affected pattern is
  checked with `ServiceMix.check/3` including the planned inserts, so a copy that
  would make a pattern and date carry listed and frequency trips for the first time
  is an `{:error, {:mixed_service, details}}` consequence the engine refuses before
  any write (R9, INV-5, AC-20).

  The planner is pure (CR-1): it reads only its arguments and never calls `Repo`,
  the clock or process state.
  """

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.ServiceMix
  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  @doc """
  Plans one `:copy` command against the loaded review state (R7 and R9).

  Every command trip must be loaded in `state.trips`; a missing one is
  `{:error, :not_found}`. A trip whose stored clocks cannot be read or that has no
  first departure is `{:error, :invalid_command}`; a trip whose clocks or windows
  would fall below 00:00 is an `{:error, :negative_time}` consequence and produces
  no insert. For this command the loader provides `state.existing_trip_ids`,
  `state.pattern_trips` and `state.service_dates`, which the ID allocator, the R9
  check and the shared-date warning read.
  """
  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :not_found | :invalid_command}
  def plan({:copy, trip_ids, service_id, offset, skip_existing}, state)
      when is_list(trip_ids) and is_binary(service_id) and is_integer(offset) do
    with {:ok, loaded} <- load_trips(trip_ids, state),
         {:ok, planned} <- plan_trips(loaded, offset) do
      planned = mark_skipped(planned, skip_existing, duplicate_candidates(state, service_id))
      ids = allocate_ids(planned, service_id, state)

      {:ok,
       %{
         updates: [],
         inserts: inserts(planned, ids, service_id),
         deletes: [],
         consequences: consequences(planned, service_id, state)
       }}
    end
  end

  def plan(_command, _state), do: {:error, :invalid_command}

  # --- planning -------------------------------------------------------------

  defp plan_trips(loaded, offset) do
    loaded
    |> Enum.reduce_while({:ok, []}, fn {id, entry}, {:ok, acc} ->
      case plan_trip(id, entry, offset) do
        {:ok, plan} -> {:cont, {:ok, [plan | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, _reason} = error -> error
    end
  end

  defp plan_trip(id, entry, offset) do
    trip = value(entry, :trip)
    rows = ordered_stop_times(entry)

    with {:ok, new_rows} <- shifted_rows(rows, offset),
         {:ok, new_frequencies} <- shifted_windows(List.wrap(value(entry, :frequencies)), offset),
         {:ok, departure} <- start_secs(new_rows) do
      {:ok, plan(id, trip, new_rows, new_frequencies, departure)}
    else
      # One trip's result falling below 00:00 refuses that copy; the review renders
      # the error and the engine refuses the whole command before any write.
      {:error, :negative_time} -> {:ok, plan(id, trip, nil, [], nil, :negative_time)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan(id, trip, new_rows, new_frequencies, departure, error \\ nil) do
    %{
      id: id,
      trip: trip,
      new_rows: new_rows,
      new_frequencies: new_frequencies,
      new_departure: departure,
      error: error,
      skipped?: false
    }
  end

  # Every clock moves by the offset; a nil clock (a cleared intermediate stop)
  # stays nil and every other source column is copied unchanged.
  defp shifted_rows(rows, offset) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      with {:ok, arrival} <- shift_clock(value(row, :arrival_time), offset),
           {:ok, departure} <- shift_clock(value(row, :departure_time), offset) do
        {:cont, {:ok, [insert_stop_time(row, arrival, departure) | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finish()
  end

  defp insert_stop_time(row, arrival, departure) do
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

  defp shift_clock(nil, _offset), do: {:ok, nil}

  defp shift_clock(secs, offset) when is_integer(secs) and secs >= 0 do
    if secs + offset >= 0,
      do: {:ok, GtfsTime.format(secs + offset)},
      else: {:error, :negative_time}
  end

  defp shift_clock(clock, offset) when is_binary(clock) do
    case GtfsTime.parse(clock) do
      {:ok, secs} -> shift_clock(secs, offset)
      {:error, :invalid_time} -> {:error, :invalid_command}
    end
  end

  defp shift_clock(_clock, _offset), do: {:error, :invalid_command}

  # A frequency window keeps its headway and stored exact-times choice; both clocks
  # move by the offset.
  defp shifted_windows(frequencies, offset) do
    frequencies
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      with {:ok, start_time} <- shift_window_clock(value(row, :start_time), offset),
           {:ok, end_time} <- shift_window_clock(value(row, :end_time), offset) do
        window = %{
          start_time: start_time,
          end_time: end_time,
          headway_secs: value(row, :headway_secs),
          exact_times: value(row, :exact_times)
        }

        {:cont, {:ok, [window | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finish()
  end

  defp shift_window_clock(clock, offset) do
    case shift_clock(clock, offset) do
      {:ok, nil} -> {:error, :invalid_command}
      {:ok, shifted} -> {:ok, shifted}
      {:error, _reason} = error -> error
    end
  end

  # The copied trip's start is its first row's departure, or its arrival at a trip
  # whose first stop stores only one clock (the ID allocator's stamp).
  defp start_secs([first | _rest]) do
    case secs(value(first, :departure_time)) || secs(value(first, :arrival_time)) do
      nil -> {:error, :invalid_command}
      secs -> {:ok, secs}
    end
  end

  defp start_secs(_rows), do: {:error, :invalid_command}

  # --- skip existing --------------------------------------------------------

  defp mark_skipped(planned, skip_existing, candidates) do
    {planned, _taken} =
      Enum.map_reduce(planned, candidates, fn plan, taken ->
        if skip?(plan, skip_existing, taken) do
          {%{plan | skipped?: true}, taken}
        else
          {plan, taken |> put_departure(plan)}
        end
      end)

    planned
  end

  defp skip?(%{error: error}, _skip_existing, _taken) when not is_nil(error), do: false

  defp skip?(plan, skip_existing, taken),
    do: skip_existing and MapSet.member?(taken, departure_key(plan))

  defp put_departure(taken, %{error: nil} = plan), do: MapSet.put(taken, departure_key(plan))

  defp put_departure(taken, _plan), do: taken

  defp departure_key(plan), do: {value(plan.trip, :route_pattern_id), plan.new_departure}

  # Every listed trip of the pattern the loader already holds that runs on the
  # target service, as the target departures a copy would duplicate. Planned
  # inserts join the set as they are kept, so a batch never creates two trips at
  # one departure either.
  defp duplicate_candidates(state, service_id) do
    case value(state, :trips) do
      %{} = trips ->
        trips
        |> Enum.flat_map(&candidate(&1, service_id))
        |> MapSet.new()

      _trips ->
        MapSet.new()
    end
  end

  defp candidate({_id, entry}, service_id) do
    trip = value(entry, :trip)
    pattern_id = value(trip, :route_pattern_id)

    with true <- value(trip, :service_id) == service_id,
         true <- List.wrap(value(entry, :frequencies)) == [],
         true <- is_binary(pattern_id),
         {:ok, departure} <- start_secs(ordered_stop_times(entry)) do
      [{pattern_id, departure}]
    else
      _skip -> []
    end
  end

  # --- inserts --------------------------------------------------------------

  defp allocate_ids(planned, service_id, state) do
    existing = List.wrap(value(state, :existing_trip_ids))

    planned
    |> Enum.filter(&copy_planned?/1)
    |> Enum.group_by(fn plan -> value(plan.trip, :direction_id) end)
    |> Enum.sort_by(fn {direction, _plans} -> direction end)
    |> Enum.reduce(%{}, fn {_direction, plans}, ids ->
      first = hd(plans)
      starts = Enum.map(plans, & &1.new_departure)

      route_id = value(first.trip, :route_id)
      direction = value(first.trip, :direction_id)

      plans
      |> Enum.zip(
        TripChanges.allocate_trip_ids(route_id, direction, service_id, starts, existing)
      )
      |> Enum.reduce(ids, fn {plan, trip_id}, acc -> Map.put(acc, plan.id, trip_id) end)
    end)
  end

  defp copy_planned?(plan), do: plan.error == nil and not plan.skipped?

  defp inserts(planned, ids, service_id) do
    for plan <- planned, copy_planned?(plan) do
      %{
        source_id: plan.id,
        attrs: insert_attrs(plan, Map.fetch!(ids, plan.id), service_id),
        stop_times: plan.new_rows,
        frequencies: plan.new_frequencies
      }
    end
  end

  defp insert_attrs(plan, trip_id, service_id) do
    trip = plan.trip

    %{
      trip_id: trip_id,
      route_id: value(trip, :route_id),
      service_id: service_id,
      direction_id: value(trip, :direction_id),
      trip_headsign: value(trip, :trip_headsign),
      trip_short_name: trip_short_name(plan, service_id),
      wheelchair_accessible: value(trip, :wheelchair_accessible),
      bikes_allowed: value(trip, :bikes_allowed),
      cars_allowed: value(trip, :cars_allowed),
      shape_id: value(trip, :shape_id),
      route_pattern_id: value(trip, :route_pattern_id),
      timed_pattern_id: value(trip, :timed_pattern_id),
      pattern_derivation_state: value(trip, :pattern_derivation_state),
      pattern_derivation_reason: value(trip, :pattern_derivation_reason)
    }
  end

  defp trip_short_name(plan, service_id) do
    if value(plan.trip, :service_id) == service_id,
      do: nil,
      else: value(plan.trip, :trip_short_name)
  end

  # --- consequences ---------------------------------------------------------

  defp consequences(planned, service_id, state) do
    negative_time_errors(planned) ++
      mixed_service_errors(planned, service_id, state) ++
      shared_dates_warnings(planned, service_id, state) ++
      skipped_notes(planned)
  end

  defp negative_time_errors(planned) do
    planned
    |> Enum.flat_map(fn plan -> if plan.error, do: [{:error, plan.error}], else: [] end)
    |> Enum.uniq()
  end

  # R9 checks each affected pattern's trips with the planned inserts added; an
  # untouched pattern's before and after lists are equal, so its check is `:ok`.
  defp mixed_service_errors(planned, service_id, state) do
    service_dates = value(state, :service_dates) || %{}
    pattern_trips = value(state, :pattern_trips) || %{}
    added = inserts_by_pattern(planned, service_id)

    pattern_trips
    |> Enum.sort_by(fn {pattern_id, _trips} -> pattern_id end)
    |> Enum.flat_map(fn {pattern_id, trips} ->
      before_trips = Enum.map(trips, &trip_kind/1)

      case ServiceMix.check(
             before_trips,
             before_trips ++ Map.get(added, pattern_id, []),
             service_dates
           ) do
        :ok -> []
        {:error, error} -> [{:error, error}]
      end
    end)
  end

  defp inserts_by_pattern(planned, service_id) do
    planned
    |> Enum.filter(&copy_planned?/1)
    |> Enum.group_by(
      fn plan -> value(plan.trip, :route_pattern_id) end,
      fn plan -> %{service_id: service_id, frequency?: plan.new_frequencies != []} end
    )
  end

  defp trip_kind(trip) do
    %{service_id: value(trip, :service_id), frequency?: value(trip, :frequency?) == true}
  end

  # One statement per source service day the copies leave, naming the dates the
  # source and target services share.
  defp shared_dates_warnings(planned, service_id, state) do
    service_dates = value(state, :service_dates) || %{}
    target_dates = date_set(service_dates, service_id)

    planned
    |> Enum.map(&value(&1.trip, :service_id))
    |> Enum.reject(&(is_nil(&1) or &1 == service_id))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn source_service ->
      shared = MapSet.intersection(date_set(service_dates, source_service), target_dates)

      case MapSet.size(shared) do
        0 -> []
        count -> [{:warning, {:shared_dates, source_service, count}}]
      end
    end)
  end

  defp date_set(service_dates, service_id),
    do: MapSet.new(Map.get(service_dates, service_id, []))

  defp skipped_notes(planned) do
    for plan <- planned, plan.skipped? do
      {:note, {:skipped_existing, plan.id, GtfsTime.format(plan.new_departure)}}
    end
  end

  # --- helpers --------------------------------------------------------------

  defp load_trips(trip_ids, state) do
    case value(state, :trips) do
      %{} = trips -> load_each(trip_ids, trips)
      _trips -> {:error, :not_found}
    end
  end

  defp load_each(trip_ids, trips) do
    loaded = Enum.map(trip_ids, &{&1, Map.get(trips, &1)})

    if Enum.any?(loaded, fn {_id, entry} -> is_nil(entry) end) do
      {:error, :not_found}
    else
      {:ok, loaded}
    end
  end

  defp ordered_stop_times(entry) do
    entry
    |> value(:stop_times)
    |> List.wrap()
    |> Enum.sort_by(&{value(&1, :stop_sequence), value(&1, :id)})
  end

  defp secs(value) when is_integer(value) and value >= 0, do: value

  defp secs(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, secs} -> secs
      {:error, :invalid_time} -> nil
    end
  end

  defp secs(_value), do: nil

  defp finish({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp finish({:error, _reason} = error), do: error

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
