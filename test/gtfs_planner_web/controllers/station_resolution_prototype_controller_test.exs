defmodule GtfsPlannerWeb.StationResolutionPrototypeControllerTest do
  use GtfsPlannerWeb.ConnCase

  import GtfsPlanner.AccountsFixtures

  @endpoint_path "/station-data-resolution-prototype"

  describe "GET /station-data-resolution-prototype" do
    test "returns 200 with HTML content type for authenticated user", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(@endpoint_path)

      assert conn.status == 200
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "text/html"
    end

    test "response body exactly matches the file in priv/prototypes", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(@endpoint_path)

      expected =
        File.read!(
          Application.app_dir(:gtfs_planner, "priv/prototypes/station-resolution-v2.html")
        )

      assert conn.resp_body == expected
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      conn = get(conn, @endpoint_path)

      assert redirected_to(conn) == "/users/log_in"
    end

    test "prototype is not served as a direct static asset", %{conn: conn} do
      conn = get(conn, "/prototypes/station-resolution-v2.html")

      assert conn.status == 404
    end
  end
end
