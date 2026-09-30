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

  `preview_closures/5` loads one station's analysis inputs inside
  `Export.with_read_snapshot/1`, so the station snapshot, the station's closures,
  the referenced native calendars and exceptions, the agency zone and the
  service-day origins all describe one committed revision. Time-aware evaluation
  never uses DisplayClock's UTC fallback: a missing, invalid or conflicting
  agency zone is refused with its reason while closure authoring still works.

  `analyze_closures/5` reuses that one snapshot and sweeps the same station over
  a bounded range of service dates. The covered span is
  `[origin(first), max(origin(last + 1), the latest end of an instance on
  last))`, so a `00:00:00` window on a daylight-saving service date and a
  `25:00:00` window on the last service date are both inside it. Every instance
  boundary is swept rather than sampled, and only the periods whose comparison
  differs from the base graph are returned, each with the exact active instances
  that caused it. A limit is never reported as a complete answer: an incomplete
  base evaluation keeps the report incomplete whatever the findings are.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [add_error: 3, get_field: 2]

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions.Schedule
  alias GtfsPlanner.Gtfs.StationReport2.Evolutions
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # Fixed local resource bounds, not configuration. The candidate-date ceiling
  # keeps a pathological integer service time from generating a span to query,
  # and the instance ceiling is integer arithmetic checked before any instance is
  # built. The range ceiling bounds the service dates one request may ask about.
  @max_instances 200_000
  @max_candidate_dates 100_000
  @max_range_days 31

  # A `before` action sits 60 seconds before its instance starts (AC-38).
  @before_offset_seconds 60

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
  @type boundary_target :: :before | :closes | :during | :reopens
  @type analysis_error ::
          :not_found
          | :range_invalid
          | {:timezone_unavailable, DisplayClock.fallback_reason()}
          | :analysis_too_large
  @type preview :: %{
          service_date: Date.t(),
          service_time: non_neg_integer(),
          instant: DateTime.t(),
          local_time: NaiveDateTime.t(),
          timezone: String.t(),
          closed: [Schedule.instance()],
          day_instances: [Schedule.instance()],
          timeline_instances: [Schedule.instance()],
          timeline_start: DateTime.t(),
          timeline_end: DateTime.t(),
          boundary_targets: %{
            {Ecto.UUID.t(), Date.t(), boundary_target} => %{
              date: Date.t(),
              time: non_neg_integer()
            }
          },
          base: Evolutions.evaluation(),
          effective: Evolutions.evaluation(),
          comparison: Evolutions.comparison(),
          computed_at: DateTime.t()
        }
  @type range_finding :: %{
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          local_start: NaiveDateTime.t(),
          local_end: NaiveDateTime.t(),
          start_utc_offset: integer(),
          end_utc_offset: integer(),
          preview_target: %{date: Date.t(), time: non_neg_integer()},
          instances: [Schedule.instance()],
          comparison: Evolutions.comparison()
        }
  @type range_report :: %{
          first_date: Date.t(),
          last_date: Date.t(),
          status: :complete | :incomplete,
          incomplete_reasons: [Evolutions.incomplete_reason()],
          horizon_start: DateTime.t(),
          horizon_end: DateTime.t(),
          local_start: NaiveDateTime.t(),
          local_end: NaiveDateTime.t(),
          timezone: String.t(),
          base: Evolutions.evaluation(),
          findings: [range_finding()],
          computed_at: DateTime.t()
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
  Returns the native reference boundary for closures in one organization/version.

  A service id belongs to the set only when a `calendars` or `calendar_dates`
  row exists in the scope; a metadata-only identity (a `calendar_attributes`
  row alone) does not qualify. This is the single definition of that boundary:
  closure authoring, the closure usage guards and the registered
  `pathway_evolutions.txt` import pass all read it, so a feed cannot satisfy an
  import reference while failing an authoring reference, or the reverse.
  """
  @spec native_service_ids(Ecto.UUID.t(), Ecto.UUID.t()) :: MapSet.t(String.t())
  def native_service_ids(organization_id, gtfs_version_id) do
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

  @doc """
  Previews one station's closure effect at a single service date and service time.

  Every input is loaded inside `Export.with_read_snapshot/1` - the production
  `Export.Snapshot.Repo` adapter establishes a repeatable-read transaction before
  the first query - so the station snapshot, the station's closures, the
  referenced native calendars and exceptions, the agency zone and the service-day
  origins all describe one committed revision. Graph evaluation, comparison and
  localization run after that transaction is released.

  Service-day time is exact: `service_time` is added to the PostgreSQL-derived
  origin of `service_date` (local noon in the single valid agency zone minus 12
  elapsed hours), so `00:15:00` on a New York spring-forward date resolves to
  `2027-03-14T04:15:00Z` and a value above `24:00:00` stays above it.
  `closed` names every instance covering the instant from any service date, so a
  Monday `25:00:00` window closes its pathway on Tuesday `01:00`. `day_instances`
  are the selected service date's instances and `timeline_instances` adds every
  earlier or later instance intersecting
  `[origin(service_date), max(origin(service_date + 1), latest end on
  service_date))`, so previous-service-date spill-over is visible while the
  boundary targets stay unclipped. `boundary_targets` carries the exact
  `{date, time}` for each selected-date instance's `before`, `closes`, `during`
  and `reopens` action.

  Refusals are `{:error, :not_found}` for a foreign, unpublished, non-station or
  malformed scope, `{:error, {:timezone_unavailable, reason}}` when the agency
  zone is missing, invalid or conflicting (the UTC fallback is never used, and
  authoring still works), and `{:error, :analysis_too_large}` when the candidate
  span or the instance count exceeds its bound. Both bounds are checked before any
  instance is built.

  A non-binary `stop_id` is refused as `:not_found`, matching
  `station_closures/3`. A non-`Date` service date or a negative or non-integer
  service time is a function-clause error, matching `Schedule.preview_dates/3`:
  a caller parses the request before it reaches the loader.
  """
  @spec preview_closures(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), Date.t(), non_neg_integer()) ::
          {:ok, preview()} | {:error, analysis_error()}
  def preview_closures(
        organization_id,
        gtfs_version_id,
        stop_id,
        %Date{} = service_date,
        service_time
      )
      when is_binary(stop_id) and is_integer(service_time) and service_time >= 0 do
    with {:ok, inputs} <-
           load_station_analysis(organization_id, gtfs_version_id, stop_id, fn station ->
             load_preview_inputs(station, service_date, service_time)
           end) do
      {:ok, build_preview(inputs, service_date, service_time)}
    end
  end

  def preview_closures(
        _organization_id,
        _gtfs_version_id,
        _stop_id,
        _service_date,
        _service_time
      ),
      do: {:error, :not_found}

  @doc """
  Reports every access loss one station suffers over `first_date..last_date`.

  This is the range form of `preview_closures/5`: it loads the same inputs
  inside the same read snapshot, then sweeps every instance boundary in the
  covered span instead of sampling instants. A reversed range and a span over 31
  requested service days are refused before a single row is read, because the
  range check cannot answer them.

  The covered span is `[origin(first_date), max(origin(last_date + 1), the
  latest end of an instance on last_date))`, so a `00:00:00` window on a
  daylight-saving service date and a `25:00:00` window on the last service date
  are both inside it. `findings` holds only the periods whose comparison differs
  from the base graph - a lost pair or a platform that lost every step-free
  route - each with its exact active instances, its local endpoints, both UTC
  offsets and the `preview_target` that names its start instant. Periods whose
  active closure identities changed are kept apart, so a cause change is never
  erased; presentation groups these exact periods, it never recomputes them.

  `status` and `incomplete_reasons` come from the base evaluation and are never
  softened: an empty `findings` list beside an `:incomplete` base is not
  "no connection lost".

  Refusals are `{:error, :not_found}` for a foreign, unpublished, non-station or
  malformed scope, `{:error, {:timezone_unavailable, reason}}` when the agency
  zone is missing, invalid or conflicting, `{:error, :range_invalid}` for a
  reversed or over-long range, and `{:error, :analysis_too_large}` when the
  candidate span or the instance count exceeds its bound.
  """
  @spec analyze_closures(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), Date.t(), Date.t()) ::
          {:ok, range_report()} | {:error, analysis_error()}
  def analyze_closures(
        organization_id,
        gtfs_version_id,
        stop_id,
        %Date{} = first_date,
        %Date{} = last_date
      )
      when is_binary(stop_id) do
    with :ok <- within_range_limit(first_date, last_date),
         {:ok, inputs} <-
           load_station_analysis(organization_id, gtfs_version_id, stop_id, fn station ->
             load_range_inputs(station, first_date, last_date)
           end) do
      {:ok, build_range_report(inputs, first_date, last_date)}
    end
  end

  def analyze_closures(_organization_id, _gtfs_version_id, _stop_id, _first, _last),
    do: {:error, :not_found}

  # A reversed range and a span over the requested-day ceiling are refused here,
  # before any row is read. `Date.diff/2` is negative for a reversed range, so one
  # integer comparison covers both refusals.
  defp within_range_limit(%Date{} = first_date, %Date{} = last_date) do
    days = Date.diff(last_date, first_date) + 1
    if days in 1..@max_range_days, do: :ok, else: {:error, :range_invalid}
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
      Authorization.lock_editor!(audit_context)
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
      Authorization.lock_editor!(audit_context)
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
      Authorization.lock_editor!(audit_context)
      Calendars.lock_published_version!(audit_context)
      evolution = lock_evolution!(id, expected_fingerprint, audit_context)
      deleted = evolution |> Repo.delete() |> write_or_rollback!()
      audit!(audit_context, deleted, "deleted")
      %{deleted: deleted}
    end)
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

  # The station's own closure rows, in the deterministic closure-row order. The
  # list read and the analysis snapshot share it, so both name the same rows.
  defp station_evolutions(snapshot, organization_id, gtfs_version_id) do
    pathway_ids = snapshot.pathways |> Enum.map(& &1.pathway_id) |> Enum.uniq()

    scoped_evolutions(organization_id, gtfs_version_id)
    |> where([e], e.pathway_id in ^pathway_ids)
    |> order_by([e], asc: e.pathway_id, asc: e.start_time, asc: e.service_id, asc: e.end_time)
    |> order_by([e], asc: e.id)
    |> Repo.all()
  end

  # -- analysis snapshot ------------------------------------------------------

  # One station's analysis inputs, loaded inside a single repeatable-read
  # transaction and handed to `continue`, which resolves the date-dependent part
  # (the preview's candidate envelope, the range check's horizon) against the same
  # revision. Returning early does not roll back: this is a read.
  defp load_station_analysis(organization_id, gtfs_version_id, stop_id, continue)
       when is_binary(stop_id) do
    loaded =
      Export.with_read_snapshot(fn ->
        with :ok <- validate_scope(organization_id, gtfs_version_id),
             %Stop{location_type: 1} <-
               Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id),
             {:ok, snapshot} <-
               Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
          snapshot
          |> station_inputs(organization_id, gtfs_version_id)
          |> usable_zone(continue)
        else
          _other -> {:error, :not_found}
        end
      end)

    case loaded do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp station_inputs(snapshot, organization_id, gtfs_version_id) do
    evolutions = station_evolutions(snapshot, organization_id, gtfs_version_id)

    %{
      snapshot: snapshot,
      evolutions: evolutions,
      natives: native_calendars(organization_id, gtfs_version_id, evolutions),
      zone: DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    }
  end

  # Time-aware evaluation never uses DisplayClock's UTC fallback, so a missing,
  # invalid or conflicting agency zone is refused with its reason before any
  # candidate date is generated. Closure authoring is unaffected.
  defp usable_zone(%{zone: %{fallback?: true, fallback_reason: reason}}, _continue),
    do: {:error, {:timezone_unavailable, reason}}

  defp usable_zone(station, continue), do: continue.(station)

  # `%{service_id => {Calendar.t() | nil, [CalendarDate.t()]}}` for the services
  # the station's closures actually reference. A service with no native row maps to
  # `{nil, []}`, which `ServiceDates` treats as an always-inactive service rather
  # than as a second calendar rule.
  defp native_calendars(_organization_id, _gtfs_version_id, []), do: %{}

  defp native_calendars(organization_id, gtfs_version_id, evolutions) do
    service_ids = evolutions |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort()

    calendars =
      from(c in Calendar,
        where:
          c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id and
            c.service_id in ^service_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.service_id, &1})

    exceptions =
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id and
            d.service_id in ^service_ids,
        order_by: [asc: d.service_id, asc: d.date]
      )
      |> Repo.all()

    grouped = Enum.group_by(exceptions, & &1.service_id)

    Map.new(service_ids, fn service_id ->
      {service_id, {Map.get(calendars, service_id), Map.get(grouped, service_id, [])}}
    end)
  end

  # PostgreSQL owns the service-day origin: local noon on the date in the agency
  # zone minus 12 elapsed hours, so a DST transition and a value above 24:00:00
  # need no Elixir timezone database. `interval '12 hours'` is deliberate; '1 day'
  # would be 23 or 25 elapsed hours across a transition.
  defp service_day_origins(timezone, %Date{} = first, %Date{} = last) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT ($1::date + n)::date,
               (($1::date + n)::timestamp + interval '12 hours') AT TIME ZONE $2 - interval '12 hours'
        FROM generate_series(0, $3::date - $1::date) AS n
        """,
        [first, timezone, last]
      )

    Map.new(rows, fn [date, origin] -> {date, origin} end)
  end

  # -- analysis inputs --------------------------------------------------------

  defp load_preview_inputs(station, service_date, service_time) do
    with {:ok, envelope} <-
           sized_envelope(Schedule.preview_dates(station.evolutions, service_date, service_time)),
         {:ok, envelope} <-
           expand_envelope(
             station,
             envelope,
             &bounds_preview_interval?(&1, station.evolutions, service_date, service_time)
           ) do
      {:ok, Map.merge(station, envelope)}
    end
  end

  defp load_range_inputs(station, %Date{} = first_date, %Date{} = last_date) do
    with {:ok, envelope} <-
           sized_envelope(Schedule.range_dates(station.evolutions, first_date, last_date)),
         {:ok, envelope} <-
           expand_envelope(
             station,
             envelope,
             &bounds_range_interval?(&1, station.evolutions, first_date, last_date)
           ) do
      {:ok, Map.merge(station, envelope)}
    end
  end

  # `Date.diff/2` is integer arithmetic on the lazy candidate range, so the
  # candidate bound is checked before a single date is generated or queried.
  defp sized_envelope(dates) do
    if Date.diff(dates.last, dates.first) + 1 > @max_candidate_dates do
      {:error, :analysis_too_large}
    else
      {:ok, %{first: dates.first, last: dates.last, loaded: nil, origins: %{}, active_dates: %{}}}
    end
  end

  # `Schedule.preview_dates/3` and `Schedule.range_dates/3` size the candidate
  # envelope with 23 elapsed hours per service date, which is only an estimate: a
  # zone whose offset moves far can leave the initial edges unable to bound the
  # displayed interval. Each pass checks the instance bound and then the exact
  # origin inequalities, widening the envelope by one civil date per edge and
  # querying only the dates it has not loaded. The candidate bound stops the loop,
  # so the envelope is never silently incomplete.
  defp expand_envelope(station, envelope, bounds) do
    with {:ok, active_dates} <- active_dates_within(station, envelope.first, envelope.last),
         :ok <- check_instance_bound(station.evolutions, active_dates),
         {:ok, envelope} <- load_envelope_origins(station.zone, envelope) do
      envelope = %{envelope | active_dates: active_dates}

      if bounds.(envelope), do: {:ok, envelope}, else: widen_and_retry(station, envelope, bounds)
    end
  end

  defp widen_and_retry(station, envelope, bounds) do
    with {:ok, widened} <- widen_envelope(envelope) do
      expand_envelope(station, widened, bounds)
    end
  end

  # The envelope is adequate when its loaded origins bound the absolute interval
  # the preview displays, `[a, b)`: `a` is the selected date's origin and `b` is
  # the later of the next date's origin, the longest closure window on the
  # selected date and the requested instant plus one second. An instance can
  # intersect the interval only when `origin(lower) + max_end <= a`, and can start
  # inside it only when `origin(upper) >= b`. The upper edge also requires the next
  # date's origin to be loaded, because the displayed span ends there.
  defp bounds_preview_interval?(
         %{origins: origins, first: first, last: last},
         evolutions,
         service_date,
         service_time
       ) do
    max_end = longest_window(evolutions)
    start_at = Map.fetch!(origins, service_date)
    instant = DateTime.add(start_at, service_time, :second)
    next_date = Date.add(service_date, 1)

    required_end =
      latest_instant(
        Enum.reject(
          [
            Map.get(origins, next_date),
            DateTime.add(start_at, max_end, :second),
            DateTime.add(instant, 1, :second)
          ],
          &is_nil/1
        )
      )

    lower_reaches_start? =
      DateTime.compare(
        DateTime.add(Map.fetch!(origins, first), max_end, :second),
        start_at
      ) != :gt

    upper_reaches_end? =
      Date.compare(last, next_date) != :lt and
        DateTime.compare(Map.fetch!(origins, last), required_end) != :lt

    lower_reaches_start? and upper_reaches_end?
  end

  # The range check has the same shape: it must cover
  # `[origin(first_date), horizon end)`, where the horizon end is the later of
  # the origin after `last_date` and the latest end of an instance on
  # `last_date`. The last date's own instances establish that end, so they are
  # the only ones the envelope has to bound before the sweep runs.
  # `Schedule.range_dates/3` always includes `last_date + 1`, so the origin
  # `Schedule.horizon/4` needs is loaded from the first pass on.
  defp bounds_range_interval?(
         %{origins: origins, active_dates: active_dates, first: first, last: last},
         evolutions,
         %Date{} = first_date,
         %Date{} = last_date
       ) do
    max_end = longest_window(evolutions)
    start_at = Map.fetch!(origins, first_date)
    next_date = Date.add(last_date, 1)

    {_start_at, required_end} =
      Schedule.horizon(
        origins,
        last_date_instances(evolutions, active_dates, origins, last_date),
        first_date,
        last_date
      )

    lower_reaches_start? =
      DateTime.compare(
        DateTime.add(Map.fetch!(origins, first), max_end, :second),
        start_at
      ) != :gt

    upper_reaches_end? =
      Date.compare(last, next_date) != :lt and
        DateTime.compare(Map.fetch!(origins, last), required_end) != :lt

    lower_reaches_start? and upper_reaches_end?
  end

  # The instances of the requested last service date only, for the horizon
  # calculation the envelope must be wide enough for. Building them through
  # `Schedule.instances/3` keeps the origin requirement in one place: a date with
  # no loaded origin contributes nothing, exactly as it does in the full sweep.
  defp last_date_instances(evolutions, active_dates, origins, %Date{} = last_date) do
    on_last_date =
      Map.new(active_dates, fn {service_id, dates} ->
        {service_id, if(last_date in dates, do: [last_date], else: [])}
      end)

    Schedule.instances(evolutions, on_last_date, origins)
  end

  # One civil date per edge, with the candidate bound rechecked before the dates
  # are queried.
  defp widen_envelope(%{first: first, last: last} = envelope) do
    if Date.diff(last, first) + 3 > @max_candidate_dates do
      {:error, :analysis_too_large}
    else
      {:ok, %{envelope | first: Date.add(first, -1), last: Date.add(last, 1)}}
    end
  end

  # Each pass widens the envelope by one civil date per edge, so only the dates
  # outside the already loaded range are queried: widening a long-running loop
  # stays proportional to the envelope rather than to the passes. The loaded range
  # is the envelope, so each slice re-reads at most one date it already has.
  defp load_envelope_origins(zone, %{first: first, last: last, loaded: nil} = envelope) do
    origins = service_day_origins(zone.timezone, first, last)
    {:ok, %{envelope | loaded: {first, last}, origins: origins}}
  end

  defp load_envelope_origins(zone, %{first: first, last: last, loaded: {from, to}} = envelope) do
    origins =
      [{first, from}, {to, last}]
      |> Enum.reject(fn {added_first, added_last} ->
        Date.compare(added_first, added_last) == :gt
      end)
      |> Enum.flat_map(fn {added_first, added_last} ->
        service_day_origins(zone.timezone, added_first, added_last) |> Map.to_list()
      end)
      |> Enum.reduce(envelope.origins, fn {date, origin}, acc -> Map.put(acc, date, origin) end)

    {:ok, %{envelope | loaded: {earlier(first, from), later(last, to)}, origins: origins}}
  end

  defp earlier(left, right) do
    if Date.compare(left, right) == :lt, do: left, else: right
  end

  defp later(left, right) do
    if Date.compare(left, right) == :gt, do: left, else: right
  end

  defp active_dates_within(station, %Date{} = first, %Date{} = last) do
    {:ok,
     Map.new(station.natives, fn {service_id, {calendar, exceptions}} ->
       {service_id, ServiceDates.active_dates_between(calendar, exceptions, first, last)}
     end)}
  end

  # `Schedule.instance_count/2` is integer arithmetic over the supplied date
  # lists, so the bound holds before a single instance is built. Every candidate
  # date in the final envelope has a loaded origin, so the count and the built
  # instance set agree here.
  defp check_instance_bound(evolutions, active_dates) do
    if Schedule.instance_count(evolutions, active_dates) > @max_instances do
      {:error, :analysis_too_large}
    else
      :ok
    end
  end

  defp longest_window(evolutions) do
    Enum.reduce(evolutions, 0, fn evolution, max_end ->
      max(evolution.end_time, max_end)
    end)
  end

  # -- preview result ---------------------------------------------------------

  defp build_preview(
         %{
           snapshot: snapshot,
           evolutions: evolutions,
           zone: zone,
           origins: origins,
           active_dates: active_dates
         },
         service_date,
         service_time
       ) do
    instances = Schedule.instances(evolutions, active_dates, origins)
    start_at = Map.fetch!(origins, service_date)
    instant = DateTime.add(start_at, service_time, :second)
    day_instances = Enum.filter(instances, &(&1.service_date == service_date))

    # With `first == last` this is the preview's displayed span: the selected
    # date's origin through the later of the next origin and the latest end on
    # that date.
    {timeline_start, timeline_end} =
      Schedule.horizon(origins, day_instances, service_date, service_date)

    closed = Schedule.closed_at(instances, instant)
    base = Evolutions.evaluate(snapshot, MapSet.new())
    effective = Evolutions.evaluate(snapshot, MapSet.new(closed, & &1.pathway_id))
    [local_time] = DisplayClock.localize_many([instant], zone)

    %{
      service_date: service_date,
      service_time: service_time,
      instant: instant,
      local_time: local_time,
      timezone: zone.timezone,
      closed: closed,
      day_instances: day_instances,
      timeline_instances: Enum.filter(instances, &intersects?(&1, timeline_start, timeline_end)),
      timeline_start: timeline_start,
      timeline_end: timeline_end,
      boundary_targets: boundary_targets(day_instances, origins),
      base: base,
      effective: effective,
      comparison: Evolutions.compare(base, effective),
      computed_at: DateTime.utc_now()
    }
  end

  defp intersects?(instance, starts_at, ends_at) do
    DateTime.compare(instance.starts_at, ends_at) == :lt and
      DateTime.compare(instance.ends_at, starts_at) == :gt
  end

  # The four action instants for each selected-date instance, named as exact
  # service-day seconds from an origin at or before the target. A `before` target
  # that falls before its own origin walks back to the previous loaded origin, and
  # a `reopens` target past midnight keeps its elapsed seconds (`25:00:00`) rather
  # than being reparsed as a clock label.
  defp boundary_targets(day_instances, origins) do
    for instance <- day_instances,
        {phase, instant} <- boundary_instants(instance),
        into: %{} do
      {{instance.evolution_id, instance.service_date, phase},
       Schedule.preview_target(instant, instance.service_date, origins)}
    end
  end

  defp boundary_instants(instance) do
    starts_at = instance.starts_at
    midpoint = div(DateTime.diff(instance.ends_at, starts_at, :second), 2)

    [
      before: DateTime.add(starts_at, -@before_offset_seconds, :second),
      closes: starts_at,
      during: DateTime.add(starts_at, midpoint, :second),
      reopens: instance.ends_at
    ]
  end

  # -- range result -----------------------------------------------------------

  defp build_range_report(
         %{
           snapshot: snapshot,
           evolutions: evolutions,
           zone: zone,
           origins: origins,
           active_dates: active_dates
         },
         first_date,
         last_date
       ) do
    instances = Schedule.instances(evolutions, active_dates, origins)
    {horizon_start, horizon_end} = Schedule.horizon(origins, instances, first_date, last_date)
    base = Evolutions.evaluate(snapshot, MapSet.new())

    losses =
      loss_periods(Schedule.segments(instances, horizon_start, horizon_end), snapshot, base)

    # Every local label the report shows comes from one conversion, so the
    # offsets below are the difference between the converted wall clock and the
    # UTC instant it names, and not arithmetic the caller repeats.
    [local_start, local_end | period_locals] =
      DisplayClock.localize_many(
        [horizon_start, horizon_end] ++ Enum.flat_map(losses, &period_endpoints/1),
        zone
      )

    findings =
      losses
      |> Enum.zip(Enum.chunk_every(period_locals, 2, 2, :discard))
      |> Enum.map(fn {{segment, comparison}, [local_start, local_end]} ->
        range_finding(segment, comparison, local_start, local_end, origins)
      end)

    %{
      first_date: first_date,
      last_date: last_date,
      # The base evaluation's own status. An incomplete station is never softened
      # into a complete answer by an empty findings list.
      status: base.status,
      incomplete_reasons: base.incomplete_reasons,
      horizon_start: horizon_start,
      horizon_end: horizon_end,
      local_start: local_start,
      local_end: local_end,
      timezone: zone.timezone,
      base: base,
      findings: findings,
      computed_at: DateTime.utc_now()
    }
  end

  # The periods of the sweep whose comparison differs from the base graph: a lost
  # pair, or a platform that lost every step-free route. A period that loses no
  # connection is not a finding, and an unchanged graph is never a finding.
  # `Schedule.segments/3` already keeps periods apart when their active closure
  # identities differ, so a cause change survives the filter and no second merge
  # is needed here.
  #
  # Two periods with the same closed pathway set are the same graph, so the
  # comparison is computed once per closed set within this call and never cached
  # across calls.
  defp loss_periods(segments, snapshot, base) do
    {losses, _cache} =
      Enum.reduce(segments, {[], %{}}, fn segment, {losses, cache} ->
        comparison =
          Map.get_lazy(cache, segment.closed_pathway_ids, fn ->
            Evolutions.compare(base, Evolutions.evaluate(snapshot, segment.closed_pathway_ids))
          end)

        if reports_loss?(comparison) do
          {[{segment, comparison} | losses],
           Map.put(cache, segment.closed_pathway_ids, comparison)}
        else
          {losses, cache}
        end
      end)

    Enum.reverse(losses)
  end

  defp reports_loss?(comparison) do
    comparison.lost != [] or
      comparison.platforms_without_step_free.to_platform != [] or
      comparison.platforms_without_step_free.to_exit != []
  end

  defp period_endpoints({segment, _comparison}), do: [segment.starts_at, segment.ends_at]

  defp range_finding(segment, comparison, local_start, local_end, origins) do
    %{
      starts_at: segment.starts_at,
      ends_at: segment.ends_at,
      local_start: local_start,
      local_end: local_end,
      start_utc_offset: utc_offset(segment.starts_at, local_start),
      end_utc_offset: utc_offset(segment.ends_at, local_end),
      preview_target: preview_target(segment, origins),
      instances: segment.instances,
      comparison: comparison
    }
  end

  # The zone offset of one instant, from the converted wall clock the shared
  # localization returned. Repeated civil clock hours stay distinguishable
  # because each endpoint keeps its own offset next to its absolute instant.
  defp utc_offset(%DateTime{} = instant, %NaiveDateTime{} = local) do
    NaiveDateTime.diff(local, DateTime.to_naive(instant), :second)
  end

  # The service date and elapsed seconds naming a loss period's start instant.
  defp preview_target(segment, origins) do
    Schedule.preview_target(segment.starts_at, latest_service_date(segment, origins), origins)
  end

  # The active instances are preferred, so a `25:00:00` window keeps its own
  # service date instead of being reparsed as a clock label, and their origin is
  # always at or before the instant they cover. A period with no instance cannot
  # report a loss, so the fallback is the latest loaded origin at or before the
  # instant, which `Schedule.preview_target/3` would choose for itself.
  defp latest_service_date(%{instances: [_ | _] = instances}, _origins) do
    instances |> Enum.map(& &1.service_date) |> Enum.reduce(&later/2)
  end

  defp latest_service_date(%{starts_at: starts_at}, origins) do
    Enum.reduce(origins, nil, fn {candidate, origin}, latest ->
      if DateTime.compare(origin, starts_at) != :gt do
        later_or_nil(candidate, latest)
      else
        latest
      end
    end)
  end

  defp later_or_nil(candidate, nil), do: candidate

  defp later_or_nil(candidate, latest) do
    if Date.compare(candidate, latest) == :gt, do: candidate, else: latest
  end

  defp latest_instant([instant | rest]) do
    Enum.reduce(rest, instant, &later_instant/2)
  end

  defp later_instant(instant, current) do
    if DateTime.compare(instant, current) == :gt, do: instant, else: current
  end

  defp closures_for(snapshot, organization_id, gtfs_version_id) do
    evolutions = station_evolutions(snapshot, organization_id, gtfs_version_id)
    pathway_by_id = Map.new(snapshot.pathways, &{&1.pathway_id, &1})

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
