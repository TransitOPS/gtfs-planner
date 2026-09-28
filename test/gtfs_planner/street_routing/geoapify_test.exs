defmodule GtfsPlanner.StreetRouting.GeoapifyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GtfsPlanner.StreetRouting.Geoapify

  @owner GtfsPlanner.StreetRouting.Geoapify
  @test_key "test-routing-key-9f8e7d6c5b4a"

  setup do
    original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
    Application.put_env(:gtfs_planner, :geoapify_api_key, @test_key)

    on_exit(fn ->
      if is_nil(original_key) do
        Application.delete_env(:gtfs_planner, :geoapify_api_key)
      else
        Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)
      end
    end)

    :ok
  end

  defp routing_response(legs) do
    %{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"mode" => "bus"},
          "geometry" => %{"type" => "MultiLineString", "coordinates" => legs}
        }
      ]
    }
  end

  defp stub_json(status, payload) do
    Req.Test.stub(@owner, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:routing_request, conn.method, conn.request_path, conn.query_params})
      Plug.Conn.send_resp(put_json_content_type(conn), status, Jason.encode!(payload))
    end)
  end

  defp put_json_content_type(conn) do
    Plug.Conn.put_resp_content_type(conn, "application/json")
  end

  describe "route/2 with stubbed Geoapify responses" do
    test "sends one GET with lat,lon waypoints, bus mode and the key, returning ordered [lon, lat] legs" do
      leg1 = [[-74.006, 40.7128], [-74.0055, 40.7133]]
      leg2 = [[-74.005, 40.7138], [-74.0045, 40.7143], [-74.004, 40.7148]]

      stub_json(200, routing_response([leg1, leg2]))

      waypoints = [{40.7128, -74.006}, {40.7138, -74.005}, {40.7148, -74.004}]

      assert {:ok, [^leg1, ^leg2]} = Geoapify.route(waypoints)

      assert_received {:routing_request, "GET", "/v1/routing", params}
      assert params["waypoints"] == "40.7128,-74.006|40.7138,-74.005|40.7148,-74.004"
      assert params["mode"] == "bus"
      assert params["apiKey"] == @test_key
      refute_received {:routing_request, _, _, _}
    end

    test "chunks 30 waypoints into two requests sharing the boundary waypoint" do
      Req.Test.stub(@owner, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        waypoints_param = conn.query_params["waypoints"]
        send(self(), {:routing_request, waypoints_param})

        parts = String.split(waypoints_param, "|")
        pair_count = length(parts) - 1
        # Waypoints are {40.0 + i, -74.0 - i}, so the first waypoint's
        # latitude recovers the global pair offset for this chunk.
        [first_lat, _lon] = String.split(hd(parts), ",")
        {first_lat, _} = Float.parse(first_lat)
        start_index = trunc(first_lat - 40.0)

        legs =
          Enum.map(1..pair_count, fn k ->
            i = (start_index + k) * 1.0
            [[i, 50.0], [i + 0.5, 50.5]]
          end)

        conn |> put_json_content_type() |> Req.Test.json(routing_response(legs))
      end)

      waypoints = Enum.map(0..29, fn i -> {40.0 + i, -74.0 - i} end)

      assert {:ok, legs} = Geoapify.route(waypoints)
      assert length(legs) == 29
      assert hd(legs) == [[1.0, 50.0], [1.5, 50.5]]
      assert List.last(legs) == [[29.0, 50.0], [29.5, 50.5]]

      assert_received {:routing_request, first}
      assert_received {:routing_request, second}
      refute_received {:routing_request, _}

      first_parts = String.split(first, "|")
      second_parts = String.split(second, "|")

      assert length(first_parts) == 25
      assert hd(first_parts) == "40.0,-74.0"
      assert length(second_parts) == 6
      assert List.last(first_parts) == hd(second_parts)
      assert hd(second_parts) == "64.0,-98.0"
    end

    test "a leg-count mismatch returns :invalid_response" do
      leg = [[-74.006, 40.7128], [-74.005, 40.7138]]
      stub_json(200, routing_response([leg]))

      waypoints = [{40.7128, -74.006}, {40.7138, -74.005}, {40.7148, -74.004}]

      assert {:error, :invalid_response} = Geoapify.route(waypoints)
    end

    test "fewer than two waypoints returns :invalid_response without a request" do
      Req.Test.stub(@owner, fn _conn -> raise "must not request with fewer than two waypoints" end)

      assert {:error, :invalid_response} = Geoapify.route([{40.7128, -74.006}])
      assert {:error, :invalid_response} = Geoapify.route([])
    end

    test "429 returns :rate_limited" do
      Req.Test.stub(@owner, fn conn ->
        send(self(), :routing_attempt)
        Plug.Conn.send_resp(conn, 429, "too many requests")
      end)

      assert {:error, :rate_limited} =
               Geoapify.route([{40.7128, -74.006}, {40.7138, -74.005}])

      assert_received :routing_attempt
      assert_received :routing_attempt
      assert_received :routing_attempt
      refute_received :routing_attempt
    end

    test "400 returns :no_route without retrying" do
      Req.Test.stub(@owner, fn conn ->
        send(self(), :routing_attempt)
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      assert {:error, :no_route} = Geoapify.route([{40.7128, -74.006}, {40.7138, -74.005}])

      assert_received :routing_attempt
      refute_received :routing_attempt
    end

    test "500 returns :unavailable after the two retries" do
      Req.Test.stub(@owner, fn conn ->
        send(self(), :routing_attempt)
        Plug.Conn.send_resp(conn, 500, "internal server error")
      end)

      assert {:error, :unavailable} =
               Geoapify.route([{40.7128, -74.006}, {40.7138, -74.005}])

      assert_received :routing_attempt
      assert_received :routing_attempt
      assert_received :routing_attempt
      refute_received :routing_attempt
    end

    test "a transport timeout returns :unavailable" do
      Req.Test.stub(@owner, fn conn ->
        send(self(), :routing_attempt)
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, :unavailable} =
               Geoapify.route([{40.7128, -74.006}, {40.7138, -74.005}])

      assert_received :routing_attempt
      assert_received :routing_attempt
      assert_received :routing_attempt
      refute_received :routing_attempt
    end

    test "a nil key returns :api_key_missing without a request" do
      Application.put_env(:gtfs_planner, :geoapify_api_key, nil)

      Req.Test.stub(@owner, fn _conn -> raise "must not request without a key" end)

      assert {:error, :api_key_missing} =
               Geoapify.route([{40.7128, -74.006}, {40.7138, -74.005}])
    end

    test "logs and error terms never expose the key or apiKey" do
      Req.Test.stub(@owner, fn conn ->
        Plug.Conn.send_resp(conn, 500, "internal server error")
      end)

      log =
        capture_log(fn ->
          assert {:error, :unavailable} =
                   Geoapify.route([{40.7128, -74.006}, {40.7138, -74.005}])
        end)

      refute log =~ @test_key
      refute log =~ "apiKey"
    end

    test "the dispatcher delegates to the configured service" do
      leg = [[-74.006, 40.7128], [-74.005, 40.7138]]
      stub_json(200, routing_response([leg]))

      assert {:ok, [^leg]} =
               GtfsPlanner.StreetRouting.route([{40.7128, -74.006}, {40.7138, -74.005}])
    end
  end
end
