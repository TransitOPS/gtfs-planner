defmodule GtfsPlannerWeb.Design.DesignSystemLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  alias GtfsPlannerWeb.Design.DesignSystemLive

  setup do
    %{user: user_fixture()}
  end

  describe "access" do
    test "redirects unauthenticated visitors to the log in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/design")
    end
  end

  describe "index action" do
    test "lands on the introduction page inside the content column", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = conn |> live(~p"/design") |> follow_redirect(conn)

      assert has_element?(view, "#design-page-content #ds-page-introduction")
    end
  end

  describe "sidebar" do
    test "renders a patch link for every registry entry", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      for %{slug: slug, title: title} <- DesignSystemLive.pages() do
        assert has_element?(view, ~s(#design-sidebar a[href="/design/#{slug}"]), title)
      end
    end

    test "renders both group headings", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      assert has_element?(view, "#design-sidebar", "Foundations")
      assert has_element?(view, "#design-sidebar", "Components")
    end

    test "orders Foundations before Components", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      headings =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#design-sidebar h2")
        |> LazyHTML.text()

      assert headings == "FoundationsComponents"
    end
  end

  describe "show action" do
    test "marks the active link with aria-current and leaves others unmarked", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/colors")

      assert has_element?(view, ~s(#design-sidebar a[href="/design/colors"][aria-current="page"]))
      refute has_element?(view, ~s(#design-sidebar a[href="/design/introduction"][aria-current]))
    end

    test "recovers to the introduction page for an unknown slug", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = conn |> live(~p"/design/does-not-exist") |> follow_redirect(conn)

      assert has_element?(view, "#design-page-content #ds-page-introduction")
    end
  end

  describe "page bodies" do
    for %{slug: slug, title: title} <- GtfsPlannerWeb.Design.DesignSystemLive.pages() do
      test "renders the #{slug} page body", %{conn: conn, user: user} do
        conn = log_in_user(conn, user)

        {:ok, view, _html} = live(conn, ~p"/design/#{unquote(slug)}")

        assert has_element?(view, "#design-page-content #ds-page-#{unquote(slug)}")
        assert has_element?(view, "#ds-page-#{unquote(slug)}", unquote(title))
      end
    end
  end
end
