defmodule GtfsPlanner.Accounts.User do
  @moduledoc """
  User schema for authentication and account management.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
          hashed_password: String.t() | nil,
          password: String.t() | nil,
          current_password: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :confirmed_at, :naive_datetime

    has_many :tokens, GtfsPlanner.Accounts.UserToken
    has_many :memberships, GtfsPlanner.Accounts.UserOrgMembership

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A user changeset for registration.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :password])
    |> trim_string_fields(except: [:password, :current_password])
    |> validate_email(opts)
    |> validate_password(opts)
  end

  @doc """
  A user changeset for account settings (email).
  """
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> trim_string_fields(except: [:password, :current_password])
    |> validate_email()
    |> case do
      %{changes: %{email: _}} = changeset ->
        changeset
        |> update_change(:email, &String.downcase/1)

      changeset ->
        changeset
    end
  end

  @doc """
  A user changeset for password.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password", required: true)
    |> validate_password(opts)
  end

  @doc """
  A user changeset for confirming the email.
  """
  def confirm_password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:current_password])
    |> validate_current_password(opts)
  end

  @doc """
  A user changeset for confirming the email.
  """
  def confirm_changeset(user) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  A user changeset for inviting a user.
  """
  def invite_changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [:email])
    |> trim_string_fields(except: [:password, :current_password])
    |> validate_email()
    |> validate_required([:email])
    |> unique_constraint(:email)
  end

  @doc """
  A generic changeset for users.
  """
  def changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> trim_string_fields(except: [:password, :current_password])
    |> validate_email(opts)
  end

  @doc """
  Validates the current password.

  Accepts either a password string or an options keyword list with :user.
  """
  def validate_current_password(changeset, password) when is_binary(password) do
    validate_current_password(changeset, password, [])
  end

  def validate_current_password(changeset, password, opts)
      when is_binary(password) and is_list(opts) do
    changeset
    |> put_change(:current_password, password)
    |> validate_required([:current_password])
    |> maybe_validate_current_password(Keyword.put(opts, :password, password))
  end

  defp validate_email(changeset, _opts \\ []) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, GtfsPlanner.Repo)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp maybe_validate_current_password(changeset, opts) do
    user = Keyword.get(opts, :user)
    password = Keyword.get(opts, :password)
    current_password = get_change(changeset, :current_password) || password

    cond do
      !user ->
        changeset
        |> add_error(:current_password, "cannot be validated without user")

      current_password && valid_password?(user, current_password) ->
        changeset

      current_password ->
        add_error(changeset, :current_password, "is invalid")

      true ->
        changeset
    end
  end

  @doc """
  Verifies the password.

  Returns `true` if the password is correct and `false` otherwise.
  """
  @spec valid_password?(t(), String.t()) :: boolean()
  def valid_password?(%GtfsPlanner.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end

  @doc """
  Generates a random password.
  """
  @spec generate_user_password(integer()) :: String.t()
  def generate_user_password(length \\ 24) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode64()
    |> binary_part(0, length)
  end
end
