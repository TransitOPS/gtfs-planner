defmodule GtfsPlannerWeb.Gtfs.StationDiagramLivePathwayCommandsTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{AuditContext, Pathway, Stations}
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
      stop_fixture(organization.id, version.id, stop_id: "PATHWAY_STATION", location_type: 1)

    level = level_fixture(organization.id, version.id, level_id: "PATHWAY_LEVEL")

    {:ok, _attachment} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        stop_id: station.stop_id,
        level_id: level.level_id
      })

    from_stop =
      stop_fixture(organization.id, version.id,
        stop_id: "PATHWAY_FROM",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
      )

    to_stop =
      stop_fixture(organization.id, version.id,
        stop_id: "PATHWAY_TO",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 60.0, "y" => 70.0}
      )

    pathway =
      pathway_fixture(organization.id, version.id, from_stop.stop_id, to_stop.stop_id, %{
        pathway_id: "PATHWAY_EDITOR",
        traversal_time: 45,
        pathway_mode: 1,
        is_bidirectional: true
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
      from_stop: from_stop,
      to_stop: to_stop,
      pathway: pathway,
      audit: audit
    }
  end

  test "a stale save keeps the draft and reloads the revision only", scope do
    view = mount_diagram(scope)
    open_pathway(view, scope.pathway)

    assert {:ok, current} =
             Stations.update_pathway(scope.audit, scope.pathway.id, %{traversal_time: 51}, 1)

    view |> form("#pathway-form", %{"traversal_time" => "67"}) |> render_submit()

    assert has_element?(view, "#pathway-drawer-overlay[data-open='true']")

    assert has_element?(
             view,
             "#pathway-outcome[tabindex='-1']",
             "This pathway changed since you opened it. Your edits are still here."
           )

    assert has_element?(view, "#pathway-reload", "Reload station")
    assert has_element?(view, "#pathway-form input[name='traversal_time'][value='67']")
    assert has_element?(view, "#pathway-submit:not([disabled])")
    assert Repo.get!(Pathway, scope.pathway.id).traversal_time == 51

    view |> element("#pathway-reload") |> render_click()

    assert has_element?(view, "#pathway-form input[name='traversal_time'][value='67']")

    assert has_element?(
             view,
             "#pathway-form input[name='lock_version'][value='#{current.lock_version}']"
           )

    refute has_element?(view, "#pathway-outcome")
  end

  test "a flip from an older revision does not swap endpoints", scope do
    view = mount_diagram(scope)
    open_pathway(view, scope.pathway)

    assert has_element?(
             view,
             "button[phx-click='flip_pathway'][phx-value-revision='#{scope.pathway.lock_version}']"
           )

    assert {:ok, _current} =
             Stations.update_pathway(scope.audit, scope.pathway.id, %{traversal_time: 52}, 1)

    view |> element("button[phx-click='flip_pathway']") |> render_click()

    assert has_element?(view, "#pathway-outcome", "This pathway changed since you opened it")
    assert has_element?(view, "#pathway-drawer-overlay[data-open='true']")
    assert has_element?(view, "#pathway-reload")
    current = Repo.get!(Pathway, scope.pathway.id)
    assert current.from_stop_id == scope.from_stop.stop_id
    assert current.to_stop_id == scope.to_stop.stop_id
    assert current.traversal_time == 52
  end

  test "a closure-backed deletion keeps the pathway and the existing refusal", scope do
    pathway_evolution_fixture(scope.organization.id, scope.version.id, %{
      pathway_id: scope.pathway.pathway_id
    })

    view = mount_diagram(scope)
    open_pathway(view, scope.pathway)
    view |> element("#delete-pathway-button") |> render_click()
    view |> element("#station-diagram-confirmation-confirm") |> render_click()

    assert has_element?(view, "#pathway-in-use-error", "This pathway has scheduled closures")
    assert has_element?(view, "#pathway-drawer-overlay[data-open='true']")
    assert Repo.get!(Pathway, scope.pathway.id)
    assert pathway_logs(scope) == []
  end

  test "first and second pathway creation record one history entry each", scope do
    # Start with a different pair so the seeded pathway does not occupy a slot.
    third =
      stop_fixture(scope.organization.id, scope.version.id,
        stop_id: "PATHWAY_THIRD",
        location_type: 0,
        parent_station: scope.station.stop_id,
        level_id: scope.from_stop.level_id,
        diagram_coordinate: %{"x" => 80.0, "y" => 20.0}
      )

    view = mount_diagram(scope)

    render_hook(view, "create_pathway", %{
      "from_stop_id" => scope.from_stop.id,
      "to_stop_id" => third.id
    })

    [first] =
      Gtfs.list_pathways_for_station(scope.organization.id, scope.version.id, scope.station.id)
      |> Enum.filter(&(&1.to_stop_id == third.stop_id))

    assert [%{action: "created", actor_id: actor_id}] = pathway_logs(scope, first.id)
    assert actor_id == scope.user.id

    view |> element("#add-second-pathway-btn") |> render_click()

    siblings =
      Gtfs.list_pathways_for_station(scope.organization.id, scope.version.id, scope.station.id)
      |> Enum.filter(&(&1.to_stop_id == third.stop_id))

    assert length(siblings) == 2
    assert Enum.all?(siblings, fn pathway -> length(pathway_logs(scope, pathway.id)) == 1 end)
  end

  test "revoked editor cannot save from an already open drawer", scope do
    view = mount_diagram(scope)
    open_pathway(view, scope.pathway)
    deactivate_membership_fixture(scope.membership)

    view |> form("#pathway-form", %{"traversal_time" => "67"}) |> render_submit()

    assert has_element?(
             view,
             "#pathway-outcome",
             "You no longer have edit access to this organization."
           )

    assert has_element?(view, "#pathway-form input[name='traversal_time'][value='67']")
    assert has_element?(view, "#pathway-submit[disabled]")
    assert Repo.get!(Pathway, scope.pathway.id).traversal_time == 45
    assert pathway_logs(scope) == []
  end

  test "a deleted pathway keeps the open draft and reports the missing row", scope do
    view = mount_diagram(scope)
    open_pathway(view, scope.pathway)

    assert {:ok, _deleted} =
             Stations.delete_pathway(scope.audit, scope.pathway.id, scope.pathway.lock_version)

    view |> form("#pathway-form", %{"traversal_time" => "67"}) |> render_submit()

    assert has_element?(view, "#pathway-drawer-overlay[data-open='true']")
    assert has_element?(view, "#pathway-outcome", "This pathway no longer exists.")
    assert has_element?(view, "#pathway-form input[name='traversal_time'][value='67']")
    assert has_element?(view, "#pathway-reload")
    refute Repo.get(Pathway, scope.pathway.id)
  end

  defp mount_diagram(scope) do
    conn = log_in_user(scope.conn, scope.user, organization: scope.organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{scope.version.id}/stops/#{scope.station.stop_id}/diagram")

    view
  end

  defp open_pathway(view, pathway) do
    view
    |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
    |> render_click()

    assert has_element?(
             view,
             "#pathway-form input[name='lock_version'][value='#{pathway.lock_version}']"
           )
  end

  defp pathway_logs(scope, pathway_id \\ nil) do
    Gtfs.list_change_logs_for_entity(
      scope.organization.id,
      scope.version.id,
      "pathway",
      pathway_id || scope.pathway.id
    )
  end
end
