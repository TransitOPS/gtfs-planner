defmodule GtfsPlannerWeb.MapBuildingsControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures

  @overpass_response %{
    "elements" => [
      %{
        "type" => "way",
        "id" => 1,
        "tags" => %{"building" => "yes"},
        "geometry" => [
          %{"lat" => 40.0, "lon" => -74.0},
          %{"lat" => 40.0, "lon" => -73.9},
          %{"lat" => 40.1, "lon" => -73.9},
          %{"lat" => 40.1, "lon" => -74.0}
        ]
      }
    ]
  }

  setup %{conn: conn} do
    user = user_fixture()
    authed_conn = log_in_user(conn, user)
    {:ok, conn: authed_conn, unauth_conn: conn}
  end

  describe "GET /map/buildings" do
    test "returns GeoJSON FeatureCollection on upstream 200", %{conn: conn} do
      Req.Test.stub(GtfsPlannerWeb.MapBuildingsController, fn plug_conn ->
        Req.Test.json(plug_conn, @overpass_response)
      end)

      conn = get(conn, "/map/buildings?lat=40.05&lon=-73.95&radius=500")

      assert conn.status == 200
      assert {"content-type", ct} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert ct =~ "application/geo+json"

      body = Jason.decode!(conn.resp_body)
      assert body["type"] == "FeatureCollection"
      assert [feature] = body["features"]
      assert feature["geometry"]["type"] == "Polygon"
      assert feature["properties"] == %{"building" => "yes"}
      # Polygon ring is closed.
      [ring] = feature["geometry"]["coordinates"]
      assert List.first(ring) == List.last(ring)
    end

    test "returns 400 on missing lat", %{conn: conn} do
      conn = get(conn, "/map/buildings?lon=-73.95")
      assert conn.status == 400
    end

    test "returns 400 on non-numeric lon", %{conn: conn} do
      conn = get(conn, "/map/buildings?lat=40.0&lon=abc")
      assert conn.status == 400
    end

    test "returns 400 on radius over the cap", %{conn: conn} do
      conn = get(conn, "/map/buildings?lat=40.0&lon=-74.0&radius=5000")
      assert conn.status == 400
    end

    test "returns 502 on upstream non-200", %{conn: conn} do
      Req.Test.stub(GtfsPlannerWeb.MapBuildingsController, fn plug_conn ->
        Plug.Conn.resp(plug_conn, 503, "service unavailable")
      end)

      conn = get(conn, "/map/buildings?lat=40.0&lon=-74.0")

      assert conn.status == 502
      assert conn.resp_body =~ "upstream 503"
    end

    test "unauthenticated requests follow the :require_authenticated_user pipeline", %{
      unauth_conn: unauth_conn
    } do
      conn = get(unauth_conn, "/map/buildings?lat=40.0&lon=-74.0")
      assert redirected_to(conn) == "/users/log_in"
    end
  end
end
