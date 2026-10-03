defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveNamingRollbackTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog, Pathway, Stations, Stop}
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, version.id,
        stop_id: "NAMING_STATION",
        location_type: 1
      )

    child =
      child_stop_fixture(organization.id, version.id, station.stop_id,
        stop_id: "ORIGINAL_CHILD",
        stop_name: "Child platform",
        diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
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
      version: version,
      station: station,
      child: child,
      audit: audit
    }
  end

  test "a changed stop ID refreshes the naming preview and keeps apply available", scope do
    view = mount_diagram(scope)
    render_hook(view, "open_naming_drawer", %{})
    assert has_element?(view, "#naming-row-ORIGINAL_CHILD")

    assert {:ok, _renamed} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_id: "CONCURRENT_CHILD"},
               scope.child.lock_version
             )

    log_count = Repo.aggregate(ChangeLog, :count)
    render_hook(view, "apply_naming_convention", %{})

    assert has_element?(
             view,
             "#naming-outcome[tabindex='-1']",
             "Stop IDs changed since this preview. Review the new preview before applying."
           )

    assert has_element?(view, "#naming-row-CONCURRENT_CHILD")
    refute has_element?(view, "#naming-row-ORIGINAL_CHILD")
    assert has_element?(view, "#apply-naming-convention:not([disabled])")
    assert Repo.get!(Stop, scope.child.id).stop_id == "CONCURRENT_CHILD"
    assert Repo.aggregate(ChangeLog, :count) == log_count
  end

  test "a newer edit keeps the rollback panel open and writes no rollback", scope do
    assert {:ok, first_edit} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_name: "First edit"},
               scope.child.lock_version
             )

    [log] = logs(scope, "stop", scope.child.id)
    view = mount_diagram(scope)
    open_history(view, "stop", scope.child.id)
    render_hook(view, "preview_rollback_change_log", %{"log-id" => log.id})

    assert :sys.get_state(view.pid).socket.assigns.rollback_preview.expected_revision ==
             first_edit.lock_version

    assert {:ok, newer_edit} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_name: "Newer edit"},
               first_edit.lock_version
             )

    log_count = Repo.aggregate(ChangeLog, :count)
    render_hook(view, "confirm_rollback_change_log", %{"log-id" => log.id})

    assert has_element?(
             view,
             "#rollback-outcome[tabindex='-1']",
             "This item changed after the preview. Review the change again."
           )

    assert has_element?(view, "#rollback-preview-review-stop")
    refute has_element?(view, "#rollback-preview-confirm-stop")
    assert Repo.get!(Stop, scope.child.id).lock_version == newer_edit.lock_version
    assert Repo.get!(Stop, scope.child.id).stop_name == "Newer edit"
    assert Repo.aggregate(ChangeLog, :count) == log_count
  end

  test "another station's log cannot be previewed or confirmed", scope do
    other_station =
      stop_fixture(scope.organization.id, scope.version.id,
        stop_id: "OTHER_STATION",
        location_type: 1
      )

    other_child =
      child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id,
        stop_id: "OTHER_CHILD"
      )

    other_audit = %{scope.audit | station_stop_id: other_station.stop_id}

    assert {:ok, _edited} =
             Stations.update_child_stop(
               other_audit,
               other_child.id,
               %{stop_name: "Other edit"},
               other_child.lock_version
             )

    [log] = logs(scope, "stop", other_child.id)
    view = mount_diagram(scope)
    log_count = Repo.aggregate(ChangeLog, :count)

    render_hook(view, "preview_rollback_change_log", %{"log-id" => log.id})
    assert has_element?(view, "#flash-error", "entity no longer exists")
    refute has_element?(view, "#rollback-preview-stop")

    render_hook(view, "confirm_rollback_change_log", %{"log-id" => log.id})
    assert has_element?(view, "#flash-error", "entity no longer exists")
    assert Repo.get!(Stop, other_child.id).stop_name == "Other edit"
    assert Repo.aggregate(ChangeLog, :count) == log_count
  end

  test "ordinary preview restores a stop ID from a historical pair through Stations", scope do
    other = child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id)

    pathway =
      pathway_fixture(
        scope.organization.id,
        scope.version.id,
        scope.child.stop_id,
        other.stop_id
      )

    assert {:ok, renamed} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_id: "RENAMED_CHILD"},
               scope.child.lock_version
             )

    [source_log] = logs(scope, "stop", scope.child.id)

    log =
      source_log
      |> Ecto.Changeset.change(%{
        station_stop_id: "HISTORICAL_STATION_ID",
        changed_fields:
          Map.put(source_log.changed_fields, "stop_id", ["ORIGINAL_CHILD", "RENAMED_CHILD"])
      })
      |> Repo.update!()

    assert {:ok, scoped} = Stations.rollback_preview(scope.audit, log.id)
    assert scoped.expected_revision == renamed.lock_version
    assert scoped.current["stop_id"] == "RENAMED_CHILD"
    assert scoped.target["stop_id"] == "ORIGINAL_CHILD"

    view = mount_diagram(scope)
    open_history(view, "stop", scope.child.id)
    render_hook(view, "preview_rollback_change_log", %{"log-id" => log.id})

    assert has_element?(view, "#rollback-preview-stop")
    assert has_element?(view, "#rollback-preview-diff-stop", "RENAMED_CHILD")
    assert has_element?(view, "#rollback-preview-diff-stop", "ORIGINAL_CHILD")

    render_hook(view, "confirm_rollback_change_log", %{"log-id" => log.id})

    assert Repo.get!(Stop, scope.child.id).stop_id == "ORIGINAL_CHILD"
    assert Repo.get!(Pathway, pathway.id).from_stop_id == "ORIGINAL_CHILD"
    assert [%{action: "rolled_back"} | _] = logs(scope, "stop", scope.child.id)
  end

  test "ordinary preview reads a map-form historical stop ID pair", scope do
    assert {:ok, renamed} =
             Stations.update_child_stop(
               scope.audit,
               scope.child.id,
               %{stop_id: "MAP_PAIR_CHILD"},
               scope.child.lock_version
             )

    [source_log] = logs(scope, "stop", scope.child.id)

    log =
      source_log
      |> Ecto.Changeset.change(%{
        snapshot: Map.delete(source_log.snapshot, "stop_id"),
        changed_fields:
          Map.put(source_log.changed_fields, "stop_id", %{
            "from" => "ORIGINAL_CHILD",
            "to" => "MAP_PAIR_CHILD"
          })
      })
      |> Repo.update!()

    view = mount_diagram(scope)
    open_history(view, "stop", scope.child.id)
    render_hook(view, "preview_rollback_change_log", %{"log-id" => log.id})

    preview = :sys.get_state(view.pid).socket.assigns.rollback_preview
    assert preview.expected_revision == renamed.lock_version

    assert %{current: "MAP_PAIR_CHILD", restored: "ORIGINAL_CHILD"} =
             Enum.find(preview.field_changes, &(&1.field == "stop_id"))

    assert has_element?(view, "#rollback-preview-confirm-stop")
  end

  test "stop-level history remains audit only", scope do
    level = level_fixture(scope.organization.id, scope.version.id)

    {:ok, stop_level} =
      insert_stop_level(%{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        stop_id: scope.station.stop_id,
        level_id: level.level_id
      })

    {:ok, _audit_log} =
      Audit.record_change_in_transaction(
        scope.audit,
        :stop_level,
        stop_level,
        "updated",
        %{
          floorplan_scale_mpp: Decimal.new("2")
        }
      )

    [log] = logs(scope, "stop_level", stop_level.id)
    assert {:error, :audit_only_entity} = Stations.rollback_preview(scope.audit, log.id)

    view = mount_diagram(scope)
    render_hook(view, "preview_rollback_change_log", %{"log-id" => log.id})
    refute has_element?(view, "#rollback-preview-confirm-stop_level")
    assert Repo.get!(Gtfs.StopLevel, stop_level.id).lock_version == stop_level.lock_version
  end

  defp mount_diagram(scope) do
    conn = log_in_user(scope.conn, scope.user, organization: scope.organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{scope.version.id}/stops/#{scope.station.stop_id}/diagram")

    view
  end

  # The History tab and its rollback preview render only inside the drawer of the
  # selected stop, so the helper selects the stop before opening the tab.
  defp open_history(view, "stop", id) do
    render_hook(view, "edit_child_stop", %{"id" => id})
    view |> element("#stop-tab-history") |> render_click()
    render_async(view, 5_000)
  end

  defp logs(scope, type, id) do
    Gtfs.list_change_logs_for_entity(scope.organization.id, scope.version.id, type, id)
  end
end
