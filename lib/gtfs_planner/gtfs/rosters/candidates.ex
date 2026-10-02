defmodule GtfsPlanner.Gtfs.Rosters.Candidates do
  @moduledoc """
  Decides what a planner may build: the runs a slot can take, and whether a
  builder is allowed to make the change it is offering (domain rule 5).

  This is **the** availability owner. "Set Mon–Fri to run N", "Create Mon–Fri
  line" and "Add to line" all read these four functions, and so do the writers,
  so a disabled button and a refused write are one computation rather than two
  that can disagree. Nothing here writes: a refusal is a value the writer turns
  into "nothing changed".

  Every answer is computed from the one roster composition
  `Rosters.Roster.build/1` produced (INV-15) — a slot's stored run, its rest
  either side, the base week, the open work and the rules all arrive inside that
  `Roster.t()`. No run is re-derived and no rest rule is re-invented: the rest
  arithmetic and the "which adjacent pairs are short" decision are
  `Rosters.Checks` (INV-11, and the cross-step contract this card names).

  ## The refusal order is the planner's

  A builder is refused for the first thing that is wrong, in a fixed order, so
  the message names the thing to fix first rather than the first thing a
  function happened to test:

  1. `{:unknown_run, id}` — the run is not one of the day type's runs, so there
     is no work to place.
  2. `:single_day_group` — the weekday's group is one day, so "set the group"
     would set one slot and imply a rule it has none of.
  3. `{:run_held, weekday, line_number}` — another line already works that run
     that day. A run is on at most one line per weekday.
  4. `{:day_filled, weekday, run_id}` — the line already works a *different* run
     that day, which the group would overwrite.
  5. `{:short_rest, from, to, rest_secs, run_id}` — the week the change would
     leave has an adjacent pair under the minimum rest.

  A slot is judged as it stands, not as it was set: a slot still holding the
  **same** run does not fill its day (re-setting it is how a re-cut run is
  accepted), but a slot holding another run fills its day whether it is fresh or
  stale. Short rest is checked over the **whole resulting week**, not only the
  pair the change touches, so a builder never leaves a week that fails the rule
  even where the fault was already there.

  Pure: it reads no repository, clock, file or network, and writes nothing.
  """

  alias GtfsPlanner.Gtfs.Rosters.Checks
  alias GtfsPlanner.Gtfs.Rosters.Roster

  @seconds_per_minute 60

  @typedoc "Why a builder cannot do what it was asked to do."
  @type refusal ::
          {:unknown_run, String.t()}
          | {:no_base, 1..7}
          | :single_day_group
          | {:run_held, 1..7, pos_integer()}
          | {:day_filled, 1..7, String.t()}
          | {:short_rest, 1..7, 1..7, integer(), String.t()}

  @typedoc "One run offered for a slot, and the rest it would leave either side."
  @type candidate :: %{
          run_id: String.t(),
          run: map(),
          rest_before_secs: integer() | nil,
          rest_after_secs: integer() | nil,
          short?: boolean()
        }

  @doc """
  The runs a weekday's slot can take, the slot as it stands, and its group.

  `current` is the line's slot on that weekday — which may be a stale slot, so
  the drawer can say which kind — and `group` is the weekday's base-day-type
  group, or `nil` when the weekday has no base day type at all.

  The candidates are the weekday's **open** runs (nothing holds them that day)
  plus the run the slot already names when it belongs to the weekday's own base
  day type, so a re-cut run the planner has to re-set is still on offer. Each
  carries the rest it would leave against the line's non-stale neighbours either
  side, and `short?` says whether either of them is under the minimum.

  The order is the one a planner chooses by: how close the run's sign-on is to
  the middle of the line's own week, so a run that fits the shape of the rest of
  the line is offered first. A line with no other working day has no middle, and
  the runs read in sign-on order instead. `run_id` settles a tie.
  """
  @spec slot_candidates(Roster.t(), Ecto.UUID.t(), 1..7) :: %{
          current: Roster.slot() | nil,
          group: %{weekdays: [1..7], label: String.t()} | nil,
          candidates: [candidate()]
        }
  def slot_candidates(roster, line_id, weekday) do
    line = find_line(roster, line_id)
    group = weekday_group(roster, weekday)

    %{
      current: line && Map.get(line.slots, weekday),
      group: group && %{weekdays: group.weekdays, label: group.label},
      candidates:
        roster
        |> offered_runs(line, group, weekday)
        |> Enum.map(&candidate(roster, line, weekday, &1))
        |> sort_candidates(median_sign_on(line, weekday))
    }
  end

  @doc """
  Whether the line may take the run on the weekday's whole group, and why not.

  The group is every weekday that shares the slot weekday's base day type, and
  the change replaces each of those weekdays' slots. `:ok` means the writers may
  proceed; a refusal comes back in the order `moduledoc` gives.

  A line id the roster does not hold is `:not_found`, the same answer the
  writers give for a missing or foreign line, rather than a new refusal the
  roster does not own.
  """
  @spec group_availability(Roster.t(), Ecto.UUID.t(), 1..7, String.t()) ::
          :ok | {:error, refusal() | :not_found}
  def group_availability(roster, line_id, weekday, run_id) do
    case find_line(roster, line_id) do
      nil -> {:error, :not_found}
      line -> decide_group(roster, line, weekday, run_id)
    end
  end

  @doc """
  Whether a new line may be built from the run, and on which weekdays.

  The weekdays are those whose base day type is the run's own, so "Create Mon–Fri
  line" creates exactly the group the run belongs to. A new line has no slots
  yet, so the only things that can refuse it are an unknown run, a day type no
  weekday is based on, a weekday where another line already holds the run, and
  the short rest the run would leave between its own consecutive days.
  """
  @spec new_line_availability(Roster.t(), String.t(), String.t()) ::
          {:ok, [1..7]} | {:error, refusal()}
  def new_line_availability(roster, day_type_key, run_id) do
    group = Enum.find(roster.groups, &(&1.day_type.key == day_type_key))

    with {:ok, run} <- fetch_run(known_runs(roster, day_type_key), run_id),
         {:ok, weekdays} <- group_weekdays(group),
         :ok <- check_held(roster, weekdays, day_type_key, run_id, nil),
         :ok <- check_rest(roster, new_week(weekdays, run_id, run)) do
      {:ok, weekdays}
    end
  end

  @doc """
  The lines an open run can be added to on a weekday, best fit first.

  A line qualifies when it has no slot on that weekday at all — a stale slot is
  still a day the line works, so it is not one of these. Each row carries the
  rest the run would leave against that line's non-stale neighbours, and the
  lines that would keep every rest come first, then the line with the least paid
  time, so adding work spreads it rather than loading the busiest line. Line
  number settles a tie.
  """
  @spec lines_for_open_run(Roster.t(), String.t(), 1..7) :: [
          %{
            line: Roster.line(),
            rest_before_secs: integer() | nil,
            rest_after_secs: integer() | nil,
            short?: boolean()
          }
        ]
  def lines_for_open_run(roster, run_id, weekday) do
    case Enum.find(open_runs_on(roster, weekday), &(&1.run_id == run_id)) do
      nil ->
        []

      run ->
        roster.lines
        |> Enum.reject(&Map.has_key?(&1.slots, weekday))
        |> Enum.map(&line_row(roster, &1, weekday, run))
        |> Enum.sort_by(&{&1.short?, &1.line.paid_secs, &1.line.line_number})
    end
  end

  # The refusal chain for "set this group on this line", in the moduledoc's
  # order. Each check answers `:ok` or `{:error, refusal}`, so the first failure
  # is the one the planner is told about.
  defp decide_group(roster, line, weekday, run_id) do
    group = weekday_group(roster, weekday)
    key = group && group.day_type.key

    with {:ok, run} <- fetch_run(known_runs(roster, key), run_id),
         :ok <- check_group_size(group),
         :ok <- check_held(roster, group.weekdays, key, run_id, line.id),
         :ok <- check_filled(line, group.weekdays, run_id) do
      check_rest(roster, proposed_week(line, group.weekdays, run_id, run))
    end
  end

  defp fetch_run(known, run_id) do
    case Map.fetch(known, run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, {:unknown_run, run_id}}
    end
  end

  defp check_group_size(nil), do: {:error, :single_day_group}
  defp check_group_size(%{weekdays: [_only_day]}), do: {:error, :single_day_group}
  defp check_group_size(_group), do: :ok

  # A day type no weekday is based on cannot become a line: there is no week for
  # it to repeat. The refusal type carries a weekday and this case has none to
  # name, so it says Monday — the first weekday of the week, and the only answer
  # the type allows. The open-work cards are built from the groups themselves, so
  # a planner cannot reach this case; it is a guard against a caller's key that
  # has drifted from the base week.
  defp group_weekdays(nil), do: {:error, {:no_base, 1}}
  defp group_weekdays(group), do: {:ok, group.weekdays}

  # The first weekday of the group where a line other than the one being built on
  # already works that run. The line being built on is not a holder: it is the
  # line the change is for, and a `nil` line id is the new line, which holds
  # nothing yet.
  defp check_held(roster, weekdays, key, run_id, line_id) do
    holder =
      Enum.find_value(weekdays, fn weekday ->
        case Enum.find_value(roster.lines, &holder_on?(&1, weekday, key, run_id, line_id)) do
          nil -> nil
          line_number -> {weekday, line_number}
        end
      end)

    case holder do
      nil -> :ok
      {weekday, line_number} -> {:error, {:run_held, weekday, line_number}}
    end
  end

  defp holder_on?(line, weekday, key, run_id, line_id) do
    if line.id != line_id and holds?(line, weekday, key, run_id), do: line.line_number
  end

  defp holds?(line, weekday, key, run_id) do
    case Map.get(line.slots, weekday) do
      %{day_type_key: ^key, run_id: ^run_id} -> true
      _no_slot -> false
    end
  end

  # The first group weekday the line already works a different run on, stale or
  # not: a day off is the only thing a group may fill.
  defp check_filled(line, weekdays, run_id) do
    case Enum.find(weekdays, &filled_on?(line, &1, run_id)) do
      nil -> :ok
      weekday -> {:error, {:day_filled, weekday, line.slots[weekday].run_id}}
    end
  end

  defp filled_on?(line, weekday, run_id) do
    case Map.get(line.slots, weekday) do
      nil -> false
      slot -> slot.run_id != run_id
    end
  end

  defp check_rest(roster, week) do
    case Checks.short_rests(times_of(week), roster.rules.min_rest_minutes) do
      [] ->
        :ok

      [%{from: from, to: to, rest_secs: rest_secs} | _rest] ->
        # The refusal names the run that starts too soon, which is the one the
        # later weekday of the pair works.
        {:error, {:short_rest, from, to, rest_secs, week[to].run_id}}
    end
  end

  defp times_of(week) do
    Map.new(week, fn {weekday, day} -> {weekday, day.work} end)
  end

  # The week the change would leave: the line's non-stale slots, with every
  # group weekday replaced by the run. A stale slot on a group day is replaced
  # like any other, and a stale slot outside it is left out because its times
  # are the ones the slot was set with, not the run's.
  defp proposed_week(line, weekdays, run_id, run) do
    keep =
      for {weekday, slot} <- slots(line),
          slot.state == :ok,
          weekday not in weekdays,
          do: {weekday, %{run_id: slot.run_id, work: slot.run.work}}

    Map.merge(Map.new(keep), new_week(weekdays, run_id, run))
  end

  defp new_week(weekdays, run_id, run) do
    Map.new(weekdays, &{&1, %{run_id: run_id, work: run.work}})
  end

  # The runs a slot may take: the weekday's open runs, plus the run its own slot
  # names, so a run the planner has to re-set is still on offer. A slot of
  # another day type is not a proposal for this weekday — `current` already
  # reports it — and a slot whose run no longer exists offers nothing to place.
  defp offered_runs(roster, line, group, weekday) do
    key = group && group.day_type.key
    known = known_runs(roster, key)

    (Enum.map(open_runs_on(roster, weekday), & &1.run_id) ++ current_run_ids(line, weekday, key))
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(known, &1))
    |> Enum.map(&Map.fetch!(known, &1))
  end

  defp current_run_ids(line, weekday, key) do
    case line && Map.get(line.slots, weekday) do
      %{day_type_key: ^key, run_id: run_id} -> [run_id]
      _no_slot_of_this_base -> []
    end
  end

  # Every run of the day type the roster knows about, open or held. A run held
  # somewhere is still a run: knowing it is what lets a builder say the run is
  # already on line 3 rather than that it does not exist.
  defp known_runs(_roster, nil), do: %{}

  defp known_runs(roster, key) do
    held =
      for line <- roster.lines,
          slot <- Map.values(line.slots),
          slot.day_type_key == key,
          not is_nil(slot.run),
          into: %{},
          do: {slot.run_id, slot.run}

    open =
      for group <- roster.groups,
          group.day_type.key == key,
          open_run <- group.open_runs,
          into: %{},
          do: {open_run.run_id, open_run.run}

    Map.merge(held, open)
  end

  defp open_runs_on(roster, weekday) do
    for group <- roster.groups,
        weekday in group.weekdays,
        open_run <- group.open_runs,
        weekday in open_run.open_weekdays,
        do: open_run.run
  end

  defp weekday_group(roster, weekday) do
    Enum.find(roster.groups, &(weekday in &1.weekdays))
  end

  defp find_line(roster, line_id) do
    Enum.find(roster.lines, &(&1.id == line_id))
  end

  defp slots(nil), do: []
  defp slots(line), do: Map.to_list(line.slots)

  defp candidate(roster, line, weekday, run) do
    before_secs = rest_before(line, Checks.previous_weekday(weekday), run)
    after_secs = rest_after(line, Checks.next_weekday(weekday), run)
    min_secs = roster.rules.min_rest_minutes * @seconds_per_minute

    %{
      run_id: run.run_id,
      run: run,
      rest_before_secs: before_secs,
      rest_after_secs: after_secs,
      short?: Enum.any?([before_secs, after_secs], &(is_integer(&1) and &1 < min_secs))
    }
  end

  # The rest a run would leave against the weekday before it, and against the
  # weekday after it. `nil` where the line does not work that day: a day off
  # either side is never short, so there is nothing to check.
  defp rest_before(line, weekday, run) do
    case line && Map.get(line.slots, weekday) do
      %{state: :ok, run: %{work: previous}} -> Checks.rest_secs(previous, run.work)
      _day_off -> nil
    end
  end

  defp rest_after(line, weekday, run) do
    case line && Map.get(line.slots, weekday) do
      %{state: :ok, run: %{work: next_run}} -> Checks.rest_secs(run.work, next_run)
      _day_off -> nil
    end
  end

  defp line_row(roster, line, weekday, run) do
    rest = candidate(roster, line, weekday, run)

    %{
      line: line,
      rest_before_secs: rest.rest_before_secs,
      rest_after_secs: rest.rest_after_secs,
      short?: rest.short?
    }
  end

  # The middle sign-on of the line's other working days, the upper one of an even
  # count. `nil` for a line with no other non-stale working day, which is what
  # falls back to sign-on order.
  defp median_sign_on(line, weekday) do
    sign_ons =
      for {other, slot} <- slots(line),
          other != weekday,
          slot.state == :ok,
          do: slot.run.work.sign_on_secs

    case Enum.sort(sign_ons) do
      [] -> nil
      sorted -> Enum.at(sorted, div(length(sorted), 2))
    end
  end

  defp sort_candidates(candidates, nil),
    do: Enum.sort_by(candidates, &{&1.run.work.sign_on_secs, &1.run_id})

  defp sort_candidates(candidates, median),
    do: Enum.sort_by(candidates, &{abs(&1.run.work.sign_on_secs - median), &1.run_id})
end
