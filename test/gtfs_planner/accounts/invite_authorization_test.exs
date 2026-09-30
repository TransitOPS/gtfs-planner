defmodule GtfsPlanner.Accounts.InviteAuthorizationTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.{User, UserOrgMembership, UserToken}

  describe "invite_member/5 authorization" do
    test "a usable organization administrator can invite a member" do
      organization = organization_fixture()
      actor = user_fixture()
      organization_membership_fixture(actor, organization, ["pathways_studio_admin"])
      email = unique_user_email()

      assert {:ok, %User{} = invited_user} =
               Accounts.invite_member(
                 email,
                 organization.id,
                 ["pathways_studio_editor"],
                 &Function.identity/1,
                 actor: actor
               )

      assert invited_user.email == email

      assert Repo.get_by(UserOrgMembership,
               user_id: invited_user.id,
               organization_id: organization.id
             )

      assert Repo.get_by(UserToken, user_id: invited_user.id, context: "invite")
    end

    test "editors, deactivated administrators, and administrators from another organization are denied" do
      organization = organization_fixture()
      editor = editor_fixture(organization)

      deactivated_admin = user_fixture()

      deactivated_admin_membership =
        organization_membership_fixture(deactivated_admin, organization, ["pathways_studio_admin"])

      deactivate_membership_fixture(deactivated_admin_membership)

      other_organization = organization_fixture()
      foreign_admin = user_fixture()

      organization_membership_fixture(foreign_admin, other_organization, ["pathways_studio_admin"])

      before = %{
        users: Repo.aggregate(User, :count),
        memberships: Repo.aggregate(UserOrgMembership, :count),
        tokens: Repo.aggregate(UserToken, :count)
      }

      for actor <- [editor, deactivated_admin, foreign_admin] do
        email = unique_user_email()

        assert {:error, :forbidden} =
                 Accounts.invite_member(
                   email,
                   organization.id,
                   ["pathways_studio_editor"],
                   &Function.identity/1,
                   actor: actor
                 )

        refute Repo.get_by(User, email: email)
        assert Repo.aggregate(User, :count) == before.users
        assert Repo.aggregate(UserOrgMembership, :count) == before.memberships
        assert Repo.aggregate(UserToken, :count) == before.tokens
      end
    end

    test "a system administrator can invite into another organization" do
      actor_organization = organization_fixture()
      target_organization = organization_fixture()
      actor = system_admin_fixture(actor_organization)
      email = unique_user_email()

      assert {:ok, %User{} = invited_user} =
               Accounts.invite_member(
                 email,
                 target_organization.id,
                 ["pathways_studio_editor"],
                 &Function.identity/1,
                 actor: actor
               )

      assert invited_user.email == email

      assert Repo.get_by(UserOrgMembership,
               user_id: invited_user.id,
               organization_id: target_organization.id
             )
    end

    test "requires the actor option" do
      organization = organization_fixture()

      assert_raise KeyError, fn ->
        Accounts.invite_member(
          unique_user_email(),
          organization.id,
          ["pathways_studio_editor"],
          &Function.identity/1
        )
      end
    end
  end
end
