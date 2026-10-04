defmodule GtfsPlanner.Gtfs.FareZones.RouteSelectionTest do
  @moduledoc """
  Merge evidence (EV-1) for `FareZones.route_selection/3`: the boardable stops a
  route selection means, with exclusions, the only-unzoned filter, serving routes,
  caps and scope isolation.

  Every expected literal is hand-derived from `GtfsPlanner.FareSelectionFixtures`
  (routes R6 and R9, stops A1 to AIR2, trips T6 and T9), not from the query. A
  twin organization and a second version of the same organization carry the same
  route and stop IDs, so a missing scope predicate doubles or leaks rows.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.VersionsFixtures

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)
    stops = FareSelectionFixtures.insert_network!(organization, version)

    %{organization: organization, version: version, stops: stops}
  end

  defp selection(organization, version, route_ids, opts \\ []) do
    FareZones.route_selection(organization.id, version.id, %{
      route_ids: route_ids,
      only_unzoned?: Keyword.get(opts, :only_unzoned?, false),
      exclude_stop_ids: Keyword.get(opts, :exclude, [])
    })
  end

  test "only-unzoned R6 minus AIR1 returns A1 and A3 with the counts and serving routes", %{
    organization: organization,
    version: version,
    stops: stops
  } do
    assert {:ok, selection} =
             selection(organization, version, ["R6"], only_unzoned?: true, exclude: ["AIR1"])

    assert selection.routes == [
             %{route_id: "R6", route_short_name: "6", route_long_name: "Route Six"}
           ]

    assert selection.served_count == 4
    assert selection.already_zoned_count == 1
    assert selection.excluded == [%{stop_id: "AIR1", stop_name: "Airport Gate"}]
    assert selection.unmatched_exclusions == []
    assert selection.route_names == %{"R6" => "6", "R9" => "9"}

    assert selection.stops == [
             %{
               id: stops["A1"].id,
               stop_id: "A1",
               stop_name: "Alder",
               zone_id: nil,
               route_ids: ["R6"]
             },
             %{
               id: stops["A3"].id,
               stop_id: "A3",
               stop_name: "Cedar",
               zone_id: nil,
               route_ids: ["R6", "R9"]
             }
           ]
  end

  test "without the unzoned filter every served stop is selected, never the station or the unserved stop",
       %{organization: organization, version: version} do
    assert {:ok, selection} = selection(organization, version, ["R6"])

    assert Enum.map(selection.stops, &{&1.stop_id, &1.zone_id}) == [
             {"AIR1", nil},
             {"A1", nil},
             {"A2", "B"},
             {"A3", nil}
           ]

    assert selection.served_count == 4
    assert selection.already_zoned_count == 0
    assert selection.excluded == []
  end

  test "an exclusion that no named route serves is unmatched and changes nothing", %{
    organization: organization,
    version: version
  } do
    assert {:ok, selection} = selection(organization, version, ["R6"], exclude: ["AIR2"])

    assert Enum.map(selection.stops, & &1.stop_id) == ["AIR1", "A1", "A2", "A3"]
    assert selection.unmatched_exclusions == ["AIR2"]
    assert selection.excluded == []
  end

  test "two routes serve the union of their stops once each", %{
    organization: organization,
    version: version
  } do
    assert {:ok, selection} = selection(organization, version, ["R9", "R6", "R9"])

    assert selection.served_count == 5
    assert Enum.map(selection.stops, & &1.stop_id) == ["AIR1", "AIR2", "A1", "A2", "A3"]
    assert Enum.map(selection.routes, & &1.route_id) == ["R9", "R6"]
  end

  test "an excluded stop leaves the selection before the unzoned filter counts it", %{
    organization: organization,
    version: version
  } do
    assert {:ok, selection} =
             selection(organization, version, ["R6"], only_unzoned?: true, exclude: ["A2"])

    assert selection.already_zoned_count == 0
    assert selection.excluded == [%{stop_id: "A2", stop_name: "Birch"}]
    assert Enum.map(selection.stops, & &1.stop_id) == ["AIR1", "A1", "A3"]
  end

  describe "refusals" do
    test "no routes, more than five routes and an unknown route", %{
      organization: organization,
      version: version
    } do
      assert selection(organization, version, []) == {:error, :no_routes}

      assert selection(organization, version, ~w(R1 R2 R3 R4 R5 R6)) == {:error, :too_many_routes}

      assert selection(organization, version, ["R6", "NOPE"]) ==
               {:error, {:unknown_route, "NOPE"}}
    end

    test "an unknown stop and a station are not exclusions", %{
      organization: organization,
      version: version
    } do
      assert selection(organization, version, ["R6"], exclude: ["GHOST"]) ==
               {:error, {:unknown_stop, "GHOST"}}

      assert selection(organization, version, ["R6"], exclude: ["S1"]) ==
               {:error, {:unknown_stop, "S1"}}
    end

    test "more than 100 exclusions", %{organization: organization, version: version} do
      exclusions = Enum.map(1..101, &"X#{&1}")

      assert selection(organization, version, ["R6"], exclude: exclusions) ==
               {:error, :too_many_exclusions}
    end

    test "more than 1,000 served stops reports the count", %{
      organization: organization,
      version: version
    } do
      names = Enum.map(1..1001, &"B#{&1}")

      GtfsPlanner.GtfsFixtures.route_fixture(organization.id, version.id, %{route_id: "RBIG"})
      FareSelectionFixtures.insert_stops!(organization, version, Enum.map(names, &%{stop_id: &1}))
      FareSelectionFixtures.call_at!(organization, version, "RBIG", "T-BIG", names)

      assert selection(organization, version, ["RBIG"]) == {:error, {:too_many_stops, 1001}}
    end
  end

  test "an empty zone ID is a zone value, so the stop counts as zoned", %{
    organization: organization,
    version: version
  } do
    FareSelectionFixtures.insert_stops!(organization, version, [
      %{stop_id: "E1", stop_name: "Empty", zone_id: ""}
    ])

    FareSelectionFixtures.call_at!(organization, version, "R9", "T-E", ["E1"])

    assert {:ok, selection} = selection(organization, version, ["R9"], only_unzoned?: true)

    assert Enum.map(selection.stops, & &1.stop_id) == ["AIR2", "A3"]
    assert selection.already_zoned_count == 1
    assert selection.served_count == 3
  end

  test "a route with no stop_times serves nothing", %{
    organization: organization,
    version: version
  } do
    GtfsPlanner.GtfsFixtures.route_fixture(organization.id, version.id, %{route_id: "R0"})

    assert {:ok, selection} = selection(organization, version, ["R0"])
    assert selection.served_count == 0
    assert selection.stops == []
  end

  test "a twin organization and a second version return only their own stops", %{
    organization: organization,
    version: version,
    stops: stops
  } do
    twin_organization = OrganizationsFixtures.organization_fixture()
    twin_version = VersionsFixtures.gtfs_version_fixture(twin_organization.id)
    twin_stops = FareSelectionFixtures.insert_network!(twin_organization, twin_version)

    second_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    second_stops = FareSelectionFixtures.insert_network!(organization, second_version)

    assert {:ok, original} = selection(organization, version, ["R6"])
    assert {:ok, twin} = selection(twin_organization, twin_version, ["R6"])
    assert {:ok, second} = selection(organization, second_version, ["R6"])

    assert Enum.map(original.stops, & &1.id) ==
             Enum.map(["AIR1", "A1", "A2", "A3"], &stops[&1].id)

    assert Enum.map(twin.stops, & &1.id) ==
             Enum.map(["AIR1", "A1", "A2", "A3"], &twin_stops[&1].id)

    assert Enum.map(second.stops, & &1.id) ==
             Enum.map(["AIR1", "A1", "A2", "A3"], &second_stops[&1].id)

    assert original.served_count == 4
    assert twin.served_count == 4
    assert second.served_count == 4
  end
end
