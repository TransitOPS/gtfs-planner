defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveLevelCommandsTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog, Level, Stations, StopLevel}
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

    station =
      stop_fixture(organization.id, version.id, stop_id: "LEVEL_STATION", location_type: 1)

    level =
      level_fixture(organization.id, version.id, level_id: "LEVEL_ONE", level_name: "Level one")

    {:ok, stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        stop_id: station.stop_id,
        level_id: level.level_id
      })

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
      stop_level: stop_level,
      audit: audit
    }
  end

  test "stale level edit preserves the draft and reloads only its revision", scope do
    view = mount_diagram(scope)
    render_hook(view, "open_edit_level", %{})

    assert {:ok, current} =
             Stations.update_level(
               scope.audit,
               scope.level.id,
               %{level_name: "Newer name"},
               scope.level.lock_version
             )

    view |> form("#level-form", %{"level_name" => "My draft"}) |> render_submit()

    assert has_element?(view, "#level-sidebar-overlay[data-open='true']")

    assert has_element?(
             view,
             "#level-outcome[tabindex='-1']",
             "This level changed since you opened it."
           )

    assert has_element?(view, "#level-form input[name='level_name'][value='My draft']")
    assert has_element?(view, "#level-submit:not([disabled])")
    assert Repo.get!(Level, scope.level.id).level_name == "Newer name"

    view |> element("#level-reload") |> render_click()

    assert has_element?(view, "#level-form input[name='level_name'][value='My draft']")

    assert has_element?(
             view,
             "#level-form input[name='lock_version'][value='#{current.lock_version}']"
           )

    refute has_element?(view, "#level-outcome")
  end

  test "adding another organization's level reports a missing level and writes nothing", scope do
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_level = level_fixture(foreign_organization.id, foreign_version.id)
    _available_level = level_fixture(scope.organization.id, scope.version.id)

    view = mount_diagram(scope)
    render_hook(view, "open_add_level", %{})
    assert has_element?(view, "#level-form select[name='existing_level_id']")

    associations_before = Repo.aggregate(StopLevel, :count, :id)
    logs_before = Repo.aggregate(ChangeLog, :count, :id)

    render_submit(view, "save_level", %{"existing_level_id" => foreign_level.id})

    assert has_element?(view, "#level-outcome", "This level no longer exists.")
    assert has_element?(view, "#level-sidebar-overlay[data-open='true']")
    assert Repo.aggregate(StopLevel, :count, :id) == associations_before
    assert Repo.aggregate(ChangeLog, :count, :id) == logs_before

    assert is_nil(
             Gtfs.get_stop_level(
               scope.organization.id,
               scope.version.id,
               scope.station.id,
               foreign_level.id
             )
           )
  end

  test "revoked editor keeps the level draft and cannot submit again", scope do
    view = mount_diagram(scope)
    render_hook(view, "open_edit_level", %{})
    deactivate_membership_fixture(scope.membership)

    view |> form("#level-form", %{"level_name" => "Revoked draft"}) |> render_submit()

    assert has_element?(view, "#level-outcome", "You no longer have edit access")

    assert has_element?(
             view,
             "#level-form input[name='level_name'][value='Revoked draft'][disabled]"
           )

    assert has_element?(view, "#level-submit[disabled]")
    refute has_element?(view, "#level-reload")
    assert Repo.get!(Level, scope.level.id).level_name == "Level one"
  end

  test "stale ruler save keeps its entered distance and leaves scale unchanged", scope do
    {:ok, seeded} =
      put_stop_level_scale(scope.stop_level, %{
        scale_point_a: %{"x" => 10.0, "y" => 10.0},
        scale_point_b: %{"x" => 20.0, "y" => 10.0},
        scale_distance_meters: Decimal.new("25"),
        scale_meters_per_unit: Decimal.new("2.5")
      })

    view = mount_diagram(scope)
    render_hook(view, "scale_line_click", %{})

    assert {:ok, %{stop_level: current}} =
             Stations.save_scale(
               scope.audit,
               seeded.id,
               %{
                 scale_point_a: %{"x" => 10.0, "y" => 10.0},
                 scale_point_b: %{"x" => 20.0, "y" => 10.0},
                 scale_distance_meters: Decimal.new("30"),
                 scale_meters_per_unit: Decimal.new("3")
               },
               seeded.lock_version
             )

    view |> form("#ruler-form", %{"ruler" => %{"distance_meters" => "40"}}) |> render_submit()

    assert has_element?(
             view,
             "#ruler-outcome[tabindex='-1']",
             "This scale changed since you opened it."
           )

    assert has_element?(view, "#ruler-form input[name='ruler[distance_meters]'][value='40']")
    assert has_element?(view, "#ruler-submit:not([disabled])")

    assert Decimal.equal?(
             Repo.get!(StopLevel, seeded.id).scale_distance_meters,
             Decimal.new("30")
           )

    view |> element("#ruler-reload") |> render_click()
    assert has_element?(view, "#ruler-form input[name='ruler[distance_meters]'][value='40']")

    assert has_element?(
             view,
             "#ruler-form input[name='ruler[lock_version]'][value='#{current.lock_version}']"
           )
  end

  test "confirmed detach refuses a stale stop-level revision", scope do
    view = mount_diagram(scope)
    render_hook(view, "open_edit_level", %{})
    view |> element("#remove-level-from-station-button") |> render_click()

    assert {:ok, current} =
             Stations.save_alignment(
               scope.audit,
               scope.stop_level.id,
               %{
                 floorplan_center_lat: "40.0",
                 floorplan_center_lon: "-73.0",
                 floorplan_scale_mpp: "1.0",
                 floorplan_rotation_deg: "0.0"
               },
               scope.stop_level.lock_version
             )

    view |> element("#station-diagram-confirmation-confirm") |> render_click()

    assert has_element?(view, "#level-outcome", "This level changed since you opened it.")
    assert Repo.get!(StopLevel, scope.stop_level.id).lock_version == current.lock_version
  end

  test "confirmed detach records the stop-level deletion", scope do
    view = mount_diagram(scope)
    render_hook(view, "open_edit_level", %{})
    view |> element("#remove-level-from-station-button") |> render_click()
    view |> element("#station-diagram-confirmation-confirm") |> render_click()

    refute Repo.get(StopLevel, scope.stop_level.id)

    assert [%{action: "deleted", actor_id: actor_id}] =
             Gtfs.list_change_logs_for_entity(
               scope.organization.id,
               scope.version.id,
               "stop_level",
               scope.stop_level.id
             )

    assert actor_id == scope.user.id
  end

  defp mount_diagram(scope) do
    conn = log_in_user(scope.conn, scope.user, organization: scope.organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{scope.version.id}/stops/#{scope.station.stop_id}/diagram")

    view
  end
end
