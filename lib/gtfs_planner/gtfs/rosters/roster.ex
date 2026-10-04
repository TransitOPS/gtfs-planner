defmodule GtfsPlanner.Gtfs.Rosters.Roster do
  @moduledoc """
  Composes a version's roster: its lines' slots, stale states, findings, weekly
  figures, the open work left over, and the summary the page counts from.

  This is **the** roster composition. The page, the writers' availability checks
  and the export all read this one result; none of them walks
  `roster_line_days` or a day type's runs to answer a question already answered
  here (INV-15). Runs themselves are never recomputed — they arrive as
  `Runs.Day.derive/4`'s result, read as `run_days[key].runs` (INV-11).

  ## What a slot says about its run

  A `roster_line_days` row names a run-day and stores the run's sign-on and
  sign-off at the moment it was set, so the composition can tell three kinds of
  drift apart and say which one happened:

  * `:base_changed` — the weekday's base day type is no longer the row's
    `day_type_key`. Checked first, because a run that is also gone or re-cut is
    still first of all a base change.
  * `:run_removed` — the day type no longer derives that run.
  * `:run_changed` — the run is still there but signs on or off at different
    times, which is what a re-cut does to work while keeping the run ID (the
    producer's choice, not this module's).

  A stale slot still counts as a **working day** — the operator is booked, the
  page must still draw the day — but it is left out of weekly paid time, of the
  rest checks and of the export, because none of them can trust the times the
  row carries.

  ## What the checks report

  The three crew rules are `Rosters.Checks`: rest between adjacent working days,
  two consecutive days off in the cyclic week, and weekly paid hours against the
  configured warning. Every finding here is a warning; nothing blocks a
  planner, which is why a short rest is reported on the **later** weekday (the
  day whose run starts too soon) and the stale and error findings name the slot's
  own weekday.

  ## Open work

  A run is open on a weekday when no slot on that weekday — stale or not — holds
  that day type and run ID, so a run that a re-cut has made stale is still the
  planner's to re-set rather than free to hand to somebody else. Groups come
  from `Rosters.BaseWeek.groups/1`, one per base day type, each listing the
  weekdays its runs are still open on.

  Pure: it reads no repository, clock, file or network, and writes nothing. The
  base week, the derived runs, the lines and the rules all arrive as arguments.
  """

  alias GtfsPlanner.Gtfs.Rosters.BaseWeek
  alias GtfsPlanner.Gtfs.Rosters.Checks

  @weekdays 1..7
  @seconds_per_minute 60
  @seconds_per_hour 3_600

  @typedoc "The version's roster rules, as `blocking_settings` stores them."
  @type rules :: %{min_rest_minutes: 480..720, weekly_hours_warn_above: 40..60}

  @typedoc """
  One stored line with its days, as the roster writer reads them.

  `id` and `line_number` are `nil` for a line a caller is composing rather than
  reading: the TODS generator's preview composes proposed lines beside the
  version's own, and neither the row's identity nor its number exists until the
  writer assigns it (`create_line/1` owns the numbering).
  """
  @type line_input :: %{
          id: Ecto.UUID.t() | nil,
          line_number: pos_integer() | nil,
          operator: map() | nil,
          days: [map()]
        }

  @typedoc "Why a slot no longer matches the run it names."
  @type stale_reason :: :base_changed | :run_removed | :run_changed

  @typedoc "One weekday's slot, with the run it still resolves to, if any."
  @type slot :: %{
          weekday: 1..7,
          day_type_key: String.t(),
          run_id: String.t(),
          run: map() | nil,
          stored: Checks.times(),
          state: :ok | {:stale, stale_reason()}
        }

  @typedoc "A warning about a line. Every roster finding is a warning."
  @type finding :: %{
          code: :short_rest | :days_off | :weekly_hours | :stale_slot | :run_has_errors,
          weekdays: [1..7],
          detail: map()
        }

  @typedoc "One composed line: its slots, figures, rest and findings."
  @type line :: %{
          id: Ecto.UUID.t(),
          line_number: pos_integer(),
          operator: map() | nil,
          slots: %{optional(1..7) => slot()},
          days_off: %{groups: [[1..7]], ok?: boolean()},
          paid_secs: non_neg_integer(),
          over_40_secs: non_neg_integer(),
          rest: %{optional(1..7) => %{before_secs: integer() | nil, after_secs: integer() | nil}},
          findings: [finding()]
        }

  @typedoc "A run of a base day type and the weekdays of its group it is still open on."
  @type open_run :: %{run_id: String.t(), run: map(), open_weekdays: [1..7]}

  @typedoc "One base day type's weekdays, label and open work."
  @type group :: %{
          day_type: map(),
          weekdays: [1..7],
          label: String.t(),
          open_runs: [open_run()],
          open_run_days: non_neg_integer()
        }

  @typedoc "The page's figures, all derived from the lines and the open work."
  @type summary :: %{
          lines: non_neg_integer(),
          open_lines: non_neg_integer(),
          run_days_in_lines: non_neg_integer(),
          run_days_total: non_neg_integer(),
          open_by_weekday: %{(1..7) => non_neg_integer()},
          split_days_off: non_neg_integer(),
          lines_with_problems: non_neg_integer(),
          stale_slots: non_neg_integer(),
          weekly_paid:
            %{
              min_secs: non_neg_integer(),
              max_secs: non_neg_integer(),
              avg_secs: non_neg_integer(),
              above_threshold: non_neg_integer()
            }
            | nil
        }

  @typedoc "The whole composition: the page, the writers and the export all read this."
  @type t :: %{
          base_week: map(),
          rules: rules(),
          lines: [line()],
          groups: [group()],
          summary: summary()
        }

  @doc """
  Composes the roster from the base week, the derived runs, the lines and the rules.

  `run_days` is `Runs.Day.derive/4`'s result keyed by day-type key, and the
  lines are the version's `roster_lines` with their days and operator, as
  `line_input()` describes. Lines come back sorted by line number, and each
  line's findings sorted by the weekday they concern and then by code, so the
  grid, the writers and the export read them in the same order.
  """
  @spec build(%{
          base_week: map(),
          run_days: %{optional(String.t()) => map()},
          lines: [line_input()],
          rules: rules()
        }) :: t()
  def build(%{base_week: base_week, run_days: run_days, lines: lines, rules: rules}) do
    runs = index_runs(run_days)

    built =
      lines
      |> Enum.map(&build_line(&1, base_week, runs, rules))
      |> Enum.sort_by(& &1.line_number)

    groups = build_groups(base_week, runs, held_slots(lines))

    %{
      base_week: base_week,
      rules: rules,
      lines: built,
      groups: groups,
      summary: summary(built, base_week, runs, groups, rules)
    }
  end

  # One map from day-type key to run ID to run, so a slot resolves its run in a
  # single lookup instead of a scan of the day's runs.
  defp index_runs(run_days) do
    Map.new(run_days, fn {key, derived} ->
      {key, Map.new(derived.runs, &{&1.run_id, &1})}
    end)
  end

  # Every run-day any line holds, stale or not: this is what makes a run not open
  # on a weekday.
  defp held_slots(lines) do
    for line <- lines, day <- line.days, into: %{} do
      {{day.weekday, day.day_type_key, day.run_id}, true}
    end
  end

  defp build_line(line, base_week, runs, rules) do
    slots = Map.new(line.days, &{&1.weekday, build_slot(&1, base_week, runs)})
    working = Map.keys(slots) |> Enum.sort()
    fresh = Map.filter(slots, fn {_weekday, slot} -> slot.state == :ok end)
    paid_secs = fresh |> Map.values() |> Enum.sum_by(& &1.run.work.paid_secs)
    hours = Checks.weekly_hours(paid_secs, rules.weekly_hours_warn_above)
    days_off = Checks.days_off(working)

    %{
      id: line.id,
      line_number: line.line_number,
      operator: line.operator,
      slots: slots,
      days_off: days_off,
      paid_secs: paid_secs,
      over_40_secs: hours.over_40_secs,
      rest: rest_by_weekday(fresh),
      findings: findings(slots, fresh, days_off, hours, paid_secs, rules)
    }
  end

  defp build_slot(day, base_week, runs) do
    run = runs |> Map.get(day.day_type_key, %{}) |> Map.get(day.run_id)

    %{
      weekday: day.weekday,
      day_type_key: day.day_type_key,
      run_id: day.run_id,
      run: run,
      stored: %{sign_on_secs: day.run_sign_on_secs, sign_off_secs: day.run_sign_off_secs},
      state: slot_state(day, base_week, run)
    }
  end

  # The order is the spec's: a day type that is no longer the weekday's base is
  # reported as that, whatever became of the run as well.
  defp slot_state(day, base_week, run) do
    cond do
      not base?(day, base_week) -> {:stale, :base_changed}
      is_nil(run) -> {:stale, :run_removed}
      re_cut?(day, run) -> {:stale, :run_changed}
      true -> :ok
    end
  end

  defp base?(day, base_week) do
    case Map.get(base_week, day.weekday) do
      %{day_type: %{key: key}} -> key == day.day_type_key
      _no_base -> false
    end
  end

  defp re_cut?(day, run) do
    day.run_sign_on_secs != run.work.sign_on_secs or
      day.run_sign_off_secs != run.work.sign_off_secs
  end

  # Rest either side of each working day, from the run that brackets it. Only
  # adjacent weekdays are compared, so a day off on either side reads as no rest
  # to check rather than as a rest of 24 hours.
  defp rest_by_weekday(fresh) do
    Map.new(fresh, fn {weekday, _slot} ->
      {weekday,
       %{
         before_secs: adjacent_rest(fresh, Checks.previous_weekday(weekday), weekday),
         after_secs: adjacent_rest(fresh, weekday, Checks.next_weekday(weekday))
       }}
    end)
  end

  defp adjacent_rest(fresh, from, to) do
    with {:ok, %{run: %{work: previous}}} <- Map.fetch(fresh, from),
         {:ok, %{run: %{work: next_run}}} <- Map.fetch(fresh, to) do
      Checks.rest_secs(previous, next_run)
    else
      _not_both_working -> nil
    end
  end

  defp findings(slots, fresh, days_off, hours, paid_secs, rules) do
    (Enum.flat_map(Map.values(slots), &stale_finding/1) ++
       Enum.flat_map(Map.values(slots), &error_finding/1) ++
       short_rest_findings(fresh, rules) ++
       days_off_findings(days_off) ++
       weekly_hours_findings(fresh, hours, paid_secs, rules))
    |> Enum.sort_by(&{first_weekday(&1), &1.code})
  end

  defp stale_finding(%{state: {:stale, reason}} = slot) do
    [
      %{
        code: :stale_slot,
        weekdays: [slot.weekday],
        detail: %{
          reason: reason,
          run_id: slot.run_id,
          stored: slot.stored,
          current: current_times(slot.run)
        }
      }
    ]
  end

  defp stale_finding(_fresh_slot), do: []

  defp current_times(nil), do: nil

  defp current_times(run),
    do: %{sign_on_secs: run.work.sign_on_secs, sign_off_secs: run.work.sign_off_secs}

  # A run with an error finding is left out of the export, so the line has to say
  # so here rather than let the planner assign work that will not be exported.
  defp error_finding(%{run: %{findings: run_findings}} = slot) do
    case Enum.filter(run_findings, &(&1.severity == :error)) do
      [] ->
        []

      errors ->
        [
          %{
            code: :run_has_errors,
            weekdays: [slot.weekday],
            detail: %{
              run_id: slot.run_id,
              codes: errors |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort()
            }
          }
        ]
    end
  end

  defp error_finding(_slot_without_a_run), do: []

  defp short_rest_findings(fresh, rules) do
    min_secs = rules.min_rest_minutes * @seconds_per_minute

    fresh
    |> weekday_times()
    |> Checks.short_rests(rules.min_rest_minutes)
    |> Enum.map(fn %{from: from, to: to, rest_secs: rest_secs} ->
      %{
        code: :short_rest,
        weekdays: [to],
        detail: %{from: from, to: to, rest_secs: rest_secs, min_secs: min_secs}
      }
    end)
  end

  defp weekday_times(fresh) do
    Map.new(fresh, fn {weekday, slot} -> {weekday, slot.run.work} end)
  end

  # A line that works every day has no day off at all, and its finding names no
  # weekday; it sorts first rather than claiming a day it has nothing to say
  # about.
  defp days_off_findings(%{ok?: true}), do: []

  defp days_off_findings(%{groups: groups}) do
    [
      %{
        code: :days_off,
        weekdays: groups |> List.flatten() |> Enum.sort(),
        detail: %{groups: groups}
      }
    ]
  end

  defp weekly_hours_findings(_fresh, %{warn?: false}, _paid_secs, _rules), do: []

  defp weekly_hours_findings(fresh, %{over_40_secs: over_40_secs}, paid_secs, rules) do
    [
      %{
        code: :weekly_hours,
        weekdays: fresh |> Map.keys() |> Enum.sort(),
        detail: %{
          paid_secs: paid_secs,
          over_40_secs: over_40_secs,
          warn_above_hours: rules.weekly_hours_warn_above
        }
      }
    ]
  end

  defp first_weekday(%{weekdays: []}), do: 0
  defp first_weekday(%{weekdays: weekdays}), do: Enum.min(weekdays)

  defp build_groups(base_week, runs, held) do
    base_week
    |> BaseWeek.groups()
    |> Enum.map(fn %{day_type: day_type, weekdays: weekdays, label: label} ->
      open_runs = open_runs(day_type, weekdays, runs, held)

      %{
        day_type: day_type,
        weekdays: weekdays,
        label: label,
        open_runs: open_runs,
        open_run_days: Enum.sum(Enum.map(open_runs, &length(&1.open_weekdays)))
      }
    end)
  end

  # The runs keep the order `run_days` gives them, which `Runs.Day.derive/4` has
  # already sorted by sign-on and then run ID, so open work reads in the day's
  # order without this module sorting a list it does not own.
  defp open_runs(day_type, weekdays, runs, held) do
    key = day_type.key

    runs_of(runs, key)
    |> Enum.map(fn run ->
      %{
        run_id: run.run_id,
        run: run,
        open_weekdays: Enum.reject(weekdays, &held_run_day?(held, &1, key, run.run_id))
      }
    end)
    |> Enum.reject(&(&1.open_weekdays == []))
  end

  defp held_run_day?(held, weekday, key, run_id) do
    Map.has_key?(held, {weekday, key, run_id})
  end

  defp runs_of(runs, key), do: runs |> Map.get(key, %{}) |> Map.values()

  defp summary(lines, base_week, runs, groups, rules) do
    paid = lines |> Enum.map(& &1.paid_secs) |> Enum.filter(&(&1 > 0))

    %{
      lines: length(lines),
      open_lines: Enum.count(lines, &is_nil(&1.operator)),
      run_days_in_lines: Enum.sum(Enum.map(lines, &count_fresh(&1))),
      run_days_total: run_days_total(base_week, runs),
      open_by_weekday: open_by_weekday(groups),
      split_days_off: Enum.count(lines, &(&1.days_off.ok? == false)),
      lines_with_problems: Enum.count(lines, &(&1.findings != [])),
      stale_slots: lines |> Enum.map(&count_stale/1) |> Enum.sum(),
      weekly_paid: weekly_paid(paid, rules)
    }
  end

  defp count_fresh(line) do
    Enum.count(line.slots, fn {_weekday, slot} -> slot.state == :ok end)
  end

  defp count_stale(line) do
    Enum.count(line.slots, fn {_weekday, slot} -> match?({:stale, _reason}, slot.state) end)
  end

  # The total is what the base week makes available to put in a line: every
  # derived run of every weekday's base day type, whether or not it is in one.
  defp run_days_total(base_week, runs) do
    Enum.sum(
      for weekday <- @weekdays do
        case Map.get(base_week, weekday) do
          %{day_type: %{key: key}} -> length(runs_of(runs, key))
          _no_base -> 0
        end
      end
    )
  end

  # Counted over the groups rather than from the lines, so a weekday's open
  # figure is the same number the open-work list shows for it.
  defp open_by_weekday(groups) do
    Map.new(@weekdays, fn weekday ->
      {weekday,
       Enum.sum(
         for group <- groups,
             weekday in group.weekdays,
             open_run <- group.open_runs,
             weekday in open_run.open_weekdays,
             do: 1
       )}
    end)
  end

  # Only lines with paid time take part, so a line whose every run is stale is
  # not reported as a line paid nothing: with no line paid, there is no range.
  defp weekly_paid([], _rules), do: nil

  defp weekly_paid(paid_secs, rules) do
    %{
      min_secs: Enum.min(paid_secs),
      max_secs: Enum.max(paid_secs),
      avg_secs: round(Enum.sum(paid_secs) / length(paid_secs)),
      above_threshold:
        Enum.count(paid_secs, &(&1 > rules.weekly_hours_warn_above * @seconds_per_hour))
    }
  end
end
