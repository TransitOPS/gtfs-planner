defmodule GtfsPlanner.Agents.BrowserServiceAnswers do
  @moduledoc """
  The A02/A19 service-answer dates shared by the seeded feed and the OpenRouter
  stand-in, so a browser journey and the rows it reads cannot disagree about
  which date is "Thanksgiving".

  `test/support/browser_seed.exs` builds the Browser Service Answers Version's
  calendars, exceptions and trips from these dates, and
  `GtfsPlanner.Agents.BrowserOpenRouter` asks about the same dates, so the
  stand-in's tool call always names a date the seeded calendars actually run.
  Every date is derived from `Date.utc_today/0` rather than
  `Gtfs.DisplayClock.today/2`, because the version's own zone would otherwise
  move "today" by a day against the stand-in's clock.

  The shape mirrors the A02 worked example: the holiday is a Thursday at least
  two weeks out whose weekday baseline is removed and replaced by an
  exception-only calendar, and the coverage dates sit after `REGULAR` ends so
  H8 has nothing left while H12 keeps Sunday service through `SCHOOL`.
  """

  @thanksgiving_dow 4
  @sunday_dow 7

  @doc "The date the journeys and the seed both call today."
  def today, do: Date.utc_today()

  @doc """
  The holiday: the first Thursday at least fourteen days after today, so the
  weekly calendars that run it are unambiguous on any run date.
  """
  def thanksgiving do
    Date.add(today(), 14 + days_until(@thanksgiving_dow))
  end

  @doc "The Wednesday before the holiday, which H8 does not run."
  def thanksgiving_eve, do: Date.add(thanksgiving(), -1)

  @doc "The last date `REGULAR` runs, four weeks before the holiday."
  def regular_last_day, do: Date.add(thanksgiving(), -28)

  @doc "The first date after `REGULAR` ends."
  def nov_first, do: Date.add(regular_last_day(), 1)

  @doc "The first Sunday on or after `nov_first/0`, when H12 runs `SCHOOL`."
  def nov_sunday do
    Date.add(nov_first(), rem(@sunday_dow - Date.day_of_week(nov_first()), 7))
  end

  @doc "The first date the seeded weekly calendars cover."
  def range_start, do: Date.add(today(), -30)

  @doc "The last date the seeded weekly calendars cover."
  def range_end, do: Date.add(today(), 120)

  defp days_until(day_of_week) do
    rem(day_of_week - Date.day_of_week(today()), 7)
  end
end
