defmodule GtfsPlanner.Gtfs.Rosters.Checks do
  @moduledoc """
  The three crew rules a roster line is checked against: rest between
  consecutive working days, two consecutive days off, and weekly paid hours.

  All of them are pure arithmetic on values the caller already has, so they can
  be reasoned about without a repository, a clock or a derived roster.

  Rest runs from the previous day's sign-off to the next day's sign-on across the
  whole service day, so it works for a sign-off after midnight and for a sign-on
  before it: `rest = next.sign_on_secs + 86_400 - previous.sign_off_secs`.
  Only **adjacent** weekdays are compared, which is why the walk is cyclic
  (Sunday -> Monday) and why a day off between two working days needs no check —
  it is always at least a full day.

  Days off are counted cyclically as well, so Sunday and Monday are one group of
  two and a 4x10 line with Friday to Sunday off qualifies. A line that works
  every day has no day off, so it has no group and does not qualify; a line that
  works no day has all seven off and does.

  Weekly hours report the seconds over 40 for every line and warn only above the
  configured hour count, so built-in overtime (40 to 48 hours) is shown, not
  flagged.
  """

  @typedoc "A run's work times as service-day seconds; either may fall outside 0..86_400."
  @type times :: %{sign_on_secs: integer(), sign_off_secs: integer()}

  @typedoc "The working days' times, keyed by ISO weekday (1 = Monday)."
  @type weekday_times :: %{(1..7) => times()}

  @typedoc "One pair of adjacent working days that leaves less than the minimum rest."
  @type short_rest :: %{from: 1..7, to: 1..7, rest_secs: integer()}

  @day_secs 86_400
  @seconds_per_minute 60
  @seconds_per_hour 3_600
  @over_40_secs 40 * @seconds_per_hour

  @doc """
  The rest in seconds between two consecutive working days.

  `previous` is the earlier day's run and `next_run` the following day's. The
  result may be negative when the two runs overlap, which is itself a short rest.
  """
  @spec rest_secs(times(), times()) :: integer()
  def rest_secs(previous, next_run) do
    next_run.sign_on_secs + @day_secs - previous.sign_off_secs
  end

  @doc """
  The adjacent weekday pairs that leave less than `min_rest_minutes` of rest.

  Only pairs of days that both work are compared, and the pair is always the
  next weekday of the week, wrapping Sunday -> Monday, so a line with a day off
  in between is never reported. The result comes back sorted by `from`, the
  earlier weekday of the pair.
  """
  @spec short_rests(weekday_times(), 480..720) :: [short_rest()]
  def short_rests(weekday_times, min_rest_minutes) do
    min_secs = min_rest_minutes * @seconds_per_minute

    Enum.flat_map(1..7, fn from ->
      to = next_weekday(from)

      case adjacent_rest(weekday_times, from, to) do
        rest when is_integer(rest) and rest < min_secs ->
          [%{from: from, to: to, rest_secs: rest}]

        _not_short ->
          []
      end
    end)
  end

  @doc """
  The runs of consecutive days off in a line's week, and whether it qualifies.

  Takes the working weekdays and returns the off days grouped cyclically, so
  Sunday and Monday are the single group `[7, 1]` and a 4x10 line's Friday to
  Sunday is `[5, 6, 7]`. Groups are in week order by their first weekday, and a
  week with no working day at all is the one group of all seven days.

  `ok?` is true when any group is at least two days long, or when the line works
  no day and therefore has all seven off.
  """
  @spec days_off([1..7]) :: %{groups: [[1..7]], ok?: boolean()}
  def days_off(working_weekdays) do
    working = MapSet.new(working_weekdays)
    groups = off_groups(working)

    %{
      groups: groups,
      ok?: Enum.any?(groups, &(length(&1) >= 2))
    }
  end

  @doc """
  The seconds a line's weekly paid time runs over 40, and whether it warns.

  `warn_above_hours` is the roster setting; the line is flagged only when its
  paid time is strictly greater, so exactly 48:00 is not a warning and 48:01 is.
  """
  @spec weekly_hours(non_neg_integer(), 40..60) :: %{
          over_40_secs: non_neg_integer(),
          warn?: boolean()
        }
  def weekly_hours(paid_secs, warn_above_hours) do
    %{
      over_40_secs: max(paid_secs - @over_40_secs, 0),
      warn?: paid_secs > warn_above_hours * @seconds_per_hour
    }
  end

  @doc """
  The weekday after `weekday` in the cyclic week, wrapping Sunday (`7`) to
  Monday (`1`).

  Only adjacent weekdays are ever compared, so the walk wraps rather than
  stopping at the end of the week.
  """
  @spec next_weekday(1..7) :: 1..7
  def next_weekday(7), do: 1
  def next_weekday(weekday), do: weekday + 1

  @doc """
  The weekday before `weekday` in the cyclic week, wrapping Monday (`1`) to
  Sunday (`7`).
  """
  @spec previous_weekday(1..7) :: 1..7
  def previous_weekday(1), do: 7
  def previous_weekday(weekday), do: weekday - 1

  defp adjacent_rest(weekday_times, from, to) do
    case {Map.fetch(weekday_times, from), Map.fetch(weekday_times, to)} do
      {{:ok, previous}, {:ok, next_run}} -> rest_secs(previous, next_run)
      _not_both_working -> nil
    end
  end

  # Days off are the complement of the working days; the walk starts at each day
  # whose predecessor works and runs on while the days stay off.
  defp off_groups(working) do
    if Enum.empty?(working) do
      [Enum.to_list(1..7)]
    else
      1..7
      |> Enum.filter(
        &(MapSet.member?(working, previous_weekday(&1)) and not MapSet.member?(working, &1))
      )
      |> Enum.map(&off_run(&1, working, []))
    end
  end

  defp off_run(weekday, working, acc) do
    next_weekday = next_weekday(weekday)

    if MapSet.member?(working, next_weekday) do
      Enum.reverse([weekday | acc])
    else
      off_run(next_weekday, working, [weekday | acc])
    end
  end
end
