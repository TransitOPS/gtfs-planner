defmodule GtfsPlannerWeb.AssignOrganization do
  @moduledoc """
  LiveView mount hook to assign organization from session.

  This hook extracts the `organization_id` from the user's session,
  fetches the corresponding organization, and assigns it to the
  LiveView socket as `:current_organization`. It also fetches the
  user's roles for that organization and assigns them as `:user_roles`.
  For organization-scoped users, it also assigns GTFS version context
  via `:available_versions` and `:current_gtfs_version`.
  If no organization is in the session or the organization is not found,
  it redirects to the login page with an error.

  Administrators (system-scoped users) bypass the organization requirement.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2, attach_hook: 4]
  import Phoenix.Component, only: [assign: 3]
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.UserAuth

  @doc """
  LiveView mount hook to assign organization from session.

  ## Parameters
    - :default: The hook name
    - _params: The route parameters (unused)
    - session: The session containing the organization_id
    - socket: The LiveView socket

  ## Returns
    - `{:cont, socket}` with `:current_organization`, `:user_roles`,
      `:available_versions`, and `:current_gtfs_version` assigned if found
    - `{:cont, socket}` without organization if user is administrator
    - `{:halt, socket}` with flash error and redirect if organization not in session or not found
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    current_user = socket.assigns[:current_user]

    # Administrator bypass - administrators don't need organization context
    if current_user && UserAuth.is_administrator?(current_user) do
      {:cont, socket}
    else
      assign_organization_from_session(session, socket)
    end
  end

  defp assign_organization_from_session(%{"organization_id" => organization_id}, socket) do
    case Organizations.get_organization(organization_id) do
      %Organizations.Organization{} = organization ->
        current_user = socket.assigns[:current_user]

        # Check if user is deactivated in this organization
        if current_user &&
             Organizations.user_deactivated_in_organization?(current_user.id, organization_id) do
          # Delete session token to force re-authentication
          if user_token = socket.private[:connect_params]["user_token"] do
            GtfsPlanner.Accounts.delete_session_token(user_token)
          end

          socket =
            socket
            |> put_flash(:error, "Your account has been deactivated in this organization.")
            |> redirect(to: "/users/log_in")

          {:halt, socket}
        else
          # Fetch user's roles for this organization
          user_roles =
            case Accounts.get_user_org_membership(current_user.id, organization_id) do
              %Accounts.UserOrgMembership{roles: roles} -> roles
              nil -> []
            end

          available_versions = Versions.list_gtfs_versions_for_dropdown(organization_id)

          current_gtfs_version =
            case Versions.get_latest_gtfs_version(organization_id) do
              {:ok, version} -> version
              {:error, :no_versions} -> nil
            end

          {:cont,
           socket
           |> assign(:current_organization, organization)
           |> assign(:user_roles, user_roles)
           |> assign(:available_versions, available_versions)
           |> assign(:current_gtfs_version, current_gtfs_version)
           |> attach_hook(
             :refresh_gtfs_versions_after_rename,
             :handle_info,
             &refresh_after_rename/2
           )}
        end

      nil ->
        socket =
          socket
          |> put_flash(:error, "Organization not found")
          |> redirect(to: "/users/log_in")

        {:halt, socket}
    end
  end

  defp assign_organization_from_session(_session, socket) do
    socket =
      socket
      |> put_flash(:error, "Your account has no organization assigned. Contact an administrator.")
      |> redirect(to: "/users/log_in")

    {:halt, socket}
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
