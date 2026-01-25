defmodule GtfsPlanner.Gtfs.RoutePatternTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.RoutePattern

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 0,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      assert changeset.valid?
    end

    test "valid changeset with all fields" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 1,
        route_pattern_name: "Inbound to Downtown",
        route_pattern_time_desc: "Weekday Morning",
        route_pattern_typicality: 1,
        route_pattern_sort_order: 10,
        representative_trip_id: "trip-123",
        canonical_route_pattern: 1,
        active: true,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      assert changeset.valid?
    end

    test "invalid changeset missing route_pattern_id" do
      attrs = %{
        route_id: "route-1",
        direction_id: 0,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{route_pattern_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing route_id" do
      attrs = %{
        route_pattern_id: "pattern-1",
        direction_id: 0,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{route_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing direction_id" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{direction_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset with direction_id less than 0" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: -1,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{direction_id: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with direction_id greater than 1" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 2,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{direction_id: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with route_pattern_typicality less than 0" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 0,
        route_pattern_typicality: -1,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{route_pattern_typicality: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with route_pattern_typicality greater than 5" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 0,
        route_pattern_typicality: 6,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{route_pattern_typicality: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with canonical_route_pattern less than 0" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 0,
        canonical_route_pattern: -1,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{canonical_route_pattern: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with canonical_route_pattern greater than 2" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 0,
        canonical_route_pattern: 3,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?
      assert %{canonical_route_pattern: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset with negative route_pattern_sort_order" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 0,
        route_pattern_sort_order: -1,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      refute changeset.valid?

      assert %{route_pattern_sort_order: ["must be greater than or equal to 0"]} =
               errors_on(changeset)
    end

    test "valid changeset with route_pattern_sort_order of 0" do
      attrs = %{
        route_pattern_id: "pattern-1",
        route_id: "route-1",
        direction_id: 0,
        route_pattern_sort_order: 0,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      changeset = RoutePattern.changeset(%RoutePattern{}, attrs)

      assert changeset.valid?
    end
  end

  describe "typicality_label/1" do
    test "returns correct label for typicality value 0" do
      assert RoutePattern.typicality_label(0) == "Not defined"
    end

    test "returns correct label for typicality value 1" do
      assert RoutePattern.typicality_label(1) == "Typical"
    end

    test "returns correct label for typicality value 2" do
      assert RoutePattern.typicality_label(2) == "Deviation"
    end

    test "returns correct label for typicality value 3" do
      assert RoutePattern.typicality_label(3) == "Atypical"
    end

    test "returns correct label for typicality value 4" do
      assert RoutePattern.typicality_label(4) == "Diversion"
    end

    test "returns correct label for typicality value 5" do
      assert RoutePattern.typicality_label(5) == "Canonical reference"
    end

    test "returns 'Unknown' for invalid typicality value" do
      assert RoutePattern.typicality_label(99) == "Unknown"
      assert RoutePattern.typicality_label(-1) == "Unknown"
    end
  end
end
