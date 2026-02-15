defmodule GtfsPlannerWeb.Gtfs.StopsLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  describe "StopsLive" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS access
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
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

    test "paginates stations", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      Enum.each(1..51, fn idx ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "S#{String.pad_leading(Integer.to_string(idx), 3, "0")}",
          stop_name: "Station #{String.pad_leading(Integer.to_string(idx), 3, "0")}",
          parent_station: nil
        })
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      html =
        view
        |> element("button[phx-click='paginate'][phx-value-page='2']")
        |> render_click()

      assert html =~ "Station 051"
      refute html =~ "Station 001"
      assert_patch(view, "/gtfs/#{version.id}/stops?page=2")
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
        roles: ["pathways_studio_editor"]
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

  describe "route filtering" do
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

    test "can filter by route", %{
      conn: conn,
      user: user,
      organization: org,
      gtfs_version: version
    } do
      # Setup data: Route1 serves Station1, Route2 serves Station2
      station1 = stop_fixture(org.id, version.id, %{stop_id: "S1", stop_name: "Station 1"})
      route1 = route_fixture(org.id, version.id, %{route_id: "R1", route_short_name: "Route 1"})
      trip1 = trip_fixture(org.id, version.id, route1.route_id, %{trip_id: "T1"})
      stop_time_fixture(org.id, version.id, trip1.trip_id, station1.stop_id)

      station2 = stop_fixture(org.id, version.id, %{stop_id: "S2", stop_name: "Station 2"})
      route2 = route_fixture(org.id, version.id, %{route_id: "R2", route_short_name: "Route 2"})
      trip2 = trip_fixture(org.id, version.id, route2.route_id, %{trip_id: "T2"})
      stop_time_fixture(org.id, version.id, trip2.trip_id, station2.stop_id)

      conn = log_in_user(conn, user, organization: org)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/stops")

      # Verify Routes column and filter exist
      assert html =~ "Routes"
      assert has_element?(view, "#station-filter-form select[name='route_id']")

      # Verify route badges are displayed
      assert html =~ "Route 1"
      assert html =~ "Route 2"

      # Filter by Route 1
      html =
        view
        |> form("#station-filter-form", %{"route_id" => "R1"})
        |> render_change()

      # Verify only Station 1 is shown
      assert html =~ "Station 1"
      refute html =~ "Station 2"
      assert_patch(view, "/gtfs/#{version.id}/stops?route_id=R1")
    end
  end
end
