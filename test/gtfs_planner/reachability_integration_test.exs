defmodule GtfsPlanner.ReachabilityIntegrationTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  setup do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    _ground = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})
    _upper = level_fixture(org.id, version.id, %{level_id: "L2", level_index: 1.0})

    station =
      stop_fixture(org.id, version.id, %{
        stop_id: "STATION_1",
        stop_name: "Test Station",
        location_type: 1,
        level_id: "L1"
      })

    entrance =
      stop_fixture(org.id, version.id, %{
        stop_id: "ENT_A",
        stop_name: "Entrance A",
        location_type: 2,
        parent_station: station.stop_id,
        stop_lat: Decimal.new("39.9526"),
        stop_lon: Decimal.new("-75.1653"),
        level_id: "L1"
      })

    platform =
      stop_fixture(org.id, version.id, %{
        stop_id: "PLAT_1",
        stop_name: "Platform 1",
        location_type: 0,
        parent_station: station.stop_id,
        stop_lat: Decimal.new("39.9527"),
        stop_lon: Decimal.new("-75.1653"),
        level_id: "L1"
      })

    pathway_fixture(org.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_1",
      pathway_mode: 2,
      is_bidirectional: true,
      traversal_time: 45
    })

    entrance_b =
      stop_fixture(org.id, version.id, %{
        stop_id: "ENT_B",
        stop_name: "Entrance B",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L2"
      })

    platform_b =
      stop_fixture(org.id, version.id, %{
        stop_id: "PLAT_2",
        stop_name: "Platform 2",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L2"
      })

    platform_c =
      stop_fixture(org.id, version.id, %{
        stop_id: "PLAT_3",
        stop_name: "Platform 3",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L2"
      })

    pathway_fixture(org.id, version.id, entrance_b.stop_id, platform_b.stop_id, %{
      pathway_id: "PW_ELEVATOR",
      pathway_mode: 5,
      is_bidirectional: true,
      traversal_time: 45
    })

    pathway_fixture(org.id, version.id, platform_b.stop_id, platform_c.stop_id, %{
      pathway_id: "PW_PLATFORM_LINK",
      pathway_mode: 1,
      is_bidirectional: true,
      traversal_time: 45
    })

    pathway_fixture(org.id, version.id, platform.stop_id, platform_b.stop_id, %{
      pathway_id: "PW_STAIRS_BRANCH",
      pathway_mode: 2,
      is_bidirectional: true,
      traversal_time: 45
    })

    %{org: org, version: version, station: station}
  end

  describe "start_run/4 end-to-end" do
    test "runs the full dual-graph path and persists a completed envelope", %{
      org: org,
      version: version,
      station: station
    } do
      assert {:ok, run} = Reachability.start_run(org.id, version.id, station.stop_id)

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run.id))

      assert run.status == "running"
      assert run.engine == "pathways_router"
      assert run.result_schema_version == 1

      run = wait_for_completion(run.id)

      assert run.status == "completed"
      assert run.completed_at != nil
      assert run.duration_ms != nil
      assert run.errors_count == 0
      assert run.warnings_count > 0
      assert run.infos_count > 0

      envelope = run.result_json
      assert envelope["engine"] == "pathways_router"
      assert envelope["engine_ref"] == "c34f9e84b7742de231652cb9bb3b3ba3cc8e8fcd"
      assert envelope["result_schema_version"] == 1
      assert envelope["preferences"] == "default"
      assert envelope["metadata"]["station_stop_id"] == station.stop_id
      assert envelope["outcome"] == "warning"

      assert envelope["topology"] == %{
               "entrance_count" => 2,
               "platform_count" => 3,
               "pathway_count" => 4,
               "level_count" => 2
             }

      pairs = envelope["pairs"]
      assert length(pairs) == 36

      assert Enum.all?(
               Enum.filter(pairs, &(&1["mode"] == "walking")),
               &(&1["outcome"] == "reachable")
             )

      assert Enum.any?(pairs, fn pair ->
               pair["mode"] == "wheelchair" and pair["outcome"] == "unreachable"
             end)

      indices = Enum.map(pairs, & &1["index"])
      assert indices == Enum.to_list(0..(length(pairs) - 1))

      refute Enum.any?(pairs, &Map.has_key?(&1, "steps"))

      assert {:ok, json} = Jason.encode(envelope)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded == envelope
    end

    test "broadcasts completion on the run topic", %{org: org, version: version, station: station} do
      assert {:ok, run} = Reachability.start_run(org.id, version.id, station.stop_id)

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run.id))

      assert_receive {:reachability_run_completed, run_id}, 5_000
      assert run_id == run.id
    end

    test "returns :station_not_found for unknown station", %{org: org, version: version} do
      assert {:error, :station_not_found} =
               Reachability.start_run(org.id, version.id, "NONEXISTENT")
    end
  end

  describe "tenant and version isolation" do
    test "same-named stops in another org do not leak into the graph", %{
      org: org,
      version: version,
      station: station
    } do
      other_version = gtfs_version_fixture(org.id)

      foreign_station =
        stop_fixture(org.id, other_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Foreign Version Station",
          location_type: 1,
          level_id: "L1"
        })

      foreign_entrance =
        stop_fixture(org.id, other_version.id, %{
          stop_id: "ENT_A",
          stop_name: "Foreign Version Entrance",
          location_type: 2,
          parent_station: foreign_station.stop_id,
          level_id: "L1"
        })

      foreign_platform =
        stop_fixture(org.id, other_version.id, %{
          stop_id: "PLAT_1",
          stop_name: "Foreign Version Platform",
          location_type: 0,
          parent_station: foreign_station.stop_id,
          level_id: "L1"
        })

      pathway_fixture(
        org.id,
        other_version.id,
        foreign_entrance.stop_id,
        foreign_platform.stop_id,
        %{
          pathway_id: "VERSION_WHEELCHAIR_SHORTCUT",
          pathway_mode: 1,
          is_bidirectional: true
        }
      )

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      _foreign_station =
        stop_fixture(other_org.id, other_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Foreign Station",
          location_type: 1,
          level_id: "L1"
        })

      _foreign_entrance =
        stop_fixture(other_org.id, other_version.id, %{
          stop_id: "ENT_A",
          stop_name: "Foreign Entrance",
          location_type: 2,
          stop_lat: Decimal.new("40.0"),
          stop_lon: Decimal.new("-74.0"),
          level_id: "L1"
        })

      assert {:ok, run} = Reachability.start_run(org.id, version.id, station.stop_id)
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run.id))
      run = wait_for_completion(run.id)

      assert run.status == "completed"
      envelope = run.result_json

      assert envelope["station"]["stop_id"] == station.stop_id
      assert envelope["station"]["stop_name"] == "Test Station"

      for pair <- envelope["pairs"] do
        assert pair["from_stop_id"] in ["ENT_A", "ENT_B", "PLAT_1", "PLAT_2", "PLAT_3"]
        assert pair["to_stop_id"] in ["ENT_A", "ENT_B", "PLAT_1", "PLAT_2", "PLAT_3"]
      end

      assert envelope["totals"]["wheelchair_unreachable"] > 0
    end
  end

  defp wait_for_completion(run_id) do
    assert_receive {:reachability_run_completed, ^run_id}, 5_000
    Repo.get!(ValidationRun, run_id)
  end
end
