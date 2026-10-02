defmodule GtfsPlannerWeb.Navigation do
  @moduledoc """
  Role-aware navigation components for the application.

  Renders navigation links based on the current user's roles within their organization.
  """

  use Phoenix.Component
  import GtfsPlannerWeb.CoreComponents
  import GtfsPlannerWeb.UserAuth, only: [is_administrator?: 1]

  # The main task areas in the information architecture's order. Each entry is
  # `{link key, {label, families}}`, where the families are the path segments
  # under `/gtfs/:version` that mark the link current and the first family is
  # also the link's own destination. GTFS holds Export and Import, whose pages
  # carry their own tabs.
  defp main_tasks do
    [
      routes: {"Routes", ["routes", "transfers"]},
      stops: {"Stops", ["stops"]},
      calendars: {"Calendars", ["calendars"]},
      alerts: {"Alerts", ["alerts"]},
      flex: {"Flex", ["flex"]},
      operations: {"Operations", ["blocks", "runs", "rosters"]},
      gtfs: {"GTFS", ["export", "import", "validation", "station-reachability"]}
    ]
  end

  # Design-system task link: a label-only target that takes the selection tint
  # from its own `aria-current`, so the state is never signalled by hue alone.
  defp task_link_class do
    "flex min-h-11 items-center whitespace-nowrap rounded-control px-3 text-sm font-semibold no-underline text-muted hover:bg-canvas hover:text-strong aria-[current=page]:bg-selection aria-[current=page]:text-action"
  end

  # Account-menu item, sized for the 44px target and using the design system's
  # canvas hover instead of daisyUI's base-200. Exactly one text color is applied
  # per state, so no two utilities compete for the same property.
  defp menu_item_class(current?) do
    [
      "flex min-h-11 items-center rounded-control px-3 text-sm no-underline hover:bg-canvas focus:bg-canvas",
      if(current?, do: "bg-selection font-semibold text-action", else: "text-strong")
    ]
  end

  @doc """
  Renders the role-aware main navigation: Admin first for system
  administrators, then a divider and the task areas in the information
  architecture's order. Task areas hidden for the organization's product
  (`GtfsPlannerWeb.ProductSurfaces.visible?/2`) are omitted.

  Task links are label-only and carry the design system's selection tint on the
  current area; each task owns its path family, so `/gtfs/:version/runs` marks
  Operations and `/gtfs/:version/import` marks GTFS.

  ## Attributes

    * `:current_user` - The currently authenticated user
    * `:current_organization` - The user's current organization context
    * `:user_roles` - List of role strings for the current user in the current organization
    * `:current_path` - The current URL path for highlighting the current task
    * `:current_gtfs_version` - The current GTFS version, for the task destinations

  ## Examples

      <.top_nav
        current_user={@current_user}
        current_organization={@current_organization}
        user_roles={@user_roles}
        current_path={@current_path}
        current_gtfs_version={@current_gtfs_version}
      />
  """
  attr :current_user, :map, required: true
  attr :current_organization, :map, default: nil
  attr :user_roles, :list, default: []
  attr :current_path, :string, default: "/"
  attr :current_gtfs_version, :map, default: nil

  def top_nav(assigns) do
    assigns =
      assign(assigns,
        show_tasks:
          has_role?(assigns.user_roles, :pathways_studio_editor) &&
            assigns.current_organization && assigns.current_gtfs_version,
        visible_tasks:
          Enum.filter(main_tasks(), fn {key, _label_families} ->
            GtfsPlannerWeb.ProductSurfaces.visible?(assigns.current_organization, key)
          end)
      )

    ~H"""
    <nav
      id="main-navigation"
      role="navigation"
      aria-label="Main navigation"
      class="flex min-h-[72px] flex-wrap items-center gap-1"
    >
      <%= if is_administrator?(@current_user) do %>
        <.link
          id="nav-organizations"
          navigate="/admin/organizations"
          class={task_link_class()}
          aria-current={path_family_active?(@current_path, ["admin", "organizations"]) && "page"}
        >
          Admin
        </.link>
        <span :if={@show_tasks} aria-hidden="true" class="mx-2 h-6 w-px shrink-0 bg-subtle"></span>
      <% end %>

      <.link
        :for={{key, {label, families}} <- @visible_tasks}
        :if={@show_tasks}
        id={"nav-#{key}"}
        navigate={"/gtfs/#{@current_gtfs_version.id}/#{hd(families)}"}
        class={task_link_class()}
        aria-current={gtfs_family_active?(@current_path, families) && "page"}
      >
        {label}
      </.link>
    </nav>
    """
  end

  @doc """
  Renders the account menu: a trigger showing the user's initials that opens a
  dropdown with the scoped Settings entry and the signed-in account's own
  actions.

  Settings lives here rather than in the task bar because it is not a task area.
  The target follows the viewer's context: an editor with a version gets that
  version's Settings, an organization administrator without a qualifying editor
  context gets the organization's Users page, and anyone else gets no Settings
  entry and no organization label.

  ## Attributes

    * `:current_user` - The currently authenticated user (email used for the
      accessible label, the panel's "Signed in as" line and the initials)
    * `:current_path` - The current URL path, for marking the account and
      Settings entries current
    * `:current_organization` - The user's current organization context
    * `:user_roles` - List of role strings for the current user in the current organization
    * `:current_gtfs_version` - The current GTFS version, part of the editor's
      Settings path
  """
  attr :current_user, :map, required: true
  attr :current_path, :string, default: "/"
  attr :current_organization, :map, default: nil
  attr :user_roles, :list, default: []
  attr :current_gtfs_version, :map, default: nil

  def user_menu(assigns) do
    assigns =
      assign(assigns,
        initials: initials(assigns.current_user.email),
        settings:
          settings_target(
            assigns.current_organization,
            assigns.user_roles,
            assigns.current_gtfs_version
          ),
        settings_current?: settings_family_active?(assigns.current_path),
        menu_current?: menu_current_family?(assigns.current_path)
      )

    ~H"""
    <div id="user-menu" phx-hook="UserMenu" class="relative">
      <button
        type="button"
        data-user-menu-trigger
        data-current={@menu_current? && "true"}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls="user-menu-panel"
        aria-label={"Account menu for #{@current_user.email}"}
        title="Account"
        class={[
          "inline-flex min-h-11 min-w-11 items-center justify-center gap-1.5 rounded-control px-1.5",
          if(@menu_current?,
            do: "bg-selection text-action",
            else: "text-muted hover:bg-canvas hover:text-strong"
          )
        ]}
      >
        <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-navy-100 text-[13px] font-semibold leading-none tracking-[0.02em] text-strong">
          {@initials}
        </span>
        <.icon name="hero-chevron-down" class="size-4 shrink-0" />
      </button>

      <div
        id="user-menu-panel"
        data-user-menu-panel
        role="menu"
        aria-label="Account"
        hidden
        class="absolute right-0 mt-1 w-80 z-50 rounded-card border border-subtle bg-white p-2 shadow-float"
      >
        <%= if @settings do %>
          <p class="px-3 pb-1 pt-2 text-[13px] font-semibold text-muted">
            {@current_organization.name}
          </p>
          <.link
            id="settings-link"
            navigate={@settings.href}
            role="menuitem"
            aria-current={@settings_current? && "page"}
            class={[
              "flex min-h-11 flex-col justify-center rounded-control px-3 py-2 no-underline",
              if(@settings_current?,
                do: "bg-selection text-action",
                else: "text-strong hover:bg-canvas focus:bg-canvas"
              )
            ]}
          >
            <span class="text-sm font-semibold">Settings</span>
            <span class="text-[13px] leading-snug text-muted">{@settings.hint}</span>
          </.link>
          <div class="my-1 border-t border-subtle"></div>
        <% end %>

        <div class="flex items-center gap-3 px-3 pb-2 pt-2">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-navy-100 text-[13px] font-semibold leading-none tracking-[0.02em] text-strong">
            {@initials}
          </span>
          <div class="min-w-0">
            <p class="text-[13px] leading-snug text-muted">Signed in as</p>
            <p class="truncate text-sm font-semibold text-strong">{@current_user.email}</p>
          </div>
        </div>

        <.link
          navigate="/users/settings"
          role="menuitem"
          class={menu_item_class(path_family_active?(@current_path, ["users", "settings"]))}
          aria-current={path_family_active?(@current_path, ["users", "settings"]) && "page"}
        >
          Profile settings
        </.link>
        <.link href="/users/log_out" method="delete" role="menuitem" class={menu_item_class(false)}>
          Log out
        </.link>
      </div>
    </div>
    """
  end

  # The Settings entry for this viewer's context, or nil when the viewer has no
  # Settings destination. An editor with a version wins over the organization
  # administrator fallback, and an organization is required for both. When the
  # organization's product hides version Settings, the editor branch is skipped
  # so an administrator falls back to Users and anyone else gets no entry.
  defp settings_target(nil, _user_roles, _current_gtfs_version), do: nil

  defp settings_target(organization, user_roles, current_gtfs_version) do
    cond do
      has_role?(user_roles, :pathways_studio_editor) && current_gtfs_version &&
          GtfsPlannerWeb.ProductSurfaces.visible?(organization, :feed_details) ->
        %{
          href: "/gtfs/#{current_gtfs_version.id}/settings",
          hint: "Agencies, fares, exports, garages, fleet"
        }

      has_role?(user_roles, :pathways_studio_admin) ->
        %{href: "/admin/users", hint: "Organization name, users"}

      true ->
        nil
    end
  end

  # Initials for the avatar: the first letter of up to two parts of the email's
  # local part, split on `.`, `_`, `-` and `+`. Users have no name field, and an
  # email with an empty local part falls back to its first grapheme.
  defp initials(email) do
    [local_part | _rest] = String.split(email, "@", parts: 2)

    case String.split(local_part, [".", "_", "-", "+"], trim: true) do
      [] -> email |> String.first() |> String.upcase()
      parts -> parts |> Enum.take(2) |> Enum.map_join(&String.upcase(String.first(&1)))
    end
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

  # The version-prefixed settings family (`/gtfs/:version/settings...`), matched
  # on the literal segment so a lookalike slug cannot select it.
  defp gtfs_settings_family_active?(current_path) do
    case path_segments(current_path) do
      ["gtfs", _version, "settings" | _rest] -> true
      _ -> false
    end
  end

  # Settings is current on its two destination families; the menu trigger is
  # current there as well as on the account's own settings page.
  defp settings_family_active?(current_path) do
    gtfs_settings_family_active?(current_path) ||
      path_family_active?(current_path, ["admin", "users"])
  end

  defp menu_current_family?(current_path) do
    settings_family_active?(current_path) ||
      path_family_active?(current_path, ["users", "settings"])
  end

  # A task is current when the segment after the version is one of its families.
  defp gtfs_family_active?(current_path, families) do
    case path_segments(current_path) do
      ["gtfs", _version, segment | _rest] -> segment in families
      _ -> false
    end
  end

  defp has_role?(user_roles, role) when is_atom(role) do
    role_string = Atom.to_string(role)
    role_string in user_roles
  end
end
