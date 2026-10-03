defmodule GtfsPlannerWeb.Gtfs.AlertComponentsTest do
  use ExUnit.Case, async: true

  alias GtfsPlannerWeb.Gtfs.AlertComponents

  # The diagnostics are shaped the way `Alerts.Targets` returns them, so each sentence
  # is the one the Alerts list and the editor's repair panel show for that selector.
  describe "target_note/1" do
    test "names a selector the active schedule lacks by its type and ID" do
      assert AlertComponents.target_note(%{
               kind: :missing,
               target_type: :stop,
               id: "S1",
               reason: :not_in_active_schedule,
               selector: %{stop_id: "S1"}
             }) == "Stop S1 is not in the active schedule"
    end

    test "says which route does not serve the stop of a pair" do
      assert AlertComponents.target_note(%{
               kind: :inapplicable,
               target_type: :route_stop_pair,
               id: "S2",
               reason: :stop_not_on_route,
               selector: %{route_id: "R1", stop_id: "S2"}
             }) == "Route R1 does not serve stop S2"
    end

    test "says which stretch no trip runs" do
      assert AlertComponents.target_note(%{
               kind: :inapplicable,
               target_type: :stretch,
               id: "C",
               reason: :stretch_not_on_route,
               selector: %{
                 route_ids: ["R1"],
                 stretch_from_stop_id: "C",
                 stretch_to_stop_id: "A"
               }
             }) == "No trip runs from stop C to stop A"
    end

    test "says which dated trip does not run, and which start is not a departure" do
      trip = %{kind: :inapplicable, target_type: :trip, id: "T1"}

      assert AlertComponents.target_note(
               Map.merge(trip, %{
                 reason: :service_not_running_on_date,
                 selector: %{trip_id: "T1", service_date: ~D[2026-10-12], start_time: nil}
               })
             ) == "Trip T1 does not run on 2026-10-12"

      assert AlertComponents.target_note(
               Map.merge(trip, %{
                 reason: :start_time_not_a_departure,
                 selector: %{
                   trip_id: "T1",
                   service_date: ~D[2026-10-05],
                   start_time: "09:10:00"
                 }
               })
             ) == "Trip T1 has no departure at 09:10:00"
    end

    test "reads a diagnostic it has no sentence for instead of raising" do
      unlisted = %{
        kind: :inapplicable,
        target_type: :fare_zone,
        id: "Z1",
        reason: :zone_closed,
        selector: %{}
      }

      assert AlertComponents.target_note(unlisted) == "Target Z1 needs attention"
      assert AlertComponents.target_type_label(:fare_zone) == "Target"
    end
  end
end
