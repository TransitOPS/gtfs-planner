defmodule GtfsPlanner.Gtfs.Blocking.TodsExport do
  @moduledoc """
  The four TODS supplement files' rows for a version's derived movements.

  A consumer of a TODS feed needs a *service* to hang a movement on, and a
  movement is a deadhead: it carries no revenue, so the public calendar has no
  service for it. Each day type gets one supplement service listing exactly
  that day type's dates, and a second service with the `_prev` suffix listing the
  same dates one day earlier for the movements that start before midnight — a
  23:45 pull-out belongs to the previous service day, and a `calendar_dates` row
  is the only place a TODS feed can say so. A day type carrying a run that signs
  on before midnight is the exception: its before-midnight movements stay on the
  day type's own service, read one day later, because a consumer requires the
  run's service dates to be a subset of every trip it works and the run names
  that service, not `_prev`.

  The IDs are generated rather than read, because a supplement ID equal to a
  public one would silently attach a deadhead to public service. Every
  generated identifier keeps its shape first and gains a suffix only when that
  shape is taken: a service ID widens its digest — 6, then 8, 10 and 12 hex
  characters of the SHA-256 of the day-type key — before it takes a `_2`, `_3`
  suffix, while the route and trip IDs take a suffix directly. Widening before
  suffixing is what makes a widened ID still read as the same day type, and every
  check is against the public IDs of the same snapshot *and* the ones already
  handed out, so two day types that hash alike still get two services. All three
  kinds draw on one used set, so a supplement identifier is never reused anywhere
  in the export even if the namespacing would have allowed it.

  Only what a consumer can actually run is written. An unknown drive names no
  endpoint it can schedule and no time it can use, so it is left out and counted
  in `omitted` rather than written as a movement with a missing time; a layover is
  not a movement at all and is not counted. That count is what the export turns
  into "N movements have no driving time and were left out."

  A movement's two stop times are its endpoints: the pull-out leaves the garage at
  `start_secs` and reaches the first stop at `end_secs`; a drive leaves the
  previous trip's last stop at its arrival and reaches the next trip's first stop
  one drive later, with the remaining wait left at the destination. A
  time at or above 24:00 is kept, as GTFS allows, so a 25:10 pull-back reads
  `25:10:00` rather than being wrapped back into the morning. On a day type with
  no before-midnight run, a negative time is never formatted: the movement moves
  to the `_prev` service and its clock is read one day later, which is why a 00:05
  first departure behind a 20-minute pull-out leaves the garage at `23:45:00` on
  the previous service day. On a day type whose run signs on before midnight, the
  same movement stays on the day type's own service with one day added to its
  clock, so its `23:45:00` reads against the same service day as the run's
  `30:00:00` trip.

  Garages are written by their correctable `garage_id`, the only place a planning
  reference becomes a public one; every other endpoint is a public
  `stop_id`, read off the same trip rows the movements were derived from.

  The module is pure: it reads its arguments and calls no repository, clock, file
  or network. Movements stay derived and stored nowhere — these rows are
  rebuilt from `Movements.t()` on every export, and the public files never carry
  them.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.GtfsTime

  @seconds_per_day 86_400

  @service_prefix "ops_dt_"
  @prev_suffix "_prev"
  @route_id "deadheads"
  @route_short_name "Deadheads"
  @route_long_name "Vehicle deadheads"
  @route_type 3

  # The digest widths a generated service or trip ID tries, in order, before it
  # falls back to a `_2` suffix.
  @hex_widths [6, 8, 10, 12]

  @type day_type :: %{
          required(:key) => String.t(),
          required(:dates) => [Date.t()],
          optional(atom) => term()
        }

  @typedoc """
  One block as the export needs it: the block's own ID, the trip rows its
  movements were derived from — a drive gap names the trips it sits between, so
  it names its endpoints through them — and those movements.
  """
  @type block :: %{
          required(:block_id) => String.t(),
          required(:trips) => [Checks.trip_row()],
          required(:movements) => Movements.t()
        }

  @type public_ids :: %{
          required(:service_ids) => [String.t()],
          required(:trip_ids) => [String.t()],
          required(:route_ids) => [String.t()]
        }

  @type input :: %{
          required(:day_types) => [day_type()],
          required(:blocks_by_day_type) => %{optional(String.t()) => [block()]},
          required(:garages_by_id) => %{optional(Ecto.UUID.t()) => Context.garage()},
          required(:public_ids) => public_ids()
        }

  @typedoc """
  One movement as it is written, before it is given identifiers: the kind a
  consumer reads, its two endpoints as `Context.ref/0` tuples and its span in
  service-day seconds, which may be negative or above 86,400.
  """
  @type leg :: %{
          kind: :pull_out | :pull_back | :deadhead,
          leg_key: :pull_out | :pull_back | {:gap, non_neg_integer()},
          from: Context.ref(),
          to: Context.ref(),
          start_secs: integer(),
          end_secs: integer()
        }

  @type run_day_type :: %{optional(:shifted?) => boolean()}

  @type result :: %{
          calendar_dates: [map()],
          routes: [map()],
          trips: [map()],
          stop_times: [map()],
          omitted: non_neg_integer()
        }

  @type result_with_ids :: %{
          calendar_dates: [map()],
          routes: [map()],
          trips: [map()],
          stop_times: [map()],
          omitted: non_neg_integer(),
          ids: ids()
        }

  @typedoc """
  The identifiers a consumer needs to refer back to what was written.

  `service_ids` is by day type, so a run event can name the service its run hangs
  on. Each entry carries the `prev_service_id` alongside it, which is `nil` unless
  the `_prev` service was reserved. It is here rather than derivable by the
  caller because reservation can suffix the ID: a `_prev` that collided takes
  `_prev_2`, so appending the suffix at the far end would name a service that was
  never written. `movement_trip_ids` is by `{day_type_key, block_id, leg}` — the leg being
  `:pull_out`, `:pull_back` or `{:gap, index}` for a drive — so a run event on a
  deadhead can name the trip that movement was written as.

  A gap the export could not write, an unknown drive, has no entry: it has no trip,
  so there is nothing to refer to.
  """
  @type ids :: %{
          required(:service_ids) => %{
            optional(String.t()) => %{
              required(:service_id) => String.t(),
              required(:prev_service_id) => String.t() | nil
            }
          },
          required(:movement_trip_ids) => %{
            optional({String.t(), String.t(), term()}) => String.t()
          }
        }

  @doc """
  Builds the supplement rows for every day type's derived movements.

  `input` carries the day types in their own order, the blocks of each by day-type
  key, the garages by UUID and the public trip, route and service IDs of the same
  snapshot. A day type with no exportable movement contributes nothing at all — no
  empty service, no empty route — so the export can omit an empty file rather
  than write a header-only one.

  `run_day_types` is optional and defaults to `%{}`. When a day type carries runs,
  it is listed there and is kept even when it has no movement, because its
  service is what the run events hang on: a day type with runs and no deadhead
  still needs a `service_id` and its `calendar_dates` rows. Such a day type
  contributes no `routes` row, since the deadhead route exists only to carry
  movements.

  A `run_day_types` entry may carry `shifted?: true` to write that day type's
  before-midnight movements with one day added to their clocks on that day type's
  own service, which is what a run reaching before midnight needs: the run names
  the day type's own service, so a movement it works may not sit on `_prev`.

  `garages_by_id` must cover every garage a movement names: a pull's endpoint is
  resolved with `Map.fetch!/2`, so a caller that passed the wrong map is told
  rather than receiving a stop time with no stop.
  """
  @spec rows(input()) :: result() | result_with_ids()
  def rows(
        %{
          day_types: day_types,
          blocks_by_day_type: blocks_by_day_type,
          garages_by_id: garages_by_id,
          public_ids: public_ids
        } = input
      ) do
    run_day_types = Map.get(input, :run_day_types, %{})

    %{days: days, omitted: omitted} =
      collect(day_types, blocks_by_day_type, garages_by_id, run_day_types)

    # No day type survived, so there is no service and no movement to name: the
    # result carries no `ids` at all in this case, and keeps the shape it had
    # before `ids` was added. Every path that can be referred to runs through `build/3`.
    if days == [] do
      %{calendar_dates: [], routes: [], trips: [], stop_times: [], omitted: omitted}
    else
      build(days, omitted, public_ids)
    end
  end

  # One pass over the day types, in their own order, keeping only the legs a
  # consumer can run and counting the ones left out. Nothing is identified yet, so
  # a day type with nothing to write is known before an identifier is spent on it.
  #
  # A day type listed in `run_day_types` is the exception: it is kept with no legs
  # at all, because a run on it still needs a service to hang on. `shifted?` is
  # carried onto the day so the clock choice is made where the movement is written,
  # rather than by threading the whole map into `day_rows/3`.
  defp collect(day_types, blocks_by_day_type, garages_by_id, run_day_types) do
    Enum.reduce(day_types, %{days: [], omitted: 0}, fn day_type, acc ->
      run? = Map.has_key?(run_day_types, day_type.key)
      shifted? = shifted?(Map.get(run_day_types, day_type.key))

      case legs_for(Map.get(blocks_by_day_type, day_type.key, []), garages_by_id, day_type.key) do
        {[], omitted} when run? ->
          %{
            acc
            | days: acc.days ++ [%{day_type: day_type, legs: [], shifted?: shifted?}],
              omitted: acc.omitted + omitted
          }

        {[], omitted} ->
          %{acc | omitted: acc.omitted + omitted}

        {legs, omitted} ->
          %{
            acc
            | days: acc.days ++ [%{day_type: day_type, legs: legs, shifted?: shifted?}],
              omitted: acc.omitted + omitted
          }
      end
    end)
  end

  defp shifted?(nil), do: false
  defp shifted?(run_day_type), do: Map.get(run_day_type, :shifted?, false)

  defp legs_for(blocks, garages_by_id, day_type_key) do
    Enum.flat_map_reduce(blocks, 0, fn block, omitted ->
      {legs, block_omitted} = block_legs(block, garages_by_id)

      legs =
        Enum.map(legs, fn leg ->
          Map.merge(leg, %{
            from: resolve_ref(leg.from, garages_by_id),
            to: resolve_ref(leg.to, garages_by_id),
            movement_key: {day_type_key, block.block_id, leg.leg_key}
          })
        end)

      {Enum.map(legs, &Map.put(&1, :block_id, block.block_id)), omitted + block_omitted}
    end)
  end

  # One block's legs in the order the vehicle runs them: the pull-out, each drive
  # between trips in order, then the pull-back. The order is the vehicle's own, not
  # the order the fields happen to sit in, so a consumer reading the block down the
  # file reads one day's movements. Every leg is returned with its endpoints as the
  # refs `Movements` and the gaps carry, and `legs_for/2` resolves them once.
  defp block_legs(block, _garages_by_id) do
    movements = block.movements

    {pull_out, pull_out_omitted} = pull_leg(movements.pull_out, :pull_out)
    {pull_back, pull_back_omitted} = pull_leg(movements.pull_back, :pull_back)
    {drives, drive_omitted} = drive_legs(block.trips, movements.gaps)

    legs =
      Enum.reject([pull_out | drives] ++ [pull_back], &is_nil/1)

    {legs, pull_out_omitted + pull_back_omitted + drive_omitted}
  end

  # A pull that resolved to a known driving time is written; one that did not has
  # no time a consumer can schedule, so it is counted and left out. A pull is never
  # dropped for being short — a garage already at the first stop is a zero-length
  # pull-out, and that is still a movement.
  defp pull_leg(nil, _kind), do: {nil, 0}
  defp pull_leg(%{drive_secs: nil}, _kind), do: {nil, 1}

  defp pull_leg(pull, kind) do
    leg = %{
      kind: kind,
      leg_key: kind,
      from: pull.from,
      to: pull.to,
      start_secs: pull.start_secs,
      end_secs: pull.end_secs
    }

    {leg, 0}
  end

  # A gap names the trips it sits between, so its endpoints are read off the same
  # `Checks.sequence/1` order the movements were built from. The drive runs
  # first and the wait belongs to the destination, so the leg ends one drive after
  # the arrival rather than at the departure; a gap whose drive overruns its
  # departure is an infeasible plan, and the movement written is still the one it
  # actually describes.
  #
  # The gap's own `index` is carried into the leg, so a drive is addressable as
  # `{:gap, index}` rather than only by where it sits in the written order. A
  # block with two identical drives would otherwise be indistinguishable, and the
  # index is what a run event holds.
  defp drive_legs(trips, gaps) do
    by_id = Map.new(trips, &{&1.id, &1})

    {legs, omitted} =
      Enum.reduce(gaps, {[], 0}, fn
        %{kind: :unknown}, {legs, omitted} ->
          {legs, omitted + 1}

        %{kind: :layover}, acc ->
          acc

        %{kind: :drive} = gap, {legs, omitted} ->
          case {Map.get(by_id, gap.from_id), Map.get(by_id, gap.to_id)} do
            {%{last_stop: %{stop_id: from_id}}, %{first_stop: %{stop_id: to_id}}} ->
              leg = %{
                kind: :deadhead,
                leg_key: {:gap, gap.index},
                from: {:stop, from_id},
                to: {:stop, to_id},
                start_secs: gap.arrival_secs,
                end_secs: gap.arrival_secs + gap.drive_secs
              }

              {[leg | legs], omitted}

            _a_gap_whose_trip_is_not_in_this_block ->
              {legs, omitted + 1}
          end
      end)

    {Enum.reverse(legs), omitted}
  end

  defp build(days, omitted, public_ids) do
    {route_id, used} = reserve(fixed_candidates(@route_id), used_ids(public_ids))

    # The used set is carried through every day type, not reset between them, so
    # two day types that hashed alike still get two services and two sets of trip
    # IDs. Reservation order is `days` order, which is `day_types` order, so an
    # existing export's identifiers do not shift because runs were added.
    {day_rows, {_used, ids}} =
      Enum.map_reduce(days, {used, []}, fn day, {used, ids} ->
        {rows, day_ids, used} = day_rows(day, route_id, used)

        {rows, {used, [day_ids | ids]}}
      end)

    ids = Enum.reverse(ids)
    trips = Enum.flat_map(day_rows, & &1.trips)

    %{
      calendar_dates: Enum.flat_map(day_rows, & &1.calendar_dates),
      # The deadhead route exists only to carry movements, so a run day type with
      # no movement writes none: a route row with no trip on it is a row a
      # consumer cannot act on, which is the same rule that drops a service with
      # no movement.
      routes: if(trips == [], do: [], else: [route_row(route_id)]),
      trips: trips,
      stop_times: Enum.flat_map(day_rows, & &1.stop_times),
      omitted: omitted,
      ids: %{
        service_ids:
          Map.new(ids, &{&1.key, %{service_id: &1.service_id, prev_service_id: &1.prev_id}}),
        movement_trip_ids: Enum.reduce(ids, %{}, &Map.merge(&2, &1.movement_trip_ids))
      }
    }
  end

  # The public identifiers of the same snapshot, as one set. A supplement
  # identifier is checked against all of them, so widening a service digest is also
  # a check against a public trip or route ID rather than only a public service.
  defp used_ids(public_ids) do
    MapSet.new(public_ids.service_ids ++ public_ids.trip_ids ++ public_ids.route_ids)
  end

  defp day_rows(%{day_type: day_type, legs: legs, shifted?: shifted?}, route_id, used) do
    {service_id, used} = reserve(service_candidates(day_type.key), used)

    # The `_prev` service exists when a movement actually starts before midnight
    # and no run on the day type signs on before it: a service listing previous
    # dates with no movement on it is a row no consumer can act on. A day type
    # with such a run instead keeps those movements on its own service, so the
    # run's service dates stay a subset of the trips it works.
    {prev_id, used} =
      if not shifted? and Enum.any?(legs, &(&1.start_secs < 0)) do
        reserve(fixed_candidates(service_id <> @prev_suffix), used)
      else
        {nil, used}
      end

    hex = digest_hex(day_type.key)
    dates = day_type.dates |> Enum.uniq() |> Enum.sort()

    # Each movement appears on its own service exactly once; the pair of services
    # means a consumer reading the previous day finds it, and the reader of the
    # day itself does not.
    calendar_dates =
      [{service_id, dates}, {prev_id, Enum.map(dates, &Date.add(&1, -1))}]
      |> Enum.reject(fn {id, _dates} -> is_nil(id) end)
      |> Enum.flat_map(fn {id, dates} ->
        Enum.map(dates, &%{service_id: id, date: &1, exception_type: 1})
      end)

    # The sequence number is per block, so `dh-<block>-<short>-<seq>` reads as a
    # block's own ordered day, and an omitted movement leaves no hole in it.
    {sequenced, _counters} =
      Enum.map_reduce(legs, %{}, fn leg, counters ->
        seq = Map.get(counters, leg.block_id, 0) + 1
        {{leg, seq}, Map.put(counters, leg.block_id, seq)}
      end)

    {trips_with_times, used} =
      Enum.map_reduce(sequenced, used, fn {leg, seq}, used ->
        {trip_id, used} = reserve(trip_candidates(leg.block_id, hex, seq), used)
        read_on = read_on(leg.start_secs, shifted?)

        trip = %{
          route_id: route_id,
          service_id: if(read_on == :previous, do: prev_id, else: service_id),
          trip_id: trip_id,
          tods_trip_type: leg.kind
        }

        stop_times = [
          stop_time(trip_id, leg.from, leg.start_secs, read_on, 1),
          stop_time(trip_id, leg.to, leg.end_secs, read_on, 2)
        ]

        {{trip, stop_times, {leg.movement_key, trip_id}}, used}
      end)

    {trips, stop_times, movement_trip_ids} = unzip3(trips_with_times)

    {
      %{
        calendar_dates: calendar_dates,
        trips: trips,
        stop_times: Enum.flat_map(stop_times, & &1)
      },
      %{
        key: day_type.key,
        service_id: service_id,
        prev_id: prev_id,
        movement_trip_ids: Map.new(movement_trip_ids)
      },
      used
    }
  end

  # Trips, their stop times and the id each movement was written as, all from one
  # pass — the mapping is only correct if it is taken from the same trip row that
  # was written, never recomputed from the leg afterwards.
  defp unzip3(tuples) do
    Enum.reduce(tuples, {[], [], []}, fn {trip, stop_times, movement}, {t, s, m} ->
      {[trip | t], [stop_times | s], [movement | m]}
    end)
    |> then(fn {t, s, m} -> {Enum.reverse(t), Enum.reverse(s), Enum.reverse(m)} end)
  end

  # A movement is written on the previous service day when it *starts* before
  # midnight and its day type has no before-midnight run, and both of its times
  # are then read against that day: a start of −900 s is 23:45:00 of the day
  # before, and an end of 300 s is 00:05:00 of the day the movement actually
  # starts in. On a day type whose run signs on before midnight the movement stays
  # on the day type's own service and every one of its times moves a day later, so
  # a start of −900 s reads `23:45:00` and an end of 300 s reads `24:05:00`, the
  # same service day the run's own events use. A movement that starts at or after
  # midnight keeps its own day, so a 25:10 pull-back stays `25:10:00` — GTFS
  # allows a time past 24:00 and wrapping it would move the pull-back to the
  # wrong morning.
  defp stop_time(trip_id, stop_id, secs, read_on, sequence) do
    clock = clock(secs, read_on)

    %{
      trip_id: trip_id,
      arrival_time: clock,
      departure_time: clock,
      stop_id: stop_id,
      stop_sequence: sequence
    }
  end

  # How a leg's clock is read: on its own day, on the day before when it starts
  # before midnight on a day type without a before-midnight run, or one day later
  # on the day type's own service when a run signs on before it.
  defp read_on(secs, true) when secs < 0, do: :extended
  defp read_on(secs, _shifted?) when secs < 0, do: :previous
  defp read_on(_secs, _shifted?), do: :own

  defp route_row(route_id) do
    %{
      route_id: route_id,
      route_short_name: @route_short_name,
      route_long_name: @route_long_name,
      route_type: @route_type
    }
  end

  # Only the TODS export turns a garage's UUID into its public `garage_id`;
  # every other endpoint is already a public `stop_id`.
  defp resolve_ref({:stop, stop_id}, _garages_by_id), do: stop_id

  defp resolve_ref({:garage, garage_uuid}, garages_by_id),
    do: Map.fetch!(garages_by_id, garage_uuid).garage_id

  defp service_candidates(key) do
    key |> digest_hex() |> width_candidates(@service_prefix)
  end

  defp trip_candidates(block_id, hex, seq) do
    width_candidates(hex, "dh-#{block_id}-", "-#{seq}")
  end

  # A name with no digest of its own: the route and the previous-day service keep
  # one fixed shape and take a suffix when a public ID already holds it.
  defp fixed_candidates(name) do
    Stream.concat([name], suffixed_candidates([name]))
  end

  # The candidates for one identifier, in preference order: the preferred shape
  # first, then its suffixes. Built lazily, because the suffix tail is unbounded
  # and only the first free form is ever needed.
  defp width_candidates(hex, prefix, suffix \\ "") do
    bases = Enum.map(@hex_widths, &"#{prefix}#{hex_part(hex, &1)}#{suffix}")

    Stream.concat(bases, suffixed_candidates(bases))
  end

  # A day type's own digest, at the width its identifier takes. The key is
  # canonical — `DayTypes.key/1` is the SHA-256 of the day type's sorted service
  # IDs — so the same day type hashes the same way here and in the service ID that
  # leads it, on this run and the next.
  defp digest_hex(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  defp hex_part(hex, width), do: String.slice(hex, 0, width)

  defp suffixed_candidates(bases) do
    Stream.flat_map(Stream.iterate(2, &(&1 + 1)), fn n ->
      Enum.map(bases, &"#{&1}_#{n}")
    end)
  end

  # An identifier is spent once, and the shape it prefers is kept for as long as
  # one of its forms is free: the candidate list runs 6, 8, 10 and 12 hex and only
  # then the `_2`, `_3` suffixes, so a widened ID still reads as the same day type
  # and a suffixed one is a last resort rather than a first choice.
  defp reserve(candidates, used) do
    case Enum.find(candidates, &(not MapSet.member?(used, &1))) do
      nil -> raise ArgumentError, "no free TODS supplement identifier available"
      id -> {id, MapSet.put(used, id)}
    end
  end

  # Service-day seconds as a clock. A time read against the previous service day
  # is read one day earlier, so it is never formatted as a negative clock string;
  # a time read one day later on the day's own service keeps its hours, so a
  # negative start becomes an evening clock and a post-midnight end past 24:00; a
  # time read on its own service past 24:00 is kept, as GTFS allows.
  defp clock(secs, :previous) when secs < @seconds_per_day,
    do: clock(rem(secs + @seconds_per_day, @seconds_per_day), :own)

  defp clock(secs, :extended), do: clock_secs(secs + @seconds_per_day)
  defp clock(secs, :own), do: clock_secs(secs)

  defp clock_secs(secs) when secs >= 0, do: GtfsTime.format(secs)

  defp clock_secs(negative) do
    raise ArgumentError, "a negative service-day time cannot be formatted: #{negative} s"
  end
end
