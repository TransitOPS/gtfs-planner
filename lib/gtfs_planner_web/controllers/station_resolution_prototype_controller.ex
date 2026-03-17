defmodule GtfsPlannerWeb.StationResolutionPrototypeController do
  use GtfsPlannerWeb, :controller

  def index(conn, _params) do
    path = Application.app_dir(:gtfs_planner, "priv/prototypes/station-resolution-v2.html")

    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end
end
