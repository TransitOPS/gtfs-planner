defmodule GtfsPlanner.StreetRouting.Behaviour do
  @moduledoc """
  Behaviour for a street routing service.

  Routing runs server-side so the Geoapify API key never reaches the browser.
  Waypoints are `{latitude, longitude}` tuples in visit order; returned legs
  are GeoJSON-ordered `[longitude, latitude]` point lists, one leg per
  consecutive waypoint pair.
  """

  @callback route([{float(), float()}], keyword()) ::
              {:ok, [[[float()]]]}
              | {:error,
                 :no_route | :unavailable | :rate_limited | :api_key_missing | :invalid_response}
end
