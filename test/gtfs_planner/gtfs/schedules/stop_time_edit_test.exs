defmodule GtfsPlanner.Gtfs.Schedules.StopTimeEditTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Schedules.StopTimeEdit

  # Every expected list below is literal and hand-derived from the R1 rules and
  # examples in spec.md §4.2. Nothing here computes an expectation with the module
  # under test.

  # Riverside 07:15, Oak Avenue 07:20, Cedar Library 07:26, Market Square 07:33,
  # Valley College 07:53 — the R1 example trip.
  @cedar [
    %{arrival: 26_100, departure: 26_100, timepoint: 1},
    %{arrival: 26_400, departure: 26_400, timepoint: 1},
    %{arrival: 26_760, departure: 26_760, timepoint: 1},
    %{arrival: 27_180, departure: 27_180, timepoint: 1},
    %{arrival: 28_380, departure: 28_380, timepoint: 1}
  ]

  # Shown stops 1 and 4; stops 2 and 3 are hidden non-timepoints.
  @hidden_before [
    %{arrival: 0, departure: 0, timepoint: 1},
    %{arrival: 251, departure: 251, timepoint: 0},
    %{arrival: 499, departure: 499, timepoint: 0},
    %{arrival: 1000, departure: 1000, timepoint: 1}
  ]

  # Shown stops 1, 4 and 7; stops 2, 3, 5 and 6 are hidden non-timepoints, and the
  # hidden stops carry dwell.
  @timepoints [
    %{arrival: 0, departure: 0, timepoint: 1},
    %{arrival: 151, departure: 201, timepoint: 0},
    %{arrival: 499, departure: 549, timepoint: 0},
    %{arrival: 900, departure: 1000, timepoint: 1},
    %{arrival: 1050, departure: 1100, timepoint: 0},
    %{arrival: 1350, departure: 1400, timepoint: 0},
    %{arrival: 1500, departure: 1500, timepoint: 1}
  ]

  describe "apply/5 :later" do
    test "moves the edited stop and every later stop" do
      assert StopTimeEdit.apply(@cedar, 3, 26_880, :later, :all) ==
               {:ok,
                [
                  %{arrival: 26_100, departure: 26_100, timepoint: 1},
                  %{arrival: 26_400, departure: 26_400, timepoint: 1},
                  %{arrival: 26_880, departure: 26_880, timepoint: 1},
                  %{arrival: 27_300, departure: 27_300, timepoint: 1},
                  %{arrival: 28_500, departure: 28_500, timepoint: 1}
                ]}
    end

    test "leaves the earlier stops fixed when the edit moves a stop earlier" do
      assert StopTimeEdit.apply(@cedar, 4, 26_880, :later, :all) ==
               {:ok,
                [
                  %{arrival: 26_100, departure: 26_100, timepoint: 1},
                  %{arrival: 26_400, departure: 26_400, timepoint: 1},
                  %{arrival: 26_760, departure: 26_760, timepoint: 1},
                  %{arrival: 26_880, departure: 26_880, timepoint: 1},
                  %{arrival: 28_080, departure: 28_080, timepoint: 1}
                ]}
    end

    test "keeps the edited stop's dwell" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 60, departure: 90, timepoint: 1},
        %{arrival: 120, departure: 120, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 2, 130, :later, :all) ==
               {:ok,
                [
                  %{arrival: 0, departure: 0, timepoint: 1},
                  %{arrival: 100, departure: 130, timepoint: 1},
                  %{arrival: 160, departure: 160, timepoint: 1}
                ]}
    end

    test "moves the whole trip when the first stop is edited" do
      expected =
        {:ok,
         [
           %{arrival: 26_400, departure: 26_400, timepoint: 1},
           %{arrival: 26_700, departure: 26_700, timepoint: 1},
           %{arrival: 27_060, departure: 27_060, timepoint: 1},
           %{arrival: 27_480, departure: 27_480, timepoint: 1},
           %{arrival: 28_680, departure: 28_680, timepoint: 1}
         ]}

      assert StopTimeEdit.apply(@cedar, 1, 26_400, :later, :all) == expected
      assert StopTimeEdit.apply(@cedar, 1, 26_400, :only, [1, 3]) == expected
    end
  end

  describe "apply/5 :only" do
    test "moves one stop in All stops" do
      assert StopTimeEdit.apply(@cedar, 3, 26_880, :only, :all) ==
               {:ok,
                [
                  %{arrival: 26_100, departure: 26_100, timepoint: 1},
                  %{arrival: 26_400, departure: 26_400, timepoint: 1},
                  %{arrival: 26_880, departure: 26_880, timepoint: 1},
                  %{arrival: 27_180, departure: 27_180, timepoint: 1},
                  %{arrival: 28_380, departure: 28_380, timepoint: 1}
                ]}
    end

    test "re-spaces the hidden stops between the previous shown stop and the edit" do
      assert StopTimeEdit.apply(@hidden_before, 4, 1200, :only, [1, 4]) ==
               {:ok,
                [
                  %{arrival: 0, departure: 0, timepoint: 1},
                  %{arrival: 301, departure: 301, timepoint: 0},
                  %{arrival: 598, departure: 598, timepoint: 0},
                  %{arrival: 1200, departure: 1200, timepoint: 1}
                ]}
    end

    test "re-spaces the hidden stops on both sides of the edit, floored per value" do
      assert StopTimeEdit.apply(@timepoints, 4, 700, :only, [1, 4, 7]) ==
               {:ok,
                [
                  %{arrival: 0, departure: 0, timepoint: 1},
                  %{arrival: 100, departure: 134, timepoint: 0},
                  %{arrival: 332, departure: 366, timepoint: 0},
                  %{arrival: 600, departure: 700, timepoint: 1},
                  %{arrival: 780, departure: 860, timepoint: 0},
                  %{arrival: 1260, departure: 1340, timepoint: 0},
                  %{arrival: 1500, departure: 1500, timepoint: 1}
                ]}
    end

    test "maps a hidden stop between anchors with dwell through one travel span" do
      # Previous shown stop 07:00/07:05, hidden 07:06/07:06, edited 07:10 -> 07:20:
      # the 5-minute span from 07:05 becomes 15 minutes, so 07:06 lands on 07:08.
      stops = [
        %{arrival: 25_200, departure: 25_500, timepoint: 1},
        %{arrival: 25_560, departure: 25_560, timepoint: 0},
        %{arrival: 25_800, departure: 25_800, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 3, 26_400, :only, [1, 3]) ==
               {:ok,
                [
                  %{arrival: 25_200, departure: 25_500, timepoint: 1},
                  %{arrival: 25_680, departure: 25_680, timepoint: 0},
                  %{arrival: 26_400, departure: 26_400, timepoint: 1}
                ]}
    end

    test "keeps a hidden stop's blank times blank when re-spacing" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: nil, departure: nil, timepoint: 0},
        %{arrival: nil, departure: 549, timepoint: 0},
        %{arrival: 1000, departure: 1000, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 4, 1200, :only, [1, 4]) ==
               {:ok,
                [
                  %{arrival: 0, departure: 0, timepoint: 1},
                  %{arrival: nil, departure: nil, timepoint: 0},
                  %{arrival: nil, departure: 658, timepoint: 0},
                  %{arrival: 1200, departure: 1200, timepoint: 1}
                ]}
    end

    test "sets a hidden run before the edit to the previous shown stop's new time" do
      stops = [
        %{arrival: 100, departure: 100, timepoint: 1},
        %{arrival: 100, departure: 100, timepoint: 0},
        %{arrival: 100, departure: 100, timepoint: 0},
        %{arrival: 100, departure: 100, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 4, 200, :only, [1, 4]) ==
               {:ok,
                [
                  %{arrival: 100, departure: 100, timepoint: 1},
                  %{arrival: 100, departure: 100, timepoint: 0},
                  %{arrival: 100, departure: 100, timepoint: 0},
                  %{arrival: 200, departure: 200, timepoint: 1}
                ]}
    end

    test "sets a hidden run after the edit to the edited stop's new time" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 100, departure: 100, timepoint: 1},
        %{arrival: 100, departure: 100, timepoint: 0},
        %{arrival: 100, departure: 100, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 2, 50, :only, [1, 2, 4]) ==
               {:ok,
                [
                  %{arrival: 0, departure: 0, timepoint: 1},
                  %{arrival: 50, departure: 50, timepoint: 1},
                  %{arrival: 50, departure: 50, timepoint: 0},
                  %{arrival: 100, departure: 100, timepoint: 1}
                ]}
    end
  end

  describe "apply/5 :anchor" do
    test "moves every stop by the same change" do
      assert StopTimeEdit.apply(@cedar, 3, 26_880, :anchor, :all) ==
               {:ok,
                [
                  %{arrival: 26_220, departure: 26_220, timepoint: 1},
                  %{arrival: 26_520, departure: 26_520, timepoint: 1},
                  %{arrival: 26_880, departure: 26_880, timepoint: 1},
                  %{arrival: 27_300, departure: 27_300, timepoint: 1},
                  %{arrival: 28_500, departure: 28_500, timepoint: 1}
                ]}
    end
  end

  describe "apply/5 last stop" do
    test "edits the arrival and keeps the dwell" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 60, departure: 90, timepoint: 1},
        %{arrival: 120, departure: 150, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 3, 210, :later, :all) ==
               {:ok,
                [
                  %{arrival: 0, departure: 0, timepoint: 1},
                  %{arrival: 60, departure: 90, timepoint: 1},
                  %{arrival: 210, departure: 240, timepoint: 1}
                ]}
    end
  end

  describe "apply/5 stops with no stored time" do
    test "sets both times and moves no other stop in every mode" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 60, departure: 60, timepoint: 1},
        %{arrival: nil, departure: nil, timepoint: 0},
        %{arrival: 240, departure: 240, timepoint: 1}
      ]

      expected =
        {:ok,
         [
           %{arrival: 0, departure: 0, timepoint: 1},
           %{arrival: 60, departure: 60, timepoint: 1},
           %{arrival: 180, departure: 180, timepoint: 0},
           %{arrival: 240, departure: 240, timepoint: 1}
         ]}

      assert StopTimeEdit.apply(stops, 3, 180, :later, :all) == expected
      assert StopTimeEdit.apply(stops, 3, 180, :only, :all) == expected
      assert StopTimeEdit.apply(stops, 3, 180, :anchor, :all) == expected
    end
  end

  describe "apply/5 refusals" do
    test "reports the position whose arrival precedes the previous departure" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 60, departure: 60, timepoint: 1},
        %{arrival: 120, departure: 120, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 3, 30, :later, :all) ==
               {:error, {:out_of_order, 3}}
    end

    test "refuses a result with a negative time" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 60, departure: 60, timepoint: 1},
        %{arrival: 120, departure: 120, timepoint: 1}
      ]

      assert StopTimeEdit.apply(stops, 2, 10, :anchor, :all) == {:error, :negative_time}
    end
  end

  describe "clear/2" do
    test "clears an intermediate non-timepoint stop" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 60, departure: 90, timepoint: 0},
        %{arrival: 120, departure: 150, timepoint: 0},
        %{arrival: 200, departure: 200, timepoint: 1}
      ]

      assert StopTimeEdit.clear(stops, 2) ==
               {:ok,
                [
                  %{arrival: 0, departure: 0, timepoint: 1},
                  %{arrival: nil, departure: nil, timepoint: 0},
                  %{arrival: 120, departure: 150, timepoint: 0},
                  %{arrival: 200, departure: 200, timepoint: 1}
                ]}
    end

    test "refuses the first stop, the last stop and a timepoint stop" do
      assert StopTimeEdit.clear(@cedar, 1) == {:error, :clear_not_allowed}
      assert StopTimeEdit.clear(@cedar, 5) == {:error, :clear_not_allowed}
      assert StopTimeEdit.clear(@cedar, 3) == {:error, :clear_not_allowed}
    end

    test "refuses a stop whose timepoint is not stored as 0" do
      stops = [
        %{arrival: 0, departure: 0, timepoint: 1},
        %{arrival: 60, departure: 60, timepoint: nil},
        %{arrival: 120, departure: 120, timepoint: 1}
      ]

      assert StopTimeEdit.clear(stops, 2) == {:error, :clear_not_allowed}
    end
  end
end
