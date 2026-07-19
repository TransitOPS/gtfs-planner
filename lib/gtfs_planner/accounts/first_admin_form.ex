defmodule GtfsPlanner.Accounts.FirstAdminForm do
  @moduledoc """
  Composite command model for the zero-user first-install setup form.

  Composes the authoritative `GtfsPlanner.Accounts.User` and
  `GtfsPlanner.Organizations.Organization` changesets behind one
  browser-facing field namespace, converts valid input into transaction
  attributes, normalizes transaction failures into safe form errors, and
  removes secrets from failed-submit state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Organizations.Organization

  require Logger

  @primary_key false
  embedded_schema do
    field :email, :string
    field :password, :string, redact: true
    field :password_confirmation, :string, redact: true
    field :organization_name, :string
    field :organization_alias, :string
  end

  @browser_fields [
    :email,
    :password,
    :password_confirmation,
    :organization_name,
    :organization_alias
  ]

  @secret_changes [:password, :password_confirmation]
  @secret_params ["password", "password_confirmation"]

  @domain_field_mapping %{
    email: :email,
    password: :password,
    name: :organization_name,
    alias: :organization_alias
  }

  @base_error "Setup could not be completed. Please try again."

  @type attrs :: %{optional(atom() | String.t()) => term()}

  @doc """
  Builds the composite first-install changeset from browser params.

  Casts the five browser-facing fields, validates password confirmation,
  and copies errors from the authoritative user and organization
  changesets onto the composite fields while preserving error metadata
  and source order.
  """
  @spec changeset(attrs()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    composite =
      %__MODULE__{}
      |> cast(attrs, @browser_fields)
      |> validate_confirmation(:password, message: "does not match password", required: true)

    user_changeset =
      User.registration_changeset(%User{}, user_attrs(composite), hash_password: false)

    organization_changeset =
      Organization.changeset(%Organization{}, organization_attrs(composite))

    copy_errors(composite, user_changeset.errors ++ organization_changeset.errors)
  end

  @doc """
  Converts a valid composite changeset into transaction attributes.
  """
  @spec registration_attrs(Ecto.Changeset.t()) :: %{user: map(), organization: map()}
  def registration_attrs(%Ecto.Changeset{valid?: true} = changeset) do
    %{
      user: user_attrs(changeset),
      organization: organization_attrs(changeset)
    }
  end

  @doc """
  Maps a failed transaction operation onto the composite changeset.

  User and organization changeset failures remap their errors onto the
  browser-facing fields. Every other operation or reason adds a generic
  retryable base error and logs only the failed operation and a stable
  reason class, never the reason itself or any submitted value.
  """
  @spec from_transaction_error(Ecto.Changeset.t(), atom(), term()) :: Ecto.Changeset.t()
  def from_transaction_error(changeset, operation, %Ecto.Changeset{} = source)
      when operation in [:user, :org] do
    copy_errors(changeset, source.errors)
  end

  def from_transaction_error(changeset, operation, reason) do
    Logger.error(
      "First admin registration failed first_admin_operation=#{operation} failure_class=#{failure_class(reason)}"
    )

    add_error(changeset, :base, @base_error)
  end

  @doc """
  Removes password values from a failed-submit changeset while retaining
  validation errors and all non-secret fields.
  """
  @spec sanitize_secrets(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def sanitize_secrets(%Ecto.Changeset{} = changeset) do
    %{
      changeset
      | params: drop_secret_params(changeset.params),
        changes: Map.drop(changeset.changes, @secret_changes)
    }
  end

  defp user_attrs(changeset) do
    %{
      email: get_field(changeset, :email),
      password: get_field(changeset, :password)
    }
  end

  defp organization_attrs(changeset) do
    %{
      name: get_field(changeset, :organization_name),
      alias: get_field(changeset, :organization_alias)
    }
  end

  defp copy_errors(changeset, errors) do
    errors
    |> Enum.reverse()
    |> Enum.reduce(changeset, fn {field, {message, metadata}}, acc ->
      add_error(acc, Map.get(@domain_field_mapping, field, :base), message, metadata)
    end)
  end

  defp drop_secret_params(nil), do: nil
  defp drop_secret_params(params), do: Map.drop(params, @secret_params ++ @secret_changes)

  defp failure_class(%Ecto.Changeset{}), do: :changeset
  defp failure_class(reason) when is_atom(reason), do: :atom
  defp failure_class(reason) when is_tuple(reason), do: :tuple
  defp failure_class(reason) when is_exception(reason), do: :exception
  defp failure_class(_reason), do: :other
end
