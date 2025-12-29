defmodule GtfsPlannerWeb.Admin.UsersLive do
  @moduledoc """
  LiveView for managing users within an organization.
  Requires the pathways_studio_admin role.
  """
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.EnsureRole, :require_pathways_studio_admin}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Manage Users")
      |> assign_new(:user_roles, fn ->
        case socket.assigns do
          %{current_user: %{roles: roles}} -> roles
          _ -> []
        end
      end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Manage Users
        <:subtitle>User management coming soon.</:subtitle>
      </.header>
    </Layouts.app>
    """
  end
end
