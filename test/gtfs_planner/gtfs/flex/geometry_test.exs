defmodule GtfsPlanner.Gtfs.Flex.GeometryTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  @bowtie %{"type" => "Polygon", "coordinates" => [[[0, 0], [1, 1], [1, 0], [0, 1], [0, 0]]]}
  @clockwise_square %{
    "type" => "Polygon",
    "coordinates" => [[[0, 0], [0, 1], [1, 1], [1, 0], [0, 0]]]
  }

  @nine_decimals %{
    "type" => "Polygon",
    "coordinates" => [
      [
        [-124.051234567, 44.631234567],
        [-124.041234567, 44.631234567],
        [-124.041234567, 44.641234567],
        [-124.051234567, 44.631234567]
      ]
    ]
  }

  describe "normalize/1" do
    test "a self-crossing ring reports its crossing point and a reason" do
      assert {:error, {:invalid, reason, [lon, lat]}} = Geometry.normalize(@bowtie)

      assert is_binary(reason)
      assert reason != ""
      assert_in_delta lon, 0.5, 1.0e-6
      assert_in_delta lat, 0.5, 1.0e-6
    end

    test "a GeoJSON binary is decoded, and a broken one is unreadable" do
      assert {:error, {:invalid, _reason, [lon, lat]}} =
               Geometry.normalize(Jason.encode!(@bowtie))

      assert_in_delta lon, 0.5, 1.0e-6
      assert_in_delta lat, 0.5, 1.0e-6

      assert {:error, :unreadable} = Geometry.normalize("{not json")
    end

    test "a clockwise square comes back counterclockwise as a MultiPolygon" do
      assert shoelace(@clockwise_square) < 0

      assert {:ok, %{geojson: geojson, vertices: 5}} = Geometry.normalize(@clockwise_square)
      assert geojson["type"] == "MultiPolygon"
      assert [polygon] = geojson["coordinates"]
      assert [exterior] = polygon
      assert shoelace(exterior) > 0
      assert hd(exterior) == List.last(exterior)
    end

    test "5,001 positions are rejected and 5,000 are accepted" do
      assert position_count(circle(5_000)) == 5_000
      assert position_count(circle(5_001)) == 5_001

      assert {:ok, %{vertices: 5_000, geojson: %{"type" => "MultiPolygon"}}} =
               Geometry.normalize(circle(5_000))

      assert {:error, :too_many_vertices} = Geometry.normalize(circle(5_001))
    end

    test "swapped coordinates are reported only when swapping would fix them" do
      swapped = %{
        "type" => "Polygon",
        "coordinates" => [
          [
            [44.631234, -124.051234],
            [44.631234, -124.041234],
            [44.641234, -124.041234],
            [44.631234, -124.051234]
          ]
        ]
      }

      assert {:error, :swapped_coordinates} = Geometry.normalize(swapped)

      # East of 90° longitude: the longitude slot is beyond 90 but the latitude is
      # fine, so this is not a swapped file.
      china = %{
        "type" => "Polygon",
        "coordinates" => [
          [[120.5, 44.6], [120.6, 44.6], [120.6, 44.7], [120.5, 44.6]]
        ]
      }

      assert {:ok, %{geojson: %{"type" => "MultiPolygon"}}} = Geometry.normalize(china)
    end

    test "anything that is not one closed polygon is rejected" do
      line = %{
        "type" => "Feature",
        "properties" => %{},
        "geometry" => %{"type" => "LineString", "coordinates" => [[0, 0], [1, 1]]}
      }

      point = %{
        "type" => "Feature",
        "properties" => %{},
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]}
      }

      assert {:error, :not_polygon} = Geometry.normalize(line)
      assert {:error, :not_polygon} = Geometry.normalize(point)

      assert {:error, :not_polygon} =
               Geometry.normalize(%{"type" => "GeometryCollection", "geometries" => []})

      assert {:error, :not_polygon} =
               Geometry.normalize(%{"type" => "Feature", "properties" => %{}, "geometry" => nil})

      assert {:error, :not_polygon} =
               Geometry.normalize(%{"type" => "Polygon", "coordinates" => []})

      # A structurally polygonal ring PostGIS itself rejects: it reports no problem
      # location, so the first submitted position is the marker.
      assert {:error, {:invalid, reason, [0, 0]}} =
               Geometry.normalize(%{"type" => "Polygon", "coordinates" => [[[0, 0], [0, 1]]]})

      assert is_binary(reason)
      assert reason != ""

      collection = %{
        "type" => "FeatureCollection",
        "features" => [
          %{
            "type" => "Feature",
            "properties" => %{"name" => "North"},
            "geometry" => @clockwise_square
          },
          %{"type" => "Feature", "properties" => %{"name" => "South"}, "geometry" => @bowtie}
        ]
      }

      assert {:error, :not_polygon} = Geometry.normalize(collection)

      assert {:ok, %{geojson: %{"type" => "MultiPolygon"}}} =
               Geometry.normalize(%{collection | "features" => [hd(collection["features"])]})
    end

    test "a valid shape with nine decimals stays valid through export_geojson/1" do
      assert {:ok, %{geojson: geojson}} = Geometry.normalize(@nine_decimals)

      exported = Geometry.export_geojson(@nine_decimals)
      assert position_count(exported) == position_count(@nine_decimals)

      assert Enum.all?(coordinates(exported), fn value -> value == Float.round(value, 6) end)
      assert Enum.any?(coordinates(exported), fn value -> value != 0 end)

      # The re-read output is what PostGIS would store, and it is still valid.
      assert {:ok, %{geojson: re_read}} = Geometry.normalize(exported)
      assert re_read["type"] == "MultiPolygon"

      assert {:ok, %{geojson: exported_geometry}} = Geometry.normalize(geojson)
      assert position_count(exported_geometry) == position_count(geojson)
    end
  end

  describe "simplify/2" do
    test "a dense polygon loses vertices and keeps its hole" do
      dense = dense_with_hole()

      assert position_count(dense) > 100
      assert {:ok, simplified} = Geometry.simplify(dense, 20)

      assert simplified["type"] == "Polygon"
      assert [exterior, hole] = simplified["coordinates"]
      assert length(exterior) >= 4
      assert length(hole) >= 4
      assert hd(exterior) == List.last(exterior)
      assert hd(hole) == List.last(hole)
      assert position_count(simplified) < position_count(dense)

      assert {:ok, %{geojson: %{"type" => "MultiPolygon"}}} = Geometry.normalize(simplified)
    end
  end

  describe "put_geom/2 and get_geojson/1" do
    test "geometry round-trips through flex_areas.geom and absent geometry is left out" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      service = insert_service(organization, version)
      area = insert_area(service, "a1", 1)

      route_area =
        insert_area(service, "a2", 2, %{"source" => "route_distance", "distance_m" => 800})

      assert {:ok, %{geojson: geojson}} = Geometry.normalize(@clockwise_square)
      assert :ok = Geometry.put_geom(area.id, geojson)

      assert Geometry.get_geojson([area.id]) == %{area.id => geojson}
      assert Geometry.get_geojson([area.id, Ecto.UUID.generate()]) == %{area.id => geojson}
      assert Geometry.get_geojson([route_area.id]) == %{}
      assert Geometry.get_geojson([]) == %{}
    end

    test "writing geometry for an unknown area reports it" do
      assert {:error, :not_found} = Geometry.put_geom(Ecto.UUID.generate(), @clockwise_square)
    end
  end

  defp circle(positions) do
    %{"type" => "Polygon", "coordinates" => [ring(positions, 0.01)]}
  end

  defp dense_with_hole do
    %{
      "type" => "Polygon",
      "coordinates" => [ring(200, 0.01), Enum.reverse(ring(40, 0.002))]
    }
  end

  defp ring(positions, radius) do
    steps = positions - 1

    points =
      for index <- 0..(steps - 1) do
        angle = 2 * :math.pi() * index / steps
        [-124.05 + radius * :math.cos(angle), 44.63 + radius * :math.sin(angle)]
      end

    points ++ [hd(points)]
  end

  defp position_count(%{"type" => "Polygon", "coordinates" => rings}) do
    Enum.sum(Enum.map(rings, &length/1))
  end

  defp position_count(%{"type" => "MultiPolygon", "coordinates" => polygons}) do
    polygons
    |> Enum.flat_map(fn rings -> Enum.map(rings, &length/1) end)
    |> Enum.sum()
  end

  defp coordinates(geojson) do
    geojson |> positions() |> Enum.flat_map(& &1)
  end

  defp positions(%{"type" => "Polygon", "coordinates" => rings}), do: Enum.concat(rings)

  defp positions(%{"type" => "MultiPolygon", "coordinates" => polygons}) do
    polygons |> Enum.concat() |> Enum.concat()
  end

  defp shoelace(%{"type" => "Polygon", "coordinates" => [ring | _rings]}), do: shoelace(ring)

  defp shoelace(ring) do
    ring
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [[x1, y1], [x2, y2]] -> x1 * y2 - x2 * y1 end)
    |> Enum.sum()
  end

  defp insert_service(organization, version) do
    %FlexService{organization_id: organization.id, gtfs_version_id: version.id}
    |> FlexService.create_changeset(%{
      "key" => "service-#{System.unique_integer([:positive])}",
      "name" => "Newport Dial-a-Ride",
      "kind" => "area"
    })
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
end
