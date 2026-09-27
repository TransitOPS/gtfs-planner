defmodule GtfsPlanner.Gtfs.Calendars do
  @moduledoc """
  Scoped reads and audited lifecycle commands for editable service calendars.

  A calendar identity is the union of the service IDs stored in `calendars`,
  `calendar_dates` and `calendar_attributes` for one organization/version.
  Reads never invent rows: an exception-only service and a metadata-only service
  are each one visible identity, and `kind` is `:weekly` only when a weekly row
  exists. Summaries reuse `Calendars.ServiceDates` for effective dates and
  warnings, and resolve the warning date through `Gtfs.DisplayClock`'s
  agency-zone PostgreSQL localization.

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
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
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
  @type kind :: :weekly | :dates_only
  @type command ::
          {:delete, String.t()}
          | {:save, String.t(), map()}
          | {:convert, String.t(), kind(), map()}
          | {:add_break, String.t(), Date.t(), Date.t()}
          | {:put_exceptions, String.t(), [Date.t()], 1 | 2}
          | {:remove_exceptions, String.t(), [Date.t()]}
          | {:date_change, [Date.t()], [String.t()], [String.t()]}
  @type calendar_usage :: %{
          optional(:service_id) => String.t(),
          trip_count: non_neg_integer(),
          route_ids: [String.t()],
          routes: [%{route_id: String.t(), trip_count: non_neg_integer()}]
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
          active_dates: [Date.t()],
          first_active_date: Date.t() | nil,
          last_active_date: Date.t() | nil,
          fingerprint: String.t(),
          warnings: [ServiceDates.warning()],
          status: summary_status()
        }
  @type payload :: %{
          calendar: Calendar.t() | nil,
          attributes: CalendarAttribute.t() | nil,
          exceptions: [CalendarDate.t()],
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
          | {:in_use, non_neg_integer(), [String.t()]}
  @type write_error :: Ecto.Changeset.t() | error()
  @type feed_gap :: %{first_date: Date.t(), last_date: Date.t()}
  @type review_result :: %{
          fingerprint: String.t(),
          changes: map(),
          warnings: list(),
          affected_service_ids: [String.t()],
          active_date_count: non_neg_integer()
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
  Loads one calendar identity as its weekly row, metadata anchor, exceptions and source fingerprint.

  A service ID that appears in none of the three tables returns
  `{:error, :not_found}`; a load never invents an anchor row.

  The editor needs the same derived values the list shows, so one coherent load
  additionally carries the identity `:kind`, the effective `:active_dates`, the
  derived `:periods`, the `:warnings` at the agency-local today, that `:today`
  together with the resolved agency `:zone` (including its UTC fallback reason)
  and the grouped `:usage`. Deriving them here keeps the editor from re-implementing
  `ServiceDates` or resolving a second, disagreeing clock.
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

      source
      |> Map.put(:kind, kind_for(calendar))
      |> Map.put(:active_dates, ServiceDates.active_dates(calendar, exceptions))
      |> Map.put(:periods, ServiceDates.periods(calendar, exceptions))
      |> Map.put(:warnings, ServiceDates.warnings(calendar, exceptions, clock.date))
      |> Map.put(:today, clock.date)
      |> Map.put(:zone, clock)
      |> Map.put(:usage, one_usage(organization_id, version_id, service_id))
    end)
  end

  def get_calendar(_organization_id, _version_id, _service_id), do: {:error, :not_found}

  @doc """
  Returns the scoped trip usage of one calendar identity grouped by route.

  The result carries the total `trip_count`, the sorted distinct `route_ids` and
  one `%{route_id: ..., trip_count: ...}` entry per route, which is what the
  detail view and the blocked-delete explanation need. Usage of other versions or
  organizations is never included.
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
  `{:in_use, trip_count, route_ids}`, and otherwise the result carries the reviewed
  `changes`, projected `warnings`, the `affected_service_ids` that would change, the
  projected `active_date_count` and a command-bound `fingerprint` that
  `apply_calendar_change/3` requires. The shared version lock is released before the
  caller renders the review.
  """
  @spec review_calendar_change(term(), map(), AuditContext.t()) ::
          {:ok, review_result()} | {:error, write_error()}
  def review_calendar_change(command, source_fingerprints, %AuditContext{} = audit_context) do
    with {:ok, normalized} <- normalize_command(command),
         :ok <- normalize_source_fingerprints(source_fingerprints, command_targets(normalized)) do
      transact(fn ->
        authorize_editor!(audit_context)
        lock_shared_published_version!(audit_context)
        review!(normalized, source_fingerprints, audit_context)
      end)
    end
  end

  @doc """
  Applies a previously reviewed calendar command under the write lock.

  The reviewed fingerprint is recomputed from the current rows and the normalized
  command before anything changes, so another committed change or a different
  command returns `{:error, :stale_review}` with no writes. A command whose stored
  rows do not change writes nothing and adds no audit record.
  """
  @spec apply_calendar_change(term(), term(), AuditContext.t()) ::
          {:ok, map()} | {:error, write_error()}
  def apply_calendar_change(command, review_fingerprint, %AuditContext{} = audit_context) do
    with {:ok, normalized} <- normalize_command(command),
         :ok <- validate_review_fingerprint(review_fingerprint) do
      transact(fn ->
        authorize_editor!(audit_context)
        lock_published_version!(audit_context)
        apply!(normalized, review_fingerprint, audit_context)
      end)
    end
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
    usage = trip_usage_rows(organization_id, version_id)
    today = resolve_today(organization_id, version_id, opts)

    organization_id
    |> union_service_ids(version_id)
    |> Enum.map(
      &summary(&1, organization_id, version_id, calendars, attributes, exceptions, usage, today)
    )
    |> Enum.sort_by(fn summary -> {sort_name(summary), summary.service_id} end)
    |> sort_summaries(opts)
  end

  defp sort_summaries(summaries, opts) do
    case {Keyword.get(opts, :sort_by, :name), Keyword.get(opts, :sort_dir, :asc)} do
      {:period, direction} -> sort_by_period(summaries, direction)
      {_name, :desc} -> Enum.sort_by(summaries, &{sort_name(&1), &1.service_id}, :desc)
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
        &{Date.to_erl(&1.first_active_date), sort_name(&1), &1.service_id},
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
    active_dates = ServiceDates.active_dates(calendar, service_exceptions)
    warnings = ServiceDates.warnings(calendar, service_exceptions, today)

    %{
      service_id: service_id,
      name: attribute && attribute.service_description,
      kind: kind_for(calendar),
      calendar: calendar,
      attributes: attribute,
      trip_count: service_usage.trip_count,
      active_dates: active_dates,
      first_active_date: List.first(active_dates),
      last_active_date: List.last(active_dates),
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
      warnings: warnings,
      status:
        summary_status(
          calendar,
          service_exceptions,
          active_dates,
          warnings,
          service_usage.trip_count,
          today
        )
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

  defp sort_name(%{name: name, service_id: service_id}) when is_binary(name) do
    case String.trim(name) do
      "" -> String.downcase(service_id)
      trimmed -> String.downcase(trimmed)
    end
  end

  defp sort_name(%{service_id: service_id}), do: String.downcase(service_id)

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

  defp empty_usage, do: %{trip_count: 0, route_ids: [], routes: []}

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
          {:ok, service_id}
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
      nil -> {:ok, available_service_id(source_service_id, audit_context)}
      requested when is_binary(requested) -> {:ok, requested}
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

  # -- Review and apply ------------------------------------------------------

  # -- Review and apply ------------------------------------------------------

  defp review!(normalized, source_fingerprints, audit_context) do
    sources = loaded_sources!(command_targets(normalized), source_fingerprints, audit_context)

    case plan_all(normalized, sources, audit_context) do
      {:ok, plans} -> review_result(normalized, sources, plans)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply!(normalized, review_fingerprint, audit_context) do
    sources = current_sources!(command_targets(normalized), audit_context)

    unless secure_equal?(review_fingerprint_for(sources, normalized), review_fingerprint) do
      Repo.rollback(:stale_review)
    end

    case plan_all(normalized, sources, audit_context) do
      {:ok, plans} -> apply_plans!(normalized, sources, plans, audit_context)
      {:error, reason} -> Repo.rollback(reason)
    end
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

    if usage.trip_count > 0 do
      {:error, {:in_use, usage.trip_count, usage.route_ids}}
    else
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

    case plan_command(command, source, audit_context) do
      {:ok, plan} -> {:ok, %{service_id => plan}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_plan(service_id, source) do
    active_date_count = length(ServiceDates.active_dates(source.calendar, source.exceptions))

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
             row_changes: 1 + length(source.exceptions) + length(effective),
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
             row_changes: 1,
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

  defp authorize_editor(%AuditContext{
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

  defp lock_shared_published_version!(organization_id, version_id) do
    organization_id
    |> published_version_for_share(version_id)
    |> case do
      %GtfsVersion{} = version -> version
      nil -> Repo.rollback(:not_found)
    end
  end

  defp lock_shared_published_version!(%AuditContext{} = audit_context) do
    lock_shared_published_version!(audit_context.organization_id, audit_context.gtfs_version_id)
  end

  defp lock_published_version!(%AuditContext{} = audit_context) do
    audit_context.organization_id
    |> published_version_for_update(audit_context.gtfs_version_id)
    |> case do
      %GtfsVersion{} = version -> version
      nil -> Repo.rollback(:not_found)
    end
  end

  # A literal lock string is required by Ecto; sharing the scoped version row
  # excludes cooperating writers only for the duration of one aggregate load.
  defp published_version_for_share(organization_id, version_id) do
    if uuid?(organization_id) and uuid?(version_id) do
      from(v in GtfsVersion,
        where:
          v.id == ^version_id and v.organization_id == ^organization_id and
            v.publication_status == ^@published_status,
        lock: "FOR SHARE"
      )
      |> Repo.one()
    end
  end

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
      usage: %{trip_count: usage.trip_count, route_ids: usage.route_ids}
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
