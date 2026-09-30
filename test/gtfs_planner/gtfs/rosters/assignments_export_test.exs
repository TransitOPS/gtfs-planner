defmodule GtfsPlanner.Gtfs.Rosters.AssignmentsExportTest do
  @moduledoc """
  The `employee_run_dates.txt` rows and warning counts, over a literal calendar.

  The calendar is written out rather than generated, because the point of this
  file is to be an oracle: the expected rows below are read off the two weeks
  2026-10-05 (Mon) to 2026-10-18 (Sun) by hand, so they cannot be moved by the
  same arithmetic that produces them.

  * **Weekday** works 10-05 to 10-09 and 10-13 to 10-16: nine dates, Monday to
    Friday, with Monday 2026-10-12 left out because it is the holiday.
  * **Sunday** works both Sundays and that holiday — 10-11, 10-12, 10-18 — so
    10-12 is a Monday running Sunday service, which no Monday line may be
    exported for.
  * **Saturday** works 10-10 and 10-17.

  The base week therefore comes out as Weekday for Monday to Friday, Saturday for
  Saturday and Sunday for Sunday, each by having the most dates on its weekday:
  Monday has two Weekday dates and one Sunday date.

  Times are service-day seconds, so `sign_on_secs: -900` is 15 minutes before
  midnight and puts the run on the day type's `_prev` service and the previous
  date — 10-11 becomes 10-10, 10-18 becomes 10-17, which are dates the Saturday
  day type also works. That is correct: the two files name the same service for
  the same run, and the run is not dropped because another day type happens to
  hold that date.

  The module is pure, so `async: true` and no sandbox are right here.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Rosters.AssignmentsExport
  alias GtfsPlanner.Gtfs.Rosters.BaseWeek
  alias GtfsPlanner.Gtfs.Rosters.Roster

  @rules %{min_rest_minutes: 600, weekly_hours_warn_above: 48}

  @services %{
    "weekday" => %{service_id: "ops_dt_weekday", prev_service_id: nil},
    "sunday" => %{service_id: "ops_dt_sunday", prev_service_id: "ops_dt_sunday_prev"},
    "saturday" => %{service_id: "ops_dt_saturday", prev_service_id: nil}
  }

  @day_types [
    %{
      key: "weekday",
      label: "Weekday",
      date_count: 9,
      dates: [
        ~D[2026-10-05],
        ~D[2026-10-06],
        ~D[2026-10-07],
        ~D[2026-10-08],
        ~D[2026-10-09],
        ~D[2026-10-13],
        ~D[2026-10-14],
        ~D[2026-10-15],
        ~D[2026-10-16]
      ]
    },
    %{
      key: "sunday",
      label: "Sunday",
      date_count: 3,
      dates: [~D[2026-10-11], ~D[2026-10-12], ~D[2026-10-18]]
    },
    %{
      key: "saturday",
      label: "Saturday",
      date_count: 2,
      dates: [~D[2026-10-10], ~D[2026-10-17]]
    }
  ]

  # 05:00 to 20:00, paid 15 h.
  @run_1001 %{
    run_id: "1001",
    work: %{sign_on_secs: 18_000, sign_off_secs: 72_000, paid_secs: 54_000},
    findings: []
  }

  # 07:00 to 19:00, paid 12 h. Signs on before midnight, so it is written on the
  # day type's previous-date service.
  @run_7002 %{
    run_id: "7002",
    work: %{sign_on_secs: -900, sign_off_secs: 68_400, paid_secs: 38_700},
    findings: []
  }

  # 06:00 to 20:00, paid 14 h.
  @run_7001 %{
    run_id: "7001",
    work: %{sign_on_secs: 21_600, sign_off_secs: 72_000, paid_secs: 50_400},
    findings: []
  }

  # 08:00 to 20:00, paid 12 h.
  @run_1021 %{
    run_id: "1021",
    work: %{sign_on_secs: 28_800, sign_off_secs: 72_000, paid_secs: 43_200},
    findings: []
  }

  # 06:30 to 18:30, paid 12 h, with an error finding: spec 08 leaves this run out
  # of `run_events.txt`, so it is left out here too.
  @run_1030 %{
    run_id: "1030",
    work: %{sign_on_secs: 23_400, sign_off_secs: 66_600, paid_secs: 43_200},
    findings: [%{code: :too_short, severity: :error}]
  }

  # 06:00 to 15:00, paid 9 h.
  @run_6010 %{
    run_id: "6010",
    work: %{sign_on_secs: 21_600, sign_off_secs: 54_000, paid_secs: 32_400},
    findings: []
  }

  # 07:00 to 16:00, paid 9 h.
  @run_6011 %{
    run_id: "6011",
    work: %{sign_on_secs: 25_200, sign_off_secs: 57_600, paid_secs: 32_400},
    findings: []
  }

  # 08:00 to 17:00, paid 9 h.
  @run_6012 %{
    run_id: "6012",
    work: %{sign_on_secs: 28_800, sign_off_secs: 61_200, paid_secs: 32_400},
    findings: []
  }

  describe "rows/1" do
    test "writes one row per assigned line per base-week date, in date order" do
      result = rows(roster())

      assert result.rows == [
               row(~D[2026-10-05], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-06], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-07], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-08], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-09], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-10], "ops_dt_sunday_prev", "7002", "E4090", "Kim Adeyemi"),
               row(~D[2026-10-11], "ops_dt_sunday", "7001", "E4108", "Dan Okonkwo"),
               row(~D[2026-10-13], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-14], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-15], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-16], "ops_dt_weekday", "1001", "E4101", "Rosa Iversen"),
               row(~D[2026-10-17], "ops_dt_sunday_prev", "7002", "E4090", "Kim Adeyemi"),
               row(~D[2026-10-18], "ops_dt_sunday", "7001", "E4108", "Dan Okonkwo")
             ]
    end

    test "dates a run signing on before midnight a day earlier on the previous service" do
      result = rows(roster())

      before_midnight =
        result.rows
        |> Enum.filter(&(&1.run_id == "7002"))
        |> Enum.map(&{Date.to_iso8601(&1.date), &1.service_id})

      assert before_midnight == [
               {"2026-10-10", "ops_dt_sunday_prev"},
               {"2026-10-17", "ops_dt_sunday_prev"}
             ]
    end

    test "leaves out the stale slot, the errored run and the line with no operator" do
      result = rows(roster())

      assert Enum.map(result.rows, & &1.run_id) |> Enum.uniq() |> Enum.sort() == [
               "1001",
               "7001",
               "7002"
             ]

      assert %{stale_slots: 1, left_out_slots: 1, unassigned_lines: 1} = result
    end

    test "reports a date whose day type is not its weekday's base as other-service" do
      result = rows(roster())

      # 10-12 is a Monday in the Sunday day type, and Monday's base is Weekday:
      # nothing is exported for it, and both of the Sunday day type's exported
      # runs stay open on it.
      assert result.other_service_dates == [~D[2026-10-12]]
      assert result.open_run_days == 2
    end

    test "writes nil service IDs and the operator's name when no export services are given" do
      result = rows(roster(), nil)

      assert Enum.all?(result.rows, &is_nil(&1.service_id))
      assert row(~D[2026-10-10], nil, "7002", "E4090", "Kim Adeyemi") in result.rows
      # The shift is the run's, not the service map's: the date still moves.
      assert Enum.filter(result.rows, &(&1.run_id == "7002")) |> Enum.map(& &1.date) == [
               ~D[2026-10-10],
               ~D[2026-10-17]
             ]
    end

    test "sorts by date, then service ID, run ID and employee ID" do
      # Two lines work the same Monday and Tuesday, which the writers would
      # refuse, but sorting is a property of the result rather than of the
      # writes. The higher employee ID is on the lower run ID, so a sort that
      # reached employee ID first would put 1021 ahead of 1001. Monday is 10-05
      # (10-12 is the holiday) and Tuesday is 10-06 and 10-13.
      monday_tuesday = [
        line(
          12,
          [held(1, "weekday", @run_1001), held(2, "weekday", @run_1001)],
          operator("E4300", "Ana Ruiz")
        ),
        line(
          13,
          [held(1, "weekday", @run_1021), held(2, "weekday", @run_1021)],
          operator("E4100", "Bo Silva")
        )
      ]

      result = rows(roster(monday_tuesday), nil)

      assert result.rows == [
               row(~D[2026-10-05], nil, "1001", "E4300", "Ana Ruiz"),
               row(~D[2026-10-05], nil, "1021", "E4100", "Bo Silva"),
               row(~D[2026-10-06], nil, "1001", "E4300", "Ana Ruiz"),
               row(~D[2026-10-06], nil, "1021", "E4100", "Bo Silva"),
               row(~D[2026-10-13], nil, "1001", "E4300", "Ana Ruiz"),
               row(~D[2026-10-13], nil, "1021", "E4100", "Bo Silva")
             ]
    end

    test "writes no rows for a version with no lines" do
      result = rows(roster([]))

      assert result.rows == []
      assert %{unassigned_lines: 0, stale_slots: 0, left_out_slots: 0} = result
      # Nothing is assigned, but 10-12 still runs service no Monday line works,
      # so the date is still reported rather than passed over.
      assert result.other_service_dates == [~D[2026-10-12]]
      assert result.open_run_days == 2
    end

    test "a day type with no derived runs exports nothing and is not an other-service date" do
      saturday_line = [line(80, [held(6, "saturday", @run_6012)], operator("E4103", "Ivy Chen"))]
      derived = Map.put(run_days(), "saturday", %{runs: [], uncovered: []})

      result = rows(roster(saturday_line), @services, derived)

      assert result.rows == []
      # Only the holiday Monday is left: 10-10 and 10-17 run a day type with no
      # runs at all, which is not service running differently.
      assert result.other_service_dates == [~D[2026-10-12]]
      assert result.open_run_days == 2
    end
  end

  # The roster every expectation above is read off: a Mon–Fri line, a Sunday line,
  # a second Sunday line working a run that signs on before midnight, a Saturday
  # slot a re-cut has made stale, a Wednesday slot on a run with an error, and a
  # Saturday line nobody has picked.
  defp roster(lines \\ default_lines()) do
    Roster.build(%{
      base_week: BaseWeek.resolve(@day_types, %{}),
      run_days: %{
        "weekday" => %{runs: [@run_1001, @run_1021, @run_1030], uncovered: []},
        "sunday" => %{runs: [@run_7001, @run_7002], uncovered: []},
        "saturday" => %{runs: [@run_6010, @run_6011, @run_6012], uncovered: []}
      },
      lines: lines,
      rules: @rules
    })
  end

  defp rows(roster, services \\ @services, derived \\ run_days()) do
    AssignmentsExport.rows(%{
      roster: roster,
      day_types: @day_types,
      run_days: derived,
      services: services
    })
  end

  # `rows/1` is given the same derived runs the roster was built from, because the
  # export reads runs from its own argument rather than from the composition.
  defp run_days do
    %{
      "weekday" => %{runs: [@run_1001, @run_1021, @run_1030], uncovered: []},
      "sunday" => %{runs: [@run_7001, @run_7002], uncovered: []},
      "saturday" => %{runs: [@run_6010, @run_6011, @run_6012], uncovered: []}
    }
  end

  defp default_lines do
    [
      line(
        12,
        Enum.map(1..5, &held(&1, "weekday", @run_1001)),
        operator("E4101", "Rosa Iversen")
      ),
      line(30, [held(7, "sunday", @run_7001)], operator("E4108", "Dan Okonkwo")),
      line(40, [held(7, "sunday", @run_7002)], operator("E4090", "Kim Adeyemi")),
      line(50, [re_cut(6, "saturday", @run_6010)], operator("E4102", "Lena Vogt")),
      line(60, [held(3, "weekday", @run_1030)], operator("E4110", "Sam Idris")),
      line(70, [held(6, "saturday", @run_6011)])
    ]
  end

  defp line(number, days, operator \\ nil) do
    %{
      id: "00000000-0000-0000-0000-0000000000" <> String.pad_leading("#{number}", 12, "0"),
      line_number: number,
      operator: operator,
      days: days
    }
  end

  defp operator(employee_id, display_name) do
    %{
      id: "11111111-1111-1111-1111-#{String.pad_leading(display_name, 12, "0")}",
      employee_id: employee_id,
      display_name: display_name,
      seniority_number: nil
    }
  end

  defp held(weekday, day_type_key, run) do
    %{
      weekday: weekday,
      day_type_key: day_type_key,
      run_id: run.run_id,
      run_sign_on_secs: run.work.sign_on_secs,
      run_sign_off_secs: run.work.sign_off_secs
    }
  end

  # A slot still naming a run that is there, with the times it had before the
  # re-cut: stale, and so left out of the export.
  defp re_cut(weekday, day_type_key, run) do
    weekday
    |> held(day_type_key, run)
    |> Map.put(:run_sign_off_secs, run.work.sign_off_secs - 1_800)
  end

  defp row(date, service_id, run_id, employee_id, operator_name) do
    %{
      date: date,
      service_id: service_id,
      run_id: run_id,
      employee_id: employee_id,
      operator_name: operator_name
    }
  end
end
