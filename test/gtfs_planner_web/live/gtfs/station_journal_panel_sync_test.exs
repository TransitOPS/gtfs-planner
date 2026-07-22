defmodule GtfsPlannerWeb.Gtfs.StationJournalPanelSyncTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.JournalPhoto
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.StationDiagramLive

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
    {station, level, stop_level} = station_with_level(organization.id, gtfs_version.id, "A")

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    }
  end

  test "the production route resolves trusted scope and applies one complete newest-first payload",
       %{
         conn: conn,
         user: user,
         organization: organization,
         gtfs_version: gtfs_version,
         station: station,
         level: level,
         stop_level: stop_level
       } do
    node =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "JOURNAL_NODE",
        stop_name: "North mezzanine",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id
      })

    other_node =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "JOURNAL_NODE_2",
        stop_name: "South mezzanine",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id
      })

    {:ok, pathway} =
      Gtfs.create_pathway(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        pathway_id: "JOURNAL_PATHWAY",
        from_stop_id: node.stop_id,
        to_stop_id: other_node.stop_id,
        pathway_mode: 1,
        is_bidirectional: true
      })

    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(
        organization.id,
        gtfs_version.id,
        station.id,
        user.id
      )

    ids = %{
      station: Ecto.UUID.generate(),
      node: Ecto.UUID.generate(),
      pathway: Ecto.UUID.generate(),
      pin: Ecto.UUID.generate()
    }

    assert %{synced_count: 4, errors: []} =
             Gtfs.sync_journal_entries(scope, [
               journal_attrs(ids.station, "station", ~U[2026-07-18 12:00:00.000000Z]),
               journal_attrs(ids.node, "node", ~U[2026-07-18 12:10:00.000000Z], %{
                 target_id: node.id
               }),
               journal_attrs(ids.pathway, "pathway", ~U[2026-07-18 12:20:00.000000Z], %{
                 target_id: pathway.id
               }),
               journal_attrs(ids.pin, "pin", ~U[2026-07-18 12:30:00.000000Z], %{
                 stop_level_id: stop_level.id,
                 diagram_x: 10.0,
                 diagram_y: 20.0
               })
             ])

    assert {:ok, _closed} = Gtfs.close_journal_entry(scope, ids.station)

    view = open_diagram(conn, user, organization, gtfs_version, station)
    render_async(view, 5_000)

    initial = assigns(view)

    assert %Scope{
             organization_id: organization_id,
             gtfs_version_id: version_id,
             station_id: station_id,
             actor_id: actor_id
           } = initial.journal_scope

    assert organization_id == organization.id
    assert version_id == gtfs_version.id
    assert station_id == station.id
    assert actor_id == user.id
    assert initial.journal_open_count == 3
    assert initial.journal_closed_count == 1
    assert initial.journal_state == :ready
    assert initial.journal_request == nil
    assert initial.journal_visible_count == 0
    assert initial.journal_rendered_signature == []
    assert initial.journal_rendered_entry_ids == MapSet.new()
    assert initial.journal_authors == %{}
    assert initial.journal_targets == %{}

    assert Enum.map(initial.journal_observed_signature, &elem(&1, 0)) == [
             ids.pin,
             ids.pathway,
             ids.node,
             ids.station
           ]

    render_hook(view, "refresh_journal", %{})
    render_async(view, 5_000)

    loaded = assigns(view)

    assert loaded.journal_loaded_once?
    assert loaded.journal_visible_count == 3
    assert loaded.journal_open_count == 3
    assert loaded.journal_closed_count == 1
    assert loaded.journal_rendered_signature == loaded.journal_observed_signature
    assert loaded.journal_rendered_entry_ids == MapSet.new(Map.values(ids))
    assert loaded.journal_authors[user.id].email == user.email
    assert loaded.journal_targets[node.id] == %{label: "North mezzanine"}
    assert loaded.journal_targets[pathway.id] == %{label: "JOURNAL_PATHWAY"}
    assert loaded.journal_targets[stop_level.id] == %{label: "Platform A"}
    assert %NaiveDateTime{} = loaded.journal_local_times[{ids.pin, :captured}]
    assert %NaiveDateTime{} = loaded.journal_local_times[{ids.station, :closed}]
    assert %NaiveDateTime{} = loaded.journal_now
    refute Map.has_key?(loaded, :journal_entries)
    assert has_element?(view, "#diagram-canvas-wrapper")
  end

  test "observe-scrolled application updates only observed metadata and set-derived pending ids",
       %{
         conn: conn,
         user: user,
         organization: organization,
         gtfs_version: gtfs_version,
         station: station
       } do
    view = open_diagram(conn, user, organization, gtfs_version, station)
    render_async(view, 5_000)
    render_hook(view, "refresh_journal", %{})
    render_async(view, 5_000)

    socket = :sys.get_state(view.pid).socket
    existing_id = Ecto.UUID.generate()
    new_id = Ecto.UUID.generate()

    observe_request = %{
      scope_key: {organization.id, gtfs_version.id, station.id},
      generation: socket.assigns.journal_load_generation + 1,
      intent: :observe_scrolled,
      reason: :pubsub,
      filter: :open
    }

    socket = put_in(socket.assigns.journal_request, observe_request)
    rendered_signature = socket.assigns.journal_rendered_signature
    authors = socket.assigns.journal_authors
    targets = socket.assigns.journal_targets

    payload = %{
      open_count: 2,
      closed_count: 1,
      entry_ids: MapSet.new([existing_id, new_id]),
      signature: [{new_id, ~U[2026-07-18 12:00:00.000000Z], nil, []}]
    }

    assert {:noreply, observed_socket} =
             StationDiagramLive.handle_async(
               :journal_load,
               {:ok, {observe_request, {:ok, payload}}},
               socket
             )

    assert observed_socket.assigns.journal_open_count == 2
    assert observed_socket.assigns.journal_closed_count == 1
    assert observed_socket.assigns.journal_pending_new_ids == MapSet.new([existing_id, new_id])
    assert observed_socket.assigns.journal_observed_signature == payload.signature
    assert observed_socket.assigns.journal_rendered_signature == rendered_signature
    assert observed_socket.assigns.journal_authors == authors
    assert observed_socket.assigns.journal_targets == targets
    assert observed_socket.assigns.journal_request == nil
  end

  test "complete request identity rejects superseded same-station results and cancelled exits",
       %{
         conn: conn,
         user: user,
         organization: organization,
         gtfs_version: gtfs_version,
         station: station
       } do
    control_journal_source()
    view = open_diagram(conn, user, organization, gtfs_version, station)

    first = await_journal_request(station.id)
    release_journal(first, :real)
    render_async(view, 5_000)

    render_hook(view, "refresh_journal", %{})
    older = await_journal_request(station.id)

    render_hook(view, "refresh_journal", %{})
    newest = await_journal_request(station.id)

    current_socket = :sys.get_state(view.pid).socket
    current_request = current_socket.assigns.journal_request

    assert current_request.generation == 3
    assert current_request.intent == :full
    assert current_request.reason == :retry
    assert current_request.filter == :open

    mismatches = [
      %{current_request | generation: current_request.generation - 1},
      %{current_request | intent: :counts_only},
      %{current_request | reason: :refresh},
      %{current_request | filter: :all},
      %{
        current_request
        | scope_key: {Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate()}
      }
    ]

    Enum.each(mismatches, fn request ->
      assert {:noreply, ^current_socket} =
               StationDiagramLive.handle_async(
                 :journal_load,
                 {:ok, {request, {:ok, %{unexpected: true}}}},
                 current_socket
               )
    end)

    assert {:noreply, ^current_socket} =
             StationDiagramLive.handle_async(
               :journal_load,
               {:exit, {:shutdown, :cancel}},
               current_socket
             )

    release_journal(newest, :real)
    render_async(view, 5_000)
    accepted = assigns(view)

    older_ref = Process.monitor(older)
    release_journal(older, [])
    assert_receive {:DOWN, ^older_ref, :process, ^older, _reason}, 5_000
    _ = :sys.get_state(view.pid)

    assert assigns(view).journal_load_generation == accepted.journal_load_generation
    assert assigns(view).journal_rendered_signature == accepted.journal_rendered_signature
    assert assigns(view).journal_state == :ready
  end

  test "a scoped broadcast refreshes only counts while the panel is closed", context do
    existing_id = Ecto.UUID.generate()
    new_id = Ecto.UUID.generate()
    scope = scope(context)

    sync_entries(scope, [
      journal_attrs(existing_id, "station", ~U[2026-07-18 12:00:00.000000Z])
    ])

    view = open_diagram(context)
    render_async(view, 5_000)
    render_hook(view, "refresh_journal", %{})
    render_async(view, 5_000)

    before = assigns(view)
    refute before.journal_panel_open?
    assert before.journal_rendered_entry_ids == MapSet.new([existing_id])

    sync_entries(scope, [journal_attrs(new_id, "station", ~U[2026-07-18 12:01:00.000000Z])])
    settle_journal(view)

    counted = assigns(view)
    refute counted.journal_panel_open?
    assert counted.journal_open_count == 2
    assert counted.journal_closed_count == 0
    assert counted.journal_rendered_entry_ids == before.journal_rendered_entry_ids
    assert counted.journal_rendered_signature == before.journal_rendered_signature
    assert Enum.map(counted.journal_observed_signature, &elem(&1, 0)) == [new_id, existing_id]
  end

  test "at-top changed and identical PubSub snapshots refresh once without pending work",
       context do
    entry_id = Ecto.UUID.generate()
    scope = scope(context)

    sync_entries(scope, [
      journal_attrs(entry_id, "station", ~U[2026-07-18 12:00:00.000000Z])
    ])

    view = open_loaded_journal(context)
    before = assigns(view)

    sync_entries(scope, [
      journal_attrs(entry_id, "station", ~U[2026-07-18 12:00:00.000000Z], %{
        body: "Authoritative update"
      })
    ])

    settle_journal(view)

    changed = assigns(view)
    assert changed.journal_panel_open?
    assert changed.journal_at_top?
    assert changed.journal_rendered_signature != before.journal_rendered_signature
    assert changed.journal_rendered_signature == changed.journal_observed_signature
    assert changed.journal_pending_new_ids == MapSet.new()

    broadcast_journal(scope)
    settle_journal(view)

    identical = assigns(view)
    assert identical.journal_rendered_signature == changed.journal_rendered_signature
    assert identical.journal_observed_signature == changed.journal_observed_signature
    assert identical.journal_pending_new_ids == MapSet.new()
    assert identical.journal_visible_count == 1
  end

  test "scrolled PubSub derives pending IDs and stays idempotent across repeat and photo-only updates",
       context do
    existing_id = Ecto.UUID.generate()
    new_id = Ecto.UUID.generate()
    photo_id = Ecto.UUID.generate()
    scope = scope(context)

    sync_entries(scope, [
      journal_attrs(existing_id, "station", ~U[2026-07-18 12:00:00.000000Z])
    ])

    view = open_loaded_journal(context)
    render_hook(view, "journal_scroll_state", %{"at_top" => false})
    refute assigns(view).journal_at_top?

    sync_entries(scope, [journal_attrs(new_id, "station", ~U[2026-07-18 12:01:00.000000Z])])
    settle_journal(view)

    first_observation = assigns(view)
    assert first_observation.journal_pending_new_ids == MapSet.new([new_id])
    assert first_observation.journal_rendered_entry_ids == MapSet.new([existing_id])

    assert first_observation.journal_rendered_signature !=
             first_observation.journal_observed_signature

    broadcast_journal(scope)
    settle_journal(view)
    assert assigns(view).journal_pending_new_ids == MapSet.new([new_id])

    Repo.insert!(%JournalPhoto{
      id: photo_id,
      journal_entry_id: existing_id,
      filename: "scrolled-photo.jpg",
      content_type: "image/jpeg",
      byte_size: 10,
      sha256: :crypto.hash(:sha256, "scrolled-photo"),
      captured_at: ~U[2026-07-18 12:02:00.000000Z]
    })

    broadcast_journal(scope)
    settle_journal(view)

    photo_observation = assigns(view)
    assert photo_observation.journal_pending_new_ids == MapSet.new([new_id])

    assert signature_photo_ids(photo_observation.journal_observed_signature, existing_id) == [
             photo_id
           ]

    assert signature_photo_ids(photo_observation.journal_rendered_signature, existing_id) == []

    render_hook(view, "journal_scroll_state", %{"at_top" => true})
    render_async(view, 5_000)

    refreshed = assigns(view)
    assert refreshed.journal_at_top?
    assert refreshed.journal_pending_new_ids == MapSet.new()
    assert refreshed.journal_rendered_entry_ids == MapSet.new([existing_id, new_id])
    assert refreshed.journal_rendered_signature == refreshed.journal_observed_signature
    assert_push_event(view, "journal-scroll-top", %{})
    new_entry_selector = "#journal-entries-#{new_id}"
    assert_push_event(view, "journal-focus", %{selector: ^new_entry_selector})
  end

  test "foreign station messages cannot change the current journal snapshot", context do
    entry_id = Ecto.UUID.generate()
    scope = scope(context)
    sync_entries(scope, [journal_attrs(entry_id, "station", ~U[2026-07-18 12:00:00.000000Z])])

    view = open_loaded_journal(context)
    before = assigns(view)
    foreign_station_id = Ecto.UUID.generate()

    send(view.pid, {:station_journal_changed, foreign_station_id})
    _ = :sys.get_state(view.pid)

    after_foreign = assigns(view)
    assert after_foreign.journal_request == nil
    assert after_foreign.journal_load_generation == before.journal_load_generation
    assert after_foreign.journal_rendered_entry_ids == before.journal_rendered_entry_ids
    assert after_foreign.journal_rendered_signature == before.journal_rendered_signature
    assert after_foreign.journal_observed_signature == before.journal_observed_signature
    assert after_foreign.journal_pending_new_ids == before.journal_pending_new_ids
  end

  test "closing the panel invalidates its held full request before a late completion", context do
    entry_id = Ecto.UUID.generate()
    scope = scope(context)
    sync_entries(scope, [journal_attrs(entry_id, "station", ~U[2026-07-18 12:00:00.000000Z])])
    control_journal_source()

    view = open_diagram(context)
    initial_task = await_journal_request(context.station.id)
    release_journal(initial_task, :real)
    render_async(view, 5_000)

    render_hook(view, "open_journal", %{})
    held_task = await_journal_request(context.station.id)
    held_generation = assigns(view).journal_load_generation

    render_hook(view, "close_journal", %{})

    closed = assigns(view)
    refute closed.journal_panel_open?
    assert closed.journal_request == nil
    assert closed.journal_state == :idle
    assert closed.journal_rendered_signature == []

    held_ref = Process.monitor(held_task)
    release_journal(held_task, :real)
    assert_receive {:DOWN, ^held_ref, :process, ^held_task, _reason}, 5_000
    _ = :sys.get_state(view.pid)

    after_late = assigns(view)
    assert after_late.journal_load_generation == held_generation
    assert after_late.journal_request == nil
    assert after_late.journal_rendered_signature == []
    assert after_late.journal_visible_count == 0
  end

  test "a station reset invalidates the old request and rebuilds trusted scope",
       %{
         conn: conn,
         user: user,
         organization: organization,
         gtfs_version: gtfs_version,
         station: station
       } do
    control_journal_source()

    {station_b, _level_b, _stop_level_b} =
      station_with_level(organization.id, gtfs_version.id, "B")

    view = open_diagram(conn, user, organization, gtfs_version, station)
    old_task = await_journal_request(station.id)

    render_patch(view, "/gtfs/#{gtfs_version.id}/stops/#{station_b.stop_id}/diagram")
    new_task = await_journal_request(station_b.id)

    reset = assigns(view)
    assert reset.journal_scope.station_id == station_b.id

    assert reset.journal_request.scope_key ==
             {organization.id, gtfs_version.id, station_b.id}

    assert reset.journal_load_generation == 2
    assert reset.journal_open_count == 0
    assert reset.journal_closed_count == 0
    assert reset.journal_visible_count == 0
    assert reset.journal_rendered_entry_ids == MapSet.new()
    assert reset.journal_pending_new_ids == MapSet.new()
    assert reset.journal_undo_ids == MapSet.new()
    assert reset.journal_authors == %{}
    assert reset.journal_targets == %{}

    old_ref = Process.monitor(old_task)
    release_journal(old_task, :real)
    assert_receive {:DOWN, ^old_ref, :process, ^old_task, _reason}, 5_000
    _ = :sys.get_state(view.pid)

    assert assigns(view).journal_scope.station_id == station_b.id
    assert assigns(view).journal_request.generation == 2

    release_journal(new_task, :real)
    render_async(view, 5_000)

    final = assigns(view)
    assert final.journal_scope.station_id == station_b.id
    assert final.journal_state == :ready
    assert final.journal_request == nil
  end

  test "initial counts-only load populates markers while keeping panel closed and observe-scrolled updates markers",
       context do
    scope = scope(context)
    pin_id = Ecto.UUID.generate()

    sync_entries(scope, [
      journal_attrs(pin_id, "pin", ~U[2026-07-18 12:00:00.000000Z], %{
        stop_level_id: context.stop_level.id,
        diagram_x: 30.0,
        diagram_y: 40.0
      })
    ])

    view = open_diagram(context)
    render_async(view, 5_000)

    initial = assigns(view)
    refute initial.journal_panel_open?
    assert initial.journal_marker_index != nil
    assert MapSet.member?(initial.journal_floorplan_entry_ids, pin_id)

    assert has_element?(
             view,
             "#journal-markers-svg #journal-markers-svg-journal-marker-pin-#{pin_id}"
           )

    render_hook(view, "open_journal", %{})
    render_async(view, 5_000)

    full = assigns(view)
    assert full.journal_marker_index != nil
    assert full.journal_loaded_once?

    assert has_element?(
             view,
             "#journal-markers-svg #journal-markers-svg-journal-marker-pin-#{pin_id}"
           )
  end

  test "first load failure leaves markers empty and refresh failure preserves accepted markers",
       context do
    control_journal_source()
    view = open_diagram(context)

    first_req = await_journal_request(context.station.id)
    release_journal(first_req, {:error, :db_down})
    render_async(view, 5_000)

    failed_initial = assigns(view)
    assert failed_initial.journal_state == :error
    assert failed_initial.journal_marker_index == nil
    refute has_element?(view, "#journal-markers-svg [data-journal-marker]")

    render_hook(view, "refresh_journal", %{})
    ok_req = await_journal_request(context.station.id)
    release_journal(ok_req, :real)
    render_async(view, 5_000)

    accepted = assigns(view)
    assert accepted.journal_state == :ready
    assert accepted.journal_marker_index != nil

    render_hook(view, "refresh_journal", %{})
    fail_req = await_journal_request(context.station.id)
    release_journal(fail_req, {:error, :timeout})
    render_async(view, 5_000)

    refresh_failed = assigns(view)
    assert refresh_failed.journal_state == :error
    assert refresh_failed.journal_refresh_error? == true
    assert refresh_failed.journal_marker_index == accepted.journal_marker_index
  end

  defp station_with_level(organization_id, gtfs_version_id, suffix) do
    station =
      stop_fixture(organization_id, gtfs_version_id, %{
        stop_id: "JOURNAL_STATION_#{suffix}",
        stop_name: "Journal Station #{suffix}",
        location_type: 1
      })

    level =
      level_fixture(organization_id, gtfs_version_id, %{
        level_id: "journal_level_#{suffix}",
        level_name: "Platform #{suffix}",
        level_index: 0.0
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        stop_id: station.id,
        level_id: level.id
      })

    {station, level, stop_level}
  end

  defp journal_attrs(id, target_type, captured_at, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        target_type: target_type,
        body: "Journal entry #{id}",
        captured_at: captured_at
      },
      extra
    )
  end

  defp open_diagram(conn, user, organization, gtfs_version, station) do
    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

    view
  end

  defp open_diagram(context) do
    open_diagram(
      context.conn,
      context.user,
      context.organization,
      context.gtfs_version,
      context.station
    )
  end

  defp open_loaded_journal(context) do
    view = open_diagram(context)
    render_async(view, 5_000)
    render_hook(view, "open_journal", %{})
    render_async(view, 5_000)
    view
  end

  defp scope(context) do
    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(
        context.organization.id,
        context.gtfs_version.id,
        context.station.id,
        context.user.id
      )

    scope
  end

  defp sync_entries(scope, entries) do
    assert %{synced_count: synced_count, errors: []} = Gtfs.sync_journal_entries(scope, entries)
    assert synced_count == length(entries)
  end

  defp broadcast_journal(scope) do
    topic =
      "station_journal:#{scope.organization_id}:#{scope.gtfs_version_id}:#{scope.station_id}"

    assert :ok =
             Phoenix.PubSub.broadcast(
               GtfsPlanner.PubSub,
               topic,
               {:station_journal_changed, scope.station_id}
             )
  end

  defp settle_journal(view) do
    _ = :sys.get_state(view.pid)
    render_async(view, 5_000)
    _ = :sys.get_state(view.pid)
  end

  defp signature_photo_ids(signature, entry_id) do
    {_id, _updated_at, _closed_at, photo_ids} =
      Enum.find(signature, &(elem(&1, 0) == entry_id))

    photo_ids
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

  defp await_journal_request(station_id) do
    assert_receive {:journal_requested, task_pid, %Scope{station_id: ^station_id}, opts}, 5_000
    assert opts == [status: :all, order: :desc]
    task_pid
  end

  defp release_journal(task_pid, result) do
    send(task_pid, {:journal_release, result})
  end
end
