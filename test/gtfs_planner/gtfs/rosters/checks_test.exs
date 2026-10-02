defmodule GtfsPlanner.Gtfs.Rosters.ChecksTest do
  @moduledoc """
  The three crew rules: rest between adjacent working days, days off in the
  cyclic week, and weekly paid hours.

  The expected values come from `context.md` and the spec's domain rules, not
  from the module: the service-day seconds are written as literals so the
  arithmetic is checked against the hand-computed cases the sources give (a
  23:40 sign-off against a 07:00 sign-on, line 7's 24:17/05:13 pair, the 48:00
  and 48:01 warning boundary). Times are service-day seconds, so a sign-off past
  midnight or a sign-on before it is just a number outside 0..86_400.

  The module is pure arithmetic, so `async: true` and no sandbox are right here;
  `roster_test.exs` covers these rules over derived runs.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Rosters.Checks

  describe "rest_secs/2" do
    test "measures a 23:40 sign-off to the next 07:00 sign-on" do
      # 85_200 s is 23:40 and 25_200 s is 07:00, so the operator has the seven
      # hours between them plus the twenty hours to midnight.
      assert Checks.rest_secs(%{sign_off_secs: 85_200}, %{sign_on_secs: 25_200}) == 26_400
    end

    test "measures line 7's 24:17 sign-off to the next 05:13 sign-on" do
      # A sign-off past midnight and a sign-on inside the day, still cyclic.
      assert Checks.rest_secs(%{sign_off_secs: 87_420}, %{sign_on_secs: 18_780}) == 17_760
    end

    test "counts a sign-off well past midnight against the same day's sign-on" do
      assert Checks.rest_secs(%{sign_off_secs: 91_800}, %{sign_on_secs: 25_200}) == 19_800
    end

    test "counts a next-day sign-on before midnight from the day before" do
      # The run signs on at -00:20, twenty minutes before the service day starts.
      assert Checks.rest_secs(%{sign_off_secs: 80_000}, %{sign_on_secs: -1_200}) == 5_200
    end

    test "is negative when the two runs overlap" do
      # Sign-off at 100_000 s is 03:46 the next day, so a 01:00 sign-on the
      # following morning means the operator never got off.
      assert Checks.rest_secs(%{sign_off_secs: 100_000}, %{sign_on_secs: 3_600}) == -10_000
    end

    test "reads only the sign-off of the earlier run and the sign-on of the later one" do
      earlier = %{sign_on_secs: 0, sign_off_secs: 85_200}
      later = %{sign_on_secs: 25_200, sign_off_secs: 90_000}

      assert Checks.rest_secs(earlier, later) == 26_400
    end
  end

  describe "short_rests/2" do
    # Sunday signs off at 23:07 (83_220) and Monday signs on at 05:40 (20_400),
    # which is step 8's counterexample: 6 h 33 min across the week wrap.
    @sunday %{sign_on_secs: 0, sign_off_secs: 83_220}
    @monday %{sign_on_secs: 20_400, sign_off_secs: 86_000}

    test "checks Sunday to Monday across the wrap" do
      assert Checks.short_rests(%{7 => @sunday, 1 => @monday}, 600) == [
               %{from: 7, to: 1, rest_secs: 23_580}
             ]
    end

    test "does not check a pair of days that are not adjacent" do
      # Monday and Wednesday have Tuesday off between them, so the rest is at
      # least a whole day and there is nothing to check.
      assert Checks.short_rests(%{1 => @monday, 3 => @monday}, 600) == []
    end

    test "reports only the pairs that are short" do
      # Monday signs off at 23:40 and Tuesday signs on at 09:39: 35_940 s, one
      # minute under the 600-minute minimum.
      assert Checks.short_rests(
               %{
                 1 => %{sign_on_secs: 0, sign_off_secs: 85_200},
                 2 => %{sign_on_secs: 34_740, sign_off_secs: 85_000}
               },
               600
             ) == [%{from: 1, to: 2, rest_secs: 35_940}]
    end

    test "treats exactly the minimum as not short" do
      # The same pair at 09:40 leaves exactly 36_000 s, which is 600 minutes.
      assert Checks.short_rests(
               %{
                 1 => %{sign_on_secs: 0, sign_off_secs: 85_200},
                 2 => %{sign_on_secs: 34_800, sign_off_secs: 85_000}
               },
               600
             ) == []
    end

    test "reports the pairs sorted by the earlier weekday" do
      # Monday signs off at 23:20 (84_000) and Tuesday signs on at 00:00, which
      # is 400 s; Saturday signs off at 23:53 (86_000) and Sunday signs on at
      # 00:00, also 400 s.
      week = %{
        1 => @monday,
        2 => %{sign_on_secs: 0, sign_off_secs: 84_000},
        6 => @monday,
        7 => @sunday
      }

      assert Enum.map(Checks.short_rests(week, 600), &{&1.from, &1.to}) == [
               {1, 2},
               {6, 7},
               {7, 1}
             ]
    end

    test "reads the minimum from the setting, not from a constant" do
      week = %{
        1 => %{sign_on_secs: 0, sign_off_secs: 85_200},
        2 => %{sign_on_secs: 34_800, sign_off_secs: 85_000}
      }

      assert Checks.short_rests(week, 480) == []
      assert Checks.short_rests(week, 720) == [%{from: 1, to: 2, rest_secs: 36_000}]
    end

    test "has nothing to check for a line that works a single day" do
      assert Checks.short_rests(%{3 => @monday}, 600) == []
    end

    test "has nothing to check for a line with no working day" do
      assert Checks.short_rests(%{}, 600) == []
    end
  end

  describe "days_off/1" do
    test "reports single days off as not ok" do
      # Working Monday, Wednesday, Thursday, Friday and Saturday: Tuesday and
      # Sunday off, and neither touches the other, so the pair of days off is
      # split.
      assert Checks.days_off([1, 3, 4, 5, 6]) == %{groups: [[2], [7]], ok?: false}
    end

    test "accepts a weekend off" do
      assert Checks.days_off([1, 2, 3, 4, 5]) == %{groups: [[6, 7]], ok?: true}
    end

    test "counts Sunday and Monday as one group across the wrap" do
      assert Checks.days_off([2, 3, 4, 5, 6]) == %{groups: [[7, 1]], ok?: true}
    end

    test "accepts a 4x10 line with three days off" do
      assert Checks.days_off([1, 2, 3, 4]) == %{groups: [[5, 6, 7]], ok?: true}
    end

    test "accepts a line with no working day" do
      assert Checks.days_off([]) == %{groups: [[1, 2, 3, 4, 5, 6, 7]], ok?: true}
    end

    test "reports split days off when two single days are separated" do
      assert Checks.days_off([1, 3, 5, 6, 7]) == %{groups: [[2], [4]], ok?: false}
    end

    test "reports a single off day for a line that works six days" do
      assert Checks.days_off([1, 2, 3, 4, 5, 6]) == %{groups: [[7]], ok?: false}
    end

    test "reports no days off for a line that works every day" do
      assert Checks.days_off([1, 2, 3, 4, 5, 6, 7]) == %{groups: [], ok?: false}
    end

    test "ignores the order the working days arrive in" do
      assert Checks.days_off([5, 1, 2, 3, 4]) == Checks.days_off([1, 2, 3, 4, 5])
    end
  end

  describe "weekly_hours/2" do
    test "reports the seconds over 40 without warning at the threshold" do
      # 48 hours exactly is not a warning; 48 h is 4 h over 40 h.
      assert Checks.weekly_hours(172_800, 48) == %{over_40_secs: 28_800, warn?: false}
    end

    test "warns one second past the threshold" do
      assert Checks.weekly_hours(172_860, 48) == %{over_40_secs: 28_860, warn?: true}
    end

    test "reports no overtime for a line under 40 hours" do
      assert Checks.weekly_hours(140_000, 48) == %{over_40_secs: 0, warn?: false}
    end

    test "reports no overtime at exactly 40 hours" do
      assert Checks.weekly_hours(144_000, 48) == %{over_40_secs: 0, warn?: false}
    end

    test "reads the warning from the setting, not from a constant" do
      # 172_800 s is 48 h, which a 40-hour setting flags and a 60-hour one does not.
      assert Checks.weekly_hours(172_800, 40).warn?
      refute Checks.weekly_hours(172_800, 60).warn?
    end
  end

  describe "next_weekday/1 and previous_weekday/1" do
    test "steps forward one day and wraps Sunday to Monday" do
      assert Enum.map(1..7, &Checks.next_weekday/1) == [2, 3, 4, 5, 6, 7, 1]
    end

    test "steps back one day and wraps Monday to Sunday" do
      assert Enum.map(1..7, &Checks.previous_weekday/1) == [7, 1, 2, 3, 4, 5, 6]
    end

    test "round-trips every weekday across the wrap" do
      assert Enum.all?(1..7, &(Checks.next_weekday(Checks.previous_weekday(&1)) == &1))
      assert Enum.all?(1..7, &(Checks.previous_weekday(Checks.next_weekday(&1)) == &1))
    end
  end
end
