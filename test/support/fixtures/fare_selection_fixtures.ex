defmodule GtfsPlanner.FareSelectionFixtures do
  @moduledoc """
  A small route and stop network for fare-zone route selections.

  `insert_network!/2` writes the same literal rows into any organization and
  version, so a test builds the network twice (a twin organization, a second
  version) and a missing scope predicate shows up as extra or foreign rows.

  Routes: `R6` (short name "6") and `R9` ("9").

  Boardable stops (`location_type` 0): `A1` "Alder" (no zone, R6), `A2` "Birch"
  (zone "B", R6), `A3` "Cedar" (no zone, R6 and R9), `AIR1` "Airport Gate" (no
  zone, R6), `AIR2` "Airport Terminal" (no zone, R9 only) and `U1` "Unserved" (no
  zone, no stop_times). `S1` "Central Station" is a station (`location_type` 1)
  that R6's trip calls at.

  Trip `T6` of R6 calls at A1, A2, A3, AIR1, S1 in that order and trip `T9` of R9
  at A3, AIR2. Every stop name starts with a capital letter and no two names tie,
  so the order is the same under C and en_US collation.
  """

  import GtfsPlanner.GtfsFixtures, only: [route_fixture: 3, trip_fixture: 4]

  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  @stops [
    %{stop_id: "A1", stop_name: "Alder", zone_id: nil},
    %{stop_id: "A2", stop_name: "Birch", zone_id: "B"},
    %{stop_id: "A3", stop_name: "Cedar", zone_id: nil},
    %{stop_id: "AIR1", stop_name: "Airport Gate", zone_id: nil},
    %{stop_id: "AIR2", stop_name: "Airport Terminal", zone_id: nil},
    %{stop_id: "U1", stop_name: "Unserved", zone_id: nil},
    %{stop_id: "S1", stop_name: "Central Station", zone_id: nil, location_type: 1}
  ]

  @doc """
  Inserts the network into the organization and version.

  Returns the inserted stop rows keyed by natural `stop_id`.
  """
  def insert_network!(organization, version) do
    org_id = organization.id
    version_id = version.id

    route_fixture(org_id, version_id, %{
      route_id: "R6",
      route_short_name: "6",
      route_long_name: "Six"
    })

    route_fixture(org_id, version_id, %{
      route_id: "R9",
      route_short_name: "9",
      route_long_name: "Nine"
    })

    stops = insert_stops!(organization, version, @stops)

    call_at!(organization, version, "R6", "T6", ["A1", "A2", "A3", "AIR1", "S1"])
    call_at!(organization, version, "R9", "T9", ["A3", "AIR2"])

    Map.new(stops, &{&1.stop_id, &1})
  end

  @doc "Inserts boardable stops (or other location types) straight into the tables."
  def insert_stops!(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn stop ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop.stop_id,
          stop_name: Map.get(stop, :stop_name, "Stop #{stop.stop_id}"),
          location_type: Map.get(stop, :location_type, 0),
          zone_id: Map.get(stop, :zone_id),
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    ^count = length(rows)
    rows
  end

  @doc "Adds a trip of `route_id` with one stop_time per natural stop ID, in order."
  def call_at!(organization, version, route_id, trip_id, stop_ids) do
    trip_fixture(organization.id, version.id, route_id, %{trip_id: trip_id, service_id: "WK"})
    now = DateTime.utc_now()

    rows =
      stop_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {stop_id, sequence} ->
        %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          trip_id: trip_id,
          stop_id: stop_id,
          stop_sequence: sequence,
          arrival_time: "08:00:00",
          departure_time: "08:00:00",
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(StopTime, rows)
    ^count = length(rows)
    :ok
  end

  @doc "Declares a zone record so the zone is in the inventory."
  def declare_zone!(organization, version, zone_id) do
    Repo.insert!(%FareZone{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      zone_id: zone_id,
      name: "Zone #{zone_id}",
      color: "ocean"
    })
  end
end
