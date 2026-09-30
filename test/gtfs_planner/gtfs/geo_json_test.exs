defmodule GtfsPlanner.Gtfs.GeoJsonTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.GeoJson

  describe "decode/1" do
    test "answers unreadable for a binary that is not JSON" do
      assert GeoJson.decode("not json") == {:error, :unreadable}
    end

    test "decodes a JSON binary into a document" do
      assert GeoJson.decode(~s({"type":"Point","coordinates":[0,0]})) ==
               {:ok, %{"type" => "Point", "coordinates" => [0, 0]}}
    end

    test "passes an already-decoded map through" do
      document = %{"type" => "Feature"}

      assert GeoJson.decode(document) == {:ok, document}
    end
  end

  describe "features/1" do
    test "returns a FeatureCollection's features in document order" do
      first = %{"type" => "Feature", "properties" => %{"name" => "A"}}
      second = %{"type" => "Feature", "properties" => %{"name" => "B"}}

      assert GeoJson.features(%{
               "type" => "FeatureCollection",
               "features" => [first, second]
             }) == [first, second]
    end

    test "wraps a single Feature as one feature" do
      feature = %{"type" => "Feature", "geometry" => %{"type" => "Point"}}

      assert GeoJson.features(feature) == [feature]
    end

    test "wraps bare Polygon and MultiPolygon geometries with no properties" do
      polygon = %{"type" => "Polygon", "coordinates" => [[[0, 0], [1, 1], [0, 1], [0, 0]]]}
      multi = %{"type" => "MultiPolygon", "coordinates" => [[polygon["coordinates"]]]}

      assert GeoJson.features(polygon) == [
               %{"type" => "Feature", "properties" => %{}, "geometry" => polygon}
             ]

      assert GeoJson.features(multi) == [
               %{"type" => "Feature", "properties" => %{}, "geometry" => multi}
             ]
    end

    test "wraps bare LineString and MultiLineString geometries with no properties" do
      line = %{"type" => "LineString", "coordinates" => [[0, 0], [1, 1]]}
      multi = %{"type" => "MultiLineString", "coordinates" => [line["coordinates"]]}

      assert GeoJson.features(line) == [
               %{"type" => "Feature", "properties" => %{}, "geometry" => line}
             ]

      assert GeoJson.features(multi) == [
               %{"type" => "Feature", "properties" => %{}, "geometry" => multi}
             ]
    end

    test "yields no features for a Point or an unrecognized document" do
      assert GeoJson.features(%{"type" => "Point", "coordinates" => [0, 0]}) == []
      assert GeoJson.features(%{"type" => "FeatureCollection"}) == []
    end
  end

  describe "swapped_axes?/1" do
    test "is true for latitude-first positions" do
      assert GeoJson.swapped_axes?([[44.63, -124.05], [44.61, -122.33]]) == true
    end

    test "is false for longitude-first positions" do
      assert GeoJson.swapped_axes?([[-124.05, 44.63], [-122.33, 44.61]]) == false
    end

    test "is false for a latitude beyond ±90 that a swap would not fix" do
      assert GeoJson.swapped_axes?([[44.63, -124.05], [-120.0, 45.0], [0.0, 200.0]]) == false
    end

    test "is false when no position has a latitude beyond ±90" do
      assert GeoJson.swapped_axes?([]) == false
    end
  end
end
