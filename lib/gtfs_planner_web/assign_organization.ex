defmodule GtfsPlannerWeb.AssignOrganization do
  @moduledoc """
  LiveView mount hook to assign organization from session.

  This hook extracts the `organization_id` from the user's session,
  fetches the corresponding organization, and assigns it to the
  LiveView socket as `:current_organization`. If no organization
  is in the session or the organization is not found, it redirects
  to the login page with an error.

  Administrators (system-scoped users) bypass the organization requirement.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]
  import Phoenix.Component, only: [assign: 3]
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.UserAuth

  @doc """
  LiveView mount hook to assign organization from session.

  ## Parameters
    - :default: The hook name
    - _params: The route parameters (unused)
    - session: The session containing the organization_id
    - socket: The LiveView socket

  ## Returns
    - `{:cont, socket}` with `:current_organization` assigned if found
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
        {:cont, assign(socket, :current_organization, organization)}

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
end
