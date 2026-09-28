defmodule GtfsPlanner.Gtfs.PathwayEvolutions do
  @moduledoc """
  Scoped reads for scheduled pathway closures and their native calendar choices.

  Every read names one organization and GTFS version and accepts only a
  published scope with well-formed identifiers; anything else returns
  `{:error, :not_found}` (or a zero count) without exposing rows. Station reads
  accept only a real station stop (`location_type` 1) and reuse the station
  report snapshot, so a closure belongs to the station when its pathway has
  either endpoint among the station's descendant stops, boarding areas included.

  A closure row carries the persisted `Gtfs.Gtfs.PathwayEvolution` with its
  fingerprint, its exact snapshot pathway and its native calendar option. The
  option exists only for services with at least one `calendars` or
  `calendar_dates` row in the scope: a metadata-only identity (a
  `calendar_attributes` row alone) is not a valid closure reference, so it is
  excluded from `closure_calendars/2` and yields `calendar: nil` on a closure
  row. `Calendars.list_calendars/3` keeps showing metadata-only identities as
  editable calendars; that contract is unchanged here.

  Fingerprinting lives here because the mutation and editor handoffs compare the
  row they loaded against the current row. The digest covers exactly the
  persisted closure row, so editing a referenced calendar or pathway never makes
  a closure stale, while any write to the row itself does.

  Creates, updates and deletes are audited, locked mutations: each rechecks
  the actor's active editor membership, locks the scoped published version with
  `Calendars.lock_published_version!/1`, validates the exact native service and
  pathway references (plus station membership when the audit context carries a
  station), writes through `PathwayEvolution.changeset/2` and records one
  structured `pathway_evolution` change log in the same transaction. Any audit
  failure rolls the closure back. Scope comes from the `AuditContext`, never
  from the attribute map.

  Updates and deletes are stale-safe: the scoped row is loaded `FOR UPDATE`
  and its fingerprint is compared with the caller's before any write, so a save
  or delete based on an older row returns `:stale_review` while edits beside the
  row (calendars, pathways) never do. An unchanged valid update returns the
  persisted row without touching `updated_at` or writing audit. The update log
  carries explicit `before`/`after` snapshots, the delete log `before` only.
  Delete removes only the closure row and is independent of calendar activity.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [add_error: 3, get_field: 2]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @type fingerprint :: String.t()
  @type calendar_option :: %{
          service_id: String.t(),
          name: String.t() | nil,
          label: String.t(),
          first_active_date: Date.t() | nil,
          last_active_date: Date.t() | nil,
          active_date_count: non_neg_integer(),
          trip_count: non_neg_integer(),
          closure_count: non_neg_integer()
        }
  @type closure_row :: %{
          evolution: PathwayEvolution.t(),
          fingerprint: fingerprint(),
          pathway: Pathway.t(),
          calendar: calendar_option() | nil
        }
  @type notice :: {:overlaps, [PathwayEvolution.t()]} | :no_active_dates
  @type mutation_result :: %{
          evolution: PathwayEvolution.t(),
          fingerprint: fingerprint(),
          notices: [notice()]
        }

  @doc """
  Lists one published station's scheduled closures beside its station snapshot.

  The result carries the `Gtfs.get_station_report_snapshot/3` map (station,
  child stops, levels, pathways) plus `:closures`, one row per closure whose
  pathway has either endpoint in the station, every pathway mode included.
  Rows are sorted by `pathway_id`, `start_time`, `service_id`, `end_time`, `id`
  and each carries its fingerprint, exact snapshot pathway and native calendar
  option (`nil` when the referenced service has no native row in scope).

  An unknown, non-station (`location_type` other than 1), unpublished or foreign
  target returns `{:error, :not_found}` without rows.
  """
  @spec station_closures(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok,
           %{
             station: Stop.t(),
             child_stops: [Stop.t()],
             levels: [map()],
             pathways: [Pathway.t()],
             closures: [closure_row()]
           }}
          | {:error, :not_found}
  def station_closures(organization_id, gtfs_version_id, stop_id) when is_binary(stop_id) do
    with :ok <- validate_scope(organization_id, gtfs_version_id),
         %Stop{location_type: 1} <-
           Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id),
         {:ok, snapshot} <-
           Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id),
         {:ok, closures} <- closures_for(snapshot, organization_id, gtfs_version_id) do
      {:ok, Map.put(snapshot, :closures, closures)}
    else
      _ -> {:error, :not_found}
    end
  end

  def station_closures(_organization_id, _gtfs_version_id, _stop_id), do: {:error, :not_found}

  @doc """
  Lists the native calendar choices for closures in one published scope.

  One option per service with a `calendars` or `calendar_dates` row, in
  `Calendars.list_calendars/3` order. Metadata-only identities are excluded;
  they remain visible in the calendars context. Options carry the display label
  (the calendar name, or the exact `service_id` when unnamed), effective first
  and last active dates with the active date count, the grouped trip count and
  the scope-wide count of closure rows referencing the service.

  A foreign, invalid or unpublished scope returns `{:error, :not_found}`.
  """
  @spec closure_calendars(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [calendar_option()]} | {:error, :not_found}
  def closure_calendars(organization_id, gtfs_version_id) do
    with :ok <- validate_scope(organization_id, gtfs_version_id),
         {:ok, options} <- calendar_options(organization_id, gtfs_version_id, nil) do
      {:ok, options}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns the count of closure rows in one published organization/version.

  Malformed identifiers, foreign scopes and unpublished versions count as 0.
  """
  @spec count_closures(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def count_closures(organization_id, gtfs_version_id) do
    if validate_scope(organization_id, gtfs_version_id) == :ok do
      scoped_evolutions(organization_id, gtfs_version_id)
      |> Repo.aggregate(:count)
    else
      0
    end
  end

  @doc """
  Returns the fingerprint of one persisted closure row.

  Mutations and the editor compare this digest against the row they loaded, so
  a save or delete whose fingerprint differs from the current row is refused as
  stale. It covers exactly the persisted row: referenced calendar or pathway
  edits leave it unchanged, any write to the row changes it.
  """
  @spec fingerprint(PathwayEvolution.t()) :: fingerprint()
  def fingerprint(%PathwayEvolution{} = evolution) do
    %{
      id: evolution.id,
      organization_id: evolution.organization_id,
      gtfs_version_id: evolution.gtfs_version_id,
      pathway_id: evolution.pathway_id,
      service_id: evolution.service_id,
      start_time: evolution.start_time,
      end_time: evolution.end_time,
      note: evolution.note,
      inserted_at: evolution.inserted_at,
      updated_at: evolution.updated_at
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Creates one validated closure under the published-version write lock.

  The actor's active editor membership is rechecked first (`:forbidden` on a
  missing, foreign, deactivated or role-less membership), then the scoped
  published version is locked (`:not_found` when unpublished or foreign). The
  `service_id` must carry at least one `calendars` or `calendar_dates` row in the
  version — a metadata-only identity is refused with a `:service_id` field error
  — and `pathway_id` must be an exact pathway of the version, a `:pathway_id`
  field error otherwise. When the audit context carries a `station_stop_id`, the
  station must be a real station in the scope (`:not_found` otherwise) and the
  pathway must belong to it (a `:pathway_id` field error otherwise).

  The row is inserted through `PathwayEvolution.changeset/2` (which owns the
  window rules and the note ceiling) and one structured `pathway_evolution`
  change log records the closure UUID as `entity_id`, `pathway_id` as external
  ID and `before` = nil / `after` = the normalized closure snapshot in the same
  transaction; any audit failure rolls back the closure. An exact duplicate
  tuple is refused with "This closure already exists."

  A successful create returns the persisted row, its fingerprint and notices:
  `{:overlaps, others}` names other closures on the same pathway and `service_id`
  whose windows overlap (adjacent windows and other services produce no overlap
  notice), and `:no_active_dates` reports a referenced calendar with no active
  service dates. Scope comes from the audit context, never from `attrs`.
  """
  @spec create_pathway_evolution(map(), AuditContext.t()) ::
          {:ok, mutation_result()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def create_pathway_evolution(attrs, %AuditContext{} = audit_context) when is_map(attrs) do
    transact(fn ->
      authorize_editor!(audit_context)
      Calendars.lock_published_version!(audit_context)
      create_locked!(attrs, audit_context)
    end)
  end

  defp create_locked!(attrs, audit_context) do
    station = station_scope!(audit_context)

    changeset =
      %PathwayEvolution{
        organization_id: audit_context.organization_id,
        gtfs_version_id: audit_context.gtfs_version_id
      }
      |> PathwayEvolution.changeset(attrs)
      |> validate_service_reference(audit_context)
      |> validate_pathway_reference(audit_context, station)

    evolution = changeset |> Repo.insert() |> write_or_rollback!()
    audit!(audit_context, evolution, "created")

    mutation_result(evolution)
  end

  @doc """
  Updates one persisted closure under the published-version write lock.

  The create rules apply unchanged: the actor's active editor membership is
  rechecked (`:forbidden` otherwise), the scoped published version is locked
  (`:not_found` when unpublished or foreign) and the station scope is resolved
  from the audit context. The scoped row is then loaded `FOR UPDATE` and its
  fingerprint compared with the caller's before any write: a mismatch returns
  `:stale_review` and an unknown, foreign or malformed closure id returns
  `:not_found`, neither writing anything.

  The update goes through `PathwayEvolution.changeset/2` (window rules and note
  ceiling) and rechecks the native service and pathway references, including
  station membership. A valid submission whose fields are unchanged returns the
  persisted row and its fingerprint without touching `updated_at` or writing
  audit. A real change records one `pathway_evolution` change log with explicit
  `before`/`after` snapshots in the same transaction; any audit failure rolls
  the update back. Notices match create: same-service `{:overlaps, others}` and
  `:no_active_dates`. Scope comes from the audit context, never from `attrs`.
  """
  @spec update_pathway_evolution(Ecto.UUID.t(), map(), fingerprint(), AuditContext.t()) ::
          {:ok, mutation_result()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | :stale_review}
  def update_pathway_evolution(id, attrs, expected_fingerprint, %AuditContext{} = audit_context)
      when is_map(attrs) do
    transact(fn ->
      authorize_editor!(audit_context)
      Calendars.lock_published_version!(audit_context)
      evolution = lock_evolution!(id, expected_fingerprint, audit_context)
      update_locked!(evolution, attrs, audit_context)
    end)
  end

  @doc """
  Deletes one persisted closure under the published-version write lock.

  Authorization, the version lock, the scoped row load and the fingerprint
  compare match `update_pathway_evolution/4`: a mismatched
  fingerprint returns `:stale_review` and preserves the row, and an unknown,
  foreign or malformed closure id returns `:not_found`.

  Deletion is independent of calendar activity: no notice or active-date state
  can block it, and only the closure row is removed — its calendar and pathway
  rows are left intact. One `pathway_evolution` change log records the `before`
  snapshot in the same transaction; any audit failure rolls the delete back.
  """
  @spec delete_pathway_evolution(Ecto.UUID.t(), fingerprint(), AuditContext.t()) ::
          {:ok, %{deleted: PathwayEvolution.t()}}
          | {:error, :forbidden | :not_found | :stale_review}
  def delete_pathway_evolution(id, expected_fingerprint, %AuditContext{} = audit_context) do
    transact(fn ->
      authorize_editor!(audit_context)
      Calendars.lock_published_version!(audit_context)
      evolution = lock_evolution!(id, expected_fingerprint, audit_context)
      deleted = evolution |> Repo.delete() |> write_or_rollback!()
      audit!(audit_context, deleted, "deleted")
      %{deleted: deleted}
    end)
  end

  defp authorize_editor!(%AuditContext{} = audit_context) do
    case Calendars.authorize_editor(audit_context) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_locked!(%PathwayEvolution{} = evolution, attrs, %AuditContext{} = audit_context) do
    station = station_scope!(audit_context)

    changeset =
      evolution
      |> PathwayEvolution.changeset(attrs)
      |> validate_service_reference(audit_context)
      |> validate_pathway_reference(audit_context, station)

    cond do
      not changeset.valid? ->
        Repo.rollback(changeset)

      # An unchanged valid submission writes neither row nor audit.
      changeset.changes == %{} ->
        mutation_result(evolution)

      true ->
        apply_update!(evolution, changeset, audit_context)
    end
  end

  defp apply_update!(%PathwayEvolution{} = evolution, changeset, %AuditContext{} = audit_context) do
    before = Gtfs.entity_snapshot(:pathway_evolution, evolution)
    updated = changeset |> Repo.update() |> write_or_rollback!()

    audit!(audit_context, updated, "updated", %{
      before: before,
      after: Gtfs.entity_snapshot(:pathway_evolution, updated)
    })

    mutation_result(updated)
  end

  # The scoped row is locked before the fingerprint compare, so concurrent
  # editors serialize here and the slower one sees the committed row and a
  # stale fingerprint. A missing, foreign or malformed id is :not_found.
  defp lock_evolution!(id, expected_fingerprint, %AuditContext{} = audit_context) do
    evolution = locked_evolution(audit_context, id)

    cond do
      is_nil(evolution) -> Repo.rollback(:not_found)
      fingerprint(evolution) != expected_fingerprint -> Repo.rollback(:stale_review)
      true -> evolution
    end
  end

  defp locked_evolution(%AuditContext{} = audit_context, id) do
    with true <- is_binary(id),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      from(e in scoped_evolutions(audit_context.organization_id, audit_context.gtfs_version_id),
        where: e.id == ^uuid,
        lock: "FOR UPDATE"
      )
      |> Repo.one()
    else
      _other -> nil
    end
  end

  defp mutation_result(%PathwayEvolution{} = evolution) do
    %{evolution: evolution, fingerprint: fingerprint(evolution), notices: notices_for(evolution)}
  end

  # The station scope is authority, not a field: a missing, foreign or
  # non-station target returns :not_found before any field validation, matching
  # the read boundary. A context without a station scope skips the check.
  defp station_scope!(%AuditContext{station_stop_id: nil}), do: nil

  defp station_scope!(%AuditContext{} = audit_context) do
    case Gtfs.get_stop_by_stop_id(
           audit_context.organization_id,
           audit_context.gtfs_version_id,
           audit_context.station_stop_id
         ) do
      %Stop{location_type: 1} = station -> station
      _other -> Repo.rollback(:not_found)
    end
  end

  defp validate_service_reference(changeset, %AuditContext{} = audit_context) do
    service_id = get_field(changeset, :service_id)

    if present?(service_id) and
         not MapSet.member?(
           native_service_ids(audit_context.organization_id, audit_context.gtfs_version_id),
           service_id
         ) do
      add_error(changeset, :service_id, "has no calendar or calendar dates in this version")
    else
      changeset
    end
  end

  defp validate_pathway_reference(changeset, %AuditContext{} = audit_context, station) do
    pathway_id = get_field(changeset, :pathway_id)

    if present?(pathway_id) do
      cond do
        is_nil(scoped_pathway(audit_context, pathway_id)) ->
          add_error(changeset, :pathway_id, "does not exist in this version")

        not is_nil(station) and not pathway_at_station?(audit_context, station, pathway_id) ->
          add_error(changeset, :pathway_id, "is not a pathway at this station")

        true ->
          changeset
      end
    else
      changeset
    end
  end

  defp scoped_pathway(%AuditContext{} = audit_context, pathway_id) do
    from(p in Pathway,
      where:
        p.organization_id == ^audit_context.organization_id and
          p.gtfs_version_id == ^audit_context.gtfs_version_id and
          p.pathway_id == ^pathway_id
    )
    |> Repo.one()
  end

  # Membership reuses the station snapshot's pathway rule unchanged: the
  # pathway has either endpoint among the station's descendant stops.
  defp pathway_at_station?(%AuditContext{} = audit_context, station, pathway_id) do
    audit_context.organization_id
    |> Gtfs.list_pathways_for_station(audit_context.gtfs_version_id, station.id)
    |> Enum.any?(&(&1.pathway_id == pathway_id))
  end

  defp write_or_rollback!({:ok, written}), do: written
  defp write_or_rollback!({:error, error}), do: Repo.rollback(error)

  defp audit!(
         %AuditContext{} = audit_context,
         %PathwayEvolution{} = evolution,
         action,
         attrs \\ %{}
       ) do
    case Gtfs.record_change_in_transaction(
           audit_context,
           :pathway_evolution,
           evolution,
           action,
           attrs
         ) do
      {:ok, log} -> log
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp notices_for(%PathwayEvolution{} = evolution) do
    overlaps = overlapping_closures(evolution)

    overlap_notices = if overlaps == [], do: [], else: [{:overlaps, overlaps}]

    if service_active_dates?(evolution) do
      overlap_notices
    else
      overlap_notices ++ [:no_active_dates]
    end
  end

  # Half-open windows: two closures overlap only when each starts before the
  # other ends, so adjacent windows never warn. Only the same pathway and
  # service_id can warn.
  defp overlapping_closures(%PathwayEvolution{} = evolution) do
    from(e in PathwayEvolution,
      where:
        e.organization_id == ^evolution.organization_id and
          e.gtfs_version_id == ^evolution.gtfs_version_id and
          e.pathway_id == ^evolution.pathway_id and e.service_id == ^evolution.service_id and
          e.id != ^evolution.id and
          e.start_time < ^evolution.end_time and e.end_time > ^evolution.start_time,
      order_by: [asc: e.start_time, asc: e.end_time, asc: e.id]
    )
    |> Repo.all()
  end

  defp service_active_dates?(%PathwayEvolution{} = evolution) do
    organization_id = evolution.organization_id
    gtfs_version_id = evolution.gtfs_version_id
    service_id = evolution.service_id

    calendar =
      from(c in Calendar,
        where:
          c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id and
            c.service_id == ^service_id
      )
      |> Repo.one()

    exceptions =
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id and
            d.service_id == ^service_id
      )
      |> Repo.all()

    ServiceDates.active_dates(calendar, exceptions) != []
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp closures_for(snapshot, organization_id, gtfs_version_id) do
    pathway_by_id = Map.new(snapshot.pathways, &{&1.pathway_id, &1})

    evolutions =
      scoped_evolutions(organization_id, gtfs_version_id)
      |> where([e], e.pathway_id in ^Map.keys(pathway_by_id))
      |> order_by([e], asc: e.pathway_id, asc: e.start_time, asc: e.service_id, asc: e.end_time)
      |> order_by([e], asc: e.id)
      |> Repo.all()

    with {:ok, options} <-
           calendar_options(
             organization_id,
             gtfs_version_id,
             MapSet.new(evolutions, & &1.service_id)
           ) do
      options_by_service = Map.new(options, &{&1.service_id, &1})

      rows =
        Enum.map(evolutions, fn evolution ->
          %{
            evolution: evolution,
            fingerprint: fingerprint(evolution),
            pathway: Map.fetch!(pathway_by_id, evolution.pathway_id),
            calendar: Map.get(options_by_service, evolution.service_id)
          }
        end)

      {:ok, rows}
    end
  end

  defp calendar_options(organization_id, gtfs_version_id, only_service_ids) do
    with {:ok, summaries} <- Calendars.list_calendars(organization_id, gtfs_version_id) do
      native = native_service_ids(organization_id, gtfs_version_id)
      closure_counts = closure_counts_by_service(organization_id, gtfs_version_id)

      options =
        summaries
        |> Enum.filter(fn summary ->
          MapSet.member?(native, summary.service_id) and
            (is_nil(only_service_ids) or MapSet.member?(only_service_ids, summary.service_id))
        end)
        |> Enum.map(&calendar_option(&1, closure_counts))

      {:ok, options}
    end
  end

  defp calendar_option(summary, closure_counts) do
    %{
      service_id: summary.service_id,
      name: summary.name,
      label: calendar_label(summary),
      first_active_date: summary.first_active_date,
      last_active_date: summary.last_active_date,
      active_date_count: length(summary.active_dates),
      trip_count: summary.trip_count,
      closure_count: Map.get(closure_counts, summary.service_id, 0)
    }
  end

  defp calendar_label(%{name: name, service_id: service_id}) when is_binary(name) do
    case String.trim(name) do
      "" -> service_id
      trimmed -> trimmed
    end
  end

  defp calendar_label(%{service_id: service_id}), do: service_id

  # The native reference boundary for closures: a service counts only when a
  # weekly or exception row exists in the scope. A metadata-only identity does
  # not qualify.
  defp native_service_ids(organization_id, gtfs_version_id) do
    weekly =
      from(c in Calendar,
        where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id,
        select: c.service_id
      )

    dates =
      from(d in CalendarDate,
        where: d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id,
        select: d.service_id
      )

    from(s in subquery(union(weekly, ^dates)), select: s.service_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp closure_counts_by_service(organization_id, gtfs_version_id) do
    scoped_evolutions(organization_id, gtfs_version_id)
    |> group_by([e], e.service_id)
    |> select([e], {e.service_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp scoped_evolutions(organization_id, gtfs_version_id) do
    from(e in PathwayEvolution,
      where: e.organization_id == ^organization_id and e.gtfs_version_id == ^gtfs_version_id
    )
  end

  defp validate_scope(organization_id, gtfs_version_id) do
    if uuid?(organization_id) and uuid?(gtfs_version_id) and
         Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
      :ok
    else
      :error
    end
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false
end
