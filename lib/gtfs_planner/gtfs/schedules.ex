defmodule GtfsPlanner.Gtfs.Schedules do
  @moduledoc """
  Scoped reads and trip creation for one route's Schedules tab.

  `load_route_schedule/4` loads everything one Schedules page renders from one
  published organization/version/route scope. It runs in one read transaction
  that holds the version row `FOR SHARE` through `Calendars.list_calendars/3`, so
  a cooperating calendar write cannot interleave with the loaded aggregate.

  The read canonicalizes the requested calendar, direction, pattern and stops
  filters, builds every section from the stored stop times through
  `Schedules.Timetable.build/5` (never from a timing), and derives the planning
  summary with `Schedules.Summary`. Stored clock strings are parsed in Elixir with
  `GtfsTime`; no SQL string `MIN`/`MAX` orders times. The query count is constant
  and independent of the trip count.

  `create_trips/3` creates one departure or a bounded series from a pattern timing
  in one transaction. It reuses spec 01's locks and transaction boundary and spec
  02's calendar reference lock, takes the locks in the rule-table order (version
  `FOR SHARE` -> route `FOR UPDATE` -> pattern `FOR UPDATE`), loads the timing rows
  after the route lock, materializes the stored stop times through spec 01's
  `Materializer`, and writes one audit log per created trip.

  Every result is scoped: a foreign, invalid or unpublished organization,
  version or route rolls back to `{:error, :not_found}`.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Gtfs.Schedules.Timetable
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # A series is bounded so one drawer submission cannot create an unbounded
  # number of trips and audit rows; stop times are inserted in fixed chunks.
  @max_series_trips 200
  @stop_time_chunk_size 1_000
  # Spec 01's bounded retry for serialization or lock contention.
  @write_attempts 3

  @type filters :: %{
          service_id: String.t() | nil,
          direction_id: 0 | 1 | nil,
          pattern: :all | Ecto.UUID.t(),
          stops: :timepoints | :all
        }

  @type calendar_entry :: %{
          service_id: String.t(),
          name: String.t() | nil,
          kind: Calendars.kind(),
          route_trip_count: non_neg_integer()
        }

  @type pattern_entry :: %{
          id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          name: String.t(),
          direction_id: 0 | 1,
          typicality: integer(),
          timings: [map()]
        }

  @type summary :: %{
          vehicles: %{count: non_neg_integer(), at_secs: non_neg_integer() | nil},
          trips_per_hour: [Summary.hour_count()],
          incomplete_trip_count: non_neg_integer()
        }

  @type schedule :: %{
          route: Route.t(),
          filters: filters(),
          calendars: [calendar_entry()],
          patterns: [pattern_entry()],
          sections: [Timetable.section()],
          unlinked_trip_count: non_neg_integer(),
          summary: summary(),
          block_suggestions: [String.t()],
          direction_labels: %{0 => String.t(), 1 => String.t()}
        }

  @type error :: :not_found

  @type create_attrs :: %{
          pattern_id: Ecto.UUID.t(),
          timed_pattern_id: Ecto.UUID.t(),
          service_id: String.t(),
          start_time: String.t(),
          repeat: nil | %{every_minutes: pos_integer(), until: String.t()}
        }

  @type create_error ::
          :invalid_input
          | :invalid_time
          | :invalid_interval
          | :until_before_start
          | :too_many_trips
          | :not_found
          | :calendar_not_found
          | :trip_id_conflict
          | :negative_time
          | :invalid_chronology
          | :busy

  @doc """
  Expands a series of departure seconds from `start_secs`.

  Without a repeat the series is the single departure `[start_secs]`. With
  `every_minutes` it is `start + k * every` for every `k >= 0` whose departure is
  at or before `until_secs`, so a departure after midnight is above 24 hours and
  `until_secs` is included only when a departure lands exactly on it.

  A non-positive or missing interval and a missing end are
  `{:error, :invalid_interval}`, an end before the start is
  `{:error, :until_before_start}`, and more than #{@max_series_trips} departures is
  `{:error, :too_many_trips}`.
  """
  @spec series_starts(non_neg_integer(), pos_integer() | nil, non_neg_integer() | nil) ::
          {:ok, [non_neg_integer()]}
          | {:error, :invalid_interval | :until_before_start | :too_many_trips}
  def series_starts(start_secs, nil, _until_secs)
      when is_integer(start_secs) and start_secs >= 0,
      do: {:ok, [start_secs]}

  def series_starts(start_secs, every_minutes, until_secs)
      when is_integer(start_secs) and start_secs >= 0 do
    cond do
      not (is_integer(every_minutes) and every_minutes > 0) -> {:error, :invalid_interval}
      not (is_integer(until_secs) and until_secs >= 0) -> {:error, :invalid_interval}
      until_secs < start_secs -> {:error, :until_before_start}
      true -> series(start_secs, every_minutes * 60, until_secs)
    end
  end

  def series_starts(_start_secs, _every_minutes, _until_secs), do: {:error, :invalid_interval}

  @doc """
  Creates one departure or a bounded series on one of the route's patterns.

  `attrs` carries `:pattern_id` (a route pattern UUID), `:timed_pattern_id` (a
  timing of that pattern), `:service_id`, `:start_time` and `:repeat`
  (`nil` or `%{every_minutes: pos_integer(), until: clock}`). The departures are
  exactly `series_starts/3`, and the request is refused before any lock is taken
  when that expansion fails.

  Each created trip takes the pattern's direction and natural ID, the timing, the
  `linked` derivation state and `timing.headsign || pattern.headsign`, with a
  fresh `route-direction-service-HHMM` trip ID and a new stop time per pattern
  occurrence materialized from the timing's offsets. One audit log per trip is
  written in the same transaction with one shared `operation_id`, so an audit
  failure rolls back every row this call created. A unique-index violation on
  `trip_id` rolls back `:trip_id_conflict` rather than renaming the ID.
  """
  @spec create_trips(String.t(), create_attrs(), AuditContext.t()) ::
          {:ok, %{trips: [Trip.t()]}} | {:error, Ecto.Changeset.t() | create_error()}
  def create_trips(route_id, attrs, %AuditContext{} = audit_context) when is_map(attrs) do
    with {:ok, starts} <- departure_seconds(attrs) do
      run_write(route_id, starts, attrs, audit_context, @write_attempts)
    end
  end

  def create_trips(_route_id, _attrs, _audit_context), do: {:error, :invalid_input}

  @doc """
  Loads one route's Schedules read for `organization_id`/`version_id`.

  `filters` accepts `:service_id`, `:direction_id` (or `:direction`), `:pattern`
  (a route pattern UUID or `:all`) and `:stops` (`:timepoints` or `:all`). Each is
  canonicalized against the loaded scope: an unknown calendar falls back to the
  one with the most trips on this route, an unknown direction to one with trips,
  an unknown pattern to `:all` and any stops value other than `:all` to
  `:timepoints`. String keys are accepted so URL params can be passed through.

  Returns `{:ok, schedule()}` or `{:error, :not_found}` for a foreign, invalid or
  unpublished scope.
  """
  @spec load_route_schedule(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), filters()) ::
          {:ok, schedule()} | {:error, error()}
  def load_route_schedule(organization_id, version_id, route_id, filters) do
    case Repo.transaction(fn ->
           read_route_schedule(organization_id, version_id, route_id, filters)
         end) do
      {:ok, schedule} -> {:ok, schedule}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_route_schedule(organization_id, version_id, route_id, filters) do
    route = published_route!(organization_id, version_id, route_id)

    calendars =
      organization_id
      |> load_calendars!(version_id)
      |> attach_route_trip_counts(route_trip_counts(organization_id, version_id, route_id))

    calendar = resolve_calendar(calendars, filter_value(filters, :service_id))

    trips = load_trips(organization_id, version_id, route_id, calendar)

    direction =
      resolve_direction(
        filter_value(filters, :direction_id) || filter_value(filters, :direction),
        trips
      )

    patterns = load_patterns(organization_id, version_id, route_id)
    direction_patterns = Enum.filter(patterns, &(&1.direction_id == direction))
    pattern = resolve_pattern(filter_value(filters, :pattern), direction_patterns)
    stops = resolve_stops(filter_value(filters, :stops))

    occurrences_by_pattern = load_occurrences(organization_id, version_id, patterns)
    timings_by_pattern = load_timings(organization_id, version_id, patterns)

    stops_by_id =
      load_stops(organization_id, version_id, occurrence_stop_ids(occurrences_by_pattern))

    stop_times_by_trip = load_stop_times(organization_id, version_id, trips)
    frequencies_by_trip = load_frequencies(organization_id, version_id, trips)

    trip_data =
      Enum.map(trips, fn trip ->
        %{
          trip: trip,
          bounds: trip_bounds(Map.get(stop_times_by_trip, trip.trip_id, [])),
          frequencies: Map.get(frequencies_by_trip, trip.trip_id, [])
        }
      end)

    section_patterns = Enum.filter(direction_patterns, &(pattern == :all or &1.id == pattern))

    sections =
      build_sections(section_patterns, %{
        trips: trips,
        direction: direction,
        occurrences_by_pattern: occurrences_by_pattern,
        timings_by_pattern: timings_by_pattern,
        stops_by_id: stops_by_id,
        stop_times_by_trip: stop_times_by_trip,
        frequencies_by_trip: frequencies_by_trip
      })

    %{
      route: route,
      filters: %{
        service_id: calendar && calendar.service_id,
        direction_id: direction,
        pattern: pattern,
        stops: stops
      },
      calendars: calendars,
      patterns: pattern_entries(patterns, timings_by_pattern),
      sections: sections,
      unlinked_trip_count: unlinked_trip_count(trips, patterns),
      summary: summary(trip_data, direction),
      block_suggestions: block_suggestions(trips, direction),
      direction_labels: direction_labels(trips)
    }
  end

  # -- Scoped loads -----------------------------------------------------------

  defp published_route!(organization_id, version_id, route_id) do
    query =
      from(route in Route,
        join: version in GtfsVersion,
        on:
          version.id == route.gtfs_version_id and
            version.organization_id == route.organization_id,
        where:
          route.organization_id == ^organization_id and route.gtfs_version_id == ^version_id and
            route.route_id == ^route_id and version.publication_status == "published"
      )

    case Repo.one(query) do
      %Route{} = route -> route
      nil -> Repo.rollback(:not_found)
    end
  end

  # One transaction and one version-row share lock cover the whole aggregate.
  defp load_calendars!(organization_id, version_id) do
    case Calendars.list_calendars(organization_id, version_id) do
      {:ok, summaries} -> summaries
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Spec 02's per-identity `trip_count` counts every route in the version; the
  # picker's own count is this route's grouped trip count.
  defp route_trip_counts(organization_id, version_id, route_id) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id == ^route_id and not is_nil(t.service_id),
      group_by: t.service_id,
      select: {t.service_id, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp attach_route_trip_counts(summaries, counts) do
    Enum.map(summaries, fn summary ->
      %{
        service_id: summary.service_id,
        name: summary.name,
        kind: summary.kind,
        route_trip_count: Map.get(counts, summary.service_id, 0)
      }
    end)
  end

  defp load_trips(_organization_id, _version_id, _route_id, nil), do: []

  defp load_trips(organization_id, version_id, route_id, %{service_id: service_id}) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id == ^route_id and t.service_id == ^service_id,
      order_by: [asc: t.direction_id, asc: t.trip_id, asc: t.id]
    )
    |> Repo.all()
  end

  defp load_patterns(organization_id, version_id, route_id) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^organization_id and p.gtfs_version_id == ^version_id and
          p.route_id == ^route_id
    )
    |> Repo.all()
    |> Enum.sort_by(fn pattern ->
      {is_nil(pattern.route_pattern_sort_order), pattern.route_pattern_sort_order || 0,
       pattern.route_pattern_name || "", pattern.route_pattern_id}
    end)
  end

  defp load_occurrences(_organization_id, _version_id, []), do: %{}

  defp load_occurrences(organization_id, version_id, patterns) do
    pattern_ids = Enum.map(patterns, & &1.id)

    from(o in RoutePatternStop,
      where:
        o.organization_id == ^organization_id and o.gtfs_version_id == ^version_id and
          o.route_pattern_id in ^pattern_ids,
      order_by: [asc: o.route_pattern_id, asc: o.position, asc: o.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_pattern_id)
  end

  defp load_timings(_organization_id, _version_id, []), do: %{}

  defp load_timings(organization_id, version_id, patterns) do
    pattern_ids = Enum.map(patterns, & &1.id)

    timings =
      from(t in TimedPattern,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_pattern_id in ^pattern_ids,
        order_by: [asc: t.route_pattern_id, asc: t.name, asc: t.id]
      )
      |> Repo.all()

    rows_by_timing = timing_rows(organization_id, version_id, Enum.map(timings, & &1.id))

    timings
    |> Enum.group_by(& &1.route_pattern_id)
    |> Map.new(fn {pattern_id, pattern_timings} ->
      {pattern_id,
       Enum.map(pattern_timings, fn timing ->
         %{
           id: timing.id,
           name: timing.name,
           headsign: timing.headsign,
           rows: Map.get(rows_by_timing, timing.id, [])
         }
       end)}
    end)
  end

  defp timing_rows(_organization_id, _version_id, []), do: %{}

  defp timing_rows(organization_id, version_id, timing_ids) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where:
        occurrence.organization_id == ^organization_id and
          occurrence.gtfs_version_id == ^version_id and row.timed_pattern_id in ^timing_ids,
      order_by: [asc: row.timed_pattern_id, asc: occurrence.position, asc: occurrence.id],
      select: %{
        timed_pattern_id: row.timed_pattern_id,
        position: occurrence.position,
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.timed_pattern_id)
  end

  defp load_stops(_organization_id, _version_id, []), do: %{}

  defp load_stops(organization_id, version_id, stop_ids) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
          s.stop_id in ^stop_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.stop_id, &1})
  end

  defp occurrence_stop_ids(occurrences_by_pattern) do
    occurrences_by_pattern
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.stop_id)
    |> Enum.uniq()
  end

  defp load_stop_times(_organization_id, _version_id, []), do: %{}

  defp load_stop_times(organization_id, version_id, trips) do
    trip_ids = Enum.map(trips, & &1.trip_id)

    from(st in StopTime,
      where:
        st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
          st.trip_id in ^trip_ids,
      order_by: [asc: st.trip_id, asc: st.stop_sequence, asc: st.id],
      select: %{
        trip_id: st.trip_id,
        stop_sequence: st.stop_sequence,
        id: st.id,
        stop_id: st.stop_id,
        arrival_time: st.arrival_time,
        departure_time: st.departure_time
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.trip_id)
  end

  defp load_frequencies(_organization_id, _version_id, []), do: %{}

  defp load_frequencies(organization_id, version_id, trips) do
    trip_ids = Enum.map(trips, & &1.trip_id)

    from(f in Frequency,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^version_id and
          f.trip_id in ^trip_ids,
      order_by: [asc: f.trip_id, asc: f.start_time]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.trip_id)
  end

  # -- Canonical filters ------------------------------------------------------

  # The calendar list is already ordered by name then service ID, so the first
  # calendar with the most trips on this route carries the specified tie-break;
  # a route with no trips resolves to the first calendar in list order.
  defp resolve_calendar(calendars, requested) do
    case Enum.find(calendars, &(&1.service_id == requested)) do
      %{service_id: _service_id} = calendar ->
        calendar

      nil ->
        case calendars do
          [] ->
            nil

          calendars ->
            most = calendars |> Enum.map(& &1.route_trip_count) |> Enum.max()
            Enum.find(calendars, &(&1.route_trip_count == most))
        end
    end
  end

  defp resolve_direction(requested, trips) do
    case normalize_direction(requested) do
      direction when direction in [0, 1] ->
        direction

      nil ->
        counts = Enum.frequencies_by(trips, & &1.direction_id)

        cond do
          Map.get(counts, 0, 0) > 0 -> 0
          Map.get(counts, 1, 0) > 0 -> 1
          true -> 0
        end
    end
  end

  defp normalize_direction(0), do: 0
  defp normalize_direction(1), do: 1
  defp normalize_direction("0"), do: 0
  defp normalize_direction("1"), do: 1
  defp normalize_direction(_requested), do: nil

  # The requested pattern may be the pattern's UUID or its natural `route_pattern_id`;
  # either is canonicalized to the UUID the payload exposes, and anything else falls
  # back to `:all`. A pattern of the other direction never resolves.
  defp resolve_pattern(requested, direction_patterns) when is_binary(requested) do
    case Enum.find(direction_patterns, fn pattern ->
           pattern.id == requested or pattern.route_pattern_id == requested
         end) do
      %RoutePattern{id: id} -> id
      nil -> :all
    end
  end

  defp resolve_pattern(_requested, _direction_patterns), do: :all

  defp resolve_stops(value) when value in [:all, "all"], do: :all
  defp resolve_stops(_value), do: :timepoints

  defp filter_value(filters, key) when is_map(filters) do
    case Map.fetch(filters, key) do
      {:ok, value} -> value
      :error -> Map.get(filters, Atom.to_string(key))
    end
  end

  defp filter_value(_filters, _key), do: nil

  # -- Sections ---------------------------------------------------------------

  defp build_sections(section_patterns, data) do
    Enum.flat_map(section_patterns, &section(&1, data))
  end

  defp section(pattern, data) do
    trips =
      Enum.filter(data.trips, fn trip ->
        trip.direction_id == data.direction and
          trip.route_pattern_id == pattern.route_pattern_id
      end)

    case trips do
      [] ->
        []

      trips ->
        occurrences = Map.get(data.occurrences_by_pattern, pattern.id, [])
        timings = Map.get(data.timings_by_pattern, pattern.id, [])
        timetable_trips = Enum.map(trips, &timetable_trip(&1, data))

        [Timetable.build(pattern, occurrences, data.stops_by_id, timings, timetable_trips)]
    end
  end

  defp timetable_trip(trip, data) do
    Map.merge(Map.from_struct(trip), %{
      stop_times: Map.get(data.stop_times_by_trip, trip.trip_id, []),
      frequencies: Map.get(data.frequencies_by_trip, trip.trip_id, [])
    })
  end

  defp pattern_entries(patterns, timings_by_pattern) do
    Enum.map(patterns, fn pattern ->
      %{
        id: pattern.id,
        route_pattern_id: pattern.route_pattern_id,
        name: pattern.route_pattern_name || pattern.route_pattern_id,
        direction_id: pattern.direction_id,
        typicality: pattern.route_pattern_typicality,
        timings: Map.get(timings_by_pattern, pattern.id, [])
      }
    end)
  end

  # A trip belongs to a section of its own direction only when a route pattern of
  # this route carries the same natural ID and the same direction. A nil or
  # dangling pattern, a pattern in the other direction and a nil direction are
  # unlinked; those trips are counted but never placed in a section.
  defp unlinked_trip_count(trips, patterns) do
    linked =
      patterns
      |> Enum.map(fn pattern -> {pattern.route_pattern_id, pattern.direction_id} end)
      |> MapSet.new()

    Enum.count(trips, fn trip ->
      not (trip.direction_id in [0, 1] and
             MapSet.member?(linked, {trip.route_pattern_id, trip.direction_id}))
    end)
  end

  # -- Planning summary -------------------------------------------------------

  defp summary(trip_data, direction) do
    complete = Enum.filter(trip_data, &match?(%{bounds: {:ok, _, _}}, &1))

    direction_data = Enum.filter(trip_data, &(&1.trip.direction_id == direction))

    {scheduled, frequency} =
      Enum.split_with(direction_data, &(frequency_windows(&1.frequencies) == []))

    %{
      vehicles: complete |> Enum.flat_map(&spans_for/1) |> Summary.peak_vehicles(),
      trips_per_hour:
        Summary.trips_per_hour(
          for(%{bounds: {:ok, start_secs, _}} <- scheduled, do: start_secs),
          Enum.flat_map(frequency, &frequency_windows(&1.frequencies))
        ),
      incomplete_trip_count: length(trip_data) - length(complete)
    }
  end

  defp block_suggestions(trips, direction) do
    trips
    |> Enum.filter(&(&1.direction_id == direction))
    |> Enum.map(& &1.block_id)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp direction_labels(trips) do
    %{0 => direction_label(trips, 0), 1 => direction_label(trips, 1)}
  end

  defp direction_label(trips, direction) do
    headsigns =
      trips
      |> Enum.filter(&(&1.direction_id == direction))
      |> Enum.map(& &1.trip_headsign)
      |> Enum.reject(&(&1 in [nil, ""]))

    case headsigns do
      [] ->
        RoutePattern.direction_label(direction)

      headsigns ->
        counts = Enum.frequencies(headsigns)
        most = counts |> Map.values() |> Enum.max()

        headsign =
          counts
          |> Enum.filter(fn {_headsign, count} -> count == most end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.min_by(&{String.downcase(&1), &1})

        "To #{headsign}"
    end
  end

  # -- Trip spans -------------------------------------------------------------

  # The stored first departure and last arrival are parsed here with `GtfsTime`;
  # SQL string `MIN`/`MAX` never orders a clock value. A trip missing either bound
  # is incomplete and excluded from every summary.
  defp trip_bounds([]), do: :error

  defp trip_bounds(stop_times) do
    sorted = Enum.sort_by(stop_times, &{&1.stop_sequence, &1.id})

    with {:ok, start_secs} <- GtfsTime.parse(List.first(sorted).departure_time),
         {:ok, end_secs} <- GtfsTime.parse(List.last(sorted).arrival_time) do
      {:ok, start_secs, end_secs}
    else
      _ -> :error
    end
  end

  defp spans_for(%{bounds: {:ok, start_secs, end_secs}, frequencies: frequencies}) do
    case frequency_windows(frequencies) do
      [] ->
        [%{start_secs: start_secs, end_secs: end_secs}]

      windows ->
        duration = end_secs - start_secs

        Enum.map(windows, fn window ->
          %{
            start_secs: window.start_secs,
            end_secs: window.start_secs + duration,
            until_secs: window.until_secs,
            headway_secs: window.headway_secs
          }
        end)
    end
  end

  defp spans_for(_data), do: []

  defp frequency_windows(frequencies) do
    for %{start_time: start_time, end_time: end_time, headway_secs: headway_secs} <- frequencies,
        is_integer(headway_secs) and headway_secs > 0,
        {:ok, start_secs} <- [GtfsTime.parse(start_time)],
        {:ok, until_secs} <- [GtfsTime.parse(end_time)] do
      %{start_secs: start_secs, until_secs: until_secs, headway_secs: headway_secs}
    end
  end

  # -- Creation ---------------------------------------------------------------

  # The series is expanded before any lock is taken, so an invalid interval or an
  # over-long series refuses without a transaction or a write.
  defp departure_seconds(attrs) do
    with {:ok, start_secs} <- GtfsTime.parse(attr(attrs, :start_time)) do
      case attr(attrs, :repeat) do
        nil -> {:ok, [start_secs]}
        repeat -> expand_repeat(start_secs, repeat)
      end
    end
  end

  defp expand_repeat(start_secs, repeat) when is_map(repeat) do
    with {:ok, until_secs} <- GtfsTime.parse(attr(repeat, :until)) do
      series_starts(start_secs, attr(repeat, :every_minutes), until_secs)
    end
  end

  defp expand_repeat(_start_secs, _repeat), do: {:error, :invalid_input}

  # Spec 01's bounded retry: a serialization failure or lock contention retries
  # the whole transaction; every other failure is returned unchanged.
  defp run_write(route_id, starts, attrs, audit_context, attempts) do
    case run_write_transaction(fn -> insert_trips!(route_id, starts, attrs, audit_context) end) do
      {:ok, result} ->
        {:ok, result}

      {:serialization_failure, _error} ->
        retry_write(route_id, starts, attrs, audit_context, attempts)

      {:error, reason} ->
        retry_write_error(reason, route_id, starts, attrs, audit_context, attempts)
    end
  end

  defp retry_write(route_id, starts, attrs, audit_context, attempts) when attempts > 1,
    do: run_write(route_id, starts, attrs, audit_context, attempts - 1)

  defp retry_write(_route_id, _starts, _attrs, _audit_context, _attempts), do: {:error, :busy}

  defp retry_write_error(reason, route_id, starts, attrs, audit_context, attempts) do
    if serialization_failure?(reason),
      do: retry_write(route_id, starts, attrs, audit_context, attempts),
      else: {:error, reason}
  end

  defp run_write_transaction(transaction) do
    write_transaction_module().run(transaction)
  rescue
    error in Postgrex.Error ->
      if serialization_failure?(error) do
        {:serialization_failure, error}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp write_transaction_module do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )
  end

  defp serialization_failure?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:serialization_failure, "40001"],
       do: true

  defp serialization_failure?(_error), do: false

  defp insert_trips!(route_id, starts, attrs, audit_context) do
    pattern_id = attr(attrs, :pattern_id)
    timed_pattern_id = attr(attrs, :timed_pattern_id)
    service_id = attr(attrs, :service_id)
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    unless uuid?(pattern_id) and uuid?(timed_pattern_id), do: Repo.rollback(:not_found)

    # Rule-table lock order: the calendar's version row `FOR SHARE` first, then the
    # route `FOR UPDATE`, then the pattern `FOR UPDATE`. Timing rows are loaded
    # after the route lock, so a created trip always matches the committed timing.
    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, service_id)
    route = RoutePatterns.lock_published_route!(audit_context, route_id)
    pattern = RoutePatterns.lock_pattern!(route, pattern_id)
    timing = locked_timing!(pattern, timed_pattern_id)

    occurrences = pattern_occurrences(pattern)
    rows = timing_rows(timing)
    materialized = materialized_stop_times(starts, occurrences, rows)

    existing_trip_ids = version_trip_ids(organization_id, version_id)

    trip_ids =
      allocate_trip_ids(
        route.route_id,
        pattern.direction_id,
        service_id,
        starts,
        existing_trip_ids
      )

    trips =
      insert_trip_batch!(starts, trip_ids, route, pattern, timing, service_id, audit_context)

    now = DateTime.utc_now()

    trips
    |> Enum.zip(materialized)
    |> Enum.flat_map(fn {trip, stop_times} -> stop_time_rows(trip, stop_times, now) end)
    |> insert_stop_times!()

    audit_created_trips!(trips, starts, materialized, timing, audit_context)

    %{trips: trips}
  end

  defp materialized_stop_times(starts, occurrences, timing_rows) do
    Enum.map(starts, fn start_secs ->
      case Materializer.materialize(start_secs, occurrences, timing_rows) do
        {:ok, stop_times} -> stop_times
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_trip_batch!(starts, trip_ids, route, pattern, timing, service_id, audit_context) do
    headsign = timing.headsign || pattern.headsign

    starts
    |> Enum.zip(trip_ids)
    |> Enum.map(fn {_start_secs, trip_id} ->
      insert_trip!(%{
        trip_id: trip_id,
        route_id: route.route_id,
        service_id: service_id,
        direction_id: pattern.direction_id,
        trip_headsign: headsign,
        organization_id: audit_context.organization_id,
        gtfs_version_id: audit_context.gtfs_version_id,
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
    end)
  end

  # Application-owned linkage fields are set from the loaded records, never cast
  # from the request (CR-4). A unique-index violation on `trip_id` rolls the call
  # back with `:trip_id_conflict` instead of renaming the allocated ID.
  defp insert_trip!(attrs) do
    changeset =
      %Trip{}
      |> Trip.changeset(attrs)
      |> Ecto.Changeset.change(
        Map.take(attrs, [
          :route_pattern_id,
          :timed_pattern_id,
          :pattern_derivation_state,
          :pattern_derivation_reason
        ])
      )

    case Repo.insert(changeset) do
      {:ok, trip} ->
        trip

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_conflict?(changeset),
          do: Repo.rollback(:trip_id_conflict),
          else: Repo.rollback(changeset)
    end
  end

  defp unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, meta}} ->
      constraint_type(meta) == :unique
    end)
  end

  defp constraint_type(meta) when is_list(meta), do: Keyword.get(meta, :constraint)
  defp constraint_type(meta) when is_map(meta), do: Map.get(meta, :constraint)
  defp constraint_type(_meta), do: nil

  defp stop_time_rows(trip, materialized, now) do
    Enum.map(materialized, fn row ->
      %{
        trip_id: trip.trip_id,
        stop_id: row.stop_id,
        stop_sequence: row.stop_sequence,
        arrival_time: row.arrival_time,
        departure_time: row.departure_time,
        stop_headsign: row.stop_headsign,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        timepoint: row.timepoint,
        continuous_pickup: nil,
        continuous_drop_off: nil,
        shape_dist_traveled: nil,
        organization_id: trip.organization_id,
        gtfs_version_id: trip.gtfs_version_id,
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp insert_stop_times!(rows) do
    rows
    |> Enum.chunk_every(@stop_time_chunk_size)
    |> Enum.each(fn chunk -> Repo.insert_all(StopTime, chunk) end)

    :ok
  end

  # One log per created trip through the shared audit dispatch, all sharing one
  # `operation_id` and the batch's affected trip UUIDs. Any audit error rolls the
  # whole transaction back, so no created row survives a partial audit.
  defp audit_created_trips!(trips, starts, materialized, timing, audit_context) do
    operation_id = Ecto.UUID.generate()
    affected_trip_ids = Enum.map(trips, & &1.id)

    Enum.zip([trips, starts, materialized])
    |> Enum.each(fn {trip, start_secs, stop_times} ->
      snapshot = created_trip_snapshot(trip, timing, start_secs, length(stop_times))

      case Gtfs.record_change_in_transaction(audit_context, :trip, trip, "created", %{
             before: nil,
             after: snapshot,
             operation_id: operation_id,
             affected_trip_ids: affected_trip_ids
           }) do
        {:ok, _log} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)

    :ok
  end

  defp created_trip_snapshot(trip, timing, start_secs, stop_time_count) do
    %{
      "trip_id" => trip.trip_id,
      "route_id" => trip.route_id,
      "service_id" => trip.service_id,
      "direction_id" => trip.direction_id,
      "route_pattern_id" => trip.route_pattern_id,
      "timed_pattern_id" => trip.timed_pattern_id,
      "timing_name" => timing.name,
      "pattern_derivation_state" => trip.pattern_derivation_state,
      "trip_headsign" => trip.trip_headsign,
      "trip_short_name" => trip.trip_short_name,
      "block_id" => trip.block_id,
      "wheelchair_accessible" => trip.wheelchair_accessible,
      "bikes_allowed" => trip.bikes_allowed,
      "shape_id" => trip.shape_id,
      "start_time" => GtfsTime.format(start_secs),
      "stop_time_count" => stop_time_count,
      "frequencies" => []
    }
  end

  defp locked_timing!(pattern, timed_pattern_id) do
    query =
      from(t in TimedPattern,
        where: t.route_pattern_id == ^pattern.id and t.id == ^timed_pattern_id
      )

    case Repo.one(query) do
      %TimedPattern{} = timing -> timing
      nil -> Repo.rollback(:not_found)
    end
  end

  defp pattern_occurrences(pattern) do
    from(o in RoutePatternStop,
      where:
        o.organization_id == ^pattern.organization_id and
          o.gtfs_version_id == ^pattern.gtfs_version_id and
          o.route_pattern_id == ^pattern.id,
      order_by: [asc: o.position, asc: o.id]
    )
    |> Repo.all()
  end

  defp timing_rows(timing) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where:
        row.timed_pattern_id == ^timing.id and
          occurrence.organization_id == ^timing.organization_id and
          occurrence.gtfs_version_id == ^timing.gtfs_version_id,
      order_by: [asc: occurrence.position, asc: occurrence.id],
      select: %{
        stop_id: occurrence.stop_id,
        position: occurrence.position,
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        stop_headsign: row.stop_headsign
      }
    )
    |> Repo.all()
  end

  defp version_trip_ids(organization_id, version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id,
      select: t.trip_id
    )
    |> Repo.all()
  end

  # Trip IDs are unique within the organization and version, so the version's
  # existing IDs seed the candidate set. Across the batch, a later departure can
  # never reuse an ID this call already reserved.
  defp allocate_trip_ids(route_id, direction_id, service_id, starts, existing_trip_ids) do
    {trip_ids, _taken} =
      Enum.map_reduce(starts, MapSet.new(existing_trip_ids), fn start_secs, taken ->
        base = trip_id_base(route_id, direction_id, service_id, start_secs)
        trip_id = next_free_trip_id(base, taken)

        {trip_id, MapSet.put(taken, trip_id)}
      end)

    trip_ids
  end

  # The base itself when free; otherwise the smallest free suffix at or above 2.
  defp next_free_trip_id(base, taken) do
    if MapSet.member?(taken, base) do
      suffix =
        2
        |> Stream.iterate(&(&1 + 1))
        |> Enum.find(fn candidate -> not MapSet.member?(taken, "#{base}-#{candidate}") end)

      "#{base}-#{suffix}"
    else
      base
    end
  end

  defp trip_id_base(route_id, direction_id, service_id, start_secs) do
    "#{route_id}-#{direction_id}-#{service_id}-#{trip_id_stamp(start_secs)}"
  end

  # `HHMM` is unwrapped `hours * 100 + minutes`, zero-padded to four digits, so
  # `25:10` is `2510`.
  defp trip_id_stamp(start_secs) do
    hours = div(start_secs, 3_600)
    minutes = start_secs |> rem(3_600) |> div(60)

    (hours * 100 + minutes)
    |> Integer.to_string()
    |> String.pad_leading(4, "0")
  end

  defp series(start_secs, every_secs, until_secs) do
    count = div(until_secs - start_secs, every_secs) + 1

    if count > @max_series_trips do
      {:error, :too_many_trips}
    else
      {:ok, Enum.map(0..(count - 1), &(start_secs + &1 * every_secs))}
    end
  end

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp attr(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp attr(_map, _key), do: nil
end
