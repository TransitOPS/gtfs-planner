defmodule GtfsPlanner.Gtfs.Export.PreflightTest do
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export.Preflight
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    %{organization: organization, version: version}
  end

  describe "run/2" do
    test "returns :ok for a version without violations", %{organization: org, version: version} do
      arrange_clean_feed(org.id, version.id)

      assert Preflight.run(org.id, version.id) == :ok
    end

    test "returns :ok for a version without any rows", %{organization: org, version: version} do
      assert Preflight.run(org.id, version.id) == :ok
    end
  end

  describe "station_with_parent" do
    test "reports a station that has a parent station", %{organization: org, version: version} do
      import_stop(org.id, version.id, stop_id: "ROOT", location_type: 1)
      import_stop(org.id, version.id, stop_id: "NESTED", location_type: 1, parent_station: "ROOT")

      import_stop(org.id, version.id,
        stop_id: "PLATFORM",
        location_type: 0,
        parent_station: "ROOT"
      )

      assert {:error, [%{code: "station_with_parent", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "1 station has a parent station"
      assert message =~ "NESTED"
      refute message =~ "PLATFORM"
      assert message =~ "Floorplans"
    end
  end

  describe "stops_missing_coordinates" do
    test "reports stops, stations and entrances without latitude or longitude", %{
      organization: org,
      version: version
    } do
      stop_fixture(org.id, version.id, stop_id: "NO_LAT", stop_lat: nil)
      stop_fixture(org.id, version.id, stop_id: "NO_LON", stop_lon: nil, location_type: 1)

      stop_fixture(org.id, version.id,
        stop_id: "NO_BOTH",
        stop_lat: nil,
        stop_lon: nil,
        location_type: 2
      )

      assert {:error, [%{code: "stops_missing_coordinates", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "3 stops, stations or entrances have no latitude/longitude"
      assert message =~ "(for example NO_BOTH, NO_LAT, NO_LON)"
      assert message =~ "Floorplans"
    end

    test "reports a stop with a nil location type, which GTFS reads as 0", %{
      organization: org,
      version: version
    } do
      stop_fixture(org.id, version.id,
        stop_id: "NIL_TYPE",
        location_type: nil,
        stop_lat: nil,
        stop_lon: nil
      )

      assert {:error, [%{code: "stops_missing_coordinates", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "1 stop, station or entrance has no latitude/longitude"
      assert message =~ "NIL_TYPE"
    end

    test "does not report a generic node or a boarding area without coordinates", %{
      organization: org,
      version: version
    } do
      stop_fixture(org.id, version.id,
        stop_id: "NODE",
        location_type: 3,
        stop_lat: nil,
        stop_lon: nil
      )

      stop_fixture(org.id, version.id,
        stop_id: "BOARDING",
        location_type: 4,
        stop_lat: nil,
        stop_lon: nil
      )

      assert Preflight.run(org.id, version.id) == :ok
    end

    test "counts every finding and names at most five examples", %{
      organization: org,
      version: version
    } do
      for index <- 1..7 do
        stop_fixture(org.id, version.id, stop_id: "STOP_#{index}", stop_lat: nil, stop_lon: nil)
      end

      assert {:error, [%{message: message}]} = Preflight.run(org.id, version.id)

      assert message =~ "7 stops, stations or entrances have no latitude/longitude"
      assert message =~ "(for example STOP_1, STOP_2, STOP_3, STOP_4, STOP_5)"
      refute message =~ "STOP_6"
    end
  end

  describe "bidirectional_exit_gate" do
    test "reports an exit gate stored as bidirectional", %{organization: org, version: version} do
      gate = pathway_between_new_stops(org.id, version.id, pathway_id: "GATE_1", pathway_mode: 7)
      make_bidirectional(gate)
      pathway_between_new_stops(org.id, version.id, pathway_id: "WALKWAY", pathway_mode: 1)

      assert {:error, [%{code: "bidirectional_exit_gate", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "1 exit gate is two-way"
      assert message =~ "GATE_1"
      refute message =~ "WALKWAY"
    end

    test "does not report an exit gate that is one-way", %{organization: org, version: version} do
      pathway_between_new_stops(org.id, version.id, pathway_id: "GATE_1", pathway_mode: 7)

      assert Preflight.run(org.id, version.id) == :ok
    end
  end

  describe "mixed_agency_timezones" do
    test "reports agencies with different timezones", %{organization: org, version: version} do
      agency_fixture(org.id, version.id, agency_timezone: "America/New_York")
      agency_fixture(org.id, version.id, agency_timezone: "America/Chicago")

      assert {:error, [%{code: "mixed_agency_timezones", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "2 different timezones"
      assert message =~ "America/Chicago, America/New_York"
      assert message =~ "Agencies"
    end

    test "does not report agencies that share a timezone", %{organization: org, version: version} do
      agency_fixture(org.id, version.id, agency_timezone: "America/New_York")
      agency_fixture(org.id, version.id, agency_timezone: "America/New_York")

      assert Preflight.run(org.id, version.id) == :ok
    end

    test "does not report a version with one agency", %{organization: org, version: version} do
      agency_fixture(org.id, version.id, agency_timezone: "America/New_York")

      assert Preflight.run(org.id, version.id) == :ok
    end

    test "does not report a version with no agency", %{organization: org, version: version} do
      stop_fixture(org.id, version.id)

      assert Preflight.run(org.id, version.id) == :ok
    end
  end

  describe "transfer_missing_reference" do
    test "reports one issue for transfers naming a missing stop, route or trip", %{
      organization: org,
      version: version
    } do
      stop = stop_fixture(org.id, version.id, stop_id: "REAL_STOP")

      transfer_fixture(org.id, version.id,
        from_stop_id: "REAL_STOP",
        to_stop_id: "GHOST_STOP"
      )

      transfer_fixture(org.id, version.id,
        from_stop_id: stop.stop_id,
        to_stop_id: stop.stop_id,
        from_route_id: "GHOST_ROUTE"
      )

      transfer_fixture(org.id, version.id,
        transfer_type: 4,
        from_trip_id: "GHOST_TRIP_A",
        to_trip_id: "GHOST_TRIP_B"
      )

      transfer_fixture(org.id, version.id, from_stop_id: "REAL_STOP", to_stop_id: "REAL_STOP")

      assert {:error, [%{code: "transfer_missing_reference", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "3 transfers name a stop, route or trip that does not exist"

      assert message =~
               "(for example GHOST_ROUTE, GHOST_STOP, GHOST_TRIP_A, GHOST_TRIP_B)"

      assert message =~ "Transfers page"
    end

    test "reports a transfer whose stop exists only in another version", %{
      organization: org,
      version: version
    } do
      other_version = gtfs_version_fixture(org.id)
      stop_fixture(org.id, version.id, stop_id: "HERE")
      stop_fixture(org.id, other_version.id, stop_id: "ELSEWHERE")
      transfer_fixture(org.id, version.id, from_stop_id: "HERE", to_stop_id: "ELSEWHERE")

      assert {:error, [%{code: "transfer_missing_reference", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "1 transfer names a stop, route or trip"
      assert message =~ "ELSEWHERE"
    end
  end

  describe "trip_missing_service" do
    test "reports trips whose service has no calendar or calendar dates", %{
      organization: org,
      version: version
    } do
      route = route_fixture(org.id, version.id)
      calendar_fixture(org.id, version.id, service_id: "WEEKDAY")
      trip_fixture(org.id, version.id, route.route_id, service_id: "WEEKDAY")
      trip_fixture(org.id, version.id, route.route_id, service_id: "GHOST_SERVICE")
      trip_fixture(org.id, version.id, route.route_id, service_id: "GHOST_SERVICE")
      trip_fixture(org.id, version.id, route.route_id, service_id: "OTHER_GHOST")

      assert {:error, [%{code: "trip_missing_service", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "3 trips use a service ID that has no calendar or calendar dates"
      assert message =~ "(for example GHOST_SERVICE, OTHER_GHOST)"
      assert message =~ "Calendars page"
    end

    test "does not report a trip whose service exists only in calendar dates", %{
      organization: org,
      version: version
    } do
      route = route_fixture(org.id, version.id)
      calendar_date_fixture(org.id, version.id, service_id: "HOLIDAY")
      trip_fixture(org.id, version.id, route.route_id, service_id: "HOLIDAY")

      assert Preflight.run(org.id, version.id) == :ok
    end

    test "reports a trip whose service exists only in another version", %{
      organization: org,
      version: version
    } do
      other_version = gtfs_version_fixture(org.id)
      route = route_fixture(org.id, version.id)
      calendar_fixture(org.id, other_version.id, service_id: "ELSEWHERE")
      trip_fixture(org.id, version.id, route.route_id, service_id: "ELSEWHERE")

      assert {:error, [%{code: "trip_missing_service", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "1 trip uses a service ID"
      assert message =~ "ELSEWHERE"
    end

    test "ignores trips of an inactive route, which the export leaves out", %{
      organization: org,
      version: version
    } do
      active_route = route_fixture(org.id, version.id)
      inactive_route = route_fixture(org.id, version.id, route_id: "R_INACTIVE", active: false)
      trip_fixture(org.id, version.id, inactive_route.route_id, service_id: "RETIRED_SERVICE")
      trip_fixture(org.id, version.id, active_route.route_id, service_id: "GHOST_SERVICE")

      assert {:error, [%{code: "trip_missing_service", message: message}]} =
               Preflight.run(org.id, version.id)

      assert message =~ "1 trip uses a service ID"
      assert message =~ "(for example GHOST_SERVICE)"
    end
  end

  describe "scoping" do
    test "does not report violations stored in another version", %{
      organization: org,
      version: version
    } do
      other_version = gtfs_version_fixture(org.id)
      arrange_every_violation(org.id, other_version.id)

      assert Preflight.run(org.id, version.id) == :ok
      assert {:error, issues} = Preflight.run(org.id, other_version.id)
      assert length(issues) == 6
    end

    test "does not report violations stored in another organization", %{
      organization: org,
      version: version
    } do
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      arrange_every_violation(other_org.id, other_version.id)

      assert Preflight.run(org.id, version.id) == :ok
      assert {:error, issues} = Preflight.run(other_org.id, other_version.id)
      assert length(issues) == 6
    end
  end

  describe "run/3" do
    test "reports every check for a full export", %{organization: org, version: version} do
      arrange_every_violation(org.id, version.id)

      assert {:error, issues} = Preflight.run(org.id, version.id, :full)

      assert Enum.map(issues, & &1.code) == [
               "station_with_parent",
               "stops_missing_coordinates",
               "bidirectional_exit_gate",
               "mixed_agency_timezones",
               "transfer_missing_reference",
               "trip_missing_service"
             ]
    end

    test "checks only stops and pathways for a pathways export", %{
      organization: org,
      version: version
    } do
      arrange_every_violation(org.id, version.id)

      assert {:error, issues} = Preflight.run(org.id, version.id, :pathways)

      assert Enum.map(issues, & &1.code) == [
               "station_with_parent",
               "stops_missing_coordinates",
               "bidirectional_exit_gate"
             ]
    end
  end

  defp arrange_clean_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id, agency_timezone: "America/New_York")
    stop_fixture(organization_id, version_id, stop_id: "A")
    stop_fixture(organization_id, version_id, stop_id: "B")
    pathway_fixture(organization_id, version_id, "A", "B", pathway_mode: 1)
    route = route_fixture(organization_id, version_id)
    calendar_fixture(organization_id, version_id, service_id: "WEEKDAY")
    trip_fixture(organization_id, version_id, route.route_id, service_id: "WEEKDAY")
    transfer_fixture(organization_id, version_id, from_stop_id: "A", to_stop_id: "B")
  end

  # One violation for each check, each with its own ID.
  defp arrange_every_violation(organization_id, version_id) do
    import_stop(organization_id, version_id, stop_id: "ROOT", location_type: 1)

    import_stop(organization_id, version_id,
      stop_id: "NESTED",
      location_type: 1,
      parent_station: "ROOT"
    )

    stop_fixture(organization_id, version_id, stop_id: "NO_COORDS", stop_lat: nil, stop_lon: nil)

    organization_id
    |> pathway_between_new_stops(version_id, pathway_id: "GATE", pathway_mode: 7)
    |> make_bidirectional()

    agency_fixture(organization_id, version_id, agency_timezone: "America/New_York")
    agency_fixture(organization_id, version_id, agency_timezone: "America/Chicago")

    transfer_fixture(organization_id, version_id, from_stop_id: "ROOT", to_stop_id: "GHOST_STOP")

    route = route_fixture(organization_id, version_id)
    trip_fixture(organization_id, version_id, route.route_id, service_id: "GHOST_SERVICE")
  end

  # `Gtfs.create_stop/1` rejects a station inside a station; the import path
  # stores it, which is how this state reaches a version.
  defp import_stop(organization_id, version_id, attrs) do
    {:ok, stop} =
      attrs
      |> valid_stop_attrs()
      |> Map.merge(%{organization_id: organization_id, gtfs_version_id: version_id})
      |> Gtfs.import_create_stop()

    stop
  end

  defp pathway_between_new_stops(organization_id, version_id, attrs) do
    from_stop = stop_fixture(organization_id, version_id)
    to_stop = stop_fixture(organization_id, version_id)

    pathway_fixture(organization_id, version_id, from_stop.stop_id, to_stop.stop_id, attrs)
  end

  # `Pathway.changeset/2` forces exit gates to one-way, so a stored two-way exit
  # gate needs a direct write, as an older import would have left it.
  defp make_bidirectional(%Pathway{id: id} = pathway) do
    {1, _} =
      Repo.update_all(from(p in Pathway, where: p.id == ^id), set: [is_bidirectional: true])

    pathway
  end
end
