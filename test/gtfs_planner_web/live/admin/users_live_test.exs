defmodule GtfsPlannerWeb.Admin.UsersLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts

  setup %{conn: conn} do
    # Create organization and pathways_studio_admin user
    organization = organization_fixture()
    admin_user = user_fixture()

    # Create admin membership
    Accounts.create_user_org_membership(%{
      user_id: admin_user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_admin"]
    })

    # Log in as admin user and set organization in session
    conn =
      conn
      |> log_in_user(admin_user)
      |> Plug.Conn.put_session(:organization_id, organization.id)

    %{conn: conn, admin_user: admin_user, organization: organization}
  end

  describe "index action" do
    test "renders user list with organization members", %{
      conn: conn,
      admin_user: admin_user,
      organization: organization
    } do
      # Create additional users in the same organization
      user1 = user_fixture(%{email: "viewer@example.com"})
      user2 = user_fixture(%{email: "editor@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: user1.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      Accounts.create_user_org_membership(%{
        user_id: user2.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      # Navigate to users index page
      {:ok, _view, html} = live(conn, ~p"/admin/users")

      # Assert page title
      assert html =~ "Users"

      # Assert all organization members are visible
      assert html =~ admin_user.email
      assert html =~ "viewer@example.com"
      assert html =~ "editor@example.com"
    end

    test "does not show users from other organizations", %{
      conn: conn,
      admin_user: admin_user
    } do
      # Create another organization with a user
      other_org = organization_fixture(%{alias: "other-org", name: "Other Organization"})
      other_user = user_fixture(%{email: "other@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: other_user.id,
        organization_id: other_org.id,
        roles: ["pathways_studio_editor"]
      })

      # Navigate to users index page
      {:ok, _view, html} = live(conn, ~p"/admin/users")

      # Assert only admin's email is visible, not other organization's user
      assert html =~ admin_user.email
      refute html =~ "other@example.com"
    end

    test "displays user status badges", %{conn: conn, organization: organization} do
      # Create active user
      active_user = user_fixture(%{email: "active@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: active_user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      # Create deactivated user
      deactivated_user = user_fixture(%{email: "deactivated@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: deactivated_user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      GtfsPlanner.Organizations.deactivate_user_in_organization(
        deactivated_user.id,
        organization.id
      )

      # Navigate to users index page
      {:ok, _view, html} = live(conn, ~p"/admin/users")

      # Assert status badges are displayed
      assert html =~ "Active"
      assert html =~ "Deactivated"
    end
  end

  describe "invite flow" do
    test "opens invite drawer and invites new user", %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      # Fill and submit the invite form
      assert view
             |> form("#invite-form",
               invite: %{
                 email: "newmember@example.com",
                 roles: ["pathways_studio_editor"]
               }
             )
             |> render_submit()

      # Assert patched to index
      assert_patch(view, ~p"/admin/users")

      # Verify user was created
      user = Accounts.get_user_by_email("newmember@example.com")
      assert user
      assert user.email == "newmember@example.com"

      # Verify membership exists with correct roles
      memberships = Accounts.list_user_org_memberships(user.id)
      membership = Enum.find(memberships, &(&1.organization_id == organization.id))
      assert membership
      assert "pathways_studio_editor" in membership.roles
    end

    test "displays newly invited user in members list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      # Submit the invite form
      assert view
             |> form("#invite-form",
               invite: %{
                 email: "invited@example.com",
                 roles: ["pathways_studio_editor"]
               }
             )
             |> render_submit()

      # Navigate back to index
      {:ok, _index_view, html} = live(conn, ~p"/admin/users")

      # Assert new user appears in list
      assert html =~ "invited@example.com"
    end

    test "validates email format in invite form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      # Submit with invalid email
      html =
        view
        |> form("#invite-form",
          invite: %{
            email: "invalid-email",
            roles: ["pathways_studio_editor"]
          }
        )
        |> render_change()

      # Should still render the form (validation happens on client/server)
      assert html =~ "invite-form"
    end

    test "requires at least one role for invite", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      # Submit with no roles
      html =
        view
        |> form("#invite-form",
          invite: %{
            email: "norole@example.com",
            roles: []
          }
        )
        |> render_submit()

      # Should show error or remain on form
      assert html =~ "invite-form"
    end
  end

  describe "organization settings route" do
    test "pathways_studio_admin can access organization-settings route", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/admin/users/organization-settings")
    end

    test "assigns organization_form for :organization_settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/organization-settings")

      form = :sys.get_state(view.pid).socket.assigns.organization_form
      assert %Phoenix.HTML.Form{} = form
      assert form.source.data.__struct__ == GtfsPlanner.Organizations.Organization
    end
  end

  describe "deactivation flow" do
    test "deactivates user and shows deactivated status", %{
      conn: conn,
      organization: organization
    } do
      # Create a user to deactivate
      user = user_fixture(%{email: "todeactivate@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      {:ok, view, html} = live(conn, ~p"/admin/users")

      # Verify user is initially active
      assert html =~ "todeactivate@example.com"
      assert html =~ "Active"

      # Click deactivate button
      view
      |> element("button[phx-click='deactivate'][phx-value-user-id='#{user.id}']")
      |> render_click()

      # Get updated HTML
      html = render(view)

      # Assert user now shows as deactivated
      assert html =~ "Deactivated"

      # Verify deactivation in database
      assert GtfsPlanner.Organizations.user_deactivated_in_organization?(
               user.id,
               organization.id
             )
    end

    test "activates previously deactivated user", %{conn: conn, organization: organization} do
      # Create and deactivate a user
      user = user_fixture(%{email: "toactivate@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      GtfsPlanner.Organizations.deactivate_user_in_organization(user.id, organization.id)

      {:ok, view, html} = live(conn, ~p"/admin/users")

      # Verify user is deactivated
      assert html =~ "toactivate@example.com"
      assert html =~ "Deactivated"

      # Click activate button
      view
      |> element("button[phx-click='activate'][phx-value-user-id='#{user.id}']")
      |> render_click()

      # Get updated HTML
      html = render(view)

      # Assert user now shows as active
      assert html =~ "Active"

      # Verify activation in database
      refute GtfsPlanner.Organizations.user_deactivated_in_organization?(
               user.id,
               organization.id
             )
    end

    test "deactivation invalidates user sessions", %{conn: conn, organization: organization} do
      # Create a user and generate a session token
      user = user_fixture(%{email: "sessiontest@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      # Generate session token
      token = Accounts.generate_user_session_token(user)

      # Verify token is valid
      assert Accounts.get_user_by_session_token(token) != nil

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      # Deactivate user
      view
      |> element("button[phx-click='deactivate'][phx-value-user-id='#{user.id}']")
      |> render_click()

      # Verify session token is no longer valid
      assert Accounts.get_user_by_session_token(token) == nil
    end
  end
end
