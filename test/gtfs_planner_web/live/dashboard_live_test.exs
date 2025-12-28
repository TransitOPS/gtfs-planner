defmodule GtfsPlannerWeb.DashboardLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

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

      assert html =~ "Welcome to GTFS Planner"
      assert html =~ "You are logged in as #{user.email}"
    end

    test "provides link to organizations page", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a[href=\"/organizations\"]", "View Organizations")
    end
  end
end
