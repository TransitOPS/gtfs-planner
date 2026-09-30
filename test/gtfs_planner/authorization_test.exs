defmodule GtfsPlanner.AuthorizationTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Accounts.UserOrgMembership

  setup do
    %{organization: organization_fixture()}
  end

  test "an active editor is authorized and its membership can be locked", %{
    organization: organization
  } do
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)
    context = context(actor, organization)

    assert :ok = Authorization.authorize_editor(context)

    assert {:ok, %UserOrgMembership{id: id}} =
             Repo.transaction(fn -> Authorization.lock_editor!(context) end)

    assert id == membership.id
  end

  test "editor checks reject absent, inactive, wrong-role and foreign memberships", %{
    organization: organization
  } do
    outsider = user_fixture()
    inactive = user_fixture()
    inactive_membership = organization_membership_fixture(inactive, organization)
    deactivate_membership_fixture(inactive_membership)
    roleless = user_fixture()
    organization_membership_fixture(roleless, organization, [])
    admin = user_fixture()
    organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
    foreign = user_fixture()
    organization_membership_fixture(foreign, organization_fixture())

    for actor <- [outsider, inactive, roleless, admin, foreign] do
      context = context(actor, organization)

      assert {:error, :forbidden} = Authorization.authorize_editor(context)

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Authorization.lock_editor!(context) end)
    end
  end

  test "editor checks fail closed for malformed actor and organization IDs", %{
    organization: organization
  } do
    actor = user_fixture()
    organization_membership_fixture(actor, organization)

    for context <- [
          %{actor_id: "bad-uuid", organization_id: organization.id},
          %{actor_id: actor.id, organization_id: "bad-uuid"},
          %{}
        ] do
      assert {:error, :forbidden} = Authorization.authorize_editor(context)

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Authorization.lock_editor!(context) end)
    end
  end

  test "an active system administrator in another organization can administer a member", %{
    organization: organization
  } do
    actor = user_fixture()
    organization_membership_fixture(actor, organization_fixture(), ["administrator"])

    assert {:ok, :system} =
             Repo.transaction(fn -> Authorization.lock_member_admin!(actor, organization.id) end)
  end

  test "an active organization admin with a password can administer a member", %{
    organization: organization
  } do
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization, ["pathways_studio_admin"])

    assert Authorization.usable_admin?(membership, actor)

    assert {:ok, %UserOrgMembership{id: id}} =
             Repo.transaction(fn -> Authorization.lock_member_admin!(actor, organization.id) end)

    assert id == membership.id
  end

  test "pending, inactive, foreign and editor-only admins cannot administer members", %{
    organization: organization
  } do
    pending = user_fixture()

    pending_membership =
      organization_membership_fixture(pending, organization, ["pathways_studio_admin"])

    Repo.update!(Ecto.Changeset.change(pending, hashed_password: nil))
    refute Authorization.usable_admin?(pending_membership, %{pending | hashed_password: nil})

    inactive = user_fixture()

    inactive_membership =
      organization_membership_fixture(inactive, organization, ["pathways_studio_admin"])

    deactivate_membership_fixture(inactive_membership)
    foreign = user_fixture()
    organization_membership_fixture(foreign, organization_fixture(), ["pathways_studio_admin"])
    editor = user_fixture()
    organization_membership_fixture(editor, organization)

    for actor <- [pending, inactive, foreign, editor] do
      assert {:error, :forbidden} =
               Repo.transaction(fn ->
                 Authorization.lock_member_admin!(actor, organization.id)
               end)
    end
  end

  test "a deactivated system administrator is refused", %{organization: organization} do
    actor = user_fixture()

    actor
    |> organization_membership_fixture(organization_fixture(), ["administrator"])
    |> deactivate_membership_fixture()

    assert {:error, :forbidden} =
             Repo.transaction(fn -> Authorization.lock_member_admin!(actor, organization.id) end)
  end

  test "a missing organization is not found before membership authorization" do
    actor = user_fixture()
    organization_membership_fixture(actor, organization_fixture(), ["administrator"])

    assert {:error, :not_found} =
             Repo.transaction(fn ->
               Authorization.lock_member_admin!(actor, Ecto.UUID.generate())
             end)
  end

  defp context(actor, organization) do
    %{actor_id: actor.id, organization_id: organization.id}
  end
end
