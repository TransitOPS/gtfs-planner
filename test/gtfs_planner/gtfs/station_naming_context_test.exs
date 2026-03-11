defmodule GtfsPlanner.Gtfs.StationNamingContextTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    %{organization: organization, gtfs_version: gtfs_version}
  end

  describe "preview_station_naming/3" do
    test "returns preview with correct counts", %{organization: org, gtfs_version: version} do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "CENTRAL",
          stop_name: "Central Station",
          location_type: 1
        })

      _platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "PLAT_1",
          stop_name: "Platform 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ground"
        })

      _entrance =
        stop_fixture(org.id, version.id, %{
          stop_id: "ENT_1",
          stop_name: "Entrance 1",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "street"
        })

      _pathway =
        pathway_fixture(org.id, version.id, "PLAT_1", "ENT_1", %{
          pathway_mode: 5
        })

      assert {:ok, preview} =
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id)

      assert preview.renamed_stops_count == 2
      assert preview.updated_pathways_count == 1
      assert length(preview.rows) == 2

      mapping = Map.new(preview.rows, fn %{old_id: old, new_id: new} -> {old, new} end)
      assert mapping["PLAT_1"] == "central_platform_elevator_ground_01"
      assert mapping["ENT_1"] == "central_entrance_elevator_street_01"
    end

    test "returns :no_stops when station has no qualifying children", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "EMPTY",
          stop_name: "Empty Station",
          location_type: 1
        })

      assert {:error, :no_stops} =
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id)
    end

    test "returns :naming_collision when new ID conflicts with existing stop", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "ST",
          stop_name: "St",
          location_type: 1
        })

      _child =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_A",
          stop_name: "Child A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "lvl"
        })

      # Create a stop with the exact ID that the naming convention would generate
      _blocker =
        stop_fixture(org.id, version.id, %{
          stop_id: "st_platform_general_lvl_01",
          stop_name: "Blocker",
          location_type: 0
        })

      assert {:error, {:naming_collision, collisions}} =
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id)

      assert "st_platform_general_lvl_01" in collisions
    end
  end

  describe "apply_station_naming/3" do
    test "renames stops and updates pathway references atomically", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "MAIN",
          stop_name: "Main",
          location_type: 1
        })

      _node =
        stop_fixture(org.id, version.id, %{
          stop_id: "NODE_A",
          stop_name: "Node A",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L0"
        })

      _platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "PLAT_X",
          stop_name: "Platform X",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L0"
        })

      pathway =
        pathway_fixture(org.id, version.id, "NODE_A", "PLAT_X", %{
          pathway_mode: 2
        })

      assert {:ok, %{renamed_stops: 2, updated_pathways: 1}} =
               Gtfs.apply_station_naming(org.id, version.id, station.stop_id)

      # Verify stop IDs were updated
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "main_node_stairs_l0_01")
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "main_platform_stairs_l0_01")

      # Verify old IDs no longer exist
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "NODE_A")
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "PLAT_X")

      # Verify pathway references updated
      updated_pathway = Gtfs.get_pathway!(pathway.id)
      assert updated_pathway.from_stop_id == "main_node_stairs_l0_01"
      assert updated_pathway.to_stop_id == "main_platform_stairs_l0_01"
    end

    test "returns :no_stops when no children exist", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "LONELY",
          stop_name: "Lonely",
          location_type: 1
        })

      assert {:error, :no_stops} =
               Gtfs.apply_station_naming(org.id, version.id, station.stop_id)
    end
  end
end
