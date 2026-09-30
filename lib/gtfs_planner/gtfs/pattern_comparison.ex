defmodule GtfsPlanner.Gtfs.PatternComparison do
  @moduledoc """
  Scoped read models for the pattern comparison page (spec 19, `R6`-`R9`).

  `compare/2` composes one two-pattern comparison: the URL route's pattern A, an
  optional pattern B resolved through `RoutePatterns.get_scoped_pattern/3`, the
  calendars and timings each side is compared on, trip usage, the stop alignment
  and the end-to-end running times. Every read filters by `organization_id` and
  `gtfs_version_id` and requires a published route (`INV-1`); the module writes
  nothing (`INV-2`) and takes its running-time values from `Alignment` (`INV-5`).

  - `R8` Defaults. The calendar is the one with the most trips of A and B
    combined, ties keeping `Calendars.list_calendars/2` order; an unknown
    `service` falls back to it. A side's timing is the requested one when it
    belongs to that pattern, otherwise the timing with the most trips on the
    calendar, then the most trips on all calendars, then name ascending. The
    all-calendars count is one trip row per trip, while the calendar count is the
    `Usage` departure count the calendar select shows.
  - `R9` Scope. A is looked up by the URL route plus its natural ID, so a
    pattern outside the route is `{:error, :not_found}`. B resolves inside the
    organization, version and a published route; a missing, foreign or
    unpublished B yields `b: nil`, `b_error: {:not_found, id}` and no B data.
    `ta`/`tb` are used only when they name one of that side's own timings.
  - `R6` End to end. A side's end-to-end time is its last timing row's arrival
    minus its first row's departure. The change is B minus A with the whole
    percentage of A. All are nil when either side has no chosen timing or B is
    shown in reverse.
  - With `b: nil`, up to three same-direction suggestions of the route are
    returned, ordered by trips on the chosen calendar then stops in common; a
    pattern with an identical stop list is excluded.

  When B is shown in reverse the alignment runs against B's reversed stop list
  and running times are not compared; `opposite?` is then false because it
  describes the patterns rather than the reversed view, which `reversed?` names.
  A stop in `stops_by_id` is a timepoint when either side's chosen timing marks
  it as one (`TimedPatternStop.timepoint == 1`). `stops` on a side is its
  ordered stop IDs; stop names, codes and coordinates live in `stops_by_id`.

  Assumed ceilings: stop visits are bounded as `Alignment` documents, and the
  suggestion scan reads this route's patterns only.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.PatternComparison.Alignment
  alias GtfsPlanner.Gtfs.PatternComparison.Usage
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @suggestion_limit 3

  @typedoc "The scoped published organization and version every read is limited to."
  @type scope :: %{organization_id: Ecto.UUID.t(), gtfs_version_id: Ecto.UUID.t()}

  @doc """
  Composes the comparison of `a` and `b` on the URL route (spec §4, `R6`-`R9`).

  A missing route or A is `{:error, :not_found}`. A `b` that does not resolve
  inside the organization, the version and a published route is reported as
  `b_error: {:not_found, id}` with `b`, `alignment` and every B read as nil.
  """
  @spec compare(scope(), map()) :: {:ok, map()} | {:error, :not_found}
  def compare(scope, params) do
    with {:ok, route} <-
           RoutePatterns.published_route(
             scope.organization_id,
             scope.gtfs_version_id,
             Map.get(params, :route_id)
           ),
         {:ok, a} <- route_pattern(scope, route.route_id, Map.get(params, :a)) do
      {b, b_route, b_error} = resolve_b(scope, Map.get(params, :b))
      candidates = if is_nil(b), do: suggestion_candidates(scope, route, a), else: []

      calendars = Usage.calendars(scope, [a.route_pattern_id | pattern_ids(b)])
      service_id = resolve_service(calendars, Map.get(params, :service), a, b)

      base_patterns = [a | List.wrap(b)]

      # Visits and timings hang off the pattern's UUID; trips and usage use the
      # natural route_pattern_id.
      stops_by_pattern =
        pattern_stops(scope, Enum.map(base_patterns ++ candidates, & &1.id))

      timings_by_pattern = pattern_timings(scope, Enum.map(base_patterns, & &1.id))
      all_counts = timing_trip_counts(scope, base_patterns)
      usage = Usage.usage(scope, base_patterns ++ candidates, service_id)

      a_side =
        side(
          a,
          route,
          stops_by_pattern,
          timings_by_pattern,
          all_counts,
          usage,
          Map.get(params, :ta)
        )

      b_side =
        b &&
          side(
            b,
            b_route,
            stops_by_pattern,
            timings_by_pattern,
            all_counts,
            usage,
            Map.get(params, :tb)
          )

      reversed? = Map.get(params, :reverse) == true

      suggestions =
        if is_nil(b_side),
          do: suggestions(candidates, a_side.stops, stops_by_pattern, usage),
          else: []

      {:ok,
       %{
         route: route,
         a: a_side,
         b: b_side,
         b_error: b_error,
         calendars: calendars,
         service_id: service_id,
         alignment: b_side && alignment(a_side, b_side, reversed?),
         stops_by_id:
           stops_by_id(scope, a_side.stops ++ side_stops(b_side), a_side.rows, b_rows(b_side)),
         suggestions: suggestions
       }}
    end
  end

  defp pattern_ids(nil), do: []
  defp pattern_ids(%RoutePattern{route_pattern_id: id}), do: [id]

  defp side_stops(nil), do: []
  defp side_stops(side), do: side.stops

  defp b_rows(nil), do: []
  defp b_rows(side), do: [side.rows]

  # A must belong to the URL route inside the scope; a pattern of another route
  # or version is :not_found, exactly as a missing one is (R9).
  defp route_pattern(scope, route_id, route_pattern_id) do
    query =
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^scope.organization_id and
            pattern.gtfs_version_id == ^scope.gtfs_version_id and
            pattern.route_id == ^route_id and
            pattern.route_pattern_id == ^route_pattern_id
      )

    case Repo.one(query) do
      %RoutePattern{} = pattern -> {:ok, pattern}
      nil -> {:error, :not_found}
    end
  end

  defp resolve_b(_scope, nil), do: {nil, nil, nil}

  defp resolve_b(scope, route_pattern_id) do
    with {:ok, %RoutePattern{} = pattern} <-
           RoutePatterns.get_scoped_pattern(
             scope.organization_id,
             scope.gtfs_version_id,
             route_pattern_id
           ),
         {:ok, route} <-
           RoutePatterns.published_route(
             scope.organization_id,
             scope.gtfs_version_id,
             pattern.route_id
           ) do
      {pattern, route, nil}
    else
      {:error, :not_found} -> {nil, nil, {:not_found, route_pattern_id}}
    end
  end

  defp suggestion_candidates(scope, route, a) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^scope.organization_id and
          pattern.gtfs_version_id == ^scope.gtfs_version_id and
          pattern.route_id == ^route.route_id and
          pattern.direction_id == ^a.direction_id and
          pattern.route_pattern_id != ^a.route_pattern_id,
      order_by: [asc: pattern.route_pattern_sort_order, asc: pattern.route_pattern_id]
    )
    |> Repo.all()
  end

  # The chosen calendar is the requested one when it exists, otherwise the
  # calendar with the most trips of A and B together; ties keep the calendar
  # list order (R8).
  defp resolve_service(calendars, requested, a, b) do
    if Enum.any?(calendars, &(&1.service_id == requested)) do
      requested
    else
      busiest_calendar(calendars, [a.route_pattern_id | pattern_ids(b)])
    end
  end

  defp busiest_calendar([], _pattern_ids), do: nil

  defp busiest_calendar(calendars, pattern_ids) do
    calendars
    |> Enum.reduce(nil, fn calendar, best ->
      if is_nil(best) or calendar_trips(calendar, pattern_ids) > calendar_trips(best, pattern_ids) do
        calendar
      else
        best
      end
    end)
    |> Map.fetch!(:service_id)
  end

  defp calendar_trips(calendar, pattern_ids) do
    Enum.sum_by(pattern_ids, &Map.get(calendar.trips, &1, 0))
  end

  defp side(
         pattern,
         route,
         stops_by_pattern,
         timings_by_pattern,
         all_counts,
         usage,
         requested_timing_id
       ) do
    summary = Map.fetch!(usage, pattern.route_pattern_id)
    timings = Map.get(timings_by_pattern, pattern.id, [])

    timing =
      select_timing(
        timings,
        requested_timing_id,
        summary.by_timing,
        Map.get(all_counts, pattern.route_pattern_id, %{})
      )

    %{
      pattern: pattern,
      route: route,
      stops: Map.get(stops_by_pattern, pattern.id, []),
      timings:
        Enum.map(timings, fn timing ->
          %{id: timing.id, name: timing.name, trips: Map.get(summary.by_timing, timing.id, 0)}
        end),
      timing_id: timing && timing.id,
      rows: timing_rows(pattern, timing),
      usage: summary
    }
  end

  defp timing_rows(_pattern, nil), do: nil

  defp timing_rows(pattern, %TimedPattern{} = timing),
    do: RoutePatterns.timing_rows(pattern.id, timing.id)

  # A requested timing is used only when it belongs to this pattern; otherwise
  # the default is the most trips on the calendar, then the most trips on all
  # calendars, then name ascending (R8, R9).
  defp select_timing([], _requested, _calendar_trips, _all_trips), do: nil

  defp select_timing(timings, requested, calendar_trips, all_trips) do
    case Enum.find(timings, &(&1.id == requested)) do
      %TimedPattern{} = timing -> timing
      nil -> Enum.min_by(timings, &timing_rank(&1, calendar_trips, all_trips))
    end
  end

  defp timing_rank(timing, calendar_trips, all_trips) do
    {-Map.get(calendar_trips, timing.id, 0), -Map.get(all_trips, timing.id, 0), timing.name,
     timing.id}
  end

  defp alignment(a_side, b_side, reversed?) do
    b_stops = if reversed?, do: Enum.reverse(b_side.stops), else: b_side.stops
    rows = Alignment.align(a_side.stops, b_stops)

    # A reversed B has no comparable times: its timing rows run the other way,
    # so segments, waits and boarding comparisons are dropped (R4).
    a_rows = a_side.rows
    b_rows = if reversed?, do: nil, else: b_side.rows
    segments = Alignment.segments(rows, a_rows, b_rows)

    differences =
      Alignment.differences(rows, %{segments: segments.segments, a_rows: a_rows, b_rows: b_rows})

    {end_a, end_b, end_change, end_percent} = end_to_end(a_side.rows, b_side.rows, reversed?)

    %{
      rows: rows,
      segments: segments.segments,
      untimed: segments.untimed,
      waits: segments.waits,
      differences: differences,
      counts: counts(rows),
      identical?: a_side.stops == b_side.stops,
      opposite?: not reversed? and Alignment.opposite?(a_side.stops, b_side.stops),
      reversed?: reversed?,
      end_a: end_a,
      end_b: end_b,
      end_change: end_change,
      end_percent: end_percent
    }
  end

  defp counts(rows) do
    Enum.reduce(rows, %{shared: 0, a_only: 0, b_only: 0, moved: 0}, fn row, counts ->
      case row do
        %{type: :same} -> %{counts | shared: counts.shared + 1}
        %{type: :a, moved_to: nil} -> %{counts | a_only: counts.a_only + 1}
        %{type: :a} -> %{counts | moved: counts.moved + 1}
        %{type: :b, moved_to: nil} -> %{counts | b_only: counts.b_only + 1}
        %{type: :b} -> counts
      end
    end)
  end

  defp end_to_end(_a_rows, _b_rows, true), do: {nil, nil, nil, nil}

  defp end_to_end(a_rows, b_rows, _reversed?) do
    end_a = end_duration(a_rows)
    end_b = end_duration(b_rows)
    change = if is_integer(end_a) and is_integer(end_b), do: end_b - end_a
    percent = if is_integer(change) and end_a != 0, do: round(change / end_a * 100)

    {end_a, end_b, change, percent}
  end

  defp end_duration(nil), do: nil
  defp end_duration([]), do: nil

  defp end_duration([first | _] = rows) do
    last = List.last(rows)

    if is_integer(first.departure_offset) and is_integer(last.arrival_offset) do
      last.arrival_offset - first.departure_offset
    end
  end

  defp suggestions(candidates, a_stops, pattern_stops, usage) do
    a_stop_ids = MapSet.new(a_stops)

    candidates
    |> Enum.map(&suggestion(&1, a_stops, a_stop_ids, pattern_stops, usage))
    |> Enum.reject(& &1.identical?)
    |> Enum.sort_by(&{-&1.trips, -&1.shared})
    |> Enum.take(@suggestion_limit)
    |> Enum.map(&Map.drop(&1, [:identical?]))
  end

  defp suggestion(pattern, a_stops, a_stop_ids, pattern_stops, usage) do
    stops = Map.get(pattern_stops, pattern.id, [])

    %{
      route_pattern_id: pattern.route_pattern_id,
      name: pattern.route_pattern_name,
      shared: MapSet.intersection(a_stop_ids, MapSet.new(stops)) |> MapSet.size(),
      trips: usage |> Map.get(pattern.route_pattern_id, %{total: 0}) |> Map.get(:total, 0),
      identical?: stops == a_stops
    }
  end

  # One query for both sides' visits keyed by the pattern's UUID, ordered by
  # pattern and position; the route_pattern_id column is that UUID.
  defp pattern_stops(_scope, []), do: %{}

  defp pattern_stops(scope, pattern_ids) do
    from(occurrence in RoutePatternStop,
      where:
        occurrence.organization_id == ^scope.organization_id and
          occurrence.gtfs_version_id == ^scope.gtfs_version_id and
          occurrence.route_pattern_id in ^Enum.uniq(pattern_ids),
      order_by: [asc: occurrence.route_pattern_id, asc: occurrence.position],
      select: {occurrence.route_pattern_id, occurrence.stop_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # One query for every side's named timings, keyed by the pattern's UUID.
  defp pattern_timings(_scope, []), do: %{}

  defp pattern_timings(scope, pattern_ids) do
    from(timing in TimedPattern,
      where:
        timing.organization_id == ^scope.organization_id and
          timing.gtfs_version_id == ^scope.gtfs_version_id and
          timing.route_pattern_id in ^Enum.uniq(pattern_ids),
      order_by: [asc: timing.route_pattern_id, asc: timing.name, asc: timing.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_pattern_id)
  end

  # One query for every side's trips per timing on all calendars, used only for
  # the default-timing tie-break; the selected calendar's counts come from Usage.
  defp timing_trip_counts(scope, patterns) do
    pattern_ids = Enum.map(patterns, & &1.route_pattern_id)

    from(trip in Trip,
      where:
        trip.organization_id == ^scope.organization_id and
          trip.gtfs_version_id == ^scope.gtfs_version_id and
          trip.route_pattern_id in ^pattern_ids,
      group_by: [trip.route_pattern_id, trip.timed_pattern_id],
      select: {trip.route_pattern_id, trip.timed_pattern_id, count(trip.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {pattern_id, timing_id, count}, counts ->
      Map.update(counts, pattern_id, %{timing_id => count}, &Map.put(&1, timing_id, count))
    end)
  end

  # The card's stop projection: names, codes and coordinates only, both sides in
  # one query. `timepoint?` follows the chosen timings, not the stop row.
  defp stops_by_id(scope, stop_ids, a_rows, b_rows) do
    stop_ids = stop_ids |> Enum.uniq() |> Enum.sort()

    if stop_ids == [] do
      %{}
    else
      timepoints = timepoint_ids([a_rows | b_rows])

      from(stop in Stop,
        where:
          stop.organization_id == ^scope.organization_id and
            stop.gtfs_version_id == ^scope.gtfs_version_id and stop.stop_id in ^stop_ids,
        select: %{
          stop_id: stop.stop_id,
          stop_name: stop.stop_name,
          stop_code: stop.stop_code,
          stop_lat: stop.stop_lat,
          stop_lon: stop.stop_lon
        }
      )
      |> Repo.all()
      |> Map.new(fn stop ->
        {stop.stop_id, Map.put(stop, :timepoint?, MapSet.member?(timepoints, stop.stop_id))}
      end)
    end
  end

  defp timepoint_ids(row_lists) do
    for rows <- row_lists,
        is_list(rows),
        row <- rows,
        row.timepoint == 1,
        into: MapSet.new(),
        do: row.stop_id
  end
end
