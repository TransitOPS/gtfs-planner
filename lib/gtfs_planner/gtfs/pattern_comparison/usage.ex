defmodule GtfsPlanner.Gtfs.PatternComparison.Usage do
  @moduledoc """
  Trips per calendar, timing and hour for a set of route patterns (spec 19 R7).

  `usage/3` answers one side of a comparison for the selected calendar: how many
  trips each pattern runs on it, split by timing and custom trips, plus the
  24-hour histogram of first departures. A trip with frequencies.txt windows
  counts as its expanded departures only, never as its template row, and its own
  stored departure stays out of the scheduled list; a trip whose every window is
  unusable falls back to its stored departure, exactly as the route schedule
  summary falls back. Departures come from `Schedules.Summary.trips_per_hour/2`,
  so the compare page counts one repeating trip exactly as the Schedules tab
  does (`end_time` is the exclusive window end). A departure after midnight (hour
  24 or later) joins the last bucket, as the prototype does, so the histogram is
  always 24 buckets.

  `calendars/2` adds each pattern's count per calendar for the calendar select
  and the default-calendar rule, with the same R7 expansion.

  Every read filters by `organization_id` and `gtfs_version_id` (INV-1) and writes
  nothing (INV-2). The query count stays flat as trips grow: at most three queries
  for `usage/3` (trips, frequencies, first stop times) and at most two for
  `calendars/2`, plus `Calendars.list_calendars/2`.

  `service_id: nil` means no calendar is selected, so nothing counts, as an
  unresolved calendar leaves the route schedule empty. `calendars/2` runs
  `Calendars.list_calendars/2` outside any surrounding transaction, as that read
  requires; a foreign, invalid or unpublished scope has no calendars and returns
  `[]`.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @hours_per_day 24
  @all_services :all

  @typedoc "The scoped published organization and version every read is limited to."
  @type scope :: %{organization_id: Ecto.UUID.t(), gtfs_version_id: Ecto.UUID.t()}

  @typedoc """
  One pattern's trips on one calendar.

  `:total` counts departures: one per scheduled trip and one per expanded
  frequency departure. `:by_timing` holds that same count per `timed_pattern_id`,
  `:custom` the trips with no timing, `:repeating` the frequency departures, and
  `:hours` the 24 first-departure buckets.
  """
  @type usage_summary :: %{
          total: non_neg_integer(),
          by_timing: %{Ecto.UUID.t() => non_neg_integer()},
          custom: non_neg_integer(),
          repeating: non_neg_integer(),
          hours: [non_neg_integer()]
        }

  @typedoc "One calendar with each requested pattern's trip count on it."
  @type calendar_usage :: %{
          service_id: String.t(),
          name: String.t(),
          trips: %{String.t() => non_neg_integer()}
        }

  @doc """
  Counts one side's trips on one calendar, keyed by `route_pattern_id`.

  Every pattern gets an entry, an all-zero one when the pattern does not run on
  the calendar. `service_id: nil` counts nothing.
  """
  @spec usage(scope(), [RoutePattern.t()], String.t() | nil) :: %{String.t() => usage_summary()}
  def usage(_scope, patterns, nil) do
    Map.new(patterns, &{&1.route_pattern_id, empty_summary()})
  end

  def usage(_scope, [], _service_id), do: %{}

  def usage(scope, patterns, service_id) do
    ids = Enum.map(patterns, & &1.route_pattern_id)

    trips = load_trips(scope, ids, service_id)
    entries = trip_entries(trips, scope)
    first_departures = load_first_departures(scope, Enum.map(trips, & &1.trip_id))

    by_pattern = Enum.group_by(entries, & &1.trip.route_pattern_id)

    Map.new(ids, fn id ->
      {id, summary_for(Map.get(by_pattern, id, []), first_departures)}
    end)
  end

  @doc """
  Lists every calendar of the scope with each requested pattern's trip count.

  The order is `Calendars.list_calendars/2`'s own (display name, then service ID),
  so a caller's tie-break reads it unchanged. `trips` names every requested
  pattern, with `0` for a pattern that does not run on that calendar. A foreign,
  invalid or unpublished scope has no calendars: `[]`.
  """
  @spec calendars(scope(), [String.t()]) :: [calendar_usage()]
  def calendars(scope, route_pattern_ids) do
    case Calendars.list_calendars(scope.organization_id, scope.gtfs_version_id) do
      {:ok, summaries} -> calendar_summaries(scope, route_pattern_ids, summaries)
      {:error, :not_found} -> []
    end
  end

  defp calendar_summaries(scope, route_pattern_ids, summaries) do
    counts =
      scope
      |> load_trips(route_pattern_ids, @all_services)
      |> trip_entries(scope)
      |> Enum.group_by(& &1.trip.service_id)
      |> Map.new(fn {service_id, entries} ->
        {service_id, pattern_counts(route_pattern_ids, entries)}
      end)

    Enum.map(summaries, fn summary ->
      %{
        service_id: summary.service_id,
        name: summary.name || summary.service_id,
        trips: Map.get(counts, summary.service_id, pattern_counts(route_pattern_ids, []))
      }
    end)
  end

  defp pattern_counts(route_pattern_ids, entries) do
    by_pattern = Enum.group_by(entries, & &1.trip.route_pattern_id)

    Map.new(route_pattern_ids, fn id ->
      {id, by_pattern |> Map.get(id, []) |> Enum.sum_by(& &1.count)}
    end)
  end

  # One entry per trip: a trip with usable frequency windows counts as its
  # expanded departures only, every other trip as its stored first departure.
  defp trip_entries(trips, scope) do
    frequencies = load_frequencies(scope, Enum.map(trips, & &1.trip_id))

    Enum.map(trips, fn trip ->
      case frequencies |> Map.get(trip.trip_id, []) |> Schedules.frequency_windows() do
        [] ->
          %{trip: trip, count: 1, repeating: 0, windows: []}

        windows ->
          count = departure_count(windows)
          %{trip: trip, count: count, repeating: count, windows: windows}
      end
    end)
  end

  # Reuses the expansion the Schedules tab counts, so one repeating trip has one
  # count in the application.
  defp departure_count(windows) do
    Summary.trips_per_hour([], windows)
    |> Enum.sum_by(fn {_hour, count, _approximate?} -> count end)
  end

  defp summary_for([], _first_departures), do: empty_summary()

  defp summary_for(entries, first_departures) do
    totals =
      Enum.reduce(entries, %{total: 0, by_timing: %{}, custom: 0, repeating: 0}, &put_entry/2)

    Map.put(totals, :hours, hour_buckets(entries, first_departures))
  end

  defp put_entry(entry, totals) do
    totals = %{
      totals
      | total: totals.total + entry.count,
        repeating: totals.repeating + entry.repeating
    }

    case entry.trip.timed_pattern_id do
      nil ->
        %{totals | custom: totals.custom + entry.count}

      timing_id ->
        by_timing =
          Map.update(totals.by_timing, timing_id, entry.count, &(&1 + entry.count))

        %{totals | by_timing: by_timing}
    end
  end

  defp hour_buckets(entries, first_departures) do
    scheduled =
      for %{windows: [], trip: %{trip_id: trip_id}} <- entries,
          seconds = Map.get(first_departures, trip_id),
          is_integer(seconds),
          do: seconds

    scheduled
    |> Summary.trips_per_hour(Enum.flat_map(entries, & &1.windows))
    |> Enum.reduce(List.duplicate(0, @hours_per_day), fn {hour, count, _approximate?}, hours ->
      # An after-midnight departure joins the last bucket, as the prototype does.
      List.update_at(hours, min(hour, @hours_per_day - 1), &(&1 + count))
    end)
  end

  defp empty_summary do
    %{total: 0, by_timing: %{}, custom: 0, repeating: 0, hours: List.duplicate(0, @hours_per_day)}
  end

  defp load_trips(_scope, [], _service_id), do: []

  defp load_trips(scope, route_pattern_ids, service_id) do
    from(t in Trip,
      where:
        t.organization_id == ^scope.organization_id and
          t.gtfs_version_id == ^scope.gtfs_version_id and
          t.route_pattern_id in ^route_pattern_ids,
      order_by: [asc: t.route_pattern_id, asc: t.trip_id, asc: t.id],
      select: %{
        trip_id: t.trip_id,
        route_pattern_id: t.route_pattern_id,
        service_id: t.service_id,
        timed_pattern_id: t.timed_pattern_id
      }
    )
    |> filter_service(service_id)
    |> Repo.all()
  end

  defp filter_service(query, @all_services), do: query

  defp filter_service(query, service_id) do
    where(query, [t], t.service_id == ^service_id)
  end

  # The stored frequencies of the trips in view, read once and grouped; parsing
  # them into windows happens per trip in `trip_entries/2`.
  defp load_frequencies(_scope, []), do: %{}

  defp load_frequencies(scope, trip_ids) do
    from(f in Frequency,
      where:
        f.organization_id == ^scope.organization_id and
          f.gtfs_version_id == ^scope.gtfs_version_id and f.trip_id in ^trip_ids,
      order_by: [asc: f.trip_id, asc: f.start_time]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.trip_id)
  end

  # The first stop time of every trip in view, minimal columns, one query. The
  # first row per trip is its first departure; a later stop never replaces it.
  defp load_first_departures(_scope, []), do: %{}

  defp load_first_departures(scope, trip_ids) do
    from(st in StopTime,
      where:
        st.organization_id == ^scope.organization_id and
          st.gtfs_version_id == ^scope.gtfs_version_id and st.trip_id in ^trip_ids,
      order_by: [asc: st.trip_id, asc: st.stop_sequence, asc: st.id],
      select: %{trip_id: st.trip_id, departure_time: st.departure_time}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn %{trip_id: trip_id, departure_time: departure_time}, departures ->
      Map.put_new(departures, trip_id, parse_seconds(departure_time))
    end)
  end

  defp parse_seconds(nil), do: nil

  defp parse_seconds(departure_time) do
    case GtfsTime.parse(departure_time) do
      {:ok, seconds} -> seconds
      {:error, _reason} -> nil
    end
  end
end
