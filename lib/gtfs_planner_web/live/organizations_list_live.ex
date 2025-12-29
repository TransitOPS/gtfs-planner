defmodule GtfsPlannerWeb.OrganizationsListLive do
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.EnsureRole, :require}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Organizations")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Organizations
        <:subtitle>Manage your organizations and their members.</:subtitle>
      </.header>
      <p>Organization list will be implemented here.</p>
    </Layouts.app>
    """
  end
end
