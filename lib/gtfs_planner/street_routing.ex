defmodule GtfsPlanner.StreetRouting do
  @moduledoc """
  Context module for server-side street routing.

  Dispatches to the configured `GtfsPlanner.StreetRouting.Behaviour`
  implementation (Geoapify in `bus` mode in production). Each waypoint pair
  costs one Geoapify credit.
  """

  alias GtfsPlanner.StreetRouting.Behaviour

  @behaviour Behaviour

  @doc """
  Routes through the given waypoints in order.

  Returns `{:ok, legs}` with one `[longitude, latitude]` leg per consecutive
  waypoint pair, or `{:error, reason}` on failure.

  ## Parameters

    - `waypoints` - a list of `{latitude, longitude}` tuples in visit order
      (at least two)
    - `opts` - optional keyword list of options (currently unused)

  ## Examples

      iex> route([{40.7128, -74.006}, {40.7138, -74.005}])
      {:ok, [[[-74.006, 40.7128], [-74.005, 40.7138]]]}
  """
  @spec route([{float(), float()}], keyword()) ::
          {:ok, [[[float()]]]}
          | {:error,
             :no_route | :unavailable | :rate_limited | :api_key_missing | :invalid_response}
  @impl Behaviour
  def route(waypoints, opts \\ []) do
    service =
      Application.get_env(
        :gtfs_planner,
        :street_routing_service,
        GtfsPlanner.StreetRouting.Geoapify
      )

    service.route(waypoints, opts)
  end
end
