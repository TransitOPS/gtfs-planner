defmodule GtfsPlannerWeb.Gtfs.StopDetailLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  describe "StopDetailLive - station editing status" do
    setup do
      organization = organization_fixture()
      viewer = user_fixture(%{email: "viewer@example.com"})
      editor = user_fixture(%{email: "editor@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: viewer.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_STATUS",
          stop_name: "Status Station",
          location_type: 1
        })

      %{
        viewer: viewer,
        editor: editor,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "assigns an existing station editing status when the station page loads", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 editor
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status.id == status.id
      assert state.socket.assigns.station_editing_status.user.id == editor.id
      assert state.socket.assigns.station_editing_status.user.email == editor.email
    end

    test "updates the station editing status assign from PubSub broadcasts", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.station_editing_status == nil

      assert {:ok, status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 editor
               )

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status.id == status.id
      assert state.socket.assigns.station_editing_status.user.id == editor.id

      assert :ok = Gtfs.clear_station_editing_status(organization.id, gtfs_version.id, station.id)

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.station_editing_status == nil
    end
  end

  describe "StopDetailLive - No Level child stop edit link" do
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
          stop_id: "STATION_1",
          stop_name: "Test Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Level 1",
          level_index: 0.0
        })

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

    test "renders Edit in Diagram link for No Level child stops with correct href", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      # ORPHAN_LEVEL is a level_id with no matching Level row, so the
      # stop's preloaded :level association is nil → groups under "No Level".
      no_level_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_NO_LEVEL",
          stop_name: "Child No Level",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ORPHAN_LEVEL"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      expected_href =
        "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?edit_child_stop_id=#{no_level_stop.id}"

      assert has_element?(
               view,
               "#child-stop-row-#{no_level_stop.id} a[href=\"#{expected_href}\"]",
               "Edit in Diagram"
             )
    end

    test "does not render Edit in Diagram link for child stops with a level", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      leveled_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_WITH_LEVEL",
          stop_name: "Child With Level",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert html =~ "CHILD_WITH_LEVEL"
      assert html =~ "Child With Level"

      refute has_element?(
               view,
               "#child-stop-row-#{leveled_stop.id} a",
               "Edit in Diagram"
             )
    end

    test "only No Level rows get the edit link when both groups exist", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      no_level_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_NO_LEVEL_2",
          stop_name: "Child No Level 2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ORPHAN_LEVEL_2"
        })

      leveled_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_WITH_LEVEL_2",
          stop_name: "Child With Level 2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      expected_href =
        "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?edit_child_stop_id=#{no_level_stop.id}"

      assert has_element?(
               view,
               "#child-stop-row-#{no_level_stop.id} a[href=\"#{expected_href}\"]",
               "Edit in Diagram"
             )

      refute has_element?(
               view,
               "#child-stop-row-#{leveled_stop.id} a",
               "Edit in Diagram"
             )
    end
  end
end
