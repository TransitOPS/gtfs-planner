defmodule GtfsPlanner.Gtfs.Transfers.OptionsTest do
  @moduledoc """
  Merge evidence (EV-7) for the transfer editor's option queries.

  The editor needs four scoped reads: `Transfers.search_stops/3` and
  `Transfers.fetch_pickable_stop/3` for the stop and station fields, and
  `Transfers.route_options/4` and `Transfers.trip_options/6` for the selectors that
  depend on a chosen stop. They must filter by organization and version, restrict
  stops to the selectable location types, escape LIKE wildcards, order and truncate
  as specified, and append a stored selector that is missing, inactive or no longer
  serving with its note.

  The cases use the shared literal network (`TransfersFixtures`) and expect literal
  options, so queries that leak another tenant's or version's rows, accept an
  entrance, treat `%` or `_` as a wildcard, ignore station coverage, rank an
  inactive route above an active one, or silently drop a stored selector are
  rejected here. EV-7 does not prove the map reads (EV-8), the facade wiring into a
  LiveView (EV-20) or the pick-on-map session (EV-27), and it is not a load test
  (EV-13).
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.TransfersFixtures

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)

    %{organization: organization, version: version}
  end

  describe "search_stops/3" do
    test "returns the version's selectable stops whose name, ID or platform code matches", ctx do
      result = search(ctx, "central")

      assert MapSet.new(Enum.map(result.stops, & &1.stop_id)) ==
               MapSet.new(["CEN", "CEN-A", "CEN-C"])

      refute result.truncated?
      refute Enum.any?(result.stops, &(&1.stop_id == "CEN-E"))
    end

    test "matches platform codes, ignores case and treats LIKE wildcards literally", ctx do
      assert "CEN-C" in Enum.map(search(ctx, "C").stops, & &1.stop_id)

      assert search(ctx, "CENTRAL").stops == search(ctx, "central").stops

      set_platform_code(ctx, "MKT", "DOCK-9")
      assert Enum.map(search(ctx, "dock-9").stops, & &1.stop_id) == ["MKT"]

      assert search(ctx, "%").stops == []
      assert search(ctx, "_").stops == []
      assert search(ctx, "").stops == []
      assert search(ctx, "   ").stops == []

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      stop_fixture(other_organization.id, other_version.id, %{
        stop_id: "CEN-X",
        stop_name: "Central Annex"
      })

      assert search(ctx, "annex").stops == []

      assert Enum.map(
               Transfers.search_stops(other_organization.id, other_version.id, "annex").stops,
               & &1.stop_id
             ) == ["CEN-X"]
    end

    test "returns 20 options and truncated? when more stops match", ctx do
      for index <- 1..21 do
        number = index |> Integer.to_string() |> String.pad_leading(2, "0")

        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "X#{number}",
          stop_name: "Central Extra #{number}"
        })
      end

      result = search(ctx, "extra")

      expected_names =
        for index <- 1..20 do
          number = index |> Integer.to_string() |> String.pad_leading(2, "0")
          "Central Extra #{number}"
        end

      assert result.truncated?
      assert Enum.map(result.stops, & &1.stop_name) == expected_names
      refute "Central Extra 21" in Enum.map(result.stops, & &1.stop_name)
    end

    test "reports the parent station, the child count and float coordinates", ctx do
      options = search(ctx, "central").stops |> Map.new(&{&1.stop_id, &1})

      assert options["CEN-A"] == %{
               stop_id: "CEN-A",
               stop_name: "Central · Bay A",
               location_type: 0,
               platform_code: "A",
               parent_name: "Central Station",
               child_count: 0,
               lat: 40.0001,
               lon: -75.0002
             }

      assert options["CEN"].location_type == 1
      assert options["CEN"].child_count == 2
      assert options["CEN"].parent_name == nil
      assert is_float(options["CEN"].lat)

      assert {:ok, %{lat: nil, lon: nil} = noc} = fetch_stop(ctx, "NOC")
      assert noc.stop_name == "No Coordinates"
    end
  end

  describe "fetch_pickable_stop/3" do
    test "returns the option for a selectable stop and :error otherwise", ctx do
      assert {:ok, %{stop_id: "CEN-A", parent_name: "Central Station"}} = fetch_stop(ctx, "CEN-A")
      assert {:ok, %{stop_id: "CEN", child_count: 2, location_type: 1}} = fetch_stop(ctx, "CEN")

      assert fetch_stop(ctx, "CEN-E") == :error
      assert fetch_stop(ctx, "NOPE") == :error
      assert fetch_stop(ctx, nil) == :error

      other_version = gtfs_version_fixture(ctx.organization.id)

      stop_fixture(ctx.organization.id, other_version.id, %{
        stop_id: "CEN-B",
        stop_name: "Central · Bay B"
      })

      assert fetch_stop(ctx, "CEN-B") == :error

      assert {:ok, %{stop_id: "CEN-B"}} =
               Transfers.fetch_pickable_stop(ctx.organization.id, other_version.id, "CEN-B")
    end
  end

  describe "route_options/4" do
    test "lists the active routes serving a stop's coverage", ctx do
      assert route_options(ctx, "CEN", nil) == [
               %{route_id: "12", route_short_name: "12", route_long_name: "Riverside", note: nil},
               %{route_id: "24", route_short_name: "24", route_long_name: "Harbor", note: nil},
               %{route_id: "6", route_short_name: "6", route_long_name: "Museum", note: nil}
             ]

      assert Enum.map(route_options(ctx, "MKT", nil), & &1.route_id) == ["12", "24"]
      assert route_options(ctx, nil, nil) == []
      assert route_options(ctx, "NOWHERE", nil) == []
    end

    test "appends the stored route with its reason when it is not offered", ctx do
      inactive = route_options(ctx, "MKT", "99")

      assert Enum.map(inactive, & &1.route_id) == ["12", "24", "99"]

      assert List.last(inactive) == %{
               route_id: "99",
               route_short_name: "99",
               route_long_name: "Old Line",
               note: :inactive
             }

      assert List.last(route_options(ctx, "MKT", "R404")) == %{
               route_id: "R404",
               route_short_name: nil,
               route_long_name: nil,
               note: :missing
             }

      assert List.last(route_options(ctx, "MKT", "6")) == %{
               route_id: "6",
               route_short_name: "6",
               route_long_name: "Museum",
               note: :not_serving
             }

      assert Enum.map(route_options(ctx, "MKT", "12"), & &1.route_id) == ["12", "24"]

      assert route_options(ctx, "NOWHERE", "12") == [
               %{
                 route_id: "12",
                 route_short_name: "12",
                 route_long_name: "Riverside",
                 note: :not_serving
               }
             ]
    end
  end

  describe "trip_options/6" do
    test "lists the route's trips serving the coverage with the earliest side clock", ctx do
      assert trip_options(ctx, "12", "CEN", :from, nil) == [
               %{
                 trip_id: "12-0815",
                 time: "08:15",
                 headsign: "Harbor",
                 service_id: "WKDY",
                 note: nil
               }
             ]

      assert trip_options(ctx, "12", "MKT", :to, nil) == [
               %{
                 trip_id: "12-0815",
                 time: "08:25",
                 headsign: "Harbor",
                 service_id: "WKDY",
                 note: nil
               },
               %{
                 trip_id: "12-1010",
                 time: "10:10",
                 headsign: "Harbor",
                 service_id: "WKDY",
                 note: nil
               }
             ]

      assert Enum.map(trip_options(ctx, "24", "CEN", :from, nil), & &1.trip_id) == ["24-0840"]
      assert trip_options(ctx, nil, "CEN", :from, nil) == []
      assert trip_options(ctx, "12", nil, :from, nil) == []
      assert trip_options(ctx, "12", "NOWHERE", :from, nil) == []
    end

    test "keeps the seconds of an earliest side clock", ctx do
      trip_fixture(ctx.organization.id, ctx.version.id, "12", %{
        trip_id: "12-0705",
        service_id: "WKDY",
        trip_headsign: "Harbor"
      })

      stop_time_fixture(ctx.organization.id, ctx.version.id, "12-0705", "CEN-A", %{
        arrival_time: "07:05:30",
        departure_time: "07:05:30",
        stop_sequence: 1
      })

      assert trip_options(ctx, "12", "CEN", :from, nil) == [
               %{
                 trip_id: "12-0705",
                 time: "07:05:30",
                 headsign: "Harbor",
                 service_id: "WKDY",
                 note: nil
               },
               %{
                 trip_id: "12-0815",
                 time: "08:15",
                 headsign: "Harbor",
                 service_id: "WKDY",
                 note: nil
               }
             ]
    end

    test "appends the stored trip with its reason when it is not offered", ctx do
      other_route = trip_options(ctx, "12", "CEN", :from, "24-0840")

      assert Enum.map(other_route, & &1.trip_id) == ["12-0815", "24-0840"]

      assert List.last(other_route) == %{
               trip_id: "24-0840",
               time: nil,
               headsign: "Market Street",
               service_id: "WKDY",
               note: :other_route
             }

      assert List.last(trip_options(ctx, "12", "CEN", :from, "12-1010")) == %{
               trip_id: "12-1010",
               time: nil,
               headsign: "Harbor",
               service_id: "WKDY",
               note: :not_serving
             }

      assert List.last(trip_options(ctx, "12", "CEN", :from, "T404")) == %{
               trip_id: "T404",
               time: nil,
               headsign: nil,
               service_id: nil,
               note: :missing
             }

      assert Enum.map(trip_options(ctx, "12", "MKT", :to, "12-0815"), & &1.trip_id) ==
               ["12-0815", "12-1010"]
    end
  end

  describe "Gtfs facades" do
    test "delegate to the option queries", ctx do
      assert Gtfs.search_transfer_stops(ctx.organization.id, ctx.version.id, "central") ==
               search(ctx, "central")

      assert Gtfs.fetch_transfer_stop(ctx.organization.id, ctx.version.id, "CEN-A") ==
               fetch_stop(ctx, "CEN-A")

      assert Gtfs.fetch_transfer_stop(ctx.organization.id, ctx.version.id, "CEN-E") == :error

      assert Gtfs.transfer_route_options(ctx.organization.id, ctx.version.id, "MKT", "99") ==
               route_options(ctx, "MKT", "99")

      assert Gtfs.transfer_trip_options(
               ctx.organization.id,
               ctx.version.id,
               "12",
               "MKT",
               :to,
               nil
             ) ==
               trip_options(ctx, "12", "MKT", :to, nil)
    end
  end

  defp search(ctx, query),
    do: Transfers.search_stops(ctx.organization.id, ctx.version.id, query)

  defp fetch_stop(ctx, stop_id),
    do: Transfers.fetch_pickable_stop(ctx.organization.id, ctx.version.id, stop_id)

  defp route_options(ctx, stop_id, current),
    do: Transfers.route_options(ctx.organization.id, ctx.version.id, stop_id, current)

  defp trip_options(ctx, route_id, stop_id, side, current),
    do:
      Transfers.trip_options(
        ctx.organization.id,
        ctx.version.id,
        route_id,
        stop_id,
        side,
        current
      )

  defp set_platform_code(ctx, stop_id, platform_code) do
    Repo.update_all(
      from(s in Stop,
        where:
          s.organization_id == ^ctx.organization.id and
            s.gtfs_version_id == ^ctx.version.id and s.stop_id == ^stop_id
      ),
      set: [platform_code: platform_code]
    )
  end
end
