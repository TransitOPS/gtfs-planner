defmodule GtfsPlannerWeb.Gtfs.StationJournalPanelTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.JournalPhoto
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

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "JOURNAL_PANEL_STATION",
        stop_name: "Journal Panel Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "journal_panel_level",
        level_name: "Journal Panel Level",
        level_index: 0.0
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
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
      stop_level: stop_level,
      scope: scope
    }
  end

  test "production toolbar and workspace compose the journal as a left push panel", context do
    view = open_diagram(context)
    render_async(view, 5_000)

    assert has_element?(
             view,
             "#diagram-page[style*='--diagram-journal-open'][phx-hook='JournalPanelHook']:not([phx-update='ignore'])"
           )

    assert has_element?(view, "#diagram-action-strip #scale-control + #journal-trigger")
    assert has_element?(view, "#journal-trigger[aria-expanded='false']")
    refute has_element?(view, "#station-journal-panel")

    view
    |> element("#journal-trigger")
    |> render_click()

    render_async(view, 5_000)

    assert has_element?(view, "#journal-trigger[aria-expanded='true']")

    assert has_element?(
             view,
             "#station-journal-panel[phx-mounted][phx-remove][phx-window-keydown='close_journal'][phx-key='escape']:not([phx-update='ignore'])"
           )

    assert has_element?(
             view,
             "#diagram-workspace > #station-journal-panel + #diagram-canvas-wrapper.min-w-0.flex-1"
           )

    assert has_element?(
             view,
             "#station-journal-panel[class~='w-[340px]'][class~='min-w-[340px]'][class~='max-w-[340px]']"
           )

    assert has_element?(view, "#journal-empty-first-use")
    refute has_element?(view, "#journal-filter")
    refute has_element?(view, "[data-journal-scrim]")

    render_hook(view, "switch_mode", %{"mode" => "add"})
    assert has_element?(view, "#journal-trigger")

    render_hook(view, "switch_mode", %{"mode" => "connect"})
    assert has_element?(view, "#journal-trigger")

    render_hook(view, "switch_mode", %{"mode" => "map"})
    refute has_element?(view, "#journal-trigger")
    refute has_element?(view, "#station-journal-panel")
    assert_push_event(view, "journal-focus", %{selector: "#diagram-mode-option-map"})
  end

  test "journal motion CSS consumes the canonical palette and covers non-ideal states" do
    css = File.read!("assets/css/app.css")

    assert css =~ "#station-journal-panel"
    assert css =~ "#journal-entry-list"
    assert css =~ ".journal-panel-motion"
    assert css =~ ".journal-loading-delay"
    assert css =~ ".journal-entry-motion"
    assert css =~ "var(--diagram-journal-open)"
    assert css =~ "@media (prefers-reduced-motion: reduce)"
    refute Regex.match?(~r/--diagram-journal-open\s*:/, css)
  end

  test "opening the panel streams every entry, closed included, from the server-owned stream",
       context do
    open_id = Ecto.UUID.generate()
    closed_id = Ecto.UUID.generate()

    sync_entries(context.scope, [
      entry_attrs(open_id, ~U[2026-07-18 12:00:00.000000Z]),
      entry_attrs(closed_id, ~U[2026-07-18 12:10:00.000000Z])
    ])

    assert {:ok, _closed} = Gtfs.close_journal_entry(context.scope, closed_id)

    view = open_diagram(context)
    render_async(view, 5_000)
    refute has_element?(view, "#station-journal-panel")

    render_hook(view, "open_journal", %{})
    render_async(view, 5_000)

    opened = assigns(view)
    assert opened.journal_panel_open?
    assert opened.journal_filter == :all
    assert opened.journal_open_count == 1
    assert opened.journal_closed_count == 1
    assert opened.journal_visible_count == 2
    assert opened.journal_rendered_entry_ids == MapSet.new([open_id, closed_id])
    assert opened.journal_pending_new_ids == MapSet.new()

    assert has_element?(view, "#journal-entries-#{open_id} [data-role='journal-note']")
    assert has_element?(view, "#journal-entries-#{closed_id} [data-role='journal-note']")
  end

  test "the photo viewer opens in-app, absorbs Escape, and returns focus", context do
    entry_id = Ecto.UUID.generate()
    photo_id = Ecto.UUID.generate()

    sync_entries(context.scope, [entry_attrs(entry_id, ~U[2026-07-18 12:00:00.000000Z])])

    Repo.insert!(%JournalPhoto{
      id: photo_id,
      journal_entry_id: entry_id,
      filename: "journal-photo.jpg",
      content_type: "image/jpeg",
      byte_size: 10,
      sha256: :crypto.hash(:sha256, "journal-photo"),
      captured_at: ~U[2026-07-18 12:01:00.000000Z]
    })

    view = open_loaded_journal(context)

    render_hook(view, "open_journal_photo", %{"photo_id" => photo_id, "entry_id" => entry_id})

    viewer = assigns(view).journal_photo_viewer
    assert viewer.photo_id == photo_id
    assert viewer.entry_id == entry_id
    assert viewer.index == 1
    assert viewer.count == 1
    assert viewer.src =~ "journal-photo.jpg"
    assert has_element?(view, "#journal-photo-viewer[role='dialog']")
    assert_push_event(view, "journal-focus", %{selector: "#journal-photo-viewer-close"})

    render_hook(view, "close_journal", %{})

    after_escape = assigns(view)
    assert after_escape.journal_photo_viewer == nil
    assert after_escape.journal_panel_open?
    photo_selector = "#journal-photo-#{photo_id}"
    assert_push_event(view, "journal-focus", %{selector: ^photo_selector})

    render_hook(view, "close_journal", %{})
    refute assigns(view).journal_panel_open?
  end

  test "an unknown photo fails soft without opening the viewer", context do
    entry_id = Ecto.UUID.generate()
    sync_entries(context.scope, [entry_attrs(entry_id, ~U[2026-07-18 12:00:00.000000Z])])

    view = open_loaded_journal(context)

    render_hook(view, "open_journal_photo", %{
      "photo_id" => Ecto.UUID.generate(),
      "entry_id" => entry_id
    })

    failed = assigns(view)
    assert failed.journal_photo_viewer == nil
    assert failed.journal_error_message == "The journal entry could not be changed."
  end

  test "editing from a journal entry carries the note into the drawer", context do
    entry_id = Ecto.UUID.generate()

    node =
      stop_fixture(context.organization.id, context.gtfs_version.id, %{
        stop_id: "JOURNAL_CONTEXT_NODE",
        stop_name: "Journal Context Node",
        location_type: 3,
        parent_station: context.station.stop_id,
        level_id: context.level.level_id,
        diagram_coordinate: %{"x" => 12.0, "y" => 24.0}
      })

    sync_entries(context.scope, [
      %{
        id: entry_id,
        target_type: "node",
        target_id: node.id,
        body: "Confirm signage before export.",
        captured_at: ~U[2026-07-18 12:00:00.000000Z]
      }
    ])

    view = open_loaded_journal(context)

    render_hook(view, "edit_child_stop", %{"id" => node.id, "journal_entry_id" => entry_id})

    after_edit = assigns(view)
    refute after_edit.journal_panel_open?
    assert after_edit.journal_form_context.entry_id == entry_id
    assert after_edit.journal_form_context.body == "Confirm signage before export."
    assert has_element?(view, "#journal-form-context")
    assert render(view) =~ "Confirm signage before export."

    render_hook(view, "close_drawer", %{})
    assert assigns(view).journal_form_context == nil
    refute has_element?(view, "#journal-form-context")

    render_hook(view, "edit_child_stop", %{"id" => node.id})
    assert assigns(view).journal_form_context == nil
    refute has_element?(view, "#journal-form-context")
  end

  test "closed entries render like open entries with no filter or completion controls",
       context do
    open_id = Ecto.UUID.generate()
    closed_id = Ecto.UUID.generate()

    sync_entries(context.scope, [
      entry_attrs(open_id, ~U[2026-07-18 12:00:00.000000Z]),
      entry_attrs(closed_id, ~U[2026-07-18 12:10:00.000000Z])
    ])

    assert {:ok, _closed} = Gtfs.close_journal_entry(context.scope, closed_id)

    view = open_loaded_journal(context)

    assert has_element?(view, "#journal-trigger-count", "2")
    assert has_element?(view, "#journal-count-summary", "2 entries")
    assert has_element?(view, "#journal-entries-#{open_id}[data-role='journal-entry']")
    assert has_element?(view, "#journal-entries-#{closed_id}[data-role='journal-entry']")

    refute has_element?(view, "#journal-filter")
    refute has_element?(view, "[data-entry-state]")
    refute has_element?(view, "#journal-close-entry-#{open_id}")
    refute has_element?(view, "#journal-reopen-entry-#{closed_id}")
    refute has_element?(view, "#journal-undo-entry-#{closed_id}")
    refute has_element?(view, "#journal-entries-#{closed_id}.opacity-70")
    refute render(view) =~ "Closed ·"
  end

  test "the panel shows only this station's entries on open and refresh", context do
    entry_id = Ecto.UUID.generate()
    sync_entries(context.scope, [entry_attrs(entry_id, ~U[2026-07-18 12:00:00.000000Z])])

    other_station =
      stop_fixture(context.organization.id, context.gtfs_version.id, %{
        stop_id: "JOURNAL_FOREIGN_STATION",
        stop_name: "Foreign Station",
        location_type: 1
      })

    {:ok, other_scope} =
      Gtfs.resolve_station_journal_scope(
        context.organization.id,
        context.gtfs_version.id,
        other_station.id,
        context.user.id
      )

    foreign_id = Ecto.UUID.generate()
    sync_entries(other_scope, [entry_attrs(foreign_id, ~U[2026-07-18 12:05:00.000000Z])])

    view = open_loaded_journal(context)

    opened = assigns(view)
    assert opened.journal_visible_count == 1
    assert opened.journal_rendered_entry_ids == MapSet.new([entry_id])
    assert has_element?(view, "#journal-entries-#{entry_id}")
    refute has_element?(view, "#journal-entries-#{foreign_id}")

    render_hook(view, "refresh_journal", %{})
    render_async(view, 5_000)

    refreshed = assigns(view)
    assert refreshed.journal_visible_count == 1
    assert refreshed.journal_rendered_entry_ids == MapSet.new([entry_id])
    refute has_element?(view, "#journal-entries-#{foreign_id}")
    assert [%{id: ^foreign_id, closed_at: nil}] = Gtfs.list_station_journal(other_scope)
  end

  test "Align restoration stays server-owned for a panel opened on the current page", context do
    entry_id = Ecto.UUID.generate()
    sync_entries(context.scope, [entry_attrs(entry_id, ~U[2026-07-18 12:00:00.000000Z])])

    view = open_loaded_journal(context)

    render_hook(view, "switch_mode", %{"mode" => "map"})

    aligned = assigns(view)
    assert aligned.mode == :map
    refute aligned.journal_panel_open?
    assert aligned.journal_restore_after_align?
    assert_push_event(view, "journal-focus", %{selector: "#diagram-mode-option-map"})

    render_hook(view, "switch_mode", %{"mode" => "view"})
    render_async(view, 5_000)

    restored = assigns(view)
    assert restored.mode == :view
    assert restored.journal_panel_open?
    refute restored.journal_restore_after_align?
    assert_push_event(view, "journal-focus", %{selector: "#diagram-mode-option-view"})
  end

  test "scoped node and pathway edit events close the panel before opening existing drawers",
       context do
    node =
      stop_fixture(context.organization.id, context.gtfs_version.id, %{
        stop_id: "JOURNAL_EDIT_NODE",
        stop_name: "Journal edit node",
        location_type: 0,
        parent_station: context.station.stop_id,
        level_id: context.level.level_id,
        diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
      })

    other_node =
      stop_fixture(context.organization.id, context.gtfs_version.id, %{
        stop_id: "JOURNAL_EDIT_NODE_2",
        stop_name: "Journal edit node 2",
        location_type: 0,
        parent_station: context.station.stop_id,
        level_id: context.level.level_id,
        diagram_coordinate: %{"x" => 30.0, "y" => 40.0}
      })

    {:ok, pathway} =
      Gtfs.create_pathway(%{
        organization_id: context.organization.id,
        gtfs_version_id: context.gtfs_version.id,
        pathway_id: "JOURNAL_EDIT_PATHWAY",
        from_stop_id: node.stop_id,
        to_stop_id: other_node.stop_id,
        pathway_mode: 1,
        is_bidirectional: true
      })

    sync_entries(context.scope, [
      Map.put(
        entry_attrs(Ecto.UUID.generate(), ~U[2026-07-18 12:00:00.000000Z]),
        :target_type,
        "node"
      )
      |> Map.put(:target_id, node.id),
      Map.put(
        entry_attrs(Ecto.UUID.generate(), ~U[2026-07-18 12:01:00.000000Z]),
        :target_type,
        "pathway"
      )
      |> Map.put(:target_id, pathway.id)
    ])

    view = open_loaded_journal(context)

    render_hook(view, "edit_child_stop", %{"id" => node.id})

    node_drawer = assigns(view)
    refute node_drawer.journal_panel_open?
    assert node_drawer.selected_stop_id == node.id
    assert node_drawer.active_point_id == node.id

    render_hook(view, "open_journal", %{})
    render_async(view, 5_000)
    assert assigns(view).journal_panel_open?

    render_hook(view, "edit_pathway", %{"id" => pathway.id})

    pathway_drawer = assigns(view)
    refute pathway_drawer.journal_panel_open?
    assert pathway_drawer.show_pathway_drawer
    assert pathway_drawer.editing_pathway.id == pathway.id
  end

  defp open_loaded_journal(context) do
    view = open_diagram(context)
    render_async(view, 5_000)
    render_hook(view, "open_journal", %{})
    render_async(view, 5_000)
    view
  end

  defp open_diagram(context) do
    conn = log_in_user(context.conn, context.user, organization: context.organization)

    {:ok, view, _html} =
      live(
        conn,
        "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}/diagram",
        on_error: :warn
      )

    view
  end

  defp sync_entries(scope, entries) do
    assert %{synced_count: synced_count, errors: []} = Gtfs.sync_journal_entries(scope, entries)
    assert synced_count == length(entries)
  end

  defp entry_attrs(id, captured_at) do
    %{
      id: id,
      target_type: "station",
      body: "Journal entry #{id}",
      captured_at: captured_at
    }
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
