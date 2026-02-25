defmodule GtfsPlannerWeb.Gtfs.ImportLiveDiffTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

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
