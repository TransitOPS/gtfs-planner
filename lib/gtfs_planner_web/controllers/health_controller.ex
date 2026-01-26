defmodule GtfsPlannerWeb.HealthController do
  use GtfsPlannerWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
