defmodule GtfsPlanner.StreetRouting.Geoapify do
  @moduledoc """
  Street routing through the Geoapify Routing API in `bus` mode.

  The API key stays server-side: it is read from the existing
  `:geoapify_api_key` application env and is never returned in an error tuple
  or written to the logs. Every failure is a bare atom so `Req` error structs
  (which can embed the request URL) never escape this boundary.

  Requests are chunked into runs of at most 25 waypoints sharing each boundary
  waypoint, and legs are concatenated back in order. A chunk whose leg count
  does not match its pair count fails the whole route rather than returning a
  partial result.
  """

  alias GtfsPlanner.StreetRouting.Behaviour

  require Logger

  @behaviour Behaviour

  @routing_url "https://api.geoapify.com/v1/routing"
  @max_waypoints_per_request 25

  @impl Behaviour
  def route(waypoints, _opts \\ []) do
    case do_route(waypoints) do
      {:ok, _legs} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning("street routing failed", reason: reason)
        error
    end
  end

  defp do_route(waypoints) when is_list(waypoints) do
    if valid_waypoints?(waypoints) do
      with {:ok, key} <- api_key() do
        waypoints
        |> chunk_waypoints()
        |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
          case request_chunk(chunk, key) do
            {:ok, legs} -> {:cont, {:ok, acc ++ legs}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
      end
    else
      {:error, :invalid_response}
    end
  end

  defp do_route(_waypoints), do: {:error, :invalid_response}

  defp valid_waypoints?(waypoints) do
    length(waypoints) >= 2 and Enum.all?(waypoints, &valid_waypoint?/1)
  end

  defp valid_waypoint?({lat, lon}) when is_number(lat) and is_number(lon), do: true
  defp valid_waypoint?(_), do: false

  defp api_key do
    case Application.get_env(:gtfs_planner, :geoapify_api_key) do
      nil -> {:error, :api_key_missing}
      key -> {:ok, key}
    end
  end

  # Chunks share each boundary waypoint: chunk k covers waypoints
  # [24k .. 24k+24]. A trailing single waypoint only shares the previous
  # chunk's boundary, so chunks below two waypoints are dropped.
  defp chunk_waypoints(waypoints) do
    waypoints
    |> Enum.chunk_every(@max_waypoints_per_request, @max_waypoints_per_request - 1)
    |> Enum.reject(&(length(&1) < 2))
  end

  defp request_chunk(chunk, key) do
    waypoints_param =
      Enum.map_join(chunk, "|", fn {lat, lon} -> "#{lat},#{lon}" end)

    options = req_options(waypoints_param, key)

    try do
      case Req.get(@routing_url, options) do
        {:ok, %{status: 200, body: body}} -> parse_chunk(body, length(chunk) - 1)
        {:ok, %{status: status}} when status in [400, 404, 422] -> {:error, :no_route}
        {:ok, %{status: status}} when status in [401, 403] -> {:error, :unavailable}
        {:ok, %{status: 429}} -> {:error, :rate_limited}
        {:ok, %{status: _status}} -> {:error, :unavailable}
        {:error, _reason} -> {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    end
  end

  defp req_options(waypoints_param, key) do
    base = [
      params: [waypoints: waypoints_param, mode: "bus", apiKey: key],
      receive_timeout: 15_000,
      retry: :safe_transient,
      max_retries: 2
    ]

    case Application.get_env(:gtfs_planner, :street_routing_req_plug) do
      nil -> base
      plug -> Keyword.put(base, :plug, plug)
    end
  end

  # Legs arrive as GeoJSON `[longitude, latitude]` and stay in that order;
  # only the request parameter uses `latitude,longitude` order.
  defp parse_chunk(
         %{
           "features" => [
             %{"geometry" => %{"type" => "MultiLineString", "coordinates" => legs}} | _features
           ]
         },
         pair_count
       )
       when is_list(legs) and length(legs) == pair_count do
    if Enum.all?(legs, &valid_leg?/1) do
      {:ok, legs}
    else
      {:error, :invalid_response}
    end
  end

  defp parse_chunk(_body, _pair_count), do: {:error, :invalid_response}

  defp valid_leg?(leg) when is_list(leg) and leg != [] do
    Enum.all?(leg, fn
      [lon, lat] when is_number(lon) and is_number(lat) -> true
      _point -> false
    end)
  end

  defp valid_leg?(_leg), do: false
end
