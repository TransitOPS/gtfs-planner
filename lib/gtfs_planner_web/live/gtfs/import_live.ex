defmodule GtfsPlannerWeb.Gtfs.ImportLive do
  @moduledoc """
  LiveView for importing GTFS data.
  Requires the pathways_studio_editor role (editor only, not viewer).
  """
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_editor}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Import GTFS")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Import GTFS
        <:subtitle>GTFS import functionality coming soon.</:subtitle>
      </.header>
    </Layouts.app>
    """
  end
end
