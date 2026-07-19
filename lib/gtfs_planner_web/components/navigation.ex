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
  attr :current_gtfs_version, :map, default: nil

  def top_nav(assigns) do
    ~H"""
    <nav
      role="navigation"
      aria-label="Main navigation"
      class="flex flex-wrap items-center gap-1"
    >
      <%= if is_administrator?(@current_user) do %>
        <.link
          navigate="/admin/organizations"
          class={nav_link_class(path_family_active?(@current_path, ["admin", "organizations"]))}
          aria-current={path_family_active?(@current_path, ["admin", "organizations"]) && "page"}
        >
          Organizations
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_admin) && @current_organization do %>
        <.link
          navigate="/admin/users"
          class={nav_link_class(path_family_active?(@current_path, ["admin", "users"]))}
          aria-current={path_family_active?(@current_path, ["admin", "users"]) && "page"}
        >
          <.icon name="hero-user-group" class="w-4 h-4" /> Users
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_editor) && @current_organization &&
              @current_gtfs_version do %>
        <.link
          navigate={"/gtfs/#{@current_gtfs_version.id}/routes"}
          class={nav_link_class(gtfs_family_active?(@current_path, "routes"))}
          aria-current={gtfs_family_active?(@current_path, "routes") && "page"}
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Routes
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_editor) && @current_organization &&
              @current_gtfs_version do %>
        <.link
          navigate={"/gtfs/#{@current_gtfs_version.id}/stops"}
          class={nav_link_class(gtfs_family_active?(@current_path, "stops"))}
          aria-current={gtfs_family_active?(@current_path, "stops") && "page"}
        >
          <.icon name="hero-map-pin" class="w-4 h-4" /> Stations
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_editor) && @current_organization &&
              @current_gtfs_version do %>
        <.link
          navigate={"/gtfs/#{@current_gtfs_version.id}/import"}
          class={nav_link_class(gtfs_family_active?(@current_path, "import"))}
          aria-current={gtfs_family_active?(@current_path, "import") && "page"}
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Import
        </.link>
      <% end %>

      <%= if has_role?(@user_roles, :pathways_studio_editor) && @current_organization &&
              @current_gtfs_version do %>
        <.link
          navigate={"/gtfs/#{@current_gtfs_version.id}/export"}
          class={nav_link_class(gtfs_family_active?(@current_path, "export"))}
          aria-current={gtfs_family_active?(@current_path, "export") && "page"}
        >
          <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> Export
        </.link>
      <% end %>
    </nav>
    """
  end

  defp nav_link_class(is_active) do
    base =
      "inline-flex items-center gap-1.5 px-3 py-2 min-h-11 rounded-md text-sm transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"

    state =
      if is_active do
        "font-semibold text-base-content border-b-2 border-primary bg-base-200"
      else
        "font-medium text-base-content/70 border-b-2 border-transparent hover:text-base-content hover:bg-base-200"
      end

    [base, state]
  end

  defp path_segments(current_path) do
    current_path
    |> URI.parse()
    |> Map.get(:path, "/")
    |> String.split("/", trim: true)
  end

  defp path_family_active?(current_path, family_segments) do
    segments = path_segments(current_path)
    Enum.take(segments, length(family_segments)) == family_segments
  end

  defp gtfs_family_active?(current_path, task) do
    segments = path_segments(current_path)

    case segments do
      ["gtfs", _version, ^task | _rest] -> true
      _ -> false
    end
  end

  defp has_role?(user_roles, role) when is_atom(role) do
    role_string = Atom.to_string(role)
    role_string in user_roles
  end
end
