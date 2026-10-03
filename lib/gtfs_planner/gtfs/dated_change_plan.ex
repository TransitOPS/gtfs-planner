defmodule GtfsPlanner.Gtfs.DatedChangePlan do
  @moduledoc """
  Plan-only dated change planning: accepted intent first, computation later.

  This module is the date-bounded change planner (A36). It never writes a
  calendar, trip, time, block, transfer, run or audit row, and it exposes no
  apply, prepared command or execution token (INV-1, AC-10, AC-11). It owns
  intent normalization and acceptance, the one coherent read those are
  computed from, and the pure date and clock computation over that read; the
  remaining step is `prepare/2`.

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

  ## Original dates, not the requested window

  `partition/2` answers one question: on which of its *original* service dates
  does each selected service run? It uses the native
  `GtfsPlanner.Gtfs.Calendars.ServiceDates.active_dates/2`, so D is the whole
  effective schedule - a multi-year weekly range and additions outside it
  included - and never the requested window alone. T is D intersected with the
  inclusive accepted interval, N is D minus T, so `T` and `N` are disjoint and
  their union is exactly D.

  A date the original service does not run stays absent: a removed holiday is
  not in D, so it is in neither T nor N and no partition ever proposes it. An
  unselected trip that shares a calendar keeps D in full, which is why a
  partition names both its selected trips and the unaffected ones beside them.
  An empty T is a complete no-op analysis, not a saved change.

  The enumeration is admitted before it runs: the inclusive weekly span of
  every unique loaded calendar plus one cell per exception row is counted
  first, and a workload above `@max_date_work_cells` cells is
  `{:incomplete, reason}` rather than a partial complete answer (AC-5, AC-6,
  AC-7, CR-3).

  ## Exact service-day clocks

  `project_times/3` moves the accepted shift over the temporary dates, using
  the native `GtfsTime` integer seconds. A service day is not a 24-hour day
  and is never wrapped: `25:10:00` with `+300` is `25:15:00` on the same
  service day, never `01:15:00` of the next one, and a normal date keeps the
  clocks it already has (AC-8).

  Arrival and departure are read and moved separately, so a stop's dwell
  survives. A value GTFS leaves empty stays unknown, and the stop's other clock
  is never a stand-in for it: a blank arrival is unknown in both positions, not
  a departure fallback. A clock that cannot be read, or whose projected seconds
  fall below 0 or above the supported range, is refused the same way rather
  than wrapped.

  A frequency window is a template, not a listed occurrence, so its stored
  window is disclosed and no clock is projected for it. Every such case is an
  entry in `unresolved`, and `timing` is `:complete` only when that list is
  empty: a refused, unknown or excluded trip never reads as a complete
  exact-timing plan, and complete date computation stays a separate claim.

  ## Impact and execution prerequisites

  `prepare/2` is the one call a host makes. It performs `load/2` once and then
  runs `partition/2` and `project_times/3` as pure functions over that single
  read, so the report describes one database state rather than three reads that
  could straddle a commit (AC-3, AC-9).

  The report names who else the change touches. `dependency_rows` holds the
  scoped users of every touched calendar, every same-block trip, every version
  transfer rule with its `0..5` type and referential selectors, the block
  attributes and operating settings in force, the run assignments keyed by
  `Trip.id` UUID and `day_type_key`, and each selected trip's route, pattern
  and timing selectors with its stop incidence. The rows are the loaded rows,
  so `dependency_digest` fingerprints their exact content and every selector
  they carry.

  Transfer applicability is deliberately conservative: a rule's presence is a
  review candidate, never a certificate that a connection is feasible. Nothing
  here widens the accepted selection - a user of a touched calendar that the
  editor did not select is reported as a dependency, never as something this
  plan would change.

  `execution_stages` says what would have to exist before such a change could be
  executed, and every stage is `:foundation_missing` today: date partition and
  reassignment, temporary identity and date overlap, block and transfer lineage,
  and partial-save reconciliation with publication prevention. The reasons
  describe the current native `Copy`, `Shift` and `MoveCalendar` contracts from
  the code that implements them. None of them is an executable operation, a
  prepared command or a token, and nothing here tracks a manual editor action
  as completed execution (AC-10, CR-1, INV-1).
  """

  import Ecto.Query

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
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
  @max_delta_seconds 86_400
  @max_approval_note_length 2_000
  @max_source_label_length 200

  @iso_date_format ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
  @signed_integer_format ~r/\A[+-]?[0-9]+\z/

  # Truthful computation admission limits, not evaluated agency capacity: an
  # over-cap read is incomplete, never a partial complete snapshot. The trip
  # selection cap is the single owner of `@max_selected_trips`, so the intent
  # message and the loader's admission guard cannot disagree.
  @max_selected_trips 100
  @max_version_trips 10_000
  @max_stop_times 75_000
  @max_dependency_rows 20_000
  @max_date_work_cells 200_000

  # The number of native service dates one page of a partition lists. The host
  # streams exactly this many rows and reports the set's full total beside it.
  @page_size 50
  @partition_kinds [:original, :temporary, :normal]
  @partition_date_keys %{
    original: :original_dates,
    temporary: :temporary_dates,
    normal: :normal_dates
  }

  # The native `GtfsTime` supported range. A projection outside it is refused
  # rather than wrapped into a clock the service day never had.
  @max_gtfs_seconds 2_147_483_647

  @read_timeout_env :gtfs_dated_change_read_timeout_ms
  @read_timeout_ms 30_000

  @weekday_fields [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
  @published_status "published"

  # The exact row shape `partition/2` produces, in sorted order.
  @partition_keys [
    :normal_dates,
    :original_dates,
    :selected_trip_ids,
    :service_id,
    :temporary_dates,
    :unaffected_trip_ids
  ]

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

  @typedoc """
  One selected service's original service dates and the two partitions of them.

  `original_dates` is the complete effective D. `temporary_dates` is T, D inside
  the accepted inclusive interval, and `normal_dates` is N, D minus T.
  `unaffected_trip_ids` are the version's other trips of the same calendar: they
  keep all of D and are not part of the change.
  """
  @type partition :: %{
          service_id: String.t(),
          selected_trip_ids: [Ecto.UUID.t()],
          unaffected_trip_ids: [Ecto.UUID.t()],
          original_dates: [Date.t()],
          temporary_dates: [Date.t()],
          normal_dates: [Date.t()]
        }

  @typedoc "One partition per selected service, ordered by `service_id`."
  @type partitions :: [partition()]

  @typedoc """
  One stop's clocks before and after the shift, as native `GtfsTime` seconds.

  A value the stored row does not carry, cannot be read, or cannot be moved
  within the supported range is `:unknown` in both positions rather than an
  invented clock, and the projection's `unresolved` list says why.
  """
  @type clock_row :: %{
          trip_id: Ecto.UUID.t(),
          stop_sequence: integer(),
          before_arrival: non_neg_integer() | :unknown,
          before_departure: non_neg_integer() | :unknown,
          temporary_arrival: non_neg_integer() | :unknown,
          temporary_departure: non_neg_integer() | :unknown
        }

  @typedoc "One frequency window, disclosed as stored and never expanded."
  @type frequency_window :: %{
          trip_id: Ecto.UUID.t(),
          service_id: String.t(),
          start_time: String.t(),
          end_time: String.t(),
          headway_secs: integer(),
          exact_times: integer() | nil
        }

  @typedoc "Why one clock could not be projected exactly."
  @type unresolved_reason :: %{
          reason: atom(),
          service_id: String.t(),
          trip_id: Ecto.UUID.t(),
          stop_sequence: integer() | nil,
          clock: :arrival | :departure | nil
        }

  @typedoc """
  The proposed service-day clocks for the temporary dates, and what stays unknown.

  `projected_clocks` describes the temporary dates only; a normal date keeps the
  `before_*` clocks. `timing` is `:complete` only when `unresolved` is empty, so
  a plan that refused or could not read any exact timing can never present itself
  as a complete one (AC-8).
  """
  @type clock_projection :: %{
          schema_version: pos_integer(),
          input_digest: String.t(),
          dependency_digest: String.t(),
          partitions_digest: String.t(),
          delta_seconds: integer(),
          timing: :complete | :unresolved,
          projected_clocks: [clock_row()],
          frequency_windows: [frequency_window()],
          unresolved: [unresolved_reason()]
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
  One scoped dependency row, keeping the identity its selector refers to.

  `applicability: :conservative_review_candidate` is not decoration: a transfer
  rule that references a selected trip is disclosed so it can be reviewed, not
  so a connection can be assumed to exist.
  """
  @type dependency_row :: map()

  @typedoc """
  Everything the plan's impact consists of, as loaded rows.

  Every list holds the projected content of one dependency kind, so
  `dependency_digest` fingerprints it exactly. A calendar user the editor did
  not select appears here and is never in the accepted selection.
  """
  @type dependency_rows :: %{
          affected_services: [map()],
          trip_selectors: [map()],
          same_block_trips: [map()],
          transfers: [dependency_row()],
          block_attributes: [map()],
          blocking_settings: [map()],
          route_operating_settings: [map()],
          trip_runs: [map()],
          stop_incidence: [map()]
        }

  @typedoc """
  One prerequisite of executing a date-bounded change.

  `status` is `:analysis_complete` where the plan itself finished the analysis,
  `:native_review_needed` where an existing native review already covers it, and
  `:foundation_missing` where no writer in this application can do it. Every
  stage this planner reports is `:foundation_missing`: the analysis is complete
  and the execution foundation is absent (AC-10).
  """
  @type execution_stage :: %{
          kind: atom(),
          status: :analysis_complete | :native_review_needed | :foundation_missing,
          affected_ids: [String.t()],
          reasons: [String.t()]
        }

  @typedoc """
  The read-only plan a reviewer reads before deciding anything.

  `computation: :complete` describes the date partition and `timing` describes
  the projected clocks, so complete dates never imply complete timing. There is
  no command, callback, token or pending-operation list anywhere in it: an
  incomplete computation arrives as `{:error, {:incomplete, reason}}` instead of
  a report claiming completeness (AC-5, AC-10, CR-1, CR-3).
  """
  @type report :: %{
          schema_version: pos_integer(),
          scope: %{
            organization_id: Ecto.UUID.t(),
            gtfs_version_id: Ecto.UUID.t(),
            route_uuid: Ecto.UUID.t(),
            route_id: String.t()
          },
          input_digest: String.t(),
          dependency_digest: String.t(),
          computation: :complete | :incomplete,
          timing: :complete | :unresolved,
          totals: %{
            selected_trips: non_neg_integer(),
            affected_trip_dates: non_neg_integer(),
            unchanged_trip_dates: non_neg_integer(),
            unaffected_calendar_users: non_neg_integer()
          },
          partitions: partitions(),
          projected_clocks: [clock_row()],
          unaffected_users: [Ecto.UUID.t()],
          dependency_rows: dependency_rows(),
          execution_stages: [execution_stage()],
          unresolved: [unresolved_reason()]
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
           in_text_rows(
             RoutePattern,
             scoped,
             :route_pattern_id,
             pattern_ids,
             :route_patterns,
             @max_dependency_rows
           ),
         {:ok, route_pattern_stops} <-
           in_text_rows(
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
    # The select names the stop row: without it the read returns the joined
    # pattern, and every projected field below would be read off the wrong
    # struct.
    from(pattern in TimedPattern,
      join: stop in TimedPatternStop,
      on: stop.timed_pattern_id == pattern.id,
      where:
        pattern.organization_id == ^scoped.organization_id and
          pattern.gtfs_version_id == ^scoped.version_id and
          stop.timed_pattern_id in ^timed_pattern_ids,
      select: stop
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

  defp in_text_rows(_queryable, _scoped, _field, [], _kind, _cap), do: {:ok, []}

  # The pattern tables hold two id namespaces: the ids a feed imported, and the
  # `app-` ids the application mints for the patterns it derives itself. Both
  # are compared as text, because a column typed as a UUID would refuse the
  # application's own identifiers before the row could be read (AC-3).
  defp in_text_rows(queryable, scoped, field, values, kind, cap) do
    from(row in queryable,
      where:
        row.organization_id == ^scoped.organization_id and
          row.gtfs_version_id == ^scoped.version_id
    )
    |> where([row], type(field(row, ^field), :string) in ^values)
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

  # -- original date partitions ----------------------------------------------

  @doc """
  Splits each selected service's complete original service dates into the
  affected and unaffected partitions.

  `snapshot` is a `load/2` snapshot and `accepted` is the source it was read
  for; a source that is not the one this snapshot was loaded for is refused, so
  a partition can never describe a different selection or interval than the
  data behind it (INV-2).

  D comes from the native `Calendars.ServiceDates.active_dates/2` over the
  snapshot's own calendar and exception rows, so it is the whole effective
  schedule: an inclusive multi-year weekly range, additions inside and outside
  it, and removals subtracted from both. T is D inside the accepted inclusive
  interval, N is D minus T. `T` and `N` are disjoint and their union is exactly
  D, which is what keeps a date the original service never ran - a removed
  holiday - out of both, and what keeps an outside-range addition in N.

  A trip of the same calendar that the editor did not select keeps all of D and
  is reported beside the selected trips as an unaffected user, so a partition
  never reads as if the change covered the whole calendar (AC-7).

  An empty T is a complete no-op analysis: it describes a plan that would change
  nothing, and nothing is saved.

  Failure is `{:error, {:incomplete, reason}}`: the enumeration is refused
  before it runs when the inclusive weekly spans plus exception rows over the
  unique loaded calendars exceed `@max_date_work_cells`, when the source does
  not match the snapshot, when a selected trip is not among the loaded trips, or
  when calendar data the native evaluator cannot read is present. Exact-boundary
  equality is admitted (AC-5, CR-3).
  """
  @spec partition(snapshot() | map(), accepted() | map()) ::
          {:ok, partitions()} | {:error, incomplete()}
  def partition(snapshot, accepted) when is_map(snapshot) and is_map(accepted) do
    with {:ok, source} <- accepted_source(accepted),
         :ok <- matched_source(snapshot, source),
         {:ok, selected} <- selected_trips(snapshot),
         {:ok, services} <- loaded_calendars(snapshot),
         :ok <- within_work_cell_cap(services) do
      build_partitions(snapshot, services, selected, source)
    end
  end

  def partition(_snapshot, _accepted), do: {:error, {:incomplete, :invalid_snapshot}}

  # A partition describes the read its accepted source asked for. A source from
  # another selection or interval is refused instead of being partitioned
  # against this snapshot's rows.
  defp matched_source(snapshot, source) do
    cond do
      Map.get(snapshot, :input_digest) != source.input_digest ->
        {:error, {:incomplete, :snapshot_source_mismatch}}

      not interval?(source.first_date, source.last_date) ->
        {:error, {:incomplete, :invalid_accepted_source}}

      true ->
        :ok
    end
  end

  # An inclusive interval needs two real dates in order. A reversed or
  # unreadable pair would intersect nothing and look like a complete no-op.
  defp interval?(first_date, last_date) do
    match?(%Date{}, first_date) and match?(%Date{}, last_date) and
      Date.compare(first_date, last_date) != :gt
  end

  # The selection the snapshot was loaded for, as the snapshot's own trips. A
  # selected trip the read did not return has no calendar to partition, so it is
  # incomplete rather than silently absent from the plan, and a snapshot naming
  # no usable selection is never an empty-but-complete plan.
  defp selected_trips(snapshot) do
    trips = snapshot |> Map.get(:trips) |> Enum.filter(&is_map/1)
    selected = snapshot |> Map.get(:selected_trip_ids) |> readable_selection_ids()

    cond do
      selected == [] ->
        {:error, {:incomplete, :invalid_snapshot}}

      Enum.any?(selected, fn id -> not Enum.any?(trips, &(&1.id == id)) end) ->
        {:error, {:incomplete, {:unselected_trip, hd(selected)}}}

      true ->
        {:ok, Enum.filter(trips, &(&1.id in selected))}
    end
  end

  defp readable_selection_ids(nil), do: []

  defp readable_selection_ids(ids) when is_list(ids) do
    Enum.filter(ids, &(is_binary(&1) and Ecto.UUID.cast(&1) == {:ok, &1}))
  end

  defp readable_selection_ids(_selected_trip_ids), do: []

  # One entry per unique loaded calendar, holding the native shapes the date
  # evaluator consumes: a `Calendar` struct, or `nil` for exception-only
  # service, plus that service's exception rows.
  defp loaded_calendars(snapshot) do
    rows = snapshot |> Map.get(:calendars) |> Enum.filter(&is_map/1)
    exceptions = snapshot |> Map.get(:calendar_dates) |> Enum.filter(&is_map/1)

    service_ids =
      Enum.uniq(Enum.map(rows ++ exceptions, & &1.service_id)) |> Enum.sort()

    calendars = Map.new(rows, &{&1.service_id, calendar_row(&1)})

    {:ok,
     Map.new(service_ids, fn service_id ->
       {service_id,
        %{
          calendar: Map.get(calendars, service_id),
          exceptions: Enum.filter(exceptions, &(&1.service_id == service_id))
        }}
     end)}
  end

  defp calendar_row(row) do
    struct(Calendar, row)
  end

  # The work the enumeration would do, counted before it is done: every civil
  # day of each inclusive weekly range plus one cell per exception row. Equality
  # with the cap is admitted; only an over-cap workload is refused.
  defp within_work_cell_cap(services) do
    cells =
      Enum.reduce(services, 0, fn {_service_id, %{calendar: calendar, exceptions: exceptions}},
                                  total ->
        total + weekly_span(calendar) + length(exceptions)
      end)

    if cells > @max_date_work_cells do
      {:error, {:incomplete, {:date_work_cap_exceeded, cells, @max_date_work_cells}}}
    else
      :ok
    end
  end

  defp weekly_span(nil), do: 0
  defp weekly_span(calendar), do: Date.diff(calendar.end_date, calendar.start_date) + 1

  defp build_partitions(snapshot, services, selected, source) do
    trips = snapshot |> Map.get(:trips) |> Enum.filter(&is_map/1)

    selected
    |> Enum.map(& &1.service_id)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn service_id ->
      partition_for(service_id, services, selected, trips, source)
    end)
    |> Enum.reduce_while({:ok, []}, fn partition, {:ok, acc} ->
      case partition do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, partitions} -> {:ok, Enum.reverse(partitions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp partition_for(service_id, services, selected, trips, source) do
    service = Map.get(services, service_id, %{calendar: nil, exceptions: []})

    with {:ok, original} <- active_dates(service) do
      temporary = Enum.filter(original, &inside?(&1, source.first_date, source.last_date))

      {:ok,
       %{
         service_id: service_id,
         selected_trip_ids: trip_ids(selected, service_id),
         unaffected_trip_ids: trip_ids(trips, service_id) -- trip_ids(selected, service_id),
         original_dates: original,
         temporary_dates: temporary,
         normal_dates: original -- temporary
       }}
    end
  end

  # The native evaluator is the only source of D. `load/2` already refused the
  # calendar shapes it cannot read, so a raise here is a snapshot that was not
  # read through the loader; it is incomplete, never a partial partition.
  defp active_dates(%{calendar: calendar, exceptions: exceptions}) do
    # `Enum.sort_by/3` with `Date` rather than `Enum.sort/1`: a `%Date{}` is a
    # struct, and the default `<=` compares its fields, not its chronology.
    {:ok, calendar |> ServiceDates.active_dates(exceptions) |> Enum.sort_by(& &1, Date)}
  rescue
    ArgumentError -> {:error, {:incomplete, {:unreadable_calendar, calendar_label(calendar)}}}
  end

  defp inside?(date, first_date, last_date) do
    Date.compare(date, first_date) != :lt and Date.compare(date, last_date) != :gt
  end

  defp trip_ids(trips, service_id) do
    trips |> Enum.filter(&(&1.service_id == service_id)) |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp calendar_label(nil), do: nil
  defp calendar_label(calendar), do: calendar.service_id

  # -- exact service-day clocks ----------------------------------------------

  @doc """
  Projects the accepted shift onto the exact service-day clocks the temporary
  dates would run.

  `snapshot` is a `load/2` snapshot, `accepted` is the source it was read for and
  `partitions` is what `partition/2` returned for that same source, so the three
  inputs have to describe one plan: a source the snapshot was not read for, a
  partition that is not this snapshot's own output, a selected trip the snapshot
  did not load and a selected trip the partition files under another service are
  all `{:error, {:incomplete, reason}}` before any clock is projected (INV-2).

  Clocks are the native `GtfsTime` integer seconds of `0..2147483647`, moved by
  the accepted whole-second delta. A service day is not a 24-hour day and is never
  wrapped: `25:10:00` with `+300` is `25:15:00` on the same service day, and the
  date is never reduced modulo 86,400 into the next one (AC-8).

  Arrival and departure are read and moved separately, which is what keeps a
  stop's dwell: a stop arriving at `06:00:00` and leaving at `06:05:00` with
  `+300` arrives at `06:05:00` and leaves at `06:10:00`. A value GTFS leaves
  empty stays unknown; the other clock of the same stop is not a stand-in for
  it, so a blank arrival is `:unknown` in both positions and is reported as
  unresolved rather than as a departure fallback (AC-8).

  A clock that cannot be read, or whose projected seconds fall below 0 or above
  the supported range, is refused the same way: `:unknown` in both positions,
  never a wrapped or invented clock. A frequency-based trip is disclosed with
  its stored windows and no projected clock, because a headway window is a
  template rather than a listed service occurrence, and expanding it would invent
  occurrences the feed never listed. A listed trip with no stored stop times is
  reported for the same reason.

  Rows are projected for the temporary dates only. A partition with no temporary
  date proposes no clock, so it contributes no rows and keeps the clocks its
  normal dates already have; `projected_clocks` is empty for a plan that would
  change nothing.

  `timing` is `:complete` only when `unresolved` is empty, so exact timing is
  never claimed for a refused, unknown or excluded trip. Nothing here writes,
  relinks or persists a timing, and no separate native review read is taken
  (CR-1, INV-1).
  """
  @spec project_times(snapshot() | map(), accepted() | map(), partitions() | list()) ::
          {:ok, clock_projection()} | {:error, incomplete()}
  def project_times(snapshot, accepted, partitions)
      when is_map(snapshot) and is_map(accepted) do
    with {:ok, read} <- projection_input(snapshot),
         {:ok, source} <- accepted_source(accepted),
         :ok <- matched_source(snapshot, source),
         {:ok, bound} <- readable_partitions(read, partitions) do
      {:ok, build_projection(read, bound, source, partitions)}
    end
  end

  def project_times(snapshot, _accepted, _partitions) when is_map(snapshot),
    do: {:error, {:incomplete, :invalid_accepted_source}}

  def project_times(_snapshot, _accepted, _partitions),
    do: {:error, {:incomplete, :invalid_snapshot}}

  # Everything the projection reads, taken once from the snapshot: no second read
  # of the source, so the projection cannot mix two database states or two
  # snapshots. Empty stop times and empty frequencies are readable content, not a
  # missing read: they are what an unresolved trip looks like.
  defp projection_input(snapshot) do
    trips = snapshot |> Map.get(:trips) |> Enum.filter(&is_map/1)
    dependency_digest = Map.get(snapshot, :dependency_digest)

    with true <- trips != [],
         true <- is_binary(dependency_digest) do
      {:ok,
       %{
         dependency_digest: dependency_digest,
         by_id: Map.new(trips, &{&1.id, &1}),
         selected: readable_selection_ids(Map.get(snapshot, :selected_trip_ids)),
         stop_times: group_by_trip(snapshot, :stop_times),
         frequencies: group_by_trip(snapshot, :frequencies)
       }}
    else
      _unreadable -> {:error, {:incomplete, :invalid_snapshot}}
    end
  end

  # The snapshot's timing rows are keyed by the imported `Trip.trip_id`, which is
  # a different namespace from the `Trip.id` UUID a plan is written in; the
  # caller converts at the trip, never inside a row.
  defp group_by_trip(snapshot, kind) do
    snapshot |> Map.get(kind) |> Enum.filter(&is_map/1) |> Enum.group_by(& &1.trip_id)
  end

  # The partitions have to be this snapshot's own partition of this source's own
  # selection, so each is bound to a readable row shape and then to the trips it
  # claims. A hand-made list is refused rather than projected: a date the
  # original service does not run, or a trip outside the read, would describe a
  # different plan than the one the data behind it supports.
  defp readable_partitions(read, partitions) do
    with :ok <- well_formed_partitions(partitions),
         :ok <- bound_services(partitions, read) do
      {:ok,
       Enum.map(partitions, fn partition ->
         {partition, Enum.map(partition.selected_trip_ids, &read.by_id[&1])}
       end)}
    end
  end

  defp well_formed_partitions(partitions) when is_list(partitions) do
    cond do
      partitions == [] ->
        {:error, {:incomplete, :invalid_partitions}}

      Enum.any?(partitions, &(not partition_shape?(&1))) ->
        {:error, {:incomplete, :invalid_partitions}}

      service_ids(partitions) != Enum.uniq(service_ids(partitions)) ->
        {:error, {:incomplete, :duplicate_partition_service}}

      true ->
        :ok
    end
  end

  defp well_formed_partitions(_partitions), do: {:error, {:incomplete, :invalid_partitions}}

  # A partition names its own date lists, so T and N overlapping would project a
  # shift onto a date that is also claimed unchanged.
  defp partition_shape?(partition) when is_map(partition) do
    Map.keys(partition) |> Enum.sort() == @partition_keys and
      partition_identity?(partition) and
      partition_dates?(partition)
  end

  defp partition_shape?(_partition), do: false

  defp partition_identity?(partition) do
    is_binary(partition.service_id) and partition.service_id != "" and
      partition.selected_trip_ids != [] and
      readable_selection_ids(partition.selected_trip_ids) == partition.selected_trip_ids and
      readable_selection_ids(partition.unaffected_trip_ids) == partition.unaffected_trip_ids
  end

  defp partition_dates?(partition) do
    readable_dates(partition.original_dates) and
      readable_dates(partition.temporary_dates) and
      readable_dates(partition.normal_dates) and
      MapSet.disjoint?(
        MapSet.new(partition.temporary_dates),
        MapSet.new(partition.normal_dates)
      )
  end

  defp readable_dates(dates),
    do: is_list(dates) and Enum.all?(dates, &match?(%Date{}, &1))

  defp service_ids(partitions), do: Enum.map(partitions, & &1.service_id)

  defp bound_services(partitions, read) do
    Enum.reduce_while(partitions, :ok, fn partition, :ok ->
      case bound_trip_ids(partition, read) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp bound_trip_ids(partition, read) do
    Enum.reduce_while(partition.selected_trip_ids, :ok, fn trip_id, :ok ->
      case bound_trip(partition, trip_id, read) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A trip outside the read's own selection is a different plan: widening the
  # selected set here would project clocks the editor never accepted.
  defp bound_trip(partition, trip_id, read) do
    if trip_id in read.selected and Map.has_key?(read.by_id, trip_id) do
      bound_service(partition, Map.fetch!(read.by_id, trip_id))
    else
      {:error, {:incomplete, {:unselected_trip, trip_id}}}
    end
  end

  defp bound_service(partition, %{id: trip_id, service_id: service_id})
       when service_id != partition.service_id,
       do: {:error, {:incomplete, {:partition_service_mismatch, trip_id}}}

  defp bound_service(_partition, _trip), do: :ok

  defp build_projection(read, bound, source, described) do
    {clocks, windows, unresolved} =
      Enum.reduce(bound, {[], [], []}, fn
        # A partition with no temporary date proposes no clock at all, so it
        # contributes nothing: its normal dates keep the clocks they already have.
        {%{temporary_dates: []}, _trips}, projected ->
          projected

        {_partition, trips}, projected ->
          Enum.reduce(trips, projected, fn trip, {clocks, windows, unresolved} ->
            trip_projection = project_trip(trip, read, source.delta_seconds)

            {Enum.reverse(trip_projection.clocks) ++ clocks,
             Enum.reverse(trip_projection.windows) ++ windows,
             Enum.reverse(trip_projection.unresolved) ++ unresolved}
          end)
      end)

    %{
      schema_version: @schema_version,
      input_digest: source.input_digest,
      dependency_digest: read.dependency_digest,
      partitions_digest: dependency_digest([{:partitions, described}]),
      delta_seconds: source.delta_seconds,
      timing: if(unresolved == [], do: :complete, else: :unresolved),
      projected_clocks: Enum.reverse(clocks),
      frequency_windows: Enum.reverse(windows),
      unresolved: Enum.reverse(unresolved)
    }
  end

  # One selected trip's proposed clocks, or why it has none. A frequency window
  # is a template: the occurrences it would run are not listed in the feed, so
  # the plan discloses the stored window and projects no clock for it.
  defp project_trip(trip, read, delta) do
    windows = read.frequencies |> Map.get(trip.trip_id, []) |> ordered_windows()
    rows = read.stop_times |> Map.get(trip.trip_id, []) |> ordered_stop_times()

    cond do
      windows != [] ->
        %{
          clocks: [],
          windows: Enum.map(windows, &frequency_window(trip, &1)),
          unresolved: [unresolved_reason(trip, :frequency_not_exact, nil, nil)]
        }

      rows == [] ->
        %{
          clocks: [],
          windows: [],
          unresolved: [unresolved_reason(trip, :no_listed_stop_times, nil, nil)]
        }

      true ->
        {clocks, unresolved} = project_rows(trip, rows, delta)
        %{clocks: clocks, windows: [], unresolved: unresolved}
    end
  end

  defp ordered_stop_times(rows),
    do: Enum.sort_by(rows, &{&1.stop_sequence, &1.id})

  defp ordered_windows(rows), do: Enum.sort_by(rows, &{&1.start_time, &1.id})

  defp frequency_window(trip, row) do
    %{
      trip_id: trip.id,
      service_id: trip.service_id,
      start_time: row.start_time,
      end_time: row.end_time,
      headway_secs: row.headway_secs,
      exact_times: row.exact_times
    }
  end

  # Each stop's two clocks are read and moved separately, which is what keeps a
  # stop's dwell across the shift: the same whole-second delta applies to both
  # fields of a row, and a field that cannot be moved becomes unknown on its own
  # rather than taking the other field's value with it.
  defp project_rows(trip, rows, delta) do
    Enum.reduce(rows, {[], []}, fn row, {clocks, unresolved} ->
      {arrival, arrival_reason} = project_clock(row.arrival_time, delta)
      {departure, departure_reason} = project_clock(row.departure_time, delta)

      clock = %{
        trip_id: trip.id,
        stop_sequence: row.stop_sequence,
        before_arrival: original_clock(row.arrival_time),
        before_departure: original_clock(row.departure_time),
        temporary_arrival: arrival,
        temporary_departure: departure
      }

      {[clock | clocks],
       unresolved ++
         field_reason(trip, row, :arrival, arrival_reason) ++
         field_reason(trip, row, :departure, departure_reason)}
    end)
    |> then(fn {clocks, unresolved} -> {Enum.reverse(clocks), unresolved} end)
  end

  # A stored clock and the same clock moved by the shift. A blank value is
  # unknown in both positions: GTFS leaves it empty, and the stop's other clock
  # is not a stand-in for it. A projected second below zero or above the
  # supported range is refused rather than wrapped into a clock this service day
  # never had.
  defp project_clock(value, delta) do
    case read_clock(value) do
      {:unknown, reason} -> {:unknown, reason}
      {seconds, nil} -> move_clock(seconds, delta)
    end
  end

  defp read_clock(value) do
    if blank_clock?(value) do
      {:unknown, :unknown_clock}
    else
      case GtfsTime.parse(value) do
        {:ok, seconds} -> {seconds, nil}
        {:error, :invalid_time} -> {:unknown, :invalid_clock}
      end
    end
  end

  defp move_clock(seconds, delta) do
    case seconds + delta do
      projected when projected < 0 -> {:unknown, :negative_time}
      projected when projected > @max_gtfs_seconds -> {:unknown, :time_overflow}
      projected -> {projected, nil}
    end
  end

  # The stored clock, read the same way the moved one is, so a value the reader
  # cannot parse is unknown before the shift rather than only after it.
  defp original_clock(value) do
    case project_clock(value, 0) do
      {seconds, nil} -> seconds
      {:unknown, _reason} -> :unknown
    end
  end

  defp blank_clock?(nil), do: true
  defp blank_clock?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_clock?(_value), do: false

  defp field_reason(_trip, _row, _clock, nil), do: []

  defp field_reason(trip, row, clock, reason),
    do: [unresolved_reason(trip, reason, row.stop_sequence, clock)]

  defp unresolved_reason(trip, reason, stop_sequence, clock) do
    %{
      reason: reason,
      service_id: trip.service_id,
      trip_id: trip.id,
      stop_sequence: stop_sequence,
      clock: clock
    }
  end

  # -- impact and execution prerequisites ------------------------------------

  @doc """
  Composes the one coherent read, the pure partition and clock computation over
  it, and the impact report a reviewer reads before deciding anything.

  `scope` and `accepted` are the same inputs `load/2` takes, and the load
  happens exactly once: `partition/2` and `project_times/3` run as pure
  functions over that snapshot, so the report describes one database state and
  cannot mix two commits (AC-3, AC-9). Failure is `load/2`'s own -
  `{:error, :forbidden | :not_found | {:incomplete, reason}}` - so an incomplete
  read is never dressed up as a report with fewer rows (AC-5, CR-3).

  `dependency_rows` enumerates who else the change touches, without widening it:

    * `affected_services` - every touched calendar, its selected trips and the
      unselected trips of the same calendar that keep all of D. Those
      unaffected users are reported, never included in the change.
    * `trip_selectors` - each selected trip's route, route pattern, timed
      pattern and block identity, kept in the namespaces they were stored in.
    * `same_block_trips` - every version trip sharing a selected trip's block,
      with `successor_candidate` naming the ones whose own service runs on the
      affected dates. A successor candidate is a block peer, not a computed
      successor.
    * `transfers` - every version transfer rule, including the general type 4
      and type 5 rules that reference no trip, route or stop. Each row keeps its
      exact selectors, and `applicability: :conservative_review_candidate`
      records that presence is not connection feasibility.
    * `block_attributes`, `blocking_settings` and `route_operating_settings` -
      the planning attributes and operating settings a later execution would
      have to respect.
    * `trip_runs` - run assignments keyed by `Trip.id` UUID and `day_type_key`.
      The UUID namespace is never confused with the imported `Trip.trip_id` the
      transfer rules use.
    * `stop_incidence` - per stop, which selected trips stop there and how many
      times.

  `execution_stages` names what has to exist before any of this could be
  executed, and every stage is `:foundation_missing`: partition/reassignment,
  temporary identity/overlap, block/transfer lineage, and partial-save
  reconciliation with publication prevention. The reasons describe the current
  `Copy`, `Shift` and `MoveCalendar` contracts from the code that implements
  them.

  Nothing here is executable. There is no apply callback, prepared command,
  token or operation list in the report, and a manual edit made later in the
  native editor is never observed or recorded as completed execution
  (AC-10, CR-1, INV-1).
  """
  @spec prepare(Scope.t(), accepted() | map()) :: {:ok, report()} | {:error, error()}
  def prepare(%Scope{} = scope, accepted) do
    with {:ok, snapshot} <- load(scope, accepted),
         {:ok, partitions} <- partition(snapshot, accepted),
         {:ok, projection} <- project_times(snapshot, accepted, partitions) do
      {:ok, build_report(snapshot, partitions, projection)}
    end
  end

  def prepare(_scope, _accepted), do: {:error, :forbidden}

  @doc """
  One page of one partition's native service dates, for a host that lists them.

  A report holds every original date of every loaded calendar, which is more
  than any page should paint at once, so the host asks for one partition's one
  date set at a time. `partition_kind` is `:original`, `:temporary` or
  `:normal`; the rows are that partition's own dates, ascending.

  The result is `%{service_id:, partition_kind:, total:, page:, pages:, rows:}`,
  where `total` counts every date in the set and `pages` is at least one: an
  empty partition is page 1 of 1 with no rows rather than a missing selection.
  A service the report does not name, a kind that is not one of the three, or a
  page past the end is `{:error, :invalid_selection}`. Nothing here computes:
  the dates are the ones the one snapshot already admitted, so paging cannot
  describe a second database state (AC-3, CR-3).
  """
  @spec page(map(), term(), atom(), term()) :: {:ok, map()} | {:error, :invalid_selection}
  def page(report, service_id, partition_kind, page_number)
      when is_map(report) and is_atom(partition_kind) and is_integer(page_number) and
             page_number >= 1 do
    with true <- partition_kind in @partition_kinds,
         {:ok, partition} <- report_partition(report, service_id) do
      dates = partition |> Map.fetch!(Map.fetch!(@partition_date_keys, partition_kind))
      dates = Enum.sort_by(dates, & &1, Date)
      total = length(dates)
      pages = max(div(total + @page_size - 1, @page_size), 1)

      if page_number > pages do
        {:error, :invalid_selection}
      else
        {:ok,
         %{
           service_id: partition.service_id,
           partition_kind: partition_kind,
           total: total,
           page: page_number,
           pages: pages,
           rows: Enum.slice(dates, (page_number - 1) * @page_size, @page_size)
         }}
      end
    else
      _other -> {:error, :invalid_selection}
    end
  end

  def page(_report, _service_id, _partition_kind, _page_number),
    do: {:error, :invalid_selection}

  defp report_partition(report, service_id) do
    partitions = report |> Map.get(:partitions) |> List.wrap()

    case Enum.find(partitions, &(is_map(&1) and &1.service_id == service_id)) do
      nil -> {:error, :invalid_selection}
      partition -> {:ok, partition}
    end
  end

  defp build_report(snapshot, partitions, projection) do
    impact = impact_input(snapshot, partitions)
    rows = dependency_rows(impact, partitions)

    %{
      schema_version: @schema_version,
      scope: Map.get(snapshot, :scope),
      input_digest: Map.get(snapshot, :input_digest),
      dependency_digest: Map.get(snapshot, :dependency_digest),
      computation: :complete,
      timing: projection.timing,
      totals: totals(partitions, impact),
      partitions: partitions,
      projected_clocks: projection.projected_clocks,
      unaffected_users: unaffected_users(partitions),
      dependency_rows: rows,
      execution_stages: execution_stages(rows, impact),
      unresolved: projection.unresolved
    }
  end

  # Everything the dependency rows and the stages read, taken once from the
  # snapshot. The selected trips are the read's own selection, so a dependency
  # can never name a trip the editor did not accept.
  defp impact_input(snapshot, partitions) do
    trips = snapshot |> Map.get(:trips) |> Enum.filter(&is_map/1)
    selected_ids = readable_selection_ids(Map.get(snapshot, :selected_trip_ids))
    selected = Enum.filter(trips, &(&1.id in selected_ids))

    %{
      trips: trips,
      selected: selected,
      selected_imported: MapSet.new(selected, & &1.trip_id),
      blocks: MapSet.new(selected, & &1.block_id) |> MapSet.delete(nil),
      routes: selected |> Enum.map(& &1.route_id) |> Enum.uniq(),
      services: MapSet.new(partitions, & &1.service_id),
      temporary_services:
        MapSet.new(partitions, & &1.service_id)
        |> MapSet.filter(fn service_id ->
          Enum.any?(partitions, &(&1.service_id == service_id and &1.temporary_dates != []))
        end),
      snapshot: snapshot,
      selected_ids: selected_ids
    }
  end

  # Trip-date pairs, not unique dates: two trips of the same service on the same
  # affected date are two pairs, which is what a reader comparing the count of
  # changed trips against the count of changed dates needs to see.
  defp totals(partitions, impact) do
    %{
      selected_trips: length(impact.selected_ids),
      affected_trip_dates: trip_date_pairs(partitions, :temporary_dates),
      unchanged_trip_dates: trip_date_pairs(partitions, :normal_dates),
      unaffected_calendar_users: length(unaffected_users(partitions))
    }
  end

  defp trip_date_pairs(partitions, key) do
    Enum.reduce(partitions, 0, fn partition, total ->
      total + length(partition.selected_trip_ids) * length(Map.fetch!(partition, key))
    end)
  end

  defp unaffected_users(partitions) do
    partitions
    |> Enum.flat_map(& &1.unaffected_trip_ids)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dependency_rows(impact, partitions) do
    snapshot = impact.snapshot

    %{
      affected_services: affected_services(snapshot, partitions),
      trip_selectors: Enum.map(impact.selected, &trip_selectors/1),
      same_block_trips: same_block_trips(snapshot, impact),
      transfers: transfer_rows(snapshot, impact),
      block_attributes: loaded_rows(snapshot, :block_attributes, &block_row?(&1, impact)),
      blocking_settings: loaded_rows(snapshot, :blocking_settings),
      route_operating_settings:
        loaded_rows(snapshot, :route_operating_settings, &(&1.route_id in impact.routes)),
      trip_runs: trip_run_rows(snapshot, impact),
      stop_incidence: stop_incidence(snapshot, impact)
    }
  end

  defp loaded_rows(snapshot, kind), do: loaded_rows(snapshot, kind, fn _row -> true end)

  defp loaded_rows(snapshot, kind, predicate) do
    snapshot
    |> Map.get(kind)
    |> Enum.filter(&(is_map(&1) and predicate.(&1)))
    |> Enum.sort_by(&row_identity/1)
  end

  # Every loaded row keeps its own primary key in `id`, so sorting by it is the
  # one ordering that does not depend on a partial row's content.
  defp row_identity(row), do: Map.get(row, :id) || ""

  defp block_row?(row, impact), do: MapSet.member?(impact.blocks, row.block_id)

  defp affected_services(snapshot, partitions) do
    calendars = Map.new(loaded_rows(snapshot, :calendars), &{&1.service_id, &1.id})

    Enum.map(partitions, fn partition ->
      %{
        service_id: partition.service_id,
        calendar_id: Map.get(calendars, partition.service_id),
        selected_trip_ids: partition.selected_trip_ids,
        unaffected_trip_ids: partition.unaffected_trip_ids,
        temporary_date_count: length(partition.temporary_dates),
        normal_date_count: length(partition.normal_dates)
      }
    end)
  end

  defp trip_selectors(trip) do
    %{
      trip_id: trip.id,
      trip_ref: trip.trip_id,
      service_id: trip.service_id,
      route_id: trip.route_id,
      route_pattern_id: trip.route_pattern_id,
      timed_pattern_id: trip.timed_pattern_id,
      block_id: trip.block_id
    }
  end

  # Every trip sharing a selected trip's block, selected or not. A block peer
  # whose own service runs on an affected date is flagged as a successor
  # candidate; that is a block relationship the plan discloses, not a computed
  # succession the native blocker did not produce.
  defp same_block_trips(snapshot, impact) do
    selected_blocks = MapSet.new(impact.selected, & &1.id)

    snapshot
    |> Map.get(:trips)
    |> Enum.filter(&(is_map(&1) and MapSet.member?(impact.blocks, &1.block_id)))
    |> Enum.map(fn trip ->
      %{
        trip_id: trip.id,
        trip_ref: trip.trip_id,
        service_id: trip.service_id,
        block_id: trip.block_id,
        selected: MapSet.member?(selected_blocks, trip.id),
        successor_candidate: MapSet.member?(impact.temporary_services, trip.service_id)
      }
    end)
    |> Enum.sort_by(&{&1.block_id, &1.trip_ref})
  end

  # Every version transfer rule is a conservative dependency: a rule that
  # references no trip, route or stop - the general type 4 and type 5 rules -
  # can still bear on the change, so it is listed rather than dropped. The row
  # keeps its stored `from_*`/`to_*` selectors exactly, and the applicability
  # marker records that listing a rule is not a claim the connection works.
  defp transfer_rows(snapshot, impact) do
    selected = impact.selected_imported

    loaded_rows(snapshot, :transfers)
    |> Enum.map(fn row ->
      row
      |> Map.put(:applicability, :conservative_review_candidate)
      |> Map.put(:references_selected_trips, references(row, selected))
    end)
  end

  defp references(row, selected) do
    []
    |> maybe_reference(Map.get(row, :from_trip_id), selected, :from_trip)
    |> maybe_reference(Map.get(row, :to_trip_id), selected, :to_trip)
    |> Enum.sort()
  end

  defp maybe_reference(refs, nil, _selected, _side), do: refs

  defp maybe_reference(refs, trip_ref, selected, side) do
    if MapSet.member?(selected, trip_ref), do: [side | refs], else: refs
  end

  # Run assignments are keyed by the `Trip.id` UUID, so a row is selected here by
  # that UUID and never by the imported `Trip.trip_id`.
  defp trip_run_rows(snapshot, impact) do
    relevant =
      MapSet.new(impact.selected, & &1.id)
      |> MapSet.union(MapSet.new(same_block_trip_ids(snapshot, impact)))

    loaded_rows(snapshot, :trip_runs, &MapSet.member?(relevant, &1.trip_id))
  end

  defp same_block_trip_ids(snapshot, impact) do
    snapshot
    |> Map.get(:trips)
    |> Enum.filter(&(is_map(&1) and MapSet.member?(impact.blocks, &1.block_id)))
    |> Enum.map(& &1.id)
  end

  # Per stop, the selected trips that call there and how often. It is stop
  # incidence in the selected trips, not a connection or an in-seat analysis.
  defp stop_incidence(snapshot, impact) do
    snapshot
    |> Map.get(:stop_times)
    |> Enum.filter(&(is_map(&1) and MapSet.member?(impact.selected_imported, &1.trip_id)))
    |> Enum.group_by(& &1.stop_id)
    |> Enum.map(fn {stop_id, rows} ->
      %{
        stop_id: stop_id,
        occurrence_count: length(rows),
        trip_refs: rows |> Enum.map(& &1.trip_id) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.stop_id)
  end

  defp execution_stages(rows, impact) do
    selected = impact.selected_ids
    services = impact.services |> MapSet.to_list() |> Enum.sort()

    [
      stage(
        :partition_reassignment,
        services,
        [
          "The native Change calendar (MoveCalendar) moves whole selected trips to another service_id; it never splits one calendar's original dates into a temporary partition.",
          "Shift moves clocks and frequency windows on the trips it loads and creates and removes no calendar date, so no native writer establishes a temporary partition of a touched calendar.",
          "This plan computes that partition - the affected dates T and the unchanged dates N of every touched service - but writes nothing: no calendar, calendar_date, trip or stop-time writer is reachable from it."
        ]
      ),
      stage(
        :temporary_identity_overlap,
        selected,
        [
          "Copy allocates every new trip_id through TripChanges.allocate_trip_ids/5, so a copy carries no stored lineage back to the trip it came from and no date-bounded overlap with it.",
          "Copy's listed-duplicate check matches the target route_pattern_id and the first departure clock against listed trips of the target service. It carries no date lineage, so it cannot tell a temporary identity from the original on a date they share.",
          "Shift keeps the stored Trip.id and edits that trip in place, so it has no separate temporary identity and no overlap to reconcile against the original.",
          "Nothing in the application records that one trip is the temporary form of another on a bounded set of dates."
        ]
      ),
      stage(
        :block_transfer_lineage,
        impact.blocks |> MapSet.to_list() |> Enum.sort(),
        [
          "Copy's insert carries no block_id and its command writes no transfer row, so a copy starts unblocked with no in-seat records.",
          "Shift's updates carry no block_id, so a shift keeps the block it already had; no writer records a block's dates, or the transfer rules that would apply while a trip is temporarily shifted.",
          "#{length(rows.transfers)} version transfer rules are listed conservatively with their type and referential selectors. Presence is a review candidate, not a certificate that a connection is feasible.",
          "#{length(rows.block_attributes)} block attributes, #{length(rows.blocking_settings)} operating settings and #{length(rows.trip_runs)} run assignments are listed, and none of them survives a partition the application cannot yet establish."
        ]
      ),
      stage(
        :partial_save_reconciliation,
        selected,
        [
          "Copy, Shift and MoveCalendar each save their own reviewed command independently; nothing reconciles the state of a change that was only partly saved.",
          "No guard withholds publication of a version whose dated change is partly applied, so an interrupted plan could leave a version that reads as current and is not.",
          "This report exposes no apply command, callback or token, and it observes no manual editor action, so nothing here tracks execution as done."
        ]
      )
    ]
  end

  defp stage(kind, affected_ids, reasons) do
    %{
      kind: kind,
      status: :foundation_missing,
      affected_ids: Enum.uniq(affected_ids),
      reasons: reasons
    }
  end

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
