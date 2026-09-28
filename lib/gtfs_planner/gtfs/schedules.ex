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

  `update_trip/5`, `duplicate_trip/4` and `delete_trips/4` edit the same published
  service in place. Each runs in one write transaction that reuses the same locks
  and spec 01's `rematerialize_trip!/4`, re-checks the caller's `updated_at`
  before writing, enforces the custom-compatibility and frequency rules at the
  context boundary, and writes one `"trip"` audit log per affected trip. A bulk
  deletion validates the whole list before deleting anything and removes
  stop_times, frequencies and trip-scoped transfers before the trips. A calendar
  change on a blocked trip additionally joins the block guarantee: it takes
  `Blocking.lock_blocking!/1` in the rule-table order and clears the block in the
  same update when the new dates would put the trip on another vehicle's work
  (R9, D2, INV-1).

  Every result is scoped: a foreign, invalid or unpublished organization,
  version or route rolls back to `{:error, :not_found}`.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
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
  alias GtfsPlanner.Gtfs.Transfer
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

  @type update_attrs :: %{
          optional(:start_time) => String.t(),
          optional(:timed_pattern_id) => Ecto.UUID.t() | nil,
          optional(:service_id) => String.t() | nil,
          optional(:trip_headsign) => String.t() | nil,
          optional(:trip_short_name) => String.t() | nil,
          optional(:wheelchair_accessible) => 0..2 | nil,
          optional(:bikes_allowed) => 0..2 | nil
        }

  @type update_error ::
          :invalid_input
          | :not_found
          | :calendar_not_found
          | :invalid_time
          | :stale
          | :frequency_trip
          | :stops_differ
          | :timed_pattern_required
          | :trip_stop_times_mismatch
          | :busy

  @type duplicate_attrs :: %{
          start_time: String.t(),
          timed_pattern_id: Ecto.UUID.t()
        }

  @type delete_error :: :invalid_input | :not_found | :stale | :busy
  @type delete_result :: %{trips: non_neg_integer(), transfers: non_neg_integer()}

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
      run_write(fn -> insert_trips!(route_id, starts, attrs, audit_context) end)
    end
  end

  def create_trips(_route_id, _attrs, _audit_context), do: {:error, :invalid_input}

  @doc """
  Edits one trip in place, keeping its `trip_id`.

  `attrs` is a subset of `:start_time`, `:timed_pattern_id`, `:service_id`,
  `:trip_headsign`, `:trip_short_name`, `:wheelchair_accessible` and
  `:bikes_allowed`. The metadata fields go through a changeset that casts only
  those four fields and validates the two 0..2 enums. A block is read-only here:
  block membership changes on the Blocks page, so a submitted `:block_id` is
  ignored and leaves the stored block untouched. A calendar change is the one
  exception: it takes the version's blocking advisory lock and clears the block in
  the same update when the trip would join another vehicle's work on its new dates
  (R9, D2), so one audit entry records the calendar and the block change together.
  `direction_id` and `route_pattern_id` are never editable, and `trip_id` never
  changes.

  `expected_updated_at` (a `DateTime` or an ISO 8601 string) must equal the
  locked trip's `updated_at`, otherwise nothing is written and `:stale` is
  returned. A start or timing change on a frequency trip is `:frequency_trip`; on
  a linked trip it re-materializes the trip against a timing of its own pattern;
  on a custom trip it adopts the submitted timing, which is `:stops_differ`
  unless the ordered stop IDs and direction match the pattern and
  `:timed_pattern_required` when no timing is submitted. A request that changes
  nothing returns the trip with no write and no audit, and every changed trip's
  `updated_at` advances.
  """
  @spec update_trip(
          String.t(),
          Ecto.UUID.t(),
          update_attrs(),
          DateTime.t() | String.t() | nil,
          AuditContext.t()
        ) ::
          {:ok, Trip.t()} | {:error, Ecto.Changeset.t() | update_error()}
  def update_trip(route_id, trip_id, attrs, expected_updated_at, %AuditContext{} = audit_context)
      when is_map(attrs) do
    run_write(fn ->
      update_trip_transaction(route_id, trip_id, attrs, expected_updated_at, audit_context)
    end)
  end

  def update_trip(_route_id, _trip_id, _attrs, _expected_updated_at, _audit_context),
    do: {:error, :invalid_input}

  @doc """
  Creates one new trip on the source trip's pattern at the submitted start and timing.

  `attrs` carries `:start_time` and `:timed_pattern_id` (a timing of the source
  trip's pattern; required, because a custom source has no timing of its own).
  The new trip copies `service_id`, `trip_headsign`, `trip_short_name`,
  `wheelchair_accessible`, `bikes_allowed` and `shape_id`, gets no block, takes
  the pattern's direction, and gets a freshly allocated trip ID. New stop times
  take the pattern's per-visit distances when the source already references the
  pattern's shape; otherwise their distances are nil (R15). The duplicate is
  audited as created. A frequency source is refused with `:frequency_trip` and
  the source trip itself is never written.
  """
  @spec duplicate_trip(String.t(), Ecto.UUID.t(), duplicate_attrs(), AuditContext.t()) ::
          {:ok, Trip.t()} | {:error, Ecto.Changeset.t() | update_error()}
  def duplicate_trip(route_id, trip_id, attrs, %AuditContext{} = audit_context)
      when is_map(attrs) do
    run_write(fn -> duplicate_trip_transaction(route_id, trip_id, attrs, audit_context) end)
  end

  def duplicate_trip(_route_id, _trip_id, _attrs, _audit_context), do: {:error, :invalid_input}

  @doc """
  Deletes every listed trip of one route and calendar with its stop times,
  frequencies and trip-scoped transfers.

  The IDs are deduplicated and locked by UUID. The whole list is validated before
  anything is deleted: an ID that is not a trip of this organization, version and
  route is `:not_found`, and a trip on another calendar is `:stale`. Otherwise
  stop_times and frequencies are removed by `(organization_id, gtfs_version_id,
  trip_id)`, every transfer of this organization and version whose `from_trip_id`
  or `to_trip_id` equals one of the deleted natural `trip_id`s is removed, and
  then the trips, all in one transaction. Returns `%{trips: ..., transfers: ...}`
  with the number of deleted trips and removed transfers. One `"trip"` audit log
  per deleted trip shares a single `operation_id` and lists the affected trip
  UUIDs; removed transfers are not audited.
  """
  @spec delete_trips(String.t(), String.t() | nil, [Ecto.UUID.t()], AuditContext.t()) ::
          {:ok, delete_result()} | {:error, delete_error()}
  def delete_trips(route_id, service_id, trip_ids, %AuditContext{} = audit_context)
      when is_list(trip_ids) do
    case run_write(fn ->
           delete_trips_transaction(route_id, service_id, trip_ids, audit_context)
         end) do
      # A forged or foreign calendar is a scope failure for this writer.
      {:error, :calendar_not_found} -> {:error, :not_found}
      result -> result
    end
  end

  def delete_trips(_route_id, _service_id, _trip_ids, _audit_context),
    do: {:error, :invalid_input}

  @doc """
  Counts the transfers of one organization and version that name any of `trip_ids`.

  `trip_ids` are natural `trips.trip_id` values, not trip UUIDs. The count runs
  the same query `delete_trips/4` removes, so a caller can state the consequence
  before a deletion; an empty list counts nothing without a query.
  """
  @spec count_trip_transfers(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: non_neg_integer()
  def count_trip_transfers(_organization_id, _version_id, []), do: 0

  def count_trip_transfers(organization_id, version_id, trip_ids) when is_list(trip_ids) do
    trip_transfers_query(organization_id, version_id, trip_ids)
    |> Repo.aggregate(:count)
  end

  @doc """
  Builds the audit snapshot of many trips in three scoped queries.

  Returns `%{trip.id => snapshot}` with the same snapshot shape the trip edit path
  records, so a caller that audits many trips in one write reuses the stored shape
  instead of duplicating it (CR-5). Stop times, frequencies and timing names load
  for every given trip at once, scoped to `organization_id` and `version_id`; stop
  times are included only for a trip whose `pattern_derivation_state` is not
  `"linked"`, exactly as `edit_snapshot/3` decides, and `start_time` is the first
  stop time's departure.
  """
  @spec trip_audit_snapshots(Ecto.UUID.t(), Ecto.UUID.t(), [Trip.t()]) :: %{
          Ecto.UUID.t() => map()
        }
  def trip_audit_snapshots(organization_id, version_id, trips) when is_list(trips) do
    stop_times_by_trip = load_stop_times(organization_id, version_id, trips)
    frequencies_by_trip = load_frequencies(organization_id, version_id, trips)
    timing_names = timing_names(organization_id, version_id, trips)

    Map.new(trips, fn trip ->
      stop_times = Map.get(stop_times_by_trip, trip.trip_id, [])

      {trip.id,
       trip_snapshot(
         trip,
         Map.get(timing_names, trip.timed_pattern_id),
         first_departure_secs(stop_times),
         stop_times,
         ordered_frequencies(frequencies_by_trip, trip.trip_id),
         trip.pattern_derivation_state != "linked"
       )}
    end)
  end

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

    direction_data = Enum.filter(complete, &(&1.trip.direction_id == direction))

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
  defp run_write(transaction, attempts \\ @write_attempts) do
    case run_write_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:serialization_failure, _error} ->
        retry_write(transaction, attempts)

      {:error, reason} ->
        retry_write_error(reason, transaction, attempts)
    end
  end

  defp retry_write(transaction, attempts) when attempts > 1,
    do: run_write(transaction, attempts - 1)

  defp retry_write(_transaction, _attempts), do: {:error, :busy}

  defp retry_write_error(reason, transaction, attempts) do
    if serialization_failure?(reason),
      do: retry_write(transaction, attempts),
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
    # The shape attributes are read after the pattern lock, so they cannot
    # change until commit (R15).
    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, service_id)
    route = RoutePatterns.lock_published_route!(audit_context, route_id)
    pattern = RoutePatterns.lock_pattern!(route, pattern_id)
    shape_attrs = Alignments.trip_shape_attrs(pattern)
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
      insert_trip_batch!(
        starts,
        trip_ids,
        route,
        pattern,
        timing,
        service_id,
        shape_attrs.shape_id,
        audit_context
      )

    now = DateTime.utc_now()

    trips
    |> Enum.zip(materialized)
    |> Enum.flat_map(fn {trip, stop_times} ->
      stop_time_rows(trip, stop_times, shape_attrs.visit_distances, now)
    end)
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

  # Trips created on a drawn pattern carry its `shape_id`; on an undrawn
  # pattern the ID stays nil (R15). The linkage fields remain
  # application-owned, never cast from the request.
  defp insert_trip_batch!(
         starts,
         trip_ids,
         route,
         pattern,
         timing,
         service_id,
         shape_id,
         audit_context
       ) do
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
        shape_id: shape_id,
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

  # `distances` runs alongside the materialized rows by position; a row past
  # the end of the vector (which cannot happen for a locked pattern's own
  # occurrences) keeps nil rather than shifting every later distance.
  defp stop_time_rows(trip, materialized, distances, now) do
    materialized
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
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
        shape_dist_traveled: Enum.at(distances, index),
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
      audit_trip!(
        audit_context,
        trip,
        "created",
        nil,
        trip_snapshot(trip, timing.name, start_secs, stop_times, [], false),
        operation_id,
        affected_trip_ids
      )
    end)

    :ok
  end

  # One log per affected trip through the shared audit dispatch; any audit error
  # rolls the whole transaction back, so no trip data survives a partial audit. A
  # bulk operation passes one generated operation id and its complete affected
  # trip UUID list.
  defp audit_trip!(audit_context, trip, action, before, after_snapshot, operation_id, affected) do
    case Gtfs.record_change_in_transaction(audit_context, :trip, trip, action, %{
           before: before,
           after: after_snapshot,
           operation_id: operation_id,
           affected_trip_ids: affected
         }) do
      {:ok, _log} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The audit snapshot shape is shared by create, edit, duplicate and delete so
  # change history reads one shape. `stop_times` is included only for a snapshot
  # of a custom trip, whose times cannot be reconstructed from a timing.
  defp trip_snapshot(trip, timing_name, start_secs, stop_times, frequencies, include_stop_times?) do
    snapshot = %{
      "trip_id" => trip.trip_id,
      "route_id" => trip.route_id,
      "service_id" => trip.service_id,
      "direction_id" => trip.direction_id,
      "route_pattern_id" => trip.route_pattern_id,
      "timed_pattern_id" => trip.timed_pattern_id,
      "timing_name" => timing_name,
      "pattern_derivation_state" => trip.pattern_derivation_state,
      "trip_headsign" => trip.trip_headsign,
      "trip_short_name" => trip.trip_short_name,
      "block_id" => trip.block_id,
      "wheelchair_accessible" => trip.wheelchair_accessible,
      "bikes_allowed" => trip.bikes_allowed,
      "shape_id" => trip.shape_id,
      "start_time" => start_secs && GtfsTime.format(start_secs),
      "stop_time_count" => length(stop_times),
      "frequencies" => Enum.map(frequencies, &frequency_snapshot/1)
    }

    if include_stop_times? do
      Map.put(snapshot, "stop_times", Enum.map(stop_times, &stop_time_snapshot/1))
    else
      snapshot
    end
  end

  defp frequency_snapshot(frequency) do
    %{
      "start_time" => frequency.start_time,
      "end_time" => frequency.end_time,
      "headway_secs" => frequency.headway_secs,
      "exact_times" => frequency.exact_times
    }
  end

  defp stop_time_snapshot(stop_time) do
    %{
      "stop_id" => stop_time.stop_id,
      "arrival_time" => stop_time.arrival_time,
      "departure_time" => stop_time.departure_time
    }
  end

  # -- Editing, duplication and deletion --------------------------------------

  defp update_trip_transaction(route_id, trip_id, attrs, expected_updated_at, audit_context) do
    case requested_start_secs(attrs) do
      {:ok, requested_start} ->
        do_update_trip(
          route_id,
          trip_id,
          attrs,
          requested_start,
          expected_updated_at,
          audit_context
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Every trip writer locks in the rule-table order: the target calendar's version
  # row `FOR SHARE`, the route `FOR UPDATE`, the trip's pattern `FOR UPDATE`, the
  # version's blocking advisory lock when the request changes the calendar, and then
  # the trip row `FOR UPDATE` by UUID (INV-1). Timing rows load after the route
  # lock, so a retime always materializes the committed timing.
  defp do_update_trip(route_id, trip_id, attrs, requested_start, expected_updated_at, audit) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    unless uuid?(trip_id), do: Repo.rollback(:not_found)

    # The pre-lock read chooses the calendar identity and pattern to lock and
    # detects a trip that moved underneath the caller; the locked row read below
    # is the authoritative one.
    current = scoped_trip!(organization_id, version_id, route_id, trip_id)
    target_service = attr(attrs, :service_id) || current.service_id

    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, target_service)
    route = RoutePatterns.lock_published_route!(audit, route_id)
    pattern = lock_trip_pattern!(route, current.route_pattern_id)

    # A calendar change can clear the block, so it joins the block guarantee: the
    # advisory lock is taken after the pattern lock and before the trip row lock.
    if target_service != current.service_id, do: Blocking.lock_blocking!(version_id)

    trip = lock_trip!(organization_id, version_id, route.route_id, trip_id)

    if stale?(trip, expected_updated_at) or trip.route_pattern_id != current.route_pattern_id,
      do: Repo.rollback(:stale)

    effective_service = attr(attrs, :service_id) || trip.service_id

    if effective_service != target_service,
      do: Calendars.lock_service_for_reference!(organization_id, version_id, effective_service)

    edit_trip!(pattern, trip, attrs, requested_start, audit)
  end

  defp edit_trip!(pattern, trip, attrs, requested_start, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    stop_times = trip_stop_times(organization_id, version_id, trip.trip_id)
    frequencies = trip_frequencies(organization_id, version_id, trip.trip_id)
    current_start = first_departure_secs(stop_times)

    changeset = metadata_changeset(trip, attrs)
    unless changeset.valid?, do: Repo.rollback(changeset)

    request = trip_edit_request(attrs, trip, requested_start, current_start)
    {rewritten?, linkage} = rewrite_trip_times!(pattern, trip, request, stop_times, frequencies)

    changeset =
      changeset
      |> put_service_change(request, trip)
      |> Ecto.Changeset.change(linkage)

    if rewritten? or changeset.changes != %{} do
      persist_trip_edit!(changeset, trip, request, frequencies, audit_context)
    else
      # A request that changes nothing writes no trip row and no audit log.
      trip
    end
  end

  # A submitted value is a change only when it differs from the locked row, so a
  # request repeating the current values is a no-op.
  defp trip_edit_request(attrs, trip, requested_start, current_start) do
    requested_timing_id = attr(attrs, :timed_pattern_id)
    custom? = trip.pattern_derivation_state != "linked"

    %{
      service: attr(attrs, :service_id),
      requested_timing_id: requested_timing_id,
      requested_start: requested_start,
      current_start: current_start,
      custom?: custom?,
      adoption?: custom? and is_binary(requested_timing_id),
      timing_change?:
        is_binary(requested_timing_id) and requested_timing_id != trip.timed_pattern_id,
      start_change?: not is_nil(requested_start) and requested_start != current_start
    }
  end

  defp put_service_change(changeset, request, trip) do
    if is_binary(request.service) and request.service != trip.service_id do
      changeset
      |> Ecto.Changeset.change(service_id: request.service)
      |> clear_conflicting_block(trip, request.service)
    else
      changeset
    end
  end

  # D2/R9: a calendar change that would put the trip on dates where its block runs
  # another vehicle's work clears the block in the same update, so `persist_trip_edit!/5`
  # writes both changes at once and its `before`/`after` snapshots record them together
  # (AC-17). An unblocked trip has nothing to clear and reads no calendars.
  defp clear_conflicting_block(changeset, trip, service_id) do
    if is_binary(trip.block_id) and
         not Blocking.calendar_change_keeps_block?(
           trip.organization_id,
           trip.gtfs_version_id,
           trip,
           service_id
         ),
       do: Ecto.Changeset.change(changeset, block_id: nil),
       else: changeset
  end

  # Frequency service has no editable start or timing. A linked trip retimes
  # against a timing of its own pattern; a custom trip adopts the submitted timing
  # only when its ordered stops and direction match the pattern. Returns whether
  # rows were rewritten and the linkage fields the edit sets.
  defp rewrite_trip_times!(
         _pattern,
         _trip,
         %{adoption?: false, start_change?: false, timing_change?: false},
         _stop_times,
         _frequencies
       ),
       do: {false, %{}}

  defp rewrite_trip_times!(_pattern, _trip, _request, _stop_times, [_frequency | _rest]),
    do: Repo.rollback(:frequency_trip)

  defp rewrite_trip_times!(pattern, trip, %{adoption?: true} = request, stop_times, _frequencies),
    do: adopt_timing!(pattern, trip, request, stop_times)

  defp rewrite_trip_times!(pattern, trip, request, _stop_times, _frequencies) do
    if request.custom? and request.start_change? and not is_binary(request.requested_timing_id),
      do: Repo.rollback(:timed_pattern_required)

    retime_linked_trip!(pattern, trip, request)
  end

  defp adopt_timing!(nil, _trip, _request, _stop_times), do: Repo.rollback(:not_found)

  defp adopt_timing!(pattern, trip, request, stop_times) do
    timing = locked_timing!(pattern, request.requested_timing_id)
    occurrences = pattern_occurrences(pattern)

    if trip.direction_id != pattern.direction_id or not compatible_stops?(stop_times, occurrences),
      do: Repo.rollback(:stops_differ)

    rematerialize!(trip, pattern, timing, request)

    {true,
     %{
       timed_pattern_id: timing.id,
       pattern_derivation_state: "linked",
       pattern_derivation_reason: nil
     }}
  end

  defp retime_linked_trip!(nil, _trip, _request), do: Repo.rollback(:not_found)

  defp retime_linked_trip!(pattern, trip, request) do
    timing = locked_timing!(pattern, request.requested_timing_id || trip.timed_pattern_id)
    rematerialize!(trip, pattern, timing, request)

    {true, if(request.timing_change?, do: %{timed_pattern_id: timing.id}, else: %{})}
  end

  defp rematerialize!(trip, pattern, timing, request) do
    start_secs = request.requested_start || request.current_start || Repo.rollback(:invalid_time)

    RoutePatterns.rematerialize_trip!(
      trip,
      pattern_occurrences(pattern),
      timing_rows(timing),
      start_secs
    )
  end

  defp compatible_stops?(stop_times, occurrences) do
    Enum.map(stop_times, & &1.stop_id) == Enum.map(occurrences, & &1.stop_id)
  end

  defp persist_trip_edit!(changeset, trip, request, frequencies, audit_context) do
    before = edit_snapshot(trip, frequencies, request.current_start)

    # `force_change/3` makes the trip row's advance explicit even when the edit
    # only rewrote stop times, so INV-3 holds for every changed trip.
    changeset = Ecto.Changeset.force_change(changeset, :updated_at, DateTime.utc_now())
    updated = update_trip_row!(changeset)

    after_snapshot =
      edit_snapshot(
        updated,
        frequencies,
        request.requested_start || request.current_start
      )

    audit_trip!(
      audit_context,
      updated,
      "updated",
      before,
      after_snapshot,
      Ecto.UUID.generate(),
      [updated.id]
    )

    updated
  end

  defp update_trip_row!(changeset) do
    case Repo.update(changeset) do
      {:ok, trip} -> trip
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp edit_snapshot(trip, frequencies, start_secs) do
    stop_times = trip_stop_times(trip.organization_id, trip.gtfs_version_id, trip.trip_id)

    trip_snapshot(
      trip,
      timing_name(trip.organization_id, trip.gtfs_version_id, trip.timed_pattern_id),
      start_secs,
      stop_times,
      frequencies,
      trip.pattern_derivation_state != "linked"
    )
  end

  # The edit changeset casts only the four editable metadata fields; linkage,
  # calendar and times are application-owned and set from loaded records (CR-4).
  # `block_id` is deliberately absent: Schedules shows blocks read-only and the
  # Blocks page is the only block editor (D1, INV-5).
  @metadata_fields [
    :trip_headsign,
    :trip_short_name,
    :wheelchair_accessible,
    :bikes_allowed
  ]

  defp metadata_changeset(trip, attrs) do
    trip
    |> Ecto.Changeset.cast(attrs, @metadata_fields)
    |> GtfsPlanner.ChangesetHelpers.trim_string_fields()
    |> Ecto.Changeset.validate_inclusion(:wheelchair_accessible, 0..2)
    |> Ecto.Changeset.validate_inclusion(:bikes_allowed, 0..2)
  end

  defp duplicate_trip_transaction(route_id, trip_id, attrs, audit_context) do
    case GtfsTime.parse(attr(attrs, :start_time)) do
      {:ok, start_secs} -> do_duplicate_trip(route_id, trip_id, attrs, start_secs, audit_context)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp do_duplicate_trip(route_id, trip_id, attrs, start_secs, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    timed_pattern_id = attr(attrs, :timed_pattern_id)

    unless uuid?(trip_id) and uuid?(timed_pattern_id), do: Repo.rollback(:not_found)

    current = scoped_trip!(organization_id, version_id, route_id, trip_id)
    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, current.service_id)

    route = RoutePatterns.lock_published_route!(audit_context, route_id)
    pattern = duplicate_pattern!(route, current.route_pattern_id)
    trip = lock_trip!(organization_id, version_id, route.route_id, trip_id)

    if trip.route_pattern_id != current.route_pattern_id, do: Repo.rollback(:stale)

    if trip_frequencies(organization_id, version_id, trip.trip_id) != [],
      do: Repo.rollback(:frequency_trip)

    timing = locked_timing!(pattern, timed_pattern_id)
    occurrences = pattern_occurrences(pattern)
    [materialized] = materialized_stop_times([start_secs], occurrences, timing_rows(timing))

    [new_trip_id] =
      allocate_trip_ids(
        route.route_id,
        pattern.direction_id,
        trip.service_id,
        [start_secs],
        version_trip_ids(organization_id, version_id)
      )

    new_trip = insert_trip!(duplicate_trip_attrs(trip, route, pattern, timing, new_trip_id))

    # The copy keeps the source's shape ID (which equals the pattern's shape
    # when the source is already on it). Only a source on the pattern's own
    # shape takes the pattern's per-visit distances; any other source keeps
    # nil distances, as before (R15).
    shape_attrs = Alignments.trip_shape_attrs(pattern)

    distances =
      if trip.shape_id == pattern.shape_id and not is_nil(pattern.shape_id) do
        shape_attrs.visit_distances
      else
        List.duplicate(nil, length(materialized))
      end

    insert_stop_times!(stop_time_rows(new_trip, materialized, distances, DateTime.utc_now()))

    audit_trip!(
      audit_context,
      new_trip,
      "created",
      nil,
      trip_snapshot(new_trip, timing.name, start_secs, materialized, [], false),
      Ecto.UUID.generate(),
      [new_trip.id]
    )

    new_trip
  end

  # The copy takes the pattern's direction and natural ID and the source trip's
  # service and rider-facing metadata, including its shape, but never its block:
  # a duplicate is unblocked until it is assigned on the Blocks page (D1).
  defp duplicate_trip_attrs(trip, route, pattern, timing, trip_id) do
    %{
      trip_id: trip_id,
      route_id: route.route_id,
      service_id: trip.service_id,
      direction_id: pattern.direction_id,
      trip_headsign: trip.trip_headsign,
      trip_short_name: trip.trip_short_name,
      block_id: nil,
      wheelchair_accessible: trip.wheelchair_accessible,
      bikes_allowed: trip.bikes_allowed,
      shape_id: trip.shape_id,
      organization_id: trip.organization_id,
      gtfs_version_id: trip.gtfs_version_id,
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    }
  end

  defp duplicate_pattern!(route, route_pattern_id) do
    case lock_trip_pattern!(route, route_pattern_id) do
      %RoutePattern{} = pattern -> pattern
      nil -> Repo.rollback(:not_found)
    end
  end

  defp delete_trips_transaction(route_id, service_id, trip_ids, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    trip_uuids = Enum.uniq(trip_ids)

    unless Enum.all?(trip_uuids, &uuid?/1), do: Repo.rollback(:not_found)

    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, service_id)
    route = RoutePatterns.lock_published_route!(audit_context, route_id)

    trips = lock_matching_trips!(organization_id, version_id, route.route_id, trip_uuids)
    validate_delete_scope!(trips, trip_uuids, service_id)

    # The whole list is valid, so nothing has been deleted yet.
    snapshots = Enum.map(trips, &{&1, deleted_trip_snapshot(&1)})
    natural_ids = Enum.map(trips, & &1.trip_id)

    delete_children!(:stop_times, organization_id, version_id, natural_ids)
    delete_children!(:frequencies, organization_id, version_id, natural_ids)

    {transfers, nil} =
      Repo.delete_all(trip_transfers_query(organization_id, version_id, natural_ids))

    count = delete_trip_rows!(organization_id, version_id, trip_uuids)

    operation_id = Ecto.UUID.generate()
    affected_trip_ids = Enum.map(trips, & &1.id)

    Enum.each(snapshots, fn {trip, before} ->
      audit_trip!(
        audit_context,
        trip,
        "deleted",
        before,
        nil,
        operation_id,
        affected_trip_ids
      )
    end)

    %{trips: count, transfers: transfers}
  end

  defp lock_matching_trips!(organization_id, version_id, route_id, trip_uuids) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id == ^route_id and t.id in ^trip_uuids,
      order_by: [asc: t.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  # A missing row is any ID that is not a trip of this organization, version and
  # route; a calendar mismatch is any trip in the list on another calendar. Either
  # one rejects the whole list before a single row is deleted.
  defp validate_delete_scope!(trips, trip_uuids, service_id) do
    if length(trips) != length(trip_uuids), do: Repo.rollback(:not_found)
    if Enum.any?(trips, &(&1.service_id != service_id)), do: Repo.rollback(:stale)
    :ok
  end

  defp deleted_trip_snapshot(trip) do
    stop_times = trip_stop_times(trip.organization_id, trip.gtfs_version_id, trip.trip_id)
    frequencies = trip_frequencies(trip.organization_id, trip.gtfs_version_id, trip.trip_id)

    trip_snapshot(
      trip,
      timing_name(trip.organization_id, trip.gtfs_version_id, trip.timed_pattern_id),
      first_departure_secs(stop_times),
      stop_times,
      frequencies,
      trip.pattern_derivation_state != "linked"
    )
  end

  defp delete_children!(:stop_times, organization_id, version_id, trip_ids) do
    Repo.delete_all(
      from(st in StopTime,
        where:
          st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
            st.trip_id in ^trip_ids
      )
    )

    :ok
  end

  defp delete_children!(:frequencies, organization_id, version_id, trip_ids) do
    Repo.delete_all(
      from(f in Frequency,
        where:
          f.organization_id == ^organization_id and f.gtfs_version_id == ^version_id and
            f.trip_id in ^trip_ids
      )
    )

    :ok
  end

  # One builder for the counted read and the deletion, so the count a caller sees
  # is the set the deletion removes. The trip columns hold natural `trip_id`
  # values, never `trips.id` UUIDs.
  defp trip_transfers_query(organization_id, version_id, trip_ids) do
    from(t in Transfer,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          (t.from_trip_id in ^trip_ids or t.to_trip_id in ^trip_ids)
    )
  end

  defp delete_trip_rows!(organization_id, version_id, trip_uuids) do
    {count, nil} =
      Repo.delete_all(
        from(t in Trip,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
              t.id in ^trip_uuids
        )
      )

    count
  end

  # -- Scoped trip reads ------------------------------------------------------

  defp scoped_trip!(organization_id, version_id, route_id, trip_id) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id == ^route_id and t.id == ^trip_id
    )
    |> Repo.one()
    |> case do
      %Trip{} = trip -> trip
      nil -> Repo.rollback(:not_found)
    end
  end

  defp lock_trip!(organization_id, version_id, route_id, trip_id) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id == ^route_id and t.id == ^trip_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      %Trip{} = trip -> trip
      nil -> Repo.rollback(:not_found)
    end
  end

  # Locks the trip's own pattern through spec 01's published helper; an unlinked
  # trip whose natural ID resolves to no pattern of this route has none to lock.
  defp lock_trip_pattern!(route, route_pattern_id) when is_binary(route_pattern_id) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^route.organization_id and
          p.gtfs_version_id == ^route.gtfs_version_id and p.route_id == ^route.route_id and
          p.route_pattern_id == ^route_pattern_id,
      select: p.id
    )
    |> Repo.one()
    |> case do
      nil -> nil
      pattern_id -> RoutePatterns.lock_pattern!(route, pattern_id)
    end
  end

  defp lock_trip_pattern!(_route, _route_pattern_id), do: nil

  defp trip_stop_times(organization_id, version_id, trip_id) do
    from(st in StopTime,
      where:
        st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
          st.trip_id == ^trip_id,
      order_by: [asc: st.stop_sequence, asc: st.id]
    )
    |> Repo.all()
  end

  defp trip_frequencies(organization_id, version_id, trip_id) do
    from(f in Frequency,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^version_id and
          f.trip_id == ^trip_id,
      order_by: [asc: f.start_time, asc: f.id]
    )
    |> Repo.all()
  end

  defp first_departure_secs([]), do: nil

  defp first_departure_secs([first | _rest]) do
    case GtfsTime.parse(first.departure_time) do
      {:ok, seconds} -> seconds
      {:error, _reason} -> nil
    end
  end

  defp timing_name(_organization_id, _version_id, nil), do: nil

  defp timing_name(organization_id, version_id, timed_pattern_id) do
    from(t in TimedPattern,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.id == ^timed_pattern_id,
      select: t.name
    )
    |> Repo.one()
  end

  defp timing_names(_organization_id, _version_id, []), do: %{}

  defp timing_names(organization_id, version_id, trips) do
    timed_pattern_ids =
      trips
      |> Enum.map(& &1.timed_pattern_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    from(t in TimedPattern,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.id in ^timed_pattern_ids,
      select: {t.id, t.name}
    )
    |> Repo.all()
    |> Map.new()
  end

  # `load_frequencies/3` orders a batch by trip and start time; sorting one trip's
  # windows by start time then id restores `trip_frequencies/3`'s order, so the
  # batch snapshot and the snapshot an edit records compare equal.
  defp ordered_frequencies(frequencies_by_trip, trip_id) do
    frequencies_by_trip
    |> Map.get(trip_id, [])
    |> Enum.sort_by(&{&1.start_time, &1.id})
  end

  # The requested start is optional; when present it must parse before any lock
  # is taken, so an unparseable clock never reaches a transaction.
  defp requested_start_secs(attrs) do
    case attr(attrs, :start_time) do
      nil -> {:ok, nil}
      value -> GtfsTime.parse(value)
    end
  end

  # The caller's expected timestamp may be the loaded DateTime or its ISO 8601
  # form; anything missing or unparseable is stale, so a write is never blind.
  defp stale?(trip, expected_updated_at) do
    case normalize_timestamp(expected_updated_at) do
      %DateTime{} = expected -> DateTime.compare(trip.updated_at, expected) != :eq
      nil -> true
    end
  end

  defp normalize_timestamp(%DateTime{} = value), do: value

  defp normalize_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp normalize_timestamp(_value), do: nil

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
