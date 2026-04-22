defmodule GtfsPlannerWeb.MapTilesController do
  @moduledoc """
  Server-side proxy for Geoapify raster map tiles.

  Keeps the Geoapify API key off the client by forwarding
  `{style, z, x, y}` to the Geoapify tile endpoint and streaming the
  binary PNG response back with a 24h cache-control header.
  """

  use GtfsPlannerWeb, :controller

  @styles ~w(osm-bright osm-carto maptiler-3d satellite)

  def show(conn, %{"style" => style, "z" => z, "x" => x, "y" => y}) do
    with :ok <- validate_style(style),
         {:ok, z_int} <- parse_coord(z),
         {:ok, x_int} <- parse_coord(x),
         {:ok, y_int} <- parse_coord(y),
         {:ok, key} <- fetch_api_key() do
      fetch_tile(conn, style, z_int, x_int, y_int, key)
    else
      {:error, :unknown_style} ->
        send_resp(conn, 400, "unknown tile style")

      {:error, :non_integer_coord} ->
        send_resp(conn, 400, "non-integer tile coordinate")

      {:error, :missing_api_key} ->
        send_resp(conn, 500, "geoapify_api_key is not configured")
    end
  end

  defp validate_style(style) when style in @styles, do: :ok
  defp validate_style(_), do: {:error, :unknown_style}

  defp parse_coord(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :non_integer_coord}
    end
  end

  defp fetch_api_key do
    case Application.get_env(:gtfs_planner, :geoapify_api_key) do
      nil -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  defp fetch_tile(conn, style, z, x, y, key) do
    url = "https://maps.geoapify.com/v1/tile/#{style}/#{z}/#{x}/#{y}.png?apiKey=#{key}"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        conn
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, body)

      {:ok, %{status: status}} ->
        send_resp(conn, 502, "upstream #{status}")

      {:error, _reason} ->
        send_resp(conn, 502, "upstream network error")
    end
  end
end
