defmodule GtfsPlannerWeb.MapTilesControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

  setup %{conn: conn} do
    # Ensure a known API key for tests that exercise the upstream fetch path.
    original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
    Application.put_env(:gtfs_planner, :geoapify_api_key, "test-key")

    on_exit(fn ->
      if is_nil(original_key) do
        Application.delete_env(:gtfs_planner, :geoapify_api_key)
      else
        Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)
      end
    end)

    user = user_fixture()
    authed_conn = log_in_user(conn, user)

    {:ok, conn: authed_conn, unauth_conn: conn}
  end

  describe "GET /map/tiles/:style/:z/:x/:y" do
    test "returns 200 image/png with cache headers on upstream 200", %{conn: conn} do
      Req.Test.stub(GtfsPlannerWeb.MapTilesController, fn plug_conn ->
        plug_conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.resp(200, @png_bytes)
      end)

      conn = get(conn, "/map/tiles/osm-bright/10/300/400")

      assert conn.status == 200
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "image/png"

      assert {"cache-control", "public, max-age=86400"} =
               List.keyfind(conn.resp_headers, "cache-control", 0)

      assert conn.resp_body == @png_bytes
    end

    test "returns 400 on non-integer z", %{conn: conn} do
      conn = get(conn, "/map/tiles/osm-bright/abc/300/400")

      assert conn.status == 400
    end

    test "returns 400 on unknown style", %{conn: conn} do
      conn = get(conn, "/map/tiles/not-a-style/10/300/400")

      assert conn.status == 400
    end

    test "returns 500 when geoapify_api_key is nil", %{conn: conn} do
      original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
      Application.put_env(:gtfs_planner, :geoapify_api_key, nil)

      on_exit(fn ->
        Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)
      end)

      # Any upstream invocation would raise — asserts no network call is made.
      Req.Test.stub(GtfsPlannerWeb.MapTilesController, fn _plug_conn ->
        raise "upstream must not be called when geoapify_api_key is nil"
      end)

      conn = get(conn, "/map/tiles/osm-bright/10/300/400")

      assert conn.status == 500
    end

    test "returns 502 on upstream non-200", %{conn: conn} do
      Req.Test.stub(GtfsPlannerWeb.MapTilesController, fn plug_conn ->
        Plug.Conn.resp(plug_conn, 503, "service unavailable")
      end)

      conn = get(conn, "/map/tiles/osm-bright/10/300/400")

      assert conn.status == 502
      assert conn.resp_body =~ "upstream 503"
    end

    test "unauthenticated requests follow the :require_authenticated_user pipeline", %{
      unauth_conn: unauth_conn
    } do
      conn = get(unauth_conn, "/map/tiles/osm-bright/10/300/400")

      assert redirected_to(conn) == "/users/log_in"
    end
  end
end
