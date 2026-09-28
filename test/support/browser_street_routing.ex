defmodule GtfsPlanner.BrowserStreetRouting do
  @moduledoc """
  Test-only street routing adapter for browser journeys.

  `config/test.exs` selects it only while `BROWSER_E2E` is `true`, because a
  Playwright journey drives street generation in a real browser where no
  `Req.Test` stub exists. Ordinary ExUnit runs keep the production
  `GtfsPlanner.StreetRouting.Geoapify` adapter with a `Req.Test` plug.

  The adapter answers the same contract as the production adapter: one
  GeoJSON-ordered `[longitude, latitude]` leg per consecutive waypoint pair.
  Each leg holds the start point, the midpoint offset +0.0005° longitude, and
  the end point, so a journey can assert generated drafts without live
  Geoapify credits. A waypoint at latitude 40.7500 reports `{:error,
  :no_route}`, matching the production adapter's unroutable failure.
  """

  @behaviour GtfsPlanner.StreetRouting.Behaviour

  @unroutable_latitude 40.7500
  @midpoint_lon_offset 0.0005

  @impl GtfsPlanner.StreetRouting.Behaviour
  def route(waypoints, opts \\ [])

  def route(waypoints, _opts) when is_list(waypoints) do
    if valid_waypoints?(waypoints) do
      if Enum.any?(waypoints, fn {lat, _lon} -> lat == @unroutable_latitude end) do
        {:error, :no_route}
      else
        legs =
          waypoints
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [{lat1, lon1}, {lat2, lon2}] ->
            [
              [lon1, lat1],
              [(lon1 + lon2) / 2 + @midpoint_lon_offset, (lat1 + lat2) / 2],
              [lon2, lat2]
            ]
          end)

        {:ok, legs}
      end
    else
      {:error, :invalid_response}
    end
  end

  def route(_waypoints, _opts), do: {:error, :invalid_response}

  defp valid_waypoints?(waypoints) do
    length(waypoints) >= 2 and
      Enum.all?(waypoints, fn
        {lat, lon} when is_number(lat) and is_number(lon) -> true
        _waypoint -> false
      end)
  end
end
