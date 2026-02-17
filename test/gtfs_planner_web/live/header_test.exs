defmodule GtfsPlannerWeb.HeaderTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  describe "Header - Unauthenticated Users (Auth Layout)" do
    test "displays Pathways Studio logo text", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/log_in")

      # Auth layout displays logo text in a span, not a link
      assert html =~ "Pathways Studio"
    end

    test "does not display logout button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log_in")

      refute has_element?(view, "a[href='/users/log_out']", "Log out")
    end
  end

  describe "Header - Authenticated Users" do
    test "displays Pathways Studio logo text", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Pathways Studio"
      assert has_element?(view, "a[href='/']", "Pathways Studio")
    end

    test "displays logout button", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a[href='/users/log_out']", "Log out")
    end

    test "logout button uses correct method and path", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      # Verify logout link exists with correct attributes
      assert html =~ "href=\"/users/log_out\""
      assert html =~ "data-method=\"delete\""
      assert has_element?(view, "a[href='/users/log_out']", "Log out")
    end
  end
end
