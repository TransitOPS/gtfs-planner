defmodule GtfsPlanner.Authorization do
  @moduledoc """
  Current membership checks for interactive writes.

  A write transaction takes the actor's membership share lock before any version
  or entity lock. Membership changes take the organization update lock before
  locking membership rows; they do not lock versions or run rows.
  """

  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @editor_role "pathways_studio_editor"
  @admin_role "pathways_studio_admin"
  @system_role "administrator"

  @doc "Returns whether the actor currently has an active editor membership in the organization."
  @spec authorize_editor(map()) :: :ok | {:error, :forbidden}
  def authorize_editor(%{actor_id: actor_id, organization_id: organization_id}) do
    with {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
         {:ok, organization_id} <- Ecto.UUID.cast(organization_id),
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(actor_id, organization_id),
         true <- active_role?(membership, @editor_role) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_editor(_), do: {:error, :forbidden}

  @doc """
  Locks the actor's current editor membership for the rest of a write transaction.

  Call only inside `Repo.transaction/1`. Missing or revoked permission rolls the
  transaction back with `:forbidden`.
  """
  @spec lock_editor!(map()) :: UserOrgMembership.t()
  def lock_editor!(%{actor_id: actor_id, organization_id: organization_id}) do
    with {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
         {:ok, organization_id} <- Ecto.UUID.cast(organization_id),
         %UserOrgMembership{} = membership <- locked_membership(actor_id, organization_id),
         true <- active_role?(membership, @editor_role) do
      membership
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  def lock_editor!(_), do: Repo.rollback(:forbidden)

  @doc """
  Locks the organization before checking membership administration permission.

  Call only inside `Repo.transaction/1`. A missing organization rolls back with
  `:not_found`; missing or unusable permission rolls back with `:forbidden`.
  """
  @spec lock_member_admin!(User.t(), Ecto.UUID.t()) :: :system | UserOrgMembership.t()
  def lock_member_admin!(%User{id: actor_id}, organization_id) do
    case lock_member_admin(%User{id: actor_id}, organization_id) do
      {:ok, permission} -> permission
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def lock_member_admin!(_, _), do: Repo.rollback(:forbidden)

  @doc """
  Locks the organization and returns the actor's current member-admin permission.

  Call only inside a transaction. Returns `{:error, reason}` without rolling
  back so the result can be composed inside `Ecto.Multi.run/3`.
  """
  @spec lock_member_admin(User.t(), Ecto.UUID.t()) ::
          {:ok, :system | UserOrgMembership.t()} | {:error, :not_found | :forbidden}
  def lock_member_admin(%User{id: actor_id}, organization_id) do
    with {:ok, organization_id} <- Ecto.UUID.cast(organization_id),
         %Organization{} <-
           Repo.one(from o in Organization, where: o.id == ^organization_id, lock: "FOR UPDATE") do
      if system_administrator?(actor_id) do
        {:ok, :system}
      else
        membership = locked_membership(actor_id, organization_id)
        user = Repo.get(User, actor_id)

        if usable_admin?(membership, user),
          do: {:ok, membership},
          else: {:error, :forbidden}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def lock_member_admin(_, _), do: {:error, :forbidden}

  @doc "Returns whether a membership belongs to an active admin with a password."
  @spec usable_admin?(UserOrgMembership.t() | nil, User.t() | nil) :: boolean()
  def usable_admin?(%UserOrgMembership{} = membership, %User{} = user) do
    active_role?(membership, @admin_role) and not is_nil(user.hashed_password)
  end

  def usable_admin?(_, _), do: false

  defp active_role?(%UserOrgMembership{deactivated_at: nil, roles: roles}, role)
       when is_list(roles),
       do: role in roles

  defp active_role?(_, _), do: false

  defp locked_membership(actor_id, organization_id) do
    Repo.one(
      from m in UserOrgMembership,
        where: m.user_id == ^actor_id and m.organization_id == ^organization_id,
        lock: "FOR SHARE"
    )
  end

  defp system_administrator?(actor_id) do
    Repo.one(
      from m in UserOrgMembership,
        where: m.user_id == ^actor_id and is_nil(m.deactivated_at) and ^@system_role in m.roles,
        select: m.id,
        limit: 1,
        lock: "FOR SHARE"
    ) != nil
  end
end
