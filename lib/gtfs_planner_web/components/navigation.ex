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
          <.icon name="hero-map-pin" class="w-4 h-4" /> Stops &amp; stations
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

  @doc """
  Renders the account menu: an icon-only trigger that opens a dropdown with
  account-scoped actions (Account settings, Log out).

  These actions are grouped here — separate from the task navigation in
  `top_nav/1` — because they concern the signed-in account, not the transit data.
  The trigger stays icon-only to keep the header uncluttered; the account's email
  is carried in the trigger's `aria-label` and shown in the panel's "Signed in as"
  header, so identity is available without competing with the task nav visually.

  ## Attributes

    * `:current_user` - The currently authenticated user (email used for the
      accessible label and the panel's "Signed in as" line)
    * `:current_path` - The current URL path, for marking Account settings active
  """
  attr :current_user, :map, required: true
  attr :current_path, :string, default: "/"

  def user_menu(assigns) do
    ~H"""
    <div id="user-menu" phx-hook="UserMenu" class="relative">
      <button
        type="button"
        data-user-menu-trigger
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls="user-menu-panel"
        aria-label={"Account menu for #{@current_user.email}"}
        title="Account"
        class="inline-flex items-center justify-center gap-1 min-h-11 min-w-11 rounded-md px-2.5 py-2 text-base-content/70 hover:text-base-content hover:bg-base-200 transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"
      >
        <.icon name="hero-user-circle" class="w-6 h-6 flex-none" />
        <.icon name="hero-chevron-down" class="w-4 h-4 flex-none" />
      </button>

      <div
        id="user-menu-panel"
        data-user-menu-panel
        role="menu"
        aria-label="Account"
        hidden
        class="absolute right-0 mt-1 w-56 z-50 rounded-box border border-base-300 bg-base-100 py-1 shadow-lg"
      >
        <div class="px-3 py-2 border-b border-base-300">
          <p class="text-xs text-base-content/70">Signed in as</p>
          <p class="text-sm font-medium text-base-content truncate">{@current_user.email}</p>
        </div>
        <.link
          navigate="/users/settings"
          role="menuitem"
          class={[
            "flex items-center gap-2 min-h-11 px-3 py-2 text-sm focus:outline-none focus:bg-base-200",
            if(path_family_active?(@current_path, ["users", "settings"]),
              do: "font-semibold text-base-content bg-base-200",
              else: "text-base-content/80 hover:bg-base-200 hover:text-base-content"
            )
          ]}
          aria-current={path_family_active?(@current_path, ["users", "settings"]) && "page"}
        >
          <.icon name="hero-cog-6-tooth" class="w-4 h-4 flex-none" /> Account settings
        </.link>
        <.link
          href="/users/log_out"
          method="delete"
          role="menuitem"
          class="flex items-center gap-2 min-h-11 px-3 py-2 text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content focus:outline-none focus:bg-base-200"
        >
          <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4 flex-none" /> Log out
        </.link>
      </div>
    </div>
    """
  end

  defp nav_link_class(is_active) do
    base =
      "inline-flex items-center gap-1.5 px-3 py-2 min-h-11 rounded-md text-sm transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"

    state =
      if is_active do
        "font-semibold text-base-content bg-base-200"
      else
        "font-medium text-base-content/70 hover:text-base-content hover:bg-base-200"
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
