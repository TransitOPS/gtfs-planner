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

    test "displays logout with accessible name and 44px target", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      # Icon-only control: the accessible name comes from aria-label/title, not
      # visible text.
      assert has_element?(
               view,
               "a[href='/users/log_out'][aria-label='Log out of your account'][title='Log out']"
             )

      assert has_element?(view, "#app-header a[href='/users/log_out'].min-h-11.min-w-11")
    end

    test "logout button uses correct method and path", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "href=\"/users/log_out\""
      assert html =~ "data-method=\"delete\""
      assert has_element?(view, "a[href='/users/log_out'][aria-label='Log out of your account']")
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

    test "auth page renders Pathways Studio brand", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      assert html =~ "Pathways Studio"
    end
  end
end
