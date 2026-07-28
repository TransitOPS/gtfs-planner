defmodule GtfsPlannerWeb.Gtfs.StationReachabilityResultLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Validations

  describe "StationReachabilityResultLive" do
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
          stop_id: "STATION_REACHABILITY_RESULT",
          stop_name: "Station Reachability Result",
          location_type: 1,
          parent_station: nil
        })

      %{user: user, organization: organization, gtfs_version: gtfs_version, station: station}
    end

    test "renders running spinner state for station reachability runs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "station_reachability")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert html =~ "STARTED"
    end

    test "redirects non-station runs to shared validation result page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: to_path}}} =
               live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert to_path == "/gtfs/#{version.id}/validation/#{run.id}"
    end
  end
end
