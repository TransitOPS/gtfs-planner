defmodule GtfsPlanner.Gtfs.Transfers.MapReadsTest do
  @moduledoc """
  Merge evidence (EV-8) for the transfer editor's map reads.

  The connection map needs three scoped reads: `Transfers.map_payload/3` for the
  selected pair (endpoints, a station's drawable children and the endpoints that
  carry no coordinates), `Transfers.stops_in_bounds/3` for the pick-on-map
  candidates of a viewport that the browser hook supplies, and
  `Transfers.version_extent/2` for the version's own initial view.

  The cases use the shared literal network (`TransfersFixtures`) and expect literal
  points, so a payload that leaks another version's stop, reports a missing
  coordinate for an unknown ID, draws an entrance or a child without coordinates,
  fails to clamp a hook's out-of-range bound, crashes on a non-numeric bound, or
  returns more than 200 candidates is rejected here. EV-8 proves the server reads
  only: it does not prove the Leaflet hook or the map region that render them
  (EV-26/EV-27), the pick session itself (EV-27) or the page (EV-29).
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.TransfersFixtures

  @box %{"south" => 39.98, "west" => -75.03, "north" => 40.02, "east" => -74.98}
  @box_names ["CEN", "CEN-A", "CEN-C", "HBR", "MKT", "MUS"]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)

    %{organization: organization, version: version}
  end

  describe "map_payload/3" do
    test "returns both endpoints and the departure station's drawable children", ctx do
      assert payload(ctx, "CEN", "MKT") == %{
               a: point("CEN", "Central Station", 40.0, -75.0, 1),
               b: point("MKT", "Market Street", 40.01, -75.01, 0),
               children: [
                 Map.put(point("CEN-A", "Central · Bay A", 40.0001, -75.0002, 0), :side, "a"),
                 Map.put(point("CEN-C", "Central · Bay C", 40.0002, -74.9998, 0), :side, "a")
               ],
               missing_coordinates: []
             }
    end

    test "tags an arrival station's children with side b and never the entrance", ctx do
      assert %{a: %{stop_id: "MKT"}, b: %{stop_id: "CEN"}, children: children} =
               payload(ctx, "MKT", "CEN")

      assert Enum.map(children, &{&1.stop_id, &1.side}) == [{"CEN-A", "b"}, {"CEN-C", "b"}]
      refute Enum.any?(children, &(&1.stop_id == "CEN-E"))
    end

    test "omits a child without coordinates", ctx do
      insert_stop(ctx.organization.id, ctx.version.id, %{
        stop_id: "CEN-D",
        stop_name: "Central · Bay D",
        parent_station: "CEN",
        stop_lat: nil,
        stop_lon: nil
      })

      assert %{children: children, missing_coordinates: []} = payload(ctx, "CEN", "MKT")
      assert Enum.map(children, & &1.stop_id) == ["CEN-A", "CEN-C"]
    end

    test "reports an endpoint without coordinates once and yields a nil point", ctx do
      assert payload(ctx, "NOC", "NOC") == %{
               a: nil,
               b: nil,
               children: [],
               missing_coordinates: ["No Coordinates"]
             }

      assert payload(ctx, "NOC", "MKT") == %{
               a: nil,
               b: point("MKT", "Market Street", 40.01, -75.01, 0),
               children: [],
               missing_coordinates: ["No Coordinates"]
             }
    end

    test "yields nil without a missing entry for an unknown, foreign or non-string ID", ctx do
      assert payload(ctx, "NOPE", nil) == %{
               a: nil,
               b: nil,
               children: [],
               missing_coordinates: []
             }

      assert payload(ctx, nil, 123) == %{
               a: nil,
               b: nil,
               children: [],
               missing_coordinates: []
             }

      other_version = gtfs_version_fixture(ctx.organization.id)

      insert_stop(ctx.organization.id, other_version.id, %{
        stop_id: "CEN",
        stop_name: "Other Central",
        stop_lat: 41.0,
        stop_lon: -74.0
      })

      assert %{a: nil, missing_coordinates: []} =
               Transfers.map_payload(ctx.organization.id, other_version.id, %{
                 from_stop_id: "MKT",
                 to_stop_id: nil
               })

      assert %{a: %{stop_id: "CEN", name: "Other Central"}} =
               Transfers.map_payload(ctx.organization.id, other_version.id, %{
                 from_stop_id: "CEN",
                 to_stop_id: nil
               })
    end

    test "returns equal points when the same stop is on both sides", ctx do
      assert %{a: a, b: b, children: children} = payload(ctx, "CEN", "CEN")
      assert a == b
      assert a == point("CEN", "Central Station", 40.0, -75.0, 1)
      assert Enum.map(children, &{&1.stop_id, &1.side}) == [{"CEN-A", "a"}, {"CEN-C", "a"}]

      assert %{children: []} = payload(ctx, "MKT", "MKT")
    end
  end

  describe "stops_in_bounds/3" do
    test "returns the drawable stops inside the box as float points", ctx do
      assert {:ok, %{stops: stops, truncated?: false}} = in_bounds(ctx, @box)

      assert MapSet.new(Enum.map(stops, & &1.stop_id)) == MapSet.new(@box_names)

      assert Enum.find(stops, &(&1.stop_id == "CEN")) ==
               point("CEN", "Central Station", 40.0, -75.0, 1)

      assert Enum.all?(stops, &(is_float(&1.lat) and is_float(&1.lon)))
      refute Enum.any?(stops, &(&1.stop_id in ["CEN-E", "NOC"]))
    end

    test "accepts numeric strings and atom keys for the same box", ctx do
      numeric_strings = %{
        "south" => "39.98",
        "west" => "-75.03",
        "north" => "40.02",
        "east" => "-74.98"
      }

      assert {:ok, numbers} = in_bounds(ctx, @box)
      assert {:ok, strings} = in_bounds(ctx, numeric_strings)
      assert strings == numbers

      assert {:ok, atoms} =
               in_bounds(ctx, %{south: 39.98, west: -75.03, north: 40.02, east: -74.98})

      assert atoms == numbers
    end

    test "rejects a missing key and a non-numeric bound", ctx do
      assert in_bounds(ctx, %{"south" => 39.98, "west" => -75.03, "north" => 40.02}) ==
               {:error, :invalid_bounds}

      assert in_bounds(ctx, %{}) == {:error, :invalid_bounds}
      assert in_bounds(ctx, []) == {:error, :invalid_bounds}
      assert in_bounds(ctx, Map.put(@box, "east", "abc")) == {:error, :invalid_bounds}
      assert in_bounds(ctx, Map.put(@box, "east", "40.0abc")) == {:error, :invalid_bounds}
      assert in_bounds(ctx, Map.put(@box, "east", nil)) == {:error, :invalid_bounds}
      assert in_bounds(ctx, Map.put(@box, "east", true)) == {:error, :invalid_bounds}
      assert in_bounds(ctx, Map.put(@box, "east", [40.0])) == {:error, :invalid_bounds}
    end

    test "rejects a reversed box", ctx do
      assert in_bounds(ctx, Map.put(@box, "south", 40.03)) == {:error, :invalid_bounds}
      assert in_bounds(ctx, Map.put(@box, "west", -74.9)) == {:error, :invalid_bounds}
    end

    test "clamps out-of-range latitudes and longitudes instead of failing", ctx do
      assert in_bounds(ctx, %{"south" => 40.0, "west" => -75.03, "north" => 95, "east" => -74.98}) ==
               in_bounds(ctx, %{
                 "south" => 40.0,
                 "west" => -75.03,
                 "north" => 90,
                 "east" => -74.98
               })

      assert {:ok, %{stops: stops}} =
               in_bounds(ctx, %{
                 "south" => 40.0,
                 "west" => -75.03,
                 "north" => 95,
                 "east" => -74.98
               })

      assert "CEN" in Enum.map(stops, & &1.stop_id)
      refute "HBR" in Enum.map(stops, & &1.stop_id)

      assert in_bounds(ctx, %{"south" => 39.0, "west" => -195, "north" => 41.0, "east" => 185}) ==
               in_bounds(ctx, %{"south" => 39.0, "west" => -180, "north" => 41.0, "east" => 180})

      # The ordering check runs on the clamped values, so two out-of-range
      # latitudes collapse to 90 and an equal box rather than south > north.
      assert in_bounds(ctx, %{"south" => 95, "west" => -75.03, "north" => 90, "east" => -74.98}) ==
               {:ok, %{stops: [], truncated?: false}}
    end

    test "never returns another version's or organization's stops", ctx do
      sibling_version = gtfs_version_fixture(ctx.organization.id)

      insert_stop(ctx.organization.id, sibling_version.id, %{
        stop_id: "SIB",
        stop_name: "Sibling Version",
        stop_lat: 40.0,
        stop_lon: -75.0
      })

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      insert_stop(other_organization.id, other_version.id, %{
        stop_id: "OUT",
        stop_name: "Outside",
        stop_lat: 40.0,
        stop_lon: -75.0
      })

      assert {:ok, %{stops: stops}} = in_bounds(ctx, @box)
      refute Enum.any?(stops, &(&1.stop_id in ["SIB", "OUT"]))

      assert {:ok, %{stops: [%{stop_id: "SIB"}]}} =
               Transfers.stops_in_bounds(ctx.organization.id, sibling_version.id, @box)

      assert {:ok, %{stops: [%{stop_id: "OUT"}]}} =
               Transfers.stops_in_bounds(other_organization.id, other_version.id, @box)
    end

    test "returns 200 stops with truncated? when the box holds more", ctx do
      insert_box_stops(ctx, 201)

      assert {:ok, %{stops: stops, truncated?: true}} =
               in_bounds(ctx, %{
                 "south" => 40.9,
                 "west" => -74.1,
                 "north" => 41.1,
                 "east" => -73.9
               })

      assert length(stops) == 200
      assert Enum.map(stops, & &1.name) == Enum.map(1..200, &box_name/1)
      assert Enum.all?(stops, &(&1.lat == 41.0 and &1.lon == -74.0))
    end
  end

  describe "version_extent/2" do
    test "returns the version's own bounding box as floats", ctx do
      assert Transfers.version_extent(ctx.organization.id, ctx.version.id) ==
               %{south: 39.99, west: -75.02, north: 40.01, east: -74.99}
    end

    test "returns nil for a version whose stops have no coordinates", ctx do
      empty_version = gtfs_version_fixture(ctx.organization.id)

      assert Transfers.version_extent(ctx.organization.id, empty_version.id) == nil

      insert_stop(ctx.organization.id, empty_version.id, %{
        stop_id: "NOC2",
        stop_name: "No Coordinates Too",
        stop_lat: nil,
        stop_lon: nil
      })

      assert Transfers.version_extent(ctx.organization.id, empty_version.id) == nil
    end

    test "is scoped to the organization and version", ctx do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      insert_stop(other_organization.id, other_version.id, %{
        stop_id: "OUT",
        stop_name: "Outside",
        stop_lat: 10.0,
        stop_lon: 10.0
      })

      assert Transfers.version_extent(ctx.organization.id, ctx.version.id) ==
               %{south: 39.99, west: -75.02, north: 40.01, east: -74.99}

      assert Transfers.version_extent(other_organization.id, other_version.id) ==
               %{south: 10.0, west: 10.0, north: 10.0, east: 10.0}
    end
  end

  describe "Gtfs facades" do
    test "delegate to the map reads", ctx do
      assert Gtfs.transfer_map_payload(ctx.organization.id, ctx.version.id, %{
               from_stop_id: "CEN",
               to_stop_id: "MKT"
             }) == payload(ctx, "CEN", "MKT")

      assert Gtfs.transfer_stops_in_bounds(ctx.organization.id, ctx.version.id, @box) ==
               in_bounds(ctx, @box)

      assert Gtfs.transfer_version_extent(ctx.organization.id, ctx.version.id) ==
               Transfers.version_extent(ctx.organization.id, ctx.version.id)
    end
  end

  defp payload(ctx, from_stop_id, to_stop_id) do
    Transfers.map_payload(ctx.organization.id, ctx.version.id, %{
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id
    })
  end

  defp in_bounds(ctx, bounds),
    do: Transfers.stops_in_bounds(ctx.organization.id, ctx.version.id, bounds)

  defp point(stop_id, name, lat, lon, location_type) do
    %{stop_id: stop_id, name: name, lat: lat, lon: lon, location_type: location_type}
  end

  # The permissive import changeset is the same one `TransfersFixtures` uses for a
  # stop that names a parent station, so a test can add a child without a level.
  defp insert_stop(organization_id, gtfs_version_id, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.merge(%{organization_id: organization_id, gtfs_version_id: gtfs_version_id})

    %Stop{}
    |> Stop.import_changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_box_stops(ctx, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..count, fn index ->
        %{
          id: Ecto.UUID.generate(),
          stop_id: String.replace(box_name(index), " ", ""),
          stop_name: box_name(index),
          stop_lat: Decimal.from_float(41.0),
          stop_lon: Decimal.from_float(-74.0),
          location_type: 0,
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {^count, nil} = Repo.insert_all(Stop, rows)
  end

  defp box_name(index) do
    "Box " <> String.pad_leading(Integer.to_string(index), 3, "0")
  end
end
