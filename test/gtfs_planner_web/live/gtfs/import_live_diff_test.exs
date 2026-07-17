defmodule GtfsPlannerWeb.Gtfs.ImportLiveDiffTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  defp await_import_task(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    render(view)
  end

  describe "reviewed diff isolation after a full-feed publication" do
    setup %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()
      route_version = gtfs_version_fixture(organization.id)

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{route_version.id}/import")

      %{view: view, organization: organization, route_version: route_version}
    end

    test "diff still targets the route version after a new version is published", %{
      view: view,
      organization: organization,
      route_version: route_version
    } do
      # First, run a successful full-feed import that publishes a new version.
      upload =
        file_input(view, "#gtfs-import-form", :gtfs_files, [
          %{
            name: "levels.txt",
            content: "level_id,level_index,level_name\nL1,0.0,Ground",
            type: "text/plain"
          }
        ])

      render_upload(upload, "levels.txt")

      view
      |> form("#gtfs-import-form", %{
        "gtfs_import_form" => %{"version_name" => "Published Import"}
      })
      |> render_submit()

      await_import_task(view)

      published = Enum.find(all_versions(organization.id), &(&1.name == "Published Import"))
      assert published.publication_status == "published"
      assert published.id != route_version.id

      # The reviewed-diff destination remains anchored to the route version.
      assert has_element?(view, "#diff-destination", route_version.name)

      # A reviewed diff apply writes to the route version, not the published one.
      levels_content = "level_id,level_index,level_name\nDIFFLVL,2.0,Diff Level"

      diff_upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(diff_upload, "levels.txt")

      view |> form("#diff-upload-form", %{}) |> render_submit()

      view
      |> element("button[phx-click='approve-all'][phx-value-action='add']")
      |> render_click()

      view |> element("#diff-apply-btn") |> render_click()

      assert Gtfs.get_level_by_level_id(organization.id, route_version.id, "DIFFLVL")
      refute Gtfs.get_level_by_level_id(organization.id, published.id, "DIFFLVL")
    end
  end

  defp all_versions(organization_id) do
    import Ecto.Query

    GtfsPlanner.Repo.all(
      from(v in Versions.GtfsVersion, where: v.organization_id == ^organization_id)
    )
  end

  describe "station diff workflow" do
    setup %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/import")

      %{view: view, organization: organization, gtfs_version: gtfs_version}
    end

    test "renders update station data section", %{view: view} do
      assert has_element?(view, "#diff-upload-form")
      assert has_element?(view, "#diff-compute-btn")
      refute has_element?(view, "#diff-reset-btn")
    end

    test "duplicate entity file blocks diff globally and offers recovery", %{view: view} do
      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"dup.zip",
          [
            {~c"levels.txt", "level_id,level_index,level_name\nL1,0.0,Level 1"},
            {~c"levels.txt", "level_id,level_index,level_name\nL2,1.0,Level 2"}
          ],
          [:memory]
        )

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "dup.zip", content: zip_binary, type: "application/zip"}
        ])

      render_upload(upload, "dup.zip")
      view |> form("#diff-upload-form") |> render_submit()

      # Global blocker suppresses both review regions and the decision table.
      assert has_element?(view, "#diff-blockers")
      assert has_element?(view, "#diff-choose-corrected-files", "Choose corrected files")
      refute has_element?(view, "#diff-decisions")
      refute has_element?(view, "#diff-preview-region")
      refute has_element?(view, "#diff-apply-btn")
    end

    test "incomplete levels.txt renders degraded region with bounded diagnostics", %{
      view: view
    } do
      # levels.txt missing the required level_id header fails structural completeness.
      levels_content = "level_index,level_name\n0.0,Ground"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")
      view |> form("#diff-upload-form") |> render_submit()

      assert has_element?(view, "#diff-degraded-region")
      assert has_element?(view, "#diff-degraded-region", "levels.txt")
      # The degraded region names the entity type and error count.
      assert has_element?(view, "#diff-degraded-region", "Levels")
      # The apply button is suppressed while a file is degraded (no applicable decisions).
      assert has_element?(view, "#diff-apply-btn[disabled]")
      refute has_element?(view, "#diff-preview-region")
    end

    test "failed entity renders read-only preview while complete entity stays applicable", %{
      view: view,
      gtfs_version: gtfs_version,
      organization: organization
    } do
      # levels.txt is complete and applicable; stops.txt is missing its header
      # so it degrades into a read-only preview only.
      levels_content = "level_id,level_index,level_name\nL1,0.0,Level 1"

      stops_content = "stop_id,stop_name,stop_lat,stop_lon,location_type\nS1,Stop 1,40.0,-74.0,0\nS1,Duplicate,40.1,-74.1,0"

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"mixed.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content}
          ],
          [:memory]
        )

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "mixed.zip", content: zip_binary, type: "application/zip"}
        ])

      render_upload(upload, "mixed.zip")
      view |> form("#diff-upload-form", %{}) |> render_submit()

      # Complete level decision keeps its approval controls (applicable).
      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='level:L1']")

      # Degraded stops produces a read-only preview region with no action buttons.
      assert has_element?(view, "#diff-preview-region")
      assert has_element?(view, "#diff-preview-decisions", "stop")

      # The preview row for the failed stop has no approve/reject controls.
      refute has_element?(
               view,
               "#diff-preview-decisions button[phx-click='approve-decision'][phx-value-id='stop:S1']"
             )

      # The full-feed / applicable apply button still exists for the applicable level.
      assert has_element?(view, "#diff-apply-btn")
      _ = {organization, gtfs_version}
    end

    test "computes diff decisions from uploaded files", %{view: view} do
      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"station-diff.zip",
          [
            {~c"levels.txt", "level_id,level_index,level_name\nL1,0.0,Level 1"},
            {~c"stops.txt",
             "stop_id,stop_name,stop_lat,stop_lon,location_type\nS1,Stop 1,40.0,-74.0,0\nS2,Stop 2,40.1,-74.1,0"},
            {~c"pathways.txt",
             "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional\nP1,S1,S2,1,1"}
          ],
          [:memory]
        )

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "station-diff.zip", content: zip_binary, type: "application/zip"}
        ])

      render_upload(upload, "station-diff.zip")

      view
      |> form("#diff-upload-form")
      |> render_submit()

      assert has_element?(view, "#diff-filter-all")
      assert has_element?(view, "#diff-apply-btn")
      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='level:L1']")
      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='stop:S1']")
      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='pathway:P1']")
    end

    test "filters decisions by action", %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      level_fixture(organization.id, gtfs_version.id, %{level_id: "L1", level_name: "Old"})

      levels_content =
        "level_id,level_index,level_name\nL1,0.0,New\nL2,1.0,Second"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")

      view
      |> form("#diff-upload-form")
      |> render_submit()

      view
      |> element("#diff-filter-add")
      |> render_click()

      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='level:L2']")
      refute has_element?(view, "button[phx-click='approve-decision'][phx-value-id='level:L1']")
    end

    test "approves and rejects a single decision", %{view: view} do
      levels_content = "level_id,level_index,level_name\nL1,0.0,Level 1"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")

      view
      |> form("#diff-upload-form")
      |> render_submit()

      view
      |> element("button[phx-click='approve-decision'][phx-value-id='level:L1']")
      |> render_click()

      assert has_element?(view, "#diff-apply-btn", "Apply Approved (1)")

      view
      |> element("button[phx-click='reject-decision'][phx-value-id='level:L1']")
      |> render_click()

      assert has_element?(view, "#diff-apply-btn", "Apply Approved (0)")
    end

    test "bulk approve marks matching actions", %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      level_fixture(organization.id, gtfs_version.id, %{level_id: "L1", level_name: "Old"})

      levels_content =
        "level_id,level_index,level_name\nL1,0.0,New\nL2,1.0,Second"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")

      view
      |> form("#diff-upload-form")
      |> render_submit()

      view
      |> element("button[phx-click='approve-all'][phx-value-action='add']")
      |> render_click()

      assert has_element?(view, "#diff-apply-btn", "Apply Approved (1)")

      view
      |> element("button[phx-click='approve-all'][phx-value-action='modify']")
      |> render_click()

      assert has_element?(view, "#diff-apply-btn", "Apply Approved (2)")
    end

    test "applies approved decisions and transitions to done", %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      level_fixture(organization.id, gtfs_version.id, %{level_id: "L1", level_name: "Old"})

      levels_content = "level_id,level_index,level_name\nL1,0.0,Updated Name"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")

      view
      |> form("#diff-upload-form")
      |> render_submit()

      view
      |> element("button[phx-click='approve-decision'][phx-value-id='level:L1']")
      |> render_click()

      view
      |> element("#diff-apply-btn")
      |> render_click()

      assert has_element?(view, "#diff-reset-btn")
      assert has_element?(view, ".rounded-lg", "Applied 1 decisions successfully, 0 failed.")
      refute has_element?(view, "#diff-apply-btn")

      updated = Gtfs.get_level_by_level_id(organization.id, gtfs_version.id, "L1")
      assert updated.level_name == "Updated Name"
    end

    test "approve-decision on preview or unknown id leaves approved count at zero", %{
      view: view
    } do
      # levels.txt is complete and applicable; stops.txt has a duplicate
      # natural key so it degrades into read-only preview decisions.
      levels_content = "level_id,level_index,level_name\nL1,0.0,Level 1"

      stops_content = "stop_id,stop_name,stop_lat,stop_lon,location_type\nS1,Stop 1,40.0,-74.0,0\nS1,Duplicate,40.1,-74.1,0"

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"mixed.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content}
          ],
          [:memory]
        )

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "mixed.zip", content: zip_binary, type: "application/zip"}
        ])

      render_upload(upload, "mixed.zip")
      view |> form("#diff-upload-form", %{}) |> render_submit()

      # A crafted approve-decision for a preview id (stop:S1) is ignored.
      render_click(view, "approve-decision", %{"id" => "stop:S1"})

      # A crafted approve-decision for an unknown id is ignored.
      render_click(view, "approve-decision", %{"id" => "level:DOES-NOT-EXIST"})

      # No decision is approved; review state is unchanged.
      assert has_element?(view, "#diff-apply-btn", "Apply Approved (0)")
      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='level:L1']")
    end

    test "crafted apply-decisions performs zero database mutations when nothing is approved", %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      level_fixture(organization.id, gtfs_version.id, %{level_id: "L1", level_name: "Old"})

      levels_content = "level_id,level_index,level_name\nL1,0.0,Updated Name"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")
      view |> form("#diff-upload-form") |> render_submit()

      # Capture DB state before any crafted apply.
      before_level = Gtfs.get_level_by_level_id(organization.id, gtfs_version.id, "L1")

      # Crafted apply-decisions with nothing approved mutates nothing.
      render_click(view, "apply-decisions")

      after_level = Gtfs.get_level_by_level_id(organization.id, gtfs_version.id, "L1")

      assert before_level.level_name == after_level.level_name
      # The apply step transitions to done even with zero approved decisions.
      refute has_element?(view, "#diff-apply-btn")
      assert has_element?(view, "#diff-reset-btn")
    end

    test "crafted apply-decisions with preview-only stops performs zero mutations", %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      # levels.txt complete/applicable; stops.txt has a duplicate natural key so
      # it degrades to read-only preview only (no applicable stop decision).
      levels_content = "level_id,level_index,level_name\nL1,0.0,Level 1"

      stops_content = "stop_id,stop_name,stop_lat,stop_lon,location_type\nS1,Stop 1,40.0,-74.0,0\nS1,Duplicate,40.1,-74.1,0"

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"mixed.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content}
          ],
          [:memory]
        )

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "mixed.zip", content: zip_binary, type: "application/zip"}
        ])

      render_upload(upload, "mixed.zip")
      view |> form("#diff-upload-form", %{}) |> render_submit()

      before_levels = Gtfs.count_levels(organization.id, gtfs_version.id)
      before_stops = length(Gtfs.list_stops(organization.id, gtfs_version.id))

      # Crafted apply-decisions reaching only decisions_by_id (empty approvals).
      render_click(view, "apply-decisions")

      after_levels = Gtfs.count_levels(organization.id, gtfs_version.id)
      after_stops = length(Gtfs.list_stops(organization.id, gtfs_version.id))

      assert before_levels == after_levels
      assert before_stops == after_stops
      # The preview stop never reaches the database.
      refute Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "S1")
    end

    test "approve-all only marks decisions present in the applicable map", %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      level_fixture(organization.id, gtfs_version.id, %{level_id: "L1", level_name: "Old"})

      levels_content =
        "level_id,level_index,level_name\nL1,0.0,New\nL2,1.0,Second"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")
      view |> form("#diff-upload-form") |> render_submit()

      # Approve the add action only; the modify decision must remain unapproved.
      view
      |> element("button[phx-click='approve-all'][phx-value-action='add']")
      |> render_click()

      assert has_element?(view, "#diff-apply-btn", "Apply Approved (1)")

      # Only the add decision (L2) is approved; the modify decision (L1) is not.
      refute has_element?(view, "#diff-apply-btn", "Apply Approved (2)")

      # A crafted approve-decision for a preview/unknown id cannot inflate count.
      render_click(view, "approve-decision", %{"id" => "level:GHOST"})
      assert has_element?(view, "#diff-apply-btn", "Apply Approved (1)")
    end

    test "recompute with corrected files replaces stale approvals and restores removals", %{
      view: view,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      # Seed a level that will become a removal once a complete levels file is uploaded.
      level_fixture(organization.id, gtfs_version.id, %{level_id: "L1", level_name: "To Remove"})

      # First upload: levels.txt is missing its header -> degraded, no removals.
      bad_levels = "level_index,level_name\n0.0,Ground"

      bad_upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: bad_levels, type: "text/plain"}
        ])

      render_upload(bad_upload, "levels.txt")
      view |> form("#diff-upload-form") |> render_submit()

      assert has_element?(view, "#diff-degraded-region")
      refute has_element?(view, "#diff-preview-region")

      # Approve-all on the (empty) applicable set; count stays zero.
      assert has_element?(view, "#diff-apply-btn", "Apply Approved (0)")

      # Corrected upload: complete levels.txt that omits L1 -> removal decision.
      good_levels = "level_id,level_index,level_name\nL2,1.0,Level 2"

      # Reset so the corrected file replaces the prior source entirely.
      view |> element("#diff-reset-btn") |> render_click()

      good_upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: good_levels, type: "text/plain"}
        ])

      render_upload(good_upload, "levels.txt")
      view |> form("#diff-upload-form") |> render_submit()

      # Stale degraded region and prior approvals are gone; the legitimate
      # removal decision for the now-absent L1 returns once the source is complete.
      refute has_element?(view, "#diff-degraded-region")
      refute has_element?(view, "#diff-preview-region")
      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='level:L1']")
      assert has_element?(view, "button[phx-click='approve-decision'][phx-value-id='level:L2']")

      # Approve the removal and apply.
      view
      |> element("button[phx-click='approve-decision'][phx-value-id='level:L1']")
      |> render_click()

      view |> element("#diff-apply-btn") |> render_click()

      refute Gtfs.get_level_by_level_id(organization.id, gtfs_version.id, "L1")
    end

    test "reset clears applicable and preview collections, failures, and blockers", %{
      view: view
    } do
      # A degraded upload populates parse failures and a preview region.
      levels_content = "level_id,level_index,level_name\nL1,0.0,Level 1"
      stops_content = "stop_id,stop_name,stop_lat,stop_lon,location_type\nS1,Stop 1,40.0,-74.0,0\nS1,Duplicate,40.1,-74.1,0"

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"mixed.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content}
          ],
          [:memory]
        )

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "mixed.zip", content: zip_binary, type: "application/zip"}
        ])

      render_upload(upload, "mixed.zip")
      view |> form("#diff-upload-form", %{}) |> render_submit()

      assert has_element?(view, "#diff-preview-region")

      view |> element("#diff-reset-btn") |> render_click()

      # All review state returns to the upload step.
      assert has_element?(view, "#diff-upload-form")
      refute has_element?(view, "#diff-filter-all")
      refute has_element?(view, "#diff-reset-btn")
      refute has_element?(view, "#diff-preview-region")
      refute has_element?(view, "#diff-degraded-region")
      refute has_element?(view, "#diff-blockers")
    end

    test "reset clears review state and returns upload step", %{view: view} do
      levels_content = "level_id,level_index,level_name\nL1,0.0,Level 1"

      upload =
        file_input(view, "#diff-upload-form", :diff_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")

      view
      |> form("#diff-upload-form")
      |> render_submit()

      assert has_element?(view, "#diff-filter-all")
      assert has_element?(view, "#diff-reset-btn")

      view
      |> element("#diff-reset-btn")
      |> render_click()

      assert has_element?(view, "#diff-upload-form")
      assert has_element?(view, "#diff-compute-btn")
      refute has_element?(view, "#diff-filter-all")
      refute has_element?(view, "#diff-reset-btn")
    end
  end
end
