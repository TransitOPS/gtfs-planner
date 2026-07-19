defmodule GtfsPlannerWeb.StationResolutionPrototypeRetirementTest do
  use GtfsPlannerWeb.ConnCase

  import GtfsPlanner.AccountsFixtures

  describe "former prototype paths return 404" do
    test "authenticated GET /station-data-resolution-prototype returns 404", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get("/station-data-resolution-prototype")

      assert conn.status == 404
    end

    test "authenticated GET of former stylesheet path returns 404", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get("/station-data-resolution-prototype/station-resolution-v2.css")

      assert conn.status == 404
    end

    test "unauthenticated GET /station-data-resolution-prototype returns 404", %{conn: conn} do
      conn = get(conn, "/station-data-resolution-prototype")

      assert conn.status == 404
    end

    test "raw /prototypes/ path is not statically published", %{conn: conn} do
      conn = get(conn, "/prototypes/station-resolution-v2.html")

      assert conn.status == 404
    end
  end
end
