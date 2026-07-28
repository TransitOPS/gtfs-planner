defmodule GtfsPlanner.ReachabilityTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Repo
  alias GtfsPlanner.TestSupport.ControlledReachabilityRunner
  alias GtfsPlanner.Validations.ValidationRun

  setup do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    _level = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})

    station =
      stop_fixture(org.id, version.id, %{stop_id: "STATION", location_type: 1, level_id: "L1"})

    entrance =
      stop_fixture(org.id, version.id, %{
        stop_id: "ENTRANCE",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L1"
      })

    platform =
      stop_fixture(org.id, version.id, %{
        stop_id: "PLATFORM",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L1"
      })

    pathway_fixture(org.id, version.id, entrance.stop_id, platform.stop_id, %{traversal_time: 30})

    ControlledReachabilityRunner.put_owner(self())
    on_exit(&ControlledReachabilityRunner.clear_owner/0)

    %{org: org, version: version, station: station}
  end

  test "creates, broadcasts, and persists a completed run", %{
    org: org,
    version: version,
    station: station
  } do
    assert {:ok, run} = start_controlled_run(org, version, station)
    run_id = run.id
    runner_pid = await_runner()

    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run_id))
    complete_runner(runner_pid)

    assert_receive {:reachability_run_completed, ^run_id}, 5_000

    assert %ValidationRun{status: "completed", engine: "pathways_router"} =
             Repo.get!(ValidationRun, run_id)
  end

  test "admits one active run, permits a different station, and admits again after completion", %{
    org: org,
    version: version,
    station: station
  } do
    assert {:ok, run} = start_controlled_run(org, version, station)
    run_id = run.id
    runner_pid = await_runner()

    assert {:error, :run_in_progress} = start_controlled_run(org, version, station)

    other_station =
      stop_fixture(org.id, version.id, %{stop_id: "OTHER_STATION", location_type: 1})

    assert {:ok, _other_run} = start_controlled_run(org, version, other_station)
    other_runner_pid = await_runner()
    complete_runner(other_runner_pid)

    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run_id))
    complete_runner(runner_pid)
    assert_receive {:reachability_run_completed, ^run_id}, 5_000

    assert {:ok, retry_run} = start_controlled_run(org, version, station)
    retry_runner_pid = await_runner()
    complete_runner(retry_runner_pid)
    assert retry_run.id != run.id
  end

  test "rejects unknown stations without persisting a run", %{org: org, version: version} do
    assert {:error, :station_not_found} = Reachability.start_run(org.id, version.id, "MISSING")
    assert run_count(org.id, version.id) == 0
  end

  test "rejects an oversized battery without persisting a run", %{
    org: org,
    version: version,
    station: station
  } do
    for index <- 1..20 do
      stop_fixture(org.id, version.id, %{
        stop_id: "EXTRA_ENTRANCE_#{index}",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L1"
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "EXTRA_PLATFORM_#{index}",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L1"
      })
    end

    assert {:error, :battery_too_large} = start_controlled_run(org, version, station)
    assert run_count(org.id, version.id) == 0
  end

  test "persists injected runner failures and broadcasts the terminal failure", %{
    org: org,
    version: version,
    station: station
  } do
    assert {:ok, run} = start_controlled_run(org, version, station)
    run_id = run.id
    runner_pid = await_runner()

    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run_id))
    fail_runner(runner_pid)

    assert_receive {:reachability_run_failed, ^run_id, :injected_failure}, 5_000

    assert %ValidationRun{status: "failed", error_details: ":injected_failure"} =
             Repo.get!(ValidationRun, run_id)
  end

  test "returns active and recent runs only within the requested station scope", %{
    org: org,
    version: version,
    station: station
  } do
    assert {:ok, run} = start_controlled_run(org, version, station)
    run_id = run.id
    runner_pid = await_runner()

    assert %ValidationRun{id: ^run_id} =
             Reachability.get_active_run(org.id, version.id, station.stop_id)

    assert [%ValidationRun{id: ^run_id}] =
             Reachability.list_recent_runs(org.id, version.id, station.stop_id)

    complete_runner(runner_pid)
  end

  defp start_controlled_run(org, version, station) do
    Reachability.start_run(org.id, version.id, station.stop_id,
      runner: ControlledReachabilityRunner
    )
  end

  defp await_runner do
    assert_receive {:controlled_runner_started, runner_pid}, 5_000
    runner_pid
  end

  defp complete_runner(runner_pid) do
    ref = Process.monitor(runner_pid)
    send(runner_pid, :complete)
    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :normal}, 5_000
  end

  defp fail_runner(runner_pid) do
    ref = Process.monitor(runner_pid)
    send(runner_pid, :fail)
    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :normal}, 5_000
  end

  defp run_count(organization_id, gtfs_version_id) do
    ValidationRun
    |> where(
      [run],
      run.organization_id == ^organization_id and run.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count, :id)
  end
end
