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

    test "create_level/1 creates a level with valid attrs", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_level_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, level} = Gtfs.create_level(attrs)
      assert level.level_id == attrs.level_id
      assert level.level_index == attrs.level_index
      assert level.organization_id == org.id
      assert level.gtfs_version_id == version.id
    end

    test "create_level/1 returns error with invalid attrs", %{
      organization: org,
      gtfs_version: version
    } do
      attrs = %{
        organization_id: org.id,
        gtfs_version_id: version.id,
        level_id: nil,
        level_index: nil
      }

      assert {:error, changeset} = Gtfs.create_level(attrs)

      assert %{level_id: ["can't be blank"], level_index: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "create_level/1 enforces unique level_id within organization and version", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_level_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, _level1} = Gtfs.create_level(attrs)
      assert {:error, changeset} = Gtfs.create_level(attrs)
      # Composite unique constraint error appears on organization_id field
      assert "has already been taken" in errors_on(changeset).organization_id
    end

    test "list_levels/2 returns levels for the given organization and version", %{
      organization: org,
      gtfs_version: version
    } do
      # Create levels for this org/version
      level1 = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})
      level2 = level_fixture(org.id, version.id, %{level_id: "L2", level_index: 1.0})

      # Create another org/version with its own levels
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      _other_level =
        level_fixture(other_org.id, other_version.id, %{level_id: "L1", level_index: 0.0})

      levels = Gtfs.list_levels(org.id, version.id)

      assert length(levels) == 2
      assert Enum.any?(levels, fn l -> l.id == level1.id end)
      assert Enum.any?(levels, fn l -> l.id == level2.id end)
      assert Enum.all?(levels, fn l -> l.organization_id == org.id end)
      assert Enum.all?(levels, fn l -> l.gtfs_version_id == version.id end)
    end

    test "list_levels/2 orders by level_index ascending", %{
      organization: org,
      gtfs_version: version
    } do
      level3 = level_fixture(org.id, version.id, %{level_id: "L3", level_index: 2.0})
      level1 = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})
      level2 = level_fixture(org.id, version.id, %{level_id: "L2", level_index: 1.0})

      levels = Gtfs.list_levels(org.id, version.id)

      # Check ordering by level_index
      assert Enum.map(levels, & &1.level_index) == [0.0, 1.0, 2.0]
      # Verify the correct IDs are present
      assert Enum.map(levels, & &1.id) == [level1.id, level2.id, level3.id]
    end

    test "get_level!/1 returns the level with the given id", %{
      organization: org,
      gtfs_version: version
    } do
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

    test "get_level_by_level_id/3 returns the level within organization and version", %{
      organization: org,
      gtfs_version: version
    } do
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

    test "update_level/2 updates a level with valid attrs", %{
      organization: org,
      gtfs_version: version
    } do
      level = level_fixture(org.id, version.id)

      update_attrs = %{level_name: "Updated Name", level_index: 5.0}
      assert {:ok, updated_level} = Gtfs.update_level(level, update_attrs)
      assert updated_level.level_name == "Updated Name"
      assert updated_level.level_index == 5.0
      assert updated_level.id == level.id
    end

    test "update_level/2 returns error with invalid attrs", %{
      organization: org,
      gtfs_version: version
    } do
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

    test "create_stop/1 creates a stop with valid attrs", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_stop_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, stop} = Gtfs.create_stop(attrs)
      assert stop.stop_id == attrs.stop_id
      assert stop.stop_name == attrs.stop_name
      assert stop.organization_id == org.id
      assert stop.gtfs_version_id == version.id
    end

    test "create_stop/1 returns error with invalid attrs", %{
      organization: org,
      gtfs_version: version
    } do
      attrs = %{
        organization_id: org.id,
        gtfs_version_id: version.id,
        stop_id: nil
      }

      assert {:error, changeset} = Gtfs.create_stop(attrs)
      assert %{stop_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_stop/1 requires level_id when parent_station is set", %{
      organization: org,
      gtfs_version: version
    } do
      station = stop_fixture(org.id, version.id, %{stop_id: "PARENT_STATION", location_type: 1})

      attrs =
        valid_stop_attrs(%{
          stop_id: "CHILD_NO_LEVEL",
          parent_station: station.stop_id,
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      assert {:error, changeset} = Gtfs.create_stop(attrs)
      assert %{level_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "list_stops/2 returns stops for the given organization and version", %{
      organization: org,
      gtfs_version: version
    } do
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

    test "create_stop/1 enforces unique stop_id within organization and version", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_stop_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, _stop1} = Gtfs.create_stop(attrs)
      assert {:error, changeset} = Gtfs.create_stop(attrs)
      # Composite unique constraint error appears on organization_id field
      assert "has already been taken" in errors_on(changeset).organization_id
    end

    test "get_stop!/1 returns the stop with the given id", %{
      organization: org,
      gtfs_version: version
    } do
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

    test "get_stop_by_stop_id/3 returns the stop within organization and version", %{
      organization: org,
      gtfs_version: version
    } do
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

    test "update_stop/2 updates a stop with valid attrs", %{
      organization: org,
      gtfs_version: version
    } do
      stop = stop_fixture(org.id, version.id)

      update_attrs = %{stop_name: "Updated Station Name", stop_lat: Decimal.new("40.7128")}
      assert {:ok, updated_stop} = Gtfs.update_stop(stop, update_attrs)
      assert updated_stop.stop_name == "Updated Station Name"
      assert updated_stop.stop_lat == Decimal.new("40.7128")
      assert updated_stop.id == stop.id
    end

    test "update_stop/2 returns error with invalid attrs", %{
      organization: org,
      gtfs_version: version
    } do
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

    test "create_stop/1 accepts optional stop_desc field", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_stop_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)
        |> Map.put(:stop_desc, "A test stop description")

      assert {:ok, stop} = Gtfs.create_stop(attrs)
      assert stop.stop_desc == "A test stop description"
    end

    test "create_stop/1 accepts optional platform_code field", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_stop_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)
        |> Map.put(:platform_code, "Platform A")

      assert {:ok, stop} = Gtfs.create_stop(attrs)
      assert stop.platform_code == "Platform A"
    end

    test "create_stop/1 allows nil for stop_desc and platform_code", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_stop_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)

      assert {:ok, stop} = Gtfs.create_stop(attrs)
      assert stop.stop_desc == nil
      assert stop.platform_code == nil
    end

    test "update_stop/2 can set stop_desc", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id)
      assert stop.stop_desc == nil

      update_attrs = %{stop_desc: "Updated description"}
      assert {:ok, updated_stop} = Gtfs.update_stop(stop, update_attrs)
      assert updated_stop.stop_desc == "Updated description"
    end

    test "update_stop/2 can set platform_code", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id)
      assert stop.platform_code == nil

      update_attrs = %{platform_code: "Platform B"}
      assert {:ok, updated_stop} = Gtfs.update_stop(stop, update_attrs)
      assert updated_stop.platform_code == "Platform B"
    end

    test "get_stop!/1 retrieves stop with stop_desc and platform_code", %{
      organization: org,
      gtfs_version: version
    } do
      attrs =
        valid_stop_attrs()
        |> Map.put(:organization_id, org.id)
        |> Map.put(:gtfs_version_id, version.id)
        |> Map.put(:stop_desc, "Test description")
        |> Map.put(:platform_code, "Platform C")

      assert {:ok, stop} = Gtfs.create_stop(attrs)

      fetched_stop = Gtfs.get_stop!(stop.id)
      assert fetched_stop.stop_desc == "Test description"
      assert fetched_stop.platform_code == "Platform C"
    end

    test "remove_child_stop_from_diagram/4 clears fields and deletes connected pathways", %{
      organization: org,
      gtfs_version: version
    } do
      station = stop_fixture(org.id, version.id, %{stop_id: "STATION_RM", location_type: 1})

      level =
        level_fixture(org.id, version.id, %{
          level_id: "L_RM",
          level_name: "Platform",
          level_index: 0.0
        })

      child_a =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_RM_A",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
        })

      child_b =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_RM_B",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 40.0}
        })

      pathway =
        pathway_fixture(org.id, version.id, child_a.stop_id, child_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      assert {:ok, updated} =
               Gtfs.remove_child_stop_from_diagram(
                 org.id,
                 version.id,
                 station.stop_id,
                 child_a.id
               )

      assert is_nil(updated.diagram_coordinate)
      assert is_nil(updated.level_id)
      assert is_nil(Repo.get(GtfsPlanner.Gtfs.Pathway, pathway.id))
    end

    test "remove_child_stop_from_diagram/4 returns :not_found for wrong station scope", %{
      organization: org,
      gtfs_version: version
    } do
      station = stop_fixture(org.id, version.id, %{stop_id: "STATION_NF", location_type: 1})
      other_station = stop_fixture(org.id, version.id, %{stop_id: "OTHER_NF", location_type: 1})

      level =
        level_fixture(org.id, version.id, %{
          level_id: "L_NF",
          level_name: "Ground",
          level_index: 0.0
        })

      child =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_NF",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 5.0, "y" => 5.0}
        })

      assert {:error, :not_found} =
               Gtfs.remove_child_stop_from_diagram(
                 org.id,
                 version.id,
                 other_station.stop_id,
                 child.id
               )

      # Verify the stop is unchanged
      unchanged = Gtfs.get_stop!(child.id)
      assert unchanged.diagram_coordinate == %{"x" => 5.0, "y" => 5.0}
      assert unchanged.level_id == level.level_id
    end

    test "delete_child_stop/4 deletes the child stop and connected pathways", %{
      organization: org,
      gtfs_version: version
    } do
      station = stop_fixture(org.id, version.id, %{stop_id: "STATION_DEL", location_type: 1})

      level =
        level_fixture(org.id, version.id, %{
          level_id: "L_DEL",
          level_name: "Platform",
          level_index: 0.0
        })

      child_a =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_DEL_A",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
        })

      child_b =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_DEL_B",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 40.0}
        })

      pathway =
        pathway_fixture(org.id, version.id, child_a.stop_id, child_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      assert {:ok, deleted} =
               Gtfs.delete_child_stop(
                 org.id,
                 version.id,
                 station.stop_id,
                 child_a.id
               )

      assert deleted.id == child_a.id
      assert Gtfs.get_stop(child_a.id) == nil
      assert is_nil(Repo.get(GtfsPlanner.Gtfs.Pathway, pathway.id))
      assert Gtfs.get_stop(child_b.id).id == child_b.id
    end

    test "delete_child_stop/4 returns :not_found for wrong station scope", %{
      organization: org,
      gtfs_version: version
    } do
      station = stop_fixture(org.id, version.id, %{stop_id: "STATION_DEL_NF", location_type: 1})

      other_station =
        stop_fixture(org.id, version.id, %{stop_id: "OTHER_DEL_NF", location_type: 1})

      level =
        level_fixture(org.id, version.id, %{
          level_id: "L_DEL_NF",
          level_name: "Ground",
          level_index: 0.0
        })

      child =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_DEL_NF",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 5.0, "y" => 5.0}
        })

      sibling =
        stop_fixture(org.id, version.id, %{
          stop_id: "SIB_DEL_NF",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 15.0, "y" => 10.0}
        })

      pathway =
        pathway_fixture(org.id, version.id, child.stop_id, sibling.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      assert {:error, :not_found} =
               Gtfs.delete_child_stop(
                 org.id,
                 version.id,
                 other_station.stop_id,
                 child.id
               )

      assert Gtfs.get_stop(child.id).id == child.id
      assert Repo.get(GtfsPlanner.Gtfs.Pathway, pathway.id).id == pathway.id
    end
  end

  describe "unique_stop_id/4" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "returns base stop_id when there is no collision", %{
      organization: org,
      gtfs_version: version
    } do
      assert Gtfs.unique_stop_id(org.id, version.id, "node_main") == "node_main"
    end

    test "returns base_2 when base already exists", %{organization: org, gtfs_version: version} do
      _stop = stop_fixture(org.id, version.id, %{stop_id: "node_main"})
      assert Gtfs.unique_stop_id(org.id, version.id, "node_main") == "node_main_2"
    end

    test "returns first available suffix across multiple collisions", %{
      organization: org,
      gtfs_version: version
    } do
      _stop1 = stop_fixture(org.id, version.id, %{stop_id: "node_main"})
      _stop2 = stop_fixture(org.id, version.id, %{stop_id: "node_main_2"})
      assert Gtfs.unique_stop_id(org.id, version.id, "node_main") == "node_main_3"
    end

    test "exclude_stop_id ignores the specified stop_id", %{
      organization: org,
      gtfs_version: version
    } do
      _stop = stop_fixture(org.id, version.id, %{stop_id: "node_main"})
      assert Gtfs.unique_stop_id(org.id, version.id, "node_main", "node_main") == "node_main"
    end
  end

  describe "list_stations/2" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "returns only stations (stops with no parent)", %{
      organization: org,
      gtfs_version: version
    } do
      # Create a station (no parent)
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "STATION1",
          stop_name: "Main Station",
          parent_station: nil
        })

      # Create a child stop (has parent)
      level = level_fixture(org.id, version.id, %{level_id: "L_CHILD", level_index: 0.0})

      _child =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD1",
          stop_name: "Platform 1",
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      stations = Gtfs.list_stations(org.id, version.id)

      assert length(stations) == 1
      assert hd(stations).id == station.id
      assert hd(stations).parent_station == nil
    end

    test "does not return stations from other organizations", %{
      organization: org,
      gtfs_version: version
    } do
      # Create station for this org
      _station = stop_fixture(org.id, version.id, %{stop_id: "STATION1", parent_station: nil})

      # Create another org with its own station
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      _other_station =
        stop_fixture(other_org.id, other_version.id, %{
          stop_id: "STATION2",
          parent_station: nil
        })

      stations = Gtfs.list_stations(org.id, version.id)

      assert length(stations) == 1
      assert Enum.all?(stations, fn s -> s.organization_id == org.id end)
    end

    test "does not return stations from other versions", %{
      organization: org,
      gtfs_version: version
    } do
      # Create station for this version
      _station = stop_fixture(org.id, version.id, %{stop_id: "STATION1", parent_station: nil})

      # Create another version with its own station
      other_version = gtfs_version_fixture(org.id)

      _other_station =
        stop_fixture(org.id, other_version.id, %{stop_id: "STATION2", parent_station: nil})

      stations = Gtfs.list_stations(org.id, version.id)

      assert length(stations) == 1
      assert Enum.all?(stations, fn s -> s.gtfs_version_id == version.id end)
    end

    test "orders stations by stop_name ascending", %{organization: org, gtfs_version: version} do
      station_c =
        stop_fixture(org.id, version.id, %{
          stop_id: "STATION_C",
          stop_name: "Charlie Station",
          parent_station: nil
        })

      station_a =
        stop_fixture(org.id, version.id, %{
          stop_id: "STATION_A",
          stop_name: "Alpha Station",
          parent_station: nil
        })

      station_b =
        stop_fixture(org.id, version.id, %{
          stop_id: "STATION_B",
          stop_name: "Bravo Station",
          parent_station: nil
        })

      stations = Gtfs.list_stations(org.id, version.id)

      assert length(stations) == 3
      assert Enum.map(stations, & &1.id) == [station_a.id, station_b.id, station_c.id]
    end
  end

  describe "list_child_stops_for_parent/3" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "returns child stops for a parent station", %{organization: org, gtfs_version: version} do
      level = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})
      parent = stop_fixture(org.id, version.id, %{stop_id: "PARENT", location_type: 1})

      child =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD",
          parent_station: parent.stop_id,
          level_id: level.id
        })

      result = Gtfs.list_child_stops_for_parent(org.id, version.id, parent.id)

      assert length(result) == 1
      assert hd(result).id == child.id
      assert hd(result).level_id == level.id
    end
  end

  describe "list_levels_for_station/3" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "returns levels scoped to a specific station", %{
      organization: org,
      gtfs_version: version
    } do
      # Create two stations
      station_a = stop_fixture(org.id, version.id, %{stop_id: "STATION_A", location_type: 1})
      station_b = stop_fixture(org.id, version.id, %{stop_id: "STATION_B", location_type: 1})

      # Create levels for station A
      level1 =
        level_fixture(org.id, version.id, %{
          level_id: "L1",
          level_index: 0.0,
          level_name: "Ground"
        })

      level2 =
        level_fixture(org.id, version.id, %{
          level_id: "L2",
          level_index: 1.0,
          level_name: "Platform"
        })

      # Create child stops (platforms) on these levels for station A
      stop_fixture(org.id, version.id, %{
        stop_id: "A_PLATFORM_1",
        parent_station: station_a.stop_id,
        level_id: level1.level_id
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "A_PLATFORM_2",
        parent_station: station_a.stop_id,
        level_id: level2.level_id
      })

      # Also create stop_level associations to test diagram_filename (optional)
      Gtfs.create_stop_level(%{
        stop_id: station_a.id,
        level_id: level1.id,
        organization_id: org.id,
        gtfs_version_id: version.id
      })

      Gtfs.create_stop_level(%{
        stop_id: station_a.id,
        level_id: level2.id,
        organization_id: org.id,
        gtfs_version_id: version.id
      })

      # Create a level without parent_station_id (orphaned)
      _orphaned_level =
        level_fixture(org.id, version.id, %{
          level_id: "L_ORPHAN",
          level_index: 0.0
        })

      # Verify station A gets its levels
      result_a = Gtfs.list_levels_for_station(org.id, version.id, station_a.id)

      assert length(result_a) == 2
      assert Enum.any?(result_a, fn %{level: l} -> l.id == level1.id end)
      assert Enum.any?(result_a, fn %{level: l} -> l.id == level2.id end)

      # Verify station B returns empty list (no levels assigned)
      result_b = Gtfs.list_levels_for_station(org.id, version.id, station_b.id)
      assert result_b == []
    end

    test "orders levels by level_index ascending", %{organization: org, gtfs_version: version} do
      station = stop_fixture(org.id, version.id, %{stop_id: "STATION", location_type: 1})

      level2 =
        level_fixture(org.id, version.id, %{
          level_id: "L2",
          level_index: 2.0
        })

      level0 =
        level_fixture(org.id, version.id, %{
          level_id: "L0",
          level_index: 0.0
        })

      level1 =
        level_fixture(org.id, version.id, %{
          level_id: "L1",
          level_index: 1.0
        })

      # Create child stops on each level
      stop_fixture(org.id, version.id, %{
        stop_id: "PLATFORM_0",
        parent_station: station.stop_id,
        level_id: level0.level_id
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "PLATFORM_1",
        parent_station: station.stop_id,
        level_id: level1.level_id
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "PLATFORM_2",
        parent_station: station.stop_id,
        level_id: level2.level_id
      })

      result = Gtfs.list_levels_for_station(org.id, version.id, station.id)

      assert Enum.map(result, & &1.level.level_index) == [0.0, 1.0, 2.0]
      assert Enum.map(result, & &1.level.id) == [level0.id, level1.id, level2.id]
    end

    test "returns mixed levels from child stops and stop_levels", %{
      organization: org,
      gtfs_version: version
    } do
      station = stop_fixture(org.id, version.id, %{stop_id: "STATION_MIXED", location_type: 1})

      child_only_level =
        level_fixture(org.id, version.id, %{
          level_id: "L_CHILD_ONLY",
          level_index: 0.0
        })

      stop_level_only_level =
        level_fixture(org.id, version.id, %{
          level_id: "L_STOP_LEVEL_ONLY",
          level_index: 1.0
        })

      stop_fixture(org.id, version.id, %{
        stop_id: "CHILD_MIXED_1",
        parent_station: station.stop_id,
        level_id: child_only_level.level_id
      })

      Gtfs.create_stop_level(%{
        stop_id: station.id,
        level_id: stop_level_only_level.id,
        organization_id: org.id,
        gtfs_version_id: version.id
      })

      result = Gtfs.list_levels_for_station(org.id, version.id, station.id)

      assert Enum.map(result, & &1.level.id) == [child_only_level.id, stop_level_only_level.id]

      assert Enum.any?(result, fn %{level: level, stop_count: count, diagram_filename: filename} ->
               level.id == child_only_level.id and count == 1 and is_nil(filename)
             end)

      assert Enum.any?(result, fn %{level: level, stop_count: count, diagram_filename: filename} ->
               level.id == stop_level_only_level.id and count == 0 and is_nil(filename)
             end)
    end
  end

  describe "get_routes_for_stops/3" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "returns routes for stops", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id, %{stop_id: "S1"})
      route = route_fixture(org.id, version.id, %{route_id: "R1", route_short_name: "Route 1"})
      trip = trip_fixture(org.id, version.id, route.route_id, %{trip_id: "T1"})
      _stop_time = stop_time_fixture(org.id, version.id, trip.trip_id, stop.stop_id)

      routes_map = Gtfs.get_routes_for_stops(org.id, version.id, [stop.stop_id])

      assert Map.has_key?(routes_map, stop.stop_id)
      [route_info] = routes_map[stop.stop_id]
      assert route_info.route_id == route.route_id
      assert route_info.route_short_name == route.route_short_name
    end

    test "returns empty list for stops with no routes", %{
      organization: org,
      gtfs_version: version
    } do
      stop = stop_fixture(org.id, version.id, %{stop_id: "S1"})
      routes_map = Gtfs.get_routes_for_stops(org.id, version.id, [stop.stop_id])
      assert routes_map == %{}
    end
  end

  describe "list_stations/3 route filtering" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "filters stations by route_id", %{organization: org, gtfs_version: version} do
      # Station served by Route 1
      station1 = stop_fixture(org.id, version.id, %{stop_id: "S1", parent_station: nil})
      route1 = route_fixture(org.id, version.id, %{route_id: "R1"})
      trip1 = trip_fixture(org.id, version.id, route1.route_id, %{trip_id: "T1"})
      stop_time_fixture(org.id, version.id, trip1.trip_id, station1.stop_id)

      # Station served by Route 2
      station2 = stop_fixture(org.id, version.id, %{stop_id: "S2", parent_station: nil})
      route2 = route_fixture(org.id, version.id, %{route_id: "R2"})
      trip2 = trip_fixture(org.id, version.id, route2.route_id, %{trip_id: "T2"})
      stop_time_fixture(org.id, version.id, trip2.trip_id, station2.stop_id)

      # Filter for Route 1
      stations = Gtfs.list_stations(org.id, version.id, route_id: "R1")
      assert length(stations) == 1
      assert hd(stations).id == station1.id

      # Filter for Route 2
      stations = Gtfs.list_stations(org.id, version.id, route_id: "R2")
      assert length(stations) == 1
      assert hd(stations).id == station2.id
    end

    test "returns all stations when route_id is nil", %{organization: org, gtfs_version: version} do
      stop_fixture(org.id, version.id, %{stop_id: "S1", parent_station: nil})
      stop_fixture(org.id, version.id, %{stop_id: "S2", parent_station: nil})

      stations = Gtfs.list_stations(org.id, version.id, route_id: nil)
      assert length(stations) == 2
    end
  end

  describe "list_pathways_for_station/3" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "returns pathways for child stops of a station", %{
      organization: org,
      gtfs_version: version
    } do
      parent = stop_fixture(org.id, version.id, %{stop_id: "PARENT", location_type: 1})
      level = level_fixture(org.id, version.id, %{level_id: "L_PATH", level_index: 0.0})

      child1 =
        stop_fixture(org.id, version.id, %{
          stop_id: "C1",
          parent_station: parent.stop_id,
          level_id: level.level_id
        })

      child2 =
        stop_fixture(org.id, version.id, %{
          stop_id: "C2",
          parent_station: parent.stop_id,
          level_id: level.level_id
        })

      pathway =
        pathway_fixture(org.id, version.id, child1.stop_id, child2.stop_id, %{
          pathway_id: "P1",
          pathway_mode: 1
        })

      result = Gtfs.list_pathways_for_station(org.id, version.id, parent.id)

      assert length(result) == 1
      assert hd(result).id == pathway.id
      assert hd(result).from_stop.id == child1.id
      assert hd(result).to_stop.id == child2.id
    end
  end

  describe "update_pathway/2" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      parent =
        stop_fixture(organization.id, gtfs_version.id, %{stop_id: "PARENT", location_type: 1})

      level =
        level_fixture(organization.id, gtfs_version.id, %{level_id: "L_PATHWAY", level_index: 0.0})

      child1 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "C1",
          parent_station: parent.stop_id,
          level_id: level.level_id
        })

      child2 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "C2",
          parent_station: parent.stop_id,
          level_id: level.level_id
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, child1.stop_id, child2.stop_id, %{
          pathway_id: "P1",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 60
        })

      %{
        organization: organization,
        gtfs_version: gtfs_version,
        parent: parent,
        child1: child1,
        child2: child2,
        pathway: pathway
      }
    end

    test "updates a pathway with valid attrs", %{pathway: pathway} do
      update_attrs = %{
        pathway_mode: 2,
        is_bidirectional: false,
        traversal_time: 120,
        stair_count: 15
      }

      assert {:ok, updated_pathway} = Gtfs.update_pathway(pathway, update_attrs)
      assert updated_pathway.id == pathway.id
      assert updated_pathway.pathway_mode == 2
      assert updated_pathway.is_bidirectional == false
      assert updated_pathway.traversal_time == 120
      assert updated_pathway.stair_count == 15
    end

    test "updates pathway_mode to different types", %{pathway: pathway} do
      # Test each valid pathway mode
      for mode <- 1..7 do
        assert {:ok, updated} = Gtfs.update_pathway(pathway, %{pathway_mode: mode})
        assert updated.pathway_mode == mode
      end
    end

    test "updates optional fields to non-nil values", %{pathway: pathway} do
      update_attrs = %{
        length: Decimal.new("10.5"),
        max_slope: Decimal.new("0.15"),
        min_width: Decimal.new("1.2"),
        signposted_as: "To Platform A",
        reversed_signposted_as: "From Platform A"
      }

      assert {:ok, updated} = Gtfs.update_pathway(pathway, update_attrs)
      assert Decimal.equal?(updated.length, Decimal.new("10.5"))
      assert Decimal.equal?(updated.max_slope, Decimal.new("0.15"))
      assert Decimal.equal?(updated.min_width, Decimal.new("1.2"))
      assert updated.signposted_as == "To Platform A"
      assert updated.reversed_signposted_as == "From Platform A"
    end

    test "returns error with invalid pathway_mode", %{pathway: pathway} do
      # pathway_mode must be between 1 and 7
      for invalid_mode <- [0, 8, 99] do
        assert {:error, changeset} = Gtfs.update_pathway(pathway, %{pathway_mode: invalid_mode})
        assert %{pathway_mode: ["is invalid"]} = errors_on(changeset)
      end
    end

    test "returns error when pathway_mode is nil", %{pathway: pathway} do
      assert {:error, changeset} = Gtfs.update_pathway(pathway, %{pathway_mode: nil})
      assert %{pathway_mode: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error when pathway_id is set to nil", %{pathway: pathway} do
      assert {:error, changeset} = Gtfs.update_pathway(pathway, %{pathway_id: nil})
      assert %{pathway_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "does not change immutable fields like id", %{pathway: pathway} do
      original_id = pathway.id

      assert {:ok, updated} = Gtfs.update_pathway(pathway, %{pathway_mode: 3})
      assert updated.id == original_id
    end

    test "broadcasts update event on successful update", %{pathway: pathway} do
      # Subscribe to the pathways PubSub topic
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "pathways")

      update_attrs = %{pathway_mode: 5}
      assert {:ok, updated_pathway} = Gtfs.update_pathway(pathway, update_attrs)

      # Assert that we received the broadcast message
      assert_receive {[:pathways, :updated], ^updated_pathway}
    end

    test "does not broadcast on validation failure", %{pathway: pathway} do
      # Subscribe to the pathways PubSub topic
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "pathways")

      # Attempt to update with invalid data
      assert {:error, _changeset} = Gtfs.update_pathway(pathway, %{pathway_mode: nil})

      # Assert that no broadcast message was received
      refute_receive {[:pathways, :updated], _}, 100
    end
  end

  describe "routes" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "list_routes/3 filters by route_type", %{organization: org, gtfs_version: version} do
      # Create routes with different route types
      _tram_route = route_fixture(org.id, version.id, %{route_id: "TRAM1", route_type: 0})
      bus_route1 = route_fixture(org.id, version.id, %{route_id: "BUS1", route_type: 3})
      bus_route2 = route_fixture(org.id, version.id, %{route_id: "BUS2", route_type: 3})
      _subway_route = route_fixture(org.id, version.id, %{route_id: "SUBWAY1", route_type: 1})

      # Filter by bus routes (route_type: 3)
      routes = Gtfs.list_routes(org.id, version.id, route_type: 3)

      # Assert only bus routes are returned
      assert length(routes) == 2
      assert Enum.all?(routes, fn r -> r.route_type == 3 end)
      route_ids = Enum.map(routes, & &1.id)
      assert bus_route1.id in route_ids
      assert bus_route2.id in route_ids
    end

    test "list_routes/3 searches by name", %{organization: org, gtfs_version: version} do
      # Create routes with different names
      express_route1 =
        route_fixture(org.id, version.id, %{
          route_id: "EXP1",
          route_short_name: "Express 1",
          route_long_name: "Downtown Express"
        })

      express_route2 =
        route_fixture(org.id, version.id, %{
          route_id: "EXP2",
          route_short_name: "Express 2",
          route_long_name: "Airport Express"
        })

      _local_route =
        route_fixture(org.id, version.id, %{
          route_id: "LOCAL1",
          route_short_name: "Local 1",
          route_long_name: "Local Service"
        })

      # Search for "express" routes
      routes = Gtfs.list_routes(org.id, version.id, search: "express")

      # Assert only routes containing "express" are returned
      assert length(routes) == 2
      route_ids = Enum.map(routes, & &1.id)
      assert express_route1.id in route_ids
      assert express_route2.id in route_ids
    end

    test "list_routes/3 sorts by column", %{organization: org, gtfs_version: version} do
      # Create routes with specific short names
      route_a =
        route_fixture(org.id, version.id, %{route_id: "R1", route_short_name: "Alpha"})

      route_b =
        route_fixture(org.id, version.id, %{route_id: "R2", route_short_name: "Bravo"})

      route_c =
        route_fixture(org.id, version.id, %{route_id: "R3", route_short_name: "Charlie"})

      # Sort by route_short_name descending
      routes = Gtfs.list_routes(org.id, version.id, sort_by: :route_short_name, sort_dir: :desc)

      # Assert routes are in descending order by route_short_name
      assert length(routes) == 3
      assert Enum.map(routes, & &1.id) == [route_c.id, route_b.id, route_a.id]
      assert Enum.map(routes, & &1.route_short_name) == ["Charlie", "Bravo", "Alpha"]
    end

    test "list_routes/3 paginates results", %{organization: org, gtfs_version: version} do
      # Create 5 routes
      _route1 = route_fixture(org.id, version.id, %{route_id: "R1", route_short_name: "1"})
      _route2 = route_fixture(org.id, version.id, %{route_id: "R2", route_short_name: "2"})
      route3 = route_fixture(org.id, version.id, %{route_id: "R3", route_short_name: "3"})
      route4 = route_fixture(org.id, version.id, %{route_id: "R4", route_short_name: "4"})
      _route5 = route_fixture(org.id, version.id, %{route_id: "R5", route_short_name: "5"})

      # Get page 2 with per_page: 2 (should return routes 3 and 4)
      routes = Gtfs.list_routes(org.id, version.id, page: 2, per_page: 2)

      # Assert 2 routes returned
      assert length(routes) == 2

      # Assert they are the 3rd and 4th routes (by default sort: route_id ascending)
      route_ids = Enum.map(routes, & &1.id)
      assert route3.id in route_ids
      assert route4.id in route_ids
    end
  end

  describe "stop level scale calibration" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_SCALE",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_SCALE",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      from_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SCALE_FROM",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      to_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SCALE_TO",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{x: 13.0, y: 14.0}
        })

      %{stop_level: stop_level, from_stop: from_stop, to_stop: to_stop}
    end

    test "update_stop_level_scale/2 saves valid calibration", %{stop_level: stop_level} do
      attrs = %{
        scale_point_a: %{"x" => 10.0, "y" => 10.0},
        scale_point_b: %{"x" => 20.0, "y" => 10.0},
        scale_distance_meters: Decimal.new("25.0"),
        scale_meters_per_unit: Decimal.new("2.5")
      }

      assert {:ok, updated} = Gtfs.update_stop_level_scale(stop_level, attrs)
      assert updated.scale_point_a == attrs.scale_point_a
      assert updated.scale_point_b == attrs.scale_point_b
      assert Decimal.equal?(updated.scale_distance_meters, Decimal.new("25.0"))
      assert Decimal.equal?(updated.scale_meters_per_unit, Decimal.new("2.5"))
    end

    test "all-or-none validation fails partial payloads", %{stop_level: stop_level} do
      assert {:error, changeset} =
               Gtfs.update_stop_level_scale(stop_level, %{
                 scale_point_a: %{"x" => 10.0, "y" => 10.0}
               })

      assert "scale calibration requires both points, distance, and ratio" in errors_on(changeset).scale_point_a
    end

    test "invalid distance and ratio are rejected", %{stop_level: stop_level} do
      assert {:error, changeset} =
               Gtfs.update_stop_level_scale(stop_level, %{
                 scale_point_a: %{"x" => 10.0, "y" => 10.0},
                 scale_point_b: %{"x" => 20.0, "y" => 20.0},
                 scale_distance_meters: Decimal.new("-1"),
                 scale_meters_per_unit: Decimal.new("0")
               })

      assert "must be greater than 0" in errors_on(changeset).scale_distance_meters
      assert "must be greater than 0" in errors_on(changeset).scale_meters_per_unit
    end

    test "clear_stop_level_scale/1 clears all fields", %{stop_level: stop_level} do
      {:ok, calibrated} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 10.0, "y" => 10.0},
          scale_point_b: %{"x" => 20.0, "y" => 20.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("1")
        })

      assert {:ok, cleared} = Gtfs.clear_stop_level_scale(calibrated)
      assert is_nil(cleared.scale_point_a)
      assert is_nil(cleared.scale_point_b)
      assert is_nil(cleared.scale_distance_meters)
      assert is_nil(cleared.scale_meters_per_unit)
    end

    test "update_stop_level_diagram/2 clears existing calibration", %{stop_level: stop_level} do
      {:ok, calibrated} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 10.0, "y" => 10.0},
          scale_point_b: %{"x" => 20.0, "y" => 20.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("1")
        })

      assert {:ok, updated} = Gtfs.update_stop_level_diagram(calibrated, "diagram.png")
      assert updated.diagram_filename == "diagram.png"
      assert is_nil(updated.scale_point_a)
      assert is_nil(updated.scale_point_b)
      assert is_nil(updated.scale_distance_meters)
      assert is_nil(updated.scale_meters_per_unit)
    end

    test "calculate_pathway_length/3 returns rounded decimal", %{
      stop_level: stop_level,
      from_stop: from_stop,
      to_stop: to_stop
    } do
      {:ok, calibrated} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 0.0, "y" => 0.0},
          scale_point_b: %{"x" => 10.0, "y" => 0.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("2")
        })

      assert Gtfs.calculate_pathway_length(calibrated, from_stop, to_stop) == Decimal.new("10.00")
    end
  end
end
