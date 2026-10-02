defmodule GtfsPlanner.Gtfs.ReleaseComparison.Service do
  @max_exact_occurrences 200_000

  @moduledoc """
  Evaluates the effective service of one projected artifact over an inclusive
  date window.

  `evaluate/3` takes exactly what
  `GtfsPlanner.Gtfs.ReleaseComparison.Projection.build/1` returns and the same
  inclusive window step 1 validated, and answers two separate questions per
  route, direction, ordered stop pattern and date: how many scheduled trip
  occurrences the artifact claims, and how many exact departures it can
  actually enumerate.

  ## Effective service dates

  Dates come from
  `GtfsPlanner.Gtfs.Calendars.ServiceDates.active_dates_between/4`, one call
  per service, so weekly rows, additions and removals keep the native semantics
  - including that an exception outside the query window is still validated.
  Only an `ArgumentError` from that call is caught, and it becomes a disclosed
  `:unevaluable_service`. A service named by a trip that no calendar table
  describes is `:unknown_service`; neither case yields a date, so an
  unevaluable service never becomes a service with no service.

  ## Scheduled occurrences and exact departures

  A trip with no frequency template is one scheduled occurrence per active
  date, and exactly one departure to enumerate from it.

  A trip whose templates are `exact_times = 1` expands
  `start + k * headway` while the departure stays strictly below `end`, so
  `08:00`–`09:00` every 20 minutes gives 08:00, 08:20 and 08:40 and never
  09:00. Each occurrence's time is that departure plus the occurrence's own
  offset from the trip's first stop, which is where a frequency window is
  anchored.

  A template with `exact_times = 0` - or a blank `exact_times`, which GTFS
  defines as 0 - is retained as a window and contributes to neither count,
  because the artifact does not state how many trips it stands for. A template
  whose `exact_times` is anything else, whose headway is not positive, whose
  window is not `start < end`, whose first-stop time is unreadable, or which
  overlaps another window of the same trip is disclosed and contributes no
  departures.

  A template is never counted as one trip. An unstated departure total stays
  unstated: the group reports the counts it can prove and marks
  `count_complete?` false rather than reporting a smaller total as if it were
  the whole service.

  Unreadable stop times suppress spans, never existence: a trip whose times
  cannot be read still contributes its scheduled occurrence and its departure,
  and its span is marked incomplete instead of claiming no service.

  ## Bounded work

  More than #{@max_exact_occurrences} expanded occurrences in one artifact
  refuses the whole evaluation as `{:error, :unsupported_size}`. The departure
  count of a window is arithmetic, so the total is decided before any departure
  list is allocated and an oversized artifact is refused rather than
  materialised and trimmed.

  ## Timezones and aligned timing

  A group carries the timezone it was resolved against and `nil` when the
  route's agency timezone is unknown. Seconds are service-day seconds:
  `25:10:00` stays 90,600, and no value is reduced modulo a civil day, so
  nothing here normalises through `Time` or `DateTime`. Only two groups with
  the same known timezone can be compared for aligned timing, which is why an
  unresolved timezone is carried rather than defaulted.

  ## Unresolvable native references

  The native exporter writes each table's stored primary reference into the
  foreign columns, so a genuinely produced artifact's `trips.txt` names a route
  UUID no `routes.txt` row defines. Such a trip is still evaluated: it keeps its
  occurrences and its counts, its group carries `timezone: nil`, and the
  unresolved route is disclosed as `:unknown_route`. Evaluation never repairs a
  reference it cannot prove, so a native artifact reports less alignment, not
  more.

  Outputs are sorted, so a later result digest stays stable.
  """

  alias GtfsPlanner.Gtfs.Calendars.ServiceDates

  @type pattern :: [%{required(:stop_id) => String.t(), required(:sequence) => term()}]

  @type frequency_window :: %{
          required(:trip_id) => String.t(),
          required(:start_secs) => non_neg_integer(),
          required(:end_secs) => non_neg_integer(),
          required(:headway_secs) => pos_integer(),
          required(:exact_times) => 0,
          required(:source) => map() | nil
        }

  @type group :: %{
          required(:route_id) => String.t(),
          required(:direction_id) => 0 | 1 | nil,
          required(:pattern) => pattern(),
          required(:date) => Date.t(),
          required(:timezone) => String.t() | nil,
          required(:scheduled_count) => non_neg_integer(),
          required(:exact_count) => non_neg_integer(),
          required(:first_secs) => non_neg_integer() | nil,
          required(:last_secs) => non_neg_integer() | nil,
          required(:frequency_windows) => [frequency_window()],
          required(:count_complete?) => boolean(),
          required(:span_complete?) => boolean(),
          required(:source_refs) => [map()]
        }

  @type unknown :: %{
          required(:entity) => :service | :frequency | :route,
          required(:entity_id) => String.t() | nil,
          required(:reason) => atom(),
          required(:detail) => String.t(),
          required(:source) => map() | nil
        }

  @type evaluated_trip :: %{
          required(:trip_id) => String.t(),
          required(:route_id) => String.t(),
          required(:direction_id) => 0 | 1 | nil,
          required(:service_dates) => [Date.t()],
          required(:pattern) => pattern(),
          required(:time_vector) => [{term(), term()}],
          required(:frequencies) => [map()]
        }

  @doc """
  Evaluates one projected artifact over an inclusive window.

  Returns `{:error, :unsupported_size}` when the artifact would expand to more
  than #{@max_exact_occurrences} exact occurrences. Raises `ArgumentError` for a
  window that ends before it starts, which is a caller programming error: step 1
  validates the window before any artifact is chosen.
  """
  @spec evaluate(map(), Date.t(), Date.t()) :: {:ok, map()} | {:error, :unsupported_size}
  def evaluate(projection, from, to)
      when is_map(projection) and is_struct(from, Date) and is_struct(to, Date) do
    if Date.compare(from, to) == :gt do
      raise ArgumentError,
            "query window ends before it starts: " <>
              "#{Date.to_iso8601(to)} < #{Date.to_iso8601(from)}"
    end

    context = context(projection)
    services = active_services(context, from, to)

    case collect_trips(context, services) do
      {:error, :unsupported_size} ->
        {:error, :unsupported_size}

      {:ok, evaluated, contributions, unknowns} ->
        groups = build_groups(contributions)

        {:ok,
         %{
           from: from,
           to: to,
           groups: groups,
           evaluated_trips: Enum.sort_by(Map.values(evaluated), & &1.trip_id),
           unknowns: sort_unknowns(unknowns),
           complete?:
             unknowns == [] and groups != [] and
               Enum.all?(groups, &(&1.count_complete? and &1.span_complete?))
         }}
    end
  end

  # -- context ----------------------------------------------------------------

  defp context(projection) do
    %{
      routes: Map.get(projection, :routes) || %{},
      trips: Map.get(projection, :trips) || %{},
      calendars: Map.get(projection, :calendars) || %{},
      exceptions: Map.get(projection, :exceptions) || %{},
      occurrences: Map.get(projection, :stop_occurrences) || %{},
      frequencies: Map.get(projection, :frequencies) || []
    }
  end

  # -- effective service dates ------------------------------------------------

  # One call per service, so weekly rows, additions and removals keep the native
  # semantics and an exception outside the window is still validated. Only an
  # `ArgumentError` becomes an unknown.
  defp active_services(context, from, to) do
    Map.new(context.calendars, fn {service_id, calendar} ->
      exceptions = Map.get(context.exceptions, service_id, [])

      dates =
        try do
          {:ok, ServiceDates.active_dates_between(calendar, exceptions, from, to)}
        rescue
          ArgumentError -> {:error, unevaluable_service(service_id, calendar)}
        end

      {service_id, dates}
    end)
  end

  # A service no calendar table describes is not a service with no dates.
  defp service_dates(%{service_id: service_id}, services) do
    case Map.fetch(services, service_id) do
      {:ok, {:ok, dates}} -> {:ok, dates}
      {:ok, {:error, unknown}} -> {:error, unknown}
      :error -> {:error, undescribed_service(service_id)}
    end
  end

  # -- per trip ---------------------------------------------------------------

  defp collect_trips(context, services) do
    context.trips
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, blank_acc()}, fn trip_id, {:ok, acc} ->
      {result, occurrences} = evaluate_trip(context, trip_id, services)

      if acc.total + occurrences > @max_exact_occurrences do
        {:halt, {:error, :unsupported_size}}
      else
        next = %{
          evaluated: Map.put(acc.evaluated, trip_id, result.trip),
          contributions: acc.contributions ++ result.contributions,
          unknowns: acc.unknowns ++ result.unknowns,
          total: acc.total + occurrences
        }

        {:cont, {:ok, next}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc.evaluated, acc.contributions, acc.unknowns}
      {:error, reason} -> {:error, reason}
    end
  end

  defp blank_acc, do: %{evaluated: %{}, contributions: [], unknowns: [], total: 0}

  defp evaluate_trip(context, trip_id, services) do
    trip = context.trips[trip_id]
    occurrences = Map.get(context.occurrences, trip_id, [])
    frequencies = trip_frequencies(context, trip_id)
    {timezone, route_unknowns} = route_context(context, trip)

    case service_dates(trip, services) do
      {:ok, dates} ->
        evaluate_active_trip(trip, occurrences, frequencies, dates, timezone, route_unknowns)

      # An unevaluable service contributes no date and no group, so nothing can
      # read it as a service that lost every trip.
      {:error, unknown} ->
        {%{
           trip: evaluated_trip(trip, occurrences, frequencies, []),
           contributions: [],
           unknowns: route_unknowns ++ [unknown]
         }, 0}
    end
  end

  defp evaluate_active_trip(trip, occurrences, frequencies, dates, timezone, route_unknowns) do
    plan = departure_plan(occurrences, frequencies)

    contributions =
      Enum.map(dates, &contribution(trip, occurrences, frequencies, &1, timezone, plan))

    result = %{
      trip: evaluated_trip(trip, occurrences, frequencies, dates),
      contributions: contributions,
      unknowns: route_unknowns ++ plan.unknowns
    }

    {result, plan.exact_occurrences * length(dates)}
  end

  defp trip_frequencies(context, trip_id) do
    Enum.filter(context.frequencies, &(&1.trip_id == trip_id))
  end

  # A route's timezone comes from its agency, so an unresolvable agency leaves
  # the group without one instead of with a guess.
  defp route_context(context, trip) do
    case Map.fetch(context.routes, trip.route_id) do
      {:ok, %{timezone: timezone, timezone_known?: true}} -> {timezone, []}
      {:ok, _route} -> {nil, []}
      :error -> {nil, [unresolved_route(trip.route_id)]}
    end
  end

  defp evaluated_trip(trip, occurrences, frequencies, dates) do
    %{
      trip_id: trip.trip_id,
      route_id: trip.route_id,
      direction_id: trip.direction_id,
      service_dates: dates,
      pattern: pattern_of(occurrences),
      time_vector: Enum.map(occurrences, &{&1.arrival_secs, &1.departure_secs}),
      frequencies: Enum.map(frequencies, &frequency_entry/1)
    }
  end

  defp frequency_entry(entry) do
    Map.take(entry, [:trip_id, :start_secs, :end_secs, :headway_secs, :exact_times, :source])
  end

  defp pattern_of(occurrences) do
    Enum.map(occurrences, &%{stop_id: &1.stop_id, sequence: &1.sequence})
  end

  # -- departures -------------------------------------------------------------

  # Occurrence times are service-day seconds. A departure falls back to its
  # arrival, matching the native departure query, and an unreadable value stays
  # `nil` rather than becoming midnight or a zero.
  defp occurrence_secs(%{departure_secs: secs}) when is_integer(secs), do: secs
  defp occurrence_secs(%{arrival_secs: secs}) when is_integer(secs), do: secs
  defp occurrence_secs(_occurrence), do: nil

  defp departure_plan(occurrences, frequencies) do
    offsets = Enum.map(occurrences, &occurrence_secs/1)

    case frequencies do
      [] -> scheduled_plan(occurrences, offsets)
      _templates -> frequency_plan(occurrences, offsets, frequencies)
    end
  end

  defp plan(fields) do
    Map.merge(%{frequency_windows: [], unknowns: [], source_refs: []}, fields)
  end

  # One scheduled occurrence per active date, and one departure to enumerate
  # from it. An unreadable time keeps the occurrence and suppresses only the span.
  defp scheduled_plan(occurrences, offsets) do
    known = Enum.reject(offsets, &is_nil/1)

    plan(%{
      scheduled_count: 1,
      exact_count: 1,
      exact_occurrences: 1,
      first_secs: minimum(known),
      last_secs: maximum(known),
      count_complete?: true,
      span_complete?: occurrences != [] and length(known) == length(offsets)
    })
  end

  defp frequency_plan(occurrences, offsets, frequencies) do
    {usable, rejected} = usable_windows(frequencies)

    # A window is anchored at the trip's first stop, so an unreadable first time
    # makes every window unusable rather than merely unshiftable.
    case offsets do
      [first | _rest] when is_integer(first) ->
        {accepted, overlap_unknowns} = accepted_windows(usable, rejected)
        summarize(occurrences, Enum.map(offsets, &(&1 - first)), accepted, overlap_unknowns)

      _unanchored ->
        unanchored_windows(usable, rejected)
    end
  end

  defp unanchored_windows(usable, rejected) do
    unknown =
      frequency_unknown(
        nil,
        :unusable_frequency_anchor,
        "the trip's first stop has no readable time, so no window can be anchored"
      )

    anchored =
      Enum.map(usable, fn window ->
        window_unknown(
          window,
          :unusable_frequency_anchor,
          "the trip's first stop has no readable time, so no departure can be placed"
        )
      end)

    summarize([], [], [], rejected ++ anchored ++ [unknown])
  end

  # A window is usable only when it states an exclusive end after its start, a
  # positive integer headway and a supported `exact_times`. Everything else is
  # disclosed with its own reason rather than dropped.
  defp usable_windows(frequencies) do
    Enum.reduce(frequencies, {[], []}, fn entry, {usable, rejected} ->
      case window_reason(entry) do
        nil -> {usable ++ [entry], rejected}
        reason -> {usable, rejected ++ [window_unknown(entry, reason)]}
      end
    end)
  end

  defp window_reason(%{exact_times: exact_times}) when exact_times not in [0, 1],
    do: :unsupported_exact_times

  defp window_reason(%{start_secs: start, end_secs: finish})
       when not is_integer(start) or not is_integer(finish),
       do: :unreadable_frequency_window

  defp window_reason(%{start_secs: start, end_secs: finish}) when finish <= start,
    do: :until_not_after_from

  defp window_reason(%{headway_secs: headway}) when not is_integer(headway) or headway <= 0,
    do: :invalid_headway

  defp window_reason(_entry), do: nil

  # Windows of one trip may touch but not overlap. Judged in start order like the
  # native frequency validator, the later window is the offending one.
  defp accepted_windows(usable, unknowns) do
    {_latest_end, accepted, overlap_unknowns} =
      usable
      |> Enum.sort_by(&{&1.start_secs, &1.end_secs})
      |> Enum.reduce({nil, [], unknowns}, fn window, {latest_end, accepted, unknowns} ->
        if is_integer(latest_end) and window.start_secs < latest_end do
          {latest_end, accepted,
           unknowns ++ [window_unknown(window, :overlapping_frequency_windows)]}
        else
          {max(latest_end || window.end_secs, window.end_secs), accepted ++ [window], unknowns}
        end
      end)

    {accepted, overlap_unknowns}
  end

  defp summarize(occurrences, offsets, accepted, unknowns) do
    exact = Enum.map(Enum.filter(accepted, &(&1.exact_times == 1)), &expand/1)
    retained = Enum.map(Enum.filter(accepted, &(&1.exact_times == 0)), &retained_window/1)
    departures = exact |> Enum.map(& &1.count) |> Enum.sum()
    {first_secs, last_secs} = exact_span(exact, offsets)

    plan(%{
      scheduled_count: departures,
      exact_count: departures,
      exact_occurrences: departures,
      frequency_windows: retained,
      first_secs: first_secs,
      last_secs: last_secs,
      # A retained window or a rejected window states a departure total this step
      # cannot prove, so the group's totals are the counts it can count rather
      # than the whole service.
      count_complete?: retained == [] and exact != [] and unknowns == [],
      span_complete?:
        retained == [] and exact != [] and occurrences != [] and
          length(Enum.reject(offsets, &is_nil/1)) == length(offsets),
      unknowns: unknowns,
      source_refs: source_refs(occurrences)
    })
  end

  # A frequency window is anchored at the trip's first stop, so `offsets` are
  # measured from that anchor and the first stop's own shift is zero. A later
  # occurrence's time is its departure plus that shift; only the extremes are
  # needed for the span, so the shift costs arithmetic rather than one shifted
  # time per departure.
  defp exact_span([], _offsets), do: {nil, nil}

  defp exact_span(exact, offsets) do
    known = Enum.reject(offsets, &is_nil/1)

    if known == [] do
      {nil, nil}
    else
      first = exact |> Enum.map(& &1.first_departure) |> Enum.min()
      last = exact |> Enum.map(& &1.last_departure) |> Enum.max()

      {first + Enum.min(known), last + Enum.max(known)}
    end
  end

  # The number of departures is arithmetic, so an artifact-size bound is decided
  # before any departure list is allocated. `first_secs`/`last_secs` carry the
  # occurrence-offset shift from the trip's first stop once, applied to the
  # extremes only.
  defp expand(%{start_secs: start, end_secs: finish, headway_secs: headway} = window) do
    count = div(finish - start - 1, headway) + 1

    Map.merge(window, %{
      count: count,
      first_departure: start,
      last_departure: start + (count - 1) * headway
    })
  end

  defp retained_window(window) do
    %{
      trip_id: window.trip_id,
      start_secs: window.start_secs,
      end_secs: window.end_secs,
      headway_secs: window.headway_secs,
      exact_times: 0,
      source: Map.get(window, :source)
    }
  end

  # -- contributions ----------------------------------------------------------

  defp contribution(trip, occurrences, frequencies, date, timezone, plan) do
    %{
      route_id: trip.route_id,
      direction_id: trip.direction_id,
      pattern: pattern_of(occurrences),
      date: date,
      timezone: timezone,
      scheduled_count: plan.scheduled_count,
      exact_count: plan.exact_count,
      first_secs: plan.first_secs,
      last_secs: plan.last_secs,
      frequency_windows: plan.frequency_windows,
      count_complete?: plan.count_complete?,
      span_complete?: plan.span_complete?,
      source_refs: plan.source_refs ++ trip_source_refs(trip, frequencies)
    }
  end

  defp source_refs(occurrences), do: occurrences |> Enum.map(& &1.source) |> reject_nil()

  defp trip_source_refs(trip, frequencies) do
    (Enum.map(frequencies, &Map.get(&1, :source)) ++ [Map.get(trip, :source)])
    |> reject_nil()
    |> sort_refs()
  end

  defp reject_nil(refs), do: Enum.reject(refs, &is_nil/1)

  defp sort_refs(refs), do: Enum.uniq(refs) |> Enum.sort_by(&{&1.file, &1.row})

  # -- groups -----------------------------------------------------------------

  defp build_groups(contributions) do
    contributions
    |> Enum.group_by(
      &{&1.route_id, &1.direction_id, pattern_key(&1.pattern), &1.date, &1.timezone}
    )
    |> Enum.map(fn {{route_id, direction_id, _pattern, date, timezone}, rows} ->
      combine(route_id, direction_id, hd(rows).pattern, date, timezone, rows)
    end)
    |> Enum.sort_by(&group_order/1)
  end

  defp combine(route_id, direction_id, pattern, date, timezone, rows) do
    %{
      route_id: route_id,
      direction_id: direction_id,
      pattern: pattern,
      date: date,
      timezone: timezone,
      scheduled_count: Enum.sum(Enum.map(rows, & &1.scheduled_count)),
      exact_count: Enum.sum(Enum.map(rows, & &1.exact_count)),
      first_secs: rows |> Enum.map(& &1.first_secs) |> reject_nil() |> minimum(),
      last_secs: rows |> Enum.map(& &1.last_secs) |> reject_nil() |> maximum(),
      frequency_windows: windows_of(rows),
      count_complete?: Enum.all?(rows, & &1.count_complete?),
      span_complete?: Enum.all?(rows, & &1.span_complete?),
      source_refs: rows |> Enum.flat_map(& &1.source_refs) |> sort_refs()
    }
  end

  defp windows_of(rows) do
    rows
    |> Enum.flat_map(& &1.frequency_windows)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.trip_id, &1.start_secs, &1.end_secs, &1.headway_secs})
  end

  defp group_order(group) do
    {group.route_id, direction_order(group.direction_id), pattern_key(group.pattern),
     Date.to_iso8601(group.date), group.timezone || ""}
  end

  defp direction_order(nil), do: -1
  defp direction_order(direction_id), do: direction_id

  defp pattern_key(pattern) do
    Enum.map_join(pattern, ";", &"#{&1.sequence}:#{&1.stop_id}")
  end

  defp minimum([]), do: nil
  defp minimum(values), do: Enum.min(values)

  defp maximum([]), do: nil
  defp maximum(values), do: Enum.max(values)

  # -- unknowns ---------------------------------------------------------------

  defp unevaluable_service(service_id, calendar) do
    %{
      entity: :service,
      entity_id: service_id,
      reason: :unevaluable_service,
      detail: "the service dates could not be evaluated from the selected bytes",
      source: Map.get(calendar, :source)
    }
  end

  defp undescribed_service(service_id) do
    %{
      entity: :service,
      entity_id: service_id,
      reason: :unknown_service,
      detail: "no calendar.txt or calendar_dates.txt row describes this service",
      source: nil
    }
  end

  defp unresolved_route(route_id) do
    %{
      entity: :route,
      entity_id: route_id,
      reason: :unknown_route,
      detail: "routes.txt does not define the route this trip names",
      source: nil
    }
  end

  defp window_unknown(entry, reason, detail) do
    frequency_unknown(entry.trip_id, reason, detail, Map.get(entry, :source))
  end

  defp window_unknown(entry, reason),
    do: window_unknown(entry, reason, "the window states no usable departure list")

  defp frequency_unknown(trip_id, reason, detail, source \\ nil) do
    %{entity: :frequency, entity_id: trip_id, reason: reason, detail: detail, source: source}
  end

  defp sort_unknowns(unknowns) do
    Enum.sort_by(unknowns, fn entry ->
      {to_string(entry.entity), entry.entity_id || "", to_string(entry.reason), entry.detail}
    end)
  end
end
