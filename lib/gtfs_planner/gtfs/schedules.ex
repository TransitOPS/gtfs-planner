defmodule GtfsPlanner.Gtfs.Schedules do
  @moduledoc """
  Scoped reads and trip creation for one route's Schedules tab.

  `load_route_schedule/4` loads everything one Schedules page renders from one
  published organization/version/route scope. It runs in one read transaction
  that holds the version row `FOR SHARE` through `Calendars.list_calendars/3`, so
  a cooperating calendar write cannot interleave with the loaded aggregate.

  The read canonicalizes the requested calendar, direction, pattern and stops
  filters, builds every section from the stored stop times through
  `Schedules.Timetable.build/6` (never from a timing), and derives the planning
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

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Blocking.Queries
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Export.MissingTimes
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Schedules.ServiceMix
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Gtfs.Schedules.Timetable
  alias GtfsPlanner.Gtfs.Schedules.TripChanges
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.TimetablePaste
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions.GtfsVersion

  # A series is bounded so one drawer submission cannot create an unbounded
  # number of trips and audit rows; stop times are inserted in fixed chunks.
  @max_series_trips 200
  @stop_time_chunk_size 1_000
  # Spec 01's bounded retry for serialization or lock contention.
  @write_attempts 3
  # A maximum paste (500 trips × 150 stops) took about 11 s on an idle machine,
  # close to the 15 s connection default, so the paste apply gets its own
  # bounded transaction budget. Other Schedules writers keep the default.
  @paste_transaction_timeout 60_000

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
          headsign: String.t() | nil,
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
          | :forbidden
          | :not_found
          | :calendar_not_found
          | :trip_id_conflict
          | :negative_time
          | :invalid_chronology
          | {:mixed_service, map()}
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
          | :forbidden
          | :not_found
          | :calendar_not_found
          | :invalid_time
          | :stale
          | :frequency_trip
          | :stops_differ
          | :timed_pattern_required
          | :trip_stop_times_mismatch
          | :busy
          | ServiceMix.error()

  @type duplicate_attrs :: %{
          start_time: String.t(),
          timed_pattern_id: Ecto.UUID.t()
        }

  @type delete_error :: :invalid_input | :forbidden | :not_found | :stale | :busy
  @type delete_result :: %{trips: non_neg_integer(), transfers: non_neg_integer()}

  @typedoc "One reviewed headsign change: `id` is the trip UUID, `trip_id` its
  natural ID, and `from`/`to` the normalized reviewed and target headsigns."
  @type change :: %{
          required(:id) => Ecto.UUID.t(),
          required(:trip_id) => String.t(),
          required(:from) => String.t() | nil,
          required(:to) => String.t() | nil
        }

  @typedoc """
  What an apply accepts as its stale tolerance (R3, §4.4).

  `{:reviewed, fingerprint}` is the reviewed bulk command and the Shift strip,
  `{:expected, %{trip_uuid => updated_at}}` a direct cell edit, clear or nudge whose
  page loaded those rows, and `:none` the unfenced `:add_frequency` pairing. Every
  other command/fence pairing is `{:error, :fence_required}`.
  """
  @type fence :: {:reviewed, String.t()} | {:expected, %{Ecto.UUID.t() => DateTime.t()}} | :none

  @typedoc "What one applied command returns; `restore` is nil for a non-undoable command."
  @type apply_result :: %{
          operation_id: Ecto.UUID.t(),
          changed_trip_ids: [Ecto.UUID.t()],
          created_trip_ids: [Ecto.UUID.t()],
          deleted_trip_ids: [Ecto.UUID.t()],
          transfers_removed: non_neg_integer(),
          change_set: TripChanges.change_set(),
          restore: TripChanges.restore_payload() | nil
        }

  @type apply_error ::
          {:stale_review, TripChanges.review()}
          | :stale
          | {:refused, [TripChanges.consequence()]}
          | :fence_required
          | :forbidden
          | :not_found
          | :calendar_not_found
          | :invalid_command
          | :too_many_trips
          | :busy
          | :trip_stop_times_mismatch
          | :trip_id_conflict
          | Ecto.Changeset.t()

  @typedoc """
  What one restore returns (R10, §4.4).

  `restored_trip_ids` are the updated trips put back and `deleted_trip_ids` the
  created trips removed; `operation_id` is the restore's own operation, while
  every audit log carries the original apply's id in `undoes`.
  """
  @type restore_result :: %{
          operation_id: Ecto.UUID.t(),
          restored_trip_ids: [Ecto.UUID.t()],
          deleted_trip_ids: [Ecto.UUID.t()]
        }

  @type restore_error ::
          {:not_restorable, :changed | :transfer_names_created_trip, [Ecto.UUID.t()]}
          | :forbidden
          | :not_found
          | :invalid_command
          | :trip_stop_times_mismatch
          | :busy
          | Ecto.Changeset.t()

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

  A create that would add the pattern's first listed trips to a service date that
  already carries its frequency service is refused with
  `{:error, {:mixed_service, details}}` and writes nothing (R9, AC-20), while a
  pattern and date that already mix stay creatable.
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
  A calendar change that would newly mix listed trips and frequency service on the
  trip's pattern is `{:mixed_service, details}` with nothing written (R9, INV-5).
  `direction_id` and `route_pattern_id` are never editable, and `trip_id` never
  changes.

  A submitted `:trip_headsign` that is blank stores the trip's headsign fallback,
  `timing.headsign || pattern.headsign` (see `fallback_headsign/2`), the same value
  a new trip on that timing gets. The timing is the one the trip has after this
  edit. Without a non-blank fallback the headsign is stored as nil.

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
  The headsign a blank trip headsign takes: the timing's, else the pattern's.

  Returns nil when neither is present, so a trip is never given a blank headsign.
  """
  @spec fallback_headsign(String.t() | nil, String.t() | nil) :: String.t() | nil
  def fallback_headsign(timing_headsign, pattern_headsign) do
    Enum.find([timing_headsign, pattern_headsign], &(is_binary(&1) and String.trim(&1) != ""))
  end

  @doc """
  Creates one new trip on the source trip's pattern at the submitted start and timing.

  `attrs` carries `:start_time` and `:timed_pattern_id` (a timing of the source
  trip's pattern; required, because a custom source has no timing of its own).
  The new trip copies `service_id`, `trip_headsign`, `wheelchair_accessible`,
  `bikes_allowed` and `shape_id`, gets no block, takes the pattern's direction,
  and gets a freshly allocated trip ID. It gets no `trip_short_name`: the public
  trip number identifies a trip within its service day, and the copy runs on the
  source's service. New stop times take the pattern's per-visit distances when
  the source already references the pattern's shape; otherwise their distances
  are nil (R15). The duplicate is audited as created. A frequency source is
  refused with `:frequency_trip` and the source trip itself is never written.
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
  UUIDs, and each removed transfer is logged with a `"deleted"` `"transfer"`
  change carrying its own before snapshot under the same `operation_id` (R11).
  An audit failure rolls the whole deletion back, so a transfer row is never
  removed unaudited.
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

  # -- Change review (R3) -----------------------------------------------------

  @doc """
  Reviews one trip-change command without writing.

  The command is validated first, then one read transaction loads its scoped
  state: the route, every affected trip with its stop times and frequency rows,
  the affected patterns with their occurrences and timings, the version's
  calendars, and the per-command inputs (`block_inputs`, `existing_trip_ids`,
  `transfer_counts`, `target_service`). `TripChanges.plan/2` turns the command
  into a change set.

  A trip UUID outside this organization, version or route is
  `{:error, :not_found}`; a target calendar outside the version is
  `{:error, :calendar_not_found}`. The review carries the canonical command, the
  planned change set, the R3 fingerprint an apply must match, the preview of
  every updated trip's occurrence positions as the seconds the grid shows, and
  the counts of changed, created, deleted, excluded and skipped trips. Nothing
  is written and no audit log is recorded.
  """
  @spec review_trip_change(String.t(), TripChanges.command(), AuditContext.t()) ::
          {:ok, TripChanges.review()}
          | {:error,
             :not_found | :invalid_command | :too_many_trips | :calendar_not_found | term()}
  def review_trip_change(route_id, command, %AuditContext{} = audit_context) do
    case TripChanges.validate(command) do
      {:ok, command} ->
        run_read(fn -> do_review_trip_change(route_id, command, audit_context) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def review_trip_change(_route_id, _command, _audit_context), do: {:error, :invalid_input}

  defp do_review_trip_change(route_id, command, audit_context) do
    route =
      published_route!(audit_context.organization_id, audit_context.gtfs_version_id, route_id)

    state = load_change_state(route, command, audit_context)

    case TripChanges.plan(command, state) do
      {:ok, change_set} -> change_review(command, state, change_set)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The review and the apply path share this loader: the review runs it in a
  # plain read transaction without row locks, and the apply path re-runs it under
  # the §4.4 lock order before it plans and fences. Every read is scoped to the
  # organization, version and route, so a foreign UUID can never enter the state.
  defp load_change_state(route, command, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    identities = change_identities!(organization_id, version_id, route, command)
    calendars = load_calendars!(organization_id, version_id)
    check_target_service!(command, calendars)

    pattern_ids = change_pattern_ids!(organization_id, version_id, route, command, identities)
    patterns = change_patterns!(organization_id, version_id, route, pattern_ids)
    trips = change_trips(organization_id, version_id, route, identities, patterns)

    %{
      route: route,
      trips: trips,
      patterns: patterns,
      calendars: calendars,
      service_dates: DayTypes.service_dates(calendars),
      pattern_trips: change_pattern_trips(trips, patterns),
      target_service: change_target_service(command)
    }
    |> put_block_inputs(command, organization_id, version_id, identities)
    |> put_existing_trip_ids(command, organization_id, version_id)
    |> put_transfer_counts(command, organization_id, version_id, identities)
  end

  # Every trip the command names must be a trip of this organization, version and
  # route; a miss is a scope failure, never a planner concern.
  defp change_identities!(organization_id, version_id, route, command) do
    case cast_change_trip_ids(change_trip_ids(command)) do
      {:ok, trip_ids} ->
        identities = Queries.trip_identities(organization_id, version_id, {:uuids, trip_ids})

        if scoped_identities?(identities, trip_ids, route) do
          identities
        else
          Repo.rollback(:not_found)
        end

      :error ->
        Repo.rollback(:not_found)
    end
  end

  defp scoped_identities?(identities, trip_ids, route) do
    length(identities) == length(trip_ids) and
      Enum.all?(identities, &(&1.route_id == route.route_id))
  end

  defp cast_change_trip_ids(trip_ids) do
    trip_ids
    |> Enum.reduce_while({:ok, []}, fn trip_id, {:ok, acc} ->
      case Ecto.UUID.cast(trip_id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
      :error -> :error
    end
  end

  defp change_trip_ids({:edit_stop, trip_id, _params}), do: [trip_id]
  defp change_trip_ids({:shift, trip_ids, _delta, _from_position}), do: trip_ids
  defp change_trip_ids({:set_timing, trip_ids, _timing_id}), do: trip_ids
  defp change_trip_ids({:move_calendar, trip_ids, _service_id}), do: trip_ids
  defp change_trip_ids({:copy, trip_ids, _service_id, _offset, _skip_existing}), do: trip_ids
  defp change_trip_ids({:add_frequency, _attrs}), do: []
  defp change_trip_ids({:update_frequency, trip_id, _params}), do: [trip_id]
  defp change_trip_ids({:convert_frequency, trip_id}), do: [trip_id]

  defp change_trip_ids({:restore, payload}) do
    restored = payload |> attr(:trips) |> List.wrap() |> Enum.map(&attr(&1, :id))
    created = payload |> attr(:created) |> List.wrap() |> Enum.map(&attr(&1, :id))

    Enum.uniq(restored ++ created)
  end

  # The affected patterns are the trips' own patterns plus the pattern an
  # `:add_frequency` command writes to; that pattern must be one of this route's.
  defp change_pattern_ids!(organization_id, version_id, route, command, identities) do
    trip_patterns =
      identities
      |> Enum.map(& &1.route_pattern_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case command do
      {:add_frequency, %{pattern_id: pattern_id}} ->
        pattern = change_pattern!(organization_id, version_id, route, pattern_id)
        Enum.uniq([pattern.route_pattern_id | trip_patterns])

      _command ->
        trip_patterns
    end
  end

  defp change_pattern!(organization_id, version_id, route, pattern_id) do
    query =
      from(p in RoutePattern,
        where:
          p.organization_id == ^organization_id and p.gtfs_version_id == ^version_id and
            p.route_id == ^route.route_id and p.id == ^pattern_id
      )

    case Repo.one(query) do
      %RoutePattern{} = pattern -> pattern
      nil -> Repo.rollback(:not_found)
    end
  end

  # A trip whose stored pattern is gone stays loadable (the reader calls it
  # unlinked); only the patterns that resolve to this route's rows are keyed.
  defp change_patterns!(organization_id, version_id, route, pattern_ids) do
    patterns =
      from(p in RoutePattern,
        where:
          p.organization_id == ^organization_id and p.gtfs_version_id == ^version_id and
            p.route_id == ^route.route_id and p.route_pattern_id in ^pattern_ids,
        order_by: [asc: p.route_pattern_id]
      )
      |> Repo.all()

    occurrences = load_occurrences(organization_id, version_id, patterns)
    timings = load_timings(organization_id, version_id, patterns)

    Map.new(patterns, fn pattern ->
      {pattern.route_pattern_id,
       %{
         pattern: pattern,
         occurrences: Map.get(occurrences, pattern.id, []),
         timings: Map.get(timings, pattern.id, []) |> Enum.map(&change_timing/1)
       }}
    end)
  end

  defp change_timing(timing),
    do: %{timing: Map.delete(timing, :rows), rows: Map.get(timing, :rows, [])}

  # Every trip of an affected pattern is loaded, not only the command's own: the
  # R4 duplicate check and the later copy, calendar and mixing rules read the
  # pattern's trips from this map.
  defp change_trips(organization_id, version_id, route, identities, patterns) do
    pattern_ids = Map.keys(patterns)
    identity_ids = Enum.map(identities, & &1.id)

    trips =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_id == ^route.route_id and
            (t.route_pattern_id in ^pattern_ids or t.id in ^identity_ids),
        order_by: [asc: t.id]
      )
      |> Repo.all()

    stop_times = load_stop_times(organization_id, version_id, trips)
    frequencies = load_frequencies(organization_id, version_id, trips)

    Map.new(trips, fn trip ->
      {trip.id,
       %{
         trip: trip,
         stop_times: Map.get(stop_times, trip.trip_id, []),
         frequencies: Map.get(frequencies, trip.trip_id, [])
       }}
    end)
  end

  defp change_pattern_trips(trips, patterns) do
    loaded =
      Enum.reduce(trips, %{}, fn {_trip_uuid, entry}, acc ->
        trip = entry.trip

        summary = %{
          id: trip.id,
          service_id: trip.service_id,
          frequency?: entry.frequencies != []
        }

        case trip.route_pattern_id do
          nil -> acc
          pattern_id -> Map.update(acc, pattern_id, [summary], &[summary | &1])
        end
      end)

    Map.new(patterns, fn {pattern_id, _pattern} ->
      {pattern_id, loaded |> Map.get(pattern_id, []) |> Enum.sort_by(& &1.id)}
    end)
  end

  defp check_target_service!(command, calendars) do
    case change_target_service(command) do
      nil ->
        :ok

      service_id ->
        unless Enum.any?(calendars, &(&1.service_id == service_id)),
          do: Repo.rollback(:calendar_not_found)
    end
  end

  defp change_target_service({:move_calendar, _trip_ids, service_id}), do: service_id

  defp change_target_service({:copy, _trip_ids, service_id, _offset, _skip_existing}),
    do: service_id

  defp change_target_service({:add_frequency, attrs}), do: attr(attrs, :service_id)
  defp change_target_service(_command), do: nil

  defp put_block_inputs(state, command, organization_id, version_id, identities)
       when elem(command, 0) in [:shift, :move_calendar] do
    Map.put(
      state,
      :block_inputs,
      block_inputs(organization_id, version_id, state.calendars, identities)
    )
  end

  defp put_block_inputs(state, _command, _organization_id, _version_id, _identities), do: state

  defp put_existing_trip_ids(state, command, organization_id, version_id)
       when elem(command, 0) in [:copy, :add_frequency, :convert_frequency] do
    Map.put(state, :existing_trip_ids, version_trip_ids(organization_id, version_id))
  end

  defp put_existing_trip_ids(state, _command, _organization_id, _version_id), do: state

  defp put_transfer_counts(state, command, organization_id, version_id, identities)
       when elem(command, 0) in [:convert_frequency, :restore] do
    natural_ids = identities |> Enum.map(& &1.trip_id) |> Enum.uniq()
    Map.put(state, :transfer_counts, transfer_counts(organization_id, version_id, natural_ids))
  end

  defp put_transfer_counts(state, _command, _organization_id, _version_id, _identities), do: state

  # The selected trips plus every trip on their blocks anywhere in the version,
  # with the in-seat records naming them: exactly the inputs
  # `Blocking.project_trip_changes/2` consumes.
  defp block_inputs(organization_id, version_id, calendars, identities) do
    selected_ids = Enum.map(identities, & &1.id)

    block_ids =
      identities |> Enum.map(& &1.block_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    trips =
      (Queries.trip_rows(organization_id, version_id, {:uuids, selected_ids}) ++
         block_trip_rows(organization_id, version_id, block_ids))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id)

    %{
      calendars: calendars,
      trips: trips,
      transfers: Queries.in_seat_rows(organization_id, version_id, Enum.map(trips, & &1.trip_id)),
      settings: Blocking.get_settings(organization_id, version_id)
    }
  end

  defp block_trip_rows(_organization_id, _version_id, []), do: []

  defp block_trip_rows(organization_id, version_id, block_ids),
    do: Queries.trip_rows(organization_id, version_id, {:blocks, block_ids})

  # `%{natural_trip_id => n}` for every given trip, including zero-count trips,
  # so an undo can require every created trip's count to be zero (R10).
  defp transfer_counts(_organization_id, _version_id, []), do: %{}

  defp transfer_counts(organization_id, version_id, natural_trip_ids) do
    counts = Map.new(natural_trip_ids, &{&1, 0})

    from(t in Transfer,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          (t.from_trip_id in ^natural_trip_ids or t.to_trip_id in ^natural_trip_ids),
      select: {t.from_trip_id, t.to_trip_id}
    )
    |> Repo.all()
    |> Enum.reduce(counts, &count_transfer/2)
  end

  defp count_transfer({from_trip_id, to_trip_id}, counts) do
    [from_trip_id, to_trip_id]
    |> Enum.uniq()
    |> Enum.reduce(counts, fn trip_id, acc ->
      if Map.has_key?(acc, trip_id), do: Map.update!(acc, trip_id, &(&1 + 1)), else: acc
    end)
  end

  defp change_review(command, state, change_set) do
    %{
      command: command,
      change_set: change_set,
      fingerprint: TripChanges.fingerprint(command, state, change_set),
      preview: change_preview(change_set),
      counts: change_counts(change_set)
    }
  end

  # The grid shows a stop's departure everywhere except the last column, where it
  # shows the arrival, so every preview cell carries the value that cell will
  # display; a missing or unreadable time stays nil.
  defp change_preview(%{updates: updates}) do
    updates
    |> Enum.filter(&is_list(&1.stop_times))
    |> Map.new(fn update -> {update.trip_id, update_preview(update.stop_times)} end)
  end

  defp update_preview(stop_times) do
    last = length(stop_times)

    stop_times
    |> Enum.with_index(1)
    |> Map.new(fn {row, index} ->
      {Map.get(row, :position, index), preview_secs(row, index == last)}
    end)
  end

  defp preview_secs(row, last?) do
    value = if last?, do: Map.get(row, :arrival_time), else: Map.get(row, :departure_time)

    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, _reason} -> nil
    end
  end

  defp change_counts(change_set) do
    %{
      changed: length(change_set.updates),
      created: length(change_set.inserts),
      deleted: length(change_set.deletes),
      excluded: consequence_count(change_set.consequences, :excluded),
      skipped: consequence_count(change_set.consequences, :skipped_existing)
    }
  end

  defp consequence_count(consequences, tag) do
    Enum.count(consequences, &match?({:note, {^tag, _, _}}, &1))
  end

  defp run_read(read) do
    case Repo.transaction(read) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Change apply (R3) ------------------------------------------------------

  @doc """
  Applies one validated trip-change command in a single write transaction.

  The command is validated first; the transaction then re-reads the command's
  scoped identities and takes the §4.4 engine locks in order: the calendar
  reference check for every involved service in sorted order, the published route
  `FOR UPDATE`, each affected pattern `FOR UPDATE` by ascending UUID, the version's
  blocking advisory lock when `block_id` can change, and the affected trips
  `FOR UPDATE` by ascending UUID. Under those locks it re-loads the same state the
  review loaded, plans the command again and checks the caller's fence: a
  `{:reviewed, fingerprint}` must equal the recomputed fingerprint
  (`{:error, {:stale_review, review}}` otherwise) and an `{:expected, ...}` map must
  equal every command trip's `updated_at` (`{:error, :stale}` otherwise). Any
  command/fence pairing outside §4.4 is `{:error, :fence_required}`.

  A change set carrying any `{:error, _}` consequence is
  `{:error, {:refused, errors}}` with no write. Otherwise the applier reads the
  audit `before` snapshots and the restore capture, writes the change set (trip
  fields and a forced `updated_at`, positionally written stop-time values,
  wholesale frequency replacement, inserts and deletes), and records one `"trip"`
  audit log per affected trip under one shared operation id. The result carries the
  changed, created and deleted trip UUIDs, the removed transfer count, the applied
  change set, and the restore payload an undo re-submits (nil for
  `:convert_frequency` and `:restore`).
  """
  @spec apply_trip_change(String.t(), TripChanges.command(), fence(), AuditContext.t()) ::
          {:ok, apply_result()} | {:error, apply_error()}
  def apply_trip_change(route_id, command, fence, %AuditContext{} = audit_context) do
    case TripChanges.validate(command) do
      {:ok, command} ->
        run_write(fn -> do_apply_trip_change(route_id, command, fence, audit_context) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_trip_change(_route_id, _command, _fence, _audit_context),
    do: {:error, :invalid_input}

  @doc """
  Restores one executed command's captured rows in a single write transaction (R10).

  `payload` is the exact capture a successful `apply_trip_change/4` returned. The
  transaction re-reads the payload's trip identities under the §4.4 lock order
  (the same locks the original command took, plus the blocking advisory lock when
  a captured `block_id` differs from the locked row), plans the payload through
  `TripChanges.Restore` and fences: every payload trip's locked `updated_at` must
  equal its captured `written_updated_at`, and no transfer may name a trip the
  restore deletes. A trip that changed is
  `{:error, {:not_restorable, :changed, ids}}`; a transfer naming a created trip
  is `{:error, {:not_restorable, :transfer_names_created_trip, ids}}`; both write
  nothing.

  Otherwise the updated trips' captured fields, stop-time values and frequency
  rows are put back, the created trips with their stop times, frequencies and
  naming transfers are deleted, and one `"trip"` audit log per affected trip is
  recorded under one shared operation id with `undoes` set to the payload's
  original operation id. Returns the restore's operation id, the restored trip
  UUIDs and the deleted trip UUIDs.
  """
  @spec restore_trips(String.t(), TripChanges.restore_payload(), AuditContext.t()) ::
          {:ok, restore_result()} | {:error, restore_error()}
  def restore_trips(route_id, payload, %AuditContext{} = audit_context) do
    case TripChanges.validate({:restore, payload}) do
      {:ok, {:restore, payload}} ->
        run_write(fn -> do_restore_trips(route_id, payload, audit_context) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def restore_trips(_route_id, _payload, _audit_context), do: {:error, :invalid_input}

  defp do_apply_trip_change(route_id, command, fence, audit_context) do
    Authorization.lock_editor!(audit_context)
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    # The pre-lock read chooses the lock set (services, route, patterns, trips);
    # every identity is re-read under the locks below, which is the authoritative
    # state the fence and the planner consume.
    route = published_route!(organization_id, version_id, route_id)
    identities = change_identities!(organization_id, version_id, route, command)

    patterns =
      change_patterns!(
        organization_id,
        version_id,
        route,
        change_pattern_ids!(organization_id, version_id, route, command, identities)
      )

    lock_change_scope!(route_id, command, identities, patterns, audit_context)

    state = load_change_state(route, command, audit_context)

    case TripChanges.plan(command, state) do
      {:ok, change_set} ->
        review = change_review(command, state, change_set)

        with :ok <- check_fence!(command, fence, state, review),
             :ok <- refuse_errors!(change_set) do
          apply_change_set(route, command, state, change_set, audit_context)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp do_restore_trips(route_id, payload, audit_context) do
    Authorization.lock_editor!(audit_context)
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    command = {:restore, payload}

    # The same pre-lock read and §4.4 lock order as `apply_trip_change/4`: a
    # restore locks the trips it puts back and the created trips it removes.
    route = published_route!(organization_id, version_id, route_id)
    identities = change_identities!(organization_id, version_id, route, command)

    patterns =
      change_patterns!(
        organization_id,
        version_id,
        route,
        change_pattern_ids!(organization_id, version_id, route, command, identities)
      )

    lock_change_scope!(route_id, command, identities, patterns, audit_context)

    state = load_change_state(route, command, audit_context)

    case TripChanges.plan(command, state) do
      {:ok, change_set} ->
        case restore_fence!(payload, change_set, state) do
          :ok -> apply_restore(route, payload, state, change_set, audit_context)
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # The apply machinery does the write; a restore adds the `undoes` audit key and
  # returns its own result shape instead of the full apply result.
  defp apply_restore(route, payload, state, change_set, audit_context) do
    result =
      apply_change_set(route, {:restore, payload}, state, change_set, audit_context, %{
        undoes: attr(payload, :operation_id)
      })

    %{
      operation_id: result.operation_id,
      restored_trip_ids: result.changed_trip_ids,
      deleted_trip_ids: result.deleted_trip_ids
    }
  end

  # INV-1 lock order: calendar reference locks for every involved service in
  # sorted order, the route, the affected patterns by ascending UUID, the blocking
  # advisory lock when a block can change, then the trips by ascending UUID.
  defp lock_change_scope!(route_id, command, identities, patterns, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    identities
    |> change_services(command)
    |> Enum.each(&Calendars.lock_service_for_reference!(organization_id, version_id, &1))

    route = RoutePatterns.lock_published_route!(audit_context, route_id)

    patterns
    |> Map.values()
    |> Enum.map(& &1.pattern)
    |> Enum.sort_by(& &1.id)
    |> Enum.each(&RoutePatterns.lock_pattern!(route, &1.id))

    if change_locks_blocking?(command, identities), do: Blocking.lock_blocking!(version_id)

    lock_change_trips!(organization_id, version_id, route.route_id, Enum.map(identities, & &1.id))
    :ok
  end

  defp change_services(identities, command) do
    (Enum.map(identities, & &1.service_id) ++
       [change_target_service(command) | restore_services(command)])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A restore writes each captured `service_id` back, so every one of them must
  # still exist; a deleted calendar rolls back `:calendar_not_found` under its lock.
  defp restore_services({:restore, payload}) do
    payload
    |> attr(:trips)
    |> List.wrap()
    |> Enum.map(&attr(attr(&1, :fields), :service_id))
  end

  defp restore_services(_command), do: []

  # A calendar move can clear a block and a restore can put a captured block back,
  # so those two commands join the block guarantee; every other command leaves
  # `block_id` alone and must not take the advisory lock.
  defp change_locks_blocking?({:move_calendar, _trip_ids, _service_id}, _identities), do: true

  defp change_locks_blocking?({:restore, payload}, identities) do
    captured = payload_block_ids(payload)

    Enum.any?(identities, fn identity ->
      Map.get(captured, identity.id) != identity.block_id
    end)
  end

  defp change_locks_blocking?(_command, _identities), do: false

  defp payload_block_ids(payload) do
    payload
    |> attr(:trips)
    |> List.wrap()
    |> Map.new(fn trip -> {attr(trip, :id), attr(attr(trip, :fields), :block_id)} end)
  end

  defp lock_change_trips!(_organization_id, _version_id, _route_id, []), do: :ok

  defp lock_change_trips!(organization_id, version_id, route_id, trip_uuids) do
    locked =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_id == ^route_id and t.id in ^trip_uuids,
        order_by: [asc: t.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    if length(locked) != length(trip_uuids), do: Repo.rollback(:not_found)
    :ok
  end

  # §4.4 fence table: a reviewed command compares the recomputed fingerprint, a
  # direct command compares every affected trip's `updated_at`, and adding
  # frequency service has no prior row to fence.
  defp check_fence!(command, fence, state, review) do
    case {fence_rule(command), fence} do
      {:reviewed, {:reviewed, fingerprint}} when is_binary(fingerprint) ->
        reviewed_fence(fingerprint, review)

      {:reviewed_or_expected, {:reviewed, fingerprint}} when is_binary(fingerprint) ->
        reviewed_fence(fingerprint, review)

      {:expected, {:expected, expected}} when is_map(expected) ->
        expected_fence(command, expected, state)

      {:reviewed_or_expected, {:expected, expected}} when is_map(expected) ->
        expected_fence(command, expected, state)

      {:none, :none} ->
        :ok

      _pairing ->
        {:error, :fence_required}
    end
  end

  defp reviewed_fence(fingerprint, review) do
    if fingerprint == review.fingerprint, do: :ok, else: {:error, {:stale_review, review}}
  end

  defp fence_rule({:shift, _trip_ids, _delta, _from_position}), do: :reviewed_or_expected
  defp fence_rule({:edit_stop, _trip_id, _params}), do: :expected
  defp fence_rule({:update_frequency, _trip_id, _params}), do: :expected
  defp fence_rule({:set_timing, _trip_ids, _timing_id}), do: :reviewed
  defp fence_rule({:move_calendar, _trip_ids, _service_id}), do: :reviewed
  defp fence_rule({:copy, _trip_ids, _service_id, _offset, _skip_existing}), do: :reviewed
  defp fence_rule({:convert_frequency, _trip_id}), do: :reviewed
  defp fence_rule({:add_frequency, _attrs}), do: :none
  defp fence_rule(_command), do: :unsupported

  defp expected_fence(command, expected, state) do
    if command
       |> change_trip_ids()
       |> Enum.all?(&expected_trip?(&1, expected, state)) do
      :ok
    else
      {:error, :stale}
    end
  end

  defp expected_trip?(trip_id, expected, state) do
    case Map.get(state.trips, trip_id) do
      %{trip: trip} -> expected_match?(trip.updated_at, Map.get(expected, trip_id))
      _missing -> false
    end
  end

  defp expected_match?(updated_at, expected) do
    case normalize_timestamp(expected) do
      %DateTime{} = value -> DateTime.compare(updated_at, value) == :eq
      nil -> false
    end
  end

  # R10's restore fence: every payload trip must still carry the `updated_at` the
  # original write produced, every timing link the restore puts back must still
  # hold, and no transfer may name a trip the restore deletes. The changed check
  # runs first; both refusals list the UUIDs and write nothing.
  defp restore_fence!(payload, change_set, state) do
    case Enum.uniq(restore_changed_ids(payload, state) ++ relink_changed_ids(change_set, state)) do
      [] -> restore_transfer_fence!(payload, state)
      ids -> {:error, {:not_restorable, :changed, Enum.sort(ids)}}
    end
  end

  # Editing or deleting a timing leaves the trips no longer linked to it alone, so
  # their `updated_at` cannot fence it. A restore that links a trip back to another
  # timing requires that timing to exist and still materialize the captured
  # clocks, pickup and drop-off types (blank read as 0) and stop headsigns; only
  # timepoint may differ, as it does for paste links.
  defp relink_changed_ids(change_set, state) do
    change_set.updates
    |> Enum.reject(&relink_current?(&1, state))
    |> Enum.map(& &1.trip_id)
  end

  defp relink_current?(%{trip_id: trip_id, fields: fields, stop_times: rows}, state) do
    timing_id = Map.get(fields, :timed_pattern_id)

    case Map.get(state.trips, trip_id) do
      %{trip: %{timed_pattern_id: current} = trip}
      when not is_nil(timing_id) and current != timing_id and is_list(rows) ->
        timing_rows_current?(Map.get(state.patterns, trip.route_pattern_id), timing_id, rows)

      _unlinked_or_unchanged ->
        true
    end
  end

  defp timing_rows_current?(%{} = pattern, timing_id, rows) do
    case Enum.find(pattern.timings, &(&1.timing.id == timing_id)) do
      %{rows: timing_rows} ->
        TripChanges.timing_rows_match?(rows, pattern.occurrences, timing_rows)

      nil ->
        false
    end
  end

  defp timing_rows_current?(nil, _timing_id, _rows), do: false

  defp restore_changed_ids(payload, state) do
    payload
    |> restore_entries()
    |> Enum.reject(fn {id, written_updated_at} ->
      restore_unchanged?(id, written_updated_at, state)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Every updated and created entry carries `written_updated_at`: the timestamp
  # the original write forced on the trip, which this restore's fence compares.
  defp restore_entries(payload) do
    (List.wrap(attr(payload, :trips)) ++ List.wrap(attr(payload, :created)))
    |> Enum.map(&{attr(&1, :id), attr(&1, :written_updated_at)})
  end

  defp restore_unchanged?(trip_id, written_updated_at, state) do
    with %{trip: trip} <- Map.get(state.trips, trip_id),
         %DateTime{} = written <- normalize_timestamp(written_updated_at) do
      DateTime.compare(trip.updated_at, written) == :eq
    else
      _missing_or_unreadable -> false
    end
  end

  defp restore_transfer_fence!(payload, state) do
    counts = attr(state, :transfer_counts) || %{}

    ids =
      payload
      |> attr(:created)
      |> List.wrap()
      |> Enum.filter(fn trip -> Map.get(counts, attr(trip, :trip_id), 0) != 0 end)
      |> Enum.map(&attr(&1, :id))
      |> Enum.uniq()
      |> Enum.sort()

    if ids == [], do: :ok, else: {:error, {:not_restorable, :transfer_names_created_trip, ids}}
  end

  defp refuse_errors!(change_set) do
    case Enum.filter(change_set.consequences, &match?({:error, _}, &1)) do
      [] -> :ok
      errors -> {:error, {:refused, errors}}
    end
  end

  defp apply_change_set(route, command, state, change_set, audit_context, audit_extra \\ %{}) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    now = DateTime.utc_now()
    operation_id = Ecto.UUID.generate()

    updates = Enum.map(change_set.updates, &change_update_entry(&1, state))
    deletes = Enum.map(change_set.deletes, &change_delete_entry(&1, state))

    # R11: the audit `before` snapshots and the restore capture are read before
    # any row changes; a later restore fences on the `updated_at` this write makes.
    restore = capture_restore(command, route, updates, operation_id, audit_context, now)

    before =
      trip_audit_snapshots(
        organization_id,
        version_id,
        change_trip_structs(updates, deletes)
      )

    updated =
      Enum.map(updates, fn {update, entry} ->
        {entry.trip, apply_change_update!(update, entry, now)}
      end)

    inserted = Enum.map(change_set.inserts, &apply_change_insert!(&1, audit_context))
    transfers_removed = apply_change_deletes(organization_id, version_id, deletes)
    restore = put_restore_created(restore, inserted)

    after_snapshots =
      trip_audit_snapshots(
        organization_id,
        version_id,
        Enum.map(updated, &elem(&1, 1)) ++ inserted
      )

    affected_ids = change_affected_ids(updates, inserted, deletes)

    audit_change_set!(
      audit_context,
      %{operation_id: operation_id, affected_ids: affected_ids, extra: audit_extra},
      before,
      after_snapshots,
      %{updated: updated, inserted: inserted, deletes: deletes}
    )

    %{
      operation_id: operation_id,
      changed_trip_ids: Enum.map(updated, fn {_before, after_trip} -> after_trip.id end),
      created_trip_ids: Enum.map(inserted, & &1.id),
      deleted_trip_ids: Enum.map(deletes, & &1.trip.id),
      transfers_removed: transfers_removed,
      change_set: change_set,
      restore: restore
    }
  end

  defp change_update_entry(update, state) do
    case Map.get(state.trips, update.trip_id) do
      %{trip: _trip} = entry -> {update, entry}
      _missing -> Repo.rollback(:not_found)
    end
  end

  defp change_delete_entry(trip_id, state) do
    case Map.get(state.trips, trip_id) do
      %{trip: _trip} = entry -> entry
      _missing -> Repo.rollback(:not_found)
    end
  end

  defp change_trip_structs(updates, deletes) do
    Enum.map(updates, fn {_update, entry} -> entry.trip end) ++
      Enum.map(deletes, & &1.trip)
  end

  # An update writes the planned trip fields, forces a fresh `updated_at` even
  # when only the stop times moved (FH-15, INV-2), then writes the listed
  # stop-time values positionally and replaces the frequency rows when given.
  defp apply_change_update!(update, entry, now) do
    updated =
      entry.trip
      |> Ecto.Changeset.change(update.fields)
      |> Ecto.Changeset.force_change(:updated_at, now)
      |> update_trip_row!()

    write_change_stop_times!(updated, update.stop_times)
    write_change_frequencies!(updated, update.frequencies)
    updated
  end

  defp write_change_stop_times!(_trip, :unchanged), do: :ok

  defp write_change_stop_times!(trip, values) when is_list(values) do
    rows =
      from(st in StopTime,
        where:
          st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id and st.trip_id == ^trip.trip_id,
        order_by: [asc: st.stop_sequence, asc: st.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    if length(rows) != length(values), do: Repo.rollback(:trip_stop_times_mismatch)

    rows
    |> Enum.zip(Enum.sort_by(values, & &1.position))
    |> Enum.each(fn {row, values} ->
      attrs =
        [:arrival_time, :departure_time, :timepoint, :pickup_type, :drop_off_type, :stop_headsign]
        |> Enum.filter(&Map.has_key?(values, &1))
        |> Map.new(&{&1, Map.get(values, &1)})

      row
      |> Ecto.Changeset.change(attrs)
      |> update_stop_time_row!()
    end)
  end

  defp write_change_frequencies!(_trip, :unchanged), do: :ok

  defp write_change_frequencies!(trip, frequencies) when is_list(frequencies) do
    delete_children!(:frequencies, trip.organization_id, trip.gtfs_version_id, [trip.trip_id])
    insert_change_frequencies!(trip, frequencies)
  end

  # A created trip never carries a block (R7, FH-23): the engine owns the scope
  # columns and drops any `block_id` a change set submits.
  defp apply_change_insert!(insert, audit_context) do
    attrs =
      insert.attrs
      |> Map.drop([:block_id])
      |> Map.put(:organization_id, audit_context.organization_id)
      |> Map.put(:gtfs_version_id, audit_context.gtfs_version_id)

    trip = insert_trip!(attrs)

    insert_change_stop_times!(trip, List.wrap(insert.stop_times))
    insert_change_frequencies!(trip, List.wrap(insert.frequencies))
    trip
  end

  defp insert_change_stop_times!(trip, rows) do
    now = DateTime.utc_now()

    rows =
      Enum.map(rows, fn row ->
        %{
          trip_id: trip.trip_id,
          stop_id: attr(row, :stop_id),
          stop_sequence: attr(row, :stop_sequence),
          arrival_time: attr(row, :arrival_time),
          departure_time: attr(row, :departure_time),
          stop_headsign: attr(row, :stop_headsign),
          pickup_type: attr(row, :pickup_type),
          drop_off_type: attr(row, :drop_off_type),
          continuous_pickup: attr(row, :continuous_pickup),
          continuous_drop_off: attr(row, :continuous_drop_off),
          shape_dist_traveled: attr(row, :shape_dist_traveled),
          timepoint: attr(row, :timepoint),
          organization_id: trip.organization_id,
          gtfs_version_id: trip.gtfs_version_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_stop_times!(rows)
  end

  defp insert_change_frequencies!(trip, frequencies) do
    now = DateTime.utc_now()

    rows =
      Enum.map(frequencies, fn frequency ->
        %{
          trip_id: trip.trip_id,
          start_time: frequency_time(frequency, :start_time, :start_secs),
          end_time: frequency_time(frequency, :end_time, :end_secs),
          headway_secs: attr(frequency, :headway_secs),
          exact_times: attr(frequency, :exact_times),
          organization_id: trip.organization_id,
          gtfs_version_id: trip.gtfs_version_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [], do: Repo.insert_all(Frequency, rows)
    :ok
  end

  # The stored-row frequency shape carries clocks; a `FrequencyWindows.window()`
  # carries seconds. One accepts both without a second converter.
  defp frequency_time(frequency, time_key, secs_key) do
    case attr(frequency, time_key) do
      time when is_binary(time) ->
        time

      _missing ->
        case attr(frequency, secs_key) do
          secs when is_integer(secs) -> GtfsTime.format(secs)
          _absent -> nil
        end
    end
  end

  defp apply_change_deletes(_organization_id, _version_id, []), do: 0

  defp apply_change_deletes(organization_id, version_id, deletes) do
    trips = Enum.map(deletes, & &1.trip)
    natural_ids = Enum.map(trips, & &1.trip_id)

    delete_children!(:stop_times, organization_id, version_id, natural_ids)
    delete_children!(:frequencies, organization_id, version_id, natural_ids)

    {transfers, nil} =
      Repo.delete_all(trip_transfers_query(organization_id, version_id, natural_ids))

    delete_trip_rows!(organization_id, version_id, Enum.map(trips, & &1.id))
    transfers
  end

  # The restore payload captures what an undo puts back (R10): the changed trip's
  # R10 fields, its stop-time rows and its frequency rows, plus the `updated_at`
  # this write produces. `:convert_frequency` and `:restore` are not undoable.
  defp capture_restore(command, route, updates, operation_id, audit_context, now) do
    if undoable_command?(command) do
      %{
        operation_id: operation_id,
        organization_id: audit_context.organization_id,
        gtfs_version_id: audit_context.gtfs_version_id,
        route_id: route.route_id,
        trips: Enum.map(updates, fn {_update, entry} -> restore_trip(entry, now) end),
        created: []
      }
    end
  end

  defp undoable_command?(command) when is_tuple(command) and tuple_size(command) > 0,
    do: elem(command, 0) not in [:convert_frequency, :restore]

  defp undoable_command?(_command), do: false

  defp restore_trip(entry, written_updated_at) do
    %{
      id: entry.trip.id,
      written_updated_at: written_updated_at,
      fields:
        Map.take(entry.trip, [
          :service_id,
          :timed_pattern_id,
          :pattern_derivation_state,
          :pattern_derivation_reason,
          :block_id
        ]),
      stop_times: Enum.map(entry.stop_times, &restore_stop_time/1),
      frequencies: Enum.map(entry.frequencies, &restore_frequency/1)
    }
  end

  defp restore_stop_time(stop_time) do
    %{
      id: attr(stop_time, :id),
      arrival_time: attr(stop_time, :arrival_time),
      departure_time: attr(stop_time, :departure_time),
      timepoint: attr(stop_time, :timepoint),
      pickup_type: attr(stop_time, :pickup_type),
      drop_off_type: attr(stop_time, :drop_off_type),
      stop_headsign: attr(stop_time, :stop_headsign)
    }
  end

  defp restore_frequency(frequency) do
    %{
      start_time: attr(frequency, :start_time),
      end_time: attr(frequency, :end_time),
      headway_secs: attr(frequency, :headway_secs),
      exact_times: attr(frequency, :exact_times)
    }
  end

  defp put_restore_created(nil, _inserted), do: nil

  defp put_restore_created(restore, inserted) do
    Map.put(restore, :created, Enum.map(inserted, &restore_created_trip/1))
  end

  defp restore_created_trip(trip) do
    %{id: trip.id, trip_id: trip.trip_id, written_updated_at: trip.updated_at}
  end

  defp change_affected_ids(updates, inserted, deletes) do
    (Enum.map(updates, fn {_update, entry} -> entry.trip.id end) ++
       Enum.map(inserted, & &1.id) ++ Enum.map(deletes, & &1.trip.id))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # R11: one `"trip"` log per affected trip, all sharing one operation id and the
  # command's complete affected trip list. An audit failure rolls the whole
  # transaction back (INV-3).
  defp audit_change_set!(audit_context, audit, before, after_snapshots, written) do
    Enum.each(written.updated, fn {before_trip, after_trip} ->
      audit_trip!(
        audit_context,
        after_trip,
        "updated",
        Map.get(before, before_trip.id),
        Map.get(after_snapshots, after_trip.id),
        audit.operation_id,
        audit.affected_ids,
        audit.extra
      )
    end)

    Enum.each(written.inserted, fn trip ->
      audit_trip!(
        audit_context,
        trip,
        "created",
        nil,
        Map.get(after_snapshots, trip.id),
        audit.operation_id,
        audit.affected_ids,
        audit.extra
      )
    end)

    Enum.each(written.deletes, fn entry ->
      audit_trip!(
        audit_context,
        entry.trip,
        "deleted",
        Map.get(before, entry.trip.id),
        nil,
        audit.operation_id,
        audit.affected_ids,
        audit.extra
      )
    end)

    :ok
  end

  defp update_stop_time_row!(changeset) do
    case Repo.update(changeset) do
      {:ok, stop_time} -> stop_time
      {:error, changeset} -> Repo.rollback(changeset)
    end
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
  Locks every trip of one locked route `FOR UPDATE` in stable UUID order.

  Call only inside `Repo.transaction/1`, after the version and route locks.
  This is the R5 route-cascade trip lock: the whole sorted set is taken in one
  ordered statement so opposing schedule/lifecycle writers deadlock-free.
  """
  @spec lock_route_trips!(Route.t()) :: [Trip.t()]
  def lock_route_trips!(%Route{} = route) do
    from(t in Trip,
      where:
        t.organization_id == ^route.organization_id and
          t.gtfs_version_id == ^route.gtfs_version_id and t.route_id == ^route.route_id,
      order_by: [asc: t.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  @doc """
  Removes one route's trips and trip-owned rows for the reviewed route cascade
  (R5), auditing each removed trip with the existing bulk-delete semantics
  under one shared operation id.

  Call only inside the reviewed route-deletion transaction, after the route
  and its sorted trips are locked and the deletion review has been recomputed
  and accepted. `trips` are the locked scoped trips in UUID order; every trip
  is removed regardless of calendar or derivation state, including custom,
  pending and unpatterned trips. Stop times and frequencies are removed by the
  removed natural `trip_id`s; transfers are left to the caller's broader route
  cascade. Returns the removed row counts keyed like the review categories so
  the caller can check them against the review.
  """
  @spec cascade_delete_route_trips!([Trip.t()], Ecto.UUID.t(), AuditContext.t()) :: map()
  def cascade_delete_route_trips!(trips, operation_id, %AuditContext{} = audit_context)
      when is_list(trips) and is_binary(operation_id) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    snapshots = Enum.map(trips, &{&1, deleted_trip_snapshot(&1)})
    natural_ids = Enum.map(trips, & &1.trip_id)
    trip_uuids = Enum.map(trips, & &1.id)

    stop_times = delete_children!(:stop_times, organization_id, version_id, natural_ids)
    frequencies = delete_children!(:frequencies, organization_id, version_id, natural_ids)
    count = delete_trip_rows!(organization_id, version_id, trip_uuids)

    Enum.each(snapshots, fn {trip, before} ->
      audit_trip!(audit_context, trip, "deleted", before, nil, operation_id, trip_uuids)
    end)

    %{trips: count, stop_times: stop_times, frequencies: frequencies}
  end

  @doc """
  Writes the reviewed trip headsign changes and audits each written trip.

  This is the only path that writes `trip_headsign` for headsign propagation
  (CR-2). `changes` are `%{id, trip_id, from, to}` maps: `id` is the trip UUID,
  `from` the normalized value the review showed and `to` the normalized target.
  The changed trips are locked `FOR UPDATE` scoped to the audit context's
  organization and version, and an id outside that scope rolls back
  `:invalid_selection`. Each trip is fenced on its reviewed value: any trip
  whose stored `trip_headsign` no longer normalizes to `change.from` rolls back
  `{:stale, [%{id, trip_id, reviewed, current}]}` and nothing is written. A
  change whose `from` and `to` agree is a no-op and writes neither trip row nor
  audit log. Every other trip gets `trip_headsign: change.to` and a fresh
  `updated_at` through one `update_all` per distinct target, and one `"trip"`
  "updated" ChangeLog row with an `edit_snapshot` before and after, the given
  `operation_id` and all written trip UUIDs. Returns the written changes in
  input order.

  Call only inside an editor transaction that already locked current membership,
  the published route and pattern. The production callers are
  `RoutePatterns.write_selection!/2` and `undo_headsign_write!/3`, reached from
  its early-authorized public writers. This transaction guard and the audit
  context are not permission checks. The function opens
  no transaction of its own: every rollback, including an audit failure, rolls
  back the caller's transaction, so the trip writes and their audit rows commit
  together or not at all.
  """
  @spec write_trip_headsigns!([change()], Ecto.UUID.t(), AuditContext.t()) :: [change()]
  def write_trip_headsigns!(changes, operation_id, %AuditContext{} = audit_context)
      when is_list(changes) and is_binary(operation_id) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "write_trip_headsigns! requires an authorized transaction")

    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    changes = Enum.uniq_by(changes, & &1.id)

    trips = lock_headsign_trips!(organization_id, version_id, changes)
    stale = stale_headsign_changes(trips, changes)

    if stale != [], do: Repo.rollback({:stale, stale})

    # Both sides are already normalized review values, so the no-op equality is
    # the `Headsigns` rule like every other headsign comparison (CR-1).
    written = Enum.reject(changes, fn change -> Headsigns.follows?(change.to, change.from) end)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    written
    |> Enum.group_by(& &1.to)
    |> Enum.each(fn {to, group} ->
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.id in ^Enum.map(group, & &1.id)
      )
      |> Repo.update_all(set: [trip_headsign: to, updated_at: now])
    end)

    audit_written_headsigns!(audit_context, trips, written, operation_id, now)
    written
  end

  @doc """
  Loads one route's Schedules read for `organization_id`/`version_id`.

  `filters` accepts `:service_id`, `:direction_id` (or `:direction`), `:pattern`
  (a route pattern row UUID or `:all`), `:route_pattern_id` (a feed route pattern
  ID, for callers that hold one instead of a row) and `:stops` (`:timepoints` or
  `:all`). Each is canonicalized against the loaded scope: an unknown calendar
  falls back to the one with the most trips on this route, an unknown direction
  to one with trips, an unknown pattern, or both pattern selectors together, to
  `:all` and any stops value other than `:all` to `:timepoints`. A pattern value
  is never read as the other kind, whatever it looks like. String keys are
  accepted so URL params can be passed through.

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

  @type paste_timing_row :: %{
          arrival_offset: integer(),
          departure_offset: integer(),
          timepoint: 0 | 1 | nil,
          pickup_type: integer() | nil,
          drop_off_type: integer() | nil,
          stop_headsign: String.t() | nil
        }

  @type paste_pattern :: %{
          id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          name: String.t(),
          headsign: String.t() | nil,
          occurrences: [%{id: Ecto.UUID.t(), stop_id: String.t(), position: pos_integer()}],
          timings: [
            %{
              id: Ecto.UUID.t(),
              name: String.t(),
              headsign: String.t() | nil,
              rows: [paste_timing_row()],
              trip_count: non_neg_integer()
            }
          ]
        }

  @type paste_trip :: %{
          id: Ecto.UUID.t(),
          trip_id: String.t(),
          direction_id: 0 | 1 | nil,
          route_pattern_id: String.t() | nil,
          timed_pattern_id: Ecto.UUID.t() | nil,
          pattern_derivation_state: String.t() | nil,
          start_secs: non_neg_integer() | nil,
          end_secs: non_neg_integer() | nil,
          span: %{start_secs: non_neg_integer(), end_secs: non_neg_integer()} | nil,
          spans: [map()],
          frequencies: [map()],
          frequency_rows: [map()],
          stops_differ?: boolean(),
          trip_short_name: String.t() | nil,
          block_id: String.t() | nil,
          trip_headsign: String.t() | nil,
          updated_at: DateTime.t() | nil,
          transfer_ids: [String.t()],
          in_seat_transfer: boolean()
        }

  @type paste_scope :: %{
          route: Route.t(),
          calendar:
            %{
              service_id: String.t(),
              name: String.t() | nil,
              kind: Calendars.kind(),
              first_active_date: Date.t() | nil,
              last_active_date: Date.t() | nil,
              trip_count: non_neg_integer()
            }
            | nil,
          direction_id: 0 | 1,
          pattern_id: Ecto.UUID.t() | nil,
          patterns: [paste_pattern()],
          stops: %{optional(String.t()) => %{stop_code: String.t() | nil, stop_name: String.t()}},
          trips: [paste_trip()],
          other_calendars?: boolean()
        }

  @type paste_apply_result :: %{
          added: non_neg_integer(),
          changed: non_neg_integer(),
          removed: non_neg_integer(),
          transfers_removed: non_neg_integer(),
          new_timings: [String.t()],
          vehicles_before: non_neg_integer(),
          vehicles_after: non_neg_integer(),
          trip_ids: [String.t()]
        }

  @type paste_apply_error ::
          :stale_plan
          | :blocking_issues
          | :refused
          | :forbidden
          | :not_found
          | :busy
          | ServiceMix.error()
          | Ecto.Changeset.t()

  @doc """
  Loads the paste scope for one route, calendar and direction.

  `params` accepts `:service_id`, `:direction_id` (or `:direction`),
  `:pattern_id` (or `:pattern`, a route pattern row UUID) and `:route_pattern_id`
  (a feed route pattern ID). Each is resolved like `load_route_schedule/4`: an
  unknown calendar falls back to the one with the most trips on this route,
  an unknown direction to one with trips, and an absent pattern to the
  direction's most-used pattern (most trips on the resolved calendar, ties
  keep pattern order). A requested pattern that is not one of the direction's
  patterns, or both pattern selectors together, is `{:error, :not_found}`; a
  pattern value is never read as the other kind. String keys are accepted so
  URL params can be passed through.

  The whole scope loads in one read transaction that holds the version row
  `FOR SHARE` through `Calendars.list_calendars/3`, exactly like the Schedules
  read, so a cooperating calendar write cannot interleave with it. Returns
  `{:error, :not_found}` for a foreign, invalid or unpublished scope.

  The scope is the plain map `TimetablePaste.review/2` and `Plan.build/6`
  consume: `route`, `calendar` (`service_id`, `name`, `kind`, first/last active
  dates, this route's trip count), `direction_id`, `pattern_id` (chosen),
  `patterns` of the direction (each with `occurrences` in position order and
  `timings` whose `rows` align positionally with the occurrences and carry the
  calendar trip count), `stops` (`stop_id => %{stop_code, stop_name}`), `trips`
  (every trip of the route on the calendar, both directions, with `start_secs`,
  `span`/`spans` from `trip_bounds/1`/`spans_for/1`, frequency rows,
  `stops_differ?` marked the way `Timetable.build/5` marks it, transfer ids
  naming the trip and the in-seat transfer flag), and `other_calendars?` for
  display (whether the route also runs on another calendar).
  """
  @spec load_paste_scope(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, paste_scope()} | {:error, error()}
  def load_paste_scope(organization_id, version_id, route_id, params, _opts \\ []) do
    case Repo.transaction(fn ->
           read_paste_scope(organization_id, version_id, route_id, params)
         end) do
      {:ok, scope} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads the block rows a paste review warns about.

  Delegates to `Blocking.Queries.trip_rows/3` with a `{:blocks, ids,
  [service_id]}` filter, so the rows are the version's trips on those blocks
  and the calendar — other routes included, because a block overlap is real
  whatever route runs the other trip. `block_ids_or_params` is a plain list of
  block IDs (every service of the version), a `{ids, service_id}` tuple, or a
  `%{block_ids: ids, service_id: service_id}` map; an empty ID list reads
  nothing and returns `[]`.
  """
  @spec load_block_rows(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          [String.t()] | {[String.t()], String.t()} | map()
        ) :: [Blocking.Checks.trip_row()]
  def load_block_rows(organization_id, version_id, _route_id, block_ids)
      when is_list(block_ids) do
    if Enum.all?(block_ids, &(&1 in [nil, ""])) do
      []
    else
      Blocking.Queries.trip_rows(organization_id, version_id, {:blocks, block_ids})
    end
  end

  def load_block_rows(organization_id, version_id, route_id, {block_ids, service_id}) do
    load_block_rows(organization_id, version_id, route_id, %{
      block_ids: block_ids,
      service_id: service_id
    })
  end

  def load_block_rows(organization_id, version_id, _route_id, params) when is_map(params) do
    block_ids = filter_value(params, :block_ids) || []
    service_id = filter_value(params, :service_id)

    if Enum.all?(List.wrap(block_ids), &(&1 in [nil, ""])) do
      []
    else
      Blocking.Queries.trip_rows(
        organization_id,
        version_id,
        {:blocks, List.wrap(block_ids), List.wrap(service_id)}
      )
    end
  end

  @doc """
  Applies a reviewed pasted timetable to one route, calendar and direction.

  `scope_params` carries the prepared `%{service_id:, direction_id:, pattern_id:}`
  (all concrete at apply time; string keys accepted). `input` is the
  `TimetablePaste.review/2` input the fingerprint was prepared from, and
  `fingerprint` is that review's fingerprint.

  Runs through `run_write/3` (SERIALIZABLE, 3 attempts, a 60 s transaction
  budget; retries exhausted →
  `:busy`). Inside, in the Schedules lock order:
  `Calendars.lock_service_for_reference!/3` → `lock_published_route!/2` →
  `lock_pattern!/2` for every pattern of the route in the direction, ascending
  UUID → `Blocking.lock_blocking!/1` →
  trips of the route, calendar and direction `FOR UPDATE` ascending UUID.
  The scope then reloads from locked state (`read_paste_scope/4`) and the
  review rebuilds from it (`TimetablePaste.review/2`): a fingerprint mismatch
  — including an unused-timing edit, a pattern change, an opposite-direction
  trip edit or a new transfer naming a removed trip — rolls back `:stale_plan`
  with nothing written. A `plan.refusal` rolls back `:refused`; any
  `:needs_decision` change (or a review with column issues and no plan) rolls
  back `:blocking_issues`. Adds that would newly mix listed trips and frequency
  service on a pattern roll back `{:mixed_service, details}` (R9).

  Writes share one `operation_id`. Removals go through `remove_locked_trips!/3`
  with one `'deleted'` audit per removed trip; pending timings are created via
  `RoutePatterns.create_pasted_timing!/6` before the `:change` trips that
  reference them, and each changed trip keeps its `trip_id` while its times
  are rematerialized (or its stop times re-inserted when its stop count
  differs) with one `'updated'` audit carrying the before/after
  `trip_snapshot/6`. Each `:add` then inserts one trip with an
  `TripChanges.allocate_trip_ids/5` natural ID, `linked` state and the plan's R13
  metadata, materializes its stop times (R9 timepoints 1/0) via
  `stop_time_rows/3` + `insert_stop_times!/1`, and audits 'created' — all
  under the same `operation_id`. `vehicles_before/after` come from the
  locked plan.

  A foreign, invalid or unpublished organization, version, route or calendar,
  and a pattern outside the direction, roll back to `{:error, :not_found}`;
  the apply never escapes the organization/version/route/direction (AC-23).
  An audit failure rolls back every row (AC-19).
  """
  @spec apply_paste(String.t(), map(), map(), String.t(), AuditContext.t()) ::
          {:ok, paste_apply_result()} | {:error, paste_apply_error()}
  def apply_paste(route_id, scope_params, input, fingerprint, %AuditContext{} = audit_context)
      when is_binary(route_id) and is_map(scope_params) and is_map(input) and
             is_binary(fingerprint) do
    case run_write(
           fn ->
             apply_paste_transaction(route_id, scope_params, input, fingerprint, audit_context)
           end,
           @write_attempts,
           timeout: @paste_transaction_timeout
         ) do
      # A forged or foreign calendar is a scope failure for this writer.
      {:error, :calendar_not_found} -> {:error, :not_found}
      result -> result
    end
  end

  def apply_paste(_route_id, _scope_params, _input, _fingerprint, _audit_context),
    do: {:error, :not_found}

  # -- Paste apply (step 16: locks, freshness and removals) --------------------

  # Any rollback below leaves nothing written (AC-19): the freshness, refusal
  # and blocking checks all run before the first removal, and the removals
  # share the transaction with their audits.
  defp apply_paste_transaction(route_id, scope_params, input, fingerprint, audit_context) do
    Authorization.lock_editor!(audit_context)
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    service_id = filter_value(scope_params, :service_id)
    direction = apply_direction!(scope_params)

    unless is_binary(service_id) and service_id != "", do: Repo.rollback(:not_found)

    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, service_id)
    route = RoutePatterns.lock_published_route!(audit_context, route_id)

    lock_direction_patterns!(route, direction)

    # Every paste joins spec 05's block guarantee (R16), whether or not its
    # input maps a Block column: deciding from the raw text would have to
    # repeat the column matcher's header rules, and the lock only contends
    # with a concurrent Blocks writer on this version.
    Blocking.lock_blocking!(version_id)

    locked_trips =
      lock_direction_trips!(organization_id, version_id, route.route_id, service_id, direction)

    scope = read_paste_scope(organization_id, version_id, route.route_id, scope_params)

    review =
      case TimetablePaste.review(scope, input) do
        {:ok, review} -> review
        {:error, _reason} -> Repo.rollback(:stale_plan)
      end

    if review.fingerprint != fingerprint, do: Repo.rollback(:stale_plan)
    verify_paste_plan!(review)
    check_paste_service_mix!(organization_id, version_id, route, review.plan, service_id)

    operation_id = Ecto.UUID.generate()

    remove_trips = apply_removal_trips!(review.plan, locked_trips)
    snapshots = trip_audit_snapshots(organization_id, version_id, remove_trips)
    result = remove_locked_trips!(audit_context, remove_trips, operation_id)
    audit_removed_trips!(audit_context, remove_trips, snapshots, operation_id)

    pasted_timings = create_paste_timings!(route, review.plan, audit_context, operation_id)

    {changed_count, changed_ids} =
      apply_paste_changes!(
        route,
        review.plan,
        locked_trips,
        pasted_timings,
        operation_id,
        audit_context
      )

    {added_count, added_ids} =
      apply_paste_adds!(
        route,
        review.plan,
        service_id,
        direction,
        pasted_timings,
        operation_id,
        audit_context
      )

    %{
      added: added_count,
      changed: changed_count,
      removed: result.trips,
      transfers_removed: result.transfers,
      new_timings: paste_timing_names(review.plan),
      vehicles_before: review.plan.vehicles.before,
      vehicles_after: review.plan.vehicles.after,
      trip_ids: paste_result_trip_ids(review.plan, changed_ids, added_ids)
    }
  end

  # The rebuilt review must carry a writable plan: no column issues, no
  # refusal and no open decisions (AC-19). Anything else rolls back without
  # writing, like the stale fingerprint above.
  defp verify_paste_plan!(review) do
    if is_nil(review.plan), do: Repo.rollback(:blocking_issues)
    if not is_nil(review.plan.refusal), do: Repo.rollback(:refused)
    if review.plan.counts.needs_decision > 0, do: Repo.rollback(:blocking_issues)
  end

  # R9 (INV-5): every add is a listed trip on the paste's calendar. Each pattern
  # receiving adds is checked with the plan's removals gone and the adds present,
  # under the direction's pattern locks. A :change keeps its trip's calendar,
  # pattern and frequency rows, so it cannot create a mix.
  defp check_paste_service_mix!(organization_id, version_id, route, plan, service_id) do
    removed =
      plan
      |> paste_changes()
      |> Enum.filter(&(attr(&1, :op) == :remove))
      |> MapSet.new(&attr(attr(&1, :trip), :id))

    pattern_ids =
      plan |> paste_adds() |> Enum.map(&attr(attr(&1, :row), :pattern_id)) |> Enum.uniq()

    service_dates =
      if pattern_ids != [],
        do: DayTypes.service_dates(load_calendars!(organization_id, version_id))

    Enum.each(pattern_ids, fn pattern_id ->
      pattern = lock_paste_pattern!(route, pattern_id)
      before_trips = pattern_trip_kinds(organization_id, version_id, route, pattern)

      after_trips =
        Enum.reject(before_trips, &MapSet.member?(removed, &1.id)) ++
          [%{service_id: service_id, frequency?: false}]

      case ServiceMix.check(before_trips, after_trips, service_dates) do
        :ok -> :ok
        {:error, {:mixed_service, details}} -> Repo.rollback({:mixed_service, details})
      end
    end)
  end

  # scope_params carries the prepared calendar and direction; at apply time both
  # are concrete. Anything else cannot be locked safely, so it is a foreign
  # scope (AC-23), not a default resolution.
  defp apply_direction!(params) do
    case filter_value(params, :direction_id) || filter_value(params, :direction) do
      0 -> 0
      1 -> 1
      "0" -> 0
      "1" -> 1
      _direction -> Repo.rollback(:not_found)
    end
  end

  # Every pattern of the route in the direction, locked FOR UPDATE in ascending
  # UUID so opposing schedule/lifecycle writers take them in the same order.
  defp lock_direction_patterns!(route, direction) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^route.organization_id and
          p.gtfs_version_id == ^route.gtfs_version_id and
          p.route_id == ^route.route_id and p.direction_id == ^direction,
      order_by: [asc: p.id],
      select: p.id
    )
    |> Repo.all()
    |> Enum.each(&RoutePatterns.lock_pattern!(route, &1))
  end

  # Every trip of the route on the calendar in the direction, FOR UPDATE in
  # ascending UUID — the same stable order delete_trips/4 uses.
  defp lock_direction_trips!(organization_id, version_id, route_id, service_id, direction) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id == ^route_id and t.service_id == ^service_id and
          t.direction_id == ^direction,
      order_by: [asc: t.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  # The :remove changes name locked scope trips by UUID. Filtering the locked
  # direction trips preserves ascending UUID order for remove_locked_trips!/3.
  # A removal naming no locked trip means the scope moved under the locks, so
  # the plan is stale rather than partially applied.
  defp apply_removal_trips!(plan, locked_trips) do
    removal_ids =
      plan.changes
      |> Enum.filter(&(&1.op == :remove))
      |> Enum.map(& &1.trip.id)
      |> MapSet.new()

    remove_trips = Enum.filter(locked_trips, &MapSet.member?(removal_ids, &1.id))

    if length(remove_trips) != MapSet.size(removal_ids), do: Repo.rollback(:stale_plan)

    remove_trips
  end

  defp audit_removed_trips!(_audit_context, [], _snapshots, _operation_id), do: :ok

  defp audit_removed_trips!(audit_context, remove_trips, snapshots, operation_id) do
    affected_trip_ids = Enum.map(remove_trips, & &1.id)

    Enum.each(remove_trips, fn trip ->
      audit_trip!(
        audit_context,
        trip,
        "deleted",
        Map.get(snapshots, trip.id),
        nil,
        operation_id,
        affected_trip_ids
      )
    end)
  end

  # Step 17: pending timings first (AC-19), in plan order, before the trip
  # updates that reference them. The returned map is keyed by
  # `{pattern_id, name}` because Plan names pending timings per pattern, so
  # two patterns in one paste can each mint `Pasted <stamp> · A`. New
  # timings carry no headsign, so trips keep falling through to the pattern
  # default exactly as Plan's effective-default rule assumes (a pending
  # timing has no headsign yet).
  defp create_paste_timings!(route, plan, audit_context, operation_id) do
    Enum.reduce(paste_timing_entries(plan), %{}, fn entry, by_key ->
      name = attr(entry, :name)
      key = {attr(entry, :pattern_id), name}

      if Map.has_key?(by_key, key) do
        by_key
      else
        pattern = lock_paste_pattern!(route, attr(entry, :pattern_id))

        timing =
          RoutePatterns.create_pasted_timing!(
            pattern,
            name,
            attr(entry, :timing_rows) || [],
            nil,
            audit_context,
            operation_id
          )

        Map.put(by_key, key, timing.id)
      end
    end)
  end

  defp lock_paste_pattern!(route, pattern_id) when is_binary(pattern_id),
    do: RoutePatterns.lock_pattern!(route, pattern_id)

  defp lock_paste_pattern!(_route, _pattern_id), do: Repo.rollback(:stale_plan)

  # Step 17: one rematerialized write per :change, in plan order. The trip
  # keeps its `trip_id`, transfers and every field outside the plan's
  # metadata (R13); only `timed_pattern_id`, the linkage, `trip_short_name`,
  # `block_id` and `trip_headsign` move, and an empty headsign never writes
  # (the stored value stays). Stop counts matching the pattern rewrite rows
  # in place via `rematerialize_trip!/4`; a differing count deletes and
  # re-inserts from `Materializer.materialize/3` (R9 timepoints included).
  # Each change audits 'updated' with the before/after `trip_snapshot/6`
  # under the shared operation id and bumps `updated_at` (AC-22).
  defp apply_paste_changes!(
         route,
         plan,
         locked_trips,
         pasted_timings,
         operation_id,
         audit_context
       ) do
    changes = plan |> paste_changes() |> Enum.filter(&(attr(&1, :op) == :change))
    by_id = Map.new(locked_trips, &{&1.id, &1})
    affected = Enum.map(changes, &locked_change_uuid!(&1, by_id))

    changed_ids =
      Enum.map(changes, fn change ->
        apply_paste_change!(
          route,
          change,
          by_id,
          pasted_timings,
          operation_id,
          affected,
          audit_context
        )
      end)

    {length(changes), changed_ids}
  end

  # A :change names a locked scope trip by UUID. A change naming no locked
  # trip means the scope moved under the locks, so the plan is stale rather
  # than partially applied (the same rule as removals).
  defp locked_change_uuid!(change, by_id) do
    uuid = attr(attr(change, :trip), :id)

    if is_binary(uuid) and Map.has_key?(by_id, uuid),
      do: uuid,
      else: Repo.rollback(:stale_plan)
  end

  defp apply_paste_change!(
         route,
         change,
         by_id,
         pasted_timings,
         operation_id,
         affected,
         audit_context
       ) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    trip = Map.fetch!(by_id, locked_change_uuid!(change, by_id))
    row = attr(change, :row)
    unless is_map(row), do: Repo.rollback(:stale_plan)

    start_secs = attr(row, :start_secs)
    unless is_integer(start_secs), do: Repo.rollback(:stale_plan)

    timing_rows = attr(row, :timing_rows)
    unless is_list(timing_rows) and timing_rows != [], do: Repo.rollback(:stale_plan)

    timed_pattern_id = paste_change_timing_id!(change, pasted_timings)
    pattern = lock_paste_pattern!(route, attr(row, :pattern_id))
    occurrences = pattern_occurrences(pattern)

    unless length(timing_rows) == length(occurrences), do: Repo.rollback(:stale_plan)

    old_stop_times = trip_stop_times(organization_id, version_id, trip.trip_id)
    frequencies = trip_frequencies(organization_id, version_id, trip.trip_id)

    before =
      trip_snapshot(
        trip,
        timing_name(organization_id, version_id, trip.timed_pattern_id),
        first_departure_secs(old_stop_times),
        old_stop_times,
        frequencies,
        trip.pattern_derivation_state != "linked"
      )

    rewrite_paste_stop_times!(trip, pattern, occurrences, old_stop_times, timing_rows, start_secs)
    updated = update_paste_trip_row!(trip, change, timed_pattern_id)
    new_stop_times = trip_stop_times(organization_id, version_id, trip.trip_id)

    after_snapshot =
      trip_snapshot(
        updated,
        timing_name(organization_id, version_id, timed_pattern_id),
        start_secs,
        new_stop_times,
        frequencies,
        updated.pattern_derivation_state != "linked"
      )

    audit_trip!(audit_context, updated, "updated", before, after_snapshot, operation_id, affected)

    updated.trip_id
  end

  # An {:existing, id} timing is already stored; a {:new, name} timing was
  # created above on the row's own pattern, so that pattern's mapped id
  # applies. Anything else means the plan no longer fits the locked state.
  defp paste_change_timing_id!(change, pasted_timings) do
    pattern_id = attr(attr(change, :row), :pattern_id)

    case attr(change, :timing) do
      {:existing, id} when is_binary(id) ->
        id

      {:new, name} when is_binary(name) ->
        case Map.fetch(pasted_timings, {pattern_id, name}) do
          {:ok, id} -> id
          :error -> Repo.rollback(:stale_plan)
        end

      _timing ->
        Repo.rollback(:stale_plan)
    end
  end

  defp rewrite_paste_stop_times!(
         trip,
         pattern,
         occurrences,
         old_stop_times,
         timing_rows,
         start_secs
       ) do
    if length(old_stop_times) == length(occurrences) do
      RoutePatterns.rematerialize_trip!(trip, occurrences, timing_rows, start_secs)
    else
      materialized =
        case Materializer.materialize(start_secs, occurrences, timing_rows) do
          {:ok, rows} -> rows
          {:error, _reason} -> Repo.rollback(:stale_plan)
        end

      delete_children!(:stop_times, trip.organization_id, trip.gtfs_version_id, [trip.trip_id])

      shape_attrs = Alignments.trip_shape_attrs(pattern)

      trip
      |> stop_time_rows(materialized, shape_attrs.visit_distances, DateTime.utc_now())
      |> insert_stop_times!()
    end
  end

  # Linkage plus the plan's R13 metadata, nothing else: `trip_id`, transfers,
  # accessibility and every unrelated field stay on the locked row. A blank
  # headsign keeps the stored value, so an empty headsign never writes.
  defp update_paste_trip_row!(trip, change, timed_pattern_id) do
    headsign = attr(change, :trip_headsign)

    headsign =
      if is_binary(headsign) and String.trim(headsign) == "",
        do: trip.trip_headsign,
        else: headsign

    trip
    |> Ecto.Changeset.change(%{
      timed_pattern_id: timed_pattern_id,
      pattern_derivation_state: "linked",
      pattern_derivation_reason: nil,
      trip_short_name: attr(change, :trip_short_name),
      block_id: attr(change, :block_id),
      trip_headsign: headsign
    })
    |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())
    |> update_trip_row!()
  end

  # Step 18: one insert per :add, in plan order (AC-11, AC-16, AC-22).
  # IDs come from `TripChanges.allocate_trip_ids/5` seeded with the version's IDs read
  # after the removals, so a removed natural ID is free to reuse and a
  # later departure never reuses an ID this apply already reserved (a
  # same-HHMM collision takes the `-2` suffix). Each add sets its
  # `timed_pattern_id` (existing id or mapped pending id), `linked` state,
  # and the plan's R13 metadata (a blank headsign stores nil, never "");
  # stop times come from `Materializer.materialize/3` with R9 timepoints
  # (1 at pasted occurrences, 0 at estimated ones) and GTFS-convention 0
  # pickup/drop attributes, inserted via `stop_time_rows/3` +
  # `insert_stop_times!/1`. Each new trip audits 'created' with the
  # before/after `trip_snapshot/6` under the shared operation id. Timing
  # 'created' audits already ran in `create_paste_timings!/3`, so no timing
  # audit belongs here. Any stale add (no locked pattern, mistimed vector,
  # unmapped timing) rolls back `:stale_plan`, never partial (AC-19).
  defp apply_paste_adds!(
         route,
         plan,
         service_id,
         direction,
         pasted_timings,
         operation_id,
         audit_context
       ) do
    adds = paste_adds(plan)

    if adds == [] do
      {0, []}
    else
      organization_id = audit_context.organization_id
      version_id = audit_context.gtfs_version_id

      starts = Enum.map(adds, &paste_add_start!(&1))

      trip_ids =
        TripChanges.allocate_trip_ids(
          route.route_id,
          direction,
          service_id,
          starts,
          version_trip_ids(organization_id, version_id)
        )

      now = DateTime.utc_now()

      inserted =
        Enum.map(Enum.zip(adds, trip_ids), fn {change, trip_id} ->
          insert_paste_add!(
            route,
            change,
            trip_id,
            service_id,
            direction,
            pasted_timings,
            audit_context,
            now
          )
        end)

      all_stop_rows = Enum.flat_map(inserted, &elem(&1, 1))
      unless all_stop_rows == [], do: insert_stop_times!(all_stop_rows)

      trips = Enum.map(inserted, &elem(&1, 0))
      affected = Enum.map(trips, & &1.id)

      Enum.each(inserted, fn {trip, _rows, materialized, start_secs, timing_label} ->
        after_snapshot =
          trip_snapshot(trip, timing_label, start_secs, materialized, [], false)

        audit_trip!(
          audit_context,
          trip,
          "created",
          nil,
          after_snapshot,
          operation_id,
          affected
        )
      end)

      {length(adds), Enum.map(trips, & &1.trip_id)}
    end
  end

  defp paste_adds(plan), do: plan |> paste_changes() |> Enum.filter(&paste_add?(&1))

  defp paste_add?(change), do: attr(change, :op) in [:add, "add"]

  defp paste_add_start!(change) do
    start_secs = attr(attr(change, :row), :start_secs)
    unless is_integer(start_secs), do: Repo.rollback(:stale_plan)
    start_secs
  end

  # Inserts one :add trip row and builds (but does not yet insert) its stop
  # times; the caller inserts all stop rows in one `insert_stop_times!/1`
  # call and then audits. Returns `{trip, stop_rows, materialized,
  # start_secs, timing_label}` for the audit.
  defp insert_paste_add!(
         route,
         change,
         trip_id,
         service_id,
         direction,
         pasted_timings,
         audit_context,
         now
       ) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    row = attr(change, :row)
    unless is_map(row), do: Repo.rollback(:stale_plan)

    start_secs = attr(row, :start_secs)
    unless is_integer(start_secs), do: Repo.rollback(:stale_plan)

    raw_timing_rows = attr(row, :timing_rows)

    unless is_list(raw_timing_rows) and raw_timing_rows != [],
      do: Repo.rollback(:stale_plan)

    timing_rows = normalize_paste_timing_rows(raw_timing_rows)
    timed_pattern_id = paste_change_timing_id!(change, pasted_timings)
    pattern = lock_paste_pattern!(route, attr(row, :pattern_id))
    if pattern.direction_id != direction, do: Repo.rollback(:stale_plan)

    occurrences = pattern_occurrences(pattern)
    unless length(timing_rows) == length(occurrences), do: Repo.rollback(:stale_plan)

    materialized =
      case Materializer.materialize(start_secs, occurrences, timing_rows) do
        {:ok, rows} -> rows
        {:error, _reason} -> Repo.rollback(:stale_plan)
      end

    shape_attrs = Alignments.trip_shape_attrs(pattern)

    trip =
      insert_trip!(%{
        trip_id: trip_id,
        route_id: route.route_id,
        service_id: service_id,
        direction_id: pattern.direction_id,
        trip_headsign: paste_add_headsign(change),
        trip_short_name: attr(change, :trip_short_name),
        block_id: attr(change, :block_id),
        shape_id: shape_attrs.shape_id,
        organization_id: organization_id,
        gtfs_version_id: version_id,
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timed_pattern_id,
        pattern_derivation_state: "linked",
        pattern_derivation_reason: nil
      })

    stop_rows = stop_time_rows(trip, materialized, shape_attrs.visit_distances, now)

    {trip, stop_rows, materialized, start_secs,
     paste_add_timing_label(change, timed_pattern_id, organization_id, version_id)}
  end

  # GTFS reads an absent pickup/drop as 0; normalize nil here so the add
  # path never stores nil next to the 0s RowResolver keys and
  # `create_pasted_timing!/6` stores (coordinator note on e8e2cefe).
  defp normalize_paste_timing_rows(rows) do
    Enum.map(rows, fn row when is_map(row) ->
      pickup = attr(row, :pickup_type)
      drop = attr(row, :drop_off_type)

      row
      |> Map.put(:pickup_type, if(is_nil(pickup), do: 0, else: pickup))
      |> Map.put(:drop_off_type, if(is_nil(drop), do: 0, else: drop))
      |> Map.put("pickup_type", if(is_nil(pickup), do: 0, else: pickup))
      |> Map.put("drop_off_type", if(is_nil(drop), do: 0, else: drop))
    end)
  end

  # New trips take the plan's effective default headsign already; a blank
  # stores nil so an empty headsign never writes (INV-4).
  defp paste_add_headsign(change) do
    case attr(change, :trip_headsign) do
      headsign when is_binary(headsign) ->
        if String.trim(headsign) == "", do: nil, else: headsign

      headsign ->
        headsign
    end
  end

  # The audit's timing label: pending timings already name themselves;
  # existing timings read back through the locked version state.
  defp paste_add_timing_label(change, timed_pattern_id, organization_id, version_id) do
    case attr(change, :timing) do
      {:new, name} when is_binary(name) -> name
      {:existing, _id} -> timing_name(organization_id, version_id, timed_pattern_id)
      _timing -> nil
    end
  end

  # `trip_ids` in overall plan order: the :change ids and :add ids each
  # arrive in plan order, so walk the plan and drain each queue in turn.
  defp paste_result_trip_ids(plan, changed_ids, added_ids) do
    {ids, _, _} =
      Enum.reduce(paste_changes(plan), {[], changed_ids, added_ids}, &collect_result_trip_id/2)

    Enum.reverse(ids)
  end

  defp collect_result_trip_id(change, {acc, changes, adds}) do
    case attr(change, :op) do
      op when op in [:change, "change"] -> take_change_id(acc, changes, adds)
      op when op in [:add, "add"] -> take_added_id(acc, changes, adds)
      _op -> {acc, changes, adds}
    end
  end

  defp take_change_id(acc, [id | rest], adds), do: {[id | acc], rest, adds}
  defp take_change_id(acc, [], adds), do: {acc, [], adds}

  defp take_added_id(acc, changes, [id | rest]), do: {[id | acc], changes, rest}
  defp take_added_id(acc, changes, []), do: {acc, changes, []}

  defp paste_changes(plan), do: attr(plan, :changes) || []

  defp paste_timing_entries(plan), do: attr(plan, :new_timings) || []

  defp paste_timing_names(plan), do: Enum.map(paste_timing_entries(plan), &attr(&1, :name))

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

    pattern =
      resolve_pattern(
        filter_value(filters, :pattern),
        filter_value(filters, :route_pattern_id),
        direction_patterns
      )

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

    estimate = schedule_estimate(organization_id, version_id)

    sections =
      build_sections(section_patterns, %{
        trips: trips,
        direction: direction,
        occurrences_by_pattern: occurrences_by_pattern,
        timings_by_pattern: timings_by_pattern,
        stops_by_id: stops_by_id,
        stop_times_by_trip: stop_times_by_trip,
        frequencies_by_trip: frequencies_by_trip,
        estimate: estimate
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

  # -- Paste scope ------------------------------------------------------------

  defp read_paste_scope(organization_id, version_id, route_id, params) do
    route = published_route!(organization_id, version_id, route_id)

    summaries = load_calendars!(organization_id, version_id)
    counts = route_trip_counts(organization_id, version_id, route_id)
    calendars = attach_route_trip_counts(summaries, counts)

    calendar = resolve_calendar(calendars, filter_value(params, :service_id))
    trips = load_trips(organization_id, version_id, route_id, calendar)

    direction =
      resolve_direction(
        filter_value(params, :direction_id) || filter_value(params, :direction),
        trips
      )

    patterns = load_patterns(organization_id, version_id, route_id)
    direction_patterns = Enum.filter(patterns, &(&1.direction_id == direction))

    pattern_id =
      resolve_paste_pattern(
        filter_value(params, :pattern_id) || filter_value(params, :pattern),
        filter_value(params, :route_pattern_id),
        direction_patterns,
        trips
      )

    occurrences_by_pattern = load_occurrences(organization_id, version_id, patterns)
    timings_by_pattern = load_paste_timings(organization_id, version_id, patterns)

    stops_by_id =
      load_stops(organization_id, version_id, occurrence_stop_ids(occurrences_by_pattern))

    stop_times_by_trip = load_stop_times(organization_id, version_id, trips)
    frequencies_by_trip = load_frequencies(organization_id, version_id, trips)
    {transfers_by_trip, in_seat_trips} = paste_transfer_groups(organization_id, version_id, trips)
    timing_use_counts = Enum.frequencies_by(trips, & &1.timed_pattern_id)

    %{
      route: route,
      calendar: paste_calendar(calendar, summaries),
      direction_id: direction,
      pattern_id: pattern_id,
      patterns:
        Enum.map(direction_patterns, fn pattern ->
          paste_pattern_entry(
            pattern,
            occurrences_by_pattern,
            timings_by_pattern,
            timing_use_counts
          )
        end),
      stops:
        Map.new(stops_by_id, fn {stop_id, stop} ->
          {stop_id, %{stop_code: stop.stop_code, stop_name: stop.stop_name}}
        end),
      trips:
        Enum.map(trips, fn trip ->
          paste_trip_entry(
            trip,
            Map.get(stop_times_by_trip, trip.trip_id, []),
            Map.get(frequencies_by_trip, trip.trip_id, []),
            Map.get(transfers_by_trip, trip.trip_id, []),
            MapSet.member?(in_seat_trips, trip.trip_id),
            patterns,
            occurrences_by_pattern,
            timings_by_pattern
          )
        end),
      other_calendars?: paste_other_calendars?(counts, calendar)
    }
  end

  # A requested pattern is a row UUID (`pattern_id`/`pattern`) or a feed
  # `route_pattern_id`, never both and never guessed from the value's spelling.
  # Unlike the Schedules read, a request that names no pattern of the chosen
  # direction, or both kinds, is a foreign scope, not an `:all` fallback. An
  # absent request resolves to the direction's most-used pattern (most trips
  # on the resolved calendar, ties keep pattern order), or nil when the
  # direction has no pattern at all.
  defp resolve_paste_pattern(row_id, route_pattern_id, direction_patterns, trips) do
    case select_pattern(row_id, route_pattern_id, direction_patterns) do
      {:ok, %RoutePattern{id: id}} -> id
      :absent -> default_paste_pattern(direction_patterns, trips)
      _invalid -> Repo.rollback(:not_found)
    end
  end

  defp default_paste_pattern([], _trips), do: nil

  defp default_paste_pattern(direction_patterns, trips) do
    counts = Enum.frequencies_by(trips, &{&1.route_pattern_id, &1.direction_id})

    direction_patterns
    |> Enum.max_by(
      &Map.get(counts, {&1.route_pattern_id, &1.direction_id}, 0),
      fn -> hd(direction_patterns) end
    )
    |> Map.fetch!(:id)
  end

  defp paste_calendar(nil, _summaries), do: nil

  defp paste_calendar(calendar, summaries) do
    summary = Enum.find(summaries, &(&1.service_id == calendar.service_id))

    %{
      service_id: calendar.service_id,
      name: calendar.name,
      kind: calendar.kind,
      first_active_date: summary && summary.first_active_date,
      last_active_date: summary && summary.last_active_date,
      trip_count: calendar.route_trip_count
    }
  end

  defp paste_other_calendars?(counts, calendar) do
    chosen = calendar && calendar.service_id
    Enum.any?(counts, fn {service_id, count} -> count > 0 and service_id != chosen end)
  end

  defp paste_pattern_entry(pattern, occurrences_by_pattern, timings_by_pattern, timing_use_counts) do
    occurrences = Map.get(occurrences_by_pattern, pattern.id, [])
    timings = Map.get(timings_by_pattern, pattern.id, [])

    %{
      id: pattern.id,
      route_pattern_id: pattern.route_pattern_id,
      name: pattern.route_pattern_name || pattern.route_pattern_id,
      headsign: pattern.headsign,
      occurrences:
        Enum.map(occurrences, fn occurrence ->
          %{id: occurrence.id, stop_id: occurrence.stop_id, position: occurrence.position}
        end),
      timings:
        Enum.map(timings, fn timing ->
          Map.put(timing, :trip_count, Map.get(timing_use_counts, timing.id, 0))
        end)
    }
  end

  # Timing rows with every field the paste key covers, in occurrence position
  # order so they align positionally with the pattern's occurrences (the shape
  # RowResolver and Plan consume). `load_timings/3` stays untouched: the
  # Schedules read never needs the per-stop attributes.
  defp load_paste_timings(_organization_id, _version_id, []), do: %{}

  defp load_paste_timings(organization_id, version_id, patterns) do
    route_pattern_ids = Enum.map(patterns, & &1.route_pattern_id)

    timings =
      from(t in TimedPattern,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_pattern_id in ^route_pattern_ids,
        order_by: [asc: t.route_pattern_id, asc: t.name, asc: t.id]
      )
      |> Repo.all()

    rows_by_timing = paste_timing_rows(organization_id, version_id, Enum.map(timings, & &1.id))

    timings
    |> Enum.group_by(& &1.route_pattern_id)
    |> Map.new(fn {route_pattern_id, pattern_timings} ->
      {route_pattern_id,
       Enum.map(pattern_timings, fn timing ->
         %{
           id: timing.id,
           name: timing.name,
           headsign: timing.headsign,
           rows: Map.get(rows_by_timing, timing.id, [])
         }
       end)}
    end)
    |> by_pattern_row(patterns)
  end

  # Child rows carry their pattern's GTFS `route_pattern_id`; the readers look
  # them up by the pattern row's `id`. `patterns` are the loaded rows of one
  # organization and version, so the GTFS ID names exactly one of them.
  defp by_pattern_row(grouped, patterns) do
    row_ids = Map.new(patterns, &{&1.route_pattern_id, &1.id})

    Map.new(grouped, fn {route_pattern_id, rows} ->
      {Map.fetch!(row_ids, route_pattern_id), rows}
    end)
  end

  defp paste_timing_rows(_organization_id, _version_id, []), do: %{}

  defp paste_timing_rows(organization_id, version_id, timing_ids) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where:
        occurrence.organization_id == ^organization_id and
          occurrence.gtfs_version_id == ^version_id and row.timed_pattern_id in ^timing_ids,
      order_by: [asc: row.timed_pattern_id, asc: occurrence.position, asc: occurrence.id],
      select: %{
        timed_pattern_id: row.timed_pattern_id,
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        stop_headsign: row.stop_headsign
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.timed_pattern_id)
    |> Map.new(fn {timing_id, rows} ->
      {timing_id, Enum.map(rows, &Map.delete(&1, :timed_pattern_id))}
    end)
  end

  defp paste_trip_entry(
         trip,
         stop_times,
         frequencies,
         transfer_ids,
         in_seat?,
         patterns,
         occurrences_by_pattern,
         timings_by_pattern
       ) do
    bounds = trip_bounds(stop_times)

    {start_secs, end_secs} =
      case bounds do
        {:ok, start_secs, end_secs} -> {start_secs, end_secs}
        :error -> {nil, nil}
      end

    # A frequency trip without stored stop times still refuses Replace: fall
    # back to its earliest frequency window so pairing sees a real start.
    start_secs = start_secs || paste_frequency_start(frequencies)

    span =
      if is_integer(start_secs) and is_integer(end_secs) do
        %{start_secs: start_secs, end_secs: end_secs}
      end

    frequency_rows =
      Enum.map(frequencies, fn frequency ->
        %{
          start_time: frequency.start_time,
          end_time: frequency.end_time,
          headway_secs: frequency.headway_secs,
          exact_times: frequency.exact_times
        }
      end)

    %{
      id: trip.id,
      trip_id: trip.trip_id,
      direction_id: trip.direction_id,
      route_pattern_id: trip.route_pattern_id,
      timed_pattern_id: trip.timed_pattern_id,
      pattern_derivation_state: trip.pattern_derivation_state,
      start_secs: start_secs,
      end_secs: end_secs,
      span: span,
      spans: spans_for(%{bounds: bounds, frequencies: frequencies}),
      frequencies: frequency_rows,
      frequency_rows: frequency_rows,
      stops_differ?:
        paste_stops_differ?(
          trip,
          patterns,
          occurrences_by_pattern,
          timings_by_pattern,
          stop_times
        ),
      trip_short_name: trip.trip_short_name,
      block_id: trip.block_id,
      trip_headsign: trip.trip_headsign,
      updated_at: trip.updated_at,
      transfer_ids: transfer_ids,
      in_seat_transfer: in_seat?
    }
  end

  defp paste_frequency_start(frequencies) do
    frequencies
    |> frequency_windows()
    |> Enum.map(& &1.start_secs)
    |> Enum.min(fn -> nil end)
  end

  # The Timetable read-path rule: a trip off every timing of its own pattern is
  # custom, and a custom trip whose ordered stops no longer match the pattern's
  # occurrences differs. Trips with no pattern of their own have nothing to
  # differ from.
  defp paste_stops_differ?(trip, patterns, occurrences_by_pattern, timings_by_pattern, stop_times) do
    case Enum.find(
           patterns,
           &(&1.route_pattern_id == trip.route_pattern_id and
               &1.direction_id == trip.direction_id)
         ) do
      nil ->
        false

      pattern ->
        timings = Map.get(timings_by_pattern, pattern.id, [])
        custom? = is_nil(Enum.find(timings, &(&1.id == trip.timed_pattern_id)))
        occurrences = Map.get(occurrences_by_pattern, pattern.id, [])

        custom? and occurrences != [] and
          Enum.map(stop_times, & &1.stop_id) != Enum.map(occurrences, & &1.stop_id)
    end
  end

  # Transfers name the natural `trip_id`, never the UUID: group every transfer
  # touching a scope trip by the trips it names, and collect the natural IDs on
  # either side of an in-seat (type 4/5) transfer for the retime warning.
  defp paste_transfer_groups(_organization_id, _version_id, []), do: {%{}, MapSet.new()}

  defp paste_transfer_groups(organization_id, version_id, trips) do
    natural_ids = trips |> Enum.map(& &1.trip_id) |> Enum.uniq()

    rows =
      from(t in Transfer,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            (t.from_trip_id in ^natural_ids or t.to_trip_id in ^natural_ids),
        order_by: [asc: t.from_trip_id, asc: t.to_trip_id, asc: t.id],
        select: %{
          id: t.id,
          from_trip_id: t.from_trip_id,
          to_trip_id: t.to_trip_id,
          transfer_type: t.transfer_type
        }
      )
      |> Repo.all()

    by_trip =
      Map.new(natural_ids, fn natural_id ->
        ids =
          rows
          |> Enum.filter(&(&1.from_trip_id == natural_id or &1.to_trip_id == natural_id))
          |> Enum.map(& &1.id)
          |> Enum.sort()

        {natural_id, ids}
      end)

    in_seat =
      rows
      |> Enum.filter(&(&1.transfer_type in [4, 5]))
      |> Enum.flat_map(&[&1.from_trip_id, &1.to_trip_id])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {by_trip, in_seat}
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
    route_pattern_ids = Enum.map(patterns, & &1.route_pattern_id)

    from(o in RoutePatternStop,
      where:
        o.organization_id == ^organization_id and o.gtfs_version_id == ^version_id and
          o.route_pattern_id in ^route_pattern_ids,
      order_by: [asc: o.route_pattern_id, asc: o.position, asc: o.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_pattern_id)
    |> by_pattern_row(patterns)
  end

  defp load_timings(_organization_id, _version_id, []), do: %{}

  defp load_timings(organization_id, version_id, patterns) do
    route_pattern_ids = Enum.map(patterns, & &1.route_pattern_id)

    timings =
      from(t in TimedPattern,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_pattern_id in ^route_pattern_ids,
        order_by: [asc: t.route_pattern_id, asc: t.name, asc: t.id]
      )
      |> Repo.all()

    rows_by_timing = timing_rows(organization_id, version_id, Enum.map(timings, & &1.id))

    timings
    |> Enum.group_by(& &1.route_pattern_id)
    |> Map.new(fn {route_pattern_id, pattern_timings} ->
      {route_pattern_id,
       Enum.map(pattern_timings, fn timing ->
         %{
           id: timing.id,
           name: timing.name,
           headsign: timing.headsign,
           rows: Map.get(rows_by_timing, timing.id, [])
         }
       end)}
    end)
    |> by_pattern_row(patterns)
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
        timepoint: row.timepoint,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        stop_headsign: row.stop_headsign
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
        departure_time: st.departure_time,
        timepoint: st.timepoint,
        pickup_type: st.pickup_type,
        drop_off_type: st.drop_off_type,
        stop_headsign: st.stop_headsign,
        # A copy or a conversion writes a full stop-time row (R7, R8), so the
        # loader reads the two continuous flags and the shape distance it keeps.
        continuous_pickup: st.continuous_pickup,
        continuous_drop_off: st.continuous_drop_off,
        shape_dist_traveled: st.shape_dist_traveled
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

  # The requested pattern is a row UUID (`pattern`) or a feed `route_pattern_id`,
  # never both and never guessed from the value's spelling. It resolves to the
  # UUID the payload exposes; an absent, unknown or ambiguous request falls back
  # to `:all`. A pattern of the other direction never resolves.
  defp resolve_pattern(row_id, route_pattern_id, direction_patterns) do
    case select_pattern(row_id, route_pattern_id, direction_patterns) do
      {:ok, %RoutePattern{id: id}} -> id
      _unselected -> :all
    end
  end

  # Exactly one binary selector selects by its own kind: `{:ok, pattern}` for a
  # match, `:not_found` for none, `:ambiguous` when both kinds are named and
  # `:absent` when neither is.
  defp select_pattern(row_id, route_pattern_id, direction_patterns) do
    case {row_id, route_pattern_id} do
      {row, natural} when is_binary(row) and is_binary(natural) ->
        :ambiguous

      {row, _absent} when is_binary(row) ->
        find_pattern(direction_patterns, &(&1.id == row))

      {_absent, natural} when is_binary(natural) ->
        find_pattern(direction_patterns, &(&1.route_pattern_id == natural))

      _neither ->
        :absent
    end
  end

  defp find_pattern(direction_patterns, matches?) do
    case Enum.find(direction_patterns, matches?) do
      %RoutePattern{} = pattern -> {:ok, pattern}
      nil -> :not_found
    end
  end

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
        estimate = Map.get(data, :estimate, nil)

        opts =
          case estimate do
            %{method: method, coordinates: coords} -> [estimate: method, coordinates: coords]
            _ -> []
          end

        [Timetable.build(pattern, occurrences, data.stops_by_id, timings, timetable_trips, opts)]
    end
  end

  # The Schedules estimate preview follows the current Export defaults
  # (spec 23, AC-26): with estimation on, custom trips preview the export
  # method with stop coordinates; with estimation off, no estimate is passed
  # and the timetable shows stored values only. Read-only (INV-1) and scoped
  # to this organization and version (INV-2).
  defp schedule_estimate(organization_id, version_id) do
    defaults = ExportDefaults.get(organization_id)

    if defaults.estimate_missing_times do
      %{
        method: defaults.estimate_method,
        coordinates: MissingTimes.stop_coordinates(organization_id, version_id)
      }
    else
      nil
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
        headsign: pattern.headsign,
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

  @doc """
  Reduces stored frequencies.txt windows to parsed integer seconds.

  One window per `%Frequency{}` row with a positive `headway_secs` and parseable
  `start_time`/`end_time`; a row failing either check is dropped, so a trip whose
  every row drops out is summarized from its stored departure instead of from the
  window. `end_time` stays the exclusive window end, so shared summaries of these
  windows stay identical for every caller.
  """
  @spec frequency_windows([map()]) :: [
          %{
            start_secs: non_neg_integer(),
            until_secs: non_neg_integer(),
            headway_secs: pos_integer()
          }
        ]
  def frequency_windows(frequencies) do
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

  # Spec 01's bounded retry: a serialization failure or a deadlock retries the
  # whole transaction; every other failure is returned unchanged.
  defp run_write(transaction, attempts \\ @write_attempts, options \\ []) do
    case run_write_transaction(transaction, options) do
      {:ok, result} ->
        {:ok, result}

      {:serialization_failure, _error} ->
        retry_write(transaction, attempts, options)

      {:error, reason} ->
        retry_write_error(reason, transaction, attempts, options)
    end
  end

  defp retry_write(transaction, attempts, options) when attempts > 1,
    do: run_write(transaction, attempts - 1, options)

  defp retry_write(_transaction, _attempts, _options), do: {:error, :busy}

  defp retry_write_error(reason, transaction, attempts, options) do
    if Repo.retryable_conflict?(reason),
      do: retry_write(transaction, attempts, options),
      else: {:error, reason}
  end

  defp run_write_transaction(transaction, []), do: run_write_transaction(transaction)

  defp run_write_transaction(transaction, options) do
    ReviewedApplyTransaction.adapter().run(transaction, options)
  rescue
    error in Postgrex.Error -> write_failure(error, __STACKTRACE__)
  end

  defp run_write_transaction(transaction) do
    ReviewedApplyTransaction.adapter().run(transaction)
  rescue
    error in Postgrex.Error -> write_failure(error, __STACKTRACE__)
  end

  defp write_failure(error, stacktrace) do
    if Repo.retryable_conflict?(error),
      do: {:serialization_failure, error},
      else: reraise(error, stacktrace)
  end

  defp insert_trips!(route_id, starts, attrs, audit_context) do
    Authorization.lock_editor!(audit_context)
    pattern_id = attr(attrs, :pattern_id)
    timed_pattern_id = attr(attrs, :timed_pattern_id)
    service_id = attr(attrs, :service_id)
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    unless Values.uuid?(pattern_id) and Values.uuid?(timed_pattern_id),
      do: Repo.rollback(:not_found)

    # Rule-table lock order: the calendar's version row `FOR SHARE` first, then the
    # route `FOR UPDATE`, then the pattern `FOR UPDATE`. Timing rows are loaded
    # after the route lock, so a created trip always matches the committed timing.
    # The shape attributes are read after the pattern lock, so they cannot
    # change until commit (R15).
    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, service_id)
    route = RoutePatterns.lock_published_route!(audit_context, route_id)
    pattern = RoutePatterns.lock_pattern!(route, pattern_id)
    :ok = check_service_mix!(organization_id, version_id, route, pattern, service_id)
    shape_attrs = Alignments.trip_shape_attrs(pattern)
    timing = locked_timing!(pattern, timed_pattern_id)

    occurrences = pattern_occurrences(pattern)
    rows = timing_rows(timing)
    materialized = materialized_stop_times(starts, occurrences, rows)

    existing_trip_ids = version_trip_ids(organization_id, version_id)

    trip_ids =
      TripChanges.allocate_trip_ids(
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

  # R9 (INV-5): the new trips are all listed and share the requested service, and
  # the rule is set-based per service, so one `after` entry stands for the whole
  # batch. The pattern lock is held, so no writer following the rule-table lock
  # order can add a trip or a window to this pattern until this transaction ends.
  defp check_service_mix!(organization_id, version_id, route, pattern, service_id) do
    before_trips = pattern_trip_kinds(organization_id, version_id, route, pattern)
    after_trips = before_trips ++ [%{service_id: service_id, frequency?: false}]
    service_dates = DayTypes.service_dates(load_calendars!(organization_id, version_id))

    case ServiceMix.check(before_trips, after_trips, service_dates) do
      :ok -> :ok
      {:error, {:mixed_service, details}} -> Repo.rollback({:mixed_service, details})
    end
  end

  # R9 (INV-5) for one trip's calendar change: the pattern's trips before, and the
  # same trips with this one on its new service after, under the held pattern lock.
  # A trip on no pattern, or one keeping its service, has nothing to check.
  defp check_moved_service_mix!(_organization_id, _version_id, _route, nil, _trip, _service_id),
    do: :ok

  defp check_moved_service_mix!(_organization_id, _version_id, _route, _pattern, trip, service_id)
       when trip.service_id == service_id,
       do: :ok

  defp check_moved_service_mix!(organization_id, version_id, route, pattern, trip, service_id) do
    before_trips = pattern_trip_kinds(organization_id, version_id, route, pattern)

    after_trips =
      Enum.map(before_trips, fn kind ->
        if kind.id == trip.id, do: %{kind | service_id: service_id}, else: kind
      end)

    service_dates = DayTypes.service_dates(load_calendars!(organization_id, version_id))

    case ServiceMix.check(before_trips, after_trips, service_dates) do
      :ok -> :ok
      {:error, {:mixed_service, details}} -> Repo.rollback({:mixed_service, details})
    end
  end

  # Every trip already on the pattern, with the frequency flag the rule reads.
  # Trips whose stored pattern is gone (unlinked) are on no pattern and are not
  # part of the mix check, the same way `load_change_state/3` reads them.
  defp pattern_trip_kinds(organization_id, version_id, route, pattern) do
    trips =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_id == ^route.route_id and t.route_pattern_id == ^pattern.route_pattern_id,
        order_by: [asc: t.id]
      )
      |> Repo.all()

    frequencies = load_frequencies(organization_id, version_id, trips)

    Enum.map(trips, fn trip ->
      %{
        id: trip.id,
        service_id: trip.service_id,
        frequency?: Map.get(frequencies, trip.trip_id, []) != []
      }
    end)
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
  defp audit_trip!(
         audit_context,
         trip,
         action,
         before,
         after_snapshot,
         operation_id,
         affected,
         extra \\ %{}
       ) do
    case Audit.record_change_in_transaction(
           audit_context,
           :trip,
           trip,
           action,
           Map.merge(
             %{
               before: before,
               after: after_snapshot,
               operation_id: operation_id,
               affected_trip_ids: affected
             },
             extra
           )
         ) do
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
    Authorization.lock_editor!(audit_context)

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

    unless Values.uuid?(trip_id), do: Repo.rollback(:not_found)

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

    check_moved_service_mix!(organization_id, version_id, route, pattern, trip, effective_service)

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
      |> put_headsign_fallback(
        pattern,
        Map.get(linkage, :timed_pattern_id, trip.timed_pattern_id)
      )

    if rewritten? or changeset.changes != %{} do
      persist_trip_edit!(changeset, trip, request, frequencies, audit_context)
    else
      # A request that changes nothing writes no trip row and no audit log.
      trip
    end
  end

  # A request that submits a blank headsign gets the fallback of the timing the
  # trip ends up on, so the stored value is the one the drawer hint names. A
  # request without a headsign leaves the stored one alone.
  defp put_headsign_fallback(changeset, pattern, timing_id) do
    if Map.has_key?(changeset.params, "trip_headsign") and
         is_nil(Ecto.Changeset.get_field(changeset, :trip_headsign)) do
      Ecto.Changeset.put_change(changeset, :trip_headsign, headsign_fallback(pattern, timing_id))
    else
      changeset
    end
  end

  defp headsign_fallback(nil, _timing_id), do: nil

  defp headsign_fallback(pattern, timing_id) do
    timing_headsign =
      if is_binary(timing_id) do
        Repo.one(
          from(t in RoutePatterns.timings_query(pattern),
            where: t.id == ^timing_id,
            select: t.headsign
          )
        )
      end

    fallback_headsign(timing_headsign, pattern.headsign)
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
    Authorization.lock_editor!(audit_context)

    case GtfsTime.parse(attr(attrs, :start_time)) do
      {:ok, start_secs} -> do_duplicate_trip(route_id, trip_id, attrs, start_secs, audit_context)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp do_duplicate_trip(route_id, trip_id, attrs, start_secs, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    timed_pattern_id = attr(attrs, :timed_pattern_id)

    unless Values.uuid?(trip_id) and Values.uuid?(timed_pattern_id), do: Repo.rollback(:not_found)

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
      TripChanges.allocate_trip_ids(
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
  # a duplicate is unblocked until it is assigned on the Blocks page (D1). It
  # also gets no trip number, which would repeat the source's on one service day.
  defp duplicate_trip_attrs(trip, route, pattern, timing, trip_id) do
    %{
      trip_id: trip_id,
      route_id: route.route_id,
      service_id: trip.service_id,
      direction_id: pattern.direction_id,
      trip_headsign: trip.trip_headsign,
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
    Authorization.lock_editor!(audit_context)
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    trip_uuids = Enum.uniq(trip_ids)

    unless Enum.all?(trip_uuids, &Values.uuid?/1), do: Repo.rollback(:not_found)

    :ok = Calendars.lock_service_for_reference!(organization_id, version_id, service_id)
    route = RoutePatterns.lock_published_route!(audit_context, route_id)

    trips = lock_matching_trips!(organization_id, version_id, route.route_id, trip_uuids)
    validate_delete_scope!(trips, trip_uuids, service_id)

    # The whole list is valid, so nothing has been deleted yet.
    snapshots = Enum.map(trips, &{&1, deleted_trip_snapshot(&1)})

    # R11/INV-5: the transfers the deletion removes are audited with the trip
    # logs, so the operation id exists before any child row goes.
    operation_id = Ecto.UUID.generate()

    result = remove_locked_trips!(audit_context, trips, operation_id)

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

    result
  end

  # Shared trip removal for `delete_trips/4` and the paste (R14/INV-6).
  #
  # `trips` are the locked scoped trips in UUID order. Deletes stop_times,
  # frequencies and every transfer naming a removed natural `trip_id`, then the
  # trip rows. Each removed transfer is audited with the caller's `operation_id`
  # (R11/INV-5), so the paste and the deletion log the transfers they remove with
  # the same operation id as their trip logs.
  defp remove_locked_trips!(audit_context, trips, operation_id) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    natural_ids = Enum.map(trips, & &1.trip_id)
    trip_uuids = Enum.map(trips, & &1.id)

    delete_children!(:stop_times, organization_id, version_id, natural_ids)
    delete_children!(:frequencies, organization_id, version_id, natural_ids)

    transfers = delete_trip_transfers!(audit_context, natural_ids, operation_id)

    count = delete_trip_rows!(organization_id, version_id, trip_uuids)

    %{trips: count, transfers: transfers}
  end

  # R11: each removed transfer is locked in id order, snapshotted, deleted and
  # logged with this deletion's operation id, in 15's R9 shape. The scope is the
  # existing `trip_transfers_query/3`, so a general type 0-3 row naming a deleted
  # trip is removed and audited exactly like a type 4/5 row, and the returned
  # count is the number of rows the same cleanup removed before.
  defp delete_trip_transfers!(audit_context, natural_ids, operation_id) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    rows =
      from(t in Transfer,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            (t.from_trip_id in ^natural_ids or t.to_trip_id in ^natural_ids),
        order_by: [asc: t.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    {count, nil} = Repo.delete_all(trip_transfers_query(organization_id, version_id, natural_ids))

    affected_ids = Enum.map(rows, & &1.id)

    Enum.each(rows, fn row ->
      audit_transfer!(
        audit_context,
        row,
        "deleted",
        Transfer.audit_snapshot(row),
        nil,
        operation_id,
        affected_ids
      )
    end)

    count
  end

  # An audit failure is the caller's rollback: no transfer row is ever removed
  # unaudited (INV-5), and it rolls back the trips with it.
  defp audit_transfer!(audit_context, transfer, action, before, after_snapshot, op, affected) do
    case Audit.record_change_in_transaction(audit_context, :transfer, transfer, action, %{
           before: before,
           after: after_snapshot,
           operation_id: op,
           affected_transfer_ids: affected
         }) do
      {:ok, _log} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
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

  # -- Audited trip headsign writes -------------------------------------------

  # Every change id must name a trip of this organization and version; a foreign
  # row, a stale UUID or a non-UUID is an invalid selection that writes nothing
  # (INV-1). Precedent: `FareZones.lock_selected_stops/3`.
  defp lock_headsign_trips!(organization_id, version_id, changes) do
    ids = Enum.map(changes, & &1.id)

    unless Enum.all?(ids, &Values.uuid?/1), do: Repo.rollback(:invalid_selection)

    trips =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.id in ^ids,
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    if length(trips) != length(ids), do: Repo.rollback(:invalid_selection)

    trips
  end

  # `from` is the normalized value the review showed, so the fence applies the
  # same normalization to the stored value before comparing. The stale rows name
  # the raw stored value so the caller can show what moved.
  defp stale_headsign_changes(trips, changes) do
    trip_by_id = Map.new(trips, &{&1.id, &1})

    for %{id: id, from: from} <- changes,
        trip = Map.fetch!(trip_by_id, id),
        Headsigns.normalize(trip.trip_headsign) != from do
      %{id: id, trip_id: trip.trip_id, reviewed: from, current: trip.trip_headsign}
    end
  end

  # One audit row per written trip, sharing the caller's operation id and the
  # full written id list like the other bulk trip audits. The write touches only
  # `trip_headsign` and `updated_at`, so the reconstructed after row is exact
  # and the before/after snapshots differ in `trip_headsign` alone.
  defp audit_written_headsigns!(audit_context, trips, written, operation_id, now) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    trip_by_id = Map.new(trips, &{&1.id, &1})
    affected = Enum.map(written, & &1.id)

    Enum.each(written, fn change ->
      trip = Map.fetch!(trip_by_id, change.id)
      frequencies = trip_frequencies(organization_id, version_id, trip.trip_id)

      start_secs =
        first_departure_secs(trip_stop_times(organization_id, version_id, trip.trip_id))

      before = edit_snapshot(trip, frequencies, start_secs)

      updated = %{trip | trip_headsign: change.to, updated_at: now}
      after_snapshot = edit_snapshot(updated, frequencies, start_secs)

      audit_trip!(
        audit_context,
        updated,
        "updated",
        before,
        after_snapshot,
        operation_id,
        affected
      )
    end)
  end

  defp delete_children!(:stop_times, organization_id, version_id, trip_ids) do
    {count, nil} =
      Repo.delete_all(
        from(st in StopTime,
          where:
            st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
              st.trip_id in ^trip_ids
        )
      )

    count
  end

  defp delete_children!(:frequencies, organization_id, version_id, trip_ids) do
    {count, nil} =
      Repo.delete_all(
        from(f in Frequency,
          where:
            f.organization_id == ^organization_id and f.gtfs_version_id == ^version_id and
              f.trip_id in ^trip_ids
        )
      )

    count
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
    query = from(t in RoutePatterns.timings_query(pattern), where: t.id == ^timed_pattern_id)

    case Repo.one(query) do
      %TimedPattern{} = timing -> timing
      nil -> Repo.rollback(:not_found)
    end
  end

  defp pattern_occurrences(pattern) do
    pattern
    |> RoutePatterns.occurrences_query()
    |> order_by([o], asc: o.position, asc: o.id)
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

  defp series(start_secs, every_secs, until_secs) do
    count = div(until_secs - start_secs, every_secs) + 1

    if count > @max_series_trips do
      {:error, :too_many_trips}
    else
      {:ok, Enum.map(0..(count - 1), &(start_secs + &1 * every_secs))}
    end
  end

  defp attr(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp attr(_map, _key), do: nil
end
