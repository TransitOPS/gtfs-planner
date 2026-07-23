defmodule GtfsPlannerWeb.Gtfs.StationJournalPanelStatesTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationJournal.Scope

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

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "JOURNAL_STATE_STATION",
        stop_name: "Journal State Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "journal_state_level",
        level_name: "Journal State Level",
        level_index: 0.0
      })

    {:ok, _stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    }
  end

  test "a held initial read enters loading without blanking the floorplan", context do
    control_journal_source()
    view = open_diagram(context)
    task = await_journal_request(context.station.id)

    loading = assigns(view)
    assert loading.journal_state == :loading
    refute loading.journal_loaded_once?
    assert loading.journal_request.intent == :counts_only
    assert loading.journal_request.reason == :station_load

    assert has_element?(
             view,
             "#diagram-page[phx-hook='JournalPanelHook']:not([phx-update='ignore'])"
           )

    assert has_element?(view, "#diagram-canvas-wrapper")

    release_journal(task, :real)
    render_async(view, 5_000)
    assert assigns(view).journal_state == :ready
  end

  test "first-load failure is recoverable and an empty retry becomes authoritative", context do
    control_journal_source()
    view = open_diagram(context)
    task = await_journal_request(context.station.id)

    release_journal(task, {:raise, "first journal read failed"})
    render_async(view, 5_000)

    failed = assigns(view)
    assert failed.journal_state == :error
    refute failed.journal_loaded_once?
    refute failed.journal_refresh_error?
    assert failed.journal_request == nil
    assert failed.journal_open_count == 0
    assert failed.journal_closed_count == 0
    assert has_element?(view, "#diagram-canvas-wrapper")

    render_hook(view, "refresh_journal", %{})
    retry_task = await_journal_request(context.station.id)
    release_journal(retry_task, :real)
    render_async(view, 5_000)

    recovered = assigns(view)
    assert recovered.journal_state == :ready
    assert recovered.journal_loaded_once?
    assert recovered.journal_visible_count == 0
    assert recovered.journal_rendered_signature == []
    assert recovered.journal_rendered_entry_ids == MapSet.new()
    refute recovered.journal_refresh_error?
  end

  test "refresh failure preserves the successful stream snapshot and marks it stale", context do
    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(
        context.organization.id,
        context.gtfs_version.id,
        context.station.id,
        context.user.id
      )

    entry_id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(scope, [
               %{
                 id: entry_id,
                 target_type: "station",
                 body: "Keep this visible",
                 captured_at: ~U[2026-07-18 12:00:00.000000Z]
               }
             ])

    control_journal_source()
    view = open_diagram(context)
    initial_task = await_journal_request(context.station.id)
    release_journal(initial_task, :real)
    render_async(view, 5_000)

    render_hook(view, "refresh_journal", %{})
    full_task = await_journal_request(context.station.id)
    release_journal(full_task, :real)
    render_async(view, 5_000)

    successful = assigns(view)
    assert successful.journal_loaded_once?
    assert successful.journal_visible_count == 1
    assert successful.journal_rendered_entry_ids == MapSet.new([entry_id])

    render_hook(view, "refresh_journal", %{})
    failed_task = await_journal_request(context.station.id)
    release_journal(failed_task, {:raise, "refresh journal read failed"})
    render_async(view, 5_000)

    stale = assigns(view)
    assert stale.journal_state == :error
    assert stale.journal_loaded_once?
    assert stale.journal_refresh_error?
    assert stale.journal_visible_count == successful.journal_visible_count
    assert stale.journal_open_count == successful.journal_open_count
    assert stale.journal_closed_count == successful.journal_closed_count
    assert stale.journal_rendered_entry_ids == successful.journal_rendered_entry_ids
    assert stale.journal_rendered_signature == successful.journal_rendered_signature
    assert stale.journal_authors == successful.journal_authors
    assert stale.journal_request == nil
    assert has_element?(view, "#diagram-canvas-wrapper")
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

  defp release_journal(task_pid, result), do: send(task_pid, {:journal_release, result})
end
