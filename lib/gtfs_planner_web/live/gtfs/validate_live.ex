defmodule GtfsPlannerWeb.Gtfs.ValidateLive do
  @moduledoc """
  LiveView for validating GTFS data.
  Accessible by both pathways_studio_editor and pathways_studio_viewer roles.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = get_user_roles(socket)

    {:ok,
     socket
     |> assign(:page_title, "Validate GTFS")
     |> assign(:user_roles, user_roles)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      user_roles={@user_roles}
      current_path={@current_path}
    >
      <div class="container mx-auto px-4 py-8">
        <h1 class="text-3xl font-bold mb-4">Validate GTFS</h1>
        <p class="text-gray-600">GTFS validation functionality coming soon.</p>
      </div>
    </Layouts.app>
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
end
