defmodule GtfsPlanner.Gtfs.DatedChangePlan do
  @moduledoc """
  Plan-only dated change planning: accepted intent first, computation later.

  This module is the date-bounded change planner (A36). It never writes a
  calendar, trip, time, block, transfer, run or audit row, and it exposes no
  apply, prepared command or execution token (INV-1, AC-10, AC-11). It owns
  intent normalization and acceptance, and the one coherent read those are
  computed from; the computation steps `partition/2`, `project_times/3` and
  `prepare/2` belong to later work.

  ## Two server-owned steps

  `normalize_intent/2` turns submitted form fields plus the caller's own
  selection into a `draft`, or into focused `field_errors` the host renders on
  the same form. `accept_intent/2` re-reads the *current* server selection and
  produces the `accepted` source every later step reads.

  The split is the authority boundary (AC-1, AC-2):

    * Dates are explicit and inclusive. `first_date` and `last_date` are full
      `YYYY-MM-DD` values with a four-digit year, and `last_date` is not before
      `first_date`. A date without a year, a two-digit year, a non-ISO ordering
      or a reversed interval is refused with a message naming the field; no year
      is ever inferred from the current date.
    * The shift is a signed integer second count in `-86400..86400`, so `+300`
      moves the same service-day seconds five minutes later and never rolls into
      the next service date.
    * The approval note is the editor's own supplied provenance: nonblank and at
      most 2,000 characters. An optional source label is at most 200 characters.
    * A selection is 1 to 100 distinct trip UUIDs. A duplicate entry, a
      non-UUID entry, an empty selection and an over-cap selection are refused.
    * No route, organization, actor, version, pack, digest or accepted flag is
      ever read from submitted fields. Those keys are server-owned, and a
      request carrying one is refused rather than quietly dropping it, so a
      client cannot smuggle identity or a pre-baked acceptance.

  ## Acceptance binds the current selection

  `accept_intent/2` recomputes the digest itself and compares the draft's sorted
  trip UUIDs with the caller's current server selection. A selection that
  changed since normalization is `{:error, :selection_changed}`, which is how a
  host invalidates acceptance when a selection changes (AC-2). A draft carrying
  an unexpected key — a forged `input_digest`, `accepted` or identity field — is
  `{:error, :invalid_draft}`: acceptance is produced only from the exact
  normalized shape.

  `accepted` carries `schema_version`, the sorted `trip_ids`, `first_date`,
  `last_date`, `delta_seconds`, `approval_note`, `source_label` and a
  deterministic `input_digest` binding all of them. Two accepts of the same
  normalized intent produce the same digest; changing any bound value changes it
  (INV-2).

  Acceptance confirms the editor's interpretation of their own supplied dates,
  shift and approval text. It freezes that provenance as data; it is not a
  certification of operating approval and it authorizes no write.

  ## One coherent read

  `load/2` reads everything a plan needs inside a single bounded
  `REPEATABLE READ READ ONLY` transaction, so a writer that commits between two
  of its queries cannot make the snapshot describe two database states
  (AC-3, AC-4). It re-authorizes the current editor inside that transaction
  before any scoped entity read, resolves the route and version under the
  current organization, and returns only immutable maps.

  Completeness is admission-based. Each kind is read with `cap + 1` rows, so a
  read that exceeds a cap, a read that does not finish inside the deadline and
  calendar data the native date evaluator cannot read are all
  `{:incomplete, reason}`: a partial read is never reported as a complete one
  (AC-5, CR-3). `dependency_digest` is a content digest over the sorted,
  fully projected rows and their identities, not over counts or timestamps, so
  a same-count replacement changes it.

  The snapshot boundary is the existing
  `GtfsPlanner.Gtfs.ServiceQueries.Snapshot` adapter selection, so a SQL
  sandbox fixture takes its no-op implementation and ordinary use takes the
  production one. `gtfs_dated_change_read_timeout_ms` bounds the read in
  milliseconds; it defaults to 30 seconds.
  """

  import Ecto.Query

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @schema_version 1
  @max_selected_trips 100
  @max_delta_seconds 86_400
  @max_approval_note_length 2_000
  @max_source_label_length 200

  @iso_date_format ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
  @signed_integer_format ~r/\A[+-]?[0-9]+\z/

  # Truthful computation admission limits, not evaluated agency capacity: an
  # over-cap read is incomplete, never a partial complete snapshot.
  @max_selected_trips 100
  @max_version_trips 10_000
  @max_stop_times 75_000
  @max_dependency_rows 20_000

  @read_timeout_env :gtfs_dated_change_read_timeout_ms
  @read_timeout_ms 30_000

  @weekday_fields [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
  @published_status "published"

  @accepted_keys [
    :approval_note,
    :delta_seconds,
    :first_date,
    :input_digest,
    :last_date,
    :schema_version,
    :source_label,
    :trip_ids
  ]

  # The complete field content of every loaded kind. Nothing here is a count,
  # an `updated_at` or a presentation value, so a same-count substitution
  # changes the digest (AC-4).
  @projections %{
    trips: [
      :id,
      :trip_id,
      :route_id,
      :service_id,
      :trip_headsign,
      :trip_short_name,
      :direction_id,
      :block_id,
      :shape_id,
      :route_pattern_id,
      :timed_pattern_id,
      :pattern_derivation_state
    ],
    calendars: [:id, :service_id] ++ @weekday_fields ++ [:start_date, :end_date],
    calendar_dates: [:id, :service_id, :date, :exception_type],
    stop_times: [
      :id,
      :trip_id,
      :stop_id,
      :stop_sequence,
      :arrival_time,
      :departure_time,
      :stop_headsign,
      :pickup_type,
      :drop_off_type,
      :timepoint
    ],
    frequencies: [:id, :trip_id, :start_time, :end_time, :headway_secs, :exact_times],
    routes: [
      :id,
      :route_id,
      :route_type,
      :route_short_name,
      :route_long_name,
      :agency_id,
      :active,
      :continuous_pickup,
      :continuous_drop_off
    ],
    route_patterns: [
      :id,
      :route_pattern_id,
      :route_id,
      :headsign,
      :direction_id,
      :representative_trip_id,
      :active,
      :alignment_digest
    ],
    route_pattern_stops: [:id, :route_pattern_id, :stop_id, :position, :shape_dist_traveled],
    timed_patterns: [:id, :route_pattern_id, :name, :headsign, :derivation_key],
    timed_pattern_stops: [
      :id,
      :timed_pattern_id,
      :route_pattern_stop_id,
      :arrival_offset,
      :departure_offset,
      :timepoint,
      :pickup_type,
      :drop_off_type,
      :stop_headsign
    ],
    block_attributes: [:id, :block_id, :service_id, :garage_id, :vehicle_type_id],
    blocking_settings: [
      :id,
      :min_layover_minutes,
      :max_block_minutes,
      :interlining,
      :default_garage_id,
      :deadhead_speed_kmh,
      :deadhead_circuity,
      :max_piece_minutes,
      :report_pull_out_minutes,
      :report_relief_minutes,
      :sign_off_minutes,
      :paid_break_max_minutes,
      :max_spread_minutes,
      :min_rest_minutes,
      :weekly_hours_warn_above
    ],
    route_operating_settings: [:id, :route_id, :garage_id, :required_vehicle_type_id],
    transfers: [
      :id,
      :from_stop_id,
      :to_stop_id,
      :from_route_id,
      :to_route_id,
      :from_trip_id,
      :to_trip_id,
      :transfer_type,
      :min_transfer_time
    ],
    trip_runs: [:id, :trip_id, :day_type_key, :run_id]
  }

  # Client fields the server owns. Their presence refuses the request; the
  # value is never read.
  @server_owned_fields ~w(
    route_id route_uuid organization_id org_id user_id actor_id
    gtfs_version_id version_id pack_id schema_version
    input_digest digest dependency_digest accepted
  )

  @draft_fields [:first_date, :last_date, :delta_seconds, :approval_note, :source_label]
  @draft_keys Enum.sort(@draft_fields ++ [:trip_ids])

  @typedoc """
  A validated but unaccepted intent.

  `trip_ids` is the sorted selection the draft was normalized from. Every value
  is already normalized: `Date` structs, an integer `delta_seconds`, trimmed
  text, and no server-owned field.
  """
  @type draft :: %{
          first_date: Date.t(),
          last_date: Date.t(),
          delta_seconds: integer(),
          approval_note: String.t(),
          source_label: String.t() | nil,
          trip_ids: [String.t()]
        }

  @typedoc """
  The accepted intent source later steps read.

  `input_digest` is a lowercase hex SHA-256 over the canonical, explicitly
  ordered encoding of every other key, so it changes if any of them changes.
  """
  @type accepted :: %{
          schema_version: pos_integer(),
          trip_ids: [String.t()],
          first_date: Date.t(),
          last_date: Date.t(),
          delta_seconds: integer(),
          approval_note: String.t(),
          source_label: String.t() | nil,
          input_digest: String.t()
        }

  @typedoc "Field-keyed validation messages a host renders on the submitted form."
  @type field_errors :: %{optional(atom()) => [String.t()]}

  @typedoc """
  The complete, coherent dependency read every later computation runs on.

  Every list holds the projected content of one loaded kind, sorted by content
  rather than by database order. `dependency_digest` binds that content, and
  `input_digest` carries the accepted source this read was requested for.
  """
  @type snapshot :: %{
          optional(atom()) => list(),
          scope: %{
            organization_id: Ecto.UUID.t(),
            gtfs_version_id: Ecto.UUID.t(),
            route_uuid: Ecto.UUID.t(),
            route_id: String.t()
          },
          input_digest: String.t(),
          selected_trip_ids: [Ecto.UUID.t()],
          dependency_digest: String.t()
        }

  @typedoc """
  Why no complete snapshot is available: a cap, the read deadline, calendar data
  the native date evaluator cannot read, or a source that is not an accepted
  intent.
  """
  @type incomplete :: {:incomplete, term()}

  @type error :: :forbidden | :not_found | incomplete()

  @doc """
  Normalizes submitted intent fields and the caller's own selection into a
  `draft`, or refuses with `field_errors`.

  `params` carries the submitted intent fields (`first_date`, `last_date`,
  `delta_seconds`, `approval_note`, `source_label`) under string or atom keys.
  `selected_trip_ids` is the caller's own current selection of 1 to 100
  distinct trip UUIDs, or a server map carrying them under `:trip_ids`.

  Refusal is field-scoped and additive: every invalid field is reported in one
  pass, and the host keeps its own form assigns, so a refusal never discards
  the draft the editor typed (AC-2).
  """
  @spec normalize_intent(map(), [String.t()] | term()) ::
          {:ok, draft()} | {:error, field_errors()}
  def normalize_intent(params, selected_trip_ids) when is_map(params) do
    with :ok <- reject_server_owned_fields(params) do
      errors =
        %{}
        |> put_errors(:first_date, date_error(params, :first_date))
        |> put_errors(:last_date, date_error(params, :last_date))
        |> put_delta_errors(params)
        |> put_errors(:approval_note, approval_note_error(params))
        |> put_errors(:source_label, source_label_error(params))
        |> put_selection_errors(selected_trip_ids)

      case errors do
        errors when map_size(errors) > 0 -> {:error, errors}
        _no_errors -> build_draft(params, selected_trip_ids)
      end
    end
  end

  def normalize_intent(_params, _selected_trip_ids),
    do: {:error, %{base: ["Submit the dated change intent form."]}}

  @doc """
  Accepts a normalized `draft` against the caller's current server selection.

  Returns the `accepted` source, `{:error, :invalid_draft}` when `draft` is not
  the exact normalized shape, and `{:error, :selection_changed}` when the
  current selection no longer matches the one the draft was normalized from.
  Selection and draft changes therefore cannot leave a stale acceptance behind
  (AC-2), and the digest is always recomputed here rather than trusted from the
  draft (AC-1).
  """
  @spec accept_intent(draft(), [String.t()] | map() | term()) ::
          {:ok, accepted()} | {:error, atom()}
  def accept_intent(draft, server_selection) when is_map(draft) do
    with :ok <- validate_draft(draft),
         {:ok, selection} <- normalize_selection(server_selection) do
      if selection == draft.trip_ids do
        {:ok, accept(draft)}
      else
        {:error, :selection_changed}
      end
    end
  end

  def accept_intent(_draft, _server_selection), do: {:error, :invalid_draft}

  @doc """
  Returns the lowercase hex SHA-256 `input_digest` binding an accepted source.

  The encoded value is an explicitly ordered JSON array of `[key, value]` pairs,
  so the digest depends on the values alone and never on map ordering.
  """
  @spec input_digest(map()) :: String.t()
  def input_digest(source) when is_map(source) do
    [
      ["schema_version", Map.fetch!(source, :schema_version)],
      ["trip_ids", Map.fetch!(source, :trip_ids)],
      ["first_date", source |> Map.fetch!(:first_date) |> encode_date()],
      ["last_date", source |> Map.fetch!(:last_date) |> encode_date()],
      ["delta_seconds", Map.fetch!(source, :delta_seconds)],
      ["approval_note", Map.fetch!(source, :approval_note)],
      ["source_label", Map.fetch!(source, :source_label)]
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- the coherent read -----------------------------------------------------

  @doc """
  Loads the complete dependency snapshot `accepted` plans against.

  `scope` is the server-created `GtfsPlanner.Agents.Scope{}`: the current actor,
  organization and version, plus the route identity of the page the plan runs
  from. `accepted` is the source `accept_intent/2` produced, and its own
  `input_digest` is re-derived here, so a caller cannot pass a source that was
  never accepted.

  Every read happens inside one bounded `REPEATABLE READ READ ONLY`
  transaction: the current editor is re-authorized there before any scoped
  entity read, and the route and version are resolved under the current
  organization. The transaction closes before the snapshot is returned, so no
  provider request is ever made while it is held.

  The read is deliberately conservative rather than scoped to the selection: it
  covers every trip of the version, so an unselected trip sharing a calendar,
  a block or a transfer stays visible to the plan instead of disappearing from
  it (AC-3).

  Failure is truthful and never partial:

    * `{:error, :forbidden}` - the current membership is not an active
      editor's, or the scope carries no usable organization/version identity.
    * `{:error, :not_found}` - the version is not the current organization's
      published one, the route identity is not this page's route, or a selected
      trip is not one of that route's trips.
    * `{:error, {:incomplete, reason}}` - a cap, the read deadline, calendar
      data the native date evaluator cannot read, or a source that is not an
      accepted intent. Later steps must treat this as unknown, not complete
      (AC-5, CR-3).
  """
  @spec load(Scope.t(), accepted() | map()) :: {:ok, snapshot()} | {:error, error()}
  def load(%Scope{} = scope, accepted) do
    with {:ok, source} <- accepted_source(accepted),
         {:ok, organization_id} <- uuid_field(scope, :organization_id),
         {:ok, version_id} <- uuid_field(scope, :gtfs_version_id),
         {:ok, route_uuid} <- route_identity(scope) do
      scoped = %{organization_id: organization_id, version_id: version_id}

      in_read_snapshot(fn -> read_snapshot(scope, scoped, route_uuid, source) end)
    end
  end

  def load(_scope, _accepted), do: {:error, :forbidden}

  defp read_snapshot(scope, scoped, route_uuid, source) do
    with :ok <- Scope.authorize(scope),
         {:ok, route} <- published_route(scoped, route_uuid),
         {:ok, selected_trip_ids} <- scoped_selection(scoped, route, source),
         {:ok, trips} <- version_trips(scoped),
         {:ok, calendars} <- scoped_rows(Calendar, scoped, :calendars),
         {:ok, calendar_dates} <- scoped_rows(CalendarDate, scoped, :calendar_dates),
         :ok <- validate_calendars(calendars, calendar_dates),
         {:ok, dependencies} <- dependencies(scoped, trips) do
      parts =
        [{:trips, trips}, {:calendars, calendars}, {:calendar_dates, calendar_dates}] ++
          dependencies

      {:ok, snapshot(scoped, route, source, selected_trip_ids, parts)}
    end
  end

  # The version's published gate is the native Schedules gate: a version still
  # importing has no Schedules page to plan against, so it is the same
  # `{:error, :not_found}` a foreign or deleted route produces.
  defp published_route(scoped, route_uuid) do
    query =
      from(route in Route,
        join: version in GtfsVersion,
        on:
          version.id == route.gtfs_version_id and version.organization_id == route.organization_id,
        where:
          route.id == ^route_uuid and route.organization_id == ^scoped.organization_id and
            route.gtfs_version_id == ^scoped.version_id and
            version.publication_status == ^@published_status
      )

    case Repo.one(query) do
      %Route{} = route -> {:ok, route}
      nil -> {:error, :not_found}
    end
  end

  # `Trip.id` is the selection namespace. Every selected trip has to be a trip
  # of the scoped route: a selection that names a foreign, another version's or
  # another route's trip is the same refusal, so no foreign trip is disclosed
  # and a partly foreign selection never loads the part it could.
  defp scoped_selection(scoped, route, source) do
    query =
      from(t in Trip,
        where:
          t.organization_id == ^scoped.organization_id and t.gtfs_version_id == ^scoped.version_id and
            t.route_id == ^route.route_id and t.id in ^source.trip_ids
      )

    case capped_rows(query, @max_selected_trips, :selected_trips) do
      {:ok, trips} ->
        selected = trips |> Enum.map(& &1.id) |> Enum.sort()

        if selected == Enum.sort(source.trip_ids), do: {:ok, selected}, else: {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp version_trips(scoped) do
    from(t in Trip,
      where:
        t.organization_id == ^scoped.organization_id and t.gtfs_version_id == ^scoped.version_id
    )
    |> capped_rows(@max_version_trips, :trips)
  end

  # Every dependency kind is read under its own tenant and version predicate and
  # its own cap. `in_rows/6` is the shared shape of a scoped read restricted to
  # referenced identities; the timed-pattern stops are joined to their
  # organization-owned parent because that table carries no tenant column.
  defp dependencies(scoped, trips) do
    imported_trip_ids = Enum.map(trips, & &1.trip_id)
    route_ids = trips |> Enum.map(& &1.route_id) |> Enum.uniq()
    pattern_ids = trips |> Enum.map(& &1.route_pattern_id) |> Enum.uniq() |> List.delete(nil)

    timed_pattern_ids =
      trips |> Enum.map(& &1.timed_pattern_id) |> Enum.uniq() |> List.delete(nil)

    block_ids = trips |> Enum.map(& &1.block_id) |> Enum.uniq() |> List.delete(nil)
    trip_uuids = Enum.map(trips, & &1.id)

    with {:ok, stop_times} <-
           in_rows(StopTime, scoped, :trip_id, imported_trip_ids, :stop_times, @max_stop_times),
         {:ok, frequencies} <-
           in_rows(
             Frequency,
             scoped,
             :trip_id,
             imported_trip_ids,
             :frequencies,
             @max_dependency_rows
           ),
         {:ok, routes} <-
           in_rows(Route, scoped, :route_id, route_ids, :routes, @max_dependency_rows),
         {:ok, route_patterns} <-
           in_rows(
             RoutePattern,
             scoped,
             :route_pattern_id,
             pattern_ids,
             :route_patterns,
             @max_dependency_rows
           ),
         {:ok, route_pattern_stops} <-
           in_rows(
             RoutePatternStop,
             scoped,
             :route_pattern_id,
             pattern_ids,
             :route_pattern_stops,
             @max_dependency_rows
           ),
         {:ok, timed_patterns} <-
           in_rows(
             TimedPattern,
             scoped,
             :id,
             timed_pattern_ids,
             :timed_patterns,
             @max_dependency_rows
           ),
         {:ok, timed_pattern_stops} <- timed_pattern_stops(scoped, timed_pattern_ids),
         {:ok, block_attributes} <-
           in_rows(
             BlockAttribute,
             scoped,
             :block_id,
             block_ids,
             :block_attributes,
             @max_dependency_rows
           ),
         {:ok, blocking_settings} <- scoped_rows(BlockingSetting, scoped, :blocking_settings),
         {:ok, route_operating_settings} <-
           in_rows(
             RouteOperatingSetting,
             scoped,
             :route_id,
             route_ids,
             :route_operating_settings,
             @max_dependency_rows
           ),
         # Every version transfer rule is a conservative dependency: an unrelated
         # one is disclosed as a review candidate rather than silently dropped.
         {:ok, transfers} <- scoped_rows(Transfer, scoped, :transfers),
         {:ok, trip_runs} <-
           in_rows(TripRun, scoped, :trip_id, trip_uuids, :trip_runs, @max_dependency_rows) do
      {:ok,
       [
         stop_times: stop_times,
         frequencies: frequencies,
         routes: routes,
         route_patterns: route_patterns,
         route_pattern_stops: route_pattern_stops,
         timed_patterns: timed_patterns,
         timed_pattern_stops: timed_pattern_stops,
         block_attributes: block_attributes,
         blocking_settings: blocking_settings,
         route_operating_settings: route_operating_settings,
         transfers: transfers,
         trip_runs: trip_runs
       ]}
    end
  end

  defp timed_pattern_stops(_scoped, []), do: {:ok, []}

  defp timed_pattern_stops(scoped, timed_pattern_ids) do
    from(pattern in TimedPattern,
      join: stop in TimedPatternStop,
      on: stop.timed_pattern_id == pattern.id,
      where:
        pattern.organization_id == ^scoped.organization_id and
          pattern.gtfs_version_id == ^scoped.version_id and
          stop.timed_pattern_id in ^timed_pattern_ids
    )
    |> capped_rows(@max_dependency_rows, :timed_pattern_stops)
  end

  defp scoped_rows(queryable, scoped, kind) do
    from(row in queryable,
      where:
        row.organization_id == ^scoped.organization_id and
          row.gtfs_version_id == ^scoped.version_id
    )
    |> capped_rows(@max_dependency_rows, kind)
  end

  defp in_rows(_queryable, _scoped, _field, [], _kind, _cap), do: {:ok, []}

  defp in_rows(queryable, scoped, field, values, kind, cap) do
    from(row in queryable,
      where:
        row.organization_id == ^scoped.organization_id and
          row.gtfs_version_id == ^scoped.version_id
    )
    |> where([row], field(row, ^field) in ^values)
    |> capped_rows(cap, kind)
  end

  # `cap + 1` rows are read so an over-cap read is recognized as such before any
  # of it is materialized into the snapshot (AC-5).
  defp capped_rows(query, cap, kind) do
    rows = Repo.all(limit(query, ^(cap + 1)))

    if length(rows) > cap,
      do: {:error, {:incomplete, {:row_cap_exceeded, kind, cap}}},
      else: {:ok, rows}
  end

  # The native date evaluator raises on a reversed weekly range, a weekday
  # column outside 0/1, a non-date exception or an unsupported exception type.
  # Reading it here keeps `partition/2` from having to invent a partial D.
  defp validate_calendars(calendars, calendar_dates) do
    unreadable =
      Enum.find(calendars, fn row -> not readable_calendar?(row) end) ||
        Enum.find(calendar_dates, &unreadable_exception?/1)

    case unreadable do
      nil -> :ok
      row -> {:error, {:incomplete, {:unreadable_calendar, row.service_id}}}
    end
  end

  defp readable_calendar?(calendar) do
    match?(%Date{}, calendar.start_date) and match?(%Date{}, calendar.end_date) and
      Date.compare(calendar.start_date, calendar.end_date) != :gt and
      Enum.all?(@weekday_fields, &(Map.get(calendar, &1) in [0, 1]))
  end

  defp unreadable_exception?(date) do
    not match?(%Date{}, date.date) or date.exception_type not in [1, 2]
  end

  # The transaction carries the production `REPEATABLE READ READ ONLY`
  # boundary, the statement deadline, and nothing else: it is closed before the
  # caller can build any request, and a rollback leaves no partial read usable.
  # The deadline is a statement timeout rather than a transaction timeout, so
  # what it reports is a read that could not finish inside its own limit.
  defp in_read_snapshot(read) do
    Repo.transaction(fn ->
      snapshot_module().begin_read()
      Repo.query!("SET LOCAL statement_timeout = #{read_timeout_ms()}")
      read.()
    end)
    |> case do
      {:ok, {:ok, snapshot}} -> {:ok, snapshot}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error -> {:error, {:incomplete, read_failure(error)}}
    _error in DBConnection.ConnectionError -> {:error, {:incomplete, :read_timeout}}
  end

  # A cancelled statement is the read deadline, and any other driver failure is
  # an unreadable source: both are incomplete, never a partial complete read.
  defp read_failure(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: :statement_timeout
  defp read_failure(%Postgrex.Error{}), do: :read_failed

  # The same selection the native service queries use: a SQL sandbox fixture
  # takes the no-op boundary, ordinary use takes the production one.
  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot, Snapshot.Repo)
  end

  defp read_timeout_ms do
    case Application.get_env(:gtfs_planner, @read_timeout_env, @read_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> @read_timeout_ms
    end
  end

  defp snapshot(scoped, route, source, selected_trip_ids, parts) do
    projected = Enum.map(parts, fn {kind, rows} -> {kind, project(rows, kind)} end)

    Map.merge(Map.new(projected), %{
      scope: %{
        organization_id: scoped.organization_id,
        gtfs_version_id: scoped.version_id,
        route_uuid: route.id,
        route_id: route.route_id
      },
      input_digest: source.input_digest,
      selected_trip_ids: selected_trip_ids,
      dependency_digest: dependency_digest(projected)
    })
  end

  defp project(rows, kind) do
    fields = Map.fetch!(@projections, kind)

    Enum.map(rows, fn row -> Map.new(fields, fn field -> {field, Map.fetch!(row, field)} end) end)
  end

  # Sorted complete content: rows are ordered by their own projected content, so
  # neither database order nor a re-inserted identity can change the digest
  # while a changed field, or a replaced row with the same count, does.
  defp dependency_digest(parts) do
    parts
    |> Enum.map(fn {kind, rows} ->
      [kind, rows |> Enum.map(&row_pairs/1) |> Enum.sort()]
    end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp row_pairs(row) do
    row
    |> Enum.map(fn {field, value} -> [Atom.to_string(field), encode_value(value)] end)
    |> Enum.sort()
  end

  defp encode_value(%Date{} = date), do: Date.to_iso8601(date)
  defp encode_value(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp encode_value(value), do: value

  # The accepted source is the only input `load/2` trusts, and it is trusted only
  # when it is exactly what `accept_intent/2` produces: the eight bound keys and
  # a digest this module recomputes rather than reads.
  defp accepted_source(accepted) when is_map(accepted) do
    if accepted |> Map.keys() |> Enum.sort() == @accepted_keys and
         readable_selection?(accepted.trip_ids) and
         accepted.input_digest == input_digest(accepted) do
      {:ok, accepted}
    else
      {:error, {:incomplete, :invalid_accepted_source}}
    end
  end

  defp accepted_source(_accepted), do: {:error, {:incomplete, :invalid_accepted_source}}

  # The over-cap selection is admitted here on purpose: the read's own `cap + 1`
  # admission is what reports it, so a caller cannot widen the plan by widening
  # the source. A repeated, empty or non-UUID entry is not a selection
  # `accept_intent/2` can produce, so it is refused as a source at all.
  defp readable_selection?([]), do: false

  defp readable_selection?(trip_ids) when is_list(trip_ids) do
    Enum.all?(trip_ids, &(is_binary(&1) and Ecto.UUID.cast(&1) == {:ok, &1})) and
      trip_ids == Enum.uniq(trip_ids)
  end

  defp readable_selection?(_trip_ids), do: false

  defp uuid_field(scope, field) do
    case Ecto.UUID.cast(Map.fetch!(scope, field)) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :forbidden}
    end
  end

  # A whole-version page names no route, so it has no dated change plan to load.
  defp route_identity(%Scope{resource_context: %{identity: {:route, route_uuid}}}) do
    case Ecto.UUID.cast(route_uuid) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp route_identity(%Scope{}), do: {:error, :not_found}

  # -- normalization ---------------------------------------------------------

  defp reject_server_owned_fields(params) do
    case params
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.filter(&(&1 in @server_owned_fields)) do
      [] -> :ok
      found -> {:error, %{base: [server_owned_message(found)]}}
    end
  end

  defp server_owned_message([field]),
    do: "#{field} is set by the server and cannot be submitted."

  defp server_owned_message(fields),
    do: "#{Enum.join(Enum.sort(fields), ", ")} are set by the server and cannot be submitted."

  defp date_error(params, field) do
    case fetch(params, field) do
      {:ok, %Date{} = date} ->
        {:ok, date}

      {:ok, value} when is_binary(value) ->
        parse_iso_date(value, field)

      _absent ->
        {:error, date_message(field)}
    end
  end

  defp parse_iso_date(value, field) do
    if Regex.match?(@iso_date_format, value) do
      value |> Date.from_iso8601() |> normalize_date_result(field)
    else
      {:error, date_message(field)}
    end
  end

  defp normalize_date_result({:ok, date}, _field), do: {:ok, date}

  defp normalize_date_result({:error, _reason}, field),
    do: {:error, "Enter #{date_label(field)} as a real calendar date."}

  defp date_message(field), do: "Enter #{date_label(field)} as YYYY-MM-DD with a four-digit year."

  defp date_label(:first_date), do: "the first date"
  defp date_label(:last_date), do: "the last date"

  defp delta_error(params) do
    case fetch(params, :delta_seconds) do
      {:ok, value} when is_integer(value) ->
        check_delta(value)

      {:ok, value} when is_binary(value) ->
        parse_delta(value)

      _absent ->
        {:error, delta_message()}
    end
  end

  defp parse_delta(value) do
    if Regex.match?(@signed_integer_format, String.trim(value)) do
      case Integer.parse(String.trim(value)) do
        {seconds, ""} -> check_delta(seconds)
        _unparsed -> {:error, delta_message()}
      end
    else
      {:error, delta_message()}
    end
  end

  defp check_delta(seconds) when seconds >= -@max_delta_seconds and seconds <= @max_delta_seconds,
    do: {:ok, seconds}

  defp check_delta(_seconds), do: {:error, delta_message()}

  defp delta_message,
    do:
      "Enter a whole-second shift between -#{@max_delta_seconds} and #{@max_delta_seconds}; use a minus sign for earlier."

  defp approval_note_error(params) do
    case fetch(params, :approval_note) do
      {:ok, value} when is_binary(value) ->
        note = String.trim(value)

        cond do
          note == "" -> {:error, "Enter the approval note you supplied for this change."}
          String.length(note) > @max_approval_note_length -> {:error, approval_note_message()}
          true -> {:ok, note}
        end

      _absent ->
        {:error, "Enter the approval note you supplied for this change."}
    end
  end

  defp approval_note_message,
    do: "Keep the approval note to #{@max_approval_note_length} characters or fewer."

  defp source_label_error(params) do
    case fetch(params, :source_label) do
      {:ok, value} when is_binary(value) ->
        source_label_value(value)

      {:ok, nil} ->
        {:ok, nil}

      _absent ->
        {:ok, nil}
    end
  end

  defp source_label_value(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      label -> check_source_label(label)
    end
  end

  defp check_source_label(label) do
    if String.length(label) > @max_source_label_length do
      {:error, source_label_message()}
    else
      {:ok, label}
    end
  end

  defp source_label_message,
    do: "Keep the source label to #{@max_source_label_length} characters or fewer."

  # Sorted and deduplicated comparisons: two callers that selected the same
  # trips in a different order produce the same draft and the same acceptance.
  # The current selection is a list of trip UUIDs, or a server map carrying them
  # under `:trip_ids`, so a host can pass the value it already holds.
  defp normalize_selection(%{trip_ids: ids}), do: normalize_selection(ids)

  defp normalize_selection(ids) when is_list(ids) do
    cond do
      not Enum.all?(ids, &is_binary/1) -> {:error, :invalid_selection}
      not Enum.all?(ids, &(Ecto.UUID.cast(&1) == {:ok, &1})) -> {:error, :invalid_selection}
      ids != Enum.uniq(ids) -> {:error, :invalid_selection}
      true -> {:ok, Enum.sort(ids)}
    end
  end

  defp normalize_selection(_selected_trip_ids), do: {:error, :invalid_selection}

  defp selection_error(selected_trip_ids) do
    case normalize_selection(selected_trip_ids) do
      {:ok, []} ->
        {:error, "Select at least one trip."}

      {:ok, ids} when length(ids) > @max_selected_trips ->
        {:error, "Select at most #{@max_selected_trips} trips."}

      {:ok, ids} ->
        {:ok, ids}

      {:error, :invalid_selection} ->
        {:error, "Select trips by their identifiers, without repeats."}
    end
  end

  defp put_errors(errors, field, result) do
    case result do
      {:ok, _value} -> errors
      {:error, message} -> Map.put(errors, field, [message])
    end
  end

  # Both dates are validated before they are compared, so a reversed interval
  # over otherwise valid dates is the only additional message it produces.
  defp put_delta_errors(errors, params) do
    errors = put_errors(errors, :delta_seconds, delta_error(params))

    with {:ok, first_date} <- date_error(params, :first_date),
         {:ok, last_date} <- date_error(params, :last_date),
         :lt <- Date.compare(last_date, first_date) do
      Map.put(errors, :last_date, ["The last date must not be before the first date."])
    else
      _valid_or_unreadable_dates -> errors
    end
  end

  defp put_selection_errors(errors, selected_trip_ids) do
    put_errors(errors, :selected_trip_ids, selection_error(selected_trip_ids))
  end

  defp build_draft(params, selected_trip_ids) do
    {:ok, first_date} = date_error(params, :first_date)
    {:ok, last_date} = date_error(params, :last_date)
    {:ok, delta_seconds} = delta_error(params)
    {:ok, approval_note} = approval_note_error(params)
    {:ok, source_label} = source_label_error(params)
    {:ok, trip_ids} = selection_error(selected_trip_ids)

    {:ok,
     %{
       first_date: first_date,
       last_date: last_date,
       delta_seconds: delta_seconds,
       approval_note: approval_note,
       source_label: source_label,
       trip_ids: trip_ids
     }}
  end

  defp fetch(params, field) do
    case Map.fetch(params, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(params, Atom.to_string(field))
    end
  end

  # -- acceptance ------------------------------------------------------------

  defp validate_draft(draft) do
    cond do
      draft |> Map.keys() |> Enum.sort() != @draft_keys -> {:error, :invalid_draft}
      Enum.any?(@draft_fields, &(not valid_draft_value?(draft, &1))) -> {:error, :invalid_draft}
      not valid_draft_selection?(draft.trip_ids) -> {:error, :invalid_draft}
      true -> :ok
    end
  end

  defp valid_draft_selection?(ids) do
    match?({:ok, _sorted}, normalize_selection(ids)) and ids == Enum.sort(ids)
  end

  defp valid_draft_value?(draft, :first_date), do: match?(%Date{}, draft.first_date)
  defp valid_draft_value?(draft, :last_date), do: match?(%Date{}, draft.last_date)

  defp valid_draft_value?(draft, :delta_seconds),
    do: is_integer(draft.delta_seconds) and abs(draft.delta_seconds) <= @max_delta_seconds

  defp valid_draft_value?(draft, :approval_note),
    do:
      is_binary(draft.approval_note) and draft.approval_note != "" and
        String.length(draft.approval_note) <= @max_approval_note_length

  defp valid_draft_value?(draft, :source_label) do
    case draft.source_label do
      nil -> true
      label -> is_binary(label) and String.length(label) <= @max_source_label_length
    end
  end

  defp accept(draft) do
    bound = %{
      schema_version: @schema_version,
      trip_ids: draft.trip_ids,
      first_date: draft.first_date,
      last_date: draft.last_date,
      delta_seconds: draft.delta_seconds,
      approval_note: draft.approval_note,
      source_label: draft.source_label
    }

    Map.put(bound, :input_digest, input_digest(bound))
  end

  defp encode_date(%Date{} = date), do: Date.to_iso8601(date)
  defp encode_date(value) when is_binary(value), do: value
end
