defmodule GtfsPlannerWeb.DashboardLive do
  use GtfsPlannerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title">Welcome to GTFS Planner</h2>
          <p>You are logged in as {@current_user.email}</p>
          <div class="card-actions justify-end">
            <.link navigate={~p"/organizations"} class="btn btn-primary">
              View Organizations
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
