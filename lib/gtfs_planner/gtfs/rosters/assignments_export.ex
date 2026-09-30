defmodule GtfsPlanner.Gtfs.Rosters.AssignmentsExport do
  @moduledoc """
  The `employee_run_dates.txt` rows for one export, and the warning counts the
  export and the Rosters page read together.

  One row is one assigned line working one base-week date: `date`,
  `service_id`, `run_id` and `employee_id`. A date contributes rows only for the
  day type that **is** its weekday's base, so the rows can never name a
  `(service_id, date)` the same ZIP's `calendar_dates_supplement.txt` does not
  list (INV-14). The service ID is that day type's own, and a run signing on
  before midnight moves to the previous date on the day type's `_prev` service,
  which is exactly the shift `Runs.TodsExport` gives the same run in
  `run_events.txt`.

  Three things are deliberately absent from a row's date. A date whose day type
  is not its weekday's base runs different service: nothing is emitted for it, the
  date is reported in `other_service_dates`, and the day type's exported runs
  count as open run-days. A stale slot is left out, because its stored times are
  the only reason it can be called stale. A run with an error finding is left out
  and counted, on the same rule as `run_events.txt`, so the two files can never
  disagree about which runs exist.

  `operator_name` rides on the row for the page's preview only. Step 22 writes
  the four TODS columns and leaves the name behind, so no exported file carries
  an operator's name or seniority number (AC-24).

  `services` is the export's `ids.service_ids`, or `nil` for the page, which
  shows the rows without service IDs. The date shift does not depend on it: a run
  signing on before midnight is dated a day earlier either way.

  Pure: it reads its arguments and calls no repository, clock, file or network.
  Slots, stale states and findings come from `Rosters.Roster.build/1` and runs
  from `Runs.Day.derive/4`'s result; neither is recomputed here (INV-15).
  """

  alias GtfsPlanner.Gtfs.Rosters.Roster

  @type row :: %{
          date: Date.t(),
          service_id: String.t() | nil,
          run_id: String.t(),
          employee_id: String.t(),
          operator_name: String.t()
        }

  @type result :: %{
          rows: [row()],
          other_service_dates: [Date.t()],
          open_run_days: non_neg_integer(),
          unassigned_lines: non_neg_integer(),
          stale_slots: non_neg_integer(),
          left_out_slots: non_neg_integer()
        }

  @doc """
  Expands assigned, non-stale slots over the base week's dates.

  `run_days` is `Runs.Day.derive/4`'s result keyed by day-type key and
  `day_types` is `Blocking.DayTypes.derive/1`'s list; each date is placed by
  membership in a day type's `dates`, because a date belongs to exactly one.

  Rows come back sorted by date, then service ID, run ID and employee ID, so the
  file and the page's preview read in the same order whatever order the day types,
  the lines and the slots arrive in. `other_service_dates` is sorted too, because
  the warning lists its first three dates in date order.
  """
  @spec rows(%{
          required(:roster) => Roster.t(),
          required(:day_types) => [map()],
          required(:run_days) => %{optional(String.t()) => map()},
          required(:services) => %{optional(String.t()) => map()} | nil
        }) :: result()
  def rows(%{roster: roster, day_types: day_types, run_days: run_days, services: services}) do
    exported = exported_runs(run_days)

    days = Enum.map(day_types, &expand_day_type(&1, roster, exported, services))

    %{
      rows:
        days
        |> Enum.flat_map(& &1.rows)
        |> Enum.sort_by(&{&1.date, &1.service_id, &1.run_id, &1.employee_id}),
      other_service_dates:
        days |> Enum.flat_map(& &1.other_service_dates) |> Enum.uniq() |> Enum.sort(),
      open_run_days: Enum.sum(Enum.map(days, & &1.open_run_days)),
      unassigned_lines: Enum.count(roster.lines, &is_nil(&1.operator)),
      stale_slots: roster.summary.stale_slots,
      left_out_slots: left_out_slots(roster)
    }
  end

  # A day type with no exported run has nothing to export and nothing to warn
  # about: its trips were never cut, so a date it happens to hold is not a date
  # "running different service".
  defp expand_day_type(day_type, roster, exported, services) do
    case Map.get(exported, day_type.key, %{}) do
      runs when map_size(runs) == 0 ->
        %{rows: [], other_service_dates: [], open_run_days: 0}

      runs ->
        day_type.dates
        |> Enum.sort()
        |> Enum.reduce(%{rows: [], other_service_dates: [], open_run_days: 0}, fn date, acc ->
          expand_date(date, day_type, roster, runs, services, acc)
        end)
    end
  end

  defp expand_date(date, day_type, roster, runs, services, acc) do
    weekday = Date.day_of_week(date)

    if base?(roster.base_week, weekday, day_type.key) do
      %{acc | rows: acc.rows ++ assigned_rows(weekday, day_type, date, roster, runs, services)}
    else
      %{
        acc
        | other_service_dates: [date | acc.other_service_dates],
          open_run_days: acc.open_run_days + map_size(runs)
      }
    end
  end

  defp base?(base_week, weekday, key) do
    case Map.get(base_week, weekday) do
      %{day_type: %{key: ^key}} -> true
      _no_base -> false
    end
  end

  # One row per assigned line that works this weekday on this day type. A line
  # without an operator is a warning, not a row, and a stale slot is not counted
  # here either: `Roster.build/1` has already decided it cannot be trusted.
  defp assigned_rows(weekday, day_type, date, roster, runs, services) do
    for line <- roster.lines,
        not is_nil(line.operator),
        slot = Map.get(line.slots, weekday),
        slot && slot.state == :ok && slot.day_type_key == day_type.key,
        run = Map.get(runs, slot.run_id),
        do: row(date, day_type, run, line.operator, services)
  end

  # The previous-day shift is the run's, not the date's: a run signing on before
  # midnight belongs to the service day before, so it is dated `d - 1` on the
  # `_prev` service, whose supplement dates are the day type's dates minus one
  # day. Which of the two services to name is decided once, here, the way
  # `Runs.TodsExport.service_for/2` decides it for the same run.
  defp row(date, day_type, run, operator, services) do
    {date, service_id} =
      if run.work.sign_on_secs < 0 do
        {Date.add(date, -1), service(services, day_type.key, :prev_service_id)}
      else
        {date, service(services, day_type.key, :service_id)}
      end

    %{
      date: date,
      service_id: service_id,
      run_id: run.run_id,
      employee_id: operator.employee_id,
      operator_name: operator.display_name
    }
  end

  defp service(nil, _key, _field), do: nil
  defp service(services, key, field), do: services |> Map.get(key, %{}) |> Map.get(field)

  # Indexed once, so a slot resolves its run and its run's exportability in one
  # lookup. The same rule as `run_events.txt`: a run with an error finding is not
  # in the file, so it must not be in this one (INV-14).
  defp exported_runs(run_days) do
    Map.new(run_days, fn {key, derived} ->
      {key, derived.runs |> Enum.reject(&error_run?/1) |> Map.new(&{&1.run_id, &1})}
    end)
  end

  defp error_run?(run), do: Enum.any?(run.findings, &(&1.severity == :error))

  # A slot the roster still trusts whose run the export will drop. Counted per
  # slot, not per row, because the run is dropped from every date it works.
  defp left_out_slots(roster) do
    Enum.count(roster.lines, fn line ->
      not is_nil(line.operator) and
        Enum.any?(line.slots, fn {_weekday, slot} ->
          slot.state == :ok and not is_nil(slot.run) and error_run?(slot.run)
        end)
    end)
  end
end
