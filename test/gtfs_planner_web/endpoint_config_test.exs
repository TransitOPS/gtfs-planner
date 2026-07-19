defmodule GtfsPlannerWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  test "test endpoint accepts the Playwright loopback origin" do
    endpoint_config = Application.fetch_env!(:gtfs_planner, GtfsPlannerWeb.Endpoint)

    assert endpoint_config[:check_origin] == false
  end
end
