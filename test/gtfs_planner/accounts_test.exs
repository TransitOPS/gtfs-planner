defmodule GtfsPlanner.AccountsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.{User, UserToken, UserOrgMembership}
  import GtfsPlanner.OrganizationsFixtures

  describe "get_user!/1" do
    test "raises if id does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(Ecto.UUID.generate())
      end
    end

    test "returns the user with the given id" do
      user = user_fixture()
      assert Accounts.get_user!(user.id) == user
    end
  end

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{email: email} = user = user_fixture()
      assert %User{id: id} = Accounts.get_user_by_email(email)
      assert id == user.id
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      user = user_fixture()

      assert %User{id: id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      assert id == user.id
    end
  end

  describe "register_user/1" do
    test "requires email and password to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{
               email: ["can't be blank"],
               password: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates email and password when given" do
      {:error, changeset} =
        Accounts.register_user(%{email: "not valid", password: "not valid"})

      assert %{
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"]
             } = errors_on(changeset)
    end

    test "validates maximum values for email and password for security" do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.register_user(%{email: too_long <> "@example.com", password: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()

      {:error, changeset} = Accounts.register_user(%{email: email})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users with a hashed password" do
      email = unique_user_email()
      password = valid_user_password()

      {:ok, user} = Accounts.register_user(%{email: email, password: password})

      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.password)
      assert user.hashed_password != password
    end
  end

  describe "change_user_registration/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_registration(%User{})
      assert changeset.required == [:password, :email]
    end

    test "allows changes to email and password" do
      attrs = valid_user_attributes()

      changeset = Accounts.change_user_registration(%User{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :email) == String.downcase(attrs.email)
      assert get_change(changeset, :password) == attrs.password
    end
  end

  describe "change_user_email/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "apply_user_email/3" do
    setup do
      %{user: user_fixture()}
    end

    test "requires email to change", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: ""})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, "invalid", %{email: unique_user_email()})

      assert %{current_password: ["is invalid"]} = errors_on(changeset)
    end

    test "applies the email without persisting it", %{user: user} do
      email = unique_user_email()

      {:ok, applied_user} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: email})

      assert applied_user.email == email
      assert Accounts.get_user!(user.id).email == user.email
    end
  end

  describe "update_user_email/2" do
    setup do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(
            %{user | email: email},
            user.email,
            fn token -> "#{url}/users/update_email/#{token}" end
          )
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert Accounts.update_user_email(user, token) == :ok
      updated_user = Accounts.get_user!(user.id)
      assert updated_user.email != user.email
      assert updated_user.email == email
      assert updated_user.confirmed_at
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") == :error
      assert Accounts.get_user!(user.id).email == user.email
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) == :error
      assert Accounts.get_user!(user.id).email == user.email
    end
  end

  describe "change_user_password/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(%User{}, %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      assert changeset.valid?
    end
  end

  describe "update_user_password/3" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, "invalid", %{password: "valid password 123456"})

      assert %{current_password: ["is invalid"]} = errors_on(changeset)
    end

    test "updates the password", %{user: user} do
      {:ok, _user} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password()) == nil
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, _} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert token
      assert is_binary(token)
    end

    test "does not generate the same token twice", %{user: user} do
      token1 = Accounts.generate_user_session_token(user)
      token2 = Accounts.generate_user_session_token(user)
      assert token1 != token2
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{user: _user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "delete_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "deletes the token", %{user: _user, token: token} do
      assert Accounts.delete_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_user_confirmation_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, fn token ->
            "#{url}/users/confirm/#{token}"
          end)
        end)

      assert {:ok, _} = Accounts.confirm_user(token)
    end
  end

  describe "confirm_user/1" do
    setup do
      user = user_fixture()

      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(%{user | email: email}, fn token ->
            "#{url}/users/confirm/#{token}"
          end)
        end)

      %{user: user, token: token, email: email}
    end

    test "confirms the email with a valid token", %{user: user, token: token} do
      assert {:ok, confirmed_user} = Accounts.confirm_user(token)
      assert confirmed_user.confirmed_at
      assert confirmed_user.email == user.email

      assert Accounts.get_user!(user.id).confirmed_at
    end

    test "does not confirm with invalid token", %{user: user} do
      assert Accounts.confirm_user("oops") == :error
      refute Accounts.get_user!(user.id).confirmed_at
    end

    test "does not confirm email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.confirm_user(token) == :error
      refute Accounts.get_user!(user.id).confirmed_at
    end
  end

  describe "deliver_user_reset_password_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, fn token ->
            "#{url}/users/reset_password/#{token}"
          end)
        end)

      assert user.email == Accounts.get_user_by_reset_password_token(token).email
    end
  end

  describe "get_user_by_reset_password_token/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, fn token ->
            "#{url}/users/reset_password/#{token}"
          end)
        end)

      %{user: user, token: token}
    end

    test "returns user with valid token", %{user: user, token: token} do
      assert reset_user = Accounts.get_user_by_reset_password_token(token)
      assert reset_user.id == user.id
    end

    test "does not return user with invalid token" do
      refute Accounts.get_user_by_reset_password_token("oops")
    end

    test "does not return user if token expired", %{user: _user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      refute Accounts.get_user_by_reset_password_token(token)
    end
  end

  describe "reset_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.reset_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.reset_user_password(user, %{
          password: too_long,
          password_confirmation: too_long
        })

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, _updated_user} =
        Accounts.reset_user_password(user, %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, _} =
        Accounts.reset_user_password(user, %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "invite_user/2" do
    setup do
      %{organization_id: Ecto.UUID.generate()}
    end

    test "creates a new user when email does not exist", %{organization_id: org_id} do
      email = unique_user_email()

      assert {:ok, %User{}} = Accounts.invite_user(email, org_id)
      assert Accounts.get_user_by_email(email)
    end

    test "returns existing user when email already exists", %{organization_id: org_id} do
      existing_user = user_fixture()

      assert {:ok, %User{id: id}} = Accounts.invite_user(existing_user.email, org_id)
      assert id == existing_user.id
    end

    test "downcases email", %{organization_id: org_id} do
      email = "UPPERCASE@EXAMPLE.COM"
      {:ok, user} = Accounts.invite_user(email, org_id)
      assert user.email == "uppercase@example.com"
    end

    test "validates email format", %{organization_id: org_id} do
      {:error, changeset} = Accounts.invite_user("invalid-email", org_id)
      assert errors_on(changeset).email == ["must have the @ sign and no spaces"]
    end
  end

  describe "deliver_user_invite/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_invite(user, fn token -> "#{url}/users/accept_invite/#{token}" end)
        end)

      assert user.email == Accounts.get_user_by_invite_token(token).email
    end
  end

  describe "get_user_by_invite_token/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_invite(user, fn token -> "#{url}/users/accept_invite/#{token}" end)
        end)

      %{user: user, token: token}
    end

    test "returns the user with valid token", %{user: user, token: token} do
      assert invite_user = Accounts.get_user_by_invite_token(token)
      assert invite_user.id == user.id
    end

    test "does not return user with invalid token" do
      refute Accounts.get_user_by_invite_token("oops")
    end
  end

  describe "accept_invite_set_password/2" do
    setup do
      user = user_fixture()
      org = organization_fixture()
      org_id = org.id

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_invite(user, fn token -> "#{url}/users/accept_invite/#{token}" end)
        end)

      %{user: user, token: token, org_id: org_id}
    end

    test "sets password and creates membership", %{user: user, org_id: org_id} do
      {:ok, _updated_user} =
        Accounts.accept_invite_set_password(user, %{
          password: "new valid password",
          password_confirmation: "new valid password",
          organization_id: org_id
        })

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")

      assert membership =
               Repo.get_by(UserOrgMembership, user_id: user.id, organization_id: org_id)

      assert membership
    end

    test "validates password", %{user: user, org_id: org_id} do
      {:error, changeset} =
        Accounts.accept_invite_set_password(user, %{
          password: "invalid",
          password_confirmation: "another",
          organization_id: org_id
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "deletes invite token after acceptance", %{user: user, org_id: org_id} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_invite(user, fn token -> "#{url}/users/accept_invite/#{token}" end)
        end)

      Accounts.accept_invite_set_password(user, %{
        password: "new valid password",
        password_confirmation: "new valid password",
        organization_id: org_id
      })

      refute Accounts.get_user_by_invite_token(token)
    end
  end

  describe "list_user_org_memberships/1" do
    test "returns user's memberships" do
      user = user_fixture()
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org1.id,
          roles: ["pathways_studio_admin"]
        })

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org2.id,
          roles: ["pathways_studio_viewer"]
        })

      memberships = Accounts.list_user_org_memberships(user.id)
      assert length(memberships) == 2
    end

    test "returns empty list for user with no memberships" do
      user = user_fixture()
      memberships = Accounts.list_user_org_memberships(user.id)
      assert memberships == []
    end
  end

  describe "get_user_org_membership/2" do
    setup do
      user = user_fixture()
      org = organization_fixture()

      {:ok, membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org.id,
          roles: ["pathways_studio_admin"]
        })

      %{user: user, org: org, membership: membership}
    end

    test "returns membership when it exists", %{user: user, org: org, membership: membership} do
      assert Accounts.get_user_org_membership(user.id, org.id) == membership
    end

    test "returns nil when membership does not exist", %{user: user} do
      refute Accounts.get_user_org_membership(user.id, Ecto.UUID.generate())
    end
  end

  describe "create_user_org_membership/1" do
    test "creates membership with valid attributes" do
      user = user_fixture()
      org = organization_fixture()

      attrs = %{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_admin", "pathways_studio_editor"]
      }

      assert {:ok, %UserOrgMembership{} = membership} = Accounts.create_user_org_membership(attrs)
      assert membership.user_id == user.id
      assert membership.organization_id == org.id
      assert membership.roles == ["pathways_studio_admin", "pathways_studio_editor"]
    end

    test "returns error with invalid attributes" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.create_user_org_membership(%{user_id: nil, organization_id: nil})
    end
  end

  describe "update_user_org_membership/2" do
    setup do
      user = user_fixture()
      org = organization_fixture()

      {:ok, membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org.id,
          roles: ["pathways_studio_admin"]
        })

      %{membership: membership}
    end

    test "updates membership with valid attributes", %{membership: membership} do
      assert {:ok, %UserOrgMembership{} = updated} =
               Accounts.update_user_org_membership(membership, %{
                 roles: ["pathways_studio_viewer"]
               })

      assert updated.roles == ["pathways_studio_viewer"]
    end

    test "returns error with invalid attributes", %{membership: membership} do
      # roles must be an array, passing a string should fail
      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_user_org_membership(membership, %{roles: "invalid"})
    end
  end

  describe "delete_user_org_membership/1" do
    setup do
      user = user_fixture()
      org = organization_fixture()

      {:ok, membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org.id,
          roles: ["pathways_studio_admin"]
        })

      %{membership: membership}
    end

    test "deletes_membership membership", %{membership: membership} do
      assert {:ok, %UserOrgMembership{}} = Accounts.delete_user_org_membership(membership)
      refute Repo.get(UserOrgMembership, membership.id)
    end
  end

  describe "change_user_org_membership/2" do
    test "returns a changeset" do
      membership = %UserOrgMembership{}
      assert %Ecto.Changeset{} = _changeset = Accounts.change_user_org_membership(membership)
    end

    test "allows fields to be set" do
      membership = %UserOrgMembership{
        user_id: Ecto.UUID.generate(),
        organization_id: Ecto.UUID.generate()
      }

      changeset =
        Accounts.change_user_org_membership(membership, %{
          roles: ["pathways_studio_admin", "pathways_studio_editor"]
        })

      assert changeset.valid?
    end
  end
end
