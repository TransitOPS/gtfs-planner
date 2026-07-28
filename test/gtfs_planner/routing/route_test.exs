defmodule GtfsPlanner.Routing.RouteTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Routing.Route

  describe "from_itinerary/1" do
    test "derives step_count from the converted step list" do
      itinerary = %PathwaysRouter.Itinerary{
        duration_seconds: 120,
        distance_meters: 85.5,
        generalized_cost: 240,
        steps: [
          %{
            relative_direction: :depart,
            street_name: "Main St",
            distance_meters: 50.0,
            name_derived?: false
          },
          %{
            relative_direction: :right,
            street_name: "pathway",
            distance_meters: 35.5,
            name_derived?: true
          }
        ]
      }

      route = Route.from_itinerary(itinerary)

      assert route.duration_seconds == 120
      assert route.distance_meters == 85.5
      assert route.generalized_cost == 240
      assert route.step_count == 2
    end

    test "sets step_count to 0 for an empty step list" do
      itinerary = %PathwaysRouter.Itinerary{
        duration_seconds: 0,
        distance_meters: 0.0,
        generalized_cost: 0,
        steps: []
      }

      route = Route.from_itinerary(itinerary)

      assert route.step_count == 0
      assert route.steps == []
    end

    test "step maps expose direction, name, distance_meters, and name_derived?" do
      itinerary = %PathwaysRouter.Itinerary{
        duration_seconds: 60,
        distance_meters: 40.0,
        generalized_cost: 120,
        steps: [
          %{
            relative_direction: :follow_signs,
            street_name: "To Platform 1",
            distance_meters: 40.0,
            name_derived?: false
          }
        ]
      }

      route = Route.from_itinerary(itinerary)
      [step] = route.steps

      assert step.direction == :follow_signs
      assert step.name == "To Platform 1"
      assert step.distance_meters == 40.0
      assert step.name_derived? == false
    end
  end
end
