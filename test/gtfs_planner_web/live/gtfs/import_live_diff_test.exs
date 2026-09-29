defmodule GtfsPlannerWeb.Gtfs.ImportLiveDiffTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Repo

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
    assert has_element?(view, "#diff-decisions [data-review-row]")

    assert has_element?(
             view,
             "button[phx-click='approve-decision'][phx-value-id='level:RECONNECT']"
           )

    {:ok, reconnected, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(reconnected, "#diff-decisions [data-review-row]")

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

    assert has_element?(view, "#diff-apply-btn", "Apply 1 change")

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

    # The stopped review says so and offers the retry and a way to start over.
    assert has_element?(
             reconnected,
             "#diff-run-state[data-state='cancelled']",
             "The review was cancelled"
           )

    assert has_element?(reconnected, "#diff-retry-btn", "Retry review")
    assert has_element?(reconnected, "#diff-start-over-btn", "Choose corrected files")
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

    assert has_element?(
             view,
             "#diff-degraded-region",
             "levels.txt: the file is missing its ID column."
           )

    duplicate_zip =
      zip!([
        {~c"first/levels.txt", "level_id,level_index,level_name\nL1,1.0,One"},
        {~c"second/levels.txt", "level_id,level_index,level_name\nL2,2.0,Two"}
      ])

    duplicate_version = gtfs_version_fixture(organization.id)
    {:ok, duplicate_view, _html} = live(conn, "/gtfs/#{duplicate_version.id}/import")
    submit_diff(duplicate_view, "duplicate.zip", duplicate_zip)
    await_change_task(duplicate_view)

    assert has_element?(
             duplicate_view,
             "#diff-degraded-region",
             "More than one levels.txt was included."
           )

    inner_zip = zip!([{~c"levels.txt", "level_id,level_index,level_name\nL1,1.0,One"}])
    nested_zip = zip!([{~c"inner.zip", inner_zip}])

    nested_version = gtfs_version_fixture(organization.id)
    {:ok, nested_view, _html} = live(conn, "/gtfs/#{nested_version.id}/import")
    submit_diff(nested_view, "nested.zip", nested_zip)
    await_change_task(nested_view)

    assert has_element?(
             nested_view,
             "#diff-degraded-region",
             "nested.zip: the zip contains another zip."
           )

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

    assert has_element?(
             oversized_view,
             "#diff-degraded-region",
             "oversized.zip: the zip is too large once unpacked."
           )

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
    refute has_element?(view, "#diff-decisions [data-review-row]")

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
    assert has_element?(view, "#diff-apply-btn", "Apply changes")

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
    assert has_element?(view, "#diff-apply-btn", "Apply 1 change")
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
    assert has_element?(view, "#diff-count-applied", "0")
    assert has_element?(view, "#diff-count-failed", "1")
    assert has_element?(view, "#diff-count-unapplied", "0")
    assert has_element?(view, "#diff-retry-btn", "Retry 1 change")
    assert has_element?(view, "#diff-run-state", "0 changes were applied")
  end

  test "the list of everything bulk-approves only additions and changes; removals are approved from their own tab",
       %{view: view, organization: organization, version: version} do
    stop_fixture(organization.id, version.id, %{stop_id: "GONE", stop_name: "Gone"})

    submit_diff(
      view,
      "stops.txt",
      "stop_id,stop_name,stop_lat,stop_lon,location_type\nNEW,New,40.0,-74.0,0"
    )

    await_change_task(view)

    # All offers the safe kinds only.
    assert has_element?(view, "#diff-approve-all-add", "Approve all 1 added")
    refute has_element?(view, "#diff-approve-all-remove")
    refute has_element?(view, "#diff-approve-all-conflict")

    # The removal is approved from its own tab, under a note that says what it does.
    view |> element("#diff-filter-remove") |> render_click()
    assert has_element?(view, "#diff-filter-note", "Approving deletes them from the version.")
    assert has_element?(view, "#diff-approve-all-remove", "Approve all 1 removals")

    assert has_element?(
             view,
             "button[phx-click='approve-decision'][phx-value-id='stop:GONE'][aria-label='Approve removal: Stop GONE']",
             "Approve removal"
           )

    refute has_element?(view, "#diff-consequence")

    view |> element("#diff-approve-all-remove") |> render_click()

    # The apply bar names the removal and the count it will apply.
    assert has_element?(view, "#diff-consequence", "Includes 1 removal.")
    assert has_element?(view, "#diff-apply-btn", "Apply 1 change")
    assert has_element?(view, "#diff-approve-all-remove[disabled]", "All removals approved")
  end

  test "each change kind is counted and named for the reviewer", %{view: view} do
    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nADDED,1.0,Added")
    await_change_task(view)

    assert has_element?(view, "#diff-summary-add", "1")
    assert has_element?(view, "#diff-summary-modify", "0")
    assert has_element?(view, "#diff-summary-conflict", "0")
    assert has_element?(view, "#diff-summary-remove", "0")

    assert has_element?(view, "#diff-filter-add", "Added")
    assert has_element?(view, "#diff-filter-conflict", "Edited here")
    assert has_element?(view, "#diff-review-summary", "Approve at least one change to apply.")

    view
    |> element("button[phx-click='approve-decision'][phx-value-id='level:ADDED']")
    |> render_click()

    assert has_element?(view, "#diff-review-summary", "1 of 1 changes approved.")
  end

  test "a partial run offers Start over, which returns to upload and survives a reload", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    insert_run!(organization, version, :partial)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(view, "#diff-run-state[data-state='partial']")
    assert has_element?(view, "#diff-retry-btn")
    assert has_element?(view, "#diff-partial-note", "Applied changes stay in this version.")

    select_diff_file(view, "levels.txt", "level_id,level_index,level_name\nL1,1.0,One")
    assert has_element?(view, "#diff-compute-btn[disabled]")

    view |> element("#diff-start-over-btn") |> render_click()

    refute has_element?(view, "#diff-run-state")
    select_diff_file(view, "levels.txt", "level_id,level_index,level_name\nL1,1.0,One")
    assert has_element?(view, "#diff-compute-btn:not([disabled])")

    {:ok, reloaded, _html} = live(conn, "/gtfs/#{version.id}/import")

    refute has_element?(reloaded, "#diff-run-state")
    select_diff_file(reloaded, "levels.txt", "level_id,level_index,level_name\nL1,1.0,One")
    assert has_element?(reloaded, "#diff-compute-btn:not([disabled])")
  end

  test "a failed run offers Start over, which returns to upload and survives a reload", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    insert_run!(organization, version, :failed, %{failure_code: "parse_failed"})
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(view, "#diff-run-state[data-state='failed']")
    refute has_element?(view, "#diff-partial-note")

    view |> element("#diff-start-over-btn") |> render_click()

    refute has_element?(view, "#diff-run-state")

    {:ok, reloaded, _html} = live(conn, "/gtfs/#{version.id}/import")
    refute has_element?(reloaded, "#diff-run-state")
  end

  test "a new diff computes after starting over from a partial run", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    partial = insert_run!(organization, version, :partial)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    view |> element("#diff-start-over-btn") |> render_click()
    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nRESTART,1.0,Restart")
    await_change_task(view)

    assert has_element?(view, "#diff-decisions [data-review-row]")

    assert %{state: :review, id: new_id} =
             ChangeRuns.latest_for_version(organization.id, version.id)

    refute new_id == partial.id

    assert %{state: :cancelled} =
             ChangeRuns.get_for_version(organization.id, version.id, partial.id)

    {:ok, reloaded, _html} = live(conn, "/gtfs/#{version.id}/import")
    assert has_element?(reloaded, "#diff-decisions [data-review-row]")
  end

  test "a partial run lists each failed decision with a plain reason", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    run = insert_run!(organization, version, :partial)
    insert_decision!(run, "DRIFT", %{status: :stale, apply_failure_code: "drifted"})

    insert_decision!(run, "DEPENDENT", %{
      status: :failed,
      apply_failure_code: "dependencies_unmet",
      action: :add
    })

    insert_decision!(run, "ODD", %{status: :failed, apply_failure_code: "apply_failed"})
    insert_decision!(run, "DONE", %{status: :applied, apply_failure_code: nil})

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(
             view,
             "#diff-failed-decisions li[data-decision-id='stop:DRIFT']",
             "Changed since the review was computed"
           )

    assert has_element?(
             view,
             "#diff-failed-decisions li[data-decision-id='stop:DRIFT']",
             "modify"
           )

    assert has_element?(view, "#diff-failed-decisions li[data-decision-id='stop:DRIFT']", "DRIFT")

    assert has_element?(
             view,
             "#diff-failed-decisions li[data-decision-id='stop:DEPENDENT']",
             "Depends on a change that was not applied"
           )

    assert has_element?(
             view,
             "#diff-failed-decisions li[data-decision-id='stop:ODD']",
             "Could not be applied"
           )

    refute has_element?(view, "#diff-failed-decisions li[data-decision-id='stop:DONE']")
  end

  test "a removal row states what still uses the stop and omits the line when nothing does", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    stop_fixture(organization.id, version.id, %{stop_id: "central"})
    stop_fixture(organization.id, version.id, %{stop_id: "lonely"})
    stop_time_fixture(organization.id, version.id, "T1", "central")
    stop_time_fixture(organization.id, version.id, "T2", "central")

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: "central",
      to_stop_id: "central"
    })

    run = insert_run!(organization, version, :review, %{finished_at: nil})
    central = insert_removal!(run, :stop, "central")
    lonely = insert_removal!(run, :stop, "lonely")

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(
             view,
             "#diff-decision-dependents-#{central.id}",
             "Used by 2 stop times and 1 transfer. Removal will be refused while they exist."
           )

    refute has_element?(view, "#diff-decision-dependents-#{lonely.id}")
    assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='stop:central']")
  end

  test "a level removal row states how many stops use the level", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    level_fixture(organization.id, version.id, %{level_id: "L1"})
    stop_fixture(organization.id, version.id, %{stop_id: "platform-a", level_id: "L1"})
    stop_fixture(organization.id, version.id, %{stop_id: "platform-b", level_id: "L1"})

    run = insert_run!(organization, version, :review, %{finished_at: nil})
    level = insert_removal!(run, :level, "L1")

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(
             view,
             "#diff-decision-dependents-#{level.id}",
             "Used by 2 stops. Removal will be refused while they exist."
           )
  end

  test "an approved removal of a stop that trips use is listed as failed with its reason", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    stop_fixture(organization.id, version.id, %{stop_id: "central"})
    stop_time_fixture(organization.id, version.id, "T1", "central")

    run = insert_run!(organization, version, :review, %{finished_at: nil})
    insert_removal!(run, :stop, "central")

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    view
    |> element("button[phx-click='approve-decision'][phx-value-id='stop:central']")
    |> render_click()

    view |> element("#diff-apply-btn") |> render_click()
    await_change_task(view)

    assert Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

    assert has_element?(
             view,
             "#diff-failed-decisions li[data-decision-id='stop:central']",
             "Still used by trips, transfers, pathways or other records in this version"
           )
  end

  test "the failed decision list stops at 50 and counts the rest", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    run = insert_run!(organization, version, :partial)
    insert_failed_decisions!(run, 52)

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(view, "#diff-failed-decisions li[data-decision-id='stop:S049']")
    refute has_element?(view, "#diff-failed-decisions li[data-decision-id='stop:S050']")
    assert has_element?(view, "#diff-failed-decisions-more", "and 2 more")
  end

  test "Start over is not offered while a run is computing", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    insert_run!(organization, version, :computing)

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(view, "#diff-run-state[data-state='computing']")
    refute has_element?(view, "#diff-start-over-btn")
  end

  test "Start over is not offered while a run is applying", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    insert_run!(organization, version, :applying)

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(view, "#diff-run-state[data-state='applying']")
    refute has_element?(view, "#diff-start-over-btn")
  end

  test "a crafted Start over event leaves a running review in place", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    run = insert_run!(organization, version, :computing)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    render_click(view, "start-over-diff")

    assert has_element?(view, "#diff-run-state[data-state='computing']")
    assert %{state: :computing} = ChangeRuns.get_for_version(organization.id, version.id, run.id)
  end

  defp select_diff_file(view, filename, content) do
    type = if Path.extname(filename) == ".zip", do: "application/zip", else: "text/plain"

    view
    |> file_input("#diff-upload-form", :diff_files, [
      %{name: filename, content: content, type: type}
    ])
    |> render_upload(filename)
  end

  defp submit_diff(view, filename, content) do
    select_diff_file(view, filename, content)
    view |> form("#diff-upload-form") |> render_submit()
  end

  defp insert_run!(organization, version, state, attrs \\ %{}) do
    now = DateTime.utc_now()

    %ChangeRun{}
    |> ChangeRun.system_changeset(
      %{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: Ecto.UUID.generate(),
        actor_email: "reviewer@example.com",
        state: state,
        phase: :cleanup,
        summary: %{"applied" => 1, "failed" => 1, "unapplied" => 0}
      }
      |> Map.merge(run_timing(state, now))
      |> Map.merge(attrs)
    )
    |> Repo.insert!()
  end

  defp run_timing(state, now) when state in [:computing, :applying] do
    %{
      started_at: now,
      lease_token: Ecto.UUID.generate(),
      lease_expires_at: DateTime.add(now, 300, :second)
    }
  end

  defp run_timing(_terminal_state, now), do: %{started_at: now, finished_at: now}

  defp insert_decision!(run, key, attrs) do
    %ChangeDecision{}
    |> ChangeDecision.system_changeset(
      Map.merge(
        %{
          change_run_id: run.id,
          decision_id: "stop:#{key}",
          entity_type: :stop,
          action: :modify,
          status: :stale,
          natural_key: key,
          apply_failure_code: "drifted"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_removal!(run, entity_type, key) do
    insert_decision!(run, key, %{
      decision_id: "#{entity_type}:#{key}",
      entity_type: entity_type,
      action: :remove,
      status: :pending,
      apply_failure_code: nil
    })
  end

  defp insert_failed_decisions!(run, count) do
    Enum.each(0..(count - 1), fn index ->
      key = "S" <> String.pad_leading(Integer.to_string(index), 3, "0")
      insert_decision!(run, key, %{})
    end)
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
