defmodule GtfsPlanner.GtfsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Level

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  describe "levels" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "create_level/1 creates a level with valid attrs", %{organization: org, gtfs_version: version} do
      attrs = valid_level_attrs()
      |> Map.put(:organization_id, org.id)
      |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, level} = Gtfs.create_level(attrs)
      assert level.level_id == attrs.level_id
      assert level.level_index == attrs.level_index
      assert level.organization_id == org.id
      assert level.gtfs_version_id == version.id
    end

    test "create_level/1 returns error with invalid attrs", %{organization: org, gtfs_version: version} do
      attrs = %{
        organization_id: org.id,
        gtfs_version_id: version.id,
        level_id: nil,
        level_index: nil
      }

      assert {:error, changeset} = Gtfs.create_level(attrs)
      assert %{level_id: ["can't be blank"], level_index: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_level/1 enforces unique level_id within organization and version", %{organization: org, gtfs_version: version} do
      attrs = valid_level_attrs()
      |> Map.put(:organization_id, org.id)
      |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, _level1} = Gtfs.create_level(attrs)
      assert {:error, changeset} = Gtfs.create_level(attrs)
      # Composite unique constraint error appears on organization_id field
      assert "has already been taken" in errors_on(changeset).organization_id
    end

    test "list_levels/2 returns levels for the given organization and version", %{organization: org, gtfs_version: version} do
      # Create levels for this org/version
      level1 = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})
      level2 = level_fixture(org.id, version.id, %{level_id: "L2", level_index: 1.0})

      # Create another org/version with its own levels
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      _other_level = level_fixture(other_org.id, other_version.id, %{level_id: "L1", level_index: 0.0})

      levels = Gtfs.list_levels(org.id, version.id)

      assert length(levels) == 2
      assert Enum.any?(levels, fn l -> l.id == level1.id end)
      assert Enum.any?(levels, fn l -> l.id == level2.id end)
      assert Enum.all?(levels, fn l -> l.organization_id == org.id end)
      assert Enum.all?(levels, fn l -> l.gtfs_version_id == version.id end)
    end

    test "list_levels/2 orders by level_index ascending", %{organization: org, gtfs_version: version} do
      level3 = level_fixture(org.id, version.id, %{level_id: "L3", level_index: 2.0})
      level1 = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})
      level2 = level_fixture(org.id, version.id, %{level_id: "L2", level_index: 1.0})

      levels = Gtfs.list_levels(org.id, version.id)

      # Check ordering by level_index
      assert Enum.map(levels, & &1.level_index) == [0.0, 1.0, 2.0]
      # Verify the correct IDs are present
      assert Enum.map(levels, & &1.id) == [level1.id, level2.id, level3.id]
    end

    test "get_level!/1 returns the level with the given id", %{organization: org, gtfs_version: version} do
      level = level_fixture(org.id, version.id)

      fetched_level = Gtfs.get_level!(level.id)
      assert fetched_level.id == level.id
      assert fetched_level.level_id == level.level_id
    end

    test "get_level!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Gtfs.get_level!(Ecto.UUID.generate())
      end
    end

    test "get_level/1 returns nil for non-existent id" do
      assert Gtfs.get_level(Ecto.UUID.generate()) == nil
    end

    test "get_level_by_level_id/3 returns the level within organization and version", %{organization: org, gtfs_version: version} do
      level = level_fixture(org.id, version.id, %{level_id: "SPECIAL"})

      # Should find the level
      assert Gtfs.get_level_by_level_id(org.id, version.id, "SPECIAL").id == level.id

      # Should not find with wrong level_id
      assert Gtfs.get_level_by_level_id(org.id, version.id, "NONEXISTENT") == nil

      # Should not find with wrong organization
      other_org = organization_fixture()
      assert Gtfs.get_level_by_level_id(other_org.id, version.id, "SPECIAL") == nil

      # Should not find with wrong version
      other_version = gtfs_version_fixture(org.id)
      assert Gtfs.get_level_by_level_id(org.id, other_version.id, "SPECIAL") == nil
    end

    test "update_level/2 updates a level with valid attrs", %{organization: org, gtfs_version: version} do
      level = level_fixture(org.id, version.id)

      update_attrs = %{level_name: "Updated Name", level_index: 5.0}
      assert {:ok, updated_level} = Gtfs.update_level(level, update_attrs)
      assert updated_level.level_name == "Updated Name"
      assert updated_level.level_index == 5.0
      assert updated_level.id == level.id
    end

    test "update_level/2 returns error with invalid attrs", %{organization: org, gtfs_version: version} do
      level = level_fixture(org.id, version.id)

      assert {:error, changeset} = Gtfs.update_level(level, %{level_id: nil})
      assert %{level_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "delete_level/1 deletes the level", %{organization: org, gtfs_version: version} do
      level = level_fixture(org.id, version.id)

      assert {:ok, %Level{}} = Gtfs.delete_level(level)
      assert Gtfs.get_level(level.id) == nil
    end

    test "change_level/2 returns a level changeset", %{organization: org, gtfs_version: version} do
      level = level_fixture(org.id, version.id)
      assert %Ecto.Changeset{} = Gtfs.change_level(level)
    end
  end

  describe "stops" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "create_stop/1 creates a stop with valid attrs", %{organization: org, gtfs_version: version} do
      attrs = valid_stop_attrs()
      |> Map.put(:organization_id, org.id)
      |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, stop} = Gtfs.create_stop(attrs)
      assert stop.stop_id == attrs.stop_id
      assert stop.stop_name == attrs.stop_name
      assert stop.organization_id == org.id
      assert stop.gtfs_version_id == version.id
    end

    test "create_stop/1 returns error with invalid attrs", %{organization: org, gtfs_version: version} do
      attrs = %{
        organization_id: org.id,
        gtfs_version_id: version.id,
        stop_id: nil
      }

      assert {:error, changeset} = Gtfs.create_stop(attrs)
      assert %{stop_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "list_stops/2 returns stops for the given organization and version", %{organization: org, gtfs_version: version} do
      stop1 = stop_fixture(org.id, version.id, %{stop_id: "stop1"})
      stop2 = stop_fixture(org.id, version.id, %{stop_id: "stop2"})

      # Create another org/version with its own stops
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      _other_stop = stop_fixture(other_org.id, other_version.id, %{stop_id: "stop1"})

      stops = Gtfs.list_stops(org.id, version.id)

      assert length(stops) == 2
      assert Enum.any?(stops, fn s -> s.id == stop1.id end)
      assert Enum.any?(stops, fn s -> s.id == stop2.id end)
      assert Enum.all?(stops, fn s -> s.organization_id == org.id end)
      assert Enum.all?(stops, fn s -> s.gtfs_version_id == version.id end)
    end

    test "create_stop/1 enforces unique stop_id within organization and version", %{organization: org, gtfs_version: version} do
      attrs = valid_stop_attrs()
      |> Map.put(:organization_id, org.id)
      |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, _stop1} = Gtfs.create_stop(attrs)
      assert {:error, changeset} = Gtfs.create_stop(attrs)
      # Composite unique constraint error appears on organization_id field
      assert "has already been taken" in errors_on(changeset).organization_id
    end

    test "get_stop!/1 returns the stop with the given id", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id)

      fetched_stop = Gtfs.get_stop!(stop.id)
      assert fetched_stop.id == stop.id
      assert fetched_stop.stop_id == stop.stop_id
    end

    test "get_stop!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Gtfs.get_stop!(Ecto.UUID.generate())
      end
    end

    test "get_stop/1 returns nil for non-existent id" do
      assert Gtfs.get_stop(Ecto.UUID.generate()) == nil
    end

    test "get_stop_by_stop_id/3 returns the stop within organization and version", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id, %{stop_id: "SPECIAL"})

      # Should find the stop
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "SPECIAL").id == stop.id

      # Should not find with wrong stop_id
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "NONEXISTENT") == nil

      # Should not find with wrong organization
      other_org = organization_fixture()
      assert Gtfs.get_stop_by_stop_id(other_org.id, version.id, "SPECIAL") == nil

      # Should not find with wrong version
      other_version = gtfs_version_fixture(org.id)
      assert Gtfs.get_stop_by_stop_id(org.id, other_version.id, "SPECIAL") == nil
    end

    test "update_stop/2 updates a stop with valid attrs", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id)

      update_attrs = %{stop_name: "Updated Station Name", stop_lat: Decimal.new("40.7128")}
      assert {:ok, updated_stop} = Gtfs.update_stop(stop, update_attrs)
      assert updated_stop.stop_name == "Updated Station Name"
      assert updated_stop.stop_lat == Decimal.new("40.7128")
      assert updated_stop.id == stop.id
    end

    test "update_stop/2 returns error with invalid attrs", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id)

      assert {:error, changeset} = Gtfs.update_stop(stop, %{stop_id: nil})
      assert %{stop_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "delete_stop/1 deletes the stop", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id)

      assert {:ok, %GtfsPlanner.Gtfs.Stop{}} = Gtfs.delete_stop(stop)
      assert Gtfs.get_stop(stop.id) == nil
    end

    test "change_stop/2 returns a stop changeset", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id)
      assert %Ecto.Changeset{} = Gtfs.change_stop(stop)
    end
  end
end
