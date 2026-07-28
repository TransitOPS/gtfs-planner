defmodule GtfsPlanner.Routing.Route do
  @moduledoc """
  Application-owned, serializable result of a routing plan.
  """

  @type step :: %{
          direction: atom(),
          name: String.t(),
          distance_meters: float(),
          name_derived?: boolean()
        }

  @type t :: %__MODULE__{
          duration_seconds: non_neg_integer(),
          distance_meters: float(),
          generalized_cost: non_neg_integer(),
          step_count: non_neg_integer(),
          steps: [step()]
        }

  defstruct [:duration_seconds, :distance_meters, :generalized_cost, :step_count, steps: []]

  @spec from_itinerary(PathwaysRouter.Itinerary.t()) :: t()
  def from_itinerary(%PathwaysRouter.Itinerary{} = itinerary) do
    steps =
      Enum.map(itinerary.steps, fn step ->
        %{
          direction: step.relative_direction,
          name: step.street_name,
          distance_meters: step.distance_meters,
          name_derived?: step.name_derived?
        }
      end)

    %__MODULE__{
      duration_seconds: itinerary.duration_seconds,
      distance_meters: itinerary.distance_meters,
      generalized_cost: itinerary.generalized_cost,
      step_count: length(steps),
      steps: steps
    }
  end
end
