defmodule GtfsPlannerWeb.HeaderTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  describe "Header - Unauthenticated Users (Auth Layout)" do
    test "displays Pathways Studio brand with semantic tokens", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      assert html =~ "text-brand"
      assert html =~ "Pathways Studio"
      assert html =~ "bg-brand"
    end

    test "does not display logout button", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      refute html =~ "/users/log_out"
    end

    test "auth layout uses semantic border not shadow", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      assert html =~ "border-base-300"
      refute html =~ "shadow"
    end
  end

  describe "Header - Authenticated Users" do
    test "displays Pathways Studio brand link with semantic tokens", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#app-header a[href='/']", "Pathways Studio")
      assert has_element?(view, "#app-header .bg-brand img")
      assert has_element?(view, "#app-header span.text-brand", "Pathways Studio")
    end

    test "account menu trigger is icon-only, labeled and paneled with the email", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      # Icon-only trigger: identity is in the accessible name and the panel, not
      # visible header text.
      trigger_html =
        view
        |> element("#app-header #user-menu [data-user-menu-trigger][aria-haspopup='menu']")
        |> render()

      assert trigger_html =~ user.email
      assert has_element?(view, "#user-menu-panel", "Signed in as")
      assert has_element?(view, "#user-menu-panel", user.email)
    end

    test "log out is a menu item with visible label and 44px target", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#user-menu-panel a[href='/users/log_out'][role='menuitem']",
               "Log out"
             )

      assert has_element?(view, "#user-menu-panel a[href='/users/log_out'].min-h-11")
    end

    test "logout item uses correct method and path", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "href=\"/users/log_out\""
      assert html =~ "data-method=\"delete\""
      assert has_element?(view, "#user-menu-panel a[href='/users/log_out']")
    end

    test "header wraps without horizontal overflow", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#app-header .flex-wrap")
    end

    test "navigation renders inside the header", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#app-header nav[aria-label='Main navigation']")
    end

    test "Account settings lives in the account menu, not the task nav", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#app-header #user-menu-panel a[href='/users/settings']",
               "Account settings"
             )

      refute has_element?(
               view,
               "#app-header nav[aria-label='Main navigation'] a[href='/users/settings']"
             )
    end

    test "Account settings is active on settings and inactive on dashboard", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, settings_view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(
               settings_view,
               "#app-header #user-menu-panel a[href='/users/settings'][aria-current='page']",
               "Account settings"
             )

      {:ok, dash_view, _html} = live(conn, ~p"/")

      refute has_element?(
               dash_view,
               "#app-header #user-menu-panel a[href='/users/settings'][aria-current='page']"
             )

      assert has_element?(
               dash_view,
               "#app-header #user-menu-panel a[href='/users/settings']:not([aria-current])"
             )
    end

    test "optional account context assigns status without requiring organization", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      # Dashboard remains reachable with no session organization (optional mode).
      assert html =~ "Pathways Studio"
      assert has_element?(view, "#dashboard-no-organization")
      assert has_element?(view, "#app-header #user-menu-panel a[href='/users/settings']")
    end

    test "design routes remain reachable without optional organization assigns", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/design/navigation")

      assert html =~ "Navigation"
      assert has_element?(view, "#ds-page-navigation")
      assert has_element?(view, "#app-header #user-menu-panel a[href='/users/settings']")
    end
  end

  describe "Document titles" do
    test "root title uses Pathways Studio suffix with page title", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "· Pathways Studio</title>"
      assert html =~ ~s(data-default="Pathways Studio")
      assert html =~ ~s(data-suffix=" · Pathways Studio")
    end

    test "settings title uses Pathways Studio shell", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/users/settings")

      assert html =~ "· Pathways Studio</title>"
      assert html =~ ~s(data-default="Pathways Studio")
      assert html =~ ~s(data-suffix=" · Pathways Studio")
    end

    test "auth page renders Pathways Studio brand", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      assert html =~ "Pathways Studio"
    end
  end
end
