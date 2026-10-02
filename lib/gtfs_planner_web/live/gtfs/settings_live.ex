defmodule GtfsPlannerWeb.Gtfs.SettingsLive do
  @moduledoc """
  Version-scoped Settings: the grouped overview and its placeholder sections.

  Settings holds configuration that is changed rarely, so the overview groups
  its entries by the scope they affect: the current version, all versions of the
  organization, and the organization itself. Every destination stays under
  `/gtfs/:version/settings` — the version in the URL is navigation context, even
  for the organization-level group, following the organization-wide asset pages.
  The Users page keeps its own `/admin/users` layout and authorization, so the
  overview links to it rather than moving it.

  The overview is a directory, so it carries no tab bar: its rows are the
  navigation between sections. A section page names its way back instead, with a
  "Settings" link above its heading (`PlannerComponents.back_link/1`). Pages that
  still render the tab bar drop it as they move to the same link.

  The one unbuilt section (`feed-url`) renders the shared
  `GtfsPlannerWeb.ComingSoon` body, and the overview reads its title and summary
  from the same catalog, so the two surfaces cannot drift apart. A section slug is
  looked up in a fixed map: no request string becomes an atom, and an unknown slug
  flashes and returns to the overview instead of rendering a page nobody
  described. Feed details, Agencies, Export defaults and Fares are built, so their
  literal routes are declared ahead of the section route and the overview lists
  them above the placeholder, which sits last under a "Coming soon" band.

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

  import GtfsPlannerWeb.ComingSoon, only: [coming_soon: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ComingSoon
  alias GtfsPlannerWeb.Layouts
  alias GtfsPlannerWeb.ProductSurfaces

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The one placeholder section, keyed by its literal URL slug. A request path
  # only ever looks a slug up here, and the answer is this fixed atom or `:error`.
  # A built section is not listed: its literal route resolves before the
  # `/settings/:section` placeholder route, so this map would only ever answer
  # for a destination that no longer renders Coming soon.
  @sections %{
    "feed-url" => :feed_url
  }

  # The overview's fixed groups, in the sitemap's order. Placeholder entries take
  # their title and summary from the shared catalog; the pages that already exist
  # carry their own copy and keep their current destinations.
  #
  # No version-scoped placeholder remains: Feed details, Agencies and Fares are
  # built pages, so they are listed below with their own copy.
  @version_sections []
  @all_version_sections ["feed-url"]

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
        "The wording your organization uses for alerts: message scripts and writing guidelines."
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
     |> assign(:page_title, "Settings")
     |> assign(:section_key, nil)
     |> assign(:section_slug, nil)}
  end

  @impl true
  def handle_params(%{"section" => slug}, _uri, socket) do
    case Map.fetch(@sections, slug) do
      {:ok, key} ->
        {:noreply,
         socket
         |> assign(:section_key, key)
         |> assign(:section_slug, slug)
         |> assign(:page_title, ComingSoon.feature(key).title)}

      :error ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "That settings section doesn’t exist. Choose one from the list below."
         )
         |> push_navigate(to: settings_path(socket.assigns.current_gtfs_version.id))}
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
    assigns = assign_section_content(assigns)

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
        <%= if @section_key do %>
          <.back_link id="settings-back" navigate={settings_path(@current_gtfs_version.id)}>
            Settings
          </.back_link>
          <div class="mt-2">
            <.coming_soon feature={@feature} scope_label={@scope_label} />
          </div>
        <% else %>
          <.header class="pb-8">
            Settings
            <:subtitle>
              Setup you change only occasionally. Each group says what a change affects.
            </:subtitle>
          </.header>

          <.settings_overview groups={
            overview_groups(@current_gtfs_version, @user_roles, @current_organization)
          } />
        <% end %>
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
  # list of directory rows on the right. Rows that do not work yet follow the
  # working ones under a "Coming soon" band and stay links, so the placeholder page
  # can explain them.
  attr :group, :map, required: true

  defp settings_group(assigns) do
    {ready, soon} = Enum.split_with(assigns.group.entries, &(&1.status == :active))
    assigns = assign(assigns, ready: ready, soon: soon)

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
        <ul :if={@ready != []} class="divide-y divide-subtle">
          <.directory_row :for={entry <- @ready} entry={entry} />
        </ul>
        <h3
          :if={@soon != []}
          class={[
            "bg-canvas px-5 py-2.5 text-[13px] font-semibold text-muted",
            @ready != [] && "border-t border-subtle"
          ]}
        >
          Coming soon
        </h3>
        <ul :if={@soon != []} class="divide-y divide-subtle border-t border-subtle">
          <.directory_row :for={entry <- @soon} entry={entry} />
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
            class={[
              "mt-1 block max-w-[62ch] text-pretty text-sm leading-relaxed",
              if(@entry.status == :active, do: "text-default", else: "text-muted")
            ]}
          >
            {@entry.summary}
          </span>
        </span>
        <.icon
          name="hero-chevron-right"
          class="size-4 text-muted sm:col-start-3 sm:row-start-1"
        />
        <span
          :if={@entry.status == :coming_soon}
          class="col-span-2 sm:col-span-1 sm:col-start-2 sm:row-start-1"
        >
          <span class="inline-flex items-center gap-1.5 rounded-badge bg-canvas px-2 py-0.5 text-[13px] font-[650] text-muted">
            <.icon name="hero-clock" class="size-4" /> Coming soon
          </span>
        </span>
      </.link>
    </li>
    """
  end

  # A section page renders the catalog body for the mapped key, labelled with the
  # scope that key declares. The overview needs neither, so it is left alone.
  defp assign_section_content(%{section_key: nil} = assigns), do: assigns

  defp assign_section_content(assigns) do
    feature = ComingSoon.feature(assigns.section_key)

    scope_label =
      if feature.scope == :all_versions,
        do: "All versions",
        else: scope_here(assigns.current_gtfs_version)

    assign(assigns, feature: feature, scope_label: scope_label)
  end

  # ProductSurfaces alone decides which entries an organization sees (INV-1):
  # every entry key is asked through `visible?/2`, and groups left empty are
  # dropped. The Organization group keeps its existing admin gate and is never
  # filtered, so an org admin still sees it when everything else is hidden.
  defp overview_groups(version, user_roles, organization) do
    version_entries =
      (Enum.map(@version_pages, &existing_page_entry(&1, version.id)) ++
         Enum.map(@version_sections, &placeholder_entry(&1, version.id)))
      |> Enum.filter(&ProductSurfaces.visible?(organization, &1.key))

    all_version_entries =
      (Enum.map(@all_version_pages, &existing_page_entry(&1, version.id)) ++
         Enum.map(@all_version_sections, &placeholder_entry(&1, version.id)))
      |> Enum.filter(&ProductSurfaces.visible?(organization, &1.key))

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

  defp placeholder_entry(slug, version_id) do
    key = Map.fetch!(@sections, slug)
    feature = ComingSoon.feature(key)

    %{
      key: key,
      title: feature.title,
      summary: feature.summary,
      path: section_path(version_id, slug),
      status: :coming_soon
    }
  end

  defp existing_page_entry(page, version_id) do
    %{
      key: page.key,
      title: page.title,
      summary: page.summary,
      path: section_path(version_id, page.slug),
      status: :active
    }
  end

  defp scope_here(version), do: "This version: #{version.name}"

  defp version_target(socket, version_id) do
    case socket.assigns.section_slug do
      nil -> settings_path(version_id)
      slug -> section_path(version_id, slug)
    end
  end

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  defp section_path(version_id, slug), do: "/gtfs/#{version_id}/settings/#{slug}"
end
