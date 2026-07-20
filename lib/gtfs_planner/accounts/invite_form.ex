defmodule GtfsPlanner.Accounts.InviteForm do
  @moduledoc """
  Embedded command model for the organization member invitation form.

  Owns the two browser-facing fields (`:email` and `:roles`), normalizes the
  submitted email, restricts roles to the canonical organization-scoped set,
  exposes the canonical role options for select controls, and maps invitation
  transaction failures onto safe form errors.

  The form may carry a `:base` error, but `:base` is never cast from browser
  params.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Authorization.Roles

  require Logger

  @primary_key false
  embedded_schema do
    field :email, :string
    field :roles, {:array, :string}, default: []
  end

  @browser_fields [:email, :roles]

  @allowed_roles ~w(pathways_studio_admin pathways_studio_editor)

  @base_error "The invitation could not be completed. Please try again."
  @duplicate_membership_error "This person is already a member of this organization."
  @invalid_role_error "contains an invalid role"
  @missing_role_error "must select at least one role"

  @membership_conflict_fields [:user_id, :organization_id]

  @type attrs :: %{optional(atom() | String.t()) => term()}

  @doc """
  Builds the invitation changeset from browser params.

  Trims and downcases the email, drops blank role entries, delegates email
  validation to the authoritative `User.invite_changeset/2`, and validates the
  role selection independently so email and role errors never mask each other.
  """
  @spec changeset(attrs()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    form =
      %__MODULE__{}
      |> cast(attrs, @browser_fields)
      |> update_change(:email, &normalize_email/1)
      |> update_change(:roles, &normalize_roles/1)
      |> validate_roles()

    email_changeset = User.invite_changeset(%User{}, %{email: get_field(form, :email)})

    copy_errors(form, shape_errors(email_changeset.errors))
  end

  # An invitation reuses an existing account, so an already-registered email is
  # a valid submission here. Uniqueness stays enforced by the user insert
  # inside the invitation transaction and is remapped by
  # `from_transaction_error/3` if a concurrent insert wins the race.
  defp shape_errors(errors) do
    Enum.reject(errors, fn {_field, {_message, metadata}} ->
      Keyword.get(metadata, :validation) == :unsafe_unique
    end)
  end

  @doc """
  Returns the canonical `{label, value}` options for organization roles.

  The system-level `administrator` role is organization-out-of-scope and is
  never offered, so it cannot be submitted through an organization invitation.
  """
  @spec available_roles() :: [{String.t(), String.t()}]
  def available_roles do
    by_value =
      :organization
      |> Roles.list_by_scope()
      |> Map.new(fn {role, %{name: name}} -> {Atom.to_string(role), name} end)

    for value <- @allowed_roles, name = Map.get(by_value, value), do: {name, value}
  end

  @doc """
  Maps a failed invitation transaction operation onto the form changeset.

  User failures remap onto `:email`, membership role failures remap onto
  `:roles`, and a membership uniqueness conflict becomes an explicit base
  error. Every other operation or reason adds a generic retryable base error
  and logs only the failed operation and a stable reason class, never the
  reason itself or any submitted value.
  """
  @spec from_transaction_error(Ecto.Changeset.t(), atom(), term()) :: Ecto.Changeset.t()
  def from_transaction_error(changeset, :user, %Ecto.Changeset{} = source) do
    copy_errors(changeset, source.errors)
  end

  def from_transaction_error(changeset, :membership, %Ecto.Changeset{} = source) do
    if Enum.any?(source.errors, fn {field, _} -> field in @membership_conflict_fields end) do
      add_error(changeset, :base, @duplicate_membership_error)
    else
      copy_errors(changeset, source.errors)
    end
  end

  def from_transaction_error(changeset, operation, reason) do
    Logger.error(
      "Organization invitation failed invite_operation=#{operation} failure_class=#{failure_class(reason)}"
    )

    add_error(changeset, :base, @base_error)
  end

  defp normalize_email(nil), do: nil

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp normalize_email(email), do: email

  defp normalize_roles(roles) when is_list(roles) do
    roles
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_roles(roles), do: roles

  defp validate_roles(changeset) do
    case get_field(changeset, :roles) do
      roles when is_list(roles) and roles != [] ->
        if Enum.all?(roles, &(&1 in @allowed_roles)) do
          changeset
        else
          add_error(changeset, :roles, @invalid_role_error)
        end

      _ ->
        add_error(changeset, :roles, @missing_role_error)
    end
  end

  defp copy_errors(changeset, errors) do
    errors
    |> Enum.reverse()
    |> Enum.reduce(changeset, fn {field, {message, metadata}}, acc ->
      add_error(acc, form_field(field), message, metadata)
    end)
  end

  defp form_field(:email), do: :email
  defp form_field(:roles), do: :roles
  defp form_field(_field), do: :base

  defp failure_class(%Ecto.Changeset{}), do: :changeset
  defp failure_class(reason) when is_atom(reason), do: :atom
  defp failure_class(reason) when is_tuple(reason), do: :tuple
  defp failure_class(reason) when is_exception(reason), do: :exception
  defp failure_class(_reason), do: :other
end
