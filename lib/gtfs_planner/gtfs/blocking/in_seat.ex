defmodule GtfsPlanner.Gtfs.Blocking.InSeat do
  @moduledoc """
  Pure in-seat state rule (R6) for one type 4/5 transfer record.

  A type 4/5 record claims that riders stay on the vehicle between two trips. The
  record matches only when, on every date both trips run, the second trip
  immediately follows the first in one block and any record stops equal the first
  trip's last and the second trip's first stop. `state/2` evaluates that rule over
  the supplied context in AC-7's order and returns exactly one state; `finding/3`
  turns the state into the single warning or notice the page lists.

  The rule is shared: the day load (step 7), the Schedules problem check (step 17)
  and the block-change review (step 11) all read this module rather than each
  deriving a second answer (INV-2). Every day type in `context.day_types` where
  both trips run is evaluated, not only the day type on screen, so a record that is
  not next on another day type is stale even when it matches the viewed one.

  Two boundaries follow from the context: a day type is only evaluated when it
  contains both trips' services, and the record's stops are compared only when the
  record carries them, so a row made stopless by the transfer-integrity work stays
  valid. The module computes from its arguments only: no database, clock, files or
  network (CR-1).
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.DayTypes

  @type in_seat_row :: %{
          id: Ecto.UUID.t(),
          from_trip_id: String.t(),
          to_trip_id: String.t(),
          transfer_type: 4 | 5,
          from_stop_id: String.t() | nil,
          to_stop_id: String.t() | nil
        }

  @type reason ::
          :trip_missing
          | :no_shared_date
          | :no_block
          | :stops_changed
          | {:not_next, [%{key: String.t(), label: String.t(), date_count: pos_integer()}]}

  @type state ::
          :matches
          | {:stale, reason()}
          | {:unconfirmed, :next_service_day | :untimed | :coupling}

  @type context :: %{
          trips: %{String.t() => Checks.trip_row()},
          service_dates: %{String.t() => MapSet.t(Date.t())},
          day_types: [DayTypes.day_type()],
          sequences: %{{String.t(), String.t()} => [Ecto.UUID.t()]}
        }

  @doc """
  Returns the one state of a type 4/5 record over the supplied context.

  AC-7's order decides which state a record with several defects gets:

  1. A trip the context does not carry is `{:stale, :trip_missing}`.
  2. No shared date is `{:unconfirmed, :next_service_day}` when the second trip
     runs the day after a date of the first, otherwise `{:stale, :no_shared_date}`.
  3. Either trip without a block is `{:stale, :no_block}`.
  4. Either trip unplottable or frequency-based is `{:unconfirmed, :untimed}`.
  5. The second trip ending before the first arrives is `{:unconfirmed, :coupling}`
     when the second trip's first departure is before the first trip's last
     arrival.
  6. A non-nil record stop that differs from the matching endpoint is
     `{:stale, :stops_changed}`.
  7. A day type in `context.day_types` where both services run and where the two
     trips are not the same block's consecutive trips is reported as
     `{:stale, {:not_next, failures}}`, one entry per such day type in list order.
  8. Otherwise `:matches`.
  """
  @spec state(in_seat_row(), context()) :: state()
  def state(row, context) do
    with {:ok, from} <- Map.fetch(context.trips, row.from_trip_id),
         {:ok, to} <- Map.fetch(context.trips, row.to_trip_id) do
      evaluate(row, from, to, context)
    else
      :error -> {:stale, :trip_missing}
    end
  end

  @doc """
  Returns the finding a state contributes to the day, or `nil` for `:matches`.

  A stale state is an `:in_seat_stale` warning with `transfer_id` set to the
  record's ID, and an unconfirmed state is an `:in_seat_unconfirmed` notice. Both
  carry the first trip's block ID, the trip UUIDs the context holds, and
  `detail.reason` with the state's reason, so a listing can print the day types a
  record is not next on without evaluating the rule again.
  """
  @spec finding(in_seat_row(), state(), context()) :: Checks.finding() | nil
  def finding(_row, :matches, _context), do: nil

  def finding(row, {:stale, reason}, context) do
    build(row, context, :in_seat_stale, :warning, reason)
  end

  def finding(row, {:unconfirmed, reason}, context) do
    build(row, context, :in_seat_unconfirmed, :notice, reason)
  end

  defp evaluate(row, from, to, context) do
    from_dates = service_dates(context, from.service_id)
    to_dates = service_dates(context, to.service_id)

    cond do
      MapSet.disjoint?(from_dates, to_dates) -> no_shared_date_state(from_dates, to_dates)
      is_nil(from.block_id) or is_nil(to.block_id) -> {:stale, :no_block}
      not timed?(from) or not timed?(to) -> {:unconfirmed, :untimed}
      to.first_departure < from.last_arrival -> {:unconfirmed, :coupling}
      stops_changed?(row, from, to) -> {:stale, :stops_changed}
      true -> consecutive_state(from, to, context)
    end
  end

  # A service the context does not carry has no dates, so a record naming it never
  # shares a date.
  defp service_dates(context, service_id) do
    Map.get(context.service_dates, service_id, MapSet.new())
  end

  defp no_shared_date_state(from_dates, to_dates) do
    if Enum.any?(from_dates, &MapSet.member?(to_dates, Date.add(&1, 1))) do
      {:unconfirmed, :next_service_day}
    else
      {:stale, :no_shared_date}
    end
  end

  defp timed?(trip), do: trip.plottable? and not trip.frequency?

  # Only a stop the record names is compared: a stopless row stays valid.
  defp stops_changed?(row, from, to) do
    stop_differs?(row.from_stop_id, from.last_stop) or
      stop_differs?(row.to_stop_id, to.first_stop)
  end

  defp stop_differs?(nil, _endpoint), do: false
  defp stop_differs?(_record_stop_id, nil), do: true
  defp stop_differs?(record_stop_id, endpoint), do: endpoint.stop_id != record_stop_id

  defp consecutive_state(from, to, context) do
    failures =
      context.day_types
      |> Enum.filter(&runs_both?(&1, from, to))
      |> Enum.reject(&consecutive?(&1, from, to, context.sequences))
      |> Enum.map(&failure/1)

    case failures do
      [] -> :matches
      failures -> {:stale, {:not_next, failures}}
    end
  end

  defp runs_both?(day_type, from, to) do
    from.service_id in day_type.service_ids and to.service_id in day_type.service_ids
  end

  # The two trips must be the same block's next pair in the order the day type
  # loaded them in, including when the day type holds no order for that block.
  defp consecutive?(day_type, from, to, sequences) do
    from.block_id == to.block_id and
      sequences
      |> Map.get({day_type.key, from.block_id}, [])
      |> followed_by?(from.id, to.id)
  end

  defp followed_by?(order, from_id, to_id) do
    index = Enum.find_index(order, &(&1 == from_id))

    is_integer(index) and Enum.at(order, index + 1) == to_id
  end

  defp failure(day_type) do
    %{key: day_type.key, label: day_type.label, date_count: day_type.date_count}
  end

  defp build(row, context, code, severity, reason) do
    %{
      code: code,
      severity: severity,
      block_id: first_block_id(row, context),
      trip_ids: trip_ids(row, context),
      transfer_id: row.id,
      detail: %{reason: reason}
    }
  end

  defp first_block_id(row, context) do
    case Map.fetch(context.trips, row.from_trip_id) do
      {:ok, from} -> from.block_id
      :error -> nil
    end
  end

  defp trip_ids(row, context) do
    [row.from_trip_id, row.to_trip_id]
    |> Enum.flat_map(&existing_trip_id(&1, context))
    |> Enum.uniq()
  end

  defp existing_trip_id(trip_id, context) do
    case Map.fetch(context.trips, trip_id) do
      {:ok, trip} -> [trip.id]
      :error -> []
    end
  end
end
