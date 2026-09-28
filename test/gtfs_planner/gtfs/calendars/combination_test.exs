defmodule GtfsPlanner.Gtfs.Calendars.CombinationTest do
  @moduledoc """
  Pure combination algebra: the effective-date union, deliberate conflicts, explicit
  decisions, conflict grouping and per-calendar consequences.

  Every case uses literal service IDs and civil dates taken from the accepted rules:
  Thanksgiving removed by one calendar and run by another, two conflicts separated by a
  normal service day, an ordinary weekday absence, an out-of-range and a dates-only
  removal, adjacent conflicts with equal and with different participants, a group value
  expanded against the current review, and the agency-local today split. `plan/5` and
  `expand_group_choices/2` are pure, so no database or clock is involved.

  These cases are a committed source of EV-2 (`combination_test.exs`), owned by step 17.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.Combination

  @month_first ~D[2026-11-23]
  @month_last ~D[2026-11-30]
  @weekdays [1, 2, 3, 4, 5]
  @every_day [1, 2, 3, 4, 5, 6, 7]
  @thanksgiving ~D[2026-11-26]
  @today ~D[2026-11-26]

  describe "plan/5 union and conflicts" do
    test "requires a choice for a date one calendar removes and another runs" do
      sources = %{"SEASONAL" => season_removing_thanksgiving(2), "YEAR_ROUND" => year_round(7)}

      assert {:ok, plan} = Combination.plan(sources, "YEAR_ROUND", ["SEASONAL"], %{}, @today)

      assert plan.ready? == false
      assert plan.result_dates == nil
      assert plan.unresolved_dates == [@thanksgiving]

      assert plan.union_dates == [
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               @thanksgiving,
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]

      assert plan.conflicts == [
               %{
                 date: @thanksgiving,
                 running_ids: ["YEAR_ROUND"],
                 removing_ids: ["SEASONAL"],
                 group_key: "2026-11-26"
               }
             ]
    end

    test "run keeps the conflict date and no_service removes only that date" do
      sources = %{"SEASONAL" => season_removing_thanksgiving(2), "YEAR_ROUND" => year_round(7)}

      assert {:ok, run_plan} =
               Combination.plan(
                 sources,
                 "YEAR_ROUND",
                 ["SEASONAL"],
                 %{"2026-11-26" => "run"},
                 @today
               )

      assert run_plan.ready? == true
      assert run_plan.unresolved_dates == []

      assert run_plan.result_dates == [
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               @thanksgiving,
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]

      assert {:ok, no_service_plan} =
               Combination.plan(
                 sources,
                 "YEAR_ROUND",
                 ["SEASONAL"],
                 %{"2026-11-26" => "no_service"},
                 @today
               )

      assert no_service_plan.result_dates == [
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]

      assert effect_for(no_service_plan, "YEAR_ROUND").lost_dates == [@thanksgiving]
      assert effect_for(no_service_plan, "YEAR_ROUND").gained_dates == []
      assert effect_for(no_service_plan, "SEASONAL").gained_dates == []
      assert effect_for(no_service_plan, "SEASONAL").lost_dates == []
    end

    test "accepts the allowlisted decision atoms and date keys" do
      sources = %{"SEASONAL" => season_removing_thanksgiving(2), "YEAR_ROUND" => year_round(7)}

      assert {:ok, atom_plan} =
               Combination.plan(
                 sources,
                 "YEAR_ROUND",
                 ["SEASONAL"],
                 %{"2026-11-26" => :no_service},
                 @today
               )

      assert {:ok, date_key_plan} =
               Combination.plan(
                 sources,
                 "YEAR_ROUND",
                 ["SEASONAL"],
                 %{@thanksgiving => "run"},
                 @today
               )

      assert atom_plan.result_dates == [
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]

      assert date_key_plan.result_dates == [
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               @thanksgiving,
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]
    end

    test "leaves the date between two conflicts running" do
      sources = %{"SEASONAL" => two_conflicts(3), "YEAR_ROUND" => year_round(8)}

      decisions = %{"2026-11-23" => "no_service", "2026-11-25" => "no_service"}

      assert {:ok, plan} =
               Combination.plan(sources, "YEAR_ROUND", ["SEASONAL"], decisions, @today)

      assert plan.ready? == true

      assert plan.result_dates == [
               ~D[2026-11-24],
               ~D[2026-11-26],
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]

      assert Enum.map(plan.conflicts, & &1.date) == [~D[2026-11-23], ~D[2026-11-25]]
      assert Enum.map(plan.conflicts, & &1.group_key) == ["2026-11-23", "2026-11-25"]
    end

    test "creates no conflict from a weekday absence, an out-of-range or a dates-only removal" do
      sources = %{
        "ALL_DAYS" => snapshot(weekly(@month_first, @month_last, @every_day), [], 4),
        "WEEKDAY" => weekday_removing_a_date_outside_its_range(6),
        "DATES_ONLY" => snapshot(nil, [removed(~D[2026-11-24])], 1)
      }

      assert {:ok, plan} =
               Combination.plan(sources, "ALL_DAYS", ["WEEKDAY", "DATES_ONLY"], %{}, @today)

      assert plan.conflicts == []
      assert plan.ready? == true
      assert plan.unresolved_dates == []
      assert plan.result_dates == plan.union_dates
      assert ~D[2026-11-28] in plan.result_dates
      assert ~D[2026-11-29] in plan.result_dates
      refute ~D[2026-12-25] in plan.union_dates
    end
  end

  describe "plan/5 conflict grouping" do
    test "groups civil-adjacent dates with equal participants under one key" do
      sources = %{"BASE" => year_round(9), "BREAK" => break_over_thursday_and_friday(5)}

      assert {:ok, plan} = Combination.plan(sources, "BASE", ["BREAK"], %{}, @today)

      assert plan.conflicts == [
               %{
                 date: ~D[2026-11-26],
                 running_ids: ["BASE"],
                 removing_ids: ["BREAK"],
                 group_key: "2026-11-26"
               },
               %{
                 date: ~D[2026-11-27],
                 running_ids: ["BASE"],
                 removing_ids: ["BREAK"],
                 group_key: "2026-11-26"
               }
             ]

      assert plan.unresolved_dates == [~D[2026-11-26], ~D[2026-11-27]]

      assert Combination.expand_group_choices(plan.conflicts, %{"2026-11-26" => "no_service"}) ==
               {:ok, %{"2026-11-26" => :no_service, "2026-11-27" => :no_service}}

      assert {:ok, decided} =
               Combination.plan(
                 sources,
                 "BASE",
                 ["BREAK"],
                 %{"2026-11-26" => "no_service", "2026-11-27" => "no_service"},
                 @today
               )

      assert decided.result_dates == [
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               ~D[2026-11-30]
             ]
    end

    test "keeps civil-adjacent dates with different participants in separate groups" do
      sources = %{
        "BASE" => year_round(9),
        "BREAK" => break_over_thursday_and_friday(5),
        "THURSDAY" => snapshot(nil, [added(~D[2026-11-26])], 1)
      }

      assert {:ok, plan} = Combination.plan(sources, "BASE", ["BREAK", "THURSDAY"], %{}, @today)

      assert plan.conflicts == [
               %{
                 date: ~D[2026-11-26],
                 running_ids: ["BASE", "THURSDAY"],
                 removing_ids: ["BREAK"],
                 group_key: "2026-11-26"
               },
               %{
                 date: ~D[2026-11-27],
                 running_ids: ["BASE"],
                 removing_ids: ["BREAK"],
                 group_key: "2026-11-27"
               }
             ]

      assert Combination.expand_group_choices(plan.conflicts, %{"2026-11-27" => "run"}) ==
               {:ok, %{"2026-11-27" => :run}}

      assert Combination.expand_group_choices(plan.conflicts, %{"2026-11-26" => :no_service}) ==
               {:ok, %{"2026-11-26" => :no_service}}
    end

    test "expands a group value against the current review only" do
      sources = %{"BASE" => year_round(9), "BREAK" => break_over_thursday_and_friday(5)}

      assert {:ok, plan} = Combination.plan(sources, "BASE", ["BREAK"], %{}, @today)

      assert Enum.map(plan.conflicts, & &1.group_key) == ["2026-11-26", "2026-11-26"]

      assert Combination.expand_group_choices(plan.conflicts, %{"2026-11-27" => "run"}) ==
               {:error, :invalid_command}

      assert Combination.expand_group_choices(plan.conflicts, %{"2026-11-25" => "run"}) ==
               {:error, :invalid_command}

      assert Combination.expand_group_choices(plan.conflicts, %{"2026-11-26" => "off"}) ==
               {:error, :invalid_command}

      assert Combination.expand_group_choices(plan.conflicts, %{@thanksgiving => "run"}) ==
               {:ok, %{"2026-11-26" => :run, "2026-11-27" => :run}}

      assert Combination.expand_group_choices([], %{"2026-11-26" => "run"}) ==
               {:error, :invalid_command}

      assert Combination.expand_group_choices(plan.conflicts, "2026-11-26") ==
               {:error, :invalid_command}
    end
  end

  describe "plan/5 effects" do
    test "states gains and losses per calendar split at agency-local today" do
      sources = %{
        "SEASONAL" => snapshot(weekly(~D[2026-11-16], ~D[2026-11-20], @weekdays), [], 2),
        "YEAR_ROUND" => year_round(5)
      }

      assert {:ok, plan} = Combination.plan(sources, "YEAR_ROUND", ["SEASONAL"], %{}, @today)

      assert plan.ready? == true
      assert Enum.map(plan.effects, & &1.service_id) == ["SEASONAL", "YEAR_ROUND"]

      assert plan.result_dates == [
               ~D[2026-11-16],
               ~D[2026-11-17],
               ~D[2026-11-18],
               ~D[2026-11-19],
               ~D[2026-11-20],
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               ~D[2026-11-26],
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]

      year_round = effect_for(plan, "YEAR_ROUND")

      assert year_round.trip_count == 5
      assert year_round.moving? == false

      assert year_round.gained_dates == [
               ~D[2026-11-16],
               ~D[2026-11-17],
               ~D[2026-11-18],
               ~D[2026-11-19],
               ~D[2026-11-20]
             ]

      assert year_round.upcoming_gained_dates == []
      assert year_round.past_gained_dates == year_round.gained_dates
      assert year_round.lost_dates == []

      seasonal = effect_for(plan, "SEASONAL")

      assert seasonal.trip_count == 2
      assert seasonal.moving? == true

      assert seasonal.gained_dates == [
               ~D[2026-11-23],
               ~D[2026-11-24],
               ~D[2026-11-25],
               ~D[2026-11-26],
               ~D[2026-11-27],
               ~D[2026-11-30]
             ]

      assert seasonal.upcoming_gained_dates == [~D[2026-11-26], ~D[2026-11-27], ~D[2026-11-30]]
      assert seasonal.past_gained_dates == [~D[2026-11-23], ~D[2026-11-24], ~D[2026-11-25]]
      assert seasonal.upcoming_lost_dates == []
      assert seasonal.past_lost_dates == []
    end

    test "reports source facts without final gains or losses while a conflict is undecided" do
      sources = %{"SEASONAL" => season_removing_thanksgiving(2), "YEAR_ROUND" => year_round(7)}

      assert {:ok, plan} = Combination.plan(sources, "YEAR_ROUND", ["SEASONAL"], %{}, @today)

      seasonal = effect_for(plan, "SEASONAL")

      assert seasonal.trip_count == 2
      assert seasonal.moving? == true
      assert seasonal.gained_dates == nil
      assert seasonal.lost_dates == nil
      assert seasonal.upcoming_gained_dates == nil
      assert seasonal.upcoming_lost_dates == nil
      assert seasonal.past_gained_dates == nil
      assert seasonal.past_lost_dates == nil
    end
  end

  describe "plan/5 command validation" do
    test "rejects repeated sources, destination-as-source, no sources and unknown IDs" do
      sources = %{"SEASONAL" => year_round(2), "YEAR_ROUND" => year_round(7)}

      assert Combination.plan(sources, "YEAR_ROUND", ["SEASONAL", "SEASONAL"], %{}, @today) ==
               {:error, :invalid_command}

      assert Combination.plan(sources, "YEAR_ROUND", ["YEAR_ROUND"], %{}, @today) ==
               {:error, :invalid_command}

      assert Combination.plan(sources, "YEAR_ROUND", [], %{}, @today) ==
               {:error, :invalid_command}

      assert Combination.plan(sources, "YEAR_ROUND", [""], %{}, @today) ==
               {:error, :invalid_command}

      assert Combination.plan(sources, " YEAR_ROUND ", ["SEASONAL"], %{}, @today) ==
               {:error, {:invalid_calendar, " YEAR_ROUND ", :missing}}

      assert Combination.plan(sources, "YEAR_ROUND", [" SEASONAL "], %{}, @today) ==
               {:error, {:invalid_calendar, " SEASONAL ", :missing}}

      assert Combination.plan(sources, "YEAR_ROUND", ["MISSING"], %{}, @today) ==
               {:error, {:invalid_calendar, "MISSING", :missing}}
    end

    test "rejects an unknown decision value" do
      sources = %{"SEASONAL" => season_removing_thanksgiving(2), "YEAR_ROUND" => year_round(7)}

      assert Combination.plan(
               sources,
               "YEAR_ROUND",
               ["SEASONAL"],
               %{"2026-11-26" => "maybe"},
               @today
             ) == {:error, :invalid_command}

      assert Combination.plan(
               sources,
               "YEAR_ROUND",
               ["SEASONAL"],
               %{"2026-11-26" => "off"},
               @today
             ) == {:error, :invalid_command}

      assert Combination.plan(
               sources,
               "YEAR_ROUND",
               ["SEASONAL"],
               %{"2026-11-26" => nil},
               @today
             ) == {:error, :invalid_command}
    end

    test "rejects a malformed or non-conflict decision key" do
      sources = %{"SEASONAL" => season_removing_thanksgiving(2), "YEAR_ROUND" => year_round(7)}

      assert Combination.plan(
               sources,
               "YEAR_ROUND",
               ["SEASONAL"],
               %{"not-a-date" => "run"},
               @today
             ) == {:error, :invalid_command}

      assert Combination.plan(
               sources,
               "YEAR_ROUND",
               ["SEASONAL"],
               %{"2026-11-26T00:00:00" => "run"},
               @today
             ) == {:error, :invalid_command}

      assert Combination.plan(
               sources,
               "YEAR_ROUND",
               ["SEASONAL"],
               %{"2026-11-24" => "run"},
               @today
             ) == {:error, :invalid_command}
    end

    test "rejects one conflict date reached twice" do
      sources = %{"SEASONAL" => season_removing_thanksgiving(2), "YEAR_ROUND" => year_round(7)}

      assert Combination.plan(
               sources,
               "YEAR_ROUND",
               ["SEASONAL"],
               %{"2026-11-26" => "run", @thanksgiving => "no_service"},
               @today
             ) == {:error, :invalid_command}
    end

    test "rejects a malformed command instead of raising" do
      sources = %{"SEASONAL" => year_round(2), "YEAR_ROUND" => year_round(7)}

      assert Combination.plan(sources, "YEAR_ROUND", "SEASONAL", %{}, @today) ==
               {:error, :invalid_command}

      assert Combination.plan([], "YEAR_ROUND", ["SEASONAL"], %{}, @today) ==
               {:error, :invalid_command}

      assert Combination.plan(sources, "YEAR_ROUND", ["SEASONAL"], [], @today) ==
               {:error, :invalid_command}

      assert Combination.plan(sources, "YEAR_ROUND", ["SEASONAL"], %{}, ~N[2026-11-26T00:00:00]) ==
               {:error, :invalid_command}

      assert Combination.plan(sources, nil, ["SEASONAL"], %{}, @today) ==
               {:error, :invalid_command}
    end

    test "names the selected calendar that cannot be evaluated" do
      base = year_round(7)

      reversed = %{
        "REVERSED" => snapshot(weekly(~D[2026-12-31], ~D[2026-01-01], @weekdays), [], 0),
        "YEAR_ROUND" => base
      }

      assert Combination.plan(reversed, "YEAR_ROUND", ["REVERSED"], %{}, @today) ==
               {:error, {:invalid_calendar, "REVERSED", :reversed_range}}

      contradictory = %{
        "CONFLICTING" => snapshot(nil, [added(@thanksgiving), removed(@thanksgiving)], 0),
        "YEAR_ROUND" => base
      }

      assert Combination.plan(contradictory, "YEAR_ROUND", ["CONFLICTING"], %{}, @today) ==
               {:error, {:invalid_calendar, "CONFLICTING", :conflicting_exceptions}}

      malformed_calendar = %{
        "NO_END" => %{
          calendar: %Calendar{start_date: @month_first, end_date: nil},
          exceptions: [],
          trip_count: 0
        },
        "YEAR_ROUND" => base
      }

      assert Combination.plan(malformed_calendar, "YEAR_ROUND", ["NO_END"], %{}, @today) ==
               {:error, {:invalid_calendar, "NO_END", :malformed_calendar}}

      malformed_snapshot = %{
        "INCOMPLETE" => %{calendar: nil, exceptions: []},
        "BAD_EXCEPTION" => %{
          calendar: nil,
          exceptions: [%CalendarDate{date: @thanksgiving, exception_type: 3}],
          trip_count: 0
        },
        "YEAR_ROUND" => base
      }

      assert Combination.plan(malformed_snapshot, "YEAR_ROUND", ["INCOMPLETE"], %{}, @today) ==
               {:error, {:invalid_calendar, "INCOMPLETE", :malformed_snapshot}}

      assert Combination.plan(malformed_snapshot, "YEAR_ROUND", ["BAD_EXCEPTION"], %{}, @today) ==
               {:error, {:invalid_calendar, "BAD_EXCEPTION", :malformed_calendar}}

      assert Combination.plan(%{}, "YEAR_ROUND", ["SEASONAL"], %{}, @today) ==
               {:error, {:invalid_calendar, "YEAR_ROUND", :missing}}
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp season_removing_thanksgiving(trip_count) do
    snapshot(weekly(@month_first, @month_last, @weekdays), [removed(@thanksgiving)], trip_count)
  end

  defp year_round(trip_count) do
    snapshot(weekly(@month_first, @month_last, @weekdays), [], trip_count)
  end

  defp two_conflicts(trip_count) do
    exceptions = [removed(~D[2026-11-23]), removed(~D[2026-11-25])]

    snapshot(weekly(@month_first, @month_last, @weekdays), exceptions, trip_count)
  end

  defp break_over_thursday_and_friday(trip_count) do
    exceptions = [removed(~D[2026-11-26]), removed(~D[2026-11-27])]

    snapshot(weekly(@month_first, @month_last, @weekdays), exceptions, trip_count)
  end

  defp weekday_removing_a_date_outside_its_range(trip_count) do
    exceptions = [removed(~D[2026-12-25])]

    snapshot(weekly(@month_first, @month_last, @weekdays), exceptions, trip_count)
  end

  # The snapshots carry the attributes key the review loader supplies; the pure algebra
  # does not consume it.
  defp snapshot(calendar, exceptions, trip_count) do
    %{calendar: calendar, exceptions: exceptions, attributes: nil, trip_count: trip_count}
  end

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

  defp added(date), do: %CalendarDate{date: date, exception_type: 1}
  defp removed(date), do: %CalendarDate{date: date, exception_type: 2}

  defp flag(weekdays, index), do: if(index in weekdays, do: 1, else: 0)

  defp effect_for(plan, service_id), do: Enum.find(plan.effects, &(&1.service_id == service_id))
end
