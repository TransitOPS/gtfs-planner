defmodule GtfsPlannerWeb.Gtfs.StopsLive do
  @moduledoc """
  LiveView for managing GTFS stations (stops).
  Requires the pathways_studio_editor or pathways_studio_viewer role.
  """
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = get_user_roles(socket)

    {:ok,
     socket
     |> assign(:page_title, "Stations")
     |> assign(:user_roles, user_roles)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_organization={@current_organization} user_roles={@user_roles}>
      <.header>
        Stations
        <:subtitle>GTFS station management coming soon.</:subtitle>
      </.header>
    </Layouts.app>
    """
  end
end
