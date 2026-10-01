defmodule GtfsPlanner.Gtfs.Flex.GeometryStatsTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  # A 0.01° square at 44.6°N: about 0.88 km² measured on geography.
  @square %{
    "type" => "Polygon",
    "coordinates" => [
      [[-124.05, 44.6], [-124.04, 44.6], [-124.04, 44.61], [-124.05, 44.61], [-124.05, 44.6]]
    ]
  }

  # The same square with its eastern edge pulled back, so S3 (-124.04) falls
  # outside and S1 (-124.045) stays inside.
  @shrunk %{
    "type" => "Polygon",
    "coordinates" => [
      [[-124.05, 44.6], [-124.044, 44.6], [-124.044, 44.61], [-124.05, 44.61], [-124.05, 44.6]]
    ]
  }

  describe "stats/3" do
    test "measures a square and lists the stops inside it, including one on the boundary" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_stop(organization, version, "S1", "-124.045", "44.605")
      insert_stop(organization, version, "S2", "-124.06", "44.605")
      insert_stop(organization, version, "S3", "-124.04", "44.605")
      insert_stop(organization, version, "S4", nil, nil)

      stats = Geometry.stats(organization.id, version.id, @square)

      assert stats.stop_ids == ["S1", "S3"]
      assert stats.route_ids == []

      # The km² is the geography area, not the planar area of 0.01° squares
      # (which would be 1.0e-4) and not a projected area.
      %Postgrex.Result{rows: [[geography_km2]]} =
        Repo.query!("SELECT ST_Area(ST_GeomFromGeoJSON($1)::geography) / 1e6", [
          Jason.encode!(@square)
        ])

      assert_in_delta stats.km2, geography_km2, geography_km2 * 0.001
      assert_in_delta stats.km2, 0.88, 0.01

      # The editor normalises first (step 25), so a stored-ready MultiPolygon
      # measures the same.
      assert {:ok, %{geojson: normalized}} = Geometry.normalize(@square)
      normalized_stats = Geometry.stats(organization.id, version.id, normalized)

      assert normalized_stats.stop_ids == ["S1", "S3"]
      assert normalized_stats.route_ids == []
      assert_in_delta normalized_stats.km2, stats.km2, 0.000_001
    end

    test "lists exactly the routes whose trips visit a covered stop" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_stop(organization, version, "S1", "-124.045", "44.605")
      insert_stop(organization, version, "S2", "-124.06", "44.605")
      insert_stop(organization, version, "S3", "-124.04", "44.605")

      insert_route_with_trip(organization, version, "R1", "T1", ["S1"])
      insert_route_with_trip(organization, version, "R2", "T2", ["S2"])
      # T3 visits a covered stop (S3) and an uncovered one (S2): the route
      # counts once, and the uncovered stop does not add a route.
      insert_route_with_trip(organization, version, "R3", "T3", ["S3", "S2"])

      stats = Geometry.stats(organization.id, version.id, @square)

      assert stats.stop_ids == ["S1", "S3"]
      assert stats.route_ids == ["R1", "R3"]
    end

    test "keeps another version's and another organization's stops and routes out" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      insert_stop(organization, version, "S1", "-124.045", "44.605")
      insert_route_with_trip(organization, version, "R1", "T1", ["S1"])

      # The same natural IDs in a sibling version of the same organization.
      insert_stop(organization, other_version, "S1", "-124.045", "44.605")

      insert_route_with_trip(
        organization,
        other_version,
        "R-other-version",
        "T-other-version",
        ["S1"]
      )

      # The same natural IDs in another organization.
      insert_stop(other_organization, other_org_version, "S1", "-124.045", "44.605")

      insert_route_with_trip(
        other_organization,
        other_org_version,
        "R-other-org",
        "T-other-org",
        ["S1"]
      )

      stats = Geometry.stats(organization.id, version.id, @square)

      assert stats.stop_ids == ["S1"]
      assert stats.route_ids == ["R1"]
    end
  end

  describe "overlaps/4" do
    test "returns intersecting active area services at or above 0.5 km²" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      edited = insert_area_service(organization, version, "Edited", %{})
      put_area(edited, "a1", 1, @square)

      # Shifted 0.002° east: 80% of the square, about 0.71 km².
      overlapping = insert_area_service(organization, version, "Overlapping area", %{})
      put_area(overlapping, "a1", 1, shift_east(@square, 0.002))

      # Shifted 0.009° east: about 0.09 km², below the threshold.
      below = insert_area_service(organization, version, "Below threshold", %{})
      put_area(below, "a1", 1, shift_east(@square, 0.009))

      # Shifted 0.05° east: no intersection at all.
      disjoint = insert_area_service(organization, version, "Disjoint", %{})
      put_area(disjoint, "a1", 1, shift_east(@square, 0.05))

      # Two disjoint areas, each about 0.30 km² inside the draft: the service
      # counts once, by its union, so it clears the 0.5 km² threshold.
      split = insert_area_service(organization, version, "Split", %{})
      put_area(split, "a1", 1, shift_east(@square, 0.0066))
      put_area(split, "a2", 2, shift_east(@square, -0.0066))

      # Two identical areas: the union counts once, not the same 0.71 km² twice.
      double = insert_area_service(organization, version, "Double", %{})
      put_area(double, "a1", 1, shift_east(@square, 0.002))
      put_area(double, "a2", 2, shift_east(@square, 0.002))

      inactive = insert_area_service(organization, version, "Inactive area", %{"active" => false})
      put_area(inactive, "a1", 1, @square)

      detour =
        insert_area_service(organization, version, "Detour service", %{
          "kind" => "detour",
          "route_id" => "R1"
        })

      put_area(detour, "a1", 1, @square)

      # A route-distance area stores no geometry and must not break the query.
      no_geometry = insert_area_service(organization, version, "No geometry", %{})

      insert_area(no_geometry, "a1", 1, %{
        "source" => "route_distance",
        "distance_m" => 800
      })

      # An area service of another organization over the same square is not listed.
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_service = insert_area_service(foreign_organization, foreign_version, "Foreign", %{})
      put_area(foreign_service, "a1", 1, @square)

      # A row that claims this organization and version but points at a service
      # in another scope cannot exist: the ownership constraint refuses it.
      assert_raise Ecto.ConstraintError, ~r/flex_areas_flex_services_owner_fkey/, fn ->
        %FlexArea{
          flex_service_id: foreign_service.id,
          organization_id: organization.id,
          gtfs_version_id: version.id
        }
        |> FlexArea.changeset(%{
          "key" => "a2",
          "position" => 2,
          "name" => "Cross-scope area",
          "source" => "drawn"
        })
        |> Repo.insert!()
      end

      results = Geometry.overlaps(organization.id, version.id, @square, edited.id)

      assert Enum.map(results, & &1.name) == ["Double", "Overlapping area", "Split"]

      assert %{service_id: service_id, km2: km2} =
               Enum.find(results, &(&1.name == "Overlapping area"))

      assert service_id == overlapping.id
      assert_in_delta km2, 0.71, 0.02

      assert %{km2: split_km2} = Enum.find(results, &(&1.name == "Split"))
      assert_in_delta split_km2, 0.60, 0.02

      assert %{km2: double_km2} = Enum.find(results, &(&1.name == "Double"))
      assert_in_delta double_km2, 0.71, 0.02

      # Without an exclusion the edited service is measured too, and the order
      # is stable by name.
      all = Geometry.overlaps(organization.id, version.id, @square, nil)

      assert Enum.map(all, & &1.name) == ["Double", "Edited", "Overlapping area", "Split"]

      assert Enum.map(all, & &1.service_id) == [double.id, edited.id, overlapping.id, split.id]

      # Excluding another service leaves the rest.
      excluded = Geometry.overlaps(organization.id, version.id, @square, overlapping.id)
      assert Enum.map(excluded, & &1.name) == ["Double", "Edited", "Split"]
      assert Enum.map(excluded, & &1.service_id) == [double.id, edited.id, split.id]

      assert below.id not in Enum.map(all, & &1.service_id)
      assert disjoint.id not in Enum.map(all, & &1.service_id)
      assert inactive.id not in Enum.map(all, & &1.service_id)
      assert detour.id not in Enum.map(all, & &1.service_id)
      assert no_geometry.id not in Enum.map(all, & &1.service_id)
      assert foreign_service.id not in Enum.map(all, & &1.service_id)
    end
  end

  describe "compare/2" do
    test "a new area has nothing before and joins every stop in the draft" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_stop(organization, version, "S1", "-124.045", "44.605")
      insert_stop(organization, version, "S3", "-124.04", "44.605")

      draft = Geometry.stats(organization.id, version.id, @square)
      comparison = Geometry.compare(nil, draft)

      assert comparison.km2_before == 0.0
      assert comparison.km2_after == draft.km2
      assert comparison.stops_joined == ["S1", "S3"]
      assert comparison.stops_left == []
    end

    test "a shrunk area reports the stop that fell outside" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_stop(organization, version, "S1", "-124.045", "44.605")
      insert_stop(organization, version, "S3", "-124.04", "44.605")

      saved = Geometry.stats(organization.id, version.id, @square)
      draft = Geometry.stats(organization.id, version.id, @shrunk)

      assert saved.stop_ids == ["S1", "S3"]
      assert draft.stop_ids == ["S1"]

      comparison = Geometry.compare(saved, draft)

      assert comparison.km2_before == saved.km2
      assert comparison.km2_after == draft.km2
      assert comparison.km2_after < comparison.km2_before
      assert comparison.stops_left == ["S3"]
      assert comparison.stops_joined == []
    end

    test "a side with geometry but no measured km² is measured here" do
      comparison =
        Geometry.compare(
          %{geojson: @square, stop_ids: ["S1", "S3"]},
          %{geojson: @shrunk, stop_ids: ["S1"]}
        )

      %Postgrex.Result{rows: [[square_km2]]} =
        Repo.query!("SELECT ST_Area(ST_GeomFromGeoJSON($1)::geography) / 1e6", [
          Jason.encode!(@square)
        ])

      assert_in_delta comparison.km2_before, square_km2, square_km2 * 0.001
      assert comparison.km2_before > comparison.km2_after
      assert comparison.stops_left == ["S3"]
      assert comparison.stops_joined == []
    end
  end

  defp insert_stop(organization, version, stop_id, lon, lat) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_lon: lon && Decimal.new(lon),
      stop_lat: lat && Decimal.new(lat)
    })
  end

  defp insert_route_with_trip(organization, version, route_id, trip_id, stop_ids) do
    route = route_fixture(organization.id, version.id, %{route_id: route_id})
    trip = trip_fixture(organization.id, version.id, route.route_id, %{trip_id: trip_id})

    Enum.each(stop_ids, fn stop_id ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, stop_id)
    end)

    route
  end

  defp insert_area_service(organization, version, name, attrs) do
    attrs =
      Map.merge(
        %{
          "key" => "service-#{System.unique_integer([:positive])}",
          "name" => name,
          "kind" => "area",
          "active" => true
        },
        attrs
      )

    %FlexService{organization_id: organization.id, gtfs_version_id: version.id}
    |> FlexService.create_changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_area(service, key, position, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{"key" => key, "position" => position, "name" => "Area #{key}", "source" => "drawn"},
        attrs
      )

    %FlexArea{
      flex_service_id: service.id,
      organization_id: service.organization_id,
      gtfs_version_id: service.gtfs_version_id
    }
    |> FlexArea.changeset(attrs)
    |> Repo.insert!()
  end

  defp put_area(service, key, position, geojson) do
    area = insert_area(service, key, position)
    :ok = Geometry.put_geom(area.id, geojson)
    area
  end

  defp shift_east(%{"type" => "Polygon", "coordinates" => [ring]} = geojson, degrees) do
    shifted = Enum.map(ring, fn [lon, lat] -> [lon + degrees, lat] end)
    %{geojson | "coordinates" => [shifted]}
  end
end
