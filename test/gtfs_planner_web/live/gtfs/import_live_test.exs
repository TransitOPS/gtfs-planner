defmodule GtfsPlannerWeb.Gtfs.ImportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.Import.{
    ChangeRun,
    ChangeRuns,
    Failure,
    Recovery,
    Result,
    Run,
    SourceStorage
  }

  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @levels_content "level_id,level_index,level_name\nL1,0.0,Ground"
  @stops_content "stop_id,stop_name,stop_lat,stop_lon,level_id\nS1,Stop 1,1.0,1.0,L1"

  # The agency findings block's feed: two routes and one stop, so the published
  # version has routes for `FeedSettings.agency_health/2` to report, and no
  # agency unless the case adds an agency.txt of its own (AC-27).
  @findings_routes_content "route_id,route_short_name,route_long_name,route_type\n" <>
                             "R1,1,First Route,3\n" <>
                             "R2,2,Second Route,3"
  @findings_stops_content "stop_id,stop_name,stop_lat,stop_lon\nS1,Stop 1,42.36,-71.05"
  @findings_one_agency_content "agency_id,agency_name,agency_url,agency_timezone\n" <>
                                 "NCT,North Coast Transit,https://northcoast.example,America/New_York"
  @findings_two_zone_agencies_content "agency_id,agency_name,agency_url,agency_timezone\n" <>
                                        "NCT,North Coast Transit,https://northcoast.example,America/New_York\n" <>
                                        "HBR,Harbor Shuttle,https://harbor.example,America/Chicago"
  @findings_invalid_zone_agency_content "agency_id,agency_name,agency_url,agency_timezone\n" <>
                                          "NCT,North Coast Transit,https://northcoast.example,Mars/Olympus"

  defmodule BlockingCleanupWorker do
    def run(organization_id, run_id, lease_token) do
      owner = Application.fetch_env!(:gtfs_planner, :blocking_cleanup_worker_owner)
      send(owner, {:blocking_cleanup_worker_started, self()})

      receive do
        :continue ->
          Recovery.run(organization_id, run_id, lease_token)
      end
    end
  end

  defp editor_context(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, gtfs_version: gtfs_version}
  end

  # Deterministically wait for the supervised publication task to finish, then
  # flush the LiveView mailbox by rendering. No sleeps: we monitor the task
  # process and assert on its DOWN message. The supervised Runner broadcasts
  # `{:import_run_changed, run_id}` only after the task exits, so we re-render
  # until the LiveView has applied the terminal transition (the "Importing"
  # CTA returns to idle) rather than racing the broadcast.
  defp await_import_task(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    # The runner supervisor admits one import, so the next start needs this one gone.
    GtfsPlanner.Support.RunnerSlots.await_idle()
    await_import_settled(view, 100)
  end

  defp await_import_settled(view, 0), do: render(view)

  defp await_import_settled(view, tries) do
    html = render(view)

    if html =~ "Importing" do
      await_import_settled(view, tries - 1)
    else
      html
    end
  end

  defp await_cleanup_task(view) do
    runner_pids =
      GtfsPlanner.Gtfs.Import.RunnerSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_, pid, _, _} -> pid end)

    for pid <- runner_pids do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    await_cleanup_settled(view, 100)
  end

  defp await_cleanup_settled(view, 0), do: render(view)

  defp await_cleanup_settled(view, tries) do
    state = :sys.get_state(view.pid)

    if state.socket.assigns.processing_discard do
      await_cleanup_settled(view, tries - 1)
    else
      render(view)
    end
  end

  defp put_socket_assigns(view, assigns) do
    :sys.replace_state(view.pid, fn
      %{socket: socket} = state ->
        %{state | socket: %{socket | assigns: Map.merge(socket.assigns, Map.new(assigns))}}

      state ->
        state
    end)
  end

  defp upload_gtfs(view, files) do
    view
    |> file_input("#gtfs-import-form", :gtfs_files, files)
    |> then(fn upload ->
      Enum.each(files, fn %{name: name} -> render_upload(upload, name) end)
      upload
    end)
  end

  # A single .zip entry bundles multiple GTFS files. The LiveView test harness
  # only reliably consumes one upload channel per submit, and the importer
  # expands the archive, so a zip is the deterministic way to import several
  # files in one submission.
  defp gtfs_zip(entries) do
    zip_entries = Enum.map(entries, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"gtfs.zip", zip_entries, [:memory])
    %{name: "gtfs.zip", content: binary, type: "application/zip"}
  end

  defp submit_import(view, version_name) do
    view
    |> form("#gtfs-import-form", %{"gtfs_import_form" => %{"version_name" => version_name}})
    |> render_submit()
  end

  defp published_versions(organization_id) do
    Versions.list_gtfs_versions(organization_id)
  end

  defp version_by_name(organization_id, name) do
    Enum.find(all_versions(organization_id), &(&1.name == name))
  end

  defp all_versions(organization_id) do
    import Ecto.Query

    GtfsPlanner.Repo.all(
      from(v in GtfsPlanner.Versions.GtfsVersion, where: v.organization_id == ^organization_id)
    )
  end

  describe "page + version boundary" do
    setup :editor_context

    test "displays import page with valid version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/import")

      assert html =~ "Import data"
      assert html =~ "Feed files"
      assert html =~ "One .zip, or up to 50 .txt or .csv files"
    end

    test "redirects with error for invalid version UUID", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      conn = log_in_user(conn, user, organization: organization)
      invalid_uuid = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
               live(conn, "/gtfs/#{invalid_uuid}/import")
    end

    test "redirects with error for version from different organization", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      conn = log_in_user(conn, user, organization: organization)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
               live(conn, "/gtfs/#{other_version.id}/import")
    end
  end

  describe "version switching" do
    setup :editor_context

    test "switch_gtfs_version navigates to published version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version1
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, version2} = Versions.create_gtfs_version(organization.id, %{name: "V2"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version1.id}/import")

      render_hook(view, "switch_gtfs_version", %{"version" => to_string(version2.id)})

      assert_redirect(view, "/gtfs/#{version2.id}/import")
    end

    test "crafted version events do not navigate to unavailable versions", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version1
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_org = organization_fixture()
      foreign = gtfs_version_fixture(other_org.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version1.id}/import")

      for bad_id <- [to_string(staging.id), to_string(foreign.id), "not-a-uuid"] do
        render_hook(view, "switch_gtfs_version", %{"version" => bad_id})
        refute_redirected(view)

        render_hook(view, "gtfs_version_loaded", %{"version_id" => bad_id})
        refute_redirected(view)
      end
    end
  end

  describe "form + destination" do
    setup :editor_context

    test "renders required version name field and destination summary", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      assert has_element?(view, "#gtfs-import-version-name")
      assert has_element?(view, "#gtfs-import-reason", "Choose a feed file to import.")
      assert has_element?(view, "#gtfs-import-submit", "Import feed")
      assert render(view) =~ version.name
    end

    test "uses shared, labeled upload fields and task actions for both import paths", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      assert has_element?(view, "#gtfs-import-upload[data-upload-state='idle']")
      assert has_element?(view, "#gtfs-import-upload-label", "Feed files")
      assert has_element?(view, "#gtfs-import-upload-help")
      assert has_element?(view, "#diff-upload[data-upload-state='idle']")
      assert has_element?(view, "#diff-upload-label", "Station data files")
      assert has_element?(view, "#diff-upload-help")
      assert has_element?(view, "#diff-compute-btn[disabled]", "Review changes")
      assert has_element?(view, "#import-recovery-empty")
    end

    test "import button disabled with no files, enabled once a file is present", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      assert has_element?(view, "#gtfs-import-submit[disabled]")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      refute has_element?(view, "#gtfs-import-submit[disabled]")
    end

    test "blank name error appears only after the field is touched", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      refute render(view) =~ "Enter a name for the new version."

      view |> element("#gtfs-import-version-name") |> render_blur()

      view
      |> element("#gtfs-import-form")
      |> render_change(%{"gtfs_import_form" => %{"version_name" => ""}})

      assert render(view) =~ "Enter a name for the new version."
    end
  end

  describe "destination + state rendering" do
    setup :editor_context

    test "idle form names both the route version and the prospective destination", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/import")

      # Before any file is chosen the workspace already says a feed creates a new
      # version and leaves the current one alone.
      assert has_element?(view, "#import-workspace")
      assert html =~ "Creates a new version. #{version.name} isn’t changed."

      # The reviewed-diff destination separately names the existing-version target.
      assert has_element?(view, "#diff-destination", "Approved changes go into #{version.name}.")
    end

    test "version name input has a programmatic label and error association", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      # The shared input owns one alert container with a stable id.
      view |> element("#gtfs-import-version-name") |> render_blur()

      view
      |> element("#gtfs-import-form")
      |> render_change(%{"gtfs_import_form" => %{"version_name" => ""}})

      html = render(view)

      assert html =~ "id=\"gtfs-import-version-name-error\""
      assert html =~ ~r/aria-describedby="[^"]*gtfs-import-version-name-error"/
      assert html =~ ~r/aria-invalid="true"/
      assert html =~ "Enter a name for the new version."
    end

    test "primary CTA shows pending state and disables while publication is active", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      # The synchronous post-submit render reflects the in-flight publication:
      # the CTA is disabled and shows the pending label.
      html = submit_import(view, "Pending State")

      assert html =~ "Importing"
      assert has_element?(view, "#gtfs-import-submit[disabled]")

      # The polite live region is present to surface progress.
      assert html =~ ~r/id="gtfs-import-status"[^>]*aria-live="polite"/

      # After completion the CTA returns to its idle label.
      final = await_import_task(view)
      refute final =~ "Importing"
    end

    test "success announces the published version and links to it while keeping the diff destination",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: route_version
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([{"levels.txt", @levels_content}, {"stops.txt", @stops_content}])
      ])

      submit_import(view, "Announced Version")
      html = await_import_task(view)

      # The published outcome is announced in an assertive live region.
      assert has_element?(view, "#gtfs-import-result[aria-live='assertive']")
      assert has_element?(view, "#gtfs-import-result-title", "Imported “Announced Version”")
      assert html =~ "Announced Version"

      # View version is a navigation link to the published target.
      target = version_by_name(organization.id, "Announced Version")
      assert has_element?(view, "#gtfs-import-view-version[href='/gtfs/#{target.id}/routes']")

      # The route-version diff destination is preserved alongside the result.
      assert has_element?(view, "#diff-destination")
    end

    test "validation failure uses the shared input exactly once and preserves keyboard correction",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: route_version
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, existing} = Versions.create_gtfs_version(organization.id, %{name: "Taken"})

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      html = submit_import(view, existing.name)

      # One alert container associated with the field; no duplicate markup.
      assert length(Regex.scan(~r/id="gtfs-import-version-name-error"/, html)) == 1
      assert html =~ "You already have a version named “Taken”. Choose a different name."

      # The form is still keyboard-reachable for correction.
      assert has_element?(view, "#gtfs-import-version-name")
      assert has_element?(view, "#gtfs-import-submit")
    end

    test "validation failure pushes a first-error focus event for keyboard correction", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      view |> element("#gtfs-import-version-name") |> render_blur()

      view
      |> element("#gtfs-import-form")
      |> render_change(%{"gtfs_import_form" => %{"version_name" => ""}})

      # The server pushes a focus command (handled client-side by the colocated
      # .ImportErrorFocus hook) so assistive tech lands on the offending field.
      assert_push_event(view, "focus_first_error", %{selector: "#gtfs-import-version-name"})
    end
  end

  describe "valid full-feed import" do
    setup :editor_context

    test "creates one staging target, publishes it, and leaves the route version unchanged", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      before_count = length(all_versions(organization.id))
      route_published_at = route_version.published_at

      upload_gtfs(view, [
        gtfs_zip([{"levels.txt", @levels_content}, {"stops.txt", @stops_content}])
      ])

      submit_import(view, "Spring 2025")
      html = await_import_task(view)

      # Exactly one new version row was created.
      assert length(all_versions(organization.id)) == before_count + 1

      target = version_by_name(organization.id, "Spring 2025")
      assert target
      assert target.id != route_version.id
      assert target.publication_status == "published"
      assert target.published_at

      # Imported rows landed on the staging target, never the route version.
      assert Gtfs.get_level_by_level_id(organization.id, target.id, "L1")
      refute Gtfs.get_level_by_level_id(organization.id, route_version.id, "L1")

      # The route version is untouched and still published.
      route_after = Versions.get_gtfs_version_for_lifecycle(organization.id, route_version.id)
      assert route_after.publication_status == "published"
      assert route_after.published_at == route_published_at

      # Result names the target and links to it.
      assert html =~ "Imported “Spring 2025”"
      assert has_element?(view, "#gtfs-import-view-version[href='/gtfs/#{target.id}/routes']")
    end

    test "stale page context still creates a fresh target and never writes the route version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      # A newer version is published after the page mounted, making the page's
      # current_gtfs_version stale relative to the latest.
      {:ok, newer} = Versions.create_gtfs_version(organization.id, %{name: "Newer"})

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])
      submit_import(view, "Fresh Target")
      await_import_task(view)

      target = version_by_name(organization.id, "Fresh Target")
      assert target.id != route_version.id
      assert target.id != newer.id
      assert target.publication_status == "published"

      refute Gtfs.get_level_by_level_id(organization.id, route_version.id, "L1")
      refute Gtfs.get_level_by_level_id(organization.id, newer.id, "L1")
      assert Gtfs.get_level_by_level_id(organization.id, target.id, "L1")
    end
  end

  describe "create failure and retry" do
    setup :editor_context

    test "duplicate name preserves upload, creates no row/task, and retry creates one row", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, existing} = Versions.create_gtfs_version(organization.id, %{name: "Existing"})

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      before_count = length(all_versions(organization.id))
      html = submit_import(view, existing.name)

      # No lifecycle row was created and no task was started.
      assert length(all_versions(organization.id)) == before_count
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []
      assert html =~ "You already have a version named “Existing”"

      # The selected upload entry is preserved.
      assert has_element?(view, "button[phx-click='cancel-upload']")

      # Correcting the name creates exactly one staging row (then publishes).
      submit_import(view, "Corrected Name")
      await_import_task(view)

      assert length(all_versions(organization.id)) == before_count + 1
      target = version_by_name(organization.id, "Corrected Name")
      assert target.publication_status == "published"
    end

    test "blank name is rejected as a changeset error preserving the upload", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      before_count = length(all_versions(organization.id))
      submit_import(view, "")

      assert length(all_versions(organization.id)) == before_count
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []

      assert has_element?(
               view,
               "#gtfs-import-version-name-error",
               "Enter a name for the new version."
             )

      assert has_element?(view, "button[phx-click='cancel-upload']")
    end
  end

  describe "crafted submissions" do
    setup :editor_context

    test "empty-file submission is rejected without creating a version or task", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      before_count = length(all_versions(organization.id))

      # No uploads selected: craft the submit event directly.
      render_submit(element(view, "#gtfs-import-form"), %{
        "gtfs_import_form" => %{"version_name" => "No Files"}
      })

      assert length(all_versions(organization.id)) == before_count
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []
      assert render(view) =~ "Select at least one file"
    end

    test "already-active submission does not start a second task", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      # Simulate an import already in progress.
      put_socket_assigns(view, %{importing: true})

      before_count = length(all_versions(organization.id))
      submit_import(view, "Should Not Create")

      assert length(all_versions(organization.id)) == before_count
      refute version_by_name(organization.id, "Should Not Create")
    end
  end

  describe "admission before staging" do
    setup :editor_context
    setup :await_idle_runners

    test "claims the run before copying the upload and starts the worker only after install", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])
      attach_staging_probe(&__MODULE__.record_staging/4, organization)

      submit_import(view, "Ordered Import")
      await_import_task(view)

      assert_received {:staging_started, at_first_copy}
      assert at_first_copy.run_state == "running"
      assert at_first_copy.run_token == at_first_copy.runner_token
      assert at_first_copy.worker == nil

      target = version_by_name(organization.id, "Ordered Import")
      assert target.publication_status == "published"
      assert Gtfs.get_level_by_level_id(organization.id, target.id, "L1")
    end
  end

  describe "post-create staging failure" do
    setup :editor_context
    setup :await_idle_runners

    test "an upload set over the storage limit stays selected and can be resubmitted under the same name",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: route_version
         } do
      # A zero root budget makes `SourceStorage.stage/4` refuse every upload.
      put_application_env(:gtfs_task_artifacts_max_total_bytes, 0)
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      submit_import(view, "Consume Fail")
      GtfsPlanner.Support.RunnerSlots.await_idle()
      html = render(view)

      # The run is closed with nothing imported, and its empty version is gone.
      run = Repo.get_by!(Run, organization_id: organization.id, version_name: "Consume Fail")
      assert run.state == "failed"
      assert run.reason_code == "source_not_installed"
      assert is_nil(run.lease_token)
      refute version_by_name(organization.id, "Consume Fail")
      refute has_element?(view, "#import-run-#{run.id}")

      # No worker started, no rows written to any version, and nothing staged.
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []
      refute Gtfs.get_level_by_level_id(organization.id, route_version.id, "L1")

      {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
      refute File.exists?(run_dir)

      assert has_element?(view, "#gtfs-import-result", "“Consume Fail” wasn’t imported.")
      assert has_element?(view, "#gtfs-import-result", "exceed the import storage limit")
      assert html =~ "Upload fewer or smaller files."
      refute html =~ "couldn’t read the uploaded files"
      assert has_element?(view, "#gtfs-import-upload-entries", "levels.txt")

      # With room for the files, the same selection imports under the same name.
      Application.put_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes, 1024 * 1024 * 1024)
      submit_import(view, "Consume Fail")
      await_import_task(view)

      target = version_by_name(organization.id, "Consume Fail")
      assert target.publication_status == "published"
      assert Gtfs.get_level_by_level_id(organization.id, target.id, "L1")
      refute has_element?(view, "#gtfs-import-result", "wasn’t imported")
    end

    test "storage that cannot be written asks for the files again and drops the selection", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      # A root below a regular file cannot be created, so staging fails without a capacity error.
      blocker = Path.join(System.tmp_dir!(), "import-live-blocker-#{Ecto.UUID.generate()}")
      File.write!(blocker, "not a directory")
      on_exit(fn -> File.rm(blocker) end)
      put_application_env(:gtfs_task_artifacts_path, Path.join(blocker, "root"))

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      submit_import(view, "Unwritable")
      GtfsPlanner.Support.RunnerSlots.await_idle()
      html = render(view)

      run = Repo.get_by!(Run, organization_id: organization.id, version_name: "Unwritable")
      assert %Run{state: "failed", reason_code: "source_not_installed"} = run
      refute version_by_name(organization.id, "Unwritable")
      assert has_element?(view, "#gtfs-import-result", "couldn’t read the uploaded files")
      refute html =~ "exceed the import storage limit"
      refute has_element?(view, "#gtfs-import-upload-entries", "levels.txt")
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []
    end

    test "an install that arrives after the runner's deadline fails the import and removes the copy",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: route_version
         } do
      put_application_env(:import_source_install_timeout_ms, 50)
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])
      attach_staging_probe(&__MODULE__.await_runner_exit/4, organization)

      submit_import(view, "Too Slow")
      html = render(view)

      run = Repo.get_by!(Run, organization_id: organization.id, version_name: "Too Slow")
      assert %Run{state: "failed", reason_code: "source_not_installed"} = run
      refute version_by_name(organization.id, "Too Slow")

      {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
      refute File.exists?(run_dir)
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []
      assert has_element?(view, "#gtfs-import-result", "“Too Slow” wasn’t imported.")
      assert html =~ "couldn’t read the uploaded files"
      refute has_element?(view, "#gtfs-importing-card")
    end
  end

  describe "recovery UI" do
    setup :editor_context

    defp insert_run(organization_id, version, state, opts \\ []) do
      attrs =
        opts
        |> Keyword.merge(
          organization_id: organization_id,
          gtfs_version_id: version.id,
          version_name: version.name,
          state: state,
          committed_counts: Keyword.get(opts, :committed_counts, %{}),
          counts_complete: Keyword.get(opts, :counts_complete, true),
          failed_file: Keyword.get(opts, :failed_file),
          failed_row: Keyword.get(opts, :failed_row),
          finished_at: Keyword.get_lazy(opts, :finished_at, fn -> DateTime.utc_now() end)
        )
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      GtfsPlanner.Repo.insert!(struct(GtfsPlanner.Gtfs.Import.Run, attrs))
    end

    test "mount streams recoverable runs with stable ids and a distinct action per state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, failed_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "F1"})
      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      insert_run(organization.id, failed_v, "failed")

      {:ok, partial_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "P1"})
      {:ok, partial_v} = Versions.fail_unpublished_gtfs_version(organization.id, partial_v.id)

      insert_run(organization.id, partial_v, "partial",
        committed_counts: %{levels: 5, stops: 10},
        failed_file: "stops.txt",
        failed_row: 3
      )

      {:ok, inter_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "I1"})
      {:ok, inter_v} = Versions.fail_unpublished_gtfs_version(organization.id, inter_v.id)
      insert_run(organization.id, inter_v, "interrupted", counts_complete: false)

      {:ok, pubfail_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "PF1"})
      {:ok, pubfail_v} = Versions.claim_staging_gtfs_version(organization.id, pubfail_v.id)

      insert_run(organization.id, pubfail_v, "publication_failed",
        committed_counts: %{levels: 1},
        counts_complete: true
      )

      {:ok, view, html} = live(conn, "/gtfs/#{route_version.id}/import")

      # Stable streamed cards with stable ids per run.
      assert has_element?(view, "#import-recovery-runs")

      assert has_element?(
               view,
               "#import-run-#{GtfsPlanner.Repo.get_by(GtfsPlanner.Gtfs.Import.Run, version_name: "F1").id}"
             )

      assert has_element?(
               view,
               "#import-run-#{GtfsPlanner.Repo.get_by(GtfsPlanner.Gtfs.Import.Run, version_name: "P1").id}"
             )

      assert has_element?(
               view,
               "#import-run-#{GtfsPlanner.Repo.get_by(GtfsPlanner.Gtfs.Import.Run, version_name: "I1").id}"
             )

      assert has_element?(
               view,
               "#import-run-#{GtfsPlanner.Repo.get_by(GtfsPlanner.Gtfs.Import.Run, version_name: "PF1").id}"
             )

      # Each non-active state renders its distinct next action.
      assert html =~ "Discard failed import"
      assert html =~ "Publish version"
      # partial/failed/interrupted/cleanup_failed share discard only
      assert html =~ "we can’t tell how much was saved"
    end

    test "partial cards show durable counts and sanitized file/row; interrupted states uncertainty",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: route_version
         } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, partial_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Counts"})
      {:ok, partial_v} = Versions.fail_unpublished_gtfs_version(organization.id, partial_v.id)

      insert_run(organization.id, partial_v, "partial",
        committed_counts: %{levels: 5, stops: 12, pathways: 3},
        failed_file: "stops.txt",
        failed_row: 7
      )

      {:ok, inter_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Unc"})
      {:ok, inter_v} = Versions.fail_unpublished_gtfs_version(organization.id, inter_v.id)
      insert_run(organization.id, inter_v, "interrupted", counts_complete: false)

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      html = render(view)

      # Durable counts + sanitized file/row are shown, never raw internals.
      assert html =~ "5 levels"
      assert html =~ "12 stops"
      assert html =~ "3 pathways"
      assert html =~ "stops.txt"
      assert html =~ "row 7"

      # Interrupted states uncertainty, no counts rendered.
      assert html =~ "we can’t tell how much was saved"
      refute html =~ "inspect("
      refute html =~ "Ecto"
      refute html =~ ~s(SQL)
      refute html =~ "/tmp/"
    end

    test "discard confirms in a dialog naming the version, then focuses the upload", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, failed_v} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "ToDiscard"})

      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      # The confirmation stays closed until "Discard failed import" is clicked.
      assert has_element?(view, "#import-discard-dialog[data-open='false']")

      view
      |> element("#discard-#{run.id}")
      |> render_click()

      # Now the dialog names the version and the consequence, and its confirm
      # button repeats the verb and object.
      assert has_element?(view, "#import-discard-dialog[data-open='true']")
      assert has_element?(view, "#import-discard-dialog-body", "“ToDiscard” stopped before")
      assert has_element?(view, "#import-discard-dialog-confirm", "Delete failed version")
      assert has_element?(view, "#import-discard-dialog-cancel", "Keep version")

      # Confirming discards the failed version and removes the card.
      view
      |> element("#import-discard-dialog-confirm")
      |> render_click()

      await_cleanup_task(view)

      assert has_element?(view, "#import-recovery-empty")
      assert has_element?(view, "#import-discard-dialog[data-open='false']")

      # The removed version name is prefilled into the new-upload name field, and
      # the page says it deleted the version.
      assert has_element?(view, "#gtfs-import-version-name[value='ToDiscard']")

      assert has_element?(
               view,
               "#gtfs-import-discarded",
               "Deleted the failed version “ToDiscard”."
             )

      # Focus is pushed to the upload control.
      assert_push_event(view, "focus_gtfs_import_files", %{})

      # The failed version row is gone after cleanup.
      refute Versions.get_gtfs_version_for_lifecycle(organization.id, failed_v.id)
    end

    test "supervised discard completes after the initiating LiveView disconnects", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      previous_worker = Application.get_env(:gtfs_planner, :import_cleanup_worker_module)
      previous_owner = Application.get_env(:gtfs_planner, :blocking_cleanup_worker_owner)

      Application.put_env(:gtfs_planner, :import_cleanup_worker_module, BlockingCleanupWorker)
      Application.put_env(:gtfs_planner, :blocking_cleanup_worker_owner, self())

      on_exit(fn ->
        restore_application_env(:import_cleanup_worker_module, previous_worker)
        restore_application_env(:blocking_cleanup_worker_owner, previous_owner)
      end)

      {:ok, failed_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Detached cleanup"})

      {:ok, failed_version} =
        Versions.fail_unpublished_gtfs_version(organization.id, failed_version.id)

      run = insert_run(organization.id, failed_version, "failed")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      view |> element("#discard-#{run.id}") |> render_click()
      view |> element("#import-discard-dialog-confirm") |> render_click()

      assert_receive {:blocking_cleanup_worker_started, worker_pid}

      runner_pid =
        Enum.find_value(
          DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Import.RunnerSupervisor),
          fn {_, pid, _, _} ->
            if :sys.get_state(pid).task_pid == worker_pid, do: pid
          end
        )

      refute is_nil(runner_pid)

      view_pid = view.pid
      view_ref = Process.monitor(view_pid)
      GenServer.stop(view_pid)
      assert_receive {:DOWN, ^view_ref, :process, ^view_pid, _reason}

      assert :sys.get_state(runner_pid).task_pid == worker_pid

      worker_ref = Process.monitor(worker_pid)
      runner_ref = Process.monitor(runner_pid)
      send(worker_pid, :continue)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :normal}, 15_000
      assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}, 15_000

      assert Repo.get!(Run, run.id).state == "cleaned"
      refute Versions.get_gtfs_version_for_lifecycle(organization.id, failed_version.id)
    end

    test "opening a second discard confirmation replaces the first", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, first_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Discard First"})

      {:ok, first_version} =
        Versions.fail_unpublished_gtfs_version(organization.id, first_version.id)

      first_run = insert_run(organization.id, first_version, "failed")

      {:ok, second_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Discard Second"})

      {:ok, second_version} =
        Versions.fail_unpublished_gtfs_version(organization.id, second_version.id)

      second_run = insert_run(organization.id, second_version, "failed")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      view |> element("#discard-#{first_run.id}") |> render_click()
      assert has_element?(view, "#import-discard-dialog-body", "“Discard First”")

      view |> element("#discard-#{second_run.id}") |> render_click()

      refute has_element?(view, "#import-discard-dialog-body", "Discard First")
      assert has_element?(view, "#import-discard-dialog-body", "“Discard Second”")
      assert :sys.get_state(view.pid).socket.assigns.pending_discard_run_id == second_run.id
    end

    test "keeping the version closes the dialog and deletes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, failed_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Keep Me"})
      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      view |> element("#discard-#{run.id}") |> render_click()
      assert has_element?(view, "#import-discard-dialog[data-open='true']")

      view |> element("#import-discard-dialog-cancel") |> render_click()

      assert has_element?(view, "#import-discard-dialog[data-open='false']")
      assert has_element?(view, "#import-run-#{run.id}")
      assert Versions.get_gtfs_version_for_lifecycle(organization.id, failed_v.id)
    end

    test "a delete that cannot start says so in the list", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, failed_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Claimed"})
      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      view |> element("#discard-#{run.id}") |> render_click()

      # Another session claims the cleanup between opening the dialog and confirming.
      {:ok, _run, _version, _token} =
        GtfsPlanner.Gtfs.ImportRuns.claim_cleanup(organization.id, run.id, %{
          id: user.id,
          email: user.email
        })

      view |> element("#import-discard-dialog-confirm") |> render_click()

      assert has_element?(view, "#import-recovery-error", "That version couldn’t be deleted.")
      assert has_element?(view, "#import-discard-dialog[data-open='false']")
    end

    test "publication retry clears processing state and removes the recovery card", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Retry Publish"})

      {:ok, version} = Versions.claim_staging_gtfs_version(organization.id, version.id)

      run =
        insert_run(organization.id, version, "publication_failed",
          committed_counts: %{levels: 1},
          counts_complete: true
        )

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      assert has_element?(view, "#publish-version-#{run.id}")

      view |> element("#publish-version-#{run.id}") |> render_click()
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#import-run-#{run.id}")
      assert Versions.published_gtfs_version_for_org?(organization.id, version.id)
      assert :sys.get_state(view.pid).socket.assigns.processing_publish == nil
    end

    test "crafted publish/discard events for a published/cross-org target change nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      other_org = organization_fixture()
      {:ok, other_v} = Versions.create_staging_gtfs_version(other_org.id, %{name: "Other"})
      {:ok, other_v} = Versions.fail_unpublished_gtfs_version(other_org.id, other_v.id)
      other_run = insert_run(other_org.id, other_v, "failed")

      {:ok, _existing} = Versions.create_gtfs_version(organization.id, %{name: "Published"})
      {:ok, pub_run_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Pub"})
      {:ok, pub_run_v} = Versions.claim_staging_gtfs_version(organization.id, pub_run_v.id)
      {:ok, pub_run_v} = Versions.publish_importing_gtfs_version(organization.id, pub_run_v.id)
      pub_run = insert_run(organization.id, pub_run_v, "published")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      # Cross-org run and a published run are not recoverable and the events are
      # ignored (no crash, no state change).
      render_hook(view, "delete_version", %{"run_id" => to_string(other_run.id)})
      render_hook(view, "publish_version", %{"run_id" => to_string(pub_run.id)})
      render_hook(view, "delete_version", %{"run_id" => to_string(pub_run.id)})

      # The published version is untouched.
      assert Versions.published_gtfs_version_for_org?(organization.id, pub_run_v.id)
      # The cross-org failed version is untouched.
      assert Versions.get_gtfs_version_for_lifecycle(other_org.id, other_v.id)

      # A forged cross-organization broadcast is ignored without changing the
      # scoped recovery count or trying to delete a missing streamed row.
      recovery_count = :sys.get_state(view.pid).socket.assigns.recovery_count
      send(view.pid, {:import_run_changed, other_run.id})
      assert :sys.get_state(view.pid).socket.assigns.recovery_count == recovery_count
    end

    test "a newly recoverable run updates the exact count without duplicate-broadcast drift", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      assert :sys.get_state(view.pid).socket.assigns.recovery_count == 0

      {:ok, failed_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "New"})
      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      send(view.pid, {:import_run_changed, run.id})
      assert :sys.get_state(view.pid).socket.assigns.recovery_count == 1
      assert has_element?(view, "#import-run-#{run.id}")

      send(view.pid, {:import_run_changed, run.id})
      assert :sys.get_state(view.pid).socket.assigns.recovery_count == 1
    end

    test "a failed UI cleanup re-streams the durable cleanup_failed state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, failed_v} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Cleanup Failure"})

      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      Application.put_env(
        :gtfs_planner,
        :import_cleanup_inject_failure,
        {:filesystem, :before_namespace}
      )

      on_exit(fn -> Application.delete_env(:gtfs_planner, :import_cleanup_inject_failure) end)

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      view |> element("#discard-#{run.id}") |> render_click()
      view |> element("#import-discard-dialog-confirm") |> render_click()

      await_cleanup_task(view)

      assert has_element?(view, "#import-run-#{run.id}")
      assert has_element?(view, "#import-run-#{run.id}", "Delete failed")

      assert has_element?(
               view,
               "#import-run-#{run.id}",
               "We couldn’t finish deleting this version."
             )

      assert Repo.get!(Run, run.id).state == "cleanup_failed"
    end

    test "terminal {:import_run_changed, run_id} reloads the card from durable state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, failed_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Reload"})
      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      assert has_element?(view, "#import-run-#{run.id}")

      # Clean up the run in a separate (already-terminated) LiveView context by
      # claiming + discarding directly, then broadcast the terminal change.
      {:ok, _run, cleanup_version, token} =
        GtfsPlanner.Gtfs.ImportRuns.claim_cleanup(organization.id, run.id, %{
          id: user.id,
          email: user.email
        })

      cleared =
        GtfsPlanner.Repo.get!(GtfsPlanner.Gtfs.Import.Run, run.id)
        |> GtfsPlanner.Gtfs.Import.Recovery.discard_claimed(cleanup_version, token)

      assert cleared == {:ok, nil}

      # The broadcasting LiveView reconnects to the already-persisted state.
      send(view.pid, {:import_run_changed, run.id})
      html = render(view)

      refute has_element?(view, "#import-run-#{run.id}")
      assert html =~ "None. If an import stops before it publishes"
      assert has_element?(view, "#import-recovery-empty")
    end
  end

  # Step 24 / EV-26. A scheduled-closure row outside the supported subset stops
  # the import in phase one: the Import page names the file, the CSV row and one
  # bounded field/fix sentence, ahead of Import feed, releases the upload action
  # for that run, and keeps the failure durable until the version is discarded.
  describe "closure rejection recovery" do
    setup :editor_context

    @evolution_codes ~w(
      evolution_pathway_required evolution_service_required
      evolution_opening_unsupported evolution_direction_unsupported
      evolution_time_invalid evolution_pathway_missing evolution_service_missing
      evolution_duplicate
    )

    test "each bounded code renders its own file, row and field/fix sentence with a unique element",
         %{conn: conn, user: user, organization: organization, gtfs_version: route_version} do
      conn = log_in_user(conn, user, organization: organization)

      sentences = %{
        "evolution_pathway_required" => "Name the pathway, using the exact pathway_id",
        "evolution_service_required" => "Name the calendar, using the exact service_id",
        "evolution_opening_unsupported" => "Remove the opening row",
        "evolution_direction_unsupported" => "Leave direction blank or remove the column",
        "evolution_time_invalid" => "Use H:MM:SS with the end above the start",
        "evolution_pathway_missing" => "Import pathways.txt in the same feed",
        "evolution_service_missing" => "Import the calendar file in the same feed",
        "evolution_duplicate" => "Remove the repeated row"
      }

      runs =
        @evolution_codes
        |> Enum.with_index(2)
        |> Enum.map(fn {code, row} ->
          {:ok, version} =
            Versions.create_staging_gtfs_version(organization.id, %{name: "Rejected #{code}"})

          {:ok, version} = Versions.fail_unpublished_gtfs_version(organization.id, version.id)

          insert_run(organization.id, version, "failed",
            failed_file: "pathway_evolutions.txt",
            failed_row: row,
            reason_code: code
          )
        end)

      {:ok, view, html} = live(conn, "/gtfs/#{route_version.id}/import")

      # Recovery precedes Import feed while it holds runs, and the empty state is
      # gone (AC-42).
      recovery_at = :binary.match(html, ~s(id="import-recovery-section")) |> elem(0)
      feed_at = :binary.match(html, ~s(id="import-workspace")) |> elem(0)
      assert recovery_at < feed_at
      refute has_element?(view, "#import-recovery-empty")

      for {code, run} <- Enum.zip(@evolution_codes, runs) do
        assert has_element?(view, "#import-evolution-rejection-#{run.id}")
        assert html =~ ~s(data-evolution-rejection="#{code}")

        # The element names the file, the CSV row and the code's own sentence;
        # the text filter reads the rendered text, not the markup.
        assert has_element?(
                 view,
                 "#import-evolution-rejection-#{run.id}",
                 "Row #{run.failed_row}"
               )

        assert has_element?(
                 view,
                 "#import-evolution-rejection-#{run.id}",
                 "pathway_evolutions.txt"
               )

        assert has_element?(
                 view,
                 "#import-evolution-rejection-#{run.id}",
                 Map.fetch!(sentences, code)
               )
      end

      ids =
        Regex.scan(~r/id="import-evolution-rejection-([^"]+)"/, html, capture: :all_but_first)
        |> List.flatten()

      assert length(ids) == length(@evolution_codes)
      assert ids |> Enum.uniq() |> length() == length(@evolution_codes)
    end

    test "a real rejected closure import names the reason, releases the form and stays durable",
         %{conn: conn, user: user, organization: organization, gtfs_version: route_version} do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      # The rejected row carries a marker in its direction column. The run stores
      # the bounded code, file and row, never the value, so the marker must not
      # reach the page either.
      closure_file =
        "pathway_id,service_id,start_time,end_time,is_closed,direction\n" <>
          "PW1,CAL_DAILY,09:00:00,15:00:00,1,rejected-marker-9a"

      upload_gtfs(view, [
        gtfs_zip([
          {"levels.txt", @levels_content},
          {"stops.txt", @stops_content},
          {"pathway_evolutions.txt", closure_file}
        ])
      ])

      submit_import(view, "Rejected closure feed")
      html = await_import_task(view)

      run = Repo.get_by!(Run, version_name: "Rejected closure feed")
      target = Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)

      # Phase one failed: the version stays unpublished and no closure persisted.
      assert target.publication_status == "failed"

      assert Repo.all(
               from(e in GtfsPlanner.Gtfs.PathwayEvolution,
                 where: e.gtfs_version_id == ^target.id
               )
             ) == []

      assert has_element?(view, "#import-evolution-rejection-#{run.id}", "Row 2")

      assert has_element?(
               view,
               "#import-evolution-rejection-#{run.id}",
               "Leave direction blank or remove the column"
             )

      assert html =~ ~s(data-evolution-rejection="evolution_direction_unsupported")
      assert html =~ ~s(data-evolution-file="pathway_evolutions.txt")
      assert html =~ "remains unpublished until this failed import is discarded"
      refute html =~ "rejected-marker-9a"

      recovery_at = :binary.match(html, ~s(id="import-recovery-section")) |> elem(0)
      feed_at = :binary.match(html, ~s(id="import-workspace")) |> elem(0)
      assert recovery_at < feed_at

      # The terminal failure releases this run's import action: the form returns
      # from its pending state (the consumed entries mean the button's own
      # disabled state now reflects the empty upload field, and the browser case
      # proves the next submission works).
      submit = view |> element("#gtfs-import-submit") |> render()
      assert submit =~ "Import feed"
      refute submit =~ "Importing"
      refute html =~ "Importing…"

      # The published route version stays untouched.
      route_after = Versions.get_gtfs_version_for_lifecycle(organization.id, route_version.id)
      assert route_after.publication_status == "published"

      # A reconnect rebuilds the same durable failure.
      {:ok, reloaded, reload_html} = live(conn, "/gtfs/#{route_version.id}/import")
      assert has_element?(reloaded, "#import-evolution-rejection-#{run.id}")
      assert reload_html =~ "Rejected closure feed"
      assert reload_html =~ "Leave direction blank or remove the column"
      refute reload_html =~ "rejected-marker-9a"

      # Discarding removes only the failed version.
      reloaded |> element("#discard-#{run.id}") |> render_click()
      reloaded |> element("#import-discard-dialog-confirm") |> render_click()
      await_cleanup_task(reloaded)

      refute has_element?(reloaded, "#import-run-#{run.id}")
      assert has_element?(reloaded, "#import-recovery-empty")
      assert has_element?(reloaded, "#gtfs-import-discarded", "Rejected closure feed")
      refute Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)
      assert Versions.get_gtfs_version_for_lifecycle(organization.id, route_version.id)
    end

    test "durable counts name committed closures and read correctly at one and at many", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, many} = Versions.create_staging_gtfs_version(organization.id, %{name: "Counted Many"})
      {:ok, many} = Versions.fail_unpublished_gtfs_version(organization.id, many.id)

      many_run =
        insert_run(organization.id, many, "partial",
          committed_counts: %{levels: 1, stops: 12, pathways: 3, pathway_evolutions: 2},
          failed_file: "stop_times.txt",
          failed_row: 4
        )

      {:ok, one} = Versions.create_staging_gtfs_version(organization.id, %{name: "Counted One"})
      {:ok, one} = Versions.fail_unpublished_gtfs_version(organization.id, one.id)

      one_run =
        insert_run(organization.id, one, "partial",
          committed_counts: %{pathway_evolutions: 1},
          failed_file: "stop_times.txt",
          failed_row: 3
        )

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      many_card = view |> element("#import-run-#{many_run.id}") |> render()
      assert many_card =~ "1 level,"
      assert many_card =~ "12 stops,"
      assert many_card =~ "3 pathways,"
      assert many_card =~ "2 pathway closures"
      refute many_card =~ "2 level"

      one_card = view |> element("#import-run-#{one_run.id}") |> render()
      assert one_card =~ "1 pathway closure"
      refute one_card =~ "1 pathway closures"
    end

    test "a terminal transition for another target keeps this page's import in flight", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      {:ok, own_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Own target"})

      {:ok, own_version} =
        Versions.fail_unpublished_gtfs_version(organization.id, own_version.id)

      own_run = insert_run(organization.id, own_version, "failed", reason_code: "row_invalid")

      {:ok, other_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Other target"})

      {:ok, other_version} =
        Versions.fail_unpublished_gtfs_version(organization.id, other_version.id)

      other_run = insert_run(organization.id, other_version, "failed", reason_code: "row_invalid")

      put_socket_assigns(view, importing: true, import_target: own_version)

      # Another run reaching terminal state leaves this page's import alone.
      send(view.pid, {:import_run_changed, other_run.id})
      render(view)
      assert :sys.get_state(view.pid).socket.assigns.importing

      # This page's own run releases it, restoring the upload action.
      send(view.pid, {:import_run_changed, own_run.id})
      render(view)
      refute :sys.get_state(view.pid).socket.assigns.importing
      assert :sys.get_state(view.pid).socket.assigns.import_progress == nil

      submit = view |> element("#gtfs-import-submit") |> render()
      assert submit =~ "Import feed"
      refute submit =~ "disabled"
    end
  end

  describe "end-to-end recovery boundary integration (AC-4/6/7/13/14)" do
    setup :editor_context

    test "terminating the first LiveView, killing its runner, then remounting reconciles and keeps prior rows byte-identical",
         %{conn: conn, user: user, organization: organization, gtfs_version: route_version} do
      conn = log_in_user(conn, user, organization: organization)

      previous_worker = Application.get_env(:gtfs_planner, :import_worker_module)
      previous_owner = Application.get_env(:gtfs_planner, :blocking_import_worker_owner)

      Application.put_env(
        :gtfs_planner,
        :import_worker_module,
        GtfsPlanner.Support.BlockingImportWorker
      )

      Application.put_env(:gtfs_planner, :blocking_import_worker_owner, self())

      on_exit(fn ->
        restore_application_env(:import_worker_module, previous_worker)
        restore_application_env(:blocking_import_worker_owner, previous_owner)
      end)

      uploads = Application.fetch_env!(:gtfs_planner, :uploads_path)

      # A prior published version whose rows + diagram file must stay byte-identical.
      {:ok, prior} = Versions.create_gtfs_version(organization.id, %{name: "Prior Live"})

      GtfsPlanner.Gtfs.create_level(%{
        level_id: "LP",
        level_index: 0.0,
        level_name: "Prior Level",
        organization_id: organization.id,
        gtfs_version_id: prior.id
      })

      prior_file =
        Path.join([uploads, "diagrams", organization.id, prior.id, "station", "prior_live.png"])

      File.mkdir_p!(Path.dirname(prior_file))
      prior_bytes = "prior-live-bytes-#{String.duplicate("z", 32)}"
      File.write!(prior_file, prior_bytes)

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([{"levels.txt", @levels_content}, {"stops.txt", @stops_content}])
      ])

      submit_import(view, "Drop Me")
      assert_receive {:blocking_import_worker_started, worker_pid}

      # The initiating LiveView process for the import; terminate it and confirm
      # it is gone (AC-6: the runner must survive).
      view_ref = Process.monitor(view.pid)
      # Find the supervised runner that owns the in-flight import.
      runner_pid =
        Enum.find_value(0..20, nil, fn _ ->
          case DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Import.RunnerSupervisor) do
            [] -> nil
            [{_, pid, _, _}] -> pid
            _ -> nil
          end
        end)

      refute is_nil(runner_pid)

      # Terminate the LiveView owner (graceful stop; a normal/shutdown exit
      # does not propagate to the linked test process, unlike :kill).
      view_pid = view.pid
      GenServer.stop(view_pid)
      assert_receive {:DOWN, ^view_ref, :process, ^view_pid, _reason}, 15_000

      # The supervisor-owned runner survives the LiveView. Kill it afterward so
      # its normal closure cannot execute (AC-7).
      task_pid = :sys.get_state(runner_pid).task_pid
      assert task_pid == worker_pid
      runner_ref = Process.monitor(runner_pid)
      task_ref = Process.monitor(task_pid)
      Process.exit(runner_pid, :kill)
      assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :killed}
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}

      # The run is still active (running) because the lease is unexpired.
      run =
        from(r in GtfsPlanner.Gtfs.Import.Run, where: r.organization_id == ^organization.id)
        |> GtfsPlanner.Repo.one!()

      assert run.state == "running"

      # Force the lease to a far-past timestamp and reconcile via the real
      # ImportRuns entry point.
      expired = ~U[2000-01-01 00:00:00.000000Z]

      {1, nil} =
        from(r in GtfsPlanner.Gtfs.Import.Run,
          where: r.id == ^run.id,
          update: [set: [lease_expires_at: ^expired]]
        )
        |> GtfsPlanner.Repo.update_all([])

      reconciled = GtfsPlanner.Gtfs.ImportRuns.reconcile_expired(organization.id)
      assert Enum.any?(reconciled, &(&1.id == run.id))

      # The reconstructed state is authoritative: interrupted, version failed.
      assert GtfsPlanner.Repo.get!(GtfsPlanner.Gtfs.Import.Run, run.id).state == "interrupted"
      target = Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)
      assert target.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)

      # Remount a fresh LiveView: it reconciles on mount and streams the
      # interrupted run as a recoverable card (AC-6/AC-7).
      {:ok, view2, html2} = live(conn, "/gtfs/#{route_version.id}/import")

      assert has_element?(view2, "#import-recovery-section-title", "Unfinished imports")
      assert has_element?(view2, "#import-run-#{run.id}")
      assert html2 =~ "we can’t tell how much was saved"

      # Prior published version rows + diagram file are byte-identical.
      assert GtfsPlanner.Gtfs.list_levels(organization.id, prior.id) != []
      assert File.read!(prior_file) == prior_bytes

      # No target is externally visible before guarded publication.
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)
    end

    test "discard through the UI then re-upload the same name yields one fresh target (AC-13/AC-14)",
         %{conn: conn, user: user, organization: organization, gtfs_version: route_version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, failed_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Again"})
      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")
      assert has_element?(view, "#import-run-#{run.id}")

      # Discard through the UI confirmation.
      view |> element("#discard-#{run.id}") |> render_click()
      view |> element("#import-discard-dialog-confirm") |> render_click()

      await_cleanup_task(view)

      assert has_element?(view, "#import-recovery-empty")
      refute Versions.get_gtfs_version_for_lifecycle(organization.id, failed_v.id)

      before_versions = length(all_versions(organization.id))

      # Re-upload the same feed under the SAME version name.
      upload_gtfs(view, [
        gtfs_zip([{"levels.txt", @levels_content}, {"stops.txt", @stops_content}])
      ])

      submit_import(view, "Again")
      await_import_task(view)

      # Exactly one new version row (the fresh target), no duplicate for the name.
      assert length(all_versions(organization.id)) == before_versions + 1

      again_versions =
        from(v in GtfsPlanner.Versions.GtfsVersion,
          where: v.organization_id == ^organization.id and v.name == "Again"
        )
        |> GtfsPlanner.Repo.all()

      assert length(again_versions) == 1
      target = Enum.at(again_versions, 0)
      assert target.publication_status == "published"
      assert GtfsPlanner.Gtfs.get_level_by_level_id(organization.id, target.id, "L1")
    end

    test "terminal {:import_run_changed, run_id} reloads the card from already-persisted state during a live import",
         %{conn: conn, user: user, organization: organization, gtfs_version: route_version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([{"levels.txt", @levels_content}, {"stops.txt", @stops_content}])
      ])

      # The synchronous post-submit render reflects the in-flight publication.
      html = submit_import(view, "Live Reconcile")
      assert html =~ "Importing"

      # Wait for the supervised task to finish, then flush by rendering until the
      # LiveView has applied the terminal transition.
      for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
      end

      await_import_settled(view, 100)

      # The published target is now externally visible and the success result was
      # applied from persisted durable state.
      target = version_by_name(organization.id, "Live Reconcile")
      assert target
      assert target.publication_status == "published"
      assert has_element?(view, "#gtfs-import-result-title", "Imported “Live Reconcile”")
      assert has_element?(view, "#gtfs-import-view-version[href='/gtfs/#{target.id}/routes']")
    end
  end

  describe "a started import that ends without publishing" do
    setup :editor_context

    setup do
      previous_worker = Application.get_env(:gtfs_planner, :import_worker_module)
      previous_owner = Application.get_env(:gtfs_planner, :blocking_import_worker_owner)

      Application.put_env(
        :gtfs_planner,
        :import_worker_module,
        GtfsPlanner.Support.BlockingImportWorker
      )

      Application.put_env(:gtfs_planner, :blocking_import_worker_owner, self())

      on_exit(fn ->
        restore_application_env(:import_worker_module, previous_worker)
        restore_application_env(:blocking_import_worker_owner, previous_owner)
      end)

      :ok
    end

    # Starts an import whose worker holds the claimed run in `running`, and
    # returns the view with the durable run the page is tracking.
    defp start_held_import(conn, user, organization, route_version, name) do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])
      submit_import(view, name)
      assert_receive {:blocking_import_worker_started, worker_pid}
      on_exit(fn -> send(worker_pid, :finish) end)

      run =
        Repo.one!(
          from(r in Run, where: r.organization_id == ^organization.id and r.version_name == ^name)
        )

      assert run.state == "running"
      {view, run}
    end

    defp close_run_with_failure(organization, run, outcome, opts) do
      failure =
        Failure.from_error(
          :executor_lost,
          Keyword.merge([phase: :phase_2, outcome: outcome], opts)
        )

      {:ok, closed, _version} =
        ImportRuns.fail_import(organization.id, run.id, run.lease_token, failure)

      closed
    end

    test "a runner failure frees the form and reports the failed import beside it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      Application.put_env(
        :gtfs_planner,
        :import_worker_module,
        GtfsPlanner.Gtfs.Import.Publication
      )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        %{
          name: "levels.txt",
          content: "level_id,level_index\nL1,0.0\nL1,0.0",
          type: "text/plain"
        }
      ])

      submit_import(view, "Runner Failure")
      await_import_task(view)

      run =
        Repo.one!(
          from(r in Run,
            where: r.organization_id == ^organization.id and r.version_name == "Runner Failure"
          )
        )

      assert run.state == "failed"

      assert has_element?(view, "#gtfs-import-submit", "Import feed")
      refute has_element?(view, "#gtfs-import-submit", "Importing")
      assert has_element?(view, "#gtfs-import-result", "Runner Failure")
      assert has_element?(view, "#gtfs-import-result", "did not finish")
      assert has_element?(view, "#import-run-#{run.id}")
    end

    test "a partial import frees the form and reports the failed import beside it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      {view, run} = start_held_import(conn, user, organization, route_version, "Partial Import")

      closed =
        close_run_with_failure(organization, run, :partial,
          committed_counts: %{"levels" => 1},
          failed_file: "stops.txt"
        )

      assert closed.state == "partial"
      send(view.pid, {:import_run_changed, run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#gtfs-import-submit", "Import feed")
      refute has_element?(view, "#gtfs-import-submit", "Importing")
      assert has_element?(view, "#gtfs-import-result", "Partial Import")
      assert has_element?(view, "#gtfs-import-result", "did not finish")
      assert has_element?(view, "#import-run-#{run.id}")
    end

    test "an interrupted import frees the form and reports the failed import beside it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      {view, run} = start_held_import(conn, user, organization, route_version, "Lost Runner")

      closed =
        close_run_with_failure(organization, run, :interrupted, counts_complete: false)

      assert closed.state == "interrupted"
      send(view.pid, {:import_run_changed, run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#gtfs-import-submit", "Import feed")
      refute has_element?(view, "#gtfs-import-submit", "Importing")
      assert has_element?(view, "#gtfs-import-result", "Lost Runner")
      assert has_element?(view, "#gtfs-import-result", "did not finish")
      assert has_element?(view, "#import-run-#{run.id}")
    end

    test "a publication failure frees the form and reports the unpublished version beside it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      {view, run} = start_held_import(conn, user, organization, route_version, "Publish Failure")

      result = %Result{
        counts: %{levels: 1},
        unrecognized_files: [],
        topic: "import:test",
        archive_warnings: [],
        extensions: :not_present
      }

      {:ok, closed} =
        ImportRuns.record_publication_failure(
          organization.id,
          run.id,
          run.lease_token,
          result,
          :publication_failed
        )

      assert closed.state == "publication_failed"
      send(view.pid, {:import_run_changed, run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#gtfs-import-submit", "Import feed")
      refute has_element?(view, "#gtfs-import-submit", "Importing")
      assert has_element?(view, "#gtfs-import-result", "Publish Failure")
      assert has_element?(view, "#gtfs-import-result", "could not be published")
      assert has_element?(view, "#publish-version-#{run.id}")
    end

    test "a change to the run that is still running keeps the Importing state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      {view, run} = start_held_import(conn, user, organization, route_version, "Still Running")

      send(view.pid, {:import_run_changed, run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#gtfs-import-submit[disabled]", "Importing")
      refute has_element?(view, "#gtfs-import-result")
    end

    test "another run failing keeps the Importing state and shows no failure result", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      {view, _run} = start_held_import(conn, user, organization, route_version, "Mine")

      {:ok, other_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Theirs"})
      {:ok, other_v} = Versions.fail_unpublished_gtfs_version(organization.id, other_v.id)
      other_run = insert_run(organization.id, other_v, "failed")

      send(view.pid, {:import_run_changed, other_run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#import-run-#{other_run.id}")
      assert has_element?(view, "#gtfs-import-submit[disabled]", "Importing")
      refute has_element?(view, "#gtfs-import-result")
    end

    test "another run publishing keeps the Importing state and shows no result", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      {view, _run} = start_held_import(conn, user, organization, route_version, "Mine")

      {:ok, other_v} = Versions.create_gtfs_version(organization.id, %{name: "Theirs"})
      other_run = insert_run(organization.id, other_v, "published")

      send(view.pid, {:import_run_changed, other_run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#gtfs-import-submit[disabled]", "Importing")
      refute has_element?(view, "#gtfs-import-result")
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_application_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

  defp await_idle_runners(_context), do: GtfsPlanner.Support.RunnerSlots.await_idle()

  # Sets an application key for one test and restores the previous value on exit.
  defp put_application_env(key, value) do
    previous = Application.get_env(:gtfs_planner, key)
    Application.put_env(:gtfs_planner, key, value)
    on_exit(fn -> restore_application_env(key, previous) end)
  end

  # `SourceStorage.stage/4` announces every staging call from the calling process, here the
  # LiveView, before it copies a byte. The probe's handler runs at that moment.
  defp attach_staging_probe(handler, organization) do
    handler_id = "import-live-staging-#{System.unique_integer([:positive])}"
    config = %{owner: self(), organization_id: organization.id}

    :ok =
      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :task_artifact_capacity, :lock_attempt],
        handler,
        config
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Records the run and the runner as they are when the upload starts to be copied.
  def record_staging(_event, _measurements, _metadata, %{owner: owner, organization_id: id}) do
    run = Repo.one!(from(r in Run, where: r.organization_id == ^id))
    runner_state = :sys.get_state(only_import_runner())

    send(
      owner,
      {:staging_started,
       %{
         run_state: run.state,
         run_token: run.lease_token,
         runner_token: runner_state.lease_token,
         worker: runner_state.task_pid
       }}
    )
  end

  # Holds the staging process until the runner has stopped, so the install that follows
  # reaches a runner that already passed its deadline.
  def await_runner_exit(_event, _measurements, _metadata, _config) do
    for {_id, runner, _type, _modules} <-
          DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Import.RunnerSupervisor),
        is_pid(runner) do
      ref = Process.monitor(runner)

      receive do
        {:DOWN, ^ref, :process, ^runner, _reason} -> :ok
      after
        5_000 -> raise "the import runner did not stop at its install deadline"
      end
    end
  end

  defp only_import_runner do
    [{_id, runner, _type, _modules}] =
      DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Import.RunnerSupervisor)

    runner
  end

  describe "upload display" do
    setup :editor_context

    test "file upload shows the entry and cancel removes it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      assert render(view) =~ "levels.txt"

      view |> element("button[phx-click='cancel-upload']") |> render_click()
      refute has_element?(view, "button[phx-click='cancel-upload']")
    end

    test ".zip upload is accepted without an unrecognized warning", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      {:ok, {_name, zip_binary}} =
        :zip.create(~c"gtfs.zip", [{~c"levels.txt", "level_id,level_index\nL1,0.0"}], [:memory])

      upload_gtfs(view, [%{name: "gtfs_export.zip", content: zip_binary, type: "application/zip"}])

      html = render(view)
      assert html =~ "gtfs_export.zip"
      refute html =~ "Unrecognized Files"
    end
  end

  describe "reviewed diff isolation" do
    setup :editor_context

    test "diff apply targets the route version and creates no staging version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      _parent =
        stop_fixture(organization.id, version.id, %{
          stop_id: "PARENT_STATION_DIFF",
          stop_name: "Parent Station",
          location_type: 1
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      before_versions = length(all_versions(organization.id))
      before_published = length(published_versions(organization.id))

      stops_content =
        "stop_id,stop_name,stop_lat,stop_lon,parent_station,level_id\n" <>
          "CHILD_DIFF_NO_LEVEL,Child Diff Stop,1.0,1.0,PARENT_STATION_DIFF,\n"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "stops.txt", content: stops_content, type: "text/plain"}
        ])

      render_upload(upload, "stops.txt")

      view |> form("#diff-upload-form", %{}) |> render_submit()
      await_import_task(view)

      view
      |> element("button[phx-click='approve-all'][phx-value-action='add']")
      |> render_click()

      view |> element("#diff-apply-btn") |> render_click()
      await_import_task(view)

      assert has_element?(view, "#diff-count-applied", "1")
      assert has_element?(view, "#diff-count-failed", "0")
      assert has_element?(view, "#diff-count-unapplied", "0")

      # The change landed on the route version and created no new version rows.
      child = Gtfs.get_stop_by_stop_id(organization.id, version.id, "CHILD_DIFF_NO_LEVEL")
      assert child.parent_station == "PARENT_STATION_DIFF"
      assert length(all_versions(organization.id)) == before_versions
      assert length(published_versions(organization.id)) == before_published
    end
  end

  describe "choosing what to import" do
    setup :editor_context

    test "shows one workflow at a time and keeps each form's chosen files", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      # A complete feed is the common job, so it is chosen and the other form waits.
      assert has_element?(view, "#import-source-feed[checked]")
      assert has_element?(view, "#import-workspace-title", "Import a feed")
      refute has_element?(view, "#gtfs-import-form[hidden]")
      assert has_element?(view, "#diff-upload-form[hidden]")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      view |> element("#import-source-form") |> render_change(%{"source" => "station"})

      assert has_element?(view, "#import-source-station[checked]")
      assert has_element?(view, "#import-workspace-title", "Update station data")
      assert has_element?(view, "#gtfs-import-form[hidden]")
      refute has_element?(view, "#diff-upload-form[hidden]")

      # Going back finds the file that was chosen.
      view |> element("#import-source-form") |> render_change(%{"source" => "feed"})

      refute has_element?(view, "#gtfs-import-form[hidden]")
      assert has_element?(view, "#gtfs-import-upload-entries", "levels.txt")
    end

    test "an unknown source changes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      render_hook(view, "select_source", %{"source" => "everything"})

      assert :sys.get_state(view.pid).socket.assigns.source == :feed
    end

    test "a review in progress opens on the station workflow", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _run} =
        ChangeRuns.create_pending_compute(
          organization.id,
          version.id,
          %{id: user.id, email: user.email},
          []
        )

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      assert has_element?(view, "#import-source-station[checked]")
      assert has_element?(view, "#diff-run-state[data-state='pending_compute']")
      # The running review is the page's subject, so the form steps aside.
      assert has_element?(view, "#import-workspace[hidden]")
    end

    test "a finished review does not take over the page on open", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      actor = %{id: user.id, email: user.email}

      {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, actor, [])

      run
      |> ChangeRun.system_changeset(%{
        state: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -60, :second),
        finished_at: DateTime.utc_now(),
        summary: %{"applied" => 3, "failed" => 0, "unapplied" => 0}
      })
      |> Repo.update!()

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      # The feed form is what is showing; the finished review is one choice away.
      assert has_element?(view, "#import-source-feed[checked]")
      refute has_element?(view, "#import-workspace[hidden]")
      refute has_element?(view, "#diff-done")

      # Choosing station changes starts a new review instead of showing the old one.
      view |> element("#import-source-form") |> render_change(%{"source" => "station"})

      refute has_element?(view, "#diff-done")
      refute has_element?(view, "#import-workspace[hidden]")
      refute has_element?(view, "#diff-upload-form[hidden]")
      assert has_element?(view, "#diff-compute-btn[disabled]")
    end

    test "a refused file says what to do about it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      upload =
        file_input(view, "#gtfs-import-form", :gtfs_files, [
          %{name: "stop-times.xlsx", content: "x", type: "application/vnd.ms-excel"}
        ])

      render_upload(upload, "stop-times.xlsx")

      assert has_element?(
               view,
               "#gtfs-import-upload-entries",
               "Spreadsheets can’t be imported. Save it as a .csv or .txt file, or include it in a .zip."
             )

      assert has_element?(view, "#gtfs-import-upload[data-upload-state='failed']")
    end
  end

  describe "after an import" do
    setup :editor_context

    test "Import another feed returns to an empty form and clears the result", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([{"levels.txt", @levels_content}, {"stops.txt", @stops_content}])
      ])

      submit_import(view, "First Feed")
      await_import_task(view)

      # The result replaces the form.
      assert has_element?(view, "#gtfs-import-result")
      assert has_element?(view, "#import-workspace[hidden]")

      view |> element("#gtfs-import-another") |> render_click()

      refute has_element?(view, "#gtfs-import-result")
      refute has_element?(view, "#import-workspace[hidden]")
      refute has_element?(view, "#gtfs-import-version-name[value='First Feed']")
      assert_push_event(view, "focus_gtfs_import_files", %{})
    end

    test "the counts of levels, stops and pathways come from the run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([{"levels.txt", @levels_content}, {"stops.txt", @stops_content}])
      ])

      submit_import(view, "Counted Feed")
      await_import_task(view)

      assert has_element?(view, "#gtfs-import-count-levels", "1")
      assert has_element?(view, "#gtfs-import-count-stops", "1")
      assert has_element?(view, "#gtfs-import-count-pathways", "0")
      assert has_element?(view, "#gtfs-import-check-version[href$='/export']")
    end
  end

  describe "an import that stops" do
    setup :editor_context

    test "returns the page to the form and lists the stopped import", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      {:ok, failed_v} = Versions.create_staging_gtfs_version(organization.id, %{name: "Stops"})
      {:ok, failed_v} = Versions.fail_unpublished_gtfs_version(organization.id, failed_v.id)
      run = insert_run(organization.id, failed_v, "failed")

      # The import this page started is running.
      put_socket_assigns(view, %{importing: true, import_target: failed_v})

      send(view.pid, {:import_run_changed, run.id})
      html = render(view)

      # The progress card does not wait for a result that will not come.
      refute :sys.get_state(view.pid).socket.assigns.importing
      refute has_element?(view, "#gtfs-importing-card")
      refute has_element?(view, "#import-workspace[hidden]")
      assert has_element?(view, "#import-run-#{run.id}", "Failed")
      assert html =~ "Delete this version and import again."
    end
  end

  describe "GTFS area navigation" do
    setup :editor_context

    test "mounts the GTFS tabs with Import current above the unchanged page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/import")

      assert has_element?(view, "#gtfs-sub-nav")
      assert has_element?(view, "#gtfs-tab-import[aria-current='page']")
      assert has_element?(view, "#gtfs-tab-export[href='/gtfs/#{version.id}/export']")
      refute has_element?(view, "#gtfs-tab-export[aria-current='page']")

      assert html =~ "Import data"
      assert has_element?(view, "#gtfs-import-form")
      assert has_element?(view, "#import-workspace")
    end
  end

  # The success result's agency findings for the version just published (AC-27,
  # R11). Every case imports a real feed through the real form and runner, so
  # `success_for_published_target/2` reads the new version's own agency health,
  # and the link is compared with that version's ID rather than the URL's.
  describe "agency findings" do
    setup :editor_context

    test "a feed with routes but no agency publishes and names the finding", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([
          {"routes.txt", @findings_routes_content},
          {"stops.txt", @findings_stops_content}
        ])
      ])

      submit_import(view, "Findings Missing Agency")
      html = await_import_task(view)

      # Publication is unaffected: the new version is published and announced.
      assert has_element?(view, "#gtfs-import-result-title", "Imported “Findings Missing Agency”")

      published = version_by_name(organization.id, "Findings Missing Agency")
      assert published
      refute published.id == route_version.id

      assert Versions.get_gtfs_version_for_lifecycle(organization.id, published.id).publication_status ==
               "published"

      assert has_element?(view, "#gtfs-import-result #gtfs-import-agency-findings")
      assert html =~ "No agency in this feed"
      assert html =~ "2 routes need an operating agency before export."
      refute html =~ "Choose one timezone for this version."

      # The finding links to the published version, never to the URL version.
      assert has_element?(
               view,
               "#gtfs-import-set-up-agency[href='/gtfs/#{published.id}/settings/agencies']"
             )

      refute has_element?(
               view,
               "#gtfs-import-set-up-agency[href='/gtfs/#{route_version.id}/settings/agencies']"
             )
    end

    test "two agencies in different timezones name the disagreement", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([
          {"agency.txt", @findings_two_zone_agencies_content},
          {"routes.txt", @findings_routes_content},
          {"stops.txt", @findings_stops_content}
        ])
      ])

      submit_import(view, "Findings Mixed Zones")
      html = await_import_task(view)

      published = version_by_name(organization.id, "Findings Mixed Zones")
      assert published
      assert published.publication_status == "published"

      assert has_element?(view, "#gtfs-import-agency-findings")
      assert html =~ "Agencies use different timezones"
      assert html =~ "Choose one timezone for this version."
      refute html =~ "No agency in this feed"

      assert has_element?(
               view,
               "#gtfs-import-resolve-timezones[href='/gtfs/#{published.id}/settings/agencies']"
             )

      assert html =~ "Resolve timezones"
    end

    test "an unrecognized agency timezone names that reason", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([
          {"agency.txt", @findings_invalid_zone_agency_content},
          {"routes.txt", @findings_routes_content},
          {"stops.txt", @findings_stops_content}
        ])
      ])

      submit_import(view, "Findings Invalid Zone")
      html = await_import_task(view)

      published = version_by_name(organization.id, "Findings Invalid Zone")
      assert published
      assert published.publication_status == "published"

      assert has_element?(view, "#gtfs-import-agency-findings")
      assert html =~ "The agency timezone isn’t recognized"
      assert html =~ "Choose one timezone for this version."
      refute html =~ "No agency in this feed"
    end

    test "a clean single-agency feed publishes with no findings element", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([
          {"agency.txt", @findings_one_agency_content},
          {"routes.txt", @findings_routes_content},
          {"stops.txt", @findings_stops_content}
        ])
      ])

      submit_import(view, "Findings Clean Feed")
      html = await_import_task(view)

      published = version_by_name(organization.id, "Findings Clean Feed")
      assert published
      assert published.publication_status == "published"

      assert has_element?(view, "#gtfs-import-result-title", "Imported “Findings Clean Feed”")
      refute has_element?(view, "#gtfs-import-agency-findings")
      refute html =~ "No agency in this feed"
      refute html =~ "Choose one timezone for this version."
    end

    test "a new import clears the previous version's finding", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [
        gtfs_zip([
          {"routes.txt", @findings_routes_content},
          {"stops.txt", @findings_stops_content}
        ])
      ])

      submit_import(view, "Findings Then Clean")
      html = await_import_task(view)

      assert has_element?(view, "#gtfs-import-agency-findings")
      assert html =~ "No agency in this feed"

      upload_gtfs(view, [
        gtfs_zip([
          {"agency.txt", @findings_one_agency_content},
          {"routes.txt", @findings_routes_content},
          {"stops.txt", @findings_stops_content}
        ])
      ])

      html = submit_import(view, "Findings Second Feed")

      # The previous finding is cleared while the new import runs, before the
      # new version exists to have findings of its own.
      refute html =~ "No agency in this feed"
      refute has_element?(view, "#gtfs-import-agency-findings")

      html = await_import_task(view)

      assert has_element?(view, "#gtfs-import-result-title", "Imported “Findings Second Feed”")
      refute has_element?(view, "#gtfs-import-agency-findings")
      refute html =~ "No agency in this feed"
    end
  end
end
