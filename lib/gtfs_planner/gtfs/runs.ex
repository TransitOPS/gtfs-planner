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
  organization and version alongside the Block rules, on the same row, and
  each writer replaces only the columns it owns — a crew save cannot reset a
  minimum layover and a Block rules save cannot reset a crew rule.

  A version with no stored crew rules reads the researched defaults and writes
  nothing: a read never inserts a row.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Runs.{Cutter, Day, Numbering, Plan}
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
  # than these would reset the Block rules stored on the same row, and one that
  # replaced fewer would leave a previous save's value behind.
  @replace_crew_columns BlockingSetting.crew_fields() ++ [:updated_at]

  @published_status "published"

  # Rows per write statement. PostgreSQL caps a statement at 65535 bind
  # parameters and a plan is a whole day, so a single insert would fail on a
  # large one. 500 leaves the cap a long way off for any realistic day while
  # keeping the round trips few.
  @write_batch 500

  # What a day type with no runs answers: the zeros and the nil share
  # `Runs.Day.derive/4` gives when both counts are zero.
  @empty_derived_stats %{
    stats: %{by_type: %{straight: 0, split: 0}, straight_share: nil}
  }

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

  A version with no service dates has no day type at all, so there is no day to
  load and `day.day_type` is nil. That answers
  `{:error, {:unknown_day_type, []}}` — the same shape as an unrecognised day
  key, carrying an empty list, which is what tells a caller to say "no dates"
  rather than "choose one of these". Deriving anyway would raise on the nil day
  type, and a read that 500s on a version with no calendars is worse than one
  that says so.
  """
  @spec load_runs(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, runs_day()}
          | {:error, :not_found | {:unknown_day_type, [Blocking.DayTypes.day_type()]}}
  def load_runs(organization_id, gtfs_version_id, day_type_key) do
    Repo.transaction(fn ->
      case Blocking.load_day(organization_id, gtfs_version_id, day_type_key) do
        # A version with no service dates has no day type — `Blocking.load_day/3`
        # answers `{:ok, day}` with `day.day_type` nil and no trips. There is
        # then nothing to derive, and `build_runs_day/3` would raise on the nil
        # day type. It is the same condition as an unrecognised day key — this
        # version has no day of the name asked for — so it is reported through
        # the same error, carrying the day types the version really has. That
        # list is empty here, and the empty list is what tells a caller to say
        # "no dates" rather than "choose one of these". A read that 500s on a
        # version with no calendars is worse than one that says so.
        #
        # The day is a plain map, not a struct, so this matches on the key.
        {:ok, %{day_type: nil} = day} -> Repo.rollback({:unknown_day_type, day.day_types})
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
    blocks = candidate_block_inputs(day)
    sequence_ids = MapSet.new(Enum.flat_map(blocks, &Enum.map(&1.trips, fn trip -> trip.id end)))
    rows = day_type_rows(organization_id, gtfs_version_id, key)
    version_rows = version_rows(organization_id, gtfs_version_id)

    live =
      rows
      |> Enum.map(fn {_id, trip_id, run_id} -> {trip_id, run_id} end)
      |> Map.new()
      |> restrict(sequence_ids)

    crew = get_crew_settings(organization_id, gtfs_version_id)
    derived = Day.derive(blocks, live, day.context, crew)
    orphan_ids = orphan_row_ids(rows, version_rows, sequence_ids, day.day_types)
    orphans = length(orphan_ids)

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

  @doc """
  Returns one day's block inputs, in the shape `Runs.Day.derive/4` and
  `Runs.Cutter` take.

  `candidate_day` is a day-shaped map whose `:blocks` carry the block's own
  identifier, its sequence trips, its movements and its relief windows — the shape
  `Blocking.load_day/3` builds, which is why the conversion lives here rather than
  in every caller. `block.summary.block_id` is the block's own identifier: the
  trips carry a block they were built with, and this is the one the day resolved
  them into.

  A caller that composes a day itself — the TODS generator composes one from
  candidate blocks and a scope's rows — passes it here rather than rebuilding the
  input shape, so the derivation a candidate is read with is the derivation the
  page reads.
  """
  @spec candidate_block_inputs(%{blocks: [map()]}) :: [map()]
  def candidate_block_inputs(%{blocks: blocks}) do
    Enum.map(blocks, fn block ->
      %{
        block_id: block.summary.block_id,
        trips: block.trips,
        movements: block.movements,
        windows: block.windows
      }
    end)
  end

  # The day's own rows, as `{row_id, trip_id, run_id}`. Projecting rather than
  # loading whole rows keeps this to what the assignments, the orphan test and
  # the undo each need, and it is the projection `orphan_row_ids/4` takes.
  defp day_type_rows(organization_id, gtfs_version_id, key) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
            row.day_type_key == ^key,
        select: {row.id, row.trip_id, row.run_id},
        order_by: [asc: row.trip_id]
      )
    )
  end

  # Every row of the version, as `{row_id, day_type_key}` — enough to find the
  # rows whose key is no longer a day type, which is a question about the keys
  # held in memory rather than about anything the database knows.
  defp version_rows(organization_id, gtfs_version_id) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id,
        select: {row.id, row.day_type_key}
      )
    )
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

  # The rows `remove_orphans/3` deletes and `load_runs/3` counts: this day type's
  # own orphans, plus every row of the version under a key that is no longer a
  # day type. One definition, because a cleanup that counted a different set from
  # the read that offered it would either miss rows or delete live ones.
  #
  # The two are disjoint — a stale-key row is not under this day's key, and this
  # day's key is by construction a current one — so no row appears twice.
  #
  # Both callers pass the rows in rather than this querying, so the read path
  # pays for no extra query and the writer sees exactly the rows the read saw.
  defp orphan_row_ids(day_rows, version_rows, sequence_ids, day_types) do
    keys = MapSet.new(Enum.map(day_types, & &1.key))

    mine =
      for {row_id, trip_id, _run_id} <- day_rows,
          not MapSet.member?(sequence_ids, trip_id),
          do: row_id

    theirs =
      for {row_id, key} <- version_rows,
          not MapSet.member?(keys, key),
          do: row_id

    Enum.sort(mine ++ theirs)
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
  Writes manual run moves, checking every trip's expected run and returning an undo.

  A move is `%{trip_id:, from:, to:}` where `to` is a run ID, `nil` to unassign,
  or `:new` to create a run. Every `:new` in one call resolves to the **same**
  new run: an operator dragging three trips onto "new run" means one run, not
  three, and three calls to `next_run_id/1` would give three.

  The check is optimistic and per trip. A move names what the
  editor saw as that trip's current run, and the write is refused with
  `:stale_moves` if any of them differ — so one trip somebody else moved since
  the page loaded fails the whole call and writes nothing, rather than
  overwriting a colleague. This is what makes undo safe: undo is the same call
  with the moves reversed, so it is refused by the same rule.

  The lock order is the one every runs writer shares, in one transaction: the
  version's input-write lock (which also refuses an unpublished version), then
  the blocking lock, then the reads, then the writes. Rows are scoped by
  organization, version and day type key on every query, so a Weekday write
  cannot reach a Saturday row that happens to carry the same run ID.
  """
  @spec apply_moves(AuditContext.t(), String.t(), [map()]) ::
          {:ok,
           %{changed_trips: non_neg_integer(), new_run_id: String.t() | nil, undo: [Plan.move()]}}
          | {:error,
             :forbidden
             | :not_found
             | :stale_moves
             | {:invalid_trips, [Ecto.UUID.t()]}
             | {:invalid_run_id, term()}}
  def apply_moves(%AuditContext{} = audit, day_type_key, moves) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit)
      organization_id = audit.organization_id
      gtfs_version_id = audit.gtfs_version_id
      Versions.lock_for_input_write!(organization_id, gtfs_version_id)
      :ok = Blocking.lock_blocking!(gtfs_version_id)

      case Blocking.load_day(organization_id, gtfs_version_id, day_type_key) do
        {:ok, day} -> write_moves(organization_id, gtfs_version_id, day, moves)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A move is a plain map on the way in and on the way out, in the shape
  # `Plan.move/1` uses, so an undo is a `Plan.move/1` without conversion.

  defp write_moves(organization_id, gtfs_version_id, day, moves) do
    key = day.day_type.key

    sequence_ids =
      MapSet.new(Enum.flat_map(day.blocks, &Enum.map(&1.trips, fn trip -> trip.id end)))

    current = current_runs(organization_id, gtfs_version_id, key, moves)

    with :ok <- check_trips(moves, sequence_ids),
         :ok <- check_fresh(moves, current),
         {:ok, resolved, new_run_id} <-
           resolve_targets(moves, key, organization_id, gtfs_version_id) do
      persist(organization_id, gtfs_version_id, key, resolved, current, new_run_id)
    else
      # The checks answer `{:error, reason}` so the `with` can read as a
      # pipeline, but the rollback reason is the bare `reason`: rolling back
      # `{:error, reason}` would hand the caller `{:error, {:error, reason}}`.
      # The success path returns a bare map, because the transaction supplies
      # the `{:ok, _}`.
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # One query for the named trips rather than one per move: a page can drag a
  # whole block at once, and a query per trip would be a query per trip for no
  # reason.
  defp current_runs(organization_id, gtfs_version_id, key, moves) do
    trip_ids = moves |> Enum.map(& &1.trip_id) |> Enum.uniq()

    case trip_ids do
      [] ->
        %{}

      ids ->
        from(row in TripRun,
          where:
            row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
              row.day_type_key == ^key and row.trip_id in ^ids,
          select: {row.trip_id, row.run_id}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  # A move naming a trip that is not a sequence trip of this day type is refused
  # before any current run is read, and every offending trip is returned rather
  # than the first, so a page can mark all of them at once.
  defp check_trips(moves, sequence_ids) do
    case moves
         |> Enum.map(& &1.trip_id)
         |> Enum.uniq()
         |> Enum.reject(&MapSet.member?(sequence_ids, &1)) do
      [] -> :ok
      invalid -> {:error, {:invalid_trips, Enum.sort(invalid)}}
    end
  end

  # Rule 14's per-trip check. `from` is what the editor saw, so `nil` is a real
  # value here rather than "unset": a trip the editor believed was unassigned
  # must still be unassigned.
  defp check_fresh(moves, current) do
    stale? =
      Enum.any?(moves, &(Map.get(current, &1.trip_id) != &1.from))

    if stale?, do: {:error, :stale_moves}, else: :ok
  end

  # One `:new` for the whole call, numbered above every run the day type already
  # uses. Every trip that asked for a new run gets the same one: an operator
  # dragging three trips onto "new run" means one run, not three.
  defp resolve_targets(moves, key, organization_id, gtfs_version_id) do
    new_run_id =
      if Enum.any?(moves, &(&1.to == :new)) do
        organization_id
        |> run_ids_for(gtfs_version_id, key)
        |> Numbering.next_run_id()
      end

    resolved = Enum.map(moves, &%{&1 | to: if(&1.to == :new, do: new_run_id, else: &1.to)})

    case validate_run_ids(resolved) do
      :ok -> {:ok, resolved, new_run_id}
      {:error, _} = error -> error
    end
  end

  defp validate_run_ids(moves) do
    case Enum.find(moves, &(not (is_nil(&1.to) or Numbering.valid_run_id?(&1.to)))) do
      nil -> :ok
      %{to: bad} -> {:error, {:invalid_run_id, bad}}
    end
  end

  defp run_ids_for(organization_id, gtfs_version_id, key) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
            row.day_type_key == ^key,
        select: row.run_id,
        distinct: true
      )
    )
  end

  # Every move is written before any is, so a refusal above has written nothing.
  # An unassignment is a scoped delete rather than a row with a null run ID: the
  # table has a `run_id_format` check that `NULL` would not satisfy, and a row
  # with no run is not a row that says a trip is in no run.
  defp persist(organization_id, gtfs_version_id, key, moves, current, new_run_id) do
    now = DateTime.utc_now()

    assigns = Enum.filter(moves, & &1.to)
    unassigns = Enum.reject(moves, & &1.to)

    if assigns != [] do
      Repo.insert_all(
        TripRun,
        Enum.map(assigns, fn move ->
          %{
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id,
            day_type_key: key,
            trip_id: move.trip_id,
            run_id: move.to,
            inserted_at: now,
            updated_at: now
          }
        end),
        # A column list, not an index name. PostgreSQL's `ON CONFLICT (...)` takes
        # column names or expressions and resolves the unique index itself; the
        # truncated index name that `TripRun.changeset/2` needs for
        # `unique_constraint` has no use here, because this path does not have to
        # match a violation to a declaration.
        on_conflict: {:replace, [:run_id, :updated_at]},
        conflict_target: [:organization_id, :gtfs_version_id, :day_type_key, :trip_id]
      )
    end

    if unassigns != [] do
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
            row.day_type_key == ^key and row.trip_id in ^Enum.map(unassigns, & &1.trip_id)
      )
      |> Repo.delete_all()
    end

    changed = Enum.count(moves, &(Map.get(current, &1.trip_id) != &1.to))

    # A bare map, not `{:ok, map}`: the transaction function's return value is
    # what the transaction wraps.
    %{
      changed_trips: changed,
      new_run_id: new_run_id,
      undo: undo_for(moves, new_run_id)
    }
  end

  # The undo is the same call with the moves reversed, which is what lets it be
  # refused by `check_fresh/2` like any other write. A `:new` target is replaced
  # by the ID it resolved to, so undoing a create removes the run's rows rather
  # than trying to remove a run named `:new`.
  defp undo_for(moves, new_run_id) do
    moves
    |> Enum.map(fn move ->
      %{
        trip_id: move.trip_id,
        from: move.to,
        to: if(move.from == :new, do: new_run_id, else: move.from)
      }
    end)
    |> Enum.sort_by(& &1.trip_id)
  end

  @doc """
  Renames a run on one day type and returns an undo.

  Every row carrying `old_id` becomes a row carrying `new_id`, and nothing else
  moves. The returned `undo` is the reversed moves, so undoing a rename is
  `apply_moves/4` on it — the same optimistic per-trip rule that any
  other write obeys, which is what stops an undo from reverting somebody else's
  edit made in between.

  The new ID is checked before the transaction with `TripRun.change_run_id/1`,
  which is the same format `TripRun.changeset/2` checks a row against. Whether
  the ID is **already used in this day type** is a fact about the rows, so it is
  checked inside, under the same lock order as `apply_moves/4`: the version's
  input-write lock, then the blocking lock, then the reads, then the update.

  Existence is checked before uniqueness, so renaming a run that is not there
  answers `:unknown_run` even when the new ID is also taken — there is nothing
  to rename, and "this run does not exist" is the more useful answer.
  """
  @spec rename_run(AuditContext.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{undo: [Plan.move()]}}
          | {:error, :forbidden | :not_found | :unknown_run | Ecto.Changeset.t()}
  def rename_run(%AuditContext{} = audit, day_type_key, old_id, new_id) do
    case TripRun.change_run_id(%{run_id: new_id}) do
      changeset when not changeset.valid? ->
        # Before the transaction: a malformed ID is not a race, and refusing it
        # without taking a lock keeps a typo from blocking another writer.
        {:error, changeset}

      changeset ->
        Repo.transaction(fn ->
          Authorization.lock_editor!(audit)
          organization_id = audit.organization_id
          gtfs_version_id = audit.gtfs_version_id

          organization_id
          |> Versions.lock_for_input_write!(gtfs_version_id)
          |> refuse_unpublished!()

          :ok = Blocking.lock_blocking!(gtfs_version_id)

          rename_locked(organization_id, gtfs_version_id, day_type_key, old_id, changeset)
        end)
    end
  end

  # The other writers refuse an unpublished version through
  # `Blocking.load_day/3`; a rename reads no day, so it checks the locked row.
  defp refuse_unpublished!(%{publication_status: @published_status}), do: :ok
  defp refuse_unpublished!(_version), do: Repo.rollback(:not_found)

  defp rename_locked(organization_id, gtfs_version_id, day_type_key, old_id, changeset) do
    case run_rows(organization_id, gtfs_version_id, day_type_key, old_id) do
      [] ->
        Repo.rollback(:unknown_run)

      _old_rows ->
        case check_available(changeset, old_id, organization_id, gtfs_version_id, day_type_key) do
          {:ok, valid} -> do_rename(organization_id, gtfs_version_id, day_type_key, old_id, valid)
          {:error, invalid} -> Repo.rollback(invalid)
        end
    end
  end

  # The ID is free unless the day type already has rows under it. A run renamed
  # to its own ID is excluded: it is not a *different* run using that ID, and
  # refusing it with "already used in this day type" would be a confusing answer
  # to a rename that changes nothing.
  defp check_available(changeset, old_id, organization_id, gtfs_version_id, day_type_key) do
    requested = Ecto.Changeset.get_change(changeset, :run_id)

    taken? =
      organization_id
      |> run_ids_for(gtfs_version_id, day_type_key)
      |> Enum.any?(&(&1 == requested and &1 != old_id))

    if taken? do
      {:error, Ecto.Changeset.add_error(changeset, :run_id, "is already used in this day type")}
    else
      {:ok, changeset}
    end
  end

  defp do_rename(organization_id, gtfs_version_id, day_type_key, old_id, changeset) do
    new_id = Ecto.Changeset.get_change(changeset, :run_id)

    from(row in TripRun,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
          row.day_type_key == ^day_type_key and row.run_id == ^old_id
    )
    |> Repo.update_all(set: [run_id: new_id, updated_at: DateTime.utc_now()])

    # The undo is read back rather than derived from `old_rows`, so it is exactly
    # the set of moves the update actually produced — which matters if the
    # rename was a no-op. A bare map, not `{:ok, map}`: the transaction
    # supplies the `{:ok, _}`.
    %{undo: rename_undo(organization_id, gtfs_version_id, day_type_key, new_id, old_id)}
  end

  defp rename_undo(organization_id, gtfs_version_id, day_type_key, new_id, old_id) do
    from(row in TripRun,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
          row.day_type_key == ^day_type_key and row.run_id == ^new_id,
      select: row.trip_id,
      order_by: [asc: row.trip_id]
    )
    |> Repo.all()
    # The map is built here rather than in the query's `select`: a literal in a
    # select is read as a field reference, so `from: new_id` would ask for a
    # column called `new_id`.
    |> Enum.map(&%{trip_id: &1, from: new_id, to: old_id})
  end

  defp run_rows(organization_id, gtfs_version_id, day_type_key, run_id) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
            row.day_type_key == ^day_type_key and row.run_id == ^run_id,
        select: row.trip_id,
        order_by: [asc: row.trip_id]
      )
    )
  end

  @doc """
  Deletes this day type's orphaned assignments and returns how many were deleted.

  The rows removed are **exactly** the ones `load_runs/3` counted — the same
  `orphan_row_ids/4`, fed the same rows. A cleanup that computed its own set
  would either miss rows the page told the planner about, or delete live ones,
  and neither failure would be visible in the count it returns.

  Two kinds are removed: a row whose trip is no longer a sequence trip of this
  day type, and a row under a day type key that no longer exists. The second is
  removed from whichever day type asks, which is what makes it findable at all —
  no page reads its key.

  Scoped to the organization and version, so another organization's orphans are
  untouched even when the trip UUIDs are the same shape. A second call
  finds nothing left and returns `{:ok, 0}`: removal is idempotent because it is
  defined by what is there, not by what happened to be there before.
  """
  @spec remove_orphans(AuditContext.t(), String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :forbidden | :not_found | {:unknown_day_type, list()}}
  def remove_orphans(%AuditContext{} = audit, day_type_key) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit)
      organization_id = audit.organization_id
      gtfs_version_id = audit.gtfs_version_id
      Versions.lock_for_input_write!(organization_id, gtfs_version_id)
      :ok = Blocking.lock_blocking!(gtfs_version_id)

      case Blocking.load_day(organization_id, gtfs_version_id, day_type_key) do
        {:ok, day} -> delete_orphans(organization_id, gtfs_version_id, day)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp delete_orphans(organization_id, gtfs_version_id, day) do
    sequence_ids =
      MapSet.new(Enum.flat_map(day.blocks, &Enum.map(&1.trips, fn trip -> trip.id end)))

    case orphan_row_ids(
           day_type_rows(organization_id, gtfs_version_id, day.day_type.key),
           version_rows(organization_id, gtfs_version_id),
           sequence_ids,
           day.day_types
         ) do
      # A count, not `:ok`: the `@spec` answers `{:ok, non_neg_integer()}`, and a
      # page showing "removed N" needs the N to be zero rather than missing.
      [] ->
        0

      ids ->
        # Deleted by primary key rather than by a repeat of the orphan test: the
        # rows were already selected and validated, and re-deriving the predicate
        # in SQL is a second chance to disagree with the count above.
        {count, _} = Repo.delete_all(from(row in TripRun, where: row.id in ^ids))
        count
    end
  end

  @doc """
  Suggests runs for a day type and returns a plan, writing nothing.

  The plan is what a planner is shown before deciding, and it carries three
  things they cannot compute themselves: the moves the suggestion would make, the
  figures the day would have afterwards, and the fingerprint the apply will
  re-check.

  **It takes no lock and writes no row** — not a `trip_runs` row, not a crew
  column, not a settings row. A suggestion is a read that happens to run the
  cutter, and the gate for it is that the table is byte-for-byte what it was
  before. That is also why it composes `load_runs/3` rather than re-reading:
  the plan's `before` figures, its fingerprint and the assignments it diffs
  against are then the same values the page already showed, by construction
  rather than by agreement between two implementations.

  The proposed assignments are the current ones **merged with** the cutter's
  output. `Cutter.run/5` returns only the assignments it made, so handing those
  to `Plan.build/1` as the whole proposal would read every existing run as a
  move to no run — a plan that unsets the day.

  `after` is the figures the day *would* have, computed by deriving the proposed
  assignments through the same path `load_runs/3` uses, orphan notice included.
  Skipping the notice would make `after` disagree with what an apply actually
  produces on a day that has orphans: the figures a planner is shown are the
  ones the apply will leave, not the ones the derivation alone gives.
  """
  @spec suggest_runs(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil, Cutter.scope()) ::
          {:ok, Plan.t()}
          | {:error, :not_found | {:unknown_day_type, [Blocking.DayTypes.day_type()]}}
  def suggest_runs(organization_id, gtfs_version_id, day_type_key, scope) do
    case load_runs(organization_id, gtfs_version_id, day_type_key) do
      {:ok, runs_day} -> {:ok, suggest_plan(runs_day, scope)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp suggest_plan(runs_day, scope) do
    %{day: day, crew: crew, assignments: current, derived: derived} = runs_day
    blocks = candidate_block_inputs(day)

    cut = Cutter.run(scope, blocks, current, day.context, crew)
    proposed = Map.merge(current, cut.assignments)

    preview =
      blocks
      |> Day.derive(proposed, day.context, crew)
      |> report_orphans(runs_day.orphans.count)

    # `after:` is a key, never a variable: `after` is a reserved word in Elixir,
    # and `Plan.build/1` binds it as `after_stats` for the same reason.
    Plan.build(%{
      day_type_key: day.day_type.key,
      scope: scope,
      current: current,
      proposed: proposed,
      before: derived.stats,
      after: preview.stats,
      preview: preview,
      fingerprint: runs_day.fingerprint
    })
  end

  @doc """
  Applies a runs plan: every move it names, or none, and an undo.

  The plan was built by `suggest_runs/4` against a day as it looked at preview
  time. This checks that it still does.

  **The fingerprint is recomputed inside the transaction, after the locks and
  before the first write.** Both halves of that sentence matter. After the
  locks, because the check and the write it guards must not be separable by
  another writer. Before the first write, because `updated_at` is in the covered
  set: a check run after a write would see the write's own effect and refuse a
  plan this call had just applied correctly.

  A mismatch rolls back with `:stale_plan` and writes nothing.
  The plan is **not** re-validated against its own `from` values beyond the trip
  check — the fingerprint already covers every assignment on the day type, so a
  stale plan is detected before the moves are read, and one mechanism is enough.

  Writes go in batches of 500 rows. PostgreSQL caps a statement at 65535 bind
  parameters and a plan is a whole day, so a single insert would fail on a large
  one; the batch size is chosen well under the cap. A `Postgrex.Error` from any
  batch — a run ID that slipped past validation, a constraint, a deadlock —
  becomes `:write_failed` and rolls the whole call back, so a half-applied plan
  cannot exist.
  """
  @spec apply_run_plan(AuditContext.t(), Plan.t()) ::
          {:ok, %{changed_trips: non_neg_integer(), undo: [Plan.move()]}}
          | {:error,
             :forbidden
             | :not_found
             | :stale_plan
             | {:invalid_trips, [Ecto.UUID.t()]}
             | :write_failed}
  def apply_run_plan(%AuditContext{} = audit, plan) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit)
      organization_id = audit.organization_id
      gtfs_version_id = audit.gtfs_version_id
      Versions.lock_for_input_write!(organization_id, gtfs_version_id)
      :ok = Blocking.lock_blocking!(gtfs_version_id)

      case Blocking.load_day(organization_id, gtfs_version_id, plan.day_type_key) do
        {:ok, day} -> write_plan(organization_id, gtfs_version_id, day, plan)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp write_plan(organization_id, gtfs_version_id, day, plan) do
    # The same read `suggest_runs/4` used, and therefore the same fingerprint:
    # the stale check works because both sides compute it with one function, not
    # because two implementations agree.
    runs_day = build_runs_day(organization_id, gtfs_version_id, day)

    if runs_day.fingerprint == plan.fingerprint do
      sequence_ids =
        MapSet.new(Enum.flat_map(day.blocks, &Enum.map(&1.trips, fn trip -> trip.id end)))

      case check_trips(plan.moves, sequence_ids) do
        # The bare reason is rolled back, not the `{:error, reason}` tuple:
        # rolling that back hands the caller `{:error, {:error, reason}}`.
        {:error, reason} -> Repo.rollback(reason)
        :ok -> apply_plan_moves(organization_id, gtfs_version_id, day, plan)
      end
    else
      Repo.rollback(:stale_plan)
    end
  end

  # Every move, or none. A `Postgrex.Error` from any batch — a run ID that
  # slipped past, a constraint, a deadlock — is caught and rolled back, so a
  # half-applied plan cannot be observed.
  defp apply_plan_moves(organization_id, gtfs_version_id, day, plan) do
    key = day.day_type.key
    now = DateTime.utc_now()
    assigns = Enum.filter(plan.moves, & &1.to)
    unassigns = Enum.reject(plan.moves, & &1.to)

    try do
      assigns
      |> Enum.chunk_every(@write_batch)
      |> Enum.each(fn batch ->
        Repo.insert_all(
          TripRun,
          Enum.map(batch, fn move ->
            %{
              organization_id: organization_id,
              gtfs_version_id: gtfs_version_id,
              day_type_key: key,
              trip_id: move.trip_id,
              run_id: move.to,
              inserted_at: now,
              updated_at: now
            }
          end),
          # Columns, not the index name: PostgreSQL's `ON CONFLICT (...)` takes
          # column names or expressions and resolves the unique index itself.
          on_conflict: {:replace, [:run_id, :updated_at]},
          conflict_target: [:organization_id, :gtfs_version_id, :day_type_key, :trip_id]
        )
      end)

      unassigns
      |> Enum.chunk_every(@write_batch)
      |> Enum.each(fn batch ->
        Repo.delete_all(
          from(row in TripRun,
            where:
              row.organization_id == ^organization_id and
                row.gtfs_version_id == ^gtfs_version_id and row.day_type_key == ^key and
                row.trip_id in ^Enum.map(batch, & &1.trip_id)
          )
        )
      end)

      # Every move in a plan is a trip whose run differs, and the fingerprint
      # confirmed nothing changed since the plan was built, so the move count is
      # the changed count and needs no second read to discover.
      %{changed_trips: length(plan.moves), undo: plan_undo(plan.moves)}
    rescue
      Postgrex.Error -> Repo.rollback(:write_failed)
    end
  end

  # The undo is `apply_moves/4` material: every move reversed, in the same shape,
  # so undoing a plan is refused by the same per-trip rule rather than by
  # a bespoke reverse-update that would bypass it.
  defp plan_undo(moves) do
    moves
    |> Enum.map(&%{trip_id: &1.trip_id, from: &1.to, to: &1.from})
    |> Enum.sort_by(& &1.trip_id)
  end

  @doc """
  Counts the day-type runs that hold any of the given trips.

  This is the figure the Blocks preview asks for: how many runs would a change
  to these trips disturb. The count is of **distinct `(day_type_key, run_id)`
  pairs**, which is what makes it a count of runs rather than of rows. Two
  trips of one run count 1, and the same run ID on two day types counts 2,
  because a run is scoped to its day type — the same ID on a Saturday is a
  different run from the weekday one, and the pair is the run's identity.

  **The trips are named by UUID, not by GTFS trip ID.** `trip_runs.trip_id` is
  the `belongs_to :trip` key, so it holds `Trip.id`. A caller holding GTFS
  strings — the page's own `trip_id` — has to resolve them first; passing them
  straight here is a cast error rather than a wrong answer, so the mistake
  cannot be silent. The Blocks preview holds `Trip` structs, so it already has
  what this wants.

  The answer is a plain number, not `{:ok, n}`: there is no failure to report.
  An empty list, and a trip held by no run, both count 0, and another
  organization's or version's rows are excluded rather than refused — the
  question is a count, and a row the caller may not see is a row that does not
  contribute.

  Orphaned rows — a stored assignment whose trip has left the day type — are
  still counted, because they are still runs in the table. Removing them is
  `remove_orphans/3`'s separate job; quietly excluding them here would make
  this figure disagree with the rows an orphan cleanup would go on to delete.

  It opens no transaction. It is a single statement, so it is already atomic,
  and a transaction would add nothing but a savepoint.
  """
  @spec count_runs_for_trips(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) :: non_neg_integer()
  def count_runs_for_trips(organization_id, gtfs_version_id, trip_ids) do
    if trip_ids == [] do
      0
    else
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id,
        where: row.trip_id in ^trip_ids,
        select: {row.day_type_key, row.run_id},
        distinct: true
      )
      |> Repo.all()
      |> length()
    end
  end

  @doc """
  Derives every day type's runs from the movements export read.

  Takes the `Blocking.export_movements/2` result, an assignment map keyed by day
  type key, and the crew rules, and answers `%{day_type_key => Day.derived()}`
  for every day type the export listed.

  **It opens no transaction.** It is called from inside the caller's — the
  export's one read snapshot — and a nested `Repo.transaction/1` would only take
  a savepoint, as `Blocking.load_day/3` becoming one inside `load_runs/3`
  already is. More to the point, this function reads nothing at all: every input
  is an argument, so a transaction would guard a computation rather than a read.

  What it builds per day type is the same block input `load_runs/3` builds, from
  the same two places: the export's blocks carry the movements, and the relief
  windows come from `Blocking.Relief.windows/3` over the export's **context**,
  which is why that context is returned rather than recomputed. The composition
  is then `Runs.Day.derive/4` — the only day composition in the system,
  so a day type's runs here and its runs on the page are the same runs.
  """
  @spec derive_version(Blocking.export_movements_result(), %{String.t() => map()}, map()) ::
          %{optional(String.t()) => Day.derived()}
  def derive_version(export, assignments_by_day_type, crew) do
    blocks_by_day_type = export.blocks_by_day_type
    contexts = export.contexts_by_day_type

    for {key, blocks} <- blocks_by_day_type, into: %{} do
      context = contexts[key]

      inputs =
        Enum.map(blocks, fn block ->
          %{
            block_id: block.block_id,
            trips: block.trips,
            movements: block.movements,
            windows: Blocking.Relief.windows(block.trips, block.movements, context)
          }
        end)

      {key, Day.derive(inputs, Map.get(assignments_by_day_type, key, %{}), context, crew)}
    end
  end

  @doc """
  Returns every day type's straight and split counts and the straight share.

  This is the version-wide summary: every day type of the
  version, not just one, so a planner comparing a weekday with a Saturday does
  not have to load each in turn. A day type with no runs is **listed** with
  straight 0, split 0 and a share of `nil` — a nil share is the answer
  `Runs.Day.derive/4` already gives when both counts are zero, and the page must
  show it rather than omit the day type, or a version with one unworked Saturday
  would look like a version that does not have one.

  An unpublished or foreign version is `{:error, :not_found}`. The published
  check comes first, before any day is derived, so a draft version costs
  nothing to refuse.
  """
  @spec day_type_shares(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok,
           [
             %{
               day_type_key: String.t(),
               label: String.t(),
               straight: non_neg_integer(),
               split: non_neg_integer(),
               share: 0..100 | nil
             }
           ]}
          | {:error, :not_found}
  def day_type_shares(organization_id, gtfs_version_id) do
    Repo.transaction(fn ->
      if Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
        export = Blocking.export_movements(organization_id, gtfs_version_id)
        crew = get_crew_settings(organization_id, gtfs_version_id)
        assignments = assignments_by_day_type(organization_id, gtfs_version_id)
        derived = derive_version(export, assignments, crew)

        shares(export.day_types, derived)
      else
        Repo.rollback(:not_found)
      end
    end)
  end

  # One row per day type the export listed. Its own function so this read is
  # `transaction -> if`, and the row shape is stated once rather than inside the
  # published check.
  defp shares(day_types, derived) do
    for day_type <- day_types do
      # A day type the export listed always has an entry, but a default
      # that answers the question anyway costs one line and removes a
      # crash from a read that has no other way to fail.
      stats =
        derived
        |> Map.get(day_type.key, @empty_derived_stats)
        |> Map.fetch!(:stats)

      %{
        day_type_key: day_type.key,
        label: day_type.label,
        straight: stats.by_type.straight,
        split: stats.by_type.split,
        share: stats.straight_share
      }
    end
  end

  @doc """
  Every saved run assignment of the version, grouped by its day type key.

  This is the saved half of a day: which trips are in which run. It is public
  because the operations export composes the other half itself — it already holds
  the `Blocking.export_movements/2` result, so it passes that to `derive_version/3`
  beside these rather than deriving the blocks and windows a second time.

  A key no current day type has is simply absent, because the day types come from
  the export rather than from the table.
  """
  @spec assignments_by_day_type(Ecto.UUID.t(), Ecto.UUID.t()) :: %{optional(String.t()) => map()}
  def assignments_by_day_type(organization_id, gtfs_version_id) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id,
        select: {row.day_type_key, row.trip_id, row.run_id}
      )
    )
    |> Enum.group_by(fn {key, _trip_id, _run_id} -> key end, fn {_key, trip_id, run_id} ->
      {trip_id, run_id}
    end)
    |> Map.new(fn {key, pairs} -> {key, Map.new(pairs)} end)
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

  The save runs in one transaction that locks the editor membership first, then the
  scoped version row `FOR SHARE` (`Versions.lock_for_input_write!/2`), so the rules a review loaded
  cannot change under a calendar combination that owns the version, and this save
  waits behind such an owner in turn. It then takes `Blocking.lock_blocking!/1`, so
  a crew save serializes with every other planning-input writer and cannot slip
  between a plan's review and its apply.

  The upsert replaces only the five crew columns and the write timestamp. Its base
  carries the stored Block rules values, so a first save on a version with no row
  satisfies the Block rules columns rather than inserting defaults over them.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is outside its range
  or blank, in which case nothing is written.
  """
  @spec update_crew_settings(AuditContext.t(), map()) ::
          {:ok, crew()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def update_crew_settings(%AuditContext{} = audit, attrs) do
    case Repo.transaction(fn -> write_crew_settings!(audit, attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The editor membership lock is first; the version share lock follows, before
  # the published check and the upsert, and `lock_blocking!/1` follows it and
  # nothing else, in the blocking writers' order, so this writer joins the same serialization
  # point as the block writers instead of taking a second runs lock.
  defp write_crew_settings!(%AuditContext{} = audit, attrs) do
    Authorization.lock_editor!(audit)
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id
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
