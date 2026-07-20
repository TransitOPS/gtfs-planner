defmodule GtfsPlanner.Organizations do
  @moduledoc """
  The Organizations context for multi-tenant organization management and API key authentication.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Organizations.AdminReadAdapter
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Organizations.ApiKey
  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
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
  Returns the list of API keys for an organization.

  ## Examples

      iex> list_api_keys(organization_id)
      [%ApiKey{}, ...]
  """
  def list_api_keys(organization_id) do
    from(a in ApiKey, where: a.organization_id == ^organization_id)
    |> Repo.all()
  end

  @doc """
  Gets a single API key.

  Raises `Ecto.NoResultsError` if the ApiKey does not exist.

  ## Examples

      iex> get_api_key!(123)
      %ApiKey{}

      iex> get_api_key!(456)
      ** (Ecto.NoResultsError)
  """
  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  @doc """
  Gets an API key by its token.

  Returns nil if the token is invalid or the API key does not exist.

  ## Examples

      iex> get_api_key_by_token("GtfsPlanner.V1.abcdefg")
      {:ok, %ApiKey{}}

      iex> get_api_key_by_token("invalid")
      {:error, :invalid}
  """
  def get_api_key_by_token(token) when is_binary(token) do
    ApiKey.verify_token(token, Repo)
  end

  @doc """
  Creates an API key for an organization.

  ## Examples

      iex> create_api_key(organization_id, %{description: "My Key", roles: ["read"]})
      {:ok, {%ApiKey{}, "GtfsPlanner.V1.abcdefg"}}

      iex> create_api_key(organization_id, %{description: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_api_key(organization_id, attrs \\ %{}) do
    import Ecto.Changeset, only: [validate_required: 2]

    changeset =
      %ApiKey{organization_id: organization_id}
      |> ApiKey.changeset(attrs)
      |> validate_required([:organization_id])

    {token, updated_changeset} = ApiKey.build_hashed_token(organization_id, changeset)

    case Repo.insert(updated_changeset) do
      {:ok, api_key} -> {:ok, {api_key, token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Updates an API key.

  ## Examples

      iex> update_api_key(api_key, %{description: "Updated Description"})
      {:ok, %ApiKey{}}

      iex> update_api_key(api_key, %{description: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_api_key(%ApiKey{} = api_key, attrs) do
    api_key
    |> ApiKey.update_changeset(attrs)
    |> Repo.update()
    |> broadcast([:api_keys, :updated])
  end

  @doc """
  Deletes an API key.

  ## Examples

      iex> delete_api_key(api_key)
      {:ok, %ApiKey{}}

      iex> delete_api_key(api_key)
      {:error, %Ecto.Changeset{}}
  """
  def delete_api_key(%ApiKey{} = api_key) do
    Repo.delete(api_key)
    |> broadcast([:api_keys, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking API key changes.

  ## Examples

      iex> change_api_key(api_key)
      %Ecto.Changeset{data: %ApiKey{}}
  """
  def change_api_key(api_key, attrs \\ %{})

  def change_api_key(%ApiKey{id: id} = api_key, attrs) when not is_nil(id) do
    ApiKey.update_changeset(api_key, attrs)
  end

  def change_api_key(%ApiKey{} = api_key, attrs) do
    ApiKey.changeset(api_key, attrs)
  end

  @doc """
  Adds a user to an organization with specified roles.

  ## Examples

      iex> add_user_to_organization(user_id, organization_id, [:administrator])
      {:ok, %UserOrgMembership{}}

      iex> add_user_to_organization(user_id, organization_id, [])
      {:ok, %UserOrgMembership{}}
  """
  def add_user_to_organization(user_id, organization_id, roles \\ []) do
    %UserOrgMembership{
      user_id: user_id,
      organization_id: organization_id,
      roles: roles
    }
    |> UserOrgMembership.changeset(%{})
    |> Repo.insert()
    |> broadcast([:memberships, :created])
  end

  @doc """
  Removes a user from an organization.

  ## Examples

      iex> remove_user_from_organization(user_id, organization_id)
      {:ok, %UserOrgMembership{}}

      iex> remove_user_from_organization(user_id, organization_id)
      {:error, :not_found}
  """
  def remove_user_from_organization(user_id, organization_id) do
    from(m in UserOrgMembership,
      where: m.user_id == ^user_id and m.organization_id == ^organization_id
    )
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      membership ->
        Repo.delete(membership)
        |> broadcast([:memberships, :deleted])
    end
  end

  @doc """
  Updates a user's roles in an organization.

  ## Examples

      iex> update_user_roles(user_id, organization_id, [:administrator, :editor])
      {:ok, %UserOrgMembership{}}

      iex> update_user_roles(user_id, organization_id, [])
      {:ok, %UserOrgMembership{}}
  """
  def update_user_roles(user_id, organization_id, roles) do
    from(m in UserOrgMembership,
      where: m.user_id == ^user_id and m.organization_id == ^organization_id,
      preload: [:user, :organization]
    )
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      membership ->
        membership
        |> UserOrgMembership.changeset(%{roles: roles})
        |> Repo.update()
        |> broadcast([:memberships, :updated])
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

  ## Examples

      iex> deactivate_user_in_organization(user_id, organization_id)
      {:ok, %UserOrgMembership{}}

      iex> deactivate_user_in_organization(user_id, organization_id)
      {:error, :not_found}
  """
  def deactivate_user_in_organization(user_id, organization_id) do
    from(m in UserOrgMembership,
      where: m.user_id == ^user_id and m.organization_id == ^organization_id
    )
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      membership ->
        result =
          membership
          |> Ecto.Changeset.change(%{
            deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> Repo.update()

        case result do
          {:ok, _membership} = success ->
            # Invalidate all user sessions
            GtfsPlanner.Accounts.delete_user_sessions(user_id)
            broadcast(success, [:memberships, :deactivated])

          error ->
            error
        end
    end
  end

  @doc """
  Activates a user in an organization by clearing deactivated_at timestamp.

  ## Examples

      iex> activate_user_in_organization(user_id, organization_id)
      {:ok, %UserOrgMembership{}}

      iex> activate_user_in_organization(user_id, organization_id)
      {:error, :not_found}
  """
  def activate_user_in_organization(user_id, organization_id) do
    from(m in UserOrgMembership,
      where: m.user_id == ^user_id and m.organization_id == ^organization_id
    )
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      membership ->
        membership
        |> Ecto.Changeset.change(%{deactivated_at: nil})
        |> Repo.update()
        |> broadcast([:memberships, :activated])
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
