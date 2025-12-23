defmodule GtfsPlanner.Accounts.UserToken do
  @moduledoc """
  Token schema for authentication sessions and email verification tokens.

  This schema manages various types of tokens:
  - Session tokens for user authentication (60-day expiry)
  - Email tokens for invitations, password resets, and email changes
  - All tokens are hashed in the database for security
  """

  use Ecto.Schema
  import Ecto.Query

  @rand_size 32

  @session_validity_in_days 60

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :user, GtfsPlanner.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a token and token struct to be stored in the database.

  The token is generated using cryptographically secure random bytes
  and is returned as a binary that should be sent to the user (e.g., in an email).
  The token struct contains the hashed version for database storage.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %GtfsPlanner.Accounts.UserToken{token: token, context: "session", user_id: user.id}}
  end

  @doc """
  Builds a token with a specific context for email-based operations.

  Contexts:
  - "invite": User invitation (7-day expiry)
  - "reset_password": Password reset (1-day expiry)
  - "change:<email>": Email change confirmation (7-day expiry)
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(:sha256, token)

    {Base.url_encode64(token, padding: false),
     %GtfsPlanner.Accounts.UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Verifies a session token and returns a query to fetch the user.

  Returns `:error` if the token is invalid or expired.
  Returns `{:ok, query}` if the token is valid.
  """
  def verify_session_token_query(token) do
    hashed_token = :crypto.hash(:sha256, token)

    query =
      from token in by_token_and_context_query(hashed_token, "session"),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: token.user_id

    {:ok, query}
  end

  @doc """
  Verifies an email token and returns a query to fetch the user.

  Returns `:error` if the token is invalid.
  Returns `{:ok, query}` if the token is valid.
  """
  def verify_email_token_query(token, context) do
    hashed_token = :crypto.hash(:sha256, token)

    query =
      from token in by_token_and_context_query(hashed_token, context),
        select: token.user_id

    {:ok, query}
  end

  @doc """
  Checks if the token is associated with the given user and context.
  """
  def valid_token?(token, context) do
    hashed_token = :crypto.hash(:sha256, token)

    query =
      from t in by_token_and_context_query(hashed_token, context),
        select: t.token

    GtfsPlanner.Repo.exists?(query)
  end

  @doc """
  Deletes a token by context and user.
  """
  def delete_user_token(%GtfsPlanner.Accounts.User{} = user, context) do
    from(t in GtfsPlanner.Accounts.UserToken, where: t.user_id == ^user.id and t.context == ^context)
    |> GtfsPlanner.Repo.delete_all()
  end

  @doc """
  Deletes all session tokens for the given user.
  """
  def delete_session_tokens(%GtfsPlanner.Accounts.User{} = user) do
    from(t in GtfsPlanner.Accounts.UserToken, where: t.user_id == ^user.id and t.context == "session")
    |> GtfsPlanner.Repo.delete_all()
  end

  @doc """
  Deletes all tokens for the given user.
  """
  def delete_user_tokens(%GtfsPlanner.Accounts.User{} = user) do
    from(t in GtfsPlanner.Accounts.UserToken, where: t.user_id == ^user.id)
    |> GtfsPlanner.Repo.delete_all()
  end

  # Private helper functions

  defp by_token_and_context_query(token, context) do
    from t in GtfsPlanner.Accounts.UserToken,
      where: t.token == ^token and t.context == ^context
  end

  defp by_email_and_context_query(email, context) do
    from t in GtfsPlanner.Accounts.UserToken,
      where: t.sent_to == ^email and t.context == ^context
  end
end
