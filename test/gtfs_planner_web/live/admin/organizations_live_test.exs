defmodule GtfsPlannerWeb.Admin.OrganizationsLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts

  setup %{conn: conn} do
    # Create a system administrator user
    organization = organization_fixture()
    user = user_fixture()

    # Create administrator membership
    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["administrator"]
    })

    # Log in the user and set organization in session
    conn =
      conn
      |> log_in_user(user)
      |> Plug.Conn.put_session(:organization_id, organization.id)

    %{conn: conn, user: user, organization: organization}
  end

  describe "drawer form submission" do
    test "creates organization via drawer form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      # Fill and submit the form
      assert view
             |> form("#org-form", organization: %{name: "New Test Org", alias: "new-test-org"})
             |> render_submit()

      # Assert patched to index (push_patch stays on same LiveView)
      assert_patch(view, ~p"/admin/organizations")

      # Navigate to index and verify new org is in the list
      {:ok, index_view, html} = live(conn, ~p"/admin/organizations")

      assert html =~ "New Test Org"
      assert html =~ "new-test-org"
      assert has_element?(index_view, "#organizations")
    end

    test "edits organization via drawer form", %{conn: conn} do
      # Create an organization to edit
      org = organization_fixture(%{name: "Original Name", alias: "original-alias"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{org.id}/edit")

      # Change the name
      assert view
             |> form("#org-form", organization: %{name: "Updated Name"})
             |> render_submit()

      # Assert patched to index (push_patch stays on same LiveView)
      assert_patch(view, ~p"/admin/organizations")

      # Navigate to index and verify org is updated
      {:ok, index_view, html} = live(conn, ~p"/admin/organizations")

      assert html =~ "Updated Name"
      assert html =~ "original-alias"
      assert has_element?(index_view, "#organizations")
    end

    test "shows validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      # Submit empty form
      html =
        view
        |> form("#org-form", organization: %{name: "", alias: ""})
        |> render_submit()

      # Assert error messages are visible
      assert html =~ "can&#39;t be blank"
    end
  end
end