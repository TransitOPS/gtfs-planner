defmodule GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponentsTest do
  use ExUnit.Case, async: true

  alias GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents

  test "exposes change_log_list/1 as a function component" do
    Code.ensure_loaded!(ChangeHistoryComponents)
    assert function_exported?(ChangeHistoryComponents, :change_log_list, 1)
  end

  describe "display_name/1" do
    test "extracts and titlecases the local part of an email" do
      assert ChangeHistoryComponents.__test_display_name__("ryan.mahoney@example.com") ==
               "Ryan Mahoney"
    end

    test "returns Unknown for nil" do
      assert ChangeHistoryComponents.__test_display_name__(nil) == "Unknown"
    end

    test "returns Unknown for empty string" do
      assert ChangeHistoryComponents.__test_display_name__("") == "Unknown"
    end
  end

  describe "format_date_header/2" do
    test "labels today" do
      today = ~D[2026-04-26]
      assert ChangeHistoryComponents.__test_format_date_header__(today, today) =~ "TODAY"
    end

    test "labels yesterday" do
      today = ~D[2026-04-26]
      yesterday = Date.add(today, -1)

      assert ChangeHistoryComponents.__test_format_date_header__(yesterday, today) =~
               "YESTERDAY"
    end

    test "older dates render plain upcased month/day" do
      today = ~D[2026-04-26]
      older = Date.add(today, -10)
      result = ChangeHistoryComponents.__test_format_date_header__(older, today)

      refute result =~ "TODAY"
      refute result =~ "YESTERDAY"
      assert result == "APR 16"
    end
  end

  describe "format_time_short/2" do
    test "renders today's time without separator" do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      result = ChangeHistoryComponents.__test_format_time_short__(now, today)

      refute result =~ "·"
      assert result =~ ~r/\d{1,2}:\d{2}\s(AM|PM)/
    end

    test "renders other-day time with month/day separator" do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      yesterday = DateTime.add(now, -86_400, :second)

      assert ChangeHistoryComponents.__test_format_time_short__(yesterday, today) =~ "·"
    end
  end

  describe "group_entries_by_date/1" do
    test "groups by date and sorts descending" do
      d1 = ~U[2026-04-24 10:00:00Z]
      d2 = ~U[2026-04-25 10:00:00Z]
      d3 = ~U[2026-04-26 10:00:00Z]

      entries = [
        %{id: 1, inserted_at: d1},
        %{id: 2, inserted_at: d3},
        %{id: 3, inserted_at: d2},
        %{id: 4, inserted_at: d3}
      ]

      grouped = ChangeHistoryComponents.__test_group_entries_by_date__(entries)
      dates = Enum.map(grouped, fn {date, _} -> date end)

      assert dates == [~D[2026-04-26], ~D[2026-04-25], ~D[2026-04-24]]
    end
  end

  describe "relative_time/2" do
    test "just now for sub-minute differences" do
      now = DateTime.utc_now()
      assert ChangeHistoryComponents.__test_relative_time__(now, now) =~ "just now"
    end

    test "minutes ago" do
      now = DateTime.utc_now()
      five_min_ago = DateTime.add(now, -5 * 60, :second)

      assert ChangeHistoryComponents.__test_relative_time__(five_min_ago, now) ==
               "5 minutes ago"
    end

    test "yesterday for one-day-ago" do
      now = DateTime.utc_now()
      one_day_ago = DateTime.add(now, -86_400, :second)

      assert ChangeHistoryComponents.__test_relative_time__(one_day_ago, now) == "yesterday"
    end
  end
end
