defmodule GtfsPlannerWeb.Navigation do
  @moduledoc """
  Role-aware navigation components for the application.

  Renders navigation links based on the current user's roles within their organization.
  """

  use Phoenix.Component
  import GtfsPlannerWeb.CoreComponents

  @doc """
  Renders a role-aware sidebar navigation component.

  ## Attributes

    * `:current_user` - The currently authenticated user
    * `:current_organization` - The user's current organization context
    * `:user_roles` - List of role strings for the current user in the current organization

  ## Examples

      <.sidebar
        current_user={@current_user}
        current_organization={@current_organization}
        user_roles={@user_roles}
      />
  """
  attr :current_user, :map, required: true
  attr :current_organization, :map, default: nil
  attr :user_roles, :list, default: []

  def sidebar(assigns) do
    ~H"""
    <nav class="menu bg-base-200 w-64 min-h-screen p-4">
      <ul>
        <%= if has_role?(@user_roles, :administrator) do %>
          <li>
            <.link navigate="/organizations" class="menu-item">
              <.icon name="hero-building-office" class="w-5 h-5" />
              Organizations
            </.link>
          </li>
        <% end %>

        <%= if has_role?(@user_roles, :pathways_studio_admin) && @current_organization do %>
          <li>
            <.link navigate={"/organizations/#{@current_organization.alias}/admin/users"} class="menu-item">
              <.icon name="hero-user-group" class="w-5 h-5" />
              Users
            </.link>
          </li>
        <% end %>

        <%= if (has_role?(@user_roles, :pathways_studio_editor) || has_role?(@user_roles, :pathways_studio_viewer)) && @current_organization do %>
          <li>
            <.link navigate={"/organizations/#{@current_organization.alias}/gtfs/v1/stops"} class="menu-item">
              <.icon name="hero-map-pin" class="w-5 h-5" />
              Stations
            </.link>
          </li>
        <% end %>

        <%= if has_role?(@user_roles, :pathways_studio_editor) && @current_organization do %>
          <li>
            <.link navigate={"/organizations/#{@current_organization.alias}/gtfs/v1/import"} class="menu-item">
              <.icon name="hero-arrow-down-tray" class="w-5 h-5" />
              Import
            </.link>
          </li>
        <% end %>

        <%= if (has_role?(@user_roles, :pathways_studio_editor) || has_role?(@user_roles, :pathways_studio_viewer)) && @current_organization do %>
          <li>
            <.link navigate={"/organizations/#{@current_organization.alias}/gtfs/v1/export"} class="menu-item">
              <.icon name="hero-arrow-up-tray" class="w-5 h-5" />
              Export
            </.link>
          </li>
          <li>
            <.link navigate={"/organizations/#{@current_organization.alias}/gtfs/v1/validate"} class="menu-item">
              <.icon name="hero-shield-check" class="w-5 h-5" />
              Validate
            </.link>
          </li>
        <% end %>
      </ul>
    </nav>
    """
  end

  defp has_role?(user_roles, role) when is_atom(role) do
    role_string = Atom.to_string(role)
    role_string in user_roles
  end
end
