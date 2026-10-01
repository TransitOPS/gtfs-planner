defmodule GtfsPlanner.Gtfs.Blocking do
  @moduledoc """
  Scoped reads and writes for the Blocks page.

  Every function is scoped to one organization and GTFS version: organization,
  version and actor come from arguments, never from submitted parameters. The
  minimum layover is stored per published version, read as a default without
  writing a row, and validated before it reaches the table. A save takes the
  scoped version row `FOR SHARE` before its published check and its row write, so
  a calendar combination that owns the version cannot commit a fresh layover
  between its review and its apply.

  `load_day/3` loads one day type of a published version inside one transaction:
  it derives the day types from `Calendars.list_calendars/3`, selects the requested
  key, reads the day type's trips with their endpoints through `Blocking.Queries`
  and assembles blocks, the pool, findings, counts, the peak and the timeline axis.
  Every trip of the day type appears exactly once, in the block named by its
  `block_id` or in the pool (R2, AC-2).

  The day also carries every type 4/5 record naming one of its trips, evaluated by
  the shared `Blocking.InSeat` rule over every day type both of the record's trips
  run in, not only the selected one (R6, AC-7, INV-2).

  `block_problems_for_trips/3` is the advisory read behind the Schedules drawer's
  warning: the current errors and warnings that involve the given trips on any date
  they run, grouped by code, trip pair and block, with the day types and their
  summed date count. It takes no lock, so it can run after a Schedules commit
  without holding the day it just changed.

  `suggest_blocks/4` is the read-only suggestion: one transaction that resolves the
  day type, scopes its trips by mode, refuses a scope above `@max_plan_trips`, calls
  `Blocking.Generator.run/4` and hands the result to `Blocking.Plan.build/1`. It
  writes nothing and takes no blocking lock, so a suggestion is always a proposal
  the page can render and only `apply_block_plan/3` can write.

  `preview_day/2` draws the day one such plan would leave behind, as a day of
  exactly the shape `load_day/3` returns. It is pure — the plan's moves and
  attribute rows are applied to the loaded day and the day load's own per-block
  assembly is re-run over them, with no read and no write — so a page can show the
  suggestion on the page itself and the saved day is never mutated.

  `check_connections/3` and `lock_and_check_connections!/2` answer R1 for candidate trip
  pairs with the same `InSeat.state/2` the day load uses, so the drawer's pre-check, the
  review and the save cannot disagree (CR-2, INV-2). The read runs in a transaction; the
  locked variant runs inside the caller's, after the version `FOR SHARE` read and the
  blocking lock, and locks the named trips and their blocks' trips before re-reading them
  (INV-1). Both evaluate a stopless candidate row per pair, so the stops a write will
  store are not part of the decision.

  `project_calendar_combination/2` and `project_trip_changes/2` are the pure batch
  producers a calendar combination and a per-trip change review read. The first projects
  every proposed service-ID move and destination date change at once and decides which
  moved blocks must be cleared from that one projection; the second projects per-trip
  service and endpoint changes over the same private helpers, with every changed row
  applied at once and every clear decided from that one projection before any clear is
  applied. `CalendarChange`/`Schedules` keep their single-trip R9 answer, and no
  calendar-side module evaluates blocks a second time (CR-2).

  `apply_block_change/4` is the one write path for an `:assign`, `:unassign`,
  `:rename` or `:merge` command. It locks the version's blocking advisory lock and
  every trip row its decision depends on before it reviews, so the review the user
  confirmed and the write describe the same locked state, audits one `"trip"`
  change log per changed
  trip in the Schedules snapshot shape, and retries a serialization failure or
  deadlock as a whole. It writes `trips.block_id` and the change logs only: no
  transfer row is ever inserted, updated or deleted (INV-3).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.AuditContext

  alias GtfsPlanner.Gtfs.Blocking.{
    Checks,
    Context,
    DayTypes,
    DeadheadTimes,
    Distance,
    Fleet,
    Generator,
    InSeat,
    LowerBound,
    Movements,
    Plan,
    Queries,
    Relief,
    Review,
    Summary,
    TodsExport
  }

  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # The settings a version with no stored row reads. The map is the single
  # definition of the defaults: the reader merges stored columns over it and the form
  # changeset fills a partial map from it, so the database defaults, this map and the
  # drawn inputs cannot drift apart.
  @defaults %{
    min_layover_minutes: 5,
    max_block_minutes: nil,
    pull_out_buffer_minutes: 0,
    interlining: :any,
    default_garage_id: nil,
    deadhead_speed_kmh: 30,
    deadhead_circuity: 1.3,
    max_piece_minutes: nil
  }

  # Every settings column plus the write timestamp: an upsert that replaced only
  # some of them would leave a previous save's value behind on the same row.
  @replace_columns BlockingSetting.settings_fields() ++ [:updated_at]

  # The two value columns of one route's row plus the write timestamp: an upsert
  # that replaced only one of them would leave a previous save's other value
  # behind, so clearing a garage and setting a type never leaves the old garage.
  @replace_setting_columns [:garage_id, :required_vehicle_type_id, :updated_at]

  # The one value column of a driving-time pair plus the write timestamp. A save
  # replaces the minutes of the same ordered pair and never writes its reverse, so
  # an entered A→B value cannot be shadowed by a later B→A save.
  @replace_deadhead_columns [:minutes, :updated_at]

  # The one column the Operator changes drawer owns, plus the write timestamp. The
  # relief limit shares its row with the eight Block rules settings, and a save
  # here replaces only this one of them: writing the limit must not blank a stored
  # layover, interlining rule or default garage.
  @replace_piece_columns [:max_piece_minutes, :updated_at]

  # The two value columns of one block's row on one service, plus the write
  # timestamp. A save replaces both: clearing a garage and setting a type must
  # never leave the earlier value behind on the same row, and a repeated save of
  # the same values is the same row rather than a second one.
  @replace_attribute_columns [:garage_id, :vehicle_type_id, :updated_at]

  # The pair sources a Movements leg can carry. Every leg of the day is listed for
  # the Driving times drawer; only an estimated one is counted as "N estimated".
  @estimated_sources [:estimated]
  @driven_sources [:estimated, :entered, :unknown]

  @published_status "published"
  @seconds_per_hour 3600

  # The timeline chart and the Peak drawer bucket the day in 15-minute bins.
  @bin_secs 900

  # One command changes at most this many trips, the same bound the Schedules
  # series uses; the largest measured block holds 192 trips.
  # The single row bound a blocking write works in: `apply_block_change/4` refuses a
  # command naming more trips than this, and `apply_block_plan/3` batches its
  # `update_all` writes at the same size so one plan is never one unbounded statement.
  @max_command_trips 500

  # One suggestion reads at most this many trip rows. It is the measured target
  # the `blocking_scale` test checks a generated day type against, and it is the
  # largest scope `Generator.run/4` and `Plan.build/1` are meant to answer in the
  # time the page can wait for a preview. A scope above it is refused rather than
  # truncated, so a suggestion is never a partial answer.
  @max_plan_trips 3_000

  # The transaction boundary is retried as a whole three times, for a serialization
  # failure or a deadlock, before the command reports `:busy` (AC-14, INV-1).
  @write_attempts 3
  @retryable_codes [:serialization_failure, "40001", :deadlock_detected, "40P01"]

  @type block :: %{
          summary: Summary.block_summary(),
          trips: [Queries.trip_row()],
          gaps: [Checks.gap()],
          findings: [Checks.finding()],
          # Garage and type resolution, movements and relief stretches for this block,
          # derived once and attached so every consumer (the page, the export, the plan)
          # reads the same answer.
          resolution: Context.resolve_result(),
          movements: Movements.t(),
          # The instants an operator change may happen in this block, attached
          # beside the stretches measured from them, so a consumer that marks
          # where a change is possible reads the same windows the checks did.
          windows: [Relief.window()],
          stretches: [Relief.stretch()]
        }

  @type in_seat_entry :: %{row: Queries.in_seat_row(), state: InSeat.state()}

  # R8's listed row: the stored record's own fields with the one reason that no
  # block in the version reaches.
  @type unmatched_in_seat_record :: %{
          id: Ecto.UUID.t(),
          from_trip_id: String.t(),
          to_trip_id: String.t(),
          transfer_type: 4 | 5,
          from_stop_id: String.t() | nil,
          to_stop_id: String.t() | nil,
          updated_at: DateTime.t(),
          reason: InSeat.reason()
        }

  # The three stale reasons R8 lists. A `{:not_next, _}` record is stale on a day
  # type it is still reachable on, and an unconfirmed state is not a broken
  # record, so neither reason belongs to the version's listing.
  @unmatched_reasons [:trip_missing, :no_shared_date, :no_block]

  @typedoc """
  What `export_movements/2` hands the operations export: the day types in
  derivation order, each one's blocks in the shape `TodsExport.rows/1` reads
  them, and the garages by UUID so a pull's garage can be written by its public
  `garage_id`.
  """
  @type export_movements_result :: %{
          day_types: [DayTypes.day_type()],
          blocks_by_day_type: %{optional(String.t()) => [TodsExport.block()]},
          garages_by_id: %{optional(Ecto.UUID.t()) => Context.garage()},
          # The context each day type's blocks were built against. It is the
          # same value the day load would build for that day type, so a consumer
          # that derives anything else per day type - runs, relief windows - reads
          # the day load's own inputs rather than recomputing them.
          contexts_by_day_type: %{optional(String.t()) => Context.t()}
        }

  @typedoc "One candidate in-seat connection: the two natural trip IDs it would join."
  @type pair :: {from_trip_id :: String.t(), to_trip_id :: String.t()}

  @type problem :: %{
          code: Checks.code(),
          block_id: String.t() | nil,
          day_type_keys: [String.t()],
          date_count: non_neg_integer()
        }

  @typedoc """
  The plan figures of one day type.

  `vehicles` counts blocks, `minimum` is `Blocking.LowerBound`'s floor (a bound,
  never a target), and the four second totals and two kilometre totals are the sums
  of the blocks' movements. `riders` is the share of platform time the vehicle
  spent carrying riders, `round(service ÷ platform × 100)`, and `problems` is the
  day's finding count, so the plan summary and the preview compare like with like.
  """
  @type figures :: %{
          vehicles: non_neg_integer(),
          minimum: non_neg_integer(),
          platform_secs: non_neg_integer(),
          service_secs: non_neg_integer(),
          layover_secs: non_neg_integer(),
          drive_secs: non_neg_integer(),
          service_km: float(),
          deadhead_km: float(),
          riders: non_neg_integer(),
          problems: non_neg_integer()
        }

  @typedoc """
  The day's longest unrelieved stretch with the block it belongs to, or `nil`
  when no block has a stretch at all (a day type with no block, or none with a
  platform span).
  """
  @type longest_stretch ::
          nil
          | %{
              from_secs: integer(),
              to_secs: integer(),
              secs: non_neg_integer(),
              block_id: String.t()
            }

  @type day :: %{
          day_types: [DayTypes.day_type()],
          day_type: DayTypes.day_type() | nil,
          settings: settings(),
          context: Context.t(),
          routes: %{String.t() => Queries.route_info()},
          blocks: [block()],
          pool: [Queries.trip_row()],
          unplottable: [Queries.trip_row()],
          findings: [Checks.finding()],
          figures: figures(),
          fleet: [Fleet.row()],
          # The day's longest unrelieved stretch and the block it belongs to, so
          # the plan summary names one place rather than re-deriving the answer.
          longest_stretch: longest_stretch(),
          estimated_pairs: non_neg_integer(),
          # by each named trip in the day type
          in_seat: %{Ecto.UUID.t() => [in_seat_entry()]},
          counts: %{
            blocks: non_neg_integer(),
            trips: non_neg_integer(),
            unassigned: non_neg_integer(),
            problems: non_neg_integer(),
            notices: non_neg_integer()
          },
          peak: %{
            count: non_neg_integer(),
            at_secs: integer() | nil,
            excluded_unassigned: non_neg_integer(),
            excluded_frequency: non_neg_integer()
          },
          bins: [%{start_secs: integer(), count: non_neg_integer()}],
          axis: %{start_secs: integer(), end_secs: integer()} | nil,
          mixed_timezones?: boolean(),
          # The type 4/5 rows, the rows their block orders were read over and the
          # context they were evaluated in, kept so `preview_day/2` can re-run the relief
          # stretches over a plan without reading them again. Server-side state like
          # `context` itself: the page never reads it.
          in_seat_source: %{
            rows: [InSeat.in_seat_row()],
            block_rows: [Queries.trip_row()],
            context: InSeat.context()
          }
        }

  @type command ::
          {:assign, [Ecto.UUID.t()], String.t() | :new}
          | {:unassign, [Ecto.UUID.t()]}
          | {:rename, String.t(), String.t()}
          | {:merge, String.t(), String.t()}
          | {:attributes, String.t(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil}

  @type change :: %{trip: Queries.trip_row(), from: String.t() | nil, to: String.t() | nil}

  @type apply_result :: %{
          operation_id: Ecto.UUID.t() | nil,
          changed_trip_ids: [Ecto.UUID.t()],
          block_id: String.t() | nil,
          review: Review.review() | nil
        }

  @typedoc """
  The loaded review input set one calendar combination is projected over.

  `calendars` carries every selected calendar in the summary shape
  `Calendars.list_calendars/3` returns and `DayTypes` consumes, `trips` every trip of
  the review's closure with its real endpoints, `transfers` the type-4/5 records naming
  those trips and `settings` the version's stored minimum layover. `raw` and `today`
  belong to the review fingerprint and the upcoming/past split rather than to the block
  projection.
  """
  @type combination_inputs :: %{
          calendars: [DayTypes.calendar()],
          trips: [Queries.trip_row()],
          selected_trip_ids: [Ecto.UUID.t()],
          transfers: [Queries.in_seat_row()],
          settings: %{min_layover_minutes: 0..120},
          raw: map(),
          today: Date.t()
        }

  @typedoc "The resolved combination command the projection reads."
  @type combination_command :: %{
          destination_id: String.t(),
          source_ids: [String.t()],
          result_dates: [Date.t()]
        }

  @typedoc """
  The loaded input set one per-trip change projection reads.

  It is the block subset of the review state: `calendars` in the summary shape
  `Calendars.list_calendars/3` returns, `trips` every loaded trip of the review with its
  real endpoints, `transfers` the type-4/5 records naming those trips and `settings` the
  version's stored minimum layover. A per-trip change never changes a calendar, so both
  projections of `project_trip_changes/2` read the same calendars.
  """
  @type trip_change_inputs :: %{
          calendars: [DayTypes.calendar()],
          trips: [Queries.trip_row()],
          transfers: [Queries.in_seat_row()],
          settings: %{min_layover_minutes: 0..120}
        }

  @typedoc """
  One `Checks`/`InSeat` finding with the day-type and date context it was evaluated in.
  """
  @type combination_finding :: %{
          code: Checks.code(),
          severity: Checks.severity(),
          block_id: String.t() | nil,
          trip_ids: [Ecto.UUID.t()],
          transfer_id: Ecto.UUID.t() | nil,
          detail: map(),
          day_type_keys: [String.t()],
          dates: [Date.t()]
        }

  @type combination_projection :: %{
          cleared_trip_ids: [Ecto.UUID.t()],
          before_findings: [combination_finding()],
          after_findings: [combination_finding()],
          transfers: [%{id: Ecto.UUID.t(), before: InSeat.state(), after: InSeat.state()}]
        }

  @typedoc """
  The eight Block rules settings, with `nil` for an unset optional limit.
  """
  @type settings :: %{
          min_layover_minutes: 0..120,
          max_block_minutes: 60..1440 | nil,
          pull_out_buffer_minutes: 0..60,
          interlining: :any | :same_stop | :none,
          default_garage_id: Ecto.UUID.t() | nil,
          deadhead_speed_kmh: 5..120,
          deadhead_circuity: float(),
          max_piece_minutes: 60..720 | nil
        }

  @typedoc """
  One route of a version and its stored operating settings. `nil` is a route the
  planner has not set, which `Context.resolve_block/3` falls back from.
  """
  @type route_setting :: %{
          route_id: String.t(),
          garage_id: Ecto.UUID.t() | nil,
          required_vehicle_type_id: Ecto.UUID.t() | nil
        }

  @typedoc """
  One directional driving-time pair of a day.

  `from` and `to` are the stored reference strings — `"stop:<stop_id>"` or
  `"garage:<uuid>"` — so a planner can hand a row straight back to
  `put_deadhead_time/3` or `clear_deadhead_time/2`, and the labels beside them
  are the stop name and the garage name a human reads. `uses` counts the legs of
  the day that drove this exact direction, `minutes` is `nil` when the drive is
  unknown, and `source` says which of the three answers it is.
  """
  @type deadhead_pair :: %{
          from: String.t(),
          to: String.t(),
          from_label: String.t(),
          to_label: String.t(),
          uses: pos_integer(),
          minutes: non_neg_integer() | nil,
          source: :entered | :estimated | :unknown
        }

  @typedoc """
  One place an operator change may be made on a day type.

  `stop_id` is the candidate's own ID — the `parent_station` where a stop has one,
  the stop itself otherwise — so marking a station covers its bays and a mark is
  stored under exactly the key this list hands out. `name` is the station or stop
  name, `station?` says which, `child_names` names the day's stops under a
  station, `waits` counts the feasible gaps whose wait happens there, and
  `marked?` says whether the version stores a mark for this candidate.
  """
  @type relief_candidate :: %{
          stop_id: String.t(),
          name: String.t(),
          station?: boolean(),
          child_names: [String.t()],
          waits: non_neg_integer(),
          marked?: boolean()
        }

  @doc """
  Returns every Block rules setting for one organization's GTFS version.

  A version with no stored row returns the defaults and stores nothing. The stored
  columns are merged over `@defaults`, so a setting the migration predates keeps
  reading as its default until it is saved. `deadhead_circuity` is a float here
  rather than the stored `Decimal`, because every consumer is pure arithmetic.
  """
  @spec get_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: settings()
  def get_settings(organization_id, gtfs_version_id) do
    case Repo.one(settings_query(organization_id, gtfs_version_id)) do
      nil -> @defaults
      stored -> Map.merge(@defaults, stored)
    end
  end

  @doc """
  Returns the changeset rendered by the settings form.

  `settings` is a value map from `get_settings/2` — or any partial map, which is
  filled from the defaults — and `attrs` are the submitted parameters; an invalid
  value carries the field error.
  """
  @spec change_settings(map(), map()) :: Ecto.Changeset.t()
  def change_settings(settings, attrs) do
    # The defaults fill in what the caller did not supply, so the merge runs the
    # other way round: merging the defaults over the given settings would replace
    # every value the caller read with a default and the form could never show a
    # stored value.
    values = @defaults |> Map.merge(settings) |> Map.take(BlockingSetting.settings_fields())

    %BlockingSetting{}
    |> Ecto.Changeset.change(values)
    |> BlockingSetting.changeset(attrs)
  end

  @doc """
  Stores the eight Block rules settings for one organization's published version.

  The save runs in one transaction that locks the editor membership first, then the
  scoped version row `FOR SHARE` (`Versions.lock_for_input_write!/2`), so the settings a review loaded
  cannot change under a calendar combination that owns the version, and this save
  waits behind such an owner in turn. It then takes `lock_blocking!/1`, so a settings
  save serializes with every other block writer and cannot slip between a plan's
  review and its apply.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is outside its
  range, names an interlining value that does not exist, or names a
  `default_garage_id` that is not a garage of this organization. One row is kept per
  organization and version, so a repeated save replaces every settings column of the
  same row rather than merging into it.
  """
  @spec update_settings(AuditContext.t(), map()) ::
          {:ok, BlockingSetting.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def update_settings(%AuditContext{} = audit, attrs) do
    case Repo.transaction(fn -> write_settings!(audit, attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The editor membership lock is first; the version share lock follows, before the
  # published check and the upsert, whether the save updates a stored row or inserts the
  # version's first one (INV-1). Nothing in this writer takes the version row `FOR UPDATE`,
  # so no caller upgrades the share lock, and the transaction makes the check and the write
  # one unit while returning the upsert's own result tuple.
  #
  # `lock_blocking!/1` follows the version lock and nothing else, in the order every block
  # writer takes locks, so this writer joins the same serialization point as the block
  # writers. It is taken before the garage lookup, which is a read of another table, and
  # before the upsert's row lock.
  defp write_settings!(%AuditContext{} = audit, attrs) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = lock_blocking!(gtfs_version_id)

      changeset =
        %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
        |> BlockingSetting.changeset(attrs)

      case check_default_garage(organization_id, changeset) do
        {:ok, changeset} ->
          Repo.insert(changeset,
            on_conflict: {:replace, @replace_columns},
            conflict_target: [:organization_id, :gtfs_version_id],
            returning: true
          )

        {:error, changeset} ->
          # Nothing has been written yet, so the transaction can commit this result and
          # still leave the stored row exactly as the previous save left it.
          {:error, changeset}
      end
    else
      # The shared lock takes no publication stance, so the published requirement stays here,
      # exactly as `Calendars` and `RoutePatterns` apply theirs after the lock.
      {:error, :not_found}
    end
  end

  # A default garage is a planning input of one organization: a garage of another
  # organization is rejected as a field error rather than being stored and resolved
  # later. Only a submitted value is checked — an untouched stored garage is the
  # previous save's own already-validated choice.
  defp check_default_garage(organization_id, changeset) do
    case Ecto.Changeset.get_change(changeset, :default_garage_id) do
      nil ->
        {:ok, changeset}

      garage_id ->
        if Operations.get_garage(organization_id, garage_id) do
          {:ok, changeset}
        else
          {:error,
           Ecto.Changeset.add_error(
             changeset,
             :default_garage_id,
             "is not a garage of this organization"
           )}
        end
    end
  end

  @doc """
  Returns one entry per route of a version, with its stored home garage and
  required vehicle type.

  Every route of the organization and version appears exactly once, ordered by
  `route_short_name` and then `route_id` (the drawer lists the routes the
  planner recognizes, not the rows that happen to exist). A route with no
  stored row answers `nil` for both values, which is how `Context.resolve_block/3` tells
  "no home garage" from "no row".
  """
  @spec list_route_operating_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: [route_setting()]
  def list_route_operating_settings(organization_id, gtfs_version_id) do
    from(r in Route,
      left_join: s in RouteOperatingSetting,
      on:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.route_id == r.route_id,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      # PostgreSQL sorts a null short name last on an ascending sort, so a route
      # with no short name keeps the bottom of the list rather than the top.
      order_by: [asc: r.route_short_name, asc: r.route_id],
      select: %{
        route_id: r.route_id,
        garage_id: s.garage_id,
        required_vehicle_type_id: s.required_vehicle_type_id
      }
    )
    |> Repo.all()
  end

  @doc """
  Stores the home garage and required vehicle type of the given routes.

  Each entry is a map with `route_id`, `garage_id` and
  `required_vehicle_type_id`, submitted as strings or atoms; a blank garage or
  type is stored as `nil`. The batch is all-or-nothing: every entry is
  validated first, and one bad entry returns
  `{:error, {:invalid, [%{route_id: id, field: field, message: message}]}}`
  with nothing stored — a garage or type of another organization, and a route
  the version does not have, are both invalid.

  The save runs in one transaction that locks the editor membership first, then the
  scoped version row `FOR SHARE`, then `lock_blocking!/1`, so it serializes with
  every other block writer and cannot slip between a plan's review of the route
  settings and its apply. A staging version or another
  organization's version is `{:error, :not_found}` and stores nothing.
  """
  @spec update_route_operating_settings(AuditContext.t(), [map()]) ::
          :ok | {:error, :forbidden | :not_found | {:invalid, [map()]}}
  def update_route_operating_settings(%AuditContext{} = audit, entries) do
    entries = Enum.map(entries, &setting_entry/1)

    case Repo.transaction(fn ->
           write_route_settings!(audit, entries)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The editor membership lock is first; the version share lock follows, exactly as
  # `write_settings!/2` takes it, and `lock_blocking!/1` follows it and nothing else,
  # so this writer joins the same serialization point as every block writer.
  defp write_route_settings!(%AuditContext{} = audit, entries) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = lock_blocking!(gtfs_version_id)

      case invalid_entries(organization_id, gtfs_version_id, entries) do
        [] -> store_route_settings!(organization_id, gtfs_version_id, entries)
        invalid -> {:error, {:invalid, invalid}}
      end
    else
      {:error, :not_found}
    end
  end

  # One validated entry as the writer and the invalid list speak it: the route it
  # names and the two values to store, with a blank value already `nil` (the
  # drawer's cleared input is `""`, which the UUID cast would reject as invalid
  # rather than read as "unset").
  defp setting_entry(entry) do
    %{
      route_id: value(entry, :route_id),
      garage_id: value(entry, :garage_id),
      required_vehicle_type_id: value(entry, :required_vehicle_type_id)
    }
  end

  defp check_uuid!(changeset, field, value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> changeset
      :error -> Ecto.Changeset.add_error(changeset, field, "is invalid")
    end
  end

  defp value(entry, key) do
    case Map.get(entry, Atom.to_string(key), Map.get(entry, key)) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  # Every entry is checked before anything is written, so a rejected batch leaves
  # the previously stored rows exactly as the last accepted save left them. The
  # route check reads the version's own routes, so a route of another version or
  # another organization is rejected the same way an unknown one is.
  defp invalid_entries(organization_id, gtfs_version_id, entries) do
    known = version_route_ids(organization_id, gtfs_version_id, entries)

    Enum.flat_map(entries, fn entry ->
      Enum.flat_map(
        [
          route_error(entry, known),
          owner_error(organization_id, entry, :garage_id, &Operations.get_garage/2),
          owner_error(
            organization_id,
            entry,
            :required_vehicle_type_id,
            &Operations.get_vehicle_type/2
          )
        ],
        fn
          nil -> []
          error -> [error]
        end
      )
    end)
  end

  defp route_error(%{route_id: nil}, _known) do
    invalid(nil, :route_id, "is required")
  end

  defp route_error(%{route_id: route_id}, known) do
    if route_id in known do
      nil
    else
      invalid(route_id, :route_id, "is not a route of this version")
    end
  end

  # An untouched value is never checked: `nil` is either the previous save's own
  # already validated choice or a route the planner has not set, exactly as
  # `check_default_garage/2` reads the settings row. A value that is set must name
  # a garage or type of this organization, so another organization's is rejected
  # here rather than stored and resolved later.
  defp owner_error(organization_id, entry, field, get) do
    case Map.fetch!(entry, field) do
      nil ->
        nil

      id ->
        if get.(organization_id, id) do
          nil
        else
          invalid(Map.fetch!(entry, :route_id), field, "is not owned by this organization")
        end
    end
  end

  defp invalid(route_id, field, message) do
    %{route_id: route_id, field: field, message: message}
  end

  defp version_route_ids(_organization_id, _gtfs_version_id, []), do: MapSet.new()

  defp version_route_ids(organization_id, gtfs_version_id, entries) do
    route_ids = entries |> Enum.map(& &1.route_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.route_id in ^route_ids,
      select: r.route_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # One upsert per entry, replacing both value columns and the write timestamp so a
  # second save cannot leave a previous save's garage behind on the same row. The
  # unique index on `(organization_id, gtfs_version_id, route_id)` is the
  # conflict target, and every value was checked in this transaction first.
  defp store_route_settings!(_organization_id, _gtfs_version_id, []), do: :ok

  defp store_route_settings!(organization_id, gtfs_version_id, entries) do
    Enum.each(entries, fn entry ->
      %RouteOperatingSetting{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        route_id: entry.route_id
      }
      |> RouteOperatingSetting.changeset(entry)
      |> Repo.insert!(
        on_conflict: {:replace, @replace_setting_columns},
        conflict_target: [:organization_id, :gtfs_version_id, :route_id]
      )
    end)
  end

  @doc """
  Lists every directional driving-time pair the day type's blocks connect.

  The list is derived from the same day load the page holds, in the same
  transaction: every block's pull-out, pull-back and driving or unknown gap names
  one ordered `{from_ref, to_ref}` pair, and each distinct pair is listed once
  with the number of legs that drove it. Nothing here re-reads the movements or
  re-derives a drive, so a pair in this list is a leg the day really has.

  Each pair carries its `minutes` and `source` from `DeadheadTimes.lookup/5` over
  that day's own context — an entered value for exactly this direction first, the
  symmetric estimate otherwise, and `:unknown` with `nil` minutes when an end has
  no coordinates. Pairs are ordered by uses descending, then by the two labels
  and the two stored references, so the busiest directions are first and the
  order never depends on the order the blocks came back in.

  `from` and `to` are the stored reference strings, so the drawer can hand a row
  straight to `put_deadhead_time/3` or `clear_deadhead_time/2`. A `nil` key
  selects the first day type; an unknown key is
  `{:error, {:unknown_day_type, day_types}}` and selects none, and a
  foreign or unpublished version is `{:error, :not_found}`.
  """
  @spec list_deadhead_pairs(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, [deadhead_pair()]}
          | {:error, :not_found | {:unknown_day_type, [DayTypes.day_type()]}}
  def list_deadhead_pairs(organization_id, gtfs_version_id, day_type_key) do
    case Repo.transaction(fn ->
           day = read_day(organization_id, gtfs_version_id, day_type_key)
           {:ok, day_pairs(day)}
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stores an entered driving time for one direction of one pair.

  `{from_ref, to_ref}` is the ordered pair of stored reference strings the list
  hands out. Both refs are decoded first: a stop ref must name a stop of this
  version and a garage ref a garage of this organization, and anything else — an
  unknown stop, another organization's garage, a hand-edited reference — is
  `{:error, :invalid_ref}` with nothing stored. Garage references are the garage
  UUID and never its correctable `garage_id`.

  `minutes` is 0–600, checked by `DeadheadTime.changeset/2` and again by the
  named database constraint, so an out-of-range or non-numeric value is a
  changeset error rather than a raised constraint violation.

  The save runs in one transaction that locks the editor membership first, then the
  scoped version row `FOR SHARE`, then `lock_blocking!/1`, so it serializes with every
  other planning-input writer and cannot slip between a plan's review of the
  entered driving times and its apply. It replaces the minutes of
  exactly this ordered pair: the reverse direction keeps whatever it had, and
  writing A→B never writes B→A. A staging or foreign version is
  `{:error, :not_found}`.
  """
  @spec put_deadhead_time(
          AuditContext.t(),
          {String.t(), String.t()},
          non_neg_integer()
        ) ::
          {:ok, DeadheadTime.t()}
          | {:error, :forbidden | :not_found | :invalid_ref | Ecto.Changeset.t()}
  def put_deadhead_time(%AuditContext{} = audit, {from_ref, to_ref}, minutes) do
    case Repo.transaction(fn ->
           write_deadhead_time!(audit, {from_ref, to_ref}, minutes)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes the entered driving time of one direction, so the pair shows its
  estimate again.

  Only the named row is deleted: the reverse direction and every other pair of
  the version keep theirs. A pair with no stored row is `{:error, :not_found}` —
  there was nothing to reset — and a staging or foreign version is
  `{:error, :not_found}` as well.

  The delete takes the same locks as a save, the version row `FOR SHARE` and then
  `lock_blocking!/1`, so a reset cannot land between a plan's review and its apply.
  """
  @spec clear_deadhead_time(AuditContext.t(), {String.t(), String.t()}) ::
          :ok | {:error, :forbidden | :not_found}
  def clear_deadhead_time(%AuditContext{} = audit, {from_ref, to_ref}) do
    case Repo.transaction(fn ->
           clear_deadhead_time!(
             audit,
             canonical_pair({from_ref, to_ref})
           )
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # One pair entry per distinct ordered pair the day drove, with the number of
  # legs behind it. The counts come from the movements the day load built, so
  # `estimated_pairs/1` — the "N estimated" the scope bar counts — is a subset of
  # this list rather than a second walk of the day's legs.
  defp day_pairs(%{blocks: blocks, context: context}) do
    stops = day_stop_refs(blocks)

    blocks
    |> Enum.flat_map(&pair_refs/1)
    |> Enum.frequencies()
    |> Enum.map(fn {{from_ref, to_ref}, uses} -> pair(context, stops, from_ref, to_ref, uses) end)
    |> Enum.sort_by(&{-&1.uses, &1.from_label, &1.to_label, &1.from, &1.to})
  end

  # The day's own stop rows, keyed by stop ID, for a pair's labels and for the
  # points its estimate is measured between. A pair's stop is always an endpoint
  # of one of the day's trips, so this map covers every stop ref a leg can name.
  defp day_stop_refs(blocks) do
    for block <- blocks,
        trip <- block.trips,
        stop <- [trip.first_stop, trip.last_stop],
        stop != nil,
        into: %{},
        do: {stop.stop_id, stop}
  end

  defp pair(context, stops, from_ref, to_ref, uses) do
    %{minutes: minutes, source: source} =
      DeadheadTimes.lookup(
        from_ref,
        ref_point(from_ref, stops, context),
        to_ref,
        ref_point(to_ref, stops, context),
        context
      )

    %{
      from: DeadheadTimes.encode_ref(from_ref),
      to: DeadheadTimes.encode_ref(to_ref),
      from_label: ref_label(from_ref, stops, context),
      to_label: ref_label(to_ref, stops, context),
      uses: uses,
      minutes: minutes,
      source: source
    }
  end

  # A stop's point is the one its own rows give, falling back to the parent
  # station's, exactly as `Queries.stop_refs/3` built it for the movements. A
  # garage's is the context's own stored coordinate.
  defp ref_point({:stop, stop_id}, stops, _context) do
    case Map.get(stops, stop_id) do
      nil -> nil
      stop -> point(stop.lat, stop.lon)
    end
  end

  defp ref_point({:garage, garage_uuid}, _stops, context) do
    case Map.get(context.garages, garage_uuid) do
      nil -> nil
      garage -> point(garage.lat, garage.lon)
    end
  end

  # A coordinate pair needs both numbers; a stop or garage that carries one
  # without the other is as unmeasurable here as it is in `Blocking.Movements`.
  defp point(lat, lon) when is_number(lat) and is_number(lon), do: {lat * 1.0, lon * 1.0}
  defp point(_lat, _lon), do: nil

  # A garage is labelled by its name — a garage is a place, not a row ID — and a
  # stop by its GTFS stop name. A ref the day cannot name (a garage the context
  # does not carry, a stop with no name) falls back to the ID it is stored as,
  # so a row is never blank.
  defp ref_label({:stop, stop_id}, stops, _context) do
    case Map.get(stops, stop_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _no_name -> stop_id
    end
  end

  defp ref_label({:garage, garage_uuid}, _stops, context) do
    case Map.get(context.garages, garage_uuid) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{garage_id: garage_id} when is_binary(garage_id) and garage_id != "" -> garage_id
      _no_name -> garage_uuid
    end
  end

  # The editor membership lock is first; the version share lock follows and
  # `lock_blocking!/1` follows it and nothing else, in the order every block writer takes
  # locks, exactly as the settings and route-settings writers take them.
  defp write_deadhead_time!(%AuditContext{} = audit, {from_ref, to_ref}, minutes) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = lock_blocking!(gtfs_version_id)

      with {:ok, from_ref} <- decode_deadhead_ref(from_ref),
           {:ok, to_ref} <- decode_deadhead_ref(to_ref),
           :ok <- check_pair_refs(organization_id, gtfs_version_id, [from_ref, to_ref]) do
        %DeadheadTime{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          # `encode_ref/1` re-writes both in their canonical stored form, so an
          # uppercase UUID reaches the row downcased and the unique index is one
          # row per pair rather than two spellings of it.
          from_ref: DeadheadTimes.encode_ref(from_ref),
          to_ref: DeadheadTimes.encode_ref(to_ref)
        }
        |> DeadheadTime.changeset(%{minutes: minutes})
        |> Repo.insert(
          on_conflict: {:replace, @replace_deadhead_columns},
          conflict_target: [:organization_id, :gtfs_version_id, :from_ref, :to_ref],
          returning: true
        )
      end
    else
      {:error, :not_found}
    end
  end

  # Only the two decoded forms reach a row. `decode_ref/1` already refuses a
  # corrupt or hand-edited reference, so this only has to refuse a value that is
  # not a stored string at all.
  defp decode_deadhead_ref(ref) when is_binary(ref) do
    case DeadheadTimes.decode_ref(ref) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_ref}
    end
  end

  defp decode_deadhead_ref(_not_a_reference), do: {:error, :invalid_ref}

  # A stop ref must name a stop of this version and a garage ref a garage of this
  # organization, so a stored row can never point at a place this planner does not
  # run. Both refs are checked before the upsert, so a rejected pair stores
  # nothing. Garage ownership is the same organization-scoped read the default
  # garage and the route settings use.
  defp check_pair_refs(organization_id, gtfs_version_id, refs) do
    stop_ids = for {:stop, stop_id} <- refs, do: stop_id
    garage_ids = for {:garage, garage_uuid} <- refs, do: garage_uuid

    with :ok <- check_stops(organization_id, gtfs_version_id, stop_ids) do
      check_garages(organization_id, garage_ids)
    end
  end

  defp check_stops(_organization_id, _gtfs_version_id, []), do: :ok

  defp check_stops(organization_id, gtfs_version_id, stop_ids) do
    known = locked_stop_ids(organization_id, gtfs_version_id, stop_ids)

    if MapSet.equal?(known, MapSet.new(stop_ids)), do: :ok, else: {:error, :invalid_ref}
  end

  defp locked_stop_ids(organization_id, gtfs_version_id, stop_ids) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id in ^stop_ids,
      order_by: [asc: s.id],
      lock: "FOR SHARE",
      select: s.stop_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The endpoint stops must still exist at save time. A parent station may be only
  # a child's parent_station string; lock its row when present, but do not require it.
  defp lock_relief_stop_refs!(organization_id, gtfs_version_id, day) do
    stops = relief_stops(day)
    actual_ids = Map.keys(stops)
    candidate_ids = stops |> candidate_groups() |> Map.keys()
    known = locked_stop_ids(organization_id, gtfs_version_id, actual_ids ++ candidate_ids)

    unless MapSet.subset?(MapSet.new(actual_ids), known), do: Repo.rollback(:not_found)
  end

  defp check_garages(_organization_id, []), do: :ok

  defp check_garages(organization_id, garage_ids) do
    known =
      from(g in Garage,
        where: g.organization_id == ^organization_id and g.id in ^garage_ids,
        order_by: [asc: g.id],
        lock: "FOR SHARE",
        select: g.id
      )
      |> Repo.all()
      |> MapSet.new()

    if MapSet.equal?(known, MapSet.new(garage_ids)), do: :ok, else: {:error, :invalid_ref}
  end

  # The version share lock and the blocking lock are taken in the order every block writer
  # takes locks, and the delete is by the four-column key of the one ordered pair: the
  # reverse direction is a different row and is never touched.
  defp clear_deadhead_time!(%AuditContext{} = audit, {from_ref, to_ref}) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = lock_blocking!(gtfs_version_id)

      {deleted, _nothing} =
        Repo.delete_all(
          from(t in DeadheadTime,
            where:
              t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
                t.from_ref == ^from_ref and t.to_ref == ^to_ref
          )
        )

      if deleted == 1, do: :ok, else: {:error, :not_found}
    else
      {:error, :not_found}
    end
  end

  # The stored form of a pair, with every decodable ref rewritten by
  # `encode_ref/1`. A ref that decodes to nothing is kept as given: it cannot
  # match a valid row either way, and refusing to answer a clear because the
  # caller sent a corrupt string would hide a row rather than remove it.
  defp canonical_pair({from_ref, to_ref}), do: {canonical_ref(from_ref), canonical_ref(to_ref)}

  defp canonical_ref(ref) do
    case DeadheadTimes.decode_ref(ref) do
      {:ok, decoded} -> DeadheadTimes.encode_ref(decoded)
      :error -> ref
    end
  end

  @doc """
  Lists every place an operator change may be made on one day type of a version.

  The candidates are the day type's own trip endpoints: every trip's first and
  last stop, in the block it is in and in the pool alike, because a relief point
  is a place a vehicle may be handed over whether or not a block has been cut
  yet. A stop with a `parent_station` is grouped under that station, so the two
  bays of a Riverside Station are one candidate and one mark; a stop without one
  is its own candidate.

  `waits` counts the feasible gaps of the day's movements whose wait happens at
  that candidate, read off the movements the day load already built rather than a
  second pass over the trips. A layover's wait happens where the vehicle
  stands between the two trips — the arrival stop, which is the endpoint
  `Relief` names for a marked layover — and a drive's wait happens at both of its
  ends, which are the two windows `Relief` names for a drive. A gap with no positive wait
  is not a place a change can happen and is not counted, and neither is an infeasible gap
  or one whose drive the version cannot compute.

  Candidates are ordered by waits descending, then name, then ID: the places
  where relief is most available come first, and the order never depends on the
  order the trips arrived in.

  `marked?` is the version's own answer for the candidate's ID, so a candidate
  whose station is marked is marked and a child stop's own row — which is not a
  candidate, and which `update_relief_settings/3` therefore leaves alone — does
  not light this row up.

  A `nil` key selects the first day type; an unknown key is
  `{:error, {:unknown_day_type, day_types}}` and selects none, and a
  foreign or unpublished version is `{:error, :not_found}`.
  """
  @spec list_relief_candidates(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, [relief_candidate()]}
          | {:error, :not_found | {:unknown_day_type, [DayTypes.day_type()]}}
  def list_relief_candidates(organization_id, gtfs_version_id, day_type_key) do
    case Repo.transaction(fn ->
           day = read_day(organization_id, gtfs_version_id, day_type_key)
           {:ok, relief_candidates(organization_id, gtfs_version_id, day)}
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stores the relief limit and which of the day type's candidates are marked.

  `attrs` is a map with `max_piece_minutes` and `marked`; the limit is 60–720 or
  a blank, which stores `nil` and turns the `:no_relief_opportunity` checks off.
  The limit is validated through `BlockingSetting.changeset/2` and
  written to the one column this drawer owns, so saving it never disturbs the
  other seven settings of the same row. `marked` is the list of candidate IDs
  the drawer shows as ticked.

  The save is all-or-nothing and runs in one transaction that locks the editor
  membership first, then the scoped version row `FOR SHARE`, then `lock_blocking!/1`, so it
  serializes with every other block writer and cannot slip between a plan's review
  of the relief inputs and its apply. The candidates are
  recomputed inside that transaction, under the lock, from the same day load the
  list reads: only the day's own candidates are written. An ID in `marked` that is
  not a candidate of this day type is ignored, and a mark on a stop outside these
  candidates stays exactly as the last save left it. An unknown day type key
  answers `{:error, {:unknown_day_type, day_types}}` and stores nothing, because
  the day cannot be read to learn its candidates; a staging or foreign
  version is `{:error, :not_found}`.

  Returns `{:ok, :ok}` on success, matching the other writers' shape so a caller
  can pattern-match one tuple.
  """
  @spec update_relief_settings(
          AuditContext.t(),
          String.t() | nil,
          map()
        ) ::
          {:ok, :ok}
          | {:error,
             :forbidden
             | :not_found
             | {:unknown_day_type, [DayTypes.day_type()]}
             | Ecto.Changeset.t()}
  def update_relief_settings(%AuditContext{} = audit, day_type_key, attrs) do
    case Repo.transaction(fn ->
           write_relief_settings!(audit, day_type_key, attrs)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The editor membership lock is first; the version share lock follows and
  # `lock_blocking!/1` follows it and nothing else, in the order every block writer takes
  # locks, exactly as the settings and driving-time writers take them. The candidates are
  # read from the day load *after* the lock, so a mark cannot be saved against a candidate
  # list a concurrent plan has already made stale.
  defp write_relief_settings!(%AuditContext{} = audit, day_type_key, attrs) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = lock_blocking!(gtfs_version_id)

      # An unknown key rolls the transaction back here, before the first write, so
      # the stored limit and marks are exactly as the last accepted save left them.
      day = read_day(organization_id, gtfs_version_id, day_type_key)
      lock_relief_stop_refs!(organization_id, gtfs_version_id, day)

      with {:ok, _setting} <- store_piece_limit!(organization_id, gtfs_version_id, attrs) do
        save_relief_marks!(organization_id, gtfs_version_id, day, marked_ids(attrs))
      end
    else
      {:error, :not_found}
    end
  end

  # The limit is cast and range-checked by the settings changeset itself, so the
  # range lives in one place. The stored row is the base rather than a bare
  # struct, so the seven columns this drawer does not own are present and satisfy
  # the changeset's required fields; the upsert then replaces only the limit
  # column and the write timestamp, so writing the limit cannot blank a stored
  # layover, interlining rule or default garage.
  defp store_piece_limit!(organization_id, gtfs_version_id, attrs) do
    stored = get_settings(organization_id, gtfs_version_id)

    %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
    |> Ecto.Changeset.change(Map.take(stored, BlockingSetting.settings_fields()))
    |> BlockingSetting.changeset(%{max_piece_minutes: value(attrs, :max_piece_minutes)})
    |> Repo.insert(
      on_conflict: {:replace, @replace_piece_columns},
      conflict_target: [:organization_id, :gtfs_version_id]
    )
  end

  # The ticked candidate IDs of a submitted form, as the set the two writes below
  # compare against. A non-list (a hand-rolled or absent parameter) is no ticks at
  # all rather than a raise, which is the same reading `update_settings/2` gives a
  # missing optional field.
  defp marked_ids(attrs) do
    case Map.get(attrs, :marked, Map.get(attrs, "marked")) do
      marked when is_list(marked) -> marked |> Enum.filter(&is_binary/1) |> MapSet.new()
      _no_list -> MapSet.new()
    end
  end

  # The mark write is a delete followed by an insert rather than a diff against the
  # stored rows, because the candidate set is derived rather than stored: a row
  # that stopped being a candidate has to go, and a row that became one has to
  # arrive, and neither is visible as a change to the marks themselves. The delete
  # is scoped to the candidate IDs, so a mark on a stop outside them is never
  # touched.
  defp save_relief_marks!(organization_id, gtfs_version_id, day, marked) do
    candidates = candidate_groups(relief_stops(day)) |> Map.keys()

    Repo.delete_all(
      from(r in ReliefPoint,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
            r.stop_id in ^candidates and r.stop_id not in ^MapSet.to_list(marked)
      )
    )

    for stop_id <- candidates,
        MapSet.member?(marked, stop_id),
        do: insert_relief_point!(organization_id, gtfs_version_id, stop_id)

    {:ok, :ok}
  end

  # `organization_id`, `gtfs_version_id` and `stop_id` are set on the struct, never
  # cast, and the row is inserted with the unique index as a do-nothing conflict
  # target: a candidate that was already ticked and stayed ticked survives the
  # delete above, so a repeated save of the same marks is a no-op rather than a
  # constraint violation.
  defp insert_relief_point!(organization_id, gtfs_version_id, stop_id) do
    %ReliefPoint{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      stop_id: stop_id
    }
    |> ReliefPoint.changeset(%{})
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:organization_id, :gtfs_version_id, :stop_id]
    )
  end

  # One candidate per place, from the day's own endpoints. `waits` comes from the
  # movements, `marked?` from the version's stored marks, and the name of a
  # station is the station row's own name, read for every station of the list in
  # one query.
  defp relief_candidates(organization_id, gtfs_version_id, day) do
    groups = candidate_groups(relief_stops(day))
    stations = station_names(organization_id, gtfs_version_id, groups)
    waits = candidate_waits(day)
    marked = day.context.relief_stop_ids

    groups
    |> Enum.map(fn {stop_id, stops} ->
      %{
        stop_id: stop_id,
        name: candidate_name(stop_id, stops, stations),
        station?: station?(stop_id, stops),
        child_names: child_names(stop_id, stops),
        waits: Map.get(waits, stop_id, 0),
        marked?: MapSet.member?(marked, stop_id)
      }
    end)
    |> Enum.sort_by(&{-&1.waits, &1.name, &1.stop_id})
  end

  # Every first and last stop of every trip of the day type, blocked and pooled
  # alike, deduplicated by stop ID: a stop two trips both end at is one candidate
  # with two waits, not two candidates.
  defp relief_stops(%{blocks: blocks, pool: pool}) do
    for trip <- Enum.flat_map(blocks, & &1.trips) ++ pool,
        stop <- [trip.first_stop, trip.last_stop],
        stop != nil,
        into: %{},
        do: {stop.stop_id, stop}
  end

  # A stop with a parent station belongs to that station, so the two bays of one
  # station are one candidate and one mark; a stop without one is its own. The
  # station row itself is not required to exist in `stops` for the grouping to
  # hold — the child names the station, and the name falls back below.
  defp candidate_groups(stops) do
    Enum.group_by(Map.values(stops), &candidate_stop_id/1)
  end

  defp candidate_stop_id(%{parent_station: parent_station})
       when is_binary(parent_station) and parent_station != "" do
    parent_station
  end

  defp candidate_stop_id(%{stop_id: stop_id}), do: stop_id

  # A candidate is a station when any of the day's stops under it is a child, which
  # is the same test `candidate_stop_id/1` grouped it by.
  defp station?(stop_id, stops) do
    Enum.any?(stops, &(&1.stop_id != stop_id))
  end

  # The station's own name where the version describes the station, so a station
  # reads as "Riverside Station" rather than as a child bay. A station the version
  # does not describe, and a stop with no name, fall back to the ID the mark is
  # stored under, so a row is never blank (the same rule `ref_label/3` uses for a
  # pair's ends).
  defp candidate_name(stop_id, stops, stations) do
    case Map.get(stations, stop_id) do
      name when is_binary(name) and name != "" ->
        name

      _no_station_row ->
        case Enum.find_value(stops, & &1.name) do
          name when is_binary(name) and name != "" -> name
          _no_name -> stop_id
        end
    end
  end

  # The names of the day's stops under a station, in name order, so the drawer can
  # say which bays the mark covers. A plain stop has no children and names none.
  defp child_names(stop_id, stops) do
    stops
    |> Enum.reject(&(&1.stop_id == stop_id))
    |> Enum.map(& &1.name)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # One query for every station name the list shows. A station the version does not
  # describe is simply absent, and `candidate_name/3` falls back.
  defp station_names(_organization_id, _gtfs_version_id, groups) when map_size(groups) == 0,
    do: %{}

  defp station_names(organization_id, gtfs_version_id, groups) do
    station_ids =
      groups
      |> Enum.filter(fn {stop_id, stops} -> station?(stop_id, stops) end)
      |> Enum.map(fn {stop_id, _stops} -> stop_id end)

    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id in ^station_ids,
      select: {s.stop_id, s.stop_name}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The feasible gaps of the day's movements, counted at the candidate each gap's
  # wait happens at. A layover's wait is one wait where the vehicle stands, which
  # is the arrival stop `Relief` names for a marked layover; a drive's wait is
  # two windows, one at each end. An infeasible gap, an unknown drive and a
  # gap with no positive wait are all places no change can be planned into, so
  # they count for nobody.
  defp candidate_waits(%{blocks: blocks}) do
    counted =
      for block <- blocks,
          trips = Map.new(block.trips, &{&1.id, &1}),
          gap <- block.movements.gaps,
          gap.feasible? == true,
          is_integer(gap.wait_secs),
          gap.wait_secs > 0,
          stop <- wait_stops(gap, trips),
          do: candidate_stop_id(stop)

    Enum.frequencies(counted)
  end

  defp wait_stops(gap, trips) do
    from_trip = Map.get(trips, gap.from_id)
    to_trip = Map.get(trips, gap.to_id)

    cond do
      is_nil(from_trip) ->
        []

      gap.kind == :layover ->
        List.wrap(from_trip.last_stop)

      gap.kind == :drive ->
        Enum.filter([from_trip.last_stop, to_trip && to_trip.first_stop], &(&1 != nil))

      true ->
        []
    end
  end

  defp settings_query(organization_id, gtfs_version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{
        min_layover_minutes: s.min_layover_minutes,
        max_block_minutes: s.max_block_minutes,
        pull_out_buffer_minutes: s.pull_out_buffer_minutes,
        interlining: s.interlining,
        default_garage_id: s.default_garage_id,
        deadhead_speed_kmh: s.deadhead_speed_kmh,
        deadhead_circuity: type(s.deadhead_circuity, :float),
        max_piece_minutes: s.max_piece_minutes
      }
    )
  end

  @doc """
  Returns every day type a version's calendars currently derive, in derivation order.

  Day types are recomputed from `Calendars.list_calendars/3` on every read and never
  stored (INV-6), so a caller that needs to ask "is this key still a day type, and
  does it run on that weekday" answers it from this list rather than from a stored
  key it would have to trust. `Rosters.update_roster_settings/2` is the caller: a
  stored base-week choice is only accepted while its day type is current and has a
  date on that weekday.

  The calendars are read through `load_calendars!/2`, so this belongs inside the
  caller's transaction and rolls that transaction back on `{:error, :not_found}` —
  an unpublished or foreign version is refused rather than answered with an empty
  list, which would read as "this version has no day type" rather than as a
  refused scope.
  """
  @spec list_day_types(Ecto.UUID.t(), Ecto.UUID.t()) :: [DayTypes.day_type()]
  def list_day_types(organization_id, gtfs_version_id) do
    organization_id
    |> load_calendars!(gtfs_version_id)
    |> DayTypes.derive()
  end

  @doc """
  Loads one day type of a published version as blocks, the pool and the day's checks.

  A `nil` key selects the first day type in `DayTypes.derive/1` order. An unknown
  key returns `{:error, {:unknown_day_type, day_types}}` and selects none: nothing
  falls back to another day type (INV-6). A version whose calendars derive no day
  type returns an empty day with `day_type: nil`. A foreign or unpublished version
  is `{:error, :not_found}` through `Calendars.list_calendars/3`, which also takes
  the published version row `FOR SHARE` for the whole read.

  Every trip of the selected day type is returned exactly once: in the block named
  by its `block_id` or in the pool. A trip without usable endpoint times is also
  listed in `unplottable` and counted (AC-2, AC-6). The query count does not grow
  with the trip count (AC-3).

  The day also carries the version's `context`: its settings, garages, vehicle
  types, route settings, block attributes, entered driving times, marked relief
  stops, fleet summary and per-trip distances, gathered by `build_context!/4` in
  a fixed number of reads. Every block is resolved against it and
  carries its `resolution`, `movements` and relief `stretches`; the
  day's `figures`, `fleet`, `longest_stretch` and `estimated_pairs` are the sums
  and rows over those, and `peak` and `bins` are counted
  over platform spans rather than trip spans. The context itself is server-side
  state: the page never reads it, it derives render assigns from the loaded day.
  """
  @spec load_day(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, day()} | {:error, :not_found | {:unknown_day_type, [DayTypes.day_type()]}}
  def load_day(organization_id, gtfs_version_id, day_type_key) do
    case Repo.transaction(fn -> read_day(organization_id, gtfs_version_id, day_type_key) end) do
      {:ok, day} -> {:ok, day}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads every day type's blocks and their derived movements for the operations export.

  This is the export's read of the same thing the day load assembles, and it
  returns it in the shape `Blocking.TodsExport.rows/1` takes: the day types in
  derivation order, each one's blocked trips grouped into blocks carrying their
  own movements, and the garages by UUID so a pull's garage can be written by its
  correctable `garage_id`. Blocks are resolved through the same
  `Context.resolve_block/3` every other consumer uses, so the export's garage is
  the day load's garage, and the movements are rebuilt from
  `Movements.build/3` on every call — nothing here is stored.

  Every day type is read, not one, because a consumer hangs a movement on a
  service of its own day type: a block running on two day types contributes its
  movements to both. A block appears once per day type under that day type's key
  and a trip with no `block_id` is a pool trip with no movement, so it is left
  out rather than given an empty block.

  The function opens no transaction. It runs inside the caller's — the export's
  one read snapshot, which has already established its isolation before the
  first query, and a nested `Repo.transaction/1` would only take a savepoint.
  The queries are therefore the ordinary ones the day load makes, against the
  caller's connection.

  Nothing but the movements is derived here: the checks, in-seat findings, fleet
  rows, peak and bins a day load computes are not read, because a consumer of a
  deadhead file has no use for them and re-deriving them would cost a read per
  day type.

  `contexts_by_day_type` is the other half of that. The context each day type's
  blocks were built against is returned rather than recomputed, so a consumer
  that needs it for anything else — `Runs.derive_version/3` builds relief windows
  from it — reads the value this read already had. Rebuilding it would not only
  cost another read per day type; the two values would agree only by accident.
  """
  @spec export_movements(Ecto.UUID.t(), Ecto.UUID.t()) :: export_movements_result()
  def export_movements(organization_id, gtfs_version_id) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    settings = get_settings(organization_id, gtfs_version_id)

    {blocks_by_day_type, garages_by_id, contexts_by_day_type} =
      Enum.reduce(day_types, {%{}, %{}, %{}}, fn day_type, {blocks, garages, contexts} ->
        trips = day_trips(organization_id, gtfs_version_id, day_type)
        context = build_context!(organization_id, gtfs_version_id, settings, trips)

        # The garages are organization-level, so the first day type's context
        # answers for every one of them; a version with no day type has no block
        # and therefore names no garage, so the empty map is the honest answer
        # there and not a missing read.
        {
          Map.put(blocks, day_type.key, movement_blocks(trips, context)),
          if(garages == %{}, do: context.garages, else: garages),
          Map.put(contexts, day_type.key, context)
        }
      end)

    %{
      day_types: day_types,
      blocks_by_day_type: blocks_by_day_type,
      garages_by_id: garages_by_id,
      contexts_by_day_type: contexts_by_day_type
    }
  end

  # One day type's blocked trips, grouped into the blocks `TodsExport.rows/1`
  # takes: the block's own ID, its trips in the order the vehicle runs them (a
  # drive gap names its endpoints through them) and the movements derived for it.
  # A pool trip has no block and therefore no movement, so it contributes
  # nothing. The blocks keep the day's own natural order, as they do on the page.
  defp movement_blocks(trips, context) do
    trips
    |> Enum.reject(&is_nil(&1.block_id))
    |> Enum.group_by(& &1.block_id)
    |> Enum.map(fn {block_id, block_trips} ->
      %{
        block_id: block_id,
        trips: order_block_trips(block_trips),
        movements:
          Movements.build(
            Checks.sequence(block_trips),
            Context.resolve_block(context, block_id, block_trips),
            context
          )
      }
    end)
    |> Enum.sort_by(&Summary.natural_key(&1.block_id))
  end

  @doc """
  Returns the day types one natural trip ID runs in.

  The trip must belong to this organization and version; anything else is
  `{:error, :not_found}`. The day types come from the same derivation the day load
  uses and keep its list order, so the answer names every date the trip runs.
  """
  @spec trip_day_types(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, %{trip_id: String.t(), day_types: [DayTypes.day_type()]}} | {:error, :not_found}
  def trip_day_types(organization_id, gtfs_version_id, trip_id) do
    case Repo.transaction(fn ->
           calendars = load_calendars!(organization_id, gtfs_version_id)
           service_id = trip_service_id!(organization_id, gtfs_version_id, trip_id)

           %{
             trip_id: trip_id,
             day_types: DayTypes.containing(DayTypes.derive(calendars), service_id)
           }
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the key of the first day type in list order containing `service_id`.

  The day types come from `Calendars.list_calendars/3` through `DayTypes.derive/1`,
  so the key is the one a day load resolves and a Blocks deep link may select; it is
  derived, never stored, and nothing falls back to another day type (INV-6). A
  service no day type contains — a calendar with no active date — is `:none`, and a
  foreign or unpublished version is `{:error, :not_found}`.
  """
  @spec first_day_type_key(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, String.t() | :none} | {:error, :not_found}
  def first_day_type_key(organization_id, gtfs_version_id, service_id) do
    case Repo.transaction(fn ->
           organization_id
           |> load_calendars!(gtfs_version_id)
           |> DayTypes.derive()
           |> DayTypes.containing(service_id)
           |> first_day_type_key!()
         end) do
      {:ok, key} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the current errors and warnings involving the given trips, grouped.

  This is the advisory read a Schedules save asks for: for each trip that names a
  block, and each day type its service runs in, the block's trips on that day type
  are checked with `Checks.block_findings/3`, and the type 4/5 records naming any of
  the given trips are evaluated once with `InSeat.state/2` through the same context
  the day load uses (INV-2, CR-2). Only `:error` and `:warning` findings that name a
  requested trip are kept, so a problem between two other trips is not reported.

  Findings are grouped by code, sorted trip IDs and block ID; each group carries the
  day types it applies to in day-type list order and their summed `date_count`, so
  "on <n> days" counts each date once however many day types a service spans. Errors
  come before warnings.

  The read is advisory: it takes no lock, so it never blocks a writer and never
  decides whether a write may proceed. A foreign or unpublished version is
  `{:error, :not_found}`.
  """
  @spec block_problems_for_trips(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
          {:ok, [problem()]} | {:error, :not_found}
  def block_problems_for_trips(organization_id, gtfs_version_id, trip_ids) do
    case Repo.transaction(fn ->
           read_block_problems(organization_id, gtfs_version_id, trip_ids)
         end) do
      {:ok, problems} -> {:ok, problems}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Suggests blocks for one day type and returns the plan a reviewer reads.

  A read-only transaction: it takes the version row `FOR SHARE` through
  `Calendars.list_calendars/3`, derives the day types through `DayTypes.derive/1`
  and resolves the key, so an unknown key answers
  `{:error, {:unknown_day_type, day_types}}` and nothing falls back to another day
  type. A foreign or unpublished version is `{:error, :not_found}`. No lock
  is taken and no row is written: this function owns the reads the suggestion is
  built from, and only `apply_block_plan/3` moves a trip's `block_id`.

  The mode decides what is in scope:

    * `:unassigned_only` — the day type's whole trip set. The generator keeps every
      existing assignment and offers the blocks already on the page as open blocks,
      so what this mode places is the day type's pool.
    * `{:selected, ids}` — the trips of those blocks on the day type, which the run
      rebuilds onto blocks it creates. An empty list, or an ID the day type does not
      run, is `{:error, :no_selection}`: there is nothing to rebuild, and guessing a
      block would rebuild one the operator did not ask about.
    * `:replace_all` — the day type's whole trip set again, but every non-frequency
      trip in it is rebuilt rather than kept.

  A scope above `@max_plan_trips` rows is `{:error, {:too_large, n}}` before the
  generator runs, so an oversized day type is refused rather than answered slowly
  and partially. A version that derives no day type at all has nothing in
  scope to suggest and answers `{:error, :no_selection}`.

  The returned `%Blocking.Plan{}` carries the moves, the new blocks and their
  attribute rows, the review of what the moves change on every affected day type,
  the before and after figures, the leftovers and the fingerprint
  `apply_block_plan/3` matches. Nothing here decides whether the plan may be
  written; a plan is a proposal until a caller confirms it under the blocking lock.
  """
  @spec suggest_blocks(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil, Generator.mode()) ::
          {:ok, Plan.t()}
          | {:error,
             :not_found
             | {:unknown_day_type, [DayTypes.day_type()]}
             | :no_selection
             | {:too_large, pos_integer()}}
  def suggest_blocks(organization_id, gtfs_version_id, day_type_key, mode) do
    case Repo.transaction(fn ->
           read_suggestion(organization_id, gtfs_version_id, day_type_key, mode)
         end) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Decides R1 for candidate in-seat connections without writing anything.

  Each pair is evaluated as a stopless candidate type-4 row through the same
  `InSeat.state/2` the day load and the block review use, over every derived day type
  both of its trips run in: `:matches` is `:ok` and any other state is
  `{:refused, state}`, refusal included, so the caller can name the day types and the
  intervening trip a not-next state carries (R1, INV-2). The read takes no lock, so it
  is a pre-check and never a guarantee: the save repeats it under the locks.

  A foreign or unpublished version is `{:error, :not_found}`, and a pair naming a trip
  this version does not hold is refused as `{:stale, :trip_missing}` rather than
  silently dropped.
  """
  @spec check_connections(Ecto.UUID.t(), Ecto.UUID.t(), [pair()]) ::
          {:ok, %{pair() => :ok | {:refused, InSeat.state()}}} | {:error, :not_found}
  def check_connections(organization_id, gtfs_version_id, pairs) do
    case Repo.transaction(fn -> read_connections!(organization_id, gtfs_version_id, pairs) end) do
      {:ok, checks} -> {:ok, checks}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists the type 4/5 records of one version that "don't match any block" (R8).

  A record qualifies exactly when its state over every day type is `{:stale,
  reason}` with reason `:trip_missing`, `:no_shared_date` or `:no_block` - the
  three reasons that no block in the version can reach. A `{:not_next, _}` record
  is stale on a day type and is still reachable there, and an unconfirmed state is
  not a broken record at all, so neither is listed. Each returned row carries the
  stored record's `id` and `updated_at` with its `reason`, which is what a
  removal confirms (R7).

  The state comes from the one `InSeat.state/2` the day load, the pre-check and the
  block review read, over the same `in_seat_context_for_rows/6` context, so the
  version's listing can never disagree with a day's (INV-2). The read is bounded:
  the calendars, the records, the trips the records name, and the trips of the
  blocks those records are evaluated in - a fixed number of queries whatever the
  number of records.

  A foreign or unpublished version is `{:error, :not_found}`.
  """
  @spec unmatched_in_seat_records(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [unmatched_in_seat_record()]} | {:error, :not_found}
  def unmatched_in_seat_records(organization_id, gtfs_version_id) do
    case Repo.transaction(fn ->
           read_unmatched!(organization_id, gtfs_version_id)
         end) do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Draws the day a plan would leave behind, as a day of exactly the shape
  `load_day/3` returns.

  The function is pure: it reads the loaded day and the plan it was built from
  and makes no repository, clock, file or network call, so a page can draw a
  suggestion without touching the database and without ever writing a row.
  `day` is the day the plan was reviewed against — the one the
  reader is looking at — and the answer is a new map: the saved day is never
  mutated, and a plan that is never applied leaves nothing behind.

  The plan is applied to the loaded day rather than re-read. Every move's trip
  takes the block the move names, so a pool trip that the plan places joins a
  block and a trip the plan moves between blocks leaves the one it was in, while
  a trip no move names keeps the block it has. The plan's own attribute rows are
  added to the context, so a new block resolves through `Context.resolve_block/3`
  on the garage and vehicle type the generator gave it and not through a second
  rule. The per-block assembly is then re-run over the moved trips by
  the same `day_assemble/3` the day load uses, so a preview's blocks, resolution,
  movements, relief stretches, findings, figures, fleet rows, counts, peak, bins
  and axis are the day load's own answers rather than a second derivation.
  The in-seat states are re-evaluated too, over the rows and the block
  orders the day load already read and the context it already built, which travel
  with the day as `:in_seat_source`; nothing is read to do it.

  A plan for another day type than the loaded one still answers, because the
  moves name trip UUIDs and the loaded day holds a trip at most once.
  """
  @spec preview_day(day(), Plan.t()) :: day()
  def preview_day(%{} = day, plan) do
    to_by_trip_id = Map.new(plan.moves, &{&1.trip.id, &1.to})

    trips =
      day
      |> day_trip_rows()
      |> Enum.map(&moved_trip(&1, to_by_trip_id))

    context = preview_context(day.context, plan.attribute_rows)
    in_seat = preview_in_seat(day, trips, to_by_trip_id)

    day
    |> Map.merge(day_assemble(trips, context, in_seat))
    |> Map.put(:in_seat_source, in_seat)
  end

  # Every trip the loaded day holds, exactly once: a block's trips, the pool and
  # the untimed list between them are the day type's whole trip set.
  defp day_trip_rows(day) do
    (Enum.flat_map(day.blocks, & &1.trips) ++ day.pool ++ day.unplottable)
    |> Enum.uniq_by(& &1.id)
  end

  defp moved_trip(row, to_by_trip_id) do
    case Map.fetch(to_by_trip_id, row.id) do
      {:ok, to} -> %{row | block_id: to}
      :error -> row
    end
  end

  # The plan's attribute rows are the rows an apply would write, keyed the way
  # `Context.attributes` is keyed, so a new block resolves on the plan's own
  # resolution rather than on nothing.
  defp preview_context(context, attribute_rows) do
    attributes =
      Enum.reduce(attribute_rows, context.attributes, fn row, attributes ->
        Map.put(attributes, {row.service_id, row.block_id}, %{
          garage_id: row.garage_id,
          vehicle_type_id: row.vehicle_type_id
        })
      end)

    %{context | attributes: attributes}
  end

  # In-seat states over the moved trips. The records and the context are the day
  # load's own; what the moves change is which block each trip is in, and therefore
  # both the context's own trip rows and the block orders it was built from, so the
  # sequences are rebuilt over the moved rows. The day's trips join the order's
  # rows so a block a move fills — one no record named, and so one the day load
  # never read orders for — is still ordered.
  defp preview_in_seat(day, trips, to_by_trip_id) do
    source = day.in_seat_source
    context = source.context

    block_rows =
      (Enum.map(source.block_rows, &moved_trip(&1, to_by_trip_id)) ++ trips)
      |> Enum.uniq_by(& &1.id)

    context = %{
      context
      | trips:
          Map.new(context.trips, fn {trip_id, row} ->
            {trip_id, moved_trip(row, to_by_trip_id)}
          end),
        sequences: sequences(context.day_types, block_rows)
    }

    %{source | block_rows: block_rows, context: context}
  end

  @doc """
  Decides R1 for candidate in-seat connections under the block writers' locks.

  Call this inside the caller's transaction, after its version `FOR SHARE` read. The
  order is `load_calendars!/2` (which re-takes that read before the publication and
  calendar reads), `lock_blocking!/1`, the named trips' `FOR UPDATE` rows with every
  trip of their blocks on the day types both of each pair's services run in, then a
  re-read of the locked rows and the evaluation (INV-1). Nothing is written and no
  refusal rolls the caller back: the caller decides what a refusal means.

  Every pair answers `%{from, to, check}`, where the trip rows are the locked rows and
  `nil` for a trip this version does not hold, whose check is then
  `{:refused, {:stale, :trip_missing}}`. The write stores the handoff stops from
  `from.last_stop` and `to.first_stop`, which is why they travel with the check.

  A foreign or unpublished version rolls the caller's transaction back with `:not_found`.
  """
  @spec lock_and_check_connections!(AuditContext.t(), [pair()]) ::
          %{
            pair() => %{
              from: Queries.trip_row() | nil,
              to: Queries.trip_row() | nil,
              check: :ok | {:refused, InSeat.state()}
            }
          }
  def lock_and_check_connections!(%AuditContext{} = audit, pairs) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    calendars = load_calendars!(organization_id, version_id)
    day_types = DayTypes.derive(calendars)
    service_dates = DayTypes.service_dates(calendars)

    lock_blocking!(version_id)

    named = Queries.trip_rows(organization_id, version_id, {:trip_ids, named_trip_ids(pairs)})

    locked_ids =
      Queries.lock_trips!(
        organization_id,
        version_id,
        Enum.map(named, & &1.id),
        named |> Enum.map(& &1.block_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        shared_service_ids(day_types, pairs, named)
      )

    rows = Queries.trip_rows(organization_id, version_id, {:uuids, locked_ids})

    checks =
      evaluate_connections(
        organization_id,
        version_id,
        day_types,
        service_dates,
        rows,
        pairs
      )

    trips_by_id = Map.new(rows, &{&1.trip_id, &1})

    Map.new(pairs, fn pair = {from_trip_id, to_trip_id} ->
      {pair,
       %{
         from: Map.get(trips_by_id, from_trip_id),
         to: Map.get(trips_by_id, to_trip_id),
         check: Map.fetch!(checks, pair)
       }}
    end)
  end

  @doc """
  Takes the version's blocking advisory lock for the rest of the transaction.

  `pg_advisory_xact_lock` on `hashtext('blocking:' <> version_id)` is the single
  definition of the lock every `block_id` writer joins (INV-1, R11). It is a
  transaction-scoped lock, so it is released by the commit or the rollback of the
  caller's transaction and never needs an explicit release. `Schedules.update_trip/5`
  takes it after its route and pattern locks and before the trip row lock; the Blocks
  apply path takes it after the version `FOR SHARE` read and before its trip locks.
  """
  @spec lock_blocking!(Ecto.UUID.t()) :: :ok
  def lock_blocking!(gtfs_version_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["blocking:" <> gtfs_version_id])
    :ok
  end

  @doc """
  Reports whether a trip may keep its block when its calendar changes (R9).

  A trip's *companions* are the other trips with its `block_id`. The ID is kept only
  when every companion that runs on a date of the new calendar also ran on a date of
  the old one — or when there is none — so a calendar change never silently puts the
  trip on another vehicle's work. `Schedules.update_trip/5` takes
  `lock_blocking!/1` for a calendar change and clears the block in the same update
  when this returns false (D2, AC-17).

  Both calendars' dates come from `Calendars.list_calendars/3` through
  `DayTypes.service_dates/1`, the one service-date source every date evaluation uses
  (CR-2), so this belongs inside the caller's transaction. A trip with no block has
  nothing to clear and keeps its answer `true`.

  ## Examples

      iex> calendar_change_keeps_block?(organization_id, gtfs_version_id, trip, "SAT")
      false
  """
  @spec calendar_change_keeps_block?(Ecto.UUID.t(), Ecto.UUID.t(), Trip.t(), String.t()) ::
          boolean()
  def calendar_change_keeps_block?(
        organization_id,
        gtfs_version_id,
        %Trip{block_id: block_id} = trip,
        service_id
      )
      when is_binary(block_id) do
    service_dates = calendar_service_dates(organization_id, gtfs_version_id)
    companions = block_companions(organization_id, gtfs_version_id, block_id, trip.id)

    companions_before =
      companions_on_dates(
        companions,
        service_dates,
        service_dates_for(service_dates, trip.service_id)
      )

    companions_after =
      companions_on_dates(companions, service_dates, service_dates_for(service_dates, service_id))

    MapSet.subset?(companions_after, companions_before)
  end

  def calendar_change_keeps_block?(_organization_id, _gtfs_version_id, %Trip{}, _service_id),
    do: true

  @doc """
  Projects every block and in-seat consequence of one calendar combination (AC-17, AC-18).

  `inputs` is the loaded review input set of `combination_inputs()` and `command` the
  resolved combination, whose `result_dates` are the destination's committed dates. The
  function is pure: it reads the loaded rows and the version's stored layover and no
  database, clock, file or network, so the review and the apply path ask this one
  producer what a combination does to blocks (CR-1, CR-2). An incomplete plan has no
  projected effects: `result_dates` must be a list.

  One projection carries every proposed change at once - each source trip's `service_id`
  becomes the destination and the destination's own dates become `result_dates` - and the
  keep decision is derived from it alone. A moved blocked trip keeps its block only when
  the companion UUIDs of that projection are a subset of its original companions, where a
  companion counts when its own dates intersect the trip's (`companions_on_dates/3`, the
  same rule `calendar_change_keeps_block?/4` answers for one trip). Every keep decision
  comes from this one before/after pair and the clears are applied together afterwards,
  so clearing one block can never make another move look safe (AC-17, PM-4). A trip's
  block decision follows its service: AC-11 moves every trip of a source calendar,
  including a companion the selection did not name.

  `cleared_trip_ids` lists exactly the moved trips whose block is cleared, sorted.
  Destination trips and trips on other calendars are never candidates: destination block
  IDs stay assigned, and the findings below report what their changed dates add.

  `before_findings` and `after_findings` are the real `Checks.block_findings/3` and
  `InSeat.finding/3` results of each projection, evaluated per derived day type over the
  trips that run in it - the scoping the day load and the block review use - and
  deduplicated by day type and `Checks.finding_key/1`. Each finding carries
  `day_type_keys` and `dates`, the day types it was evaluated in and their dates, so a
  warning a combination adds on a gained date is distinguishable from the same pair's
  pre-existing warning and a changed detail is never hidden behind an unchanged key.
  Findings are sorted by day types and key, so reordering the input lists returns an
  identical projection. An unblocked trip contributes no finding here: its unassignment
  is `cleared_trip_ids` and unassigned-pool notices belong to the day read.

  `transfers` reports every distinct type-4/5 record of `inputs.transfers` once, sorted by
  record UUID, with its `InSeat` state before and after the projection. Records are read
  only: a clear or a date change that makes one stale is reported, never rewritten
  (AC-11, AC-18).
  """
  @spec project_calendar_combination(combination_inputs(), combination_command()) ::
          combination_projection()
  def project_calendar_combination(
        %{
          calendars: calendars,
          trips: trips,
          transfers: transfers,
          settings: %{min_layover_minutes: min_layover_minutes}
        },
        %{destination_id: destination_id, source_ids: source_ids, result_dates: result_dates}
      )
      when is_list(calendars) and is_list(trips) and is_list(transfers) and
             is_binary(destination_id) and is_list(source_ids) and is_list(result_dates) do
    moved_services = MapSet.new([destination_id | source_ids])

    before = projection_state(calendars, trips, transfers, min_layover_minutes)

    after_moves =
      projection_state(
        move_calendars(calendars, destination_id, result_dates),
        Enum.map(trips, &move_trip(&1, moved_services, destination_id)),
        transfers,
        min_layover_minutes
      )

    cleared_trip_ids = clear_decisions(before, after_moves, moved_services, destination_id)
    after_state = state_trips(after_moves, clear_trips(after_moves.trips, cleared_trip_ids))

    %{
      cleared_trip_ids: cleared_trip_ids,
      before_findings: before.findings,
      after_findings: after_state.findings,
      transfers: transfer_states(before, after_state, transfers)
    }
  end

  @doc """
  Projects every block and in-seat consequence of per-trip service and endpoint changes (R6).

  `inputs` is the loaded input set of `trip_change_inputs()` and `changed` the rows the
  command writes: each one replaces the input row with the same `:id`, and an input row
  the command does not name stays as loaded. The function is pure: it reads the loaded
  rows and the version's stored layover and no database, clock, file or network (CR-1).

  One projection carries every changed row at once, so Shift's endpoint changes and Change
  calendar's service changes are projected together and a block decision never sees a
  half-applied command. A changed row whose `service_id` differs from its input row's and
  that names a block is a clear candidate; a candidate keeps its block only when the move
  leaves its companion set unchanged, where a companion counts when its own dates
  intersect the trip's (`companions_on_dates/3`). That rejects a companion the input did
  not hold - the trip would join another vehicle's work on its new dates - and a companion
  left behind on the old calendar, which would leave the trip carrying the block alone.
  Every clear is decided from that one after-projection before any clear is applied, so a
  block whose trips move together keeps its ID and clearing one block can never make
  another move look safe (AC-13, PM-4).

  `cleared_trip_ids` lists exactly the moved trips whose block is cleared, sorted.
  `after_findings` is computed with the clears applied, so it describes the day the
  command leaves behind, and `before_findings` describes the loaded day. `transfers`
  reports every distinct type-4/5 record of `inputs.transfers` once, sorted by record
  UUID, with its `InSeat` state before and after; a clear that makes one stale or
  unconfirmed is reported, never rewritten.
  """
  @spec project_trip_changes(trip_change_inputs(), [Queries.trip_row()]) ::
          combination_projection()
  def project_trip_changes(
        %{
          calendars: calendars,
          trips: trips,
          transfers: transfers,
          settings: %{min_layover_minutes: min_layover_minutes}
        },
        changed_trips
      )
      when is_list(calendars) and is_list(trips) and is_list(transfers) and
             is_list(changed_trips) do
    before = projection_state(calendars, trips, transfers, min_layover_minutes)

    after_moves =
      projection_state(
        calendars,
        replace_trips(trips, changed_trips),
        transfers,
        min_layover_minutes
      )

    cleared_trip_ids = trip_change_clear_decisions(before, after_moves, changed_trips)
    after_state = state_trips(after_moves, clear_trips(after_moves.trips, cleared_trip_ids))

    %{
      cleared_trip_ids: cleared_trip_ids,
      before_findings: before.findings,
      after_findings: after_state.findings,
      transfers: transfer_states(before, after_state, transfers)
    }
  end

  @doc """
  Applies one block command on `day_type_key` inside the reviewed transaction.

  The command's shape is validated before any transaction (AC-13, Mutation):
  UUIDs are deduplicated and cast, a malformed one is `:not_found`; a block ID is
  trimmed and must be 1–255 characters (`:invalid_block_id`); a `:rename` or
  `:merge` naming one ID twice is `:invalid_command`; an empty trip list is
  `:invalid_command`.

  Everything else runs in the configured transaction, in the order `spec.md`
  Mutation prescribes: calendars and day types, `lock_blocking!/1`, the targets and
  their eligibility (R10), the changed trips and the `@max_command_trips` bound, the
  affected day types with R8's fresh-ID resolution and a rename's collision check,
  one `FOR UPDATE` read of every decision input, R6's in-seat context,
  `Review.build/1`, the confirmation decision and the write with its audit (INV-1,
  INV-3, INV-4). An `:assign` and an `:unassign` name trips; a `:rename` and a
  `:merge` name block IDs and take the selected day type's trips carrying the
  source ID as their targets, so another day type's trips with that ID keep it
  (R2, R3, AC-13).

  A command with nothing to change returns
  `{:ok, %{operation_id: nil, changed_trip_ids: [], block_id: target | nil, review: nil}}`
  without writing and without an audit entry. A command that needs confirmation returns
  `{:needs_confirmation, review}` from inside the transaction without writing; a
  supplied `confirmation` is applied only when it equals the recomputed
  `review.fingerprint`, otherwise the command returns `{:error, {:stale_review,
  review}}` and writes nothing.

  Every refusal reaches the caller as an `{:error, reason}` tuple. An audit insert the
  database rejects, or one the audit layer refuses, rolls the command back and returns
  `{:error, {:audit_failed, reason}}` with whatever the audit layer provides — a
  changeset or the exception — so a command failure is never raised out of the
  transaction (AC-10, INV-4).
  """
  @spec apply_block_change(String.t(), command(), AuditContext.t(), String.t() | nil) ::
          {:ok, apply_result()}
          | {:needs_confirmation, Review.review()}
          | {:error,
             {:stale_review, Review.review()}
             | {:ineligible, [Ecto.UUID.t()]}
             | {:audit_failed, term()}
             | :forbidden
             | :not_found
             | {:unknown_day_type, [DayTypes.day_type()]}
             | :invalid_command
             | :invalid_block_id
             | :block_id_taken
             | :too_many_trips
             | :busy}
  def apply_block_change(day_type_key, command, %AuditContext{} = audit, confirmation \\ nil) do
    case validate_command(command) do
      {:ok, command} ->
        run_write(fn -> apply_command!(day_type_key, command, audit, confirmation) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reviews and stores one block's garage and required vehicle type.

  `attrs` carries `garage_id` and `vehicle_type_id`; a blank value is stored as
  `nil`, and a value that is not a UUID is a changeset error raised before the
  transaction opens. The save is reviewed, not applied blind: a block's row is
  keyed `(service_id, block_id)`, so a service another day type shares is read
  there too, and the review names every day type the rows reach with its date
  count and the problems the saved value adds.

  The write takes the same prefix as a block command — the scoped version `FOR
  SHARE` and its published check, the calendars and their derived day types,
  `lock_blocking!/1` and then the block's own trip rows `FOR
  UPDATE` in UUID order — rebuilds the planning context under that lock and
  compares `Context.digest/1` of it through the review's fingerprint, so
  a driving time, a route setting or another attribute entered after the review
  makes the confirmation stale rather than silently overwriting.

  A block the selected day type does not run is `{:error, :not_found}`, as is a
  garage or a vehicle type of another organization; a value of this organization
  is the only one that can be stored. A save that reaches a day type other than
  the selected one, or that adds a problem, returns `{:needs_confirmation,
  review}` and writes nothing; calling it again with `review.fingerprint` writes
  the rows and returns `{:ok, %{review: review}}`, and a fingerprint that no
  longer matches returns `{:error, {:stale_review, review}}` and writes nothing.

  No trip row changes, so no `"trip"` change log is written and no `transfers`
  row is ever inserted, updated or deleted.
  """
  @spec set_block_attributes(String.t(), String.t(), map(), AuditContext.t(), String.t() | nil) ::
          {:ok, %{review: Review.review()}}
          | {:needs_confirmation, Review.review()}
          | {:error,
             {:stale_review, Review.review()}
             | {:unknown_day_type, [DayTypes.day_type()]}
             | :forbidden
             | :not_found
             | :busy
             | Ecto.Changeset.t()}
  def set_block_attributes(
        day_type_key,
        block_id,
        attrs,
        %AuditContext{} = audit,
        confirmation \\ nil
      ) do
    case attribute_values(attrs) do
      {:ok, values} ->
        run_write(fn ->
          write_attributes!(day_type_key, block_id, values, audit, confirmation)
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Applies a reviewed suggestion as one reviewed transaction.

  `plan` is a `%Blocking.Plan{}` from `suggest_blocks/4`; the write is decided from
  the plan's `mode` and `day_type_key` and from nothing else the caller carries. The
  plan's own `moves` are never trusted as the thing to write: the run is repeated
  under `lock_blocking!/1` from the locked rows and the fresh plan's fingerprint is
  compared with the caller's, so a plan whose contents were edited, or whose inputs
  moved since the review, is `{:error, :stale_plan}` rather than a partial write.
  The plan's shape is checked before any transaction: a plan that does not
  carry a `day_type_key`, a `mode` and a `fingerprint` is
  `{:error, :invalid_plan}` and costs no query.

  Everything else runs in the configured transaction in this order: the scoped
  version `FOR SHARE` with its published check,
  the calendars and their derived day types, `lock_blocking!/1`,
  the plan's moved trips and the touched blocks' trips `FOR UPDATE` in UUID
  order, the repeated generator run and `Plan.build/1` from the locked rows, the
  fingerprint comparison, the per-destination `update_all` batches of at most
  `@max_command_trips` IDs, the `block_attributes` rows of the plan's new blocks and
  one `"trip"` change log per moved trip under a single `operation_id`. A
  write whose `update_all` count does not match the moves it covers rolls back with
  `:busy`; an audit the database or the audit layer refuses rolls back with
  `{:error, {:audit_failed, reason}}`; a serialization failure or deadlock is
  retried by `run_write/2` and reported as `:busy` after three attempts.

  A day type the version does not derive is `{:error, {:unknown_day_type, day_types}}`
  and a version of another organization, or an unpublished one, is
  `{:error, :not_found}`; both change nothing. No `transfers` row is ever inserted,
  updated or deleted, and no trip is left holding a block it did not keep.

  A plan with nothing to move still writes the attribute rows of its new blocks and
  reports `{:ok, %{operation_id: nil, changed_trip_ids: []}}`: a plan that only
  resolves a block's garage and type is a real write with no trip to move.
  """
  @spec apply_block_plan(String.t(), Plan.t(), AuditContext.t()) ::
          {:ok, %{operation_id: Ecto.UUID.t() | nil, changed_trip_ids: [Ecto.UUID.t()]}}
          | {:error,
             :stale_plan
             | :invalid_plan
             | {:unknown_day_type, [DayTypes.day_type()]}
             | :forbidden
             | :not_found
             | :busy
             | {:audit_failed, term()}}
  def apply_block_plan(day_type_key, plan, %AuditContext{} = audit)
      when is_binary(day_type_key) do
    case plan_mode(plan) do
      {:ok, mode} -> run_write(fn -> apply_plan!(day_type_key, mode, plan, audit) end)
      :error -> {:error, :invalid_plan}
    end
  end

  def apply_block_plan(_day_type_key, _plan, _audit), do: {:error, :invalid_plan}

  # The plan's shape, checked before any transaction opens. Only the `mode` decides
  # what is run; the rest of the plan's contents are re-derived under the lock and a
  # hand-built plan naming a mode the generator does not accept is refused here rather
  # than raising inside a transaction.
  defp plan_mode(%{mode: mode}) when mode in [:unassigned_only, :replace_all],
    do: {:ok, mode}

  defp plan_mode(%{mode: {:selected, ids}}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: {:ok, {:selected, ids}}, else: :error
  end

  defp plan_mode(_plan), do: :error

  # The plan's own moves are re-derived rather than written: the
  # run is repeated from the locked rows in the plan's mode and only the fresh
  # fingerprint decides whether the reviewed plan is still the current one.
  defp apply_plan!(day_type_key, mode, plan, %AuditContext{} = audit) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    version = Versions.lock_for_input_write!(organization_id, version_id)

    if version.publication_status == @published_status do
      calendars = load_calendars!(organization_id, version_id)
      day_types = DayTypes.derive(calendars)
      day_type = resolve_day_type!(day_types, day_type_key)

      if is_nil(day_type), do: Repo.rollback({:unknown_day_type, day_types})

      lock_blocking!(version_id)

      fresh = read_plan!(organization_id, version_id, calendars, day_type, day_types, plan, mode)

      if fresh.fingerprint == plan.fingerprint do
        write_plan!(audit, fresh)
      else
        Repo.rollback(:stale_plan)
      end
    else
      Repo.rollback(:not_found)
    end
  end

  # Under the blocking lock: lock the plan's moved trips and the
  # trips of every block it touches on an affected service `FOR UPDATE` in UUID order,
  # then rebuild the context and repeat the run and `Plan.build/1` from the
  # rows as they stand under that lock. The scope read and the rebuild are the same
  # private path `suggest_blocks/4` uses, so a reviewed plan and the plan re-derived
  # under the lock are two answers to the same question rather than two questions.
  #
  # The lock set is named by the caller's plan — its moves and the blocks they leave
  # and join — because that is the set the reviewed plan said it would write. The rows
  # a fresh run reads beyond it are still compared through the fingerprint, so a change
  # the lock set missed is a stale plan rather than a silent write.
  defp read_plan!(
         organization_id,
         version_id,
         calendars,
         day_type,
         day_types,
         plan,
         mode
       ) do
    scope = suggestion_rows(organization_id, version_id, day_type, mode)

    if length(scope) > @max_plan_trips, do: Repo.rollback({:too_large, length(scope)})

    # Every trip of the mode's scope, every trip the reviewed plan said it would move,
    # and every trip of a block the plan leaves or joins on an affected service, taken
    # `FOR UPDATE` in UUID order. The scope is what tells the lock set which blocks and
    # services matter; the reviewed plan's moves are added so a plan whose contents were
    # edited cannot name rows this transaction then reads unlocked.
    moved = Enum.uniq(Enum.map(scope, & &1.id) ++ plan_scope_ids(plan))
    services = Enum.uniq(Enum.map(scope, & &1.service_id) ++ plan_scope_services(plan))
    touched = plan_touched_blocks(plan)

    locked_ids = Queries.lock_trips!(organization_id, version_id, moved, touched, services)

    # Every trip the reviewed plan moves belongs to this version and
    # to a service this apply is scoped over. A plan naming a row this version does not
    # hold is not a stale plan — it is a plan about another version — so it is answered
    # `:not_found` rather than made to match this version's fingerprint. The
    # comparison reads the IDs the lock just took, so a plan can neither name a row it
    # did not lock nor pass on a row the lock never reached.
    check_plan_scope!(plan, locked_ids, Enum.uniq(Enum.map(scope, & &1.service_id)))

    # Re-read through the same scope the suggestion read: the rows the run and the
    # review see are the rows as they stand under the lock, and each mode keeps its own
    # scope shape (a `{:selected, ids}` plan is rebuilt over its selected blocks' trips,
    # never over the whole day type).
    rows = suggestion_rows(organization_id, version_id, day_type, mode)

    settings = get_settings(organization_id, version_id)
    context = build_context!(organization_id, version_id, settings, rows)

    used_ids =
      suggest_used_block_ids(organization_id, version_id, scope_day_types(day_types, rows))

    result = Generator.run(mode, rows, context, used_ids)
    affected = affected_day_types(day_types, moved_trips(rows, result.assignments))
    service_dates = DayTypes.service_dates(calendars)
    plan_rows = plan_rows(organization_id, version_id, rows, result.blocks, affected)

    Plan.build(%{
      mode: mode,
      selected_key: day_type.key,
      day_types: day_types,
      affected: affected,
      rows: plan_rows,
      result: result,
      context: context,
      in_seat: in_seat_context(organization_id, version_id, affected, service_dates, plan_rows),
      service_dates: service_dates
    })
  end

  # The trip UUIDs the reviewed plan said it would move, read defensively: a plan
  # whose `moves` are absent or the wrong shape locks nothing beyond the scope and is
  # then refused by the fingerprint comparison rather than raising in the transaction.
  defp plan_scope_ids(plan) do
    plan
    |> Map.get(:moves, [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&get_in(&1, [:trip, Access.key(:id)]))
    |> Enum.filter(&is_binary/1)
  end

  defp plan_scope_services(plan) do
    plan
    |> Map.get(:moves, [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&get_in(&1, [:trip, Access.key(:service_id)]))
    |> Enum.filter(&is_binary/1)
  end

  # The scope check itself. `locked` is this organization's and version's own locked IDs
  # and `services` the scope's services, so a plan about another organization, another
  # version or a service this day type does not run is refused rather than partially
  # applied.
  defp check_plan_scope!(plan, locked_ids, services) do
    held = MapSet.new(locked_ids)
    scoped = MapSet.new(services)

    if Enum.all?(plan_scope_ids(plan), &MapSet.member?(held, &1)) and
         Enum.all?(plan_scope_services(plan), &MapSet.member?(scoped, &1)) do
      :ok
    else
      Repo.rollback(:not_found)
    end
  end

  defp plan_touched_blocks(plan) do
    plan
    |> Map.get(:moves, [])
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&[Map.get(&1, :from), Map.get(&1, :to)])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  # The moves' block IDs in `update_all` batches grouped by
  # destination, the attribute rows of the plan's new blocks, and one `"trip"` change
  # log per moved trip sharing one operation ID. A count mismatch is a row
  # this transaction expected and did not find, so the whole plan rolls back rather
  # than leaving part of it written.
  defp write_plan!(%AuditContext{} = audit, plan) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id
    moves = plan.moves
    changed_ids = moves |> Enum.map(& &1.trip.id) |> Enum.sort()

    # The rows are read before the write, not after: the audit's `before` side is the
    # stored row, so reading it once the blocks are written would record the new block
    # on both sides and no audit would name a change.
    structs = trip_structs(organization_id, version_id, changed_ids)

    update_trip_blocks!(organization_id, version_id, moves)
    store_plan_attributes!(organization_id, version_id, plan.attribute_rows)

    if changed_ids == [] do
      %{operation_id: nil, changed_trip_ids: []}
    else
      trips = Map.new(structs, &{&1.id, &1})
      snapshots = Schedules.trip_audit_snapshots(organization_id, version_id, structs)
      operation_id = Ecto.UUID.generate()

      Enum.each(moves, fn move ->
        audit_change!(
          audit,
          Map.fetch!(trips, move.trip.id),
          move.to,
          snapshots,
          operation_id,
          changed_ids
        )
      end)

      %{operation_id: operation_id, changed_trip_ids: changed_ids}
    end
  end

  # Grouped by destination because one plan places its trips on several blocks, and
  # `update_all` takes a single value per statement. The batch bound is
  # `@max_command_trips`, the same 500-row bound a block command works in, so a large
  # plan is several bounded statements inside the one transaction rather than one
  # unbounded one. The count is checked per batch and against the moves it
  # covers: a trip the plan moves that this transaction did not update is
  # `:busy`, never a partial plan.
  defp update_trip_blocks!(organization_id, version_id, moves) do
    now = DateTime.utc_now()

    moves
    |> Enum.group_by(& &1.to)
    |> Enum.each(fn {to, group} ->
      group
      |> Enum.map(& &1.trip.id)
      |> Enum.sort()
      |> Enum.chunk_every(@max_command_trips)
      |> Enum.each(&update_block_batch!(organization_id, version_id, &1, to, now))
    end)
  end

  defp update_block_batch!(organization_id, version_id, batch, to, now) do
    {count, _} =
      Repo.update_all(
        from(t in Trip,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
              t.id in ^batch
        ),
        set: [block_id: to, updated_at: now]
      )

    if count != length(batch), do: Repo.rollback(:busy)
  end

  # One row per `(service_id, block_id)` the plan proposed, replacing both value
  # columns and the write timestamp. A repeated apply of the same plan writes the
  # same rows rather than failing on the unique index, and the scoping fields are set
  # on the struct and never cast. No `transfers` row is touched.
  defp store_plan_attributes!(organization_id, version_id, attribute_rows) do
    Enum.each(attribute_rows, fn row ->
      changeset =
        BlockAttribute.changeset(
          %BlockAttribute{
            organization_id: organization_id,
            gtfs_version_id: version_id,
            service_id: row.service_id,
            block_id: row.block_id
          },
          %{garage_id: row.garage_id, vehicle_type_id: row.vehicle_type_id}
        )

      case Repo.insert(changeset,
             on_conflict: {:replace, @replace_attribute_columns},
             conflict_target: [:organization_id, :gtfs_version_id, :service_id, :block_id]
           ) do
        {:ok, _row} -> :ok
        {:error, refused} -> Repo.rollback(refused)
      end
    end)
  end

  defp read_day(organization_id, gtfs_version_id, day_type_key) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    day_type = resolve_day_type!(day_types, day_type_key)
    trips = day_trips(organization_id, gtfs_version_id, day_type)
    settings = get_settings(organization_id, gtfs_version_id)
    context = build_context!(organization_id, gtfs_version_id, settings, trips)

    day = %{
      day_types: day_types,
      day_type: day_type,
      settings: settings,
      context: context,
      routes: Queries.routes(organization_id, gtfs_version_id, Enum.map(trips, & &1.route_id)),
      mixed_timezones?: Queries.mixed_timezones?(organization_id, gtfs_version_id)
    }

    Map.merge(
      day,
      assemble(
        organization_id,
        gtfs_version_id,
        day_types,
        DayTypes.service_dates(calendars),
        trips,
        context
      )
    )
  end

  defp day_trips(_organization_id, _gtfs_version_id, nil), do: []

  defp day_trips(organization_id, gtfs_version_id, %{service_ids: service_ids}) do
    Queries.trip_rows(organization_id, gtfs_version_id, {:services, service_ids})
  end

  # An empty version has no day type to resolve, so any key loads the empty day
  # rather than an unknown-key error (Day loading step 2).
  defp resolve_day_type!([], _day_type_key), do: nil
  defp resolve_day_type!(day_types, nil), do: hd(day_types)

  defp resolve_day_type!(day_types, day_type_key) do
    Enum.find(day_types, &(&1.key == day_type_key)) ||
      Repo.rollback({:unknown_day_type, day_types})
  end

  defp load_calendars!(organization_id, gtfs_version_id) do
    case Calendars.list_calendars(organization_id, gtfs_version_id) do
      {:ok, summaries} -> summaries
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp first_day_type_key!([]), do: :none
  defp first_day_type_key!([day_type | _day_types]), do: day_type.key

  defp read_block_problems(organization_id, gtfs_version_id, trip_ids) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    min_layover_minutes = get_settings(organization_id, gtfs_version_id).min_layover_minutes
    trips = problem_trips(organization_id, gtfs_version_id, trip_ids)

    block_entries =
      block_problem_entries(
        organization_id,
        gtfs_version_id,
        day_types,
        trips,
        min_layover_minutes
      )

    in_seat_entries =
      in_seat_problem_entries(
        organization_id,
        gtfs_version_id,
        day_types,
        DayTypes.service_dates(calendars),
        trips
      )

    problem_groups(block_entries ++ in_seat_entries, MapSet.new(trips, & &1.id), day_types)
  end

  defp problem_trips(organization_id, gtfs_version_id, trip_ids) do
    Queries.trip_rows(organization_id, gtfs_version_id, {:trip_ids, Enum.uniq(trip_ids)})
  end

  # --- suggestion ------------------------------------------------------------

  # The read behind `suggest_blocks/4`. The order is: the
  # version and its calendars, the day types and the key, the scope and its bound,
  # and only then the context, the generator and the plan. Everything the bound
  # refuses is refused before a context is built or a row is walked, so an oversized
  # day type costs one query and not a generator run.
  defp read_suggestion(organization_id, gtfs_version_id, day_type_key, mode) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    day_type = resolve_day_type!(day_types, day_type_key)

    if is_nil(day_type), do: Repo.rollback(:no_selection)

    rows = suggestion_rows(organization_id, gtfs_version_id, day_type, mode)
    if length(rows) > @max_plan_trips, do: Repo.rollback({:too_large, length(rows)})

    settings = get_settings(organization_id, gtfs_version_id)
    context = build_context!(organization_id, gtfs_version_id, settings, rows)

    # The blocks a rebuild creates are numbered after the highest numeric ID in use on
    # an affected date. The affected set is read from the scope's own services
    # rather than from the run's moves, which are not known until the run has
    # happened: every moved trip runs in a scoped service, so this set is a superset
    # of the moved trips' day types and can only continue the numbering further
    # along, never inside an ID that is in use.
    used_ids =
      suggest_used_block_ids(organization_id, gtfs_version_id, scope_day_types(day_types, rows))

    result = Generator.run(mode, rows, context, used_ids)

    affected = affected_day_types(day_types, moved_trips(rows, result.assignments))
    service_dates = DayTypes.service_dates(calendars)
    plan_rows = plan_rows(organization_id, gtfs_version_id, rows, result.blocks, affected)

    Plan.build(%{
      mode: mode,
      selected_key: day_type.key,
      day_types: day_types,
      affected: affected,
      rows: plan_rows,
      result: result,
      context: context,
      in_seat:
        in_seat_context(organization_id, gtfs_version_id, affected, service_dates, plan_rows),
      service_dates: service_dates
    })
  end

  # The rows one mode reads. The additive and the replace-all modes both read the
  # day type's whole trip set and let `Generator.run/4` split it, because the run's
  # own scope is what keeps every existing assignment and holds a frequency trip
  # back in every mode; reading only the pool here would leave the run no
  # existing block to extend. `{:selected, ids}` reads exactly the selected blocks'
  # trips on the day type and refuses a selection the day type does not run.
  defp suggestion_rows(_organization_id, _gtfs_version_id, _day_type, {:selected, []}) do
    Repo.rollback(:no_selection)
  end

  defp suggestion_rows(organization_id, gtfs_version_id, day_type, {:selected, ids}) do
    ids = ids |> Enum.uniq() |> Enum.sort()

    rows =
      Queries.trip_rows(organization_id, gtfs_version_id, {:blocks, ids, day_type.service_ids})

    if Enum.all?(ids, &held_on_day_type?(rows, &1)) do
      rows
    else
      Repo.rollback(:no_selection)
    end
  end

  defp suggestion_rows(organization_id, gtfs_version_id, day_type, mode)
       when mode in [:unassigned_only, :replace_all] do
    Queries.trip_rows(organization_id, gtfs_version_id, {:services, day_type.service_ids})
  end

  # An ID the operator selected is in scope only when the day type actually runs
  # one of its trips. A block that exists only on another day type is not this
  # day's suggestion to rebuild, and rebuilding it would move trips the operator
  # did not see selected.
  defp held_on_day_type?(rows, block_id),
    do: Enum.any?(rows, &(&1.block_id == block_id))

  # The day types the scope reaches, and so the services whose block IDs new block
  # numbering continues after. A scope with no trip reaches no day type.
  defp scope_day_types(day_types, rows) do
    rows
    |> Enum.flat_map(&DayTypes.containing(day_types, &1.service_id))
    |> Enum.uniq_by(& &1.key)
  end

  defp suggest_used_block_ids(_organization_id, _gtfs_version_id, []) do
    []
  end

  defp suggest_used_block_ids(organization_id, gtfs_version_id, day_types) do
    service_ids = day_types |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()

    organization_id
    |> Queries.used_block_ids(gtfs_version_id, service_ids)
    |> MapSet.to_list()
  end

  # The trips whose block the run changes. A trip the run held where it was, and a
  # frequency trip that keeps its assignment in every mode, compare equal here and
  # are not a move — so neither puts its service in the affected set.
  defp moved_trips(rows, assignments) do
    Enum.filter(rows, &(Map.get(assignments, &1.id) != &1.block_id))
  end

  # The rows the plan is read over: the scoped trips and the trips of every block
  # the run left in place or created, on the affected services. A block the run
  # rebuilt is complete only when the plan also sees the trips it shares with the
  # other day types that run it, and an extra row is harmless while a missing one
  # would read a block as half-empty.
  defp plan_rows(_organization_id, _gtfs_version_id, rows, _blocks, affected)
       when affected == [] or rows == [] do
    rows
  end

  defp plan_rows(organization_id, gtfs_version_id, rows, blocks, affected) do
    block_ids = blocks |> Enum.map(& &1.id) |> Enum.uniq()
    service_ids = affected |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()

    companion_rows =
      Queries.trip_rows(organization_id, gtfs_version_id, {:blocks, block_ids, service_ids})

    (rows ++ companion_rows) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)
  end

  # One `{finding, day_type}` per check result. The pairs are collected and
  # deduplicated before the read, so a block shared by several requested trips is
  # checked once per day type and every pair's block rows come from one query: the
  # query count does not grow with the number of requested trips. Each pair is
  # checked over its own block's trips on its own day type, filtered from that read.
  defp block_problem_entries(organization_id, gtfs_version_id, day_types, trips, min_layover) do
    context = Context.layover_only(min_layover)

    pairs =
      trips
      |> Enum.filter(&is_binary(&1.block_id))
      |> Enum.flat_map(fn trip ->
        Enum.map(DayTypes.containing(day_types, trip.service_id), &{trip.block_id, &1})
      end)
      |> Enum.uniq_by(fn {block_id, day_type} -> {block_id, day_type.key} end)

    rows = block_pair_rows(organization_id, gtfs_version_id, pairs)

    pairs
    |> Enum.map(fn {block_id, day_type} ->
      block_trips =
        Enum.filter(rows, &(&1.block_id == block_id and &1.service_id in day_type.service_ids))

      {Checks.block_findings(block_id, block_trips, context), day_type}
    end)
    |> Enum.flat_map(fn {findings, day_type} -> Enum.map(findings, &{&1, day_type}) end)
    |> Enum.uniq_by(fn {finding, day_type} -> {Checks.finding_key(finding), day_type.key} end)
  end

  # Every pair's block trips in one query: the rows are the union over the pair
  # block IDs and the pairs' day-type services, and each pair filters its own block
  # and service out of them above.
  defp block_pair_rows(_organization_id, _gtfs_version_id, []), do: []

  defp block_pair_rows(organization_id, gtfs_version_id, pairs) do
    Queries.trip_rows(
      organization_id,
      gtfs_version_id,
      {:blocks, pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), pair_services(pairs)}
    )
  end

  defp pair_services(pairs) do
    pairs
    |> Enum.flat_map(fn {_block_id, day_type} -> day_type.service_ids end)
    |> Enum.uniq()
  end

  # The type 4/5 records naming a requested trip, evaluated once over the derived
  # day types. A record whose evaluation names a requested trip is attributed to
  # every day type that trip runs in, like a block finding of the same trip.
  defp in_seat_problem_entries(organization_id, gtfs_version_id, day_types, service_dates, trips) do
    if Enum.any?(trips, &is_binary(&1.block_id)) do
      %{rows: rows, context: context} =
        in_seat_context(organization_id, gtfs_version_id, day_types, service_dates, trips)

      trips_by_uuid = Map.new(trips, &{&1.id, &1})

      rows
      |> Enum.map(&{&1, InSeat.state(&1, context)})
      |> Enum.map(fn {row, state} -> InSeat.finding(row, state, context) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&in_seat_problem_day_types(&1, trips_by_uuid, day_types))
      |> Enum.uniq_by(fn {finding, day_type} -> {Checks.finding_key(finding), day_type.key} end)
    else
      []
    end
  end

  defp in_seat_problem_day_types(finding, trips_by_uuid, day_types) do
    finding.trip_ids
    |> Enum.flat_map(fn uuid ->
      case Map.fetch(trips_by_uuid, uuid) do
        {:ok, trip} -> DayTypes.containing(day_types, trip.service_id)
        :error -> []
      end
    end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.map(&{finding, &1})
  end

  defp problem_groups(entries, requested, day_types) do
    order = Map.new(Enum.with_index(day_types), fn {day_type, index} -> {day_type.key, index} end)

    entries
    |> Enum.filter(&problem_entry?(&1, requested))
    |> Enum.group_by(fn {finding, _day_type} ->
      {finding.code, Enum.sort(finding.trip_ids), finding.block_id}
    end)
    |> Enum.map(fn {{code, _trip_ids, block_id}, group} ->
      group_day_types =
        group
        |> Enum.map(fn {_finding, day_type} -> day_type end)
        |> Enum.uniq_by(& &1.key)
        |> Enum.sort_by(&Map.fetch!(order, &1.key))

      problem = %{
        code: code,
        block_id: block_id,
        day_type_keys: Enum.map(group_day_types, & &1.key),
        date_count: Enum.sum(Enum.map(group_day_types, & &1.date_count))
      }

      {problem_severity_rank(hd(group)), problem}
    end)
    |> Enum.sort_by(fn {rank, problem} -> {rank, problem.block_id, problem.code} end)
    |> Enum.map(fn {_rank, problem} -> problem end)
  end

  defp problem_entry?({finding, _day_type}, requested) do
    finding.severity in [:error, :warning] and
      Enum.any?(finding.trip_ids, &MapSet.member?(requested, &1))
  end

  defp problem_severity_rank({%{severity: :error}, _day_type}), do: 0
  defp problem_severity_rank({_finding, _day_type}), do: 1

  defp trip_service_id!(organization_id, gtfs_version_id, trip_id) do
    query =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
            t.trip_id == ^trip_id,
        select: t.service_id
      )

    Repo.one(query) || Repo.rollback(:not_found)
  end

  # R9's old and new dates come from the same `Calendars.list_calendars/3` summaries
  # the day load derives day types from, so a calendar change and a day load cannot
  # disagree about a service's dates (CR-2). Inside a write transaction the version
  # row `FOR SHARE` this re-takes is already held by the caller.
  defp calendar_service_dates(organization_id, gtfs_version_id) do
    organization_id
    |> load_calendars!(gtfs_version_id)
    |> DayTypes.service_dates()
  end

  # The other trips of the block, in this organization and version only (CR-4). Only
  # the identity and the service are needed: the dates come from the calendars.
  defp block_companions(organization_id, gtfs_version_id, block_id, trip_id) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
          t.block_id == ^block_id and t.id != ^trip_id,
      select: %{id: t.id, service_id: t.service_id}
    )
    |> Repo.all()
  end

  # The UUIDs of `companions` that run on any date of `dates` - the changed trip's own
  # dates. This is R9's companion set: the single-trip check and the batch combination
  # projection both read it, each over its own projection of services and dates (AC-17).
  defp companions_on_dates(companions, service_dates, dates) do
    companions
    |> Enum.filter(&companion_on_dates?(&1.service_id, service_dates, dates))
    |> MapSet.new(& &1.id)
  end

  defp companion_on_dates?(service_id, service_dates, dates) do
    not MapSet.disjoint?(service_dates_for(service_dates, service_id), dates)
  end

  # A service the version does not hold has no dates, so it never shares one.
  defp service_dates_for(service_dates, service_id) do
    Map.get(service_dates, service_id, MapSet.new())
  end

  # -- Version-level unmatched records ---------------------------------------

  # R8's read path: the version's calendars and day types, every type 4/5 record
  # once, the trips those records name once, and the one `in_seat_context_for_rows/6`
  # context the day load and the pre-check build. The count of queries is fixed by
  # those kinds rather than by the number of records, which is what makes a
  # version-wide removal list possible on a feed with thousands of records.
  defp read_unmatched!(organization_id, gtfs_version_id) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    service_dates = DayTypes.service_dates(calendars)
    rows = Queries.all_in_seat_rows(organization_id, gtfs_version_id)

    trips =
      Queries.trip_rows(organization_id, gtfs_version_id, {:trip_ids, record_trip_ids(rows)})

    context =
      in_seat_context_for_rows(
        organization_id,
        gtfs_version_id,
        day_types,
        service_dates,
        trips,
        rows
      ).context

    Enum.flat_map(rows, &unmatched_record(&1, context))
  end

  defp record_trip_ids(rows) do
    rows
    |> Enum.flat_map(&[&1.from_trip_id, &1.to_trip_id])
    |> Enum.uniq()
  end

  # One state per record, and only the three reasons no block reaches survive. The
  # record's own fields travel with the reason, so a caller can confirm a removal
  # against the `updated_at` it read here (R7, INV-4).
  defp unmatched_record(row, context) do
    case InSeat.state(row, context) do
      {:stale, reason} when reason in @unmatched_reasons -> [Map.put(row, :reason, reason)]
      _state -> []
    end
  end

  # -- Candidate in-seat connections -----------------------------------------

  # R1's read path: the calendars and day types of the scoped version, the trips the
  # pairs name, and one stopless candidate row per pair. The candidate carries no stops
  # because the rule's stop comparison is about a stored record's own stops; the stops a
  # write stores come from the locked trip rows instead.
  defp read_connections!(organization_id, gtfs_version_id, pairs) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    service_dates = DayTypes.service_dates(calendars)

    trips =
      Queries.trip_rows(organization_id, gtfs_version_id, {:trip_ids, named_trip_ids(pairs)})

    evaluate_connections(
      organization_id,
      gtfs_version_id,
      day_types,
      service_dates,
      trips,
      pairs
    )
  end

  # One `InSeat.state/2` per pair over the shared context: `:matches` is `:ok` and
  # every other state is refused as it stands, so a refusal names the day types and the
  # intervening trip without a second evaluation anywhere.
  defp evaluate_connections(
         organization_id,
         gtfs_version_id,
         day_types,
         service_dates,
         trips,
         pairs
       ) do
    rows = Map.new(pairs, fn pair -> {pair, candidate_row(pair)} end)

    context =
      in_seat_context_for_rows(
        organization_id,
        gtfs_version_id,
        day_types,
        service_dates,
        trips,
        Map.values(rows)
      ).context

    Map.new(rows, fn {pair, row} -> {pair, connection_check(row, context)} end)
  end

  # A candidate is evaluated exactly as a stopless type 4 record would be, which is what
  # an unsaved choice describes. It has no id and is never turned into a finding.
  defp candidate_row({from_trip_id, to_trip_id}) do
    %{
      id: nil,
      from_trip_id: from_trip_id,
      to_trip_id: to_trip_id,
      transfer_type: 4,
      from_stop_id: nil,
      to_stop_id: nil
    }
  end

  defp connection_check(row, context) do
    case InSeat.state(row, context) do
      :matches -> :ok
      state -> {:refused, state}
    end
  end

  defp named_trip_ids(pairs) do
    pairs
    |> Enum.flat_map(fn {from_trip_id, to_trip_id} -> [from_trip_id, to_trip_id] end)
    |> Enum.uniq()
  end

  # The services R1 can evaluate a pair in: those of every day type both of the pair's
  # trips run in. Locking the named trips' block trips in exactly these services is the
  # set whose `block_id` the evaluation reads, so nothing it depends on can move under it
  # (INV-1). A pair whose trips are not both in hand, or never share a day type,
  # contributes nothing here and the rule decides that pair without an order.
  defp shared_service_ids(day_types, pairs, trips) do
    by_trip_id = Map.new(trips, &{&1.trip_id, &1})

    for {from_trip_id, to_trip_id} <- pairs,
        %{service_id: from_service} <- [Map.get(by_trip_id, from_trip_id)],
        %{service_id: to_service} <- [Map.get(by_trip_id, to_trip_id)],
        day_type <- day_types,
        from_service in day_type.service_ids,
        to_service in day_type.service_ids,
        service_id <- day_type.service_ids do
      service_id
    end
    |> Enum.uniq()
  end

  # -- Calendar combination projection --------------------------------------

  # One projection: the day types and service dates of its calendars, the trips it holds,
  # the checks of those trips and the in-seat context they are read with. The context is
  # built once per state, so the findings and the transfer states cannot disagree about it.
  defp projection_state(calendars, trips, transfers, min_layover_minutes) do
    projection_state(
      DayTypes.derive(calendars),
      DayTypes.service_dates(calendars),
      trips,
      transfers,
      min_layover_minutes
    )
  end

  defp projection_state(day_types, service_dates, trips, transfers, min_layover_minutes) do
    in_seat = projection_in_seat_context(day_types, service_dates, trips)

    %{
      day_types: day_types,
      service_dates: service_dates,
      trips: trips,
      transfers: transfers,
      min_layover_minutes: min_layover_minutes,
      in_seat: in_seat,
      findings: projection_findings(day_types, trips, transfers, in_seat, min_layover_minutes)
    }
  end

  # The same day types and dates with a different trip set: the after-clears state reads the
  # moved projection's calendars and asks the checks again.
  defp state_trips(%{day_types: day_types, service_dates: service_dates} = state, trips) do
    in_seat = projection_in_seat_context(day_types, service_dates, trips)

    %{
      state
      | trips: trips,
        in_seat: in_seat,
        findings:
          projection_findings(
            day_types,
            trips,
            state.transfers,
            in_seat,
            state.min_layover_minutes
          )
    }
  end

  # R9 over one projection: a block is kept only when every companion the trip runs with
  # in that projection also ran with it before it moved (AC-17, PM-4).
  defp clears_block?(trip, before, moved, destination_id) do
    companions_before =
      companions_on_dates(
        block_others(before.trips, trip),
        before.service_dates,
        service_dates_for(before.service_dates, trip.service_id)
      )

    companions_after =
      companions_on_dates(
        block_others(moved.trips, trip),
        moved.service_dates,
        service_dates_for(moved.service_dates, destination_id)
      )

    not MapSet.subset?(companions_after, companions_before)
  end

  # Every moved blocked trip is decided: a trip whose service moves takes its block with it
  # whether or not the review selection named it. The destination's own trips are not candidates -
  # AC-17 keeps destination block IDs assigned and the findings report what their gained dates add -
  # so a destination trip that would fail the same subset test is reported, never cleared.
  defp clear_candidate?(trip, moved_services, destination_id) do
    is_binary(trip.block_id) and trip.service_id != destination_id and
      MapSet.member?(moved_services, trip.service_id)
  end

  defp block_others(trips, trip) do
    Enum.filter(trips, &(&1.block_id == trip.block_id and &1.id != trip.id))
  end

  defp clear_decisions(before, moved, moved_services, destination_id) do
    before.trips
    |> Enum.filter(fn trip ->
      clear_candidate?(trip, moved_services, destination_id) and
        clears_block?(trip, before, moved, destination_id)
    end)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp clear_trips(trips, cleared_trip_ids) do
    cleared = MapSet.new(cleared_trip_ids)

    Enum.map(trips, fn trip ->
      if MapSet.member?(cleared, trip.id), do: %{trip | block_id: nil}, else: trip
    end)
  end

  # -- Per-trip change projection --------------------------------------------

  # A changed row replaces the input row with the same ID: the input rows the command does
  # not name stay as loaded, and a changed row the inputs do not hold is ignored. The input
  # order is kept, so reordering the changed rows returns an identical projection.
  defp replace_trips(trips, changed_trips) do
    changed_by_id = Map.new(changed_trips, &{&1.id, &1})
    Enum.map(trips, &Map.get(changed_by_id, &1.id, &1))
  end

  # R6's clear candidates: a changed row whose service differs from its input row's and
  # that names a block. An endpoint-only change and an unblocked move are not candidates.
  defp trip_change_clear_candidates(changed_trips, original_by_id) do
    Enum.filter(changed_trips, fn changed ->
      original = Map.get(original_by_id, changed.id)

      is_binary(changed.block_id) and is_map(original) and
        changed.service_id != original.service_id
    end)
  end

  # R6 over the one after-projection: a moved trip keeps its block only when the move
  # leaves its companion set unchanged - no companion it did not run with before (another
  # vehicle's work on its new dates) and no companion left behind (the block stayed on the
  # old calendar, so the trip would carry it alone). Every changed row is already part of
  # the projection, so a block whose trips move together keeps its ID, while deciding one
  # trip at a time would still hold its companions on the old service and clear it (PM-4).
  defp trip_change_clears_block?(changed, original, before, after_moves) do
    companions_before =
      companions_on_dates(
        block_others(before.trips, original),
        before.service_dates,
        service_dates_for(before.service_dates, original.service_id)
      )

    companions_after =
      companions_on_dates(
        block_others(after_moves.trips, changed),
        after_moves.service_dates,
        service_dates_for(after_moves.service_dates, changed.service_id)
      )

    not MapSet.equal?(companions_after, companions_before)
  end

  defp trip_change_clear_decisions(before, after_moves, changed_trips) do
    original_by_id = Map.new(before.trips, &{&1.id, &1})

    changed_trips
    |> trip_change_clear_candidates(original_by_id)
    |> Enum.filter(fn changed ->
      original = Map.fetch!(original_by_id, changed.id)
      trip_change_clears_block?(changed, original, before, after_moves)
    end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Only the destination's dates change: a source calendar keeps its own definition after
  # its last trip moves, so its dates stay part of the version's day types (INV-2).
  defp move_calendars(calendars, destination_id, result_dates) do
    Enum.map(calendars, fn calendar ->
      if calendar.service_id == destination_id do
        %{calendar | active_dates: result_dates}
      else
        calendar
      end
    end)
  end

  defp move_trip(trip, moved_services, destination_id) do
    if MapSet.member?(moved_services, trip.service_id) do
      %{trip | service_id: destination_id}
    else
      trip
    end
  end

  defp transfer_states(before, after_state, transfers) do
    transfers
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn row ->
      %{
        id: row.id,
        before: InSeat.state(row, before.in_seat),
        after: InSeat.state(row, after_state.in_seat)
      }
    end)
  end

  defp projection_in_seat_context(day_types, service_dates, trips) do
    %{
      trips: Map.new(trips, &{&1.trip_id, &1}),
      service_dates: service_dates,
      day_types: day_types,
      sequences: projection_sequences(day_types, trips),
      trip_ids_by_uuid: Map.new(trips, &{&1.id, &1.trip_id})
    }
  end

  # `Checks.sequence/1` is the order the in-seat rule reads, keyed by day type and block ID
  # for `{day key, block}`. Every derived day type is handed over: the rule itself keeps
  # only the day types where both of a record's trips run.
  defp projection_sequences(day_types, trips) do
    block_ids =
      trips
      |> Enum.filter(&is_binary(&1.block_id))
      |> Enum.map(& &1.block_id)
      |> Enum.uniq()

    for day_type <- day_types,
        block_id <- block_ids,
        into: %{} do
      order =
        trips
        |> Enum.filter(&(&1.block_id == block_id and &1.service_id in day_type.service_ids))
        |> Checks.sequence()
        |> Enum.map(& &1.id)

      {{day_type.key, block_id}, order}
    end
  end

  # The day's checks, per day type, plus the in-seat findings of every distinct record. A
  # trip without a block is in no block's findings here; `cleared_trip_ids` reports its
  # unassignment.
  defp projection_findings(day_types, trips, transfers, in_seat_context, min_layover_minutes) do
    service_by_uuid = Map.new(trips, &{&1.id, &1.service_id})

    block_findings =
      Enum.flat_map(day_types, &day_type_findings(&1, trips, min_layover_minutes))

    in_seat_findings =
      transfers
      |> Enum.uniq_by(& &1.id)
      |> Enum.flat_map(fn row ->
        row
        |> InSeat.finding(InSeat.state(row, in_seat_context), in_seat_context)
        |> List.wrap()
        |> Enum.map(
          &with_day_type_context(&1, applicable_day_types(&1, day_types, service_by_uuid))
        )
      end)

    (block_findings ++ in_seat_findings)
    |> Enum.uniq_by(&finding_context_key/1)
    |> Enum.sort_by(&finding_context_key/1)
  end

  defp day_type_findings(day_type, trips, min_layover_minutes) do
    context = Context.layover_only(min_layover_minutes)

    day_type
    |> day_type_trips(trips)
    |> Enum.group_by(& &1.block_id)
    |> Enum.flat_map(fn {block_id, block_trips} ->
      block_id
      |> Checks.block_findings(Enum.sort_by(block_trips, & &1.trip_id), context)
      |> Enum.map(&with_day_type_context(&1, [day_type]))
    end)
  end

  defp day_type_trips(day_type, trips) do
    Enum.filter(trips, &(is_binary(&1.block_id) and &1.service_id in day_type.service_ids))
  end

  # The day types a finding applies to: the ones running every service its trips name, so
  # their dates are the dates all of those trips run.
  defp applicable_day_types(finding, day_types, service_by_uuid) do
    service_ids =
      finding.trip_ids
      |> Enum.flat_map(&service_of(&1, service_by_uuid))
      |> Enum.uniq()

    case service_ids do
      [] -> []
      service_ids -> Enum.filter(day_types, &runs_all?(&1, service_ids))
    end
  end

  defp runs_all?(day_type, service_ids) do
    Enum.all?(service_ids, &(&1 in day_type.service_ids))
  end

  # A finding naming a trip the projection does not hold has no service to look up.
  defp service_of(trip_id, service_by_uuid) do
    List.wrap(Map.get(service_by_uuid, trip_id))
  end

  defp with_day_type_context(finding, day_types) do
    Map.merge(finding, %{
      day_type_keys: Enum.map(day_types, & &1.key),
      dates: day_types |> Enum.flat_map(& &1.dates) |> Enum.uniq() |> Enum.sort(Date)
    })
  end

  defp finding_context_key(finding) do
    {finding.day_type_keys, Checks.finding_key(finding)}
  end

  # --- the planning context -------------------------------------------------

  # The one place a `Context` is built. It lives here rather than in the pure
  # module because it is the only function that needs both a version's settings
  # and the reads behind them, and every database call lives in `Blocking`,
  # `Blocking.Queries` and `Operations`.
  #
  # `trips` are the `Queries.trip_rows/3` rows the caller has already read for
  # its own purpose, and they carry the `shape_id` this needs. They are not read
  # again: a day load already holds them, and a mutation holds the locked rows it
  # will write. The services are taken from those trips, so the attribute rows
  # are scoped to the services the read actually covers, and a trip's distance is
  # measured only for a trip in hand.
  #
  # The cost is fixed: the four planning-input kinds, the garages, the vehicle
  # types and the fleet summary, then one shape query and one stop-path query. It
  # does not grow with the number of trips, routes, stops or shapes.
  #
  # The bang marks a read that exits rather than answering with a partial
  # context. A context missing an input would be indistinguishable from a version
  # that has none of them, and would plan against a default without saying so —
  # so the transaction is the caller's to roll back, and this must not return
  # `nil` fields and continue.
  defp build_context!(organization_id, gtfs_version_id, settings, trips) do
    service_ids = trips |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort()
    rows = Queries.planning_rows(organization_id, gtfs_version_id, service_ids)

    %Context{
      min_layover_minutes: settings.min_layover_minutes,
      max_block_minutes: settings.max_block_minutes,
      pull_out_buffer_minutes: settings.pull_out_buffer_minutes,
      interlining: settings.interlining,
      default_garage_id: settings.default_garage_id,
      deadhead_speed_kmh: settings.deadhead_speed_kmh,
      deadhead_circuity: settings.deadhead_circuity,
      max_piece_minutes: settings.max_piece_minutes,
      garages: Operations.planning_garages(organization_id),
      vehicle_types: Operations.planning_vehicle_types(organization_id),
      route_settings: Map.new(rows.route_settings, &route_setting/1),
      attributes: Map.new(rows.attributes, &attribute/1),
      entered_minutes: entered_minutes(rows.deadhead),
      relief_stop_ids: MapSet.new(rows.relief, & &1.stop_id),
      fleet: fleet_buckets(Operations.fleet_summary(organization_id)),
      trip_km: build_trip_km(organization_id, gtfs_version_id, trips)
    }
  end

  # Both keys are always present, `nil` included. `Context.resolve_block/3` distinguishes
  # a route with no home garage from a route with no row at all, and a map that omitted
  # the `nil` keys could not say which one it was.
  defp route_setting(row) do
    {row.route_id,
     %{garage_id: row.garage_id, required_vehicle_type_id: row.required_vehicle_type_id}}
  end

  defp attribute(row) do
    {{row.service_id, row.block_id},
     %{garage_id: row.garage_id, vehicle_type_id: row.vehicle_type_id}}
  end

  # The stored refs are decoded here, and only here. `Context.entered_minutes` is
  # keyed by `{ref, ref}` tuples, so keying it with the stored `"stop:S1"` strings
  # would make every `DeadheadTimes.lookup/5` miss and silently degrade every
  # entered driving time to an estimate — no error, just quietly wrong numbers.
  # A row whose ref decodes to nothing (a hand-edited or corrupt row) is dropped
  # for the same reason: it cannot answer a lookup as a string either.
  defp entered_minutes(rows) do
    for %{from_ref: from_ref, to_ref: to_ref, minutes: minutes} <- rows,
        {:ok, decoded_from} <- [DeadheadTimes.decode_ref(from_ref)],
        {:ok, decoded_to} <- [DeadheadTimes.decode_ref(to_ref)],
        into: %{} do
      {{decoded_from, decoded_to}, minutes}
    end
  end

  # `fleet_summary/1` answers `%{garage: %Garage{} | nil, vehicle_type: %VehicleType{} | nil,
  # count: n}` for the settings pages. The context keeps only the two IDs and the
  # count, so a fleet bucket cannot drag a garage's correctable public ID or an
  # unrelated column into a fingerprint.
  defp fleet_buckets(buckets) do
    Enum.map(buckets, fn bucket ->
      %{
        garage_id: id_of(bucket.garage),
        vehicle_type_id: id_of(bucket.vehicle_type),
        count: bucket.count
      }
    end)
  end

  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id

  # A trip's distance is its shape's length when it names one, and its own stop
  # path when it does not. Each distinct shape is measured once and shared
  # by every trip naming it, and the two reads are asked for separately so the
  # cost is two queries however many trips the day has.
  defp build_trip_km(organization_id, gtfs_version_id, trips) do
    {shaped, shapeless} = Enum.split_with(trips, &is_binary(&1.shape_id))

    shape_km =
      organization_id
      |> Queries.shape_points(
        gtfs_version_id,
        shaped |> Enum.map(& &1.shape_id) |> Enum.uniq()
      )
      |> Map.new(fn {shape_id, points} -> {shape_id, Distance.path_km(points)} end)

    stop_paths =
      case Enum.map(shapeless, & &1.trip_id) do
        [] -> %{}
        trip_ids -> Queries.stop_paths(organization_id, gtfs_version_id, trip_ids)
      end

    Map.new(trips, &{&1.id, measured_trip(&1, shape_km, stop_paths)})
  end

  # A trip that names a shape is a shaped trip, and a shape the version does not
  # describe measures zero — the same answer `Distance.path_km/1` gives
  # a path of fewer than two points. It is deliberately not re-measured from its
  # stops: a second measurement for the same trip would need another query and
  # would report a number the feed never supplied. Such a shape is a malformed
  # feed, and a malformed feed understates that one trip's kilometres.
  #
  # A shapeless trip with no walkable stop path — every stop without a coordinate
  # of its own or of its parent's — is the same zero, and is marked `:path` so a
  # reader can see the distance was not measured from a shape.
  defp measured_trip(trip, shape_km, stop_paths) do
    case trip.shape_id do
      nil -> {Distance.path_km(Map.get(stop_paths, trip.trip_id, [])), :path}
      shape_id -> {Map.get(shape_km, shape_id, 0.0), :shape}
    end
  end

  # The read the day load makes and the pure assembly it hands the result to. Only
  # the in-seat context is read, and it is read once for the whole day: the
  # per-block assembly, the figures and the counts are computed from the trips
  # and the context alone, which is what lets `preview_day/2` re-run them over a
  # plan without touching the database.
  defp assemble(organization_id, gtfs_version_id, day_types, service_dates, trips, context) do
    in_seat =
      in_seat_context(
        organization_id,
        gtfs_version_id,
        day_types,
        service_dates,
        trips
      )

    Map.put(day_assemble(trips, context, in_seat), :in_seat_source, in_seat)
  end

  defp day_assemble(trips, context, in_seat) do
    {pool_trips, blocked_trips} = Enum.split_with(trips, &is_nil(&1.block_id))

    states = Enum.map(in_seat.rows, &{&1, InSeat.state(&1, in_seat.context)})

    in_seat_findings =
      states
      |> Enum.map(fn {row, state} -> InSeat.finding(row, state, in_seat.context) end)
      |> Enum.reject(&is_nil/1)

    in_seat_by_block =
      in_seat_findings
      |> Enum.filter(&is_binary(&1.block_id))
      |> Enum.group_by(& &1.block_id)

    blocks =
      blocked_trips
      |> Enum.group_by(& &1.block_id)
      |> Enum.map(fn {block_id, block_trips} ->
        build_block(
          block_id,
          block_trips,
          context,
          Map.get(in_seat_by_block, block_id, [])
        )
      end)
      |> Enum.sort_by(&Summary.natural_key(&1.summary.block_id))

    pool = order_pool(pool_trips)

    # One span per block, used for both the fleet rows and the peak, so the
    # two can never be counted over different intervals.
    spans = fleet_spans(blocks)
    fleet_rows = Fleet.rows(spans, context.fleet)

    findings =
      (Enum.flat_map(blocks, & &1.findings) ++
         pool_notices(pool_trips, context) ++ in_seat_findings)
      |> Enum.uniq_by(&Checks.finding_key/1)
      |> Kernel.++(fleet_shortfalls(fleet_rows))

    summaries = Enum.map(blocks, & &1.summary)
    peak = Fleet.peak(spans)

    %{
      blocks: blocks,
      pool: pool,
      unplottable: Enum.sort_by(Enum.reject(trips, & &1.plottable?), & &1.trip_id),
      findings: findings,
      figures: figures(blocks, trips, context, findings),
      fleet: fleet_rows,
      longest_stretch: longest_stretch(blocks),
      estimated_pairs: estimated_pairs(blocks),
      in_seat: in_seat_entries(states, trips),
      counts: %{
        blocks: length(blocks),
        trips: length(trips),
        unassigned: length(pool_trips),
        problems: Enum.count(findings, &(&1.severity in [:error, :warning])),
        notices: Enum.count(findings, &(&1.severity == :notice))
      },
      peak: %{
        count: peak.count,
        at_secs: peak.at_secs,
        excluded_unassigned: length(pool_trips),
        excluded_frequency: Enum.count(trips, & &1.frequency?)
      },
      bins: Summary.bins(summaries, @bin_secs),
      axis: axis(trips)
    }
  end

  # The day's platform spans, one per block that has one, each carrying the
  # garage and type the block resolved to. A block with no plottable trip
  # has no platform span at all and is not a vehicle anyone has to account for, so
  # it is left out rather than counted as a zero-length one.
  defp fleet_spans(blocks) do
    for block <- blocks, span = platform_span(block.movements), span != nil do
      Map.merge(span, %{
        garage_id: block.resolution.garage_id,
        vehicle_type_id: block.resolution.vehicle_type_id
      })
    end
  end

  defp platform_span(%{platform_start_secs: start, platform_end_secs: finish})
       when is_integer(start) and is_integer(finish),
       do: %{start_secs: start, end_secs: finish}

  defp platform_span(_movements), do: nil

  # A fleet row short of its listing is a page-level error with no block: the
  # demand is the garage's whole and the listing is the garage's whole, so naming
  # one block would misattribute it. `trip_ids` is empty for the same reason, and
  # the finding is unique by its row rather than by `finding_key/1` — two garages
  # short at once are two different problems with one key between them.
  defp fleet_shortfalls(fleet_rows) do
    for %{status: :short} = row <- fleet_rows do
      %{
        code: :fleet_shortfall,
        severity: :error,
        block_id: nil,
        trip_ids: [],
        transfer_id: nil,
        detail: Map.take(row, [:garage_id, :vehicle_type_id, :needed, :listed, :at_secs])
      }
    end
  end

  # The seconds and kilometres are the sums of the blocks'
  # movements rather than a second derivation, so a figure and the block it came
  # from can never disagree. `riders` is a share of platform time and is 0 with no
  # platform time rather than a division by zero.
  defp figures(blocks, trips, context, findings) do
    movements = Enum.map(blocks, & &1.movements)

    platform_secs =
      blocks
      |> Enum.map(&platform_length(platform_span(&1.movements)))
      |> Enum.sum()

    service_secs = Enum.sum(Enum.map(movements, & &1.service_secs))

    %{
      vehicles: length(blocks),
      minimum: LowerBound.compute(trips, context.min_layover_minutes),
      platform_secs: platform_secs,
      service_secs: service_secs,
      layover_secs: Enum.sum(Enum.map(movements, & &1.layover_secs)),
      drive_secs: Enum.sum(Enum.map(movements, & &1.drive_secs)),
      service_km: round_km(Enum.sum(Enum.map(movements, & &1.service_km))),
      deadhead_km: round_km(Enum.sum(Enum.map(movements, & &1.deadhead_km))),
      riders: riders(service_secs, platform_secs),
      problems: Enum.count(findings, &(&1.severity in [:error, :warning]))
    }
  end

  defp riders(_service_secs, 0), do: 0
  defp riders(service_secs, platform_secs), do: round(service_secs / platform_secs * 100)

  # `Enum.sum/1` over a day with no block is the integer `0`, which `Float.round/2`
  # refuses, so a kilometre figure is a float whatever the day holds.
  defp round_km(km), do: km |> Kernel.*(1.0) |> Float.round(3)

  # The longest stretch of the day and the block it belongs to. A tie keeps the
  # first block in the day's own (natural) block order, so two blocks with the
  # same longest stretch always name the same one.
  defp longest_stretch(blocks) do
    blocks
    |> Enum.flat_map(fn block ->
      Enum.map(block.stretches, &Map.put(&1, :block_id, block.summary.block_id))
    end)
    |> case do
      [] -> nil
      stretches -> Enum.max_by(stretches, & &1.secs)
    end
  end

  # The distinct directional pairs the day's drives are estimated rather than
  # entered, which is what the Driving times drawer counts as "N estimated".
  # A pull names its own refs; a gap names its trips, so the pair is read
  # off the same `sequence/1` the movements were built from and lines up by
  # construction. The pair is a `Context.ref/0` tuple, so `A → B` and `B → A` are
  # two pairs exactly as the `deadhead_times` rows are, and two blocks driving
  # the same pair are one.
  defp estimated_pairs(blocks) do
    blocks
    |> Enum.flat_map(&estimated_pair_refs/1)
    |> Enum.uniq()
    |> length()
  end

  defp estimated_pair_refs(%{trips: trips, movements: movements}) do
    pull_refs(movements, @estimated_sources) ++ gap_refs(trips, movements, @estimated_sources)
  end

  # Every leg of the block, in the order the movements list them: the two pulls
  # and then each driving or unknown gap. The Driving times drawer lists all of
  # them, while the count above takes only the estimated ones.
  defp pair_refs(%{trips: trips, movements: movements}) do
    pull_refs(movements, @driven_sources) ++ gap_refs(trips, movements, @driven_sources)
  end

  # A pull names its own refs, so its pair is read off the movement itself.
  defp pull_refs(movements, sources) do
    movements.pull_out
    |> List.wrap()
    |> Kernel.++(List.wrap(movements.pull_back))
    |> Enum.filter(&(pull_source(&1) in sources))
    |> Enum.map(&{&1.from, &1.to})
  end

  defp pull_source(nil), do: :none
  defp pull_source(%{source: source}), do: source

  # A gap names its trips, so the pair is read off the same `sequence/1` the
  # movements were built from and lines up by construction. A layover carries no
  # source and is never a pair; a gap whose trip is not in this block cannot name
  # a stop and is dropped.
  defp gap_refs(trips, movements, sources) do
    by_id = Map.new(trips, &{&1.id, &1})

    movements.gaps
    |> Enum.filter(&(gap_source(&1) in sources))
    |> Enum.map(fn gap ->
      case {Map.get(by_id, gap.from_id), Map.get(by_id, gap.to_id)} do
        {%{last_stop: from_stop}, %{first_stop: to_stop}} -> stop_pair(from_stop, to_stop)
        _a_gap_whose_trip_is_not_here -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp gap_source(%{source: source}), do: source

  defp stop_pair(%{stop_id: from_stop_id}, %{stop_id: to_stop_id}),
    do: {{:stop, from_stop_id}, {:stop, to_stop_id}}

  defp stop_pair(_from, _to), do: nil

  defp platform_length(%{start_secs: start_secs, end_secs: end_secs}),
    do: end_secs - start_secs

  defp platform_length(_no_span), do: 0

  defp build_block(block_id, trips, context, in_seat_findings) do
    sequence = Checks.sequence(trips)
    resolution = Context.resolve_block(context, block_id, trips)
    movements = Movements.build(sequence, resolution, context)
    windows = Relief.windows(trips, movements, context)

    # The stretch search is over the marked locations, not over the trips, so a block with
    # no marked point has no windows and one stretch over its whole platform span.
    # That is still the honest answer for the day's longest stretch, so the limit
    # is passed whether or not one is set: `nil` means the display schedule, which
    # raises no `:too_long` finding of its own.
    limit_secs = if context.max_piece_minutes, do: context.max_piece_minutes * 60

    findings =
      (Checks.block_findings(block_id, trips, context) ++ in_seat_findings)
      |> Enum.uniq_by(&Checks.finding_key/1)

    %{
      summary:
        block_id
        |> Summary.block_summary(trips, findings, platform_span_tuple(movements))
        |> Map.merge(resolution_names(resolution, context)),
      trips: order_block_trips(trips),
      gaps: Checks.gaps(sequence),
      findings: findings,
      resolution: resolution,
      movements: movements,
      windows: windows,
      stretches: Relief.stretches(movements, windows, limit_secs)
    }
  end

  # The timeline's Garage · type column reads these three keys, so the names are
  # resolved here, off the one resolution every other consumer uses, and
  # not re-derived by the page. A garage or type the resolution names but the
  # context does not hold — a row deleted since the load — falls back to `nil`,
  # which the page prints as no garage rather than as a blank cell.
  defp resolution_names(resolution, context) do
    %{
      garage_name: name_of(context.garages, resolution.garage_id),
      type_name: name_of(context.vehicle_types, resolution.vehicle_type_id),
      conflict?: not is_nil(resolution.conflict)
    }
  end

  defp name_of(_records, nil), do: nil

  defp name_of(records, id) do
    case Map.get(records, id) do
      %{name: name} -> name
      _missing -> nil
    end
  end

  # `Summary.block_summary/4` takes the platform span as a pair so a `nil` span is
  # the three-arity form's own answer, the block's own trip span.
  defp platform_span_tuple(movements) do
    case platform_span(movements) do
      nil -> nil
      span -> {span.start_secs, span.end_secs}
    end
  end

  # One entry per named trip the day type holds, under that trip's UUID, in the
  # reading order of the records (AC-7). A record whose other trip runs elsewhere
  # is listed under the trip that is here; a record naming a trip the version does
  # not hold is listed under the trip that is.
  defp in_seat_entries(states, trips) do
    uuid_by_trip_id = Map.new(trips, &{&1.trip_id, &1.id})

    states
    |> Enum.flat_map(fn {row, state} ->
      entry = %{row: row, state: state}

      [row.from_trip_id, row.to_trip_id]
      |> Enum.uniq()
      |> Enum.flat_map(&named_entry(&1, entry, uuid_by_trip_id))
    end)
    |> Enum.reduce(%{}, fn {uuid, entry}, acc -> Map.update(acc, uuid, [entry], &[entry | &1]) end)
    |> Map.new(fn {uuid, entries} -> {uuid, Enum.reverse(entries)} end)
  end

  defp named_entry(trip_id, entry, uuid_by_trip_id) do
    case Map.fetch(uuid_by_trip_id, trip_id) do
      {:ok, uuid} -> [{uuid, entry}]
      :error -> []
    end
  end

  # The in-seat context of the given trips: the type 4/5 records naming any of
  # them, the trips those records name, and the orders R6 needs. One query per kind
  # answers whatever the number of trips or records; nothing is queried per record
  # or per block (AC-3). The day types are the caller's, so a caller can restrict
  # the evaluation to the day types it is responsible for (step 12). Every record
  # whose two trips are both blocked is evaluated, whether or not the two share one
  # block ID: only the rule can decide that a cross-block pair is not next.
  #
  # The rows the orders were read over travel with the context, so `preview_day/2`
  # can rebuild those orders over a moved trip without reading them again.
  defp in_seat_context(organization_id, gtfs_version_id, day_types, service_dates, trips) do
    rows =
      Queries.in_seat_rows(organization_id, gtfs_version_id, Enum.map(trips, & &1.trip_id))

    in_seat_context_for_rows(
      organization_id,
      gtfs_version_id,
      day_types,
      service_dates,
      trips,
      rows
    )
  end

  # R1's read and locked paths evaluate candidate rows they hold rather than stored
  # records, so they share this context builder with the day load and the block review:
  # one `InSeat.state/2` decides a pair the pre-check shows and a save writes (CR-2,
  # INV-2).
  defp in_seat_context_for_rows(
         organization_id,
         gtfs_version_id,
         day_types,
         service_dates,
         trips,
         rows
       ) do
    trips = named_trips(organization_id, gtfs_version_id, rows, trips)
    evaluated = both_service_day_types(day_types, rows, trips)
    block_rows = block_rows(organization_id, gtfs_version_id, evaluated, rows, trips)

    %{
      rows: rows,
      block_rows: block_rows,
      context: %{
        trips: trips,
        service_dates: service_dates,
        day_types: evaluated,
        sequences: sequences(evaluated, block_rows),
        trip_ids_by_uuid: Map.new(block_rows, &{&1.id, &1.trip_id})
      }
    }
  end

  # The trips a record names are read once for the whole set, and only those the
  # caller did not already hand over. A trip the version does not hold is simply
  # absent, which the rule reports as `:trip_missing`.
  defp named_trips(organization_id, gtfs_version_id, rows, trips) do
    trips = Map.new(trips, &{&1.trip_id, &1})

    missing =
      rows
      |> Enum.flat_map(&[&1.from_trip_id, &1.to_trip_id])
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(trips, &1))

    Enum.reduce(
      Queries.trip_rows(organization_id, gtfs_version_id, {:trip_ids, missing}),
      trips,
      &Map.put(&2, &1.trip_id, &1)
    )
  end

  # R6 evaluates every day type both of a record's trips run in, so the context is
  # every day type containing both services of a record whose two trips are
  # blocked. The two trips need not share one block ID: whether the second follows
  # the first in one block is exactly what the rule decides, and withholding the
  # day type here would suppress the check and report a cross-block pair as valid.
  # A pair with an unblocked trip has nothing to evaluate, because the rule reports
  # `:no_block` before it reaches the day types.
  defp both_service_day_types(day_types, rows, trips) do
    rows
    |> Enum.flat_map(fn row ->
      case blocked_trips(row, trips) do
        nil ->
          []

        {from, to} ->
          day_types
          |> DayTypes.containing(from.service_id)
          |> Enum.filter(&(to.service_id in &1.service_ids))
      end
    end)
    |> Enum.uniq_by(& &1.key)
  end

  # The two trips of a record when both are in hand and each names a block, and
  # `nil` otherwise: a missing trip or an unblocked pair has no order to read.
  defp blocked_trips(row, trips) do
    case Map.get(trips, row.from_trip_id) do
      %{block_id: block_id} = from when is_binary(block_id) ->
        case Map.get(trips, row.to_trip_id) do
          %{block_id: to_block_id} = to when is_binary(to_block_id) -> {from, to}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The trips of both blocks the admitted records name, within the evaluated day
  # types' services: the rows R6 orders. Both block IDs are read so every evaluated
  # `{day key, block}` pair has its order, including the block of a cross-block
  # pair's second trip. Filtering by the services rather than by the dates and
  # collecting the IDs first keeps this one query.
  defp block_rows(organization_id, gtfs_version_id, day_types, rows, trips) do
    block_ids =
      rows
      |> Enum.flat_map(fn row ->
        case blocked_trips(row, trips) do
          nil -> []
          {from, to} -> [from.block_id, to.block_id]
        end
      end)
      |> Enum.uniq()

    service_ids = day_types |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()

    Queries.trip_rows(organization_id, gtfs_version_id, {:blocks, block_ids, service_ids})
  end

  # `Checks.sequence/1` is the same order the rule reads, keyed by day type and
  # block ID for `{day key, block}`.
  defp sequences(day_types, block_rows) do
    block_ids = block_rows |> Enum.map(& &1.block_id) |> Enum.uniq()

    for day_type <- day_types,
        block_id <- block_ids,
        into: %{} do
      order =
        block_rows
        |> Enum.filter(&(&1.block_id == block_id and &1.service_id in day_type.service_ids))
        |> Checks.sequence()
        |> Enum.map(& &1.id)

      {{day_type.key, block_id}, order}
    end
  end

  # A block lists its trips in service order first, then the trips the sequence
  # leaves out (frequency-based and unplottable) by natural trip ID.
  defp order_block_trips(trips) do
    sequence = Checks.sequence(trips)
    sequenced = MapSet.new(sequence, & &1.id)

    rest =
      trips
      |> Enum.reject(&MapSet.member?(sequenced, &1.id))
      |> Enum.sort_by(& &1.trip_id)

    sequence ++ rest
  end

  # The pool lists its plottable trips by first departure and the untimed ones
  # last, so what can be assigned to a block is read top down.
  defp order_pool(pool_trips) do
    {plottable, untimed} = Enum.split_with(pool_trips, & &1.plottable?)

    Enum.sort_by(plottable, & &1.first_departure) ++ Enum.sort_by(untimed, & &1.trip_id)
  end

  defp pool_notices(pool_trips, context) do
    Enum.flat_map(pool_trips, &Checks.block_findings(nil, [&1], context))
  end

  # The axis covers every plottable trip of the day type, blocked or not, from the
  # floor hour of the earliest first departure to the ceiling hour of the latest
  # last arrival.
  defp axis(trips) do
    plottable = Enum.filter(trips, & &1.plottable?)

    case plottable do
      [] ->
        nil

      _ ->
        %{
          start_secs: floor_hour(plottable |> Enum.map(& &1.first_departure) |> Enum.min()),
          end_secs: ceil_hour(plottable |> Enum.map(& &1.last_arrival) |> Enum.max())
        }
    end
  end

  defp floor_hour(secs), do: div(secs, @seconds_per_hour) * @seconds_per_hour

  defp ceil_hour(secs) do
    if rem(secs, @seconds_per_hour) == 0 do
      secs
    else
      floor_hour(secs) + @seconds_per_hour
    end
  end

  # -- Block commands ---------------------------------------------------------

  # Shape validation is the only part of a command that runs outside the
  # transaction, so a malformed request never opens one (Mutation).
  defp validate_command({:assign, ids, :new}) when is_list(ids) do
    case cast_trip_ids(ids) do
      {:ok, ids} -> {:ok, {:assign, ids, :new}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_command({:assign, ids, target}) when is_list(ids) and is_binary(target) do
    with {:ok, ids} <- cast_trip_ids(ids),
         {:ok, target} <- validate_block_id(target) do
      {:ok, {:assign, ids, target}}
    end
  end

  defp validate_command({:unassign, ids}) when is_list(ids) do
    case cast_trip_ids(ids) do
      {:ok, ids} -> {:ok, {:unassign, ids}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_command({:rename, from, target}) when is_binary(from) and is_binary(target) do
    with {:ok, from} <- validate_block_id(from),
         {:ok, target} <- validate_block_id(target),
         :ok <- reject_same_block_id(from, target) do
      {:ok, {:rename, from, target}}
    end
  end

  defp validate_command({:merge, from, target}) when is_binary(from) and is_binary(target) do
    with {:ok, from} <- validate_block_id(from),
         {:ok, target} <- validate_block_id(target),
         :ok <- reject_same_block_id(from, target) do
      {:ok, {:merge, from, target}}
    end
  end

  defp validate_command(_command), do: {:error, :invalid_command}

  # Renaming a block onto itself or merging a block into itself is not a command
  # (Mutation). Both IDs are trimmed first, so `{:rename, " 101 ", "101"}` is
  # rejected like `{:rename, "101", "101"}`.
  defp reject_same_block_id(id, id), do: {:error, :invalid_command}
  defp reject_same_block_id(_from, _target), do: :ok

  defp cast_trip_ids([]), do: {:error, :invalid_command}

  defp cast_trip_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, cast} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | cast]}}
        :error -> {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, cast} -> {:ok, cast |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_block_id(block_id) do
    trimmed = String.trim(block_id)

    # varchar(255) counts code points, not graphemes.
    if trimmed == "" or length(String.codepoints(trimmed)) > 255 do
      {:error, :invalid_block_id}
    else
      {:ok, trimmed}
    end
  end

  # Mutation steps 1-10: everything the command decides happens under the version's
  # blocking lock and the locked trip rows, and every refusal rolls the transaction
  # back so nothing partial commits.
  defp apply_command!(day_type_key, command, %AuditContext{} = audit, confirmation) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    calendars = load_calendars!(organization_id, version_id)
    day_types = DayTypes.derive(calendars)
    day_type = resolve_day_type!(day_types, day_type_key)
    service_dates = DayTypes.service_dates(calendars)

    # A version with no day type has no date scope a command could apply to; the
    # caller gets the same recovery error as an unknown key and nothing falls back
    # to another day type (INV-6).
    if is_nil(day_type), do: Repo.rollback({:unknown_day_type, day_types})

    lock_blocking!(version_id)

    targets = load_targets!(audit, command, day_type)
    check_eligible!(command, targets)
    changed = expected_changes(command, targets)

    if changed == [] do
      no_change_result(command)
    else
      if length(changed) > @max_command_trips, do: Repo.rollback(:too_many_trips)

      affected = affected_day_types(day_types, changed)
      target = resolve_target!(command, affected, audit)
      {rows, changes} = lock_and_reread!(audit, changed, target, affected)

      if changes == [] do
        no_change_result(command)
      else
        review_and_write!(
          %{audit: audit, target: target, day_type: day_type, affected: affected, rows: rows},
          command,
          changes,
          service_dates,
          confirmation
        )
      end
    end
  end

  # Step 3: the listed trips within the organization and the version, or `:not_found`
  # for any that is missing, foreign or unpublished (AC-11, CR-4). Deduplicated IDs
  # make the row count the completeness test.
  defp load_targets!(audit, {:assign, ids, _target}, _day_type), do: scoped_targets!(audit, ids)
  defp load_targets!(audit, {:unassign, ids}, _day_type), do: scoped_targets!(audit, ids)

  # Step 3 for a rename or a merge: the targets are the selected day type's trips
  # carrying the source ID, and no trip of the day type carrying it is `:not_found`
  # (R2, R3, AC-13). A merge additionally requires the destination ID to be carried
  # by a trip of the selected day type; a merge into an ID only another day type
  # uses is `:not_found` too. One read answers both questions.
  defp load_targets!(audit, {:rename, from, _target}, day_type) do
    case day_type_block_trips(audit, day_type, [from]) do
      [] -> Repo.rollback(:not_found)
      targets -> targets
    end
  end

  defp load_targets!(audit, {:merge, from, target}, day_type) do
    rows = day_type_block_trips(audit, day_type, [from, target])
    targets = Enum.filter(rows, &(&1.block_id == from))

    if targets == [] or not Enum.any?(rows, &(&1.block_id == target)) do
      Repo.rollback(:not_found)
    end

    targets
  end

  defp day_type_block_trips(%AuditContext{} = audit, day_type, block_ids) do
    Queries.trip_rows(
      audit.organization_id,
      audit.gtfs_version_id,
      {:blocks, block_ids, day_type.service_ids}
    )
  end

  defp scoped_targets!(%AuditContext{} = audit, ids) do
    rows = Queries.trip_rows(audit.organization_id, audit.gtfs_version_id, {:uuids, ids})

    if length(rows) == length(ids), do: rows, else: Repo.rollback(:not_found)
  end

  # R10: only a non-frequency trip with usable endpoint times can be assigned; both
  # kinds can always be unassigned.
  defp check_eligible!({:assign, ids, _target}, targets) do
    ineligible =
      targets
      |> Enum.filter(&(&1.frequency? or not &1.plottable?))
      |> MapSet.new(& &1.id)

    case Enum.filter(ids, &MapSet.member?(ineligible, &1)) do
      [] -> :ok
      ids -> Repo.rollback({:ineligible, ids})
    end
  end

  defp check_eligible!({:unassign, _ids}, _targets), do: :ok

  # A rename or a merge moves every trip of the source block as it is, so a
  # frequency-based or unplottable trip is never ineligible and never dropped from
  # the block it moves with (AC-6, AC-13).
  defp check_eligible!({:rename, _from, _target}, _targets), do: :ok
  defp check_eligible!({:merge, _from, _target}, _targets), do: :ok

  # Step 4: a target that already carries the target ID is not a change. A `:new`
  # command resolves the fresh ID only after its affected services are known (R8),
  # and every target necessarily differs from an ID no trip on its own dates uses.
  defp expected_changes({:assign, _ids, target}, targets) when is_binary(target) do
    Enum.filter(targets, &(&1.block_id != target))
  end

  defp expected_changes({:assign, _ids, :new}, targets), do: targets

  defp expected_changes({:unassign, _ids}, targets) do
    Enum.filter(targets, &(not is_nil(&1.block_id)))
  end

  # The source ID and the destination ID differ (shape validation) and every target
  # carries the source ID, so every target is a change.
  defp expected_changes({:rename, _from, _target}, targets), do: targets
  defp expected_changes({:merge, _from, _target}, targets), do: targets

  # Step 5: every day type a changed trip runs in, in list order (R3).
  defp affected_day_types(day_types, changed) do
    changed
    |> Enum.flat_map(&DayTypes.containing(day_types, &1.service_id))
    |> Enum.uniq_by(& &1.key)
  end

  # R8: the smallest positive integer string no trip running on an affected date
  # uses. The used set comes from the affected day types' services, which is exactly
  # the set of trips sharing a date with a changed trip.
  defp resolve_target!({:assign, _ids, :new}, affected, %AuditContext{} = audit) do
    used = used_block_ids(affected, audit)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find(&(not MapSet.member?(used, Integer.to_string(&1))))
    |> Integer.to_string()
  end

  defp resolve_target!({:assign, _ids, target}, _affected, _audit), do: target
  defp resolve_target!({:unassign, _ids}, _affected, _audit), do: nil

  # AC-13: a rename may take an ID only when no other trip running on a renamed
  # trip's dates uses it, resolved under the lock. The targets carry the source ID
  # the command is leaving and the destination differs from it, so membership of
  # the destination in the affected services' used set is exactly "used by a trip
  # that is not a target". A destination only a disjoint day type uses is not in
  # that set and is accepted (R2, R8).
  defp resolve_target!({:rename, _from, target}, affected, %AuditContext{} = audit) do
    if MapSet.member?(used_block_ids(affected, audit), target), do: Repo.rollback(:block_id_taken)
    target
  end

  # A merge's destination is required to exist on the selected day type (step 3), so
  # it is never a fresh ID and needs no collision check: joining it is the point of
  # the command.
  defp resolve_target!({:merge, _from, target}, _affected, _audit), do: target

  defp used_block_ids(affected, %AuditContext{} = audit) do
    service_ids = affected |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()
    Queries.used_block_ids(audit.organization_id, audit.gtfs_version_id, service_ids)
  end

  # Step 6: one query locks every decision input — the changed trips and every trip
  # of a touched block on an affected date — in UUID order, and the rows are re-read
  # so the review and the fingerprint describe the locked state and not the pre-lock
  # read (INV-1). A trip another writer moved into the target before the lock is no
  # longer a change.
  defp lock_and_reread!(%AuditContext{} = audit, changed, target, affected) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    changed_ids = Enum.map(changed, & &1.id)

    touched =
      (Enum.map(changed, & &1.block_id) ++ [target]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    service_ids = affected |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()

    locked_ids =
      Queries.lock_trips!(organization_id, version_id, changed_ids, touched, service_ids)

    rows = Queries.trip_rows(organization_id, version_id, {:uuids, locked_ids})
    changed_id_set = MapSet.new(changed_ids)

    changes =
      rows
      |> Enum.filter(&(MapSet.member?(changed_id_set, &1.id) and &1.block_id != target))
      |> Enum.map(&%{trip: &1, from: &1.block_id, to: target})

    {rows, changes}
  end

  # Steps 7-9: the in-seat context over the locked rows, the review over the affected
  # day types, and the confirmation decision. A command that needs confirmation
  # returns it from inside the transaction without writing anything.
  defp review_and_write!(%{audit: audit} = locked, command, changes, service_dates, confirmation) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    in_seat =
      in_seat_context(organization_id, version_id, locked.affected, service_dates, locked.rows)

    review =
      Review.build(%{
        command: command,
        target: locked.target,
        selected_key: locked.day_type.key,
        affected: locked.affected,
        rows: locked.rows,
        changes: changes,
        in_seat: in_seat,
        service_dates: service_dates,
        context:
          Context.layover_only(get_settings(organization_id, version_id).min_layover_minutes)
      })

    cond do
      review.needs_confirmation? and is_nil(confirmation) ->
        {:needs_confirmation, review}

      not is_nil(confirmation) and confirmation != review.fingerprint ->
        Repo.rollback({:stale_review, review})

      true ->
        write_changes!(audit, command, locked.target, changes, review)
    end
  end

  # One `update_all` sets the block and the clock on the changed rows, the
  # rows that follow the moved block follow it, then one `"trip"` change log per
  # changed trip carries the Schedules snapshot shape, the shared operation ID and
  # the whole affected list. The snapshots are built from the pre-update
  # rows, so `before` and `after` differ only in the block ID, and an audit failure
  # rolls the whole command back. No transfer row is written.
  defp write_changes!(%AuditContext{} = audit, command, target, changes, review) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id
    changed_ids = changes |> Enum.map(& &1.trip.id) |> Enum.sort()
    trips = trip_structs(organization_id, version_id, changed_ids)
    snapshots = Schedules.trip_audit_snapshots(organization_id, version_id, trips)
    operation_id = Ecto.UUID.generate()

    {count, _} =
      Repo.update_all(
        from(t in Trip,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
              t.id in ^changed_ids
        ),
        set: [block_id: target, updated_at: DateTime.utc_now()]
      )

    if count != length(changed_ids), do: Repo.rollback(:busy)

    carry_attributes!(audit, command, target, changes)

    Enum.each(trips, &audit_change!(audit, &1, target, snapshots, operation_id, changed_ids))

    %{
      operation_id: operation_id,
      changed_trip_ids: changed_ids,
      block_id: target,
      review: review
    }
  end

  # A rename or a merge carries the source block's attribute rows to the
  # destination. `:assign` and `:unassign` change which trips carry an ID without
  # moving a block's attributes, so they leave every row untouched.
  defp carry_attributes!(%AuditContext{} = audit, command, target, changes) do
    case command do
      {kind, from, _to} when kind in [:rename, :merge] ->
        move_attribute_rows!(audit, from, target, moved_services(changes))

      _command ->
        :ok
    end
  end

  # Only the moved trips' own services are considered: a service none of the moved
  # trips runs on has no row this command could carry, and reading it would move a
  # row the operator never touched.
  defp moved_services(changes) do
    changes |> Enum.map(& &1.trip.service_id) |> Enum.uniq() |> Enum.sort()
  end

  # Each service's `(service, from)` row is copied to `(service, to)` when the
  # destination has no row of its own, and the source row is deleted only when no
  # trip of that service still carries `from` in the version. A rename that moves
  # every trip of a service moves its row; a split that leaves the service's other
  # trips on the source ID keeps that row and copies it; and a merge keeps the
  # destination's own row, because `on_conflict: :nothing` never overwrites it.
  defp move_attribute_rows!(%AuditContext{} = audit, from, target, services) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id
    now = DateTime.utc_now()

    rows =
      from(a in BlockAttribute,
        where:
          a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id and
            a.service_id in ^services and a.block_id == ^from,
        select: %{
          service_id: a.service_id,
          garage_id: a.garage_id,
          vehicle_type_id: a.vehicle_type_id
        }
      )
      |> Repo.all()

    Enum.each(rows, fn row ->
      copy_attribute_row!(organization_id, version_id, target, row, now)

      if not service_carries_block?(audit, row.service_id, from) do
        delete_attribute_row!(organization_id, version_id, row.service_id, from)
      end
    end)

    :ok
  end

  # The copy carries the source row's two stored values. The destination row is
  # never overwritten: a merge into a block that already has attributes keeps them,
  # and the write timestamp is the command's own.
  defp copy_attribute_row!(organization_id, version_id, target, row, now) do
    Repo.insert_all(
      BlockAttribute,
      [
        %{
          organization_id: organization_id,
          gtfs_version_id: version_id,
          service_id: row.service_id,
          block_id: target,
          garage_id: row.garage_id,
          vehicle_type_id: row.vehicle_type_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:organization_id, :gtfs_version_id, :service_id, :block_id]
    )
  end

  # A trip of the service still carrying the source ID anywhere in the version, on
  # any date, is what keeps the row: the command moves the selected day type's
  # trips, and a trip on a date it did not touch is untouched.
  defp service_carries_block?(%AuditContext{} = audit, service_id, block_id) do
    Repo.exists?(
      from(t in Trip,
        where:
          t.organization_id == ^audit.organization_id and
            t.gtfs_version_id == ^audit.gtfs_version_id and
            t.service_id == ^service_id and t.block_id == ^block_id
      )
    )
  end

  defp delete_attribute_row!(organization_id, version_id, service_id, block_id) do
    from(a in BlockAttribute,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id and
          a.service_id == ^service_id and a.block_id == ^block_id
    )
    |> Repo.delete_all()

    :ok
  end

  # One `"trip"` change log per changed trip, in the Schedules snapshot shape with the
  # command's or plan's operation ID, the whole affected list and *this* trip's own
  # destination. A block command sends every changed trip to one target; a plan
  # sends each move to its own, so the destination is a per-call argument rather than a
  # property of the caller. Any audit failure rolls the write back first and then leaves
  # as the returned `{:error, {:audit_failed, reason}}`: a returned `{:error, changeset}`
  # keeps the changeset and a database-rejected insert keeps the exception, so an audit
  # failure reaches the caller as a refusal and never as an exception raised out of the
  # transaction (AC-10).
  defp audit_change!(
         %AuditContext{} = audit,
         trip,
         destination,
         snapshots,
         operation_id,
         changed_ids
       ) do
    snapshot = Map.fetch!(snapshots, trip.id)

    case Audit.record_change_in_transaction(
           audit,
           :trip,
           %{trip | block_id: destination},
           "updated",
           %{
             before: snapshot,
             after: Map.put(snapshot, "block_id", destination),
             operation_id: operation_id,
             affected_trip_ids: changed_ids
           }
         ) do
      {:ok, _log} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      # A serialization failure or deadlock goes to the transaction retry instead.
      if retryable?(error),
        do: reraise(error, __STACKTRACE__),
        else: Repo.rollback({:audit_failed, error})
  end

  # The audit snapshot is built from the stored rows rather than the day read's trip
  # rows, because the Schedules shape carries the trip columns the read does not
  # load; the loaded structs still hold the pre-update block, which is the `before`
  # side of the audit.
  defp trip_structs(organization_id, version_id, ids) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.id in ^ids,
      order_by: t.trip_id
    )
    |> Repo.all()
  end

  # Nothing to change: no write, no audit and no review, because there is no command
  # effect to confirm.
  defp no_change_result(command) do
    %{
      operation_id: nil,
      changed_trip_ids: [],
      block_id: resolved_block_id(command),
      review: nil
    }
  end

  defp resolved_block_id({:assign, _ids, target}) when is_binary(target), do: target
  defp resolved_block_id({:rename, _from, target}), do: target
  defp resolved_block_id({:merge, _from, target}), do: target
  defp resolved_block_id(_command), do: nil

  # The two stored values, validated before the transaction opens: a blank is
  # "unset" and a value the schema cannot cast is a changeset error, so a malformed
  # value never reaches a lock. The schema's own cast is the only rule here.
  defp attribute_values(attrs) do
    changeset =
      BlockAttribute.changeset(%BlockAttribute{}, %{
        garage_id: value(attrs, :garage_id),
        vehicle_type_id: value(attrs, :vehicle_type_id)
      })

    changeset =
      Enum.reduce([:garage_id, :vehicle_type_id], changeset, fn field, acc ->
        case Ecto.Changeset.get_field(acc, field) do
          nil -> acc
          value -> check_uuid!(acc, field, value)
        end
      end)

    if changeset.valid? do
      {:ok,
       %{
         garage_id: Ecto.Changeset.get_field(changeset, :garage_id),
         vehicle_type_id: Ecto.Changeset.get_field(changeset, :vehicle_type_id)
       }}
    else
      {:error, changeset}
    end
  end

  # The attribute write takes the same prefix as a block command — the scoped
  # version `FOR SHARE` and its published check, the calendars and the day types
  # derived from them, `lock_blocking!/1` and then the block's own
  # trip rows `FOR UPDATE` in UUID order — and only then decides what to write, so
  # a confirmation is compared against the same locked state it reviewed.
  #
  # `run_write/2` wraps the closure's own return value, so every refusal leaves
  # here as a rollback and reaches the caller as `{:error, reason}` rather than as
  # a success carrying an error tuple.
  defp write_attributes!(day_type_key, block_id, values, %AuditContext{} = audit, confirmation) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    version = Versions.lock_for_input_write!(organization_id, version_id)

    if version.publication_status == @published_status do
      calendars = load_calendars!(organization_id, version_id)
      day_types = DayTypes.derive(calendars)
      day_type = resolve_day_type!(day_types, day_type_key)
      service_dates = DayTypes.service_dates(calendars)

      if is_nil(day_type), do: Repo.rollback({:unknown_day_type, day_types})

      lock_blocking!(version_id)

      services = attribute_services!(audit, day_type, block_id)
      affected = attribute_day_types(audit, day_types, services, block_id)
      check_attribute_owners!(organization_id, values)

      rows = lock_attribute_rows!(audit, block_id, affected)

      {before, after_context} =
        attribute_contexts(organization_id, version_id, rows, block_id, services, values)

      review =
        Review.build(%{
          command: {:attributes, block_id, values.garage_id, values.vehicle_type_id},
          target: nil,
          selected_key: day_type.key,
          affected: affected,
          rows: rows,
          changes: [],
          touched: [block_id],
          context: before,
          context_after: after_context,
          inputs_digest: Context.digest(before),
          in_seat: in_seat_context(organization_id, version_id, affected, service_dates, rows),
          service_dates: service_dates
        })

      cond do
        review.needs_confirmation? and is_nil(confirmation) ->
          {:needs_confirmation, review}

        not is_nil(confirmation) and confirmation != review.fingerprint ->
          Repo.rollback({:stale_review, review})

        true ->
          store_attributes!(organization_id, version_id, block_id, services, values)
          %{review: review}
      end
    else
      Repo.rollback(:not_found)
    end
  end

  # The row keys of the save: the services of the block's trips on the selected day
  # type, read inside the version's own scope. A block the day type does not run has
  # no row to write, and neither has a block of another organization or version.
  defp attribute_services!(%AuditContext{} = audit, day_type, block_id) do
    case day_type_block_trips(audit, day_type, [block_id]) do
      [] -> Repo.rollback(:not_found)
      trips -> trips |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort()
    end
  end

  # The day types the rows reach: every day type containing one of those services
  # and holding a trip of this block, in derived order. A day type that shares the
  # service but runs no trip of the block reads no row, so it is not affected and
  # the operator is not asked to confirm for a date the save cannot change.
  defp attribute_day_types(%AuditContext{} = audit, day_types, services, block_id) do
    candidates =
      services
      |> Enum.flat_map(&DayTypes.containing(day_types, &1))
      |> Enum.uniq_by(& &1.key)

    service_ids = candidates |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()

    held =
      audit.organization_id
      |> Queries.trip_rows(audit.gtfs_version_id, {:blocks, [block_id], service_ids})
      |> MapSet.new(& &1.service_id)

    Enum.filter(candidates, &holds_block?(&1, held))
  end

  # The day type holds a trip of this block when one of the trips carrying the
  # block ID runs in one of its services.
  defp holds_block?(day_type, held),
    do: Enum.any?(day_type.service_ids, &MapSet.member?(held, &1))

  # A garage or a vehicle type of another organization is `:not_found`, the same
  # answer an unknown value gives. Stored, it would resolve as nothing at every
  # consumer and the block would silently plan from its route or the default
  # garage instead of the one the operator chose.
  defp check_attribute_owners!(organization_id, values) do
    if owned_garage?(organization_id, values.garage_id) and
         owned_vehicle_type?(organization_id, values.vehicle_type_id) do
      :ok
    else
      Repo.rollback(:not_found)
    end
  end

  defp owned_garage?(_organization_id, nil), do: true

  defp owned_garage?(organization_id, garage_id) do
    not is_nil(Operations.get_garage(organization_id, garage_id))
  end

  defp owned_vehicle_type?(_organization_id, nil), do: true

  defp owned_vehicle_type?(organization_id, vehicle_type_id) do
    not is_nil(Operations.get_vehicle_type(organization_id, vehicle_type_id))
  end

  # The rows the review reads are the block's own trips on every affected service,
  # taken in UUID order after the blocking lock and re-read, so the review and its
  # fingerprint describe the locked state rather than the pre-lock read.
  defp lock_attribute_rows!(%AuditContext{} = audit, block_id, affected) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id
    service_ids = affected |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()

    organization_id
    |> Queries.lock_trips!(version_id, [], [block_id], service_ids)
    |> then(&Queries.trip_rows(organization_id, version_id, {:uuids, &1}))
  end

  # The planning context the review read and the one this save leaves behind. Only
  # the rows of the saved services differ: every other planning input is held stable
  # by the lock, and recomputing it would make the after context disagree with the
  # digest the confirmation matched.
  defp attribute_contexts(organization_id, version_id, rows, block_id, services, values) do
    before =
      build_context!(organization_id, version_id, get_settings(organization_id, version_id), rows)

    row = %{garage_id: values.garage_id, vehicle_type_id: values.vehicle_type_id}
    attributes = Enum.reduce(services, before.attributes, &Map.put(&2, {&1, block_id}, row))

    {before, %{before | attributes: attributes}}
  end

  # One row per service, replacing both value columns and the write timestamp: a
  # save that clears a garage and sets a type must not leave the earlier garage
  # behind, and a repeated save is the same row rather than a second one. The
  # scoping fields are set on the struct and never cast.
  #
  # A refused insert is a rollback rather than a raised constraint error: the
  # ownership check above already refused a value this organization does not own,
  # so what is left is a garage or a type deleted between that read and this write,
  # and the caller's answer to it is the changeset it already knows how to show.
  defp store_attributes!(organization_id, version_id, block_id, services, values) do
    Enum.each(services, fn service_id ->
      changeset =
        BlockAttribute.changeset(
          %BlockAttribute{
            organization_id: organization_id,
            gtfs_version_id: version_id,
            service_id: service_id,
            block_id: block_id
          },
          values
        )

      case Repo.insert(changeset,
             on_conflict: {:replace, @replace_attribute_columns},
             conflict_target: [:organization_id, :gtfs_version_id, :service_id, :block_id]
           ) do
        {:ok, _row} -> :ok
        {:error, refused} -> Repo.rollback(refused)
      end
    end)
  end

  # The configured transaction boundary is retried as a whole: a serialization
  # failure or a deadlock is transient, every other failure is reported or re-raised
  # unchanged, and three failed attempts report `:busy` without raising (AC-14). The
  # module wraps the closure's own return value, so a confirmed command reports
  # `{:needs_confirmation, review}` and every other result is a success.
  defp run_write(transaction, attempts \\ @write_attempts) do
    case run_write_transaction(transaction) do
      {:ok, {:needs_confirmation, review}} -> {:needs_confirmation, review}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> retry_write(reason, transaction, attempts)
    end
  end

  defp retry_write(reason, transaction, attempts) do
    cond do
      not retryable?(reason) -> {:error, reason}
      attempts > 1 -> run_write(transaction, attempts - 1)
      true -> {:error, :busy}
    end
  end

  defp run_write_transaction(transaction) do
    write_transaction_module().run(transaction)
  rescue
    error in Postgrex.Error ->
      if retryable?(error), do: {:error, error}, else: reraise(error, __STACKTRACE__)
  end

  defp write_transaction_module do
    Application.get_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransaction.Repo)
  end

  defp retryable?(%Postgrex.Error{postgres: %{code: code}}) when code in @retryable_codes,
    do: true

  defp retryable?(_error), do: false
end
