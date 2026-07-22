defmodule GtfsPlannerWeb.Gtfs.StationJournalPanelSyncTest.ControlledJournalSource do
  @moduledoc false

  alias GtfsPlanner.Gtfs

  def list_station_journal(scope, opts) do
    Process.flag(:trap_exit, true)
    owner = Application.fetch_env!(:gtfs_planner, :station_journal_source_owner)
    send(owner, {:journal_requested, self(), scope, opts})

    receive do
      {:journal_release, :real} -> Gtfs.list_station_journal(scope, opts)
      {:journal_release, {:raise, message}} -> raise message
      {:journal_release, entries} when is_list(entries) -> entries
    after
      10_000 -> raise "controlled journal request timed out"
    end
  end

  defdelegate list_child_stops_for_parent(organization_id, gtfs_version_id, station_id),
    to: Gtfs

  defdelegate list_pathways_for_station(organization_id, gtfs_version_id, station_id),
    to: Gtfs

  defdelegate list_stop_levels_for_station(organization_id, gtfs_version_id, station_id),
    to: Gtfs

  defdelegate resolve_display_zone(organization_id, gtfs_version_id), to: Gtfs
  defdelegate localize_display_times(timestamps, zone_resolution), to: Gtfs
end

defmodule GtfsPlannerWeb.Gtfs.StationJournalPanelSyncTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlannerWeb.Gtfs.StationDiagramLive

  @controlled_source __MODULE__.ControlledJournalSource

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
    assert reset.journal_expanded_id == nil
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
