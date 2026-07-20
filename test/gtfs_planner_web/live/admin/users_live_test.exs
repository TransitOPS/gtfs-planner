defmodule GtfsPlannerWeb.Admin.UsersLiveTest do
  # `async: false` is mandatory: the read-adapter Mox runs in global mode so the
  # LiveView process (a different process from the test) resolves the same
  # expectations, and the mail-delivery cases mutate application environment.
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import Swoosh.TestAssertions

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.AdminReadAdapterMock
  alias GtfsPlanner.Repo

  @read_adapter_key :organizations_admin_read_adapter

  setup %{conn: conn} do
    organization = organization_fixture()
    admin_user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: admin_user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

    conn = log_in_user(conn, admin_user, organization: organization)

    %{conn: conn, admin_user: admin_user, organization: organization}
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp member_fixture(organization, attrs) do
    email = Map.get(attrs, :email, unique_user_email())
    roles = Map.get(attrs, :roles, ["pathways_studio_editor"])

    user =
      case Map.get(attrs, :invited?, false) do
        true ->
          {:ok, user} = Repo.insert(User.invite_changeset(%User{}, %{email: email}))
          user

        false ->
          user_fixture(%{email: email})
      end

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: roles
      })

    if Map.get(attrs, :deactivated?, false) do
      {:ok, _} = Organizations.deactivate_user_in_organization(user.id, organization.id)
    end

    user
  end

  defp use_read_mock do
    previous = Application.fetch_env(:gtfs_planner, @read_adapter_key)
    Application.put_env(:gtfs_planner, @read_adapter_key, AdminReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @read_adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @read_adapter_key)
      end
    end)

    # Global mode: mount runs once in the test process (disconnected render) and
    # once in the LiveView process (connected mount), so a process-owned
    # expectation would be unusable for the second call.
    set_mox_global()
    :ok
  end

  defp use_failing_mailer do
    previous = Application.fetch_env(:gtfs_planner, GtfsPlanner.Mailer)

    Application.put_env(:gtfs_planner, GtfsPlanner.Mailer,
      adapter: GtfsPlanner.MailerFailureAdapter
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, GtfsPlanner.Mailer, value)
        :error -> Application.delete_env(:gtfs_planner, GtfsPlanner.Mailer)
      end
    end)

    :ok
  end

  defp membership(user_id, organization_id) do
    Repo.get_by(UserOrgMembership, user_id: user_id, organization_id: organization_id)
  end

  # ----------------------------------------------------------------------------
  # AC-1 / AC-2 — routing and authorization
  # ----------------------------------------------------------------------------

  describe "routes and authorization" do
    test "the retired user-detail route returns 404", %{conn: conn, admin_user: admin_user} do
      conn = get(conn, "/admin/users/#{admin_user.id}")

      assert conn.status == 404
      refute conn.resp_body =~ admin_user.email
    end

    test "the three retained organization-admin routes still resolve", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/admin/users")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/users/invite")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/users/organization-settings")
    end

    test "a member without pathways_studio_admin cannot reach the users route", %{
      organization: organization,
      conn: conn
    } do
      editor = user_fixture()

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: editor.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      conn = conn |> recycle() |> log_in_user(editor, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} = live(conn, ~p"/admin/users")
    end

    test "members of another organization are never rendered", %{
      conn: conn,
      admin_user: admin_user
    } do
      other_organization = organization_fixture(%{alias: "other-org", name: "Other Org"})
      outsider = member_fixture(other_organization, %{email: "outsider@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#member-#{admin_user.id}")
      refute has_element?(view, "#member-#{outsider.id}")
      refute render(view) =~ "outsider@example.com"
    end
  end

  # ----------------------------------------------------------------------------
  # AC-7 / AC-8 — streamed member state, empty state, unavailable state, retry
  # ----------------------------------------------------------------------------

  describe "member list states" do
    test "renders every organization member as one streamed row", %{
      conn: conn,
      admin_user: admin_user,
      organization: organization
    } do
      active = member_fixture(organization, %{email: "active@example.com"})

      pending =
        member_fixture(organization, %{email: "pending@example.com", invited?: true})

      deactivated =
        member_fixture(organization, %{email: "gone@example.com", deactivated?: true})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "tbody#members[phx-update=stream]")
      assert has_element?(view, "#member-#{admin_user.id}")
      assert has_element?(view, "#member-#{active.id}")
      assert has_element?(view, "#member-#{pending.id}")
      assert has_element?(view, "#member-#{deactivated.id}")

      refute has_element?(view, "#members-empty")

      # Status vocabulary comes from the shared badge, with precedence applied.
      assert view |> element("#member-#{active.id} [data-role=member-status]") |> render() =~
               "Active"

      assert view |> element("#member-#{pending.id} [data-role=member-status]") |> render() =~
               "Invitation pending"

      assert view
             |> element("#member-#{deactivated.id} [data-role=member-status]")
             |> render() =~ "Deactivated"

      # Row-specific action IDs from the shared component.
      assert has_element?(view, "#resend-invite-#{pending.id}")
      assert has_element?(view, "#activate-user-#{deactivated.id}")
      assert has_element?(view, "#deactivate-user-#{active.id}")
      refute has_element?(view, "#deactivate-user-#{deactivated.id}")
    end

    test "renders the member empty state with one invitation call to action", %{conn: conn} do
      use_read_mock()
      stub(AdminReadAdapterMock, :list_users, fn _organization_id -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#members-empty")
      refute has_element?(view, "tbody#members")

      assert has_element?(view, "#members-empty a[href='/admin/users/invite']")
    end

    test "renders an unavailable read as a retryable region and recovers on Retry", %{
      conn: conn,
      admin_user: admin_user
    } do
      use_read_mock()
      stub(AdminReadAdapterMock, :list_users, fn _organization_id -> {:error, :unavailable} end)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#members-state")
      assert has_element?(view, "#retry-members")
      refute has_element?(view, "tbody#members")
      refute has_element?(view, "#members-empty")

      member = %{
        user: Accounts.get_user!(admin_user.id),
        roles: ["pathways_studio_admin"],
        deactivated_at: nil
      }

      stub(AdminReadAdapterMock, :list_users, fn _organization_id -> {:ok, [member]} end)

      view |> element("#retry-members") |> render_click()

      assert has_element?(view, "#member-#{admin_user.id}")
      refute has_element?(view, "#retry-members")
    end

    test "keeps the current organization assigned when the member read fails", %{
      conn: conn,
      organization: organization
    } do
      use_read_mock()
      stub(AdminReadAdapterMock, :list_users, fn _organization_id -> {:error, :unavailable} end)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert render(view) =~ organization.name
    end
  end

  # ----------------------------------------------------------------------------
  # AC-9 — invitation validation and in-flow service errors
  # ----------------------------------------------------------------------------

  describe "invitation validation" do
    test "reports invalid email and missing roles independently and keeps the email", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      html =
        view
        |> form("#invite-form", invite: %{email: "not-an-email"})
        |> render_submit()

      assert html =~ "must have the @ sign and no spaces"
      assert html =~ "must select at least one role"

      assert has_element?(view, "#invite-email[aria-invalid=true]")
      assert has_element?(view, "#invite-roles[aria-invalid=true]")

      # Submitted values survive the failure.
      assert has_element?(view, "#invite-email[value='not-an-email']")

      # Nothing was committed.
      refute Accounts.get_user_by_email("not-an-email")
    end

    test "moves focus to the first invalid control after a failed submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      view
      |> form("#invite-form", invite: %{email: "", roles: []})
      |> render_submit()

      assert_push_event(view, "focus_first_invite_error", %{})
    end

    test "does not push the focus event on a successful submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      view
      |> form("#invite-form",
        invite: %{email: "fresh@example.com", roles: ["pathways_studio_editor"]}
      )
      |> render_submit()

      refute_push_event(view, "focus_first_invite_error", %{})
    end

    test "reports a duplicate membership in flow on the form, not on a field", %{
      conn: conn,
      organization: organization
    } do
      existing = member_fixture(organization, %{email: "already@example.com"})
      memberships_before = Repo.aggregate(UserOrgMembership, :count)

      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      html =
        view
        |> form("#invite-form",
          invite: %{email: "already@example.com", roles: ["pathways_studio_editor"]}
        )
        |> render_submit()

      assert has_element?(view, "#invite-service-error")
      assert html =~ "already a member of this organization"

      # The drawer stays open on the invite route so the operator can correct it.
      assert has_element?(view, "dialog#invite-drawer-overlay[data-open=true]")

      assert Repo.aggregate(UserOrgMembership, :count) == memberships_before
      assert membership(existing.id, organization.id).roles == ["pathways_studio_editor"]
    end

    test "rejects the system administrator role through the organization invitation", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      refute has_element?(view, "#invite-roles-administrator")

      html =
        view
        |> form("#invite-form", invite: %{email: "sneaky@example.com"})
        |> render_submit(%{
          "invite" => %{"email" => "sneaky@example.com", "roles" => ["administrator"]}
        })

      assert html =~ "contains an invalid role"
      refute Accounts.get_user_by_email("sneaky@example.com")
    end
  end

  # ----------------------------------------------------------------------------
  # AC-4 / AC-5 — invitation transaction outcomes
  # ----------------------------------------------------------------------------

  describe "invitation outcomes" do
    test "a successful invitation commits, mails once, streams the row, and returns to the index",
         %{conn: conn, organization: organization} do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      view
      |> form("#invite-form",
        invite: %{email: "  NewMember@Example.com  ", roles: ["pathways_studio_editor"]}
      )
      |> render_submit()

      assert_patch(view, ~p"/admin/users")

      user = Accounts.get_user_by_email("newmember@example.com")
      assert user
      assert membership(user.id, organization.id).roles == ["pathways_studio_editor"]

      assert_email_sent(fn email ->
        assert {_name, "newmember@example.com"} = hd(email.to)
      end)

      assert has_element?(view, "#member-#{user.id}")

      assert view |> element("#member-action-feedback") |> render() =~
               "newmember@example.com"
    end

    test "a post-commit delivery failure keeps the membership and offers Resend invite", %{
      conn: conn,
      organization: organization
    } do
      use_failing_mailer()

      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      view
      |> form("#invite-form",
        invite: %{email: "undeliverable@example.com", roles: ["pathways_studio_editor"]}
      )
      |> render_submit()

      assert_patch(view, ~p"/admin/users")

      user = Accounts.get_user_by_email("undeliverable@example.com")
      assert user
      assert membership(user.id, organization.id)

      feedback = view |> element("#member-action-feedback") |> render()
      assert feedback =~ "undeliverable@example.com"
      assert feedback =~ "Resend invite"

      # The recovery is the row action, not resubmitting the create command.
      assert has_element?(view, "#resend-invite-#{user.id}")
    end

    test "resend reports success for a member of this organization", %{
      conn: conn,
      organization: organization
    } do
      pending = member_fixture(organization, %{email: "pending@example.com", invited?: true})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view |> element("#resend-invite-#{pending.id}") |> render_click()

      assert_email_sent(fn email ->
        assert {_name, "pending@example.com"} = hd(email.to)
      end)

      assert view |> element("#member-action-feedback") |> render() =~ "pending@example.com"
    end
  end

  # ----------------------------------------------------------------------------
  # AC-10 — pending labels and stream refresh after activation
  # ----------------------------------------------------------------------------

  describe "member actions" do
    test "row actions carry operation-specific pending labels and accessible names", %{
      conn: conn,
      organization: organization
    } do
      pending = member_fixture(organization, %{email: "pending@example.com", invited?: true})
      deactivated = member_fixture(organization, %{email: "gone@example.com", deactivated?: true})
      active = member_fixture(organization, %{email: "active@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(
               view,
               "#resend-invite-#{pending.id}[phx-disable-with='Resending invite…']"
             )

      assert has_element?(
               view,
               "#activate-user-#{deactivated.id}[phx-disable-with='Activating user…']"
             )

      assert has_element?(
               view,
               "#deactivate-user-#{active.id}[phx-disable-with='Deactivating user…']"
             )

      assert has_element?(
               view,
               "#deactivate-user-#{active.id}[aria-label='Deactivate active@example.com']"
             )
    end

    test "activation clears the deactivation and refreshes the stream", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "back@example.com", deactivated?: true})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view |> element("#activate-user-#{member.id}") |> render_click()

      refute Organizations.user_deactivated_in_organization?(member.id, organization.id)

      assert view |> element("#member-#{member.id} [data-role=member-status]") |> render() =~
               "Active"

      assert has_element?(view, "#deactivate-user-#{member.id}")
      assert view |> element("#member-action-feedback") |> render() =~ "back@example.com"
    end
  end

  # ----------------------------------------------------------------------------
  # AC-11 — server-owned scoped deactivation confirmation
  # ----------------------------------------------------------------------------

  describe "deactivation confirmation" do
    test "requesting deactivation opens the dialog with the member and both consequences", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")

      view |> element("#deactivate-user-#{member.id}") |> render_click()

      assert has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")

      dialog = view |> element("#deactivate-user-dialog") |> render()
      assert dialog =~ "target@example.com"
      assert dialog =~ organization.name
      assert dialog =~ "session"
      assert dialog =~ "Deactivate user"

      # Nothing has been mutated by opening the dialog.
      refute Organizations.user_deactivated_in_organization?(member.id, organization.id)
    end

    test "the dialog returns focus to the row trigger it was opened from", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")
      view |> element("#deactivate-user-#{member.id}") |> render_click()

      assert has_element?(
               view,
               "dialog#deactivate-user-dialog[data-return-focus-id='deactivate-user-#{member.id}']"
             )
    end

    test "cancel closes the dialog and mutates nothing", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")
      view |> element("#deactivate-user-#{member.id}") |> render_click()

      view |> element("#deactivate-user-dialog-cancel") |> render_click()

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")
      refute Organizations.user_deactivated_in_organization?(member.id, organization.id)
      assert has_element?(view, "#deactivate-user-#{member.id}")
    end

    test "confirm deactivates the member, revokes every session, and refreshes the stream", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})
      token = Accounts.generate_user_session_token(Accounts.get_user!(member.id))
      assert Accounts.get_user_by_session_token(token)

      {:ok, view, _html} = live(conn, ~p"/admin/users")
      view |> element("#deactivate-user-#{member.id}") |> render_click()
      view |> element("#deactivate-user-dialog-confirm") |> render_click()

      assert Organizations.user_deactivated_in_organization?(member.id, organization.id)
      refute Accounts.get_user_by_session_token(token)

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")

      assert view |> element("#member-#{member.id} [data-role=member-status]") |> render() =~
               "Deactivated"

      assert has_element?(view, "#activate-user-#{member.id}")
      assert view |> element("#member-action-feedback") |> render() =~ "target@example.com"
    end

    test "a request for a member of another organization is refused without mutation", %{
      conn: conn
    } do
      other_organization = organization_fixture(%{alias: "other-org", name: "Other Org"})
      outsider = member_fixture(other_organization, %{email: "outsider@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      render_click(view, "request_deactivation", %{"user-id" => outsider.id})

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")

      refute Organizations.user_deactivated_in_organization?(
               outsider.id,
               other_organization.id
             )

      assert view |> element("#member-action-feedback") |> render() =~ "no longer"
    end

    test "a malformed browser user id is refused without raising", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      render_click(view, "request_deactivation", %{"user-id" => "not-a-uuid"})

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")
      assert has_element?(view, "#member-action-feedback")
    end

    test "a confirmation whose target left the organization is refused without mutation", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")
      view |> element("#deactivate-user-#{member.id}") |> render_click()

      # The membership disappears between request and confirmation.
      Repo.delete!(membership(member.id, organization.id))

      view |> element("#deactivate-user-dialog-confirm") |> render_click()

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")
      refute Organizations.user_deactivated_in_organization?(member.id, organization.id)
      assert view |> element("#member-action-feedback") |> render() =~ "no longer"
    end

    test "confirmation ignores any browser-supplied identity", %{
      conn: conn,
      organization: organization
    } do
      target = member_fixture(organization, %{email: "target@example.com"})
      bystander = member_fixture(organization, %{email: "bystander@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")
      view |> element("#deactivate-user-#{target.id}") |> render_click()

      render_click(view, "confirm_deactivation", %{"user-id" => bystander.id})

      assert Organizations.user_deactivated_in_organization?(target.id, organization.id)
      refute Organizations.user_deactivated_in_organization?(bystander.id, organization.id)
    end
  end

  # ----------------------------------------------------------------------------
  # AC-12 — drawers preserve the background route and restore focus
  # ----------------------------------------------------------------------------

  describe "drawers" do
    test "the invitation drawer keeps the member list behind it and names its trigger", %{
      conn: conn,
      admin_user: admin_user
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users/invite")

      assert has_element?(view, "dialog#invite-drawer-overlay[data-open=true]")
      assert has_element?(view, "aside#invite-drawer #invite-form")
      assert has_element?(view, "#member-#{admin_user.id}")

      assert has_element?(
               view,
               "dialog#invite-drawer-overlay[data-return-focus-id='invite-user-trigger']"
             )

      assert has_element?(view, "#invite-user-trigger")

      view |> element("#invite-drawer-close") |> render_click()
      assert_patch(view, ~p"/admin/users")
      refute has_element?(view, "dialog#invite-drawer-overlay[data-open=true]")
    end

    test "the organization-settings drawer keeps the member list behind it", %{
      conn: conn,
      admin_user: admin_user,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users/organization-settings")

      assert has_element?(view, "dialog#organization-settings-drawer-overlay[data-open=true]")
      assert has_element?(view, "#organization-settings-form")
      assert has_element?(view, "#member-#{admin_user.id}")

      assert has_element?(
               view,
               "dialog#organization-settings-drawer-overlay[data-return-focus-id='organization-settings-trigger']"
             )

      assert has_element?(view, "#organization-settings-trigger")
      refute has_element?(view, "#organization-settings-form input[name='organization[alias]']")

      view
      |> form("#organization-settings-form", organization: %{name: "Renamed Org"})
      |> render_submit()

      assert_patch(view, ~p"/admin/users")
      assert Organizations.get_organization!(organization.id).name == "Renamed Org"
    end

    test "the organization form rejects a blank name and keeps the drawer open", %{
      conn: conn,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users/organization-settings")

      html =
        view
        |> form("#organization-settings-form", organization: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "dialog#organization-settings-drawer-overlay[data-open=true]")
      assert Organizations.get_organization!(organization.id).name == organization.name
    end

    test "the organization form ignores a crafted alias", %{
      conn: conn,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users/organization-settings")

      render_submit(view, "save_organization", %{
        "organization" => %{"name" => "Renamed Org", "alias" => "crafted-alias"}
      })

      assert_patch(view, ~p"/admin/users")

      reloaded = Organizations.get_organization!(organization.id)
      assert reloaded.name == "Renamed Org"
      assert reloaded.alias == organization.alias
    end
  end
end
