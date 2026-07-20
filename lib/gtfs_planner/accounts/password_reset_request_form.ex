defmodule GtfsPlanner.Accounts.PasswordResetRequestForm do
  @moduledoc """
  Form model for the password-reset request boundary.

  Validates the single `:email` field syntactically — trimmed presence,
  the repository's shared email shape, and a 160-character maximum — with
  no account lookup, uniqueness check, or other database access, so
  reset-request validation can never disclose whether an address belongs
  to an account.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key false
  embedded_schema do
    field :email, :string
  end

  @type attrs :: %{optional(atom() | String.t()) => term()}

  @doc """
  Builds the reset-request changeset from browser params.

  Trims whitespace and validates required presence, the shared email
  shape (`must have the @ sign and no spaces`), and a maximum length of
  160 characters. Performs no database access of any kind.
  """
  @spec changeset(attrs()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:email])
    |> trim_string_fields()
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
  end
end
