defmodule GtfsPlanner.Geocoding.GeoapifyTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Geocoding.Geoapify
  alias GtfsPlanner.Geocoding.Result

  @owner Geoapify
  @test_key "test-geoapify-key"
  @endpoint "/v1/geocode/autocomplete"

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_key = Application.get_env(:gtfs_planner, :geoapify_api_key)

    Application.put_env(:gtfs_planner, :geoapify_api_key, @test_key)

    on_exit(fn -> restore_env(:geoapify_api_key, previous_key) end)

    :ok
  end

  test "the public geocoding entrypoint reaches Geoapify through the test plug" do
    Req.Test.expect(@owner, 1, fn conn ->
      assert conn.request_path == @endpoint

      Req.Test.json(conn, %{
        "results" => [%{"formatted" => "1 Main St", "lat" => 40.1, "lon" => -73.9}]
      })
    end)

    with_geocoding_service(Geoapify, fn ->
      assert {:ok, [%Result{formatted_address: "1 Main St", lat: 40.1, lon: -73.9}]} =
               Geocoding.autocomplete("1 Main St")
    end)

    assert Application.get_env(:gtfs_planner, :geocoding_req_options)[:plug] ==
             {Req.Test, Geoapify}
  end

  test "a 503 response is retried once and retains the API error" do
    Req.Test.expect(@owner, 2, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    assert {:error, {:api_error, 503}} = Geoapify.autocomplete("Main Street", [])
  end

  test "a transport timeout maps to the existing network error" do
    Req.Test.expect(@owner, 2, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, :network_error} = Geoapify.autocomplete("Main Street", [])
  end

  test "the Req transport receives a 5-second timeout" do
    test_process = self()

    finch_request = fn request, _finch_request, _finch_name, _finch_options ->
      send(test_process, {:request_options, request.options})

      response =
        Req.Response.new(
          status: 200,
          headers: [{"content-type", "application/json"}],
          body: Jason.encode!(%{"results" => []})
        )

      {request, response}
    end

    with_req_options([retry_delay: 0, finch_request: finch_request], fn ->
      assert {:ok, []} = Geoapify.autocomplete("Main Street", [])
    end)

    assert_received {:request_options, %{receive_timeout: 5_000}}
  end

  defp with_geocoding_service(service, fun) do
    previous_service = Application.get_env(:gtfs_planner, :geocoding_service)
    Application.put_env(:gtfs_planner, :geocoding_service, service)

    try do
      fun.()
    after
      restore_env(:geocoding_service, previous_service)
    end
  end

  defp with_req_options(options, fun) do
    previous_options = Application.get_env(:gtfs_planner, :geocoding_req_options)
    Application.put_env(:gtfs_planner, :geocoding_req_options, options)

    try do
      fun.()
    after
      restore_env(:geocoding_req_options, previous_options)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
