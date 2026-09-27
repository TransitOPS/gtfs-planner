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
  `calendar` entity. This step implements the reviewed command
  `{:delete, service_id}`; the remaining tagged date commands are refused until
  the date-mutation step implements them.
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
  @unsupported_commands [
    :save,
    :convert,
    :add_break,
    :put_exceptions,
    :remove_exceptions,
    :date_change
  ]

  @type kind :: :weekly | :dates_only
  @type command :: {:delete, String.t()}
  @type calendar_usage :: %{
          optional(:service_id) => String.t(),
          trip_count: non_neg_integer(),
          route_ids: [String.t()],
          routes: [%{route_id: String.t(), trip_count: non_neg_integer()}]
        }
  @type summary :: %{
          service_id: String.t(),
          name: String.t() | nil,
          kind: kind(),
          calendar: Calendar.t() | nil,
          attributes: CalendarAttribute.t() | nil,
          trip_count: non_neg_integer(),
          first_active_date: Date.t() | nil,
          last_active_date: Date.t() | nil,
          fingerprint: String.t(),
          warnings: [ServiceDates.warning()]
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
          | :unsupported_command
          | :invalid_input
          | {:in_use, non_neg_integer(), [String.t()]}
  @type write_error :: Ecto.Changeset.t() | error()
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
  """
  @spec get_calendar(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, payload()} | {:error, :not_found}
  def get_calendar(organization_id, version_id, service_id) when is_binary(service_id) do
    transact(fn ->
      lock_shared_published_version!(organization_id, version_id)
      payload(organization_id, version_id, service_id) || Repo.rollback(:not_found)
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
          {:ok, [ServiceDates.interval()]} | {:error, :not_found}
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
  nil entries are refused before a review token exists. For `{:delete, service_id}`
  a same-scope trip returns `{:in_use, trip_count, route_ids}`, and otherwise the
  result carries the reviewed `changes`, the effective `active_date_count` and a
  command-bound `fingerprint` that `apply_calendar_change/3` requires. The shared
  version lock is released before the caller renders the review.

  Tagged date commands that this step does not implement return
  `{:error, :unsupported_command}`.
  """
  @spec review_calendar_change(term(), map(), AuditContext.t()) ::
          {:ok, review_result()} | {:error, write_error()}
  def review_calendar_change(command, source_fingerprints, %AuditContext{} = audit_context) do
    with {:ok, {:delete, service_id}} <- normalize_command(command),
         :ok <- normalize_source_fingerprints(source_fingerprints, [service_id]) do
      transact(fn ->
        authorize_editor!(audit_context)
        lock_shared_published_version!(audit_context)
        review_delete!(service_id, source_fingerprints, audit_context)
      end)
    end
  end

  @doc """
  Applies a previously reviewed calendar command under the write lock.

  The reviewed fingerprint is recomputed from the current rows before anything
  changes, so another committed change or a different command returns
  `{:error, :stale_review}` with no writes. Deleting an unused identity removes
  its weekly row, all exceptions and its metadata anchor in one transaction and
  records one complete `"deleted"` audit snapshot.
  """
  @spec apply_calendar_change(term(), term(), AuditContext.t()) ::
          {:ok, map()} | {:error, write_error()}
  def apply_calendar_change(command, review_fingerprint, %AuditContext{} = audit_context) do
    with {:ok, {:delete, service_id}} <- normalize_command(command),
         :ok <- validate_review_fingerprint(review_fingerprint) do
      transact(fn ->
        authorize_editor!(audit_context)
        lock_published_version!(audit_context)
        apply_delete!(service_id, review_fingerprint, audit_context)
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

    %{
      service_id: service_id,
      name: attribute && attribute.service_description,
      kind: kind_for(calendar),
      calendar: calendar,
      attributes: attribute,
      trip_count: service_usage.trip_count,
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
      warnings: ServiceDates.warnings(calendar, service_exceptions, today)
    }
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
    Enum.map(additions, fn date ->
      %CalendarDate{
        organization_id: audit_context.organization_id,
        gtfs_version_id: audit_context.gtfs_version_id
      }
      |> CalendarDate.changeset(%{service_id: service_id, date: date, exception_type: @added})
      |> insert_or_rollback!()
    end)
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

  defp review_delete!(service_id, source_fingerprints, audit_context) do
    source = required_payload!(service_id, audit_context)

    unless secure_equal?(Map.fetch!(source_fingerprints, service_id), source.fingerprint) do
      Repo.rollback(:stale_review)
    end

    usage = one_usage(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

    if usage.trip_count > 0 do
      Repo.rollback({:in_use, usage.trip_count, usage.route_ids})
    end

    command = {:delete, service_id}
    active_date_count = length(ServiceDates.active_dates(source.calendar, source.exceptions))

    %{
      fingerprint: review_fingerprint(source.fingerprint, command),
      changes: %{
        action: :delete,
        service_id: service_id,
        name: source.attributes && source.attributes.service_description,
        kind: kind_for(source.calendar),
        trip_count: 0,
        active_date_count: active_date_count,
        exception_count: length(source.exceptions)
      },
      warnings: [],
      affected_service_ids: [service_id],
      active_date_count: active_date_count
    }
  end

  defp apply_delete!(service_id, review_fingerprint, audit_context) do
    source = required_payload!(service_id, audit_context)

    unless secure_equal?(
             review_fingerprint(source.fingerprint, {:delete, service_id}),
             review_fingerprint
           ) do
      Repo.rollback(:stale_review)
    end

    usage = one_usage(audit_context.organization_id, audit_context.gtfs_version_id, service_id)

    if usage.trip_count > 0 do
      Repo.rollback({:in_use, usage.trip_count, usage.route_ids})
    end

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

  defp normalize_command({:delete, service_id}) when is_binary(service_id) do
    if String.trim(service_id) == "" do
      {:error, :invalid_command}
    else
      {:ok, {:delete, service_id}}
    end
  end

  defp normalize_command({tag, _service_id}) when tag in @unsupported_commands,
    do: {:error, :unsupported_command}

  defp normalize_command({tag, _service_id, _rest}) when tag in @unsupported_commands,
    do: {:error, :unsupported_command}

  defp normalize_command({tag, _service_id, _dates, _rest}) when tag in @unsupported_commands,
    do: {:error, :unsupported_command}

  defp normalize_command(_command), do: {:error, :invalid_command}

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

  defp normalize_dates(%Date.Range{} = range), do: range |> Enum.to_list() |> normalize_dates()

  defp normalize_dates(dates) when is_list(dates) do
    dates
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_date(value) do
        {:ok, date} -> {:cont, {:ok, [date | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, dates} -> {:ok, dates |> Enum.uniq() |> Enum.sort(Date)}
      :error -> :error
    end
  end

  defp normalize_dates(_dates), do: :error

  defp normalize_date(%Date{} = date), do: {:ok, date}

  defp normalize_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp normalize_date(_value), do: :error

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
