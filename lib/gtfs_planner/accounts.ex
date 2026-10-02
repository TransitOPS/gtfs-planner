defmodule GtfsPlanner.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Repo

  alias GtfsPlanner.Accounts.{
    FirstAdminForm,
    InviteForm,
    PasswordResetRequestForm,
    User,
    UserOrgMembership,
    UserToken
  }

  alias GtfsPlanner.Accounts.UserNotifier
  alias GtfsPlanner.Organizations.Organization

  @first_admin_setup_lock "accounts:first_admin_setup"

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
  Updates the user's default alert authoring mode.

  Accepts the atom or the string form of `:form` or `:assistant`; anything else
  returns `{:error, changeset}` and stores nothing.

  ## Examples

      iex> update_alert_authoring_mode(user, :assistant)
      {:ok, %User{}}

      iex> update_alert_authoring_mode(user, "chat")
      {:error, %Ecto.Changeset{}}

  """
  @spec update_alert_authoring_mode(User.t(), :form | :assistant | String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_alert_authoring_mode(%User{} = user, mode) do
    user
    |> User.alert_authoring_mode_changeset(%{alert_authoring_mode: mode})
    |> Repo.update()
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
  Emulates that the password will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_password(user, "valid password", %{password: "new valid password", password_confirmation: "new valid password"})
      {:ok, %User{}}

      iex> apply_user_password(user, "invalid password", %{password: "valid", password_confirmation: "another valid"})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_password(%User{} = user, current_password, attrs) when is_map(attrs) do
    user
    |> User.password_changeset(attrs, hash_password: false)
    |> User.validate_current_password(current_password, user: user)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: "new valid password", password_confirmation: "new valid password"})
      {:ok, {%User{}, [%UserToken{}]}}

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
    |> Ecto.Multi.run(:tokens, fn repo, _changes ->
      {:ok, repo.all(UserToken.user_and_contexts_query(user, :all))}
    end)
    |> Ecto.Multi.delete_all(:deleted, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, tokens: tokens}} -> {:ok, {user, tokens}}
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
  Deletes all session and API session tokens for a user and returns the
  deleted `%UserToken{}` records.

  Membership commands use the deleted web-session digests to disconnect the
  user's open LiveViews after the transaction commits.

  ## Examples

      iex> delete_user_sessions(user_id)
      [%UserToken{}]

  """
  def delete_user_sessions(user_id) do
    user = get_user!(user_id)

    {_count, tokens} =
      user
      |> UserToken.user_and_contexts_query(["session", "api_session"])
      |> select([t], t)
      |> Repo.delete_all()

    tokens
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

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking password-reset request changes.

  Builds a `PasswordResetRequestForm` changeset that validates the email
  syntactically — trimmed presence, shape, and maximum length — without
  querying accounts or exposing account existence.

  ## Examples

      iex> change_password_reset_request(%{"email" => "user@example.com"})
      %Ecto.Changeset{data: %PasswordResetRequestForm{}}

  """
  @spec change_password_reset_request(map()) :: Ecto.Changeset.t()
  def change_password_reset_request(attrs \\ %{}) do
    PasswordResetRequestForm.changeset(attrs)
  end

  # Minimum gap between reset emails for one account; the newest token's inserted_at records it.
  @reset_request_interval_seconds 60

  @doc ~S"""
  Delivers the reset password email to the given user.

  Only the newest reset link works: issuing a token deletes the user's earlier
  reset tokens. When the user already has a reset token issued within the last
  minute, no token is issued and no email is sent, and the result is
  `{:error, :throttled}`. The check and the insert run in one transaction that
  locks the user row, so simultaneous requests for one account send one email.
  The email is sent after that transaction commits.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/users/reset_password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_reset_password_instructions(user, &url(~p"/users/reset_password/#{&1}"))
      {:error, :throttled}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    case Repo.transaction(fn -> issue_reset_password_token(user) end) do
      {:ok, {:ok, encoded_token}} ->
        UserNotifier.deliver_reset_password_instructions(
          user,
          reset_password_url_fun.(encoded_token)
        )

      {:ok, :throttled} ->
        {:error, :throttled}
    end
  end

  defp issue_reset_password_token(user) do
    # Locking the user row makes concurrent requests for one account queue up,
    # so the later one sees the earlier one's token.
    Repo.one!(from u in User, where: u.id == ^user.id, select: u.id, lock: "FOR UPDATE")

    reset_tokens = UserToken.user_and_contexts_query(user, ["reset_password"])

    recent_tokens =
      from t in reset_tokens,
        where: t.inserted_at > ago(@reset_request_interval_seconds, "second")

    if Repo.exists?(recent_tokens) do
      :throttled
    else
      Repo.delete_all(reset_tokens)
      {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
      Repo.insert!(user_token)
      {:ok, encoded_token}
    end
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

  @type invite_member_result ::
          {:ok, User.t()}
          | {:ok, :added, User.t()}
          | {:error, :forbidden}
          | {:error, Ecto.Changeset.t()}
          | {:partial, :delivery_failed, User.t(), term()}
          | {:partial, :notification_failed, User.t(), term()}

  @doc ~S"""
  Invites a member to an organization as one atomic database command.

  Validates the submission through `GtfsPlanner.Accounts.InviteForm`, then
  locks and authorizes the actor before creating or reusing the user, inserting
  the organization membership, and inserting the invite token inside a single
  `Ecto.Multi`. An unauthorized actor returns `{:error, :forbidden}` without
  creating invite records. Any other failed database operation rolls back the
  command and returns an insert-action `InviteForm` changeset.

  The invitation email is delivered only after the transaction commits. A
  delivery failure leaves the committed user, membership, and usable invite
  token in place and returns `{:partial, :delivery_failed, user, reason}`; the
  safe recovery is `resend_user_invite/4`.

  An address that already belongs to an account with a password gets the
  membership only: no invite token is issued, because a set-password link would
  replace that password. After the commit it is sent a notice with the
  organization name and `:login_url`, and the result is `{:ok, :added, user}`.
  A notice delivery failure leaves the membership in place and returns
  `{:partial, :notification_failed, user, reason}`. `:login_url` is required
  for that case.

  ## Examples

      iex> invite_member("member@example.com", org_id, ["pathways_studio_editor"], &url(~p"/users/accept_invite/#{&1}"), actor: admin, login_url: url(~p"/users/log_in"))
      {:ok, %User{}}

      iex> invite_member("existing@example.com", org_id, ["pathways_studio_editor"], &url(~p"/users/accept_invite/#{&1}"), actor: admin, login_url: url(~p"/users/log_in"))
      {:ok, :added, %User{}}

      iex> invite_member("nope", org_id, [], &url(~p"/users/accept_invite/#{&1}"), actor: admin)
      {:error, %Ecto.Changeset{}}

  """
  @spec invite_member(
          String.t(),
          Ecto.UUID.t(),
          [String.t()],
          (String.t() -> String.t()),
          actor: User.t(),
          login_url: String.t()
        ) :: invite_member_result()
  def invite_member(email, organization_id, roles, invite_url_fun, opts \\ [])
      when is_function(invite_url_fun, 1) do
    actor = Keyword.fetch!(opts, :actor)
    changeset = InviteForm.changeset(%{"email" => email, "roles" => roles})

    if changeset.valid? do
      changeset
      |> invite_member_multi(organization_id, actor)
      |> Repo.transaction()
      |> resolve_invite_member(changeset, invite_url_fun, organization_id, opts)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp invite_member_multi(changeset, organization_id, actor) do
    email = Ecto.Changeset.get_field(changeset, :email)
    roles = Ecto.Changeset.get_field(changeset, :roles)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:authorize, fn _repo, _changes ->
      Authorization.lock_member_admin(actor, organization_id)
    end)
    |> Ecto.Multi.run(:user, fn repo, _changes -> fetch_or_insert_invitee(repo, email) end)
    |> Ecto.Multi.insert(:membership, fn %{user: user} ->
      UserOrgMembership.changeset(%UserOrgMembership{}, %{
        user_id: user.id,
        organization_id: organization_id,
        roles: roles
      })
    end)
    |> Ecto.Multi.run(:token, fn repo, %{user: user} -> insert_invite_token(repo, user) end)
  end

  defp fetch_or_insert_invitee(repo, email) do
    case repo.get_by(User, email: email) do
      nil -> repo.insert(User.invite_changeset(%User{}, %{email: email}))
      %User{} = user -> {:ok, user}
    end
  end

  # A set-password link would replace an existing password, so accounts that
  # already have one get no token.
  defp insert_invite_token(_repo, %User{hashed_password: hashed_password})
       when not is_nil(hashed_password),
       do: {:ok, nil}

  defp insert_invite_token(repo, user) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "invite")

    with {:ok, _persisted} <- repo.insert(user_token), do: {:ok, encoded_token}
  end

  defp resolve_invite_member(
         {:ok, %{user: user, token: nil}},
         _changeset,
         _invite_url_fun,
         organization_id,
         opts
       ) do
    deliver_committed_added_notice(user, organization_id, Keyword.fetch!(opts, :login_url))
  end

  defp resolve_invite_member(
         {:ok, %{user: user, token: token}},
         _changeset,
         invite_url_fun,
         _organization_id,
         _opts
       ) do
    deliver_committed_invite(user, token, invite_url_fun)
  end

  defp resolve_invite_member(
         {:error, :authorize, :forbidden, _changes},
         _changeset,
         _invite_url_fun,
         _organization_id,
         _opts
       ),
       do: {:error, :forbidden}

  defp resolve_invite_member(
         {:error, operation, reason, _changes},
         changeset,
         _invite_url_fun,
         _organization_id,
         _opts
       ) do
    {:error,
     changeset
     |> InviteForm.from_transaction_error(operation, reason)
     |> Map.put(:action, :insert)}
  end

  defp deliver_committed_invite(user, encoded_token, invite_url_fun) do
    case UserNotifier.deliver_user_invite(user, invite_url_fun.(encoded_token)) do
      {:ok, _delivery} -> {:ok, user}
      {:error, reason} -> {:partial, :delivery_failed, user, reason}
    end
  end

  defp deliver_committed_added_notice(user, organization_id, login_url) do
    organization = Repo.get!(Organization, organization_id)

    case UserNotifier.deliver_added_to_organization(user, organization.name, login_url) do
      {:ok, _delivery} -> {:ok, :added, user}
      {:error, reason} -> {:partial, :notification_failed, user, reason}
    end
  end

  @doc ~S"""
  Resends an invitation to a member who has not set a password yet.

  Runs as a member-admin command. One transaction locks the organization,
  checks that `actor` is currently a system administrator or a usable
  administrator of it, confirms `user_id` is a member of that organization and
  still has no password, and inserts a fresh invite token. The email is sent
  after the transaction commits.

  Returns `{:error, :forbidden}` without writing when the actor's permission was
  revoked, `{:error, :not_found}` for an unknown organization or a user who is
  not a member of it, and `{:error, :already_accepted}` when the user has a
  password. A delivery failure returns the notifier's `{:error, reason}` and
  leaves the token in place; resending again is the recovery.

  ## Examples

      iex> resend_user_invite(admin, org_id, user_id, &url(~p"/users/accept_invite/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> resend_user_invite(revoked_admin, org_id, user_id, &url(~p"/users/accept_invite/#{&1}"))
      {:error, :forbidden}

  """
  def resend_user_invite(actor, organization_id, user_id, invite_url_fun)
      when is_function(invite_url_fun, 1) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:authorize, fn _repo, _changes ->
      Authorization.lock_member_admin(actor, organization_id)
    end)
    |> Ecto.Multi.run(:invitee, fn repo, _changes ->
      fetch_pending_member(repo, organization_id, user_id)
    end)
    |> Ecto.Multi.run(:token, fn repo, %{invitee: user} -> insert_invite_token(repo, user) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invitee: user, token: token}} ->
        UserNotifier.deliver_user_invite(user, invite_url_fun.(token))

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  # The user row is locked so an acceptance that commits first is seen here, and
  # one that commits afterwards deletes the token inserted below.
  defp fetch_pending_member(repo, organization_id, user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %UserOrgMembership{} <-
           repo.get_by(UserOrgMembership, user_id: user_id, organization_id: organization_id),
         %User{} = user <- repo.one(from u in User, where: u.id == ^user_id, lock: "FOR UPDATE") do
      if user.hashed_password, do: {:error, :already_accepted}, else: {:ok, user}
    else
      _ -> {:error, :not_found}
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

  Deletes all of the user's tokens, so no earlier session or token outlives the
  password it was issued under. Only the password fields of `attrs` are read.

  The invited organization membership already exists: `invite_member/5` inserts
  it, with the roles the administrator chose, in the same transaction as the
  invite token. Accepting creates no membership, and an `organization_id` in
  `attrs` is ignored, so a holder of an invite token cannot name another
  organization.

  Returns `{:error, :already_has_password}` without changing anything when the
  user already has a password; an invitation must never replace one.

  ## Examples

      iex> accept_invite_set_password(user, %{password: "new valid password", password_confirmation: "new valid password"})
      {:ok, %User{}}

      iex> accept_invite_set_password(user, %{password: "invalid", password_confirmation: "doesn't match"})
      {:error, %Ecto.Changeset{}}

      iex> accept_invite_set_password(user_with_password, %{password: "new valid password", password_confirmation: "new valid password"})
      {:error, :already_has_password}

  """
  def accept_invite_set_password(%User{hashed_password: hashed_password}, _attrs)
      when not is_nil(hashed_password),
      do: {:error, :already_has_password}

  def accept_invite_set_password(user, attrs) do
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

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking first-admin setup changes.

  Builds a composite `FirstAdminForm` changeset that composes user and
  organization validation behind the five browser-facing fields.

  ## Examples

      iex> change_first_admin(%{email: "admin@example.com"})
      %Ecto.Changeset{data: %FirstAdminForm{}}

  """
  @spec change_first_admin(map()) :: Ecto.Changeset.t()
  def change_first_admin(attrs \\ %{}) do
    FirstAdminForm.changeset(attrs)
  end

  @doc """
  Registers the first administrator user along with their organization.

  Creates a user, organization, default GTFS version, user-organization membership
  with administrator role, and confirms the user account. All operations occur
  atomically within a single transaction.

  The transaction first takes an advisory lock, then checks that no user exists.
  Concurrent setups queue on the lock, and the one that waits sees the winner's
  committed user and returns `{:error, :already_set_up}` without writing.

  ## Examples

      iex> register_first_admin(%{email: "admin@example.com", password: "password123", password_confirmation: "password123", organization_name: "My Org", organization_alias: "my-org"})
      {:ok, %User{}}

      iex> register_first_admin(%{email: "invalid"})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_first_admin(map()) ::
          {:ok, User.t()} | {:error, :already_set_up} | {:error, Ecto.Changeset.t()}
  def register_first_admin(attrs) do
    changeset = FirstAdminForm.changeset(attrs)

    if changeset.valid? do
      registration = FirstAdminForm.registration_attrs(changeset)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:setup_open, fn _repo, _changes -> ensure_setup_open() end)
      |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, registration.user))
      |> Ecto.Multi.insert(
        :org,
        Organization.changeset(%Organization{}, registration.organization)
      )
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
        {:ok, %{confirm_user: user}} ->
          {:ok, user}

        {:error, :setup_open, :already_set_up, _changes} ->
          {:error, :already_set_up}

        {:error, op, reason, _} ->
          {:error,
           FirstAdminForm.from_transaction_error(changeset, op, reason)
           |> Map.put(:action, :insert)}
      end
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  # Setups queue on one advisory lock. The count is read after the lock is held,
  # so a setup that committed while this one waited is counted.
  defp ensure_setup_open do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@first_admin_setup_lock])

    if count_users() == 0, do: {:ok, :open}, else: {:error, :already_set_up}
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
  Lists all organization memberships for a user, including deactivated memberships.
  """
  def list_user_org_memberships_including_deactivated(user_id) do
    UserOrgMembership
    |> where([m], m.user_id == ^user_id)
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
