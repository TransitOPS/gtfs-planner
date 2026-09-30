defmodule GtfsPlanner.Gtfs.Schedules.StopTimeEdit do
  @moduledoc """
  Applies the R1 stop-edit time rules to one trip's stored stop times.

  `apply/5` and `clear/2` are pure: the caller passes the trip's rows in
  `(stop_sequence, id)` order plus a 1-based occurrence position and gets back either
  the rewritten list or a refusal. Timing linkage, wall-clock formatting and
  persistence belong to `Schedules.TripChanges.EditStop` and the `Schedules` engine.

  The typed time is the stop's departure, except at the last stop where it is the
  arrival; the stop's other field moves by the same change, so dwell is kept. Editing
  the first stop, or asking for `:anchor`, moves every stop; `:later` moves the edited
  stop and every later stop; `:only` moves one stop. In the timepoints view
  (`shown_positions` is a list) `:only` also re-spaces the stops hidden between the
  shown stops before and after the edit, proportional to their current spacing and
  floored per value, and stores them with `timepoint: 0`. Each hidden run maps both
  fields through one span, from the departure of the shown stop it follows to the
  arrival of the shown stop it reaches, so a run whose stored span is zero lands on
  that departure's new time. A hidden stop with no stored time stays blank.

  Stop times are integer seconds and may pass 24:00. A stop with no stored time adopts
  the typed time and moves no other stop. A result with a value below zero is refused
  `:negative_time`; a result whose arrival precedes the closest stored departure before
  it, or whose departure precedes its own arrival, is refused
  `{:out_of_order, position}`. Chronology skips stops with no stored time. Nothing is
  written on a refusal.
  """

  @typedoc "One stored stop time; `nil` means GTFS leaves the value empty."
  @type stop :: %{
          arrival: non_neg_integer() | nil,
          departure: non_neg_integer() | nil,
          timepoint: 0 | 1 | nil
        }

  @typedoc "How far an edit reaches: one stop, every later stop, or the whole trip."
  @type mode :: :later | :only | :anchor

  @doc """
  Applies one typed time to the stop at `position` (1-based).

  `shown_positions` is `:all` in the All stops view, or the 1-based indexes of the
  displayed stops in the timepoints view; it is only read by `:only`.
  """
  @spec apply([stop()], pos_integer(), non_neg_integer(), mode(), [pos_integer()] | :all) ::
          {:ok, [stop()]} | {:error, {:out_of_order, pos_integer()} | :negative_time}
  def apply(stops, position, value, mode, shown_positions)
      when is_list(stops) and position >= 1 and position <= length(stops) and
             is_integer(value) and value >= 0 and mode in [:later, :only, :anchor] do
    edited = Enum.at(stops, position - 1)

    case anchor_value(edited, position == length(stops)) do
      nil -> set_missing_time(stops, position, value)
      old -> move_stops(stops, position, value - old, mode, shown_positions)
    end
  end

  defp set_missing_time(stops, position, value) do
    stops
    |> List.replace_at(position - 1, %{
      Enum.at(stops, position - 1)
      | arrival: value,
        departure: value
    })
    |> check()
  end

  defp move_stops(stops, position, delta, mode, shown_positions) do
    moved =
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, index} -> shift(stop, index, position, mode, delta) end)

    moved
    |> maybe_respace(stops, position, mode, shown_positions)
    |> check()
  end

  defp maybe_respace(moved, old, position, :only, shown_positions)
       when position > 1 and is_list(shown_positions),
       do: respace(moved, old, position, shown_positions)

  defp maybe_respace(moved, _old, _position, _mode, _shown_positions), do: moved

  @doc """
  Clears one intermediate stop's stored time.

  Allowed only at a stop whose stored `timepoint` is exactly `0`: the first and the
  last stop always need a time, and a timepoint stop is an anchor. The cleared stop
  keeps every other field and stores empty arrival and departure; the remaining stored
  times must still be in chronological order.
  """
  @spec clear([stop()], pos_integer()) ::
          {:ok, [stop()]} | {:error, :clear_not_allowed | {:out_of_order, pos_integer()}}
  def clear(stops, position)
      when is_list(stops) and position >= 1 and position <= length(stops) do
    stop = Enum.at(stops, position - 1)

    if position == 1 or position == length(stops) or stop.timepoint != 0 do
      {:error, :clear_not_allowed}
    else
      stops
      |> List.replace_at(position - 1, %{stop | arrival: nil, departure: nil})
      |> chronology()
    end
  end

  defp anchor_value(stop, true), do: stop.arrival || stop.departure
  defp anchor_value(stop, false), do: stop.departure || stop.arrival

  defp shift(stop, index, position, mode, delta) do
    if whole_trip?(mode, position) or reaches?(mode, index, position) do
      %{stop | arrival: move(stop.arrival, delta), departure: move(stop.departure, delta)}
    else
      stop
    end
  end

  defp whole_trip?(:anchor, _position), do: true
  defp whole_trip?(_mode, position), do: position == 1

  defp reaches?(:later, index, position), do: index >= position
  defp reaches?(:only, index, position), do: index == position

  defp move(nil, _delta), do: nil
  defp move(value, delta), do: value + delta

  # Re-spaces the stops hidden between the shown stops around the edited one. Each
  # run keeps its own anchors: the shown stop it follows `near` and the one it
  # reaches `far`, mapping every stored field from the old span onto the new one.
  defp respace(moved, old, position, shown_positions) do
    runs = hidden_runs(shown_positions, position)

    moved
    |> Enum.with_index(1)
    |> Enum.map(&respace_index(&1, runs, old, moved))
  end

  defp hidden_runs(shown_positions, position) do
    [previous_shown(shown_positions, position), next_shown(shown_positions, position)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Enum.sort([&1, position]))
  end

  defp respace_index({stop, index}, runs, old, moved) do
    case Enum.find(runs, fn [near, far] -> near < index and index < far end) do
      nil ->
        stop

      [near, far] ->
        respace_stop(
          stop,
          Enum.at(old, index - 1),
          Enum.at(old, near - 1),
          Enum.at(moved, near - 1),
          Enum.at(old, far - 1),
          Enum.at(moved, far - 1)
        )
    end
  end

  defp previous_shown(shown_positions, position) do
    shown_positions
    |> Enum.filter(&(&1 < position))
    |> Enum.max(fn -> nil end)
  end

  defp next_shown(shown_positions, position) do
    shown_positions
    |> Enum.filter(&(&1 > position))
    |> Enum.min(fn -> nil end)
  end

  # Both fields of a hidden stop map through one travel span, from `near`'s departure
  # to `far`'s arrival, so a stop's dwell and its order against the anchors survive
  # when an anchor has dwell of its own.
  defp respace_stop(stop, old_stop, near_old, near_new, far_old, far_new) do
    span = {
      anchor_value(near_old, false),
      anchor_value(near_new, false),
      anchor_value(far_old, true),
      anchor_value(far_new, true)
    }

    %{
      stop
      | arrival: respace_value(old_stop.arrival, span),
        departure: respace_value(old_stop.departure, span),
        timepoint: 0
    }
  end

  defp respace_value(value, {near_old, near_new, far_old, far_new})
       when is_integer(value) and is_integer(near_old) and is_integer(near_new) and
              is_integer(far_old) and is_integer(far_new) do
    span_old = far_old - near_old
    span_new = far_new - near_new

    if span_old == 0 do
      near_new
    else
      near_new + Integer.floor_div((value - near_old) * span_new, span_old)
    end
  end

  defp respace_value(value, _span), do: value

  defp check(stops) do
    if Enum.any?(stops, &negative?/1) do
      {:error, :negative_time}
    else
      chronology(stops)
    end
  end

  defp negative?(stop) do
    below_zero?(stop.arrival) or below_zero?(stop.departure)
  end

  defp below_zero?(nil), do: false
  defp below_zero?(value), do: value < 0

  defp chronology(stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.reduce_while(nil, fn {stop, index}, previous_departure ->
      if out_of_order?(stop, previous_departure) do
        {:halt, {:error, {:out_of_order, index}}}
      else
        {:cont, stop.departure || previous_departure}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _previous_departure -> {:ok, stops}
    end
  end

  defp out_of_order?(stop, previous_departure) do
    departure_before_arrival?(stop) or arrival_before_previous?(stop.arrival, previous_departure)
  end

  defp departure_before_arrival?(%{arrival: arrival, departure: departure})
       when is_integer(arrival) and is_integer(departure),
       do: departure < arrival

  defp departure_before_arrival?(_stop), do: false

  defp arrival_before_previous?(arrival, previous_departure)
       when is_integer(arrival) and is_integer(previous_departure),
       do: arrival < previous_departure

  defp arrival_before_previous?(_arrival, _previous_departure), do: false
end
