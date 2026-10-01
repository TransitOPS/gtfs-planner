defmodule GtfsPlanner.Gtfs.Rosters.RosterTest do
  @moduledoc """
  The roster composition: slots, stale states, findings, weekly figures, open work
  and the summary.

  The day types, runs and lines are literal maps, as the card directs, and the
  expected figures are written out by hand from the spec's domain rules rather
  than recomputed here. A run carries only the fields this composition reads
  (`run_id`, the three work-time seconds and its findings' severities), so a test
  cannot pass on a field the module never looks at.

  Times are service-day seconds, so 87_420 is 24:17 and 18_780 is 05:13; the rest
  between them is 18_780 + 86_400 - 87_420 = 17_760 s, the spec's own line 7
  example, and the minimum at 600 minutes is 36_000 s. Paid times are given in
  hours and minutes in the comments: 36_720 s is 10 h 12 min, 45_000 s is
  12 h 30 min, and five of the first is 51 h.

  The module is pure, so `async: true` and no sandbox are right here.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Rosters.BaseWeek
  alias GtfsPlanner.Gtfs.Rosters.Roster

  # Monday 2026-09-07, so a generated date's ISO weekday is exact.
  @monday ~D[2026-09-07]
  @rules %{min_rest_minutes: 600, weekly_hours_warn_above: 48}

  # 05:13 to 22:00, paid 12 h 30 min.
  @run_1001 %{
    run_id: "1001",
    work: %{sign_on_secs: 18_780, sign_off_secs: 79_200, paid_secs: 45_000},
    findings: []
  }
  # 05:52 to 23:53, paid 10 h 12 min. A slot that stored 05:40 has a re-cut run.
  @run_1005 %{
    run_id: "1005",
    work: %{sign_on_secs: 21_120, sign_off_secs: 86_000, paid_secs: 36_720},
    findings: []
  }
  # 07:00 to 19:00, paid 10 h 12 min.
  @run_1009 %{
    run_id: "1009",
    work: %{sign_on_secs: 25_200, sign_off_secs: 68_400, paid_secs: 36_720},
    findings: []
  }
  # 07:00 to 24:17, paid 13 h.
  @run_1022 %{
    run_id: "1022",
    work: %{sign_on_secs: 25_200, sign_off_secs: 87_420, paid_secs: 46_800},
    findings: []
  }
  # 08:20 to 22:00, paid 12 h 30 min.
  @run_6010 %{
    run_id: "6010",
    work: %{sign_on_secs: 30_000, sign_off_secs: 79_200, paid_secs: 45_000},
    findings: []
  }
  # 00:00 to 23:07, paid 14 h.
  @run_7007 %{
    run_id: "7007",
    work: %{sign_on_secs: 0, sign_off_secs: 83_220, paid_secs: 50_400},
    findings: []
  }

  defp dates(weekdays, count) do
    @monday
    |> offsets(count * 7)
    |> Enum.filter(&(Date.day_of_week(&1) in weekdays))
    |> Enum.take(count)
  end

  defp offsets(_monday, 0), do: []

  defp offsets(monday, count), do: [monday | offsets(Date.add(monday, 1), count - 1)]

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

  defp calendar do
    [
      day_type("weekday", "Weekdays", dates([1, 2, 3, 4, 5], 20)),
      day_type("saturday", "Saturdays", dates([6], 8)),
      day_type("sunday", "Sundays", dates([7], 8))
    ]
  end

  defp base_week, do: BaseWeek.resolve(calendar(), %{})

  # The day types' runs in the order `Runs.Day.derive/4` gives them: by sign-on,
  # then run ID. 1009 and 1022 both sign on at 07:00, so the run ID breaks the tie.
  defp run_days do
    %{
      "weekday" => %{runs: [@run_1001, @run_1005, @run_1009, @run_1022]},
      "saturday" => %{runs: [@run_6010]},
      "sunday" => %{runs: [@run_7007]}
    }
  end

  defp build(lines) do
    Roster.build(%{base_week: base_week(), run_days: run_days(), lines: lines, rules: @rules})
  end

  # A slot as it is stored, with the times the run had when it was set.
  defp slot(weekday, day_type_key, run_id, sign_on_secs, sign_off_secs) do
    %{
      weekday: weekday,
      day_type_key: day_type_key,
      run_id: run_id,
      run_sign_on_secs: sign_on_secs,
      run_sign_off_secs: sign_off_secs
    }
  end

  defp held(weekday, day_type_key, run) do
    slot(weekday, day_type_key, run.run_id, run.work.sign_on_secs, run.work.sign_off_secs)
  end

  defp line(line_number, days, operator \\ nil) do
    %{id: "line-#{line_number}", line_number: line_number, operator: operator, days: days}
  end

  describe "build/1 slots" do
    test "keeps a fresh slot's state, run and stored times" do
      slot =
        build([line(7, [held(1, "weekday", @run_1022)])]).lines
        |> hd()
        |> Map.fetch!(:slots)
        |> Map.fetch!(1)

      assert slot.state == :ok
      assert slot.run == @run_1022
      assert slot.stored == %{sign_on_secs: 25_200, sign_off_secs: 87_420}
    end

    test "sorts the lines by line number however the writer read them" do
      lines =
        build([
          line(7, [held(1, "weekday", @run_1022)]),
          line(3, [held(1, "weekday", @run_1009)]),
          line(4, [held(1, "weekday", @run_1001)])
        ]).lines

      assert Enum.map(lines, & &1.line_number) == [3, 4, 7]
    end
  end

  describe "build/1 short rest" do
    test "warns on the later weekday with the rest and the minimum" do
      line = line_7()

      assert [
               %{
                 code: :short_rest,
                 weekdays: [2],
                 detail: %{from: 1, to: 2, rest_secs: 17_760, min_secs: 36_000}
               }
             ] = line.findings
    end

    test "reports the same rest either side of the pair" do
      line = line_7()

      assert line.rest[2].before_secs == 17_760
      assert line.rest[1].after_secs == 17_760
      assert line.rest[2].after_secs == nil
      assert line.rest[1].before_secs == nil
    end

    test "leaves a day off between two working days unchecked" do
      # Monday and Wednesday would leave 25_200 + 86_400 - 79_200 = 32_400 s, short
      # at 600 minutes, and it is still not a finding: the days are not adjacent.
      line =
        build([line(7, [held(1, "weekday", @run_1001), held(3, "weekday", @run_1009)])]).lines
        |> hd()

      assert line.findings == []
      assert line.rest[1] == %{before_secs: nil, after_secs: nil}
    end

    test "checks the week wrap from Sunday to Monday" do
      # Sunday signs off at 83_220 and Monday signs on at 25_200, so 25_200 + 86_400
      # - 83_220 = 28_380 s, short at 600 minutes.
      line =
        build([line(7, [held(1, "weekday", @run_1009), held(7, "sunday", @run_7007)])]).lines
        |> hd()

      assert [%{code: :short_rest, weekdays: [1], detail: %{from: 7, rest_secs: 28_380}}] =
               line.findings
    end
  end

  describe "build/1 stale slots" do
    test "a day type that is no longer the weekday's base is a changed base" do
      line = build([line(9, [held(4, "sunday", @run_7007)])]).lines |> hd()

      assert line.slots[4].state == {:stale, :base_changed}
      assert line.slots[4].run == @run_7007
    end

    test "a changed base is reported first, whatever became of the run" do
      # The run is gone as well, and the weekday's base is what the planner has to
      # fix first, so the reason is the base and not the missing run.
      roster =
        Roster.build(%{
          base_week: base_week(),
          run_days: %{
            "weekday" => %{runs: []},
            "saturday" => %{runs: []},
            "sunday" => %{runs: []}
          },
          lines: [line(9, [slot(4, "sunday", "7007", 0, 83_220)])],
          rules: @rules
        })

      assert roster.lines |> hd() |> Map.fetch!(:slots) |> Map.fetch!(4) |> Map.fetch!(:state) ==
               {:stale, :base_changed}
    end

    test "a base-changed slot is left out of weekly paid time" do
      line = build([line(9, [held(4, "sunday", @run_7007)])]).lines |> hd()

      assert line.paid_secs == 0
      assert line.over_40_secs == 0
      assert line.rest == %{}
    end

    test "a base-changed slot still counts as a working day for days off" do
      # Thursday and Saturday work, so the days off are Friday and the run
      # Sunday to Wednesday. Leaving the stale Thursday out would fold it into the
      # first group, so the two would read as [[1, 2, 3, 4, 5], [7]] instead.
      line =
        build([line(9, [held(4, "sunday", @run_7007), held(6, "saturday", @run_6010)])]).lines
        |> hd()

      assert line.days_off == %{groups: [[5], [7, 1, 2, 3]], ok?: true}
    end

    test "a run the day type no longer derives is a removed run" do
      line = build([line(9, [slot(1, "weekday", "9999", 25_200, 68_400)])]).lines |> hd()

      assert line.slots[1].state == {:stale, :run_removed}
      assert line.slots[1].run == nil
    end

    test "a removed run names the reason, the run and the times that are stored" do
      line = build([line(9, [slot(1, "weekday", "9999", 25_200, 68_400)])]).lines |> hd()

      assert [
               %{
                 code: :stale_slot,
                 weekdays: [1],
                 detail: %{
                   reason: :run_removed,
                   run_id: "9999",
                   stored: %{sign_on_secs: 25_200, sign_off_secs: 68_400},
                   current: nil
                 }
               }
             ] = line.findings
    end

    test "a run that signs on at new times is a changed run" do
      # Stored 05:40, now 05:52: the run kept its ID and lost its work.
      line = build([line(9, [slot(1, "weekday", "1005", 20_400, 86_000)])]).lines |> hd()

      assert line.slots[1].state == {:stale, :run_changed}
      assert line.slots[1].run == @run_1005
    end

    test "a changed run reports the times it was set with and the times it has now" do
      line = build([line(9, [slot(1, "weekday", "1005", 20_400, 86_000)])]).lines |> hd()

      assert [
               %{
                 code: :stale_slot,
                 weekdays: [1],
                 detail: %{
                   reason: :run_changed,
                   run_id: "1005",
                   stored: %{sign_on_secs: 20_400, sign_off_secs: 86_000},
                   current: %{sign_on_secs: 21_120, sign_off_secs: 86_000}
                 }
               }
             ] = line.findings
    end

    test "a stale slot's hours are not counted" do
      line = build([line(9, [slot(1, "weekday", "1005", 20_400, 86_000)])]).lines |> hd()

      assert line.paid_secs == 0
    end

    test "a weekday with no base day type is a changed base" do
      roster =
        Roster.build(%{
          base_week: Map.delete(base_week(), 4),
          run_days: run_days(),
          lines: [line(9, [held(4, "weekday", @run_1022)])],
          rules: @rules
        })

      assert roster.lines |> hd() |> Map.fetch!(:slots) |> Map.fetch!(4) |> Map.fetch!(:state) ==
               {:stale, :base_changed}
    end
  end

  describe "build/1 run findings" do
    test "a run with an error finding warns and its slot stays fresh" do
      run = %{@run_1005 | findings: [%{code: :cannot_reach_piece, severity: :error}]}
      line = line_over(run, 1)

      assert line.slots[1].state == :ok
      assert line.paid_secs == 36_720

      assert [
               %{
                 code: :run_has_errors,
                 weekdays: [1],
                 detail: %{run_id: "1005", codes: [:cannot_reach_piece]}
               }
             ] =
               line.findings
    end

    test "a run with only a warning finding is not an error slot" do
      run = %{@run_1005 | findings: [%{code: :spread_too_long, severity: :warning}]}
      line = line_over(run, 1)

      assert line.findings == []
    end

    test "a slot whose run is gone is not an error slot" do
      line = build([line(9, [slot(1, "weekday", "9999", 25_200, 68_400)])]).lines |> hd()

      assert finding_codes(line) == [:stale_slot]
    end
  end

  describe "build/1 weekly figures" do
    test "sums the fresh runs' paid time and reports the time over 40 hours" do
      # Five days of 10 h 12 min is 51 h, which is 39_600 s over 40 h.
      line = mon_fri(@run_1009)

      assert line.paid_secs == 183_600
      assert line.over_40_secs == 39_600
    end

    test "warns above the configured weekly hours and names the working days" do
      line = mon_fri(@run_1009)

      assert [
               %{
                 code: :weekly_hours,
                 weekdays: [1, 2, 3, 4, 5],
                 detail: %{paid_secs: 183_600, over_40_secs: 39_600, warn_above_hours: 48}
               }
             ] = line.findings
    end

    test "does not warn at exactly the threshold" do
      # Five days of 9 h 36 min is exactly 48 h.
      run = %{
        run_id: "1048",
        work: %{sign_on_secs: 25_200, sign_off_secs: 68_400, paid_secs: 34_560},
        findings: []
      }

      line = mon_fri(run)

      assert line.paid_secs == 172_800
      assert line.over_40_secs == 28_800
      assert finding_codes(line) == []
    end

    test "warns a minute over the threshold" do
      run = %{
        run_id: "1048",
        work: %{sign_on_secs: 25_200, sign_off_secs: 68_400, paid_secs: 34_572},
        findings: []
      }

      line = mon_fri(run)

      assert line.paid_secs == 172_860
      assert finding_codes(line) == [:weekly_hours]
    end
  end

  describe "build/1 days off" do
    test "reports the separated days off and warns" do
      # Works Monday, Wednesday, Friday and Saturday: Tuesday, Thursday and Sunday
      # are three single days off, which is not two consecutive days.
      line =
        build([
          line(4, [
            held(1, "weekday", @run_1001),
            held(3, "weekday", @run_1005),
            held(5, "weekday", @run_1001),
            held(6, "saturday", @run_6010)
          ])
        ]).lines
        |> hd()

      assert line.days_off == %{groups: [[2], [4], [7]], ok?: false}

      assert [%{code: :days_off, weekdays: [2, 4, 7], detail: %{groups: [[2], [4], [7]]}}] =
               line.findings
    end

    test "counts Sunday and Monday off as one group" do
      # Works Tuesday to Saturday, so the only days off are Sunday and Monday.
      line =
        build([
          line(4, [
            held(2, "weekday", @run_1009),
            held(3, "weekday", @run_1009),
            held(4, "weekday", @run_1009),
            held(5, "weekday", @run_1009),
            held(6, "saturday", @run_6010)
          ])
        ]).lines
        |> hd()

      assert line.days_off == %{groups: [[7, 1]], ok?: true}
      refute :days_off in finding_codes(line)
    end
  end

  describe "build/1 open work" do
    test "leaves out a run an editor's line holds that weekday" do
      roster = build([line(5, [held(2, "weekday", @run_1005)])])

      assert open_run(roster, "1005").open_weekdays == [1, 3, 4, 5]
    end

    test "leaves out a run a stale slot holds, so it is re-set rather than re-handed out" do
      # The slot stores 05:40 for a run that now signs on at 05:52: stale, and the
      # run is still not open on Tuesday.
      roster = build([line(5, [slot(2, "weekday", "1005", 20_400, 86_000)])])

      assert roster.lines |> hd() |> Map.fetch!(:slots) |> Map.fetch!(2) |> Map.fetch!(:state) ==
               {:stale, :run_changed}

      assert open_run(roster, "1005").open_weekdays == [1, 3, 4, 5]
    end

    test "keeps a run open on the weekdays no line holds it" do
      roster = build([line(5, [held(1, "weekday", @run_1005)])])

      assert open_run(roster, "1005").open_weekdays == [2, 3, 4, 5]
    end

    test "lists a group's runs in the day's order, without the fully held ones" do
      # Line 3 holds 1009 Monday to Friday, line 5 holds 1005 on Tuesday, so 1009
      # is not open at all, 1005 is not open on Tuesday, and the other two are open
      # on every weekday of the group.
      roster = build([line(3, mon_fri_days(@run_1009)), line(5, [held(2, "weekday", @run_1005)])])
      group = weekday_group(roster)

      assert Enum.map(group.open_runs, & &1.run_id) == ["1001", "1005", "1022"]

      assert Enum.map(group.open_runs, & &1.open_weekdays) == [
               [1, 2, 3, 4, 5],
               [1, 3, 4, 5],
               [1, 2, 3, 4, 5]
             ]
    end

    test "counts a group's open run-days across its runs" do
      roster = build([line(3, mon_fri_days(@run_1009)), line(5, [held(2, "weekday", @run_1005)])])

      assert weekday_group(roster).open_run_days == 14
    end

    test "leaves a run held under another day type in that day type's open work" do
      # Line 9 holds the Sunday run on Thursday. It holds no run of Thursday's base
      # day type, and it does not take the Sunday run off Sunday either.
      roster = build([line(9, [held(4, "sunday", @run_7007)])])
      group = Enum.find(roster.groups, &(&1.day_type.key == "sunday"))

      assert Enum.map(group.open_runs, & &1.run_id) == ["7007"]
      assert Enum.map(group.open_runs, & &1.open_weekdays) == [[7]]
    end

    test "groups the week by base day type" do
      roster = build([line(3, mon_fri_days(@run_1009))])

      assert Enum.map(roster.groups, &{&1.label, &1.weekdays, &1.open_run_days}) == [
               {"Mon–Fri", [1, 2, 3, 4, 5], 15},
               {"Sat", [6], 1},
               {"Sun", [7], 1}
             ]
    end
  end

  describe "build/1 summary" do
    test "counts the roster as composed" do
      assert roster().summary == %{
               lines: 4,
               open_lines: 2,
               run_days_in_lines: 11,
               run_days_total: 22,
               open_by_weekday: %{1 => 1, 2 => 2, 3 => 2, 4 => 3, 5 => 2, 6 => 0, 7 => 1},
               split_days_off: 1,
               lines_with_problems: 4,
               stale_slots: 1,
               weekly_paid: %{
                 min_secs: 91_800,
                 max_secs: 183_600,
                 avg_secs: 149_040,
                 above_threshold: 1
               }
             }
    end

    test "counts the run-days the base week makes available to put in a line" do
      # Four weekday runs on each of five weekdays, one Saturday run, one Sunday run.
      assert roster().summary.run_days_total == 22
    end

    test "adds the run-days in lines and the open ones up to the total" do
      summary = roster().summary

      assert summary.run_days_in_lines + Enum.sum(Map.values(summary.open_by_weekday)) ==
               summary.run_days_total
    end

    test "counts the lines with no operator as open" do
      assert roster().summary.open_lines == 2
    end

    test "counts the lines whose days off are split" do
      assert roster().summary.split_days_off == 1
    end

    test "counts every line that has a finding" do
      assert roster().summary.lines_with_problems == 4
    end

    test "counts the stale slots" do
      assert roster().summary.stale_slots == 1
    end

    test "reports no weekly paid range when no line has paid time" do
      # The only line's one slot is stale, so nothing is paid.
      summary = build([line(9, [held(4, "sunday", @run_7007)])]).summary

      assert summary.weekly_paid == nil
      assert summary.run_days_in_lines == 0
    end

    test "composes an empty roster" do
      assert build([]).summary == %{
               lines: 0,
               open_lines: 0,
               run_days_in_lines: 0,
               run_days_total: 22,
               open_by_weekday: %{1 => 4, 2 => 4, 3 => 4, 4 => 4, 5 => 4, 6 => 1, 7 => 1},
               split_days_off: 0,
               lines_with_problems: 0,
               stale_slots: 0,
               weekly_paid: nil
             }
    end
  end

  # Line 7 works Monday and Tuesday: 24:17 to 05:13 leaves 17_760 s of rest.
  defp line_7 do
    build([line(7, [held(1, "weekday", @run_1022), held(2, "weekday", @run_1001)])]).lines |> hd()
  end

  # A Mon–Fri line over one run, composed against a day type that holds only it.
  defp mon_fri(run) do
    run_days = %{run_days() | "weekday" => %{runs: [run]}}

    Roster.build(%{
      base_week: base_week(),
      run_days: run_days,
      lines: [line(3, mon_fri_days(run))],
      rules: @rules
    }).lines
    |> hd()
  end

  defp mon_fri_days(run) do
    [
      held(1, "weekday", run),
      held(2, "weekday", run),
      held(3, "weekday", run),
      held(4, "weekday", run),
      held(5, "weekday", run)
    ]
  end

  # One weekday of one run, composed against a day type that holds only it.
  defp line_over(run, weekday) do
    run_days = %{run_days() | "weekday" => %{runs: [run]}}

    Roster.build(%{
      base_week: base_week(),
      run_days: run_days,
      lines: [line(9, [held(weekday, "weekday", run)])],
      rules: @rules
    }).lines
    |> hd()
  end

  # Four lines over the same day types: a 51 h Mon–Fri line with an operator, a
  # line whose days off are split, the short-rest line 7 with no operator, and a
  # line whose only slot points at another day type.
  defp roster do
    build([
      line(3, mon_fri_days(@run_1009), operator(3, "E4101", "Aurelia Nowak", 3)),
      line(4, split_days_line(), operator(4, "E4157", "Ines Duarte", nil)),
      line(7, [held(1, "weekday", @run_1022), held(2, "weekday", @run_1001)]),
      line(9, [held(4, "sunday", @run_7007)])
    ])
  end

  # Monday, Wednesday, Friday and Saturday: 45_000 + 36_720 + 45_000 + 45_000 =
  # 171_720 s, which is 47 h 42 min and so under the 48 h warning.
  defp split_days_line do
    [
      held(1, "weekday", @run_1001),
      held(3, "weekday", @run_1005),
      held(5, "weekday", @run_1001),
      held(6, "saturday", @run_6010)
    ]
  end

  defp operator(number, employee_id, display_name, seniority_number) do
    %{
      id: "operator-#{number}",
      employee_id: employee_id,
      display_name: display_name,
      seniority_number: seniority_number
    }
  end

  defp open_run(roster, run_id) do
    roster.groups |> Enum.flat_map(& &1.open_runs) |> Enum.find(&(&1.run_id == run_id))
  end

  defp weekday_group(roster) do
    Enum.find(roster.groups, &(&1.day_type.key == "weekday"))
  end

  defp finding_codes(line) do
    line.findings |> Enum.map(& &1.code) |> Enum.sort()
  end
end
