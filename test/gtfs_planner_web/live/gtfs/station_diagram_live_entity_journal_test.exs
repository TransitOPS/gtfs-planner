defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveEntityJournalTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Repo

  @controlled_source GtfsPlannerWeb.Gtfs.ControlledJournalSource

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
        stop_id: "EJ_STATION_#{station_suffix}",
        stop_name: "Entity J Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "ej_level_#{station_suffix}",
        level_name: "Entity J Level",
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
        stop_id: "ej_child_#{station_suffix}",
        stop_name: "Child Stop",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 30.0}
      })

    second_child =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "ej_second_#{station_suffix}",
        stop_name: "Second Stop",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 60.0, "y" => 40.0}
      })

    pathway =
      pathway_fixture(organization.id, gtfs_version.id, child_stop.stop_id, second_child.stop_id)

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
      second_child: second_child,
      pathway: pathway,
      scope: scope
    }
  end

  # ============================================================================
  # Show event matching server-owned stop starts target-scoped load
  # ============================================================================

  test "show_drawer_journal for stop starts initial target-scoped load and publishes rows/count/metadata",
       context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry about child stop",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)
    assert assigns(view).journal_state == :ready

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    # Capture the request identity before releasing
    loading = assigns(view)
    assert loading.drawer_journal_state == :initial_loading
    assert loading.drawer_journal_request.entity_type == :stop
    assert loading.drawer_journal_request.entity_id == context.child_stop.id
    assert loading.drawer_journal_request.target == {"node", context.child_stop.id}

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    ready = assigns(view)
    assert ready.drawer_journal_state == :ready
    assert ready.drawer_journal_loaded_once?
    refute ready.drawer_journal_refresh_error?
    assert ready.drawer_journal_total_count == 1
    # Request identity is preserved on success for PubSub refresh
    assert ready.drawer_journal_request.entity_type == :stop
    assert ready.drawer_journal_request.target == {"node", context.child_stop.id}
  end

  # ============================================================================
  # Show event for pathway starts target-scoped load
  # ============================================================================

  test "show_drawer_journal for pathway starts target-scoped load with pathway target", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "pathway",
                 target_id: context.pathway.id,
                 body: "Pathway entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_pathway", %{"id" => context.pathway.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "pathway",
      "entity_id" => context.pathway.id
    })

    loading = assigns(view)
    assert loading.drawer_journal_state == :initial_loading
    assert loading.drawer_journal_request.entity_type == :pathway
    assert loading.drawer_journal_request.target == {"pathway", context.pathway.id}

    drawer_task =
      await_drawer_journal_request(context.station.id, {"pathway", context.pathway.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    ready = assigns(view)
    assert ready.drawer_journal_state == :ready
    assert ready.drawer_journal_total_count == 1
  end

  # ============================================================================
  # Only complete current request accepted for result mutation
  # ============================================================================

  test "PubSub superseded generation is rejected without mutating state", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    first_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(first_task, :real)
    render_async(view, 5_000)

    first = assigns(view)
    assert first.drawer_journal_state == :ready
    first_gen = first.drawer_journal_request.generation
    assert first.drawer_journal_total_count == 1

    # Now trigger PubSub — should start a refresh with higher generation
    send(view.pid, {:station_journal_changed, context.station.id})

    panel_task = await_station_journal_request(context.station.id)
    release_journal(panel_task, :real)

    refresh_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    during = assigns(view)
    assert during.drawer_journal_state == :refreshing
    assert during.drawer_journal_request.generation > first_gen
    assert during.drawer_journal_total_count == 1

    # Release the refresh task
    release_journal(refresh_task, :real)
    render_async(view, 5_000)

    current = assigns(view)
    assert current.drawer_journal_state == :ready
    assert current.drawer_journal_total_count == 1
  end

  # ============================================================================
  # Forged IDs rejected
  # ============================================================================

  test "show_drawer_journal with forged stop id is rejected when drawer does not match",
       context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry about child stop",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.second_child.id
    })

    status = assigns(view)
    assert status.drawer_journal_state == :idle
    assert is_nil(status.drawer_journal_request)
  end

  # ============================================================================
  # Foreign entity rejected (doesn't belong to station)
  # ============================================================================

  test "show_drawer_journal for non-station entity is rejected", context do
    foreign_stop =
      stop_fixture(context.organization.id, context.gtfs_version.id, %{
        stop_id: "ej_foreign_#{System.unique_integer([:positive])}",
        stop_name: "Foreign Stop",
        location_type: 0,
        parent_station: "OTHER_STATION",
        level_id: context.level.level_id,
        diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
      })

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => foreign_stop.id
    })

    status = assigns(view)
    assert status.drawer_journal_state == :idle
  end

  # ============================================================================
  # Cancelled tasks leave state unchanged
  # ============================================================================

  test "cancelled drawer journal task leaves state unchanged", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    _drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    # Cancel by closing the drawer before releasing
    render_hook(view, "close_drawer", %{})
    _ = :sys.get_state(view.pid)

    state = assigns(view)
    assert state.drawer_journal_state == :idle
    assert is_nil(state.drawer_journal_request)
    assert state.drawer_journal_total_count == 0
  end

  # ============================================================================
  # Foreign/inactive PubSub notifications inert
  # ============================================================================

  test "foreign station journal changed notification does not start drawer load", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready

    # Send a foreign-station PubSub notification (random UUID)
    send(view.pid, {:station_journal_changed, Ecto.UUID.generate()})

    refute_receive {:journal_requested, _, _, %{target: _}}, 500
    _ = :sys.get_state(view.pid)
    assert assigns(view).drawer_journal_state == :ready
  end

  # ============================================================================
  # Inactive tab PubSub notification does not refresh drawer
  # ============================================================================

  test "matching PubSub notification does not refresh when Journal tab is not active", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})
    # Drawer is open but Journal tab is NOT active

    send(view.pid, {:station_journal_changed, context.station.id})

    # Station panel will refresh
    panel_task = await_station_journal_request(context.station.id)
    release_journal(panel_task, :real)
    render_async(view, 5_000)

    state = assigns(view)
    assert state.drawer_journal_state == :idle
  end

  # ============================================================================
  # Matching active PubSub refreshes with retained rows during load
  # ============================================================================

  test "matching active PubSub refreshes drawer with retained rows", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    first = assigns(view)
    assert first.drawer_journal_state == :ready
    assert first.drawer_journal_total_count == 1

    # Now send matching PubSub — should trigger refresh while retaining rows
    send(view.pid, {:station_journal_changed, context.station.id})

    # Station panel also refreshes
    panel_task = await_station_journal_request(context.station.id)
    release_journal(panel_task, :real)

    refresh_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    during = assigns(view)
    assert during.drawer_journal_state == :refreshing
    assert during.drawer_journal_total_count == 1

    release_journal(refresh_task, :real)
    render_async(view, 5_000)

    after_refresh = assigns(view)
    assert after_refresh.drawer_journal_state == :ready
    assert after_refresh.drawer_journal_total_count == 1
  end

  # ============================================================================
  # External deletion removal on accepted reset
  # ============================================================================

  test "external entry deletion removes row from drawer on PubSub refresh", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    first = assigns(view)
    assert first.drawer_journal_total_count == 1

    # Delete the entry directly from the database
    {deleted, _} =
      Repo.delete_all(from(e in GtfsPlanner.Gtfs.JournalEntry, where: e.id == ^entry_id))

    assert deleted == 1

    # Trigger a PubSub refresh
    send(view.pid, {:station_journal_changed, context.station.id})

    panel_task = await_station_journal_request(context.station.id)
    release_journal(panel_task, :real)

    refresh_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(refresh_task, :real)
    render_async(view, 5_000)

    after_delete = assigns(view)
    assert after_delete.drawer_journal_total_count == 0
    assert after_delete.drawer_journal_state == :ready
  end

  # ============================================================================
  # First-load failure shows only initial error contract
  # ============================================================================

  test "first-load drawer journal failure shows error state with retry", context do
    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, {:raise, "drawer journal read failed"})
    render_async(view, 5_000)

    failed = assigns(view)
    assert failed.drawer_journal_state == :error
    refute failed.drawer_journal_loaded_once?
    assert failed.drawer_journal_total_count == 0
    assert is_binary(failed.drawer_journal_error_message)
    # Request identity preserved so retry can work
    assert failed.drawer_journal_request.entity_type == :stop
    assert failed.drawer_journal_request.target == {"node", context.child_stop.id}

    # Retry should work
    render_hook(view, "retry_drawer_journal", %{})

    retry_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(retry_task, :real)
    render_async(view, 5_000)

    recovered = assigns(view)
    assert recovered.drawer_journal_state == :ready
    assert recovered.drawer_journal_loaded_once?
  end

  # ============================================================================
  # Refresh failure preserves stale rows/count with Retry
  # ============================================================================

  test "refresh failure preserves stale rows and count", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Preserved entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    first_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(first_task, :real)
    render_async(view, 5_000)

    successful = assigns(view)
    assert successful.drawer_journal_state == :ready
    assert successful.drawer_journal_total_count == 1

    # Trigger a PubSub refresh that will fail
    send(view.pid, {:station_journal_changed, context.station.id})

    panel_task = await_station_journal_request(context.station.id)
    release_journal(panel_task, :real)

    refresh_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(refresh_task, {:raise, "refresh journal read failed"})
    render_async(view, 5_000)

    stale = assigns(view)
    assert stale.drawer_journal_state == :error
    assert stale.drawer_journal_loaded_once?
    assert stale.drawer_journal_refresh_error?
    assert stale.drawer_journal_total_count == successful.drawer_journal_total_count
    # Request identity preserved for another retry
    assert stale.drawer_journal_request.entity_type == :stop
    assert stale.drawer_journal_request.target == {"node", context.child_stop.id}
  end

  # ============================================================================
  # show_details cancels and resets drawer journal
  # ============================================================================

  test "show_details cancels and resets drawer journal state", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready

    render_hook(view, "show_details", %{})

    state = assigns(view)
    assert state.drawer_journal_state == :idle
    assert is_nil(state.drawer_journal_request)
    assert state.drawer_journal_total_count == 0
  end

  # ============================================================================
  # show_history cancels and resets drawer journal before starting History
  # ============================================================================

  test "show_history cancels and resets drawer journal state", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready
    assert assigns(view).drawer_journal_total_count == 1

    render_hook(view, "show_history", %{
      "entity-type" => "stop",
      "entity-id" => context.child_stop.id
    })

    render_async(view, 5_000)

    state = assigns(view)
    assert state.drawer_journal_state == :idle
    assert is_nil(state.drawer_journal_request)
    assert state.drawer_journal_total_count == 0
    assert state.history_open_for == {"stop", context.child_stop.id}
  end

  # ============================================================================
  # Close drawer cancels and resets drawer journal
  # ============================================================================

  test "closing drawer cancels and resets drawer journal", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready

    render_hook(view, "close_drawer", %{})

    state = assigns(view)
    assert state.drawer_journal_state == :idle
    assert is_nil(state.drawer_journal_request)
    assert state.drawer_journal_total_count == 0
  end

  # ============================================================================
  # Pathway pair switch cancels and resets drawer journal
  # ============================================================================

  test "pathway pair switch cancels and resets drawer journal", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "pathway",
                 target_id: context.pathway.id,
                 body: "Pathway entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_pathway", %{"id" => context.pathway.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "pathway",
      "entity_id" => context.pathway.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"pathway", context.pathway.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready

    render_hook(view, "close_pathway_drawer", %{})

    state = assigns(view)
    assert state.drawer_journal_state == :idle
  end

  # ============================================================================
  # Station change resets drawer journal
  # ============================================================================

  test "station change cancels and resets drawer journal", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready

    other_station =
      stop_fixture(context.organization.id, context.gtfs_version.id, %{
        stop_id: "EJ_OTHER_#{System.unique_integer([:positive])}",
        stop_name: "Other Station",
        location_type: 1
      })

    {:ok, _} =
      Gtfs.create_stop_level(%{
        organization_id: context.organization.id,
        gtfs_version_id: context.gtfs_version.id,
        stop_id: other_station.id,
        level_id: context.level.id
      })

    render_patch(view, "/gtfs/#{context.gtfs_version.id}/stops/#{other_station.stop_id}/diagram")

    state = assigns(view)
    assert state.drawer_journal_state == :idle
    assert is_nil(state.drawer_journal_request)
    assert state.drawer_journal_total_count == 0
  end

  # ============================================================================
  # Entity save cancels and resets drawer journal
  # ============================================================================

  test "saving child stop cancels and resets drawer journal", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready

    params = %{
      "x" => "50.0",
      "y" => "30.0",
      "stop_id" => context.child_stop.stop_id,
      "stop_name" => "Updated Child Stop",
      "location_type" => "0",
      "level_id" => context.level.level_id,
      "wheelchair_boarding" => "0",
      "platform_code" => "",
      "stop_lat" => "",
      "stop_lon" => ""
    }

    render_hook(view, "save_child_stop", params)
    _ = :sys.get_state(view.pid)

    state = assigns(view)
    assert state.drawer_journal_state == :idle
    assert is_nil(state.drawer_journal_request)
    assert state.drawer_journal_total_count == 0
  end

  # ============================================================================
  # Test helpers
  # ============================================================================

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

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp control_journal_source do
    source_before = Application.fetch_env(:gtfs_planner, :station_journal_source)
    owner_before = Application.fetch_env(:gtfs_planner, :station_journal_source_owner)

    Application.put_env(:gtfs_planner, :station_journal_source, @controlled_source)
    Application.put_env(:gtfs_planner, :station_journal_source_owner, self())

    on_exit(fn ->
      restore_env(:station_journal_source, source_before)
      restore_env(:station_journal_source_owner, owner_before)
    end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)

  defp await_station_journal_request(station_id) do
    assert_receive {:journal_requested, task_pid, %Scope{station_id: ^station_id}, opts}, 5_000
    assert opts == [status: :all, order: :desc]
    task_pid
  end

  defp await_drawer_journal_request(station_id, {_target_type, _target_id} = target) do
    assert_receive {:journal_requested, task_pid, %Scope{station_id: ^station_id}, opts},
                   5_000

    assert Keyword.get(opts, :target) == target
    assert Keyword.get(opts, :status) == :all
    assert Keyword.get(opts, :order) == :desc
    task_pid
  end

  defp release_journal(task_pid, result), do: send(task_pid, {:journal_release, result})

  # ============================================================================
  # Rendered-LiveView: persisted stop drawer renders Journal tab
  # ============================================================================

  test "persisted stop drawer renders Journal tab and badge", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Entry about child stop",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    assert has_element?(view, "#stop-tab-details")
    assert has_element?(view, "#stop-tab-history")
    assert has_element?(view, "#stop-tab-journal")
    assert has_element?(view, "#stop-panel-journal")
    assert has_element?(view, "#stop-panel-details")
    assert has_element?(view, "#stop-panel-journal")
  end

  # ============================================================================
  # Rendered-LiveView: add/new stop drawer does NOT render Journal tab
  # ============================================================================

  test "add stop drawer does not render Journal tab", context do
    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    # Simulate add mode with a pending click but no selected_stop_id
    render_hook(view, "canvas_click", %{"x" => "25.0", "y" => "35.0"})

    # Details panel is present but no tabs since selected_stop_id is nil
    refute has_element?(view, "#stop-tab-journal")
    refute has_element?(view, "#stop-panel-journal")
    refute has_element?(view, "#stop-tab-details")
    refute has_element?(view, "#stop-tab-history")
  end

  # ============================================================================
  # Rendered-LiveView: reposition stop drawer does NOT render Journal tab
  # ============================================================================

  test "reposition stop drawer does not render Journal tab", context do
    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    # Trigger canvas click and then enter reposition mode
    render_hook(view, "canvas_click", %{"x" => "25.0", "y" => "35.0"})
    render_hook(view, "enter_reposition_mode", %{})

    # In reposition mode with no selected_stop_id, Journal tab should be absent
    refute has_element?(view, "#stop-tab-journal")
    refute has_element?(view, "#stop-panel-journal")
  end

  # ============================================================================
  # Rendered-LiveView: persisted pathway drawer renders Journal tab
  # ============================================================================

  test "persisted pathway drawer renders Journal tab", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "pathway",
                 target_id: context.pathway.id,
                 body: "Pathway entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_pathway", %{"id" => context.pathway.id})

    assert has_element?(view, "#pathway-tab-details")
    assert has_element?(view, "#pathway-tab-history")
    assert has_element?(view, "#pathway-tab-journal")
    assert has_element?(view, "#pathway-panel-journal")
    refute has_element?(view, "#pathway-panel-details[hidden]")
    assert has_element?(view, "#pathway-panel-journal[hidden]")
  end

  # ============================================================================
  # Rendered-LiveView: level editor does NOT have Journal tab
  # ============================================================================

  test "level editor does not render Journal tab", context do
    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "open_edit_level", %{})

    # Level sidebar uses history_tab_strip without show_journal, so no Journal tab
    refute has_element?(view, "#level-tab-journal")
    refute has_element?(view, "#level-panel-journal")
  end

  # ============================================================================
  # Rendered-LiveView: mutual tab exclusion in stop drawer
  # ============================================================================

  test "stop drawer mutual tab exclusion — selecting Journal hides Details and History",
       context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Mutual exclusion test entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    # Initially Details is active
    refute has_element?(view, "#stop-panel-details[hidden]")
    assert has_element?(view, "#stop-panel-history[hidden]")
    assert has_element?(view, "#stop-panel-journal[hidden]")

    # Select Journal
    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    # After Journal is active
    assert has_element?(view, "#stop-panel-details[hidden]")
    assert has_element?(view, "#stop-panel-history[hidden]")
    refute has_element?(view, "#stop-panel-journal[hidden]")
    assert has_element?(view, ~S([data-role="entity-journal-panel"]))

    # Switch back to Details
    render_hook(view, "show_details", %{})
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#stop-panel-details[hidden]")
    assert has_element?(view, "#stop-panel-journal[hidden]")
  end

  # ============================================================================
  # Rendered-LiveView: drawer journal loading state
  # ============================================================================

  test "drawer journal loading state renders skeleton without hiding form", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Loading test entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    # Before releasing the task, we're in loading state
    _task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    # Loading skeleton should be present inside the journal panel
    assert has_element?(view, ~S([data-role="entity-journal-panel"]))
    # The details form should still be usable (hidden but not the form)
    refute has_element?(view, "#stop-panel-journal[hidden]")
  end

  # ============================================================================
  # Rendered-LiveView: drawer journal ready with entries
  # ============================================================================

  test "drawer journal ready state renders entry cards with data", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Ready state entry with note",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    # Entry card should be present
    entry_card_sel = "#drawer-journal-entry-#{entry_id}"
    assert has_element?(view, entry_card_sel)
    # Note body should be present
    entry_list_sel = "#drawer-journal-stop-entry-list"
    assert has_element?(view, entry_list_sel)
    # No lifecycle controls
    refute has_element?(view, "[data-entry-state]")
    # Badge in tab
    assert has_element?(view, "#stop-tab-journal")
  end

  # ============================================================================
  # Rendered-LiveView: drawer journal empty state
  # ============================================================================

  test "drawer journal empty state shows empty message", context do
    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    # Empty state should be visible
    assert has_element?(view, "#drawer-journal-stop-empty")
    # No entry cards
    refute has_element?(view, "[data-role=\"entity-journal-entry\"]")
  end

  # ============================================================================
  # Rendered-LiveView: drawer journal initial error state
  # ============================================================================

  test "drawer journal initial error state shows error with retry", context do
    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, {:raise, "drawer journal failed"})
    render_async(view, 5_000)

    # Error state with retry
    assert has_element?(view, "#drawer-journal-stop-error")
    assert has_element?(view, "#drawer-journal-stop-retry")

    # Form inputs still usable (details panel hidden but exists)
    assert has_element?(view, "#child-stop-form")
  end

  # ============================================================================
  # Rendered-LiveView: no lifecycle/status/filter/delete/marker/panel-handoff UI
  # ============================================================================

  test "drawer journal panel omits lifecycle and navigation controls", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Control-free entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    # No status filter or close/reopen/undo/delete buttons
    filter_sel = "#drawer-journal-stop-#{context.child_stop.id}-filter"
    refute has_element?(view, filter_sel)
    refute has_element?(view, ~S([id^="journal-close-entry-"]))
    refute has_element?(view, ~S([id^="journal-reopen-entry-"]))
    refute has_element?(view, ~S([id^="journal-undo-entry-"]))
    refute has_element?(view, ~S([id^="journal-delete-entry-"]))
    # No data-entry-state attributes
    refute has_element?(view, ~S([data-entry-state]))
    # No Show in journal panel actions
    refute has_element?(view, ~S([id^="journal-show-entry-"]))
  end

  # ============================================================================
  # Rendered-LiveView: journal-origin edit shows context box and no-reopen
  # ============================================================================

  test "journal-origin stop edit closes station panel and opens drawer", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Journal origin entry note",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    # Simulate opening from a journal entry
    render_hook(view, "edit_child_stop", %{
      "id" => context.child_stop.id,
      "journal_entry_id" => entry_id
    })

    # Station journal panel should be closed
    refute assigns(view).journal_panel_open?
    # Drawer should be open for editing the selected stop
    assert assigns(view).selected_stop_id == context.child_stop.id
  end

  test "journal-origin save does not reopen station panel", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Journal origin entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{
      "id" => context.child_stop.id,
      "journal_entry_id" => entry_id
    })

    # Save the stop
    params = %{
      "x" => "50.0",
      "y" => "30.0",
      "stop_id" => context.child_stop.stop_id,
      "stop_name" => "Updated After Journal",
      "location_type" => "0",
      "level_id" => context.level.level_id,
      "wheelchair_boarding" => "0",
      "platform_code" => "",
      "stop_lat" => "",
      "stop_lon" => ""
    }

    render_hook(view, "save_child_stop", params)
    _ = :sys.get_state(view.pid)

    # Station panel should still be closed
    state = assigns(view)
    refute state.journal_panel_open?
    assert state.drawer_journal_state == :idle
  end

  test "journal-origin cancel does not reopen station panel", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "node",
                 target_id: context.child_stop.id,
                 body: "Journal origin entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{
      "id" => context.child_stop.id,
      "journal_entry_id" => entry_id
    })

    # Close the drawer (cancel)
    render_hook(view, "close_drawer", %{})
    _ = :sys.get_state(view.pid)

    state = assigns(view)
    refute state.journal_panel_open?
  end

  test "journal-origin pathway edit closes station panel and opens drawer", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "pathway",
                 target_id: context.pathway.id,
                 body: "Journal pathway entry",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_pathway", %{
      "id" => context.pathway.id,
      "journal_entry_id" => entry_id
    })

    refute assigns(view).journal_panel_open?
    assert assigns(view).editing_pathway.id == context.pathway.id
  end

  # ============================================================================
  # Rendered-LiveView: form inputs usable during journal error
  # ============================================================================

  test "form inputs remain usable during drawer journal error state", context do
    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_child_stop", %{"id" => context.child_stop.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "stop",
      "entity_id" => context.child_stop.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"node", context.child_stop.id})

    release_journal(drawer_task, {:raise, "drawer journal failed"})
    render_async(view, 5_000)

    # Form should still be accessible
    assert has_element?(view, "#child-stop-form")
    # Save/Cancel buttons present
    assert has_element?(view, "button[phx-click=\"close_drawer\"]")
  end

  # ============================================================================
  # Rendered-LiveView: pathway pair switch resets drawer journal
  # ============================================================================

  test "pathway pair switch resets drawer journal stream", context do
    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(context.scope, [
               %{
                 id: entry_id,
                 target_type: "pathway",
                 target_id: context.pathway.id,
                 body: "Pathway entry for pair switch test",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    station_task = await_station_journal_request(context.station.id)
    release_journal(station_task, :real)
    render_async(view, 5_000)

    render_hook(view, "edit_pathway", %{"id" => context.pathway.id})

    render_hook(view, "show_drawer_journal", %{
      "entity_type" => "pathway",
      "entity_id" => context.pathway.id
    })

    drawer_task =
      await_drawer_journal_request(context.station.id, {"pathway", context.pathway.id})

    release_journal(drawer_task, :real)
    render_async(view, 5_000)

    assert assigns(view).drawer_journal_state == :ready

    # Close the pathway drawer — should reset
    render_hook(view, "close_pathway_drawer", %{})
    _ = :sys.get_state(view.pid)

    state = assigns(view)
    assert state.drawer_journal_state == :idle
    assert is_nil(state.drawer_journal_request)
  end
end
