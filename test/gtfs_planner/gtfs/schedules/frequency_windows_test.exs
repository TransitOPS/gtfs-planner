defmodule GtfsPlanner.Gtfs.Schedules.FrequencyWindowsTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Schedules.FrequencyWindows

  # Every expected value below is literal and hand-derived from the R8 rules and the
  # examples in spec.md §4.2 and the GTFS reference. Nothing here computes an
  # expectation with the module under test.

  # 06:00–07:00 every 10 min — the R8 example window.
  @six_to_seven %{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}

  describe "validate/1" do
    test "accepts one window and an empty list" do
      assert FrequencyWindows.validate([@six_to_seven]) == :ok
      assert FrequencyWindows.validate([]) == :ok
    end

    test "accepts touching windows" do
      assert FrequencyWindows.validate([
               @six_to_seven,
               %{start_secs: 25_200, end_secs: 28_800, headway_secs: 600}
             ]) == :ok
    end

    test "accepts touching windows submitted out of order" do
      assert FrequencyWindows.validate([
               %{start_secs: 25_200, end_secs: 28_800, headway_secs: 600},
               @six_to_seven
             ]) == :ok
    end

    test "reports an overlap at the later window's index" do
      assert FrequencyWindows.validate([
               @six_to_seven,
               %{start_secs: 23_400, end_secs: 28_800, headway_secs: 600}
             ]) == {:error, [%{index: 1, reason: :overlap}]}
    end

    test "reports an overlap against the window that starts later, not the row order" do
      assert FrequencyWindows.validate([
               %{start_secs: 23_400, end_secs: 28_800, headway_secs: 600},
               @six_to_seven
             ]) == {:error, [%{index: 0, reason: :overlap}]}
    end

    test "reports every window that starts inside an earlier one" do
      # The third window touches the second but starts inside the first
      # (06:00–07:00), so both later windows overlap.
      assert FrequencyWindows.validate([
               @six_to_seven,
               %{start_secs: 21_600, end_secs: 23_400, headway_secs: 600},
               %{start_secs: 23_400, end_secs: 25_200, headway_secs: 600}
             ]) == {:error, [%{index: 1, reason: :overlap}, %{index: 2, reason: :overlap}]}
    end

    test "reports a window nested after a long one even when it clears its neighbour" do
      # 06:00–10:00, 07:00–08:00 and 09:00–09:30: the last window clears 08:00 but
      # starts inside 06:00–10:00.
      assert FrequencyWindows.validate([
               %{start_secs: 21_600, end_secs: 36_000, headway_secs: 600},
               %{start_secs: 25_200, end_secs: 28_800, headway_secs: 600},
               %{start_secs: 32_400, end_secs: 34_200, headway_secs: 600}
             ]) == {:error, [%{index: 1, reason: :overlap}, %{index: 2, reason: :overlap}]}
    end

    test "accepts a window after 24:00" do
      assert FrequencyWindows.validate([
               %{start_secs: 90_000, end_secs: 93_600, headway_secs: 900}
             ]) == :ok
    end

    test "refuses Until equal to From" do
      assert FrequencyWindows.validate([
               %{start_secs: 21_600, end_secs: 21_600, headway_secs: 600}
             ]) == {:error, [%{index: 0, reason: :until_not_after_from}]}
    end

    test "refuses Until before From" do
      assert FrequencyWindows.validate([
               %{start_secs: 25_200, end_secs: 21_600, headway_secs: 600}
             ]) == {:error, [%{index: 0, reason: :until_not_after_from}]}
    end

    test "refuses a headway that is not a whole number of minutes" do
      assert FrequencyWindows.validate([
               %{start_secs: 21_600, end_secs: 25_200, headway_secs: 90}
             ]) == {:error, [%{index: 0, reason: :invalid_headway}]}
    end

    test "refuses a headway of zero" do
      assert FrequencyWindows.validate([
               %{start_secs: 21_600, end_secs: 25_200, headway_secs: 0}
             ]) == {:error, [%{index: 0, reason: :invalid_headway}]}
    end

    test "reports every bad window with its index and reason" do
      assert FrequencyWindows.validate([
               %{start_secs: 21_600, end_secs: 22_200, headway_secs: 600},
               %{start_secs: 21_600, end_secs: 21_600, headway_secs: 600},
               %{start_secs: 25_200, end_secs: 25_800, headway_secs: 90}
             ]) ==
               {:error,
                [
                  %{index: 1, reason: :until_not_after_from},
                  %{index: 2, reason: :invalid_headway}
                ]}
    end
  end

  describe "departures/1" do
    test "lists six departures for 06:00–07:00 every 10 min and never Until" do
      departures = FrequencyWindows.departures(@six_to_seven)

      assert departures == [21_600, 22_200, 22_800, 23_400, 24_000, 24_600]
      refute 25_200 in departures
    end

    test "supports windows after 24:00" do
      assert FrequencyWindows.departures(%{
               start_secs: 90_000,
               end_secs: 93_600,
               headway_secs: 900
             }) == [90_000, 90_900, 91_800, 92_700]
    end

    test "lists one departure when the headway is longer than the window" do
      assert FrequencyWindows.departures(%{
               start_secs: 21_600,
               end_secs: 21_900,
               headway_secs: 600
             }) == [21_600]
    end

    test "lists no departures when Until is not later than From" do
      assert FrequencyWindows.departures(%{
               start_secs: 21_600,
               end_secs: 21_600,
               headway_secs: 600
             }) == []
    end
  end

  describe "summary/1" do
    test "counts the departures and names the last and the next" do
      assert FrequencyWindows.summary(@six_to_seven) ==
               %{count: 6, last_secs: 24_600, next_secs: 25_200, longer_than_window?: false}
    end

    test "names the next departure at Until when the window divides evenly" do
      assert FrequencyWindows.summary(%{
               start_secs: 90_000,
               end_secs: 93_600,
               headway_secs: 600
             }) ==
               %{count: 6, last_secs: 93_000, next_secs: 93_600, longer_than_window?: false}
    end

    test "flags a headway longer than the window" do
      assert FrequencyWindows.summary(%{
               start_secs: 21_600,
               end_secs: 21_900,
               headway_secs: 600
             }) ==
               %{count: 1, last_secs: 21_600, next_secs: 22_200, longer_than_window?: true}
    end

    test "does not flag a headway equal to the window" do
      assert FrequencyWindows.summary(%{
               start_secs: 21_600,
               end_secs: 22_200,
               headway_secs: 600
             }) ==
               %{count: 1, last_secs: 21_600, next_secs: 22_200, longer_than_window?: false}
    end

    test "reports an empty window with no departures and no warning" do
      assert FrequencyWindows.summary(%{
               start_secs: 21_600,
               end_secs: 21_600,
               headway_secs: 600
             }) ==
               %{count: 0, last_secs: nil, next_secs: nil, longer_than_window?: false}
    end
  end
end
