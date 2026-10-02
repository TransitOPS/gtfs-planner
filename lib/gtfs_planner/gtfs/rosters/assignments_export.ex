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
  alias GtfsPlanner.Wording

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

  Dates are ordered by `Date.to_iso8601/1`, never by `Enum.sort/1` on the
  structs. `%Date{}` is a map, and Erlang orders maps field by field —
  `calendar`, `day`, `month`, `year` — so sorting the structs themselves puts
  2 March after 1 June. Every date order here is chronological.
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
        |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.service_id, &1.run_id, &1.employee_id}),
      other_service_dates:
        days
        |> Enum.flat_map(& &1.other_service_dates)
        |> Enum.uniq()
        |> Enum.sort_by(&Date.to_iso8601/1),
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
        |> Enum.sort_by(&Date.to_iso8601/1)
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
  # slot, not per row, because the run is dropped from every date it works — and
  # not per line either, because one line can work an errored run on three
  # weekdays and then has three assigned slots missing from the file, not one.
  defp left_out_slots(roster) do
    Enum.reduce(roster.lines, 0, fn line, total -> total + left_out_slot_count(line) end)
  end

  # An unassigned line is not in the file at all, so its slots are not "left out
  # for run errors" either: the `unassigned` sentence is what names that line.
  defp left_out_slot_count(%{operator: nil}), do: 0

  defp left_out_slot_count(line) do
    Enum.count(line.slots, fn {_weekday, slot} ->
      slot.state == :ok and not is_nil(slot.run) and error_run?(slot.run)
    end)
  end

  ## The sentences, shared by the export's warnings and the Rosters page

  # What the file is not, in the words the spec fixes. `planned_note/0` is that
  # sentence on its own because the page shows it whether or not the file has
  # rows: a reader looking at the export section has to be told what the numbers
  # below it mean even when there are none, and a conditional note would leave
  # the section's one sentence about what it is missing whenever it is empty.
  @planned_note "Planned from the pick. Vacations, sick days and extraboard are not included."

  @doc """
  The planned-data note, in the words the export's own warning uses.

  The export raises it as `tods_assignments_planned` only when the file has
  rows; the page draws it above the preview whether or not it does.
  """
  @spec planned_note() :: String.t()
  def planned_note, do: @planned_note

  @doc """
  The roster-line warnings as `{code, sentence}` pairs, in reading order.

  These are the sentences `Gtfs.Export` writes as
  `tods_assignments_*` warnings and the sentences the Rosters page lists, so the
  two cannot drift (INV-14): there is one wording, and `format_date` is the only
  thing that differs between them. The export passes ISO dates (`2026-10-12`);
  the page passes `"Oct 12, 2026"`.

  A warning that has nothing to report is absent rather than zero, and the
  planned note is present only when `rows` is not empty — the same condition the
  export file itself is written under.
  """
  @spec sentences(result(), (Date.t() -> String.t())) :: [{String.t(), String.t()}]
  def sentences(result, format_date \\ &Date.to_iso8601/1) do
    [
      planned_sentence(result),
      other_service_sentence(result, format_date),
      unassigned_sentence(result.unassigned_lines),
      stale_sentence(result.stale_slots),
      left_out_sentence(result.left_out_slots)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp planned_sentence(%{rows: []}), do: nil
  defp planned_sentence(_result), do: {"tods_assignments_planned", @planned_note}

  # The first three dates in date order and "and N more" only when there are
  # more, so a long calendar reports its shape rather than its whole length.
  defp other_service_sentence(%{other_service_dates: []}, _format_date), do: nil

  defp other_service_sentence(%{other_service_dates: dates} = result, format_date) do
    {first_three, rest} = Enum.split(dates, 3)

    listed = first_three |> Enum.map_join(", ", format_date)
    listed = if rest == [], do: listed, else: "#{listed} and #{length(rest)} more"
    open = open_run_days(result.open_run_days)

    detail =
      if length(dates) == 1 do
        "1 date runs different service: #{listed}. No assignment is exported for it; #{open}."
      else
        "#{length(dates)} dates run different service: #{listed}. " <>
          "No assignments are exported for them; #{open}."
      end

    {"tods_assignments_other_service", detail}
  end

  defp open_run_days(1), do: "1 run-day stays open"
  defp open_run_days(n), do: "#{n} run-days stay open"

  defp unassigned_sentence(0), do: nil

  defp unassigned_sentence(n) do
    noun = if n == 1, do: "1 line has", else: "#{n} lines have"
    {"tods_assignments_unassigned", "#{noun} no operator."}
  end

  defp stale_sentence(0), do: nil

  defp stale_sentence(n) do
    verb = if n == 1, do: "was", else: "were"
    {"tods_assignments_stale", "#{n} stale #{Wording.noun(n, "slot")} #{verb} skipped."}
  end

  defp left_out_sentence(0), do: nil

  defp left_out_sentence(n) do
    verb =
      if n == 1, do: "names a run with errors and was", else: "name runs with errors and were"

    {"tods_assignments_left_out", "#{n} assigned #{Wording.noun(n, "slot")} #{verb} left out."}
  end
end
