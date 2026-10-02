defmodule GtfsPlanner.Geocoding.GeoapifyAutocompleteBiasTest do
  @moduledoc """
  Placing several stops on a map means typing a partial street name while the
  other stops already placed say where the editor is. "9th" alone ranks by
  population, not by relevance to this feed, so `autocomplete/2` accepts a
  `:bias` point and sends it to the API.

  Two properties matter. With a bias the parameter is present and in Geoapify's
  `proximity:<lon>,<lat>` form, longitude first — sending latitude first
  silently biases toward the wrong hemisphere, and the request still succeeds.
  Without a bias nothing is added, because the garages picker calls this with
  no point and its ranking must not change.
  """

  use ExUnit.Case, async: false

  alias GtfsPlanner.Geocoding.Geoapify

  @owner GtfsPlanner.Geocoding.Geoapify
  @test_key "test-geocoding-key-3c2b1a0f9e8d"

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

  defp results do
    %{"results" => [%{"formatted" => "9th Street", "lat" => 44.63, "lon" => -124.05}]}
  end

  test "a bias is sent as proximity with longitude first, and the country filter is kept" do
    Req.Test.expect(@owner, fn conn ->
      params = conn.query_params

      assert params["bias"] == "proximity:-124.05,44.63"
      assert params["filter"] == "countrycode:us"
      assert params["text"] == "9th"

      Req.Test.json(conn, results())
    end)

    assert {:ok, [_result]} = Geoapify.autocomplete("9th", bias: {-124.05, 44.63})
  end

  test "without a bias no bias param is sent" do
    Req.Test.expect(@owner, fn conn ->
      refute Map.has_key?(conn.query_params, "bias")
      assert conn.query_params["filter"] == "countrycode:us"

      Req.Test.json(conn, results())
    end)

    assert {:ok, [_result]} = Geoapify.autocomplete("9th", [])
  end

  test "a malformed bias is ignored rather than sent half-formed" do
    # The pair is positional, so a caller that swaps it biases toward the wrong
    # side of the planet. Silently dropping a pair that is not two numbers is
    # better than sending `proximity:notanumber` and getting a 400 back.
    Req.Test.expect(@owner, fn conn ->
      refute Map.has_key?(conn.query_params, "bias")

      Req.Test.json(conn, results())
    end)

    assert {:ok, [_result]} = Geoapify.autocomplete("9th", bias: {-124.05})
  end

  test "a short query is still refused before any request" do
    assert Geoapify.autocomplete("9t", bias: {-124.05, 44.63}) == {:error, :text_too_short}
  end
end
