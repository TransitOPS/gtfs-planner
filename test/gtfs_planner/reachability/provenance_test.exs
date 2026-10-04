defmodule GtfsPlanner.Reachability.ProvenanceTest do
  @moduledoc """
  Proves the recorded provenance comes from the execution snapshot the default
  `Reachability.start_run/4` path actually routed, through the real `Runner`
  and the real supervised run.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations.ValidationRun

  setup do
    RunnerSlots.await_idle()

    org = organization_fixture()
    version = gtfs_version_fixture(org.id)

    _ground = level_fixture(org.id, version.id, %{level_id: "L1", level_index: 0.0})

    station =
      stop_fixture(org.id, version.id, %{
        stop_id: "STATION_1",
        stop_name: "Provenance Station",
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

    pathway =
      pathway_fixture(org.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_1",
        pathway_mode: 1,
        traversal_time: 45,
        min_width: Decimal.new("1.05")
      })

    %{org: org, version: version, station: station, pathway: pathway}
  end

  test "the default run persists provenance for the snapshot it routed", %{
    org: org,
    version: version,
    station: station
  } do
    run = run_to_completion(org, version, station.stop_id)

    assert run.status == "completed"

    assert %{"version" => 1, "closure_evaluation" => "not_evaluated", "digest" => digest} =
             run.result_json["input_provenance"]

    assert digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "an unchanged dataset reproduces the digest, a pathway width change does not", %{
    org: org,
    version: version,
    station: station,
    pathway: pathway
  } do
    first = run_to_completion(org, version, station.stop_id)
    second = run_to_completion(org, version, station.stop_id)

    assert first.result_json["input_provenance"] == second.result_json["input_provenance"]

    {:ok, _updated} =
      pathway
      |> Ecto.Changeset.change(%{min_width: Decimal.new("0.90")})
      |> Repo.update()

    third = run_to_completion(org, version, station.stop_id)

    refute third.result_json["input_provenance"]["digest"] ==
             first.result_json["input_provenance"]["digest"]

    # The earlier result still describes what it was computed from.
    reread = Repo.get!(ValidationRun, first.id)
    assert reread.result_json["input_provenance"] == first.result_json["input_provenance"]
  end

  # The run's task can finish before this looks for it, so both "no new task"
  # and "task already dead when monitored" mean it completed; the persisted row
  # decides.
  defp run_to_completion(org, version, station_stop_id) do
    task_pids_before = MapSet.new(runner_pids())

    assert {:ok, run} = Reachability.start_run(org.id, version.id, station_stop_id)

    case Enum.find(runner_pids(), &(&1 not in task_pids_before)) do
      nil ->
        :ok

      task_pid ->
        ref = Process.monitor(task_pid)
        assert_receive {:DOWN, ^ref, :process, ^task_pid, reason}, 5_000
        assert reason in [:normal, :noproc]
    end

    completed = Repo.get!(ValidationRun, run.id)

    assert completed.status in ["completed", "failed"],
           "run #{run.id} is #{completed.status} after its task exited"

    completed
  end

  defp runner_pids do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(GtfsPlanner.Reachability.RunnerSupervisor),
        is_pid(pid),
        do: pid
  end
end
