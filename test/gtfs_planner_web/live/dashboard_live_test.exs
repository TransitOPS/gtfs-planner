defmodule GtfsPlannerWeb.DashboardLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts

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
end
