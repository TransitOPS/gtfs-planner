defmodule GtfsPlanner.Gtfs.FlexTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # A 0.01° square at 44.6°N: the drawn Newport area of the fixture service.
  @square %{
    "type" => "Polygon",
    "coordinates" => [
      [[-124.05, 44.6], [-124.04, 44.6], [-124.04, 44.61], [-124.05, 44.61], [-124.05, 44.6]]
    ]
  }

  # The same square 0.002° east, used for a save that must roll back.
  @east %{
    "type" => "Polygon",
    "coordinates" => [
      [[-124.048, 44.6], [-124.038, 44.6], [-124.038, 44.61], [-124.048, 44.61], [-124.048, 44.6]]
    ]
  }

  # A self-crossing ring: PostGIS rejects it with a reason and a location.
  @bowtie %{"type" => "Polygon", "coordinates" => [[[0, 0], [1, 1], [1, 0], [0, 1], [0, 0]]]}

  @weekday_a %{area_key: nil, service_id: "weekday", start: "07:00", end: "18:00"}
  @weekday_b %{area_key: nil, service_id: "weekday", start: "08:00", end: "17:00"}

  describe "create_service/3" do
    test "derives the R11 key from the name and suffixes it per version" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      assert {:ok, first} = create(organization, version, "Newport Dial-a-Ride")
      assert first.key == "newport-dial-a-ride"

      assert {:ok, second} = create(organization, version, "Newport Dial-a-Ride")
      assert second.key == "newport-dial-a-ride-2"

      assert {:ok, third} = create(organization, version, "Newport Dial-a-Ride")
      assert third.key == "newport-dial-a-ride-3"

      # Another version and another organization are separate key spaces.
      assert {:ok, sibling} = create(organization, other_version, "Newport Dial-a-Ride")
      assert sibling.key == "newport-dial-a-ride"

      assert {:ok, foreign} = create(other_organization, other_org_version, "Newport Dial-a-Ride")
      assert foreign.key == "newport-dial-a-ride"
    end

    test "slugifies case, punctuation and separator runs" do
      {organization, version} = scope()

      assert {:ok, service} = create(organization, version, "  Seniors’   Shopper  ")
      assert service.key == "seniors-shopper"
      assert service.name == "Seniors’   Shopper"
    end

    test "derives the key itself, whatever the request's key says" do
      {organization, version} = scope()

      assert {:ok, service} =
               Flex.create_service(organization.id, version.id, %{
                 name: "Newport Dial-a-Ride",
                 kind: :area,
                 key: "mine"
               })

      assert service.key == "newport-dial-a-ride"

      assert {:ok, typed} =
               Flex.create_service(organization.id, version.id, %{
                 "name" => "Toledo Dial-a-Ride",
                 "kind" => "area",
                 "key" => "mine"
               })

      assert typed.key == "toledo-dial-a-ride"
      assert typed.kind == :area
    end

    test "requires a route for a detour, which starts without a distance" do
      {organization, version} = scope()
      route_fixture(organization.id, version.id, %{route_id: "R20"})

      assert {:error, changeset} =
               Flex.create_service(organization.id, version.id, %{
                 name: "Route 20 detour",
                 kind: :detour
               })

      assert %{route_id: [_message]} = errors_on(changeset)

      assert {:ok, detour} =
               Flex.create_service(organization.id, version.id, %{
                 name: "Route 20 detour",
                 kind: :detour,
                 route_id: "R20"
               })

      assert detour.route_id == "R20"
      assert detour.distance_m == nil
      assert detour.key == "route-20-detour"
    end

    test "a name that slugs to nothing is refused, not stored under an empty key" do
      {organization, version} = scope()

      assert {:error, changeset} =
               Flex.create_service(organization.id, version.id, %{name: "!!!", kind: :area})

      assert %{key: [_message]} = errors_on(changeset)
      assert service_count(organization.id, version.id) == 0
    end

    test "an unpublished or foreign version answers :version_unavailable and writes nothing" do
      {organization, version} = scope()
      {other_organization, _other_version} = scope()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      assert {:error, :version_unavailable} =
               Flex.create_service(organization.id, staging.id, %{
                 name: "Newport Dial-a-Ride",
                 kind: :area
               })

      assert {:error, :version_unavailable} =
               Flex.create_service(other_organization.id, version.id, %{
                 name: "Newport Dial-a-Ride",
                 kind: :area
               })

      assert {:error, :version_unavailable} =
               Flex.create_service(organization.id, Ecto.UUID.generate(), %{
                 name: "Newport Dial-a-Ride",
                 kind: :area
               })

      assert service_count(organization.id, staging.id) == 0
      assert service_count(organization.id, version.id) == 0
    end
  end

  describe "save_service/5" do
    test "renames the service without moving its key" do
      {organization, version} = scope()
      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)

      assert {:ok, saved} =
               Flex.save_service(
                 organization.id,
                 version.id,
                 loaded,
                 %{
                   name: "Newport Shuttle",
                   key: "mine"
                 },
                 []
               )

      assert saved.name == "Newport Shuttle"
      assert saved.key == "newport-dial-a-ride"

      {:ok, stored} = Flex.get_service(organization.id, version.id, service.id)
      assert stored.key == "newport-dial-a-ride"
      assert stored.name == "Newport Shuttle"
    end

    test "stores drawn geometry, keeps route-distance geometry NULL, and deletes omitted areas" do
      {organization, version} = scope()
      route_fixture(organization.id, version.id, %{route_id: "R20"})
      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)

      drawn = %{key: "a1", name: "Newport", source: :drawn, geojson: @square}

      moved = %{
        key: "a2",
        name: "Toledo",
        source: :route_distance,
        geojson: nil,
        route_ids: ["R20"],
        distance_m: 800
      }

      assert {:ok, saved} =
               Flex.save_service(organization.id, version.id, loaded, %{name: service.name}, [
                 drawn,
                 moved
               ])

      assert Enum.map(saved.areas, & &1.key) == ["a1", "a2"]
      assert Enum.map(saved.areas, & &1.position) == [1, 2]

      [drawn_area, moved_area] = saved.areas
      assert drawn_area.source == :drawn
      assert moved_area.source == :route_distance
      assert moved_area.route_ids == ["R20"]
      assert moved_area.distance_m == 800

      stored = Geometry.get_geojson([drawn_area.id, moved_area.id])
      assert %{"type" => "MultiPolygon"} = stored[drawn_area.id]
      refute Map.has_key?(stored, moved_area.id)

      # A second save that omits the route-distance area deletes it, and the
      # drawn area keeps its row id and its geometry.
      assert {:ok, thinned} =
               Flex.save_service(organization.id, version.id, saved, %{name: saved.name}, [drawn])

      assert Enum.map(thinned.areas, & &1.key) == ["a1"]
      assert hd(thinned.areas).id == drawn_area.id
      assert area_count(service.id) == 1
      assert Map.has_key?(Geometry.get_geojson([drawn_area.id]), drawn_area.id)
    end

    test "an invalid ring returns {:invalid_area, key, {:invalid, _, _}} and changes nothing" do
      {organization, version} = scope()
      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)

      assert {:ok, saved} =
               Flex.save_service(organization.id, version.id, loaded, %{name: service.name}, [
                 %{key: "a1", name: "Newport", source: :drawn, geojson: @square}
               ])

      assert {:ok, %{geojson: normalized}} = Geometry.normalize(@square)
      [area] = saved.areas

      assert {:error, {:invalid_area, "a2", {:invalid, _reason, [_lon, _lat]}}} =
               Flex.save_service(organization.id, version.id, saved, %{name: "Renamed"}, [
                 %{key: "a1", name: "Newport", source: :drawn, geojson: @east},
                 %{key: "a2", name: "Broken", source: :drawn, geojson: @bowtie}
               ])

      {:ok, stored} = Flex.get_service(organization.id, version.id, service.id)
      assert stored.name == service.name
      assert Enum.map(stored.areas, & &1.key) == ["a1"]
      assert Geometry.get_geojson([area.id])[area.id] == normalized
    end

    test "an incomplete area input returns a changeset error and changes nothing" do
      {organization, version} = scope()
      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)

      assert {:error, changeset} =
               Flex.save_service(organization.id, version.id, loaded, %{name: "Renamed"}, [
                 %{key: "a1", source: :drawn, geojson: @square}
               ])

      assert %{name: [_message]} = errors_on(changeset)
      assert area_count(service.id) == 0

      {:ok, stored} = Flex.get_service(organization.id, version.id, service.id)
      assert stored.name == service.name
    end

    test "a save whose input carries no geometry clears the stored polygon" do
      {organization, version} = scope()
      route_fixture(organization.id, version.id, %{route_id: "R20"})
      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)

      assert {:ok, saved} =
               Flex.save_service(organization.id, version.id, loaded, %{name: service.name}, [
                 %{key: "a1", name: "Newport", source: :drawn, geojson: @square}
               ])

      [area] = saved.areas
      assert Map.has_key?(Geometry.get_geojson([area.id]), area.id)

      assert {:ok, switched} =
               Flex.save_service(organization.id, version.id, saved, %{name: service.name}, [
                 %{
                   key: "a1",
                   name: "Newport",
                   source: :route_distance,
                   geojson: nil,
                   route_ids: ["R20"],
                   distance_m: 800
                 }
               ])

      assert [switched_area] = switched.areas
      assert switched_area.id == area.id
      assert switched_area.source == :route_distance
      assert Geometry.get_geojson([area.id]) == %{}
    end

    test "two sessions: the second save is stale and the first editor's values stay" do
      {organization, version} = scope()
      service = area_service(organization, version)
      session_a = loaded_service(organization, version, service)
      session_b = loaded_service(organization, version, service)

      assert {:ok, _saved} =
               Flex.save_service(
                 organization.id,
                 version.id,
                 session_a,
                 %{hours: [@weekday_a]},
                 []
               )

      assert {:error, :stale} =
               Flex.save_service(
                 organization.id,
                 version.id,
                 session_b,
                 %{
                   name: "Replaced",
                   hours: [@weekday_b]
                 },
                 []
               )

      {:ok, stored} = Flex.get_service(organization.id, version.id, service.id)
      assert stored.name == service.name
      assert Enum.map(stored.hours, &{&1.start, &1.end}) == [{"07:00", "18:00"}]

      # Reloading after the conflict saves (the page's "Use their changes").
      assert {:ok, merged} =
               Flex.save_service(
                 organization.id,
                 version.id,
                 stored,
                 %{name: "Newport Shuttle"},
                 []
               )

      assert merged.name == "Newport Shuttle"
      assert Enum.map(merged.hours, & &1.start) == ["07:00"]
      assert merged.lock_version == 3
    end

    test "keeps another organization's and version's services out of every call" do
      {organization, version} = scope()
      other_version = gtfs_version_fixture(organization.id)
      {other_organization, other_org_version} = scope()

      service = area_service(organization, version)
      other_version_service = area_service(organization, other_version, "Toledo Dial-a-Ride")
      other_org_service = area_service(other_organization, other_org_version, "Other Dial-a-Ride")

      assert ids(Flex.list_services(organization.id, version.id)) == [service.id]

      assert ids(Flex.list_services(organization.id, other_version.id)) == [
               other_version_service.id
             ]

      assert ids(Flex.list_services(other_organization.id, other_org_version.id)) == [
               other_org_service.id
             ]

      assert {:error, :not_found} =
               Flex.get_service(other_organization.id, other_org_version.id, service.id)

      assert {:error, :not_found} =
               Flex.get_service(organization.id, other_version.id, service.id)

      loaded = loaded_service(organization, version, service)

      assert {:error, :stale} =
               Flex.save_service(
                 other_organization.id,
                 other_org_version.id,
                 loaded,
                 %{
                   name: "Stolen"
                 },
                 []
               )

      assert {:error, :stale} =
               Flex.save_service(organization.id, other_version.id, loaded, %{name: "Moved"}, [])

      # The unsafe pair (another organization's id with this version's id)
      # fails on the version, before any service lookup.
      assert {:error, :version_unavailable} =
               Flex.save_service(other_organization.id, version.id, loaded, %{name: "Stolen"}, [])

      assert {:error, :not_found} =
               Flex.set_active(other_organization.id, other_org_version.id, service.id, false)

      assert {:error, :not_found} =
               Flex.delete_service(other_organization.id, other_org_version.id, service.id)

      {:ok, unchanged} = Flex.get_service(organization.id, version.id, service.id)
      assert unchanged.name == service.name
      assert unchanged.active
    end

    test "a write against a staging version changes nothing" do
      {organization, version} = scope()
      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      assert {:error, :version_unavailable} =
               Flex.save_service(organization.id, staging.id, loaded, %{name: "Staging save"}, [])

      assert {:error, :version_unavailable} =
               Flex.set_active(organization.id, staging.id, service.id, false)

      assert {:error, :version_unavailable} =
               Flex.delete_service(organization.id, staging.id, service.id)

      assert Flex.list_services(organization.id, staging.id) == []
      assert {:error, :not_found} = Flex.get_service(organization.id, staging.id, service.id)

      {:ok, stored} = Flex.get_service(organization.id, version.id, service.id)
      assert stored.name == service.name
      assert stored.active
    end
  end

  describe "list_services/2 and get_service/3" do
    test "lists services by name and preloads each service's areas in position order" do
      {organization, version} = scope()
      zeta = area_service(organization, version, "Zeta Dial-a-Ride")
      alpha = area_service(organization, version, "Alpha Dial-a-Ride")

      save_areas(organization, version, zeta, [
        %{
          key: "a2",
          name: "Second",
          source: :route_distance,
          route_ids: ["R20"],
          distance_m: 400
        },
        %{key: "a1", name: "First", source: :drawn, geojson: @square}
      ])

      assert Enum.map(Flex.list_services(organization.id, version.id), &{&1.name, &1.id}) == [
               {"Alpha Dial-a-Ride", alpha.id},
               {"Zeta Dial-a-Ride", zeta.id}
             ]

      {:ok, loaded} = Flex.get_service(organization.id, version.id, zeta.id)
      assert Enum.map(loaded.areas, & &1.key) == ["a2", "a1"]
      assert Enum.map(loaded.areas, & &1.position) == [1, 2]

      [listed] =
        Flex.list_services(organization.id, version.id) |> Enum.filter(&(&1.id == zeta.id))

      assert Enum.map(listed.areas, & &1.key) == ["a2", "a1"]
    end

    test "answers not found for an unknown or malformed service id" do
      {organization, version} = scope()

      assert {:error, :not_found} =
               Flex.get_service(organization.id, version.id, Ecto.UUID.generate())

      assert {:error, :not_found} = Flex.get_service(organization.id, version.id, "not-a-uuid")
      assert {:error, :not_found} = Flex.get_service(organization.id, version.id, nil)
    end
  end

  describe "set_active/4 and delete_service/3" do
    test "deactivating keeps the setup and deleting removes the service and its areas" do
      {organization, version} = scope()
      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)

      assert {:ok, saved} =
               Flex.save_service(
                 organization.id,
                 version.id,
                 loaded,
                 %{
                   hours: [@weekday_a],
                   booking_rules: [%{service_id: nil, when: :earlier_day, days: 1, by: "16:00"}],
                   phone: "(541) 555-0142"
                 },
                 [%{key: "a1", name: "Newport", source: :drawn, geojson: @square}]
               )

      assert {:ok, inactive} = Flex.set_active(organization.id, version.id, saved.id, false)
      refute inactive.active
      assert Enum.map(inactive.areas, & &1.key) == ["a1"]
      assert inactive.phone == "(541) 555-0142"

      {:ok, stored} = Flex.get_service(organization.id, version.id, saved.id)
      refute stored.active
      assert Enum.map(stored.hours, &{&1.start, &1.end}) == [{"07:00", "18:00"}]
      assert [%{days: 1, by: "16:00"}] = stored.booking_rules
      assert [%{key: "a1", source: :drawn}] = stored.areas
      assert Map.has_key?(Geometry.get_geojson([hd(stored.areas).id]), hd(stored.areas).id)

      assert {:ok, active} = Flex.set_active(organization.id, version.id, saved.id, true)
      assert active.active

      assert :ok = Flex.delete_service(organization.id, version.id, saved.id)
      assert {:error, :not_found} = Flex.get_service(organization.id, version.id, saved.id)
      assert area_count(service.id) == 0
      assert service_count(organization.id, version.id) == 0
      assert {:error, :not_found} = Flex.delete_service(organization.id, version.id, saved.id)
    end

    test "saving one service leaves another service's areas alone" do
      {organization, version} = scope()
      route_fixture(organization.id, version.id, %{route_id: "R20"})
      first = area_service(organization, version, "First Dial-a-Ride")
      second = area_service(organization, version, "Second Dial-a-Ride")

      save_areas(organization, version, second, [
        %{key: "a1", name: "Second area", source: :drawn, geojson: @square}
      ])

      {:ok, second_stored} = Flex.get_service(organization.id, version.id, second.id)
      [second_area] = second_stored.areas

      {:ok, first_loaded} = Flex.get_service(organization.id, version.id, first.id)
      assert {:ok, _saved} = Flex.save_service(organization.id, version.id, first_loaded, %{}, [])

      {:ok, second_after} = Flex.get_service(organization.id, version.id, second.id)
      assert Enum.map(second_after.areas, & &1.id) == [second_area.id]
      assert Map.has_key?(Geometry.get_geojson([second_area.id]), second_area.id)
    end
  end

  describe "derived-only flex rows (R1, CR-4)" do
    test "creating, saving, deactivating and deleting services touch no trips or stop_times" do
      {organization, version} = scope()
      route_fixture(organization.id, version.id, %{route_id: "R20"})
      stop_fixture(organization.id, version.id, %{stop_id: "S1"})
      trip_fixture(organization.id, version.id, "R20", %{trip_id: "T1"})
      stop_time_fixture(organization.id, version.id, "T1", "S1")

      before = %{
        trips: scoped_count(Trip, organization.id, version.id),
        stop_times: scoped_count(StopTime, organization.id, version.id)
      }

      service = area_service(organization, version)
      loaded = loaded_service(organization, version, service)

      {:ok, saved} =
        Flex.save_service(organization.id, version.id, loaded, %{hours: [@weekday_a]}, [
          %{key: "a1", name: "Newport", source: :drawn, geojson: @square}
        ])

      {:ok, _inactive} = Flex.set_active(organization.id, version.id, saved.id, false)
      assert :ok = Flex.delete_service(organization.id, version.id, saved.id)

      assert scoped_count(Trip, organization.id, version.id) == before.trips
      assert scoped_count(StopTime, organization.id, version.id) == before.stop_times
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {organization, version}
  end

  defp create(organization, version, name) do
    Flex.create_service(organization.id, version.id, %{name: name, kind: :area})
  end

  defp area_service(organization, version, name \\ "Newport Dial-a-Ride") do
    {:ok, service} = create(organization, version, name)
    service
  end

  defp loaded_service(organization, version, service) do
    {:ok, loaded} = Flex.get_service(organization.id, version.id, service.id)
    loaded
  end

  defp save_areas(organization, version, service, inputs) do
    loaded = loaded_service(organization, version, service)
    {:ok, saved} = Flex.save_service(organization.id, version.id, loaded, %{}, inputs)
    saved
  end

  defp ids(services), do: Enum.map(services, & &1.id)

  defp area_count(flex_service_id) do
    Repo.aggregate(from(a in FlexArea, where: a.flex_service_id == ^flex_service_id), :count)
  end

  defp service_count(organization_id, version_id) do
    Repo.aggregate(
      from(s in FlexService,
        where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id
      ),
      :count
    )
  end

  defp scoped_count(schema, organization_id, version_id) do
    Repo.aggregate(
      from(row in schema,
        where: row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id
      ),
      :count
    )
  end
end
