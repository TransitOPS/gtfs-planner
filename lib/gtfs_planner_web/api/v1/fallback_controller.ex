defmodule GtfsPlannerWeb.Api.V1.FallbackController do
  use GtfsPlannerWeb, :controller

  def call(conn, _) do
    conn
    |> put_status(404)
    |> json(%{error: %{code: "not_found", message: "Route not found."}})
  end
end
