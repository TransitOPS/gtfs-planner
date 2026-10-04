defmodule GtfsPlanner.Gtfs.StopEditingMoveImpactTest do
  @moduledoc """
  Merge evidence (EV-9) for `StopEditing.move_impact/3`.

  The impact read answers what a move would affect from the stop's references
  alone, so what is under test is that it is complete (every reference class), uses
  the native bands, and is a pure read: no street-routing request, no write and no
  lock. Expected values are written by hand from the fixture below, and
  `move_review/3` on the same stop is the contrast that proves the routing stub
  would have been reached.

  Fixture: stop `1434` ("Main St") at 44.6210, -124.0530 on pattern `P` of route
  `1` with one weekday trip, a transfer to `2000` about 79 m east, a transfer from
  `3000` about 111 m north, and a relief point. `1330` is the previous stop.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip

  @routing_owner GtfsPlanner.StreetRouting.Geoapify
  @stop_lat 44.6210
  @stop_lon -124.0530
  # One degree of latitude, in metres, on the sphere `StopPlacement.distance/2` measures.
  @metres_per_degree 111_195.0

  setup do
    Req.Test.set_req_test_to_shared(%{})
    original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
    Application.put_env(:gtfs_planner, :geoapify_api_key, "test-move-impact-key-91c2")

    on_exit(fn ->
      if is_nil(original_key),
        do: Application.delete_env(:gtfs_planner, :geoapify_api_key),
        else: Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)

      Req.Test.set_req_test_to_private(%{})
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    stops =
      Map.new(
        [
          {"1330", 44.6200, @stop_lon},
          {"1434", @stop_lat, @stop_lon},
          {"2000", @stop_lat, @stop_lon + 0.0010},
          {"3000", @stop_lat + 0.0010, @stop_lon}
        ],
        fn {id, lat, lon} ->
          {id,
           stop_fixture(organization.id, version.id, %{
             stop_id: id,
             stop_name: "Stop #{id}",
             stop_lat: Decimal.from_float(lat),
             stop_lon: Decimal.from_float(lon)
           })}
        end
      )

    route =
      route_fixture(organization.id, version.id, %{route_id: "1", route_short_name: "1"})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: "P",
        route_id: route.route_id,
        headsign: "To P"
      })

    for {stop_id, position} <- Enum.with_index(["1330", "1434"], 1),
        do: route_pattern_stop_fixture(pattern, stop_id, position)

    calendar = calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})
    timing = timed_pattern_fixture(pattern)

    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: "TRIP-P-1",
        service_id: calendar.service_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    for {stop_id, position} <- Enum.with_index(["1330", "1434"], 1) do
      stop_time_fixture(organization.id, version.id, "TRIP-P-1", stop_id, %{
        stop_sequence: position
      })
    end

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: "1434",
      to_stop_id: "2000",
      min_transfer_time: 300
    })

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: "3000",
      to_stop_id: "1434",
      min_transfer_time: 120
    })

    relief_point_fixture(organization.id, version.id, %{stop_id: "1434"})

    %{organization: organization, version: version, audit: audit, stops: stops}
  end

  test "reports the distance, native band, trips, patterns, transfers and relief point",
       context do
    stop = context.stops["1434"]

    assert {:ok, impact} =
             StopEditing.move_impact(stop.id, north(@stop_lat, 13.7), context.audit)

    assert_in_delta impact.distance_m, 13.7, 0.3
    assert impact.band == :review
    assert impact.served? == true
    assert impact.weekday_trips == 1

    assert impact.patterns == [
             %{
               label: "1 · To P",
               route_id: "1",
               route_pattern_id: "P",
               headsign: "To P",
               weekday_trips: 1
             }
           ]

    # Both directions are reported, one row per transfer, east and north partners.
    assert [east, north] = Enum.sort_by(impact.transfers, & &1.min_transfer_time, :desc)
    assert east.label =~ "Stop 2000"
    assert east.min_transfer_time == 300
    assert_in_delta east.before_m, 79.2, 0.5
    assert_in_delta east.after_m, 80.4, 0.5
    assert north.label =~ "Stop 3000"
    assert north.min_transfer_time == 120
    assert_in_delta north.before_m, 111.2, 0.5
    assert_in_delta north.after_m, 97.5, 0.5

    assert impact.relief_points == ["Relief at 1434"]

    assert Enum.sort_by(impact.references, & &1.key) == [
             %{key: :relief_points, label: "Relief points", kind: :blocking, count: 1},
             %{
               key: :route_pattern_stops,
               label: "Patterns",
               kind: :blocking,
               count: 1
             },
             %{key: :stop_times, label: "Stop times", kind: :blocking, count: 1},
             %{
               key: :transfers_from,
               label: "Transfers from",
               kind: :descriptive,
               count: 1
             },
             %{key: :transfers_to, label: "Transfers to", kind: :descriptive, count: 1}
           ]

    assert impact.unmodeled == [
             :street_path,
             :pattern_lines,
             :boarding_safety,
             :accessibility,
             :alerts
           ]
  end

  test "bands follow the native thresholds, and an unserved stop is a correction anywhere",
       context do
    served = context.stops["1434"]

    for {metres, band} <- [{7.9, :correction}, {8.1, :review}, {101.0, :far}] do
      assert {:ok, %{band: ^band}} =
               StopEditing.move_impact(served.id, north(@stop_lat, metres), context.audit)
    end

    unserved =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "9999",
        stop_name: "Nothing serves this",
        stop_lat: Decimal.from_float(@stop_lat),
        stop_lon: Decimal.from_float(@stop_lon + 0.01)
      })

    assert {:ok, impact} =
             StopEditing.move_impact(unserved.id, north(@stop_lat, 400.0), context.audit)

    assert {impact.band, impact.served?, impact.weekday_trips} == {:correction, false, 0}
    assert {impact.patterns, impact.transfers, impact.references} == {[], [], []}
  end

  test "makes no street-routing request, while the native move review does", context do
    stop = context.stops["1434"]
    counter = :counters.new(1, [])
    stub_counting_routing(counter)

    assert {:ok, _impact} =
             StopEditing.move_impact(stop.id, north(@stop_lat, 13.7), context.audit)

    assert :counters.get(counter, 1) == 0

    assert {:ok, _review} =
             StopEditing.move_review(stop.id, north(@stop_lat, 13.7), context.audit)

    assert :counters.get(counter, 1) >= 1
  end

  test "changes no row, update stamp or audit entry and holds no lock", context do
    stop = context.stops["1434"]
    before = stamps(context)

    assert {:ok, _impact} =
             StopEditing.move_impact(stop.id, north(@stop_lat, 13.7), context.audit)

    assert stamps(context) == before

    # A concurrent editor's save of the same stop is not blocked or refused.
    assert {:ok, %Stop{stop_name: "Renamed"}} =
             StopEditing.update_stop(
               stop.id,
               %{"stop_name" => "Renamed"},
               Repo.reload!(stop).updated_at,
               context.audit
             )
  end

  test "names other reference classes with their counts", context do
    station =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "ST",
        stop_name: "Station",
        location_type: 1,
        stop_lat: Decimal.from_float(@stop_lat),
        stop_lon: Decimal.from_float(@stop_lon + 0.02)
      })

    child_stop_fixture(context.organization.id, context.version.id, station.stop_id, %{
      stop_id: "ST-A",
      stop_name: "Platform A",
      location_type: 4
    })

    Repo.insert!(%StopArea{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      area_id: "zone-1",
      stop_id: "ST"
    })

    Repo.insert!(%FlexService{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      key: "hub",
      name: "Hub",
      kind: :detour,
      hub_stop_ids: ["ST"]
    })

    assert {:ok, impact} =
             StopEditing.move_impact(station.id, north(@stop_lat, 5.0), context.audit)

    counts = Map.new(impact.references, &{&1.key, {&1.kind, &1.count}})

    assert counts == %{
             child_stops: {:blocking, 1},
             flex_hubs: {:blocking, 1},
             stop_areas: {:descriptive, 1}
           }
  end

  test "refuses a non-editor, a foreign stop and an invalid point", context do
    stop = context.stops["1434"]
    stranger = user_fixture()
    stranger_audit = %{context.audit | actor_id: stranger.id, actor_email: stranger.email}

    assert StopEditing.move_impact(stop.id, north(@stop_lat, 13.7), stranger_audit) ==
             {:error, :forbidden}

    other_version = gtfs_version_fixture(context.organization.id)
    other_audit = %{context.audit | gtfs_version_id: other_version.id}

    assert StopEditing.move_impact(stop.id, north(@stop_lat, 13.7), other_audit) ==
             {:error, :not_found}

    assert StopEditing.move_impact("not-a-uuid", north(@stop_lat, 13.7), context.audit) ==
             {:error, :not_found}

    for point <- [{200.0, 0.0}, {0.0, 91.0}, {nil, 1}, {-124.0, "44.6"}, :north, {1.0}] do
      assert StopEditing.move_impact(stop.id, point, context.audit) == {:error, :invalid_input},
             inspect(point)
    end
  end

  # -- helpers ----------------------------------------------------------------

  # `metres` north of latitude `lat` along the fixture's meridian, as `{lon, lat}`.
  defp north(lat, metres), do: {@stop_lon, lat + metres / @metres_per_degree}

  defp stamps(context) do
    scope = [context.organization.id, context.version.id]

    {Repo.all(
       from(s in Stop, order_by: s.id, select: {s.id, s.updated_at, s.stop_lat, s.stop_lon})
     ), Repo.all(from(t in Transfer, order_by: t.id, select: {t.id, t.updated_at})),
     Repo.all(from(r in ReliefPoint, order_by: r.id, select: {r.id, r.updated_at})),
     Repo.all(from(p in RoutePattern, order_by: p.id, select: {p.id, p.updated_at})),
     Repo.all(from(t in Trip, order_by: t.id, select: {t.id, t.updated_at})),
     Repo.aggregate(from(l in ChangeLog, where: l.organization_id in ^scope), :count)}
  end

  defp stub_counting_routing(counter) do
    Req.Test.stub(@routing_owner, fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            %{
              "type" => "Feature",
              "properties" => %{"mode" => "bus"},
              "geometry" => %{
                "type" => "MultiLineString",
                "coordinates" => [[[-124.0530, 44.6205], [-124.0530, 44.6215]]]
              }
            }
          ]
        })
      )
    end)
  end
end
