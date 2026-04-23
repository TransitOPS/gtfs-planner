defmodule GtfsPlanner.Gtfs.AlignmentInferenceTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.AlignmentInference
  alias GtfsPlanner.Gtfs.FloorplanTransform

  @image_w 200
  @image_h 100

  defp anchor_from_svg(alignment, image_w, image_h, stop_id, svg_x, svg_y) do
    {:ok, {lat, lon}} =
      FloorplanTransform.svg_to_lat_lon(alignment, image_w, image_h, %{x: svg_x, y: svg_y})

    %{
      stop_id: stop_id,
      source: :direct,
      svg_x: svg_x,
      svg_y: svg_y,
      lat: lat,
      lon: lon
    }
  end

  defp base_anchor do
    %{
      stop_id: "s1",
      source: :direct,
      svg_x: 30.0,
      svg_y: 40.0,
      lat: 40.75,
      lon: -73.99
    }
  end

  describe "invalid image dimensions" do
    test "zero width returns :invalid_input" do
      anchors = [base_anchor(), %{base_anchor() | stop_id: "s2", svg_x: 70.0}]
      assert {:error, :invalid_input} = AlignmentInference.infer_alignment(anchors, 0, 100)
    end

    test "negative height returns :invalid_input" do
      anchors = [base_anchor(), %{base_anchor() | stop_id: "s2", svg_x: 70.0}]
      assert {:error, :invalid_input} = AlignmentInference.infer_alignment(anchors, 100, -5)
    end

    test "non-integer dim returns :invalid_input" do
      anchors = [base_anchor(), %{base_anchor() | stop_id: "s2", svg_x: 70.0}]
      assert {:error, :invalid_input} = AlignmentInference.infer_alignment(anchors, 100.5, 100)
    end

    test "non-numeric anchor field returns :invalid_input" do
      bad = %{base_anchor() | svg_x: "30"}
      anchors = [bad, %{base_anchor() | stop_id: "s2", svg_x: 70.0}]
      assert {:error, :invalid_input} = AlignmentInference.infer_alignment(anchors, @image_w, @image_h)
    end
  end

  describe "insufficient anchors" do
    test "empty list returns :insufficient_anchors" do
      assert {:error, :insufficient_anchors} =
               AlignmentInference.infer_alignment([], @image_w, @image_h)
    end

    test "single anchor returns :insufficient_anchors" do
      assert {:error, :insufficient_anchors} =
               AlignmentInference.infer_alignment([base_anchor()], @image_w, @image_h)
    end
  end

  describe "degenerate geometry" do
    test "two anchors at identical SVG points returns :degenerate_geometry" do
      a1 = base_anchor()
      a2 = %{base_anchor() | stop_id: "s2", lat: 40.7501, lon: -73.9899}

      assert {:error, :degenerate_geometry} =
               AlignmentInference.infer_alignment([a1, a2], @image_w, @image_h)
    end

    test "two anchors at near-identical SVG points returns :degenerate_geometry" do
      a1 = base_anchor()
      a2 = %{base_anchor() | stop_id: "s2", svg_x: 30.0 + 1.0e-10, svg_y: 40.0 + 1.0e-10}

      assert {:error, :degenerate_geometry} =
               AlignmentInference.infer_alignment([a1, a2], @image_w, @image_h)
    end
  end

  describe "successful 2-anchor solve" do
    test "recovers known alignment within tight tolerance" do
      alignment = %{
        center_lat: 40.75,
        center_lon: -73.99,
        scale_mpp: 0.5,
        rotation_deg: 12.0
      }

      a1 = anchor_from_svg(alignment, @image_w, @image_h, "s1", 20.0, 30.0)
      a2 = anchor_from_svg(alignment, @image_w, @image_h, "s2", 80.0, 70.0)

      assert {:ok, result} =
               AlignmentInference.infer_alignment([a1, a2], @image_w, @image_h)

      assert_in_delta result.center_lat, alignment.center_lat, 1.0e-8
      assert_in_delta result.center_lon, alignment.center_lon, 1.0e-8
      assert_in_delta result.scale_mpp, alignment.scale_mpp, 1.0e-8
      assert_in_delta result.rotation_deg, alignment.rotation_deg, 1.0e-6
      assert result.rmse_meters == 0.0
      assert result.anchor_count == 2
    end

    test "recovers zero rotation alignment" do
      alignment = %{
        center_lat: 40.75,
        center_lon: -73.99,
        scale_mpp: 1.25,
        rotation_deg: 0.0
      }

      a1 = anchor_from_svg(alignment, @image_w, @image_h, "s1", 25.0, 25.0)
      a2 = anchor_from_svg(alignment, @image_w, @image_h, "s2", 75.0, 80.0)

      assert {:ok, result} =
               AlignmentInference.infer_alignment([a1, a2], @image_w, @image_h)

      assert_in_delta result.center_lat, alignment.center_lat, 1.0e-8
      assert_in_delta result.center_lon, alignment.center_lon, 1.0e-8
      assert_in_delta result.scale_mpp, alignment.scale_mpp, 1.0e-8
      assert_in_delta result.rotation_deg, alignment.rotation_deg, 1.0e-6
      assert result.rmse_meters == 0.0
    end
  end
end
