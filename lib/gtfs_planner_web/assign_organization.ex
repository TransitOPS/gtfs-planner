defmodule GtfsPlannerWeb.AssignOrganization do
  @moduledoc """
  LiveView mount hook to assign organization from session.

  This hook extracts the `organization_id` from the user's session,
  fetches the corresponding organization, and assigns it to the
  LiveView socket as `:current_organization`. It also fetches the
  user's roles for that organization and assigns them as `:user_roles`.
  For organization-scoped users, it also assigns GTFS version context
  via `:available_versions` and `:current_gtfs_version`.

  Required mode (`:default`) redirects to login when organization context
  is missing or invalid. Optional mode (`:optional`) always continues with
  an explicit `organization_context_status` and safe nil/empty defaults when
  tenant context is unavailable.

  Administrators (system-scoped users) bypass the organization requirement.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2, attach_hook: 4]
  import Phoenix.Component, only: [assign: 3]
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.UserAuth

  @type account_context_status ::
          :system_administrator | :available | :missing | :unavailable

  @deactivated_flash "Your account has been deactivated in this organization."

  @doc """
  LiveView mount hook to assign organization from session.

  ## Parameters
    - :default: Required organization context (existing admin/GTFS routes)
    - :optional: Account routes that tolerate missing/stale context
    - _params: The route parameters (unused)
    - session: The session containing the organization_id
    - socket: The LiveView socket

  ## Returns
    - `{:cont, socket}` with organization/version assigns when authorized
    - `{:cont, socket}` without organization if user is administrator (required)
    - `{:cont, socket}` with complete safe shape and status (optional)
    - `{:halt, socket}` with flash error and redirect on required failures
      or deactivated membership
  """
  @spec on_mount(:default | :optional, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    current_user = socket.assigns[:current_user]

    # Administrator bypass - administrators don't need organization context
    if current_user && UserAuth.is_administrator?(current_user) do
      {:cont, socket}
    else
      assign_organization_required(session, socket)
    end
  end

  def on_mount(:optional, _params, session, socket) do
    current_user = socket.assigns[:current_user]

    cond do
      current_user && UserAuth.is_administrator?(current_user) ->
        {:cont, assign_safe_defaults(socket, :system_administrator)}

      true ->
        assign_organization_optional(session, socket)
    end
  end

  defp assign_organization_required(%{"organization_id" => organization_id}, socket) do
    case Organizations.get_organization(organization_id) do
      %Organizations.Organization{} = organization ->
        current_user = socket.assigns[:current_user]

        # Check if user is deactivated in this organization
        if current_user &&
             Organizations.user_deactivated_in_organization?(current_user.id, organization_id) do
          halt_deactivated(socket)
        else
          # Fetch user's roles for this organization
          user_roles =
            case Accounts.get_user_org_membership(current_user.id, organization_id) do
              %Accounts.UserOrgMembership{roles: roles} -> roles
              nil -> []
            end

          {:cont, assign_tenant_context(socket, organization, user_roles)}
        end

      nil ->
        socket =
          socket
          |> put_flash(:error, "Organization not found")
          |> redirect(to: "/users/log_in")

        {:halt, socket}
    end
  end

  defp assign_organization_required(_session, socket) do
    socket =
      socket
      |> put_flash(:error, "Your account has no organization assigned. Contact an administrator.")
      |> redirect(to: "/users/log_in")

    {:halt, socket}
  end

  defp assign_organization_optional(%{"organization_id" => organization_id}, socket) do
    current_user = socket.assigns[:current_user]

    case Organizations.get_organization(organization_id) do
      %Organizations.Organization{} = organization when not is_nil(current_user) ->
        case Accounts.get_user_org_membership(current_user.id, organization_id) do
          %Accounts.UserOrgMembership{deactivated_at: nil, roles: roles} ->
            socket =
              socket
              |> assign_tenant_context(organization, roles)
              |> assign(:organization_context_status, :available)

            {:cont, socket}

          %Accounts.UserOrgMembership{deactivated_at: deactivated_at}
          when not is_nil(deactivated_at) ->
            halt_deactivated(socket)

          nil ->
            {:cont, assign_safe_defaults(socket, :unavailable)}
        end

      _ ->
        {:cont, assign_safe_defaults(socket, :unavailable)}
    end
  end

  defp assign_organization_optional(_session, socket) do
    {:cont, assign_safe_defaults(socket, :missing)}
  end

  defp halt_deactivated(socket) do
    # Delete session token to force re-authentication
    if user_token = socket.private[:connect_params]["user_token"] do
      Accounts.delete_session_token(user_token)
    end

    socket =
      socket
      |> put_flash(:error, @deactivated_flash)
      |> redirect(to: "/users/log_in")

    {:halt, socket}
  end

  defp assign_tenant_context(socket, organization, user_roles) do
    available_versions = Versions.list_gtfs_versions_for_dropdown(organization.id)

    current_gtfs_version =
      case Versions.get_latest_gtfs_version(organization.id) do
        {:ok, version} -> version
        {:error, :no_versions} -> nil
      end

    socket
    |> assign(:current_organization, organization)
    |> assign(:user_roles, user_roles)
    |> assign(:available_versions, available_versions)
    |> assign(:current_gtfs_version, current_gtfs_version)
    |> attach_hook(
      :refresh_gtfs_versions_after_rename,
      :handle_info,
      &refresh_after_rename/2
    )
  end

  defp assign_safe_defaults(socket, status) do
    socket
    |> assign(:organization_context_status, status)
    |> assign(:current_organization, nil)
    |> assign(:user_roles, [])
    |> assign(:available_versions, [])
    |> assign(:current_gtfs_version, nil)
  end

  defp refresh_after_rename({:gtfs_version_renamed, %{id: renamed_id} = updated}, socket) do
    case socket.assigns[:current_organization] do
      %{id: org_id} ->
        versions = Versions.list_gtfs_versions_for_dropdown(org_id)

        socket =
          socket
          |> assign(:available_versions, versions)
          |> maybe_replace_current_gtfs_version(renamed_id, updated)

        {:halt, socket}

      _ ->
        {:cont, socket}
    end
  end

  defp refresh_after_rename(_msg, socket), do: {:cont, socket}

  defp maybe_replace_current_gtfs_version(socket, renamed_id, updated) do
    case socket.assigns[:current_gtfs_version] do
      %{id: ^renamed_id} -> assign(socket, :current_gtfs_version, updated)
      _ -> socket
    end
  end
end
