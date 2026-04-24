defmodule GtfsPlanner.Gtfs.StopLevelTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StopLevel

  describe "alignment_changeset/2" do
    test "is valid when all four fields are set with valid values" do
      attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.0060,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 15.0
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      assert changeset.valid?
    end

    test "is valid when all four fields are nil" do
      attrs = %{
        floorplan_center_lat: nil,
        floorplan_center_lon: nil,
        floorplan_scale_mpp: nil,
        floorplan_rotation_deg: nil
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      assert changeset.valid?
    end

    test "is valid when no alignment fields are provided" do
      changeset = StopLevel.alignment_changeset(%StopLevel{}, %{})

      assert changeset.valid?
    end

    test "is invalid when three fields are set and one is nil (all-or-none)" do
      attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.0060,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: nil
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_center_lat)
    end

    test "is invalid when only one field is set" do
      attrs = %{floorplan_center_lat: 40.7128}

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_center_lat)
    end

    test "is invalid when latitude is greater than 90" do
      attrs = %{
        floorplan_center_lat: 91.0,
        floorplan_center_lon: -74.0060,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 0.0
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_center_lat)
    end

    test "is invalid when latitude is less than -90" do
      attrs = %{
        floorplan_center_lat: -91.0,
        floorplan_center_lon: -74.0060,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 0.0
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_center_lat)
    end

    test "is invalid when longitude is greater than 180" do
      attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: 181.0,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 0.0
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_center_lon)
    end

    test "is invalid when longitude is less than -180" do
      attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -181.0,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 0.0
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_center_lon)
    end

    test "is invalid when floorplan_scale_mpp is zero" do
      attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.0060,
        floorplan_scale_mpp: 0.0,
        floorplan_rotation_deg: 0.0
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_scale_mpp)
    end

    test "is invalid when floorplan_scale_mpp is negative" do
      attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.0060,
        floorplan_scale_mpp: -0.25,
        floorplan_rotation_deg: 0.0
      }

      changeset = StopLevel.alignment_changeset(%StopLevel{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :floorplan_scale_mpp)
    end
  end
end
