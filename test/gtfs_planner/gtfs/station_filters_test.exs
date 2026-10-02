defmodule GtfsPlanner.Gtfs.StationFiltersTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs

  setup do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    first = stop_fixture(org.id, version.id, %{stop_id: "S1"})
    second = stop_fixture(org.id, version.id, %{stop_id: "S2"})
    route_fixture(org.id, version.id, %{route_id: "R"})
    trip_fixture(org.id, version.id, "R", %{trip_id: "REP", direction_id: 0})
    trip_fixture(org.id, version.id, "R", %{trip_id: "OTHER", direction_id: 1})
    stop_time_fixture(org.id, version.id, "REP", "S1")
    stop_time_fixture(org.id, version.id, "OTHER", "S2")

    %{org: org, version: version, first: first, second: second}
  end

  test "falls back to all route trips until a representative exists", ctx do
    assert_stations(ctx, [ctx.first.id, ctx.second.id], route_id: "R")
    representative(ctx.org.id, ctx.version.id, "REP")
    assert_stations(ctx, [ctx.first.id], route_id: "R")
  end

  test "a representative with no stop times does not fall back", ctx do
    trip_fixture(ctx.org.id, ctx.version.id, "R", %{trip_id: "EMPTY"})
    representative(ctx.org.id, ctx.version.id, "EMPTY")
    assert_stations(ctx, [], route_id: "R")
  end

  test "route and direction intersect their stop sets across routes", ctx do
    representative(ctx.org.id, ctx.version.id, "REP")
    assert_stations(ctx, [], route_id: "R", direction_id: 1)

    route_fixture(ctx.org.id, ctx.version.id, %{route_id: "OTHER_ROUTE"})

    trip_fixture(ctx.org.id, ctx.version.id, "OTHER_ROUTE", %{trip_id: "INBOUND", direction_id: 1})

    stop_time_fixture(ctx.org.id, ctx.version.id, "INBOUND", "S1")
    assert_stations(ctx, [ctx.first.id], route_id: "R", direction_id: 1)
  end

  test "same natural ids in another organization or version cannot affect filters", ctx do
    other_org = organization_fixture()
    other_version = gtfs_version_fixture(other_org.id)
    same_org_version = gtfs_version_fixture(ctx.org.id)

    for {org_id, version_id} <- [
          {other_org.id, other_version.id},
          {ctx.org.id, same_org_version.id}
        ] do
      stop_fixture(org_id, version_id, %{stop_id: "S2"})
      route_fixture(org_id, version_id, %{route_id: "R"})
      trip_fixture(org_id, version_id, "R", %{trip_id: "REP", direction_id: 1})
      stop_time_fixture(org_id, version_id, "REP", "S2")
      representative(org_id, version_id, "REP")
    end

    assert_stations(ctx, [ctx.first.id, ctx.second.id], route_id: "R")
    representative(ctx.org.id, ctx.version.id, "REP")
    assert_stations(ctx, [ctx.first.id], route_id: "R")
    assert_stations(ctx, [], route_id: "R", direction_id: 1)
  end

  test "list and count each execute one query with both filters", ctx do
    representative(ctx.org.id, ctx.version.id, "REP")
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:gtfs_planner, :repo, :query],
      fn _, _, _, _ ->
        if self() == owner, do: send(owner, :station_query)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert [%{id: id}] =
             Gtfs.list_stations(ctx.org.id, ctx.version.id, route_id: "R", direction_id: 0)

    assert id == ctx.first.id
    assert_received :station_query
    refute_received :station_query

    assert Gtfs.count_stations(ctx.org.id, ctx.version.id, route_id: "R", direction_id: 0) == 1
    assert_received :station_query
    refute_received :station_query
  end

  test "route choices use all trips, exclude children, and stay scoped", ctx do
    trip_fixture(ctx.org.id, ctx.version.id, "R", %{trip_id: "EMPTY"})
    representative(ctx.org.id, ctx.version.id, "EMPTY")
    route_fixture(ctx.org.id, ctx.version.id, %{route_id: "CHILD"})
    child_stop_fixture(ctx.org.id, ctx.version.id, "S1", %{stop_id: "CHILD"})
    trip_fixture(ctx.org.id, ctx.version.id, "CHILD", %{trip_id: "CHILD"})
    stop_time_fixture(ctx.org.id, ctx.version.id, "CHILD", "CHILD")
    route_fixture(ctx.org.id, ctx.version.id, %{route_id: "UNSERVED"})

    other_version = gtfs_version_fixture(ctx.org.id)
    stop_fixture(ctx.org.id, other_version.id, %{stop_id: "S1"})
    route_fixture(ctx.org.id, other_version.id, %{route_id: "UNSERVED"})
    trip_fixture(ctx.org.id, other_version.id, "UNSERVED", %{trip_id: "REP"})
    stop_time_fixture(ctx.org.id, other_version.id, "REP", "S1")

    assert [%{route_id: "R"}] = Gtfs.list_routes_serving_stations(ctx.org.id, ctx.version.id)
  end

  defp representative(org, version, trip_id) do
    route_pattern_fixture(org, version, %{route_id: "R", representative_trip_id: trip_id})
  end

  defp assert_stations(ctx, expected, opts) do
    assert Gtfs.list_stations(ctx.org.id, ctx.version.id, opts)
           |> Enum.map(& &1.id)
           |> Enum.sort() ==
             Enum.sort(expected)

    assert Gtfs.count_stations(ctx.org.id, ctx.version.id, opts) == length(expected)
  end
end
