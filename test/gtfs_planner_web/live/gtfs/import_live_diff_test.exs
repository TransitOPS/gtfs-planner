defmodule GtfsPlannerWeb.Gtfs.ImportLiveDiffTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeRuns

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    version = gtfs_version_fixture(organization.id)

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    %{conn: conn, view: view, organization: organization, version: version}
  end

  test "the route stages uploads, starts the real runner, and reattaches its persisted review", %{
    conn: conn,
    view: view,
    organization: organization,
    version: version
  } do
    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nRECONNECT,1.0,Durable")
    await_change_task(view)

    assert %{state: :review, gtfs_version_id: version_id} =
             ChangeRuns.latest_for_version(organization.id, version.id)

    assert version_id == version.id
    assert has_element?(view, "#diff-decisions [data-version-diff-row]")

    assert has_element?(
             view,
             "button[phx-click='approve-decision'][phx-value-id='level:RECONNECT']"
           )

    {:ok, reconnected, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(reconnected, "#diff-decisions [data-version-diff-row]")

    assert has_element?(
             reconnected,
             "button[phx-click='approve-decision'][phx-value-id='level:RECONNECT']"
           )
  end

  test "persists approval and applies through the scoped runner without retargeting the route version",
       %{
         view: view,
         organization: organization,
         version: version
       } do
    published_elsewhere = gtfs_version_fixture(organization.id)

    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nDURABLE,2.0,Applied")
    await_change_task(view)

    view
    |> element("button[phx-click='approve-decision'][phx-value-id='level:DURABLE']")
    |> render_click()

    assert has_element?(view, "#diff-apply-btn", "Apply Approved (1)")

    assert [%{status: :approved}] =
             ChangeRuns.latest_for_version(organization.id, version.id)
             |> then(&ChangeRuns.list_decisions(organization.id, &1.id))

    view |> element("#diff-apply-btn") |> render_click()
    await_change_task(view)

    assert Gtfs.get_level_by_level_id(organization.id, version.id, "DURABLE")
    refute Gtfs.get_level_by_level_id(organization.id, published_elsewhere.id, "DURABLE")
    assert has_element?(view, "#diff-reset-btn")
  end

  test "a pending durable review exposes a reconnect-safe cancellation action", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    actor = %{id: Ecto.UUID.generate(), email: "reviewer@example.com"}
    assert {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, actor, [])

    {:ok, reconnected, _html} = live(conn, "/gtfs/#{version.id}/import")
    assert has_element?(reconnected, "#diff-run-state[data-state='pending_compute']")

    reconnected |> element("#diff-cancel-btn") |> render_click()
    assert %{state: :cancelled} = ChangeRuns.get_for_version(organization.id, version.id, run.id)
  end

  test "storage failures render a recoverable blocker instead of crashing", %{view: view} do
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, nil)

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nL1,1.0,One")

    assert has_element?(view, "#diff-blockers", "Artifact storage unavailable")
    assert has_element?(view, "#diff-choose-corrected-files")
  end

  test "malformed, duplicate, nested, and oversized inputs remain bounded and recoverable", %{
    conn: conn,
    view: view,
    organization: organization,
    version: version
  } do
    submit_diff(view, "levels.txt", "level_index,level_name\n1.0,Missing ID")
    await_change_task(view)
    assert has_element?(view, "#diff-degraded-region", "missing natural key header")

    duplicate_zip =
      zip!([
        {~c"first/levels.txt", "level_id,level_index,level_name\nL1,1.0,One"},
        {~c"second/levels.txt", "level_id,level_index,level_name\nL2,2.0,Two"}
      ])

    duplicate_version = gtfs_version_fixture(organization.id)
    {:ok, duplicate_view, _html} = live(conn, "/gtfs/#{duplicate_version.id}/import")
    submit_diff(duplicate_view, "duplicate.zip", duplicate_zip)
    await_change_task(duplicate_view)
    assert has_element?(duplicate_view, "#diff-degraded-region", "duplicate entity file")

    inner_zip = zip!([{~c"levels.txt", "level_id,level_index,level_name\nL1,1.0,One"}])
    nested_zip = zip!([{~c"inner.zip", inner_zip}])

    nested_version = gtfs_version_fixture(organization.id)
    {:ok, nested_view, _html} = live(conn, "/gtfs/#{nested_version.id}/import")
    submit_diff(nested_view, "nested.zip", nested_zip)
    await_change_task(nested_view)
    assert has_element?(nested_view, "#diff-degraded-region", "nested archive")

    previous_limit = Application.get_env(:gtfs_planner, :import_max_zip_uncompressed_bytes)
    Application.put_env(:gtfs_planner, :import_max_zip_uncompressed_bytes, 10)

    on_exit(fn ->
      if previous_limit,
        do:
          Application.put_env(:gtfs_planner, :import_max_zip_uncompressed_bytes, previous_limit),
        else: Application.delete_env(:gtfs_planner, :import_max_zip_uncompressed_bytes)
    end)

    oversized_zip =
      zip!([{~c"levels.txt", "level_id,level_index,level_name\nLARGE,1.0,Oversized"}])

    oversized_version = gtfs_version_fixture(organization.id)
    {:ok, oversized_view, _html} = live(conn, "/gtfs/#{oversized_version.id}/import")
    submit_diff(oversized_view, "oversized.zip", oversized_zip)
    await_change_task(oversized_view)
    assert has_element?(oversized_view, "#diff-degraded-region", "archive too large")

    assert ChangeRuns.latest_for_version(organization.id, version.id)
  end

  test "dependency-tainted preview decisions cannot be approved or applied", %{view: view} do
    archive =
      zip!([
        {~c"levels.txt", "level_index,level_name\n0.0,Missing ID"},
        {~c"stops.txt",
         "stop_id,stop_name,stop_lat,stop_lon,location_type,level_id\nS1,Stop,40.0,-74.0,0,L1"},
        {~c"pathways.txt",
         "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional\nP1,S1,S1,1,1"}
      ])

    submit_diff(view, "tainted.zip", archive)
    await_change_task(view)

    assert has_element?(view, "#diff-preview-region")
    refute has_element?(view, "button[phx-value-id='stop:S1']")
    refute has_element?(view, "button[phx-value-id='pathway:P1']")

    render_click(view, "approve-decision", %{"id" => "stop:S1"})
    render_click(view, "apply-decisions")
    refute has_element?(view, "button[phx-value-id='stop:S1']")
  end

  test "filters and decision actions expose pressed state and recover from an empty filter", %{
    view: view
  } do
    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nFILTER,1.0,Filter")
    await_change_task(view)

    assert has_element?(view, "#diff-filter-all[aria-pressed='true']")
    refute has_element?(view, "#diff-filter-all[role='tab']")

    view |> element("#diff-filter-remove") |> render_click()
    assert has_element?(view, "#diff-filter-remove[aria-pressed='true']")
    refute has_element?(view, "#diff-decisions [data-version-diff-row]")

    view |> element("#diff-filter-all") |> render_click()

    approve = "button[phx-click='approve-decision'][phx-value-id='level:FILTER']"
    reject = "button[phx-click='reject-decision'][phx-value-id='level:FILTER']"
    assert has_element?(view, "#{approve}[aria-pressed='false']")

    view |> element(approve) |> render_click()
    assert has_element?(view, "#{approve}[aria-pressed='true']")

    view |> element(reject) |> render_click()
    assert has_element?(view, "#{reject}[aria-pressed='true']")
  end

  test "duplicate, unknown, and foreign decision events fail closed", %{
    view: view,
    organization: organization,
    version: version
  } do
    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nSAFE,1.0,Safe")
    await_change_task(view)
    run = ChangeRuns.latest_for_version(organization.id, version.id)

    render_click(view, "approve-decision", %{"id" => "level:UNKNOWN"})
    assert has_element?(view, "#diff-apply-btn", "Apply Approved (0)")

    other_organization = organization_fixture()

    assert {:error, :not_found} =
             ChangeRuns.set_decision_status(
               other_organization.id,
               run.id,
               "level:SAFE",
               :approved
             )

    view
    |> element("button[phx-click='approve-decision'][phx-value-id='level:SAFE']")
    |> render_click()

    render_click(view, "approve-decision", %{"id" => "level:SAFE"})
    assert has_element?(view, "#diff-apply-btn", "Apply Approved (1)")
  end

  test "stale conflicts surface exact partial counts and a retry action", %{
    view: view,
    organization: organization,
    version: version
  } do
    stop_fixture(organization.id, version.id, %{stop_id: "STALE", stop_name: "Original"})

    submit_diff(
      view,
      "stops.txt",
      "stop_id,stop_name,stop_lat,stop_lon,location_type\nSTALE,Reviewed,40.0,-74.0,0"
    )

    await_change_task(view)

    view
    |> element("button[phx-click='approve-decision'][phx-value-id='stop:STALE']")
    |> render_click()

    current = Gtfs.get_stop_by_stop_id(organization.id, version.id, "STALE")
    assert {:ok, _changed} = Gtfs.import_update_stop(current, %{stop_name: "Drifted"})

    view |> element("#diff-apply-btn") |> render_click()
    await_change_task(view)

    assert has_element?(view, "#diff-run-state[data-state='partial']")
    assert has_element?(view, "#diff-run-counts", "Applied 0 · Failed 1 · Unapplied 0")
    assert has_element?(view, "#diff-retry-btn")
  end

  defp submit_diff(view, filename, content) do
    type = if Path.extname(filename) == ".zip", do: "application/zip", else: "text/plain"

    upload =
      file_input(view, "#diff-upload-form", :diff_files, [
        %{name: filename, content: content, type: type}
      ])

    render_upload(upload, filename)
    view |> form("#diff-upload-form") |> render_submit()
  end

  defp zip!(entries) do
    {:ok, {_name, zip_binary}} = :zip.create(~c"review.zip", entries, [:memory])
    zip_binary
  end

  defp await_change_task(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    render(view)
  end
end
