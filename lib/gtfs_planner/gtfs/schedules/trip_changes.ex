defmodule GtfsPlanner.Gtfs.Schedules.TripChanges do
  @moduledoc """
  Owns the reviewed trip-change contract: commands, change sets, reviews and the
  fingerprint a review and its apply share (R3, design decisions 1–3).

  Every write in this package is one *command* that a pure planner turns into a
  *change set* of updates, inserts and deletes. This module fixes the shapes of
  both (INV-4) and owns `validate/1`, the `plan/2` dispatch, the R3 `fingerprint/3`,
  the R1 `relink/3` linkage comparison and the trip-ID `allocate_trip_ids/5` moved
  here from `Schedules`. Per design decision 2 each command step adds one planner
  module and one `plan/2` clause; per design decision 3 a reviewed command applies
  only when the engine recomputes an equal fingerprint, and a direct command is
  fenced by the affected trips' `updated_at` values instead.

  Everything here is pure (design decision 1, CR-1): the functions read only their
  arguments and never call `Repo`, the clock or process state. The engine (step 10
  onward) loads `state()` and owns locks, transactions and writes.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.Schedules.FrequencyWindows
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.Convert
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.Copy
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.EditStop
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.Frequency
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.MoveCalendar
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.Restore
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.SetTiming
  alias GtfsPlanner.Gtfs.Schedules.TripChanges.Shift

  @max_trips 500
  @max_delta_secs 24 * 3_600
  @stop_edit_modes [:later, :only, :anchor]

  @typedoc """
  One planned command.

  `:shift` carries a whole-minute delta in seconds (nonzero, within ±24 h) and an
  optional 1-based `from_position`; `:copy` carries the target service, an offset
  in seconds (a whole minute, zero allowed) and `skip_existing`.
  """
  @type command ::
          {:edit_stop, Ecto.UUID.t(),
           %{
             position: pos_integer(),
             value: non_neg_integer() | :clear,
             mode: :later | :only | :anchor,
             shown_positions: [pos_integer()] | :all
           }}
          | {:shift, [Ecto.UUID.t()], integer(), pos_integer() | nil}
          | {:set_timing, [Ecto.UUID.t()], Ecto.UUID.t()}
          | {:move_calendar, [Ecto.UUID.t()], String.t()}
          | {:copy, [Ecto.UUID.t()], String.t(), integer(), boolean()}
          | {:add_frequency,
             %{
               pattern_id: Ecto.UUID.t(),
               timed_pattern_id: Ecto.UUID.t(),
               service_id: String.t(),
               windows: [FrequencyWindows.window()],
               exact_times: 0 | 1
             }}
          | {:update_frequency, Ecto.UUID.t(),
             %{windows: [FrequencyWindows.window()], exact_times: 0 | 1 | :keep}}
          | {:convert_frequency, Ecto.UUID.t()}
          | {:restore, restore_payload()}

  @typedoc "One stop time's values; `position` is the 1-based pattern occurrence position."
  @type stop_time_values :: %{
          required(:position) => pos_integer(),
          required(:arrival_time) => String.t() | nil,
          required(:departure_time) => String.t() | nil,
          optional(:timepoint) => 0 | 1 | nil,
          optional(:pickup_type) => integer() | nil,
          optional(:drop_off_type) => integer() | nil,
          optional(:stop_headsign) => String.t() | nil
        }

  @typedoc "One updated trip; `stop_times` is the full ordered list, written positionally."
  @type update :: %{
          trip_id: Ecto.UUID.t(),
          fields: %{
            optional(
              :service_id
              | :timed_pattern_id
              | :pattern_derivation_state
              | :pattern_derivation_reason
              | :block_id
            ) => term()
          },
          stop_times: :unchanged | [stop_time_values()],
          frequencies:
            :unchanged
            | [
                FrequencyWindows.window()
                | %{
                    start_time: String.t(),
                    end_time: String.t(),
                    headway_secs: pos_integer(),
                    exact_times: 0 | 1 | nil
                  }
              ]
        }

  @typedoc "One inserted trip; `attrs` never carries `block_id`."
  @type insert :: %{
          source_id: Ecto.UUID.t() | nil,
          attrs: map(),
          stop_times: [map()],
          frequencies: [map()]
        }

  @typedoc "An error, warning or note the review renders; any `{:error, _}` refuses the write."
  @type consequence ::
          {:error,
           :negative_time
           | {:out_of_order, pos_integer()}
           | :frequency_trip
           | :stops_differ
           | :clear_not_allowed
           | {:mixed_service, map()}
           | :no_eligible_trips}
          | {:warning,
             {:block_findings, [map()]}
             | {:duplicate_departure, Ecto.UUID.t(), String.t()}
             | {:shared_dates, String.t(), pos_integer()}
             | {:headway_longer_than_window, non_neg_integer()}}
          | {:note,
             {:crosses_midnight, [Ecto.UUID.t()]}
             | {:becomes_custom, [Ecto.UUID.t()]}
             | {:loses_custom_times, [Ecto.UUID.t()]}
             | {:windows_moved, [Ecto.UUID.t()]}
             | {:excluded, Ecto.UUID.t(), atom()}
             | {:skipped_existing, Ecto.UUID.t(), String.t()}
             | {:cleared_block, Ecto.UUID.t(), String.t()}
             | {:transfers_removed, non_neg_integer()}
             | {:relinked, Ecto.UUID.t(), Ecto.UUID.t()}}

  @typedoc "What one planner emits."
  @type change_set :: %{
          updates: [update()],
          inserts: [insert()],
          deletes: [Ecto.UUID.t()],
          consequences: [consequence()]
        }

  @typedoc "A planned command plus its preview and counts; the fingerprint fences apply."
  @type review :: %{
          command: command(),
          change_set: change_set(),
          fingerprint: String.t(),
          preview: %{Ecto.UUID.t() => %{pos_integer() => non_neg_integer() | nil}},
          counts: %{
            changed: non_neg_integer(),
            created: non_neg_integer(),
            deleted: non_neg_integer(),
            excluded: non_neg_integer(),
            skipped: non_neg_integer()
          }
        }

  @typedoc "What an undoable apply captures before it writes (INV-2, R10)."
  @type restore_payload :: %{
          operation_id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          route_id: String.t(),
          trips: [
            %{
              id: Ecto.UUID.t(),
              written_updated_at: DateTime.t(),
              fields: map(),
              stop_times: [
                %{
                  id: Ecto.UUID.t(),
                  arrival_time: String.t() | nil,
                  departure_time: String.t() | nil,
                  timepoint: integer() | nil,
                  pickup_type: integer() | nil,
                  drop_off_type: integer() | nil,
                  stop_headsign: String.t() | nil
                }
              ],
              frequencies: [
                %{
                  start_time: String.t(),
                  end_time: String.t(),
                  headway_secs: pos_integer(),
                  exact_times: 0 | 1 | nil
                }
              ]
            }
          ],
          created: [%{id: Ecto.UUID.t(), trip_id: String.t(), written_updated_at: DateTime.t()}]
        }

  @typedoc """
  The engine's loaded change state (step 10 owns the exact keys): `route`,
  `trips: %{uuid => %{trip, stop_times, frequencies}}`,
  `patterns: %{route_pattern_id => %{pattern, occurrences, timings: [%{timing, rows}]}}`,
  `calendars`, `service_dates`, `pattern_trips`, and per command the optional
  `block_inputs`, `existing_trip_ids`, `transfer_counts` and `target_service`.
  """
  @type state :: map()

  @doc """
  Validates one command and returns its canonical form.

  UUID fields are cast to lowercase canonical strings, id lists are deduplicated
  and sorted, and nested params are rebuilt with their contract keys. An empty
  selection is `:invalid_command`; more than #{@max_trips} distinct trips is
  `:too_many_trips`.
  """
  @spec validate(term()) :: {:ok, command()} | {:error, :invalid_command | :too_many_trips}
  def validate({:edit_stop, trip_id, params}) when is_map(params) do
    with {:ok, trip_id} <- cast_uuid(trip_id),
         :ok <- validate_stop_edit(params) do
      {:ok, {:edit_stop, trip_id, canonical_stop_edit(params)}}
    end
  end

  def validate({:shift, ids, delta, from_position}) do
    with {:ok, ids} <- validate_ids(ids),
         :ok <- validate_delta(delta),
         :ok <- validate_from_position(from_position) do
      {:ok, {:shift, ids, delta, from_position}}
    end
  end

  def validate({:set_timing, ids, timing_id}) do
    with {:ok, ids} <- validate_ids(ids),
         {:ok, timing_id} <- cast_uuid(timing_id) do
      {:ok, {:set_timing, ids, timing_id}}
    end
  end

  def validate({:move_calendar, ids, service_id}) do
    with {:ok, ids} <- validate_ids(ids),
         true <- valid_service?(service_id) do
      {:ok, {:move_calendar, ids, service_id}}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def validate({:copy, ids, service_id, offset, skip_existing}) do
    with {:ok, ids} <- validate_ids(ids),
         true <- valid_service?(service_id),
         :ok <- validate_offset(offset),
         true <- is_boolean(skip_existing) do
      {:ok, {:copy, ids, service_id, offset, skip_existing}}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def validate({:add_frequency, attrs}) when is_map(attrs) do
    pattern_id = value(attrs, :pattern_id)
    timed_pattern_id = value(attrs, :timed_pattern_id)
    service_id = value(attrs, :service_id)
    windows = value(attrs, :windows)
    exact_times = value(attrs, :exact_times)

    with {:ok, pattern_id} <- cast_uuid(pattern_id),
         {:ok, timed_pattern_id} <- cast_uuid(timed_pattern_id),
         true <- valid_service?(service_id),
         true <- valid_windows?(windows),
         true <- exact_times in [0, 1] do
      {:ok,
       {:add_frequency,
        %{
          pattern_id: pattern_id,
          timed_pattern_id: timed_pattern_id,
          service_id: service_id,
          windows: windows,
          exact_times: exact_times
        }}}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def validate({:update_frequency, trip_id, params}) when is_map(params) do
    windows = value(params, :windows)
    exact_times = value(params, :exact_times)

    with {:ok, trip_id} <- cast_uuid(trip_id),
         true <- valid_windows?(windows),
         true <- exact_times in [0, 1, :keep] do
      {:ok, {:update_frequency, trip_id, %{windows: windows, exact_times: exact_times}}}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def validate({:convert_frequency, trip_id}) do
    with {:ok, trip_id} <- cast_uuid(trip_id) do
      {:ok, {:convert_frequency, trip_id}}
    end
  end

  def validate({:restore, payload}) when is_map(payload) do
    if restore_payload?(payload) do
      {:ok, {:restore, payload}}
    else
      {:error, :invalid_command}
    end
  end

  def validate(_command), do: {:error, :invalid_command}

  @doc """
  Dispatches a validated command to its pure planner.

  `:shift` is planned by `TripChanges.Shift`, `:edit_stop` by
  `TripChanges.EditStop`, `:set_timing` by `TripChanges.SetTiming`,
  `:move_calendar` by `TripChanges.MoveCalendar`, `:copy` by `TripChanges.Copy`,
  `:add_frequency` and `:update_frequency` by `TripChanges.Frequency`,
  `:convert_frequency` by `TripChanges.Convert` and `:restore` by
  `TripChanges.Restore`; every command without a planner clause falls through to
  `{:error, :invalid_command}`.
  """
  @spec plan(command(), state()) :: {:ok, change_set()} | {:error, term()}
  def plan({:shift, _trip_ids, _delta, _from_position} = command, state),
    do: Shift.plan(command, state)

  def plan({:edit_stop, _trip_id, _params} = command, state), do: EditStop.plan(command, state)

  def plan({:set_timing, _trip_ids, _timing_id} = command, state),
    do: SetTiming.plan(command, state)

  def plan({:move_calendar, _trip_ids, _service_id} = command, state),
    do: MoveCalendar.plan(command, state)

  def plan({:copy, _trip_ids, _service_id, _offset, _skip_existing} = command, state),
    do: Copy.plan(command, state)

  def plan({:add_frequency, _attrs} = command, state), do: Frequency.plan(command, state)

  def plan({:update_frequency, _trip_id, _params} = command, state),
    do: Frequency.plan(command, state)

  def plan({:convert_frequency, _trip_id} = command, state), do: Convert.plan(command, state)

  def plan({:restore, _payload} = command, state), do: Restore.plan(command, state)

  def plan(_command, _state), do: {:error, :invalid_command}

  @doc """
  Hashes the reviewed command, the affected trips' state and the finding keys the
  change adds (R3).

  The command's id lists are sorted, so a reordered selection fingerprints the
  same. Each affected trip contributes `{id, updated_at, service_id,
  timed_pattern_id, pattern_derivation_state, block_id, ordered stop-time clocks,
  frequency rows}`, sorted by id; a trip missing from `state` contributes
  `{id, :missing}`. The engine recomputes this value under lock and refuses the
  write when it differs (`{:error, {:stale_review, review}}`).
  """
  @spec fingerprint(command(), state(), change_set()) :: String.t()
  def fingerprint(command, state, change_set) do
    {
      sorted_command(command),
      trip_state_tuples(command, state),
      added_finding_keys(change_set)
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Compares one whole-trip result with each of a pattern's timings (R1).

  `new_rows` is the result's stop rows in pattern order, `occurrences` the pattern
  occurrences and `timings` the loaded `%{timing, rows}` entries. Each timing is
  materialized at the result's first departure, ordered by timing name then id;
  the first whose arrival, departure, timepoint, pickup type, drop-off type and
  stop headsign match every row returns `{:linked, timing_id}`. Anything else,
  including a malformed result, is `:custom`.
  """
  @spec relink([map()], [map()], [%{timing: term(), rows: [map()]}]) ::
          {:linked, Ecto.UUID.t()} | :custom
  def relink(new_rows, occurrences, timings)
      when is_list(new_rows) and is_list(occurrences) and is_list(timings) do
    departure = first_departure(new_rows)
    rows = comparison_rows(new_rows)

    if is_nil(departure) or length(rows) != length(occurrences) do
      :custom
    else
      timings
      |> Enum.sort_by(&timing_order/1)
      |> Enum.find_value(:custom, &match_timing(&1, departure, occurrences, rows))
    end
  end

  def relink(_new_rows, _occurrences, _timings), do: :custom

  @doc """
  Allocates one unique `trip_id` per departure start.

  Trip IDs are unique within the organization and version, so the version's
  existing IDs seed the candidate set. Across the batch, a later departure can
  never reuse an ID this call already reserved. A base is shared by every trip
  with the same route, direction, service and `HHMM` start stamp; the second such
  trip takes the smallest free `-n` suffix at or above 2.
  """
  @spec allocate_trip_ids(String.t(), integer() | nil, String.t(), [non_neg_integer()], [
          String.t()
        ]) :: [String.t()]
  def allocate_trip_ids(route_id, direction_id, service_id, starts, existing_trip_ids) do
    {trip_ids, _taken} =
      Enum.map_reduce(starts, MapSet.new(existing_trip_ids), fn start_secs, taken ->
        base = trip_id_base(route_id, direction_id, service_id, start_secs)
        trip_id = next_free_trip_id(base, taken)

        {trip_id, MapSet.put(taken, trip_id)}
      end)

    trip_ids
  end

  defp validate_stop_edit(params) do
    position = value(params, :position)
    edit_value = value(params, :value)
    mode = value(params, :mode)

    if is_integer(position) and position >= 1 and valid_edit_value?(edit_value) and
         mode in @stop_edit_modes and valid_shown_positions?(value(params, :shown_positions)) do
      :ok
    else
      {:error, :invalid_command}
    end
  end

  defp canonical_stop_edit(params) do
    %{
      position: value(params, :position),
      value: value(params, :value),
      mode: value(params, :mode),
      shown_positions: value(params, :shown_positions)
    }
  end

  defp valid_edit_value?(:clear), do: true
  defp valid_edit_value?(value), do: is_integer(value) and value >= 0

  defp valid_shown_positions?(:all), do: true

  defp valid_shown_positions?(positions) when is_list(positions),
    do: Enum.all?(positions, &(is_integer(&1) and &1 >= 1))

  defp valid_shown_positions?(_positions), do: false

  defp validate_ids(ids) do
    with {:ok, uuids} <- cast_ids(ids),
         :ok <- validate_trip_count(uuids) do
      {:ok, uuids}
    end
  end

  defp cast_ids(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, :invalid_command}}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, uuids |> Enum.uniq() |> Enum.sort()}
      {:error, _} = error -> error
    end
  end

  defp cast_ids(_ids), do: {:error, :invalid_command}

  defp cast_uuid(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_command}
    end
  end

  defp validate_trip_count([]), do: {:error, :invalid_command}
  defp validate_trip_count(ids) when length(ids) > @max_trips, do: {:error, :too_many_trips}
  defp validate_trip_count(_ids), do: :ok

  defp validate_delta(delta) do
    if is_integer(delta) and delta != 0 and rem(delta, 60) == 0 and
         abs(delta) <= @max_delta_secs do
      :ok
    else
      {:error, :invalid_command}
    end
  end

  defp validate_offset(offset) do
    if is_integer(offset) and rem(offset, 60) == 0 and abs(offset) <= @max_delta_secs do
      :ok
    else
      {:error, :invalid_command}
    end
  end

  defp validate_from_position(nil), do: :ok
  defp validate_from_position(position) when is_integer(position) and position >= 1, do: :ok
  defp validate_from_position(_position), do: {:error, :invalid_command}

  defp valid_service?(service_id), do: is_binary(service_id) and service_id != ""

  defp valid_windows?(windows) when is_list(windows), do: Enum.all?(windows, &valid_window?/1)
  defp valid_windows?(_windows), do: false

  defp valid_window?(%{start_secs: start_secs, end_secs: end_secs, headway_secs: headway_secs}) do
    is_integer(start_secs) and start_secs >= 0 and is_integer(end_secs) and end_secs >= 0 and
      is_integer(headway_secs) and headway_secs > 0
  end

  defp valid_window?(_window), do: false

  defp restore_payload?(payload) do
    uuid?(value(payload, :operation_id)) and uuid?(value(payload, :organization_id)) and
      uuid?(value(payload, :gtfs_version_id)) and is_binary(value(payload, :route_id)) and
      map_list?(value(payload, :trips)) and map_list?(value(payload, :created))
  end

  defp uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp map_list?(value) when is_list(value), do: Enum.all?(value, &is_map/1)
  defp map_list?(_value), do: false

  defp sorted_command({:shift, ids, delta, from_position}),
    do: {:shift, sorted(ids), delta, from_position}

  defp sorted_command({:set_timing, ids, timing_id}),
    do: {:set_timing, sorted(ids), timing_id}

  defp sorted_command({:move_calendar, ids, service_id}),
    do: {:move_calendar, sorted(ids), service_id}

  defp sorted_command({:copy, ids, service_id, offset, skip_existing}),
    do: {:copy, sorted(ids), service_id, offset, skip_existing}

  defp sorted_command(command), do: command

  defp sorted(ids) when is_list(ids), do: Enum.sort(ids)
  defp sorted(other), do: other

  defp trip_state_tuples(command, state) do
    command
    |> affected_trip_ids()
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&trip_state_tuple(&1, state))
  end

  defp affected_trip_ids({:edit_stop, trip_id, _params}), do: [trip_id]
  defp affected_trip_ids({:shift, trip_ids, _delta, _from_position}), do: trip_ids
  defp affected_trip_ids({:set_timing, trip_ids, _timing_id}), do: trip_ids
  defp affected_trip_ids({:move_calendar, trip_ids, _service_id}), do: trip_ids
  defp affected_trip_ids({:copy, trip_ids, _service_id, _offset, _skip_existing}), do: trip_ids
  defp affected_trip_ids({:add_frequency, _attrs}), do: []
  defp affected_trip_ids({:update_frequency, trip_id, _params}), do: [trip_id]
  defp affected_trip_ids({:convert_frequency, trip_id}), do: [trip_id]

  defp affected_trip_ids({:restore, payload}) do
    payload
    |> value(:trips)
    |> List.wrap()
    |> Enum.map(&value(&1, :id))
  end

  defp affected_trip_ids(_command), do: []

  defp trip_state_tuple(trip_id, state) do
    case loaded_trip(state, trip_id) do
      nil ->
        {trip_id, :missing}

      %{trip: trip} = loaded ->
        {value(trip, :id), value(trip, :updated_at), value(trip, :service_id),
         value(trip, :timed_pattern_id), value(trip, :pattern_derivation_state),
         value(trip, :block_id), stop_clocks(loaded), frequency_rows(loaded)}
    end
  end

  defp loaded_trip(state, trip_id) when is_map(state) do
    case value(state, :trips) do
      %{} = trips -> Map.get(trips, trip_id)
      _trips -> nil
    end
  end

  defp loaded_trip(_state, _trip_id), do: nil

  defp stop_clocks(%{stop_times: stop_times}) when is_list(stop_times) do
    stop_times
    |> Enum.sort_by(&{value(&1, :stop_sequence), value(&1, :id)})
    |> Enum.map(&{value(&1, :arrival_time), value(&1, :departure_time)})
  end

  defp stop_clocks(_loaded), do: []

  defp frequency_rows(%{frequencies: frequencies}) when is_list(frequencies) do
    frequencies
    |> Enum.sort_by(&{value(&1, :start_time), value(&1, :end_time)})
    |> Enum.map(
      &{value(&1, :start_time), value(&1, :end_time), value(&1, :headway_secs),
       value(&1, :exact_times)}
    )
  end

  defp frequency_rows(_loaded), do: []

  defp added_finding_keys(%{consequences: consequences}) when is_list(consequences) do
    consequences
    |> Enum.flat_map(fn
      {:warning, {:block_findings, findings}} when is_list(findings) ->
        Enum.map(findings, &Checks.finding_key/1)

      _consequence ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp added_finding_keys(_change_set), do: []

  defp first_departure([first | _rest]) do
    case clock_secs(value(first, :departure_time)) do
      secs when is_integer(secs) -> secs
      _other -> nil
    end
  end

  defp first_departure(_rows), do: nil

  defp comparison_rows(rows) do
    Enum.map(rows, fn row ->
      {clock_secs(value(row, :arrival_time)), clock_secs(value(row, :departure_time)),
       value(row, :timepoint), value(row, :pickup_type), value(row, :drop_off_type),
       value(row, :stop_headsign)}
    end)
  end

  defp clock_secs(value) when is_integer(value) and value >= 0, do: value

  defp clock_secs(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, secs} -> secs
      {:error, :invalid_time} -> value
    end
  end

  defp clock_secs(value), do: value

  defp match_timing(%{timing: timing, rows: timing_rows}, departure, occurrences, rows) do
    case Materializer.materialize(departure, occurrences, timing_rows) do
      {:ok, materialized} ->
        if comparison_rows(materialized) == rows, do: {:linked, value(timing, :id)}

      {:error, _reason} ->
        nil
    end
  end

  defp match_timing(_timing, _departure, _occurrences, _rows), do: nil

  defp timing_order(%{timing: timing}), do: {value(timing, :name), value(timing, :id)}

  # The base itself when free; otherwise the smallest free suffix at or above 2.
  defp next_free_trip_id(base, taken) do
    if MapSet.member?(taken, base) do
      suffix =
        2
        |> Stream.iterate(&(&1 + 1))
        |> Enum.find(fn candidate -> not MapSet.member?(taken, "#{base}-#{candidate}") end)

      "#{base}-#{suffix}"
    else
      base
    end
  end

  defp trip_id_base(route_id, direction_id, service_id, start_secs) do
    "#{route_id}-#{direction_id}-#{service_id}-#{trip_id_stamp(start_secs)}"
  end

  # `HHMM` is unwrapped `hours * 100 + minutes`, zero-padded to four digits, so
  # `25:10` is `2510`.
  defp trip_id_stamp(start_secs) do
    hours = div(start_secs, 3_600)
    minutes = start_secs |> rem(3_600) |> div(60)

    (hours * 100 + minutes)
    |> Integer.to_string()
    |> String.pad_leading(4, "0")
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
