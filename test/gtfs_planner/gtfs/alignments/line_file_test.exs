defmodule GtfsPlanner.Gtfs.Alignments.LineFileTest do
  @moduledoc """
  Step 33 / EV-32: the map-line download model and its GeoJSON and KML
  encodings. Expected values are literals chosen for the fixture, never
  computed by the code under test.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.MapLineFiles
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  # Thirteen stops on a rising diagonal, so every piece is distinguishable.
  # The interior point of the section that starts at stop `n` sits at
  # lon `-74.05 - 0.1 * (n - 1)`, lat `40.05`.
  @stops [
    {"S1", "40.0", "-74.0"},
    {"S2", "40.1", "-74.1"},
    {"S3", "40.2", "-74.2"},
    {"S4", "40.3", "-74.3"},
    {"S5", "40.4", "-74.4"},
    {"S6", "40.5", "-74.5"},
    {"S7", "40.6", "-74.6"},
    {"S8", "40.7", "-74.7"},
    {"S9", "40.8", "-74.8"},
    {"S10", "40.9", "-74.9"},
    {"S11", "41.0", "-75.0"},
    {"S12", "41.1", "-75.1"},
    {"S13", "41.2", "-75.2"}
  ]

  defp stop_with_coords(organization, version, stop_id, lat_s, lon_s) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: "Stop #{stop_id}",
      stop_lat: Decimal.new(lat_s),
      stop_lon: Decimal.new(lon_s)
    })
  end

  defp insert_shared(organization, version, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp insert_shape(organization, version, shape_id, sequence, lat_s, lon_s, dist_s) do
    %Shape{}
    |> Shape.changeset(%{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      shape_id: shape_id,
      shape_pt_sequence: sequence,
      shape_pt_lat: lat_s,
      shape_pt_lon: lon_s,
      shape_dist_traveled: dist_s
    })
    |> Repo.insert!()
  end

  # One stop per id, in order, on the pattern `route_pattern_id`.
  defp pattern_with_stops(organization, version, route_pattern_id, ids) do
    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: route_pattern_id,
        route_pattern_name: "Pattern #{route_pattern_id}"
      })

    ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  defp stop_ids, do: Enum.map(@stops, &elem(&1, 0))

  defp section_index(stop_id), do: String.to_integer(String.replace_prefix(stop_id, "S", ""))

  defp interior_lon(stop_id), do: -74.05 - 0.1 * (section_index(stop_id) - 1)

  defp thirteen_stop_scenario do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    Enum.each(@stops, fn {id, lat, lon} ->
      stop_with_coords(organization, version, id, lat, lon)
    end)

    route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "1"})
    _pattern = pattern_with_stops(organization, version, "P1", stop_ids())

    {organization, version}
  end

  # A saved shared path for every consecutive pair, except the positions named
  # in `skip`, which stay missing.
  defp save_pairs(organization, version, ids, skip \\ []) do
    ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index(1)
    |> Enum.each(fn {[from_id, to_id], position} ->
      if position not in skip do
        insert_shared(organization, version, from_id, to_id, [[interior_lon(from_id), 40.05]])
      end
    end)
  end

  defp geojson(model) do
    assert {:ok, document} = MapLineFiles.encode(:geojson, model)
    assert {:ok, decoded} = Jason.decode(document)
    decoded
  end

  test "a saved 13-stop pattern encodes as one LineString and 13 stop Points" do
    {organization, version} = thirteen_stop_scenario()
    save_pairs(organization, version, stop_ids())

    assert {:ok, model} = Alignments.line_file(organization.id, version.id, "R1", "P1")
    assert [pattern] = model.patterns
    assert pattern.route_pattern_id == "P1"
    assert pattern.name == "Pattern P1"
    assert pattern.direction == "0"
    assert [piece] = pattern.pieces
    # 13 visits as the ends of 12 saved sections, plus 12 interior points.
    assert length(piece) == 25
    assert List.first(piece) == [-74.0, 40.0]
    assert List.last(piece) == [-75.2, 41.2]
    assert length(pattern.stops) == 13

    decoded = geojson(model)
    assert decoded["type"] == "FeatureCollection"
    assert [line | stops] = decoded["features"]

    assert line["geometry"]["type"] == "LineString"
    assert line["geometry"]["coordinates"] == piece

    assert line["properties"] == %{
             "name" => "Pattern P1",
             "route" => "1",
             "route_pattern_id" => "P1",
             "direction" => "0"
           }

    assert length(stops) == 13
    assert Enum.all?(stops, &(&1["geometry"]["type"] == "Point"))
    assert Enum.map(stops, & &1["properties"]["stop_id"]) == stop_ids()
    assert Enum.map(stops, & &1["properties"]["position"]) == Enum.to_list(1..13)
    assert hd(stops)["geometry"]["coordinates"] == [-74.0, 40.0]
  end

  test "two missing sections split the line into a MultiLineString of 2 pieces" do
    {organization, version} = thirteen_stop_scenario()
    # Sections 5 and 6 stay missing, so the line stops before S5 and starts again
    # after S6: two pieces, never one line drawn across the gap.
    save_pairs(organization, version, stop_ids(), [5, 6])

    assert {:ok, model} = Alignments.line_file(organization.id, version.id, "R1", "P1")
    assert [pattern] = model.patterns
    assert [first_piece, second_piece] = pattern.pieces
    # Four saved sections before the gap (5 visits), six after it (7 visits).
    assert length(first_piece) == 9
    assert length(second_piece) == 13
    assert List.last(first_piece) == [-74.4, 40.4]
    assert List.first(second_piece) == [-74.6, 40.6]
    assert length(pattern.stops) == 13

    decoded = geojson(model)
    assert [line | _stops] = decoded["features"]
    assert line["geometry"]["type"] == "MultiLineString"
    assert line["geometry"]["coordinates"] == [first_piece, second_piece]
  end

  test "an imported-only pattern uses the imported shape as one piece" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_with_coords(organization, version, "S1", "40.0", "-74.0")
    stop_with_coords(organization, version, "S2", "40.1", "-74.1")
    route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "1"})
    pattern = pattern_with_stops(organization, version, "P1", ["S1", "S2"])
    timing = timed_pattern_fixture(pattern)

    insert_shape(organization, version, "SH1", 1, "40.0", "-74.0", "0.0")
    insert_shape(organization, version, "SH1", 2, "40.25", "-74.25", "10.0")

    trip =
      trip_fixture(organization.id, version.id, "R1", %{trip_id: "T1", shape_id: "SH1"})

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: "P1",
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    assert {:ok, model} = Alignments.line_file(organization.id, version.id, "R1", "P1")
    assert [entry] = model.patterns
    assert [piece] = entry.pieces
    assert piece == [[-74.0, 40.0], [-74.25, 40.25]]
    assert length(entry.stops) == 2

    decoded = geojson(model)
    assert [line, _first_stop, _second_stop] = decoded["features"]
    assert line["geometry"] == %{"type" => "LineString", "coordinates" => piece}
  end

  test "KML for a fixed two-point, two-stop fixture equals the literal document" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_with_coords(organization, version, "A", "40.0", "-74.0")
    stop_with_coords(organization, version, "B", "41.0", "-73.0")
    route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "9"})
    _pattern = pattern_with_stops(organization, version, "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [[-73.5, 40.5]])

    assert {:ok, model} = Alignments.line_file(organization.id, version.id, "R1", "P1")
    assert {:ok, document} = MapLineFiles.encode(:kml, model)

    assert document == """
           <?xml version="1.0" encoding="UTF-8"?>
           <kml xmlns="http://www.opengis.net/kml/2.2">
             <Document>
               <name>9</name>
               <Folder>
                 <name>Pattern P1</name>
                 <Placemark>
                   <name>Pattern P1</name>
                   <LineString>
                     <tessellate>1</tessellate>
                     <coordinates>-74.0,40.0 -73.5,40.5 -73.0,41.0</coordinates>
                   </LineString>
                 </Placemark>
                 <Placemark>
                   <name>Stop A</name>
                   <Point>
                     <coordinates>-74.0,40.0</coordinates>
                   </Point>
                 </Placemark>
                 <Placemark>
                   <name>Stop B</name>
                   <Point>
                     <coordinates>-73.0,41.0</coordinates>
                   </Point>
                 </Placemark>
               </Folder>
             </Document>
           </kml>
           """
  end

  test "a name with & is escaped in KML and a foreign scope is not found" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_with_coords(organization, version, "A", "40.0", "-74.0")
    stop_with_coords(organization, version, "B", "41.0", "-73.0")

    route_fixture(organization.id, version.id, %{
      route_id: "R1",
      route_short_name: "1 & 2",
      route_long_name: "Downtown <Express>"
    })

    _pattern = pattern_with_stops(organization, version, "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [[-73.5, 40.5]])

    assert {:ok, model} = Alignments.line_file(organization.id, version.id, "R1", "P1")
    assert {:ok, document} = MapLineFiles.encode(:kml, model)

    assert document =~ "<name>1 &amp; 2</name>"
    refute document =~ "1 & 2"
    assert geojson(model)["type"] == "FeatureCollection"

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    assert {:error, :not_found} =
             Alignments.line_file(other_organization.id, other_version.id, "R1", "P1")

    assert {:error, :not_found} = Alignments.line_file(organization.id, version.id, "R1", "NOPE")
  end

  test "all returns every pattern of the route and an unknown format is unsupported" do
    {organization, version} = thirteen_stop_scenario()
    save_pairs(organization, version, stop_ids())
    _second = pattern_with_stops(organization, version, "P2", ["S1", "S2"])

    assert {:ok, model} = Alignments.line_file(organization.id, version.id, "R1", "all")
    assert model.route_id == "R1"
    assert model.name == "1"
    assert Enum.map(model.patterns, & &1.route_pattern_id) == ["P1", "P2"]

    assert {:error, :unsupported} = MapLineFiles.encode(:gpx, model)
  end
end
