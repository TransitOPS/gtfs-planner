defmodule GtfsPlanner.Gtfs.Fares.InterpreterLegsTest do
  @moduledoc """
  Merge evidence (EV-7): which `fare_leg_rules` price a leg, under both of the
  reference's readings of an empty field.

  Every row here is a `%Fares.Interpreter.Rows{}` literal with expected values worked
  out by hand from the GTFS reference's "Leg matching" section for
  `fare_leg_rules.txt` and from AC-4, so nothing in this file reads the database or
  asks the code under test for its own answer (CR-2).
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.Timeframe

  # A Monday and a Saturday inside both calendars' span.
  @monday ~D[2026-10-05]
  @saturday ~D[2026-10-10]

  describe "an empty field with no rule_priority anywhere" do
    test "means all others except what a rule that also applies lists" do
      rows = rows([leg("n1", "A", nil, nil, nil, "p1"), leg(nil, nil, nil, nil, nil, "p2")])

      assert Interpreter.leg_products(rows, "n1", "A", "B", []) == ["p1"]
      assert Interpreter.leg_products(rows, "n2", "A", "B", []) == ["p2"]
    end

    test "leaves a leg that leaves the version's networks or areas unpriced" do
      rows = rows([leg("n1", "A", nil, nil, nil, "p1")])

      assert Interpreter.leg_products(rows, nil, "A", "B", []) == []
      assert Interpreter.leg_products(rows, "n1", nil, "B", []) == []
    end

    test "processes an exact match on its own, without the empty rules" do
      rows =
        rows([
          leg("n1", "A", "B", nil, nil, "p_exact"),
          leg("n1", nil, nil, nil, nil, "p_network"),
          leg(nil, nil, nil, nil, nil, "p_flat")
        ])

      assert Interpreter.leg_products(rows, "n1", "A", "B", []) == ["p_exact"]
    end

    test "matches an empty timeframe at any time and a named one only when active" do
      rows =
        rows([leg("n1", nil, nil, "peak", nil, "p_peak"), leg("n1", nil, nil, nil, nil, "p_any")])

      assert Interpreter.leg_products(rows, "n1", "A", "B", ["peak"]) == ["p_peak"]
      assert Interpreter.leg_products(rows, "n1", "A", "B", []) == ["p_any"]
    end
  end

  describe "rule_priority" do
    test "turns an empty field into 'does not affect' and keeps the highest value" do
      rows =
        rows([
          leg("n1", "A", nil, nil, nil, "p1", rule_priority: 1),
          leg(nil, nil, nil, nil, nil, "p2", rule_priority: 0)
        ])

      assert Interpreter.leg_products(rows, "n1", "A", "B", []) == ["p1"]
      assert Interpreter.leg_products(rows, "n2", "A", "B", []) == ["p2"]
    end

    test "picks the more specific product at a peak time and the general one off-peak" do
      rows =
        rows([
          leg("n1", "A", "B", "peak", nil, "p3", rule_priority: 15),
          leg("n1", "A", "B", nil, nil, "p1", rule_priority: 7)
        ])

      assert Interpreter.leg_products(rows, "n1", "A", "B", ["peak"]) == ["p3"]
      assert Interpreter.leg_products(rows, "n1", "A", "B", []) == ["p1"]
    end

    test "returns every product at the top priority, because equal options coexist" do
      rows =
        rows([
          leg("n1", "A", "B", nil, nil, "p_card", rule_priority: 5),
          leg("n1", "A", "B", nil, nil, "p_cash", rule_priority: 5),
          leg(nil, nil, nil, nil, nil, "p_flat", rule_priority: 1)
        ])

      assert Interpreter.leg_products(rows, "n1", "A", "B", []) == ["p_card", "p_cash"]
    end

    test "reads an empty priority as 0, as the reference does" do
      rows =
        rows([
          leg(nil, nil, nil, nil, nil, "p_flat"),
          leg("n1", "A", "B", nil, nil, "p_exact", rule_priority: 0)
        ])

      assert Interpreter.leg_products(rows, "n1", "A", "B", []) == ["p_flat", "p_exact"]
    end
  end

  describe "the reference's worked leg-matching example" do
    # GTFS reference, fare_leg_rules.txt, the five steps for pricing one leg (quoted
    # in `.specs/_references/reports/GTFS fares v1 and v2 authoring research.md`:
    # "Leg matching: empty means 'all others' unless rule_priority exists"). One
    # network-and-area rule, one any-area rule for that network and one rule with
    # three empty conditions, with no rule_priority in the file.
    test "step 2, an exact match is processed" do
      assert Interpreter.leg_products(rows(example_rules()), "n1", "A", "B", []) == ["p_exact"]
    end

    test "step 3, an empty field takes the leg outside the enumerated network and area" do
      assert Interpreter.leg_products(rows(example_rules()), "n1", "A", "C", []) == ["p_network"]
      assert Interpreter.leg_products(rows(example_rules()), "n2", "A", "C", []) == ["p_flat"]
      assert Interpreter.leg_products(rows(example_rules()), "n2", "Z", "C", []) == ["p_flat"]
    end

    test "step 5, a leg no rule covers is unknown, which is no product" do
      assert Interpreter.leg_products(
               rows([leg("n1", "A", "B", nil, nil, "p_exact")]),
               "n2",
               "A",
               "B",
               []
             ) ==
               []
    end
  end

  describe "active_timeframes/3" do
    test "reports a group whose service runs and whose interval holds the time" do
      rows = timeframe_rows()

      assert Interpreter.active_timeframes(rows, @monday, 7 * 3600 + 40 * 60) == [
               "peak",
               "all_day"
             ]
    end

    test "starts inclusive and ends exclusive" do
      rows = timeframe_rows()

      assert "peak" in Interpreter.active_timeframes(rows, @monday, 6 * 3600)
      refute "peak" in Interpreter.active_timeframes(rows, @monday, 10 * 3600)
    end

    test "reads an empty end as the end of the day, and 24:00:00 as the same" do
      rows =
        timeframe_rows([
          timeframe("evening", "18:00:00", nil, "weekday"),
          timeframe("night", nil, "24:00:00", "weekday")
        ])

      assert Interpreter.active_timeframes(rows, @monday, 86_399) == ["evening", "night"]
      assert Interpreter.active_timeframes(rows, @monday, 86_400) == []
    end

    test "counts a group when any one of its rows matches" do
      rows =
        timeframe_rows([
          timeframe("peak", "06:00:00", "10:00:00", "weekday"),
          timeframe("peak", "12:00:00", "14:00:00", "saturday")
        ])

      assert Interpreter.active_timeframes(rows, @saturday, 13 * 3600) == ["peak"]
      assert Interpreter.active_timeframes(rows, @saturday, 9 * 3600) == []
    end

    test "lets a calendar_dates row add or remove the service for the date" do
      removed = timeframe_rows([], date_exceptions: [%{service_id: "weekday", exception_type: 2}])
      assert Interpreter.active_timeframes(removed, @monday, 7 * 3600 + 40 * 60) == []

      added =
        timeframe_rows(
          [timeframe("holiday", "06:00:00", "10:00:00", "holiday")],
          date_exceptions: [%{service_id: "holiday", exception_type: 1}]
        )

      assert Interpreter.active_timeframes(added, @monday, 7 * 3600) == ["holiday"]
      assert Interpreter.active_timeframes(added, @saturday, 7 * 3600) == []
    end
  end

  describe "network_for_route/2" do
    test "answers from route_networks when the version has it" do
      rows = %Rows{
        route_networks: %{"R1" => "n1"},
        route_network_ids: %{"R1" => "stale", "R2" => "n2"}
      }

      assert Interpreter.network_for_route(rows, "R1") == "n1"
      assert Interpreter.network_for_route(rows, "R2") == "n2"
      assert Interpreter.network_for_route(rows, "R3") == nil
    end
  end

  defp example_rules do
    [
      leg("n1", "A", "B", nil, nil, "p_exact"),
      leg("n1", nil, nil, nil, nil, "p_network"),
      leg(nil, nil, nil, nil, nil, "p_flat")
    ]
  end

  defp rows(leg_rules) do
    %Rows{fare_leg_rules: leg_rules}
  end

  defp leg(
         network_id,
         from_area_id,
         to_area_id,
         from_timeframe_group_id,
         to_timeframe_group_id,
         product_id,
         attrs \\ []
       ) do
    struct!(
      %FareLegRule{
        leg_group_id: "lg",
        network_id: network_id,
        from_area_id: from_area_id,
        to_area_id: to_area_id,
        from_timeframe_group_id: from_timeframe_group_id,
        to_timeframe_group_id: to_timeframe_group_id,
        fare_product_id: product_id,
        rule_priority: nil
      },
      attrs
    )
  end

  defp timeframe(group_id, start_time, end_time, service_id) do
    %Timeframe{
      timeframe_group_id: group_id,
      start_time: start_time,
      end_time: end_time,
      service_id: service_id
    }
  end

  defp timeframe_rows(timeframes \\ nil, opts \\ []) do
    timeframes =
      timeframes ||
        [
          timeframe("peak", "06:00:00", "10:00:00", "weekday"),
          timeframe("all_day", nil, nil, "weekday")
        ]

    %Rows{
      timeframes: timeframes,
      calendars: [
        %Calendar{
          service_id: "weekday",
          start_date: ~D[2026-10-01],
          end_date: ~D[2026-10-31],
          monday: 1,
          tuesday: 1,
          wednesday: 1,
          thursday: 1,
          friday: 1,
          saturday: 0,
          sunday: 0
        },
        %Calendar{
          service_id: "saturday",
          start_date: ~D[2026-10-01],
          end_date: ~D[2026-10-31],
          monday: 0,
          tuesday: 0,
          wednesday: 0,
          thursday: 0,
          friday: 0,
          saturday: 1,
          sunday: 0
        }
      ],
      calendar_dates:
        Enum.map(Keyword.get(opts, :date_exceptions, []), fn exception ->
          %CalendarDate{
            service_id: exception.service_id,
            date: @monday,
            exception_type: exception.exception_type
          }
        end)
    }
  end
end
