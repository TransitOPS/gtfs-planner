defmodule GtfsPlannerWeb.Gtfs.ComingSoonLive do
  @moduledoc """
  Read-only placeholder pages for GTFS destinations that are navigable before they are built.

  One LiveView serves the one fixed action still a placeholder in the
  architecture's route table: Rosters (`/rosters`). It mounts through the
  ordinary `:gtfs_routes` session, so the shared user, organization and
  published-version hooks decide whether a request reaches it; the editor guard
  is declared here because a session alone grants no GTFS access.

  The feature body comes from `GtfsPlannerWeb.ComingSoon`. This LiveView supplies
  only what a page owns: the area sub-navigation, the `This version: <name>` scope
  label and the heading level.

  Evolutions (`/stops/:stop_id/evolutions`) is no longer one of these actions:
  `GtfsPlannerWeb.Gtfs.PathwayEvolutionsLive` serves that route with the real
  closure list, and its station scope, version switching and missing-station
  response live there. Nothing else moved.

  Version switching keeps the current action and accepts only a published version
  of the current organization. A foreign, staging or absent version leaves both
  the socket and the client's selection untouched.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.ComingSoon, only: [coming_soon: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ComingSoon
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    feature = ComingSoon.feature(socket.assigns.live_action)

    {:ok, assign(socket, :page_title, feature.title)}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id}, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: ~p"/gtfs/#{gtfs_version_id}/stops")}

      station ->
        {:noreply, assign(socket, station: station, stop_id: stop_id)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: version_target(socket, version_id))}
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
      {:noreply, push_navigate(socket, to: version_target(socket, version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:feature, ComingSoon.feature(assigns.live_action))
      |> assign(:area, area(assigns.live_action))

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
      <:sub_header :if={@area == :routes}>
        <.routes_tabs gtfs_version_id={@current_gtfs_version.id} active_tab={@live_action} />
      </:sub_header>

      <:sub_header :if={@area == :operations}>
        <.operations_sub_nav
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@live_action}
        />
      </:sub_header>

      <.coming_soon
        feature={@feature}
        scope_label={"This version: #{@current_gtfs_version.name}"}
        heading_level={heading_level(@live_action)}
      />
    </Layouts.app>
    """
  end

  # The area bar a fixed action belongs to. Flex has none: the sitemap places it
  # as a single destination, not a group with siblings.
  defp area(action) when action in [:rosters], do: :operations
  defp area(_action), do: nil

  # Every remaining placeholder is a standalone page and owns its own heading.
  defp heading_level(_action), do: 1

  defp version_target(socket, version_id) do
    case socket.assigns.live_action do
      :rosters -> ~p"/gtfs/#{version_id}/rosters"
    end
  end
end
