defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveLevelParamTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

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
        stop_id: "LEVEL_PARAM_STATION",
        stop_name: "Level Param Station",
        location_type: 1
      })

    ground_level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L1",
        level_name: "Ground",
        level_index: 0.0
      })

    upper_level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L2",
        level_name: "Upper",
        level_index: 1.0
      })

    {:ok, _ground_stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.stop_id,
        level_id: ground_level.level_id
      })

    {:ok, _upper_stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.stop_id,
        level_id: upper_level.level_id
      })

    other_station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "LEVEL_PARAM_OTHER_STATION",
        stop_name: "Level Param Other Station",
        location_type: 1
      })

    other_station_level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L3",
        level_name: "Other Station Level",
        level_index: 0.0
      })

    {:ok, _other_stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: other_station.stop_id,
        level_id: other_station_level.level_id
      })

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    }
  end

  test "opens the level named by the level query parameter", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level=L2")

    assert has_element?(
             view,
             "#level-control button[data-level-id='L2'][aria-current='true']"
           )

    refute has_element?(
             view,
             "#level-control button[data-level-id='L1'][aria-current='true']"
           )

    assert has_element?(
             view,
             "#level-control button[data-level-id='L2'][aria-current='true']",
             "Upper"
           )
  end

  test "an unknown level query parameter keeps the default level without an error flash", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level=nope")

    assert has_element?(
             view,
             "#level-control button[data-level-id='L1'][aria-current='true']"
           )

    refute has_element?(view, "#flash-error")
  end

  test "a level id from another station keeps the default level without an error flash", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level=L3")

    assert has_element?(
             view,
             "#level-control button[data-level-id='L1'][aria-current='true']"
           )

    refute has_element?(view, "#flash-error")
  end

  test "patching to a level query parameter switches the loaded station's level", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, base_path)

    assert has_element?(
             view,
             "#level-control button[data-level-id='L1'][aria-current='true']"
           )

    render_patch(view, "#{base_path}?level=L2")

    assert has_element?(
             view,
             "#level-control button[data-level-id='L2'][aria-current='true']"
           )

    refute has_element?(
             view,
             "#level-control button[data-level-id='L1'][aria-current='true']"
           )
  end
end
