defmodule GtfsPlannerWeb.MapBuildingsController do
  @moduledoc """
  Fetches OSM building footprints around a point via the Overpass API and
  returns them as GeoJSON. Used by the Map alignment tool to overlay
  precise building outlines on satellite imagery.
  """

  use GtfsPlannerWeb, :controller

  @overpass_url "https://overpass-api.de/api/interpreter"
  @max_radius 2000
  @default_radius 500

  def index(conn, params) do
    with {:ok, lat} <- parse_float(params["lat"]),
         {:ok, lon} <- parse_float(params["lon"]),
         {:ok, radius} <- parse_radius(params["radius"]) do
      fetch_buildings(conn, lat, lon, radius)
    else
      {:error, :invalid_coord} -> send_resp(conn, 400, "invalid lat or lon")
      {:error, :invalid_radius} -> send_resp(conn, 400, "invalid radius")
    end
  end

  defp parse_float(nil), do: {:error, :invalid_coord}

  defp parse_float(value) do
    case Float.parse(value) do
      {f, ""} -> {:ok, f}
      _ -> {:error, :invalid_coord}
    end
  end

  defp parse_radius(nil), do: {:ok, @default_radius}

  defp parse_radius(value) do
    case Integer.parse(value) do
      {r, ""} when r > 0 and r <= @max_radius -> {:ok, r}
      _ -> {:error, :invalid_radius}
    end
  end

  defp fetch_buildings(conn, lat, lon, radius) do
    query =
      "[out:json][timeout:25];way[\"building\"](around:#{radius},#{lat},#{lon});out geom;"

    case Req.post(@overpass_url, [form: [data: query]] ++ req_options()) do
      {:ok, %{status: 200, body: body}} ->
        conn
        |> put_resp_content_type("application/geo+json")
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, Jason.encode!(to_geojson(body)))

      {:ok, %{status: status}} ->
        send_resp(conn, 502, "upstream #{status}")

      {:error, _reason} ->
        send_resp(conn, 502, "upstream network error")
    end
  end

  defp to_geojson(%{"elements" => elements}) do
    features =
      elements
      |> Enum.filter(&polygon?/1)
      |> Enum.map(&element_to_feature/1)

    %{"type" => "FeatureCollection", "features" => features}
  end

  defp to_geojson(_), do: %{"type" => "FeatureCollection", "features" => []}

  defp polygon?(%{"type" => "way", "geometry" => [_ | _] = geom}) when length(geom) >= 3,
    do: true

  defp polygon?(_), do: false

  defp element_to_feature(%{"geometry" => geom} = el) do
    coords =
      Enum.map(geom, fn %{"lat" => lat, "lon" => lon} -> [lon, lat] end)
      |> close_ring()

    %{
      "type" => "Feature",
      "geometry" => %{"type" => "Polygon", "coordinates" => [coords]},
      "properties" => Map.get(el, "tags", %{})
    }
  end

  defp close_ring([first | _] = coords) do
    if List.last(coords) == first, do: coords, else: coords ++ [first]
  end

  defp req_options do
    base = [
      receive_timeout: 30_000,
      retry: :safe_transient,
      max_retries: 2,
      retry_delay: fn _n -> 200 end
    ]

    case Application.get_env(:gtfs_planner, :map_buildings_req_plug) do
      nil -> base
      plug -> [{:plug, plug} | base]
    end
  end
end
