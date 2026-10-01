defmodule GtfsPlanner.ReachabilityTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.TestSupport.ControlledReachabilityRunner
  alias GtfsPlanner.Validations.ValidationRun

  setup do
    # One reachability run fits the supervisor; wait out the previous test's
    # runner before this test starts its own.
    RunnerSlots.await_idle()

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

  test "admits one active run per station and admits again after completion", %{
    org: org,
    version: version,
    station: station
  } do
    assert {:ok, run} = start_controlled_run(org, version, station)
    run_id = run.id
    runner_pid = await_runner()

    assert {:error, :run_in_progress} = start_controlled_run(org, version, station)

    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run_id))
    complete_runner(runner_pid)
    assert_receive {:reachability_run_completed, ^run_id}, 5_000
    RunnerSlots.await_idle()

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

  test "fails a run left active past the timeout and starts a new one", %{
    org: org,
    version: version,
    station: station
  } do
    stale = insert_active_run(org.id, version.id, station.stop_id, minutes_ago: 16)

    assert {:ok, run} = start_controlled_run(org, version, station)
    complete_runner(await_runner())

    assert run.id != stale.id

    assert %ValidationRun{
             status: "failed",
             error_details: "The run was interrupted before it finished.",
             completed_at: %DateTime{}
           } = Repo.get!(ValidationRun, stale.id)
  end

  test "does not report a run left active past the timeout as active", %{
    org: org,
    version: version,
    station: station
  } do
    insert_active_run(org.id, version.id, station.stop_id, minutes_ago: 16)

    assert Reachability.get_active_run(org.id, version.id, station.stop_id) == nil
  end

  test "keeps blocking a start while an active run is younger than the timeout", %{
    org: org,
    version: version,
    station: station
  } do
    recent = insert_active_run(org.id, version.id, station.stop_id, minutes_ago: 1)

    assert {:error, :run_in_progress} = start_controlled_run(org, version, station)

    assert Repo.get!(ValidationRun, recent.id) == recent
  end

  test "leaves stale active runs of another station, version, or organization untouched", %{
    org: org,
    version: version,
    station: station
  } do
    other_version = gtfs_version_fixture(org.id)
    other_org = organization_fixture()
    other_org_version = gtfs_version_fixture(other_org.id)

    other_runs = [
      insert_active_run(org.id, version.id, "OTHER_STATION", minutes_ago: 16),
      insert_active_run(org.id, other_version.id, station.stop_id, minutes_ago: 16),
      insert_active_run(other_org.id, other_org_version.id, station.stop_id, minutes_ago: 16)
    ]

    assert {:ok, _run} = start_controlled_run(org, version, station)
    complete_runner(await_runner())

    for other_run <- other_runs do
      assert Repo.get!(ValidationRun, other_run.id) == other_run
    end
  end

  defp insert_active_run(organization_id, gtfs_version_id, station_stop_id, minutes_ago: minutes) do
    %ValidationRun{}
    |> ValidationRun.changeset(%{
      run_type: "station_reachability",
      status: "running",
      engine: "pathways_router",
      result_schema_version: 1,
      started_at: DateTime.add(DateTime.utc_now(), -minutes * 60, :second),
      result_json: %{"metadata" => %{"station_stop_id" => station_stop_id}}
    })
    |> Ecto.Changeset.put_change(:organization_id, organization_id)
    |> Ecto.Changeset.put_change(:gtfs_version_id, gtfs_version_id)
    |> Repo.insert!()
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
