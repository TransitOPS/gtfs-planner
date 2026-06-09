defmodule GtfsPlanner.Gtfs.FloorplanTransformTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.FloorplanTransform

  @center_lat 40.75
  @center_lon -73.99
  @scale_mpp 0.5
  @meters_per_degree_lat 111_111.0

  defp alignment(overrides \\ %{}) do
    Map.merge(
      %{
        center_lat: @center_lat,
        center_lon: @center_lon,
        scale_mpp: @scale_mpp,
        rotation_deg: 0.0
      },
      overrides
    )
  end

  defp cos_center_lat, do: :math.cos(@center_lat * :math.pi() / 180.0)

  describe "svg_to_lat_lon/4 AC 1: east offset at rotation 0" do
    test "point east of the image center yields larger lon, unchanged lat" do
      image_w = 200
      image_h = 100
      unit = image_w / 100.0
      # The image's vertical center in diagram units is 50 * h/w (the space is
      # width-normalized, top-left anchored), not 50.
      center_y_units = 50.0 * image_h / image_w

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(alignment(), image_w, image_h, %{
          x: 70.0,
          y: center_y_units
        })

      expected_meters_east = (70.0 - 50.0) * unit * @scale_mpp

      expected_lon =
        @center_lon + expected_meters_east / (@meters_per_degree_lat * cos_center_lat())

      assert_in_delta lat, @center_lat, 1.0e-12
      assert_in_delta lon, expected_lon, 1.0e-9
      assert lon > @center_lon
    end
  end

  describe "svg_to_lat_lon/4 AC 2: south offset at rotation 0" do
    test "point south of center (larger y) yields smaller lat, unchanged lon" do
      image_w = 100
      image_h = 100
      fit = 1.0

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(alignment(), image_w, image_h, %{x: 50.0, y: 80.0})

      expected_meters_south = (80.0 - 50.0) * fit * @scale_mpp
      expected_lat = @center_lat - expected_meters_south / @meters_per_degree_lat

      assert_in_delta lat, expected_lat, 1.0e-12
      assert_in_delta lon, @center_lon, 1.0e-12
      assert lat < @center_lat
    end
  end

  describe "svg_to_lat_lon/4 AC 3: rotation 90 rotates +x toward south" do
    test "a +x SVG offset ends up decreasing lat at rotation_deg = 90" do
      image_w = 100
      image_h = 100
      fit = 1.0
      dx = 30.0

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(
          alignment(%{rotation_deg: 90.0}),
          image_w,
          image_h,
          %{x: 50.0 + dx, y: 50.0}
        )

      expected_meters_south = dx * fit * @scale_mpp
      expected_lat = @center_lat - expected_meters_south / @meters_per_degree_lat

      assert_in_delta lat, expected_lat, 1.0e-9
      assert_in_delta lon, @center_lon, 1.0e-9
      assert lat < @center_lat
    end
  end

  describe "svg_to_lat_lon/4 AC 4: rotation 180 flips east/west" do
    test "a +x SVG offset becomes a westward (lower lon) geographic offset" do
      image_w = 100
      image_h = 100
      fit = 1.0
      dx = 20.0

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(
          alignment(%{rotation_deg: 180.0}),
          image_w,
          image_h,
          %{x: 50.0 + dx, y: 50.0}
        )

      expected_meters_east = -dx * fit * @scale_mpp

      expected_lon =
        @center_lon + expected_meters_east / (@meters_per_degree_lat * cos_center_lat())

      assert_in_delta lat, @center_lat, 1.0e-9
      assert_in_delta lon, expected_lon, 1.0e-9
      assert lon < @center_lon
    end
  end

  describe "svg_to_lat_lon/4 AC 5: image center on landscape image" do
    test "the painted image center maps to (center_lat, center_lon)" do
      image_w = 800
      image_h = 400
      # Width-normalized space: the image center is (50, 50 * h/w).
      center_y_units = 50.0 * image_h / image_w

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(alignment(), image_w, image_h, %{
          x: 50.0,
          y: center_y_units
        })

      assert_in_delta lat, @center_lat, 1.0e-12
      assert_in_delta lon, @center_lon, 1.0e-12
    end
  end

  describe "svg_to_lat_lon/4 AC 6: image center on portrait image" do
    test "the painted image center maps to (center_lat, center_lon), past y = 50" do
      image_w = 400
      image_h = 800
      # Portrait: the image extends past y = 100; its center sits at y = 100.
      center_y_units = 50.0 * image_h / image_w
      assert center_y_units == 100.0

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(alignment(), image_w, image_h, %{
          x: 50.0,
          y: center_y_units
        })

      assert_in_delta lat, @center_lat, 1.0e-12
      assert_in_delta lon, @center_lon, 1.0e-12
    end
  end

  describe "svg_to_lat_lon/4 AC 6b: width-normalized units on a portrait image" do
    test "a y offset scales by image WIDTH, not max(w, h)" do
      image_w = 400
      image_h = 800
      unit = image_w / 100.0
      center_y_units = 50.0 * image_h / image_w
      dy_units = 10.0

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(alignment(), image_w, image_h, %{
          x: 50.0,
          y: center_y_units + dy_units
        })

      expected_meters_south = dy_units * unit * @scale_mpp
      expected_lat = @center_lat - expected_meters_south / @meters_per_degree_lat

      assert_in_delta lat, expected_lat, 1.0e-12
      assert_in_delta lon, @center_lon, 1.0e-12
    end
  end

  describe "svg_to_lat_lon/4 AC 7: invalid alignment" do
    test "missing field" do
      bad = Map.delete(alignment(), :center_lat)

      assert {:error, :invalid_alignment} =
               FloorplanTransform.svg_to_lat_lon(bad, 100, 100, %{x: 50.0, y: 50.0})
    end

    test "non-numeric field" do
      bad = %{alignment() | scale_mpp: "0.5"}

      assert {:error, :invalid_alignment} =
               FloorplanTransform.svg_to_lat_lon(bad, 100, 100, %{x: 50.0, y: 50.0})
    end

    test "center_lat at pole makes longitude denominator zero" do
      bad = %{alignment() | center_lat: 90.0}

      assert {:error, :invalid_alignment} =
               FloorplanTransform.svg_to_lat_lon(bad, 100, 100, %{x: 50.0, y: 50.0})
    end

    test "non-map alignment" do
      assert {:error, :invalid_alignment} =
               FloorplanTransform.svg_to_lat_lon(nil, 100, 100, %{x: 50.0, y: 50.0})
    end
  end

  describe "svg_to_lat_lon/4 AC 8: invalid image dims" do
    test "zero width" do
      assert {:error, :invalid_image_dims} =
               FloorplanTransform.svg_to_lat_lon(alignment(), 0, 100, %{x: 50.0, y: 50.0})
    end

    test "negative height" do
      assert {:error, :invalid_image_dims} =
               FloorplanTransform.svg_to_lat_lon(alignment(), 100, -50, %{x: 50.0, y: 50.0})
    end

    test "non-integer dims" do
      assert {:error, :invalid_image_dims} =
               FloorplanTransform.svg_to_lat_lon(alignment(), 100.0, 100, %{x: 50.0, y: 50.0})
    end
  end

  describe "svg_to_lat_lon/4 AC 9: invalid point" do
    test "missing y" do
      assert {:error, :invalid_point} =
               FloorplanTransform.svg_to_lat_lon(alignment(), 100, 100, %{x: 50.0})
    end

    test "non-numeric values" do
      assert {:error, :invalid_point} =
               FloorplanTransform.svg_to_lat_lon(alignment(), 100, 100, %{x: "50", y: 50.0})
    end

    test "non-map point" do
      assert {:error, :invalid_point} =
               FloorplanTransform.svg_to_lat_lon(alignment(), 100, 100, nil)
    end
  end
end
