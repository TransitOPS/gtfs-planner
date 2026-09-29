defmodule GtfsPlanner.Gtfs.RoutesByStationTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @query_event [:gtfs_planner, :repo, :query]

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{organization: organization, gtfs_version: gtfs_version}
  end

  test "returns each route serving a station through its child platforms", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    level = level_fixture(organization.id, gtfs_version.id)

    station = station_fixture(organization, gtfs_version, "STA")
    first_platform = platform_fixture(organization, gtfs_version, "P1", station.stop_id, level, 0)

    second_platform =
      platform_fixture(organization, gtfs_version, "P2", station.stop_id, level, 0)

    route_five =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R5", route_short_name: "5"})

    route_seven =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R7", route_short_name: "7"})

    serve_platform(organization, gtfs_version, route_five, "T5", first_platform.stop_id)
    # A second trip on the same route must not duplicate the route in the station's list.
    serve_platform(organization, gtfs_version, route_five, "T5B", first_platform.stop_id)
    serve_platform(organization, gtfs_version, route_seven, "T7", second_platform.stop_id)

    assert Gtfs.routes_by_station(organization.id, gtfs_version.id, ["STA"]) == %{
             "STA" => [
               %{route_id: "R5", route_short_name: "5"},
               %{route_id: "R7", route_short_name: "7"}
             ]
           }
  end

  test "omits a station whose child platforms have no stop times", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    level = level_fixture(organization.id, gtfs_version.id)

    station = station_fixture(organization, gtfs_version, "STA")
    _platform = platform_fixture(organization, gtfs_version, "P1", station.stop_id, level, 0)

    assert Gtfs.routes_by_station(organization.id, gtfs_version.id, ["STA"]) == %{}
  end

  test "ignores look-alike stations in another version and another organization", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    level = level_fixture(organization.id, gtfs_version.id)

    station = station_fixture(organization, gtfs_version, "STA")
    platform = platform_fixture(organization, gtfs_version, "P1", station.stop_id, level, 0)

    route =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R5", route_short_name: "5"})

    serve_platform(organization, gtfs_version, route, "T5", platform.stop_id)

    sibling_version = gtfs_version_fixture(organization.id)
    sibling_level = level_fixture(organization.id, sibling_version.id)
    sibling_station = station_fixture(organization, sibling_version, "STA")

    sibling_platform =
      platform_fixture(
        organization,
        sibling_version,
        "P1",
        sibling_station.stop_id,
        sibling_level,
        0
      )

    sibling_route =
      route_fixture(organization.id, sibling_version.id, %{route_id: "R9", route_short_name: "9"})

    serve_platform(organization, sibling_version, sibling_route, "T9", sibling_platform.stop_id)

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)
    other_level = level_fixture(other_organization.id, other_version.id)
    other_station = station_fixture(other_organization, other_version, "STA")

    other_platform =
      platform_fixture(
        other_organization,
        other_version,
        "P1",
        other_station.stop_id,
        other_level,
        0
      )

    other_route =
      route_fixture(other_organization.id, other_version.id, %{
        route_id: "R8",
        route_short_name: "8"
      })

    serve_platform(other_organization, other_version, other_route, "T8", other_platform.stop_id)

    assert Gtfs.routes_by_station(organization.id, gtfs_version.id, ["STA"]) == %{
             "STA" => [%{route_id: "R5", route_short_name: "5"}]
           }
  end

  test "counts only child platforms, not the station row or other child types", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    level = level_fixture(organization.id, gtfs_version.id)

    station = station_fixture(organization, gtfs_version, "STA")
    platform = platform_fixture(organization, gtfs_version, "P1", station.stop_id, level, 0)

    undesignated_platform =
      platform_fixture(organization, gtfs_version, "P2", station.stop_id, level, nil)

    node = platform_fixture(organization, gtfs_version, "N1", station.stop_id, level, 3)

    route_five =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R5", route_short_name: "5"})

    route_seven =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R7", route_short_name: "7"})

    route_eight =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R8", route_short_name: "8"})

    route_nine =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R9", route_short_name: "9"})

    serve_platform(organization, gtfs_version, route_five, "T5", platform.stop_id)
    serve_platform(organization, gtfs_version, route_seven, "T7", undesignated_platform.stop_id)
    serve_platform(organization, gtfs_version, route_eight, "T8", station.stop_id)
    serve_platform(organization, gtfs_version, route_nine, "T9", node.stop_id)

    assert Gtfs.routes_by_station(organization.id, gtfs_version.id, ["STA"]) == %{
             "STA" => [
               %{route_id: "R5", route_short_name: "5"},
               %{route_id: "R7", route_short_name: "7"}
             ]
           }
  end

  test "returns %{} without querying when no stations are requested", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    result =
      refute_queries(organization, fn ->
        Gtfs.routes_by_station(organization.id, gtfs_version.id, [])
      end)

    assert result == %{}
  end

  defp station_fixture(organization, gtfs_version, stop_id) do
    stop_fixture(organization.id, gtfs_version.id, %{
      stop_id: stop_id,
      stop_name: "Station #{stop_id}",
      location_type: 1
    })
  end

  defp platform_fixture(organization, gtfs_version, stop_id, parent_station, level, location_type) do
    stop_fixture(organization.id, gtfs_version.id, %{
      stop_id: stop_id,
      stop_name: "Child stop #{stop_id}",
      location_type: location_type,
      parent_station: parent_station,
      level_id: level.level_id
    })
  end

  defp serve_platform(organization, gtfs_version, route, trip_id, stop_id) do
    trip = trip_fixture(organization.id, gtfs_version.id, route.route_id, %{trip_id: trip_id})

    stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop_id)
  end

  # Ecto emits @query_event from the process issuing the query. Only events whose
  # params carry this test's organization id are reported, so tests running in
  # parallel cannot add messages to the mailbox checked below.
  defp refute_queries(organization, fun) do
    ref = make_ref()
    handler_id = "routes-by-station-#{System.unique_integer([:positive])}"
    test_pid = self()
    organization_dump = Ecto.UUID.dump!(organization.id)

    :telemetry.attach(
      handler_id,
      @query_event,
      fn _event, _measurements, metadata, _config ->
        if is_list(metadata.params) and
             Enum.any?(metadata.params, &(&1 == organization.id or &1 == organization_dump)) do
          send(test_pid, {:repo_query, ref})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    refute_received {:repo_query, ^ref}

    result
  end
end
