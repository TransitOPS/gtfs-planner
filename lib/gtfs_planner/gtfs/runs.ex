defmodule GtfsPlanner.Gtfs.Runs do
  @moduledoc """
  Scoped reads and writes for the Runs page.

  This module is the only reader and writer of `trip_runs` and of the five crew
  columns on `blocking_settings`; the page, the plan and the export reach them
  through `Gtfs` facade functions, so a crew rule has one home and a run
  assignment has one writer.

  The crew rules are the work rules a cut is judged against: how long an operator
  reports before a piece, how long a sign-off takes, how long a break may be and
  stay paid, and how long a spread may be. They are stored per published
  organization and version alongside spec 07's Block rules, on the same row, and
  each writer replaces only the columns it owns — a crew save cannot reset a
  minimum layover and a Block rules save cannot reset a crew rule (AC-1, FH-1).

  A version with no stored crew rules reads the researched defaults and writes
  nothing: a read never inserts a row.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Runs.{Day, Plan}
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @crew_defaults %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  # The five crew columns plus the write timestamp: an upsert that replaced more
  # than these would reset the Block rules spec 07 stores on the same row, and one
  # that replaced fewer would leave a previous save's value behind (AC-1, FH-1).
  @replace_crew_columns BlockingSetting.crew_fields() ++ [:updated_at]

  @published_status "published"

  @type crew :: %{
          report_pull_out_minutes: 0..30,
          report_relief_minutes: 0..15,
          sign_off_minutes: 0..15,
          paid_break_max_minutes: 0..90,
          max_spread_minutes: 240..1080
        }

  @type runs_day :: %{
          day: Blocking.day(),
          crew: crew(),
          assignments: %{Ecto.UUID.t() => String.t()},
          derived: Day.derived(),
          orphans: %{count: non_neg_integer()},
          relief_ready?: boolean(),
          fingerprint: String.t()
        }

  @doc """
  Loads one day type's runs: its assignments, its composed runs and figures, its
  crew rules, the fingerprint a later apply re-checks, and how many assignments
  belong to no live trip.

  The whole read is one transaction. `Blocking.load_day/3` opens its own, which
  inside this one becomes a savepoint — fine, and worth saying because it looks
  like a nesting mistake and is not.

  Two kinds of assignment are **orphaned**, and both are counted rather than
  silently dropped:

    * a row for a trip that is not a sequence trip of a block in this day type —
      the trip was moved to another service, or unblocked, since the row was
      written;
    * a row of this version under a day type key that no longer exists, which
      belongs to no current day type and so is counted on **every** day type's
      page. It would otherwise be invisible forever: no page reads its key, and
      the only way to find it is the count this returns.

  A run is only ever built from live rows, so an orphan cannot reach
  `derived.runs`, `derived.stats` or the figures. It raises one
  `:orphan_assignments` notice, and — because `Runs.Day.derive/4` counted its
  problems before this module saw them — the day's notice count is recounted
  rather than left one short.
  """
  @spec load_runs(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, runs_day()}
          | {:error, :not_found | {:unknown_day_type, [Blocking.DayTypes.day_type()]}}
  def load_runs(organization_id, gtfs_version_id, day_type_key) do
    Repo.transaction(fn ->
      case Blocking.load_day(organization_id, gtfs_version_id, day_type_key) do
        {:ok, day} -> build_runs_day(organization_id, gtfs_version_id, day)
        # Rolled back rather than returned: a transaction function that returns
        # an `{:error, _}` tuple is itself a rollback, and the caller would see
        # `{:error, :rollback}` instead of the reason.
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp build_runs_day(organization_id, gtfs_version_id, day) do
    key = day.day_type.key
    blocks = block_inputs(day)
    rows = trip_run_rows(organization_id, gtfs_version_id, key)
    sequence_ids = MapSet.new(Enum.flat_map(blocks, &Enum.map(&1.trips, fn trip -> trip.id end)))
    live = restrict(Map.new(rows, &{&1.trip_id, &1.run_id}), sequence_ids)
    crew = get_crew_settings(organization_id, gtfs_version_id)
    derived = Day.derive(blocks, live, day.context, crew)
    orphans = orphan_count(organization_id, gtfs_version_id, rows, sequence_ids, day.day_types)

    %{
      day: day,
      crew: crew,
      assignments: live,
      derived: report_orphans(derived, orphans),
      orphans: %{count: orphans},
      relief_ready?: relief_ready?(day.context),
      fingerprint:
        Plan.fingerprint(%{
          context: day.context,
          trips: Enum.flat_map(blocks, & &1.trips),
          assignments: live,
          crew: crew
        })
    }
  end

  # The day's own inputs, in the shape `Runs.Day.derive/4` and `Runs.Cutter` take.
  # `summary.block_id` is the block's own identifier: the trips carry a block
  # they were built with, and this is the one the day resolved them into.
  defp block_inputs(day) do
    Enum.map(day.blocks, fn block ->
      %{
        block_id: block.summary.block_id,
        trips: block.trips,
        movements: block.movements,
        windows: block.windows
      }
    end)
  end

  defp trip_run_rows(organization_id, gtfs_version_id, key) do
    from(row in TripRun,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
          row.day_type_key == ^key
    )
    |> Repo.all()
  end

  # A row whose trip is not a sequence trip of this day is an orphan, not an
  # assignment. Restricting here, once, means every later step — the runs, the
  # figures, the fingerprint — reads an already-clean map.
  defp restrict(assignments, sequence_ids) do
    for {trip_id, run_id} <- assignments,
        MapSet.member?(sequence_ids, trip_id),
        into: %{},
        do: {trip_id, run_id}
  end

  # This day type's own orphans, plus every row of the version under a key that is
  # no longer a day type. The two are disjoint — a stale-key row is not under this
  # key — so no row is counted twice.
  defp orphan_count(organization_id, gtfs_version_id, rows, sequence_ids, day_types) do
    keys = MapSet.new(Enum.map(day_types, & &1.key))

    mine = Enum.count(rows, &(not MapSet.member?(sequence_ids, &1.trip_id)))

    theirs =
      organization_id
      |> stale_keys(gtfs_version_id)
      |> Enum.count(&(not MapSet.member?(keys, &1)))

    mine + theirs
  end

  defp stale_keys(organization_id, gtfs_version_id) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id,
        select: row.day_type_key
      )
    )
  end

  # The day's problems were counted inside `Runs.Day.derive/4`, before this
  # module knew about the orphans, so appending a notice here would leave
  # `stats.problems.notices` one short of `derived.findings`. The count is
  # corrected here rather than by teaching `Day` about orphans, which it has no
  # way to see.
  defp report_orphans(derived, 0), do: derived

  defp report_orphans(derived, orphans) do
    findings =
      derived.findings ++
        [
          %{
            code: :orphan_assignments,
            severity: :notice,
            run_ids: [],
            block_id: nil,
            trip_ids: [],
            detail: %{count: orphans}
          }
        ]

    %{
      derived
      | findings: findings,
        stats: %{
          derived.stats
          | problems: %{derived.stats.problems | notices: derived.stats.problems.notices + 1}
        }
    }
  end

  # A cut can only be planned into a relief window, and a window needs both a
  # marked point and a piece limit to cut at. Neither alone is enough, so a page
  # that offers "suggest" on one of them would offer something the cut cannot do.
  defp relief_ready?(context) do
    MapSet.size(context.relief_stop_ids) > 0 and context.max_piece_minutes != nil
  end

  @doc """
  Returns the crew rules for an organization's GTFS version.

  A version with no stored row returns the researched defaults; the read never
  inserts one, so opening the Runs page cannot create a settings row as a side
  effect of looking at it.
  """
  @spec get_crew_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: crew()
  def get_crew_settings(organization_id, gtfs_version_id) do
    case Repo.one(crew_query(organization_id, gtfs_version_id)) do
      nil -> @crew_defaults
      stored -> stored
    end
  end

  @doc """
  Returns the changeset rendered by the crew rules form.

  `crew` is a value map from `get_crew_settings/2` — or any partial map, which is
  filled from the defaults — and `attrs` are the submitted parameters; an invalid
  value carries the field error.
  """
  @spec change_crew_settings(crew(), map()) :: Ecto.Changeset.t()
  def change_crew_settings(crew, attrs) do
    # The defaults fill in what the caller did not supply, so the merge runs the
    # other way round: merging the defaults over the given crew would replace every
    # value the caller read with a default and the form could never show a stored
    # value.
    values = @crew_defaults |> Map.merge(crew) |> Map.take(BlockingSetting.crew_fields())

    %BlockingSetting{}
    |> Ecto.Changeset.change(values)
    |> BlockingSetting.crew_changeset(attrs)
  end

  @doc """
  Stores the crew rules for one organization's published version.

  The save runs in one transaction whose first statement is the scoped version row
  `FOR SHARE` (`Versions.lock_for_input_write!/2`), so the rules a review loaded
  cannot change under a calendar combination that owns the version, and this save
  waits behind such an owner in turn. It then takes `Blocking.lock_blocking!/1`, so
  a crew save serializes with every other planning-input writer and cannot slip
  between a plan's review and its apply (INV-1, INV-7, rule 13).

  The upsert replaces only the five crew columns and the write timestamp. Its base
  carries the stored Block rules values, so a first save on a version with no row
  satisfies the columns spec 07 owns rather than inserting defaults over them.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is outside its range
  or blank, in which case nothing is written.
  """
  @spec update_crew_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, crew()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_crew_settings(organization_id, gtfs_version_id, attrs) do
    case Repo.transaction(fn -> write_crew_settings!(organization_id, gtfs_version_id, attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The version share lock is the first statement of the write transaction, before
  # the published check and the upsert, and `lock_blocking!/1` follows it and
  # nothing else, in INV-1's order, so this writer joins the same serialization
  # point as the block writers instead of taking a second runs lock.
  defp write_crew_settings!(organization_id, gtfs_version_id, attrs) do
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = Blocking.lock_blocking!(gtfs_version_id)

      # The stored row is the base rather than a bare struct, so the eight columns
      # this writer does not own are present and satisfy the insert of the version's
      # first row; the upsert then replaces only the crew columns, so writing a
      # crew rule cannot blank a stored layover, interlining rule or piece limit.
      stored = Blocking.get_settings(organization_id, gtfs_version_id)

      changeset =
        %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
        |> Ecto.Changeset.change(Map.take(stored, BlockingSetting.settings_fields()))
        |> BlockingSetting.crew_changeset(attrs)

      case Repo.insert(changeset,
             on_conflict: {:replace, @replace_crew_columns},
             conflict_target: [:organization_id, :gtfs_version_id]
           ) do
        {:ok, saved} -> {:ok, crew_values(saved)}
        # Nothing has been written yet, so the transaction commits this result and
        # still leaves the stored row exactly as the previous save left it.
        {:error, invalid} -> {:error, invalid}
      end
    else
      # The shared lock takes no publication stance, so the published requirement
      # stays here, exactly as `Blocking`'s own settings writer applies it.
      {:error, :not_found}
    end
  end

  # Only the five crew columns, in the shape `get_crew_settings/2` answers with, so
  # a caller never has to know the row also carries the Block rules.
  defp crew_values(setting) do
    Map.new(BlockingSetting.crew_fields(), &{&1, Map.fetch!(setting, &1)})
  end

  # Scoped by organization and version like every other read here, and selecting
  # only the crew columns: a caller cannot learn a Block rules value through the
  # crew reader, and the Block rules reader cannot learn a crew value.
  defp crew_query(organization_id, gtfs_version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{
        report_pull_out_minutes: s.report_pull_out_minutes,
        report_relief_minutes: s.report_relief_minutes,
        sign_off_minutes: s.sign_off_minutes,
        paid_break_max_minutes: s.paid_break_max_minutes,
        max_spread_minutes: s.max_spread_minutes
      }
    )
  end
end
