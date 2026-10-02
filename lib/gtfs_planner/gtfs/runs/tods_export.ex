defmodule GtfsPlanner.Gtfs.Runs.TodsExport do
  @moduledoc """
  The `run_events.txt` rows for every day type's derived runs, in the TODS v2.1.0
  `run_events.txt` layout.

  A run is the finest thing a planner made by hand, and this file is where it
  becomes something a consumer can read. Each run's events follow the run's own
  `WorkTime.segments` in time order, numbered 10, 20, …, and the four movement
  kinds — `Pull-Out`, `Operator`, `Deadhead`, `Pull-Back` — are expanded out of
  the piece that owns them rather than being written as one event per piece. A
  piece is a span of a vehicle's day; a consumer needs to see the trips inside it.

  Identifiers are read, never generated. `service_id` is the movement export's
  per-day-type service, and the `Pull-Out`, `Deadhead` and `Pull-Back` trip IDs come from
  `Blocking.TodsExport`'s `ids`, because those are the IDs the movement files were
  actually written under. A caller that appended a suffix to reach the
  previous-day service would name a service nobody wrote: reservation suffixes the
  ID when it collides, so `_prev` can really be `_prev_2`.

  A run signing on before midnight is a run of the *previous* service day, so it
  is written on that day's `_prev` service with every one of its times 86,400
  seconds later. A time is never negative, and a revenue event past midnight
  reads above 24:00 rather than being wrapped into the morning — a run that works
  to 06:00 has genuinely worked to 06:00.

  A run with any error-severity finding is left out and counted, not written with
  a caveat: a file carrying a run nobody can roster is worse than a warning saying
  how many were dropped. Trips in no run at all are counted per day type for the
  same reason.

  The module is pure: it reads its arguments and calls no repository, clock, file
  or network. Runs stay derived and stored nowhere — these rows are rebuilt from
  `Day.derived()` on every export.
  """

  alias GtfsPlanner.Gtfs.GtfsTime

  @seconds_per_day 86_400

  @job_type "Operator"

  @event_travel "Travel"
  @event_report "Report Time"
  @event_pull_out "Pull-Out"
  @event_operator "Operator"
  @event_deadhead "Deadhead"
  @event_pull_back "Pull-Back"
  @event_break "Break"
  @event_sign_off "Sign-Off"

  # TODS reads `2` as "does not start or end mid-trip". Every event this module
  # writes begins and ends at a point the vehicle is actually at, so it is never 1.
  @at_a_point 2

  @sequence_step 10

  @type input :: %{
          required(:day_types) => [map()],
          required(:run_days) => %{optional(String.t()) => map()},
          required(:ids) => map(),
          required(:garages_by_id) => %{optional(Ecto.UUID.t()) => map()}
        }

  @type result :: %{
          run_events: [map()],
          left_out: non_neg_integer(),
          uncovered: [%{day_type: map(), trips: non_neg_integer()}]
        }

  @doc """
  The `run_day_types/1` map `Blocking.TodsExport.rows/1` takes.

  One entry per day type that has runs, each saying whether that day type needs
  its `_prev` service. `prev?` is true only when some run on the day type signs on
  before midnight, which is the only thing that makes a previous-day service carry
  a row a consumer can act on.

  A day type with **no runs at all** is left out of the map altogether, not listed
  with `prev?: false`. This is the rule that keeps a version with blocks but no
  runs from gaining an empty `calendar_dates_supplement.txt`: asking for a service
  makes `Blocking.TodsExport` mint one and list the day type's dates on it, which
  is precisely the header-only file the movement export refuses to write. A day type is asked
  for a service when it has something to hang on that service.

  A run with an error finding does not count towards `prev?`: it is left out of
  `run_events.txt` entirely, so reserving a service for it would write one listing
  dates with nothing on it. It does not remove the day type from the map, because
  the day type's other runs are still written.
  """
  @spec run_day_types(%{optional(String.t()) => map()}) :: %{optional(String.t()) => map()}
  def run_day_types(run_days) when is_map(run_days) do
    for {key, day} <- run_days, day.runs != [], into: %{} do
      {key, %{prev?: prev?(day)}}
    end
  end

  defp prev?(day) do
    day.runs
    |> Enum.reject(&error_run?/1)
    |> Enum.any?(&(&1.work.sign_on_secs < 0))
  end

  @doc """
  Builds the `run_events` rows for every day type's runs.

  `day_types` is walked in its own order and a run's events in time order, so the
  file reads as one planner's day. `ids` is `Blocking.TodsExport`'s `ids` key; a
  day type missing from it writes nothing, because a run event with no service is
  a row no consumer can act on.

  `garages_by_id` resolves a garage endpoint to its public `garage_id`, the only
  place a planning reference becomes a public one. A garage a run names but
  the map does not cover is resolved with `Map.fetch!/2`, so a caller that passed
  the wrong map is told rather than served an event with no location.
  """
  @spec rows(input()) :: result()
  def rows(%{day_types: day_types, run_days: run_days, ids: ids, garages_by_id: garages_by_id}) do
    {events, left_out, uncovered} =
      Enum.reduce(day_types, {[], 0, []}, fn day_type, {events, left_out, uncovered} ->
        case Map.get(run_days, day_type.key) do
          nil ->
            {events, left_out, uncovered}

          day ->
            {day_events, day_left_out} =
              day_events(day_type.key, day, ids, garages_by_id)

            {events ++ day_events, left_out + day_left_out,
             uncovered ++ day_uncovered(day_type, day)}
        end
      end)

    %{
      run_events: events,
      left_out: left_out,
      # A day type with nothing uncovered says nothing: a "0 trips" warning for
      # every day type of a healthy version is noise.
      uncovered: Enum.reject(uncovered, &(&1.trips == 0))
    }
  end

  # One day type's runs, in order, with the runs carrying errors dropped and
  # counted. A run is dropped whole: half a run in a consumer's feed is worse than
  # none, because the sequence numbers would no longer describe a day.
  defp day_events(key, day, ids, garages_by_id) do
    case Map.get(ids.service_ids, key) do
      nil ->
        {[], 0}

      services ->
        Enum.reduce(day.runs, {[], 0}, &day_run_events(&1, &2, key, services, ids, garages_by_id))
        |> then(fn {events, left_out} -> {Enum.reverse(events) |> List.flatten(), left_out} end)
    end
  end

  # One run's contribution to the day. A run with an error finding contributes
  # nothing and is counted, so the day's count is the number of runs that did not
  # reach the file.
  defp day_run_events(run, {events, left_out}, key, services, ids, garages_by_id) do
    if error_run?(run) do
      {events, left_out + 1}
    else
      {[run_events(key, run, services, ids, garages_by_id) | events], left_out}
    end
  end

  # A day type with no runs has not been cut yet, so its trips are not reported:
  # a version exported with blocks and no runs would otherwise warn about every
  # trip of every day type on every export.
  defp day_uncovered(_day_type, %{runs: []}), do: []
  defp day_uncovered(day_type, day), do: [uncovered(day_type, day)]

  # The trips of every piece in no run at all, counted for the day type's warning.
  defp uncovered(day_type, day) do
    trips =
      day.uncovered
      |> Enum.flat_map(& &1.trips)
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    %{day_type: day_type, trips: length(trips)}
  end

  defp error_run?(run), do: Enum.any?(run.findings, &(&1.severity == :error))

  # One run's events, in time order, numbered from 10. The service and the shift
  # are decided once per run and stamped on every one of its events, so a break or
  # a sign-off hangs on the same service as the trips around it.
  defp run_events(key, run, services, ids, garages_by_id) do
    {service_id, shift} = service_for(run, services)

    events =
      run.work.segments
      |> annotate_segments()
      |> Enum.flat_map(
        &segment_event(&1, %{
          key: key,
          run: run,
          service_id: service_id,
          ids: ids,
          garages_by_id: garages_by_id,
          shift: shift
        })
      )
      |> Enum.sort_by(& &1.start_secs)
      # 10, 20, 30 … rather than 0, 1, 2: a consumer reads a run's events off
      # these numbers, and the gaps leave room to insert one later.
      |> Enum.with_index(1)
      |> Enum.map(fn {event, n} -> Map.put(event, :event_sequence, n * @sequence_step) end)
      |> Enum.map(&row/1)

    events
  end

  # A run that signs on before midnight belongs to the previous service day, so it
  # is written on that day's `_prev` service and every one of its times moves a
  # day later. The `_prev` service must exist: a day type with such a run is
  # `prev?`, which is what reserved it. Writing the run on the day's own service
  # would place it on dates the service does not run.
  # Each segment is tagged with the index of the next piece, which is the piece a
  # report and its travel belong to: an operator reports *for* a piece, so the two
  # rows are read together. A break and a sign-off belong to no piece and keep
  # neither, which is why the walk is forwards rather than backwards.
  defp annotate_segments(segments) do
    segments
    |> Enum.reverse()
    |> Enum.map_reduce(nil, fn segment, next ->
      # Walking backwards, a piece segment is the one the segments before it
      # report for.
      next = if segment.kind == :piece, do: segment.piece_index, else: next

      # Only a report and its travel belong to a piece. A break sits between two
      # pieces and a sign-off after the last one, so attaching either would say
      # the operator was working that piece at that time.
      index = if segment.kind in [:travel, :report], do: next, else: nil

      {Map.put(segment, :_piece_index, index), next}
    end)
    |> then(fn {tagged, _} -> Enum.reverse(tagged) end)
  end

  defp service_for(run, services) do
    if run.work.sign_on_secs < 0 do
      case services.prev_service_id do
        nil ->
          raise ArgumentError,
                "run #{run.run_id} signs on before midnight but its day type reserved no _prev service"

        prev ->
          {prev, @seconds_per_day}
      end
    else
      {services.service_id, 0}
    end
  end

  defp segment_event(
         %{kind: :piece, piece_index: index} = segment,
         %{run: run} = day
       ) do
    case Enum.at(run.pieces, index - 1) do
      nil ->
        []

      piece ->
        piece_events(piece, index, day, segment)
    end
  end

  defp segment_event(segment, %{run: run, service_id: service_id, shift: shift} = day) do
    {piece_id, block_id} =
      case piece_for(run, segment._piece_index) do
        nil ->
          # A break and a sign-off belong to no piece: the break sits between two
          # pieces and the sign-off after the last one, and writing either with a
          # piece would say the operator was working that piece at that time.
          {nil, nil}

        piece ->
          {"#{run.run_id}-#{segment._piece_index}", piece.block_id}
      end

    [
      %{
        start_secs: segment.start_secs,
        service_id: service_id,
        run_id: run.run_id,
        piece_id: piece_id,
        block_id: block_id,
        event_type: simple_event_type(segment.kind),
        trip_id: "",
        start_location: location(segment.from, day.garages_by_id),
        start_time: clock(segment.start_secs, shift),
        end_location: location(segment.to, day.garages_by_id),
        end_time: clock(segment.end_secs, shift),
        start_mid_trip: nil,
        end_mid_trip: nil
      }
    ]
  end

  defp piece_for(_run, nil), do: nil
  defp piece_for(run, index), do: Enum.at(run.pieces, index - 1)

  defp simple_event_type(:travel), do: @event_travel
  defp simple_event_type(:report), do: @event_report
  defp simple_event_type(:break), do: @event_break
  defp simple_event_type(:sign_off), do: @event_sign_off

  # A piece expanded into the movements and trips it covers, each carrying the
  # piece's own ID and block. The report and the travel around a relief start are
  # separate segments; what is left inside a piece is its own work.
  defp piece_events(
         piece,
         index,
         %{key: key, run: run, service_id: service_id, shift: shift} = day,
         _segment
       ) do
    trips = piece.trips
    piece_id = "#{run.run_id}-#{index}"
    ctx = {key, run, service_id, piece_id, piece, day.garages_by_id, shift}

    pull_out =
      if pull?(piece.start_ref) do
        [
          movement_event(
            ctx,
            @event_pull_out,
            {piece.start_secs, first_departure(trips)},
            {piece.start_ref, {:stop, hd(trips).first_stop.stop_id}},
            movement_trip_id(day.ids, key, piece, :pull_out)
          )
        ]
      else
        []
      end

    operators =
      for trip <- trips do
        movement_event(
          ctx,
          @event_operator,
          {trip.first_departure, trip.last_arrival},
          {{:stop, trip.first_stop.stop_id}, {:stop, trip.last_stop.stop_id}},
          trip.trip_id
        )
      end

    deadheads = deadhead_events(ctx, day.ids, trips)

    pull_back =
      if pull?(piece.end_ref) do
        [
          movement_event(
            ctx,
            @event_pull_back,
            {last_arrival(trips), piece.end_secs},
            {{:stop, List.last(trips).last_stop.stop_id}, piece.end_ref},
            movement_trip_id(day.ids, key, piece, :pull_back)
          )
        ]
      else
        []
      end

    pull_out ++ operators ++ deadheads ++ pull_back
  end

  # Only the drive gaps the piece owns become events, and each is looked up by its
  # own gap index, which is what keeps two drives in one block apart. A layover is
  # not a movement. An unknown drive has no time a consumer could schedule, so it
  # is not written — and carries no ID either, for the same reason.
  defp deadhead_events(
         {key, run, service_id, piece_id, piece, garages_by_id, shift},
         ids,
         trips
       ) do
    ctx = {key, run, service_id, piece_id, piece, garages_by_id, shift}
    by_id = Map.new(trips, &{&1.id, &1})

    for %{kind: :drive, index: index} = gap <- piece.gaps,
        %{last_stop: %{stop_id: from_id}} = Map.get(by_id, gap.from_id),
        %{first_stop: %{stop_id: to_id}} = Map.get(by_id, gap.to_id) do
      movement_event(
        ctx,
        @event_deadhead,
        {gap.arrival_secs, gap.arrival_secs + gap.drive_secs},
        {{:stop, from_id}, {:stop, to_id}},
        movement_trip_id(ids, key, piece, {:gap, index})
      )
    end
  end

  defp movement_trip_id(ids, key, piece, leg) do
    Map.get(ids.movement_trip_ids, {key, piece.block_id, leg}, "")
  end

  defp first_departure([first | _]), do: first.first_departure
  defp last_arrival(trips), do: List.last(trips).last_arrival

  # A block that opens with a pull-out starts at the garage, and one that closes
  # with a pull-back ends there. A piece that starts at a relief starts at a stop
  # instead and has no pull-out of its own — the relief drive belongs to the
  # outgoing operator, not to this run.
  defp pull?({:garage, _uuid}), do: true
  defp pull?(_ref), do: false

  defp movement_event(
         {_key, run, service_id, piece_id, piece, garages_by_id, shift},
         event_type,
         {start_secs, end_secs},
         {from, to},
         trip_id
       ) do
    %{
      start_secs: start_secs,
      service_id: service_id,
      run_id: run.run_id,
      piece_id: piece_id,
      block_id: piece.block_id,
      event_type: event_type,
      trip_id: trip_id,
      start_location: location(from, garages_by_id),
      start_time: clock(start_secs, shift),
      end_location: location(to, garages_by_id),
      end_time: clock(end_secs, shift),
      start_mid_trip: @at_a_point,
      end_mid_trip: @at_a_point
    }
  end

  # Columns in TODS order, which is how `Operations.Tods.run_events_spec/0` writes
  # them. A `nil` is a blank cell: the file is fixed-width by column, not by
  # content.
  defp row(event) do
    %{
      service_id: event.service_id,
      run_id: event.run_id,
      event_sequence: event.event_sequence,
      piece_id: event.piece_id,
      block_id: event.block_id,
      job_type: @job_type,
      event_type: event.event_type,
      trip_id: event.trip_id,
      start_location: event.start_location,
      start_time: event.start_time,
      start_mid_trip: event.start_mid_trip,
      end_location: event.end_location,
      end_time: event.end_time,
      end_mid_trip: event.end_mid_trip
    }
  end

  # A location is a GTFS `stop_id`, or the garage's own public `garage_id` — the
  # only place a planning reference becomes a public one. A location the
  # event does not name is blank rather than a made-up stop.
  defp location(nil, _garages_by_id), do: ""
  defp location({:stop, stop_id}, _garages_by_id), do: stop_id

  defp location({:garage, garage_uuid}, garages_by_id) do
    Map.fetch!(garages_by_id, garage_uuid).garage_id
  end

  # `HH:MM:SS` of the run's service day, a day later when the run signed on before
  # midnight. A time past 24:00 is kept, as GTFS allows: a run working to 06:00 has
  # worked to 06:00, and wrapping it into the morning would move it.
  defp clock(secs, shift) do
    total = secs + shift

    if total < 0 do
      raise ArgumentError, "a run event time cannot be negative: #{total} s"
    end

    GtfsTime.format(total)
  end
end
