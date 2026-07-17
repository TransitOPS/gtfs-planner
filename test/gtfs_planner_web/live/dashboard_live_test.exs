defmodule GtfsPlannerWeb.DashboardLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  describe "Dashboard" do
    test "redirects unauthenticated users to login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/")
    end

    test "displays dashboard for authenticated users", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Dashboard"
      assert html =~ user.email
    end

    test "shows welcome message with user email", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Welcome to Pathways Studio"
      assert html =~ "You are logged in as #{user.email}"
    end

    test "provides link to organizations page for administrators", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      # Create administrator membership
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["administrator"]
      })

      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a[href=\"/admin/organizations\"]", "Manage Organizations")
    end
  end

  describe "handle_info({:gtfs_version_renamed, _}, socket)" do
    test "refreshes available_versions and leaves current_gtfs_version unchanged when a non-current version is renamed",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      {:ok, _newest} = Versions.create_gtfs_version(organization.id, %{name: "Newest Version"})

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:organization_id, organization.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assigns_before = :sys.get_state(view.pid).socket.assigns
      current_id_before = assigns_before.current_gtfs_version.id

      {non_current_id, _name} =
        Enum.find(assigns_before.available_versions, fn {id, _name} -> id != current_id_before end)

      non_current = Versions.get_published_gtfs_version_for_org!(organization.id, non_current_id)
      original_name = non_current.name

      {:ok, renamed_other} = Versions.update_gtfs_version(non_current, %{name: "Renamed Other"})

      send(view.pid, {:gtfs_version_renamed, renamed_other})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns

      assert assigns_after.current_gtfs_version.id == current_id_before
      assert {non_current_id, "Renamed Other"} in assigns_after.available_versions
      refute {non_current_id, original_name} in assigns_after.available_versions
    end

    test "updates current_gtfs_version when the renamed version is the current one",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      {:ok, _other} = Versions.create_gtfs_version(organization.id, %{name: "Other Version"})

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:organization_id, organization.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assigns_before = :sys.get_state(view.pid).socket.assigns
      current = assigns_before.current_gtfs_version

      {:ok, renamed_current} = Versions.update_gtfs_version(current, %{name: "Renamed Current"})

      send(view.pid, {:gtfs_version_renamed, renamed_current})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns

      assert assigns_after.current_gtfs_version.id == current.id
      assert assigns_after.current_gtfs_version.name == "Renamed Current"
      assert {current.id, "Renamed Current"} in assigns_after.available_versions
    end

    test "is a safe no-op for administrators without a current_organization", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["administrator"]
      })

      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assigns_before = :sys.get_state(view.pid).socket.assigns
      assert assigns_before.current_organization == nil
      assert assigns_before.current_gtfs_version == nil

      send(view.pid, {:gtfs_version_renamed, %{id: Ecto.UUID.generate(), name: "X"}})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns
      assert assigns_after.current_organization == nil
      assert assigns_after.current_gtfs_version == nil
      assert assigns_after.available_versions == assigns_before.available_versions
    end
  end
end
