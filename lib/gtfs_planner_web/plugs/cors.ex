defmodule GtfsPlannerWeb.Plugs.CORS do
  @moduledoc """
  CORS plug for the companion app API.
  Allows requests from the deployed web app and localhost for development.
  """

  import Plug.Conn

  @allowed_origins [
    "https://field-companion.pathways.jarv.us"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first()

    conn = put_resp_header(conn, "vary", "origin")

    if allowed_origin?(origin) do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, x-organization-id"
      )
      |> put_resp_header("access-control-max-age", "86400")
      |> handle_preflight()
    else
      handle_preflight(conn)
    end
  end

  defp allowed_origin?(nil), do: false

  defp allowed_origin?(origin) do
    origin in @allowed_origins or localhost_origin?(origin)
  end

  defp localhost_origin?(origin) do
    uri = URI.parse(origin)
    uri.host in ["localhost", "127.0.0.1"] and uri.scheme in ["http", "https"]
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
