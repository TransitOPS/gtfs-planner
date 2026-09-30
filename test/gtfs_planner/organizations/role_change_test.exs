defmodule GtfsPlanner.Organizations.RoleChangeTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
    editor = editor_fixture(organization)
    %{organization: organization, admin: admin, editor: editor}
  end

  test "a still-authorized admin cannot demote the last usable admin", %{
    organization: org,
    admin: admin
  } do
    token = Accounts.generate_user_session_token(admin)
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")

    assert {:error, :last_organization_admin} =
             Organizations.update_user_roles(admin, admin.id, org.id, ["pathways_studio_editor"])

    assert ["pathways_studio_admin"] == Accounts.get_user_org_membership(admin.id, org.id).roles
    assert Accounts.get_user_by_session_token(token)
    refute_receive {:session_tokens_revoked, _}
  end

  test "demoting one of two usable admins revokes both session contexts", %{
    organization: org,
    admin: admin
  } do
    other = user_fixture()
    organization_membership_fixture(other, org, ["pathways_studio_admin"])
    web_token = Accounts.generate_user_session_token(other)
    api_token = Accounts.generate_api_session_token(other)
    {:ok, digest} = UserToken.session_token_digest(web_token)
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")

    assert {:ok, %{roles: ["pathways_studio_editor"]}} =
             Organizations.update_user_roles(admin, other.id, org.id, ["pathways_studio_editor"])

    assert_receive {:session_tokens_revoked, [^digest]}
    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_by_api_session_token(api_token)
    assert ["pathways_studio_editor"] == Accounts.get_user_org_membership(other.id, org.id).roles
  end

  test "an editor cannot change roles or remove another member", %{
    organization: org,
    admin: admin,
    editor: editor
  } do
    token = Accounts.generate_user_session_token(admin)
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")

    assert {:error, :forbidden} = Organizations.update_user_roles(editor, admin.id, org.id, [])

    assert {:error, :forbidden} =
             Organizations.remove_user_from_organization(editor, admin.id, org.id)

    assert ["pathways_studio_admin"] == Accounts.get_user_org_membership(admin.id, org.id).roles
    assert Accounts.get_user_by_session_token(token)
    refute_receive {:session_tokens_revoked, _}
  end

  test "removal of the last usable admin is refused", %{organization: org, admin: admin} do
    token = Accounts.generate_user_session_token(admin)

    assert {:error, :last_organization_admin} =
             Organizations.remove_user_from_organization(admin, admin.id, org.id)

    assert Accounts.get_user_org_membership(admin.id, org.id)
    assert Accounts.get_user_by_session_token(token)
  end

  test "a pending invitee does not make demotion or removal safe", %{
    organization: org,
    admin: admin
  } do
    {:ok, invitee} = Repo.insert(User.invite_changeset(%User{}, %{email: unique_user_email()}))
    organization_membership_fixture(invitee, org, ["pathways_studio_admin"])

    assert {:error, :last_organization_admin} =
             Organizations.update_user_roles(admin, admin.id, org.id, [])

    assert {:error, :last_organization_admin} =
             Organizations.remove_user_from_organization(admin, admin.id, org.id)

    assert ["pathways_studio_admin"] == Accounts.get_user_org_membership(admin.id, org.id).roles
  end

  test "removal of a system administrator is refused", %{organization: org, admin: admin} do
    system_admin = system_admin_fixture(org)
    token = Accounts.generate_user_session_token(system_admin)

    assert {:error, :system_administrator} =
             Organizations.remove_user_from_organization(admin, system_admin.id, org.id)

    assert Accounts.get_user_org_membership(system_admin.id, org.id)
    assert Accounts.get_user_by_session_token(token)
  end

  test "removing an editor deletes the membership and both session contexts", %{
    organization: org,
    admin: admin,
    editor: editor
  } do
    membership = Accounts.get_user_org_membership(editor.id, org.id)
    web_token = Accounts.generate_user_session_token(editor)
    api_token = Accounts.generate_api_session_token(editor)
    {:ok, digest} = UserToken.session_token_digest(web_token)
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")

    assert {:ok, %UserOrgMembership{id: id}} =
             Organizations.remove_user_from_organization(admin, editor.id, org.id)

    assert id == membership.id
    assert_receive {:session_tokens_revoked, [^digest]}
    refute Repo.get(UserOrgMembership, membership.id)
    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_by_api_session_token(api_token)
  end

  test "only a system actor can change the system administrator role", %{
    organization: org,
    admin: admin,
    editor: editor
  } do
    system_admin = system_admin_fixture(org)

    assert {:error, :system_administrator} =
             Organizations.update_user_roles(admin, system_admin.id, org.id, [])

    assert {:error, :forbidden} =
             Organizations.update_user_roles(admin, editor.id, org.id, ["administrator"])

    assert {:ok, %{roles: []}} =
             Organizations.update_user_roles(system_admin, system_admin.id, org.id, [])
  end
end
