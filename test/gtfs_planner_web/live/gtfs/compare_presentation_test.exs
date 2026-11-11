defmodule GtfsPlannerWeb.Gtfs.ComparePresentationTest do
  @moduledoc """
  EV-10: the pure R6 presentation values, over hand-built comparison results.

  No database, no Repo, no fixtures: every input is a plain map shaped like a
  finished `Compare.run/3` result, so the cases pin the derivation itself.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlannerWeb.Gtfs.ComparePresentation

  # A Monday, so the derived weekdays are consecutive.
  @reference ~D[2026-01-05]

  describe "per_date/1" do
    test "a non-comparable group makes that date nil" do
      [date | _] = weekday_dates(1)

      result =
        result(%{
          window: %{from: date, to: date},
          groups: [group(date, false, 5), group(date, true, 5)]
        })

      assert ComparePresentation.per_date(result) == [%{date: date, value: nil}]
    end

    test "comparable groups sum" do
      [date | _] = weekday_dates(1)

      result =
        result(%{
          window: %{from: date, to: date},
          groups: [group(date, true, 4), group(date, true, 2)]
        })

      assert ComparePresentation.per_date(result) == [%{date: date, value: 6}]
    end

    test "a date without groups is zero" do
      [first, second | _] = weekday_dates(2)

      result =
        result(%{
          window: %{from: first, to: second},
          groups: [group(first, true, 3)]
        })

      assert ComparePresentation.per_date(result) == [
               %{date: first, value: 3},
               %{date: second, value: 0}
             ]
    end
  end

  describe "day_classes/1" do
    test "five equal weekdays make a weekdays clause" do
      per_date = Enum.map(weekday_dates(5), &%{date: &1, value: 6})

      assert ComparePresentation.day_classes(per_date) == [%{class: :weekdays, value: 6}]
    end

    test "unequal weekdays make no clause" do
      per_date =
        weekday_dates(5)
        |> Enum.zip([6, 6, 0, 6, 6])
        |> Enum.map(fn {date, value} -> %{date: date, value: value} end)

      refute Enum.any?(ComparePresentation.day_classes(per_date), &(&1.class == :weekdays))
    end

    test "a nil Saturday removes the Saturday clause" do
      [saturday, later_saturday | _] = saturdays(2)

      per_date =
        Enum.map(weekday_dates(5), &%{date: &1, value: 6}) ++
          [
            %{date: saturday, value: 6},
            %{date: later_saturday, value: nil}
          ]

      assert ComparePresentation.day_classes(per_date) == [%{class: :weekdays, value: 6}]
    end
  end

  describe "conclusion/1" do
    test "conclusion counts distinct routes and route pairs" do
      [first, second | _] = weekday_dates(2)

      result =
        result(%{
          groups: [group(first, true, 1, "R1"), group(first, true, 3, "R2")],
          effective_changes: [
            change(first, :count_changed, "R1", 1),
            change(second, :count_changed, "R1", 2),
            change(first, :added, "R2", 3)
          ]
        })

      conclusion = ComparePresentation.conclusion(result)

      assert conclusion.changed == 2
      assert conclusion.compared == length(Compare.route_pairs(result))
    end
  end

  describe "route_rows/2 and kind_counts/1" do
    test "route_rows groups equal changes across dates" do
      [first, second | _] = weekday_dates(2)

      changes = [
        change(first, :timing_changed, "R1", 5),
        change(second, :timing_changed, "R1", 5)
      ]

      result = result(%{effective_changes: changes})

      assert [row] = ComparePresentation.route_rows(result, nil)
      assert row.dates == Enum.sort([first, second], Date)
      assert row.changes == changes
    end

    test "route_rows gives distinct stable ids to groups that differ only by delta" do
      [date | _] = weekday_dates(1)

      result =
        result(%{
          effective_changes: [
            change(date, :count_changed, "R1", 1),
            change(date, :count_changed, "R1", -2)
          ]
        })

      assert [first, second] = ComparePresentation.route_rows(result, nil)
      assert first.id != second.id

      # The id comes from the group's own key, so the same result always
      # produces the same row ids.
      assert Enum.map(ComparePresentation.route_rows(result, nil), & &1.id) ==
               [first.id, second.id]
    end

    test "route_rows gives distinct ids to route names that sanitize alike" do
      [date | _] = weekday_dates(1)

      result =
        result(%{
          effective_changes: [
            change(date, :count_changed, "A/B", 1),
            change(date, :count_changed, "A B", 1)
          ]
        })

      assert [first, second] = ComparePresentation.route_rows(result, nil)
      assert first.id != second.id
    end

    test "route_rows filters by kind and kind_counts counts every kind" do
      [first, second | _] = weekday_dates(2)

      result =
        result(%{
          effective_changes: [
            change(first, :timing_changed, "R1", 5),
            change(second, :timing_changed, "R1", 5),
            change(first, :count_changed, "R2", 7)
          ]
        })

      assert [row] = ComparePresentation.route_rows(result, :timing_changed)
      assert row.kind == :timing_changed

      assert ComparePresentation.kind_counts(result) == %{
               timing_changed: 2,
               count_changed: 1
             }
    end
  end

  describe "no_change?/1" do
    test "a complete empty comparison is a no-change result" do
      assert ComparePresentation.no_change?(result(%{}))
    end

    test "an incomplete comparison is never a no-change result" do
      incomplete =
        result(%{completeness: %{status: :incomplete, reasons: [:no_service_groups]}})

      refute ComparePresentation.no_change?(incomplete)
    end

    test "a structural change is not a no-change result" do
      result =
        result(%{
          structural_changes: [
            %{entity: :route, id: "R1", change: :identifier, meaning_changed: false}
          ]
        })

      refute ComparePresentation.no_change?(result)
    end
  end

  defp group(date, comparable?, scheduled, route \\ "R1") do
    %{
      route: route,
      route_ids: %{left: route, right: route},
      direction_id: 0,
      date: date,
      comparable?: comparable?,
      delta: delta(scheduled)
    }
  end

  defp change(date, kind, route, scheduled) do
    %{
      kind: kind,
      route: route,
      route_ids: %{left: route, right: route},
      direction_id: 0,
      date: date,
      dates: [date],
      delta: delta(scheduled)
    }
  end

  defp delta(scheduled) do
    %{scheduled_count: scheduled, exact_count: nil, first_secs: nil, last_secs: nil}
  end

  defp result(overrides) do
    Map.merge(
      %{
        window: %{from: @reference, to: @reference},
        groups: [],
        effective_changes: [],
        structural_changes: [],
        completeness: %{status: :complete, reasons: []}
      },
      overrides
    )
  end

  defp weekday_dates(count) do
    @reference
    |> Stream.iterate(&Date.add(&1, 1))
    |> Stream.filter(&(Date.day_of_week(&1) in 1..5))
    |> Enum.take(count)
  end

  defp saturdays(count) do
    @reference
    |> Stream.iterate(&Date.add(&1, 1))
    |> Stream.filter(&(Date.day_of_week(&1) == 6))
    |> Enum.take(count)
  end
end
