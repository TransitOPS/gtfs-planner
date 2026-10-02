defmodule GtfsPlannerWeb.Gtfs.StationDiagramChildLevelTest do
  @moduledoc """
  GTFS needs `level_id` only for elevator pathways, so `Stop.changeset/2` leaves
  it optional for the map editor. The station diagram's own child-stop form still
  requires a level, and this test holds that line: a submit with no level shows
  the level error and inserts no stop.
  """

  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  setup %{conn: conn} do
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
        stop_id: "LEVEL_STATION",
        stop_name: "Level Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "LEVEL_L1",
        level_name: "Concourse",
        level_index: 0.0
      })

    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

    %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    }
  end

  test "submitting a child stop with no level shows the level error and inserts no stop", %{
    view: view,
    organization: organization,
    gtfs_version: gtfs_version
  } do
    render_hook(view, "switch_mode", %{"mode" => "add"})
    render_hook(view, "canvas_click", %{"x" => "30", "y" => "40"})

    render_submit(view, "save_child_stop", %{
      "stop_id" => "level_free_point",
      "stop_name" => "Level free point",
      "location_type" => "3",
      "level_id" => "",
      "wheelchair_boarding" => "",
      "x" => "30",
      "y" => "40"
    })

    assert Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "level_free_point") == nil

    assert has_element?(view, "#child-stop-form")
    assert has_element?(view, "#child-stop-level-error-0", "can\u0027t be blank")
  end

  test "the same child stop saves once a level is named", %{
    view: view,
    organization: organization,
    gtfs_version: gtfs_version,
    level: level
  } do
    render_hook(view, "switch_mode", %{"mode" => "add"})
    render_hook(view, "canvas_click", %{"x" => "30", "y" => "40"})

    render_submit(view, "save_child_stop", %{
      "stop_id" => "level_point",
      "stop_name" => "Level point",
      "location_type" => "3",
      "level_id" => level.level_id,
      "wheelchair_boarding" => "",
      "x" => "30",
      "y" => "40"
    })

    assert %{stop_id: "level_point"} =
             Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "level_point")
  end
end
