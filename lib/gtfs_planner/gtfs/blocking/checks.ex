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

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief
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
          | :cannot_reach
          | :type_mismatch
          | :short_layover
          | :in_seat_stale
          | :too_long
          | :no_relief_opportunity
          | :interlining_not_allowed
          | :block_attributes_conflict
          # Page-level, not a block's: the day load raises one per short fleet row
          # with `block_id: nil`, so no block is named and `@status_order` (which
          # is consulted per block) has no place for it.
          | :fleet_shortfall
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

  A planning context (R9) adds what the movements and the relief schedule of the
  block say about it. The block is resolved once through
  `Context.resolve_block/3`, its movements and relief stretches are built once,
  and the findings are then read off those results rather than a second rule:

    * a `{:moves, _}` gap whose drive is known but longer than the gap is a
      `:cannot_reach` error carrying `drive_secs` and `gap_secs`; the same gap
      with a reachable drive raises no `:repositions`, because the vehicle gets
      there under its own power, and a drive that could not be computed at all
      keeps the `:repositions` notice with `drive: :unknown`
    * `:short_layover` measures the wait *after* the drive, so a gap with a long
      deadhead and a short wait is reported at the wait
    * `:too_long` compares the platform minutes with the lower of the resolved
      vehicle type's `max_out_minutes` and `max_block_minutes`, when either is set
    * every unrelieved stretch longer than `max_piece_minutes` raises one
      `:no_relief_opportunity`, and an unset limit raises none (R6)
    * `:type_mismatch` per trip whose route requires a type the block does not
      have, and one `:block_attributes_conflict` per block whose attribute rows
      disagree (R4)
    * `:interlining_not_allowed` per gap where the setting forbids switching
      route: `:same_stop` allows a switch only at the same stop or the same
      station, and `:none` allows none

  `Context.layover_only/1` carries the stored minimum layover and nothing else
  and reproduces spec 05's findings exactly through it (CR-2); a context with
  planning inputs adds the findings R9 describes.
  """
  @spec block_findings(String.t() | nil, [trip_row()], Context.t()) :: [finding()]
  def block_findings(block_id, trips, %Context{} = context) do
    sequence = sequence(trips)
    overlaps = overlap_findings(block_id, overlap_pairs(sequence))

    if context.planning? do
      resolution = resolution(context, block_id, sequence)
      movements = Movements.build(sequence, resolution, context)

      overlaps ++
        planning_gap_findings(block_id, movements, sequence, context) ++
        platform_findings(block_id, movements, sequence, resolution, context) ++
        type_findings(block_id, sequence, resolution, context) ++
        conflict_finding(block_id, sequence, resolution) ++
        notices(block_id, trips)
    else
      overlaps ++
        gap_findings(block_id, gaps(sequence), context) ++
        notices(block_id, trips)
    end
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

  defp gap_findings(block_id, gaps, context) do
    min_layover_minutes = context.min_layover_minutes

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

  # --- planning findings (R9) ------------------------------------------------

  # R4 decides the block's garage and type once (INV-9). A check that has no
  # block of its own - the pool notices `Blocking` raises for a candidate trip -
  # resolves to nothing rather than borrowing another block's rows, so a trip
  # outside every block is never described as one that runs from a garage.
  defp resolution(context, block_id, sequence) do
    if is_binary(block_id) do
      Context.resolve_block(context, block_id, sequence)
    else
      %{garage_id: nil, vehicle_type_id: nil, garage_source: :none, conflict: nil}
    end
  end

  # `Movements.build/3` re-sequences its input, so the gaps it returns line up
  # with the sequence's own consecutive pairs. The handoff is read here rather
  # than taken from the movement, because the interlining rule is stated in terms
  # of the handoff and the movement keeps only the gap's kind.
  defp planning_gap_findings(block_id, movements, sequence, context) do
    movements.gaps
    |> Enum.zip(Enum.zip(sequence, Enum.drop(sequence, 1)))
    |> Enum.filter(fn {gap, _trips} -> gap.gap_secs >= 0 end)
    |> Enum.flat_map(fn {gap, {from, to}} ->
      handoff = handoff(from.last_stop, to.first_stop)

      reach_finding(block_id, gap) ++
        layover_finding(block_id, gap, context) ++
        interlining_finding(block_id, gap, from, to, handoff, context) ++
        reposition_finding(block_id, gap, handoff)
    end)
  end

  # R9: an infeasible gap is an error, not an empty move. The drive is known
  # here - an unknown one is a `:unknown` gap with no feasibility claim at all -
  # so the finding can name the number that does not fit.
  defp reach_finding(block_id, %{kind: :drive, feasible?: false} = gap) do
    [
      finding(block_id, :error, :cannot_reach, [gap.from_id, gap.to_id], %{
        drive_secs: gap.drive_secs,
        gap_secs: gap.gap_secs
      })
    ]
  end

  defp reach_finding(_block_id, _gap), do: []

  # R9: the layover is the wait the vehicle gets, not the gap it sits in. A gap
  # whose drive could not be computed has no wait to measure, and its gap is the
  # most the wait can be, so that is what is compared - the same answer spec 05
  # gave, and never a silent pass on a gap that is really short. A gap the
  # vehicle cannot reach is left to `:cannot_reach`: its wait is negative, and
  # "short layover" would be a weaker restatement of the error above it.
  defp layover_finding(_block_id, %{feasible?: false}, _context), do: []

  defp layover_finding(block_id, gap, context) do
    wait_secs = if is_integer(gap.wait_secs), do: gap.wait_secs, else: gap.gap_secs

    if wait_secs < context.min_layover_minutes * 60 do
      [
        finding(block_id, :warning, :short_layover, [gap.from_id, gap.to_id], %{
          gap_secs: gap.gap_secs,
          wait_secs: wait_secs
        })
      ]
    else
      []
    end
  end

  # R9: the notice survives only where the drive is unknown. A reachable deadhead
  # is the vehicle's work, and `drive: :unknown` is what tells the page that the
  # move is unmeasured rather than merely measured as short.
  defp reposition_finding(block_id, %{kind: :unknown} = gap, {:moves, meters} = _handoff) do
    [
      finding(block_id, :notice, :repositions, [gap.from_id, gap.to_id], %{
        gap_secs: gap.gap_secs,
        meters: meters,
        drive: :unknown
      })
    ]
  end

  defp reposition_finding(_block_id, _gap, _handoff), do: []

  defp interlining_finding(block_id, gap, from, to, handoff, context) do
    if from.route_id != to.route_id and interlining_forbids?(context.interlining, handoff) do
      [
        finding(block_id, :warning, :interlining_not_allowed, [from.id, to.id], %{
          from_route_id: from.route_id,
          to_route_id: to.route_id,
          handoff: handoff_kind(handoff),
          gap_secs: gap.gap_secs,
          interlining: context.interlining
        })
      ]
    else
      []
    end
  end

  # A route switch is the vehicle changing what it is running between two trips.
  # `:any` allows it wherever the schedule puts it, `:none` allows none, and
  # `:same_stop` allows it only where one operator can take over without moving
  # the bus: the same stop or the same station. A move between locations is not
  # interlining, so it is reported; a switch at one stop is.
  defp interlining_forbids?(:none, _handoff), do: true
  defp interlining_forbids?(:same_stop, handoff), do: handoff not in [:same_stop, :same_station]
  defp interlining_forbids?(:any, _handoff), do: false

  defp handoff_kind(:same_stop), do: :same_stop
  defp handoff_kind(:same_station), do: :same_station
  defp handoff_kind({:nearby, _meters}), do: :nearby
  defp handoff_kind({:moves, _meters}), do: :moves

  # Platform time is the pull-out start to the pull-back end, or the block's own
  # first departure to last arrival when it has no garage to pull out of. Only a
  # set limit can exceed it, and the lower of the two that are set is the one the
  # vehicle actually has to satisfy.
  defp platform_findings(block_id, movements, sequence, resolution, context) do
    too_long_finding(block_id, movements, sequence, resolution, context) ++
      relief_findings(block_id, movements, sequence, context)
  end

  defp too_long_finding(block_id, movements, sequence, resolution, context) do
    with platform_start when is_integer(platform_start) <- movements.platform_start_secs,
         platform_end when is_integer(platform_end) <- movements.platform_end_secs,
         {limit_minutes, source} when is_integer(limit_minutes) <-
           limit_minutes(resolution, context) do
      platform_secs = platform_end - platform_start

      if div(platform_secs, 60) > limit_minutes do
        [
          finding(block_id, :warning, :too_long, Enum.map(sequence, & &1.id), %{
            platform_secs: platform_secs,
            limit_minutes: limit_minutes,
            limit_source: source
          })
        ]
      else
        []
      end
    else
      _no_platform_or_no_limit -> []
    end
  end

  defp limit_minutes(resolution, context) do
    type_limit =
      case resolution.vehicle_type_id &&
             Map.get(context.vehicle_types, resolution.vehicle_type_id) do
        %{max_out_minutes: minutes} -> minutes
        _no_type -> nil
      end

    [{type_limit, :vehicle_type}, {context.max_block_minutes, :max_block_minutes}]
    |> Enum.filter(fn {minutes, _source} -> is_integer(minutes) end)
    |> case do
      [] -> nil
      limits -> Enum.min_by(limits, &elem(&1, 0))
    end
  end

  # R6's stretches come from the block's own relief windows, and a limit that is
  # not set raises nothing: an operator has not said this block needs a break, so
  # there is no contract for it to fail.
  defp relief_findings(block_id, movements, sequence, context) do
    case context.max_piece_minutes do
      nil ->
        []

      max_piece_minutes ->
        limit_secs = max_piece_minutes * 60
        windows = Relief.windows(sequence, movements, context)

        movements
        |> Relief.stretches(windows, limit_secs)
        |> Enum.filter(&(&1.secs > limit_secs))
        |> Enum.map(&relief_finding(block_id, &1, limit_secs, sequence))
    end
  end

  # The stretch is named by the trips it covers rather than by the whole block, so
  # two stretches of one block are two findings and not one. A stretch inside the
  # pull-out, before the first trip has departed, belongs to that trip's block all
  # the same, and falls back to the sequence's own ends.
  defp relief_finding(
         block_id,
         %{from_secs: from_secs, to_secs: to_secs} = stretch,
         limit_secs,
         sequence
       ) do
    {first, last} = covering_trips(sequence, from_secs, to_secs)

    finding(
      block_id,
      :warning,
      :no_relief_opportunity,
      Enum.uniq([first, last]),
      Map.put(stretch, :limit_secs, limit_secs)
    )
  end

  defp covering_trips([], _from_secs, _to_secs), do: {nil, nil}

  defp covering_trips([_first | _] = sequence, from_secs, to_secs) do
    case Enum.filter(sequence, &covers?(&1, from_secs, to_secs)) do
      [] -> {Enum.at(sequence, 0).id, List.last(sequence).id}
      covering -> {List.first(covering).id, List.last(covering).id}
    end
  end

  defp covers?(trip, from_secs, to_secs) do
    trip.first_departure < to_secs and trip.last_arrival >= from_secs
  end

  # R4's type against every trip's route requirement. A route that names a type
  # the block does not have is an error on that trip, and it is an error rather
  # than a warning because the block cannot legally run it at all.
  defp type_findings(block_id, sequence, resolution, context) do
    Enum.flat_map(sequence, fn trip ->
      case Map.get(context.route_settings, trip.route_id) do
        %{required_vehicle_type_id: required}
        when not is_nil(required) and required != resolution.vehicle_type_id ->
          [
            finding(block_id, :error, :type_mismatch, [trip.id], %{
              vehicle_type_id: resolution.vehicle_type_id,
              required_vehicle_type_id: required
            })
          ]

        _route_agrees ->
          []
      end
    end)
  end

  # One report for the block, carrying every row so the page can show which
  # calendar says what. The rows themselves are `resolve_block/3`'s, compared
  # before the context's own filtering on purpose.
  defp conflict_finding(block_id, sequence, %{conflict: rows}) when is_list(rows) do
    [
      finding(block_id, :warning, :block_attributes_conflict, Enum.map(sequence, & &1.id), %{
        rows: rows
      })
    ]
  end

  defp conflict_finding(_block_id, _sequence, _resolution), do: []

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
