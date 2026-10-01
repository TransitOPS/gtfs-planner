defmodule GtfsPlanner.Alerts.RecurrenceTest do
  @moduledoc """
  Step 4: `Recurrence` expands a civil timing answer into the occurrences it
  applies, derives the date range the list groups tabs by, and summarizes the
  pattern (R12, AC-4).

  Every expected date, time and sentence here is a literal worked out by hand
  from the spec's rules, not a value recomputed by the module under test.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer.TripTarget
  alias GtfsPlanner.Alerts.TimingAnswer

  @trip_id "44444444-4444-1111-1111-444444444444"
  @other_trip_id "55555555-5555-1111-1111-555555555555"

  describe "occurrences/1 with a weekly pattern" do
    test "expands Mon-Fri 8 PM to 5 AM over two weeks and drops the removed Friday" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 2,
          weekdays: [1, 2, 3, 4, 5],
          start_time: ~T[20:00:00],
          end_time: ~T[05:00:00],
          removed_dates: [~D[2026-10-09]]
        )

      assert {:ok, occurrences} = Recurrence.occurrences(timing)
      assert length(occurrences) == 9

      assert Enum.map(occurrences, & &1.date) == [
               ~D[2026-10-05],
               ~D[2026-10-06],
               ~D[2026-10-07],
               ~D[2026-10-08],
               ~D[2026-10-12],
               ~D[2026-10-13],
               ~D[2026-10-14],
               ~D[2026-10-15],
               ~D[2026-10-16]
             ]

      # An end at or before the start belongs to the next civil day (R12).
      assert [first | _rest] = occurrences
      assert first.starts == ~N[2026-10-05 20:00:00]
      assert first.ends == ~N[2026-10-06 05:00:00]
      assert first.all_day? == false

      assert Enum.all?(occurrences, fn occurrence ->
               occurrence.starts.time() == ~T[20:00:00] and occurrence.ends.time() == ~T[05:00:00]
             end)

      assert [first_occurrence | _rest] = occurrences

      assert NaiveDateTime.to_date(first_occurrence.ends) ==
               Date.add(first_occurrence.date, 1)
    end

    test "a removed date never appears, even when it is also added" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 2,
          weekdays: [1, 2, 3, 4, 5],
          all_day: true,
          removed_dates: [~D[2026-10-06]],
          added_dates: [~D[2026-10-06], ~D[2026-10-20]]
        )

      assert {:ok, occurrences} = Recurrence.occurrences(timing)

      assert Enum.map(occurrences, & &1.date) == [
               ~D[2026-10-05],
               ~D[2026-10-07],
               ~D[2026-10-08],
               ~D[2026-10-09],
               ~D[2026-10-12],
               ~D[2026-10-13],
               ~D[2026-10-14],
               ~D[2026-10-15],
               ~D[2026-10-16],
               ~D[2026-10-20]
             ]
    end

    test "an added date already in the pattern is not duplicated" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 1,
          weekdays: [1],
          all_day: true,
          added_dates: [~D[2026-10-05], ~D[2026-10-12]]
        )

      assert {:ok, occurrences} = Recurrence.occurrences(timing)
      assert Enum.map(occurrences, & &1.date) == [~D[2026-10-05], ~D[2026-10-12]]
    end

    test "an all-day pattern yields whole civil dates with no time of day" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 1,
          weekdays: [6, 7],
          all_day: true
        )

      assert {:ok, occurrences} = Recurrence.occurrences(timing)
      assert Enum.map(occurrences, & &1.date) == [~D[2026-10-10], ~D[2026-10-11]]

      assert Enum.all?(occurrences, fn occurrence ->
               occurrence.all_day? and is_nil(occurrence.starts) and is_nil(occurrence.ends)
             end)
    end

    test "a pattern of more than 366 days is refused" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 53,
          weekdays: [1],
          all_day: true
        )

      assert Recurrence.occurrences(timing) == {:error, :too_many}
    end

    test "a pattern that would expand to more than 400 occurrences is refused" do
      every_day =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 52,
          weekdays: [1, 2, 3, 4, 5, 6, 7],
          all_day: true
        )

      # 52 whole weeks is 364 occurrences, inside both bounds on its own.
      assert {:ok, occurrences} = Recurrence.occurrences(every_day)
      assert length(occurrences) == 364

      added_dates = for offset <- 1..37, do: Date.add(~D[2027-10-04], offset)

      assert Recurrence.occurrences(%{every_day | added_dates: added_dates}) ==
               {:error, :too_many}
    end

    test "a pattern missing its first date is incomplete" do
      timing = timing(pattern: :weekly, first_date: nil, weeks: 2, weekdays: [1], all_day: true)

      assert Recurrence.occurrences(timing) == {:error, :incomplete}
    end

    test "a pattern missing its weeks or weekdays is incomplete" do
      assert Recurrence.occurrences(
               timing(pattern: :weekly, first_date: ~D[2026-10-05], weeks: nil, all_day: true)
             ) == {:error, :incomplete}

      assert Recurrence.occurrences(
               timing(
                 pattern: :weekly,
                 first_date: ~D[2026-10-05],
                 weeks: 2,
                 weekdays: [],
                 all_day: true
               )
             ) == {:error, :incomplete}
    end

    test "a pattern with no time of day and no all-day answer is incomplete" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 1,
          weekdays: [1],
          start_time: nil,
          end_time: nil
        )

      assert Recurrence.occurrences(timing) == {:error, :incomplete}
    end
  end

  describe "occurrences/1 with a continuous pattern" do
    test "expands one period from the first date to the last" do
      timing =
        timing(
          pattern: :continuous,
          first_date: ~D[2026-10-05],
          last_date: ~D[2026-10-07],
          start_time: ~T[08:00:00],
          end_time: ~T[18:00:00]
        )

      assert {:ok, [occurrence]} = Recurrence.occurrences(timing)

      assert occurrence == %{
               date: ~D[2026-10-05],
               starts: ~N[2026-10-05 08:00:00],
               ends: ~N[2026-10-07 18:00:00],
               all_day?: false
             }
    end

    test "a continuous period of more than 366 days is refused" do
      timing =
        timing(
          pattern: :continuous,
          first_date: ~D[2026-10-05],
          last_date: Date.add(~D[2026-10-05], 366),
          start_time: ~T[08:00:00],
          end_time: ~T[18:00:00]
        )

      assert Recurrence.occurrences(timing) == {:error, :too_many}
    end

    test "a continuous period of exactly 366 days is allowed" do
      timing =
        timing(
          pattern: :continuous,
          first_date: ~D[2026-10-05],
          last_date: Date.add(~D[2026-10-05], 365),
          start_time: ~T[08:00:00],
          end_time: ~T[18:00:00]
        )

      assert {:ok, [occurrence]} = Recurrence.occurrences(timing)
      assert occurrence.date == ~D[2026-10-05]
      assert occurrence.ends == ~N[2027-10-05 18:00:00]
    end

    test "a continuous period without a last date is incomplete" do
      timing =
        timing(
          pattern: :continuous,
          first_date: ~D[2026-10-05],
          last_date: nil,
          start_time: ~T[08:00:00],
          end_time: ~T[18:00:00]
        )

      assert Recurrence.occurrences(timing) == {:error, :incomplete}
    end
  end

  describe "occurrences/1 with no pattern" do
    test "a current alert with a confirmed end is one period" do
      timing =
        timing(
          start_date: ~D[2026-10-05],
          start_time: ~T[08:00:00],
          end_kind: :confirmed,
          end_date: ~D[2026-10-06],
          end_time: ~T[18:00:00]
        )

      assert {:ok, [occurrence]} = Recurrence.occurrences(timing)
      assert occurrence.starts == ~N[2026-10-05 08:00:00]
      assert occurrence.ends == ~N[2026-10-06 18:00:00]
    end

    test "a current alert with an unknown end runs from its start time with no end" do
      timing =
        timing(
          start_date: ~D[2026-10-05],
          start_time: ~T[08:00:00],
          end_kind: :unknown,
          end_date: nil,
          end_time: nil
        )

      assert {:ok, [occurrence]} = Recurrence.occurrences(timing)
      assert occurrence.starts == ~N[2026-10-05 08:00:00]
      assert occurrence.ends == nil
    end

    test "a current alert with an overnight end ends the next morning" do
      timing =
        timing(
          start_date: ~D[2026-10-05],
          start_time: ~T[20:00:00],
          end_kind: :confirmed,
          end_date: ~D[2026-10-05],
          end_time: ~T[05:00:00]
        )

      assert {:ok, [occurrence]} = Recurrence.occurrences(timing)
      assert occurrence.starts == ~N[2026-10-05 20:00:00]
      assert occurrence.ends == ~N[2026-10-06 05:00:00]
    end
  end

  describe "date_range/1" do
    test "a current alert with an unknown end has no last date" do
      alert =
        alert(
          urgency: :now,
          timing: timing(start_date: ~D[2026-10-05], end_kind: :unknown, end_date: nil)
        )

      assert Recurrence.date_range(alert) == {~D[2026-10-05], nil}
    end

    test "a current alert with an estimated end has no last date" do
      alert =
        alert(
          urgency: :now,
          timing:
            timing(start_date: ~D[2026-10-05], end_kind: :estimated, end_date: ~D[2026-10-09])
        )

      assert Recurrence.date_range(alert) == {~D[2026-10-05], nil}
    end

    test "a current alert with a confirmed end ends on its end date" do
      alert =
        alert(
          urgency: :now,
          timing:
            timing(
              start_date: ~D[2026-10-05],
              end_kind: :confirmed,
              end_date: ~D[2026-10-09]
            )
        )

      assert Recurrence.date_range(alert) == {~D[2026-10-05], ~D[2026-10-09]}
    end

    test "a cancelled-trips alert runs from its earliest to its latest service date" do
      alert =
        alert(
          urgency: :now,
          situation: :cancelled_trips,
          scope: %ScopeAnswer{
            shape: :trips,
            trips: [
              %TripTarget{trip_id: @trip_id, service_date: ~D[2026-10-08]},
              %TripTarget{trip_id: @other_trip_id, service_date: ~D[2026-10-06]},
              %TripTarget{trip_id: @trip_id, service_date: ~D[2026-10-06]}
            ]
          },
          timing: nil
        )

      assert Recurrence.date_range(alert) == {~D[2026-10-06], ~D[2026-10-08]}
    end

    test "a cancelled-trips alert with no departures has no range" do
      alert = alert(urgency: :now, situation: :cancelled_trips, scope: nil, timing: nil)

      assert Recurrence.date_range(alert) == {nil, nil}
    end

    test "a weekly alert's range follows the dates it actually applies" do
      alert =
        alert(
          urgency: :planned,
          timing:
            timing(
              pattern: :weekly,
              first_date: ~D[2026-10-05],
              weeks: 2,
              weekdays: [1, 2, 3, 4, 5],
              all_day: true,
              removed_dates: [~D[2026-10-09]]
            )
        )

      assert Recurrence.date_range(alert) == {~D[2026-10-05], ~D[2026-10-16]}
    end

    test "a continuous alert's range is its first and last date" do
      alert =
        alert(
          urgency: :planned,
          timing:
            timing(
              pattern: :continuous,
              first_date: ~D[2026-10-05],
              last_date: ~D[2026-10-07],
              start_time: ~T[08:00:00],
              end_time: ~T[18:00:00]
            )
        )

      assert Recurrence.date_range(alert) == {~D[2026-10-05], ~D[2026-10-07]}
    end

    test "an unanswered alert has no range" do
      assert Recurrence.date_range(alert(urgency: nil, timing: nil)) == {nil, nil}

      assert Recurrence.date_range(alert(urgency: :planned, timing: timing(pattern: :weekly))) ==
               {nil, nil}
    end
  end

  describe "summary/1" do
    test "reads a weekly overnight pattern with its exception" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 2,
          weekdays: [1, 2, 3, 4, 5],
          start_time: ~T[20:00:00],
          end_time: ~T[05:00:00],
          removed_dates: [~D[2026-10-09]]
        )

      assert Recurrence.summary(timing) ==
               "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 16; except Fri Oct 9"
    end

    test "names added dates the pattern does not already cover" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 1,
          weekdays: [1],
          all_day: true,
          added_dates: [~D[2026-10-20]]
        )

      assert Recurrence.summary(timing) == "Mon, all day, Oct 5 to Oct 20; also Tue Oct 20"
    end

    test "reads a weekend all-day pattern" do
      timing =
        timing(
          pattern: :weekly,
          first_date: ~D[2026-10-05],
          weeks: 1,
          weekdays: [6, 7],
          all_day: true
        )

      assert Recurrence.summary(timing) == "Sat–Sun, all day, Oct 10 to Oct 11"
    end

    test "reads a continuous period" do
      timing =
        timing(
          pattern: :continuous,
          first_date: ~D[2026-10-05],
          last_date: ~D[2026-10-07],
          start_time: ~T[08:00:00],
          end_time: ~T[18:00:00]
        )

      assert Recurrence.summary(timing) == "Oct 5 to Oct 7, 8 AM to 6 PM"
    end

    test "reads a current alert with a confirmed end and with an open one" do
      confirmed =
        timing(
          start_date: ~D[2026-10-05],
          start_time: ~T[08:00:00],
          end_kind: :confirmed,
          end_date: ~D[2026-10-06],
          end_time: ~T[18:00:00]
        )

      assert Recurrence.summary(confirmed) == "Oct 5, 8 AM to 6 PM"

      open =
        timing(
          start_date: ~D[2026-10-05],
          start_time: ~T[08:00:00],
          end_kind: :unknown,
          end_date: nil,
          end_time: nil
        )

      assert Recurrence.summary(open) == "Oct 5, 8 AM, until further notice"
    end

    test "reads midnight and noon as words" do
      timing =
        timing(
          pattern: :continuous,
          first_date: ~D[2026-10-05],
          last_date: ~D[2026-10-05],
          start_time: ~T[00:00:00],
          end_time: ~T[12:00:00]
        )

      assert Recurrence.summary(timing) == "Oct 5, midnight to noon"
    end

    test "shows both years when a range crosses one" do
      timing =
        timing(
          pattern: :continuous,
          first_date: ~D[2026-12-28],
          last_date: ~D[2027-01-04],
          all_day: true
        )

      assert Recurrence.summary(timing) == "Dec 28, 2026 to Jan 4, 2027, all day"
    end

    test "describes what it can when the answer is still incomplete" do
      assert Recurrence.summary(nil) == ""

      assert Recurrence.summary(timing(pattern: :weekly, first_date: nil, all_day: true)) ==
               "all day"

      assert Recurrence.summary(
               timing(pattern: :weekly, first_date: ~D[2026-10-05], all_day: true)
             ) == "all day, Oct 5"
    end
  end

  defp timing(overrides), do: struct!(TimingAnswer, overrides)

  defp alert(overrides), do: struct!(Alert, overrides)
end
