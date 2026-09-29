defmodule GtfsPlanner.Boundaries.TigerwebTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Boundaries
  alias GtfsPlanner.Boundaries.Tigerweb
  alias GtfsPlanner.Gtfs.Flex.Geometry

  @owner GtfsPlanner.Boundaries.Tigerweb
  @fixtures Path.expand("../../fixtures/tigerweb", __DIR__)

  @places_service "/arcgis/rest/services/TIGERweb/Places_CouSub_ConCity_SubMCD/MapServer"
  @water_query "/arcgis/rest/services/TIGERweb/Hydro/MapServer/1/query"

  @newport_bbox {-124.08358, 44.545139, -124.012117, 44.699197}
  @newport_envelope "-124.083580,44.545139,-124.012117,44.699197"
  @toledo_bbox {-123.954783, 44.59906, -123.913327, 44.641631}
  @toledo_envelope "-123.954783,44.599060,-123.913327,44.641631"

  # The prototype measured these recorded fixtures with shapely in its
  # equirectangular projection (`evidence/prototype-src/basemap/build_scene.py`):
  # Newport 25.7966 km² of 30.3058 km² and Toledo 5.7484 km² of 6.3573 km².
  # PostGIS's geography measurement of the same land is about 0.16% larger, well
  # inside the 1% the evidence plan allows, so the assertions compare with the
  # prototype's own numbers.
  @newport_land_km2 25.7966
  @newport_boundary_km2 30.3058
  @toledo_land_km2 5.7484
  @toledo_boundary_km2 6.3573

  describe "places_near/1" do
    test "lists the places, census-designated places, county subdivisions and counties intersecting the bbox" do
      stub(recorded())

      assert {:ok, places} = Tigerweb.places_near(@newport_bbox)

      assert places == [
               %{
                 name: "Bayshore CDP",
                 layer: "cdp",
                 geoid: "4104850",
                 vintage: "2026",
                 cdp?: true,
                 state_fips: "41"
               },
               %{
                 name: "Lincoln County",
                 layer: "county",
                 geoid: "41041",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               },
               %{
                 name: "Newport CCD",
                 layer: "county_subdivision",
                 geoid: "4104192133",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               },
               %{
                 name: "Newport city",
                 layer: "place",
                 geoid: "4152450",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               },
               %{
                 name: "Siletz CCD",
                 layer: "county_subdivision",
                 geoid: "4104192907",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               },
               %{
                 name: "Toledo CCD",
                 layer: "county_subdivision",
                 geoid: "4104193230",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               },
               %{
                 name: "Toledo city",
                 layer: "place",
                 geoid: "4174000",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               },
               %{
                 name: "Waldport CCD",
                 layer: "county_subdivision",
                 geoid: "4104193349",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               }
             ]

      # One request per layer, each an attribute-only bbox query; the polygons a
      # pick never draws are not downloaded.
      assert_received {:tigerweb_request, place_path, place_params}
      assert place_path == "#{@places_service}/11/query"

      assert place_params == %{
               "geometry" => @newport_envelope,
               "geometryType" => "esriGeometryEnvelope",
               "inSR" => "4326",
               "outSR" => "4326",
               "f" => "geojson",
               "outFields" => "NAME,GEOID,STATE,PLACE,LSADC,FUNCSTAT,AREALAND,AREAWATER,MTFCC",
               "returnGeometry" => "false"
             }

      assert_received {:tigerweb_request, cdp_path, _cdp_params}
      assert cdp_path == "#{@places_service}/12/query"

      assert_received {:tigerweb_request, subdivision_path, _subdivision_params}
      assert subdivision_path == "#{@places_service}/8/query"

      assert_received {:tigerweb_request, county_path, county_params}
      assert county_path == "/arcgis/rest/services/TIGERweb/State_County/MapServer/19/query"
      assert county_params["outFields"] == "NAME,GEOID,STATE,COUNTY,FUNCSTAT,MTFCC"
      refute_received {:tigerweb_request, _path, _params}
    end

    test "answers :unavailable when a layer fails" do
      stub(fn path, params ->
        if String.ends_with?(path, "#{@places_service}/8/query") do
          {:status, 503}
        else
          recorded().(path, params)
        end
      end)

      assert {:error, :unavailable} = Tigerweb.places_near(@toledo_bbox)
    end
  end

  describe "search/2" do
    test "matches a name prefix in the given state" do
      stub(recorded())

      assert {:ok, places} = Tigerweb.search("Newport", "41")

      assert places == [
               %{
                 name: "Newport city",
                 layer: "place",
                 geoid: "4152450",
                 vintage: "2026",
                 cdp?: false,
                 state_fips: "41"
               }
             ]

      assert_received {:tigerweb_request, path, params}
      assert path == "#{@places_service}/11/query"

      assert params["where"] ==
               "STATE='41' AND UPPER(NAME) LIKE UPPER('Newport%')"

      assert params["returnGeometry"] == "false"

      assert_received {:tigerweb_request, cdp_path, cdp_params}
      assert cdp_path == "#{@places_service}/12/query"
      assert cdp_params["where"] == "STATE='41' AND UPPER(NAME) LIKE UPPER('Newport%')"
    end

    test "does not call the service for a blank name or a state that is not a FIPS code" do
      stub(fn _path, _params -> raise "must not request" end)

      assert {:ok, []} = Tigerweb.search("   ", "41")
      assert {:ok, []} = Tigerweb.search("Newport", "4")
      assert {:ok, []} = Tigerweb.search(nil, "41")
    end
  end

  describe "boundary/2" do
    test "returns the chosen place's GeoJSON geometry with the pinned vintage" do
      stub(recorded())

      assert {:ok, %{geojson: geojson, vintage: "2026"}} = Tigerweb.boundary("place", "4152450")

      assert geojson == fixture_geometry("place_4152450.json")

      assert_received {:tigerweb_request, path, params}
      assert path == "#{@places_service}/11/query"
      assert params["where"] == "GEOID='4152450'"
      refute params["returnGeometry"]
      refute_received {:tigerweb_request, _path, _params}
    end

    test "answers :not_found when the GEOID matches nothing" do
      stub(recorded())

      assert {:error, :not_found} = Tigerweb.boundary("place", "9999999")
    end

    test "answers :not_found for a layer that is not one of the pickable four" do
      stub(fn _path, _params -> raise "must not request" end)

      assert {:error, :not_found} = Tigerweb.boundary("state", "41")
    end
  end

  describe "land_boundary/2 failures" do
    test "a 503 from the boundary endpoint answers :unavailable after the retries" do
      stub(fn path, params ->
        if String.ends_with?(path, "/11/query") do
          {:status, 503}
        else
          recorded().(path, params)
        end
      end)

      assert {:error, :unavailable} = Boundaries.land_boundary("place", "4152450")

      assert_received {:tigerweb_request, _path, _params}
      assert_received {:tigerweb_request, _path, _params}
      assert_received {:tigerweb_request, _path, _params}
      refute_received {:tigerweb_request, _path, _params}
    end

    test "a transport timeout answers :unavailable" do
      stub(fn _path, _params -> :timeout end)

      assert {:error, :unavailable} = Boundaries.land_boundary("place", "4152450")
    end

    test "an unparseable body answers :unavailable" do
      stub(fn _path, _params -> {:raw, "not a FeatureCollection"} end)

      assert {:error, :unavailable} = Boundaries.land_boundary("place", "4152450")
    end

    test "an ArcGIS error body answers :unavailable" do
      stub(fn _path, _params ->
        {:json, %{"error" => %{"code" => 400, "message" => "Invalid"}}}
      end)

      assert {:error, :unavailable} = Boundaries.land_boundary("place", "4152450")
    end

    test "a water failure answers :unavailable" do
      stub(fn path, params ->
        if String.ends_with?(path, @water_query) do
          {:status, 500}
        else
          recorded().(path, params)
        end
      end)

      assert {:error, :unavailable} = Boundaries.land_boundary("place", "4152450")
    end

    test "an unknown GEOID answers :not_found without a water request" do
      stub(recorded())

      assert {:error, :not_found} = Boundaries.land_boundary("place", "9999999")

      assert_received {:tigerweb_request, _path, _params}
      refute_received {:tigerweb_request, _path, _params}
    end
  end

  describe "land_boundary/2 with the recorded boundary and water" do
    test "returns the water-removed Newport boundary as a valid MultiPolygon" do
      stub(recorded())

      assert {:ok, %{geojson: land, geoid: "4152450", layer: "place", vintage: "2026"}} =
               Boundaries.land_boundary("place", "4152450")

      assert land["type"] == "MultiPolygon"
      assert_in_delta km2(land), @newport_land_km2, @newport_land_km2 * 0.01

      # The boundary request keeps the geometry and the water request is scoped
      # to the boundary's own envelope.
      assert_received {:tigerweb_request, boundary_path, boundary_params}
      assert boundary_path == "#{@places_service}/11/query"
      assert boundary_params["where"] == "GEOID='4152450'"

      assert_received {:tigerweb_request, water_path, water_params}
      assert water_path == @water_query
      assert water_params["geometry"] == @newport_envelope
      assert water_params["geometryType"] == "esriGeometryEnvelope"
      refute_received {:tigerweb_request, _path, _params}
    end

    test "removes the recorded water from the Newport place boundary" do
      boundary = fixture_geometry("place_4152450.json")

      assert {:ok, land} =
               Geometry.land_boundary(boundary, fixture_geometries("water_newport.json"))

      assert_in_delta km2(land), @newport_land_km2, @newport_land_km2 * 0.01
      assert_in_delta km2(boundary), @newport_boundary_km2, @newport_boundary_km2 * 0.01
    end

    test "returns the water-removed Toledo boundary as a valid MultiPolygon" do
      stub(recorded())

      assert {:ok, %{geojson: land, geoid: "4174000", layer: "place", vintage: "2026"}} =
               Boundaries.land_boundary("place", "4174000")

      assert land["type"] == "MultiPolygon"
      assert_in_delta km2(land), @toledo_land_km2, @toledo_land_km2 * 0.01

      assert_received {:tigerweb_request, _boundary_path, _boundary_params}

      assert_received {:tigerweb_request, water_path, water_params}
      assert water_path == @water_query
      assert water_params["geometry"] == @toledo_envelope

      assert_in_delta km2(fixture_geometry("place_4174000.json")),
                      @toledo_boundary_km2,
                      @toledo_boundary_km2 * 0.01
    end
  end

  describe "Geometry.land_boundary/2" do
    test "accepts a self-touching Census ring and returns valid land" do
      boundary = fixture_geometry("place_4152450.json")

      assert {:ok, land} = Geometry.land_boundary(boundary, [])

      assert land["type"] == "MultiPolygon"
      assert_in_delta km2(land), @newport_boundary_km2, @newport_boundary_km2 * 0.01
    end

    test "answers :empty when the water covers the whole boundary" do
      boundary = fixture_geometry("place_4152450.json")

      assert {:error, :empty} =
               Geometry.land_boundary(boundary, [enclosing_polygon()])
    end

    test "answers :empty for a boundary that is not a polygon" do
      line = %{"type" => "LineString", "coordinates" => [[-124.0, 44.6], [-123.9, 44.7]]}

      assert {:error, :empty} = Geometry.land_boundary(line, [])
    end
  end

  describe "GtfsPlanner.BrowserBoundaries" do
    test "is selected by the test config while BROWSER_E2E is true" do
      original = System.get_env("BROWSER_E2E")
      System.put_env("BROWSER_E2E", "true")
      restore_browser_e2e(original)

      config = Config.Reader.read!(Path.expand("config/test.exs"), env: :test)

      assert config[:gtfs_planner][:boundaries_service] == GtfsPlanner.BrowserBoundaries
    end

    test "answers the same Newport and Toledo data from the fixtures without a request" do
      original = Application.get_env(:gtfs_planner, :boundaries_service)
      Application.put_env(:gtfs_planner, :boundaries_service, GtfsPlanner.BrowserBoundaries)
      restore_boundaries_service(original)

      Req.Test.stub(@owner, fn _conn -> raise "must not call TIGERweb" end)

      assert {:ok, places} = Boundaries.places_near(@newport_bbox)

      assert Enum.map(places, &{&1.name, &1.geoid, &1.cdp?}) == [
               {"Bayshore CDP", "4104850", true},
               {"Newport city", "4152450", false},
               {"Toledo city", "4174000", false}
             ]

      assert {:ok, [%{name: "Newport city", geoid: "4152450"}]} =
               Boundaries.search("Newport", "41")

      assert {:ok, %{geojson: land, geoid: "4152450", vintage: "2026"}} =
               Boundaries.land_boundary("place", "4152450")

      assert_in_delta km2(land), @newport_land_km2, @newport_land_km2 * 0.01
    end
  end

  # Measures through the production module, so no assertion issues geometry SQL
  # of its own (CR-1).
  defp km2(geojson) do
    Geometry.stats(Ecto.UUID.generate(), Ecto.UUID.generate(), geojson).km2
  end

  defp restore_browser_e2e(nil), do: on_exit(fn -> System.delete_env("BROWSER_E2E") end)
  defp restore_browser_e2e(value), do: on_exit(fn -> System.put_env("BROWSER_E2E", value) end)

  defp restore_boundaries_service(value) do
    on_exit(fn -> Application.put_env(:gtfs_planner, :boundaries_service, value) end)
  end

  defp recorded do
    fn path, params ->
      cond do
        String.ends_with?(path, @water_query) ->
          {:json, water_response(params["geometry"])}

        String.ends_with?(path, "/State_County/MapServer/19/query") ->
          {:json, fixture("county_bbox.json")}

        String.ends_with?(path, "#{@places_service}/8/query") ->
          {:json, fixture("county_subdivision_bbox.json")}

        String.ends_with?(path, "#{@places_service}/12/query") ->
          {:json, cdp_response(params)}

        String.ends_with?(path, "#{@places_service}/11/query") ->
          {:json, place_response(params)}

        true ->
          {:json, feature_collection([])}
      end
    end
  end

  defp place_response(%{"where" => where}) do
    case Regex.run(~r/GEOID='(\d+)'/, where) do
      [_match, geoid] -> geoid_response(geoid)
      nil -> fixture("search_newport.json")
    end
  end

  defp place_response(_bbox_params) do
    # The recorded bbox response carries the two prototype places plus one
    # census-designated place; the real place layer answers with the legal ones
    # only.
    feature_collection(bbox_features(&legal_place?/1))
  end

  # A census-designated place is statistical (`FUNCSTAT` "S"), a legal place is
  # active ("A"), so the recorded bbox response splits across the two layers the
  # way TIGERweb serves it. No CDP boundary is recorded, so a where clause (a
  # GEOID lookup or a name search) on that layer answers nothing.
  defp cdp_response(%{"where" => _where}), do: feature_collection([])

  defp cdp_response(_bbox_params), do: feature_collection(bbox_features(&statistical_place?/1))

  defp legal_place?(properties), do: properties["FUNCSTAT"] != "S"

  defp statistical_place?(properties), do: properties["FUNCSTAT"] == "S"

  defp geoid_response("4152450"), do: fixture("place_4152450.json")
  defp geoid_response("4174000"), do: fixture("place_4174000.json")
  defp geoid_response(_geoid), do: feature_collection([])

  defp water_response(@newport_envelope), do: fixture("water_newport.json")
  defp water_response(@toledo_envelope), do: fixture("water_toledo.json")
  defp water_response(_geometry), do: feature_collection([])

  defp bbox_features(keep?) do
    "places_bbox.json"
    |> fixture()
    |> Map.fetch!("features")
    |> Enum.filter(&keep?.(&1["properties"]))
  end

  defp feature_collection(features), do: %{"type" => "FeatureCollection", "features" => features}

  defp fixture(file) do
    @fixtures |> Path.join(file) |> File.read!() |> Jason.decode!()
  end

  defp fixture_geometry(file) do
    file |> fixture() |> Map.fetch!("features") |> hd() |> Map.fetch!("geometry")
  end

  defp fixture_geometries(file) do
    file |> fixture() |> Map.fetch!("features") |> Enum.map(&Map.fetch!(&1, "geometry"))
  end

  defp enclosing_polygon do
    %{
      "type" => "Polygon",
      "coordinates" => [
        [[-125.0, 44.0], [-123.0, 44.0], [-123.0, 45.0], [-125.0, 45.0], [-125.0, 44.0]]
      ]
    }
  end

  defp stub(handler) when is_function(handler, 2) do
    Req.Test.stub(@owner, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:tigerweb_request, conn.request_path, conn.query_params})

      case handler.(conn.request_path, conn.query_params) do
        {:json, payload} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(payload))

        {:raw, body} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)

        {:status, status} ->
          Plug.Conn.send_resp(conn, status, "error")

        :timeout ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)
  end
end
