defmodule GtfsPlannerWeb.Navigation do
  @moduledoc """
  Role-aware navigation components for the application.

  Renders navigation links based on the current user's roles within their organization.
  """

  use Phoenix.Component
  import GtfsPlannerWeb.CoreComponents
  import GtfsPlannerWeb.UserAuth, only: [is_administrator?: 1]

  @doc """
  Renders a role-aware top navigation component using Daisy UI tabs with border style.

  ## Attributes

    * `:current_user` - The currently authenticated user
    * `:current_organization` - The user's current organization context
    * `:user_roles` - List of role strings for the current user in the current organization
    * `:current_path` - The current URL path for highlighting active tab

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
    <nav role="tablist" class="tabs tabs-border">
      <%= if is_administrator?(@current_user) do %>
        <.link
          navigate="/admin/organizations"
          role="tab"
          class={["tab", active_tab?(@current_path, "/admin/organizations") && "tab-active"]}
        >
          Organizations
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_admin) && @current_organization do %>
        <.link
          navigate="/admin/users"
          role="tab"
          class={["tab", active_tab?(@current_path, "/admin/users") && "tab-active"]}
        >
          <.icon name="hero-user-group" class="w-4 h-4 mr-1" /> Users
        </.link>
      <% end %>

      <%= if (has_role?(@user_roles, :pathways_studio_editor) || has_role?(@user_roles, :pathways_studio_viewer)) && @current_organization do %>
        <.link
          navigate="/gtfs/v1/stops"
          role="tab"
          class={["tab", active_tab?(@current_path, "/gtfs/v1/stops") && "tab-active"]}
        >
          <.icon name="hero-map-pin" class="w-4 h-4 mr-1" /> Stations
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_editor) && @current_organization do %>
        <.link
          navigate="/gtfs/v1/import"
          role="tab"
          class={["tab", active_tab?(@current_path, "/gtfs/v1/import") && "tab-active"]}
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" /> Import
        </.link>
      <% end %>

      <%= if (has_role?(@user_roles, :pathways_studio_editor) || has_role?(@user_roles, :pathways_studio_viewer)) && @current_organization do %>
        <.link
          navigate="/gtfs/v1/export"
          role="tab"
          class={["tab", active_tab?(@current_path, "/gtfs/v1/export") && "tab-active"]}
        >
          <.icon name="hero-arrow-up-tray" class="w-4 h-4 mr-1" /> Export
        </.link>
        <.link
          navigate="/gtfs/v1/validate"
          role="tab"
          class={["tab", active_tab?(@current_path, "/gtfs/v1/validate") && "tab-active"]}
        >
          <.icon name="hero-shield-check" class="w-4 h-4 mr-1" /> Validate
        </.link>
      <% end %>
    </nav>
    """
  end

  defp active_tab?(current_path, tab_path) do
    String.starts_with?(current_path, tab_path)
  end

  defp has_role?(user_roles, role) when is_atom(role) do
    role_string = Atom.to_string(role)
    role_string in user_roles
  end
end
