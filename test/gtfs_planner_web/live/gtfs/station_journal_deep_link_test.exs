defmodule GtfsPlannerWeb.Gtfs.StationJournalDeepLinkTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
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

    gtfs_version = gtfs_version_fixture(organization.id)

    station_suffix = System.unique_integer([:positive])

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "DL_STATION_#{station_suffix}",
        stop_name: "Deep Link Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "dl_level_#{station_suffix}",
        level_name: "Deep Link Level",
        level_index: 0.0
      })

    {:ok, _stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    child_stop =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "dl_child_#{station_suffix}",
        stop_name: "Deep Link Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 30.0}
      })

    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(
        organization.id,
        gtfs_version.id,
        station.id,
        user.id
      )

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      child_stop: child_stop,
      scope: scope
    }
  end

  describe "journal=open deep link" do
    test "opens the journal panel with all entries and patches to bare diagram path", context do
      entry_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Deep link entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert has_element?(view, "#journal-entry-list")
      assert has_element?(view, "#journal-entries-#{entry_id}")

      assert_patch(view, base_path)
    end

    test "valid in-scope entry_id renders entry and pushes journal-focus event", context do
      entry_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Focusable entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open&entry_id=#{entry_id}", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert has_element?(view, "#journal-entries-#{entry_id}")

      expected_selector = "#journal-entries-#{entry_id}"
      assert_push_event(view, "journal-focus", %{selector: ^expected_selector})

      assert_patch(view, base_path)
    end

    test "malformed entry_id opens panel with all entries and shows not-found flash", context do
      entry_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Existing entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open&entry_id=not-a-uuid", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert has_element?(view, "#journal-entries-#{entry_id}")

      assert has_element?(
               view,
               "#flash-error",
               "Journal entry not found. It may have been removed. The journal is open with all current entries."
             )

      assert_patch(view, base_path)
    end

    test "deleted entry_id opens panel with all entries and shows not-found flash", context do
      entry_id = Ecto.UUID.generate()
      deleted_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Surviving entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        },
        %{
          id: deleted_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "To be deleted",
          captured_at: ~U[2026-07-19 10:00:00.000000Z]
        }
      ])

      entry = Repo.get!(GtfsPlanner.Gtfs.JournalEntry, deleted_id)
      Repo.delete!(entry)

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open&entry_id=#{deleted_id}", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert has_element?(view, "#journal-entries-#{entry_id}")
      refute has_element?(view, "#journal-entries-#{deleted_id}")

      assert has_element?(
               view,
               "#flash-error",
               "Journal entry not found. It may have been removed. The journal is open with all current entries."
             )

      assert_patch(view, base_path)
    end

    test "entry from another station is not focused and shows not-found flash", context do
      other_station =
        stop_fixture(context.organization.id, context.gtfs_version.id, %{
          stop_id: "DL_OTHER_STATION_#{System.unique_integer([:positive])}",
          stop_name: "Other Station",
          location_type: 1
        })

      {:ok, _other_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: context.organization.id,
          gtfs_version_id: context.gtfs_version.id,
          stop_id: other_station.id,
          level_id: context.level.id
        })

      other_child =
        stop_fixture(context.organization.id, context.gtfs_version.id, %{
          stop_id: "dl_other_child_#{System.unique_integer([:positive])}",
          stop_name: "Other Child",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: context.level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      {:ok, other_scope} =
        Gtfs.resolve_station_journal_scope(
          context.organization.id,
          context.gtfs_version.id,
          other_station.id,
          context.user.id
        )

      foreign_entry_id = Ecto.UUID.generate()

      sync_entries(other_scope, [
        %{
          id: foreign_entry_id,
          target_type: "node",
          target_id: other_child.id,
          body: "Foreign station entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      local_entry_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: local_entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Local entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open&entry_id=#{foreign_entry_id}", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert has_element?(view, "#journal-entries-#{local_entry_id}")
      refute has_element?(view, "#journal-entries-#{foreign_entry_id}")

      assert has_element?(
               view,
               "#flash-error",
               "Journal entry not found. It may have been removed. The journal is open with all current entries."
             )

      assert_patch(view, base_path)
    end

    test "entry from another version is not focused and shows not-found flash", context do
      other_version = gtfs_version_fixture(context.organization.id)

      other_station =
        stop_fixture(context.organization.id, other_version.id, %{
          stop_id: "DL_V2_STATION_#{System.unique_integer([:positive])}",
          stop_name: "Version 2 Station",
          location_type: 1
        })

      {:ok, _other_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: context.organization.id,
          gtfs_version_id: other_version.id,
          stop_id: other_station.id,
          level_id: context.level.id
        })

      other_child =
        stop_fixture(context.organization.id, other_version.id, %{
          stop_id: "dl_v2_child_#{System.unique_integer([:positive])}",
          stop_name: "V2 Child",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: context.level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      {:ok, other_scope} =
        Gtfs.resolve_station_journal_scope(
          context.organization.id,
          other_version.id,
          other_station.id,
          context.user.id
        )

      foreign_entry_id = Ecto.UUID.generate()

      sync_entries(other_scope, [
        %{
          id: foreign_entry_id,
          target_type: "node",
          target_id: other_child.id,
          body: "Other version entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open&entry_id=#{foreign_entry_id}", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      refute has_element?(view, "#journal-entries-#{foreign_entry_id}")

      assert has_element?(
               view,
               "#flash-error",
               "Journal entry not found. It may have been removed. The journal is open with all current entries."
             )

      assert_patch(view, base_path)
    end

    test "entry from another organization is not focused and shows not-found flash", context do
      other_org = organization_fixture()

      other_user = user_fixture()

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: other_user.id,
          organization_id: other_org.id,
          roles: ["pathways_studio_editor"]
        })

      other_version = gtfs_version_fixture(other_org.id)

      other_station =
        stop_fixture(other_org.id, other_version.id, %{
          stop_id: "DL_ORG2_STATION_#{System.unique_integer([:positive])}",
          stop_name: "Org 2 Station",
          location_type: 1
        })

      other_level =
        level_fixture(other_org.id, other_version.id, %{
          level_id: "dl_org2_level_#{System.unique_integer([:positive])}",
          level_name: "Org 2 Level",
          level_index: 0.0
        })

      {:ok, _other_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: other_org.id,
          gtfs_version_id: other_version.id,
          stop_id: other_station.id,
          level_id: other_level.id
        })

      other_child =
        stop_fixture(other_org.id, other_version.id, %{
          stop_id: "dl_org2_child_#{System.unique_integer([:positive])}",
          stop_name: "Org 2 Child",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: other_level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      {:ok, other_scope} =
        Gtfs.resolve_station_journal_scope(
          other_org.id,
          other_version.id,
          other_station.id,
          other_user.id
        )

      foreign_entry_id = Ecto.UUID.generate()

      sync_entries(other_scope, [
        %{
          id: foreign_entry_id,
          target_type: "node",
          target_id: other_child.id,
          body: "Other org entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open&entry_id=#{foreign_entry_id}", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      refute has_element?(view, "#journal-entries-#{foreign_entry_id}")

      assert has_element?(
               view,
               "#flash-error",
               "Journal entry not found. It may have been removed. The journal is open with all current entries."
             )

      assert_patch(view, base_path)
    end

    test "same-station replay after patch does not re-open the journal panel", context do
      entry_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Replay entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?journal=open", on_error: :warn)

      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert_patch(view, base_path)

      render_hook(view, "close_journal", %{})

      refute has_element?(view, "#station-journal-panel")

      {:ok, view2, _html} =
        live(conn, base_path, on_error: :warn)

      render_async(view2, 5_000)

      refute has_element?(view2, "#station-journal-panel")
    end

    test "same-station live patch opens, consumes, and does not replay journal intent", context do
      entry_id = Ecto.UUID.generate()
      closed_entry_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Same-station patch entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        },
        %{
          id: closed_entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Closed same-station patch entry",
          captured_at: ~U[2026-07-19 10:00:00.000000Z]
        }
      ])

      assert {:ok, _entry} = Gtfs.close_journal_entry(context.scope, closed_entry_id)

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} = live(conn, base_path, on_error: :warn)
      render_async(view, 5_000)
      refute has_element?(view, "#station-journal-panel")

      render_patch(view, "#{base_path}?journal=open&entry_id=#{entry_id}")
      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert has_element?(view, "#journal-entries-#{entry_id}")
      assert has_element?(view, "#journal-entries-#{closed_entry_id}", "Closed")

      expected_selector = "#journal-entries-#{entry_id}"
      assert_push_event(view, "journal-focus", %{selector: ^expected_selector})
      assert_patch(view, base_path)

      render_hook(view, "close_journal", %{})
      refute has_element?(view, "#station-journal-panel")

      render_patch(view, base_path)
      refute has_element?(view, "#station-journal-panel")
    end

    test "simultaneous edit_child_stop_id and journal=open opens only child-stop drawer",
         context do
      entry_id = Ecto.UUID.generate()

      sync_entries(context.scope, [
        %{
          id: entry_id,
          target_type: "node",
          target_id: context.child_stop.id,
          body: "Precedence entry",
          captured_at: ~U[2026-07-20 10:00:00.000000Z]
        }
      ])

      conn = log_in_user(context.conn, context.user, organization: context.organization)
      base_path = "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram"

      {:ok, view, _html} =
        live(
          conn,
          "#{base_path}?edit_child_stop_id=#{context.child_stop.id}&journal=open",
          on_error: :warn
        )

      render_async(view, 5_000)

      html = render(view)
      assert html =~ "Deep Link Child"

      refute has_element?(view, "#station-journal-panel")

      assert_patch(view, base_path)
    end
  end

  defp sync_entries(scope, entries) do
    assert %{synced_count: synced_count, errors: []} = Gtfs.sync_journal_entries(scope, entries)
    assert synced_count == length(entries)
  end
end
