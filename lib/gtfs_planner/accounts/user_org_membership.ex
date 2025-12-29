defmodule GtfsPlanner.Accounts.UserOrgMembership do
  @moduledoc """
  Schema representing the membership of a user in an organization.

  This schema manages the many-to-many relationship between users and organizations,
  including role-based authorization within each organization.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Authorization.Roles

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          roles: [String.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_org_memberships" do
    field :roles, {:array, :string}, default: []

    belongs_to :user, GtfsPlanner.Accounts.User
    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for creating or updating a user organization membership.
  """
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :organization_id, :roles])
    |> validate_required([:user_id, :organization_id])
    |> unique_constraint([:user_id, :organization_id])
    |> validate_roles()
  end

  defp validate_roles(changeset) do
    roles = get_field(changeset, :roles)

    if roles == nil or roles == [] do
      changeset
    else
      invalid_roles =
        Enum.reject(roles, fn role -> Roles.valid?(role) end)

      if invalid_roles == [] do
        changeset
      else
        Enum.reduce(invalid_roles, changeset, fn role, acc ->
          add_error(acc, :roles, "contains invalid role: #{role}")
        end)
      end
    end
  end
end
