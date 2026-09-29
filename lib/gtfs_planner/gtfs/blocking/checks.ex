defmodule GtfsPlanner.Gtfs.Blocking.Checks do
  @moduledoc """
  Pure block checks: the trip sequence, validator-equivalent overlaps, gaps,
  handoffs and per-block findings.

  `:overlap` follows R4 and the MobilityData validator's
  `block_trips_with_overlapping_stop_times` rule. `sequence/1` orders a block's
  trips by first arrival, then last departure, then trip ID. Each trip is compared
  with every later trip while that trip's first arrival is before the earlier
  trip's last departure, and a pair is exempt exactly when the earlier trip's last
  arrival equals the later trip's first arrival and its last departure equals the
  later trip's first departure. Stops are never compared, so an exact-equality
  handoff is exempt at any two stops.

  `handoff/2` follows R5 over two stop references: the same stop, the same
  non-empty parent station, a nearby stop within 200 m, or an empty move beyond
  200 m or with unknown coordinates. A stop reference arrives with its parent
  station's coordinates already substituted for a stop that has none
  (`Queries.trip_rows/3`), so no second stop lookup happens here.

  The module computes from its arguments only: no database, clock, files or
  network (CR-1).
  """

  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  @nearby_meters 200.0

  @type stop_ref :: %{
          stop_id: String.t(),
          name: String.t() | nil,
          parent_station: String.t() | nil,
          lat: float() | nil,
          lon: float() | nil
        }

  @type trip_row :: %{
          id: Ecto.UUID.t(),
          trip_id: String.t(),
          route_id: String.t(),
          service_id: String.t(),
          block_id: String.t() | nil,
          trip_headsign: String.t() | nil,
          route_pattern_id: String.t() | nil,
          shape_id: String.t() | nil,
          updated_at: DateTime.t(),
          frequency?: boolean(),
          headway_secs: pos_integer() | nil,
          first_arrival: non_neg_integer() | nil,
          first_departure: non_neg_integer() | nil,
          last_arrival: non_neg_integer() | nil,
          last_departure: non_neg_integer() | nil,
          first_stop: stop_ref() | nil,
          last_stop: stop_ref() | nil,
          plottable?: boolean()
        }

  @type severity :: :error | :warning | :notice

  @type code ::
          :overlap
          | :short_layover
          | :in_seat_stale
          | :repositions
          | :frequency_trip
          | :unplottable
          | :in_seat_unconfirmed

  @type finding :: %{
          code: code(),
          severity: severity(),
          block_id: String.t() | nil,
          trip_ids: [Ecto.UUID.t()],
          transfer_id: Ecto.UUID.t() | nil,
          detail: map()
        }

  @type handoff ::
          :same_stop
          | :same_station
          | {:nearby, non_neg_integer()}
          | {:moves, non_neg_integer() | nil}

  @type gap :: %{
          from_id: Ecto.UUID.t(),
          to_id: Ecto.UUID.t(),
          gap_secs: integer(),
          handoff: handoff()
        }

  @doc """
  Returns the block's plottable, non-frequency trips in service order.

  Order is first arrival, then last departure, then trip ID, so a trip that starts
  after midnight sequences after one that starts during the day. Frequency-based
  and unplottable trips are left out; `block_findings/3` reports them as notices
  instead.
  """
  @spec sequence([trip_row()]) :: [trip_row()]
  def sequence(trips) do
    trips
    |> Enum.filter(&(&1.plottable? and not &1.frequency?))
    |> Enum.sort_by(&{&1.first_arrival, &1.last_departure, &1.trip_id})
  end

  @doc """
  Returns the overlapping trip pairs of one block's `sequence/1`.

  Every later trip is compared, not only the next one, so all three pairs of a
  nested block are returned. The walk stops at the first later trip that starts at
  or after the earlier trip's last departure, and an exact-equality handoff is
  skipped without stopping. Stops are not compared.
  """
  @spec overlap_pairs([trip_row()]) :: [{trip_row(), trip_row()}]
  def overlap_pairs(sequence) do
    sequence
    |> Enum.with_index()
    |> Enum.flat_map(fn {trip, index} ->
      sequence
      |> Enum.drop(index + 1)
      |> Enum.take_while(&walkable?(trip, &1))
      |> Enum.reject(&exempt?(trip, &1))
      |> Enum.map(&{trip, &1})
    end)
  end

  @doc """
  Returns one gap per consecutive pair of one block's `sequence/1`.

  `gap_secs` is the later trip's first departure minus the earlier trip's last
  arrival, so a negative value means the two trips overlap, and `handoff` follows
  R5 between the earlier trip's last stop and the later trip's first stop.
  """
  @spec gaps([trip_row()]) :: [gap()]
  def gaps(sequence) do
    sequence
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      %{
        from_id: from.id,
        to_id: to.id,
        gap_secs: to.first_departure - from.last_arrival,
        handoff: handoff(from.last_stop, to.first_stop)
      }
    end)
  end

  @doc """
  Classifies the handoff between the end of one trip and the start of the next.

  The same stop is `:same_stop`, two distinct stops sharing a non-empty parent
  station are `:same_station`, coordinates within 200 m are `{:nearby, meters}`,
  and anything else is `{:moves, meters}` with `nil` meters when either stop has no
  coordinates.
  """
  @spec handoff(stop_ref() | nil, stop_ref() | nil) :: handoff()
  def handoff(from, to) do
    cond do
      is_nil(from) or is_nil(to) -> {:moves, nil}
      is_binary(from.stop_id) and from.stop_id == to.stop_id -> :same_stop
      same_station?(from, to) -> :same_station
      true -> move(from, to)
    end
  end

  @doc """
  Returns every finding of one block over its trips.

  Errors and warnings come from the block's sequence: one `:overlap` error per
  overlapping pair, and for each consecutive pair with a non-negative gap a
  `:short_layover` warning below `min_layover_minutes` and a `:repositions` notice
  when the handoff is an empty move. Notices cover the trips the sequence leaves
  out: one `:frequency_trip` per frequency-based trip and one `:unplottable` per
  trip without usable endpoint times, using the trip order given.

  `detail` carries the numbers the page prints: `overlap_secs` for an overlap,
  `gap_secs` for a short layover, `gap_secs` and `meters` for an empty move
  (`nil` meters when a stop has no coordinates), and `headway_secs` for a
  frequency-based trip.
  """
  @spec block_findings(String.t() | nil, [trip_row()], non_neg_integer()) :: [finding()]
  def block_findings(block_id, trips, min_layover_minutes) do
    sequence = sequence(trips)

    overlap_findings(block_id, overlap_pairs(sequence)) ++
      gap_findings(block_id, gaps(sequence), min_layover_minutes) ++
      notices(block_id, trips)
  end

  @doc """
  Returns the identity of a finding: its code, its sorted trip IDs and its transfer.

  Sorting the trip IDs makes the key independent of the order a pair is listed in,
  so a before/after comparison recognises an unchanged pair.
  """
  @spec finding_key(finding()) :: {code(), [Ecto.UUID.t()], Ecto.UUID.t() | nil}
  def finding_key(finding) do
    {finding.code, Enum.sort(finding.trip_ids), finding.transfer_id}
  end

  defp walkable?(trip, later), do: later.first_arrival < trip.last_departure

  defp exempt?(trip, later) do
    trip.last_arrival == later.first_arrival and trip.last_departure == later.first_departure
  end

  defp same_station?(from, to) do
    is_binary(from.parent_station) and from.parent_station == to.parent_station
  end

  defp move(from, to) do
    if coordinates?(from) and coordinates?(to) do
      meters = Helpers.haversine(from.lat, from.lon, to.lat, to.lon)

      if meters <= @nearby_meters do
        {:nearby, round(meters)}
      else
        {:moves, round(meters)}
      end
    else
      {:moves, nil}
    end
  end

  defp coordinates?(stop), do: is_number(stop.lat) and is_number(stop.lon)

  defp overlap_findings(block_id, pairs) do
    Enum.map(pairs, fn {earlier, later} ->
      overlap_secs = min(earlier.last_departure, later.last_departure) - later.first_arrival

      finding(block_id, :error, :overlap, [earlier.id, later.id], %{overlap_secs: overlap_secs})
    end)
  end

  defp gap_findings(block_id, gaps, min_layover_minutes) do
    gaps
    |> Enum.filter(&(&1.gap_secs >= 0))
    |> Enum.flat_map(fn gap ->
      layover(block_id, gap, min_layover_minutes) ++ reposition(block_id, gap)
    end)
  end

  defp layover(block_id, %{gap_secs: gap_secs} = gap, min_layover_minutes)
       when gap_secs < min_layover_minutes * 60 do
    [finding(block_id, :warning, :short_layover, [gap.from_id, gap.to_id], %{gap_secs: gap_secs})]
  end

  defp layover(_block_id, _gap, _min_layover_minutes), do: []

  defp reposition(block_id, %{handoff: {:moves, meters}} = gap) do
    [
      finding(block_id, :notice, :repositions, [gap.from_id, gap.to_id], %{
        gap_secs: gap.gap_secs,
        meters: meters
      })
    ]
  end

  defp reposition(_block_id, _gap), do: []

  defp notices(block_id, trips) do
    Enum.flat_map(trips, &notice(block_id, &1))
  end

  # A frequency-based trip is reported as a repeat rather than as a missing time,
  # matching the pool's single eligibility reason per trip.
  defp notice(block_id, %{frequency?: true} = trip) do
    [finding(block_id, :notice, :frequency_trip, [trip.id], %{headway_secs: trip.headway_secs})]
  end

  defp notice(block_id, %{plottable?: false} = trip) do
    [finding(block_id, :notice, :unplottable, [trip.id], %{})]
  end

  defp notice(_block_id, _trip), do: []

  defp finding(block_id, severity, code, trip_ids, detail) do
    %{
      code: code,
      severity: severity,
      block_id: block_id,
      trip_ids: trip_ids,
      transfer_id: nil,
      detail: detail
    }
  end
end
