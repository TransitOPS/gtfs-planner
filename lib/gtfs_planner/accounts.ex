defmodule GtfsPlanner.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo

  alias GtfsPlanner.Accounts.{User, UserToken, UserOrgMembership}
  alias GtfsPlanner.Accounts.UserNotifier
  alias GtfsPlanner.Organizations.Organization

  ## Database getters

  @doc """
  Gets a user by id.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Returns the count of users in the system.

  ## Examples

      iex> count_users()
      0

      iex> count_users()
      1

  """
  def count_users do
    Repo.aggregate(User, :count, :id)
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user_registration(%User{email: "valid@email.com"})
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(%User{} = user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid@email.com", %{current_password: "valid"})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid@email.com", %{current_password: "invalid"})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password, user: user)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.

  ## Examples

      iex> update_user_email(user, "valid@email.com", "valid_token")
      {:ok, %User{}}

      iex> update_user_email(user, "invalid@email.com", "invalid_token")
      {:error, :invalid_token}

  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{} = token <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, token, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, token, _context) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :user,
      user
      |> User.email_changeset(%{email: token.sent_to})
      |> User.confirm_changeset()
    )
    |> Ecto.Multi.delete(:token, token)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm_email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} =
      UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(%User{} = user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: "new valid password", password_confirmation: "new valid password"})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: "valid", password_confirmation: "another valid"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password, user: user)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_user_by_session_token(token) do
    case UserToken.verify_session_token_query(token) do
      {:ok, query} ->
        case Repo.one(query) do
          nil -> nil
          user -> user
        end

      _ ->
        nil
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_session_token(token) do
    token = Base.url_decode64!(token, padding: false)
    hashed_token = :crypto.hash(:sha256, token)
    Repo.delete_all(UserToken.token_and_context_query(hashed_token, "session"))
    :ok
  end

  @doc """
  Deletes all session tokens for a user.

  This is used when deactivating a user to force them to log out.

  ## Examples

      iex> delete_user_sessions(user_id)
      :ok

  """
  def delete_user_sessions(user_id) do
    user = get_user!(user_id)
    Repo.delete_all(UserToken.user_and_contexts_query(user, ["session", "api_session"]))
    :ok
  end

  ## API Session

  @doc """
  Generates an API session token.
  """
  def generate_api_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_api_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given API session token.
  """
  def get_user_by_api_session_token(token) do
    case UserToken.verify_api_session_token_query(token) do
      {:ok, query} ->
        Repo.one(query)

      _ ->
        nil
    end
  end

  @doc """
  Deletes a single API session token by its encoded value.
  """
  def delete_api_session_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} ->
        hashed_token = :crypto.hash(:sha256, decoded)
        Repo.delete_all(UserToken.token_and_context_query(hashed_token, "api_session"))
        :ok

      :error ->
        :ok
    end
  end

  @doc """
  Deletes all API session tokens for a user.
  """
  def delete_api_session_tokens(%User{} = user) do
    Repo.delete_all(UserToken.user_and_contexts_query(user, ["api_session"]))
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/users/reset_password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new valid password", password_confirmation: "new valid password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "invalid", password_confirmation: "doesn't match"})
      {:error, %Ecto.Changeset{}}

  """
  def reset_user_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :user,
      user |> User.password_changeset(attrs) |> User.confirm_changeset()
    )
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## User invitation

  @doc """
  Invites a user to an organization.

  Creates a user record if one doesn't exist, then generates an invite token.

  ## Examples

      iex> invite_user("new@example.com", org_id)
      {:ok, %User{}}

      iex> invite_user("", org_id)
      {:error, %Ecto.Changeset{}}

  """
  def invite_user(email, _organization_id) when is_binary(email) do
    email = String.downcase(email)

    case get_user_by_email(email) do
      nil ->
        %User{}
        |> User.invite_changeset(%{email: email})
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  @doc ~S"""
  Delivers the user invitation email to the given user.

  ## Examples

      iex> deliver_user_invite(user, &url(~p"/users/accept_invite/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_invite(%User{} = user, invite_url_fun) when is_function(invite_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "invite")
    Repo.insert!(user_token)
    UserNotifier.deliver_user_invite(user, invite_url_fun.(encoded_token))
  end

  @doc ~S"""
  Resends an invitation to a user who hasn't set a password yet.

  Returns {:error, :already_accepted} if user has already set a password.

  ## Examples

      iex> resend_user_invite(user, &url(~p"/users/accept_invite/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> resend_user_invite(accepted_user, &url(~p"/users/accept_invite/#{&1}"))
      {:error, :already_accepted}

  """
  def resend_user_invite(%User{} = user, invite_url_fun) when is_function(invite_url_fun, 1) do
    if user.hashed_password do
      {:error, :already_accepted}
    else
      deliver_user_invite(user, invite_url_fun)
    end
  end

  @doc """
  Gets the user by invite token.

  ## Examples

      iex> get_user_by_invite_token("validtoken")
      %User{}

      iex> get_user_by_invite_token("invalidtoken")
      nil

  """
  def get_user_by_invite_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "invite"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Accepts an invitation by setting the user's password.

  If an organization_id is provided, creates a membership with default viewer role.

  ## Examples

      iex> accept_invite_set_password(user, %{password: "new valid password", password_confirmation: "new valid password", organization_id: org_id})
      {:ok, %User{}}

      iex> accept_invite_set_password(user, %{password: "invalid", password_confirmation: "doesn't match"})
      {:error, %Ecto.Changeset{}}

  """
  def accept_invite_set_password(user, attrs) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(
        :user,
        user |> User.password_changeset(attrs) |> User.confirm_changeset()
      )
      |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["invite"]))

    # Add membership creation if organization_id is provided
    multi =
      case Map.get(attrs, :organization_id) || Map.get(attrs, "organization_id") do
        nil ->
          multi

        org_id ->
          membership_attrs = %{
            user_id: user.id,
            organization_id: org_id,
            roles: ["pathways_studio_editor"]
          }

          Ecto.Multi.insert(
            multi,
            :membership,
            UserOrgMembership.changeset(%UserOrgMembership{}, membership_attrs)
          )
      end

    multi
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
      {:error, :membership, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Registers the first administrator user along with their organization.

  Creates a user, organization, default GTFS version, user-organization membership
  with administrator role, and confirms the user account. All operations occur
  atomically within a single transaction.

  ## Examples

      iex> register_first_admin(%{email: "admin@example.com", password: "password123", password_confirmation: "password123"}, %{name: "My Org", alias: "my-org"})
      {:ok, %User{}}

      iex> register_first_admin(%{email: "invalid"}, %{name: "My Org"})
      {:error, %Ecto.Changeset{}}

  """
  def register_first_admin(user_attrs, org_attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, user_attrs))
    |> Ecto.Multi.insert(:org, Organization.changeset(%Organization{}, org_attrs))
    |> Ecto.Multi.run(:version, fn _repo, %{org: org} ->
      GtfsPlanner.Versions.create_default_version(org.id)
    end)
    |> Ecto.Multi.insert(:membership, fn %{user: user, org: org} ->
      UserOrgMembership.changeset(%UserOrgMembership{}, %{
        user_id: user.id,
        organization_id: org.id,
        roles: ["administrator"]
      })
    end)
    |> Ecto.Multi.update(:confirm_user, fn %{user: user} ->
      User.confirm_changeset(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
      {:error, :org, changeset, _} -> {:error, changeset}
      {:error, _, _, _} -> {:error, :transaction_failed}
    end
  end

  ## User Organization Memberships

  @doc """
  Lists all organization memberships for a user.

  ## Examples

      iex> list_user_org_memberships(user_id)
      [%UserOrgMembership{}, ...]

  """
  def list_user_org_memberships(user_id) do
    UserOrgMembership
    |> where([m], m.user_id == ^user_id and is_nil(m.deactivated_at))
    |> Repo.all()
  end

  @doc """
  Gets a user organization membership by user ID and organization ID.

  ## Examples

      iex> get_user_org_membership(user_id, org_id)
      %UserOrgMembership{}

      iex> get_user_org_membership(user_id, :invalid_org_id)
      nil

  """
  def get_user_org_membership(user_id, organization_id) do
    UserOrgMembership
    |> Repo.get_by(user_id: user_id, organization_id: organization_id)
  end

  @doc """
  Creates a user organization membership.

  ## Examples

      iex> create_user_org_membership(%{user_id: user.id, organization_id: org.id})
      {:ok, %UserOrgMembership{}}

      iex> create_user_org_membership(%{user_id: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_user_org_membership(attrs) do
    %UserOrgMembership{}
    |> UserOrgMembership.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user organization membership.

  ## Examples

      iex> update_user_org_membership(membership, %{roles: ["admin"]})
      {:ok, %UserOrgMembership{}}

      iex> update_user_org_membership(membership, %{roles: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_org_membership(%UserOrgMembership{} = membership, attrs) do
    membership
    |> UserOrgMembership.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user organization membership.

  ## Examples

      iex> delete_user_org_membership(membership)
      {:ok, %UserOrgMembership{}}

      iex> delete_user_org_membership(membership)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user_org_membership(%UserOrgMembership{} = membership) do
    Repo.delete(membership)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user organization membership changes.

  ## Examples

      iex> change_user_org_membership(membership)
      %Ecto.Changeset{data: %UserOrgMembership{}}

  """
  def change_user_org_membership(%UserOrgMembership{} = membership, attrs \\ %{}) do
    UserOrgMembership.changeset(membership, attrs)
  end
end
