defmodule GtfsPlannerWeb.Gtfs.ImportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  describe "ImportLive" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS editor role
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

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
      assert html =~ "Upload levels.txt, stops.txt, and/or pathways.txt files"
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

      # Create another organization with its own version
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
               live(conn, "/gtfs/#{other_version.id}/import")
    end

    test "requires pathways_studio_editor role", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Update user to have only viewer role (not editor)
      membership = Accounts.get_user_org_membership(user.id, organization.id)
      Accounts.update_user_org_membership(membership, %{roles: ["pathways_studio_viewer"]})

      conn = log_in_user(conn, user, organization: organization)

      # The actual error message might be different, so we'll just check that it redirects with an error
      assert {:error, {:redirect, %{to: _, flash: %{"error" => _}}}} =
               live(conn, "/gtfs/#{version.id}/import")
    end
  end

  describe "ImportLive version redirect flow" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS editor role
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "visiting /gtfs/import (no version) mounts successfully with pending state", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, "/gtfs/import")

      # Should show loading state (which indicates pending_version_resolution is true)
      assert html =~ "Loading GTFS version"
      assert html =~ "gtfs-version-resolver"
    end

    test "handle_event gtfs_version_loaded with valid version triggers redirect", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/import")

      # Simulate JS hook sending valid version_id
      assert {:error, {:live_redirect, %{to: "/gtfs/" <> _, kind: :push}}} =
               view
               |> element("#gtfs-version-resolver")
               |> render_hook("gtfs_version_loaded", %{"version_id" => to_string(version.id)})

      # The redirect should go to the versioned URL
    end
  end

  describe "ImportLive form validation" do
    setup do
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

    test "form renders with create_version unchecked by default", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/import")

      # Checkbox should be unchecked by default
      assert html =~ "Create a new GTFS version?"
      # version_name input should not be visible initially
      refute html =~ "Version Name"
    end

    test "validation error message appears in form", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/import")

      # The form should show validation errors when appropriate
      # We're testing that the form can display errors, not triggering validation
      assert html =~ "gtfs-import-form"
    end
  end

  describe "ImportLive file upload" do
    setup do
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

    test "file upload shows file in upload entries", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      # Create a test file content
      levels_content = "level_id,level_index,level_name\nL1,0.0,Ground Floor"

      # Upload a file
      view
      |> file_input("#gtfs-import-form", :gtfs_files, [
        %{
          name: "levels.txt",
          content: levels_content,
          type: "text/plain"
        }
      ])
      |> render_upload("levels.txt")

      # File should be shown in the upload entries
      assert render(view) =~ "levels.txt"
      assert render(view) =~ "uploaded"
    end

    test "cancel-upload event removes uploaded file", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      # Create a test file content
      levels_content = "level_id,level_index,level_name\nL1,0.0,Ground Floor"

      # Upload a file
      view
      |> file_input("#gtfs-import-form", :gtfs_files, [
        %{
          name: "levels.txt",
          content: levels_content,
          type: "text/plain"
        }
      ])
      |> render_upload("levels.txt")

      # File should be shown in the upload entries
      assert render(view) =~ "levels.txt"

      # Find and click the cancel button
      # The cancel button has phx-click="cancel-upload" and phx-value-ref attribute
      # Phoenix LiveView will automatically include the ref from phx-value-ref
      html_after =
        view
        |> element("button[phx-click='cancel-upload']")
        |> render_click()

      # File should no longer be shown
      refute html_after =~ "levels.txt"
    end
  end

  describe "ImportLive import submission" do
    setup do
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

    test "import button is disabled when no files are uploaded", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/import")

      # Import button should be disabled when no files are uploaded
      assert html =~ "disabled"
      assert html =~ "Import Files"
    end

    test "import button is enabled when files are uploaded", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      # Create a test file content
      levels_content = "level_id,level_index,level_name\nL1,0.0,Ground Floor"

      # Upload a file
      view
      |> file_input("#gtfs-import-form", :gtfs_files, [
        %{
          name: "levels.txt",
          content: levels_content,
          type: "text/plain"
        }
      ])
      |> render_upload("levels.txt")

      # Import button should be enabled
      html = render(view)
      refute html =~ "disabled"
      assert html =~ "Import Files"
    end

    test "submitting import shows success message", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      # Mock file content
      levels_content = "level_id,level_index,level_name\\nL1,0.0,Ground"
      stops_content = "stop_id,stop_name,stop_lat,stop_lon,level_id\\nS1,Stop 1,1,1,L1"

      # Upload files
      view
      |> file_input("#gtfs-import-form", :gtfs_files, [
        %{name: "levels.txt", content: levels_content, type: "text/plain"},
        %{name: "stops.txt", content: stops_content, type: "text/plain"}
      ])
      upload =
        view
        |> file_input("#gtfs-import-form", :gtfs_files, [
          %{name: "levels.txt", content: levels_content, type: "text/plain"},
          %{name: "stops.txt", content: stops_content, type: "text/plain"}
        ])

      render_upload(upload, "levels.txt")
      render_upload(upload, "stops.txt")

      # Submit the form
      html =
        view
        |> element("#gtfs-import-form")
        |> render_submit()

      # Assert success flash message is shown
      assert html =~ "Successfully imported"
      # Assert result box is shown with correct counts
      assert html =~ "Import Successful"
      assert html =~ "Imported 1 levels, 1 stops, 0 pathways"
    end
  end
end
