defmodule GtfsPlannerWeb.Gtfs.StationReachabilityLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "REACHABILITY_TAB_STATION",
        stop_name: "Reachability Tab Station",
        location_type: 1,
        parent_station: nil
      })

    %{user: user, organization: organization, gtfs_version: gtfs_version, station: station}
  end

  test "offers only the latest finished run, not a run history", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version,
    station: station
  } do
    older = finished_run(organization, version, station, "failed")
    backdate!(older, -3600)
    latest = finished_run(organization, version, station, "completed")

    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/reachability")

    assert has_element?(
             view,
             ~s(#last-reachability-run a[href="/gtfs/#{version.id}/station-reachability/#{latest.id}?stop_id=#{station.stop_id}"]),
             "View results"
           )

    refute has_element?(view, "table")
  end

  test "omits the last run row until a run finishes", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version,
    station: station
  } do
    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/reachability")

    refute has_element?(view, "#last-reachability-run")
  end

  describe "check states" do
    test "enables the run button when the only active run is past the timeout", ctx do
      %{conn: conn, user: user, organization: organization, gtfs_version: version} = ctx
      station = station_with_walks(organization, version)

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "station_reachability")

      run
      |> ValidationRun.changeset(%{
        status: "running",
        started_at: DateTime.add(DateTime.utc_now(), -16 * 60, :second),
        result_json: %{"metadata" => %{"station_stop_id" => station.stop_id}}
      })
      |> Repo.update!()

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#run-reachability-btn")
      refute has_element?(view, "#run-reachability-btn[disabled]")
    end

    test "offers the first check when the station has walks to test and no result yet", ctx do
      %{conn: conn, user: user, organization: organization, gtfs_version: version} = ctx
      station = station_with_walks(organization, version)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#run-reachability-btn:not([disabled])", "Run check")
      assert has_element?(view, "#run-reachability-hint", "Tests 6 walks")
      assert has_element?(view, "#last-reachability-run-none", "hasn't been checked yet")
      assert has_element?(view, "#reachability-coverage", "12 checks in total")
      refute has_element?(view, "#reachability-empty-battery")
    end

    test "says there is nothing to test and links to floorplans when the station has no walks",
         ctx do
      %{conn: conn, user: user, organization: organization} = ctx
      version = ctx.gtfs_version
      station = ctx.station

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#reachability-empty-battery", "There's nothing to test yet.")

      assert has_element?(
               view,
               ~s(#open-floorplans[href="/gtfs/#{version.id}/stops/#{station.stop_id}/diagram"])
             )

      refute has_element?(view, "#run-reachability-btn")
      refute has_element?(view, "#reachability-coverage")
    end

    test "shows the last run as unfinished when it failed", ctx do
      %{conn: conn, user: user, organization: organization, gtfs_version: version} = ctx
      station = station_with_walks(organization, version)
      run = finished_run(organization, version, station, "failed")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#last-reachability-run", "Didn't finish")

      assert has_element?(
               view,
               ~s(#last-reachability-run a[href="/gtfs/#{version.id}/station-reachability/#{run.id}?stop_id=#{station.stop_id}"]),
               "View details"
             )

      refute has_element?(view, "#last-reachability-run-none")
    end

    test "disables the run button and shows progress while a check runs", ctx do
      %{conn: conn, user: user, organization: organization, gtfs_version: version} = ctx
      station = station_with_walks(organization, version)
      _run = active_run(organization, version, station)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#run-reachability-btn[disabled]", "Checking")
      assert has_element?(view, "#reachability-running", "Checking 6 walks")
      refute has_element?(view, "#last-reachability-run-none")
    end
  end

  # One entrance and two platforms: 2 entry, 2 egress and 2 transfer walks, each
  # planned in two modes.
  defp station_with_walks(organization, version) do
    station =
      stop_fixture(organization.id, version.id, %{
        stop_id: "WALKS_STATION",
        stop_name: "Walks Station",
        location_type: 1,
        parent_station: nil
      })

    level_fixture(organization.id, version.id, %{level_id: "WALKS_L1", level_index: 0.0})

    for {stop_id, location_type} <- [{"WALKS_ENT", 2}, {"WALKS_PLAT_1", 0}, {"WALKS_PLAT_2", 0}] do
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: stop_id,
        location_type: location_type,
        parent_station: station.stop_id,
        level_id: "WALKS_L1"
      })
    end

    station
  end

  defp active_run(organization, version, station) do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "station_reachability")

    run
    |> ValidationRun.changeset(%{
      status: "running",
      result_json: %{"metadata" => %{"station_stop_id" => station.stop_id}}
    })
    |> Repo.update!()
  end

  defp backdate!(run, seconds) do
    inserted_at = DateTime.add(DateTime.utc_now(), seconds, :second)

    run
    |> Ecto.Changeset.change(%{})
    |> Ecto.Changeset.force_change(:inserted_at, inserted_at)
    |> Repo.update!()
  end

  defp finished_run(organization, version, station, status) do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "station_reachability")

    run
    |> ValidationRun.changeset(%{
      status: status,
      engine: "pathways_router",
      result_json: %{"metadata" => %{"station_stop_id" => station.stop_id}},
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end
end
