defmodule GtfsPlanner.Gtfs.Rosters do
  @moduledoc """
  Scoped reads and writes for the Rosters page.

  This module is the only reader and writer of `roster_lines`, `roster_line_days`
  and of the three roster columns on `blocking_settings` — `min_rest_minutes`,
  `weekly_hours_warn_above` and `roster_day_types`. The page reaches them through
  `Gtfs` facade functions, so a roster rule has one home.

  The roster rules are the work rules a line is judged against: the minimum rest
  between a sign-off and the next sign-on, the weekly paid hours above which a
  line is flagged, and which day type each weekday's base week works. They are
  stored per published organization and version alongside the Block rules and the
  crew rules, on the same row, and this writer replaces only the three columns it
  owns — a roster save cannot reset a minimum layover or a crew rule, and a Block
  rules or crew save cannot reset a roster rule.

  A version with no stored roster rules reads the researched defaults (600
  minutes of rest, a warning above 48 weekly hours and an empty base-week choice)
  and writes nothing: a read never inserts a row.

  A stored base-week choice is accepted only while it is current. Each weekday's
  day-type key must still be a day type the version's calendars derive, and that
  day type must have at least one date on that weekday; anything else is a field
  error rather than a stored key that silently falls back to another day's service
  (INV-6).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Rosters.BaseWeek
  alias GtfsPlanner.Gtfs.Rosters.Candidates
  alias GtfsPlanner.Gtfs.Rosters.Checks
  alias GtfsPlanner.Gtfs.Rosters.Roster
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # The rules a version with no stored row reads. The map is the single definition
  # of the defaults, exactly as `@crew_defaults` is for the Runs page: the reader
  # answers with it when no row is stored and the form changeset fills a partial
  # map from it, so the database defaults, this map and the drawn inputs cannot
  # drift apart.
  @roster_defaults %{
    min_rest_minutes: 600,
    weekly_hours_warn_above: 48,
    roster_day_types: %{}
  }

  # The three roster columns plus the write timestamp: an upsert that replaced more
  # than these would reset the Block rules and the crew rules stored on the same
  # row, and one that replaced fewer would leave a previous save's value behind.
  @replace_roster_columns BlockingSetting.roster_fields() ++ [:updated_at]

  # What one slot write replaces: the weekday's own row, kept at one row per line
  # and weekday by the `roster_line_id, weekday` index the upsert targets. Every
  # write refreshes the two stored times as well as the run, which is what makes
  # a re-set re-cut run a fresh slot again (INV-13).
  @replace_day_columns [
    :day_type_key,
    :run_id,
    :run_sign_on_secs,
    :run_sign_off_secs,
    :updated_at
  ]

  # The database's own answer to "a run is on at most one line per weekday", read
  # by name when the upsert loses the race for it.
  @run_once_constraint :roster_line_days_run_once_per_weekday

  @published_status "published"

  # The weekday a field error reads with, keyed by the ISO weekday string
  # `roster_day_types` stores and in `Date.day_of_week/1`'s order (1 = Monday).
  @weekday_names %{
    "1" => "Monday",
    "2" => "Tuesday",
    "3" => "Wednesday",
    "4" => "Thursday",
    "5" => "Friday",
    "6" => "Saturday",
    "7" => "Sunday"
  }

  @type roster_settings :: %{
          min_rest_minutes: 480..720,
          weekly_hours_warn_above: 40..60,
          roster_day_types: %{optional(String.t()) => String.t()}
        }

  @typedoc """
  The page's read: the version's day types, its derived runs, its stored rules
  and the composition itself.

  `day_types` and `run_days` are the same pair `run_events.txt` is built from, so
  the page and the export never disagree about which runs a version has.
  """
  @type roster_view :: %{
          day_types: [map()],
          run_days: %{optional(String.t()) => map()},
          settings: roster_settings(),
          roster: Roster.t()
        }

  @doc """
  Returns the three roster rules for an organization's GTFS version.

  A version with no stored row returns the researched defaults; the read never
  inserts one, so opening the Rosters page cannot create a settings row as a side
  effect of looking at it.
  """
  @spec get_roster_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: roster_settings()
  def get_roster_settings(organization_id, gtfs_version_id) do
    case Repo.one(roster_query(organization_id, gtfs_version_id)) do
      nil -> @roster_defaults
      stored -> stored
    end
  end

  @doc """
  Returns the changeset rendered by the roster settings form.

  `roster` is a value map from `get_roster_settings/2` — or any partial map, which
  is filled from the defaults — and `attrs` are the submitted parameters; an
  invalid value carries the field error.

  The day-type check needs the version's calendars, which this function has no
  scope for, so a stored key that is no longer a current day type is not reported
  here: `update_roster_settings/3` makes that call inside its transaction.
  """
  @spec change_roster_settings(roster_settings(), map()) :: Ecto.Changeset.t()
  def change_roster_settings(roster, attrs) do
    # The defaults fill in what the caller did not supply, so the merge runs the
    # other way round, exactly as `Runs.change_crew_settings/2` does: merging the
    # defaults over the given roster would replace every stored value with a
    # default and the form could never show what the version has.
    values = @roster_defaults |> Map.merge(roster) |> Map.take(BlockingSetting.roster_fields())

    %BlockingSetting{}
    |> Ecto.Changeset.change(values)
    |> BlockingSetting.roster_changeset(attrs)
  end

  @doc """
  Stores the three roster rules for one organization's published version.

  The save runs in one transaction whose first statement is the scoped version row
  `FOR SHARE` (`Versions.lock_for_input_write!/2`), so the rules a review loaded
  cannot change under a calendar combination that owns the version, and this save
  waits behind such an owner in turn. It then takes `Blocking.lock_blocking!/1`,
  so a roster save serializes with every other planning-input writer and cannot
  slip between a plan's review and its apply (INV-1). No second lock is taken.

  The upsert replaces only the three roster columns and the write timestamp. Its
  base carries the stored Block rules values, so a first save on a version with no
  row satisfies the Block rules columns rather than inserting defaults over them.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is outside its range
  or a chosen day type is not current for that weekday, in which case nothing is
  written.
  """
  @spec update_roster_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, roster_settings()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_roster_settings(organization_id, gtfs_version_id, attrs) do
    with_roster_lock(organization_id, gtfs_version_id, fn ->
      write_roster_settings!(organization_id, gtfs_version_id, attrs)
    end)
  end

  @doc """
  Creates an empty line on a published version.

  The new line has no days: a day off is the absence of a `roster_line_days` row,
  so there is nothing to write for one and an "Add line" click costs one row. The
  number is the version's highest plus one, and 1 when the version has no line —
  numbering follows the lines that exist, so deleting the last line leaves a gap
  that is never reused within the version's life.

  The number is read inside the lock, alongside the insert that takes it, so two
  sessions adding a line at the same time get two different numbers rather than
  one line and a unique-index refusal (INV-1).

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, in which case nothing is written.
  """
  @spec create_line(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{id: Ecto.UUID.t(), line_number: pos_integer()}} | {:error, :not_found}
  def create_line(organization_id, gtfs_version_id) do
    with_roster_lock(organization_id, gtfs_version_id, fn ->
      # The match is the invariant, not a guess: the number was read under the
      # lock that every other roster writer takes, so `roster_lines`' own unique
      # index on `(organization_id, gtfs_version_id, line_number)` has nothing
      # left to refuse and a failure here would be a defect, not a refusal. The
      # transaction aborts and writes nothing if it ever were one.
      {:ok, line} =
        %RosterLine{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          line_number: next_line_number(organization_id, gtfs_version_id)
        }
        |> RosterLine.changeset(%{})
        |> Repo.insert()

      {:ok, %{id: line.id, line_number: line.line_number}}
    end)
  end

  @doc """
  Sets one weekday of a line to a run, storing the run's current times.

  A slot names a run-day and the times it was set with, so the write stores the
  run's own `sign_on_secs` and `sign_off_secs` as `Runs.derive_version/3` reads
  them today. That is what makes a later re-cut of the same run visible as a
  stale slot rather than a silently accepted one, and re-setting the same run is
  how a planner accepts the new times (INV-13).

  The write is an upsert on `(line, weekday)`, so setting a day that already
  works another run replaces it and the line keeps one row for that weekday.

  Three refusals happen before anything is written, in the order the page fixes
  them: `{:no_base, weekday}` when the weekday's base week has no day type at
  all, `{:unknown_run, run_id}` when the run is not one of that day type's runs,
  and `{:run_held, weekday, line_number}` when another line already works that
  run that day. The database's own run-once-per-weekday index is the backstop for
  the third, and a refusal maps onto the same named answer whichever one caught
  it, so a planner is never told "nothing happened" (AC-13).

  A manual edit is allowed to leave short rest — the builder never creates it,
  but a planner working one day at a time is allowed to. `short_rests` is
  `Rosters.Checks.short_rests/2` over the week the write leaves, so the drawer
  can show exactly which pair is short and by how much rather than a bare
  refusal (domain rule 5).

  Returns `{:error, :not_found}` when the version is unpublished, belongs to
  another organization, or names no line of that version under the given
  organization. A foreign or malformed line id is `:not_found` too, never a
  cross-tenant write.
  """
  @spec set_slot(Ecto.UUID.t(), Ecto.UUID.t(), term(), 1..7, String.t()) ::
          {:ok, %{short_rests: [Checks.short_rest()]}}
          | {:error, :not_found | Candidates.refusal()}
  def set_slot(organization_id, gtfs_version_id, line_id, weekday, run_id) do
    with_roster_lock(organization_id, gtfs_version_id, fn ->
      with {:ok, line} <- fetch_line(organization_id, gtfs_version_id, line_id),
           {:ok, view} <- compose_read(organization_id, gtfs_version_id),
           {:ok, key, run} <- weekday_run(view, weekday, run_id),
           :ok <- check_run_held(view.roster, weekday, line.id, key, run.run_id),
           {:ok, _day} <-
             write_day(organization_id, gtfs_version_id, line.id, weekday, key, run) do
        {:ok, %{short_rests: short_rests_after(view.roster, line.id, weekday, run)}}
      end
    end)
  end

  @doc """
  Clears one weekday of a line, returning its run to open work.

  A day off is the absence of a row, so clearing is a delete of the
  `(line, weekday)` row and nothing else: no run, no derived state and no other
  line is touched. The run the day held stops being held and reappears in the
  composition's open work, which is what the page redraws from.

  A weekday that already holds no row is `{:ok, :already_off}` rather than an
  error — clearing an empty day reaches the state it was asked for, and the
  drawer can answer a second click without inventing a failure.

  Returns `{:error, :not_found}` when the version is unpublished, belongs to
  another organization, or names no line of that version under the given
  organization. A line id from another version, another organization or a
  malformed one is `:not_found` too, never a cross-tenant write.
  """
  @spec clear_slot(Ecto.UUID.t(), Ecto.UUID.t(), term(), 1..7) ::
          {:ok, :cleared | :already_off} | {:error, :not_found}
  def clear_slot(organization_id, gtfs_version_id, line_id, weekday) do
    with_roster_lock(organization_id, gtfs_version_id, fn ->
      with {:ok, line} <- fetch_line(organization_id, gtfs_version_id, line_id) do
        clear_weekday(line, weekday)
      end
    end)
  end

  # Scoped by the line the caller's organization and version own, and by the
  # weekday: no other line's row is reachable from here, and the count is what
  # distinguishes a cleared day from one that was already off.
  defp clear_weekday(line, weekday) do
    case Repo.delete_all(
           from(d in RosterLineDay,
             where: d.roster_line_id == ^line.id and d.weekday == ^weekday
           )
         ) do
      {1, _deleted} -> {:ok, :cleared}
      {0, _deleted} -> {:ok, :already_off}
    end
  end

  # The version's whole roster, composed for a writer that already holds both
  # locks and has read its own line. It reuses `load_roster/2`'s derivation and
  # `compose/5` itself, so the writer's refusals and its reported short rests are
  # computed from the same composition the page draws and the export reads
  # (INV-15) rather than from a second walk of the roster tables.
  defp compose_read(organization_id, gtfs_version_id) do
    {movements, run_days} = derive_runs(organization_id, gtfs_version_id)

    {:ok,
     compose(
       organization_id,
       gtfs_version_id,
       movements,
       run_days,
       list_lines(organization_id, gtfs_version_id)
     )}
  end

  # The run the weekday's base day type would work on that weekday, and the key
  # the slot has to name with it. A weekday no day type dates has no base and no
  # run to place (AC-2), and a run that is not one of that day type's derived
  # runs has no work to place, so both are refused before anything is written.
  defp weekday_run(view, weekday, run_id) do
    with {:ok, key} <- base_key(view.roster, weekday),
         {:ok, run} <- find_run(Map.get(view.run_days, key), run_id) do
      {:ok, key, run}
    end
  end

  defp base_key(roster, weekday) do
    case Map.get(roster.base_week, weekday) do
      %{day_type: %{key: key}} -> {:ok, key}
      _no_base -> {:error, {:no_base, weekday}}
    end
  end

  defp find_run(nil, run_id), do: {:error, {:unknown_run, run_id}}

  defp find_run(day, run_id) do
    case Enum.find(day.runs, &(&1.run_id == run_id)) do
      nil -> {:error, {:unknown_run, run_id}}
      run -> {:ok, run}
    end
  end

  # Another line already working this run-day, named by its line number so the
  # planner is told where to look. The line being written to is not a holder: it
  # is the line the change is for, and re-setting its own run on a day is how a
  # re-cut run is accepted.
  defp check_run_held(roster, weekday, line_id, day_type_key, run_id) do
    holder =
      Enum.find_value(roster.lines, fn line ->
        if line.id != line_id and holds_run_day?(line, weekday, day_type_key, run_id) do
          line.line_number
        end
      end)

    case holder do
      nil -> :ok
      line_number -> {:error, {:run_held, weekday, line_number}}
    end
  end

  defp holds_run_day?(line, weekday, day_type_key, run_id) do
    case Map.get(line.slots, weekday) do
      %{day_type_key: ^day_type_key, run_id: ^run_id} -> true
      _day_off -> false
    end
  end

  # One upsert on the `(line, weekday)` index: a day that already works another
  # run is replaced rather than refused, and every write stores the run's current
  # times so a re-cut cannot be accepted without the planner re-setting it
  # (INV-13).
  defp write_day(organization_id, gtfs_version_id, line_id, weekday, day_type_key, run) do
    attrs = %{
      run_id: run.run_id,
      run_sign_on_secs: run.work.sign_on_secs,
      run_sign_off_secs: run.work.sign_off_secs
    }

    changeset =
      %RosterLineDay{
        roster_line_id: line_id,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        weekday: weekday,
        day_type_key: day_type_key
      }
      |> RosterLineDay.changeset(attrs)

    case Repo.insert(changeset,
           on_conflict: {:replace, @replace_day_columns},
           conflict_target: [:roster_line_id, :weekday]
         ) do
      {:ok, day} ->
        {:ok, day}

      # Ecto wrapped the statement in a savepoint, so the transaction is still
      # usable here and the holder is readable: the refusal names the same line
      # the check above would have named, whichever of the two caught it.
      {:error, invalid} ->
        held_run_day(organization_id, gtfs_version_id, invalid, weekday, day_type_key, run)
    end
  end

  defp held_run_day(organization_id, gtfs_version_id, changeset, weekday, day_type_key, run) do
    if run_held_constraint?(changeset) do
      case holder_line_number(organization_id, gtfs_version_id, weekday, day_type_key, run) do
        nil -> {:error, changeset}
        line_number -> {:error, {:run_held, weekday, line_number}}
      end
    else
      {:error, changeset}
    end
  end

  defp run_held_constraint?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint] == @run_once_constraint
    end)
  end

  # The line holding the run-day the index refused, scoped by the caller's own
  # organization and version on both tables: the number a refusal reports is a
  # line of this version, never another tenant's.
  defp holder_line_number(organization_id, gtfs_version_id, weekday, day_type_key, run) do
    Repo.one(
      from(l in RosterLine,
        join: d in RosterLineDay,
        on: d.roster_line_id == l.id,
        where:
          l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id and
            d.weekday == ^weekday and d.day_type_key == ^day_type_key and d.run_id == ^run.run_id,
        select: l.line_number
      )
    )
  end

  # The short rests the week would have once this day is set: the line's own
  # non-stale days, with the weekday being written replaced by the run just
  # stored. A stale neighbour's stored times are not the run's times, so it is
  # left out exactly as `Rosters.Roster.build/1` leaves it out of its own rest
  # check — the two cannot disagree about what a line's rest is (INV-15).
  defp short_rests_after(roster, line_id, weekday, run) do
    case Enum.find(roster.lines, &(&1.id == line_id)) do
      nil ->
        []

      line ->
        line.slots
        |> Enum.reject(fn {other, _slot} -> other == weekday end)
        |> Enum.filter(fn {_other, slot} -> slot.state == :ok end)
        |> Map.new(fn {other, slot} -> {other, slot.run.work} end)
        |> Map.put(weekday, run.work)
        |> Checks.short_rests(roster.rules.min_rest_minutes)
    end
  end

  @doc """
  Deletes a line with all of its days and its recorded pick.

  The days go with the line through the foreign key, so one delete is the whole
  removal: every run the line held returns to open work, and the pick goes with
  the row, which is what "deleting a line also removes its recorded pick" means —
  the operator is left holding nothing and can be given another line.

  `run_days` is the number of `roster_line_days` rows removed, read inside the
  lock before the delete. The confirm dialog names what is about to go, and a
  line with no days reports 0 rather than a missing figure.

  Returns `{:error, :not_found}` when the version is unpublished, belongs to
  another organization, or names no line of that version under the given
  organization. A foreign or malformed line id is `:not_found` and deletes
  nothing.
  """
  @spec delete_line(Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          {:ok, %{line_number: pos_integer(), run_days: non_neg_integer()}}
          | {:error, :not_found}
  def delete_line(organization_id, gtfs_version_id, line_id) do
    with_roster_lock(organization_id, gtfs_version_id, fn ->
      with {:ok, line} <- fetch_line(organization_id, gtfs_version_id, line_id) do
        run_days =
          Repo.one(
            from(d in RosterLineDay,
              where: d.roster_line_id == ^line.id,
              select: count(d.id)
            )
          )

        # The days cascade from this one delete, so the count and the removal are
        # the same statement's worth of work and cannot disagree.
        {:ok, _deleted} = Repo.delete(line)

        {:ok, %{line_number: line.line_number, run_days: run_days}}
      end
    end)
  end

  @doc """
  Loads one organization's whole roster for a published version.

  This is the page's read and it is read-only. It reuses the export's own
  whole-version composition — `Blocking.export_movements/2` and
  `Runs.derive_version/3` — so the runs, figures and stale states the page draws
  are the ones `run_events.txt` and `employee_run_dates.txt` would be built from,
  and there is no second derivation anywhere (INV-11, INV-15). The derived runs
  and the roster lines are then handed to `Rosters.Roster.build/1`; nothing here
  walks `roster_line_days` itself.

  A version that is unpublished or belongs to another organization is
  `{:error, :not_found}`, and the check comes first so a draft version costs
  nothing to refuse.
  """
  @spec load_roster(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, roster_view()} | {:error, :not_found}
  def load_roster(organization_id, gtfs_version_id) do
    if Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
      {movements, run_days} = derive_runs(organization_id, gtfs_version_id)

      {:ok,
       compose(
         organization_id,
         gtfs_version_id,
         movements,
         run_days,
         list_lines(organization_id, gtfs_version_id)
       )}
    else
      {:error, :not_found}
    end
  end

  # The version's movements and its whole-version runs, derived exactly as
  # `Export.movement_rows/2` derives them, so the page, `set_slot/5`'s own
  # checks and the export read one snapshot (INV-11).
  defp derive_runs(organization_id, gtfs_version_id) do
    movements = Blocking.export_movements(organization_id, gtfs_version_id)

    run_days =
      Runs.derive_version(
        movements,
        Runs.assignments_by_day_type(organization_id, gtfs_version_id),
        Runs.get_crew_settings(organization_id, gtfs_version_id)
      )

    {movements, run_days}
  end

  @doc """
  Composes the roster for an export that already has its movements and runs.

  The export derives the version's runs once and passes them here rather than
  deriving them a second time, so `employee_run_dates.txt` is written from the
  same `run_days` as `run_events.txt` (INV-11, INV-15). A version with no roster
  line has nothing to export and returns `nil`, which is also what keeps the file
  and its warnings off a version that has never been rostered.
  """
  @spec export_roster(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Blocking.export_movements_result(),
          %{optional(String.t()) => map()}
        ) :: Roster.t() | nil
  def export_roster(organization_id, gtfs_version_id, movements, run_days) do
    case list_lines(organization_id, gtfs_version_id) do
      [] -> nil
      lines -> compose(organization_id, gtfs_version_id, movements, run_days, lines).roster
    end
  end

  # The one lock order every roster writer runs under (INV-1, domain rule 16):
  # `Versions.lock_for_input_write!/2` takes the published version `FOR SHARE`
  # before anything else, the publication check follows it, and
  # `Blocking.lock_blocking!/1` follows that — in the block writers' order, so a
  # roster write serializes with every other planning-input writer and cannot
  # slip between a runs rebuild's review and its apply. No second lock is taken.
  #
  # Every writer here reads and writes only after these three statements, which is
  # why the readers and writers below take no lock of their own: the fun is called
  # with both locks already held. Steps 13 to 16 reach the same helper, so a
  # fourth writer cannot take the locks in a different order by accident.
  defp with_roster_lock(organization_id, gtfs_version_id, fun) do
    case Repo.transaction(fn -> lock_and_run(organization_id, gtfs_version_id, fun) end) do
      {:ok, result} -> result
      # `lock_for_input_write!/2` rolls back with `:not_found` for a version of
      # another organization or one that does not exist, so a foreign version
      # never reaches the fun and never takes the blocking lock.
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_and_run(organization_id, gtfs_version_id, fun) do
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = Blocking.lock_blocking!(gtfs_version_id)
      fun.()
    else
      # The shared lock takes no publication stance, so the published requirement
      # stays here, exactly as `Blocking`'s and `Runs`' own writers apply it.
      # Nothing has been read or written yet.
      {:error, :not_found}
    end
  end

  # The version's highest line number plus one, read inside the lock, or 1 when
  # the version has no line. Scoped by organization and version on the query, so
  # a sibling version's numbering cannot push this version's first line to 2.
  defp next_line_number(organization_id, gtfs_version_id) do
    highest =
      Repo.one(
        from(l in RosterLine,
          where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
          select: max(l.line_number)
        )
      )

    case highest do
      nil -> 1
      number -> number + 1
    end
  end

  # The caller's own line, found through the organization and version arguments
  # rather than a submitted scope. A line id that is malformed, names no row, or
  # names a line of another version or organization is `:not_found`, so no writer
  # can reach across a tenant boundary with a well-formed UUID.
  defp fetch_line(organization_id, gtfs_version_id, line_id) do
    # `Ecto.UUID.cast/1` answers `:error` for a malformed id, which is the same
    # refusal as a missing row: never a crash, never a guess.
    case Ecto.UUID.cast(line_id) do
      {:ok, cast_id} -> read_line(organization_id, gtfs_version_id, cast_id)
      :error -> {:error, :not_found}
    end
  end

  defp read_line(organization_id, gtfs_version_id, cast_id) do
    case Repo.one(
           from(l in RosterLine,
             where:
               l.id == ^cast_id and l.organization_id == ^organization_id and
                 l.gtfs_version_id == ^gtfs_version_id
           )
         ) do
      nil -> {:error, :not_found}
      line -> {:ok, line}
    end
  end

  # The roster settings write, called with both locks already held by
  # `with_roster_lock/3`.
  defp write_roster_settings!(organization_id, gtfs_version_id, attrs) do
    # The stored row is the base rather than a bare struct, so the columns this
    # writer does not own are present and satisfy the insert of the version's
    # first row; the upsert then replaces only the roster columns, so writing a
    # roster rule cannot blank a stored layover, interlining rule or crew rule.
    stored = Blocking.get_settings(organization_id, gtfs_version_id)

    changeset =
      %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
      |> Ecto.Changeset.change(Map.take(stored, BlockingSetting.settings_fields()))
      |> BlockingSetting.roster_changeset(attrs)
      |> check_day_types(Blocking.list_day_types(organization_id, gtfs_version_id))

    case Repo.insert(changeset,
           on_conflict: {:replace, @replace_roster_columns},
           conflict_target: [:organization_id, :gtfs_version_id]
         ) do
      {:ok, saved} -> {:ok, roster_values(saved)}
      # Nothing has been written yet, so the transaction commits this result and
      # still leaves the stored row exactly as the previous save left it.
      {:error, invalid} -> {:error, invalid}
    end
  end

  # A chosen day type has to be a day type the version derives now, and it has to
  # have at least one date on the weekday it was chosen for. Both halves are
  # checked against the calendars read inside the write transaction, so a key that
  # a calendar change has made stale is refused at the moment it is submitted
  # rather than stored and reported as "Base week changed" later (INV-6).
  #
  # An entry whose weekday or key is malformed is left to
  # `BlockingSetting.roster_changeset/2`, which has already put a field error on
  # it, rather than answering the same entry twice.
  defp check_day_types(changeset, day_types) do
    case Ecto.Changeset.get_field(changeset, :roster_day_types) do
      choices when is_map(choices) ->
        # Only entries whose weekday and key are well formed are checked here: the
        # other two refusals — a weekday outside 1 to 7 and a blank key — are
        # already field errors from `roster_changeset/2`, and answering the same
        # entry twice would give the drawer two messages for one mistake.
        choices
        |> Enum.filter(fn {weekday, key} ->
          Map.has_key?(@weekday_names, weekday) and usable_key?(key)
        end)
        |> Enum.reduce(changeset, &check_day_type(&1, &2, day_types))

      _not_a_map ->
        changeset
    end
  end

  defp check_day_type({weekday, key}, changeset, day_types) do
    if runs_on_weekday?(day_types, key, weekday) do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :roster_day_types,
        "Choose a day type that runs on #{Map.fetch!(@weekday_names, weekday)}."
      )
    end
  end

  # The key must be a day type the version's calendars derive now, and that day type
  # must have at least one date on the weekday the key was chosen for.
  defp runs_on_weekday?(day_types, key, weekday) do
    case Enum.find(day_types, &(&1.key == key)) do
      %{dates: dates} -> Enum.any?(dates, &(Date.day_of_week(&1) == String.to_integer(weekday)))
      nil -> false
    end
  end

  defp usable_key?(key), do: is_binary(key) and String.trim(key) != ""

  # Only the three roster columns, in the shape `get_roster_settings/2` answers
  # with, so a caller never has to know the row also carries the Block rules and
  # the crew rules.
  defp roster_values(setting) do
    Map.new(BlockingSetting.roster_fields(), &{&1, Map.fetch!(setting, &1)})
  end

  # The one place a roster view is composed. `load_roster/2` and `export_roster/4`
  # both reach it, and the writers in steps 13–15 call it inside their own
  # transaction once they have read the lines under the lock, so the base week,
  # the rules and the composition come from one computation on every path
  # (INV-15). The base week is resolved here from the same day types the runs
  # were derived from, never from a second calendar read.
  defp compose(organization_id, gtfs_version_id, movements, run_days, lines) do
    day_types = movements.day_types
    settings = get_roster_settings(organization_id, gtfs_version_id)

    %{
      day_types: day_types,
      run_days: run_days,
      settings: settings,
      roster:
        Roster.build(%{
          base_week: BaseWeek.resolve(day_types, settings.roster_day_types),
          run_days: run_days,
          lines: lines,
          rules: settings
        })
    }
  end

  # The version's lines with their days and operator, scoped by organization and
  # version on the line query itself: a line of another organization's version or
  # of a sibling version cannot enter a composition, whichever caller asks.
  # Days come back in weekday order so the composed grid is the same whatever
  # order the database returned them in.
  defp list_lines(organization_id, gtfs_version_id) do
    RosterLine
    |> where(
      [l],
      l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id
    )
    |> preload([:operator, days: ^from(d in RosterLineDay, order_by: d.weekday)])
    |> Repo.all()
    |> Enum.map(&line_input/1)
  end

  # A stored line in the shape `Roster.build/1` reads. The days keep the stored
  # sign-on and sign-off: they are what makes a moved or re-cut run a stale slot
  # rather than a silently accepted one (INV-13).
  defp line_input(line) do
    %{
      id: line.id,
      line_number: line.line_number,
      operator: line.operator,
      days:
        Enum.map(
          line.days,
          &%{
            weekday: &1.weekday,
            day_type_key: &1.day_type_key,
            run_id: &1.run_id,
            run_sign_on_secs: &1.run_sign_on_secs,
            run_sign_off_secs: &1.run_sign_off_secs
          }
        )
    }
  end

  # Scoped by organization and version like every other read here, and selecting
  # only the roster columns: a caller cannot learn a crew or Block rules value
  # through the roster reader, and those readers cannot learn a roster value.
  defp roster_query(organization_id, gtfs_version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{
        min_rest_minutes: s.min_rest_minutes,
        weekly_hours_warn_above: s.weekly_hours_warn_above,
        roster_day_types: s.roster_day_types
      }
    )
  end
end
