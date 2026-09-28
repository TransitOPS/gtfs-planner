defmodule GtfsPlannerWeb.Gtfs.BlocksLive do
  @moduledoc """
  LiveView for Operations › Blocks.

  Blocks shows which trips one vehicle works in sequence for a day type, and it
  is the only place a block is edited. This step owns the page shell: the
  heading, the Operations sub-navigation and the page's own container. The
  day-type scope, the timeline, the checks and the page states arrive in later
  steps.

  The page mounts through the ordinary `:gtfs_routes` session, which decides
  whether a request reaches it; the editor guard is declared here because a
  session alone grants no GTFS access. Mount carries no page state and never
  patches the URL, so a link to `/blocks` always lands on the page itself.
  Version switching keeps the page on the new version and accepts only a
  published version of the current organization.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Blocks")}
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/blocks")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/blocks")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <:sub_header>
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:blocks} />
      </:sub_header>

      <div id="blocks-page">
        <section class="min-h-screen bg-base-100">
          <div class="mx-auto w-full max-w-7xl">
            <.header>
              Blocks
              <:subtitle>A block is one vehicle's sequence of trips.</:subtitle>
            </.header>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
