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

    test "renders invite member form for administrator", %{conn: conn, organization: organization} do
      {:ok, _view, html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

      # Assert page contains expected content
      assert html =~ "Invite Member"
      assert html =~ "Email"

      # Assert form element exists
      assert html =~ "invite-form"
    end

    test "invites new user to organization", %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

      # Fill and submit the invite form
      assert view
             |> form("#invite-form",
               invite: %{email: "newuser@example.com", roles: ["pathways_studio_editor"]}
             )
             |> render_submit()

      # Assert patched to organization show page
      assert_patch(view, ~p"/admin/organizations/#{organization.id}")

      # Verify user was created
      user = Accounts.get_user_by_email("newuser@example.com")
      assert user
      assert user.email == "newuser@example.com"

      # Verify membership exists with correct roles
      memberships = Accounts.list_user_org_memberships(user.id)
      membership = Enum.find(memberships, &(&1.organization_id == organization.id))
      assert membership
      assert "pathways_studio_editor" in membership.roles
    end
  end
end
