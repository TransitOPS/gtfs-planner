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
  alias GtfsPlannerWeb.Gtfs.StationDiagramLive

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

  test "open, filter, and expansion keep the server-owned stream authoritative", context do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    sync_entries(context.scope, [
      entry_attrs(first_id, ~U[2026-07-18 12:00:00.000000Z]),
      entry_attrs(second_id, ~U[2026-07-18 12:10:00.000000Z])
    ])

    view = open_diagram(context)
    render_async(view, 5_000)

    render_hook(view, "open_journal", %{})
    render_async(view, 5_000)

    opened = assigns(view)
    assert opened.journal_panel_open?
    assert opened.journal_filter == :open
    assert opened.journal_visible_count == 2
    assert opened.journal_rendered_entry_ids == MapSet.new([first_id, second_id])
    assert_push_event(view, "journal-panel-preference", %{open: true})

    socket = :sys.get_state(view.pid).socket

    assert {:noreply, expanded_socket} =
             StationDiagramLive.handle_event(
               "select_journal_entry",
               %{"id" => first_id},
               socket
             )

    assert expanded_socket.assigns.journal_expanded_id == first_id
    refute expanded_socket.assigns.streams.journal_entries.reset?

    assert [{"journal-entries-" <> ^first_id, -1, first_entry, nil, false}] =
             expanded_socket.assigns.streams.journal_entries.inserts

    assert Ecto.assoc_loaded?(first_entry.photos)

    assert {:noreply, switched_socket} =
             StationDiagramLive.handle_event(
               "select_journal_entry",
               %{"id" => second_id},
               expanded_socket
             )

    assert switched_socket.assigns.journal_expanded_id == second_id
    refute switched_socket.assigns.streams.journal_entries.reset?

    assert MapSet.new(
             Enum.map(switched_socket.assigns.streams.journal_entries.inserts, fn {
                                                                                    dom_id,
                                                                                    -1,
                                                                                    entry,
                                                                                    nil,
                                                                                    false
                                                                                  } ->
               assert Ecto.assoc_loaded?(entry.photos)
               dom_id
             end)
           ) ==
             MapSet.new(["journal-entries-#{first_id}", "journal-entries-#{second_id}"])

    render_hook(view, "set_journal_filter", %{"journal_filter" => "all"})
    render_async(view, 5_000)

    filtered = assigns(view)
    assert filtered.journal_filter == :all
    assert filtered.journal_expanded_id == nil
    assert filtered.journal_undo_ids == MapSet.new()
    assert filtered.journal_pending_new_ids == MapSet.new()
  end

  test "close, Undo, and reopen refetch the photo-preloaded row and update counts once",
       context do
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

    render_hook(view, "close_journal_entry", %{"id" => entry_id})
    settle_journal(view)

    closed = assigns(view)
    assert closed.journal_open_count == 0
    assert closed.journal_closed_count == 1
    assert closed.journal_visible_count == 1
    assert closed.journal_undo_ids == MapSet.new([entry_id])
    assert closed.journal_rendered_signature == closed.journal_observed_signature
    assert signature_photo_ids(closed, entry_id) == [photo_id]
    assert %NaiveDateTime{} = closed.journal_local_times[{entry_id, :closed}]
    undo_selector = "#journal-undo-entry-#{entry_id}"
    assert_push_event(view, "journal-focus", %{selector: ^undo_selector})

    [closed_entry] = Gtfs.list_station_journal(context.scope, status: :all, order: :desc)
    assert closed_entry.id == entry_id
    assert Ecto.assoc_loaded?(closed_entry.photos)
    assert Enum.map(closed_entry.photos, & &1.id) == [photo_id]

    render_hook(view, "undo_journal_close", %{"id" => entry_id})
    settle_journal(view)

    reopened_by_undo = assigns(view)
    assert reopened_by_undo.journal_open_count == 1
    assert reopened_by_undo.journal_closed_count == 0
    assert reopened_by_undo.journal_undo_ids == MapSet.new()
    assert signature_photo_ids(reopened_by_undo, entry_id) == [photo_id]
    close_selector = "#journal-close-entry-#{entry_id}"
    assert_push_event(view, "journal-focus", %{selector: ^close_selector})

    render_hook(view, "close_journal_entry", %{"id" => entry_id})
    settle_journal(view)
    assert assigns(view).journal_undo_ids == MapSet.new([entry_id])

    render_hook(view, "refresh_journal", %{})
    render_async(view, 5_000)
    assert assigns(view).journal_undo_ids == MapSet.new()
    assert assigns(view).journal_visible_count == 0

    render_hook(view, "set_journal_filter", %{"journal_filter" => "all"})
    render_async(view, 5_000)
    assert assigns(view).journal_undo_ids == MapSet.new()

    render_hook(view, "reopen_journal_entry", %{"id" => entry_id})
    settle_journal(view)

    reopened = assigns(view)
    assert reopened.journal_open_count == 1
    assert reopened.journal_closed_count == 0
    assert reopened.journal_visible_count == 1
    assert reopened.journal_rendered_signature == reopened.journal_observed_signature
    assert signature_photo_ids(reopened, entry_id) == [photo_id]
    assert_push_event(view, "journal-focus", %{selector: ^close_selector})
  end

  test "missing and foreign mutation IDs preserve the row snapshot and tenant data", context do
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
    before = assigns(view)

    render_hook(view, "close_journal_entry", %{"id" => Ecto.UUID.generate()})
    missing = assigns(view)
    assert_journal_snapshot_preserved(before, missing)
    assert missing.journal_error_message == "The journal entry could not be changed."
    assert missing.journal_live_message == "The journal entry was not changed. Try again."

    render_hook(view, "close_journal_entry", %{"id" => foreign_id})
    foreign = assigns(view)
    assert_journal_snapshot_preserved(before, foreign)
    assert [%{id: ^foreign_id, closed_at: nil}] = Gtfs.list_station_journal(other_scope)
  end

  test "Align restoration and browser preference restore stay server-owned", context do
    entry_id = Ecto.UUID.generate()
    sync_entries(context.scope, [entry_attrs(entry_id, ~U[2026-07-18 12:00:00.000000Z])])

    view = open_loaded_journal(context)
    assert_push_event(view, "journal-panel-preference", %{open: true})

    render_hook(view, "switch_mode", %{"mode" => "map"})

    aligned = assigns(view)
    assert aligned.mode == :map
    refute aligned.journal_panel_open?
    assert aligned.journal_restore_after_align?
    refute_push_event(view, "journal-panel-preference", %{open: false})

    render_hook(view, "restore_journal_panel", %{"open" => true})
    refute assigns(view).journal_panel_open?

    render_hook(view, "switch_mode", %{"mode" => "view"})
    render_async(view, 5_000)

    restored = assigns(view)
    assert restored.mode == :view
    assert restored.journal_panel_open?
    refute restored.journal_restore_after_align?
    refute_push_event(view, "journal-panel-preference", %{open: true})

    render_hook(view, "restore_journal_panel", %{"open" => false})
    refute assigns(view).journal_panel_open?

    render_hook(view, "restore_journal_panel", %{"open" => true})
    render_async(view, 5_000)
    assert assigns(view).journal_panel_open?
    refute_push_event(view, "journal-panel-preference", %{open: true})
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

  defp signature_photo_ids(assigns, entry_id) do
    {_id, _updated_at, _closed_at, photo_ids} =
      Enum.find(assigns.journal_rendered_signature, &(elem(&1, 0) == entry_id))

    photo_ids
  end

  defp settle_journal(view) do
    _ = :sys.get_state(view.pid)
    render_async(view, 5_000)
    _ = :sys.get_state(view.pid)
  end

  defp assert_journal_snapshot_preserved(before, after_failure) do
    assert after_failure.journal_open_count == before.journal_open_count
    assert after_failure.journal_closed_count == before.journal_closed_count
    assert after_failure.journal_visible_count == before.journal_visible_count
    assert after_failure.journal_rendered_entry_ids == before.journal_rendered_entry_ids
    assert after_failure.journal_rendered_signature == before.journal_rendered_signature
    assert after_failure.journal_observed_signature == before.journal_observed_signature
    assert after_failure.journal_expanded_id == before.journal_expanded_id
    assert after_failure.journal_undo_ids == before.journal_undo_ids
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
