defmodule GtfsPlanner.AccountsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.{FirstAdminForm, User, UserOrgMembership, UserToken}
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions.GtfsVersion
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

  describe "apply_user_password/3" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_password(user, valid_user_password(), %{
          password: "short",
          password_confirmation: "other"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_password(user, "invalid", %{
          password: "new valid password 123456"
        })

      assert %{current_password: ["is invalid"]} = errors_on(changeset)
    end

    test "applies the password without persisting it", %{user: user} do
      original_hash = user.hashed_password
      original_token_count = Repo.aggregate(UserToken, :count)

      {:ok, _applied_user} =
        Accounts.apply_user_password(user, valid_user_password(), %{
          password: "new valid password 123456",
          password_confirmation: "new valid password 123456"
        })

      assert Accounts.get_user!(user.id).hashed_password == original_hash
      assert Repo.aggregate(UserToken, :count) == original_token_count
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
      {:ok, {_user, _tokens}} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password()) == nil
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_user, _tokens}} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "preserves password and tokens on validation failure", %{user: user} do
      original_hash = user.hashed_password
      _ = Accounts.generate_user_session_token(user)
      _ = Accounts.generate_api_session_token(user)

      {:error, _changeset} =
        Accounts.update_user_password(user, "wrong_password", %{
          password: "new valid password 123456",
          password_confirmation: "new valid password 123456"
        })

      assert Accounts.get_user!(user.id).hashed_password == original_hash
      assert Repo.get_by(UserToken, user_id: user.id, context: "session")
      assert Repo.get_by(UserToken, user_id: user.id, context: "api_session")
    end

    test "returns exact captured token structs across all contexts", %{user: user} do
      _ = Accounts.generate_user_session_token(user)
      _ = Accounts.generate_api_session_token(user)
      insert_email_token(user, "reset_password")
      insert_email_token(user, "confirm")
      insert_email_token(user, "invite")
      insert_email_token(user, "change:#{user.email}")

      pre_ids =
        from(t in UserToken, where: t.user_id == ^user.id, select: t.id)
        |> Repo.all()
        |> Enum.sort()

      {:ok, {_updated_user, expired_tokens}} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      returned_ids = Enum.map(expired_tokens, & &1.id) |> Enum.sort()

      assert returned_ids != []
      assert returned_ids == pre_ids
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

  describe "generate_api_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a non-empty token string", %{user: user} do
      token = Accounts.generate_api_session_token(user)
      assert is_binary(token)
      assert token != ""
    end

    test "creates a users_tokens row with context api_session", %{user: user} do
      _token = Accounts.generate_api_session_token(user)
      assert Repo.get_by(UserToken, user_id: user.id, context: "api_session")
    end
  end

  describe "get_user_by_api_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_api_session_token(user)
      %{user: user, token: token}
    end

    test "returns user for valid token", %{user: user, token: token} do
      assert found_user = Accounts.get_user_by_api_session_token(token)
      assert found_user.id == user.id
    end

    test "returns nil for invalid token" do
      refute Accounts.get_user_by_api_session_token("invalid-token")
    end

    test "returns nil for a valid web session token (context isolation)" do
      user = user_fixture()
      web_token = Accounts.generate_user_session_token(user)
      refute Accounts.get_user_by_api_session_token(web_token)
    end

    test "returns nil for expired token", %{token: token} do
      {1, nil} =
        Repo.update_all(
          from(t in UserToken, where: t.context == "api_session"),
          set: [inserted_at: ~N[2020-01-01 00:00:00]]
        )

      refute Accounts.get_user_by_api_session_token(token)
    end
  end

  describe "delete_api_session_tokens/1" do
    test "deletes only api_session tokens, leaves session tokens intact" do
      user = user_fixture()
      _web_token = Accounts.generate_user_session_token(user)
      _api_token = Accounts.generate_api_session_token(user)

      assert Repo.get_by(UserToken, user_id: user.id, context: "session")
      assert Repo.get_by(UserToken, user_id: user.id, context: "api_session")

      {deleted_count, nil} = Accounts.delete_api_session_tokens(user)
      assert deleted_count == 1

      assert Repo.get_by(UserToken, user_id: user.id, context: "session")
      refute Repo.get_by(UserToken, user_id: user.id, context: "api_session")
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

    test "consumes the token exactly once", %{user: user, token: token} do
      assert {:ok, _} = Accounts.confirm_user(token)
      assert Accounts.confirm_user(token) == :error
      assert Accounts.get_user!(user.id).confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id, context: "confirm")
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

    test "consumes the reset token so a replay cannot resolve the user again", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, fn token ->
            "#{url}/users/reset_password/#{token}"
          end)
        end)

      assert Accounts.get_user_by_reset_password_token(token).id == user.id

      {:ok, _updated_user} =
        Accounts.reset_user_password(user, %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      refute Accounts.get_user_by_reset_password_token(token)
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
          roles: ["pathways_studio_editor"]
        })

      memberships = Accounts.list_user_org_memberships(user.id)
      assert length(memberships) == 2
    end

    test "returns empty list for user with no memberships" do
      user = user_fixture()
      memberships = Accounts.list_user_org_memberships(user.id)
      assert memberships == []
    end

    test "excludes deactivated memberships" do
      user = user_fixture()
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org1.id,
          roles: ["pathways_studio_admin"]
        })

      {:ok, deactivated} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org2.id,
          roles: ["pathways_studio_editor"]
        })

      deactivated
      |> Ecto.Changeset.change(%{
        deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      memberships = Accounts.list_user_org_memberships(user.id)
      assert length(memberships) == 1
      assert hd(memberships).organization_id == org1.id
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
                 roles: ["pathways_studio_editor"]
               })

      assert updated.roles == ["pathways_studio_editor"]
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

  describe "email and password trimming" do
    test "register_user/1 trims surrounding whitespace from email" do
      unique = System.unique_integer([:positive])
      raw = "  foo-#{unique}@example.com  "

      {:ok, user} = Accounts.register_user(%{email: raw, password: valid_user_password()})

      assert user.email == String.trim(raw)
    end

    test "change_user_email/2 trims and lowercases email" do
      user = user_fixture()

      changeset =
        Accounts.change_user_email(user, %{email: "  NewMail@Example.COM  "})

      assert get_change(changeset, :email) == "newmail@example.com"
      assert changeset.valid?
    end

    test "invite_user/2 trims and lowercases email" do
      org_id = Ecto.UUID.generate()
      raw = "  Invitee-#{System.unique_integer([:positive])}@Example.com  "

      {:ok, user} = Accounts.invite_user(raw, org_id)

      assert user.email == raw |> String.trim() |> String.downcase()
    end

    test "register_user/1 preserves whitespace in password" do
      email = unique_user_email()
      padded_password = "  hunter2 padded password  "

      {:ok, user} = Accounts.register_user(%{email: email, password: padded_password})

      assert Accounts.get_user_by_email_and_password(user.email, padded_password)
      refute Accounts.get_user_by_email_and_password(user.email, String.trim(padded_password))
    end

    test "change_user_password/2 preserves whitespace in password" do
      user = user_fixture()
      padded_password = "  hunter2 padded password  "

      changeset =
        Accounts.change_user_password(user, %{
          password: padded_password,
          password_confirmation: padded_password
        })

      assert get_change(changeset, :password) == padded_password
    end
  end

  defp insert_email_token(user, context) do
    {_encoded_token, user_token} = UserToken.build_email_token(user, context)
    Repo.insert!(user_token)
  end

  describe "change_first_admin/1" do
    test "returns a composite FirstAdminForm changeset" do
      changeset = Accounts.change_first_admin(%{})

      assert %Ecto.Changeset{data: %FirstAdminForm{}} = changeset
      refute changeset.valid?
    end

    test "returns a changeset with valid attributes that is valid at the composite level" do
      attrs = %{
        email: unique_user_email(),
        password: valid_user_password(),
        password_confirmation: valid_user_password(),
        organization_name: valid_organization_name(),
        organization_alias: unique_organization_alias()
      }

      changeset = Accounts.change_first_admin(attrs)

      assert changeset.valid?
      assert %Ecto.Changeset{data: %FirstAdminForm{}} = changeset
    end
  end

  describe "register_first_admin/1" do
    test "exports no arity-two registration function" do
      Code.ensure_loaded!(Accounts)
      refute function_exported?(Accounts, :register_first_admin, 2)
    end

    test "preflight invalid input returns Ecto.Changeset with action :insert and writes nothing" do
      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)
      version_count = Repo.aggregate(GtfsVersion, :count, :id)
      membership_count = Repo.aggregate(UserOrgMembership, :count, :id)

      result = Accounts.register_first_admin(%{email: "notanemail", password: "short"})

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert changeset.action == :insert
      assert changeset.errors != []

      assert Repo.aggregate(User, :count, :id) == user_count
      assert Repo.aggregate(Organization, :count, :id) == org_count
      assert Repo.aggregate(GtfsVersion, :count, :id) == version_count
      assert Repo.aggregate(UserOrgMembership, :count, :id) == membership_count
    end

    test "valid confirmed-administrator creates user, org, version, membership, and confirms atomically" do
      email = unique_user_email()
      password = valid_user_password()
      org_name = valid_organization_name()
      org_alias = unique_organization_alias()

      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)
      version_count = Repo.aggregate(GtfsVersion, :count, :id)
      membership_count = Repo.aggregate(UserOrgMembership, :count, :id)

      result =
        Accounts.register_first_admin(%{
          email: email,
          password: password,
          password_confirmation: password,
          organization_name: org_name,
          organization_alias: org_alias
        })

      assert {:ok, %User{} = user} = result
      assert user.email == email
      assert user.confirmed_at
      assert Accounts.get_user_by_email_and_password(email, password)

      assert Repo.aggregate(User, :count, :id) == user_count + 1
      assert Repo.aggregate(Organization, :count, :id) == org_count + 1
      assert Repo.aggregate(GtfsVersion, :count, :id) == version_count + 1
      assert Repo.aggregate(UserOrgMembership, :count, :id) == membership_count + 1

      org = Repo.get_by(Organization, alias: org_alias)
      assert org
      assert org.name == org_name

      version = Repo.one(from(v in GtfsVersion, where: v.organization_id == ^org.id))
      assert version
      assert version.name == "First Version"
      assert version.publication_status == "published"

      membership =
        Repo.get_by(UserOrgMembership, user_id: user.id, organization_id: org.id)

      assert membership
      assert membership.roles == ["administrator"]
    end

    test "real duplicate organization alias constraint maps to :organization_alias and rolls back writes" do
      alias_val = "dup-#{System.unique_integer([:positive])}"

      _existing_org = organization_fixture(%{name: "Existing Org", alias: alias_val})

      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)
      version_count = Repo.aggregate(GtfsVersion, :count, :id)
      membership_count = Repo.aggregate(UserOrgMembership, :count, :id)

      result =
        Accounts.register_first_admin(%{
          email: unique_user_email(),
          password: valid_user_password(),
          password_confirmation: valid_user_password(),
          organization_name: "New Org",
          organization_alias: alias_val
        })

      assert {:error, %Ecto.Changeset{action: :insert} = changeset} = result
      assert %{organization_alias: [_ | _]} = errors_on(changeset)

      assert Repo.aggregate(User, :count, :id) == user_count
      assert Repo.aggregate(Organization, :count, :id) == org_count
      assert Repo.aggregate(GtfsVersion, :count, :id) == version_count
      assert Repo.aggregate(UserOrgMembership, :count, :id) == membership_count
    end

    test "blank alias persists the normalized organization-name alias" do
      suffix = System.unique_integer([:positive])
      org_name = "Blank Alias Org #{suffix}"

      assert {:ok, %User{}} =
               Accounts.register_first_admin(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 organization_name: org_name,
                 organization_alias: ""
               })

      org = Repo.get_by(Organization, name: org_name)
      assert org
      assert org.alias == "blank-alias-org-#{suffix}"
    end

    test "whitespace-only alias persists the normalized organization-name alias" do
      suffix = System.unique_integer([:positive])
      org_name = "Whitespace Alias Org #{suffix}"

      assert {:ok, %User{}} =
               Accounts.register_first_admin(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 organization_name: org_name,
                 organization_alias: "   "
               })

      org = Repo.get_by(Organization, name: org_name)
      assert org
      assert org.alias == "whitespace-alias-org-#{suffix}"
    end

    test "explicit alias remains authoritative through registration" do
      suffix = System.unique_integer([:positive])
      org_name = "Explicit Alias Org #{suffix}"

      assert {:ok, %User{}} =
               Accounts.register_first_admin(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 organization_name: org_name,
                 organization_alias: "custom-path-#{suffix}"
               })

      org = Repo.get_by(Organization, alias: "custom-path-#{suffix}")
      assert org
      assert org.name == org_name
    end

    test "generated alias collision maps to organization_alias and rolls back every write" do
      suffix = System.unique_integer([:positive])
      org_name = "Collision Org #{suffix}"

      _existing_org =
        organization_fixture(%{name: "Existing Org", alias: "collision-org-#{suffix}"})

      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)
      version_count = Repo.aggregate(GtfsVersion, :count, :id)
      membership_count = Repo.aggregate(UserOrgMembership, :count, :id)

      assert {:error, %Ecto.Changeset{action: :insert} = changeset} =
               Accounts.register_first_admin(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 organization_name: org_name,
                 organization_alias: ""
               })

      assert errors_on(changeset) == %{organization_alias: ["has already been taken"]}
      assert get_field(changeset, :organization_alias) == nil

      assert Repo.aggregate(User, :count, :id) == user_count
      assert Repo.aggregate(Organization, :count, :id) == org_count
      assert Repo.aggregate(GtfsVersion, :count, :id) == version_count
      assert Repo.aggregate(UserOrgMembership, :count, :id) == membership_count
    end

    test "unsluggable generated candidate fails before the transaction and writes nothing" do
      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)
      version_count = Repo.aggregate(GtfsVersion, :count, :id)
      membership_count = Repo.aggregate(UserOrgMembership, :count, :id)

      assert {:error, %Ecto.Changeset{action: :insert} = changeset} =
               Accounts.register_first_admin(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 organization_name: "!!!",
                 organization_alias: ""
               })

      assert errors_on(changeset) == %{organization_alias: ["can't be blank"]}
      assert get_field(changeset, :organization_alias) == nil

      assert Repo.aggregate(User, :count, :id) == user_count
      assert Repo.aggregate(Organization, :count, :id) == org_count
      assert Repo.aggregate(GtfsVersion, :count, :id) == version_count
      assert Repo.aggregate(UserOrgMembership, :count, :id) == membership_count
    end
  end
end
