defmodule GtfsPlannerWeb.Gtfs.StopDetailLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo

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

    test "renders the idle station editing status button", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="set_station_editing_status"][title="Let others know you're editing this Station."]),
               "I'm editing this Station"
             )

      render_click(element(view, "#station-editing-status-button"))

      status = Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id)

      assert status.user.id == viewer.id
    end

    test "does not render the station editing status banner when no status is active", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      refute has_element?(view, "#station-editing-status-banner")
    end

    test "renders the owner active station editing status button", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, _status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 viewer
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="clear_station_editing_status"][title="Let others know you're done editing this Station."]),
               "I'm done"
             )

      render_click(element(view, "#station-editing-status-button"))

      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end

    test "renders the owner station editing status banner copy", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      started_at = DateTime.add(DateTime.utc_now(), -5 * 60, :second)

      station_editing_status_fixture_started_at!(
        organization,
        gtfs_version,
        station,
        viewer,
        started_at
      )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(view, "#station-editing-status-banner", "You're editing this Station.")

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "Others have been notified. Remember to clear this when you're done."
             )

      assert has_element?(view, "#station-editing-status-banner", "Started 5 minutes ago")
      assert has_element?(view, "#station-editing-status-banner-clear-button", "I'm done")
    end

    test "renders the other-user active station editing status button", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, _status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 editor
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="clear_station_editing_status"][title="Clear this editing status for everyone."]),
               "Clear editing status"
             )
    end

    test "renders the other-user station editing status banner copy", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      started_at = DateTime.add(DateTime.utc_now(), -60 * 60, :second)

      station_editing_status_fixture_started_at!(
        organization,
        gtfs_version,
        station,
        editor,
        started_at
      )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "#{editor.email} is editing this Station."
             )

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "You can view it, but it's best to wait before making changes."
             )

      assert has_element?(view, "#station-editing-status-banner", "Started 1 hour ago")

      assert has_element?(
               view,
               "#station-editing-status-banner-clear-button",
               "Clear editing status"
             )
    end

    test "clears the active status from the station editing status banner button", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, _status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 viewer
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      render_click(element(view, "#station-editing-status-banner-clear-button"))

      refute has_element?(view, "#station-editing-status-banner")
      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end

    test "renders every relative started time bucket in the station editing status banner", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      cases = [
        {0, "just now"},
        {60, "1 minute ago"},
        {5 * 60, "5 minutes ago"},
        {60 * 60, "1 hour ago"},
        {3 * 60 * 60, "3 hours ago"}
      ]

      Enum.each(cases, fn {seconds_ago, expected} ->
        station =
          stop_fixture(organization.id, gtfs_version.id, %{
            stop_id: "STATUS_TIME_#{seconds_ago}",
            stop_name: "Status Time #{seconds_ago}",
            location_type: 1
          })

        started_at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

        station_editing_status_fixture_started_at!(
          organization,
          gtfs_version,
          station,
          viewer,
          started_at
        )

        {:ok, view, _html} =
          live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

        assert has_element?(
                 view,
                 "#station-editing-status-banner",
                 "Started #{expected}"
               )
      end)
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

    test "set_station_editing_status event creates a status owned by the current user", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      render_click(view, "set_station_editing_status")

      state = :sys.get_state(view.pid)
      assigned_status = state.socket.assigns.station_editing_status

      persisted_status =
        Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id)

      assert assigned_status.user.id == viewer.id
      assert persisted_status.id == assigned_status.id
      assert persisted_status.user.id == viewer.id
    end

    test "clear_station_editing_status event clears the active status", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, _status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 viewer
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      render_click(view, "clear_station_editing_status")

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status == nil
      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end

    test "set_station_editing_status event leaves the assign unchanged when setting fails", %{
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

      assert {:ok, _station} = Gtfs.delete_stop(station)

      render_click(view, "set_station_editing_status")

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status.id == status.id
      assert state.socket.assigns.station_editing_status.user.id == editor.id
      assert has_element?(view, "#flash-error", "Failed to set station editing status")
      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end
  end

  defp station_editing_status_fixture_started_at!(
         organization,
         gtfs_version,
         station,
         user,
         started_at
       ) do
    assert {:ok, status} =
             Gtfs.set_station_editing_status(
               organization.id,
               gtfs_version.id,
               station,
               user
             )

    status
    |> Ecto.Changeset.change(started_at: started_at)
    |> Repo.update!()
    |> Repo.preload(:user)
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
