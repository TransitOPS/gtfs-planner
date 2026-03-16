defmodule GtfsPlanner.Gtfs.StationNamingContextTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Validations.WalkabilityTest

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
      assert preview.updated_pathways_count == 2
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

    test "preview includes boarding areas that are children of platforms", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "BOARD_STATION",
          stop_name: "Board Station",
          location_type: 1
        })

      platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "PLAT_B",
          stop_name: "Platform B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ground"
        })

      _boarding_area =
        stop_fixture(org.id, version.id, %{
          stop_id: "BA_1",
          stop_name: "Boarding Area 1",
          location_type: 4,
          parent_station: platform.stop_id,
          level_id: "ground"
        })

      _pathway =
        pathway_fixture(org.id, version.id, "PLAT_B", "BA_1", %{
          pathway_mode: 1
        })

      assert {:ok, preview} =
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id)

      old_ids = Enum.map(preview.rows, & &1.old_id)
      assert "PLAT_B" in old_ids
      assert "BA_1" in old_ids
      assert length(preview.rows) == 2
    end
  end

  describe "preview_station_naming/4 with :kebab style" do
    test "returns kebab-cased IDs based on stop names", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "CENTRAL",
          stop_name: "Central Station",
          location_type: 1
        })

      _platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "PLAT_1",
          stop_name: "Platform 2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ground"
        })

      _entrance =
        stop_fixture(org.id, version.id, %{
          stop_id: "ENT_1",
          stop_name: "Main Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "street"
        })

      assert {:ok, preview} =
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id, :kebab)

      assert preview.renamed_stops_count == 2
      assert length(preview.rows) == 2

      mapping = Map.new(preview.rows, fn %{old_id: old, new_id: new} -> {old, new} end)
      assert mapping["ENT_1"] == "main-entrance-01"
      assert mapping["PLAT_1"] == "platform-2-01"
    end

    test "returns :no_stops for station with no children", %{
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
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id, :kebab)
    end

    test "falls back to stop_id when stop_name is blank or punctuation-only", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "FALLBACK",
          stop_name: "Fallback Station",
          location_type: 1
        })

      _blank =
        stop_fixture(org.id, version.id, %{
          stop_id: "BLANK_STOP",
          stop_name: "",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _punctuation =
        stop_fixture(org.id, version.id, %{
          stop_id: "PUNC_STOP",
          stop_name: "!!!",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      assert {:ok, preview} =
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id, :kebab)

      mapping = Map.new(preview.rows, fn %{old_id: old, new_id: new} -> {old, new} end)
      assert mapping["BLANK_STOP"] == "blank-stop-01"
      assert mapping["PUNC_STOP"] == "punc-stop-01"
    end

    test "returns :naming_collision when kebab ID conflicts with existing stop", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "COLLIDE",
          stop_name: "Collision Station",
          location_type: 1
        })

      _child =
        stop_fixture(org.id, version.id, %{
          stop_id: "CHILD_COLLIDE",
          stop_name: "Main Hall",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _blocker =
        stop_fixture(org.id, version.id, %{
          stop_id: "main-hall-01",
          stop_name: "Existing Main Hall",
          location_type: 0
        })

      assert {:error, {:naming_collision, collisions}} =
               Gtfs.preview_station_naming(org.id, version.id, station.stop_id, :kebab)

      assert "main-hall-01" in collisions
    end
  end

  describe "apply_station_naming/4 with :kebab style" do
    test "renames stops using kebab-cased names", %{
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
          stop_name: "Ticket Hall",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L0"
        })

      _platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "PLAT_X",
          stop_name: "Platform 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L0"
        })

      pathway =
        pathway_fixture(org.id, version.id, "NODE_A", "PLAT_X", %{
          pathway_mode: 2
        })

      assert {:ok, %{renamed_stops: 2, updated_pathways: 2}} =
               Gtfs.apply_station_naming(org.id, version.id, station.stop_id, :kebab)

      # Verify new kebab-cased stop IDs exist
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "platform-1-01")
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "ticket-hall-01")

      # Verify old IDs no longer exist
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "NODE_A")
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "PLAT_X")

      # Verify pathway references updated
      updated_pathway = Gtfs.get_pathway!(pathway.id)
      assert updated_pathway.from_stop_id == "ticket-hall-01"
      assert updated_pathway.to_stop_id == "platform-1-01"
    end

    test "falls back to stop_id for blank and punctuation-only stop names", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "FALLBACK_APPLY",
          stop_name: "Fallback Apply",
          location_type: 1
        })

      _blank =
        stop_fixture(org.id, version.id, %{
          stop_id: "BLANK_APPLY",
          stop_name: "",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _punctuation =
        stop_fixture(org.id, version.id, %{
          stop_id: "PUNC_APPLY",
          stop_name: "!!!",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      assert {:ok, %{renamed_stops: 2}} =
               Gtfs.apply_station_naming(org.id, version.id, station.stop_id, :kebab)

      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "blank-apply-01")
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "punc-apply-01")
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "BLANK_APPLY")
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "PUNC_APPLY")
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

      assert {:ok, %{renamed_stops: 2, updated_pathways: 2}} =
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

    test "updates all known stop_id reference tables for renamed children", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "HUB",
          stop_name: "Hub",
          location_type: 1
        })

      platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "PLAT_01",
          stop_name: "Platform 01",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _boarding =
        stop_fixture(org.id, version.id, %{
          stop_id: "BOARD_01",
          stop_name: "Boarding 01",
          location_type: 4,
          parent_station: platform.stop_id,
          level_id: "L1"
        })

      _pathway =
        pathway_fixture(org.id, version.id, platform.stop_id, station.stop_id, %{pathway_mode: 5})

      route = route_fixture(org.id, version.id)
      trip = trip_fixture(org.id, version.id, route.route_id)
      _stop_time = stop_time_fixture(org.id, version.id, trip.trip_id, platform.stop_id)

      transfer =
        Repo.insert!(%Transfer{
          organization_id: org.id,
          gtfs_version_id: version.id,
          from_stop_id: station.stop_id,
          to_stop_id: platform.stop_id,
          transfer_type: 0
        })

      stop_area =
        Repo.insert!(%StopArea{
          organization_id: org.id,
          gtfs_version_id: version.id,
          area_id: "A1",
          stop_id: platform.stop_id
        })

      fare_leg_join_rule =
        Repo.insert!(%FareLegJoinRule{
          organization_id: org.id,
          gtfs_version_id: version.id,
          from_stop_id: platform.stop_id,
          to_stop_id: station.stop_id
        })

      translation =
        Repo.insert!(%Translation{
          organization_id: org.id,
          gtfs_version_id: version.id,
          table_name: "stops",
          field_name: "stop_name",
          language: "en",
          translation: "Platform 01",
          record_id: platform.stop_id
        })

      walkability_test =
        Repo.insert!(%WalkabilityTest{
          organization_id: org.id,
          gtfs_version_id: version.id,
          stop_id: platform.stop_id,
          address: "100 Main St",
          address_lat: Decimal.new("42.3601"),
          address_lon: Decimal.new("-71.0589")
        })

      assert {:ok, %{renamed_stops: 2, updated_references: updated_references}} =
               Gtfs.apply_station_naming(org.id, version.id, station.stop_id)

      assert updated_references > 0

      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "hub_platform_elevator_l1_01")
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, platform.stop_id)

      # Boarding area was also renamed (no longer exists as BOARD_01)
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "BOARD_01")

      # Find the renamed boarding area and verify its parent_station still points to the renamed platform
      renamed_boarding = Gtfs.get_stop_by_stop_id(org.id, version.id, "hub_boarding_general_l1_01")
      assert renamed_boarding
      assert renamed_boarding.parent_station == "hub_platform_elevator_l1_01"

      stop_times =
        from(st in GtfsPlanner.Gtfs.StopTime,
          where: st.organization_id == ^org.id and st.gtfs_version_id == ^version.id,
          select: st.stop_id
        )
        |> Repo.all()

      assert "hub_platform_elevator_l1_01" in stop_times

      updated_transfer = Gtfs.get_transfer!(transfer.id)
      assert updated_transfer.to_stop_id == "hub_platform_elevator_l1_01"

      updated_stop_area = Gtfs.get_stop_area!(stop_area.id)
      assert updated_stop_area.stop_id == "hub_platform_elevator_l1_01"

      updated_fare_leg_join_rule = Repo.get!(FareLegJoinRule, fare_leg_join_rule.id)
      assert updated_fare_leg_join_rule.from_stop_id == "hub_platform_elevator_l1_01"

      updated_translation = Gtfs.get_translation!(translation.id)
      assert updated_translation.record_id == "hub_platform_elevator_l1_01"

      updated_walkability_test = Repo.get!(WalkabilityTest, walkability_test.id)
      assert updated_walkability_test.stop_id == "hub_platform_elevator_l1_01"
    end
  end

  describe "apply_station_naming/5 with selected_ids" do
    test "renames only selected stops", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "SEL_STATION",
          stop_name: "Sel Station",
          location_type: 1
        })

      _platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "SEL_PLAT",
          stop_name: "Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _entrance =
        stop_fixture(org.id, version.id, %{
          stop_id: "SEL_ENT",
          stop_name: "Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      selected = MapSet.new(["SEL_PLAT"])

      assert {:ok, %{renamed_stops: 1}} =
               Gtfs.apply_station_naming(org.id, version.id, station.stop_id, :structured, selected)

      # Selected stop was renamed
      refute Gtfs.get_stop_by_stop_id(org.id, version.id, "SEL_PLAT")

      # Unselected stop retains its original stop_id
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "SEL_ENT")
    end

    test "renames nothing when selected_ids is empty", %{
      organization: org,
      gtfs_version: version
    } do
      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "EMPTY_SEL",
          stop_name: "Empty Sel",
          location_type: 1
        })

      _platform =
        stop_fixture(org.id, version.id, %{
          stop_id: "EMPTY_SEL_PLAT",
          stop_name: "Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      assert {:ok, %{renamed_stops: 0}} =
               Gtfs.apply_station_naming(
                 org.id,
                 version.id,
                 station.stop_id,
                 :structured,
                 MapSet.new()
               )

      # Original stop_id still exists
      assert Gtfs.get_stop_by_stop_id(org.id, version.id, "EMPTY_SEL_PLAT")
    end
  end
end
