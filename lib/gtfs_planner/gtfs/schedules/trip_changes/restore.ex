defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.Restore do
  @moduledoc """
  Plans a `:restore` command — an undo payload back into a change set (R10).

  The payload is the exact capture `apply_trip_change/4` returned: every updated
  trip's pre-write fields, stop-time rows and frequency rows plus the `updated_at`
  that write produced, and every created trip's id, natural trip id and
  `updated_at`. The plan puts each updated trip's fields and rows back
  positionally (the shape `Shift` emits) and deletes the created trips.

  The planner is the payload's parser as well as its planner (CR-1): the outer
  shape is `TripChanges.validate/1`'s check and every inner row is checked here,
  so an inconsistent payload is `{:error, :invalid_command}` instead of a write
  built from missing values. It is pure — it reads only its arguments and never
  calls `Repo`, the clock or process state. The `written_updated_at` fence and the
  transfer check are the engine's (`Schedules.restore_trips/3`), not this
  planner's.
  """

  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  # The R10 fields a restore puts back; the capture always carries all five.
  @field_keys [
    :service_id,
    :timed_pattern_id,
    :pattern_derivation_state,
    :pattern_derivation_reason,
    :block_id
  ]

  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :invalid_command}
  def plan({:restore, payload}, _state) when is_map(payload) do
    with {:ok, trips} <- entries(payload, :trips),
         {:ok, created} <- entries(payload, :created),
         {:ok, updates} <- updates(trips),
         {:ok, deletes} <- deletes(created) do
      {:ok, %{updates: updates, inserts: [], deletes: deletes, consequences: []}}
    end
  end

  def plan(_command, _state), do: {:error, :invalid_command}

  defp entries(payload, key) do
    case value(payload, key) do
      entries when is_list(entries) ->
        if Enum.all?(entries, &is_map/1), do: {:ok, entries}, else: {:error, :invalid_command}

      _missing ->
        {:error, :invalid_command}
    end
  end

  defp updates(trips) do
    trips
    |> Enum.reduce_while({:ok, []}, fn trip, {:ok, acc} ->
      case update_entry(trip) do
        {:ok, update} -> {:cont, {:ok, [update | acc]}}
        :error -> {:halt, {:error, :invalid_command}}
      end
    end)
    |> case do
      {:ok, updates} -> {:ok, Enum.reverse(updates)}
      {:error, _reason} = error -> error
    end
  end

  # An updated trip carries the capture's fields, the full stop-time rows in
  # pattern order and the frequency rows; each list is written back wholesale.
  defp update_entry(trip) do
    fields = value(trip, :fields)
    stop_times = value(trip, :stop_times)
    frequencies = value(trip, :frequencies)

    with {:ok, id} <- Ecto.UUID.cast(value(trip, :id)),
         true <- valid_fields?(fields),
         true <- is_list(stop_times) and Enum.all?(stop_times, &valid_stop_time?/1),
         true <- is_list(frequencies) and Enum.all?(frequencies, &valid_frequency?/1),
         true <- timestamp?(value(trip, :written_updated_at)) do
      {:ok,
       %{
         trip_id: id,
         fields: Map.new(@field_keys, fn key -> {key, value(fields, key)} end),
         stop_times: stop_time_values(stop_times),
         frequencies: Enum.map(frequencies, &frequency_values/1)
       }}
    else
      _invalid -> :error
    end
  end

  # Positions are the capture's stored order (1-based), the order the engine's
  # positional writer consumes.
  defp stop_time_values(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, position} ->
      %{
        position: position,
        arrival_time: value(row, :arrival_time),
        departure_time: value(row, :departure_time),
        timepoint: value(row, :timepoint),
        pickup_type: value(row, :pickup_type),
        drop_off_type: value(row, :drop_off_type),
        stop_headsign: value(row, :stop_headsign)
      }
    end)
  end

  defp frequency_values(row) do
    %{
      start_time: value(row, :start_time),
      end_time: value(row, :end_time),
      headway_secs: value(row, :headway_secs),
      exact_times: value(row, :exact_times)
    }
  end

  defp deletes(created) do
    created
    |> Enum.reduce_while({:ok, []}, fn trip, {:ok, acc} ->
      with {:ok, id} <- Ecto.UUID.cast(value(trip, :id)),
           true <- is_binary(value(trip, :trip_id)) and value(trip, :trip_id) != "",
           true <- timestamp?(value(trip, :written_updated_at)) do
        {:cont, {:ok, [id | acc]}}
      else
        _invalid -> {:halt, {:error, :invalid_command}}
      end
    end)
    |> case do
      {:ok, deletes} -> {:ok, Enum.reverse(deletes)}
      {:error, _reason} = error -> error
    end
  end

  defp valid_fields?(fields) when is_map(fields) do
    Enum.all?(@field_keys, fn key ->
      Map.has_key?(fields, key) or Map.has_key?(fields, Atom.to_string(key))
    end)
  end

  defp valid_fields?(_fields), do: false

  defp valid_stop_time?(row) do
    string_or_nil?(value(row, :arrival_time)) and string_or_nil?(value(row, :departure_time)) and
      value(row, :timepoint) in [0, 1, nil] and integer_or_nil?(value(row, :pickup_type)) and
      integer_or_nil?(value(row, :drop_off_type)) and string_or_nil?(value(row, :stop_headsign))
  end

  defp valid_frequency?(row) do
    is_binary(value(row, :start_time)) and is_binary(value(row, :end_time)) and
      is_integer(value(row, :headway_secs)) and value(row, :headway_secs) > 0 and
      value(row, :exact_times) in [0, 1, nil]
  end

  defp string_or_nil?(value), do: is_binary(value) or is_nil(value)
  defp integer_or_nil?(value), do: is_integer(value) or is_nil(value)

  defp timestamp?(%DateTime{}), do: true

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
