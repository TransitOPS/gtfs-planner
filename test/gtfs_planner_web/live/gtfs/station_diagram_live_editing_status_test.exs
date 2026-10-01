defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveEditingStatusTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  setup do
    organization = organization_fixture()
    user = user_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, version.id, stop_id: "STATUS_STATION", location_type: 1)

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      station: station
    }
  end

  test "marking and finishing editing writes and clears the editor's own status", scope do
    view = mount_diagram(scope)

    view |> element("#mark-editing-button") |> render_click()

    assert has_element?(view, "#editing-status-text", "You're editing")

    assert Gtfs.get_station_editing_status(
             scope.organization.id,
             scope.version.id,
             scope.station.id
           ).user_id == scope.user.id

    view |> element("#done-editing-button") |> render_click()

    assert has_element?(view, "#mark-editing-button")

    assert Gtfs.get_station_editing_status(
             scope.organization.id,
             scope.version.id,
             scope.station.id
           ) == nil
  end

  test "an editor revoked after the page loaded cannot mark the station as editing", scope do
    view = mount_diagram(scope)
    deactivate_membership_fixture(scope.membership)

    view |> element("#mark-editing-button") |> render_click()

    assert has_element?(view, "#flash-error", "You no longer have edit access")
    assert has_element?(view, "#mark-editing-button")

    assert Gtfs.get_station_editing_status(
             scope.organization.id,
             scope.version.id,
             scope.station.id
           ) == nil
  end

  test "an editor revoked after the page loaded cannot clear a status", scope do
    view = mount_diagram(scope)
    view |> element("#mark-editing-button") |> render_click()
    deactivate_membership_fixture(scope.membership)

    view |> element("#done-editing-button") |> render_click()

    assert has_element?(view, "#flash-error", "You no longer have edit access")
    assert has_element?(view, "#done-editing-button")

    assert Gtfs.get_station_editing_status(
             scope.organization.id,
             scope.version.id,
             scope.station.id
           ).user_id == scope.user.id
  end

  defp mount_diagram(scope) do
    conn = log_in_user(scope.conn, scope.user, organization: scope.organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{scope.version.id}/stops/#{scope.station.stop_id}/diagram")

    view
  end
end
