defmodule GtfsPlanner.Gtfs.Flex.GeometryDerivedTest do
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  @route_id "R"
  @out_south 44.60
  @in_north 44.61
  @short_middle 44.59

  describe "route_buffer/4" do
    test "buffers a route's shapes and measures them on geography" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, version.id, %{route_id: @route_id})

      trip_fixture(organization.id, version.id, @route_id, %{
        trip_id: "T-20-0712",
        shape_id: "shape-out"
      })

      insert_shape(organization, version, "shape-out", [
        {"-124.00", "44.60", 1, 0},
        {"-124.02", "44.60", 2, 2000}
      ])

      assert {:ok, geojson} = Geometry.route_buffer(organization.id, version.id, [@route_id], 400)

      assert geojson["type"] == "MultiPolygon"
      assert valid?(geojson)

      # The expectation is the buffered literal line, measured independently.
      %Postgrex.Result{rows: [[expected_km2]]} =
        Repo.query!("""
        SELECT ST_Area(
                 ST_Buffer(ST_GeomFromText('LINESTRING(-124.00 44.60, -124.02 44.60)', 4326)::geography,
                           400)::geometry::geography
               ) / 1e6
        """)

      assert_in_delta km2(geojson), expected_km2, expected_km2 * 0.02
    end

    test "unions the shapes of every chosen route" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, version.id, %{route_id: @route_id})
      route_fixture(organization.id, version.id, %{route_id: "R2"})

      trip_fixture(organization.id, version.id, @route_id, %{
        trip_id: "T-20-0712",
        shape_id: "shape-out"
      })

      trip_fixture(organization.id, version.id, "R2", %{
        trip_id: "T-20-0713",
        shape_id: "shape-in"
      })

      insert_shape(organization, version, "shape-out", [
        {"-124.00", "44.60", 1, 0},
        {"-124.02", "44.60", 2, 2000}
      ])

      insert_shape(organization, version, "shape-in", [
        {"-124.00", "44.61", 1, 0},
        {"-124.02", "44.61", 2, 2000}
      ])

      assert {:ok, geojson} =
               Geometry.route_buffer(organization.id, version.id, [@route_id, "R2"], 400)

      # Two disjoint buffers in one MultiPolygon.
      assert geojson["type"] == "MultiPolygon"
      assert length(geojson["coordinates"]) == 2

      assert buffer_equals?(geojson, [
               "LINESTRING(-124.00 44.60, -124.02 44.60)",
               "LINESTRING(-124.00 44.61, -124.02 44.61)"
             ])
    end

    test "answers unknown routes and routes whose trips carry no shape" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, version.id, %{route_id: @route_id})

      trip_fixture(organization.id, version.id, @route_id, %{
        trip_id: "T-20-0712",
        shape_id: nil
      })

      assert {:error, {:missing_routes, ["X"]}} =
               Geometry.route_buffer(organization.id, version.id, [@route_id, "X"], 400)

      assert {:error, :empty} =
               Geometry.route_buffer(organization.id, version.id, [@route_id], 400)

      # A shape ID no shape row answers is the same empty answer.
      trip_fixture(organization.id, version.id, @route_id, %{
        trip_id: "T-20-0713",
        shape_id: "shape-gone"
      })

      assert {:error, :empty} =
               Geometry.route_buffer(organization.id, version.id, [@route_id], 400)
    end

    test "keeps another version's and another organization's shapes out" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      route_fixture(organization.id, version.id, %{route_id: @route_id})

      trip_fixture(organization.id, version.id, @route_id, %{
        trip_id: "T-20-0712",
        shape_id: "shape-here"
      })

      insert_shape(organization, version, "shape-here", [
        {"-124.00", "44.60", 1, 0},
        {"-124.02", "44.60", 2, 2000}
      ])

      # The same route ID with a different shape in a sibling version, and with
      # the same shape in another organization.
      route_fixture(organization.id, other_version.id, %{route_id: @route_id})

      trip_fixture(organization.id, other_version.id, @route_id, %{
        trip_id: "T-other-version",
        shape_id: "shape-other-version"
      })

      insert_shape(organization, other_version, "shape-other-version", [
        {"-124.00", "44.55", 1, 0},
        {"-124.02", "44.55", 2, 2000}
      ])

      route_fixture(other_organization.id, other_org_version.id, %{route_id: @route_id})

      trip_fixture(other_organization.id, other_org_version.id, @route_id, %{
        trip_id: "T-other-org",
        shape_id: "shape-here"
      })

      insert_shape(other_organization, other_org_version, "shape-here", [
        {"-124.00", "44.55", 1, 0},
        {"-124.02", "44.55", 2, 2000}
      ])

      assert {:ok, geojson} = Geometry.route_buffer(organization.id, version.id, [@route_id], 400)

      assert buffer_equals?(geojson, ["LINESTRING(-124.00 44.60, -124.02 44.60)"], 400)
    end
  end

  describe "detour_zones/3" do
    test "gives one zone per unordered pair across both directions and a short turn" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_route_stops(organization, version)

      # Outbound along 44.60, inbound along 44.61, a short turn along 44.59.
      insert_shape(organization, version, "shape-out", [
        {"-124.00", "#{@out_south}", 1, 0},
        {"-124.01", "#{@out_south}", 2, 1000},
        {"-124.02", "#{@out_south}", 3, 2000}
      ])

      insert_shape(organization, version, "shape-in", [
        {"-124.02", "#{@in_north}", 1, 0},
        {"-124.01", "#{@in_north}", 2, 1000},
        {"-124.00", "#{@in_north}", 3, 2000}
      ])

      insert_shape(organization, version, "shape-short", [
        {"-124.00", "#{@short_middle}", 1, 0},
        {"-124.01", "#{@short_middle}", 2, 1000}
      ])

      insert_pattern(organization, version, "pattern-out", "shape-out", [
        {"A", 1, 0},
        {"B", 2, 1000},
        {"C", 3, 2000}
      ])

      insert_pattern(organization, version, "pattern-in", "shape-in", [
        {"C", 1, 0},
        {"B", 2, 1000},
        {"A", 3, 2000}
      ])

      insert_pattern(organization, version, "pattern-short", "shape-short", [
        {"A", 1, 0},
        {"B", 2, 1000}
      ])

      service = detour_service(organization, version, %{"key" => "valley"})

      assert {:ok, zones} = Geometry.detour_zones(organization.id, version.id, service)

      assert Enum.map(zones, & &1.zone_id) == ["flex-valley-A-B", "flex-valley-B-C"]
      assert Enum.map(zones, &{&1.stop_a, &1.stop_b}) == [{"A", "B"}, {"B", "C"}]

      [a_b, b_c] = zones

      assert Enum.all?(zones, &valid?(&1.geojson))

      # Both directions' segments, plus the short turn's, in one zone.
      assert buffer_equals?(a_b.geojson, [
               "LINESTRING(-124.00 44.60, -124.01 44.60)",
               "LINESTRING(-124.01 44.61, -124.00 44.61)",
               "LINESTRING(-124.00 44.59, -124.01 44.59)"
             ])

      assert buffer_equals?(b_c.geojson, [
               "LINESTRING(-124.01 44.60, -124.02 44.60)",
               "LINESTRING(-124.02 44.61, -124.01 44.61)"
             ])
    end

    test "cuts a loop visit by shape_dist_traveled" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_route_stops(organization, version, ["D"])

      # Out along 44.60 through B, back through B, then north to D: B is visited
      # at positions 2 and 4, and every leg is 0.01° long in the planar shape.
      insert_shape(organization, version, "shape-loop", [
        {"-124.00", "44.60", 1, 0},
        {"-124.01", "44.60", 2, 1000},
        {"-124.02", "44.60", 3, 2000},
        {"-124.01", "44.60", 4, 3000},
        {"-124.01", "44.61", 5, 4000}
      ])

      insert_pattern(organization, version, "pattern-loop", "shape-loop", [
        {"A", 1, 0},
        {"B", 2, 1000},
        {"C", 3, 2000},
        {"B", 4, 3000},
        {"D", 5, 4000}
      ])

      service =
        detour_service(organization, version, %{"key" => "loop", "last_stop_id" => "D"})

      assert {:ok, zones} = Geometry.detour_zones(organization.id, version.id, service)

      assert Enum.map(zones, & &1.zone_id) == [
               "flex-loop-A-B",
               "flex-loop-B-C",
               "flex-loop-B-D"
             ]

      assert Enum.all?(zones, &valid?(&1.geojson))

      # The second visit's distance is what cuts C→B; a located fraction would
      # cut B→C again and leave B→D covered by the whole loop.
      assert %{geojson: b_d} = Enum.find(zones, &(&1.zone_id == "flex-loop-B-D"))
      assert buffer_equals?(b_d, ["LINESTRING(-124.01 44.60, -124.01 44.61)"], 400)

      # The C→B cut retraces the B→C leg, so the zone is about that capsule.
      assert %{geojson: b_c} = Enum.find(zones, &(&1.zone_id == "flex-loop-B-C"))

      assert_in_delta km2(b_c), buffered_km2("LINESTRING(-124.01 44.60, -124.02 44.60)"), 0.01
    end

    test "locates a repeated stop after the previous fraction when distances are absent" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_route_stops(organization, version, ["D"])

      insert_shape(organization, version, "shape-loop", [
        {"-124.00", "44.60", 1, nil},
        {"-124.01", "44.60", 2, nil},
        {"-124.02", "44.60", 3, nil},
        {"-124.01", "44.60", 4, nil},
        {"-124.01", "44.61", 5, nil}
      ])

      insert_pattern(organization, version, "pattern-loop", "shape-loop", [
        {"A", 1, nil},
        {"B", 2, nil},
        {"C", 3, nil},
        {"B", 4, nil},
        {"D", 5, nil}
      ])

      service =
        detour_service(organization, version, %{"key" => "loop", "last_stop_id" => "D"})

      assert {:ok, zones} = Geometry.detour_zones(organization.id, version.id, service)

      assert Enum.map(zones, & &1.zone_id) == [
               "flex-loop-A-B",
               "flex-loop-B-C",
               "flex-loop-B-D"
             ]

      assert Enum.all?(zones, &valid?(&1.geojson))

      # B's second occurrence lies at 0.75 of the shape, so the leg to D is the
      # vertical one. Locking onto B's first occurrence would cut the whole loop.
      assert %{geojson: b_d} = Enum.find(zones, &(&1.zone_id == "flex-loop-B-D"))
      assert buffer_equals?(b_d, ["LINESTRING(-124.01 44.60, -124.01 44.61)"], 400)
    end

    test "uses straight lines between stop points for a pattern without a shape" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_route_stops(organization, version)

      insert_pattern(organization, version, "pattern-plain", nil, [
        {"A", 1, nil},
        {"B", 2, nil},
        {"C", 3, nil}
      ])

      service = detour_service(organization, version, %{"key" => "plain"})

      assert {:ok, zones} = Geometry.detour_zones(organization.id, version.id, service)

      assert Enum.map(zones, & &1.zone_id) == ["flex-plain-A-B", "flex-plain-B-C"]
      assert Enum.all?(zones, &valid?(&1.geojson))

      [a_b, b_c] = zones

      assert buffer_equals?(a_b.geojson, ["LINESTRING(-124.00 44.60, -124.01 44.60)"], 400)
      assert buffer_equals?(b_c.geojson, ["LINESTRING(-124.01 44.60, -124.02 44.60)"], 400)
    end

    test "buffers each stop of the stretch when the measure is stops" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_route_stops(organization, version)

      insert_shape(organization, version, "shape-out", [
        {"-124.00", "44.60", 1, 0},
        {"-124.01", "44.60", 2, 1000},
        {"-124.02", "44.60", 3, 2000}
      ])

      insert_pattern(organization, version, "pattern-out", "shape-out", [
        {"A", 1, 0},
        {"B", 2, 1000},
        {"C", 3, 2000}
      ])

      service = detour_service(organization, version, %{"key" => "stops", "measure" => "stops"})

      assert {:ok, zones} = Geometry.detour_zones(organization.id, version.id, service)

      assert Enum.map(zones, & &1.zone_id) == ["flex-stops-A-B", "flex-stops-B-C"]
      assert Enum.all?(zones, &valid?(&1.geojson))

      [a_b, b_c] = zones

      assert buffer_equals?(a_b.geojson, ["POINT(-124.00 44.60)", "POINT(-124.01 44.60)"], 400)
      assert buffer_equals?(b_c.geojson, ["POINT(-124.01 44.60)", "POINT(-124.02 44.60)"], 400)

      # Two 400 m circles per zone, measured on geography.
      assert_in_delta km2(a_b.geojson), 1.0, 0.05
      assert_in_delta km2(a_b.geojson), km2(b_c.geojson), 0.000_001
    end

    test "answers a stretch no active pattern visits, an unknown route and a missing distance" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_route_stops(organization, version)

      insert_shape(organization, version, "shape-out", [
        {"-124.00", "44.60", 1, 0},
        {"-124.01", "44.60", 2, 1000},
        {"-124.02", "44.60", 3, 2000}
      ])

      pattern =
        insert_pattern(organization, version, "pattern-out", "shape-out", [
          {"A", 1, 0},
          {"B", 2, 1000},
          {"C", 3, 2000}
        ])

      service = detour_service(organization, version, %{"key" => "valley"})

      assert {:error, :stretch_not_on_route} =
               Geometry.detour_zones(
                 organization.id,
                 version.id,
                 %{service | first_stop_id: "X", last_stop_id: "Y"}
               )

      assert {:error, {:missing_routes, ["NOPE"]}} =
               Geometry.detour_zones(
                 organization.id,
                 version.id,
                 %{service | route_id: "NOPE"}
               )

      # An inactive pattern is not a stretch, and neither is a service whose
      # distance has not been chosen: it has no geometry to derive.
      {1, _} =
        Repo.update_all(from(p in RoutePattern, where: p.id == ^pattern.id), set: [active: false])

      assert {:error, :stretch_not_on_route} =
               Geometry.detour_zones(organization.id, version.id, service)

      {1, _} =
        Repo.update_all(from(p in RoutePattern, where: p.id == ^pattern.id), set: [active: true])

      assert {:error, :empty} =
               Geometry.detour_zones(
                 organization.id,
                 version.id,
                 %{service | distance_m: nil}
               )
    end

    test "keeps another version's and another organization's patterns out" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      route_fixture(organization.id, version.id, %{route_id: @route_id})

      insert_pattern(
        organization,
        other_version,
        "pattern-other-version",
        "shape-other-version",
        [
          {"A", 1, 0},
          {"B", 2, 1000},
          {"C", 3, 2000}
        ]
      )

      insert_pattern(
        other_organization,
        other_org_version,
        "pattern-other-org",
        "shape-other-org",
        [
          {"A", 1, 0},
          {"B", 2, 1000},
          {"C", 3, 2000}
        ]
      )

      service = detour_service(organization, version, %{"key" => "valley"})

      assert {:error, :stretch_not_on_route} =
               Geometry.detour_zones(organization.id, version.id, service)
    end
  end

  defp insert_route_stops(organization, version, extra_stop_ids \\ []) do
    route_fixture(organization.id, version.id, %{route_id: @route_id})

    insert_stop(organization, version, "A", "-124.00", "#{@out_south}")
    insert_stop(organization, version, "B", "-124.01", "#{@out_south}")
    insert_stop(organization, version, "C", "-124.02", "#{@out_south}")

    Enum.each(extra_stop_ids, fn stop_id ->
      insert_stop(organization, version, stop_id, "-124.01", "44.61")
    end)
  end

  defp insert_stop(organization, version, stop_id, lon, lat) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_lon: Decimal.new(lon),
      stop_lat: Decimal.new(lat)
    })
  end

  defp insert_shape(organization, version, shape_id, points) do
    now = DateTime.utc_now()

    rows =
      Enum.map(points, fn {lon, lat, sequence, distance} ->
        %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          shape_id: shape_id,
          shape_pt_lon: Decimal.new(lon),
          shape_pt_lat: Decimal.new(lat),
          shape_pt_sequence: sequence,
          shape_dist_traveled: distance && Decimal.new(distance),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Shape, rows)
  end

  # `route_pattern_fixture/3` cannot cast `shape_id` and
  # `route_pattern_stop_fixture/4` cannot cast `shape_dist_traveled`: the
  # alignment materializer owns both columns, so the fixtures insert the rows and
  # the test derives those columns the way `Alignments` writes them.
  defp insert_pattern(organization, version, pattern_id, shape_id, stops) do
    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: pattern_id,
        route_id: @route_id,
        direction_id: 0
      })

    if shape_id do
      {1, _} =
        Repo.update_all(
          from(p in RoutePattern, where: p.id == ^pattern.id),
          set: [shape_id: shape_id]
        )
    end

    Enum.each(stops, fn {stop_id, position, distance} ->
      occurrence = route_pattern_stop_fixture(pattern, stop_id, position)

      if distance do
        {1, _} =
          Repo.update_all(
            from(o in RoutePatternStop, where: o.id == ^occurrence.id),
            set: [shape_dist_traveled: Decimal.new(distance)]
          )
      end
    end)

    pattern
  end

  defp detour_service(organization, version, attrs) do
    attrs =
      Map.merge(
        %{
          "key" => "valley",
          "name" => "Valley Line detours",
          "kind" => "detour",
          "route_id" => @route_id,
          "first_stop_id" => "A",
          "last_stop_id" => "C",
          "distance_m" => 400,
          "measure" => "route"
        },
        attrs
      )

    %FlexService{organization_id: organization.id, gtfs_version_id: version.id}
    |> FlexService.create_changeset(attrs)
    |> Repo.insert!()
  end

  # Independent expected geometry: hand-written WKT buffers unioned in SQL and
  # compared topologically with the derived zone. The comparison happens at R8's
  # six-decimal output precision, which the derived zone already carries.
  defp buffer_equals?(geojson, wkt_geometries, distance_m \\ 400) do
    %Postgrex.Result{rows: [[equal]]} =
      Repo.query!(
        """
        SELECT ST_Equals(
                 ST_GeomFromGeoJSON($1),
                 ST_ForcePolygonCCW(
                   ST_ReducePrecision(
                     ST_Multi(
                       ST_Union(
                         ARRAY(
                           SELECT ST_Buffer(ST_GeomFromText(wkt, 4326)::geography, $3)::geometry
                           FROM unnest($2::text[]) AS wkt
                         )
                       )
                     ),
                     0.000001
                   )
                 )
               )
        """,
        [Jason.encode!(geojson), wkt_geometries, distance_m]
      )

    equal
  end

  defp km2(geojson) do
    %Postgrex.Result{rows: [[km2]]} =
      Repo.query!("SELECT ST_Area(ST_GeomFromGeoJSON($1)::geography) / 1e6", [
        Jason.encode!(geojson)
      ])

    km2
  end

  defp buffered_km2(wkt_geometry, distance_m \\ 400) do
    %Postgrex.Result{rows: [[km2]]} =
      Repo.query!(
        "SELECT ST_Area(ST_Buffer(ST_GeomFromText($1, 4326)::geography, $2)::geometry::geography) / 1e6",
        [wkt_geometry, distance_m]
      )

    km2
  end

  defp valid?(geojson) do
    %Postgrex.Result{rows: [[valid]]} =
      Repo.query!("SELECT ST_IsValid(ST_GeomFromGeoJSON($1))", [Jason.encode!(geojson)])

    valid
  end
end
