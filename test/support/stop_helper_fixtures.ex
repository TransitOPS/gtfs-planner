defmodule GtfsPlanner.StopHelperFixtures do
  @moduledoc """
  Scopes for the two stop helper packs, admitted the way the stops pages admit them:
  the whole-version identity plus a source snapshot through the real
  `Scope.with_source_snapshot/2`, so a scope the seam would refuse is never built.
  """

  import GtfsPlanner.AdvancedBlockingFixtures, only: [relief_point_fixture: 3]
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Agents.Scope

  @doc """
  A `%Scope{}` for `pack_id` carrying `kind` and `payload` as its admitted snapshot, or
  with no snapshot when `snapshot` is `:none`.
  """
  def helper_scope(pack_id, organization, version, user, snapshot) do
    base = Scope.context({:version, version.id})

    context =
      case snapshot do
        :none ->
          base

        {kind, payload} ->
          {:ok, admitted} = Scope.with_source_snapshot(base, %{kind: kind, payload: payload})
          admitted
      end

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: pack_id,
      version_name: version.name,
      resource_context: context
    }
  end

  @stop_lat 44.6210
  @stop_lon -124.0530

  @doc """
  The staged served stop the move impact tests share, written by hand: stop `1434`
  ("Main St") at 44.6210, -124.0530 on pattern `P` of route `1` with one weekday trip,
  a transfer to `2000` (about 79 m east), a transfer from `3000` (about 111 m north)
  and one relief point; `1330` is the previous stop. Returns the stops by `stop_id`.
  """
  def staged_move_fixture(organization, version) do
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

    route = route_fixture(organization.id, version.id, %{route_id: "1", route_short_name: "1"})

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

    %{stops: stops, route: route, pattern: pattern}
  end

  @doc "`{lon, lat}` that many metres north of latitude `lat` along the fixture's meridian."
  def north(lat, metres), do: {@stop_lon, lat + metres / 111_195.0}

  @doc "The latitude of the staged stop `1434`."
  def staged_lat, do: @stop_lat

  @doc "The `stop_focus` snapshot the stops map admits for `stop` and an optional pin."
  def stop_focus(stop_uuid, candidate \\ nil),
    do:
      {"stop_focus", %{"schema_version" => 1, "stop_uuid" => stop_uuid, "candidate" => candidate}}
end
