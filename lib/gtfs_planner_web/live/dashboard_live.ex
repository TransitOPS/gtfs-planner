defmodule GtfsPlannerWeb.DashboardLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlannerWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_admin = UserAuth.is_administrator?(user)

    user_roles =
      case user do
        %{roles: roles} when is_list(roles) -> roles
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:is_administrator, is_admin)
     |> assign(:user_roles, user_roles)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <.header>
        Welcome to GTFS Planner
        <:subtitle>You are logged in as {@current_user.email}</:subtitle>
        <:actions>
          <%= if @is_administrator do %>
            <.link navigate={~p"/admin/organizations"} class="btn btn-primary btn-active">
              Manage Organizations
            </.link>
          <% end %>
        </:actions>
      </.header>

      <div class="mt-8 space-y-6">
        <%= if @is_administrator do %>
          <div class="bg-base-100 border border-base-300 rounded-lg p-6">
            <.list>
              <:item title="Role">Administrator</:item>
            </.list>
          </div>
        <% else %>
          <%= if assigns[:current_organization] do %>
            <div class="bg-base-100 border border-base-300 rounded-lg p-6">
              <.list>
                <:item title="Organization">{@current_organization.name}</:item>
              </.list>
            </div>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
