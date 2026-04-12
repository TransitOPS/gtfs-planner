defmodule GtfsPlannerWeb.Plugs.CORS do
  @moduledoc """
  Simple CORS plug for the companion app API.
  Allows requests from any origin in development.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> handle_preflight()
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
