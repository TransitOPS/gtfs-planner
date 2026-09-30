defmodule GtfsPlanner.Gtfs.Rosters.CandidatesTest do
  @moduledoc """
  The builder's availability: which runs a slot can take, and whether a builder
  may make the change it is offering.

  The day types, runs and lines are literal maps, as the card directs, over the
  base week `BaseWeek.resolve/2` derives from generated dates, so a weekday's
  base day type is real rather than asserted. A run carries only the fields the
  roster composition reads (`run_id`, the three work-time seconds and its
  findings' severities), so a test cannot pass on a field nothing looks at.

  Times are service-day seconds and the rest rule is 600 minutes, so 36_000 s.
  The rest between two consecutive days is `next.sign_on + 86_400 -
  prev.sign_off`, and the expectations below are written out from that arithmetic
  rather than recomputed here:

  * Sunday 7007 signs off at 23:07 (83_220), so a Monday run signing on at
    20_400 leaves 20_400 + 86_400 - 83_220 = 23_580 s — the spec's own
    counterexample — while 1028 at 33_600 leaves 36_780 s and is allowed.
  * 1005 spans 05:40 to 19:40, so Monday to Tuesday is exactly
    20_400 + 86_400 - 70_800 = 36_000 s: the minimum, and not short. 600 minutes
    is not short, 599 is.
  * 1050 spans 06:00 to 22:40, the spec's 1 000-minute spread, which leaves
    26_400 s between its own consecutive days and so cannot be a Mon–Fri line.

  The module is pure, so `async: true` and no sandbox are right here.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Rosters.BaseWeek
  alias GtfsPlanner.Gtfs.Rosters.Candidates
  alias GtfsPlanner.Gtfs.Rosters.Roster

  # Monday 2026-09-07, so a generated date's ISO weekday is exact.
  @monday ~D[2026-09-07]
  @rules %{min_rest_minutes: 600, weekly_hours_warn_above: 48}

  # Weekday runs, in the order `Runs.Day.derive/4` gives them: by sign-on, then
  # run ID. 05:13 to 22:00, paid 12 h 30 min.
  @run_1001 %{
    run_id: "1001",
    work: %{sign_on_secs: 18_780, sign_off_secs: 79_200, paid_secs: 45_000},
    findings: []
  }
  # 05:30 to 20:00, paid 12 h 30 min.
  @run_1019 %{
    run_id: "1019",
    work: %{sign_on_secs: 19_800, sign_off_secs: 72_000, paid_secs: 45_000},
    findings: []
  }
  # 05:40 to 19:40, paid 14 h. A 840-minute spread, which leaves exactly 600
  # minutes between its own consecutive days.
  @run_1005 %{
    run_id: "1005",
    work: %{sign_on_secs: 20_400, sign_off_secs: 70_800, paid_secs: 50_400},
    findings: []
  }
  # 06:00 to 20:00, paid 13 h.
  @run_1021 %{
    run_id: "1021",
    work: %{sign_on_secs: 21_600, sign_off_secs: 72_000, paid_secs: 46_800},
    findings: []
  }
  # 06:00 to 14:00, paid 8 h: a 480-minute spread, so a whole weekday group works.
  @run_1040 %{
    run_id: "1040",
    work: %{sign_on_secs: 21_600, sign_off_secs: 50_400, paid_secs: 28_800},
    findings: []
  }
  # 06:00 to 22:40, paid 16 h 40 min: the spec's 1 000-minute spread.
  @run_1050 %{
    run_id: "1050",
    work: %{sign_on_secs: 21_600, sign_off_secs: 81_600, paid_secs: 60_000},
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
  # 08:20 to 20:00, paid 11 h 6 min 40 s.
  @run_1030 %{
    run_id: "1030",
    work: %{sign_on_secs: 30_000, sign_off_secs: 72_000, paid_secs: 40_000},
    findings: []
  }
  # 09:20 to 21:40, paid 12 h 20 min.
  @run_1028 %{
    run_id: "1028",
    work: %{sign_on_secs: 33_600, sign_off_secs: 78_000, paid_secs: 44_400},
    findings: []
  }
  # 09:30 to 20:30, paid 11 h.
  @run_1031 %{
    run_id: "1031",
    work: %{sign_on_secs: 34_200, sign_off_secs: 73_800, paid_secs: 39_600},
    findings: []
  }
  # 08:20 to 22:00, paid 13 h 40 min. Saturday's only run.
  @run_6010 %{
    run_id: "6010",
    work: %{sign_on_secs: 30_000, sign_off_secs: 79_200, paid_secs: 48_600},
    findings: []
  }
  # 09:00 to 21:00, paid 12 h. A second Saturday run.
  @run_6012 %{
    run_id: "6012",
    work: %{sign_on_secs: 32_400, sign_off_secs: 75_600, paid_secs: 43_200},
    findings: []
  }
  # 09:00 to 23:07, paid 14 h. Signs off late enough to refuse an early Monday.
  @run_7007 %{
    run_id: "7007",
    work: %{sign_on_secs: 32_400, sign_off_secs: 83_220, paid_secs: 50_400},
    findings: []
  }
  # 00:00 to 20:00, paid 14 h: signs on at midnight, so Saturday to Sunday is short.
  @run_7005 %{
    run_id: "7005",
    work: %{sign_on_secs: 0, sign_off_secs: 72_000, paid_secs: 50_400},
    findings: []
  }
  # 06:00 to 14:00 on a day type no weekday is based on, so it is never open work.
  @run_9001 %{
    run_id: "9001",
    work: %{sign_on_secs: 21_600, sign_off_secs: 50_400, paid_secs: 28_800},
    findings: []
  }

  @weekday_runs [
    @run_1001,
    @run_1019,
    @run_1005,
    @run_1021,
    @run_1040,
    @run_1050,
    @run_1009,
    @run_1022,
    @run_1030,
    @run_1028,
    @run_1031
  ]

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

  # "School days" has three Mondays, so Monday's base is the day type with the
  # most Monday dates and no weekday is based on "school" at all.
  defp calendar(weekdays) do
    [
      day_type("weekday", "Weekdays", dates([1, 2, 3, 4, 5], 20)),
      day_type("saturday", "Saturdays", dates([6], 8)),
      day_type("sunday", "Sundays", dates([7], 8)),
      day_type("school", "School days", dates(weekdays, 3))
    ]
  end

  defp run_days do
    %{
      "weekday" => %{runs: @weekday_runs},
      "saturday" => %{runs: [@run_6010, @run_6012]},
      "sunday" => %{runs: [@run_7005, @run_7007]},
      "school" => %{runs: [@run_9001]}
    }
  end

  defp roster(lines) do
    Roster.build(%{
      base_week: BaseWeek.resolve(calendar([1]), %{}),
      run_days: run_days(),
      lines: lines,
      rules: @rules
    })
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

  # A slot stored with times the run no longer has: the run was re-cut.
  defp re_cut(weekday, day_type_key, run) do
    slot(
      weekday,
      day_type_key,
      run.run_id,
      run.work.sign_on_secs - 720,
      run.work.sign_off_secs - 720
    )
  end

  # A slot stored with a sign-off far later than the run's, so a week checked
  # against the row's times would be short where the run's own times are not.
  defp late_stale(weekday, day_type_key, run) do
    slot(weekday, day_type_key, run.run_id, run.work.sign_on_secs, 86_400)
  end

  defp line(line_number, days) do
    %{id: "line-#{line_number}", line_number: line_number, operator: nil, days: days}
  end

  # Line 10 of the spec's example: Saturday and Sunday only, so its other four
  # weekday runs are open and a Mon–Fri group is being offered.
  defp line_10, do: line(10, [held(6, "saturday", @run_6010), held(7, "sunday", @run_7007)])

  defp line_3, do: line(3, [held(3, "weekday", @run_1009)])

  defp by_run_id(rows), do: Enum.map(rows, & &1.run_id)

  describe "group_availability/4 refusals" do
    test "refuses the run the line cannot take after a late Sunday, naming that pair" do
      assert Candidates.group_availability(roster([line_10()]), "line-10", 1, "1005") ==
               {:error, {:short_rest, 7, 1, 23_580, "1005"}}
    end

    test "allows a run that keeps the minimum rest from the same Sunday" do
      assert Candidates.group_availability(roster([line_10()]), "line-10", 1, "1028") == :ok
    end

    test "refuses a run another line already holds, naming the line and the day" do
      assert Candidates.group_availability(roster([line_10(), line_3()]), "line-10", 1, "1009") ==
               {:error, {:run_held, 3, 3}}
    end

    test "refuses a day the line already fills with another run" do
      roster =
        roster([
          line(10, [
            held(1, "weekday", @run_1021),
            held(6, "saturday", @run_6010),
            held(7, "sunday", @run_7007)
          ])
        ])

      assert Candidates.group_availability(roster, "line-10", 1, "1005") ==
               {:error, {:day_filled, 1, "1021"}}
    end

    test "refuses a single-day group before it looks at what the run is doing" do
      # 6012 is held on Saturday by line 3, so a refusal about the run would be
      # true too; the group of one is the first thing wrong.
      roster = roster([line_10(), line(3, [held(6, "saturday", @run_6012)])])

      assert Candidates.group_availability(roster, "line-10", 6, "6012") ==
               {:error, :single_day_group}
    end

    test "refuses a run the day type does not have" do
      assert Candidates.group_availability(roster([line_10()]), "line-10", 1, "9999") ==
               {:error, {:unknown_run, "9999"}}
    end

    test "refuses a line the roster does not hold as not found" do
      assert Candidates.group_availability(roster([line_10()]), "line-999", 1, "1028") ==
               {:error, :not_found}
    end

    test "refuses a weekday with no base day type, whose runs are unknown" do
      base_week = BaseWeek.resolve(calendar([1]) |> Enum.reject(&(&1.key == "saturday")), %{})

      roster =
        Roster.build(%{
          base_week: base_week,
          run_days: run_days(),
          lines: [line_10()],
          rules: @rules
        })

      assert Candidates.group_availability(roster, "line-10", 6, "6010") ==
               {:error, {:unknown_run, "6010"}}
    end
  end

  describe "group_availability/4 stale slots" do
    test "a stale slot holding the same run does not fill its day" do
      # Line 10 works 1028 on Wednesday, but a re-cut has moved its times, so the
      # slot is stale. Re-setting the same run on the group is how that is
      # accepted, so Wednesday is neither a filled day nor a held one.
      roster =
        roster([
          line(10, [
            re_cut(3, "weekday", @run_1028),
            held(6, "saturday", @run_6010),
            held(7, "sunday", @run_7007)
          ])
        ])

      assert Candidates.group_availability(roster, "line-10", 1, "1028") == :ok
    end

    test "a stale slot holding another run does fill its day" do
      roster =
        roster([
          line(10, [
            re_cut(3, "weekday", @run_1009),
            held(6, "saturday", @run_6010),
            held(7, "sunday", @run_7007)
          ])
        ])

      assert Candidates.group_availability(roster, "line-10", 1, "1001") ==
               {:error, {:day_filled, 3, "1009"}}
    end
  end

  describe "group_availability/4 the resulting week" do
    test "refuses a short rest the line already had, not only the one being added" do
      # Saturday 6010 signs off at 22:00 and Sunday 7005 signs on at midnight, so
      # 0 + 86_400 - 79_200 = 7_200 s is already short before any change, while
      # 1040 repeated Monday to Friday leaves 57_600 s between its own days.
      roster = roster([line(12, [held(6, "saturday", @run_6010), held(7, "sunday", @run_7005)])])

      assert Candidates.group_availability(roster, "line-12", 1, "1040") ==
               {:error, {:short_rest, 6, 7, 7_200, "7005"}}
    end

    test "allows the same group once the day that was short is off" do
      roster = roster([line(12, [held(6, "saturday", @run_6010)])])

      assert Candidates.group_availability(roster, "line-12", 1, "1040") == :ok
    end

    test "leaves a stale day out of the week it checks" do
      # The row stores a 24:00 sign-off for Saturday, which would leave
      # 30_000 + 86_400 - 86_400 = 30_000 s after the 06:00 Friday run. A stale
      # slot is not the line's work any more, so the group may still be set.
      roster = roster([line(12, [late_stale(6, "saturday", @run_6010)])])

      assert Candidates.group_availability(roster, "line-12", 1, "1040") == :ok
    end
  end

  describe "new_line_availability/3" do
    test "refuses a run whose own consecutive days leave under the minimum" do
      assert Candidates.new_line_availability(roster([line_10()]), "weekday", "1050") ==
               {:error, {:short_rest, 1, 2, 26_400, "1050"}}
    end

    test "allows a run whose spread leaves the minimum between its days" do
      assert Candidates.new_line_availability(roster([line_10()]), "weekday", "1040") ==
               {:ok, [1, 2, 3, 4, 5]}
    end

    test "refuses a run another line already holds, naming the line and the day" do
      assert Candidates.new_line_availability(roster([line_10(), line_3()]), "weekday", "1009") ==
               {:error, {:run_held, 3, 3}}
    end

    test "refuses a day type no weekday is based on before anything else" do
      roster = roster([line(11, [held(1, "school", @run_9001)])])

      assert Candidates.new_line_availability(roster, "school", "9001") == {:error, {:no_base, 1}}

      assert Candidates.new_line_availability(roster, "school", "9999") ==
               {:error, {:unknown_run, "9999"}}
    end

    test "refuses a run the day type does not have" do
      assert Candidates.new_line_availability(roster([line_10()]), "weekday", "9999") ==
               {:error, {:unknown_run, "9999"}}
    end

    test "builds a single-day group when the day type is one weekday's base" do
      assert Candidates.new_line_availability(roster([line_10()]), "saturday", "6012") ==
               {:ok, [6]}
    end

    test "refuses a single-day group run another line already holds" do
      roster = roster([line_10(), line(3, [held(6, "saturday", @run_6012)])])

      assert Candidates.new_line_availability(roster, "saturday", "6012") ==
               {:error, {:run_held, 6, 3}}
    end
  end

  describe "slot_candidates/3" do
    test "offers the weekday's open runs, nearest the middle of the line's week first" do
      # Line 10 works Saturday (08:20) and Sunday (09:00), so the middle of its
      # week is Sunday's 09:00 sign-on and 1028 (09:20) is nearest it.
      drawer = Candidates.slot_candidates(roster([line_10()]), "line-10", 1)

      assert drawer.current == nil
      assert drawer.group == %{weekdays: [1, 2, 3, 4, 5], label: "Mon–Fri"}

      assert by_run_id(drawer.candidates) == [
               "1028",
               "1031",
               "1030",
               "1009",
               "1022",
               "1021",
               "1040",
               "1050",
               "1005",
               "1019",
               "1001"
             ]
    end

    test "reads a line with no other working day in sign-on order" do
      drawer = Candidates.slot_candidates(roster([line(14, [])]), "line-14", 1)

      assert by_run_id(drawer.candidates) == by_run_id(@weekday_runs)
    end

    test "gives each run the rest it would leave against the line's neighbours" do
      # Line 13 works Monday (09:20–21:40) and Wednesday (07:00–19:00), so a
      # Tuesday run sits between them.
      line_13 =
        line(13, [
          held(1, "weekday", @run_1028),
          held(3, "weekday", @run_1009),
          held(6, "saturday", @run_6010),
          held(7, "sunday", @run_7007)
        ])

      candidates =
        roster([line_13])
        |> Candidates.slot_candidates("line-13", 2)
        |> Map.fetch!(:candidates)
        |> Map.new(&{&1.run_id, &1})

      # Monday 1028 signs off at 21:40, so 1028 itself at 09:20 leaves
      # 33_600 + 86_400 - 78_000 = 42_000 s before, while the Wednesday 07:00
      # sign-on leaves only 25_200 + 86_400 - 78_000 = 33_600 s after.
      assert %{rest_before_secs: 42_000, rest_after_secs: 33_600, short?: true} =
               candidates["1028"]

      # 09:30–20:30 leaves 42_600 s before and 37_800 s after, both over 36_000.
      assert %{rest_before_secs: 42_600, rest_after_secs: 37_800, short?: false} =
               candidates["1031"]

      # 08:20–20:00 leaves 38_400 s before and 39_600 s after, both over 36_000.
      assert %{rest_before_secs: 38_400, rest_after_secs: 39_600, short?: false} =
               candidates["1030"]

      # 05:13–22:00 leaves 27_180 s before the 21:40 sign-off and 32_400 s after
      # the 07:00 one: short on both sides.
      assert %{rest_before_secs: 27_180, rest_after_secs: 32_400, short?: true} =
               candidates["1001"]

      # 06:00–22:40 leaves 30_000 s either side, short by ten minutes.
      assert %{rest_before_secs: 30_000, rest_after_secs: 30_000, short?: true} =
               candidates["1050"]
    end

    test "reads a day off either side as no rest to check" do
      drawer = Candidates.slot_candidates(roster([line(14, [])]), "line-14", 1)

      assert Enum.all?(drawer.candidates, &(&1.short? == false))
    end

    test "offers back the run the slot already holds and reports its stale state" do
      # 1028 is held on Monday, so it is not open work, but a re-cut run has to be
      # re-settable and the drawer has to say which kind of stale it is.
      roster = roster([line(13, [re_cut(1, "weekday", @run_1028)])])

      drawer = Candidates.slot_candidates(roster, "line-13", 1)

      assert drawer.current.state == {:stale, :run_changed}
      assert drawer.current.run == @run_1028
      assert "1028" in by_run_id(drawer.candidates)
      assert length(drawer.candidates) == length(@weekday_runs)
    end

    test "does not offer a run of the day type the slot was based on" do
      # Line 11's Monday slot names a "school" run, which no weekday is based on,
      # so there is no run to place there even though the row still names one.
      drawer =
        Candidates.slot_candidates(
          roster([line(11, [held(1, "school", @run_9001)])]),
          "line-11",
          1
        )

      assert drawer.current.day_type_key == "school"
      assert "9001" not in by_run_id(drawer.candidates)
    end

    test "offers nothing for a weekday with no base day type" do
      base_week = BaseWeek.resolve(calendar([1]) |> Enum.reject(&(&1.key == "saturday")), %{})

      roster =
        Roster.build(%{
          base_week: base_week,
          run_days: run_days(),
          lines: [line_10()],
          rules: @rules
        })

      drawer = Candidates.slot_candidates(roster, "line-10", 6)

      assert drawer.group == nil
      assert drawer.candidates == []
    end

    test "reads a line the roster does not hold as an empty one" do
      drawer = Candidates.slot_candidates(roster([line_10()]), "line-999", 1)

      assert drawer.current == nil
      assert by_run_id(drawer.candidates) == by_run_id(@weekday_runs)
    end
  end

  # Four lines with no Monday slot. Line 2 and line 4 pay the same and both keep
  # every rest; line 5 pays more; line 3's 05:13 Tuesday would leave only
  # 31_380 s after Monday's 09:30 sign-off. Lines 6 and 7 work Monday, so they
  # are never offered.
  defp add_to_line_roster do
    roster([
      line(2, [
        held(2, "weekday", @run_1009),
        held(3, "weekday", @run_1009),
        held(4, "weekday", @run_1009)
      ]),
      line(3, [
        held(7, "sunday", @run_7007),
        held(2, "weekday", @run_1001),
        held(3, "weekday", @run_1001)
      ]),
      line(4, [
        held(2, "weekday", @run_1009),
        held(3, "weekday", @run_1009),
        held(4, "weekday", @run_1009)
      ]),
      line(5, [
        held(7, "sunday", @run_7007),
        held(2, "weekday", @run_1009),
        held(3, "weekday", @run_1009)
      ]),
      line(6, [held(1, "weekday", @run_1021)]),
      line(7, [re_cut(1, "weekday", @run_1009)])
    ])
  end

  describe "lines_for_open_run/3" do
    test "puts the lines that keep every rest first, then the least paid" do
      rows = Candidates.lines_for_open_run(add_to_line_roster(), "1031", 1)

      assert Enum.map(rows, & &1.line.line_number) == [2, 4, 5, 3]
    end

    test "carries the rest the run would leave in each line" do
      rows = Candidates.lines_for_open_run(add_to_line_roster(), "1031", 1)

      # Line 2 has no Sunday, so nothing before, and 25_200 + 86_400 - 73_800 =
      # 37_800 s after its 07:00 Tuesday.
      assert [first | _rest] = rows
      assert first.line.line_number == 2
      assert first.rest_before_secs == nil
      assert first.rest_after_secs == 37_800
      assert first.short? == false

      # Line 5 works Sunday to 23:07, so 34_200 + 86_400 - 83_220 = 37_380 s
      # before, still over the minimum.
      assert Enum.at(rows, 2).line.line_number == 5
      assert Enum.at(rows, 2).rest_before_secs == 37_380
      assert Enum.at(rows, 2).short? == false

      # Line 3's 05:13 Tuesday leaves 18_780 + 86_400 - 73_800 = 31_380 s.
      assert List.last(rows).line.line_number == 3
      assert List.last(rows).rest_after_secs == 31_380
      assert List.last(rows).short? == true
    end

    test "offers nothing for a run that is not open on that weekday" do
      assert Candidates.lines_for_open_run(add_to_line_roster(), "1021", 1) == []
      assert Candidates.lines_for_open_run(add_to_line_roster(), "1031", 6) == []
    end
  end
end
