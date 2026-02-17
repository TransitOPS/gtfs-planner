defmodule GtfsPlanner.Authorization.Roles do
  @moduledoc """
  Canonical role definitions for the Pathways Studio application.

  Defines three distinct roles with specific scopes and permissions:
  - `administrator`: System-level role for managing organizations
  - `pathways_studio_admin`: Organization-level role for managing users
  - `pathways_studio_editor`: Organization-level role with full GTFS data access
  """

  @roles %{
    administrator: %{
      name: "Administrator",
      description: "Manages organizations (tenants) in the multi-tenant system",
      scope: :system
    },
    pathways_studio_admin: %{
      name: "Pathways Studio Admin",
      description: "Manages users within their organization",
      scope: :organization
    },
    pathways_studio_editor: %{
      name: "Pathways Studio Editor",
      description: "Full access to view and modify GTFS data",
      scope: :organization
    }
  }

  @doc """
  Returns all canonical roles with their metadata.

  ## Examples

      iex> GtfsPlanner.Authorization.Roles.all()
      %{
        administrator: %{name: "Administrator", ...},
        pathways_studio_admin: %{name: "Pathways Studio Admin", ...},
        ...
      }
  """
  def all, do: @roles

  @doc """
  Validates whether a role is in the canonical set.

  Accepts both atoms and strings.

  ## Examples

      iex> GtfsPlanner.Authorization.Roles.valid?(:administrator)
      true

      iex> GtfsPlanner.Authorization.Roles.valid?("administrator")
      true

      iex> GtfsPlanner.Authorization.Roles.valid?(:nonexistent)
      false
  """
  def valid?(role) when is_atom(role) do
    Map.has_key?(@roles, role)
  end

  def valid?(role) when is_binary(role) do
    try do
      role
      |> String.to_existing_atom()
      |> valid?()
    rescue
      ArgumentError -> false
    end
  end

  @doc """
  Returns metadata for a specific role.

  Accepts both atoms and strings. Returns nil if role doesn't exist.

  ## Examples

      iex> GtfsPlanner.Authorization.Roles.get(:pathways_studio_editor)
      %{name: "Pathways Studio Editor", description: "...", scope: :organization}

      iex> GtfsPlanner.Authorization.Roles.get("administrator")
      %{name: "Administrator", description: "...", scope: :system}
  """
  def get(role) when is_atom(role) do
    Map.get(@roles, role)
  end

  def get(role) when is_binary(role) do
    try do
      role
      |> String.to_existing_atom()
      |> get()
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Lists roles filtered by scope.

  Returns a list of `{role_atom, role_map}` tuples.

  ## Examples

      iex> GtfsPlanner.Authorization.Roles.list_by_scope(:system)
      [{:administrator, %{name: "Administrator", ...}}]

      iex> GtfsPlanner.Authorization.Roles.list_by_scope(:organization)
      [
        {:pathways_studio_admin, %{...}},
        {:pathways_studio_editor, %{...}}
      ]
  """
  def list_by_scope(scope) do
    @roles
    |> Enum.filter(fn {_role_atom, role_map} -> role_map.scope == scope end)
  end
end
