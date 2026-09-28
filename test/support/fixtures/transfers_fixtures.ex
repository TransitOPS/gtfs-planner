defmodule GtfsPlanner.TransfersFixtures do
  @moduledoc """
  The literal transfer network the transfer management tests share.

  `transfer_network_fixture/2` creates one version's stops, routes, trips and
  stop_times and returns them keyed by GTFS id, so a test can name
  `network.stops["CEN-A"]`, `network.routes["99"]` or `network.trips["12-0815"]`.
  The network is fixed rather than improvised per test because the catalog
  annotation under test — station coverage, endpoint resolution, selector routes
  and trips, and the stop_time incidence behind a competition flag — has to be
  observed against the same literal data in every case.

  Central Station `CEN` (type 1) has three children: the platforms `CEN-A` and
  `CEN-C` and the entrance `CEN-E` (type 2), which station coverage must exclude.
  The top-level stops are `MKT`, `HBR`, `MUS` and `NOC`, which carries no
  coordinates for the map reads. Routes `12`, `24`, `6` and the inactive `99`
  carry six trips; every stop_time uses the same arrival and departure time.
  """

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.GtfsFixtures
  alias GtfsPlanner.Repo

  @service_id "WKDY"

  @stops [
    {"CEN", "Central Station", [location_type: 1, stop_lat: "40.0000", stop_lon: "-75.0000"]},
    {"CEN-A", "Central · Bay A",
     [parent_station: "CEN", platform_code: "A", stop_lat: "40.0001", stop_lon: "-75.0002"]},
    {"CEN-C", "Central · Bay C",
     [parent_station: "CEN", platform_code: "C", stop_lat: "40.0002", stop_lon: "-74.9998"]},
    {"CEN-E", "Central · Main entrance",
     [parent_station: "CEN", location_type: 2, stop_lat: "40.0003", stop_lon: "-75.0001"]},
    {"MKT", "Market Street", [stop_lat: "40.0100", stop_lon: "-75.0100"]},
    {"HBR", "Harbor", [stop_lat: "39.9900", stop_lon: "-74.9900"]},
    {"MUS", "Museum", [stop_lat: "40.0050", stop_lon: "-75.0200"]},
    {"NOC", "No Coordinates", [stop_lat: nil, stop_lon: nil]}
  ]

  @routes [
    {"12", "12", "Riverside", [active: true]},
    {"24", "24", "Harbor", [active: true]},
    {"6", "6", "Museum", [active: true]},
    {"99", "99", "Old Line", [active: false]}
  ]

  @trips [
    {"12-0815", "12", "Harbor",
     [{"CEN-A", "08:15:00"}, {"MKT", "08:25:00"}, {"HBR", "08:40:00"}]},
    {"12-1010", "12", "Harbor", [{"MKT", "10:10:00"}, {"HBR", "10:25:00"}]},
    {"24-0840", "24", "Market Street",
     [{"CEN-C", "08:40:00"}, {"HBR", "08:55:00"}, {"MKT", "09:10:00"}]},
    {"24-0920", "24", "Market Street", [{"HBR", "09:20:00"}, {"MKT", "09:35:00"}]},
    {"6-0815", "6", "Central", [{"MUS", "08:15:00"}, {"CEN-A", "08:30:00"}]},
    {"99-0700", "99", "Market Street", [{"MKT", "07:00:00"}]}
  ]

  @doc """
  Creates the fixture network in one organization and version.

  Returns `%{stops: %{stop_id => Stop}, routes: %{route_id => Route},
  trips: %{trip_id => Trip}}` for this literal network.
  """
  def transfer_network_fixture(organization_id, gtfs_version_id) do
    stops =
      Map.new(@stops, fn {stop_id, stop_name, opts} ->
        {stop_id, create_stop(organization_id, gtfs_version_id, stop_id, stop_name, opts)}
      end)

    routes =
      Map.new(@routes, fn {route_id, short_name, long_name, opts} ->
        {route_id,
         GtfsFixtures.route_fixture(
           organization_id,
           gtfs_version_id,
           Map.merge(Map.new(opts), %{
             route_id: route_id,
             route_short_name: short_name,
             route_long_name: long_name
           })
         )}
      end)

    trips =
      Map.new(@trips, fn {trip_id, route_id, headsign, stop_times} ->
        trip =
          GtfsFixtures.trip_fixture(organization_id, gtfs_version_id, route_id, %{
            trip_id: trip_id,
            service_id: @service_id,
            trip_headsign: headsign
          })

        create_stop_times(organization_id, gtfs_version_id, trip_id, stop_times)
        {trip_id, trip}
      end)

    %{stops: stops, routes: routes, trips: trips}
  end

  # A child stop cannot go through `Stop.changeset/2`, which requires a `level_id`
  # for any stop that names a parent station; the import changeset is the
  # permissive path the import workflow uses for the same shape.
  defp create_stop(organization_id, gtfs_version_id, stop_id, stop_name, opts) do
    attrs =
      %{stop_id: stop_id, stop_name: stop_name}
      |> Map.merge(Map.new(opts))
      |> Map.merge(%{organization_id: organization_id, gtfs_version_id: gtfs_version_id})

    if attrs[:parent_station] do
      %Stop{}
      |> Stop.import_changeset(attrs)
      |> Repo.insert!()
    else
      GtfsFixtures.stop_fixture(organization_id, gtfs_version_id, attrs)
    end
  end

  defp create_stop_times(organization_id, gtfs_version_id, trip_id, stop_times) do
    stop_times
    |> Enum.with_index(1)
    |> Enum.each(fn {{stop_id, time}, stop_sequence} ->
      GtfsFixtures.stop_time_fixture(organization_id, gtfs_version_id, trip_id, stop_id, %{
        arrival_time: time,
        departure_time: time,
        stop_sequence: stop_sequence
      })
    end)
  end
end
