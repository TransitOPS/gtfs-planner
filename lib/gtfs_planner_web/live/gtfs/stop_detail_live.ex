defmodule GtfsPlannerWeb.Gtfs.StopDetailLive do
  @moduledoc """
  LiveView for viewing GTFS station (stop) details.
  Requires to pathways_studio_editor or pathways_studio_viewer role.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    # Check if version resolution is pending (versionless route)
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Station Details")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Station Details")
       |> assign(:user_roles, user_roles)}
    end
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
    {:noreply, assign(socket, :stop_id, stop_id)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    stop_id = socket.assigns[:stop_id]

    # Try to use the stored version_id from localStorage
    version_to_use =
      if version_id && valid_version_for_org?(version_id, current_organization.id) do
        version_id
      else
        # Fall back to latest version
        case socket.assigns[:latest_gtfs_version] do
          {:ok, version} -> to_string(version.id)
          {:error, :no_versions} -> nil
        end
      end

    if version_to_use do
      path = if stop_id, do: "/gtfs/#{version_to_use}/stops/#{stop_id}", else: "/gtfs/#{version_to_use}/stops"
      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "No GTFS versions available for your organization")
       |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    stop_id = socket.assigns[:stop_id]

    # Push event to JS hook to update localStorage
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

    # Navigate to new version
    path = if stop_id, do: "/gtfs/#{version_id}/stops/#{stop_id}", else: "/gtfs/#{version_id}/stops"
    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if assigns[:pending_version_resolution] do %>
      <%!-- Pending version resolution - mount the hook to trigger redirect --%>
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
      >
        <.header>
          Station Details
          <:subtitle>Viewing details for station: {@stop_id}</:subtitle>
          <:actions>
            <%= if assigns[:current_gtfs_version] && assigns[:available_versions] do %>
              <.gtfs_version_switcher
                current_version={@current_gtfs_version}
                versions={@available_versions}
                organization_id={@current_organization.id}
              />
            <% end %>
          </:actions>
        </.header>

        <div class="mt-8">
          <p class="text-gray-500">Station details view coming soon.</p>
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