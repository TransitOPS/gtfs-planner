defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  describe "StationDiagramLive - child stop editing" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_viewer"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      # Create a parent station
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Test Station",
          location_type: 1
        })

      # Create a level for the station
      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Level 1",
          level_index: 0.0
        })

      # Associate level with station
      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level
      }
    end

    test "clicking child stop list item opens edit drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      # Create a child stop with diagram coordinates
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_STOP_1",
          stop_name: "Child Stop 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 75.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      # Click on the child stop list item
      result =
        view
        |> element("#child-stop-list-#{child_stop.id}")
        |> render_click()

      # Assert the drawer opened with populated form fields
      assert result =~ "Child Stop 1"
      assert result =~ "CHILD_STOP_1"

      # Verify the form has the correct values in the input fields
      assert result =~ ~r/value="CHILD_STOP_1"/
      assert result =~ ~r/value="Child Stop 1"/
    end
  end
end
