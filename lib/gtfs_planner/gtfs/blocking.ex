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

  `project_calendar_combination/2` is the pure batch producer a calendar combination
  review reads: it projects every proposed service-ID move and destination date change at
  once, decides which moved blocks must be cleared from that one projection, and reports
  the real before/after checks and in-seat states. `CalendarChange`/`Schedules` keep
  their single-trip R9 answer, and no calendar-side module evaluates blocks a second time
  (CR-2).

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

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking.{Checks, DayTypes, InSeat, Queries, Review, Summary}
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # The settings a version with no stored row reads (AC-1). The map is the single
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
  # some of them would leave a previous save's value behind on the same row (FH-17).
  @replace_columns BlockingSetting.settings_fields() ++ [:updated_at]

  @published_status "published"
  @seconds_per_hour 3600

  # The timeline chart and the Peak drawer bucket the day in 15-minute bins.
  @bin_secs 900

  # One command changes at most this many trips, the same bound the Schedules
  # series uses; the largest measured block holds 192 trips.
  @max_command_trips 500

  # The transaction boundary is retried as a whole three times, for a serialization
  # failure or a deadlock, before the command reports `:busy` (AC-14, INV-1).
  @write_attempts 3
  @retryable_codes [:serialization_failure, "40001", :deadlock_detected, "40P01"]

  @type block :: %{
          summary: Summary.block_summary(),
          trips: [Queries.trip_row()],
          gaps: [Checks.gap()],
          findings: [Checks.finding()]
        }

  @type in_seat_entry :: %{row: Queries.in_seat_row(), state: InSeat.state()}

  @type problem :: %{
          code: Checks.code(),
          block_id: String.t() | nil,
          day_type_keys: [String.t()],
          date_count: non_neg_integer()
        }

  @type day :: %{
          day_types: [DayTypes.day_type()],
          day_type: DayTypes.day_type() | nil,
          settings: settings(),
          routes: %{String.t() => Queries.route_info()},
          blocks: [block()],
          pool: [Queries.trip_row()],
          unplottable: [Queries.trip_row()],
          findings: [Checks.finding()],
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
          mixed_timezones?: boolean()
        }

  @type command ::
          {:assign, [Ecto.UUID.t()], String.t() | :new}
          | {:unassign, [Ecto.UUID.t()]}
          | {:rename, String.t(), String.t()}
          | {:merge, String.t(), String.t()}

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
    values = settings |> Map.merge(@defaults) |> Map.take(BlockingSetting.settings_fields())

    %BlockingSetting{}
    |> Ecto.Changeset.change(values)
    |> BlockingSetting.changeset(attrs)
  end

  @doc """
  Stores the eight Block rules settings for one organization's published version.

  The save runs in one transaction whose first statement is the scoped version row
  `FOR SHARE` (`Versions.lock_for_input_write!/2`), so the settings a review loaded
  cannot change under a calendar combination that owns the version, and this save
  waits behind such an owner in turn. It then takes `lock_blocking!/1`, so a settings
  save serializes with every other block writer and cannot slip between a plan's
  review and its apply (INV-1, INV-7, R12).

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is outside its AC-1
  range, names an interlining value that does not exist, or names a
  `default_garage_id` that is not a garage of this organization. One row is kept per
  organization and version, so a repeated save replaces every settings column of the
  same row rather than merging into it.
  """
  @spec update_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, BlockingSetting.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_settings(organization_id, gtfs_version_id, attrs) do
    case Repo.transaction(fn -> write_settings!(organization_id, gtfs_version_id, attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The version share lock is the first statement of the write transaction, before the
  # published check and the upsert, whether the save updates a stored row or inserts the
  # version's first one (INV-1). Nothing in this writer takes the version row `FOR UPDATE`,
  # so no caller upgrades the share lock, and the transaction makes the check and the write
  # one unit while returning the upsert's own result tuple.
  #
  # `lock_blocking!/1` follows the version lock and nothing else, in INV-1's order, so
  # this writer joins the same serialization point as the block writers. It is taken
  # before the garage lookup, which is a read of another table, and before the upsert's
  # row lock.
  defp write_settings!(organization_id, gtfs_version_id, attrs) do
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

  defp read_day(organization_id, gtfs_version_id, day_type_key) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    day_type = resolve_day_type!(day_types, day_type_key)
    trips = day_trips(organization_id, gtfs_version_id, day_type)
    settings = get_settings(organization_id, gtfs_version_id)

    day = %{
      day_types: day_types,
      day_type: day_type,
      settings: settings,
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
        settings.min_layover_minutes
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

  # One `{finding, day_type}` per check result. The pairs are collected and
  # deduplicated before the read, so a block shared by several requested trips is
  # checked once per day type and every pair's block rows come from one query: the
  # query count does not grow with the number of requested trips. Each pair is
  # checked over its own block's trips on its own day type, filtered from that read.
  defp block_problem_entries(organization_id, gtfs_version_id, day_types, trips, min_layover) do
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

      {Checks.block_findings(block_id, block_trips, min_layover), day_type}
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
      sequences: projection_sequences(day_types, trips)
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
    day_type
    |> day_type_trips(trips)
    |> Enum.group_by(& &1.block_id)
    |> Enum.flat_map(fn {block_id, block_trips} ->
      block_id
      |> Checks.block_findings(Enum.sort_by(block_trips, & &1.trip_id), min_layover_minutes)
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

  defp assemble(organization_id, gtfs_version_id, day_types, service_dates, trips, min_layover) do
    {pool_trips, blocked_trips} = Enum.split_with(trips, &is_nil(&1.block_id))

    in_seat =
      in_seat_context(
        organization_id,
        gtfs_version_id,
        day_types,
        service_dates,
        trips
      )

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
          min_layover,
          Map.get(in_seat_by_block, block_id, [])
        )
      end)
      |> Enum.sort_by(&Summary.natural_key(&1.summary.block_id))

    pool = order_pool(pool_trips)

    findings =
      (Enum.flat_map(blocks, & &1.findings) ++
         pool_notices(pool_trips, min_layover) ++ in_seat_findings)
      |> Enum.uniq_by(&Checks.finding_key/1)

    summaries = Enum.map(blocks, & &1.summary)
    peak = Summary.peak(summaries)

    %{
      blocks: blocks,
      pool: pool,
      unplottable: Enum.sort_by(Enum.reject(trips, & &1.plottable?), & &1.trip_id),
      findings: findings,
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

  defp build_block(block_id, trips, min_layover_minutes, in_seat_findings) do
    findings =
      (Checks.block_findings(block_id, trips, min_layover_minutes) ++ in_seat_findings)
      |> Enum.uniq_by(&Checks.finding_key/1)

    %{
      summary: Summary.block_summary(block_id, trips, findings),
      trips: order_block_trips(trips),
      gaps: Checks.gaps(Checks.sequence(trips)),
      findings: findings
    }
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
  defp in_seat_context(organization_id, gtfs_version_id, day_types, service_dates, trips) do
    rows =
      Queries.in_seat_rows(organization_id, gtfs_version_id, Enum.map(trips, & &1.trip_id))

    trips = named_trips(organization_id, gtfs_version_id, rows, trips)
    evaluated = both_service_day_types(day_types, rows, trips)
    block_rows = block_rows(organization_id, gtfs_version_id, evaluated, rows, trips)

    %{
      rows: rows,
      context: %{
        trips: trips,
        service_dates: service_dates,
        day_types: evaluated,
        sequences: sequences(evaluated, block_rows)
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

  defp pool_notices(pool_trips, min_layover_minutes) do
    Enum.flat_map(pool_trips, &Checks.block_findings(nil, [&1], min_layover_minutes))
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
        min_layover_minutes: get_settings(organization_id, version_id).min_layover_minutes
      })

    cond do
      review.needs_confirmation? and is_nil(confirmation) ->
        {:needs_confirmation, review}

      not is_nil(confirmation) and confirmation != review.fingerprint ->
        Repo.rollback({:stale_review, review})

      true ->
        write_changes!(audit, locked.target, changes, review)
    end
  end

  # Step 10: one `update_all` sets the block and the clock on the changed rows, then
  # one `"trip"` change log per changed trip carries the Schedules snapshot shape,
  # the shared operation ID and the whole affected list (INV-4). The snapshots are
  # built from the pre-update rows, so `before` and `after` differ only in the block
  # ID, and an audit failure rolls the write back. No transfer row is written (INV-3).
  defp write_changes!(%AuditContext{} = audit, target, changes, review) do
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

    Enum.each(trips, &audit_change!(audit, &1, target, snapshots, operation_id, changed_ids))

    %{
      operation_id: operation_id,
      changed_trip_ids: changed_ids,
      block_id: target,
      review: review
    }
  end

  # One `"trip"` change log per changed trip, in the Schedules snapshot shape with the
  # command's operation ID and the whole affected list (INV-4). Any audit failure rolls
  # the command back first and then leaves as the returned
  # `{:error, {:audit_failed, reason}}`: a returned `{:error, changeset}` keeps the
  # changeset and a database-rejected insert keeps the exception, so an audit failure
  # reaches the caller as a refusal and never as an exception raised out of the
  # transaction (AC-10).
  defp audit_change!(%AuditContext{} = audit, trip, target, snapshots, operation_id, changed_ids) do
    snapshot = Map.fetch!(snapshots, trip.id)

    case GtfsPlanner.Gtfs.record_change_in_transaction(
           audit,
           :trip,
           %{trip | block_id: target},
           "updated",
           %{
             before: snapshot,
             after: Map.put(snapshot, "block_id", target),
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
