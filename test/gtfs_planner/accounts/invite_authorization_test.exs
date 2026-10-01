defmodule GtfsPlanner.Accounts.InviteAuthorizationTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 0]
  import Swoosh.TestAssertions

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

  describe "resend_user_invite/4 authorization" do
    setup do
      organization = organization_fixture()
      admin = user_fixture()
      organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
      pending = invited_user_fixture()
      organization_membership_fixture(pending, organization, ["pathways_studio_editor"])

      %{organization: organization, admin: admin, pending: pending}
    end

    test "a usable organization administrator resends an invitation", %{
      organization: organization,
      admin: admin,
      pending: pending
    } do
      assert {:ok, _delivery} =
               Accounts.resend_user_invite(
                 admin,
                 organization.id,
                 pending.id,
                 &Function.identity/1
               )

      assert [_token] = invite_tokens(pending)
      assert_email_sent(to: [{"", pending.email}])
    end

    test "an administrator revoked after the page loaded is refused and writes nothing", %{
      organization: organization,
      admin: admin,
      pending: pending
    } do
      admin_membership = Repo.get_by!(UserOrgMembership, user_id: admin.id)
      deactivate_membership_fixture(admin_membership)

      assert {:error, :forbidden} =
               Accounts.resend_user_invite(
                 admin,
                 organization.id,
                 pending.id,
                 &Function.identity/1
               )

      assert invite_tokens(pending) == []
      assert_no_email_sent()
    end

    test "editors and administrators of another organization are refused", %{
      organization: organization,
      pending: pending
    } do
      editor = editor_fixture(organization)
      foreign_admin = user_fixture()

      organization_membership_fixture(foreign_admin, organization_fixture(), [
        "pathways_studio_admin"
      ])

      for actor <- [editor, foreign_admin] do
        assert {:error, :forbidden} =
                 Accounts.resend_user_invite(
                   actor,
                   organization.id,
                   pending.id,
                   &Function.identity/1
                 )
      end

      assert invite_tokens(pending) == []
      assert_no_email_sent()
    end

    test "a system administrator resends for another organization", %{
      organization: organization,
      pending: pending
    } do
      system_admin = system_admin_fixture(organization_fixture())

      assert {:ok, _delivery} =
               Accounts.resend_user_invite(
                 system_admin,
                 organization.id,
                 pending.id,
                 &Function.identity/1
               )

      assert [_token] = invite_tokens(pending)
    end

    test "a user outside the organization is not found and gets no token", %{
      organization: organization,
      admin: admin
    } do
      outsider = invited_user_fixture()

      organization_membership_fixture(outsider, organization_fixture(), ["pathways_studio_editor"])

      assert {:error, :not_found} =
               Accounts.resend_user_invite(
                 admin,
                 organization.id,
                 outsider.id,
                 &Function.identity/1
               )

      assert invite_tokens(outsider) == []
      assert_no_email_sent()
    end

    test "an unknown organization or malformed user id is not found", %{
      organization: organization,
      admin: admin,
      pending: pending
    } do
      assert {:error, :not_found} =
               Accounts.resend_user_invite(
                 admin,
                 Ecto.UUID.generate(),
                 pending.id,
                 &Function.identity/1
               )

      assert {:error, :not_found} =
               Accounts.resend_user_invite(admin, organization.id, "nope", &Function.identity/1)

      assert invite_tokens(pending) == []
    end

    test "a member who already has a password is refused and gets no token", %{
      organization: organization,
      admin: admin
    } do
      accepted = user_fixture()
      organization_membership_fixture(accepted, organization, ["pathways_studio_editor"])

      assert {:error, :already_accepted} =
               Accounts.resend_user_invite(
                 admin,
                 organization.id,
                 accepted.id,
                 &Function.identity/1
               )

      assert invite_tokens(accepted) == []
      assert_no_email_sent()
    end
  end

  defp invite_tokens(%User{} = user) do
    Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "invite")
  end
end
