defmodule GtfsPlannerWeb.EnsureRole do
  @moduledoc """
  Role-based authorization for users and API keys.

  This module provides functions to enforce role-based access control in
  both LiveViews (via on_mount hooks) and Plug pipelines (via ensure_role/2).

  ## Role Specifications

  - Single role: `:administrator`
  - Any membership: `nil` (requires org membership but no specific role)
  - Any role in list: `any: [:role1, :role2]`
  - All roles in list: `all: [:role1, :role2]`

  ## Usage in LiveViews

  To require specific roles in a LiveView, add this module as an on_mount hook:

      defmodule MyApp.SomeLive do
        use GtfsPlannerWeb, :live_view

        on_mount {GtfsPlannerWeb.EnsureRole, :require_admin}

        # ...
      end

  ## Usage in Router

  To require roles for API endpoints:

      pipeline :require_admin do
        plug :ensure_role, :administrator
      end

  Or for multiple roles:

      pipeline :require_any_admin_or_manager do
        plug :ensure_role, any: [:administrator, :manager]
      end
  """

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations

  @doc """
  LiveView mount hook for role-based authorization.

  ## Options

  - `:require` - The role specification to enforce (required)
    - Single role: `:administrator`
    - Any membership: `nil`
    - Any role in list: `any: [:role1, :role2]`
    - All roles in list: `all: [:role1, :role2]`

  ## Examples

      on_mount {GtfsPlannerWeb.EnsureRole, require: :administrator}
      on_mount {GtfsPlannerWeb.EnsureRole, require: any: [:admin, :manager]}
      on_mount {GtfsPlannerWeb.EnsureRole, require: nil} # just requires membership
  """
  def on_mount(:default, params, session, socket) do
    on_mount({__MODULE__, :require}, params, session, socket)
  end

  def on_mount(:require_administrator, params, session, socket) do
    socket = Phoenix.Component.assign(socket, :role_spec, :administrator)
    on_mount(:require, params, session, socket)
  end

  def on_mount(:require_pathways_studio_admin, params, session, socket) do
    socket = Phoenix.Component.assign(socket, :role_spec, :pathways_studio_admin)
    on_mount(:require, params, session, socket)
  end

  def on_mount(:require_gtfs_access, params, session, socket) do
    socket = Phoenix.Component.assign(socket, :role_spec, any: [:pathways_studio_editor, :pathways_studio_viewer])
    on_mount(:require, params, session, socket)
  end

  def on_mount(:require_gtfs_editor, params, session, socket) do
    socket = Phoenix.Component.assign(socket, :role_spec, :pathways_studio_editor)
    on_mount(:require, params, session, socket)
  end

  def on_mount(:require, _params, _session, socket) do
    role_spec = socket.assigns[:role_spec] || :administrator

    # Ensure we have current_user and current_organization
    user_id =
      case socket.assigns[:current_user] do
        nil -> nil
        user -> user.id
      end

    organization_id =
      case socket.assigns[:current_organization] do
        nil -> nil
        org -> org.id
      end

    with {:ok, _user} when not is_nil(user_id) <- {:ok, user_id},
         {:ok, _org} when not is_nil(organization_id) <- {:ok, organization_id},
         {:ok, membership} <-
           Accounts.get_user_org_membership(user_id, organization_id),
         true <- has_role?(membership.roles, role_spec) do
      {:cont, socket}
    else
      _ ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You do not have permission to access this page.")
          |> Phoenix.LiveView.redirect(to: "/organizations")

        {:halt, socket}
    end
  end

  @doc """
  Plug function for role-based authorization.

  Requires that the authenticated user or API key has the specified role(s)
  in the current organization.

  ## Parameters

  - `conn` - The Plug connection
  - `role_spec` - The role specification to enforce

  ## Role Specifications

  - Single role: `:administrator`
  - Any membership: `nil` (requires org membership but no specific role)
  - Any role in list: `any: [:role1, :role2]`
  - All roles in list: `all: [:role1, :role2]`

  ## Examples

      plug :ensure_role, :administrator
      plug :ensure_role, any: [:administrator, :manager]
      plug :ensure_role, nil # requires org membership only

  """
  def ensure_role(conn, role_spec) do
    # Get user or API key from conn
    user_id =
      case conn.assigns[:current_user] do
        nil -> nil
        user -> user.id
      end

    api_key_id =
      case conn.assigns[:current_api_key] do
        nil -> nil
        api_key -> api_key.id
      end

    organization_id =
      case conn.assigns[:current_organization] do
        nil -> nil
        org -> org.id
      end

    cond do
      is_nil(organization_id) ->
        unauthorized(conn)

      # Check user roles
      not is_nil(user_id) ->
        case Accounts.get_user_org_membership(user_id, organization_id) do
          {:ok, membership} ->
            if has_role?(membership.roles, role_spec) do
              conn
            else
              unauthorized(conn)
            end

          {:error, _} ->
            unauthorized(conn)
        end

      # Check API key roles
      not is_nil(api_key_id) ->
        case Organizations.get_api_key!(api_key_id) do
          api_key when not is_nil(api_key) ->
            if has_role?(api_key.roles, role_spec) do
              conn
            else
              unauthorized(conn)
            end

          _ ->
            unauthorized(conn)
        end

      # No user or API key
      true ->
        unauthorized(conn)
    end
  end

  @doc """
  Helper function to check if a set of roles matches a role specification.

  ## Parameters

  - `roles` - List of role strings (e.g., ["administrator", "manager"])
  - `spec` - Role specification to match against

  ## Examples

      iex> has_role?(["administrator"], :administrator)
      true

      iex> has_role?(["manager", "editor"], any: [:administrator, :manager])
      true

      iex> has_role?(["administrator", "manager"], all: [:administrator, :manager])
      true

      iex> has_role?(["administrator"], all: [:administrator, :manager])
      false
  """
  def has_role?(roles, spec) do
    roles_match_spec(roles, spec)
  end

  # Private helper functions

  defp roles_match_spec(nil, _), do: false

  defp roles_match_spec(roles, nil) when is_list(roles), do: true
  defp roles_match_spec(roles, role) when is_atom(role), do: role in roles

  defp roles_match_spec(roles, any: spec) when is_list(spec) do
    Enum.any?(spec, &roles_match_spec(roles, &1))
  end

  defp roles_match_spec(roles, all: spec) when is_list(spec) do
    Enum.all?(spec, &roles_match_spec(roles, &1))
  end

  defp unauthorized(conn) do
    conn
    |> Plug.Conn.put_status(:forbidden)
    |> Phoenix.Controller.json(%{error: "You do not have permission to access this resource."})
    |> Plug.Conn.halt()
  end
end
