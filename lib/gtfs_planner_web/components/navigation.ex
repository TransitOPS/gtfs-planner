defmodule GtfsPlannerWeb.Navigation do
  @moduledoc """
  Role-aware navigation components for the application.

  Renders navigation links based on the current user's roles within their organization.
  """

  use Phoenix.Component
  import GtfsPlannerWeb.CoreComponents
  import GtfsPlannerWeb.UserAuth, only: [is_administrator?: 1]

  @doc """
  Renders a role-aware top navigation component using left-aligned pill-style links.

  ## Attributes

    * `:current_user` - The currently authenticated user
    * `:current_organization` - The user's current organization context
    * `:user_roles` - List of role strings for the current user in the current organization
    * `:current_path` - The current URL path for highlighting active pill

  ## Examples

      <.top_nav
        current_user={@current_user}
        current_organization={@current_organization}
        user_roles={@user_roles}
        current_path={@current_path}
      />
  """
  attr :current_user, :map, required: true
  attr :current_organization, :map, default: nil
  attr :user_roles, :list, default: []
  attr :current_path, :string, default: "/"

  def top_nav(assigns) do
    ~H"""
    <nav role="navigation" aria-label="Main navigation" class="flex items-center gap-2">
      <%= if is_administrator?(@current_user) do %>
        <.link
          navigate="/admin/organizations"
          class={pill_class(active_tab?(@current_path, "/admin/organizations"))}
        >
          Organizations
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_admin) && @current_organization do %>
        <.link
          navigate="/admin/users"
          class={pill_class(active_tab?(@current_path, "/admin/users"))}
        >
          <.icon name="hero-user-group" class="w-4 h-4" /> Users
        </.link>
      <% end %>

      <%= if (has_role?(@user_roles, :pathways_studio_editor) || has_role?(@user_roles, :pathways_studio_viewer)) && @current_organization do %>
        <.link
          navigate="/gtfs/stops"
          class={pill_class(gtfs_tab_active?(@current_path, "stops"))}
        >
          <.icon name="hero-map-pin" class="w-4 h-4" /> Stations
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_editor) && @current_organization do %>
        <.link
          navigate="/gtfs/import"
          class={pill_class(gtfs_tab_active?(@current_path, "import"))}
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Import
        </.link>
      <% end %>

      <%= if (has_role?(@user_roles, :pathways_studio_editor) || has_role?(@user_roles, :pathways_studio_viewer)) && @current_organization do %>
        <.link
          navigate="/gtfs/export"
          class={pill_class(gtfs_tab_active?(@current_path, "export"))}
        >
          <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> Export
        </.link>
        <.link
          navigate="/gtfs/validate"
          class={pill_class(gtfs_tab_active?(@current_path, "validate"))}
        >
          <.icon name="hero-shield-check" class="w-4 h-4" /> Validate
        </.link>
      <% end %>
    </nav>
    """
  end

  # Returns pill classes based on active state
  # Uses literal class strings for Tailwind JIT compatibility
  defp pill_class(is_active) do
    base = "inline-flex items-center gap-1.5 px-4 py-2 rounded-full text-base font-medium transition-colors duration-150 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-emerald-600"

    state =
      if is_active do
        "bg-[#009966] text-white hover:bg-[#008855]"
      else
        "bg-emerald-50 text-gray-700 hover:bg-emerald-100 hover:text-emerald-700"
      end

    [base, state]
  end

  defp active_tab?(current_path, tab_path) do
    String.starts_with?(current_path, tab_path)
  end

  # Checks if a GTFS tab is active. Handles both versionless (/gtfs/stops)
  # and versioned (/gtfs/{uuid}/stops) routes.
  defp gtfs_tab_active?(current_path, tab_name) do
    String.starts_with?(current_path, "/gtfs") &&
      String.contains?(current_path, tab_name)
  end

  defp has_role?(user_roles, role) when is_atom(role) do
    role_string = Atom.to_string(role)
    role_string in user_roles
  end
end