defmodule GtfsPlannerWeb.Gtfs.ComingSoonLive do
  @moduledoc """
  Read-only placeholder pages for GTFS destinations that are navigable before they are built.

  One LiveView serves the five fixed actions in the architecture's route table:
  Blocks/Runs/Rosters (`/blocks`, `/runs`, `/rosters`), Flex (`/flex`) and
  Evolutions (`/stops/:stop_id/evolutions`). Each mounts through
  the ordinary `:gtfs_routes` session, so the shared user, organization and
  published-version hooks decide whether a request reaches it; the editor guard is
  declared here because a session alone grants no GTFS access.

  The feature body comes from `GtfsPlannerWeb.ComingSoon`. This LiveView supplies
  only what a page owns: the area sub-navigation, the `This version: <name>` scope
  label, the heading level, and — for Evolutions — the scoped station the station
  sub-navigation needs.

  Evolutions follows `StationReachabilityLive`: `Gtfs.get_stop_by_stop_id/3` scopes
  the lookup to the selected organization and version, and any stop outside that
  scope is "not found", which flashes and returns to that version's stops list. No
  reachability run or closure record is read or written.

  Version switching keeps the current action — and the station on Evolutions — and
  accepts only a published version of the current organization. A foreign, staging
  or absent version leaves both the socket and the client's selection untouched.
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

    {:ok,
     socket
     |> assign(:page_title, feature.title)
     |> assign(:station, nil)
     |> assign(:stop_id, nil)}
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

      <:sub_header :if={@area == :station and @station}>
        <.station_sub_nav
          station={@station}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:evolutions}
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
  defp area(action) when action in [:blocks, :runs, :rosters], do: :operations
  defp area(:evolutions), do: :station
  defp area(_action), do: nil

  # Standalone placeholders own the page heading; Evolutions sits under the
  # station heading the sub-navigation renders.
  defp heading_level(:evolutions), do: 2
  defp heading_level(_action), do: 1

  defp version_target(socket, version_id) do
    case socket.assigns.live_action do
      :blocks -> ~p"/gtfs/#{version_id}/blocks"
      :runs -> ~p"/gtfs/#{version_id}/runs"
      :rosters -> ~p"/gtfs/#{version_id}/rosters"
      :flex -> ~p"/gtfs/#{version_id}/flex"
      :evolutions -> evolutions_target(socket.assigns[:stop_id], version_id)
    end
  end

  # A station that the current version does not hold never reaches here with an
  # ID; that mount redirects to the stops list instead of building a dead link.
  defp evolutions_target(stop_id, version_id) when is_binary(stop_id) do
    ~p"/gtfs/#{version_id}/stops/#{stop_id}/evolutions"
  end

  defp evolutions_target(_stop_id, version_id), do: ~p"/gtfs/#{version_id}/stops"
end
