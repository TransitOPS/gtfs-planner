defmodule GtfsPlannerWeb.Gtfs.RoutesLive do
  @moduledoc """
  LiveView for viewing GTFS routes.
  Requires pathways_studio_editor or pathways_studio_viewer role.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Routes")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id

      routes = Gtfs.list_routes(organization_id, gtfs_version_id)

      {:ok,
       socket
       |> assign(:page_title, "Routes")
       |> assign(:user_roles, user_roles)
       |> assign(:routes_empty?, routes == [])
       |> stream(:routes, routes)}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    if socket.assigns[:pending_version_resolution] do
      current_organization = socket.assigns.current_organization

      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          case Versions.get_latest_gtfs_version(current_organization.id) do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
          end
        end

      if version_to_use do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/routes")}
      else
        {:noreply, socket}
      end
    else
      current_organization = socket.assigns.current_organization
      current_version_id = to_string(socket.assigns.current_gtfs_version.id)

      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          case socket.assigns[:latest_gtfs_version] do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
            nil -> current_version_id
          end
        end

      if version_to_use && version_to_use != current_version_id do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/routes")}
      else
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
    {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/routes")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if assigns[:pending_version_resolution] do %>
      <div
        id="gtfs-version-resolver"
        phx-hook="GtfsVersionHook"
        data-organization-id={@current_organization.id}
      >
        <div class="flex items-center justify-center min-h-screen">
          <div class="text-center">
            <div class="loading loading-spinner loading-lg"></div>
            <p class="mt-4 text-base-content/60">Loading GTFS version...</p>
          </div>
        </div>
      </div>
    <% else %>
      <Layouts.app
        flash={@flash}
        current_user={@current_user}
        current_organization={@current_organization}
        user_roles={@user_roles}
        current_path={@current_path}
        current_gtfs_version={assigns[:current_gtfs_version]}
        available_versions={assigns[:available_versions] || []}
      >
        <.header>
          Routes
          <:subtitle>GTFS routes for the current version</:subtitle>
        </.header>

        <div :if={@routes_empty?} class="text-center py-8 text-base-content/60">
          No routes found
        </div>

        <div
          :if={not @routes_empty?}
          class="mt-8 bg-base-100 border border-base-300 rounded-lg overflow-hidden"
        >
          <.table id="routes" rows={@streams.routes}>
            <:col :let={{_id, route}} label="Route ID">
              <.link
                navigate={"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
                class="link link-primary"
              >
                {route.route_id}
              </.link>
            </:col>
            <:col :let={{_id, route}} label="Short Name">{route.route_short_name || "—"}</:col>
            <:col :let={{_id, route}} label="Long Name">{route.route_long_name || "—"}</:col>
            <:col :let={{_id, route}} label="Type">{Route.route_type_label(route.route_type)}</:col>
          </.table>
        </div>
      </Layouts.app>
    <% end %>
    """
  end

  defp get_user_roles(socket) do
    user = socket.assigns[:current_user]
    organization = socket.assigns[:current_organization]

    case GtfsPlanner.Accounts.get_user_org_membership(user.id, organization.id) do
      %UserOrgMembership{roles: roles} when is_list(roles) -> roles
      _ -> []
    end
  end

  defp valid_version_for_org?(version_id, organization_id) do
    try do
      case Versions.get_gtfs_version(version_id) do
        nil -> false
        version -> version.organization_id == organization_id
      end
    rescue
      _ -> false
    end
  end
end