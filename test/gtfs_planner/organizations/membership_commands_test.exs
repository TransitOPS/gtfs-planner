defmodule GtfsPlanner.Organizations.MembershipCommandsTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Organizations

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
    editor = editor_fixture(organization)
    target = editor_fixture(organization)

    %{organization: organization, admin: admin, editor: editor, target: target}
  end

  test "an editor cannot deactivate another member or delete their sessions", %{
    organization: organization,
    editor: editor,
    target: target
  } do
    web_token = Accounts.generate_user_session_token(target)
    api_token = Accounts.generate_api_session_token(target)
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")

    assert {:error, :forbidden} =
             Organizations.deactivate_user_in_organization(editor, target.id, organization.id)

    refute Organizations.user_deactivated_in_organization?(target.id, organization.id)
    assert Accounts.get_user_by_session_token(web_token)
    assert Accounts.get_user_by_api_session_token(api_token)
    refute_receive {:session_tokens_revoked, _}
  end

  test "an admin deactivates a member, deletes both session contexts, and publishes web digests",
       %{
         organization: organization,
         admin: admin,
         target: target
       } do
    web_token = Accounts.generate_user_session_token(target)
    api_token = Accounts.generate_api_session_token(target)
    {:ok, web_digest} = UserToken.session_token_digest(web_token)
    {:ok, api_digest} = UserToken.session_token_digest(api_token)
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")

    assert {:ok, %{deactivated_at: %DateTime{}}} =
             Organizations.deactivate_user_in_organization(admin, target.id, organization.id)

    assert_receive {:session_tokens_revoked, [^web_digest]}
    refute web_digest == api_digest
    assert Organizations.user_deactivated_in_organization?(target.id, organization.id)
    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_by_api_session_token(api_token)
  end

  test "the last usable admin cannot deactivate themselves", %{
    organization: organization,
    admin: admin
  } do
    token = Accounts.generate_user_session_token(admin)
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")

    assert {:error, :last_organization_admin} =
             Organizations.deactivate_user_in_organization(admin, admin.id, organization.id)

    refute Organizations.user_deactivated_in_organization?(admin.id, organization.id)
    assert Accounts.get_user_by_session_token(token)
    refute_receive {:session_tokens_revoked, _}
  end

  test "a system administrator cannot be deactivated", %{
    organization: organization,
    admin: admin
  } do
    system_admin = system_admin_fixture(organization)
    token = Accounts.generate_user_session_token(system_admin)

    assert {:error, :system_administrator} =
             Organizations.deactivate_user_in_organization(
               admin,
               system_admin.id,
               organization.id
             )

    refute Organizations.user_deactivated_in_organization?(system_admin.id, organization.id)
    assert Accounts.get_user_by_session_token(token)
  end

  test "only a usable admin can reactivate a member", %{
    organization: organization,
    admin: admin,
    editor: editor,
    target: target
  } do
    assert {:ok, %{deactivated_at: %DateTime{}}} =
             Organizations.deactivate_user_in_organization(admin, target.id, organization.id)

    assert {:error, :forbidden} =
             Organizations.activate_user_in_organization(editor, target.id, organization.id)

    assert Organizations.user_deactivated_in_organization?(target.id, organization.id)

    assert {:ok, %{deactivated_at: nil}} =
             Organizations.activate_user_in_organization(admin, target.id, organization.id)

    refute Organizations.user_deactivated_in_organization?(target.id, organization.id)
  end
end
