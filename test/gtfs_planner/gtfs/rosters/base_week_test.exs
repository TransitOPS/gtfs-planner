defmodule GtfsPlanner.Gtfs.Rosters.BaseWeekTest do
  @moduledoc """
  The base week: which day type each weekday takes its runs from.

  Day types are built as literal maps, as the card directs, because this module's
  subject is the resolution rules and not that `Blocking.DayTypes.derive/1`
  produced these shapes; `day_types_test.exs` covers that derivation. Dates are
  generated from a fixed Monday with `dates/2` so a weekday's count is exact and
  the fixture is stable.

  The counts are the interesting part: a school-year weekday has 143 Mon–Fri
  dates and the short-break weeks have 38, so "most dates on that weekday" and
  "most dates overall" are not the same day type. Weekdays come first in the
  list for a Wednesday–Saturday variant so the tie case can put an earlier key in
  front.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Rosters.BaseWeek

  # Monday 2026-09-07. Day types are listed in the order DayTypes.derive/1 gives
  # them, which is what breaks a tie between two equal Monday counts.
  @monday ~D[2026-09-07]
  @weekdays_monday_to_friday [1, 2, 3, 4, 5]
  @saturday 6
  @sunday 7

  defp dates(weekdays, count) do
    for offset <- 1..(count * 7),
        do:
          Date.add(@monday, offset)
          |> Enum.filter(&(Date.day_of_week(&1) in weekdays))
          |> Enum.take(count)
  end

  defp day_type(key, label, dates) do
    %{
      key: key,
      service_ids: [key],
      label: label,
      dates: dates,
      date_count: length(dates),
      first_date: List.first(dates),
      last_date: List.last(dates),
      trip_count: 100,
      special?: false
    }
  end

  # 143 Mon–Fri school-year dates, 38 Mon–Fri short-break dates, and the weekend
  # types. Monday's default is the school day type: 143 > 38.
  defp calendar do
    [
      day_type("school", "Weekdays + school days", dates(@weekdays_monday_to_friday, 143)),
      day_type("short_break", "Weekdays without school", dates(@weekdays_monday_to_friday, 38)),
      day_type("saturdays", "Saturdays", dates([@saturday], 20)),
      day_type("sundays", "Sundays", dates([@sunday], 20))
    ]
  end

  describe "resolve/2 with no stored choice" do
    test "gives weekdays 1 to 5 the day type with the most dates on them" do
      week = BaseWeek.resolve(calendar(), %{})

      assert Enum.map(1..5, &week[&1].day_type.label) ==
               List.duplicate("Weekdays + school days", 5)
    end

    test "gives Saturday and Sunday their own day types" do
      week = BaseWeek.resolve(calendar(), %{})

      assert week[6].day_type.label == "Saturdays"
      assert week[7].day_type.label == "Sundays"
    end

    test "marks every weekday as not chosen" do
      week = BaseWeek.resolve(calendar(), %{})

      assert Enum.all?(1..7, &(not week[&1].chosen?))
    end

    test "reports no missing choice" do
      week = BaseWeek.resolve(calendar(), %{})

      assert Enum.map(1..7, &week[&1].missing_choice) == List.duplicate(nil, 7)
    end
  end

  describe "resolve/2 with a stored choice" do
    test "uses the chosen day type for that weekday" do
      week = BaseWeek.resolve(calendar(), %{"1" => "short_break"})

      assert week[1].day_type.label == "Weekdays without school"
      assert week[1].chosen?
    end

    test "reports no missing choice for the chosen weekday" do
      week = BaseWeek.resolve(calendar(), %{"1" => "short_break"})

      assert week[1].missing_choice == nil
    end

    test "leaves the other weekdays on their default" do
      week = BaseWeek.resolve(calendar(), %{"1" => "short_break"})

      assert Enum.map(2..5, &week[&1].day_type.label) ==
               List.duplicate("Weekdays + school days", 4)

      assert Enum.all?(2..7, &(not week[&1].chosen?))
    end

    test "falls back to the default when the stored key is no longer a day type" do
      week = BaseWeek.resolve(calendar(), %{"1" => "removed_key"})

      assert week[1].day_type.label == "Weekdays + school days"
      assert week[1].chosen? == false
      assert week[1].missing_choice == "removed_key"
    end

    test "falls back to the default when the chosen day type has no date on that weekday" do
      week = BaseWeek.resolve(calendar(), %{"1" => "saturdays"})

      assert week[1].day_type.label == "Weekdays + school days"
      assert week[1].chosen? == false
      assert week[1].missing_choice == "saturdays"
    end

    test "leaves a weekday with no dates without a base day type" do
      week = BaseWeek.resolve(Enum.reject(calendar(), &(&1.key == "sundays")), %{})

      assert week[7].day_type == nil
      assert week[7].chosen? == false
      assert week[7].missing_choice == nil
    end

    test "breaks a tie of equal Monday counts in favour of the day type earlier in the list" do
      day_types = [
        day_type("school", "Weekdays + school days", dates([1], 143)),
        day_type("short_break", "Weekdays without school", dates([1], 143))
      ]

      week = BaseWeek.resolve(day_types, %{})

      assert week[1].day_type.label == "Weekdays + school days"
    end

    test "gives a weekday with no dates no base even when a choice names a real day type" do
      week =
        BaseWeek.resolve(Enum.reject(calendar(), &(&1.key == "sundays")), %{"7" => "saturdays"})

      assert week[7].day_type == nil
      assert week[7].missing_choice == "saturdays"
    end
  end

  describe "groups/1" do
    test "groups the default week into a weekday range and the two single days" do
      week = BaseWeek.resolve(calendar(), %{})

      assert Enum.map(BaseWeek.groups(week), &{&1.label, &1.weekdays}) == [
               {"Mon–Fri", [1, 2, 3, 4, 5]},
               {"Sat", [6]},
               {"Sun", [7]}
             ]
    end

    test "labels weekdays that are not consecutive with commas" do
      week = %{
        1 => %{day_type: %{key: "school"}, chosen?: true, missing_choice: nil},
        2 => %{day_type: %{key: "saturdays"}, chosen?: false, missing_choice: nil},
        3 => %{day_type: %{key: "school"}, chosen?: true, missing_choice: nil},
        4 => %{day_type: %{key: "saturdays"}, chosen?: false, missing_choice: nil},
        5 => %{day_type: %{key: "saturdays"}, chosen?: false, missing_choice: nil},
        6 => %{day_type: nil, chosen?: false, missing_choice: nil},
        7 => %{day_type: nil, chosen?: false, missing_choice: nil}
      }

      assert Enum.map(BaseWeek.groups(week), &{&1.label, &1.weekdays}) == [
               {"Mon, Wed", [1, 3]},
               {"Tue, Thu–Fri", [2, 4, 5]}
             ]
    end

    test "leaves out a weekday with no base day type" do
      week = BaseWeek.resolve(Enum.reject(calendar(), &(&1.key == "sundays")), %{})

      assert Enum.map(BaseWeek.groups(week), &{&1.label, &1.weekdays}) == [
               {"Mon–Fri", [1, 2, 3, 4, 5]},
               {"Sat", [6]}
             ]
    end

    test "carries the whole day type on each group" do
      [school | _] = BaseWeek.groups(BaseWeek.resolve(calendar(), %{}))

      assert school.day_type.key == "school"
    end

    test "groups the week a choice splits into two weekday groups" do
      week = BaseWeek.resolve(calendar(), %{"1" => "short_break"})

      assert Enum.map(BaseWeek.groups(week), &{&1.label, &1.weekdays}) == [
               {"Mon", [1]},
               {"Tue–Fri", [2, 3, 4, 5]},
               {"Sat", [6]},
               {"Sun", [7]}
             ]
    end
  end
end
