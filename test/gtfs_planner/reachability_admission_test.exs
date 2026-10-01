defmodule GtfsPlanner.ReachabilityAdmissionTest do
  @moduledoc """
  Station reachability runs under the bounded runner supervisor. A controlled
  runner holds the only slot of the application-started supervisor; a run for
  another station is refused and failed as busy without reading anything, the
  page says so and stays usable, and a new run completes once the slot is free.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.TestSupport.ControlledReachabilityRunner
  alias GtfsPlanner.Validations.ValidationRun

  setup %{conn: conn} do
    RunnerSlots.await_idle()

    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})

    ControlledReachabilityRunner.put_owner(self())

    # A runner left blocked by a failed assertion is killed before the sandbox
    # connection is released.
    on_exit(fn ->
      RunnerSlots.await_idle(1_000)
      ControlledReachabilityRunner.clear_owner()
    end)

    %{
      conn: log_in_user(conn, user, organization: organization),
      org: organization,
      version: version,
      held: station_with_walk(organization, version, "HELD"),
      waiting: station_with_walk(organization, version, "WAITING")
    }
  end

  describe "start_run/4 at capacity" do
    test "refuses a run for another station and fails it as busy", ctx do
      %{org: org, version: version, held: held, waiting: waiting} = ctx
      {held_run, runner} = hold_slot(org, version, held)

      assert {:error, :busy} = start_controlled_run(org, version, waiting)

      assert [%ValidationRun{status: "failed", error_details: "busy", completed_at: %DateTime{}}] =
               station_runs(org, version, waiting)

      assert Reachability.get_active_run(org.id, version.id, waiting.stop_id) == nil
      assert Reachability.list_recent_runs(org.id, version.id, waiting.stop_id) == []
      assert DynamicSupervisor.count_children(Reachability.RunnerSupervisor).active == 1
      assert %ValidationRun{status: "running"} = Repo.get!(ValidationRun, held_run.id)
      refute_received {:controlled_runner_started, _}

      release(runner)
    end

    test "completes a new run once the held runner has finished", ctx do
      %{org: org, version: version, held: held, waiting: waiting} = ctx
      {held_run, held_runner} = hold_slot(org, version, held)
      assert {:error, :busy} = start_controlled_run(org, version, waiting)

      release(held_runner)
      RunnerSlots.await_idle()
      assert %ValidationRun{status: "completed"} = Repo.get!(ValidationRun, held_run.id)

      assert {:ok, run} = start_controlled_run(org, version, waiting)
      run_id = run.id
      assert_receive {:controlled_runner_started, runner}, 5_000
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run_id))
      release(runner)

      assert_receive {:reachability_run_completed, ^run_id}, 5_000
      assert %ValidationRun{status: "completed"} = Repo.get!(ValidationRun, run_id)

      assert station_runs(org, version, waiting) |> Enum.map(& &1.status) |> Enum.sort() ==
               ["completed", "failed"]
    end
  end

  describe "StationReachabilityLive at capacity" do
    test "says another check is running, stays usable and keeps the last result", ctx do
      %{conn: conn, org: org, version: version, held: held, waiting: waiting} = ctx
      path = "/gtfs/#{version.id}/stops/#{waiting.stop_id}/reachability"
      {_held_run, runner} = hold_slot(org, version, held)
      {:ok, view, _html} = live(conn, path)

      view |> element("#run-reachability-btn") |> render_click()

      assert has_element?(view, "#run-error", "Another reachability check is running.")
      assert has_element?(view, "#run-error", "Try again when it finishes.")
      assert has_element?(view, "#run-reachability-btn:not([disabled])", "Run check")
      refute has_element?(view, "#reachability-running")

      {:ok, reloaded, _html} = live(conn, path)
      refute has_element?(reloaded, "#last-reachability-run")
      assert has_element?(reloaded, "#last-reachability-run-none")

      release(runner)
    end
  end

  # A station with one entrance and one platform joined by a pathway, so the
  # real runner completes it.
  defp station_with_walk(org, version, prefix) do
    station =
      stop_fixture(org.id, version.id, %{
        stop_id: "#{prefix}_STATION",
        location_type: 1,
        level_id: "L1"
      })

    entrance =
      stop_fixture(org.id, version.id, %{
        stop_id: "#{prefix}_ENTRANCE",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L1"
      })

    platform =
      stop_fixture(org.id, version.id, %{
        stop_id: "#{prefix}_PLATFORM",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L1"
      })

    pathway_fixture(org.id, version.id, entrance.stop_id, platform.stop_id, %{traversal_time: 30})

    station
  end

  defp start_controlled_run(org, version, station) do
    Reachability.start_run(org.id, version.id, station.stop_id,
      runner: ControlledReachabilityRunner
    )
  end

  defp hold_slot(org, version, station) do
    assert {:ok, run} = start_controlled_run(org, version, station)
    assert_receive {:controlled_runner_started, runner}, 5_000
    {run, runner}
  end

  defp release(runner) do
    ref = Process.monitor(runner)
    send(runner, :complete)
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 5_000
  end

  defp station_runs(org, version, station) do
    Repo.all(
      from(r in ValidationRun,
        where:
          r.organization_id == ^org.id and r.gtfs_version_id == ^version.id and
            r.run_type == "station_reachability" and
            fragment("result_json -> 'metadata' ->> 'station_stop_id' = ?", ^station.stop_id)
      )
    )
  end
end
