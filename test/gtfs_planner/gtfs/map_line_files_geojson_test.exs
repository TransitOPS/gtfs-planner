defmodule GtfsPlanner.Gtfs.MapLineFilesGeojsonTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.MapLineFiles

  @north [
    [-71.0589, 42.3601],
    [-71.0580, 42.3611]
  ]

  @south [
    [-71.0500, 42.3500],
    [-71.0490, 42.3510]
  ]

  describe "parse/2 naming and geometry" do
    test "reads a FeatureCollection's named LineStrings in document order" do
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature("LineString", @north, %{"name" => "North"}),
            feature("LineString", @south, %{"name" => "South"})
          ]
        })

      assert MapLineFiles.parse(document, "lines.geojson") ==
               {:ok,
                [
                  %{name: "North", points: @north, joined_from: 1},
                  %{name: "South", points: @south, joined_from: 1}
                ]}
    end

    test "rounds coordinates to six decimals" do
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature(
              "LineString",
              [[-71.0589123456, 42.3601987654], [-71.0580123456, 42.3611987654]],
              %{"name" => "R"}
            )
          ]
        })

      assert {:ok, [line]} = MapLineFiles.parse(document, "lines.json")
      assert line.points == [[-71.058912, 42.360199], [-71.058012, 42.361199]]
    end

    test "names a bare LineString geometry's feature from its properties" do
      document =
        Jason.encode!(%{
          "type" => "Feature",
          "properties" => %{"name" => "Bare"},
          "geometry" => %{"type" => "LineString", "coordinates" => @north}
        })

      assert {:ok, [%{name: "Bare"}]} = MapLineFiles.parse(document, "lines.geojson")
    end

    test "leaves a geometry with no properties unnamed" do
      document =
        Jason.encode!(%{"type" => "LineString", "coordinates" => @north})

      assert {:ok, [line]} = MapLineFiles.parse(document, "lines.geojson")
      assert line.name == nil
    end
  end

  describe "parse/2 joining" do
    test "joins MultiLineString parts whose ends meet within 50 m" do
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature(
              "MultiLineString",
              [
                [[-71.0589, 42.3601], [-71.0580, 42.3611]],
                [[-71.0579, 42.3612], [-71.0570, 42.3620]]
              ],
              %{"name" => "Route 1"}
            )
          ]
        })

      assert MapLineFiles.parse(document, "lines.geojson") ==
               {:ok,
                [
                  %{
                    name: "Route 1",
                    points: [
                      [-71.0589, 42.3601],
                      [-71.0580, 42.3611],
                      [-71.0579, 42.3612],
                      [-71.0570, 42.3620]
                    ],
                    joined_from: 2
                  }
                ]}
    end

    test "keeps parts 2 km apart as separate lines" do
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature(
              "MultiLineString",
              [
                [[-71.0589, 42.3601], [-71.0580, 42.3611]],
                [[-71.0589, 42.3791], [-71.0580, 42.3801]]
              ],
              %{"name" => "Route 1"}
            )
          ]
        })

      assert {:ok, [first, second]} = MapLineFiles.parse(document, "lines.geojson")
      assert first == %{name: "Route 1", points: @north, joined_from: 1}
      assert second.joined_from == 1
      assert second.name == nil
    end

    test "skips a part with no usable position" do
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature("MultiLineString", [["not a position"], @north], %{"name" => "Route 1"})
          ]
        })

      assert {:ok, [line]} = MapLineFiles.parse(document, "lines.geojson")
      assert line == %{name: "Route 1", points: @north, joined_from: 1}
    end

    test "skips positions off the globe and integers too large for a float" do
      huge = String.to_integer(String.duplicate("9", 400))

      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature("MultiLineString", [[[0, 100], [180, 80]], [[huge, 1], [2, 3]], @north], %{
              "name" => "Route 1"
            })
          ]
        })

      assert {:ok, [line]} = MapLineFiles.parse(document, "lines.geojson")
      assert line == %{name: "Route 1", points: @north, joined_from: 1}
    end

    test "joins many touching parts into one line in file order" do
      parts =
        for i <- 0..4_999, do: [[-71.0 + i * 1.0e-5, 42.0], [-71.0 + (i + 1) * 1.0e-5, 42.0]]

      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [feature("MultiLineString", parts, %{"name" => "Long"})]
        })

      assert {:ok, [line]} = MapLineFiles.parse(document, "lines.geojson")
      assert line.joined_from == 5_000
      assert length(line.points) == 10_000
      assert List.first(line.points) == [-71.0, 42.0]
      assert List.last(line.points) == [-70.95, 42.0]
    end
  end

  describe "parse/2 file problems" do
    test "reports points only for a document of Point features" do
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature("Point", [-71.0589, 42.3601], %{}),
            feature("Point", [-71.0500, 42.3500], %{})
          ]
        })

      assert MapLineFiles.parse(document, "stops.geojson") == {:error, :points_only}
    end

    test "reports areas only for a document of Polygon features" do
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            feature(
              "Polygon",
              [
                [
                  [-71.0589, 42.3601],
                  [-71.0500, 42.3601],
                  [-71.0500, 42.3700],
                  [-71.0589, 42.3601]
                ]
              ],
              %{}
            )
          ]
        })

      assert MapLineFiles.parse(document, "zones.geojson") == {:error, :areas_only}
    end

    test "reports empty for a FeatureCollection with no features" do
      document = Jason.encode!(%{"type" => "FeatureCollection", "features" => []})

      assert MapLineFiles.parse(document, "empty.geojson") == {:error, :empty}
    end

    test "reports empty for a document whose features list is missing" do
      document = Jason.encode!(%{"type" => "FeatureCollection"})

      assert MapLineFiles.parse(document, "empty.geojson") == {:error, :empty}
    end

    test "reports empty for a document of no recognised geometry" do
      document =
        Jason.encode!(%{"type" => "FeatureCollection", "features" => [%{"type" => "Feature"}]})

      assert MapLineFiles.parse(document, "unknown.geojson") == {:error, :empty}
    end

    test "reports swapped when the positions are latitude-first" do
      # A latitude beyond ±90 in the second slot is the reversal: this is Oregon
      # written `[lat, lon]`.
      document =
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [feature("LineString", [[44.61, -124.05], [44.63, -122.33]], %{})]
        })

      assert MapLineFiles.parse(document, "lines.geojson") == {:error, :swapped}
    end

    test "reports unsupported for another extension" do
      assert MapLineFiles.parse("not a map file", "shapes.shp") == {:error, :unsupported}
    end

    test "reports unreadable for a binary that is not JSON" do
      assert MapLineFiles.parse("<not json", "lines.geojson") == {:error, :unreadable}
    end
  end

  defp feature(type, geometry, properties) do
    %{
      "type" => "Feature",
      "properties" => properties,
      "geometry" => %{"type" => type, "coordinates" => geometry}
    }
  end
end
