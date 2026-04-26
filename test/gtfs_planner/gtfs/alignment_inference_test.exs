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

      assert {:error, :invalid_input} =
               AlignmentInference.infer_alignment(anchors, @image_w, @image_h)
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

    test "anchor_minimum/0 returns the threshold used by infer_alignment/3" do
      below = List.duplicate(base_anchor(), AlignmentInference.anchor_minimum() - 1)

      assert {:error, :insufficient_anchors} =
               AlignmentInference.infer_alignment(below, 1024, 768)
    end
  end

  describe "degenerate geometry" do
    test "anchors at identical SVG points return :degenerate_geometry" do
      a1 = base_anchor()
      a2 = %{base_anchor() | stop_id: "s2", lat: 40.7501, lon: -73.9899}
      a3 = %{base_anchor() | stop_id: "s3", lat: 40.7502, lon: -73.9898}

      assert {:error, :degenerate_geometry} =
               AlignmentInference.infer_alignment([a1, a2, a3], @image_w, @image_h)
    end

    test "anchors at near-identical SVG points return :degenerate_geometry" do
      a1 = base_anchor()
      a2 = %{base_anchor() | stop_id: "s2", svg_x: 30.0 + 1.0e-10, svg_y: 40.0 + 1.0e-10}
      a3 = %{base_anchor() | stop_id: "s3", svg_x: 30.0 + 2.0e-10, svg_y: 40.0 + 2.0e-10}

      assert {:error, :degenerate_geometry} =
               AlignmentInference.infer_alignment([a1, a2, a3], @image_w, @image_h)
    end
  end

  describe "successful anchor solve" do
    test "recovers known alignment within tight tolerance" do
      alignment = %{
        center_lat: 40.75,
        center_lon: -73.99,
        scale_mpp: 0.5,
        rotation_deg: 12.0
      }

      a1 = anchor_from_svg(alignment, @image_w, @image_h, "s1", 20.0, 30.0)
      a2 = anchor_from_svg(alignment, @image_w, @image_h, "s2", 80.0, 70.0)
      a3 = anchor_from_svg(alignment, @image_w, @image_h, "s3", 45.0, 82.0)

      assert {:ok, result} =
               AlignmentInference.infer_alignment([a1, a2, a3], @image_w, @image_h)

      assert_in_delta result.center_lat, alignment.center_lat, 1.0e-8
      assert_in_delta result.center_lon, alignment.center_lon, 1.0e-8
      assert_in_delta result.scale_mpp, alignment.scale_mpp, 1.0e-8
      assert_in_delta result.rotation_deg, alignment.rotation_deg, 1.0e-6
      assert_in_delta result.rmse_meters, 0.0, 1.0e-8
      assert result.anchor_count == 3
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
      a3 = anchor_from_svg(alignment, @image_w, @image_h, "s3", 42.0, 55.0)

      assert {:ok, result} =
               AlignmentInference.infer_alignment([a1, a2, a3], @image_w, @image_h)

      assert_in_delta result.center_lat, alignment.center_lat, 1.0e-8
      assert_in_delta result.center_lon, alignment.center_lon, 1.0e-8
      assert_in_delta result.scale_mpp, alignment.scale_mpp, 1.0e-8
      assert_in_delta result.rotation_deg, alignment.rotation_deg, 1.0e-6
      assert_in_delta result.rmse_meters, 0.0, 1.0e-8
    end
  end

  describe "select_anchors/2" do
    defp direct_cand(stop_id, opts \\ []) do
      %{
        stop_id: stop_id,
        svg_x: Keyword.get(opts, :svg_x, 30.0),
        svg_y: Keyword.get(opts, :svg_y, 40.0),
        lat: Keyword.get(opts, :lat, 40.75),
        lon: Keyword.get(opts, :lon, -73.99)
      }
    end

    defp cross_cand(stop_id, pathway_id, opts \\ []) do
      %{
        stop_id: stop_id,
        pathway_id: pathway_id,
        pathway_mode: Keyword.get(opts, :pathway_mode, 5),
        level_index_delta: Keyword.get(opts, :level_index_delta, 1),
        svg_x: Keyword.get(opts, :svg_x, 50.0),
        svg_y: Keyword.get(opts, :svg_y, 50.0),
        lat: Keyword.get(opts, :lat, 40.76),
        lon: Keyword.get(opts, :lon, -73.98)
      }
    end

    test "complete direct candidate becomes anchor with no exclusions" do
      {anchors, exclusions} = AlignmentInference.select_anchors([direct_cand("s1")], [])

      assert [
               %{
                 stop_id: "s1",
                 source: :direct,
                 svg_x: 30.0,
                 svg_y: 40.0,
                 lat: 40.75,
                 lon: -73.99
               }
             ] = anchors

      assert exclusions == []
    end

    test "direct candidate missing svg_x is excluded as :nil_coordinate" do
      cand = direct_cand("s1", svg_x: nil)

      {anchors, exclusions} = AlignmentInference.select_anchors([cand], [])

      assert anchors == []

      assert exclusions == [
               %{stop_id: "s1", reason: :nil_coordinate, source: :direct, pathway_id: nil}
             ]
    end

    test "direct candidate missing lat/lon is excluded as :nil_latlon" do
      cand = direct_cand("s1", lat: nil, lon: nil)

      {anchors, exclusions} = AlignmentInference.select_anchors([cand], [])

      assert anchors == []

      assert exclusions == [
               %{stop_id: "s1", reason: :nil_latlon, source: :direct, pathway_id: nil}
             ]
    end

    test "direct candidate missing both svg and lat/lon reports :nil_coordinate" do
      cand = direct_cand("s1", svg_x: nil, lat: nil, lon: nil)

      {_, exclusions} = AlignmentInference.select_anchors([cand], [])

      assert exclusions == [
               %{stop_id: "s1", reason: :nil_coordinate, source: :direct, pathway_id: nil}
             ]
    end

    test "non-elevator cross-level modes are excluded as :non_elevator_mode" do
      cands =
        for {mode, i} <- Enum.with_index([1, 2, 3, 4, 6, 7]) do
          cross_cand("s#{i}", "p#{i}", pathway_mode: mode)
        end

      {anchors, exclusions} = AlignmentInference.select_anchors([], cands)

      assert anchors == []
      assert length(exclusions) == 6
      assert Enum.all?(exclusions, &(&1.reason == :non_elevator_mode))
      assert Enum.all?(exclusions, &(&1.source == :cross_level))
    end

    test "cross-level elevator candidate with missing svg excluded as :nil_coordinate" do
      cand = cross_cand("s1", "pa", svg_x: nil)

      {anchors, exclusions} = AlignmentInference.select_anchors([], [cand])

      assert anchors == []

      assert exclusions == [
               %{stop_id: "s1", reason: :nil_coordinate, source: :cross_level, pathway_id: "pa"}
             ]
    end

    test "cross-level elevator candidate with nil partner lat/lon excluded as :nil_latlon" do
      cand = cross_cand("s1", "pa", lat: nil, lon: nil)

      {anchors, exclusions} = AlignmentInference.select_anchors([], [cand])

      assert anchors == []

      assert exclusions == [
               %{stop_id: "s1", reason: :nil_latlon, source: :cross_level, pathway_id: "pa"}
             ]
    end

    test "cross-level anchor shadowed by direct anchor for same stop" do
      direct = direct_cand("s1")
      cross = cross_cand("s1", "pa")

      {anchors, exclusions} = AlignmentInference.select_anchors([direct], [cross])

      assert [%{stop_id: "s1", source: :direct}] = anchors

      assert exclusions == [
               %{
                 stop_id: "s1",
                 reason: :shadowed_by_direct,
                 source: :cross_level,
                 pathway_id: "pa"
               }
             ]
    end

    test "multi-candidate tie-break by minimum level_index_delta" do
      near = cross_cand("s1", "pa", level_index_delta: 1)
      far = cross_cand("s1", "pb", level_index_delta: 3, svg_x: 60.0)

      {anchors, exclusions} = AlignmentInference.select_anchors([], [near, far])

      assert [%{stop_id: "s1", source: :cross_level, svg_x: 50.0}] = anchors

      assert exclusions == [
               %{stop_id: "s1", reason: :lost_tie_break, source: :cross_level, pathway_id: "pb"}
             ]
    end

    test "tie on delta breaks by ascending pathway_id" do
      c1 = cross_cand("s1", "pb", level_index_delta: 2)
      c2 = cross_cand("s1", "pa", level_index_delta: 2, svg_x: 60.0)

      {anchors, exclusions} = AlignmentInference.select_anchors([], [c1, c2])

      assert [%{stop_id: "s1", source: :cross_level, svg_x: 60.0}] = anchors

      assert exclusions == [
               %{stop_id: "s1", reason: :lost_tie_break, source: :cross_level, pathway_id: "pb"}
             ]
    end

    test "absolute value of level_index_delta drives tie-break" do
      near_neg = cross_cand("s1", "pa", level_index_delta: -1)
      far_pos = cross_cand("s1", "pb", level_index_delta: 2, svg_x: 60.0)

      {anchors, exclusions} = AlignmentInference.select_anchors([], [near_neg, far_pos])

      assert [%{stop_id: "s1", source: :cross_level, svg_x: 50.0}] = anchors

      assert Enum.map(exclusions, & &1.pathway_id) == ["pb"]
    end

    test "anchors returned sorted by stop_id" do
      directs = [
        direct_cand("s3"),
        direct_cand("s1"),
        direct_cand("s2")
      ]

      cross = [cross_cand("s4", "pa")]

      {anchors, _} = AlignmentInference.select_anchors(directs, cross)

      assert Enum.map(anchors, & &1.stop_id) == ["s1", "s2", "s3", "s4"]
    end

    test "exclusions sorted by {stop_id, reason}" do
      directs = [
        direct_cand("s2", svg_x: nil),
        direct_cand("s1", lat: nil, lon: nil)
      ]

      cross = [
        cross_cand("s1", "pa", pathway_mode: 1),
        cross_cand("s3", "pb", pathway_mode: 2)
      ]

      {_, exclusions} = AlignmentInference.select_anchors(directs, cross)

      assert Enum.map(exclusions, &{&1.stop_id, &1.reason}) == [
               {"s1", :nil_latlon},
               {"s1", :non_elevator_mode},
               {"s2", :nil_coordinate},
               {"s3", :non_elevator_mode}
             ]
    end
  end
end
