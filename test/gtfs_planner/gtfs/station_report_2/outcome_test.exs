defmodule GtfsPlanner.Gtfs.StationReport2.OutcomeTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationReport2.{DataQuality, Gps, NamingConventions, Outcome}

  describe "counts/1" do
    test "tallies each status" do
      items = [
        %{status: :fail, id: "isolated_nodes"},
        %{status: :fail, id: "gps_presence_by_type"},
        %{status: :warn, id: "wheelchair_inferrable"},
        %{status: :pass, id: "duplicate_stop_ids"},
        %{status: :info, id: "wheelchair_contradicts_context"}
      ]

      assert Outcome.counts(items) == %{passed: 1, warnings: 1, failed: 2, info: 1}
    end

    test "does not count warnings as failures" do
      assert Outcome.counts([%{status: :warn}, %{status: :warn}]) ==
               %{passed: 0, warnings: 2, failed: 0, info: 0}
    end

    test "returns zero counts for no items" do
      assert Outcome.counts([]) == %{passed: 0, warnings: 0, failed: 0, info: 0}
    end
  end

  describe "report_items/1" do
    test "returns the data quality, GPS and naming items in order for a real station snapshot" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      level = level_fixture(organization.id, gtfs_version.id, %{level_id: "L1"})

      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Station One",
          location_type: 1,
          parent_station: nil
        })

      entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_1",
          stop_name: "Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_1",
          stop_name: "Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PATH_1",
        pathway_mode: 5,
        is_bidirectional: true
      })

      assert {:ok, snapshot} =
               Gtfs.get_station_report_snapshot(
                 organization.id,
                 gtfs_version.id,
                 station.stop_id
               )

      items = Outcome.report_items(snapshot)
      data_quality_items = DataQuality.build(snapshot)
      gps_items = Gps.build(snapshot)
      naming_items = NamingConventions.build(snapshot)

      assert length(items) ==
               length(data_quality_items) + length(gps_items) + length(naming_items)

      assert Enum.map(items, & &1.id) ==
               Enum.map(data_quality_items ++ gps_items ++ naming_items, & &1.id)

      counts = Outcome.counts(items)
      frequencies = Enum.frequencies_by(items, & &1.status)

      assert counts == %{
               passed: Map.get(frequencies, :pass, 0),
               warnings: Map.get(frequencies, :warn, 0),
               failed: Map.get(frequencies, :fail, 0),
               info: Map.get(frequencies, :info, 0)
             }

      assert counts.passed + counts.warnings + counts.failed + counts.info == length(items)
    end
  end
end
