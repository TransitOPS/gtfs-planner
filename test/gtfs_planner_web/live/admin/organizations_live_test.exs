defmodule GtfsPlannerWeb.Admin.OrganizationsLiveTest do
  # `async: false` is mandatory: the read-adapter Mox runs in global mode so the
  # LiveView process (a different process from the test) resolves the same
  # stubs, and the delivery-failure case mutates application environment.
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
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @read_adapter_key :organizations_admin_read_adapter
  @unknown_organization_id "00000000-0000-4000-8000-000000000000"

  setup %{conn: conn} do
    organization = organization_fixture(%{name: "Acme Transit", alias: "acme-transit"})
    admin_user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: admin_user.id,
        organization_id: organization.id,
        roles: ["administrator"]
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

  defp member_view(user, roles) do
    %{user: Accounts.get_user!(user.id), roles: roles, deactivated_at: nil}
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
  # AC-2 — routing and authorization
  # ----------------------------------------------------------------------------

  describe "routes and authorization" do
    test "all five organization routes resolve for a system administrator", %{
      conn: conn,
      organization: organization
    } do
      assert {:ok, _view, _html} = live(conn, ~p"/admin/organizations")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/organizations/new")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/edit")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")
    end

    test "a user without the administrator role cannot reach the organization routes", %{
      conn: conn,
      organization: organization
    } do
      editor = user_fixture()

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: editor.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      conn = conn |> recycle() |> log_in_user(editor, organization: organization)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/organizations")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, ~p"/admin/organizations/#{organization.id}")
    end

    test "members of another organization are never rendered on a detail page", %{
      conn: conn,
      organization: organization
    } do
      insider = member_fixture(organization, %{email: "insider@example.com"})
      other_organization = organization_fixture(%{name: "Other Org", alias: "other-org"})
      outsider = member_fixture(other_organization, %{email: "outsider@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      assert has_element?(view, "#member-#{insider.id}")
      refute has_element?(view, "#member-#{outsider.id}")
      refute render(view) =~ "outsider@example.com"
    end
  end

  # ----------------------------------------------------------------------------
  # AC-7 / AC-8 — streamed organization index, empty state, unavailable, retry
  # ----------------------------------------------------------------------------

  describe "organization index states" do
    test "renders organizations as one streamed table with stable rows and one edit action", %{
      conn: conn,
      organization: organization
    } do
      other = organization_fixture(%{name: "Beta Transit", alias: "beta-transit"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(view, "#organizations-state")
      assert has_element?(view, "tbody#organizations[phx-update=stream]")
      assert has_element?(view, "#organization-#{organization.id}")
      assert has_element?(view, "#organization-#{other.id}")
      refute has_element?(view, "#organizations-empty")

      assert has_element?(
               view,
               "#organization-#{organization.id} a[href='/admin/organizations/#{organization.id}']",
               "Acme Transit"
             )

      assert has_element?(view, "#edit-organization-#{organization.id}")
      assert has_element?(view, "#create-organization-trigger")

      doc = view |> render() |> LazyHTML.from_fragment()
      assert Enum.count(LazyHTML.query(doc, "tbody#organizations")) == 1
    end

    test "renders the organization empty state with exactly one primary action", %{conn: conn} do
      use_read_mock()
      stub(AdminReadAdapterMock, :list_organizations, fn -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(view, "#organizations-empty")
      refute has_element?(view, "tbody#organizations")

      assert has_element?(view, "#organizations-empty a[href='/admin/organizations/new']")

      # The empty state carries the CTA, so the header primary is not duplicated.
      refute has_element?(view, "#create-organization-trigger")
    end

    test "an unavailable organization list renders a view-level retry and recovers", %{
      conn: conn,
      organization: organization
    } do
      use_read_mock()
      stub(AdminReadAdapterMock, :list_organizations, fn -> {:error, :unavailable} end)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(view, "#organizations-state")
      assert has_element?(view, "#retry-organizations")
      refute has_element?(view, "tbody#organizations")
      refute has_element?(view, "#organizations-empty")

      stub(AdminReadAdapterMock, :list_organizations, fn -> {:ok, [organization]} end)

      view |> element("#retry-organizations") |> render_click()

      assert has_element?(view, "#organization-#{organization.id}")
      refute has_element?(view, "#retry-organizations")
    end
  end

  # ----------------------------------------------------------------------------
  # AC-12 — unknown and malformed organization IDs
  # ----------------------------------------------------------------------------

  describe "organization record recovery" do
    test "an unknown organization id renders a stable recovery state without echoing it", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/admin/organizations/#{@unknown_organization_id}")

      assert has_element?(view, "#organization-record-state")
      assert has_element?(view, "#back-to-organizations")
      refute html =~ @unknown_organization_id
      refute has_element?(view, "#members-state")
    end

    test "a malformed organization id never reaches the read adapter", %{conn: conn} do
      use_read_mock()

      stub(AdminReadAdapterMock, :fetch_organization, fn _id ->
        raise "a malformed route id must be classified before the adapter"
      end)

      {:ok, view, html} = live(conn, ~p"/admin/organizations/not-a-uuid")

      assert has_element?(view, "#organization-record-state")
      assert has_element?(view, "#back-to-organizations")
      refute html =~ "not-a-uuid"
    end

    test "an unavailable organization record renders a retry that recovers", %{
      conn: conn,
      organization: organization
    } do
      use_read_mock()
      stub(AdminReadAdapterMock, :fetch_organization, fn _id -> {:error, :unavailable} end)
      stub(AdminReadAdapterMock, :list_users, fn _id -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      assert has_element?(view, "#organization-record-state")
      assert has_element?(view, "#retry-organization")

      stub(AdminReadAdapterMock, :fetch_organization, fn _id -> {:ok, organization} end)

      view |> element("#retry-organization") |> render_click()

      refute has_element?(view, "#organization-record-state")
      assert render(view) =~ "Acme Transit"
      assert has_element?(view, "#members-state")
    end
  end

  # ----------------------------------------------------------------------------
  # AC-8 — organization detail and the partial member failure
  # ----------------------------------------------------------------------------

  describe "organization detail states" do
    test "renders organization metadata with a monospaced id and the streamed members", %{
      conn: conn,
      organization: organization
    } do
      pending = member_fixture(organization, %{email: "pending@example.com", invited?: true})
      deactivated = member_fixture(organization, %{email: "gone@example.com", deactivated?: true})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      assert render(view) =~ "Acme Transit"
      assert render(view) =~ "acme-transit"

      assert view |> element("#organization-id") |> render() =~ organization.id
      assert view |> element("#organization-id") |> render() =~ "font-mono"

      assert has_element?(view, "tbody#members[phx-update=stream]")
      assert has_element?(view, "#member-#{pending.id}")
      assert has_element?(view, "#member-#{deactivated.id}")

      assert view |> element("#member-#{pending.id} [data-role=member-status]") |> render() =~
               "Invitation pending"

      assert view |> element("#member-#{deactivated.id} [data-role=member-status]") |> render() =~
               "Deactivated"

      assert has_element?(view, "#invite-member-trigger")
    end

    test "renders the member empty state with one organization-specific invitation action", %{
      conn: conn,
      organization: organization
    } do
      use_read_mock()
      stub(AdminReadAdapterMock, :fetch_organization, fn _id -> {:ok, organization} end)
      stub(AdminReadAdapterMock, :list_users, fn _id -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      assert has_element?(view, "#members-empty")
      refute has_element?(view, "tbody#members")

      assert has_element?(
               view,
               "#members-empty a[href='/admin/organizations/#{organization.id}/invite']"
             )

      refute has_element?(view, "#invite-member-trigger")
    end

    test "a member read failure preserves organization metadata and retries only that region", %{
      conn: conn,
      organization: organization,
      admin_user: admin_user
    } do
      use_read_mock()
      stub(AdminReadAdapterMock, :fetch_organization, fn _id -> {:ok, organization} end)
      stub(AdminReadAdapterMock, :list_users, fn _id -> {:error, :unavailable} end)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      # The organization survives the member failure.
      refute has_element?(view, "#organization-record-state")
      assert render(view) =~ "Acme Transit"
      assert view |> element("#organization-id") |> render() =~ organization.id

      assert has_element?(view, "#members-state")
      assert has_element?(view, "#retry-members")
      refute has_element?(view, "tbody#members")
      refute has_element?(view, "#members-empty")

      stub(AdminReadAdapterMock, :list_users, fn _id ->
        {:ok, [member_view(admin_user, ["administrator"])]}
      end)

      view |> element("#retry-members") |> render_click()

      assert has_element?(view, "#member-#{admin_user.id}")
      refute has_element?(view, "#retry-members")
      assert render(view) =~ "Acme Transit"
    end
  end

  # ----------------------------------------------------------------------------
  # AC-12 — create and edit drawers preserve the index
  # ----------------------------------------------------------------------------

  describe "organization create and edit drawers" do
    test "the create drawer keeps the index behind it and returns focus to its trigger", %{
      conn: conn,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      assert has_element?(view, "dialog#org-drawer-overlay[data-open=true]")
      assert has_element?(view, "aside#org-drawer #org-form")
      assert has_element?(view, "#organization-#{organization.id}")

      assert has_element?(
               view,
               "dialog#org-drawer-overlay[data-return-focus-id='create-organization-trigger']"
             )

      view |> element("#org-drawer-close") |> render_click()
      assert_patch(view, ~p"/admin/organizations")
      refute has_element?(view, "dialog#org-drawer-overlay[data-open=true]")
    end

    test "creating an organization streams it into the index with object-specific feedback", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      view
      |> form("#org-form", organization: %{name: "New Test Org", alias: "new-test-org"})
      |> render_submit()

      assert_patch(view, ~p"/admin/organizations")

      created = Organizations.get_organization_by_alias("new-test-org")
      assert created
      assert has_element?(view, "#organization-#{created.id}")

      assert view |> element("#organization-action-feedback") |> render() =~ "New Test Org"
    end

    test "editing an organization keeps the index behind it and saves changes", %{conn: conn} do
      org = organization_fixture(%{name: "Original Name", alias: "original-alias"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{org.id}/edit")

      assert has_element?(view, "dialog#org-drawer-overlay[data-open=true]")
      assert has_element?(view, "#organization-#{org.id}")

      assert has_element?(
               view,
               "dialog#org-drawer-overlay[data-return-focus-id='edit-organization-#{org.id}']"
             )

      view
      |> form("#org-form", organization: %{name: "Updated Name"})
      |> render_submit()

      assert_patch(view, ~p"/admin/organizations")

      reloaded = Organizations.get_organization!(org.id)
      assert reloaded.name == "Updated Name"
      assert reloaded.alias == "original-alias"

      assert view |> element("#organization-action-feedback") |> render() =~ "Updated Name"
    end

    test "a blank organization name keeps the drawer open and commits nothing", %{conn: conn} do
      organizations_before = Repo.aggregate(Organization, :count)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      html =
        view
        |> form("#org-form", organization: %{name: "", alias: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "dialog#org-drawer-overlay[data-open=true]")
      assert Repo.aggregate(Organization, :count) == organizations_before
    end
  end

  # ----------------------------------------------------------------------------
  # AC-9 / AC-12 — the invitation drawer keeps the detail context
  # ----------------------------------------------------------------------------

  describe "member invitation drawer" do
    test "the invitation drawer keeps the same detail and member context behind it", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "existing@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

      assert has_element?(view, "dialog#invite-drawer-overlay[data-open=true]")
      assert has_element?(view, "aside#invite-drawer #invite-form")

      # The detail page, not the index, is the background.
      assert render(view) =~ "Acme Transit"
      assert has_element?(view, "#member-#{member.id}")
      refute has_element?(view, "tbody#organizations")

      assert has_element?(
               view,
               "dialog#invite-drawer-overlay[data-return-focus-id='invite-member-trigger']"
             )

      view |> element("#invite-drawer-close") |> render_click()

      assert_patch(view, ~p"/admin/organizations/#{organization.id}")
      refute has_element?(view, "dialog#invite-drawer-overlay[data-open=true]")
      assert has_element?(view, "#member-#{member.id}")
    end

    test "reports invalid email and missing roles independently and keeps the email", %{
      conn: conn,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

      html =
        view
        |> form("#invite-form", invite: %{email: "not-an-email"})
        |> render_submit()

      assert html =~ "must have the @ sign and no spaces"
      assert html =~ "must select at least one role"

      assert has_element?(view, "#invite-email[aria-invalid=true]")
      assert has_element?(view, "#invite-roles[aria-invalid=true]")
      assert has_element?(view, "#invite-email[value='not-an-email']")

      assert_push_event(view, "focus_first_invite_error", %{})
      refute Accounts.get_user_by_email("not-an-email")
    end

    test "rejects the system administrator role through the organization invitation", %{
      conn: conn,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

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

    test "reports a duplicate membership in flow on the form, not on a field", %{
      conn: conn,
      organization: organization
    } do
      existing = member_fixture(organization, %{email: "already@example.com"})
      memberships_before = Repo.aggregate(UserOrgMembership, :count)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

      html =
        view
        |> form("#invite-form",
          invite: %{email: "already@example.com", roles: ["pathways_studio_editor"]}
        )
        |> render_submit()

      assert has_element?(view, "#invite-service-error")
      assert html =~ "already a member of this organization"
      assert has_element?(view, "dialog#invite-drawer-overlay[data-open=true]")

      assert Repo.aggregate(UserOrgMembership, :count) == memberships_before
      assert membership(existing.id, organization.id).roles == ["pathways_studio_editor"]
    end
  end

  # ----------------------------------------------------------------------------
  # AC-4 / AC-5 — invitation transaction outcomes
  # ----------------------------------------------------------------------------

  describe "invitation outcomes" do
    test "a successful invitation commits, mails once, streams the row, and returns to detail", %{
      conn: conn,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

      view
      |> form("#invite-form",
        invite: %{email: "  NewMember@Example.com  ", roles: ["pathways_studio_editor"]}
      )
      |> render_submit()

      assert_patch(view, ~p"/admin/organizations/#{organization.id}")

      user = Accounts.get_user_by_email("newmember@example.com")
      assert user
      assert membership(user.id, organization.id).roles == ["pathways_studio_editor"]

      assert_email_sent(fn email ->
        assert {_name, "newmember@example.com"} = hd(email.to)
      end)

      assert has_element?(view, "#member-#{user.id}")

      assert view |> element("#member-action-feedback") |> render() =~ "newmember@example.com"
    end

    test "a post-commit delivery failure keeps the membership and offers Resend invite", %{
      conn: conn,
      organization: organization
    } do
      use_failing_mailer()

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}/invite")

      view
      |> form("#invite-form",
        invite: %{email: "undeliverable@example.com", roles: ["pathways_studio_editor"]}
      )
      |> render_submit()

      assert_patch(view, ~p"/admin/organizations/#{organization.id}")

      user = Accounts.get_user_by_email("undeliverable@example.com")
      assert user
      assert membership(user.id, organization.id)

      feedback = view |> element("#member-action-feedback") |> render()
      assert feedback =~ "undeliverable@example.com"
      assert feedback =~ "Resend invite"

      assert has_element?(view, "#resend-invite-#{user.id}")
    end

    test "resend reports success for a member of this organization", %{
      conn: conn,
      organization: organization
    } do
      pending = member_fixture(organization, %{email: "pending@example.com", invited?: true})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      view |> element("#resend-invite-#{pending.id}") |> render_click()

      assert_email_sent(fn email ->
        assert {_name, "pending@example.com"} = hd(email.to)
      end)

      assert view |> element("#member-action-feedback") |> render() =~ "pending@example.com"
    end
  end

  # ----------------------------------------------------------------------------
  # AC-10 — pending labels, accessible names, and stream refresh
  # ----------------------------------------------------------------------------

  describe "member row actions" do
    test "row actions carry operation-specific pending labels and accessible names", %{
      conn: conn,
      organization: organization
    } do
      pending = member_fixture(organization, %{email: "pending@example.com", invited?: true})
      deactivated = member_fixture(organization, %{email: "gone@example.com", deactivated?: true})
      active = member_fixture(organization, %{email: "active@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

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

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      view |> element("#activate-user-#{member.id}") |> render_click()

      refute Organizations.user_deactivated_in_organization?(member.id, organization.id)

      assert view |> element("#member-#{member.id} [data-role=member-status]") |> render() =~
               "Active"

      assert has_element?(view, "#deactivate-user-#{member.id}")
      assert view |> element("#member-action-feedback") |> render() =~ "back@example.com"
    end
  end

  # ----------------------------------------------------------------------------
  # AC-11 — server-owned, organization-scoped deactivation
  # ----------------------------------------------------------------------------

  describe "deactivation confirmation" do
    test "requesting deactivation opens the dialog naming the member and both consequences", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")

      view |> element("#deactivate-user-#{member.id}") |> render_click()

      assert has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")

      dialog = view |> element("#deactivate-user-dialog") |> render()
      assert dialog =~ "target@example.com"
      assert dialog =~ "Acme Transit"
      assert dialog =~ "session"
      assert dialog =~ "Deactivate user"

      assert has_element?(
               view,
               "dialog#deactivate-user-dialog[data-return-focus-id='deactivate-user-#{member.id}']"
             )

      refute Organizations.user_deactivated_in_organization?(member.id, organization.id)
    end

    test "cancel closes the dialog and mutates nothing", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")
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

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")
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
      conn: conn,
      organization: organization
    } do
      other_organization = organization_fixture(%{name: "Other Org", alias: "other-org"})
      outsider = member_fixture(other_organization, %{email: "outsider@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      render_click(view, "request_deactivation", %{"user-id" => outsider.id})

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")
      refute Organizations.user_deactivated_in_organization?(outsider.id, other_organization.id)
      assert view |> element("#member-action-feedback") |> render() =~ "no longer"
    end

    test "a malformed browser user id is refused without raising", %{
      conn: conn,
      organization: organization
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")

      render_click(view, "request_deactivation", %{"user-id" => "not-a-uuid"})

      refute has_element?(view, "dialog#deactivate-user-dialog[data-open=true]")
      assert has_element?(view, "#member-action-feedback")
    end

    test "a confirmation whose target left the organization is refused without mutation", %{
      conn: conn,
      organization: organization
    } do
      member = member_fixture(organization, %{email: "target@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")
      view |> element("#deactivate-user-#{member.id}") |> render_click()

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

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization.id}")
      view |> element("#deactivate-user-#{target.id}") |> render_click()

      render_click(view, "confirm_deactivation", %{"user-id" => bystander.id})

      assert Organizations.user_deactivated_in_organization?(target.id, organization.id)
      refute Organizations.user_deactivated_in_organization?(bystander.id, organization.id)
    end
  end
end
