defmodule GtfsPlanner.Gtfs.Schedules do
  @moduledoc """
  Scoped reads for one route's Schedules tab.

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

  Every result is scoped: a foreign, invalid or unpublished organization,
  version or route rolls back to `{:error, :not_found}`.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
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
end
