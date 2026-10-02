defmodule GtfsPlannerWeb.Gtfs.CalendarComponentsTest do
  use ExUnit.Case, async: true

  alias GtfsPlannerWeb.Gtfs.CalendarComponents

  defp weekly(days) do
    base = %{
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0
    }

    %{calendar: Enum.reduce(days, base, &Map.put(&2, &1, 1))}
  end

  describe "runs_line/1" do
    test "leads a specific-dates calendar with the dates it lists" do
      assert CalendarComponents.runs_line(%{calendar: nil}) == "Runs on specific dates"
    end

    test "names a Monday to Friday calendar as a range" do
      row = weekly([:monday, :tuesday, :wednesday, :thursday, :friday])

      assert CalendarComponents.runs_line(row) == "Runs Mon–Fri"
    end

    test "names a weekend calendar as a range" do
      assert CalendarComponents.runs_line(weekly([:saturday, :sunday])) == "Runs Sat–Sun"
    end

    test "names a calendar with one weekly day in the plural" do
      assert CalendarComponents.runs_line(weekly([:saturday])) == "Runs Saturdays"
    end

    test "lists days that do not form a range" do
      assert CalendarComponents.runs_line(weekly([:monday, :wednesday])) == "Runs Mon, Wed"
    end

    test "says a calendar with every weekday runs every day" do
      row =
        weekly([:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday])

      assert CalendarComponents.runs_line(row) == "Runs every day"
    end

    test "says a weekly calendar with no weekly days has none" do
      assert CalendarComponents.runs_line(weekly([])) == "Has no weekly days"
    end
  end

  describe "coverage_caption/1" do
    test "omits a zero days-off part" do
      row = %{
        kind: :weekly,
        first_active_date: ~D[2026-09-01],
        last_active_date: ~D[2026-09-30],
        periods: %{breaks: [%{}], holidays: [], extra_days: []}
      }

      caption = CalendarComponents.coverage_caption(row)

      assert caption == "Sep 1, 2026 – Sep 30, 2026 · 1 break"
      refute caption =~ "days off"
    end
  end
end
