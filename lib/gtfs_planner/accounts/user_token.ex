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

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @rand_size 32

  @session_validity_in_days 60
  @api_session_validity_in_days 60

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :user, GtfsPlanner.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds a token and token struct to be stored in the database.

  The token is generated using cryptographically secure random bytes
  and is returned as a Base64 encoded string that should be sent to the user (e.g., in a session).
  The token struct contains the hashed version for database storage.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(:sha256, token)

    {Base.url_encode64(token, padding: false),
     %GtfsPlanner.Accounts.UserToken{token: hashed_token, context: "session", user_id: user.id}}
  end

  @doc """
  Builds a token and token struct for API session authentication.

  Works identically to `build_session_token/1` but uses the `"api_session"` context,
  enabling independent lifecycle management for API tokens.
  """
  def build_api_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(:sha256, token)

    {Base.url_encode64(token, padding: false),
     %GtfsPlanner.Accounts.UserToken{
       token: hashed_token,
       context: "api_session",
       user_id: user.id
     }}
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
  Verifies a session token and returns a query to fetch user.

  Returns `:error` if the token is invalid or expired.
  Returns `{:ok, query}` if the token is valid.
  """
  def verify_session_token_query(token) when is_binary(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         hashed_token = :crypto.hash(:sha256, decoded_token) do
      query =
        from token_record in by_token_and_context_query(hashed_token, "session"),
          where: token_record.inserted_at > ago(@session_validity_in_days, "day"),
          join: user in assoc(token_record, :user),
          select: user

      {:ok, query}
    else
      _ -> :error
    end
  end

  @doc """
  Verifies an API session token and returns a query to fetch user.

  Returns `:error` if the token is invalid or expired.
  Returns `{:ok, query}` if the token is valid.
  """
  def verify_api_session_token_query(token) when is_binary(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         hashed_token = :crypto.hash(:sha256, decoded_token) do
      query =
        from token_record in by_token_and_context_query(hashed_token, "api_session"),
          where: token_record.inserted_at > ago(@api_session_validity_in_days, "day"),
          join: user in assoc(token_record, :user),
          select: user

      {:ok, query}
    else
      _ -> :error
    end
  end

  @doc """
  Verifies an email token and returns a query to fetch user.

  Returns `:error` if the token is invalid.
  Returns `{:ok, query}` if the token is valid.
  """
  def verify_email_token_query(token, context) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         hashed_token = :crypto.hash(:sha256, decoded_token) do
      days = days_for_context(context)

      query =
        from token_record in by_token_and_context_query(hashed_token, context),
          join: user in assoc(token_record, :user),
          where: token_record.inserted_at > ago(^days, "day"),
          select: user

      {:ok, query}
    else
      _ -> :error
    end
  end

  def verify_change_email_token_query(token, context) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         hashed_token = :crypto.hash(:sha256, decoded_token) do
      days = days_for_context(context)

      query =
        from token_record in by_token_and_context_query(hashed_token, context),
          where: token_record.inserted_at > ago(^days, "day")

      {:ok, query}
    else
      _ -> :error
    end
  end

  defp days_for_context("api_session"), do: @api_session_validity_in_days
  defp days_for_context("invite"), do: 7
  defp days_for_context("reset_password"), do: 1
  defp days_for_context("confirm"), do: 7
  defp days_for_context("change:" <> _), do: 7

  @doc """
  Checks if the token is associated with the given user and context.
  """
  def valid_token?(token, context) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         hashed_token = :crypto.hash(:sha256, decoded_token) do
      query =
        from t in by_token_and_context_query(hashed_token, context),
          select: t.token

      GtfsPlanner.Repo.exists?(query)
    else
      _ -> false
    end
  end

  @doc """
  Gets all tokens for the given user by context(s).

  ## Examples

      iex> user_and_contexts_query(user, :all)
      #Ecto.Query<...>

      iex> user_and_contexts_query(user, ["session", "reset_password"])
      #Ecto.Query<...>

  """
  def user_and_contexts_query(user, :all) do
    from t in GtfsPlanner.Accounts.UserToken, where: t.user_id == ^user.id
  end

  def user_and_contexts_query(user, contexts) when is_list(contexts) do
    from t in GtfsPlanner.Accounts.UserToken,
      where: t.user_id == ^user.id and t.context in ^contexts
  end

  @doc """
  Gets a token query by token value and context.

  ## Examples

      iex> token_and_context_query(token, "session")
      #Ecto.Query<...>

  """
  def token_and_context_query(token, context) do
    from t in GtfsPlanner.Accounts.UserToken,
      where: t.token == ^token and t.context == ^context
  end

  @doc """
  Deletes a token by context and user.
  """
  def delete_user_token(%GtfsPlanner.Accounts.User{} = user, context) do
    from(t in GtfsPlanner.Accounts.UserToken,
      where: t.user_id == ^user.id and t.context == ^context
    )
    |> GtfsPlanner.Repo.delete_all()
  end

  @doc """
  Deletes all session tokens for the given user.
  """
  def delete_session_tokens(%GtfsPlanner.Accounts.User{} = user) do
    from(t in GtfsPlanner.Accounts.UserToken,
      where: t.user_id == ^user.id and t.context == "session"
    )
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
end
