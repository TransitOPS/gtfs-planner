defmodule GtfsPlannerWeb.Gtfs.ExportNewFileTest do
  @moduledoc """
  Focused evidence for the Export New file card and its async operations preview:
  the grouped kind choice, the operations-only tiles and inventory, the preview's
  per-visit single task, its error fallback, and the per-kind action.

  These cases drive the routed `/gtfs/:version/export` page and the real
  `GtfsPlanner.Gtfs.Export.operations_preview/2` derivation. The preview's
  blocking cases synchronise on repo-query telemetry from the preview task rather
  than sleep.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @preview_files [
    "stops_supplement.txt",
    "vehicles.txt",
    "calendar_dates_supplement.txt",
    "routes_supplement.txt",
    "trips_supplement.txt",
    "stop_times_supplement.txt",
    "run_events.txt",
    "employee_run_dates.txt"
  ]

  setup do
    organization = organization_fixture()
    user = user_fixture()
    add_editor(user, organization)
    version = gtfs_version_fixture(organization.id)
    %{user: user, organization: organization, version: version}
  end

  defp add_editor(user, organization) do
    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })
  end

  defp pathways_org do
    organization = organization_fixture(%{product: :pathways})
    user = user_fixture()
    add_editor(user, organization)
    version = gtfs_version_fixture(organization.id)
    %{user: user, organization: organization, version: version}
  end

  defp export_path(version), do: "/gtfs/#{version.id}/export"

  defp open(conn, context, query \\ "") do
    live(
      log_in_user(conn, context.user, organization: context.organization),
      export_path(context.version) <> query
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  # One repo query the operations preview issues when it derives runs. The
  # handler blocks the first matching query until the case resumes it, so a case
  # can act while the preview is in flight.
  defp attach_preview_barrier(tag, block? \\ true) do
    parent = self()
    counter = :counters.new(1, [:atomics])
    handler_id = {__MODULE__, tag, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {parent, counter, block?} ->
        if metadata[:source] == "trip_runs" do
          count = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, count)
          send(parent, {:preview_query, count, self()})

          if block? and count == 1 do
            receive do
              :resume -> :ok
            after
              30_000 -> :ok
            end
          end
        end
      end,
      {parent, counter, block?}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    counter
  end

  describe "the grouped kind choice" do
    test "a Pathways product hides the vendor fieldset and falls back to Full", context do
      %{conn: conn} = context
      context = pathways_org()

      {:ok, view, _html} = open(conn, context, "?type=operations_only")

      refute has_element?(view, "#export-type-group-vendor")
      refute has_element?(view, "#export-type-operations")
      refute has_element?(view, "#export-type-operations_only")
      assert has_element?(view, "#export-type-full[checked]")
    end

    test "a planner product shows both audience groups and four choices", context do
      {:ok, view, _html} = open(context.conn, context)

      assert has_element?(view, "#export-type-group-trip-planners")
      assert has_element?(view, "#export-type-group-vendor")

      for id <- [
            "#export-type-full",
            "#export-type-pathways",
            "#export-type-operations",
            "#export-type-operations_only"
          ] do
        assert has_element?(view, id)
      end
    end
  end

  describe "the operations-only card" do
    test "renders the operations tiles, inventory and CTA without the old anatomy", context do
      garage_fixture(context.organization.id)
      garage_fixture(context.organization.id)
      vehicle_fixture(context.organization.id)

      {:ok, view, _html} = open(context.conn, context, "?type=operations_only")

      html = render_async(view)

      # Exactly the four operations-only tiles, each with its stable id and label.
      assert count(html, "#export-metrics > div") == 4

      for {id, label} <- [
            {"export-tile-garages", "Garages"},
            {"export-tile-vehicles", "Vehicles"},
            {"export-tile-runs", "Runs"},
            {"export-tile-trips_in_run", "Trips in a run"}
          ] do
        assert has_element?(view, "##{id}", label)
      end

      assert has_element?(view, "#start-export", "Export operations data")

      # Every preview-derived file is an inventory row, run events included.
      for file <- @preview_files do
        assert has_element?(view, "#export-inventory", file)
      end

      # The old page anatomy is gone.
      refute has_element?(view, "#operations-export-note")
      refute has_element?(view, "#export-run-status")
      refute has_element?(view, "#export-guide")
      refute has_element?(view, "#export-page", "Export feed")
    end
  end

  describe "the per-kind action" do
    test "labels the action as the kind is patched through", context do
      {:ok, view, _html} = open(context.conn, context, "?type=full")

      for {type, label} <- [
            {"full", "Export full feed"},
            {"pathways", "Export station pathways"},
            {"operations", "Export feed with operations"},
            {"operations_only", "Export operations data"}
          ] do
        render_change(view, "select_export_type", %{"export" => %{"type" => type}})
        assert has_element?(view, "#start-export", label)
      end
    end

    test "a pending run of the selected kind disables the action and explains why", context do
      {:ok, _run} =
        ExportRuns.create_pending(
          context.organization.id,
          context.version.id,
          %{id: Ecto.UUID.generate(), email: "actor@example.com"},
          :operations
        )

      {:ok, view, _html} = open(context.conn, context, "?type=operations")

      assert has_element?(view, "#start-export[disabled]", "Exporting…")

      assert has_element?(
               view,
               "#export-new-file",
               "This file is being built. It appears in Files below."
             )
    end
  end

  describe "one operations preview per visit" do
    setup :committed_pool

    test "switching kinds never starts a second preview task", context do
      %{repo: repo} = context
      committed = committed_world()

      {:ok, view, _html} =
        live(
          log_in_user(context.conn, committed.user, organization: committed.organization),
          export_path(committed.version) <> "?type=full"
        )

      bind_liveview_repo(view, repo)
      counter = attach_preview_barrier(:single_task)

      # Full → Operations: the first preview starts and is held on its own pool
      # connection while handle_params can still use another.
      render_change(view, "select_export_type", %{"export" => %{"type" => "operations"}})

      task =
        receive do
          {:preview_query, 1, task} -> task
        after
          15_000 -> flunk("the first preview never issued its run query")
        end

      # Back to Full while the first preview is still held: nothing to show.
      render_change(view, "select_export_type", %{"export" => %{"type" => "full"}})
      send(task, :resume)

      html = render_async(view, 2_000)
      refute count(html, "#export-tile-garages") > 0

      # Operations-only in the same visit reuses the task already started. The
      # async settles before the counter is read, so a second task cannot hide
      # behind a scheduling race.
      render_change(view, "select_export_type", %{"export" => %{"type" => "operations_only"}})
      _ = render_async(view, 2_000)

      refute_received {:preview_query, 2, _pid}
      assert :counters.get(counter, 1) == 1
    end

    test "a ready operations broadcast refreshes the preview while Full is selected", context do
      %{repo: repo} = context
      committed = committed_world()

      {:ok, run} =
        ExportRuns.create_pending(
          committed.organization.id,
          committed.version.id,
          %{id: committed.user.id, email: committed.user.email},
          :operations_only
        )

      {:ok, view, _html} =
        live(
          log_in_user(context.conn, committed.user, organization: committed.organization),
          export_path(committed.version) <> "?type=full"
        )

      bind_liveview_repo(view, repo)
      render_change(view, "select_export_type", %{"export" => %{"type" => "operations_only"}})
      _ = render_async(view, 2_000)
      assert has_element?(view, "#export-tile-garages", "0")

      render_change(view, "select_export_type", %{"export" => %{"type" => "full"}})
      garage_fixture(committed.organization.id)

      ready = mark_ready(run)
      send(view.pid, {:export_run_changed, ready.id})
      _ = :sys.get_state(view.pid)

      _ = render_async(view, 2_000)
      render_change(view, "select_export_type", %{"export" => %{"type" => "operations_only"}})

      assert has_element?(view, "#export-tile-garages", "1")
      assert has_element?(view, "#export-inventory tbody tr", "stops_supplement.txt 1")
    end
  end

  describe "the preview fallback" do
    setup :committed_pool
    setup :short_snapshot_deadline

    test "a combined operations timeout discloses an unavailable inventory", context do
      assert_snapshot_deadline_inventory(context, "operations", 3)
    end

    test "an operations-only timeout discloses an unavailable inventory", context do
      assert_snapshot_deadline_inventory(context, "operations_only", 4)
    end
  end

  # -- committed pool ---------------------------------------------------------

  defp assert_snapshot_deadline_inventory(context, export_type, error_tiles) do
    committed = committed_world()

    {:ok, view, _html} =
      live(
        log_in_user(context.conn, committed.user, organization: committed.organization),
        export_path(committed.version) <> "?type=full"
      )

    # The connected LiveView, and therefore the preview task it spawns, reads
    # through the dedicated committed pool rather than the shared sandbox
    # connection, so the deadline closes only the dedicated connection.
    bind_liveview_repo(view, context.repo)

    _counter = attach_preview_barrier({:deadline, export_type})

    render_change(view, "select_export_type", %{"export" => %{"type" => export_type}})

    task =
      receive do
        {:preview_query, 1, task} -> task
      after
        15_000 -> flunk("the preview never reached its run query")
      end

    # Let the deadline pass before releasing the held query, so the snapshot
    # transaction is already closed when the preview resumes.
    Process.send_after(task, :resume, 600)

    html = render_async(view, 2_000)
    assert count(html, "#export-metrics [id$='-error']") == error_tiles
    assert has_element?(view, "#export-tile-garages-error", "Couldn’t count")
    assert has_element?(view, "#export-files summary", "File count unavailable")
    assert has_element?(view, "#export-inventory-unavailable", "couldn’t be counted")
    refute has_element?(view, "#export-files", "nothing left out")
    refute has_element?(view, "#export-empty-inventory")
    refute has_element?(view, "#start-export[disabled]")
  end

  defp mark_ready(run) do
    now = DateTime.utc_now()

    run
    |> Run.system_changeset(%{
      state: :ready,
      started_at: DateTime.add(now, -1, :second),
      finished_at: now,
      artifact_key: "exports/#{run.id}.zip",
      artifact_filename: "tods-#{run.id}.zip",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1,
      artifact_expires_at: DateTime.add(now, 3_600, :second)
    })
    |> Repo.update!()
  end

  defp short_snapshot_deadline(_context) do
    previous = Application.fetch_env(:gtfs_planner, :export_snapshot_timeout_ms)
    Application.put_env(:gtfs_planner, :export_snapshot_timeout_ms, 200)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :export_snapshot_timeout_ms, value)
        :error -> Application.delete_env(:gtfs_planner, :export_snapshot_timeout_ms)
      end
    end)

    :ok
  end

  # Bind the connected LiveView process (and the preview task it later spawns)
  # to the dedicated committed pool. `:sys.replace_state/2` runs the callback in
  # the LiveView process, where the dynamic repo is process-local.
  defp bind_liveview_repo(view, repo) do
    :sys.replace_state(view.pid, fn state ->
      Repo.put_dynamic_repo(repo)
      state
    end)
  end

  # A dedicated pool for the test process, the LiveView and its preview task.
  # Its connections are the ones the snapshot deadline closes; the sandboxed
  # default pool is not touched, so the sandbox owner survives.
  defp committed_pool(_context) do
    repo =
      start_supervised!(
        {Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 4, log: false}
      )

    Repo.put_dynamic_repo(repo)

    previous_snapshot = Application.fetch_env(:gtfs_planner, :gtfs_export_snapshot)

    Application.put_env(
      :gtfs_planner,
      :gtfs_export_snapshot,
      GtfsPlanner.Gtfs.Export.Snapshot.Repo
    )

    on_exit(fn ->
      case previous_snapshot do
        {:ok, value} -> Application.put_env(:gtfs_planner, :gtfs_export_snapshot, value)
        :error -> Application.delete_env(:gtfs_planner, :gtfs_export_snapshot)
      end
    end)

    %{repo: repo}
  end

  # Committed records for the one page a timeout case opens. They are created
  # through the dedicated pool and removed child-first on exit.
  defp committed_world do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(r in Run, where: r.organization_id == ^organization.id))

        delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^organization.id))

        Repo.delete_all(
          from(m in UserOrgMembership, where: m.organization_id == ^organization.id)
        )

        Repo.delete_all(from(u in User, where: u.id == ^user.id))
        Repo.delete_all(from(o in Organization, where: o.id == ^organization.id))
      end)
    end)

    %{user: user, organization: organization, version: version}
  end
end
