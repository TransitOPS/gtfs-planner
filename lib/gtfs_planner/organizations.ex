defmodule GtfsPlanner.Organizations do
  @moduledoc """
  The Organizations context for multi-tenant organization management.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.{User, UserOrgMembership, UserToken}
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Organizations.AdminReadAdapter
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions

  @default_admin_read_adapter AdminReadAdapter.Repo

  @doc """
  Returns the list of organizations.

  ## Examples

      iex> list_organizations()
      [%Organization{}, ...]
  """
  def list_organizations do
    Repo.all(Organization)
  end

  @doc """
  Counts the organizations without loading them.

  ## Examples

      iex> count_organizations()
      3
  """
  def count_organizations do
    Repo.aggregate(Organization, :count)
  end

  @doc """
  Gets a single organization.

  Returns nil if the Organization does not exist.

  ## Examples

      iex> get_organization(123)
      %Organization{}

      iex> get_organization(456)
      nil
  """
  def get_organization(id), do: Repo.get(Organization, id)

  @doc """
  Gets a single organization.

  Raises `Ecto.NoResultsError` if the Organization does not exist.

  ## Examples

      iex> get_organization!(123)
      %Organization{}

      iex> get_organization!(456)
      ** (Ecto.NoResultsError)
  """
  def get_organization!(id), do: Repo.get!(Organization, id)

  @doc """
  Gets an organization by its alias.

  Returns nil if the organization does not exist.

  ## Examples

      iex> get_organization_by_alias("my-org")
      %Organization{}

      iex> get_organization_by_alias("nonexistent")
      nil
  """
  def get_organization_by_alias(alias) when is_binary(alias) do
    Repo.get_by(Organization, alias: alias)
  end

  @doc """
  Creates an organization.

  ## Examples

      iex> create_organization(%{alias: "my-org", name: "My Org"})
      {:ok, %Organization{}}

      iex> create_organization(%{alias: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_organization(attrs \\ %{}) do
    Repo.transaction(fn ->
      with {:ok, org} <- insert_organization(attrs),
           {:ok, _version} <- Versions.create_default_version(org.id) do
        org
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> broadcast([:organizations, :created])
  end

  @doc """
  Updates an organization.

  ## Examples

      iex> update_organization(organization, %{name: "New Name"})
      {:ok, %Organization{}}

      iex> update_organization(organization, %{alias: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_organization(%Organization{} = organization, attrs) do
    organization
    |> Organization.changeset(attrs)
    |> Repo.update()
    |> broadcast([:organizations, :updated])
  end

  @doc """
  Deletes an organization.

  ## Examples

      iex> delete_organization(organization)
      {:ok, %Organization{}}

      iex> delete_organization(organization)
      {:error, %Ecto.Changeset{}}
  """
  def delete_organization(%Organization{} = organization) do
    Repo.delete(organization)
    |> broadcast([:organizations, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking organization changes.

  ## Examples

      iex> change_organization(organization)
      %Ecto.Changeset{data: %Organization{}}
  """
  def change_organization(%Organization{} = organization, attrs \\ %{}) do
    Organization.changeset(organization, attrs)
  end

  @doc """
  Removes a user from an organization.

  ## Examples

      iex> remove_user_from_organization(actor, user_id, organization_id)
      {:ok, %UserOrgMembership{}}

      iex> remove_user_from_organization(actor, user_id, organization_id)
      {:error, :not_found}
  """
  def remove_user_from_organization(actor, user_id, organization_id) do
    case membership_command(actor, organization_id, user_id, :remove) do
      {:ok, {membership, digests}} ->
        publish_session_revocations(digests)
        broadcast({:ok, membership}, [:memberships, :deleted])

      error ->
        error
    end
  end

  @doc """
  Updates a user's roles in an organization.

  ## Examples

      iex> update_user_roles(actor, user_id, organization_id, [:pathways_studio_admin])
      {:ok, %UserOrgMembership{}}

      iex> update_user_roles(actor, user_id, organization_id, [])
      {:ok, %UserOrgMembership{}}
  """
  def update_user_roles(actor, user_id, organization_id, roles) do
    case membership_command(actor, organization_id, user_id, {:roles, roles}) do
      {:ok, {membership, digests}} ->
        publish_session_revocations(digests)
        broadcast({:ok, membership}, [:memberships, :updated])

      error ->
        error
    end
  end

  @doc """
  Lists all organizations a user belongs to.

  ## Examples

      iex> list_organizations_for_user(user_id)
      [%Organization{}, ...]
  """
  def list_organizations_for_user(user_id) do
    from(o in Organization,
      join: m in UserOrgMembership,
      on: m.organization_id == o.id,
      where: m.user_id == ^user_id,
      select: {o, m.roles}
    )
    |> Repo.all()
    |> Enum.map(fn {org, roles} ->
      Map.put(org, :user_roles, roles)
    end)
  end

  @doc """
  Lists all users in an organization.

  ## Examples

      iex> list_users_in_organization(organization_id)
      [%{user: %User{}, roles: ["administrator"], deactivated_at: nil}, ...]
  """
  def list_users_in_organization(organization_id) do
    from(u in User,
      join: m in UserOrgMembership,
      on: m.user_id == u.id,
      where: m.organization_id == ^organization_id,
      select: %{user: u, roles: m.roles, deactivated_at: m.deactivated_at},
      order_by: [asc: u.email]
    )
    |> Repo.all()
  end

  @doc """
  Deactivates a user in an organization by setting deactivated_at timestamp.

  Refuses, and changes nothing, when the deactivation would remove platform
  rights or leave the organization without a usable administrator:

    * `{:error, :system_administrator}` - the membership holds `administrator`.
    * `{:error, :last_organization_admin}` - the membership holds
      `pathways_studio_admin` and no other active member of the organization
      holds it with a password set. A pending invitee cannot sign in, so they do
      not count.

  ## Examples

      iex> deactivate_user_in_organization(actor, user_id, organization_id)
      {:ok, %UserOrgMembership{}}

      iex> deactivate_user_in_organization(actor, user_id, organization_id)
      {:error, :not_found}

      iex> deactivate_user_in_organization(actor, system_administrator_id, organization_id)
      {:error, :system_administrator}
  """
  def deactivate_user_in_organization(actor, user_id, organization_id) do
    case membership_command(actor, organization_id, user_id, :deactivate) do
      {:ok, {membership, digests}} ->
        publish_session_revocations(digests)
        broadcast({:ok, membership}, [:memberships, :deactivated])

      error ->
        error
    end
  end

  @doc """
  Activates a user in an organization by clearing deactivated_at timestamp.

  ## Examples

      iex> activate_user_in_organization(actor, user_id, organization_id)
      {:ok, %UserOrgMembership{}}

      iex> activate_user_in_organization(actor, user_id, organization_id)
      {:error, :not_found}
  """
  def activate_user_in_organization(actor, user_id, organization_id) do
    case membership_command(actor, organization_id, user_id, :activate) do
      {:ok, membership} -> broadcast({:ok, membership}, [:memberships, :activated])
      error -> error
    end
  end

  @doc """
  Checks if a user is deactivated in an organization.

  ## Examples

      iex> user_deactivated_in_organization?(user_id, organization_id)
      true

      iex> user_deactivated_in_organization?(user_id, organization_id)
      false
  """
  def user_deactivated_in_organization?(user_id, organization_id) do
    from(m in UserOrgMembership,
      where: m.user_id == ^user_id and m.organization_id == ^organization_id,
      select: m.deactivated_at
    )
    |> Repo.one()
    |> case do
      nil -> false
      deactivated_at when is_struct(deactivated_at, DateTime) -> true
      _ -> false
    end
  end

  @doc """
  Lists organizations for the administration screens.

  Unlike `list_organizations/0`, this returns an explicit outcome so the caller
  can tell a working empty list apart from a database connection that is
  temporarily unavailable.

  ## Examples

      iex> list_organizations_for_admin()
      {:ok, [%Organization{}, ...]}

      iex> list_organizations_for_admin()
      {:error, :unavailable}
  """
  @spec list_organizations_for_admin() ::
          {:ok, [Organization.t()]} | {:error, :unavailable}
  def list_organizations_for_admin do
    admin_read_adapter().list_organizations()
  end

  @doc """
  Fetches one organization for the administration screens.

  The id must already be a well-formed UUID; malformed route text is classified
  by the caller before it reaches this function.

  ## Examples

      iex> fetch_organization_for_admin(organization_id)
      {:ok, %Organization{}}

      iex> fetch_organization_for_admin(unknown_organization_id)
      {:error, :not_found}
  """
  @spec fetch_organization_for_admin(Ecto.UUID.t()) ::
          {:ok, Organization.t()} | {:error, :not_found | :unavailable}
  def fetch_organization_for_admin(id) do
    admin_read_adapter().fetch_organization(id)
  end

  @doc """
  Lists an organization's members for the administration screens.

  Members keep the `list_users_in_organization/1` shape.

  ## Examples

      iex> list_users_for_admin(organization_id)
      {:ok, [%{user: %User{}, roles: ["pathways_studio_admin"], deactivated_at: nil}, ...]}

      iex> list_users_for_admin(organization_id)
      {:error, :unavailable}
  """
  @spec list_users_for_admin(Ecto.UUID.t()) ::
          {:ok, [AdminReadAdapter.member()]} | {:error, :unavailable}
  def list_users_for_admin(organization_id) do
    admin_read_adapter().list_users(organization_id)
  end

  # Private helper functions

  defp membership_command(actor, organization_id, user_id, action) do
    Repo.transaction(fn ->
      actor_level = Authorization.lock_member_admin!(actor, organization_id)

      with {:ok, user_id} <- Ecto.UUID.cast(user_id),
           %UserOrgMembership{} = membership <-
             Repo.one(
               from m in UserOrgMembership,
                 where: m.user_id == ^user_id and m.organization_id == ^organization_id,
                 lock: "FOR UPDATE"
             ) do
        apply_membership_command(action, membership, actor_level)
      else
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  defp apply_membership_command(:deactivate, membership, _actor_level) do
    case check_membership_change_allowed(membership, :deactivate, :system) do
      :ok ->
        updated =
          membership
          |> Ecto.Changeset.change(%{
            deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> update_membership!()

        {updated, delete_session_digests(updated.user_id)}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_membership_command(:activate, membership, _actor_level) do
    membership
    |> Ecto.Changeset.change(%{deactivated_at: nil})
    |> update_membership!()
  end

  defp apply_membership_command({:roles, roles}, membership, actor_level) do
    changeset = UserOrgMembership.changeset(membership, %{roles: roles})

    if not is_list(roles),
      do: Repo.rollback(Ecto.Changeset.add_error(changeset, :roles, "must be a list"))

    if not changeset.valid?, do: Repo.rollback(changeset)
    enforce_membership_change!(membership, {:roles, roles}, actor_level)

    updated = update_membership!(changeset)

    {updated, delete_session_digests(updated.user_id)}
  end

  defp apply_membership_command(:remove, membership, actor_level) do
    enforce_membership_change!(membership, :remove, actor_level)

    deleted =
      case Repo.delete(membership) do
        {:ok, deleted} -> deleted
        {:error, reason} -> Repo.rollback(reason)
      end

    {deleted, delete_session_digests(deleted.user_id)}
  end

  defp update_membership!(changeset) do
    case Repo.update(changeset) do
      {:ok, membership} -> membership
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enforce_membership_change!(membership, change, actor_level) do
    case check_membership_change_allowed(membership, change, actor_level) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # An already-deactivated membership keeps the plain re-deactivation behavior.
  defp check_membership_change_allowed(
         %UserOrgMembership{deactivated_at: %DateTime{}},
         :deactivate,
         _
       ),
       do: :ok

  defp check_membership_change_allowed(
         %UserOrgMembership{roles: roles} = membership,
         change,
         actor_level
       ) do
    proposed_roles = proposed_roles(change)
    removes_system_role? = removes_role?(roles, proposed_roles, "administrator")
    grants_system_role? = grants_role?(roles, proposed_roles, "administrator")
    removes_usable_admin? = removes_usable_admin?(membership, roles, proposed_roles)

    cond do
      removes_system_role? and system_removal_refused?(change, actor_level) ->
        {:error, :system_administrator}

      grants_system_role? and actor_level != :system ->
        {:error, :forbidden}

      removes_usable_admin? and not other_active_admin?(membership) ->
        {:error, :last_organization_admin}

      true ->
        :ok
    end
  end

  defp proposed_roles({:roles, roles}), do: roles
  defp proposed_roles(_change), do: []

  defp removes_role?(roles, proposed_roles, role),
    do: role in roles and role not in proposed_roles

  defp grants_role?(roles, proposed_roles, role),
    do: role not in roles and role in proposed_roles

  defp system_removal_refused?(change, actor_level),
    do: change == :remove or change == :deactivate or actor_level != :system

  defp removes_usable_admin?(%UserOrgMembership{} = membership, roles, proposed_roles) do
    removes_role?(roles, proposed_roles, "pathways_studio_admin") and
      is_nil(membership.deactivated_at) and
      not is_nil(Repo.get!(User, membership.user_id).hashed_password)
  end

  defp delete_session_digests(user_id) do
    user_id
    |> Accounts.delete_user_sessions()
    |> Enum.flat_map(fn
      # The token column already holds the SHA-256 digest used by web session topics.
      %UserToken{context: "session", token: digest} -> [digest]
      %UserToken{} -> []
    end)
  end

  defp publish_session_revocations(digests) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      "session_revocations",
      {:session_tokens_revoked, digests}
    )
  end

  defp other_active_admin?(%UserOrgMembership{id: id, organization_id: organization_id}) do
    from(m in UserOrgMembership,
      join: u in User,
      on: u.id == m.user_id,
      where:
        m.organization_id == ^organization_id and m.id != ^id and is_nil(m.deactivated_at) and
          ^"pathways_studio_admin" in m.roles and not is_nil(u.hashed_password)
    )
    |> Repo.exists?()
  end

  # Resolved per call so tests and future runtime configuration take effect
  # without recompiling this context.
  defp admin_read_adapter do
    Application.get_env(
      :gtfs_planner,
      :organizations_admin_read_adapter,
      @default_admin_read_adapter
    )
  end

  defp insert_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  defp broadcast({:ok, result}, event_topic) do
    Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "organizations", {event_topic, result})
    {:ok, result}
  end

  defp broadcast({:error, reason}, _event_topic) do
    {:error, reason}
  end
end
