defmodule GtfsPlannerWeb.Gtfs.ImportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  @levels_content "level_id,level_index,level_name\nL1,0.0,Ground"
  @stops_content "stop_id,stop_name,stop_lat,stop_lon,level_id\nS1,Stop 1,1.0,1.0,L1"

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
  # process and assert on its DOWN message.
  defp await_import_task(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    render(view)
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
      assert html =~ "GTFS Files"
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
      assert html =~ ~r/role="alert"/
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
      assert html =~ ~r/id="gtfs-import-submit"[^>]*disabled/

      # The polite live region is present to surface progress.
      assert html =~ ~r/id="gtfs-import-status"[^>]*aria-live="polite"/

      # After completion the CTA returns to its idle label.
      final = await_import_task(view)
      refute final =~ "Importing"
    end

    test "success announces the published version and links to it while keeping the diff destination", %{
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

    test "validation failure uses the shared input exactly once and preserves keyboard correction", %{
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
      put_socket_assigns(view, %{importing: true, import_task: make_ref()})

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

      # No task started and no rows written to any version.
      assert Task.Supervisor.children(GtfsPlanner.TaskSupervisor) == []
      refute Gtfs.get_level_by_level_id(organization.id, route_version.id, "L1")
      refute Gtfs.get_level_by_level_id(organization.id, target.id, "L1")

      assert html =~ "Import failed"
      assert html =~ "Consume Fail"
    end
  end

  describe "task terminal states" do
    setup :editor_context

    test "DOWN fails a still-importing target", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Crashing"})
      {:ok, importing} = Versions.claim_staging_gtfs_version(organization.id, staging.id)

      ref = make_ref()
      put_socket_assigns(view, %{import_task: ref, import_target: importing, importing: true})

      send(view.pid, {:DOWN, ref, :process, self(), :killed})
      render(view)

      failed = Versions.get_gtfs_version_for_lifecycle(organization.id, importing.id)
      assert failed.publication_status == "failed"
    end

    test "DOWN never overwrites a terminal (failed) target", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Terminal"})
      {:ok, _importing} = Versions.claim_staging_gtfs_version(organization.id, staging.id)
      {:ok, already_failed} = Versions.fail_unpublished_gtfs_version(organization.id, staging.id)

      ref = make_ref()

      put_socket_assigns(view, %{import_task: ref, import_target: already_failed, importing: true})

      send(view.pid, {:DOWN, ref, :process, self(), :killed})
      render(view)

      still_failed = Versions.get_gtfs_version_for_lifecycle(organization.id, staging.id)
      assert still_failed.publication_status == "failed"
    end

    test "publication failure result leaves the target importing and names it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "PubFail"})
      {:ok, importing} = Versions.claim_staging_gtfs_version(organization.id, staging.id)

      ref = make_ref()
      put_socket_assigns(view, %{import_task: ref, import_target: importing, importing: true})

      send(view.pid, {ref, {:error, importing, {:publication_failed, :db_down}}})
      html = render(view)

      assert html =~ "Publication failed"
      assert html =~ "PubFail"

      # The LiveView must not overwrite the importing state; it stays importing.
      current = Versions.get_gtfs_version_for_lifecycle(organization.id, importing.id)
      assert current.publication_status == "importing"
    end

    test "import/claim error result names the failed target", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: route_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "ImportErr"})
      {:ok, failed} = Versions.fail_unpublished_gtfs_version(organization.id, staging.id)

      ref = make_ref()
      put_socket_assigns(view, %{import_task: ref, import_target: failed, importing: true})

      send(view.pid, {ref, {:error, failed, {:import_not_publishable, :whatever}}})
      html = render(view)

      assert html =~ "Import failed"
      assert html =~ "ImportErr"
    end
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

      view
      |> element("button[phx-click='approve-all'][phx-value-action='add']")
      |> render_click()

      html = view |> element("#diff-apply-btn") |> render_click()

      assert html =~ "Applied 1 decisions successfully, 0 failed."

      # The change landed on the route version and created no new version rows.
      child = Gtfs.get_stop_by_stop_id(organization.id, version.id, "CHILD_DIFF_NO_LEVEL")
      assert child.parent_station == "PARENT_STATION_DIFF"
      assert length(all_versions(organization.id)) == before_versions
      assert length(published_versions(organization.id)) == before_published
    end
  end
end
