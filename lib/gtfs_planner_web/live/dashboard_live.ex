defmodule GtfsPlannerWeb.DashboardLive do
  @moduledoc """
  The logged-in homepage at `/`.

  The page picks exactly one state from the organization context the
  `AssignOrganization` hook assigns on mount: the system administrator, no
  organization, organization unavailable, no published version, no task
  access, organization administrator without an editing role, or a working
  page for an editor — the GTFS Planner's Next step or Pathways Studio's
  station board, by the organization's product.

  Every state renders inside `SharedComponents.home_page/1` and carries its own
  root id, so the state is testable and the page has exactly one `h1`. The
  access states' small reads (organization count, administrator emails, member
  count) happen synchronously in `mount` through `home_source/0`; the working
  pages load their regions in the steps that fill them. This module obtains
  data only through `home_source/0` and `ProductSurfaces`, and owns no message
  callback of its own — the version-rename hook owns the only one (INV-4).
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Home.AccessComponents
  import GtfsPlannerWeb.Home.SharedComponents, only: [home_head: 1, home_page: 1]

  alias GtfsPlannerWeb.ProductSurfaces

  @editor_role "pathways_studio_editor"
  @admin_role "pathways_studio_admin"

  @impl true
  def mount(_params, _session, socket) do
    state = dashboard_state(socket.assigns)

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:dashboard_state, state)
     |> load_state_data(state)}
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
      <.home_page>
        {render_dashboard_state(@dashboard_state, assigns)}
      </.home_page>
    </Layouts.app>
    """
  end

  defp dashboard_state(%{organization_context_status: :system_administrator}),
    do: :system_administrator

  defp dashboard_state(%{organization_context_status: :missing}), do: :missing

  defp dashboard_state(%{organization_context_status: :unavailable}), do: :unavailable

  defp dashboard_state(%{organization_context_status: :available, current_gtfs_version: nil}),
    do: :no_version

  defp dashboard_state(
         %{
           organization_context_status: :available,
           current_organization: %{},
           current_gtfs_version: %{},
           user_roles: roles
         } = assigns
       ) do
    cond do
      @editor_role in roles -> working_state(assigns.current_organization)
      @admin_role in roles -> :admin_only
      true -> :no_task
    end
  end

  defp working_state(organization) do
    case ProductSurfaces.brand(organization) do
      :planner -> :planner
      :pathways -> :pathways
    end
  end

  # The organization count, the administrator emails and the member count are
  # the access states' whole data need, so they load with mount instead of a
  # region. The working pages load their regions where they are rendered.
  defp load_state_data(socket, :system_administrator) do
    assign(socket, :organization_count, home_source().organization_count())
  end

  defp load_state_data(%{assigns: %{current_organization: organization}} = socket, state)
       when state in [:no_version, :no_task] do
    assign(socket, :organization_admins, home_source().organization_admins(organization.id))
  end

  defp load_state_data(%{assigns: %{current_organization: organization}} = socket, :admin_only) do
    assign(socket, :member_count, home_source().member_count(organization.id))
  end

  defp load_state_data(socket, _state), do: socket

  # Resolved per call so the homepage read boundary can be substituted in tests
  # without recompiling this module. Production always uses the context.
  defp home_source do
    Application.get_env(:gtfs_planner, :home_source, GtfsPlanner.Home)
  end

  defp render_dashboard_state(:system_administrator, assigns) do
    ~H"""
    <.sysadmin organization_count={@organization_count} />
    """
  end

  defp render_dashboard_state(:missing, assigns) do
    ~H"""
    <.no_org state={:missing} />
    """
  end

  defp render_dashboard_state(:unavailable, assigns) do
    ~H"""
    <.no_org state={:unavailable} />
    """
  end

  defp render_dashboard_state(:no_version, assigns) do
    ~H"""
    <.no_version organization={@current_organization} admins={@organization_admins} />
    """
  end

  defp render_dashboard_state(:no_task, assigns) do
    ~H"""
    <.no_task organization={@current_organization} admins={@organization_admins} />
    """
  end

  defp render_dashboard_state(:admin_only, assigns) do
    ~H"""
    <.admin_only
      organization={@current_organization}
      product={ProductSurfaces.brand(@current_organization)}
      member_count={@member_count}
    />
    """
  end

  # Placeholders for the working pages: steps 19 and 20 fill `#home-planner` and
  # `#home-pathways`. Each renders only the page head, whose h1 is the version
  # name on the Planner and "Stations" on the board (AC-8, AC-20).
  defp render_dashboard_state(:planner, assigns) do
    ~H"""
    <div id="home-planner">
      <.home_head title={@current_gtfs_version.name} />
    </div>
    """
  end

  defp render_dashboard_state(:pathways, assigns) do
    ~H"""
    <div id="home-pathways">
      <.home_head title="Stations" />
    </div>
    """
  end
end
