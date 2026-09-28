defmodule GtfsPlanner.Gtfs.Calendars do
  @moduledoc """
  Scoped reads and audited lifecycle commands for editable service calendars.

  A calendar identity is the union of the service IDs stored in `calendars`,
  `calendar_dates` and `calendar_attributes` for one organization/version.
  Reads never invent rows: an exception-only service and a metadata-only service
  are each one visible identity, and `kind` is `:weekly` only when a weekly row
  exists. Summaries reuse `Calendars.ServiceDates` for effective dates and
  warnings, and resolve the warning date through `Gtfs.DisplayClock`'s
  agency-zone PostgreSQL localization. A retained weekly range the evaluator
  refuses - an imported reversed range - is classified as `:coverage_error` on its
  own summary instead of raising, so one malformed row cannot take down a
  whole-version read. `load_screen/3` composes those summaries with the version-wide
  coverage facts for the list surface in one protected read and refuses to claim a
  complete feed while such a row is present.

  Every interactive write resolves the actor's *current* active organization
  membership with the editor role, then locks the organization-scoped published
  version row with `FOR UPDATE` before repeating the union service-ID check and
  the case-insensitive display-name check. Coherent reads and reviews hold the
  same version row with `FOR SHARE` for one aggregate load so a fingerprint can
  never combine rows from before and after a cooperating writer commits. The lock
  is not held while waiting for user confirmation: `review_calendar_change/3`
  releases it and returns a command-bound review fingerprint, and
  `apply_calendar_change/3` recomputes the source under the write lock.

  Calendar history is audit-only. Writes, anchor creation, child deletion and the
  complete aggregate before/after audit snapshot commit in one transaction through
  `Gtfs.record_change_in_transaction/5`, and station rollback refuses the
  `calendar` entity. Save, kind conversion, break, exception and multi-calendar date
  commands are planned from the retained source snapshot and applied under one
  version lock and transaction; a bulk date change shares one operation UUID and
  records the normalized selected dates and all affected service IDs in every log.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Queries
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.Combination
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"
  @editor_role "pathways_studio_editor"
  @added 1
  @removed 2
  @kinds [:weekly, :dates_only]
  @taken_message "has already been taken"
  @metadata_fields ~w(
    service_schedule_name
    service_schedule_type
    service_schedule_typicality
    rating_start_date
    rating_end_date
    rating_description
  )a
  @weekly_day_fields ~w(monday tuesday wednesday thursday friday saturday sunday)a
  @weekly_fields @weekly_day_fields ++ [:start_date, :end_date]
  @combination_decisions %{"run" => :run, "no_service" => :no_service}
  @combination_attempts 3
  @combination_trip_batch 500
  @combination_retryable_codes [:serialization_failure, "40001", :deadlock_detected, "40P01"]
  @type kind :: :weekly | :dates_only
  @type coverage_error :: %{service_id: String.t(), reason: :reversed_range}
  @type command ::
          {:delete, String.t()}
          | {:save, String.t(), map()}
          | {:convert, String.t(), kind(), map()}
          | {:add_break, String.t(), Date.t(), Date.t()}
          | {:put_exceptions, String.t(), [Date.t()], 1 | 2}
          | {:remove_exceptions, String.t(), [Date.t()]}
          | {:date_change, [Date.t()], [String.t()], [String.t()]}
          | {:combine, String.t(), [String.t()], %{String.t() => :run | :no_service}}
  @type closure_path :: %{pathway_id: String.t(), station_stop_ids: [String.t()]}
  @type calendar_usage :: %{
          optional(:service_id) => String.t(),
          trip_count: non_neg_integer(),
          route_ids: [String.t()],
          routes: [%{route_id: String.t(), trip_count: non_neg_integer()}],
          closure_count: non_neg_integer(),
          pathway_ids: [String.t()],
          closure_paths: [closure_path()]
        }
  @type summary_status :: %{
          no_service?: boolean(),
          ended?: boolean(),
          ends_soon?: boolean(),
          days_remaining: non_neg_integer() | nil,
          active_today?: boolean(),
          active_period?: boolean(),
          used_by_trips?: boolean()
        }
  @type summary :: %{
          service_id: String.t(),
          name: String.t() | nil,
          kind: kind(),
          calendar: Calendar.t() | nil,
          attributes: CalendarAttribute.t() | nil,
          trip_count: non_neg_integer(),
          coverage_error: coverage_error() | nil,
          closure_count: non_neg_integer(),
          pathway_ids: [String.t()],
          closure_paths: [closure_path()],
          active_dates: [Date.t()],
          first_active_date: Date.t() | nil,
          last_active_date: Date.t() | nil,
          fingerprint: String.t(),
          warnings: [ServiceDates.warning()],
          status: summary_status(),
          exceptions: [CalendarDate.t()],
          periods: ServiceDates.schedule_periods(),
          routes: [%{route_id: String.t(), trip_count: non_neg_integer()}]
        }
  @type screen :: %{
          rows: [summary()],
          invalid_calendars: [coverage_error()],
          today: Date.t(),
          zone: DisplayClock.today_resolution(),
          horizon: ServiceDates.interval() | nil,
          gaps: [feed_gap()] | nil,
          complete?: boolean()
        }
  @type payload :: %{
          calendar: Calendar.t() | nil,
          attributes: CalendarAttribute.t() | nil,
          exceptions: [CalendarDate.t()],
          coverage_error: coverage_error() | nil,
          fingerprint: String.t()
        }
  @type write_result :: %{
          optional(:service_id) => String.t(),
          calendar: Calendar.t() | nil,
          attributes: CalendarAttribute.t() | nil,
          exceptions: [CalendarDate.t()],
          fingerprint: String.t()
        }
  @type error ::
          :not_found
          | :forbidden
          | :stale_review
          | :invalid_command
          | :invalid_input
          | :busy
          | :native_service_required
          | :reversed_range
          | {:in_use, non_neg_integer(), [String.t()]}
          | {:closures_in_use, calendar_usage()}
          | {:closure_reference_lost, calendar_usage()}
  @type write_error :: Ecto.Changeset.t() | error()
  @type feed_gap :: %{first_date: Date.t(), last_date: Date.t()}
  @type review_result :: %{
          fingerprint: String.t(),
          changes: map(),
          warnings: list(),
          affected_service_ids: [String.t()],
          active_date_count: non_neg_integer()
        }
  @type combination_review :: %{
          action: :combine,
          ready?: boolean(),
          fingerprint: String.t() | nil,
          conflicts: [Combination.conflict()],
          effects: [Combination.effect()],
          moved_trip_count: non_neg_integer(),
          retained_sources: [String.t()],
          block_effects: Blocking.combination_projection() | nil,
          plan: Combination.plan()
        }
  @type combination_apply_result :: %{
          action: :combined | :unchanged,
          operation_id: Ecto.UUID.t() | nil,
          destination_id: String.t(),
          moved_trip_count: non_neg_integer(),
          changed_trip_ids: [Ecto.UUID.t()],
          affected_service_ids: [String.t()]
        }

  @doc """
  Lists every calendar identity in one published organization/version.

  Returns one summary per service ID found in the weekly, exception or metadata
  tables, ordered by display name then service ID. `kind` is `:weekly` only when
  a weekly row exists. Each summary carries the grouped trip count, the effective
  first/last active dates, a source fingerprint and the `ServiceDates` warnings
  for the supplied `:today` (defaulting to the agency-local date resolved through
  PostgreSQL). Reads never write.

  The `status` projection answers the list filters without exposing raw date sets:
  `active_today?` tests the effective active set, `active_period?` tests a derived
  weekly period containing today (falling back to the effective set for
  dates-only calendars and out-of-range additions), `ends_soon?`/`ended?` and
  `days_remaining` come from the same warning pass, and `used_by_trips?` reads the
  grouped usage count.

  A weekly row whose range ends before it starts is accepted by the import and
  refused by the date evaluator, so it is reported as `:coverage_error` with no
  derived dates instead of raising: the identity, name, kind and grouped usage stay
  readable, and its status asserts no date fact, including no empty service.

  `opts`: `:today` as above, `:sort_by` (`:name` default or `:period`) and
  `:sort_dir` (`:asc` default or `:desc`). Period order uses the first effective
  active date, with identities that have no active date last in both directions.

  Returns `{:error, :not_found}` for a foreign, invalid or unpublished scope.
  """
  @spec list_calendars(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, [summary()]} | {:error, :not_found}
  def list_calendars(organization_id, version_id, opts \\ []) when is_list(opts) do
    transact(fn ->
      lock_shared_published_version!(organization_id, version_id)
      build_summaries(organization_id, version_id, opts)
    end)
  end

  @doc """
  Loads one coherent calendar screen snapshot for the list surface.

  Returns the calendar `:rows` together with the version-wide coverage facts that
  belong to the same protected read: the single agency-local `:today` and its
  `:zone` resolution, the global `:horizon` and the version-wide service `:gaps`,
  plus `complete?` and `:invalid_calendars`.

  Every row carries its exception rows, its derived `:periods` (weekly periods,
  breaks, holidays, extra days, removed days) and its grouped route `:routes`, so
  the list, the coverage axis and the detail inspector read one shape instead of
  re-deriving dates. The read never writes.

  `opts` supports `:sort_by`/`:sort_dir` with `list_calendars/3` semantics and
  `:service_ids`, an exact-ID allowlist that limits `:rows` only: the global
  horizon and gaps are computed over every identity in the version before that
  filter is applied, so filtering a source list never changes them. The clock is
  resolved once for the whole read, so a caller-supplied `:today` is not used.

  A version holding a retained invalid weekly range cannot assert a complete feed:
  `:invalid_calendars` names each identified error, `complete?` is `false` and
  `:gaps` is `nil` instead of a gap set that silently ignores the unreadable
  identity. Every readable identity keeps its exact dates, periods and usage, and
  the horizon covers those evaluated dates only.

  Returns `{:error, :not_found}` for a foreign, invalid or unpublished scope.
  """
  @spec load_screen(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, screen()} | {:error, :not_found}
  def load_screen(organization_id, version_id, opts \\ []) when is_list(opts) do
    transact(fn ->
      lock_shared_published_version!(organization_id, version_id)
      clock = DisplayClock.today(organization_id, version_id)

      summaries =
        build_summaries(organization_id, version_id, Keyword.put(opts, :today, clock.date))

      active = summaries |> Enum.flat_map(& &1.active_dates) |> MapSet.new()
      invalid_calendars = summaries |> Enum.map(& &1.coverage_error) |> Enum.reject(&is_nil/1)

      %{
        rows: filter_summaries(summaries, opts),
        invalid_calendars: invalid_calendars,
        today: clock.date,
        zone: clock,
        horizon: horizon(active),
        gaps: if(invalid_calendars == [], do: missing_runs(active)),
        complete?: invalid_calendars == []
      }
    end)
  end

  @doc """
  Loads one calendar identity as its weekly row, metadata anchor, exceptions and source fingerprint.

  A service ID that appears in none of the three tables returns
  `{:error, :not_found}`; a load never invents an anchor row.

  The editor needs the same derived values the list shows, so one coherent load
  additionally carries the identity `:kind`, the effective `:active_dates`, the
  derived `:periods`, the `:warnings` at the agency-local today, that `:today`
  together with the resolved agency `:zone` (including its UTC fallback reason)
  and the grouped `:usage`. Deriving them here keeps the editor from re-implementing
  `ServiceDates` or resolving a second, disagreeing clock.

  A weekly row whose range ends before it starts is classified as in
  `list_calendars/3`: `:coverage_error` names it and the derived `:active_dates`,
  `:periods` and `:warnings` are empty instead of raising, so the editor can open the
  calendar and correct its dates. `:coverage_error` is `nil` for a readable calendar.
  """
  @spec get_calendar(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, payload()} | {:error, :not_found}
  def get_calendar(organization_id, version_id, service_id) when is_binary(service_id) do
    transact(fn ->
      lock_shared_published_version!(organization_id, version_id)
      source = payload(organization_id, version_id, service_id) || Repo.rollback(:not_found)
      clock = DisplayClock.today(organization_id, version_id)
      exceptions = source.exceptions
      calendar = source.calendar
      usage = one_usage(organization_id, version_id, service_id)
      input_errors = retained_input_errors(calendar, exceptions)
      derived = derived_dates(input_errors, calendar, exceptions, usage, clock.date)

      source
      |> Map.put(:kind, kind_for(calendar))
      |> Map.put(:coverage_error, List.first(input_errors))
      |> Map.put(:active_dates, derived.active_dates)
      |> Map.put(:periods, derived.periods)
      |> Map.put(:warnings, derived.warnings)
      |> Map.put(:today, clock.date)
      |> Map.put(:zone, clock)
      |> Map.put(:usage, usage)
    end)
  end

  def get_calendar(_organization_id, _version_id, _service_id), do: {:error, :not_found}

  @doc """
  Returns the scoped trip and closure usage of one calendar identity grouped by route.

  The result carries the total `trip_count`, the sorted distinct `route_ids`, one
  `%{route_id: ..., trip_count: ...}` entry per route, plus the existence-only
  closure usage: `closure_count`, the sorted distinct `pathway_ids` and one
  `closure_paths` entry per pathway with its owning `station_stop_ids` resolved
  from scoped endpoint ancestry. This is what the detail view and the
  blocked-delete explanation need. Usage of other versions or organizations is
  never included.
  """
  @spec calendar_usage(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, calendar_usage()} | {:error, :not_found}
  def calendar_usage(organization_id, version_id, service_id) when is_binary(service_id) do
    transact(fn ->
      lock_shared_published_version!(organization_id, version_id)

      if service_id_taken?(organization_id, version_id, service_id) do
        usage = one_usage(organization_id, version_id, service_id)
        Map.put(usage, :service_id, service_id)
      else
        Repo.rollback(:not_found)
      end
    end)
  end

  def calendar_usage(_organization_id, _version_id, _service_id), do: {:error, :not_found}

  @doc """
  Returns the maximal civil-date runs with no service on any calendar in the version.

  The span is the earliest to the latest effective active date across every
  identity in the scope, so unused calendars are included, an empty feed has no
  gaps, and metadata-only identities add no coverage. Gaps are not extended to
  `feed_info` dates or to infinity, and describe calendar coverage rather than an
  asserted transit outage.

  `today` is accepted for the list-page call shape; gap detection is defined by
  the version's own effective span and therefore does not depend on the current
  date.
  """
  @spec feed_service_gaps(Ecto.UUID.t(), Ecto.UUID.t(), Date.t()) ::
          {:ok, [feed_gap()]} | {:error, :not_found}
  def feed_service_gaps(organization_id, version_id, _today) do
    transact(fn ->
      lock_shared_published_version!(organization_id, version_id)

      calendars = calendar_rows(organization_id, version_id)
      exceptions = exception_rows(organization_id, version_id)

      active =
        organization_id
        |> union_service_ids(version_id)
        |> Enum.reduce(MapSet.new(), fn service_id, acc ->
          MapSet.union(
            acc,
            MapSet.new(
              ServiceDates.active_dates(
                Map.get(calendars, service_id),
                Map.get(exceptions, service_id, [])
              )
            )
          )
        end)

      missing_runs(active)
    end)
  end

  @doc """
  Creates one weekly or dates-only calendar under the scoped write lock.

  `attrs` requires a non-empty binary `service_id`, a trimmed non-empty unique
  `name` (stored as the MBTA `service_description`), and `kind`. A `:weekly`
  create requires at least one service day and an ordered date range; a
  `:dates_only` create requires at least one addition and writes no weekly row.
  Scope fields come from the audit context, never from `attrs`. The metadata
  anchor is always reserved, and `attrs` may supply `service_schedule_name`,
  `service_schedule_type`, `service_schedule_typicality`, `rating_start_date`,
  `rating_end_date` and `rating_description`.

  Field failures return the changeset that owns them: attribute, identity and name
  problems on the `CalendarAttribute` changeset, and service-day, date-order and
  addition problems on the `Calendar` changeset. A successful create returns the
  read payload plus its `service_id`.
  """
  @spec create_calendar(map(), AuditContext.t()) ::
          {:ok, write_result()} | {:error, write_error()}
  def create_calendar(attrs, %AuditContext{} = audit_context) when is_map(attrs) do
    with {:ok, service_id} <- create_service_id(attrs) do
      transact(fn ->
        authorize_editor!(audit_context)
        lock_published_version!(audit_context)
        create_locked!(service_id, attrs, audit_context)
      end)
    end
  end

  def create_calendar(_attrs, _audit_context), do: {:error, :invalid_input}

  @doc """
  Duplicates one calendar identity under the write lock.

  The copy receives an available `_copy` service ID and an available `(copy)`
  display name, both advancing numerically through existing collisions, copies the
  weekly row, every exception and the metadata values, copies no trips and leaves
  the source unchanged. `attrs` may supply an explicit `service_id` or `name`;
  an explicit value that is blank or collides is refused with a field error
  instead of being silently re-suffixed.
  """
  @spec duplicate_calendar(String.t(), map(), AuditContext.t()) ::
          {:ok, write_result()} | {:error, write_error()}
  def duplicate_calendar(service_id, attrs, %AuditContext{} = audit_context)
      when is_binary(service_id) and is_map(attrs) do
    transact(fn ->
      authorize_editor!(audit_context)
      lock_published_version!(audit_context)
      duplicate_locked!(service_id, attrs, audit_context)
    end)
  end

  def duplicate_calendar(_service_id, _attrs, _audit_context), do: {:error, :invalid_input}

  @doc """
  Reviews a calendar command against the fingerprints the caller loaded.

  `source_fingerprints` must map every normalized command target to the exact
  fingerprint loaded with that form or drawer source; missing, extra, blank or
  nil entries are refused before a review token exists. The retained sources are
  compared with the current rows, then the command is planned: validation errors
  return the owning changeset, an in-use conversion or delete returns
  `{:in_use, trip_count, route_ids}`, a delete blocked only by scheduled closures
  returns `{:closures_in_use, usage}`, a plan that would drop the last native row of a
  closure-referenced service returns `{:closure_reference_lost, usage}`, a
  single-calendar command on a calendar whose range ends before it starts returns
  `:reversed_range` unless it is a delete or a save that supplies a new range, and
  otherwise the result carries the reviewed
  `changes`, projected `warnings`, the `affected_service_ids` that would change, the
  projected `active_date_count` and a command-bound `fingerprint` that
  `apply_calendar_change/3` requires. The shared version lock is released before the
  caller renders the review.

  The combination command `{:combine, destination_id, source_ids, decisions}` is
  reviewed from the complete protected input set instead of one retained form source:
  `source_fingerprints` must map every selected ID, the destination and every source,
  and the result is `action: :combine` with the reviewed `conflicts`, the per-calendar
  `effects`, the `moved_trip_count`, the `retained_sources`, the simultaneous
  `block_effects` and a `fingerprint` over the loaded rows. An incomplete decision set
  has no `result_dates`, no block effects and no fingerprint, and a destination that
  cannot carry the result natively returns `:native_service_required`. The token is
  computed from the rows the server just loaded, so the supplied fingerprint values are
  only required to be present and well shaped: they are never hashed.
  """
  @spec review_calendar_change(term(), map(), AuditContext.t()) ::
          {:ok, review_result() | combination_review()} | {:error, write_error()}
  def review_calendar_change(command, source_fingerprints, %AuditContext{} = audit_context) do
    with {:ok, normalized} <- normalize_command(command),
         :ok <- normalize_source_fingerprints(source_fingerprints, command_targets(normalized)) do
      transact(fn -> review_in_transaction!(normalized, source_fingerprints, audit_context) end)
    end
  end

  @doc """
  Applies a previously reviewed calendar command under the write lock.

  The reviewed fingerprint is recomputed from the current rows and the normalized
  command before anything changes, so another committed change or a different
  command returns `{:error, :stale_review}` with no writes. A command whose stored
  rows do not change writes nothing and adds no audit record.

  The combination command `{:combine, destination_id, source_ids, decisions}` applies the
  reviewed move in one ordinary read-committed transaction: the scoped loader of
  `review_calendar_change/3` runs once, the review is recomputed from the map it returned and
  compared with the submitted token, and only then are the destination's native rows, every
  source trip, the reviewed block clears and their audit logs written together. The result is
  `%{action: :combined | :unchanged, operation_id: uuid | nil, destination_id: id,
  moved_trip_count: n, changed_trip_ids: [uuid], affected_service_ids: [id]}`; a no-op has a
  nil `operation_id` and writes no anchor, row or log. A serialization failure or deadlock
  retries the whole transaction at most three times and then returns `{:error, :busy}`; every
  domain refusal is returned unchanged without retrying.
  """
  @spec apply_calendar_change(term(), term(), AuditContext.t()) ::
          {:ok, map() | combination_apply_result()} | {:error, write_error()}
  def apply_calendar_change(command, review_fingerprint, %AuditContext{} = audit_context) do
    with {:ok, normalized} <- normalize_command(command),
         :ok <- validate_review_fingerprint(review_fingerprint) do
      dispatch_calendar_change(normalized, review_fingerprint, audit_context)
    end
  end

  # A combination has its own retried read-committed transaction; every retained-form command
  # keeps the shared version-share write body below.
  defp dispatch_calendar_change(
         {:combine, _destination_id, _source_ids, _decisions} = normalized,
         review_fingerprint,
         audit_context
       ) do
    apply_combination(normalized, review_fingerprint, audit_context)
  end

  defp dispatch_calendar_change(normalized, review_fingerprint, audit_context) do
    transact(fn ->
      authorize_editor!(audit_context)
      lock_published_version!(audit_context)
      apply!(normalized, review_fingerprint, audit_context)
    end)
  end

  # The internal entrypoint a calendar combination is reviewed and applied from. It is not a
  # public command and adds no endpoint: `review_calendar_change/3` and `apply_calendar_change/3`
  # call it inside their own ordinary `Repo.transaction/1` (READ COMMITTED, never the configured
  # `ReviewedApplyTransaction` SERIALIZABLE adapter) and both consume the same loaded map, so a
  # review and its apply can never disagree about which rows were protected.
  #
  # Inside that transaction it asserts the isolation it needs, acquires the scoped published
  # version `FOR UPDATE` before any snapshot read, re-resolves and holds the actor's current
  # active editor membership `FOR SHARE`, loads the trip closure this combination's consequences
  # depend on, takes the established lower locks, and only then reads the authoritative derived
  # rows and raw rows through the real `Blocking.Queries` producer. Every read is batched: the
  # number of queries does not grow with the number of trips.
  @doc false
  @spec load_combination_inputs!(
          {:combine, String.t(), [String.t()], map()},
          AuditContext.t()
        ) :: Blocking.combination_inputs()
  def load_combination_inputs!(
        {:combine, destination_id, source_ids, _decisions},
        %AuditContext{} = audit_context
      )
      when is_binary(destination_id) and is_list(source_ids) do
    assert_read_committed!()
    lock_published_version!(audit_context)
    lock_editor_membership!(audit_context)

    selected_ids = [destination_id | source_ids]
    {closure, transfers} = combination_closure!(audit_context, selected_ids)
    lock_combination_closure!(audit_context, closure)

    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id
    trip_ids = Enum.map(closure, & &1.id)

    raw_trips = Queries.trip_identities(organization_id, version_id, {:uuids, trip_ids})
    trips = Queries.trip_rows(organization_id, version_id, {:uuids, trip_ids})
    sources = Queries.raw_sources(organization_id, version_id, trip_ids)
    raw_settings = settings_rows(organization_id, version_id)
    calendars = combination_calendars!(audit_context, closure, selected_ids)
    selected = MapSet.new(selected_ids)

    %{
      calendars: calendars,
      trips: trips,
      selected_trip_ids:
        raw_trips
        |> Enum.filter(&MapSet.member?(selected, &1.service_id))
        |> Enum.map(& &1.id),
      transfers: transfers,
      settings: absent_marker(Blocking.get_settings(organization_id, version_id), raw_settings),
      raw: %{
        selected_calendars: combination_snapshots(calendars, selected_ids),
        trips: raw_trips,
        stop_times: sources.stop_times,
        frequencies: sources.frequencies,
        stops: sources.stops,
        parents: sources.parents,
        settings: raw_settings,
        transfers: transfers,
        agencies: agency_rows(organization_id, version_id)
      },
      today: DisplayClock.today(organization_id, version_id).date
    }
  end

  # -- Combination inputs ---------------------------------------------------

  @read_committed "read committed"

  # A combination never runs inside an earlier repeatable snapshot: a SERIALIZABLE or
  # REPEATABLE READ enclosing transaction keeps returning its pre-wait rows after the version
  # lock, so the internal boundary refuses it instead of claiming a freshness it cannot observe
  # (critique M1). An ordinary `Repo.transaction/1` and the SQL sandbox's read-committed
  # transaction both pass; the configured SERIALIZABLE apply adapter does not.
  defp assert_read_committed! do
    %Postgrex.Result{rows: [[isolation]]} = Repo.query!("SHOW transaction_isolation")

    if isolation == @read_committed do
      :ok
    else
      Repo.rollback({:unsupported_isolation, isolation})
    end
  end

  # AC-13: the actor's *current* membership is resolved again after the version-lock wait and
  # held `FOR SHARE` through commit, so a revocation committed while a combination waited is
  # refused and a later one waits for it. `authorize_editor!/1` is not reused because it reads
  # the membership without the lock this read has to hold.
  defp lock_editor_membership!(%AuditContext{} = audit_context) do
    case editor_membership_for_share(audit_context) do
      %UserOrgMembership{deactivated_at: nil, roles: roles} ->
        if editor_role?(roles), do: :ok, else: Repo.rollback(:forbidden)

      _other ->
        Repo.rollback(:forbidden)
    end
  end

  defp editor_membership_for_share(%AuditContext{
         actor_id: actor_id,
         organization_id: organization_id
       }) do
    if uuid?(actor_id) and uuid?(organization_id) do
      from(m in UserOrgMembership,
        where: m.user_id == ^actor_id and m.organization_id == ^organization_id,
        lock: "FOR SHARE"
      )
      |> Repo.one()
    end
  end

  # AC-14/AC-17: the closure starts at every selected trip and grows through the rows that decide
  # the reviewed consequences - every trip on a touched non-nil block anywhere in the version,
  # every type-4/5 record naming one of those trips, each record's counterpart trip and every
  # trip on a counterpart's block, because an in-seat sequence is read over the whole block.
  # Identities are deduplicated by UUID. The values used downstream are read again after the
  # lower locks through `Queries.trip_rows/3`, so this discovery read decides the lock set only.
  defp combination_closure!(%AuditContext{} = audit_context, selected_ids) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    selected = Queries.trip_identities(organization_id, version_id, {:services, selected_ids})
    selected_blocks = block_ids(selected)

    companions =
      selected ++ Queries.trip_identities(organization_id, version_id, {:blocks, selected_blocks})

    companion_trip_ids = natural_trip_ids(companions)

    transfers = Queries.in_seat_rows(organization_id, version_id, companion_trip_ids)

    counterparts =
      transfers
      |> Enum.flat_map(&[&1.from_trip_id, &1.to_trip_id])
      |> excluding(companion_trip_ids)
      |> then(&Queries.trip_identities(organization_id, version_id, {:trip_ids, &1}))

    block_mates =
      Queries.trip_identities(
        organization_id,
        version_id,
        {:blocks, excluding(block_ids(counterparts), selected_blocks)}
      )

    {dedupe_trips(companions ++ counterparts ++ block_mates), transfers}
  end

  # INV-1: after the exclusive version lock the command's lower locks follow the established
  # order - the closure's routes and patterns in sorted order, the version's blocking advisory
  # lock and finally the closure's trip rows in UUID order. A route or pattern this version does
  # not hold has nothing to lock and is skipped, exactly as an unlinked trip is for
  # `RoutePatterns.lock_pattern!/2`'s existing callers.
  defp lock_combination_closure!(%AuditContext{} = audit_context, trips) do
    routes = lock_combination_routes!(audit_context, trips)
    lock_combination_patterns!(audit_context, trips, routes)
    Blocking.lock_blocking!(audit_context.gtfs_version_id)

    Queries.lock_trips!(
      audit_context.organization_id,
      audit_context.gtfs_version_id,
      Enum.map(trips, & &1.id),
      [],
      []
    )

    :ok
  end

  defp lock_combination_routes!(%AuditContext{} = audit_context, trips) do
    trips
    |> distinct_values(& &1.route_id)
    |> scoped_route_ids(audit_context)
    |> Enum.map(&RoutePatterns.lock_published_route!(audit_context, &1))
  end

  defp lock_combination_patterns!(%AuditContext{} = audit_context, trips, routes) do
    route_by_route_id = Map.new(routes, &{&1.route_id, &1})

    trips
    |> distinct_values(& &1.route_pattern_id)
    |> scoped_patterns(audit_context)
    |> Enum.each(fn pattern ->
      case Map.get(route_by_route_id, pattern.route_id) do
        nil -> :ok
        route -> RoutePatterns.lock_pattern!(route, pattern.id)
      end
    end)
  end

  defp scoped_route_ids(route_ids, %AuditContext{} = audit_context) do
    from(r in Route,
      where:
        r.organization_id == ^audit_context.organization_id and
          r.gtfs_version_id == ^audit_context.gtfs_version_id and r.route_id in ^route_ids,
      order_by: r.route_id,
      select: r.route_id
    )
    |> Repo.all()
  end

  defp scoped_patterns(pattern_ids, %AuditContext{} = audit_context) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^audit_context.organization_id and
          p.gtfs_version_id == ^audit_context.gtfs_version_id and
          p.route_pattern_id in ^pattern_ids,
      order_by: [asc: p.route_id, asc: p.route_pattern_id],
      select: %{id: p.id, route_id: p.route_id}
    )
    |> Repo.all()
  end

  # Every service the closure's trips use plus every selected ID - a selected calendar with no
  # trips is still part of the plan - in the one batched summary read the list surface already
  # uses, so a service's date set is never loaded one identity at a time (AC-14).
  defp combination_calendars!(%AuditContext{} = audit_context, closure, selected_ids) do
    service_ids = MapSet.new(selected_ids ++ Enum.map(closure, & &1.service_id))

    case list_calendars(audit_context.organization_id, audit_context.gtfs_version_id) do
      {:ok, summaries} -> Enum.filter(summaries, &MapSet.member?(service_ids, &1.service_id))
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The exact selected snapshots `Combination.plan/5` and `Combination.encode/3` consume, keyed by
  # the exact service ID. A selected ID this version does not hold has no snapshot and is left
  # out, so the plan reports it as missing instead of reading an invented empty calendar.
  # Exceptions are ordered by date and type here so a digest of this map cannot depend on row
  # order.
  defp combination_snapshots(calendars, selected_ids) do
    by_service_id = Map.new(calendars, &{&1.service_id, &1})

    selected_ids
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn service_id, snapshots ->
      case Map.get(by_service_id, service_id) do
        nil ->
          snapshots

        summary ->
          Map.put(snapshots, service_id, %{
            calendar: summary.calendar,
            exceptions: Enum.sort_by(summary.exceptions, &exception_sort_key/1),
            attributes: summary.attributes,
            trip_count: summary.trip_count
          })
      end
    end)
  end

  # The absence of a stored settings row is kept, and the effective value still comes from
  # `Blocking.get_settings/2`, the owner of the real default, so the review can distinguish an
  # absent row from a stored default of the same value without a second definition of the default.
  defp absent_marker(%{min_layover_minutes: minutes}, raw_settings) do
    %{min_layover_minutes: minutes, absent?: raw_settings == []}
  end

  # -- Reviewed combination ------------------------------------------------

  # One complete reviewed combination, composed from the single protected load above: the pure
  # `Combination.plan/5` decides the union, the conflicts and the result, `Combination.encode/3`
  # proves the destination can carry that result natively while trips still reference it, and the
  # committed package-05 `Blocking` producer projects the simultaneous block and in-seat
  # consequences. Nothing is written: the digest below is the only authority an apply accepts, and
  # every lock is released when this transaction returns, before the caller renders the review.
  defp review_combination!(
         {:combine, destination_id, source_ids, decisions} = normalized,
         %AuditContext{} = audit_context
       ) do
    inputs = load_combination_inputs!(normalized, audit_context)

    case Combination.plan(
           inputs.raw.selected_calendars,
           destination_id,
           source_ids,
           decisions,
           inputs.today
         ) do
      {:ok, plan} -> combination_review(normalized, inputs, plan, audit_context)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp combination_review(
         {:combine, destination_id, source_ids, _decisions} = normalized,
         inputs,
         plan,
         %AuditContext{} = audit_context
       ) do
    if plan.ready? do
      validate_native_destination!(inputs, destination_id, source_ids, plan.result_dates)

      %{
        action: :combine,
        ready?: true,
        fingerprint: combination_fingerprint(inputs, normalized, plan, audit_context),
        conflicts: plan.conflicts,
        effects: plan.effects,
        moved_trip_count: moved_trip_count(inputs, source_ids),
        retained_sources: Enum.sort(source_ids),
        block_effects:
          Blocking.project_calendar_combination(inputs, %{
            destination_id: destination_id,
            source_ids: source_ids,
            result_dates: plan.result_dates
          }),
        plan: plan
      }
    else
      incomplete_combination_review(inputs, source_ids, plan)
    end
  end

  # An undecided review has no committed result, so it has no projected final block effects and no
  # applicable token: the union, the conflicts and the source facts are honest, but nothing here may
  # be applied and no decision is implied.
  defp incomplete_combination_review(inputs, source_ids, plan) do
    %{
      action: :combine,
      ready?: false,
      fingerprint: nil,
      conflicts: plan.conflicts,
      effects: plan.effects,
      moved_trip_count: moved_trip_count(inputs, source_ids),
      retained_sources: Enum.sort(source_ids),
      block_effects: nil,
      plan: plan
    }
  end

  # AC-10 before the editor confirms: a projected destination with neither a weekly row nor an
  # exception row, while any trip would still reference it after the moves, cannot be applied, so the
  # review returns the same `:native_service_required` the write path will. Every trip of every moving
  # source references the destination once the reviewed moves are applied.
  defp validate_native_destination!(inputs, destination_id, source_ids, result_dates) do
    selected = inputs.raw.selected_calendars

    post_move_trip_count =
      Map.fetch!(selected, destination_id).trip_count + moved_trip_count(inputs, source_ids)

    case Combination.encode(
           Map.fetch!(selected, destination_id),
           result_dates,
           post_move_trip_count
         ) do
      {:ok, _encoded} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A combination moves every trip of every source calendar, so this is the reviewed move count.
  # The counts are the scoped grouped usage the loader read, never a client total.
  defp moved_trip_count(inputs, source_ids) do
    source_ids
    |> Enum.map(&Map.fetch!(inputs.raw.selected_calendars, &1).trip_count)
    |> Enum.sum()
  end

  # The complete-input digest: the one authority a combination apply accepts. It binds the
  # organization/version scope, the exact command (destination, sorted exact selected IDs and the
  # normalized decisions), the resolved result dates and agency-local review date, the closure's
  # calendar rows - every selected weekly/attribute/exception row and every non-selected companion
  # calendar whose dates decide a moved block (AC-17) - and the rows the review actually read:
  # trip UUIDs/natural IDs and their mutable columns, endpoint stop times, frequencies, endpoint
  # stops and their parents including absence, the settings row or its absence, the transfer rows
  # and the agency rows that resolved the date and zone. Same-count replacement, retiming, a
  # minimum-layover, parent or midnight change all move it; a client-supplied total cannot, because
  # no client value is hashed and every collection below comes from the loader in the deterministic
  # order `Queries` documents (trips by UUID, raw sources and transfers by their natural keys,
  # settings at most one row per version, agencies by agency ID).
  defp combination_fingerprint(
         inputs,
         {:combine, destination_id, source_ids, decisions},
         plan,
         %AuditContext{} = audit_context
       ) do
    raw = inputs.raw

    digest(%{
      action: :combine,
      scope: {audit_context.organization_id, audit_context.gtfs_version_id},
      destination_id: destination_id,
      source_ids: Enum.sort(source_ids),
      decisions: decisions,
      result_dates: plan.result_dates,
      today: inputs.today,
      calendars: combination_calendar_rows(inputs.calendars),
      trips: raw.trips,
      stop_times: raw.stop_times,
      frequencies: raw.frequencies,
      stops: raw.stops,
      parents: raw.parents,
      settings: raw.settings,
      transfers: raw.transfers,
      agencies: raw.agencies
    })
  end

  # The closure's stored rows, not the list surface's presentation summary: the weekly row, the
  # metadata anchor, the exceptions in date order, the evaluated active dates and the grouped trip
  # count, one entry per exact service ID in ID order. Every selected row is here, and so is every
  # non-selected companion calendar. The summary's own display fields - warnings, status, periods,
  # routes - are derived for the list and are deliberately not hashed.
  defp combination_calendar_rows(calendars) do
    calendars
    |> Enum.sort_by(& &1.service_id)
    |> Enum.map(fn calendar ->
      %{
        service_id: calendar.service_id,
        calendar: calendar.calendar,
        attributes: calendar.attributes,
        exceptions: Enum.sort_by(calendar.exceptions, &exception_sort_key/1),
        active_dates: calendar.active_dates,
        trip_count: calendar.trip_count
      }
    end)
  end

  defp exception_sort_key(%CalendarDate{} = exception) do
    date = exception.date
    {date.year, date.month, date.day, exception.exception_type}
  end

  defp settings_rows(organization_id, version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id,
      select: %{id: s.id, min_layover_minutes: s.min_layover_minutes, updated_at: s.updated_at}
    )
    |> Repo.all()
  end

  defp agency_rows(organization_id, version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id,
      order_by: a.agency_id,
      select: %{
        id: a.id,
        agency_id: a.agency_id,
        agency_name: a.agency_name,
        agency_timezone: a.agency_timezone,
        agency_lang: a.agency_lang
      }
    )
    |> Repo.all()
  end

  defp block_ids(trips), do: distinct_values(trips, & &1.block_id)

  defp natural_trip_ids(trips), do: distinct_values(trips, & &1.trip_id)

  defp dedupe_trips(trips) do
    trips |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)
  end

  defp distinct_values(values, fun) do
    values |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  defp excluding(values, known) do
    known = MapSet.new(known)
    values |> Enum.uniq() |> Enum.reject(&MapSet.member?(known, &1))
  end

  # The anchor supplies the audit `entity_id`; aggregate before/after snapshots are
  # passed explicitly by this module instead of being inferred from the anchor.
  @doc false
  @spec audit_snapshot(CalendarAttribute.t()) :: map()
  def audit_snapshot(%CalendarAttribute{} = anchor), do: attribute_snapshot(anchor)

  # -- Read composition ------------------------------------------------------

  defp build_summaries(organization_id, version_id, opts) do
    calendars = calendar_rows(organization_id, version_id)
    attributes = attribute_rows(organization_id, version_id)
    exceptions = exception_rows(organization_id, version_id)
    usage = usage_rows(organization_id, version_id)
    today = resolve_today(organization_id, version_id, opts)

    organization_id
    |> union_service_ids(version_id)
    |> Enum.map(
      &summary(&1, organization_id, version_id, calendars, attributes, exceptions, usage, today)
    )
    |> Enum.sort_by(fn summary -> {display_sort_key(summary), summary.service_id} end)
    |> sort_summaries(opts)
  end

  defp sort_summaries(summaries, opts) do
    case {Keyword.get(opts, :sort_by, :name), Keyword.get(opts, :sort_dir, :asc)} do
      {:period, direction} -> sort_by_period(summaries, direction)
      {_name, :desc} -> Enum.sort_by(summaries, &{display_sort_key(&1), &1.service_id}, :desc)
      {_name, _ascending} -> summaries
    end
  end

  defp sort_by_period(summaries, direction) do
    {dated, undated} = Enum.split_with(summaries, & &1.first_active_date)

    # `Date` structs compare by field name order, so the sort key uses the
    # chronological `{year, month, day}` tuple instead.
    sorted =
      Enum.sort_by(
        dated,
        &{Date.to_erl(&1.first_active_date), display_sort_key(&1), &1.service_id},
        direction
      )

    sorted ++ undated
  end

  defp summary(
         service_id,
         organization_id,
         version_id,
         calendars,
         attributes,
         exceptions,
         usage,
         today
       ) do
    calendar = Map.get(calendars, service_id)
    attribute = Map.get(attributes, service_id)
    service_exceptions = Map.get(exceptions, service_id, [])
    service_usage = Map.get(usage, service_id, empty_usage())
    input_errors = retained_input_errors(calendar, service_exceptions)

    derived =
      derived_dates(input_errors, calendar, service_exceptions, service_usage, today)

    %{
      service_id: service_id,
      exceptions: service_exceptions,
      periods: derived.periods,
      routes: service_usage.routes,
      name: attribute && attribute.service_description,
      kind: kind_for(calendar),
      calendar: calendar,
      attributes: attribute,
      trip_count: service_usage.trip_count,
      closure_count: service_usage.closure_count,
      pathway_ids: service_usage.pathway_ids,
      closure_paths: service_usage.closure_paths,
      coverage_error: List.first(input_errors),
      active_dates: derived.active_dates,
      first_active_date: List.first(derived.active_dates),
      last_active_date: List.last(derived.active_dates),
      fingerprint:
        source_fingerprint(
          organization_id,
          version_id,
          service_id,
          calendar,
          attribute,
          service_exceptions,
          service_usage
        ),
      warnings: derived.warnings,
      status: derived.status
    }
  end

  # A retained input the import accepts and the date evaluator refuses is
  # identified here rather than raised, so one malformed row cannot take down a
  # whole-version read. The import parser and the scoped date uniqueness constraint
  # already exclude exception-side malformed states, so only the reachable weekly
  # range is checked and no arbitrary `ArgumentError` is rescued.
  defp retained_input_errors(
         %Calendar{start_date: start_date, end_date: end_date} = calendar,
         _exceptions
       )
       when is_struct(start_date, Date) and is_struct(end_date, Date) do
    if Date.compare(end_date, start_date) == :lt do
      [%{service_id: calendar.service_id, reason: :reversed_range}]
    else
      []
    end
  end

  defp retained_input_errors(_calendar, _exceptions), do: []

  defp derived_dates([], calendar, exceptions, usage, today) do
    active_dates = ServiceDates.active_dates(calendar, exceptions)
    warnings = ServiceDates.warnings(calendar, exceptions, today)

    %{
      active_dates: active_dates,
      periods: ServiceDates.periods(calendar, exceptions),
      warnings: warnings,
      status:
        summary_status(calendar, exceptions, active_dates, warnings, usage.trip_count, today)
    }
  end

  # An identified invalid input keeps identity, name and usage but asserts no
  # derived date fact: `no_service?: false` stops the defect reading as empty
  # service, and the remaining flags stay unasserted rather than invented.
  defp derived_dates(_errors, _calendar, _exceptions, usage, _today) do
    %{
      active_dates: [],
      periods: empty_periods(),
      warnings: [],
      status: %{
        no_service?: false,
        ended?: false,
        ends_soon?: false,
        days_remaining: nil,
        active_today?: false,
        active_period?: false,
        used_by_trips?: usage.trip_count > 0
      }
    }
  end

  defp summary_status(calendar, exceptions, active_dates, warnings, trip_count, today) do
    ends_soon = Enum.find(warnings, &match?(%{reason: :ends_soon}, &1))

    %{
      no_service?: active_dates == [],
      ended?: Enum.any?(warnings, &match?(%{reason: :ended}, &1)),
      ends_soon?: ends_soon != nil,
      days_remaining: ends_soon && ends_soon.days_remaining,
      active_today?: today in active_dates,
      active_period?: active_period?(calendar, exceptions, active_dates, today),
      used_by_trips?: trip_count > 0
    }
  end

  defp active_period?(nil, _exceptions, active_dates, today), do: today in active_dates

  defp active_period?(%Calendar{} = calendar, exceptions, active_dates, today) do
    in_period? =
      calendar
      |> ServiceDates.periods(exceptions)
      |> Map.fetch!(:periods)
      |> Enum.any?(fn period ->
        Date.compare(period.first_date, today) in [:eq, :lt] and
          Date.compare(period.last_date, today) in [:eq, :gt]
      end)

    in_period? or today in active_dates
  end

  @doc """
  Returns the display-name ordering key the list uses: the trimmed, case-insensitive
  name, falling back to the service ID when the name is blank.

  The list sorts by this key and then by the exact service ID, so a caller that has to
  reproduce the same order - a default destination chosen by most trips, for instance -
  uses this function instead of restating the rule.
  """
  @spec display_sort_key(map()) :: String.t()
  def display_sort_key(%{name: name, service_id: service_id}) when is_binary(name) do
    case String.trim(name) do
      "" -> String.downcase(service_id)
      trimmed -> String.downcase(trimmed)
    end
  end

  def display_sort_key(%{service_id: service_id}), do: String.downcase(service_id)

  # The source-list filter limits the returned rows only. The global horizon and
  # gaps are computed over the whole version first, so a filtered view never
  # changes them, and exact IDs are compared without trimming.
  defp filter_summaries(summaries, opts) do
    case Keyword.get(opts, :service_ids) do
      service_ids when is_list(service_ids) ->
        wanted = MapSet.new(service_ids)
        Enum.filter(summaries, &MapSet.member?(wanted, &1.service_id))

      _all_identities ->
        summaries
    end
  end

  defp horizon(active) do
    case active |> MapSet.to_list() |> Enum.sort(Date) do
      [] -> nil
      dates -> %{first_date: List.first(dates), last_date: List.last(dates)}
    end
  end

  # The empty weekly structure `ServiceDates.periods/2` returns for a calendar
  # without a weekly row, without evaluating a retained reversed range.
  defp empty_periods do
    %{periods: [], breaks: [], holidays: [], extra_days: [], removed_days: []}
  end

  defp resolve_today(organization_id, version_id, opts) do
    case Keyword.get(opts, :today) do
      %Date{} = today -> today
      _other -> DisplayClock.today(organization_id, version_id).date
    end
  end

  defp payload(organization_id, version_id, service_id) do
    calendar = one_row(Calendar, organization_id, version_id, service_id)
    attributes = one_row(CalendarAttribute, organization_id, version_id, service_id)
    exceptions = one_exceptions(organization_id, version_id, service_id)

    if is_nil(calendar) and is_nil(attributes) and exceptions == [] do
      nil
    else
      usage = one_usage(organization_id, version_id, service_id)

      %{
        calendar: calendar,
        attributes: attributes,
        exceptions: exceptions,
        fingerprint:
          source_fingerprint(
            organization_id,
            version_id,
            service_id,
            calendar,
            attributes,
            exceptions,
            usage
          )
      }
    end
  end

  defp one_row(schema, organization_id, version_id, service_id) do
    Repo.one(
      from(row in schema,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
            row.service_id == ^service_id
      )
    )
  end

  defp one_exceptions(organization_id, version_id, service_id) do
    Repo.all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id and
            d.service_id == ^service_id,
        order_by: [asc: d.date, asc: d.exception_type]
      )
    )
  end

  defp calendar_rows(organization_id, version_id) do
    from(c in Calendar,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id
    )
    |> Repo.all()
    |> Map.new(&{&1.service_id, &1})
  end

  defp attribute_rows(organization_id, version_id) do
    from(a in CalendarAttribute,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id
    )
    |> Repo.all()
    |> Map.new(&{&1.service_id, &1})
  end

  defp exception_rows(organization_id, version_id) do
    from(d in CalendarDate,
      where: d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id,
      order_by: [asc: d.date, asc: d.exception_type]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.service_id)
  end

  defp union_service_ids(organization_id, version_id) do
    organization_id
    |> union_service_ids_query(version_id)
    |> Repo.all()
    |> Enum.sort()
  end

  # One grouped query per version: the union separates an exception-only or
  # metadata-only identity from a weekly one without a per-service lookup.
  defp union_service_ids_query(organization_id, version_id) do
    weekly =
      from(c in Calendar,
        where: c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id,
        select: c.service_id
      )

    exceptions =
      from(d in CalendarDate,
        where: d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id,
        select: d.service_id
      )

    metadata =
      from(a in CalendarAttribute,
        where: a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id,
        select: a.service_id
      )

    weekly |> union(^exceptions) |> union(^metadata)
  end

  defp service_id_taken?(organization_id, version_id, service_id) do
    query =
      from(s in subquery(union_service_ids_query(organization_id, version_id)),
        where: s.service_id == ^service_id,
        select: s.service_id,
        limit: 1
      )

    Repo.one(query) != nil
  end

  defp trip_usage_rows(organization_id, version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id,
      group_by: [t.service_id, t.route_id],
      select: {t.service_id, t.route_id, count(t.id)}
    )
    |> Repo.all()
    |> Enum.group_by(fn {service_id, _route_id, _count} -> service_id end)
    |> Map.new(fn {service_id, rows} ->
      {service_id,
       usage_from_grouped_rows(Enum.map(rows, fn {_, route_id, count} -> {route_id, count} end))}
    end)
  end

  defp one_usage(organization_id, version_id, service_id) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.service_id == ^service_id,
      group_by: t.route_id,
      select: {t.route_id, count(t.id)}
    )
    |> Repo.all()
    |> usage_from_grouped_rows()
    |> Map.merge(one_closure_usage(organization_id, version_id, service_id))
  end

  # Trip and closure usage merge into one per-service map so list summaries,
  # one_usage/3 and the source fingerprint always describe the same counts.
  defp usage_rows(organization_id, version_id) do
    trips = trip_usage_rows(organization_id, version_id)
    closures = closure_usage_rows(organization_id, version_id)

    for service_id <- Enum.uniq(Map.keys(trips) ++ Map.keys(closures)), into: %{} do
      {service_id,
       Map.merge(
         Map.get(trips, service_id, empty_trip_usage()),
         Map.get(closures, service_id, empty_closure_usage())
       )}
    end
  end

  defp usage_from_grouped_rows(rows) do
    routes = rows |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&route_usage/1)

    %{
      trip_count: Enum.sum(Enum.map(routes, & &1.trip_count)),
      route_ids: Enum.map(routes, & &1.route_id),
      routes: routes
    }
  end

  defp route_usage({route_id, trip_count}), do: %{route_id: route_id, trip_count: trip_count}

  defp empty_trip_usage, do: %{trip_count: 0, route_ids: [], routes: []}

  defp empty_closure_usage, do: %{closure_count: 0, pathway_ids: [], closure_paths: []}

  defp empty_usage, do: Map.merge(empty_trip_usage(), empty_closure_usage())

  # Closure usage is existence-only reference data: one count per closure row,
  # the exact distinct pathway IDs and one closure_paths entry per pathway whose
  # owning stations come from scoped endpoint ancestry. Usage of other versions
  # or organizations is never included.
  defp one_closure_usage(organization_id, version_id, service_id) do
    pathway_ids =
      Repo.all(
        from(e in PathwayEvolution,
          where:
            e.organization_id == ^organization_id and e.gtfs_version_id == ^version_id and
              e.service_id == ^service_id,
          select: e.pathway_id
        )
      )

    closure_usage(
      length(pathway_ids),
      pathway_ids,
      pathway_station_ids(organization_id, version_id, Enum.uniq(pathway_ids))
    )
  end

  defp closure_usage_rows(organization_id, version_id) do
    rows =
      Repo.all(
        from(e in PathwayEvolution,
          where: e.organization_id == ^organization_id and e.gtfs_version_id == ^version_id,
          select: {e.service_id, e.pathway_id}
        )
      )

    stations =
      pathway_station_ids(organization_id, version_id, Enum.uniq(Enum.map(rows, &elem(&1, 1))))

    rows
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {service_id, pathway_ids} ->
      {service_id, closure_usage(length(pathway_ids), pathway_ids, stations)}
    end)
  end

  defp closure_usage(count, pathway_ids, station_ids_by_pathway) do
    sorted = pathway_ids |> Enum.uniq() |> Enum.sort()

    %{
      closure_count: count,
      pathway_ids: sorted,
      closure_paths:
        Enum.map(sorted, fn pathway_id ->
          %{
            pathway_id: pathway_id,
            station_stop_ids: Map.get(station_ids_by_pathway, pathway_id, [])
          }
        end)
    }
  end

  defp pathway_station_ids(_organization_id, _version_id, []), do: %{}

  defp pathway_station_ids(organization_id, version_id, pathway_ids) do
    endpoints =
      Repo.all(
        from(p in Pathway,
          where:
            p.organization_id == ^organization_id and p.gtfs_version_id == ^version_id and
              p.pathway_id in ^pathway_ids,
          select: {p.pathway_id, p.from_stop_id, p.to_stop_id}
        )
      )

    station_ids_by_stop =
      endpoints
      |> Enum.flat_map(fn {_pathway_id, from_stop_id, to_stop_id} ->
        [from_stop_id, to_stop_id]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(&{&1, endpoint_station_ids(organization_id, version_id, &1)})

    Map.new(endpoints, fn {pathway_id, from_stop_id, to_stop_id} ->
      station_ids =
        [from_stop_id, to_stop_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&Map.get(station_ids_by_stop, &1, []))
        |> Enum.uniq()
        |> Enum.sort()

      {pathway_id, station_ids}
    end)
  end

  # Owning stations come from the station row at the top of each endpoint's
  # parent_station chain, boarding areas included. An endpoint without a
  # station ancestor contributes no link rather than an invented one.
  defp endpoint_station_ids(organization_id, version_id, stop_id, depth \\ 0)

  defp endpoint_station_ids(_organization_id, _version_id, _stop_id, depth) when depth > 4,
    do: []

  defp endpoint_station_ids(organization_id, version_id, stop_id, depth) do
    case one_stop(organization_id, version_id, stop_id) do
      %Stop{location_type: 1} ->
        [stop_id]

      %Stop{parent_station: parent_station}
      when is_binary(parent_station) and parent_station != "" ->
        endpoint_station_ids(organization_id, version_id, parent_station, depth + 1)

      _other ->
        []
    end
  end

  defp one_stop(organization_id, version_id, stop_id) do
    Repo.one(
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
            s.stop_id == ^stop_id
      )
    )
  end

  defp kind_for(nil), do: :dates_only
  defp kind_for(%Calendar{}), do: :weekly

  defp missing_runs(active) do
    case active |> MapSet.to_list() |> Enum.sort(Date) do
      [] ->
        []

      dates ->
        active
        |> missing_dates(List.first(dates), List.last(dates))
        |> chunk_runs()
    end
  end

  defp missing_dates(active, first_date, last_date) do
    first_date
    |> Date.range(last_date)
    |> Enum.reject(&MapSet.member?(active, &1))
  end

  defp chunk_runs([]), do: []

  defp chunk_runs(dates) do
    dates
    |> Enum.chunk_while(
      [],
      fn
        date, [] ->
          {:cont, [date]}

        date, [previous | _] = acc ->
          if Date.diff(date, previous) == 1 do
            {:cont, [date | acc]}
          else
            {:cont, Enum.reverse(acc), [date]}
          end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.map(fn run -> %{first_date: List.first(run), last_date: List.last(run)} end)
  end

  # -- Create ----------------------------------------------------------------

  defp create_locked!(service_id, attrs, audit_context) do
    kind = kind_value(attrs)
    attributes_changeset = anchor_changeset(service_id, attrs, audit_context)

    weekly = weekly_changeset(service_id, attrs, audit_context)

    with :ok <- validate_kind(kind),
         :ok <- validate_anchor(attributes_changeset),
         :ok <- validate_weekly(kind, weekly),
         :ok <- validate_service_id(attributes_changeset, audit_context),
         :ok <- validate_display_name(attributes_changeset, audit_context, nil),
         {:ok, additions} <- validate_additions(kind, attrs) do
      insert_created!(service_id, kind, attributes_changeset, weekly, additions, audit_context)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp create_service_id(attrs) do
    case fetch_value(attrs, :service_id) do
      service_id when is_binary(service_id) ->
        if String.trim(service_id) == "" do
          {:error, :invalid_input}
        else
          {:ok, String.trim(service_id)}
        end

      _other ->
        {:error, :invalid_input}
    end
  end

  defp requested_name(attrs),
    do: fetch_value(attrs, :name) || fetch_value(attrs, :service_description)

  defp anchor_changeset(service_id, attrs, audit_context) do
    %CalendarAttribute{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id
    }
    |> CalendarAttribute.changeset(
      attrs
      |> metadata_attrs()
      |> Map.put(:service_id, service_id)
      |> Map.put(:service_description, requested_name(attrs))
    )
  end

  defp weekly_changeset(service_id, attrs, audit_context) do
    values = Map.new(@weekly_fields, fn field -> {field, fetch_value(attrs, field)} end)

    %Calendar{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id
    }
    |> Calendar.changeset(Map.put(values, :service_id, service_id))
  end

  defp metadata_attrs(attrs) do
    Enum.reduce(@metadata_fields, %{}, fn field, acc ->
      if key_present?(attrs, field) do
        Map.put(acc, field, fetch_value(attrs, field))
      else
        acc
      end
    end)
  end

  defp kind_value(attrs) do
    case fetch_value(attrs, :kind) do
      :weekly -> :weekly
      :dates_only -> :dates_only
      "weekly" -> :weekly
      "dates_only" -> :dates_only
      _other -> :invalid
    end
  end

  defp validate_kind(kind) when kind in @kinds, do: :ok

  defp validate_kind(_kind) do
    {:error,
     %Calendar{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:kind, "is invalid")}
  end

  defp validate_anchor(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp validate_anchor(changeset) do
    case Ecto.Changeset.get_field(changeset, :service_description) do
      nil ->
        {:error, Ecto.Changeset.add_error(changeset, :service_description, "can't be blank")}

      "" ->
        {:error, Ecto.Changeset.add_error(changeset, :service_description, "can't be blank")}

      _name ->
        :ok
    end
  end

  defp validate_weekly(:dates_only, _changeset), do: :ok

  defp validate_weekly(:weekly, %Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  defp validate_weekly(:weekly, changeset) do
    service_day? =
      Enum.any?(@weekly_day_fields, fn field ->
        Ecto.Changeset.get_field(changeset, field) == 1
      end)

    cond do
      not service_day? ->
        {:error,
         Ecto.Changeset.add_error(changeset, :service_days, "select at least one service day")}

      Date.compare(
        Ecto.Changeset.get_field(changeset, :end_date),
        Ecto.Changeset.get_field(changeset, :start_date)
      ) == :lt ->
        {:error,
         Ecto.Changeset.add_error(changeset, :end_date, "must be on or after the start date")}

      true ->
        :ok
    end
  end

  defp validate_additions(:weekly, _attrs), do: {:ok, []}

  defp validate_additions(:dates_only, attrs) do
    case normalize_dates(fetch_value(attrs, :dates)) do
      {:ok, []} ->
        {:error, addition_error("add at least one service date")}

      {:ok, dates} ->
        {:ok, dates}

      :error ->
        {:error, addition_error("must be a list of valid dates")}
    end
  end

  defp addition_error(message) do
    %Calendar{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:dates, message)
  end

  defp validate_service_id(changeset, audit_context) do
    service_id = Ecto.Changeset.get_field(changeset, :service_id)

    if service_id_taken?(
         audit_context.organization_id,
         audit_context.gtfs_version_id,
         service_id
       ) do
      {:error, Ecto.Changeset.add_error(changeset, :service_id, @taken_message)}
    else
      :ok
    end
  end

  defp validate_display_name(changeset, audit_context, exclude_service_id) do
    name = Ecto.Changeset.get_field(changeset, :service_description)

    if name_taken?(
         audit_context.organization_id,
         audit_context.gtfs_version_id,
         name,
         exclude_service_id
       ) do
      {:error, Ecto.Changeset.add_error(changeset, :service_description, @taken_message)}
    else
      :ok
    end
  end

  defp insert_created!(
         service_id,
         kind,
         attributes_changeset,
         weekly_changeset,
         additions,
         audit_context
       ) do
    anchor = insert_or_rollback!(attributes_changeset)
    calendar = insert_weekly_row(kind, weekly_changeset)
    exceptions = insert_addition_rows(additions, service_id, audit_context)

    audited_created!(service_id, calendar, anchor, exceptions, audit_context)
  end

  # A dates-only create never inserts the validated weekly changeset, so the
  # calendar never gains a synthetic weekly row.
  defp insert_weekly_row(:dates_only, _weekly_changeset), do: nil
  defp insert_weekly_row(:weekly, weekly_changeset), do: insert_or_rollback!(weekly_changeset)

  defp insert_addition_rows([], _service_id, _audit_context), do: []

  defp insert_addition_rows(additions, service_id, audit_context) do
    Enum.map(additions, &insert_exception_row!(service_id, &1, @added, audit_context))
  end

  defp insert_exception_row!(service_id, date, exception_type, audit_context) do
    %CalendarDate{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id
    }
    |> CalendarDate.changeset(%{
      service_id: service_id,
      date: date,
      exception_type: exception_type
    })
    |> Ecto.Changeset.put_change(:service_id, service_id)
    |> insert_or_rollback!()
  end

  defp audited_created!(service_id, calendar, anchor, exceptions, audit_context) do
    after_snapshot = aggregate_snapshot(service_id, calendar, anchor, exceptions)
    audit!(audit_context, anchor, "created", %{before: nil, after: after_snapshot})

    usage = one_usage(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

    %{
      service_id: service_id,
      calendar: calendar,
      attributes: anchor,
      exceptions: exceptions,
      fingerprint:
        source_fingerprint(
          audit_context.organization_id,
          audit_context.gtfs_version_id,
          service_id,
          calendar,
          anchor,
          exceptions,
          usage
        )
    }
  end

  # -- Duplicate -------------------------------------------------------------

  defp duplicate_locked!(service_id, attrs, audit_context) do
    case payload(audit_context.organization_id, audit_context.gtfs_version_id, service_id) do
      nil ->
        Repo.rollback(:not_found)

      source ->
        duplicate_source!(service_id, source, attrs, audit_context)
    end
  end

  defp duplicate_source!(service_id, source, attrs, audit_context) do
    with {:ok, new_service_id} <- duplicate_service_id(service_id, attrs, audit_context),
         {:ok, name} <- duplicate_name(service_id, source, attrs, audit_context) do
      changeset = duplicate_anchor_changeset(source, attrs, new_service_id, name, audit_context)

      with :ok <- validate_anchor(changeset),
           :ok <- validate_service_id(changeset, audit_context),
           :ok <- validate_display_name(changeset, audit_context, nil) do
        insert_duplicate!(source, new_service_id, changeset, audit_context)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp duplicate_service_id(source_service_id, attrs, audit_context) do
    case fetch_value(attrs, :service_id) do
      nil -> {:ok, available_service_id(String.trim(source_service_id), audit_context)}
      requested when is_binary(requested) -> create_service_id(attrs)
      _other -> {:error, :invalid_input}
    end
  end

  defp duplicate_name(source_service_id, source, attrs, audit_context) do
    case requested_name(attrs) do
      nil ->
        {:ok, available_copy_name(duplicate_name_base(source_service_id, source), audit_context)}

      requested when is_binary(requested) ->
        {:ok, requested}

      _other ->
        {:error, :invalid_input}
    end
  end

  defp duplicate_anchor_changeset(source, attrs, service_id, name, audit_context) do
    %CalendarAttribute{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id
    }
    |> CalendarAttribute.changeset(
      duplicate_metadata(source, attrs)
      |> Map.put(:service_id, service_id)
      |> Map.put(:service_description, name)
    )
  end

  defp duplicate_metadata(source, attrs) do
    Enum.reduce(@metadata_fields, %{}, fn field, acc ->
      if key_present?(attrs, field) do
        Map.put(acc, field, fetch_value(attrs, field))
      else
        Map.put(acc, field, source_metadata_value(source.attributes, field))
      end
    end)
  end

  defp source_metadata_value(%CalendarAttribute{} = attributes, field),
    do: Map.get(attributes, field)

  defp source_metadata_value(nil, _field), do: nil

  defp duplicate_name_base(source_service_id, source) do
    case source.attributes do
      %CalendarAttribute{service_description: description} when is_binary(description) ->
        if String.trim(description) == "", do: source_service_id, else: description

      _other ->
        source_service_id
    end
  end

  # Successive `_copy` / `(copy)` suffixes advance through every existing
  # collision; the search is lazy, so it stops at the first available candidate.
  defp available_service_id(base, audit_context) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&copy_service_id_candidate(base, &1))
    |> Enum.find(fn candidate ->
      not service_id_taken?(
        audit_context.organization_id,
        audit_context.gtfs_version_id,
        candidate
      )
    end)
  end

  defp available_copy_name(base, audit_context) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&copy_name_candidate(base, &1))
    |> Enum.find(fn candidate ->
      not name_taken?(
        audit_context.organization_id,
        audit_context.gtfs_version_id,
        candidate,
        nil
      )
    end)
  end

  defp copy_service_id_candidate(base, 1), do: "#{base}_copy"
  defp copy_service_id_candidate(base, index), do: "#{base}_copy_#{index}"
  defp copy_name_candidate(base, 1), do: "#{base} (copy)"
  defp copy_name_candidate(base, index), do: "#{base} (copy #{index})"

  defp insert_duplicate!(source, service_id, attributes_changeset, audit_context) do
    anchor = insert_or_rollback!(attributes_changeset)
    calendar = copy_weekly_row(source.calendar, service_id, audit_context)
    exceptions = copy_exception_rows(source.exceptions, service_id, audit_context)

    audited_created!(service_id, calendar, anchor, exceptions, audit_context)
  end

  defp copy_weekly_row(nil, _service_id, _audit_context), do: nil

  defp copy_weekly_row(%Calendar{} = weekly, service_id, audit_context) do
    %Calendar{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id
    }
    |> Calendar.changeset(
      weekly
      |> Map.take(@weekly_fields)
      |> Map.put(:service_id, service_id)
    )
    |> insert_or_rollback!()
  end

  defp copy_exception_rows(exceptions, service_id, audit_context) do
    Enum.map(exceptions, fn exception ->
      %CalendarDate{
        organization_id: audit_context.organization_id,
        gtfs_version_id: audit_context.gtfs_version_id
      }
      |> CalendarDate.changeset(%{
        service_id: service_id,
        date: exception.date,
        exception_type: exception.exception_type
      })
      |> insert_or_rollback!()
    end)
  end

  # -- Applying a reviewed combination ---------------------------------------

  # One reviewed combination's write path. The whole transaction is retried only for a
  # serialization failure or a deadlock and never for a domain refusal (AC-19, `:busy`); the scoped
  # loader runs exactly once per attempt and the step-15 review is recomputed from the map it
  # returned, so the submitted token is always compared with the rows this transaction holds.
  defp apply_combination(
         normalized,
         review_fingerprint,
         audit_context,
         attempts \\ @combination_attempts
       ) do
    case combination_transaction(normalized, review_fingerprint, audit_context) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        retry_combination(reason, normalized, review_fingerprint, audit_context, attempts)
    end
  end

  defp combination_transaction(normalized, review_fingerprint, audit_context) do
    Repo.transaction(fn ->
      {:combine, destination_id, source_ids, decisions} = normalized
      inputs = load_combination_inputs!(normalized, audit_context)

      case Combination.plan(
             inputs.raw.selected_calendars,
             destination_id,
             source_ids,
             decisions,
             inputs.today
           ) do
        {:ok, plan} ->
          write_reviewed_combination!(normalized, inputs, plan, review_fingerprint, audit_context)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  rescue
    # The transaction is rolled back before this clause runs, and a serialization failure or
    # deadlock is retried as a whole with the rest of the operation.
    error in [Postgrex.Error] -> {:error, error}
  end

  # The review is recomputed from the one loaded input set instead of trusting the drawer: the
  # destination must still be natively encodable, and only a secure-equal token over the current
  # rows may write. An incomplete review has no applicable token, so any submitted fingerprint is
  # stale rather than addressable.
  defp write_reviewed_combination!(normalized, inputs, plan, review_fingerprint, audit_context) do
    if plan.ready? do
      review = combination_review(normalized, inputs, plan, audit_context)

      if secure_equal?(review.fingerprint, review_fingerprint) do
        write_combination!(normalized, inputs, plan, review, audit_context)
      else
        Repo.rollback(:stale_review)
      end
    else
      Repo.rollback(:stale_review)
    end
  end

  # AC-12 first: a combination that moves no trip and leaves the destination's effective dates
  # unchanged returns `:unchanged` with a nil operation UUID and writes no anchor, row or log. Any
  # real change gets one operation UUID and one envelope carrying the complete selection, the
  # changed trip IDs and the decisions.
  defp write_combination!(normalized, inputs, plan, review, audit_context) do
    {:combine, destination_id, source_ids, decisions} = normalized
    source = Map.fetch!(inputs.raw.selected_calendars, destination_id)
    moved = moved_trip_count(inputs, source_ids)

    encoded =
      case Combination.encode(source, plan.result_dates, source.trip_count + moved) do
        {:ok, encoded} -> encoded
        {:error, reason} -> Repo.rollback(reason)
      end

    if moved == 0 and not encoded.changed? do
      unchanged_combination(destination_id)
    else
      operation_id = Ecto.UUID.generate()
      trips = load_combination_trips!(inputs, source_ids, audit_context)

      envelope = %{
        destination_id: destination_id,
        selected_service_ids: Enum.sort([destination_id | source_ids]),
        changed_trip_ids: Enum.map(trips, & &1.id),
        decisions: decisions
      }

      # The envelope belongs on the destination calendar log when that calendar actually changes,
      # because that is the one real log carrying the command. A trip-only combination has no
      # calendar log at all, so the lowest changed-trip UUID log hosts it instead; no destination
      # log is fabricated for metadata.
      if encoded.changed? do
        write_combination_destination!(
          destination_id,
          source,
          encoded,
          %{operation_id: operation_id, combination: envelope},
          audit_context
        )
      end

      move_combination_trips!(
        trips,
        destination_id,
        source_ids,
        review.block_effects.cleared_trip_ids,
        %{
          operation_id: operation_id,
          combination: envelope,
          envelope_on_lowest_trip?: not encoded.changed?
        },
        audit_context
      )

      combined_combination(destination_id, trips, operation_id, moved, encoded)
    end
  end

  defp unchanged_combination(destination_id) do
    %{
      action: :unchanged,
      operation_id: nil,
      destination_id: destination_id,
      moved_trip_count: 0,
      changed_trip_ids: [],
      affected_service_ids: []
    }
  end

  defp combined_combination(destination_id, trips, operation_id, moved, encoded) do
    affected =
      if encoded.changed? or trips != [] do
        [destination_id | Enum.map(trips, & &1.service_id)] |> Enum.uniq() |> Enum.sort()
      else
        []
      end

    %{
      action: :combined,
      operation_id: operation_id,
      destination_id: destination_id,
      moved_trip_count: moved,
      changed_trip_ids: Enum.map(trips, & &1.id),
      affected_service_ids: affected
    }
  end

  # The moved rows are loaded once, in UUID order, for the audit snapshots and the exact count
  # checks. AC-11 moves every trip of every source service, so the loaded count must equal the
  # count the review read; a difference is a count error and rolls the whole operation back.
  defp load_combination_trips!(inputs, source_ids, audit_context) do
    trips =
      Repo.all(
        from(t in Trip,
          where:
            t.organization_id == ^audit_context.organization_id and
              t.gtfs_version_id == ^audit_context.gtfs_version_id and
              t.service_id in ^source_ids,
          order_by: [asc: t.id]
        )
      )

    expected = moved_trip_count(inputs, source_ids)

    if length(trips) != expected, do: Repo.rollback({:count_mismatch, expected, length(trips)})

    trips
  end

  # The destination's own rows through the shared calendar writer: the weekly row keeps its kind
  # and mask and moves only its endpoints, the exception rows become exactly the encoded result,
  # and an imported identity's missing audit anchor is created in the same transaction. The
  # operation attrs put the combination envelope on this one real calendar log, and the stored
  # exception rows are compared with the encoded result so a partial write is a count error.
  defp write_combination_destination!(destination_id, source, encoded, operation, audit_context) do
    plan = destination_combination_plan(destination_id, source, encoded)
    result = apply_single_plan!(plan, source, destination_id, audit_context, operation)

    expected = exception_pairs(encoded.exceptions)
    stored = exception_pairs(result.exceptions)

    if stored != expected, do: Repo.rollback({:count_mismatch, length(expected), length(stored)})

    result
  end

  # The internal plan shape `apply_single_plan!/5` consumes, derived from the encoded result rather
  # than planned again: only the endpoints of a retained weekly row and the exception rows can
  # change, and the anchor is kept (or created when missing).
  defp destination_combination_plan(destination_id, source, encoded) do
    stored = Map.new(source.exceptions, &{&1.date, &1.exception_type})
    planned = Map.new(encoded.exceptions, &{&1.date, &1.exception_type})

    remove_dates =
      stored
      |> Enum.reject(fn {date, _type} -> Map.has_key?(planned, date) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort(Date)

    put_entries =
      planned
      |> Enum.reject(fn {date, type} -> Map.get(stored, date) == type end)
      |> Enum.sort_by(&elem(&1, 0), Date)

    {weekly_action, weekly_changes} = destination_weekly_action(source.calendar, encoded.calendar)

    %{
      action: :combine,
      service_id: destination_id,
      anchor_action: :keep,
      anchor_changeset: nil,
      anchor_struct: source.attributes,
      weekly_action: weekly_action,
      remove_exception_dates: remove_dates,
      put_exceptions: put_entries,
      projected_calendar: encoded.calendar,
      projected_exceptions: exception_maps(encoded.exceptions),
      active_date_count: length(ServiceDates.active_dates(encoded.calendar, encoded.exceptions)),
      changed_count: length(remove_dates) + length(put_entries) + weekly_changes,
      warnings: [],
      changes: %{}
    }
  end

  # `Combination.encode/3` keeps the destination's kind, so a weekly row only moves its endpoints
  # and a dates-only destination keeps no weekly row.
  defp destination_weekly_action(nil, nil), do: {:keep, 0}

  defp destination_weekly_action(%Calendar{} = stored, %Calendar{} = projected) do
    if {stored.start_date, stored.end_date} == {projected.start_date, projected.end_date} do
      {:keep, 0}
    else
      changeset =
        Calendar.editor_changeset(stored, %{
          start_date: projected.start_date,
          end_date: projected.end_date
        })

      {{:update, changeset}, 1}
    end
  end

  # AC-11/AC-19: every source trip moves exactly once in bounded SQL batches inside the one
  # transaction, with the exact number of updated rows checked per batch and again at the end, and
  # one `"trip"` log per moved trip carrying only the operation UUID and its own before/after
  # snapshot. The complete member list lives in the single envelope, never in every trip log
  # (AC-26).
  defp move_combination_trips!(
         trips,
         destination_id,
         source_ids,
         cleared_trip_ids,
         operation,
         audit_context
       ) do
    cleared = MapSet.new(cleared_trip_ids)
    moved = MapSet.new(trips, & &1.id)

    unless MapSet.subset?(cleared, moved) do
      Repo.rollback({:count_mismatch, :cleared_trips, MapSet.size(cleared)})
    end

    snapshots =
      Schedules.trip_audit_snapshots(
        audit_context.organization_id,
        audit_context.gtfs_version_id,
        trips
      )

    now = DateTime.utc_now()

    trips
    |> Enum.chunk_every(@combination_trip_batch)
    |> Enum.each(fn batch ->
      move_trip_batch!(Enum.map(batch, & &1.id), destination_id, now, audit_context)

      cleared_batch = Enum.filter(batch, &MapSet.member?(cleared, &1.id))

      if cleared_batch != [] do
        clear_trip_blocks!(Enum.map(cleared_batch, & &1.id), now, audit_context)
      end
    end)

    # AC-11 at commit: the moving services hold no trip any more.
    remaining =
      Repo.aggregate(
        from(t in Trip,
          where:
            t.organization_id == ^audit_context.organization_id and
              t.gtfs_version_id == ^audit_context.gtfs_version_id and
              t.service_id in ^source_ids
        ),
        :count
      )

    if remaining != 0, do: Repo.rollback({:count_mismatch, 0, remaining})

    trips
    |> Enum.with_index()
    |> Enum.each(fn {trip, index} ->
      audit_moved_trip!(trip, snapshots, destination_id, cleared, index, operation, audit_context)
    end)

    Enum.map(trips, & &1.id)
  end

  defp move_trip_batch!(ids, destination_id, now, audit_context) do
    {count, _rows} =
      Repo.update_all(moved_trips_query(ids, audit_context),
        set: [service_id: destination_id, updated_at: now]
      )

    if count != length(ids), do: Repo.rollback({:count_mismatch, length(ids), count})

    :ok
  end

  defp clear_trip_blocks!(ids, now, audit_context) do
    {count, _rows} =
      Repo.update_all(moved_trips_query(ids, audit_context),
        set: [block_id: nil, updated_at: now]
      )

    if count != length(ids), do: Repo.rollback({:count_mismatch, length(ids), count})

    :ok
  end

  defp moved_trips_query(ids, audit_context) do
    from(t in Trip,
      where:
        t.organization_id == ^audit_context.organization_id and
          t.gtfs_version_id == ^audit_context.gtfs_version_id and t.id in ^ids
    )
  end

  # One `"trip"` log per moved trip, in the Schedules snapshot shape the trip edit path stores,
  # with its own before/after and the shared operation UUID. The `after` snapshot is the stored
  # `before` with the destination service and the reviewed clear, so one log is exactly one moved
  # trip. Any audit error rolls the whole combination back.
  defp audit_moved_trip!(
         trip,
         snapshots,
         destination_id,
         cleared,
         index,
         operation,
         audit_context
       ) do
    before = Map.fetch!(snapshots, trip.id)
    block_id = if MapSet.member?(cleared, trip.id), do: nil, else: before["block_id"]

    attrs =
      %{
        before: before,
        after: before |> Map.put("service_id", destination_id) |> Map.put("block_id", block_id),
        operation_id: operation.operation_id
      }
      |> put_envelope(operation, index)

    case Gtfs.record_change_in_transaction(
           audit_context,
           :trip,
           %{trip | service_id: destination_id, block_id: block_id},
           "updated",
           attrs
         ) do
      {:ok, _log} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  rescue
    error in [Postgrex.Error] ->
      if retryable_combination_error?(error) do
        reraise error, __STACKTRACE__
      else
        Repo.rollback({:audit_failed, error})
      end

    error in [Ecto.ConstraintError, DBConnection.ConnectionError] ->
      Repo.rollback({:audit_failed, error})
  end

  defp put_envelope(attrs, %{envelope_on_lowest_trip?: true, combination: combination}, 0) do
    Map.put(attrs, :combination, combination)
  end

  defp put_envelope(attrs, _operation, _index), do: attrs

  defp retry_combination(reason, normalized, review_fingerprint, audit_context, attempts) do
    cond do
      not retryable_combination_error?(reason) ->
        {:error, reason}

      attempts > 1 ->
        apply_combination(normalized, review_fingerprint, audit_context, attempts - 1)

      true ->
        {:error, :busy}
    end
  end

  defp retryable_combination_error?(%Postgrex.Error{postgres: %{code: code}})
       when code in @combination_retryable_codes,
       do: true

  defp retryable_combination_error?(_reason), do: false

  # -- Review and apply ------------------------------------------------------

  defp review!(normalized, source_fingerprints, audit_context) do
    sources = loaded_sources!(command_targets(normalized), source_fingerprints, audit_context)

    with {:ok, plans} <- plan_all(normalized, sources, audit_context),
         :ok <- validate_plan_references(plans, audit_context) do
      review_result(normalized, sources, plans)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A review's transaction body. A combination review *is* the protected boundary of
  # `load_combination_inputs!/2`: it acquires the scoped published version `FOR UPDATE` itself and
  # rechecks the actor membership after that wait, so the shared version-share body below - the one
  # every retained-form command keeps - would take the wrong lock for it.
  defp review_in_transaction!(
         {:combine, _destination_id, _source_ids, _decisions} = normalized,
         _source_fingerprints,
         audit_context
       ) do
    review_combination!(normalized, audit_context)
  end

  defp review_in_transaction!(normalized, source_fingerprints, audit_context) do
    authorize_editor!(audit_context)
    lock_shared_published_version!(audit_context)
    review!(normalized, source_fingerprints, audit_context)
  end

  # A retained-form command's write path: the reviewed sources are re-read under the write lock
  # and the reviewed token is recomputed from them before any plan is applied. A combination never
  # reaches this clause; it has its own transaction in `apply_combination/4`.
  defp apply!(normalized, review_fingerprint, audit_context) do
    sources = current_sources!(command_targets(normalized), audit_context)

    unless secure_equal?(review_fingerprint_for(sources, normalized), review_fingerprint) do
      Repo.rollback(:stale_review)
    end

    with {:ok, plans} <- plan_all(normalized, sources, audit_context),
         :ok <- validate_plan_references(plans, audit_context) do
      apply_plans!(normalized, sources, plans, audit_context)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Existence-only reference integrity: while closures reference a service it
  # keeps at least one native row. Every projected plan (including each side of
  # a multi-service date change) must retain a weekly row or an exception row;
  # a projection with neither is refused. A projection that keeps native rows
  # but empties active dates is disclosed through the existing warnings instead.
  defp validate_plan_references(plans, audit_context) do
    Enum.reduce_while(plans, :ok, fn {service_id, plan}, :ok ->
      if is_nil(plan.projected_calendar) and plan.projected_exceptions == [] do
        usage =
          one_usage(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

        if usage.closure_count > 0 do
          {:halt, {:error, {:closure_reference_lost, usage}}}
        else
          {:cont, :ok}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp loaded_sources!(targets, source_fingerprints, audit_context) do
    Map.new(targets, fn service_id ->
      source = required_payload!(service_id, audit_context)

      unless secure_equal?(Map.fetch!(source_fingerprints, service_id), source.fingerprint) do
        Repo.rollback(:stale_review)
      end

      {service_id, source}
    end)
  end

  defp current_sources!(targets, audit_context) do
    Map.new(targets, fn service_id ->
      {service_id, required_payload!(service_id, audit_context)}
    end)
  end

  # The reviewed token binds every retained source fingerprint together with the
  # normalized command, so neither a source change nor a different command can be
  # applied against an earlier review.
  defp review_fingerprint_for(sources, normalized) do
    sources
    |> Map.new(fn {service_id, source} -> {service_id, source.fingerprint} end)
    |> review_fingerprint(normalized)
  end

  defp review_result(normalized, sources, plans) do
    changed_ids =
      plans
      |> Enum.filter(fn {_service_id, plan} -> plan.changed_count > 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    %{
      fingerprint: review_fingerprint_for(sources, normalized),
      changes: review_changes(plans, changed_ids),
      warnings: Enum.flat_map(plans, fn {_service_id, plan} -> plan.warnings end),
      affected_service_ids: changed_ids,
      active_date_count:
        plans |> Enum.map(fn {_id, plan} -> plan.active_date_count end) |> Enum.sum()
    }
  end

  defp review_changes(plans, _changed_ids) when map_size(plans) == 1 do
    [{_service_id, plan}] = Map.to_list(plans)
    plan.changes
  end

  defp review_changes(plans, changed_ids) do
    %{
      action: :date_change,
      affected_service_ids: changed_ids,
      changed_count: plans |> Enum.map(fn {_id, plan} -> plan.changed_count end) |> Enum.sum(),
      calendars:
        Map.new(plans, fn {service_id, plan} ->
          {service_id,
           %{
             changed_count: plan.changed_count,
             kind: kind_for(plan.projected_calendar),
             active_date_count: plan.active_date_count
           }}
        end)
    }
  end

  # -- Command plans ---------------------------------------------------------

  defp plan_all({:delete, service_id}, sources, audit_context) do
    source = Map.fetch!(sources, service_id)
    usage = one_usage(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

    cond do
      usage.trip_count > 0 ->
        {:error, {:in_use, usage.trip_count, usage.route_ids}}

      usage.closure_count > 0 ->
        {:error, {:closures_in_use, usage}}

      true ->
        {:ok, %{service_id => delete_plan(service_id, source)}}
    end
  end

  defp plan_all({:date_change, dates, remove_from, add_to}, sources, audit_context) do
    today = plan_today(audit_context)

    removals =
      Map.new(remove_from, fn service_id ->
        {service_id,
         date_change_plan(service_id, Map.fetch!(sources, service_id), dates, @removed, today)}
      end)

    additions =
      Map.new(add_to, fn service_id ->
        {service_id,
         date_change_plan(service_id, Map.fetch!(sources, service_id), dates, @added, today)}
      end)

    {:ok, Map.merge(removals, additions)}
  end

  defp plan_all(command, sources, audit_context) do
    [service_id] = command_targets(command)
    source = Map.fetch!(sources, service_id)

    with :ok <- readable_range(command, source),
         {:ok, plan} <- plan_command(command, source, audit_context) do
      {:ok, %{service_id => plan}}
    end
  end

  # A retained reversed range has no service dates to derive, so a command that would
  # evaluate them is refused until a save supplies a corrected range. Delete is planned
  # apart and never evaluates the range.
  defp readable_range(command, source) do
    if range_save?(command) or retained_input_errors(source.calendar, source.exceptions) == [],
      do: :ok,
      else: {:error, :reversed_range}
  end

  # The `Calendar` changeset validates the order of a range a save supplies.
  defp range_save?({:save, _service_id, attrs}), do: weekly_fields_present?(attrs)
  defp range_save?(_command), do: false

  # A reversed row reports no active dates, as `get_calendar/3` does, so deleting it
  # never evaluates the range.
  defp delete_plan(service_id, source) do
    active_date_count =
      if retained_input_errors(source.calendar, source.exceptions) == [],
        do: length(ServiceDates.active_dates(source.calendar, source.exceptions)),
        else: 0

    %{
      action: :delete,
      service_id: service_id,
      anchor_action: :keep,
      anchor_changeset: nil,
      weekly_action: :keep,
      remove_exception_dates: [],
      put_exceptions: [],
      projected_calendar: nil,
      projected_exceptions: [],
      active_date_count: active_date_count,
      changed_count: 1,
      warnings: [],
      changes: %{
        action: :delete,
        service_id: service_id,
        name: source.attributes && source.attributes.service_description,
        kind: kind_for(source.calendar),
        trip_count: 0,
        active_date_count: active_date_count,
        exception_count: length(source.exceptions)
      }
    }
  end

  defp plan_command({:save, service_id, attrs}, source, audit_context) do
    with {:ok, anchor} <- plan_anchor(source, service_id, attrs, audit_context),
         {:ok, weekly} <- plan_save_weekly(source, attrs) do
      {:ok,
       finish_plan(
         source,
         service_id,
         %{
           action: :save,
           anchor: anchor,
           weekly: weekly,
           changes: %{
             action: :save,
             service_id: service_id,
             kind: kind_for(weekly.calendar),
             metadata_changed: anchor.changed?,
             weekly_changed: weekly.action != :keep
           }
         },
         plan_today(audit_context)
       )}
    end
  end

  defp plan_command({:convert, service_id, :dates_only, attrs}, source, audit_context) do
    if is_nil(source.calendar) do
      {:error, :invalid_command}
    else
      with {:ok, anchor} <- plan_anchor(source, service_id, attrs, audit_context) do
        effective = ServiceDates.active_dates(source.calendar, source.exceptions)

        {:ok,
         finish_plan(
           source,
           service_id,
           %{
             action: :convert,
             anchor: anchor,
             weekly: %{action: :delete, calendar: nil, changeset: nil},
             remove_exception_dates: Enum.map(source.exceptions, & &1.date),
             put_exceptions: Enum.map(effective, &{&1, @added}),
             projected_calendar: nil,
             projected_exceptions: Enum.map(effective, &%{date: &1, exception_type: @added}),
             row_changes:
               length(source.exceptions) + length(effective) -
                 2 * Enum.count(source.exceptions, &(&1.exception_type == @added)),
             changes: %{
               action: :convert,
               service_id: service_id,
               kind: :dates_only,
               persisted_date_count: length(effective)
             }
           },
           plan_today(audit_context)
         )}
      end
    end
  end

  defp plan_command({:convert, service_id, :weekly, attrs}, source, audit_context) do
    usage = one_usage(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

    cond do
      not is_nil(source.calendar) ->
        {:error, :invalid_command}

      usage.trip_count > 0 ->
        {:error, {:in_use, usage.trip_count, usage.route_ids}}

      true ->
        plan_convert_weekly(source, service_id, attrs, audit_context)
    end
  end

  defp plan_command({:add_break, service_id, first_date, last_date}, source, audit_context) do
    {:ok, add_break_plan(source, service_id, first_date, last_date, plan_today(audit_context))}
  end

  defp plan_command({:put_exceptions, service_id, dates, type}, source, audit_context) do
    {:ok, put_exceptions_plan(service_id, source, dates, type, plan_today(audit_context))}
  end

  defp plan_command({:remove_exceptions, service_id, dates}, source, audit_context) do
    {:ok, remove_exceptions_plan(service_id, source, dates, plan_today(audit_context))}
  end

  defp plan_convert_weekly(source, service_id, attrs, audit_context) do
    changeset =
      %Calendar{}
      |> Calendar.editor_changeset(
        attrs
        |> weekly_updates()
        |> Map.put(:service_id, service_id)
        |> Map.put(:organization_id, audit_context.organization_id)
        |> Map.put(:gtfs_version_id, audit_context.gtfs_version_id)
      )
      |> Ecto.Changeset.put_change(:service_id, service_id)

    if changeset.valid? do
      with {:ok, anchor} <- plan_anchor(source, service_id, attrs, audit_context) do
        calendar = Ecto.Changeset.apply_changes(changeset)
        before_active = ServiceDates.active_dates(source.calendar, source.exceptions)
        projected_exceptions = exception_maps(source.exceptions)
        introduced = ServiceDates.active_dates(calendar, projected_exceptions) -- before_active

        {:ok,
         finish_plan(
           source,
           service_id,
           %{
             action: :convert,
             anchor: anchor,
             weekly: %{action: :insert, calendar: calendar, changeset: changeset},
             projected_calendar: calendar,
             projected_exceptions: projected_exceptions,
             row_changes: 0,
             changes: %{
               action: :convert,
               service_id: service_id,
               kind: :weekly,
               new_service_date_count: length(introduced),
               new_service_dates: introduced
             }
           },
           plan_today(audit_context)
         )}
      end
    else
      {:error, changeset}
    end
  end

  # A break removes only the expected weekly dates inside the inclusive range:
  # weekends stay non-service, out-of-range additions are untouched, and dates that
  # already carry a removal are not written twice.
  defp add_break_plan(source, service_id, first_date, last_date, today) do
    expected = expected_dates_in_range(source.calendar, first_date, last_date)

    already_removed =
      source.exceptions
      |> Enum.filter(&(&1.exception_type == @removed))
      |> MapSet.new(& &1.date)

    to_remove = Enum.reject(expected, &MapSet.member?(already_removed, &1))

    finish_plan(
      source,
      service_id,
      %{
        action: :add_break,
        weekly: keep_weekly(source),
        put_exceptions: Enum.map(to_remove, &{&1, @removed}),
        projected_calendar: source.calendar,
        projected_exceptions:
          project_exceptions(source.exceptions, [], Enum.map(to_remove, &{&1, @removed})),
        row_changes: length(to_remove),
        changes: %{
          action: :add_break,
          service_id: service_id,
          first_date: first_date,
          last_date: last_date,
          expected_date_count: length(expected),
          removed_date_count: length(to_remove)
        }
      },
      today
    )
  end

  defp put_exceptions_plan(service_id, source, dates, type, today) do
    existing = Map.new(source.exceptions, &{&1.date, &1.exception_type})
    changed = Enum.count(dates, &(Map.get(existing, &1) != type))
    entries = Enum.map(dates, &{&1, type})

    finish_plan(
      source,
      service_id,
      %{
        action: :put_exceptions,
        weekly: keep_weekly(source),
        put_exceptions: entries,
        projected_calendar: source.calendar,
        projected_exceptions: project_exceptions(source.exceptions, [], entries),
        row_changes: changed,
        changes: %{
          action: :put_exceptions,
          service_id: service_id,
          exception_type: type,
          date_count: length(dates),
          changed_row_count: changed
        }
      },
      today
    )
  end

  defp remove_exceptions_plan(service_id, source, dates, today) do
    existing = Map.new(source.exceptions, &{&1.date, &1.exception_type})
    removed = Enum.count(dates, &Map.has_key?(existing, &1))

    finish_plan(
      source,
      service_id,
      %{
        action: :remove_exceptions,
        weekly: keep_weekly(source),
        remove_exception_dates: dates,
        projected_calendar: source.calendar,
        projected_exceptions: project_exceptions(source.exceptions, dates, []),
        row_changes: removed,
        changes: %{
          action: :remove_exceptions,
          service_id: service_id,
          date_count: length(dates),
          removed_row_count: removed
        }
      },
      today
    )
  end

  defp date_change_plan(service_id, source, dates, type, today) do
    plan = put_exceptions_plan(service_id, source, dates, type, today)
    %{plan | action: :date_change, changes: Map.put(plan.changes, :action, :date_change)}
  end

  defp plan_today(audit_context) do
    resolve_today(audit_context.organization_id, audit_context.gtfs_version_id, [])
  end

  defp keep_weekly(source), do: %{action: :keep, calendar: source.calendar, changeset: nil}

  # Row-level counts describe distinct rows whose stored value changed: an anchor is
  # only effective when it changes, a weekly insert/update/delete counts once, and
  # repeated identical exception writes count zero so no misleading log appears.
  defp finish_plan(source, service_id, opts, today) do
    anchor =
      Map.get(opts, :anchor, %{
        anchor: source.attributes,
        action: :keep,
        changeset: nil,
        updates: %{},
        changed?: false
      })

    weekly = Map.get(opts, :weekly, keep_weekly(source))
    row_changes = Map.get(opts, :row_changes, 0)
    anchor_active? = anchor.changed? and (row_changes > 0 or map_size(anchor.updates) > 0)
    weekly_active? = weekly.action != :keep

    projected_calendar = Map.get(opts, :projected_calendar, weekly.calendar)
    projected_exceptions = Map.get(opts, :projected_exceptions, exception_maps(source.exceptions))

    {anchor_action, anchor_changeset, anchor_struct} =
      if anchor_active? do
        {anchor.action, anchor.changeset, anchor.anchor}
      else
        {:keep, nil, source.attributes}
      end

    weekly_action =
      case weekly.action do
        :keep -> :keep
        :delete -> :delete
        action -> {action, weekly.changeset}
      end

    active_date_count =
      length(ServiceDates.active_dates(projected_calendar, projected_exceptions))

    changed_count = row_changes + bool_int(anchor_active?) + bool_int(weekly_active?)

    %{
      action: opts.action,
      service_id: service_id,
      anchor_struct: anchor_struct,
      anchor_action: anchor_action,
      anchor_changeset: anchor_changeset,
      weekly_action: weekly_action,
      remove_exception_dates: Map.get(opts, :remove_exception_dates, []),
      put_exceptions: Map.get(opts, :put_exceptions, []),
      projected_calendar: projected_calendar,
      projected_exceptions: projected_exceptions,
      active_date_count: active_date_count,
      changed_count: changed_count,
      warnings: projected_warnings(service_id, projected_calendar, projected_exceptions, today),
      changes:
        opts.changes
        |> Map.put(:changed_count, changed_count)
        |> Map.put(:active_date_count, active_date_count)
    }
  end

  defp projected_warnings(service_id, calendar, exceptions, today) do
    calendar
    |> ServiceDates.warnings(exceptions, today)
    |> Enum.map(&Map.put(&1, :service_id, service_id))
  end

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0

  # -- Anchor and weekly planning --------------------------------------------

  defp plan_anchor(source, service_id, attrs, audit_context) do
    with {:ok, updates} <- anchor_updates(source, service_id, attrs, audit_context) do
      case source.attributes do
        nil -> plan_anchor_create(service_id, updates, audit_context)
        %CalendarAttribute{} = anchor -> plan_anchor_update(anchor, updates)
      end
    end
  end

  defp plan_anchor_create(service_id, updates, audit_context) do
    changeset =
      %CalendarAttribute{
        organization_id: audit_context.organization_id,
        gtfs_version_id: audit_context.gtfs_version_id
      }
      |> CalendarAttribute.changeset(Map.put(updates, :service_id, service_id))
      |> Ecto.Changeset.put_change(:service_id, service_id)

    if changeset.valid? do
      {:ok,
       %{
         anchor: Ecto.Changeset.apply_changes(changeset),
         action: :create,
         changeset: changeset,
         updates: updates,
         changed?: true
       }}
    else
      {:error, changeset}
    end
  end

  defp plan_anchor_update(anchor, updates) do
    changeset = CalendarAttribute.changeset(anchor, updates)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      changeset.changes == %{} ->
        {:ok, %{anchor: anchor, action: :keep, changeset: nil, updates: %{}, changed?: false}}

      true ->
        {:ok,
         %{
           anchor: Ecto.Changeset.apply_changes(changeset),
           action: :update,
           changeset: changeset,
           updates: updates,
           changed?: true
         }}
    end
  end

  defp anchor_updates(source, service_id, attrs, audit_context) do
    with {:ok, name} <- name_update(source, service_id, attrs, audit_context) do
      {:ok, Map.merge(metadata_attrs(attrs), name)}
    end
  end

  # An unchanged name is never rewritten and never re-checked for uniqueness, so an
  # imported duplicate name cannot block an unrelated native edit.
  defp name_update(source, service_id, attrs, audit_context) do
    case name_value(attrs) do
      nil ->
        {:ok, %{}}

      value when is_binary(value) ->
        trimmed = String.trim(value)
        current = source.attributes && source.attributes.service_description

        cond do
          trimmed == "" ->
            {:error, name_error(source, "can't be blank")}

          same_name?(current, trimmed) ->
            {:ok, %{}}

          name_taken?(
            audit_context.organization_id,
            audit_context.gtfs_version_id,
            trimmed,
            service_id
          ) ->
            {:error, name_error(source, @taken_message)}

          true ->
            {:ok, %{service_description: trimmed}}
        end

      _other ->
        {:error, name_error(source, "is invalid")}
    end
  end

  defp name_value(attrs) do
    case fetch_value(attrs, :name) do
      nil -> fetch_value(attrs, :service_description)
      value -> value
    end
  end

  defp same_name?(current, requested) when is_binary(current) do
    String.downcase(String.trim(current)) == String.downcase(requested)
  end

  defp same_name?(_current, _requested), do: false

  defp name_error(source, message) do
    changeset =
      case source.attributes do
        %CalendarAttribute{} = anchor -> Ecto.Changeset.change(anchor)
        nil -> Ecto.Changeset.change(%CalendarAttribute{})
      end

    Ecto.Changeset.add_error(changeset, :service_description, message)
  end

  defp plan_save_weekly(source, attrs) do
    cond do
      is_nil(source.calendar) ->
        {:ok, keep_weekly(source)}

      not weekly_fields_present?(attrs) ->
        {:ok, keep_weekly(source)}

      true ->
        changeset = Calendar.editor_changeset(source.calendar, weekly_updates(attrs))

        cond do
          not changeset.valid? ->
            {:error, changeset}

          calendar_snapshot(Ecto.Changeset.apply_changes(changeset)) ==
              calendar_snapshot(source.calendar) ->
            {:ok, keep_weekly(source)}

          true ->
            {:ok,
             %{
               action: :update,
               calendar: Ecto.Changeset.apply_changes(changeset),
               changeset: changeset
             }}
        end
    end
  end

  defp weekly_fields_present?(attrs),
    do: Enum.any?(@weekly_fields, &key_present?(attrs, &1))

  defp weekly_updates(attrs) do
    @weekly_fields
    |> Enum.filter(&key_present?(attrs, &1))
    |> Map.new(&{&1, fetch_value(attrs, &1)})
  end

  defp exception_maps(exceptions) do
    exceptions
    |> Enum.map(&%{date: &1.date, exception_type: &1.exception_type})
    |> Enum.sort_by(& &1.date, Date)
  end

  defp project_exceptions(source_exceptions, remove_dates, put_entries) do
    remove = MapSet.new(remove_dates)

    source_exceptions
    |> Enum.reject(&MapSet.member?(remove, &1.date))
    |> Map.new(&{&1.date, &1.exception_type})
    |> then(fn acc ->
      Enum.reduce(put_entries, acc, fn {date, type}, entries -> Map.put(entries, date, type) end)
    end)
    |> Enum.sort_by(&elem(&1, 0), Date)
    |> Enum.map(fn {date, type} -> %{date: date, exception_type: type} end)
  end

  # The expected weekly baseline comes from ServiceDates itself, so break selection
  # can never disagree with the effective-date evaluation.
  defp expected_dates_in_range(nil, _first_date, _last_date), do: []

  defp expected_dates_in_range(calendar, first_date, last_date) do
    calendar
    |> ServiceDates.active_dates([])
    |> Enum.filter(fn date ->
      Date.compare(date, first_date) != :lt and Date.compare(date, last_date) != :gt
    end)
  end

  # -- Applying plans --------------------------------------------------------

  defp apply_plans!({:delete, service_id}, sources, _plans, audit_context) do
    apply_delete!(service_id, Map.fetch!(sources, service_id), audit_context)
  end

  # One version lock and one transaction cover every affected calendar. All logs
  # share the operation UUID, the normalized selected dates and the complete set of
  # affected service IDs, so a partial commit is impossible.
  defp apply_plans!({:date_change, dates, _remove_from, _add_to}, sources, plans, audit_context) do
    changed_ids =
      plans
      |> Enum.filter(fn {_service_id, plan} -> plan.changed_count > 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    operation_id = Ecto.UUID.generate()

    results =
      Enum.map(changed_ids, fn service_id ->
        apply_single_plan!(
          Map.fetch!(plans, service_id),
          Map.fetch!(sources, service_id),
          service_id,
          audit_context,
          %{
            operation_id: operation_id,
            affected_service_ids: changed_ids,
            selected_dates: dates
          }
        )
      end)

    %{
      action: :date_change,
      operation_id: operation_id,
      affected_service_ids: changed_ids,
      selected_dates: dates,
      changed_count: Enum.sum(Enum.map(results, & &1.changed_count)),
      calendars: Enum.map(results, &Map.take(&1, [:service_id, :kind, :active_date_count]))
    }
  end

  defp apply_plans!(_command, sources, plans, audit_context) do
    [{service_id, plan}] = Map.to_list(plans)
    apply_single_plan!(plan, Map.fetch!(sources, service_id), service_id, audit_context, %{})
  end

  defp apply_single_plan!(plan, source, service_id, audit_context, operation) do
    if plan.changed_count == 0 do
      unchanged_result(source, service_id)
    else
      # An imported identity may have no metadata anchor yet. The first committed
      # row change reserves it in the same transaction, keeping the service ID and
      # leaving its name nil, so the audit log always has an entity identity.
      anchor = write_anchor!(plan, source) || insert_orphan_anchor!(service_id, audit_context)
      calendar = write_weekly!(plan, source, service_id, audit_context)
      delete_exception_dates!(plan, service_id, audit_context)
      put_exception_entries!(plan, service_id, audit_context)

      exceptions =
        one_exceptions(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

      before_snapshot =
        aggregate_snapshot(service_id, source.calendar, source.attributes, source.exceptions)

      after_snapshot = aggregate_snapshot(service_id, calendar, anchor, exceptions)

      audit!(
        audit_context,
        anchor,
        "updated",
        Map.merge(%{before: before_snapshot, after: after_snapshot}, operation)
      )

      result(plan, service_id, calendar, anchor, exceptions, audit_context)
    end
  end

  defp unchanged_result(source, service_id) do
    %{
      service_id: service_id,
      action: :unchanged,
      changed_count: 0,
      calendar: source.calendar,
      attributes: source.attributes,
      exceptions: source.exceptions,
      kind: kind_for(source.calendar),
      fingerprint: source.fingerprint
    }
  end

  defp result(plan, service_id, calendar, anchor, exceptions, audit_context) do
    usage = one_usage(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

    %{
      service_id: service_id,
      action: plan.action,
      changed_count: plan.changed_count,
      active_date_count: plan.active_date_count,
      kind: kind_for(calendar),
      calendar: calendar,
      attributes: anchor,
      exceptions: exceptions,
      fingerprint:
        source_fingerprint(
          audit_context.organization_id,
          audit_context.gtfs_version_id,
          service_id,
          calendar,
          anchor,
          exceptions,
          usage
        )
    }
  end

  defp write_anchor!(%{anchor_action: :keep}, source), do: source.attributes

  defp write_anchor!(%{anchor_action: :create, anchor_changeset: changeset}, _source),
    do: insert_or_rollback!(changeset)

  defp write_anchor!(%{anchor_action: :update, anchor_changeset: changeset}, _source) do
    case Repo.update(changeset) do
      {:ok, anchor} -> anchor
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp write_weekly!(%{weekly_action: :keep}, source, _service_id, _audit_context),
    do: source.calendar

  defp write_weekly!(%{weekly_action: :delete}, _source, service_id, audit_context) do
    delete_weekly_rows!(service_id, audit_context)
    nil
  end

  defp write_weekly!(
         %{weekly_action: {:insert, changeset}},
         _source,
         _service_id,
         _audit_context
       ),
       do: insert_or_rollback!(changeset)

  defp write_weekly!(%{weekly_action: {:update, changeset}}, _source, _service_id, _audit_context) do
    case Repo.update(changeset) do
      {:ok, calendar} -> calendar
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp delete_weekly_rows!(service_id, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    Repo.delete_all(
      from(c in Calendar,
        where:
          c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id and
            c.service_id == ^service_id
      )
    )
  end

  defp delete_exception_dates!(%{remove_exception_dates: []}, _service_id, _audit_context),
    do: :ok

  defp delete_exception_dates!(plan, service_id, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    Repo.delete_all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id and
            d.service_id == ^service_id and d.date in ^plan.remove_exception_dates
      )
    )
  end

  defp put_exception_entries!(%{put_exceptions: []}, _service_id, _audit_context), do: :ok

  defp put_exception_entries!(plan, service_id, audit_context) do
    existing =
      audit_context.organization_id
      |> one_exceptions(audit_context.gtfs_version_id, service_id)
      |> Map.new(&{&1.date, &1})

    Enum.each(plan.put_exceptions, fn {date, type} ->
      case Map.get(existing, date) do
        nil -> insert_exception_row!(service_id, date, type, audit_context)
        %CalendarDate{exception_type: ^type} -> :ok
        %CalendarDate{} = row -> update_exception_row!(row, type)
      end
    end)
  end

  defp update_exception_row!(row, type) do
    case row |> CalendarDate.changeset(%{exception_type: type}) |> Repo.update() do
      {:ok, _row} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp apply_delete!(service_id, source, audit_context) do
    before_snapshot =
      aggregate_snapshot(service_id, source.calendar, source.attributes, source.exceptions)

    anchor = source.attributes || insert_orphan_anchor!(service_id, audit_context)

    delete_identity_rows!(service_id, audit_context)
    audit!(audit_context, anchor, "deleted", %{before: before_snapshot, after: nil})

    %{service_id: service_id, action: :deleted}
  end

  # A service imported before interactive metadata gets its stable audit anchor in
  # the same transaction as its deletion, so the deleted log keeps an entity id
  # for an identity that no longer exists.
  defp insert_orphan_anchor!(service_id, audit_context) do
    %CalendarAttribute{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id
    }
    |> CalendarAttribute.changeset(%{service_id: service_id})
    |> Ecto.Changeset.put_change(:service_id, service_id)
    |> insert_or_rollback!()
  end

  defp delete_identity_rows!(service_id, audit_context) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    Repo.delete_all(
      from(c in Calendar,
        where:
          c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id and
            c.service_id == ^service_id
      )
    )

    Repo.delete_all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id and
            d.service_id == ^service_id
      )
    )

    Repo.delete_all(
      from(a in CalendarAttribute,
        where:
          a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id and
            a.service_id == ^service_id
      )
    )
  end

  defp required_payload!(service_id, audit_context) do
    case payload(audit_context.organization_id, audit_context.gtfs_version_id, service_id) do
      nil -> Repo.rollback(:not_found)
      payload -> payload
    end
  end

  # -- Command normalization -------------------------------------------------

  # Commands are explicit tagged tuples. `dates` accepts `Date` values, ISO-8601
  # strings and ascending inclusive `Date.Range` values, which are expanded here at
  # the context boundary; user strings are never converted into atoms.
  defp normalize_command({:delete, service_id}),
    do: normalize_command_service_id(service_id, &{:delete, &1})

  defp normalize_command({:save, service_id, attrs}) when is_map(attrs),
    do: normalize_command_service_id(service_id, &{:save, &1, attrs})

  defp normalize_command({:convert, service_id, kind, attrs})
       when kind in @kinds and is_map(attrs),
       do: normalize_command_service_id(service_id, &{:convert, &1, kind, attrs})

  defp normalize_command({:add_break, service_id, first_date, last_date}) do
    with {:ok, service_id} <- check_service_id(service_id),
         {:ok, first_date} <- normalize_command_date(first_date),
         {:ok, last_date} <- normalize_command_date(last_date),
         :ok <- check_range_order(first_date, last_date) do
      {:ok, {:add_break, service_id, first_date, last_date}}
    end
  end

  defp normalize_command({:put_exceptions, service_id, dates, type})
       when type in [:added, :removed] do
    with {:ok, service_id} <- check_service_id(service_id),
         {:ok, dates} <- normalize_command_dates(dates) do
      {:ok, {:put_exceptions, service_id, dates, exception_type_value(type)}}
    end
  end

  defp normalize_command({:remove_exceptions, service_id, dates}) do
    with {:ok, service_id} <- check_service_id(service_id),
         {:ok, dates} <- normalize_command_dates(dates) do
      {:ok, {:remove_exceptions, service_id, dates}}
    end
  end

  defp normalize_command({:date_change, dates, remove_from, add_to}) do
    with {:ok, dates} <- normalize_command_dates(dates),
         {:ok, remove_from} <- normalize_command_service_ids(remove_from),
         {:ok, add_to} <- normalize_command_service_ids(add_to),
         :ok <- check_targets_present(remove_from, add_to),
         :ok <- check_disjoint(remove_from, add_to) do
      {:ok, {:date_change, dates, remove_from, add_to}}
    end
  end

  # A combination keeps exact service IDs - no trimming and no case folding - and normalizes the
  # submitted decision map to the command type's form: ISO-8601 date keys and the `:run` /
  # `:no_service` atoms. Only the two allowlisted wire strings are accepted, so no submitted value
  # ever becomes an atom, and a duplicate date, an empty source list or a destination named as a
  # source is refused before any database work.
  defp normalize_command({:combine, destination_id, source_ids, decisions})
       when is_map(decisions) do
    with {:ok, destination_id} <- check_service_id(destination_id),
         {:ok, source_ids} <- normalize_combination_source_ids(source_ids, destination_id),
         {:ok, decisions} <- normalize_combination_decisions(decisions) do
      {:ok, {:combine, destination_id, source_ids, decisions}}
    end
  end

  defp normalize_command(_command), do: {:error, :invalid_command}

  defp normalize_command_service_id(service_id, fun) do
    with {:ok, service_id} <- check_service_id(service_id), do: {:ok, fun.(service_id)}
  end

  defp check_service_id(service_id) when is_binary(service_id) and service_id != "",
    do: {:ok, service_id}

  defp check_service_id(_service_id), do: {:error, :invalid_command}

  defp normalize_command_date(value) do
    case expand_dates(value) do
      {:ok, [date]} -> {:ok, date}
      _other -> {:error, :invalid_command}
    end
  end

  defp normalize_command_dates(value) do
    case normalize_dates(value) do
      {:ok, []} -> {:error, :invalid_command}
      {:ok, dates} -> {:ok, dates}
      :error -> {:error, :invalid_command}
    end
  end

  defp normalize_command_service_ids(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, values |> Enum.uniq() |> Enum.sort()}
    else
      {:error, :invalid_command}
    end
  end

  defp normalize_command_service_ids(_values), do: {:error, :invalid_command}

  defp normalize_combination_source_ids(values, destination_id) when is_list(values) do
    cond do
      values == [] -> {:error, :invalid_command}
      not Enum.all?(values, &(is_binary(&1) and &1 != "")) -> {:error, :invalid_command}
      Enum.uniq(values) != values -> {:error, :invalid_command}
      destination_id in values -> {:error, :invalid_command}
      true -> {:ok, values}
    end
  end

  defp normalize_combination_source_ids(_values, _destination_id), do: {:error, :invalid_command}

  defp normalize_combination_decisions(decisions) do
    Enum.reduce_while(decisions, {:ok, %{}}, fn decision, {:ok, normalized} ->
      put_combination_decision(normalized, decision)
    end)
  end

  # One submitted decision becomes one exact ISO-8601 date key. A non-date key, a value outside
  # the allowlist and a second entry for a date that is already normalized are all
  # `:invalid_command`, so a `%Date{}` and its own ISO string cannot decide one date twice.
  defp put_combination_decision(normalized, {key, value}) do
    with {:ok, date} <- combination_decision_date(key),
         {:ok, decision} <- combination_decision_value(value) do
      iso_date = Date.to_iso8601(date)

      if Map.has_key?(normalized, iso_date) do
        {:halt, {:error, :invalid_command}}
      else
        {:cont, {:ok, Map.put(normalized, iso_date, decision)}}
      end
    else
      {:error, _reason} -> {:halt, {:error, :invalid_command}}
    end
  end

  # The wire form is an ISO-8601 date string; a `%Date{}` is accepted so a caller that already
  # resolved the conflict dates does not have to re-encode them.
  defp combination_decision_date(%Date{} = date), do: {:ok, date}

  defp combination_decision_date(key) when is_binary(key) do
    case Date.from_iso8601(key) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_command}
    end
  end

  defp combination_decision_date(_key), do: {:error, :invalid_command}

  defp combination_decision_value(decision) when decision in [:run, :no_service],
    do: {:ok, decision}

  defp combination_decision_value(value) when is_binary(value) do
    case Map.fetch(@combination_decisions, value) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:error, :invalid_command}
    end
  end

  defp combination_decision_value(_value), do: {:error, :invalid_command}

  defp check_range_order(first_date, last_date) do
    if Date.compare(first_date, last_date) == :gt, do: {:error, :invalid_command}, else: :ok
  end

  defp check_targets_present([], []), do: {:error, :invalid_command}
  defp check_targets_present(_remove_from, _add_to), do: :ok

  defp check_disjoint(remove_from, add_to) do
    if MapSet.disjoint?(MapSet.new(remove_from), MapSet.new(add_to)) do
      :ok
    else
      {:error, :invalid_command}
    end
  end

  defp exception_type_value(:added), do: @added
  defp exception_type_value(:removed), do: @removed

  defp command_targets({:delete, service_id}), do: [service_id]
  defp command_targets({:save, service_id, _attrs}), do: [service_id]
  defp command_targets({:convert, service_id, _kind, _attrs}), do: [service_id]
  defp command_targets({:add_break, service_id, _first_date, _last_date}), do: [service_id]
  defp command_targets({:put_exceptions, service_id, _dates, _type}), do: [service_id]
  defp command_targets({:remove_exceptions, service_id, _dates}), do: [service_id]

  defp command_targets({:date_change, _dates, remove_from, add_to}),
    do: remove_from |> Kernel.++(add_to) |> Enum.uniq() |> Enum.sort()

  defp command_targets({:combine, destination_id, source_ids, _decisions}),
    do: [destination_id | source_ids] |> Enum.uniq() |> Enum.sort()

  # Exact keys must match the normalized targets and every value must be a real
  # non-empty fingerprint; there is no missing-key or nil bypass.
  defp normalize_source_fingerprints(source_fingerprints, targets)
       when is_map(source_fingerprints) do
    provided = source_fingerprints |> Map.keys() |> Enum.map(&fingerprint_key/1) |> Enum.sort()
    values = Enum.map(targets, &Map.get(source_fingerprints, &1))

    if provided == Enum.sort(targets) and Enum.all?(values, &valid_fingerprint?/1) do
      :ok
    else
      {:error, :stale_review}
    end
  end

  defp normalize_source_fingerprints(_source_fingerprints, _targets), do: {:error, :stale_review}

  defp fingerprint_key(key) when is_binary(key), do: key
  defp fingerprint_key(_key), do: :invalid

  defp valid_fingerprint?(value), do: is_binary(value) and value != ""

  defp validate_review_fingerprint(fingerprint) when is_binary(fingerprint) do
    if fingerprint == "", do: {:error, :stale_review}, else: :ok
  end

  defp validate_review_fingerprint(_fingerprint), do: {:error, :stale_review}

  # -- Authorization and locking --------------------------------------------

  defp authorize_editor!(%AuditContext{} = audit_context) do
    case authorize_editor(audit_context) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Rechecks the actor's current active organization membership and editor role.

  Every audited mutation calls this before writing, so a membership deactivated
  or revoked after mount is refused on the next save. Returns `{:error,
  :forbidden}` for a missing, foreign, deactivated or role-less membership.
  """
  @spec authorize_editor(AuditContext.t()) :: :ok | {:error, :forbidden}
  def authorize_editor(%AuditContext{
        actor_id: actor_id,
        organization_id: organization_id
      }) do
    with true <- uuid?(actor_id),
         true <- uuid?(organization_id),
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(actor_id, organization_id),
         true <- is_nil(membership.deactivated_at),
         true <- editor_role?(membership.roles) do
      :ok
    else
      _other -> {:error, :forbidden}
    end
  end

  defp editor_role?(roles) when is_list(roles), do: @editor_role in roles
  defp editor_role?(_roles), do: false

  @doc """
  Locks the published version row `FOR SHARE` and checks that `service_id` is a calendar identity.

  Schedule writers call this before any route lock, so a calendar delete cannot commit between the
  union check and the trip insert. Call only inside `Repo.transaction/1`; this is a lock, not a
  transaction, and it rolls back `:calendar_not_found` when the version is missing or the service ID
  is not in the union of calendars, calendar dates and calendar attributes for this version.
  """
  @spec lock_service_for_reference!(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: :ok
  def lock_service_for_reference!(organization_id, version_id, service_id) do
    lock_shared_published_version!(organization_id, version_id)

    unless service_id_taken?(organization_id, version_id, service_id),
      do: Repo.rollback(:calendar_not_found)

    :ok
  end

  # The shared input-write lock takes no publication stance, so calendar reads and
  # schedule writers keep their own stricter published requirement here.
  defp lock_shared_published_version!(organization_id, version_id) do
    case Versions.lock_for_input_write!(organization_id, version_id) do
      %GtfsVersion{publication_status: @published_status} = version -> version
      %GtfsVersion{} -> Repo.rollback(:not_found)
    end
  end

  defp lock_shared_published_version!(%AuditContext{} = audit_context) do
    lock_shared_published_version!(audit_context.organization_id, audit_context.gtfs_version_id)
  end

  @doc """
  Locks the scoped published version row `FOR UPDATE` and returns it.

  Call only inside `Repo.transaction/1`; this is a write lock, not a transaction.
  The lock serializes calendar and closure writers on the published version before
  any row is touched. A missing, foreign or unpublished version rolls back
  `:not_found`.
  """
  @spec lock_published_version!(AuditContext.t()) :: GtfsVersion.t()
  def lock_published_version!(%AuditContext{} = audit_context) do
    audit_context.organization_id
    |> published_version_for_update(audit_context.gtfs_version_id)
    |> case do
      %GtfsVersion{} = version -> version
      nil -> Repo.rollback(:not_found)
    end
  end

  # A literal lock string is required by Ecto.
  defp published_version_for_update(organization_id, version_id) do
    if uuid?(organization_id) and uuid?(version_id) do
      from(v in GtfsVersion,
        where:
          v.id == ^version_id and v.organization_id == ^organization_id and
            v.publication_status == ^@published_status,
        lock: "FOR UPDATE"
      )
      |> Repo.one()
    end
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  # -- Snapshots, fingerprints and digests ----------------------------------

  defp source_fingerprint(
         organization_id,
         version_id,
         service_id,
         calendar,
         attributes,
         exceptions,
         usage
       ) do
    digest(%{
      scope: {organization_id, version_id},
      service_id: service_id,
      weekly: calendar_snapshot(calendar),
      attributes: attribute_snapshot(attributes),
      dates: exception_pairs(exceptions),
      usage: %{
        trip_count: usage.trip_count,
        route_ids: usage.route_ids,
        closure_count: usage.closure_count,
        pathway_ids: usage.pathway_ids
      }
    })
  end

  defp review_fingerprint(source_fingerprint, command) do
    digest(%{source: source_fingerprint, command: canonical(command)})
  end

  defp aggregate_snapshot(service_id, calendar, attributes, exceptions) do
    %{
      "service_id" => service_id,
      "name" => attributes && attributes.service_description,
      "kind" => Atom.to_string(kind_for(calendar)),
      "weekly" => calendar_snapshot(calendar),
      "attributes" => attribute_snapshot(attributes),
      "dates" => exception_pairs(exceptions)
    }
  end

  defp calendar_snapshot(nil), do: nil

  defp calendar_snapshot(%Calendar{} = weekly) do
    %{
      "monday" => weekly.monday,
      "tuesday" => weekly.tuesday,
      "wednesday" => weekly.wednesday,
      "thursday" => weekly.thursday,
      "friday" => weekly.friday,
      "saturday" => weekly.saturday,
      "sunday" => weekly.sunday,
      "start_date" => iso_date(weekly.start_date),
      "end_date" => iso_date(weekly.end_date)
    }
  end

  defp attribute_snapshot(nil), do: nil

  defp attribute_snapshot(%CalendarAttribute{} = attributes) do
    %{
      "id" => attributes.id,
      "service_id" => attributes.service_id,
      "service_description" => attributes.service_description,
      "service_schedule_name" => attributes.service_schedule_name,
      "service_schedule_type" => attributes.service_schedule_type,
      "service_schedule_typicality" => attributes.service_schedule_typicality,
      "rating_start_date" => iso_date(attributes.rating_start_date),
      "rating_end_date" => iso_date(attributes.rating_end_date),
      "rating_description" => attributes.rating_description
    }
  end

  defp exception_pairs(exceptions) do
    exceptions
    |> Enum.sort_by(fn exception ->
      date = exception.date
      {date.year, date.month, date.day, exception.exception_type}
    end)
    |> Enum.map(fn exception ->
      %{"date" => iso_date(exception.date), "exception_type" => exception.exception_type}
    end)
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp digest(value) do
    :crypto.hash(:sha256, canonical_binary(value)) |> Base.encode16(case: :lower)
  end

  defp canonical_binary(value) do
    value |> canonical() |> :erlang.term_to_binary([:deterministic])
  end

  defp canonical(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}
  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, entry} -> {to_string(key), canonical(entry)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()
  end

  defp canonical(value), do: value

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  # -- Attribute helpers ----------------------------------------------------

  defp normalize_dates(value) do
    case expand_dates(value) do
      {:ok, dates} -> {:ok, dates |> Enum.uniq() |> Enum.sort(Date)}
      :error -> :error
    end
  end

  # Inclusive ascending ranges, `Date` values and ISO-8601 strings are expanded at
  # this boundary. A descending range is rejected instead of silently normalized.
  defp expand_dates(%Date.Range{} = range) do
    if Date.compare(range.first, range.last) == :gt do
      :error
    else
      {:ok, Enum.to_list(range)}
    end
  end

  defp expand_dates(%Date{} = date), do: {:ok, [date]}

  defp expand_dates(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, [date]}
      {:error, _reason} -> :error
    end
  end

  defp expand_dates(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case expand_dates(value) do
        {:ok, dates} -> {:cont, {:ok, acc ++ dates}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp expand_dates(_value), do: :error

  defp name_taken?(_organization_id, _version_id, name, _exclude_service_id)
       when not is_binary(name),
       do: false

  defp name_taken?(organization_id, version_id, name, exclude_service_id) do
    normalized = name |> String.trim() |> String.downcase()

    if normalized == "" do
      false
    else
      query =
        from(a in CalendarAttribute,
          where:
            a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id and
              fragment("btrim(lower(?))", a.service_description) == ^normalized,
          select: a.service_id,
          limit: 1
        )

      query =
        if is_binary(exclude_service_id) do
          from(a in query, where: a.service_id != ^exclude_service_id)
        else
          query
        end

      Repo.one(query) != nil
    end
  end

  defp key_present?(attrs, field) do
    Map.has_key?(attrs, field) or Map.has_key?(attrs, to_string(field))
  end

  defp fetch_value(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> value
      :error -> Map.get(attrs, to_string(field))
    end
  end

  # -- Audit and transaction plumbing ---------------------------------------

  defp audit!(%AuditContext{} = audit_context, anchor, action, attrs) do
    context = %{audit_context | station_stop_id: nil}

    case Gtfs.record_change_in_transaction(context, :calendar, anchor, action, attrs) do
      {:ok, log} -> log
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_or_rollback!(%Ecto.Changeset{} = changeset) do
    case Repo.insert(changeset) do
      {:ok, struct} -> struct
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
