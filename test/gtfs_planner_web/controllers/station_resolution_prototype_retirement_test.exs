defmodule GtfsPlannerWeb.StationResolutionPrototypeRetirementTest do
  use GtfsPlannerWeb.ConnCase

  import GtfsPlanner.AccountsFixtures

  describe "former prototype paths return 404" do
    test "authenticated GET /station-data-resolution-prototype returns 404 with the aligned error surface",
         %{
           conn: conn
         } do
      user = user_fixture()

      conn = conn |> log_in_user(user) |> get("/station-data-resolution-prototype")

      assert conn.status == 404
      assert aligned_404_wrapper?(conn)
    end

    test "authenticated GET of former stylesheet path returns 404 with the aligned error surface",
         %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get("/station-data-resolution-prototype/station-resolution-v2.css")

      assert conn.status == 404
      assert aligned_404_wrapper?(conn)
    end

    test "unauthenticated GET /station-data-resolution-prototype returns 404 with the aligned error surface",
         %{conn: conn} do
      conn = get(conn, "/station-data-resolution-prototype")

      assert conn.status == 404
      assert aligned_404_wrapper?(conn)
    end

    test "raw /prototypes/ path is not statically published", %{conn: conn} do
      conn = get(conn, "/prototypes/station-resolution-v2.html")

      assert conn.status == 404
    end
  end

  # Confirms the representative retired HTML paths now receive the new branded
  # 404 surface (#error-page-404) instead of the bare "Not Found" phrase,
  # without reopening the prototype fixture content contract. The raw
  # /prototypes/ asset test stays on the bare status check because its
  # concern is non-publication, not error-page composition.
  defp aligned_404_wrapper?(conn) do
    conn
    |> response(404)
    |> LazyHTML.from_document()
    |> LazyHTML.query("#error-page-404")
    |> Enum.any?()
  end
end
