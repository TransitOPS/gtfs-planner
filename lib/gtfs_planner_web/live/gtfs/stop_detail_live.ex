defmodule GtfsPlannerWeb.Gtfs.StopDetailLive do
  @moduledoc """
  LiveView for viewing GTFS station (stop) details.
  Requires the pathways_studio_editor or pathways_studio_viewer role.
  """
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Station Details")}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
    {:noreply, assign(socket, :stop_id, stop_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Station Details
        <:subtitle>Viewing details for station: {@stop_id}</:subtitle>
      </.header>

      <div class="mt-8">
        <p class="text-gray-500">Station details view coming soon.</p>
      </div>
    </Layouts.app>
    """
  end
end
