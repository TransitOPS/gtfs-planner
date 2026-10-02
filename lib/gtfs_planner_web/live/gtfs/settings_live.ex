defmodule GtfsPlannerWeb.Gtfs.SettingsLive do
  @moduledoc """
  Version-scoped Settings: the grouped directory of the pages that own them.

  Settings holds configuration that is changed rarely, so the overview groups
  its entries by the scope they affect: the current version, all versions of the
  organization, and the organization itself. Every destination stays under
  `/gtfs/:version/settings` — the version in the URL is navigation context, even
  for the organization-level group, following the organization-wide asset pages.
  The Users page keeps its own `/admin/users` layout and authorization, so the
  overview links to it rather than moving it.

  The overview is a directory, so it carries no tab bar: its rows are the
  navigation between sections, and a destination that is not the overview names
  its own way back.

  Every section has shipped, so the overview lists working pages only. One slug
  still has to answer: `feed-url` described a permanent public address, and that
  page shipped as the organization-owned `/settings/published-feeds` surface, so
  this route sends an old version-scoped bookmark there rather than to a copy of a
  placeholder that describes nothing. A slug is looked up in a fixed map: no
  request string becomes an atom, and an unknown slug flashes and returns to the
  overview instead of rendering a page nobody described.

  Access follows the other GTFS pages. The `:gtfs_routes` session supplies the
  user, organization and published version, and this LiveView declares the editor
  guard itself because a session alone grants no GTFS access. The Organization
  group appears only for `pathways_studio_admin` members; the linked admin pages
  keep their own guard.

  Version switching keeps the current section — or the overview — and accepts
  only a published version of the current organization. A foreign, staging or
  absent selection leaves both the socket and the client's selection untouched.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts
  alias GtfsPlannerWeb.ProductSurfaces

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The organization-owned page that reports this organization's published feeds.
  @published_feeds_path "/settings/published-feeds"

  # Where a version-scoped section slug belongs now, keyed by its literal URL slug.
  # A request path only ever looks a slug up here: no request string becomes an
  # atom, and an unknown slug flashes and returns to the overview.
  @moved_sections %{
    "feed-url" => @published_feeds_path
  }

  # The built version-scoped pages, in the sitemap's order. Each moved here when
  # its page shipped: the summary is the copy its Coming soon entry used to
  # carry, and its slug keeps the `/settings/...` destination.
  @version_pages [
    %{
      key: :feed_details,
      slug: "feed-details",
      title: "Feed details",
      summary:
        "Who publishes this schedule data, the dates it covers, and who apps can contact about it."
    },
    %{
      key: :agencies,
      slug: "agencies",
      title: "Agencies",
      summary:
        "The agencies that operate your routes: names, websites and the timezone your schedules run in."
    },
    %{
      key: :fares,
      slug: "fares",
      title: "Fares",
      summary: "Group stops into fare zones, then set the fare rules that use them."
    }
  ]

  # The built All versions pages, in the sitemap's order. A page that ships keeps
  # the place its Coming soon entry held — Export defaults sits where its
  # placeholder did, after Garages and Fleet — so building a page never reorders
  # the group around it.
  @all_version_pages [
    %{
      key: :alerts,
      slug: "alerts",
      title: "Alerts",
      summary:
        "The wording your organization uses for alerts: message scripts and writing guidelines.",
      # Alert settings are organization-owned and moved out of the version's own
      # path, so this entry points at the page that now owns them rather than at
      # the version's Settings path that redirects there.
      path: "/alerts/settings"
    },
    %{
      key: :garages,
      slug: "garages",
      title: "Garages",
      summary: "Where your vehicles start and end the day."
    },
    %{
      key: :fleet,
      slug: "fleet",
      title: "Fleet",
      summary: "Your vehicles, so you can check that a plan fits your fleet."
    },
    %{
      key: :export_defaults,
      slug: "export-defaults",
      title: "Export defaults",
      summary: "Choose how future exports are written."
    },
    %{
      # The permanent public addresses are the organization's, not a version's, so
      # this row leads out of the version's Settings path. Its DOM key stays
      # `feed_url`, which is the name this destination has always had here.
      key: :feed_url,
      surface: :published_feeds,
      title: "Published feeds",
      summary:
        "The permanent addresses your published feeds are served from, and what each one is serving now.",
      path: @published_feeds_path
    }
  ]

  @organization_entries [
    %{
      key: :organization_name,
      title: "Organization name",
      summary: "Change how your organization’s name appears in the app.",
      path: "/admin/users/organization-settings",
      status: :active
    },
    %{
      key: :users,
      title: "Users",
      summary: "Invite people, set their roles and turn off access.",
      path: "/admin/users",
      status: :active
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")}
  end

  @impl true
  def handle_params(%{"section" => slug}, _uri, socket) do
    case Map.fetch(@moved_sections, slug) do
      {:ok, path} ->
        {:noreply, push_navigate(socket, to: path)}

      :error ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "That settings section doesn’t exist. Choose one from the list below."
         )
         |> push_navigate(to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/settings")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: version_target(socket, version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: version_target(socket, version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <div id="settings-page">
        <.header class="pb-8">
          Settings
          <:subtitle>
            Setup you change only occasionally. Each group says what a change affects.
          </:subtitle>
        </.header>

        <.settings_overview groups={
          overview_groups(@current_gtfs_version, @user_roles, @current_organization)
        } />
      </div>
    </Layouts.app>
    """
  end

  attr :groups, :list, required: true

  defp settings_overview(assigns) do
    ~H"""
    <div id="settings-overview">
      <.settings_group :for={group <- @groups} group={group} />
    </div>
    """
  end

  # One scope: its name and what a change in it affects on the left, a bordered
  # list of directory rows on the right.
  attr :group, :map, required: true

  defp settings_group(assigns) do
    ~H"""
    <section
      id={@group.id}
      aria-labelledby={"#{@group.id}-title"}
      class="grid gap-x-12 gap-y-4 border-t border-subtle py-8 lg:grid-cols-[17.5rem_minmax(0,1fr)]"
    >
      <div class="min-w-0">
        <h2
          id={"#{@group.id}-title"}
          class="font-display text-2xl font-semibold tracking-[-0.025em] text-strong"
        >
          {@group.title}
        </h2>
        <p id={"#{@group.id}-summary"} class="mt-2 text-sm">
          <.group_summary group={@group} />
        </p>
        <p class="mt-3 text-[13px] text-muted">{@group.note}</p>
      </div>
      <div class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white">
        <ul class="divide-y divide-subtle">
          <.directory_row :for={entry <- @group.entries} entry={entry} />
        </ul>
      </div>
    </section>
    """
  end

  attr :group, :map, required: true

  defp group_summary(%{group: %{key: :version}} = assigns) do
    ~H"""
    Changes apply to <strong class="font-semibold text-strong">{@group.version_name}</strong>
    only. Other versions keep their own.
    """
  end

  defp group_summary(%{group: %{key: :all_versions}} = assigns) do
    ~H"""
    Shared by every version. A change here shows up in all of them.
    """
  end

  defp group_summary(%{group: %{key: :organization}} = assigns) do
    ~H"""
    Your organization’s name and the people who can sign in.
    """
  end

  # The whole row is the link, so hover, focus and click share one target and
  # nothing inside it competes. Focus is drawn inside the row because the list
  # clips its overflow.
  attr :entry, :map, required: true

  defp directory_row(assigns) do
    ~H"""
    <li id={"settings-entry-#{@entry.key}"}>
      <.link
        navigate={@entry.path}
        class={[
          "group grid grid-cols-[minmax(0,1fr)_1rem] items-center gap-x-6 gap-y-3 px-5 py-4 no-underline",
          "hover:bg-canvas sm:grid-cols-[minmax(0,1fr)_auto_1rem]",
          "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
        ]}
      >
        <span class="min-w-0">
          <span
            id={"settings-entry-#{@entry.key}-title"}
            class="block text-base font-semibold leading-snug text-strong underline-offset-4 group-hover:underline"
          >
            {@entry.title}
          </span>
          <span
            id={"settings-entry-#{@entry.key}-summary"}
            class="mt-1 block max-w-[62ch] text-pretty text-sm leading-relaxed text-default"
          >
            {@entry.summary}
          </span>
        </span>
        <.icon
          name="hero-chevron-right"
          class="size-4 text-muted sm:col-start-3 sm:row-start-1"
        />
      </.link>
    </li>
    """
  end

  # ProductSurfaces alone decides which entries an organization sees (INV-1):
  # every entry is asked through `visible?/2`, and groups left empty are dropped.
  # An entry may name its own surface when the destination is visible under a
  # different name than the row it is listed as; otherwise its key is the surface.
  # The Organization group keeps its existing admin gate and is never filtered, so
  # an org admin still sees it when everything else is hidden.
  defp visible_entry?(organization, entry) do
    ProductSurfaces.visible?(organization, Map.get(entry, :surface, entry.key))
  end

  defp overview_groups(version, user_roles, organization) do
    version_entries =
      @version_pages
      |> Enum.map(&existing_page_entry(&1, version.id))
      |> Enum.filter(&visible_entry?(organization, &1))

    all_version_entries =
      @all_version_pages
      |> Enum.map(&existing_page_entry(&1, version.id))
      |> Enum.filter(&visible_entry?(organization, &1))

    groups =
      [
        %{
          id: "settings-version",
          key: :version,
          title: "This version",
          version_name: version.name,
          note: "Switch versions from the header to change another one.",
          entries: version_entries
        },
        %{
          id: "settings-all-versions",
          key: :all_versions,
          title: "All versions",
          note:
            "These settings describe your organization, so they stay the same when you switch versions.",
          entries: all_version_entries
        }
      ]
      |> Enum.reject(&(&1.entries == []))

    if "pathways_studio_admin" in user_roles do
      groups ++
        [
          %{
            id: "settings-organization",
            key: :organization,
            title: "Organization",
            note: "Only organization admins see this group.",
            entries: @organization_entries
          }
        ]
    else
      groups
    end
  end

  defp existing_page_entry(page, version_id) do
    %{
      key: page.key,
      surface: Map.get(page, :surface, page.key),
      title: page.title,
      summary: page.summary,
      # An entry may name its own destination (the organization-owned Alerts page
      # does); otherwise the verified version-scoped Settings route builds it.
      path: Map.get(page, :path) || ~p"/gtfs/#{version_id}/settings/#{page.slug}"
    }
  end

  defp version_target(_socket, version_id), do: ~p"/gtfs/#{version_id}/settings"

  defp settings_path(version_id), do: ~p"/gtfs/#{version_id}/settings"

  defp section_path(version_id, slug), do: ~p"/gtfs/#{version_id}/settings/#{slug}"
end
