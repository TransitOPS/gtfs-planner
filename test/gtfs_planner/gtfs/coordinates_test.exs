defmodule GtfsPlanner.Gtfs.CoordinatesTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Coordinates

  describe "normalize_point/1" do
    test "normalizes point with atom keys" do
      assert Coordinates.normalize_point(%{x: 10, y: 20.5}) == %{x: 10.0, y: 20.5}
    end

    test "normalizes point with string keys" do
      assert Coordinates.normalize_point(%{"x" => 7, "y" => 3}) == %{x: 7.0, y: 3.0}
    end

    test "returns nil for invalid point values" do
      assert Coordinates.normalize_point(%{"x" => "bad", "y" => 3}) == nil
      assert Coordinates.normalize_point(nil) == nil
    end
  end

  describe "point_value/2" do
    test "supports atom and string lookups" do
      point = %{"x" => 2, y: 4}

      assert Coordinates.point_value(point, :x) == 2
      assert Coordinates.point_value(point, :y) == 4
    end
  end
end
