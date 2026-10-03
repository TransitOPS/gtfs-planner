defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveCommandsTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.{AuditContext, Stations, Stop}
  alias GtfsPlanner.Repo

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
    station = stop_fixture(organization.id, version.id, stop_id: "LIVE_STATION", location_type: 1)
    level = level_fixture(organization.id, version.id, level_id: "LIVE_L1")

    {:ok, _attachment} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        stop_id: station.stop_id,
        level_id: level.level_id
      })

    child =
      stop_fixture(organization.id, version.id,
        stop_id: "LIVE_CHILD",
        stop_name: "Original point",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
      )

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: station.stop_id,
      actor_id: user.id,
      actor_email: user.email
    }

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      station: station,
      level: level,
      child: child,
      audit: audit
    }
  end

  test "revoked editor keeps the open form and cannot save", scope do
    view = mount_diagram(scope)
    open_child(view, scope.child)
    deactivate_membership_fixture(scope.membership)

    submit_child(view, "My draft")

    assert has_element?(
             view,
             "#child-stop-outcome",
             "You no longer have edit access to this organization."
           )

    assert has_element?(view, "#child-stop-form input[name='stop_name'][value='My draft']")
    assert has_element?(view, "#child-stop-submit[disabled]")
    assert Repo.get!(Stop, scope.child.id).stop_name == "Original point"
  end

  test "stale save preserves typed name and reloads only the revision", scope do
    view = mount_diagram(scope)
    open_child(view, scope.child)

    assert {:ok, current} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_name: "Other editor"},
               1
             )

    submit_child(view, "My draft")

    assert has_element?(view, "#child-stop-drawer-overlay[data-open='true']")

    assert has_element?(
             view,
             "#child-stop-outcome",
             "This stop changed since you opened it. Your edits are still here."
           )

    assert has_element?(view, "#child-stop-reload", "Reload station")
    assert has_element?(view, "#child-stop-form input[name='stop_name'][value='My draft']")
    assert Repo.get!(Stop, scope.child.id).stop_name == "Other editor"

    view |> element("#child-stop-reload") |> render_click()

    assert has_element?(view, "#child-stop-form input[name='stop_name'][value='My draft']")

    assert has_element?(
             view,
             "#child-stop-form input[name='lock_version'][value='#{current.lock_version}']"
           )

    refute has_element?(view, "#child-stop-outcome")
  end

  test "another station's child UUID displays not found without changing it", scope do
    foreign_station =
      stop_fixture(scope.organization.id, scope.version.id,
        stop_id: "FOREIGN_STATION",
        location_type: 1
      )

    foreign =
      stop_fixture(scope.organization.id, scope.version.id,
        stop_id: "FOREIGN_CHILD",
        parent_station: foreign_station.stop_id,
        location_type: 0,
        level_id: scope.level.level_id,
        diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
      )

    view = mount_diagram(scope)
    render_click(view, "edit_child_stop", %{"id" => foreign.id})

    assert has_element?(view, "#child-stop-outcome", "This stop no longer exists.")
    assert Repo.get!(Stop, foreign.id).stop_id == "FOREIGN_CHILD"
  end

  test "delete with one stop time reports the dependency and retains the point", scope do
    stop_time_fixture(
      scope.organization.id,
      scope.version.id,
      "LIVE_TRIP",
      scope.child.stop_id
    )

    view = mount_diagram(scope)
    open_child(view, scope.child)
    view |> element("#delete-child-stop-button") |> render_click()
    view |> element("#station-diagram-confirmation-confirm") |> render_click()

    assert has_element?(
             view,
             "#child-stop-outcome",
             "Can't delete LIVE_CHILD: still used by 1 stop time."
           )

    assert has_element?(view, "#child-stop-drawer-overlay[data-open='true']")
    assert Repo.get!(Stop, scope.child.id)
  end

  test "stale drag preserves the stored coordinate", scope do
    view = mount_diagram(scope)
    render_hook(view, "drag_start", %{"id" => scope.child.id})

    assert {:ok, _} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_name: "Other editor"},
               1
             )

    render_hook(view, "drag_end", %{"id" => scope.child.id, "x" => "50", "y" => "60"})

    assert has_element?(
             view,
             "#child-stop-outcome",
             "This stop changed since you opened it. Your edits are still here."
           )

    assert Repo.get!(Stop, scope.child.id).diagram_coordinate == %{"x" => 20.0, "y" => 30.0}
  end

  defp mount_diagram(scope) do
    conn = log_in_user(scope.conn, scope.user, organization: scope.organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{scope.version.id}/stops/#{scope.station.stop_id}/diagram")

    view
  end

  defp open_child(view, child) do
    view
    |> element("#child-stop-row-#{child.id} button[phx-click='edit_child_stop']")
    |> render_click()

    assert has_element?(
             view,
             "#child-stop-form input[name='lock_version'][value='#{child.lock_version}']"
           )
  end

  defp submit_child(view, name) do
    view
    |> form("#child-stop-form", %{"stop_name" => name})
    |> render_submit()
  end
end
