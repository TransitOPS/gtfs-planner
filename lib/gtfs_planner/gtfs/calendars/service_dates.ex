defmodule GtfsPlanner.Gtfs.Calendars.ServiceDates do
  @moduledoc """
  Pure civil-date evaluation for one native calendar and its date exceptions.

  Every function consumes the native `GtfsPlanner.Gtfs.Calendar` and
  `GtfsPlanner.Gtfs.CalendarDate` shapes and returns plain Elixir data. No repository
  access or presentation text belongs here; `Gtfs.Calendars` and the calendar LiveViews
  share these results instead of deriving dates a second time.

  ## Contracts

    * A weekly range is inclusive at both ends. A weekday column value of `1` marks an
      expected service day and `0` a non-service day; a `nil` calendar has no weekly row.
    * Exception types are `1` (added) and `2` (removed). Persisted rows are unique by
      date, so this module raises `ArgumentError` when one date carries both types.
    * Results are ordered ascending by date and are deterministic. No date span is
      truncated, so a legitimate multi-year schedule is evaluated whole.
    * `active_dates_between/4` bounds membership to an inclusive query window without
      changing it. Only the requested days are enumerated, its result is the window
      restriction of `active_dates/2`, and all supplied input is still validated -
      including exceptions that fall outside the window.
    * Malformed input - a reversed or incomplete weekly range, a non-`Date` exception
      date or an unsupported exception type - raises `ArgumentError`. Callers validate
      editor input before persistence, so a raise here is a programming error rather
      than a rejected user action.
    * Periods are the weekly range minus break intervals and omit segments with no
      remaining expected service date. A break is a maximal run of three or more removed
      expected dates; runs of one or two are holidays. Additions never extend a weekly
      period and are reported as extra days instead.
  """

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate

  @weekday_fields [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
  @min_break_service_days 3
  @ends_soon_days 14
  @date_format "%b %-d, %Y"
  @month_format "%B %Y"
  @week_days 7
  @added 1
  @removed 2
  @state_text %{
    service: "Regular service",
    added: "Service added",
    removed: "No service — removed",
    none: "No service scheduled"
  }

  @type interval :: %{first_date: Date.t(), last_date: Date.t()}

  @type break_interval :: %{
          first_date: Date.t(),
          last_date: Date.t(),
          service_days: pos_integer()
        }

  @type schedule_periods :: %{
          periods: [interval()],
          breaks: [break_interval()],
          holidays: [Date.t()],
          extra_days: [Date.t()],
          removed_days: [Date.t()]
        }

  @type cell_state :: :service | :added | :removed | :none

  @type cell :: %{
          date: Date.t(),
          day: pos_integer(),
          state: cell_state(),
          exception: :added | :removed | nil,
          label: String.t()
        }

  @type month_grid :: %{
          year: pos_integer(),
          month: 1..12,
          title: String.t(),
          weeks: [list(cell() | nil)]
        }

  @type warning ::
          %{reason: :no_service}
          | %{reason: :ended, last_date: Date.t()}
          | %{reason: :ends_soon, last_date: Date.t(), days_remaining: non_neg_integer()}
          | %{
              reason: :coverage_gap,
              first_date: Date.t(),
              last_date: Date.t(),
              service_days: pos_integer()
            }
          | %{reason: :redundant_addition, date: Date.t(), exception: :added}
          | %{reason: :removal_on_nonservice_day, date: Date.t(), exception: :removed}
          | %{reason: :outside_range, date: Date.t(), exception: :added | :removed}

  @doc """
  Returns every effective service date sorted ascending and unique.

  The base set is the inclusive weekly range; additions inside or outside it are
  included, and removals subtract service from both the weekly base and additions.
  """
  @spec active_dates(Calendar.t() | nil, [CalendarDate.t()]) :: [Date.t()]
  def active_dates(calendar, exceptions) do
    calendar
    |> evaluate(exceptions)
    |> Map.fetch!(:active)
  end

  @doc """
  Returns the effective service dates inside an inclusive query window.

  Membership matches `active_dates/2` for every date the window covers: the weekly
  range and weekday flags supply the base, additions inside or outside the weekly
  range count, and removals subtract from both. The window only bounds the answer,
  so a short request against a multi-year calendar enumerates the requested days
  rather than the whole schedule. Supplied input is validated exactly as
  `active_dates/2` validates it, so a malformed weekly range or a malformed, or
  contradictory, exception entry still raises even when it falls outside the
  window. A `last` that precedes `first` raises `ArgumentError`.
  """
  @spec active_dates_between(Calendar.t() | nil, [CalendarDate.t()], Date.t(), Date.t()) :: [
          Date.t()
        ]
  def active_dates_between(calendar, exceptions, %Date{} = first, %Date{} = last) do
    if Date.compare(first, last) == :gt do
      raise ArgumentError,
            "query window ends before it starts: " <>
              "#{Date.to_iso8601(last)} < #{Date.to_iso8601(first)}"
    end

    {added, removed} = normalize_exceptions(exceptions)

    calendar
    |> base_dates_between(first, last)
    |> MapSet.union(within_window(added, first, last))
    |> MapSet.difference(within_window(removed, first, last))
    |> sort_dates()
  end

  @doc """
  Returns derived weekly periods, breaks, holidays and one-off dates for one calendar.

  Periods are the weekly range minus break intervals and omit segments without a
  remaining baseline date. Additions are listed as extra days and removals outside a
  break as removed days. A calendar without a weekly row returns empty weekly
  structures and every effective addition as an extra day.
  """
  @spec periods(Calendar.t() | nil, [CalendarDate.t()]) :: schedule_periods()
  def periods(calendar, exceptions) do
    calendar
    |> evaluate(exceptions)
    |> Map.take([:periods, :breaks, :holidays, :extra_days, :removed_days])
  end

  @doc """
  Builds one Monday-first month grid for the month containing `month`.

  Each week holds seven entries padded with `nil` and every civil day of the month
  appears exactly once with its exact accessible label. Cell state describes effective
  service (`:service` from the weekly baseline or `:added` from an addition) or its
  absence (`:removed` for an explicit removal, `:none` otherwise). The `exception`
  field identifies a date change that has no effect on the effective state, such as an
  addition on an already-served weekday.
  """
  @spec month_grid(Calendar.t() | nil, [CalendarDate.t()], Date.t()) :: month_grid()
  def month_grid(calendar, exceptions, %Date{} = month) do
    evaluation = evaluate(calendar, exceptions)
    first_date = Date.new!(month.year, month.month, 1)
    leading_blanks = Date.day_of_week(first_date) - 1

    cells =
      for day <- 1..Date.days_in_month(first_date) do
        Date.new!(month.year, month.month, day)
        |> grid_cell(evaluation)
      end

    weeks =
      (List.duplicate(nil, leading_blanks) ++ cells)
      |> Enum.chunk_every(@week_days)
      |> Enum.map(fn week -> week ++ List.duplicate(nil, @week_days - length(week)) end)

    %{
      year: month.year,
      month: month.month,
      title: format_date(first_date, @month_format),
      weeks: weeks
    }
  end

  @doc """
  Explains the effective schedule at an explicit `today`.

  Reports `:no_service`, `:ended` or `:ends_soon` from the effective last date, one
  `:coverage_gap` per derived break, and the exception reasons that need review:
  redundant additions, removals on non-service days and exceptions outside the weekly
  range. Warnings appear in that fixed order with dates ascending.
  """
  @spec warnings(Calendar.t() | nil, [CalendarDate.t()], Date.t()) :: [warning()]
  def warnings(calendar, exceptions, %Date{} = today) do
    evaluation = evaluate(calendar, exceptions)

    no_service_warnings(evaluation) ++
      expiry_warnings(evaluation, today) ++
      coverage_gap_warnings(evaluation) ++ exception_warnings(calendar, evaluation)
  end

  # -- evaluation -------------------------------------------------------------

  defp evaluate(calendar, exceptions) do
    {added, removed} = normalize_exceptions(exceptions)
    base = base_dates(calendar)
    base_set = MapSet.new(base)

    active =
      base_set |> MapSet.union(added) |> MapSet.difference(removed) |> sort_dates()

    {breaks, holidays} = removed_runs(base, removed)

    %{
      base: base_set,
      added: added,
      removed: removed,
      active: active,
      breaks: breaks,
      holidays: holidays,
      periods: periods_between(calendar, breaks, base, removed),
      extra_days: added |> MapSet.difference(base_set) |> sort_dates(),
      removed_days: removed |> Enum.reject(&inside_break?(&1, breaks)) |> sort_dates()
    }
  end

  defp normalize_exceptions(exceptions) do
    {added, removed} =
      Enum.reduce(exceptions, {MapSet.new(), MapSet.new()}, fn exception, {added, removed} ->
        date = exception_date!(exception)

        case exception_type!(exception) do
          @added -> {MapSet.put(added, date), removed}
          @removed -> {added, MapSet.put(removed, date)}
        end
      end)

    conflicting = added |> MapSet.intersection(removed) |> sort_dates()

    if conflicting != [] do
      raise ArgumentError,
            "conflicting exception types for #{Enum.map_join(conflicting, ", ", &Date.to_iso8601/1)}"
    end

    {added, removed}
  end

  defp exception_date!(%{date: %Date{} = date}), do: date

  defp exception_date!(exception) do
    raise ArgumentError, "expected a calendar date with a Date value, got: #{inspect(exception)}"
  end

  defp exception_type!(%{exception_type: @added}), do: @added
  defp exception_type!(%{exception_type: @removed}), do: @removed

  defp exception_type!(exception) do
    raise ArgumentError,
          "expected exception_type 1 (added) or 2 (removed), got: #{inspect(exception)}"
  end

  defp base_dates(calendar) do
    case weekly_bounds(calendar) do
      nil ->
        []

      {start_date, end_date} ->
        start_date |> Date.range(end_date) |> Enum.filter(&service_weekday?(calendar, &1))
    end
  end

  # Validates the weekly row exactly as the full-calendar path does and returns its
  # inclusive bounds, or `nil` for dates-only service. Bounded callers reuse it so a
  # query window disjoint from a malformed weekly range cannot hide the defect.
  defp weekly_bounds(nil), do: nil

  defp weekly_bounds(%Calendar{start_date: %Date{} = start_date, end_date: %Date{} = end_date}) do
    if Date.compare(start_date, end_date) == :gt do
      raise ArgumentError,
            "calendar weekly range ends before it starts: " <>
              "#{Date.to_iso8601(end_date)} < #{Date.to_iso8601(start_date)}"
    end

    {start_date, end_date}
  end

  defp weekly_bounds(%Calendar{} = calendar) do
    raise ArgumentError,
          "calendar weekly range needs both start_date and end_date, service: #{inspect(calendar.service_id)}"
  end

  defp weekly_bounds(other) do
    raise ArgumentError, "expected a Calendar struct or nil, got: #{inspect(other)}"
  end

  defp base_dates_between(calendar, first, last) do
    with {start_date, end_date} <- weekly_bounds(calendar),
         {from, to} <- overlapping_bounds({start_date, end_date}, first, last) do
      from |> Date.range(to) |> Enum.filter(&service_weekday?(calendar, &1)) |> MapSet.new()
    else
      # Dates-only service, or a query window that misses the weekly range entirely.
      nil -> MapSet.new()
    end
  end

  defp overlapping_bounds({start_date, end_date}, first, last) do
    from = later_date(start_date, first)
    to = earlier_date(end_date, last)

    if Date.compare(from, to) == :gt, do: nil, else: {from, to}
  end

  defp later_date(left, right), do: if(Date.compare(left, right) == :gt, do: left, else: right)

  defp earlier_date(left, right), do: if(Date.compare(left, right) == :lt, do: left, else: right)

  defp within_window(dates, first, last) do
    MapSet.new(
      Enum.filter(dates, fn date ->
        Date.compare(date, first) != :lt and Date.compare(date, last) != :gt
      end)
    )
  end

  defp service_weekday?(calendar, date) do
    Map.fetch!(calendar, Enum.at(@weekday_fields, Date.day_of_week(date) - 1)) == 1
  end

  defp sort_dates(dates), do: Enum.sort_by(dates, & &1, Date)

  defp removed_runs(base, removed) do
    {long_runs, short_runs} =
      base
      |> Enum.chunk_by(&MapSet.member?(removed, &1))
      |> Enum.filter(fn [first | _rest] -> MapSet.member?(removed, first) end)
      |> Enum.split_with(fn run -> length(run) >= @min_break_service_days end)

    breaks =
      Enum.map(long_runs, fn run ->
        %{first_date: hd(run), last_date: List.last(run), service_days: length(run)}
      end)

    {breaks, List.flatten(short_runs)}
  end

  defp periods_between(nil, _breaks, _base, _removed), do: []

  defp periods_between(
         %Calendar{start_date: start_date, end_date: end_date},
         breaks,
         base,
         removed
       ) do
    clean_base = Enum.reject(base, &MapSet.member?(removed, &1))

    {segments, cursor} =
      Enum.reduce(breaks, {[], start_date}, fn period_break, {segments, cursor} ->
        segments = prepend_segment(segments, cursor, Date.add(period_break.first_date, -1))
        {segments, Date.add(period_break.last_date, 1)}
      end)

    segments
    |> prepend_segment(cursor, end_date)
    |> Enum.reverse()
    |> keep_segments_with_baseline(clean_base)
  end

  defp prepend_segment(segments, from, to) do
    if Date.compare(from, to) == :gt,
      do: segments,
      else: [%{first_date: from, last_date: to} | segments]
  end

  defp keep_segments_with_baseline(segments, clean_base) do
    {kept, _remaining} =
      Enum.reduce(segments, {[], clean_base}, fn segment, {kept, clean} ->
        {in_segment, remaining} = take_segment_baseline(clean, segment)
        {prepend_if_baseline(kept, segment, in_segment), remaining}
      end)

    Enum.reverse(kept)
  end

  defp take_segment_baseline(clean, segment) do
    Enum.split_while(clean, fn date -> Date.compare(date, segment.last_date) != :gt end)
  end

  defp prepend_if_baseline(kept, segment, in_segment) do
    if Enum.any?(in_segment, fn date -> Date.compare(date, segment.first_date) != :lt end) do
      [segment | kept]
    else
      kept
    end
  end

  defp inside_break?(date, breaks) do
    Enum.any?(breaks, fn period_break ->
      Date.compare(date, period_break.first_date) != :lt and
        Date.compare(date, period_break.last_date) != :gt
    end)
  end

  # -- month grid -------------------------------------------------------------

  defp grid_cell(date, evaluation) do
    state = cell_state(date, evaluation)

    %{
      date: date,
      day: date.day,
      state: state,
      exception: exception_symbol(date, evaluation),
      label: "#{format_date(date, @date_format)}: #{Map.fetch!(@state_text, state)}"
    }
  end

  # The `Calendar` alias names the native schema, so the stdlib formatter is qualified.
  defp format_date(date, format), do: Elixir.Calendar.strftime(date, format)

  defp cell_state(date, %{base: base, added: added, removed: removed}) do
    cond do
      MapSet.member?(removed, date) -> :removed
      MapSet.member?(base, date) -> :service
      MapSet.member?(added, date) -> :added
      true -> :none
    end
  end

  defp exception_symbol(date, %{added: added, removed: removed}) do
    cond do
      MapSet.member?(removed, date) -> :removed
      MapSet.member?(added, date) -> :added
      true -> nil
    end
  end

  # -- warnings ---------------------------------------------------------------

  defp no_service_warnings(%{active: []}), do: [%{reason: :no_service}]
  defp no_service_warnings(_evaluation), do: []

  defp expiry_warnings(%{active: []}, _today), do: []

  defp expiry_warnings(%{active: active}, today) do
    last_date = List.last(active)
    days_remaining = Date.diff(last_date, today)

    cond do
      days_remaining < 0 ->
        [%{reason: :ended, last_date: last_date}]

      days_remaining <= @ends_soon_days ->
        [%{reason: :ends_soon, last_date: last_date, days_remaining: days_remaining}]

      true ->
        []
    end
  end

  defp coverage_gap_warnings(%{breaks: breaks}) do
    Enum.map(breaks, fn period_break ->
      %{
        reason: :coverage_gap,
        first_date: period_break.first_date,
        last_date: period_break.last_date,
        service_days: period_break.service_days
      }
    end)
  end

  defp exception_warnings(calendar, %{added: added, removed: removed, base: base}) do
    additions = addition_warnings(calendar, added, base)
    removals = removal_warnings(calendar, removed, base)

    Enum.sort_by(additions ++ removals, fn warning ->
      {reason_rank(warning.reason), {warning.date.year, warning.date.month, warning.date.day}}
    end)
  end

  defp addition_warnings(calendar, added, base) do
    Enum.flat_map(added, fn date ->
      cond do
        MapSet.member?(base, date) ->
          [%{reason: :redundant_addition, date: date, exception: :added}]

        outside_range?(calendar, date) ->
          [%{reason: :outside_range, date: date, exception: :added}]

        true ->
          []
      end
    end)
  end

  defp removal_warnings(calendar, removed, base) do
    Enum.flat_map(removed, fn date ->
      cond do
        MapSet.member?(base, date) ->
          []

        outside_range?(calendar, date) ->
          [%{reason: :outside_range, date: date, exception: :removed}]

        true ->
          [%{reason: :removal_on_nonservice_day, date: date, exception: :removed}]
      end
    end)
  end

  defp reason_rank(:redundant_addition), do: 0
  defp reason_rank(:removal_on_nonservice_day), do: 1
  defp reason_rank(:outside_range), do: 2

  defp outside_range?(nil, _date), do: false

  defp outside_range?(%Calendar{start_date: start_date, end_date: end_date}, date) do
    Date.compare(date, start_date) == :lt or Date.compare(date, end_date) == :gt
  end
end
