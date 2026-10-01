defmodule GtfsPlanner.Alerts.Recurrence do
  @max_span_days 366
  @max_occurrences 400

  @moduledoc """
  Expands an alert's timing answer into the civil dates and times it actually
  applies (R12, CR-7).

  Everything here is a civil `Date`, `Time` and `NaiveDateTime`. Nothing converts
  a time between zones and nothing resolves an offset or a DST transition,
  because this package only saves and views alerts: the zone name stays on the
  timing answer and the wall clock the agency wrote down is the wall clock that
  applies. A range whose end time is at or before its start time ends on the
  next civil day, and an all-day answer is the whole civil date with no time of
  day at all.

  `occurrences/1` is deliberately bounded. A pattern spanning more than
  #{@max_span_days} days, or one that would expand to more than
  #{@max_occurrences} occurrences, returns `{:error, :too_many}` before the
  occurrence list is built, so an unbounded answer cannot exhaust memory before
  the editor has a chance to refuse it. An answer missing the value its pattern
  needs returns `{:error, :incomplete}`.

  `date_range/1` is the derived `{first_date, last_date}` the alerts list groups
  its tabs by. A current alert whose end is estimated or unknown has no last
  date, because it is still running and must never be grouped as Past, and a
  cancelled-trips alert takes its range from the service dates of the departures
  it names.

  These are pure derivations over an `Alert` or a `TimingAnswer` struct: nothing
  here reads the database, writes a row or contacts an external service.
  """

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.TimingAnswer

  @weekday_names ~w(Mon Tue Wed Thu Fri Sat Sun)
  @month_names ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @type occurrence :: %{
          date: Date.t(),
          starts: NaiveDateTime.t() | nil,
          ends: NaiveDateTime.t() | nil,
          all_day?: boolean()
        }

  @doc """
  Expands a timing answer into the occurrences it describes, in date order.

  A `:weekly` answer is every chosen weekday across `weeks` whole weeks from its
  first date, minus the removed dates and plus the added dates, each appearing
  once. A `:continuous` answer is the single period between its first and last
  date. An answer with no pattern is a current alert, which is the one period
  between its start date and its confirmed end date, if it has one.

  A removed date is never returned, even when it is also added, because the
  operator removed it last.
  """
  @spec occurrences(TimingAnswer.t()) ::
          {:ok, [occurrence()]} | {:error, :too_many | :incomplete}
  def occurrences(%TimingAnswer{pattern: :weekly} = timing) do
    with {:ok, first_date} <- fetch_date(timing.first_date),
         {:ok, weeks} <- fetch_weeks(timing.weeks),
         {:ok, _weekdays} <- fetch_weekdays(timing.weekdays) do
      last_date = Date.add(first_date, weeks * 7 - 1)

      if span_days(first_date, last_date) > @max_span_days do
        {:error, :too_many}
      else
        case weekly_parts(timing) |> Map.fetch!(:dates) |> limit_occurrences() do
          {:error, reason} -> {:error, reason}
          {:ok, dates} -> build_occurrences(timing, dates)
        end
      end
    end
  end

  def occurrences(%TimingAnswer{pattern: :continuous} = timing) do
    with {:ok, first_date} <- fetch_date(timing.first_date),
         {:ok, last_date} <- fetch_date(timing.last_date) do
      case span_days(first_date, last_date) do
        days when days <= 0 -> {:error, :incomplete}
        days when days > @max_span_days -> {:error, :too_many}
        _days -> single_occurrence(timing, first_date, last_date)
      end
    end
  end

  def occurrences(%TimingAnswer{pattern: nil} = timing) do
    with {:ok, start_date} <- fetch_date(timing.start_date) do
      end_date = if timing.end_kind == :confirmed, do: timing.end_date, else: nil
      single_occurrence(timing, start_date, end_date || start_date)
    end
  end

  @doc """
  Returns the date riders are told from (AC-20).

  The answer's own `notice_on` when it has one, because that is what the editor
  chose. Otherwise the later of the agency's `today` and seven days before the
  first date the pattern applies: an alert is never told before it can be
  published, and never more than a week early by default. A `today` is read in
  the agency's own zone by the caller, so nothing here converts a time (CR-7).
  """
  @spec notice_on(TimingAnswer.t() | nil, Date.t()) :: Date.t()
  def notice_on(%TimingAnswer{notice_on: %Date{} = notice_on}, _today), do: notice_on

  def notice_on(%TimingAnswer{first_date: %Date{} = first_date}, today) do
    latest = Date.add(first_date, -7)

    if Date.compare(latest, today) == :gt, do: latest, else: today
  end

  def notice_on(_timing, today), do: today

  @doc """
  Returns the `{first_date, last_date}` an alert covers, or `{nil, nil}` when it
  does not cover any date yet.

  A current alert's last date is its confirmed end date, and stays `nil` for an
  estimated or unknown end, so a still-running alert is never grouped as Past. A
  planned alert's range comes from its expanded occurrences, so a removed last
  day shortens the range. A cancelled-trips alert has no timing pattern of its
  own: its range is the earliest and latest service date of the departures it
  names.
  """
  @spec date_range(Alert.t()) :: {Date.t() | nil, Date.t() | nil}
  def date_range(%Alert{situation: :cancelled_trips} = alert) do
    dates =
      alert
      |> trips()
      |> Enum.map(& &1.service_date)
      |> Enum.reject(&is_nil/1)

    case dates do
      [] -> {nil, nil}
      dates -> {Enum.min(dates, Date), Enum.max(dates, Date)}
    end
  end

  def date_range(%Alert{urgency: :now, timing: %TimingAnswer{} = timing}) do
    {timing.start_date, confirmed_end_date(timing)}
  end

  def date_range(%Alert{timing: %TimingAnswer{pattern: :continuous} = timing}) do
    {timing.first_date, timing.last_date}
  end

  def date_range(%Alert{timing: %TimingAnswer{} = timing}) do
    case occurrences(timing) do
      {:ok, []} ->
        {timing.first_date, timing.last_date}

      {:ok, [first | _rest] = occurrences} ->
        {first.date, List.last(occurrences).date}

      # An answer the bounds refuse still has a range the editor can show, so an
      # over-sized draft is not also unplaceable in the list.
      {:error, _reason} ->
        {timing.first_date, timing.last_date}
    end
  end

  def date_range(%Alert{}), do: {nil, nil}

  @doc """
  Summarizes a timing answer in one line, for the editor's preview and the
  assistant's "When" field.

  A weekly answer reads `Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 16;
  except Fri Oct 9`, a continuous answer reads `Oct 5 to Oct 7, 8 AM to 6 PM`,
  and a current answer reads `Oct 5, 8 PM, until further notice`.

  Returned dates carry no year, because an alert never reaches further ahead than
  the agency can plan; a range that crosses a year shows both years. Summarizing
  never fails: an answer that is still missing something describes the part it
  can.
  """
  @spec summary(TimingAnswer.t()) :: String.t()
  def summary(%TimingAnswer{pattern: :weekly} = timing) do
    parts = weekly_parts(timing)

    phrase =
      [
        weekday_phrase(timing.weekdays),
        time_phrase(timing),
        date_range_phrase(parts.first, parts.last)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

    add_exceptions(phrase, parts)
  end

  def summary(%TimingAnswer{pattern: :continuous} = timing) do
    [date_range_phrase(timing.first_date, timing.last_date), time_phrase(timing)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  def summary(%TimingAnswer{} = timing) do
    [date_range_phrase(timing.start_date, timing.start_date), time_phrase(timing)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
    |> case do
      "" -> ""
      phrase -> if timing.end_time, do: phrase, else: phrase <> ", until further notice"
    end
  end

  def summary(nil), do: ""

  # Expands the weekly pattern into the dates it keeps, together with the two
  # exception lists a summary can name. The bounds are not applied here, so a
  # draft the editor is still answering can always be described.
  defp weekly_parts(%TimingAnswer{} = timing) do
    with {:ok, first_date} <- fetch_date(timing.first_date),
         {:ok, weeks} <- fetch_weeks(timing.weeks),
         {:ok, weekdays} <- fetch_weekdays(timing.weekdays) do
      last_date = Date.add(first_date, weeks * 7 - 1)

      pattern =
        Date.range(first_date, last_date)
        |> Enum.filter(&(Date.day_of_week(&1) in weekdays))

      pattern_set = MapSet.new(pattern)
      removed_set = MapSet.new(timing.removed_dates || [])

      removed = sort_dates(Enum.filter(pattern, &MapSet.member?(removed_set, &1)))

      added =
        (timing.added_dates || [])
        |> Enum.filter(&(not MapSet.member?(pattern_set, &1)))
        |> Enum.uniq()
        |> sort_dates()

      kept =
        (pattern ++ (timing.added_dates || []))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(removed_set, &1))
        |> sort_dates()

      %{
        first: List.first(kept),
        last: List.last(kept),
        dates: kept,
        removed: removed,
        added: added
      }
    else
      _incomplete -> %{first: timing.first_date, last: nil, dates: [], removed: [], added: []}
    end
  end

  # A `Date` struct sorts by its own fields, which put the day before the month,
  # so every date list here is ordered by the calendar day count instead.
  defp sort_dates(dates), do: Enum.sort_by(dates, &Date.to_gregorian_days/1)

  defp limit_occurrences(dates) when length(dates) > @max_occurrences, do: {:error, :too_many}
  defp limit_occurrences(dates), do: {:ok, dates}

  defp single_occurrence(timing, first_date, end_date) do
    case occurrence(timing, first_date, end_date) do
      {:ok, occurrence} -> {:ok, [occurrence]}
      error -> error
    end
  end

  defp build_occurrences(_timing, []), do: {:ok, []}

  defp build_occurrences(timing, [date | rest]) do
    # Each day in a pattern stands alone, so an overnight end belongs to the day
    # it starts rather than to the last day of the pattern.
    with {:ok, occurrence} <- occurrence(timing, date, date),
         {:ok, rest_occurrences} <- build_occurrences(timing, rest) do
      {:ok, [occurrence | rest_occurrences]}
    end
  end

  defp occurrence(timing, date, end_date) do
    if timing.all_day do
      {:ok, %{date: date, starts: nil, ends: nil, all_day?: true}}
    else
      with {:ok, start_time} <- fetch_time(timing.start_time) do
        {:ok,
         %{
           date: date,
           starts: naive!(date, start_time),
           ends: end_datetime(end_date, start_time, timing.end_time),
           all_day?: false
         }}
      end
    end
  end

  # An open end has no end instant at all. Otherwise the period ends on its end
  # date, and an end at or before the start belongs to the following civil day
  # (R12) — so an 8 PM to 5 AM period on one date ends the next morning, and a
  # continuous period keeps its own last date.
  defp end_datetime(_end_date, _start_time, nil), do: nil

  defp end_datetime(end_date, start_time, end_time) do
    end_day =
      if Time.compare(end_time, start_time) != :gt do
        Date.add(end_date, 1)
      else
        end_date
      end

    naive!(end_day, end_time)
  end

  defp naive!(date, %Time{} = time), do: NaiveDateTime.new!(date, time)

  defp trips(%Alert{scope: %{} = scope}), do: Map.get(scope, :trips) || []
  defp trips(%Alert{}), do: []

  defp confirmed_end_date(%TimingAnswer{end_kind: :confirmed} = timing), do: timing.end_date
  defp confirmed_end_date(%TimingAnswer{}), do: nil

  defp fetch_date(%Date{} = date), do: {:ok, date}
  defp fetch_date(_date), do: {:error, :incomplete}

  defp fetch_weeks(weeks) when is_integer(weeks) and weeks > 0, do: {:ok, weeks}
  defp fetch_weeks(_weeks), do: {:error, :incomplete}

  defp fetch_weekdays([]), do: {:error, :incomplete}
  defp fetch_weekdays(weekdays) when is_list(weekdays), do: {:ok, Enum.uniq(weekdays)}
  defp fetch_weekdays(_weekdays), do: {:error, :incomplete}

  defp fetch_time(%Time{} = time), do: {:ok, time}
  defp fetch_time(_time), do: {:error, :incomplete}

  defp span_days(first_date, last_date), do: Date.diff(last_date, first_date) + 1

  defp weekday_phrase(weekdays) when is_list(weekdays) do
    case Enum.uniq(weekdays) |> Enum.sort() do
      [] -> ""
      [1, 2, 3, 4, 5, 6, 7] -> "Every day"
      sorted -> sorted |> contiguous_runs() |> Enum.map_join(", ", &run_phrase/1)
    end
  end

  defp weekday_phrase(_weekdays), do: ""

  # Splits a sorted weekday list into runs of consecutive ISO weekdays, so Monday
  # to Friday is one phrase and Monday, Wednesday, Friday is three.
  defp contiguous_runs(weekdays) do
    Enum.reduce(weekdays, [], &add_to_run/2) |> Enum.reverse()
  end

  defp add_to_run(day, [current | rest]) do
    case current do
      [head | _tail] when day == head + 1 -> [[day | current] | rest]
      _other -> [[day], [current | rest]]
    end
  end

  defp add_to_run(day, []), do: [[day]]

  # `contiguous_runs/1` collects each run newest first, so a run reads from its
  # earliest weekday to its latest.
  defp run_phrase([single]), do: weekday_name(single)
  defp run_phrase(run), do: "#{weekday_name(Enum.min(run))}–#{weekday_name(Enum.max(run))}"

  defp weekday_name(iso_weekday), do: Enum.at(@weekday_names, iso_weekday - 1)

  defp time_phrase(%TimingAnswer{all_day: true}), do: "all day"
  defp time_phrase(%TimingAnswer{start_time: nil}), do: ""

  defp time_phrase(%TimingAnswer{start_time: start_time, end_time: nil}),
    do: clock_time(start_time)

  defp time_phrase(%TimingAnswer{start_time: start_time, end_time: end_time}) do
    overnight = if Time.compare(end_time, start_time) != :gt, do: " the next day", else: ""

    "#{clock_time(start_time)} to #{clock_time(end_time)}#{overnight}"
  end

  defp clock_time(%Time{hour: 0, minute: 0}), do: "midnight"
  defp clock_time(%Time{hour: 12, minute: 0}), do: "noon"

  defp clock_time(%Time{hour: hour, minute: minute}) do
    meridiem = if hour < 12, do: "AM", else: "PM"
    clock_hour = rem(hour + 11, 12) + 1
    minutes = if minute == 0, do: "", else: ":#{pad_two(minute)}"

    "#{clock_hour}#{minutes} #{meridiem}"
  end

  defp pad_two(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp date_range_phrase(nil, _last_date), do: ""

  defp date_range_phrase(%Date{} = first_date, nil), do: short_date(first_date)

  defp date_range_phrase(%Date{} = date, %Date{} = last_date) when date == last_date,
    do: short_date(date)

  defp date_range_phrase(%Date{} = first_date, %Date{} = last_date) do
    if first_date.year == last_date.year do
      "#{short_date(first_date)} to #{short_date(last_date)}"
    else
      "#{long_date(first_date)} to #{long_date(last_date)}"
    end
  end

  defp date_range_phrase(_first_date, _last_date), do: ""

  defp short_date(%Date{month: month, day: day}), do: "#{Enum.at(@month_names, month - 1)} #{day}"

  defp long_date(%Date{} = date), do: "#{short_date(date)}, #{date.year}"

  defp add_exceptions("", _parts), do: ""

  defp add_exceptions(phrase, parts) do
    phrase
    |> append_dates("except ", parts.removed)
    |> append_dates("also ", parts.added)
  end

  defp append_dates(phrase, _label, []), do: phrase

  defp append_dates(phrase, label, dates) do
    phrase <> "; " <> label <> Enum.map_join(dates, ", ", &weekday_date/1)
  end

  defp weekday_date(%Date{} = date) do
    "#{weekday_name(Date.day_of_week(date))} #{short_date(date)}"
  end
end
