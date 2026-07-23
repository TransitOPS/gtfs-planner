defmodule GtfsPlannerWeb.Gtfs.StopDetailLiveJournalTest do
  use GtfsPlannerWeb.ConnCase, async: false

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
        stop_id: "JOURNAL_DETAIL_STATION",
        stop_name: "Journal Detail Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "journal_detail_level",
        level_name: "Journal Detail Level",
        level_index: 0.0
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    child_node =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "JOURNAL_DETAIL_NODE",
        stop_name: "Journal Detail Node",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id
      })

    pathway =
      pathway_fixture(organization.id, gtfs_version.id, child_node.stop_id, station.stop_id, %{
        pathway_id: "JOURNAL_DETAIL_PW"
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
      child_node: child_node,
      pathway: pathway,
      scope: scope
    }
  end

  describe "journal summary ideal state" do
    test "renders open/closed counts and three newest rows with target labels and links",
         context do
      seed_journal_entries(context)
      view = open_details(context)
      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-summary")
      assert has_element?(view, "#journal-open-count", "3 open")
      assert has_element?(view, "#journal-closed-count", "4 closed")

      assert has_element?(view, "#journal-recent-entry-list")

      assert has_element?(
               view,
               "#journal-recent-entry-list [data-role='journal-summary-entry']"
             )

      entries =
        view
        |> element("#journal-recent-entry-list")
        |> render()

      assert entries =~ "Node · Journal Detail Node"
      assert entries =~ "Pathway · JOURNAL_DETAIL_PW"
      assert entries =~ "Pin · Journal Detail Level"

      refute entries =~ "fourth entry body"

      assert has_element?(
               view,
               ~s(a#journal-footer-link[href*="/diagram"])
             )
    end

    test "closed rows are de-emphasized with opacity", context do
      seed_journal_entries(context)
      view = open_details(context)
      render_async(view, 5_000)

      html = render(view)
      assert html =~ "opacity-60"
    end

    test "station target rows show bare kind label", context do
      Gtfs.sync_journal_entries(context.scope, [
        %{
          id: Ecto.UUID.generate(),
          target_type: "station",
          body: "Station level entry",
          captured_at: ~U[2026-07-21 10:00:00Z]
        },
        %{
          id: Ecto.UUID.generate(),
          target_type: "station",
          body: "Second station entry",
          captured_at: ~U[2026-07-20 10:00:00Z]
        },
        %{
          id: Ecto.UUID.generate(),
          target_type: "station",
          body: "Third station entry",
          captured_at: ~U[2026-07-19 10:00:00Z]
        }
      ])

      view = open_details(context)
      render_async(view, 5_000)

      html = render(view)
      assert html =~ "Station"
    end

    test "removed target degrades to bare kind with removed marker", context do
      removable_node =
        stop_fixture(context.organization.id, context.gtfs_version.id, %{
          stop_id: "JOURNAL_REMOVABLE_NODE",
          stop_name: "Removable Node",
          location_type: 0,
          parent_station: context.station.stop_id,
          level_id: context.level.level_id
        })

      assert %{synced_count: 3, errors: []} =
               Gtfs.sync_journal_entries(context.scope, [
                 %{
                   id: Ecto.UUID.generate(),
                   target_type: "node",
                   target_id: removable_node.id,
                   body: "Entry with removed target",
                   captured_at: ~U[2026-07-21 10:00:00Z]
                 },
                 %{
                   id: Ecto.UUID.generate(),
                   target_type: "station",
                   body: "Second entry",
                   captured_at: ~U[2026-07-20 10:00:00Z]
                 },
                 %{
                   id: Ecto.UUID.generate(),
                   target_type: "station",
                   body: "Third entry",
                   captured_at: ~U[2026-07-19 10:00:00Z]
                 }
               ])

      GtfsPlanner.Repo.delete!(removable_node)

      view = open_details(context)
      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-summary")
      assert has_element?(view, "#journal-recent-entry-list")

      html =
        view
        |> element("#journal-recent-entry-list")
        |> render()

      assert html =~ "Node"
      assert html =~ "removed"
    end
  end

  describe "journal summary empty state" do
    test "renders empty state without a create CTA for stations with no entries", context do
      view = open_details(context)
      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-summary")
      assert has_element?(view, "#journal-summary-empty")

      html = render(view)
      refute html =~ "Create"
      refute html =~ "Add entry"
      refute html =~ "New entry"
    end
  end

  describe "journal summary non-station absence" do
    test "does not render journal section for non-station stops", context do
      _platform =
        stop_fixture(context.organization.id, context.gtfs_version.id, %{
          stop_id: "JOURNAL_DETAIL_PLATFORM",
          stop_name: "Journal Detail Platform",
          location_type: 0,
          parent_station: context.station.stop_id,
          level_id: context.level.level_id
        })

      conn = log_in_user(context.conn, context.user, organization: context.organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{context.gtfs_version.id}/stops/JOURNAL_DETAIL_PLATFORM",
          on_error: :warn
        )

      refute has_element?(view, "#station-journal-summary")
    end
  end

  describe "journal summary initial failure and retry" do
    test "shows unavailable state on first-load failure with retry", context do
      seed_journal_entries(context)
      control_journal_source()
      view = open_details(context)
      task = await_journal_request(context.station.id)

      release_journal(task, {:raise, "journal read failed"})
      render_async(view, 5_000)

      assert has_element?(view, "#journal-summary-unavailable")
      assert has_element?(view, "#journal-summary-retry")

      render_click(element(view, "#journal-summary-retry"))
      retry_task = await_journal_request(context.station.id)
      release_journal(retry_task, :real)
      render_async(view, 5_000)

      assert has_element?(view, "#journal-open-count")
    end
  end

  describe "journal summary retained snapshot on refresh failure" do
    test "preserves previous data and shows warning when refresh fails", context do
      seed_journal_entries(context)
      control_journal_source()
      view = open_details(context)
      initial_task = await_journal_request(context.station.id)
      release_journal(initial_task, :real)
      render_async(view, 5_000)

      assert has_element?(view, "#journal-open-count")
      assert has_element?(view, "#journal-recent-entry-list")

      render_click(element(view, "#journal-summary-refresh"))
      failed_task = await_journal_request(context.station.id)
      release_journal(failed_task, {:raise, "refresh failed"})
      render_async(view, 5_000)

      assert has_element?(view, "#journal-summary-stale-warning")
      assert has_element?(view, "#journal-open-count")
      assert has_element?(view, "#journal-recent-entry-list")
    end
  end

  describe "journal summary localized time" do
    test "uses relative_time formatting for capture times", context do
      Gtfs.sync_journal_entries(context.scope, [
        %{
          id: Ecto.UUID.generate(),
          target_type: "station",
          body: "Recent entry",
          captured_at: DateTime.utc_now() |> DateTime.add(-120, :second)
        },
        %{
          id: Ecto.UUID.generate(),
          target_type: "station",
          body: "Second entry",
          captured_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
        },
        %{
          id: Ecto.UUID.generate(),
          target_type: "station",
          body: "Third entry",
          captured_at: DateTime.utc_now() |> DateTime.add(-86_400, :second)
        }
      ])

      view = open_details(context)
      render_async(view, 5_000)

      html = render(view)
      assert html =~ "ago" or html =~ "just now" or html =~ "yesterday"
    end
  end

  defp seed_journal_entries(context) do
    entries = [
      %{
        id: Ecto.UUID.generate(),
        target_type: "node",
        target_id: context.child_node.id,
        body: "First entry body",
        captured_at: ~U[2026-07-21 14:00:00Z]
      },
      %{
        id: Ecto.UUID.generate(),
        target_type: "pathway",
        target_id: context.pathway.id,
        body: "Second entry body",
        captured_at: ~U[2026-07-21 12:00:00Z]
      },
      %{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: context.stop_level.id,
        diagram_x: 50.0,
        diagram_y: 50.0,
        body: "Third entry body",
        captured_at: ~U[2026-07-21 10:00:00Z]
      },
      %{
        id: Ecto.UUID.generate(),
        target_type: "station",
        body: "fourth entry body",
        captured_at: ~U[2026-07-20 10:00:00Z]
      },
      %{
        id: Ecto.UUID.generate(),
        target_type: "station",
        body: "Fifth entry body",
        captured_at: ~U[2026-07-19 10:00:00Z]
      },
      %{
        id: Ecto.UUID.generate(),
        target_type: "station",
        body: "Sixth entry body",
        captured_at: ~U[2026-07-18 10:00:00Z]
      },
      %{
        id: Ecto.UUID.generate(),
        target_type: "station",
        body: "Seventh entry body",
        captured_at: ~U[2026-07-17 10:00:00Z]
      }
    ]

    %{synced_count: 7, errors: []} = Gtfs.sync_journal_entries(context.scope, entries)

    [first, second, third | _rest] = entries
    {:ok, _} = Gtfs.close_journal_entry(context.scope, first.id)
    {:ok, _} = Gtfs.close_journal_entry(context.scope, second.id)
    {:ok, _} = Gtfs.close_journal_entry(context.scope, third.id)
    {:ok, _} = Gtfs.close_journal_entry(context.scope, Enum.at(entries, 3).id)
  end

  defp open_details(context) do
    conn = log_in_user(context.conn, context.user, organization: context.organization)

    {:ok, view, _html} =
      live(
        conn,
        "/gtfs/#{context.gtfs_version.id}/stops/#{context.station.stop_id}",
        on_error: :warn
      )

    view
  end

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
    assert_receive {:journal_requested, task_pid, %Scope{station_id: ^station_id}, _opts}, 5_000
    task_pid
  end

  defp release_journal(task_pid, result), do: send(task_pid, {:journal_release, result})
end
