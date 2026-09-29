defmodule GtfsPlanner.Gtfs.Blocking.Movements do
  @moduledoc """
  Pull-outs, pull-backs and the drives between a block's trips, as R2 and R3
  define them.

  A block's movements are *derived* and never stored (INV-8): `build/3` computes
  them from the block's trips, the garage and vehicle type resolved by
  `Blocking.Context.resolve_block/3` (INV-9) and the version's planning inputs.
  The day load, checks, relief, the generator, the export and the page all read
  this result rather than repeating the rule.

  All arithmetic is in service-day seconds. A vehicle can leave the garage before
  00:00 and return after 24:00, so a start below zero and an end above 86,400
  are ordinary values here; wrapping them is a display concern, not an arithmetic
  one.

  A pull-out ends at the first departure less `pull_out_buffer_minutes` and starts
  one drive earlier, so a 00:05 first departure behind a 20-minute pull-out starts
  at −900 s. The pull-back mirrors it: it starts one buffer after the last arrival
  and ends one drive later. A block with no resolvable garage has no pulls at all,
  and its platform span is then the first departure to the last arrival. An
  endpoint stop the feed does not describe leaves the same way: there is nowhere
  to drive, so there is no pull and the span falls back.

  Between trips, `Blocking.Checks.handoff/2` decides the kind (R2). The same stop,
  the same station and a stop within 200 m are all a layover, so the whole gap is
  wait; only a move beyond 200 m gets a drive, and `wait` is `gap − drive`. A
  negative wait is a real answer — the vehicle cannot get there in time — so it is
  reported as `feasible?: false` rather than rounded away. A drive that cannot be
  computed stays `:unknown` with no feasibility claim at all, because an unknown
  that became `0` would make every gap look reachable (FH-40).

  Three totals fall out of the legs. `service_secs` is the time the vehicle spends
  in service on its trips — each trip from its first departure to its last
  arrival — so with the drives and the waits it accounts for the platform span
  between them. `layover_secs` counts only non-negative waits: a wait that came
  out negative is an infeasibility, not time spent parked. `drive_secs` adds the
  two pulls to the inter-trip drives.

  Distance follows AC-7. `service_km` sums the trip distances the context already
  measured, and `service_km_estimated?` is true when any of them came from a stop
  path rather than a shape. `deadhead_km` adds the straight-line distance of the
  *estimated* legs only: an entered driving time is a human's real route and its
  distance is unknown, so it contributes no kilometres rather than a straight line
  that would understate the day.

  The module is pure: it reads its arguments and calls no repository, clock, file
  or network (CR-1). Garage references carry the garage's UUID, never its
  correctable public `garage_id` (CR-7).
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes

  @seconds_per_minute 60

  @type pull :: %{
          from: Context.ref(),
          to: Context.ref(),
          start_secs: integer(),
          end_secs: integer(),
          drive_secs: non_neg_integer() | nil,
          source: :entered | :estimated | :unknown,
          km: float() | nil
        }

  @type gap :: %{
          index: non_neg_integer(),
          from_id: Ecto.UUID.t(),
          to_id: Ecto.UUID.t(),
          arrival_secs: integer(),
          departure_secs: integer(),
          gap_secs: integer(),
          kind: :layover | :drive | :unknown,
          drive_secs: non_neg_integer() | nil,
          source: :entered | :estimated | :unknown | nil,
          wait_secs: integer() | nil,
          feasible?: boolean() | nil,
          km: float() | nil
        }

  @type t :: %{
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          pull_out: pull() | nil,
          pull_back: pull() | nil,
          gaps: [gap()],
          platform_start_secs: integer() | nil,
          platform_end_secs: integer() | nil,
          service_secs: non_neg_integer(),
          layover_secs: non_neg_integer(),
          drive_secs: non_neg_integer(),
          service_km: float(),
          service_km_estimated?: boolean(),
          deadhead_km: float()
        }

  @doc """
  Derives one block's movements from its trips, its resolved garage and type and
  the version's planning inputs.

  `trips` is the block's `Checks.sequence/1` order; it is re-sequenced here so a
  caller that hands over raw trips cannot crash the arithmetic on a
  frequency-based or unplottable row. A block with no usable trip has no pulls, no
  gaps, a `nil` platform span and zero totals.
  """
  @spec build([Checks.trip_row()], Context.resolve_result(), Context.t()) :: t()
  def build(trips, resolution, context) do
    sequence = Checks.sequence(trips)
    gaps = build_gaps(sequence, context)
    pull_out = pull_out(sequence, resolution.garage_id, context)
    pull_back = pull_back(sequence, resolution.garage_id, context)

    %{
      garage_id: resolution.garage_id,
      vehicle_type_id: resolution.vehicle_type_id,
      pull_out: pull_out,
      pull_back: pull_back,
      gaps: gaps,
      platform_start_secs: platform_start(sequence, pull_out),
      platform_end_secs: platform_end(sequence, pull_back),
      service_secs: service_secs(sequence),
      layover_secs: layover_secs(gaps),
      drive_secs: drive_secs([pull_out, pull_back], gaps),
      service_km: service_km(sequence, context),
      service_km_estimated?: service_km_estimated?(sequence, context),
      deadhead_km: deadhead_km([pull_out, pull_back], gaps)
    }
  end

  # R2: the handoff decides the kind, and only a move gets a drive. `Checks.gaps/1`
  # supplies `gap_secs` and the handoff; the trips are zipped back onto it for the
  # endpoint stops a drive needs. Both come from the same `sequence`, so the two
  # lists align by construction.
  defp build_gaps(sequence, context) do
    sequence
    |> Checks.gaps()
    |> Enum.zip(Enum.zip(sequence, Enum.drop(sequence, 1)))
    |> Enum.with_index()
    |> Enum.map(fn {{%{gap_secs: gap_secs, handoff: handoff}, {from, to}}, index} ->
      build_gap(index, from, to, gap_secs, handoff, context)
    end)
  end

  defp build_gap(index, from, to, gap_secs, handoff, context) do
    base = %{
      index: index,
      from_id: from.id,
      to_id: to.id,
      arrival_secs: from.last_arrival,
      departure_secs: to.first_departure,
      gap_secs: gap_secs
    }

    case handoff do
      :same_stop -> layover_gap(base, gap_secs)
      :same_station -> layover_gap(base, gap_secs)
      {:nearby, _meters} -> layover_gap(base, gap_secs)
      {:moves, _meters} -> moving_gap(base, from.last_stop, to.first_stop, gap_secs, context)
    end
  end

  # The whole gap is wait: the vehicle is already where the next trip starts. A
  # layover gap shorter than zero is an overlap rather than a reachable handoff, so
  # it is not called feasible — `Checks` reports the overlap itself.
  defp layover_gap(base, gap_secs) do
    Map.merge(base, %{
      kind: :layover,
      drive_secs: nil,
      source: nil,
      wait_secs: gap_secs,
      feasible?: gap_secs >= 0,
      km: nil
    })
  end

  defp moving_gap(base, from_stop, to_stop, gap_secs, context) do
    case {stop_ref(from_stop), stop_ref(to_stop)} do
      {nil, _to_ref} ->
        unknown_gap(base)

      {_from_ref, nil} ->
        unknown_gap(base)

      {from_ref, to_ref} ->
        drive_gap(base, from_ref, from_stop, to_ref, to_stop, gap_secs, context)
    end
  end

  defp drive_gap(base, from_ref, from_stop, to_ref, to_stop, gap_secs, context) do
    %{minutes: minutes, source: source} =
      DeadheadTimes.lookup(
        from_ref,
        stop_point(from_stop),
        to_ref,
        stop_point(to_stop),
        context
      )

    case minutes do
      nil ->
        unknown_gap(base)

      minutes ->
        drive_secs = minutes * @seconds_per_minute
        fields = drive_gap_fields(drive_secs, source, gap_secs, from_stop, to_stop, context)
        Map.merge(base, fields)
    end
  end

  defp drive_gap_fields(drive_secs, source, gap_secs, from_stop, to_stop, context) do
    %{
      kind: :drive,
      drive_secs: drive_secs,
      source: source,
      wait_secs: gap_secs - drive_secs,
      feasible?: gap_secs >= drive_secs,
      km: leg_km(source, stop_point(from_stop), stop_point(to_stop), context)
    }
  end

  # No feasibility claim: an unknown drive must never read as a reachable one.
  defp unknown_gap(base) do
    Map.merge(base, %{
      kind: :unknown,
      drive_secs: nil,
      source: :unknown,
      wait_secs: nil,
      feasible?: nil,
      km: nil
    })
  end

  # R3: the pull-out ends one buffer before the first departure and starts one
  # drive earlier. The anchor is the end, so an unknown drive collapses it to a
  # zero-length pull rather than moving the vehicle backwards in time.
  defp pull_out([], _garage_id, _context), do: nil

  defp pull_out(sequence, garage_id, context) do
    first = List.first(sequence)

    with {:garage, _uuid} = garage_ref <- garage_ref(garage_id),
         {:stop, _stop_id} = to_ref <- stop_ref(first.first_stop) do
      pull(
        garage_ref,
        garage_point(context, garage_id),
        to_ref,
        stop_point(first.first_stop),
        first.first_departure - context.pull_out_buffer_minutes * @seconds_per_minute,
        :end,
        context
      )
    else
      _unresolvable -> nil
    end
  end

  # The pull-back mirrors it: it starts one buffer after the last arrival and ends
  # one drive later, so a 25:10 arrival legitimately ends above 86,400 s.
  defp pull_back([], _garage_id, _context), do: nil

  defp pull_back(sequence, garage_id, context) do
    last = List.last(sequence)

    with {:garage, _uuid} = garage_ref <- garage_ref(garage_id),
         {:stop, _stop_id} = from_ref <- stop_ref(last.last_stop) do
      pull(
        from_ref,
        stop_point(last.last_stop),
        garage_ref,
        garage_point(context, garage_id),
        last.last_arrival + context.pull_out_buffer_minutes * @seconds_per_minute,
        :start,
        context
      )
    else
      _unresolvable -> nil
    end
  end

  defp pull(from_ref, from_point, to_ref, to_point, anchor_secs, anchor, context) do
    %{minutes: minutes, source: source} =
      DeadheadTimes.lookup(from_ref, from_point, to_ref, to_point, context)

    # `DeadheadTimes` speaks in whole minutes; R3 counts in service-day seconds,
    # so the conversion happens here and nowhere else. An unknown drive stays
    # `nil` rather than becoming a zero-second drive.
    drive_secs = if minutes == nil, do: 0, else: minutes * @seconds_per_minute
    {start_secs, end_secs} = span(anchor_secs, drive_secs, anchor)

    %{
      from: from_ref,
      to: to_ref,
      start_secs: start_secs,
      end_secs: end_secs,
      drive_secs: if(minutes == nil, do: nil, else: drive_secs),
      source: source,
      km: leg_km(source, from_point, to_point, context)
    }
  end

  defp span(anchor_secs, drive_secs, :end), do: {anchor_secs - drive_secs, anchor_secs}
  defp span(anchor_secs, drive_secs, :start), do: {anchor_secs, anchor_secs + drive_secs}

  # Without a pull the vehicle is on platform from its first departure to its last
  # arrival; that is the only span the trips themselves support.
  defp platform_start([], _pull_out), do: nil
  defp platform_start(sequence, nil), do: first_departure(sequence)
  defp platform_start(_sequence, pull_out), do: pull_out.start_secs

  defp platform_end([], _pull_back), do: nil
  defp platform_end(sequence, nil), do: List.last(sequence).last_arrival
  defp platform_end(_sequence, pull_back), do: pull_back.end_secs

  defp first_departure(sequence), do: List.first(sequence).first_departure

  # A trip is in service from pulling in at its first stop to pulling out at its
  # last, which is the span the waits and drives of the gaps sit between.
  defp service_secs(sequence) do
    Enum.reduce(sequence, 0, fn trip, total ->
      total + trip.last_arrival - trip.first_departure
    end)
  end

  defp layover_secs(gaps) do
    Enum.reduce(gaps, 0, fn gap, total -> total + max(gap.wait_secs || 0, 0) end)
  end

  defp drive_secs(pulls, gaps) do
    Enum.sum(Enum.map(pulls, &leg_secs/1)) + Enum.sum(Enum.map(gaps, &leg_secs/1))
  end

  defp leg_secs(nil), do: 0
  defp leg_secs(leg), do: leg.drive_secs || 0

  defp service_km(sequence, context) do
    Enum.reduce(sequence, 0.0, fn trip, total -> total + measured_km(trip, context) end)
  end

  defp service_km_estimated?(sequence, context) do
    Enum.any?(sequence, fn trip ->
      match?({_km, :path}, Map.get(context.trip_km, trip.id))
    end)
  end

  defp measured_km(trip, context) do
    case Map.get(context.trip_km, trip.id) do
      {km, _source} -> km
      nil -> 0.0
    end
  end

  # Only an estimated leg has a distance. An entered drive is a real route whose
  # length the version does not carry, and an unknown drive has no points to
  # measure, so neither adds a straight line (AC-7).
  defp deadhead_km(pulls, gaps) do
    Enum.sum(Enum.map(pulls, &leg_km_total/1)) + Enum.sum(Enum.map(gaps, &leg_km_total/1))
  end

  defp leg_km_total(nil), do: 0.0
  defp leg_km_total(leg), do: leg.km || 0.0

  defp leg_km(:estimated, from_point, to_point, context) do
    DeadheadTimes.estimate_km(from_point, to_point, context)
  end

  defp leg_km(_source, _from_point, _to_point, _context), do: nil

  defp garage_ref(nil), do: nil
  defp garage_ref(garage_id), do: {:garage, garage_id}

  defp stop_ref(nil), do: nil
  defp stop_ref(%{stop_id: stop_id}), do: {:stop, stop_id}

  defp garage_point(context, garage_id) do
    case Map.get(context.garages, garage_id) do
      nil -> nil
      garage -> point(garage.lat, garage.lon)
    end
  end

  defp stop_point(nil), do: nil
  defp stop_point(stop), do: point(stop.lat, stop.lon)

  # A coordinate pair needs both numbers; a stop that carries one without the
  # other is as unmeasurable as one that carries neither.
  defp point(lat, lon) when is_number(lat) and is_number(lon), do: {lat * 1.0, lon * 1.0}
  defp point(_lat, _lon), do: nil
end
