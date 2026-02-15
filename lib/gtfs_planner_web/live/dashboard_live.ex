defmodule GtfsPlannerWeb.DashboardLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.UserAuth

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]
    is_admin = UserAuth.is_administrator?(user)

    # Fetch user's organization and roles from their membership
    {current_organization, user_roles} = get_user_org_context(user, session, is_admin)
    {current_gtfs_version, available_versions} = get_gtfs_version_context(current_organization)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:is_administrator, is_admin)
     |> assign(:current_organization, current_organization)
     |> assign(:user_roles, user_roles)
     |> assign(:current_gtfs_version, current_gtfs_version)
     |> assign(:available_versions, available_versions)}
  end

  defp get_user_org_context(_user, _session, true = _is_admin) do
    # Administrators don't have org-scoped roles
    {nil, []}
  end

  defp get_user_org_context(user, session, false = _is_admin) do
    organization_id = session["organization_id"]

    if organization_id do
      organization = Organizations.get_organization(organization_id)

      user_roles =
        case Accounts.get_user_org_membership(user.id, organization_id) do
          %Accounts.UserOrgMembership{roles: roles} -> roles
          nil -> []
        end

      {organization, user_roles}
    else
      {nil, []}
    end
  end

  defp get_gtfs_version_context(nil), do: {nil, []}

  defp get_gtfs_version_context(current_organization) do
    available_versions = Versions.list_gtfs_versions_for_dropdown(current_organization.id)

    current_gtfs_version =
      case Versions.get_latest_gtfs_version(current_organization.id) do
        {:ok, version} -> version
        {:error, :no_versions} -> nil
      end

    {current_gtfs_version, available_versions}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={@user_roles}
      current_organization={@current_organization}
    >
      <.header>
        Welcome to GTFS Planner
        <:subtitle>You are logged in as {@current_user.email}</:subtitle>
        <:actions>
          <%= if @is_administrator do %>
            <.link navigate={~p"/admin/organizations"} class="btn btn-primary btn-active">
              Manage Organizations
            </.link>
          <% end %>
        </:actions>
      </.header>

      <div class="mt-8 space-y-6">
        <%= if @is_administrator do %>
          <div class="bg-base-100 border border-base-300 rounded-lg p-6">
            <.list>
              <:item title="Role">Administrator</:item>
            </.list>
          </div>
        <% else %>
          <%= if assigns[:current_organization] do %>
            <div class="bg-base-100 border border-base-300 rounded-lg p-6">
              <.list>
                <:item title="Organization">{@current_organization.name}</:item>
              </.list>
            </div>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
