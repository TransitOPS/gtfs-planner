defmodule GtfsPlannerWeb.Gtfs.StopsLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  describe "StopsLive" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS access
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_viewer"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "displays stations page with valid version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/stops")

      assert html =~ "Stations"
    end

    test "redirects with error for invalid version UUID", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      conn = log_in_user(conn, user, organization: organization)
      invalid_uuid = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
               live(conn, "/gtfs/#{invalid_uuid}/stops")
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
               live(conn, "/gtfs/#{other_version.id}/stops")
    end
  end

  describe "StopsLive version redirect flow" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS access
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_viewer"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "visiting /gtfs/stops (no version) mounts successfully with pending state", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, "/gtfs/stops")

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

      {:ok, view, _html} = live(conn, "/gtfs/stops")

      # Simulate JS hook sending valid version_id
      assert {:error, {:live_redirect, %{to: "/gtfs/" <> _, kind: :push}}} =
               view
               |> element("#gtfs-version-resolver")
               |> render_hook("gtfs_version_loaded", %{"version_id" => to_string(version.id)})

      # The redirect should go to the versioned URL
    end

    test "handle_event gtfs_version_loaded with nil falls back to latest version", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      conn = log_in_user(conn, user, organization: organization)

      # Create multiple versions
      {:ok, _version1} = GtfsPlanner.Versions.create_gtfs_version(organization.id, %{name: "V1"})
      Process.sleep(10)
      {:ok, version2} = GtfsPlanner.Versions.create_gtfs_version(organization.id, %{name: "V2"})

      {:ok, view, _html} = live(conn, "/gtfs/stops")

      # Simulate JS hook sending nil version_id (localStorage empty)
      result =
        view
        |> element("#gtfs-version-resolver")
        |> render_hook("gtfs_version_loaded", %{"version_id" => nil})

      # Should redirect to the latest version
      assert {:error, {:live_redirect, %{to: redirect_path, kind: :push}}} = result
      assert redirect_path =~ "/gtfs/#{version2.id}/stops"
    end

    test "handle_event gtfs_version_loaded with invalid version falls back to latest", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/stops")

      # Simulate JS hook sending invalid version_id
      invalid_uuid = Ecto.UUID.generate()

      result =
        view
        |> element("#gtfs-version-resolver")
        |> render_hook("gtfs_version_loaded", %{"version_id" => invalid_uuid})

      # Should fall back to latest version (the fixture version in this case)
      assert {:error, {:live_redirect, %{to: redirect_path, kind: :push}}} = result
      assert redirect_path =~ "/gtfs/#{version.id}/stops"
    end

    test "handle_event switch_gtfs_version navigates to new URL", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version1
    } do
      conn = log_in_user(conn, user, organization: organization)

      # Create another version to switch to
      {:ok, version2} = GtfsPlanner.Versions.create_gtfs_version(organization.id, %{name: "V2"})

      # Start on version1
      {:ok, view, _html} = live(conn, "/gtfs/#{version1.id}/stops")

      # Simulate switching to version2
      render_hook(view, "switch_gtfs_version", %{"version" => to_string(version2.id)})

      # Should trigger navigation to new version
      assert_redirect(view, "/gtfs/#{version2.id}/stops")
    end
  end
end
