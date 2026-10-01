defmodule GtfsPlannerWeb.Plugs.CORSTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias GtfsPlannerWeb.Plugs.CORS

  setup do
    previous = Application.fetch_env(:gtfs_planner, :api_cors_allow_localhost)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :api_cors_allow_localhost, value)
        :error -> Application.delete_env(:gtfs_planner, :api_cors_allow_localhost)
      end
    end)

    :ok
  end

  test "allows HTTP and HTTPS localhost and loopback origins when enabled" do
    assert Application.get_env(:gtfs_planner, :api_cors_allow_localhost) == true

    for origin <- [
          "http://localhost:5173",
          "https://localhost:5173",
          "http://127.0.0.1:5173",
          "https://127.0.0.1:5173"
        ] do
      conn = cors_conn(origin)

      assert get_resp_header(conn, "access-control-allow-origin") == [origin]
    end
  end

  test "omits localhost origins when disabled and keeps the companion origin allowed" do
    Application.put_env(:gtfs_planner, :api_cors_allow_localhost, false)

    local_origins = [
      "http://localhost:5173",
      "https://localhost:5173",
      "http://127.0.0.1:5173",
      "https://127.0.0.1:5173"
    ]

    companion_conn = cors_conn("https://field-companion.pathways.jarv.us")

    for origin <- local_origins do
      conn = cors_conn(origin)

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    assert get_resp_header(companion_conn, "access-control-allow-origin") == [
             "https://field-companion.pathways.jarv.us"
           ]
  end

  defp cors_conn(origin) do
    conn(:get, "/api/v1/versions")
    |> put_req_header("origin", origin)
    |> CORS.call([])
  end
end
