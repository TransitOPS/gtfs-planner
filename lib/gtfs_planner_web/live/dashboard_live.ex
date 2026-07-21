defmodule GtfsPlannerWeb.DashboardLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlannerWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:is_administrator, UserAuth.is_administrator?(user))}
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
      current_gtfs_version={@current_gtfs_version}
      available_versions={@available_versions}
    >
      {render_dashboard_state(dashboard_state(assigns), assigns)}
    </Layouts.app>
    """
  end

  defp dashboard_state(%{organization_context_status: :system_administrator}),
    do: :system_administrator

  defp dashboard_state(%{organization_context_status: :missing}), do: :missing

  defp dashboard_state(%{organization_context_status: :unavailable}), do: :unavailable

  defp dashboard_state(%{
         organization_context_status: :available,
         current_organization: %{},
         current_gtfs_version: nil
       }),
       do: :no_version

  defp dashboard_state(%{
         organization_context_status: :available,
         current_organization: %{},
         current_gtfs_version: %{},
         user_roles: roles
       }) do
    editor? = "pathways_studio_editor" in roles
    org_admin? = "pathways_studio_admin" in roles

    if editor? or org_admin?, do: :organization, else: :no_task
  end

  defp dashboard_state(%{organization_context_status: :available, current_organization: %{}}),
    do: :no_task

  defp render_dashboard_state(:system_administrator, assigns) do
    ~H"""
    <div id="dashboard-system-administrator">
      <.header>
        System administration
        <:subtitle>Signed in as {@current_user.email}</:subtitle>
        <:actions>
          <.button navigate={~p"/admin/organizations"} variant="primary" class="min-h-11">
            Manage organizations
          </.button>
        </:actions>
      </.header>
    </div>
    """
  end

  defp render_dashboard_state(:missing, assigns) do
    ~H"""
    <div id="dashboard-no-organization">
      <.header>
        Dashboard
      </.header>

      <div class="mt-6">
        <.callout kind="info" title="Organization access required">
          Organization access is required to use Pathways Studio. Contact an administrator if you need access.
        </.callout>
      </div>
    </div>
    """
  end

  defp render_dashboard_state(:unavailable, assigns) do
    ~H"""
    <div id="dashboard-organization-unavailable">
      <.header>
        Dashboard
      </.header>

      <div class="mt-6">
        <.callout kind="info" title="Organization access required">
          Organization access is required to use Pathways Studio. Contact an administrator if you need access.
        </.callout>
      </div>
    </div>
    """
  end

  defp render_dashboard_state(:no_version, assigns) do
    ~H"""
    <div id="dashboard-no-version">
      <.header>
        {@current_organization.name}
      </.header>

      <div class="mt-6">
        <.callout kind="warning" title="No published GTFS version">
          An organization administrator must publish or import a GTFS version before product routes are available.
        </.callout>
      </div>
    </div>
    """
  end

  defp render_dashboard_state(:organization, assigns) do
    roles = assigns.user_roles
    editor? = "pathways_studio_editor" in roles
    org_admin? = "pathways_studio_admin" in roles

    assigns =
      assigns
      |> assign(:editor?, editor?)
      |> assign(:org_admin?, org_admin?)

    ~H"""
    <div id="dashboard-organization">
      <.header>
        {@current_organization.name}
        <:subtitle>
          <%= cond do %>
            <% @editor? and @org_admin? -> %>
              Editor and organization administrator tasks
            <% @editor? -> %>
              Editor tasks
            <% true -> %>
              Organization administrator tasks
          <% end %>
        </:subtitle>
        <:actions>
          <%= if @editor? do %>
            <.button
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/routes"}
              variant="primary"
              class="min-h-11"
            >
              View routes
            </.button>
          <% end %>
          <%= if @org_admin? do %>
            <.button
              navigate={~p"/admin/users"}
              variant={if(@editor?, do: "secondary", else: "primary")}
              class="min-h-11"
            >
              Manage users
            </.button>
          <% end %>
        </:actions>
      </.header>
    </div>
    """
  end

  defp render_dashboard_state(:no_task, assigns) do
    ~H"""
    <div id="dashboard-no-task-access">
      <.header>
        {@current_organization.name}
      </.header>

      <div class="mt-6">
        <.callout kind="info" title="No task access">
          An organization administrator controls access to Pathways Studio tasks for this organization.
        </.callout>
      </div>
    </div>
    """
  end
end
