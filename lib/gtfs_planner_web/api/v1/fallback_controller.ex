defmodule GtfsPlannerWeb.Api.V1.FallbackController do
  use GtfsPlannerWeb, :controller

  # OPTIONS preflight is handled by the CORS plug before reaching this action,
  # but Phoenix needs a controller action to match the route.
  def preflight(conn, _params) do
    send_resp(conn, 204, "")
  end
end
