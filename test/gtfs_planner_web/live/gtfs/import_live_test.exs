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
  alias GtfsPlanner.Gtfs.Import.{Recovery, Run}
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @levels_content "level_id,level_index,level_name\nL1,0.0,Ground"
  @stops_content "stop_id,stop_name,stop_lat,stop_lon,level_id\nS1,Stop 1,1.0,1.0,L1"

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

      assert html =~ "Import GTFS"
      assert html =~ "GTFS files"
      assert html =~ ".zip archive"
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
      assert has_element?(view, "#gtfs-import-destination")
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
      assert has_element?(view, "#gtfs-import-upload-label", "GTFS files")
      assert has_element?(view, "#gtfs-import-upload-help")
      assert has_element?(view, "#diff-upload[data-upload-state='idle']")
      assert has_element?(view, "#diff-upload-label", "Station data files")
      assert has_element?(view, "#diff-upload-help")
      assert has_element?(view, "#diff-compute-btn[disabled]", "Compute diff")
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

      refute render(view) =~ "Version name is required"

      view |> element("#gtfs-import-version-name") |> render_blur()

      view
      |> element("#gtfs-import-form")
      |> render_change(%{"gtfs_import_form" => %{"version_name" => ""}})

      assert render(view) =~ "Version name is required"
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

      # The persistent destination summary appears before file selection.
      assert has_element?(view, "#gtfs-import-destination")

      # It names the prospective new version and the currently available one.
      assert html =~ "Destination: New version"
      assert html =~ version.name
      assert html =~ "remains available until import succeeds"

      # The reviewed-diff destination separately names the existing-version target.
      assert has_element?(view, "#diff-destination")
      assert render(view) =~ "Reviewed changes apply to version"
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
      assert html =~ ~r/aria-describedby="gtfs-import-version-name-error"/
      assert html =~ ~r/aria-invalid="true"/
      assert html =~ "Version name is required"
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
      assert html =~ "Import successful"
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
      assert html =~ "already exists"

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
      assert html =~ "Import successful"
      assert html =~ "Spring 2025"
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
      assert html =~ "already exists"

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
      assert render(view) =~ "can&#39;t be blank" or render(view) =~ "blank"
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

  describe "post-create consumption failure" do
    setup :editor_context

    setup do
      previous = Application.get_env(:gtfs_planner, :import_file_reader)

      Application.put_env(
        :gtfs_planner,
        :import_file_reader,
        GtfsPlanner.Support.ImportFileReaderErrorStub
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:gtfs_planner, :import_file_reader, previous)
        else
          Application.delete_env(:gtfs_planner, :import_file_reader)
        end
      end)

      :ok
    end

    test "a read error fails the exact staging target and starts no task", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      upload_gtfs(view, [%{name: "levels.txt", content: @levels_content, type: "text/plain"}])

      html = submit_import(view, "Consume Fail")

      target = version_by_name(organization.id, "Consume Fail")
      assert target
      assert target.publication_status == "failed"

      run =
        from(r in GtfsPlanner.Gtfs.Import.Run,
          where: r.organization_id == ^organization.id and r.gtfs_version_id == ^target.id
        )
        |> GtfsPlanner.Repo.one!()

      assert run.state == "failed"
      assert run.reason_code == "unknown_error"
      assert is_nil(run.lease_token)

      # No task started and no rows written to any version.
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []
      refute Gtfs.get_level_by_level_id(organization.id, route_version.id, "L1")
      refute Gtfs.get_level_by_level_id(organization.id, target.id, "L1")

      assert html =~ "Import failed"
      assert html =~ "Consume Fail"
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
      assert html =~ "counts are uncertain" or render(view) =~ "counts are uncertain"
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
      assert html =~ "uncertain"
      refute html =~ "inspect("
      refute html =~ "Ecto"
      refute html =~ ~s(SQL)
      refute html =~ "/tmp/"
    end

    test "discard uses two-step inline confirmation naming the version and focuses the upload", %{
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

      # No confirm button until "Discard failed import" is clicked.
      refute has_element?(view, "#delete-version-#{run.id}")

      view
      |> element("#discard-#{run.id}")
      |> render_click()

      # Now the confirm button names the version consequence.
      assert has_element?(view, "#delete-version-#{run.id}", "Delete failed version")
      assert render(view) =~ "ToDiscard"

      # Confirming discards the failed version and removes the card.
      view
      |> element("#delete-version-#{run.id}")
      |> render_click()

      await_cleanup_task(view)

      assert render(view) =~ "No recoverable imports for this organization."

      # The removed version name is prefilled into the new-upload name field.
      assert render(view) =~ "ToDiscard"

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
      view |> element("#delete-version-#{run.id}") |> render_click()

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

    test "opening a second discard confirmation closes the first", %{
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
      assert has_element?(view, "#delete-version-#{first_run.id}")

      view |> element("#discard-#{second_run.id}") |> render_click()

      refute has_element?(view, "#delete-version-#{first_run.id}")
      assert has_element?(view, "#delete-version-#{second_run.id}")
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
      view |> element("#delete-version-#{run.id}") |> render_click()

      await_cleanup_task(view)

      assert has_element?(view, "#import-run-#{run.id}")
      assert render(view) =~ "Cleanup failed — can be retried by discarding."
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
      assert html =~ "No recoverable imports for this organization."
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

      assert html2 =~ "Import recovery"
      assert has_element?(view2, "#import-run-#{run.id}")
      assert html2 =~ "Durable counts are uncertain"

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

      # Discard through the two-step UI confirmation.
      view |> element("#discard-#{run.id}") |> render_click()
      view |> element("#delete-version-#{run.id}") |> render_click()

      await_cleanup_task(view)

      assert render(view) =~ "No recoverable imports for this organization."
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
      assert render(view) =~ "Import successful"
      assert has_element?(view, "#gtfs-import-view-version[href='/gtfs/#{target.id}/routes']")
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_application_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

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
      html = await_import_task(view)

      assert html =~ "Applied 1 · Failed 0 · Unapplied 0"

      # The change landed on the route version and created no new version rows.
      child = Gtfs.get_stop_by_stop_id(organization.id, version.id, "CHILD_DIFF_NO_LEVEL")
      assert child.parent_station == "PARENT_STATION_DIFF"
      assert length(all_versions(organization.id)) == before_versions
      assert length(published_versions(organization.id)) == before_published
    end
  end
end
