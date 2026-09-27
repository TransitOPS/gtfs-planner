defmodule GtfsPlanner.Gtfs.Calendars.ServiceDatesTest do
  @moduledoc """
  Merge evidence (EV-1) for pure native calendar date evaluation:

  - Effective dates match an independent oracle for inclusive endpoints, all seven
    weekday indexes, leap day, additions outside the weekly range, empty and
    specific-date service and a multi-year legitimate schedule that must not be
    truncated.
  - Derived periods, breaks and holidays follow the removed-run rules, including a
    Fri/Mon/Tue closure spanning a weekend and leading/trailing/complete closures.
  - Warnings use an explicit today with exact 0/14/15-day boundaries and keep
    redundant additions, removals on non-service days and outside-range exceptions
    distinguishable.

  Every expected value is hand-derived or produced by a fixed-seed generator plus a
  bounded civil-date oracle that never calls production helpers.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates

  # Fixed generator seed, bounded civil-date oracle window and explicit today. The
  # window ends at the latest date the generator can produce, so the oracle covers
  # every generated exception and weekly range.
  @oracle_seed {20_260_926, 11, 16}
  @window_start ~D[2024-01-01]
  @max_date_offset 1095
  @window_end Date.add(@window_start, @max_date_offset)
  @today ~D[2026-11-16]

  describe "active_dates/2" do
    test "matches every weekday index over a Monday-to-Sunday range" do
      range_start = ~D[2026-03-02]
      range_end = ~D[2026-03-08]
      expected_by_index = Date.range(range_start, range_end) |> Enum.to_list()

      for {expected_date, index} <- Enum.with_index(expected_by_index, 1) do
        calendar = weekly(range_start, range_end, [index])

        assert [^expected_date] = ServiceDates.active_dates(calendar, []),
               "weekday index #{index}"
      end
    end

    test "keeps a one-day range inclusive at both endpoints" do
      monday = weekly(~D[2026-03-02], ~D[2026-03-02], [1])

      assert ServiceDates.active_dates(monday, []) == [~D[2026-03-02]]

      tuesday_with_monday_only = weekly(~D[2026-03-03], ~D[2026-03-03], [1])

      assert ServiceDates.active_dates(tuesday_with_monday_only, []) == []
    end

    test "includes the leap day inside an inclusive range" do
      calendar = weekly(~D[2024-02-28], ~D[2024-03-01], [1, 2, 3, 4, 5, 6, 7])

      assert ServiceDates.active_dates(calendar, []) ==
               [~D[2024-02-28], ~D[2024-02-29], ~D[2024-03-01]]
    end

    test "applies additions before and after the weekly range and removals over it" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-09], [1, 2, 3, 4, 5])

      exceptions = [added(~D[2026-01-01]), added(~D[2026-02-01]), removed(~D[2026-01-06])]

      assert ServiceDates.active_dates(calendar, exceptions) == [
               ~D[2026-01-01],
               ~D[2026-01-05],
               ~D[2026-01-07],
               ~D[2026-01-08],
               ~D[2026-01-09],
               ~D[2026-02-01]
             ]
    end

    test "returns sorted unique dates for a specific-date calendar" do
      exceptions = [added(~D[2026-01-09]), added(~D[2026-01-05]), added(~D[2026-01-05])]

      assert ServiceDates.active_dates(nil, exceptions) == [~D[2026-01-05], ~D[2026-01-09]]
    end

    test "does not truncate a long legitimate multi-year schedule" do
      calendar = weekly(~D[2000-01-01], ~D[2010-12-31], [1, 2, 3, 4, 5, 6, 7])

      active = ServiceDates.active_dates(calendar, [])

      expected_length = Date.diff(~D[2010-12-31], ~D[2000-01-01]) + 1

      assert expected_length == 4018
      assert length(active) == expected_length
      assert length(active) > 3660
      assert List.first(active) == ~D[2000-01-01]
      assert List.last(active) == ~D[2010-12-31]
    end

    test "raises for malformed or contradictory input instead of returning partial dates" do
      assert_raise ArgumentError, fn ->
        ServiceDates.active_dates(weekly(~D[2026-01-10], ~D[2026-01-05], [1]), [])
      end

      assert_raise ArgumentError, fn ->
        ServiceDates.active_dates(%Calendar{start_date: ~D[2026-01-05], end_date: nil}, [])
      end

      assert_raise ArgumentError, fn ->
        ServiceDates.active_dates(nil, [%CalendarDate{date: nil, exception_type: 1}])
      end

      assert_raise ArgumentError, fn ->
        ServiceDates.active_dates(nil, [%CalendarDate{date: ~D[2026-01-01], exception_type: 3}])
      end

      assert_raise ArgumentError, fn ->
        ServiceDates.active_dates(nil, [
          %CalendarDate{date: ~D[2026-01-01], exception_type: 1},
          %CalendarDate{date: ~D[2026-01-01], exception_type: 2}
        ])
      end
    end
  end

  describe "periods/2" do
    test "treats two removed expected weekdays as holidays, not a break" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])

      result = ServiceDates.periods(calendar, [removed(~D[2026-01-06]), removed(~D[2026-01-07])])

      assert result.breaks == []
      assert result.holidays == [~D[2026-01-06], ~D[2026-01-07]]
      assert result.periods == [%{first_date: ~D[2026-01-05], last_date: ~D[2026-01-30]}]
      assert result.removed_days == [~D[2026-01-06], ~D[2026-01-07]]
      assert result.extra_days == []
    end

    test "treats three removed expected weekdays as one break with inclusive bounds" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])

      result =
        ServiceDates.periods(calendar, [
          removed(~D[2026-01-06]),
          removed(~D[2026-01-07]),
          removed(~D[2026-01-08])
        ])

      assert result.breaks == [
               %{first_date: ~D[2026-01-06], last_date: ~D[2026-01-08], service_days: 3}
             ]

      assert result.holidays == []

      assert result.periods == [
               %{first_date: ~D[2026-01-05], last_date: ~D[2026-01-05]},
               %{first_date: ~D[2026-01-09], last_date: ~D[2026-01-30]}
             ]

      assert result.removed_days == []
    end

    test "keeps a weekend-spanning Fri/Mon/Tue closure in one break interval" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])

      result =
        ServiceDates.periods(calendar, [
          removed(~D[2026-01-09]),
          removed(~D[2026-01-12]),
          removed(~D[2026-01-13])
        ])

      assert result.breaks == [
               %{first_date: ~D[2026-01-09], last_date: ~D[2026-01-13], service_days: 3}
             ]

      assert result.holidays == []

      assert result.periods == [
               %{first_date: ~D[2026-01-05], last_date: ~D[2026-01-08]},
               %{first_date: ~D[2026-01-14], last_date: ~D[2026-01-30]}
             ]
    end

    test "does not emit empty periods for leading, trailing or complete closures" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])

      leading =
        ServiceDates.periods(calendar, [
          removed(~D[2026-01-05]),
          removed(~D[2026-01-06]),
          removed(~D[2026-01-07])
        ])

      assert leading.periods == [%{first_date: ~D[2026-01-08], last_date: ~D[2026-01-30]}]

      trailing =
        ServiceDates.periods(calendar, [
          removed(~D[2026-01-28]),
          removed(~D[2026-01-29]),
          removed(~D[2026-01-30])
        ])

      assert trailing.periods == [%{first_date: ~D[2026-01-05], last_date: ~D[2026-01-27]}]

      every_expected_weekday = expected_weekdays(~D[2026-01-05], ~D[2026-01-30])

      assert length(every_expected_weekday) == 20

      complete =
        ServiceDates.periods(calendar, Enum.map(every_expected_weekday, &removed/1))

      assert complete.periods == []

      assert complete.breaks == [
               %{first_date: ~D[2026-01-05], last_date: ~D[2026-01-30], service_days: 20}
             ]

      assert ServiceDates.active_dates(calendar, Enum.map(every_expected_weekday, &removed/1)) ==
               []
    end

    test "keeps a single out-of-range removal out of breaks and periods" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])
      exceptions = [removed(~D[2026-02-02])]

      result = ServiceDates.periods(calendar, exceptions)

      assert result.breaks == []
      assert result.periods == [%{first_date: ~D[2026-01-05], last_date: ~D[2026-01-30]}]
      assert result.removed_days == [~D[2026-02-02]]

      assert ServiceDates.active_dates(calendar, exceptions) ==
               expected_weekdays(~D[2026-01-05], ~D[2026-01-30])
    end

    test "lists additions separately without extending weekly periods" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-09], [1, 2, 3, 4, 5])
      exceptions = [added(~D[2026-01-03]), added(~D[2026-01-07])]

      result = ServiceDates.periods(calendar, exceptions)

      assert result.periods == [%{first_date: ~D[2026-01-05], last_date: ~D[2026-01-09]}]
      assert result.breaks == []
      assert result.holidays == []
      assert result.extra_days == [~D[2026-01-03]]

      assert ServiceDates.active_dates(calendar, exceptions) == [
               ~D[2026-01-03],
               ~D[2026-01-05],
               ~D[2026-01-06],
               ~D[2026-01-07],
               ~D[2026-01-08],
               ~D[2026-01-09]
             ]
    end

    test "returns no weekly structures for specific-date service without inventing a weekly row" do
      result = ServiceDates.periods(nil, [added(~D[2026-02-01]), added(~D[2026-01-01])])

      assert result == %{
               periods: [],
               breaks: [],
               holidays: [],
               extra_days: [~D[2026-01-01], ~D[2026-02-01]],
               removed_days: []
             }
    end

    test "treats an imported all-zero weekly row as no expected dates" do
      calendar = weekly(~D[2026-11-02], ~D[2026-12-31], [])
      exceptions = [added(~D[2026-11-08])]

      result = ServiceDates.periods(calendar, exceptions)

      assert result.periods == []
      assert result.breaks == []
      assert result.holidays == []
      assert result.extra_days == [~D[2026-11-08]]
      assert ServiceDates.active_dates(calendar, exceptions) == [~D[2026-11-08]]
    end

    test "explains effective removals that are not inside a break" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])

      result =
        ServiceDates.periods(calendar, [
          removed(~D[2026-01-06]),
          removed(~D[2026-01-20]),
          removed(~D[2026-02-02])
        ])

      assert result.holidays == [~D[2026-01-06], ~D[2026-01-20]]
      assert result.breaks == []
      assert result.removed_days == [~D[2026-01-06], ~D[2026-01-20], ~D[2026-02-02]]
    end

    test "stays bounded and correct across a multi-year schedule with many breaks" do
      calendar = weekly(~D[2025-01-06], ~D[2030-12-27], [1, 2, 3, 4, 5])

      first_of_month =
        Date.range(~D[2026-02-01], ~D[2030-11-01]) |> Enum.filter(&(&1.day == 1))

      closures =
        Enum.flat_map(first_of_month, fn month ->
          month
          |> Date.range(Date.end_of_month(month))
          |> Enum.filter(&(Date.day_of_week(&1) <= 5))
          |> Enum.take(3)
        end)

      exceptions = Enum.map(closures, &removed/1)
      result = ServiceDates.periods(calendar, exceptions)

      assert length(first_of_month) == 58
      assert length(closures) == 174
      assert length(result.breaks) == 58
      assert Enum.all?(result.breaks, &(&1.service_days == 3))
      assert length(result.periods) == 59
      assert result.periods == Enum.sort_by(result.periods, & &1.first_date, Date)

      assert result.periods
             |> Enum.zip(tl(result.periods))
             |> Enum.all?(fn {left, right} ->
               Date.compare(left.last_date, right.first_date) == :lt
             end)

      expected_weekdays =
        Date.range(~D[2025-01-06], ~D[2030-12-27])
        |> Enum.count(&(Date.day_of_week(&1) <= 5))

      assert expected_weekdays == 1560
      assert length(ServiceDates.active_dates(calendar, exceptions)) == expected_weekdays - 174
      assert List.last(result.periods).last_date == ~D[2030-12-27]
    end
  end

  describe "month_grid/3" do
    test "labels each day with the exact native state" do
      calendar = weekly(~D[2026-01-01], ~D[2026-12-31], [1, 2, 3, 4, 5])

      exceptions = [
        added(~D[2026-02-07]),
        added(~D[2026-02-10]),
        removed(~D[2026-02-09])
      ]

      grid = ServiceDates.month_grid(calendar, exceptions, ~D[2026-02-15])

      assert grid.year == 2026
      assert grid.month == 2
      assert grid.title == "February 2026"
      assert length(grid.weeks) == 5
      assert Enum.all?(grid.weeks, &(length(&1) == 7))

      first_week = List.first(grid.weeks)
      assert Enum.take(first_week, 6) == List.duplicate(nil, 6)
      assert List.last(first_week).date == ~D[2026-02-01]

      cells = grid.weeks |> List.flatten() |> Enum.reject(&is_nil/1)

      assert Enum.map(cells, & &1.date) ==
               Date.range(~D[2026-02-01], ~D[2026-02-28]) |> Enum.to_list()

      assert cell(cells, ~D[2026-02-01]) == %{
               date: ~D[2026-02-01],
               day: 1,
               state: :none,
               exception: nil,
               label: "Feb 1, 2026: No service scheduled"
             }

      assert cell(cells, ~D[2026-02-07]) == %{
               date: ~D[2026-02-07],
               day: 7,
               state: :added,
               exception: :added,
               label: "Feb 7, 2026: Service added"
             }

      assert cell(cells, ~D[2026-02-08]) == %{
               date: ~D[2026-02-08],
               day: 8,
               state: :none,
               exception: nil,
               label: "Feb 8, 2026: No service scheduled"
             }

      assert cell(cells, ~D[2026-02-09]) == %{
               date: ~D[2026-02-09],
               day: 9,
               state: :removed,
               exception: :removed,
               label: "Feb 9, 2026: No service — removed"
             }

      assert cell(cells, ~D[2026-02-10]) == %{
               date: ~D[2026-02-10],
               day: 10,
               state: :service,
               exception: :added,
               label: "Feb 10, 2026: Regular service"
             }

      assert cell(cells, ~D[2026-02-11]) == %{
               date: ~D[2026-02-11],
               day: 11,
               state: :service,
               exception: nil,
               label: "Feb 11, 2026: Regular service"
             }
    end

    test "renders every civil day once for month lengths from 28 to 31 days" do
      for {month, days, title} <- [
            {~D[2024-02-01], 29, "February 2024"},
            {~D[2026-02-01], 28, "February 2026"},
            {~D[2026-03-01], 31, "March 2026"},
            {~D[2026-11-01], 30, "November 2026"}
          ] do
        grid = ServiceDates.month_grid(nil, [], month)

        beginning = Date.beginning_of_month(month)
        ending = Date.end_of_month(month)
        leading = Date.day_of_week(beginning) - 1

        assert grid.title == title

        cells = grid.weeks |> List.flatten() |> Enum.reject(&is_nil/1)

        assert length(cells) == days
        assert Enum.map(cells, & &1.date) == Date.range(beginning, ending) |> Enum.to_list()
        assert Enum.take(List.first(grid.weeks), leading) == List.duplicate(nil, leading)
        assert Enum.all?(cells, &(&1.state == :none and &1.exception == nil))
      end
    end
  end

  describe "warnings/3" do
    test "uses the effective last date for the 0/14/15-day expiry boundaries" do
      assert ServiceDates.active_dates(nil, [added(@today)]) == [@today]

      assert ServiceDates.warnings(nil, [added(@today)], @today) == [
               %{reason: :ends_soon, last_date: @today, days_remaining: 0}
             ]

      at_fourteen = Date.add(@today, 14)

      assert ServiceDates.warnings(nil, [added(at_fourteen)], @today) == [
               %{reason: :ends_soon, last_date: at_fourteen, days_remaining: 14}
             ]

      at_fifteen = Date.add(@today, 15)

      assert ServiceDates.warnings(nil, [added(at_fifteen)], @today) == []

      yesterday = Date.add(@today, -1)

      assert ServiceDates.warnings(nil, [added(yesterday)], @today) == [
               %{reason: :ended, last_date: yesterday}
             ]
    end

    test "reports no service for an empty effective set and a coverage gap per break" do
      assert ServiceDates.warnings(nil, [], @today) == [%{reason: :no_service}]

      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])

      closed_every_weekday =
        expected_weekdays(~D[2026-01-05], ~D[2026-01-30]) |> Enum.map(&removed/1)

      assert ServiceDates.warnings(calendar, closed_every_weekday, @today) == [
               %{reason: :no_service},
               %{
                 reason: :coverage_gap,
                 first_date: ~D[2026-01-05],
                 last_date: ~D[2026-01-30],
                 service_days: 20
               }
             ]
    end

    test "distinguishes redundant additions, non-service removals and outside-range exceptions" do
      calendar = weekly(~D[2026-11-02], ~D[2026-12-31], [1, 2, 3, 4, 5])

      exceptions = [
        added(~D[2026-11-03]),
        added(~D[2026-11-08]),
        added(~D[2027-01-04]),
        removed(~D[2026-11-04]),
        removed(~D[2026-11-07]),
        removed(~D[2026-10-05])
      ]

      assert ServiceDates.warnings(calendar, exceptions, @today) == [
               %{reason: :redundant_addition, date: ~D[2026-11-03], exception: :added},
               %{reason: :removal_on_nonservice_day, date: ~D[2026-11-07], exception: :removed},
               %{reason: :outside_range, date: ~D[2026-10-05], exception: :removed},
               %{reason: :outside_range, date: ~D[2027-01-04], exception: :added}
             ]

      result = ServiceDates.periods(calendar, exceptions)
      active = ServiceDates.active_dates(calendar, exceptions)

      assert result.extra_days == [~D[2026-11-08], ~D[2027-01-04]]
      refute ~D[2026-11-04] in active
      assert ~D[2026-11-08] in active
      assert ~D[2027-01-04] in active
    end

    test "orders ended, coverage gaps and exception reasons deterministically" do
      calendar = weekly(~D[2026-01-05], ~D[2026-01-30], [1, 2, 3, 4, 5])

      exceptions = [
        removed(~D[2026-01-06]),
        removed(~D[2026-01-07]),
        removed(~D[2026-01-08]),
        removed(~D[2026-01-20]),
        removed(~D[2026-01-21]),
        removed(~D[2026-01-22])
      ]

      expected = [
        %{reason: :ended, last_date: ~D[2026-01-30]},
        %{
          reason: :coverage_gap,
          first_date: ~D[2026-01-06],
          last_date: ~D[2026-01-08],
          service_days: 3
        },
        %{
          reason: :coverage_gap,
          first_date: ~D[2026-01-20],
          last_date: ~D[2026-01-22],
          service_days: 3
        }
      ]

      assert ServiceDates.warnings(calendar, exceptions, @today) == expected
      assert ServiceDates.warnings(calendar, exceptions, @today) == expected
    end
  end

  describe "independent bounded oracle" do
    test "matches hand-independent civil-date enumeration across all fixed-seed weekday masks" do
      fixtures = generated_fixtures()

      assert length(fixtures) == 128

      for {{calendar_or_nil, exceptions}, index} <- Enum.with_index(fixtures, 1) do
        actual = ServiceDates.active_dates(calendar_or_nil, exceptions)
        expected = oracle_active_dates(calendar_or_nil, exceptions)

        assert actual == expected,
               "fixture #{index} active dates: #{describe_fixture(calendar_or_nil, exceptions)}"

        assert actual == Enum.sort_by(Enum.uniq(actual), & &1, Date), "fixture #{index} ordering"

        result = ServiceDates.periods(calendar_or_nil, exceptions)

        assert result.periods == Enum.sort_by(result.periods, & &1.first_date, Date),
               "fixture #{index} periods ordered"

        assert result.breaks == Enum.sort_by(result.breaks, & &1.first_date, Date),
               "fixture #{index} breaks ordered"

        assert result.extra_days == Enum.sort_by(Enum.uniq(result.extra_days), & &1, Date),
               "fixture #{index} extra days"

        for period <- result.periods do
          assert Date.compare(period.first_date, period.last_date) != :gt
        end

        for period_break <- result.breaks do
          assert period_break.service_days >= 3
          assert Date.compare(period_break.first_date, period_break.last_date) != :gt
        end

        if calendar_or_nil == nil do
          assert result.periods == [], "fixture #{index} dates-only periods"
          assert result.breaks == [], "fixture #{index} dates-only breaks"
          assert result.holidays == [], "fixture #{index} dates-only holidays"
        end
      end
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp weekly(start_date, end_date, weekdays) do
    %Calendar{
      start_date: start_date,
      end_date: end_date,
      monday: flag(weekdays, 1),
      tuesday: flag(weekdays, 2),
      wednesday: flag(weekdays, 3),
      thursday: flag(weekdays, 4),
      friday: flag(weekdays, 5),
      saturday: flag(weekdays, 6),
      sunday: flag(weekdays, 7)
    }
  end

  defp flag(weekdays, index), do: if(index in weekdays, do: 1, else: 0)

  defp added(date), do: %CalendarDate{date: date, exception_type: 1}
  defp removed(date), do: %CalendarDate{date: date, exception_type: 2}

  defp expected_weekdays(from, to) do
    from |> Date.range(to) |> Enum.reject(&(Date.day_of_week(&1) in [6, 7]))
  end

  defp cell(cells, date), do: Enum.find(cells, &(&1.date == date))

  # -- fixed-seed generator and bounded oracle --------------------------------

  # Cycles every weekday mask so empty, single-day and full weekly patterns are all
  # compared with the oracle; eight masks deliberately produce dates-only service.
  defp generated_fixtures do
    :rand.seed(:exsss, @oracle_seed)

    for mask <- 0..127, do: generated_fixture(mask)
  end

  defp generated_fixture(mask) do
    start_date = Date.add(@window_start, :rand.uniform(900))
    end_date = Date.add(start_date, :rand.uniform(45))
    calendar_or_nil = generated_calendar(mask, start_date, end_date)
    exceptions = generated_exceptions()

    {calendar_or_nil, exceptions}
  end

  defp generated_calendar(mask, start_date, end_date) do
    if rem(mask, 16) == 0 do
      nil
    else
      weekdays = for index <- 1..7, Bitwise.band(mask, Bitwise.bsl(1, index - 1)) != 0, do: index
      weekly(start_date, end_date, weekdays)
    end
  end

  defp generated_exceptions do
    1..:rand.uniform(12)
    |> Enum.map(fn _ ->
      %CalendarDate{
        date: Date.add(@window_start, :rand.uniform(@max_date_offset)),
        exception_type: generated_exception_type()
      }
    end)
    |> Enum.uniq_by(& &1.date)
  end

  defp generated_exception_type, do: if(:rand.uniform(3) == 1, do: 2, else: 1)

  defp oracle_active_dates(calendar_or_nil, exceptions) do
    additions =
      MapSet.new(for %CalendarDate{date: date, exception_type: 1} <- exceptions, do: date)

    removals =
      MapSet.new(for %CalendarDate{date: date, exception_type: 2} <- exceptions, do: date)

    Date.range(@window_start, @window_end)
    |> Enum.filter(fn date ->
      cond do
        MapSet.member?(removals, date) -> false
        MapSet.member?(additions, date) -> true
        true -> oracle_expected?(calendar_or_nil, date)
      end
    end)
  end

  defp oracle_expected?(nil, _date), do: false

  defp oracle_expected?(%Calendar{} = calendar, date) do
    Date.compare(date, calendar.start_date) != :lt and
      Date.compare(date, calendar.end_date) != :gt and
      oracle_weekday_flag(calendar, Date.day_of_week(date)) == 1
  end

  defp oracle_weekday_flag(calendar, day_of_week) do
    case day_of_week do
      1 -> calendar.monday
      2 -> calendar.tuesday
      3 -> calendar.wednesday
      4 -> calendar.thursday
      5 -> calendar.friday
      6 -> calendar.saturday
      7 -> calendar.sunday
    end
  end

  defp describe_fixture(nil, exceptions) do
    "dates-only, exceptions #{Enum.map_join(exceptions, ",", &Date.to_iso8601(&1.date))}"
  end

  defp describe_fixture(calendar, exceptions) do
    range = "#{Date.to_iso8601(calendar.start_date)}..#{Date.to_iso8601(calendar.end_date)}"
    "range #{range}, exceptions #{Enum.map_join(exceptions, ",", &Date.to_iso8601(&1.date))}"
  end
end
