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

  describe "distance_meters/2 AC-1: zero distance" do
    test "identical coordinates return exactly 0.0" do
      point = {40.75, -73.99}

      assert FloorplanTransform.distance_meters(point, point) === 0.0
    end
  end

  describe "distance_meters/2 AC-1: one degree of latitude" do
    test "one degree latitude offset returns approximately 111_111 meters" do
      a = {0.0, 0.0}
      b = {1.0, 0.0}

      result = FloorplanTransform.distance_meters(a, b)

      assert_in_delta result, 111_111.0, 1.0
    end
  end

  describe "distance_meters/2 AC-1: longitude scaled by cosine of mean latitude" do
    test "one degree longitude at 60 degrees latitude is halved" do
      a = {60.0, 0.0}
      b = {60.0, 1.0}

      result = FloorplanTransform.distance_meters(a, b)

      expected = 111_111.0 * :math.cos(60.0 * :math.pi() / 180.0)
      assert_in_delta result, expected, 1.0
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

  # residual_rmse_meters/4 — a landscape image, a non-zero rotation and a
  # non-unit scale, so the score exercises the real projection rather than an
  # identity transform.
  @fit_image_w 800
  @fit_image_h 400
  @fit_points [{10.0, 5.0}, {40.0, 20.0}, {70.0, 40.0}, {90.0, 15.0}, {55.0, 30.0}]

  defp fit_alignment, do: alignment(%{scale_mpp: 0.35, rotation_deg: 17.0})

  # Anchors that agree perfectly with `align`: each one is a diagram point
  # projected through the alignment under test, so the true residual is zero.
  defp anchors_for(align, points \\ @fit_points) do
    Enum.map(points, fn {x, y} ->
      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(align, @fit_image_w, @fit_image_h, %{x: x, y: y})

      %{x: x, y: y, lat: lat, lon: lon}
    end)
  end

  # The same anchors, each pushed `offset_m` metres north of where `align`
  # projects it, so every anchor contributes a distinct non-zero residual.
  defp displaced_anchors(align, offsets_m) do
    align
    |> anchors_for()
    |> Enum.zip(offsets_m)
    |> Enum.map(fn {anchor, offset_m} ->
      %{anchor | lat: anchor.lat + offset_m / @meters_per_degree_lat}
    end)
  end

  defp score(align, anchors) do
    FloorplanTransform.residual_rmse_meters(align, @fit_image_w, @fit_image_h, anchors)
  end

  describe "residual_rmse_meters/4 AC-8: scoring an alignment against its anchors" do
    test "anchors projected through the alignment under test score zero" do
      align = fit_alignment()

      assert {:ok, %{rmse_meters: rmse, anchor_count: 5}} = score(align, anchors_for(align))

      assert_in_delta rmse, 0.0, 1.0e-6
    end

    test "displacing one of five anchors by 3 m returns sqrt(3^2 / 5) meters" do
      align = fit_alignment()
      [first | rest] = anchors_for(align)
      displaced = %{first | lat: first.lat + 3.0 / @meters_per_degree_lat}

      assert {:ok, %{rmse_meters: rmse, anchor_count: 5}} = score(align, [displaced | rest])

      assert_in_delta rmse, :math.sqrt(9.0 / 5.0), 1.0e-6
    end

    test "a displaced anchor scores strictly worse than the exact fit" do
      align = fit_alignment()
      [first | rest] = anchors_for(align)
      displaced = %{first | lat: first.lat + 3.0 / @meters_per_degree_lat}

      {:ok, %{rmse_meters: exact}} = score(align, [first | rest])
      {:ok, %{rmse_meters: worse}} = score(align, [displaced | rest])

      assert worse > exact
    end

    test "reordering the anchors returns an identical result" do
      align = fit_alignment()
      # Every anchor carries a distinct non-zero residual, so reordering
      # exercises a real five-term float sum rather than a trivial one. These
      # displacements are order-sensitive at the sum level — plain list order
      # gives 51.66999999495067 and swapping the middle pair gives
      # 51.669999994950665 — which is why the implementation sums in canonical
      # order. The subsequent divide-and-sqrt happens to absorb that particular
      # difference, so this asserts the contract, not the mechanism.
      [a, b, c, d, e] = displaced_anchors(align, [5.0, 0.8, 3.3, 3.5, 1.7])

      assert score(align, [a, b, c, d, e]) === score(align, [a, b, d, c, e])
      assert score(align, [a, b, c, d, e]) === score(align, [e, d, c, b, a])
    end
  end

  describe "residual_rmse_meters/4 AC-9: the three-anchor minimum" do
    test "two exactly-matching anchors report insufficient anchors, not a perfect fit" do
      align = fit_alignment()

      assert score(align, anchors_for(align, [{10.0, 5.0}, {70.0, 40.0}])) ==
               {:error, :insufficient_anchors}
    end

    test "an empty anchor list reports insufficient anchors" do
      assert score(fit_alignment(), []) == {:error, :insufficient_anchors}
    end

    test "exactly three usable anchors are scored" do
      align = fit_alignment()

      assert {:ok, %{anchor_count: 3}} =
               score(align, anchors_for(align, [{10.0, 5.0}, {40.0, 20.0}, {70.0, 40.0}]))
    end
  end

  describe "residual_rmse_meters/4 AC-9: invalid input is distinguished from missing anchors" do
    test "a non-numeric alignment field reports invalid alignment despite five usable anchors" do
      align = fit_alignment()

      assert score(%{align | scale_mpp: "0.35"}, anchors_for(align)) ==
               {:error, :invalid_alignment}
    end

    test "an alignment at the pole reports invalid alignment" do
      align = fit_alignment()

      assert score(%{align | center_lat: 90.0}, anchors_for(align)) ==
               {:error, :invalid_alignment}
    end

    test "invalid image dimensions report invalid image dims despite five usable anchors" do
      align = fit_alignment()

      assert FloorplanTransform.residual_rmse_meters(align, 0, @fit_image_h, anchors_for(align)) ==
               {:error, :invalid_image_dims}
    end

    test "an invalid alignment outranks a below-minimum anchor count" do
      align = fit_alignment()

      assert score(%{align | scale_mpp: "0.35"}, anchors_for(align, [{10.0, 5.0}, {70.0, 40.0}])) ==
               {:error, :invalid_alignment}
    end
  end

  describe "residual_rmse_meters/4 AC-10: unprojectable anchors are skipped" do
    test "an anchor with a non-numeric diagram x is skipped and anchor_count reports survivors" do
      align = fit_alignment()
      [a, b, c, d, e] = anchors_for(align)

      assert {:ok, %{rmse_meters: rmse, anchor_count: 4}} =
               score(align, [%{a | x: "10"}, b, c, d, e])

      assert_in_delta rmse, 0.0, 1.0e-6
    end

    test "an anchor with a non-numeric target latitude is skipped" do
      align = fit_alignment()
      [a, b, c, d, e] = anchors_for(align)

      assert {:ok, %{anchor_count: 4}} = score(align, [%{a | lat: nil}, b, c, d, e])
    end

    # `stops.stop_lat` / `stops.stop_lon` are `:decimal` columns, so a caller
    # that forwards them unconverted supplies a Decimal here. This function
    # takes numbers: a Decimal is skipped, not coerced and not fatal. Callers
    # convert first — `GtfsPlanner.Gtfs` already does, via `decimal_to_float/1`.
    test "an anchor whose target latitude is a Decimal is skipped, not coerced" do
      align = fit_alignment()
      [a, b, c, d, e] = anchors_for(align)

      assert {:ok, %{anchor_count: 4}} =
               score(align, [%{a | lat: Decimal.from_float(40.75)}, b, c, d, e])
    end

    test "an anchor that is not a map is skipped" do
      align = fit_alignment()
      [_a, b, c, d, e] = anchors_for(align)

      assert {:ok, %{anchor_count: 4}} = score(align, [nil, b, c, d, e])
    end

    test "the mean divides by surviving anchors, not by the input length" do
      align = fit_alignment()
      [a, b, c, d, e] = anchors_for(align)
      displaced = %{a | lat: a.lat + 3.0 / @meters_per_degree_lat}

      assert {:ok, %{rmse_meters: rmse, anchor_count: 4}} =
               score(align, [displaced, b, c, d, %{e | x: "55"}])

      assert_in_delta rmse, :math.sqrt(9.0 / 4.0), 1.0e-6
    end

    test "skipping below the minimum reports insufficient anchors" do
      align = fit_alignment()
      [a, b, c] = anchors_for(align, [{10.0, 5.0}, {40.0, 20.0}, {70.0, 40.0}])

      assert score(align, [%{a | y: "5"}, b, c]) == {:error, :insufficient_anchors}
    end
  end
end
