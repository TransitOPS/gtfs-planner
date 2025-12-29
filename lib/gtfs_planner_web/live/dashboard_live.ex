defmodule GtfsPlannerWeb.DashboardLive do
  use GtfsPlannerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_admin = is_administrator?(user)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:is_administrator, is_admin)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title">Welcome to GTFS Planner</h2>
          <p>You are logged in as {@current_user.email}</p>

          <%= if @is_administrator do %>
            <div class="mt-4">
              <p class="text-sm text-gray-600">You are an administrator.</p>
            </div>
            <div class="card-actions justify-end">
              <.link navigate={~p"/admin/organizations"} class="btn btn-primary">
                Manage Organizations
              </.link>
            </div>
          <% else %>
            <%= if assigns[:current_organization] do %>
              <div class="mt-4">
                <p class="text-sm text-gray-600">
                  Organization: <span class="font-medium">{@current_organization.name}</span>
                </p>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
