defmodule GtfsPlannerWeb.Gtfs.TimetablePasteReviewBlankTest do
  use ExUnit.Case, async: true

  alias GtfsPlannerWeb.Gtfs.TimetablePasteReview

  # A stop between timepoints may have no scheduled time, stored as nil offsets.
  # Removing a trip on such a timing shows its old times struck through.
  test "a removed trip's blank stop reads as blank, not as a time" do
    scope = %{
      pattern_id: "p1",
      patterns: [
        %{
          id: "p1",
          route_pattern_id: "RP1",
          occurrences: [
            %{id: "o1", stop_id: "A", position: 1},
            %{id: "o2", stop_id: "B", position: 2},
            %{id: "o3", stop_id: "C", position: 3}
          ],
          timings: [
            %{
              id: "t1",
              name: "Weekday",
              rows: [
                %{arrival_offset: 0, departure_offset: 0},
                %{arrival_offset: nil, departure_offset: nil},
                %{arrival_offset: 600, departure_offset: 600}
              ]
            }
          ]
        }
      ]
    }

    change = %{
      op: :remove,
      trip: %{trip_id: "T1", route_pattern_id: "RP1", timed_pattern_id: "t1", start_secs: 28_800}
    }

    %{rows: [row]} =
      TimetablePasteReview.build(%{plan: %{changes: [change]}}, scope, %{stops_view: :all})

    assert Enum.map(row.cells, &{&1.state, &1.secs}) == [
             {:time, 28_800},
             {:blank, nil},
             {:time, 29_400}
           ]
  end
end
