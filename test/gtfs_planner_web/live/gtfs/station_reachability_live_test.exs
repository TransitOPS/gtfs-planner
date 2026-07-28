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
