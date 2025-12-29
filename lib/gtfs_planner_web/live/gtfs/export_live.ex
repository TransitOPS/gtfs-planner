defmodule GtfsPlannerWeb.Gtfs.ExportLive do
  @moduledoc """
  LiveView for exporting GTFS data.
  Accessible by both pathways_studio_editor and pathways_studio_viewer roles.
  """
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Export GTFS")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="container mx-auto px-4 py-8">
        <h1 class="text-3xl font-bold mb-4">Export GTFS</h1>
        <p class="text-gray-600">GTFS export functionality coming soon.</p>
      </div>
    </Layouts.app>
    """
  end
end
