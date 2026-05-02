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

  describe "alignment_complete?/1" do
    test "returns true when all four alignment fields are present and valid" do
      stop_level = %StopLevel{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 15.0
      }

      assert StopLevel.alignment_complete?(stop_level)
    end

    test "returns false when any alignment field is missing" do
      stop_level = %StopLevel{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: nil,
        floorplan_rotation_deg: 15.0
      }

      refute StopLevel.alignment_complete?(stop_level)
    end

    test "returns false when scale is not positive" do
      stop_level = %StopLevel{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.0,
        floorplan_rotation_deg: 15.0
      }

      refute StopLevel.alignment_complete?(stop_level)
    end

    test "returns false when latitude is outside valid range" do
      stop_level = %StopLevel{
        floorplan_center_lat: 91.0,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 15.0
      }

      refute StopLevel.alignment_complete?(stop_level)
    end

    test "returns false when longitude is outside valid range" do
      stop_level = %StopLevel{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -181.0,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 15.0
      }

      refute StopLevel.alignment_complete?(stop_level)
    end
  end

  describe "saved_synced_alignment_changeset/2" do
    test "is valid when saved_synced_alignment is true" do
      changeset =
        StopLevel.saved_synced_alignment_changeset(%StopLevel{}, %{saved_synced_alignment: true})

      assert changeset.valid?
    end

    test "is valid when saved_synced_alignment is false" do
      changeset =
        StopLevel.saved_synced_alignment_changeset(%StopLevel{}, %{saved_synced_alignment: false})

      assert changeset.valid?
    end

    test "is invalid when saved_synced_alignment is nil" do
      changeset =
        StopLevel.saved_synced_alignment_changeset(%StopLevel{}, %{saved_synced_alignment: nil})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :saved_synced_alignment)
    end
  end

  describe "alignment_transform/1" do
    test "returns normalized transform when all alignment fields are valid" do
      stop_level = %StopLevel{
        floorplan_center_lat: 40,
        floorplan_center_lon: -74,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 15
      }

      assert {:ok, transform} = StopLevel.alignment_transform(stop_level)

      assert transform == %{
               center_lat: 40.0,
               center_lon: -74.0,
               scale_mpp: 0.25,
               rotation_deg: 15.0
             }
    end

    test "returns alignment_missing when any alignment field is nil" do
      stop_level = %StopLevel{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: nil,
        floorplan_rotation_deg: 15.0
      }

      assert {:error, :alignment_missing} = StopLevel.alignment_transform(stop_level)
    end

    test "returns invalid_alignment when latitude is out of range" do
      stop_level = %StopLevel{
        floorplan_center_lat: 91.0,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.25,
        floorplan_rotation_deg: 15.0
      }

      assert {:error, :invalid_alignment} = StopLevel.alignment_transform(stop_level)
    end

    test "returns invalid_alignment when scale is not positive" do
      stop_level = %StopLevel{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.0,
        floorplan_rotation_deg: 15.0
      }

      assert {:error, :invalid_alignment} = StopLevel.alignment_transform(stop_level)
    end
  end

  describe "invert_alignment_transform/1" do
    test "returns inverted transform when input is valid" do
      transform = %{
        center_lat: 40.7128,
        center_lon: -74.0060,
        scale_mpp: 0.25,
        rotation_deg: 30.0
      }

      assert {:ok, inverted} = StopLevel.invert_alignment_transform(transform)

      assert inverted == %{
               center_lat: -40.7128,
               center_lon: 74.006,
               scale_mpp: 4.0,
               rotation_deg: -30.0
             }
    end

    test "returns non_invertible_transform when scale is zero" do
      transform = %{
        center_lat: 40.7128,
        center_lon: -74.0060,
        scale_mpp: 0.0,
        rotation_deg: 30.0
      }

      assert {:error, :non_invertible_transform} = StopLevel.invert_alignment_transform(transform)
    end

    test "returns invalid_transform when scale is negative" do
      transform = %{
        center_lat: 40.7128,
        center_lon: -74.0060,
        scale_mpp: -0.25,
        rotation_deg: 30.0
      }

      assert {:error, :invalid_transform} = StopLevel.invert_alignment_transform(transform)
    end

    test "returns invalid_transform when required keys are missing" do
      assert {:error, :invalid_transform} =
               StopLevel.invert_alignment_transform(%{center_lat: 40.7128, center_lon: -74.0060})
    end

    test "returns invalid_transform when input is not a map" do
      assert {:error, :invalid_transform} = StopLevel.invert_alignment_transform(nil)
    end
  end

  describe "compose_alignment_transforms/2" do
    test "returns composed transform for valid inputs" do
      left = %{
        center_lat: 40.0,
        center_lon: -74.0,
        scale_mpp: 2.0,
        rotation_deg: 10.0
      }

      right = %{
        center_lat: 1.5,
        center_lon: -0.5,
        scale_mpp: 0.5,
        rotation_deg: -4.0
      }

      assert {:ok, composed} = StopLevel.compose_alignment_transforms(left, right)

      assert composed == %{
               center_lat: 41.5,
               center_lon: -74.5,
               scale_mpp: 1.0,
               rotation_deg: 6.0
             }
    end

    test "returns invalid_transform when left input is invalid" do
      right = %{
        center_lat: 1.5,
        center_lon: -0.5,
        scale_mpp: 0.5,
        rotation_deg: -4.0
      }

      assert {:error, :invalid_transform} =
               StopLevel.compose_alignment_transforms(%{center_lat: 40.0}, right)
    end

    test "returns invalid_transform when right input is invalid" do
      left = %{
        center_lat: 40.0,
        center_lon: -74.0,
        scale_mpp: 2.0,
        rotation_deg: 10.0
      }

      assert {:error, :invalid_transform} =
               StopLevel.compose_alignment_transforms(left, %{scale_mpp: 0.0})
    end

    test "returns invalid_transform when input is not a map" do
      left = %{
        center_lat: 40.0,
        center_lon: -74.0,
        scale_mpp: 2.0,
        rotation_deg: 10.0
      }

      assert {:error, :invalid_transform} = StopLevel.compose_alignment_transforms(left, nil)
    end
  end

  describe "active_alignment_delta/2" do
    test "returns delta transform as T_new composed with inverse(T_old)" do
      old_alignment = %{
        floorplan_center_lat: 0.0,
        floorplan_center_lon: 0.0,
        floorplan_scale_mpp: 2.0,
        floorplan_rotation_deg: 20.0
      }

      new_alignment = %{
        floorplan_center_lat: 44.0,
        floorplan_center_lon: -70.0,
        floorplan_scale_mpp: 5.0,
        floorplan_rotation_deg: 35.0
      }

      assert {:ok, delta} = StopLevel.active_alignment_delta(old_alignment, new_alignment)

      assert delta == %{
               center_lat: 44.0,
               center_lon: -70.0,
               scale_mpp: 2.5,
               rotation_deg: 15.0
             }
    end

    test "returns alignment_missing when old alignment is incomplete" do
      old_alignment = %{
        floorplan_center_lat: 40.0,
        floorplan_center_lon: -74.0,
        floorplan_scale_mpp: nil,
        floorplan_rotation_deg: 20.0
      }

      new_alignment = %{
        floorplan_center_lat: 44.0,
        floorplan_center_lon: -70.0,
        floorplan_scale_mpp: 5.0,
        floorplan_rotation_deg: 35.0
      }

      assert {:error, :alignment_missing} =
               StopLevel.active_alignment_delta(old_alignment, new_alignment)
    end

    test "returns invalid_alignment when old alignment scale is not positive" do
      old_alignment = %{
        floorplan_center_lat: 40.0,
        floorplan_center_lon: -74.0,
        floorplan_scale_mpp: -2.0,
        floorplan_rotation_deg: 20.0
      }

      new_alignment = %{
        floorplan_center_lat: 44.0,
        floorplan_center_lon: -70.0,
        floorplan_scale_mpp: 5.0,
        floorplan_rotation_deg: 35.0
      }

      assert {:error, :invalid_alignment} =
               StopLevel.active_alignment_delta(old_alignment, new_alignment)
    end

    test "returns invalid_alignment when new alignment is invalid" do
      old_alignment = %{
        floorplan_center_lat: 40.0,
        floorplan_center_lon: -74.0,
        floorplan_scale_mpp: 2.0,
        floorplan_rotation_deg: 20.0
      }

      new_alignment = %{
        floorplan_center_lat: 44.0,
        floorplan_center_lon: 190.0,
        floorplan_scale_mpp: 5.0,
        floorplan_rotation_deg: 35.0
      }

      assert {:error, :invalid_alignment} =
               StopLevel.active_alignment_delta(old_alignment, new_alignment)
    end
  end
end
