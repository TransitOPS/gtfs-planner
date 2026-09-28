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

  The two unbuilt sections render the shared `GtfsPlannerWeb.ComingSoon` body,
  and the overview reads those titles and summaries from the same catalog, so the
  two surfaces cannot drift apart. A section slug is looked up in a fixed map:
  no request string becomes an atom, and an unknown slug flashes and returns to
  the overview instead of rendering a page nobody described. Feed details,
  Agencies and Fares are built, so their literal routes are declared ahead of the
  section route and the overview lists them as Available pages beside the
  placeholders.

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

  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ComingSoon
  alias GtfsPlannerWeb.Layouts
  alias GtfsPlannerWeb.ProductSurfaces

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The two placeholder sections, keyed by their literal URL slug. A request
  # path only ever looks a slug up here, and the answer is one of these fixed
  # atoms or `:error`. A built section is not listed: its literal route resolves
  # before the `/settings/:section` placeholder route, so this map would only
  # ever answer for a destination that no longer renders Coming soon.
  @sections %{
    "export-defaults" => :export_defaults,
    "feed-url" => :feed_url
  }

  # The overview's fixed groups, in the sitemap's order. Placeholder entries take
  # their title and summary from the shared catalog; the pages that already exist
  # carry their own copy and keep their current destinations.
  #
  # No version-scoped placeholder remains: Feed details, Agencies and Fares are
  # built pages, so they are listed below with their own copy.
  @version_sections []
  @all_version_sections ["export-defaults", "feed-url"]

  # The built version-scoped pages, in the sitemap's order. Each moved here when
  # its page shipped: the summary is the copy its Coming soon entry used to
  # carry, and its slug keeps the `/settings/...` destination.
  @version_pages [
    %{
      key: :feed_details,
      slug: "feed-details",
      title: "Feed details",
      summary: "Describe this version’s feed for data consumers."
    },
    %{
      key: :agencies,
      slug: "agencies",
      title: "Agencies",
      summary: "Manage the agencies that operate this version’s routes."
    },
    %{
      key: :fares,
      slug: "fares",
      title: "Fares",
      summary: "Set up fare zones and the fare rules that use them."
    }
  ]

  @all_version_pages [
    %{
      key: :garages,
      slug: "garages",
      title: "Garages",
      summary: "Set where your vehicles start and end the day."
    },
    %{
      key: :fleet,
      slug: "fleet",
      title: "Fleet",
      summary: "List your vehicles to check that a plan fits your fleet."
    }
  ]

  @organization_entries [
    %{
      key: :organization_name,
      title: "Organization name",
      summary: "Change your organization’s name.",
      path: "/admin/users/organization-settings",
      status: :active
    },
    %{
      key: :users,
      title: "Users",
      summary: "Manage organization members and access.",
      path: "/admin/users",
      status: :active
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:active_tab, :index)
     |> assign(:section_key, nil)
     |> assign(:section_slug, nil)}
  end

  @impl true
  def handle_params(%{"section" => slug}, _uri, socket) do
    case Map.fetch(@sections, slug) do
      {:ok, key} ->
        {:noreply,
         socket
         |> assign(:active_tab, key)
         |> assign(:section_key, key)
         |> assign(:section_slug, slug)
         |> assign(:page_title, ComingSoon.feature(key).title)}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Settings section not found")
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
      <:sub_header>
        <.settings_nav
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@active_tab}
          organization={@current_organization}
        />
      </:sub_header>

      <%= if @section_key do %>
        <.coming_soon feature={@feature} scope_label={@scope_label} />
      <% else %>
        <.header>
          Settings
          <:subtitle>Rarely changed configuration and reference data, grouped by scope.</:subtitle>
        </.header>

        <.settings_overview groups={
          overview_groups(@current_gtfs_version, @user_roles, @current_organization)
        } />
      <% end %>
    </Layouts.app>
    """
  end

  attr :groups, :list, required: true

  defp settings_overview(assigns) do
    ~H"""
    <p :if={@groups == []} id="settings-empty" class="text-sm text-muted">
      No settings are available for this organization.
    </p>
    <div
      :if={@groups != []}
      id="settings-overview"
      class={["grid gap-6 sm:grid-cols-2", length(@groups) == 3 && "xl:grid-cols-3"]}
    >
      <section :for={group <- @groups} id={group.id}>
        <h2 class="text-sm font-semibold text-base-content">{group.scope}</h2>
        <ul class="mt-3 space-y-4">
          <li
            :for={entry <- group.entries}
            id={"settings-entry-#{entry.key}"}
            class="rounded-box border border-base-300 p-4"
          >
            <.link
              navigate={entry.path}
              class="font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
            >
              {entry.title}
            </.link>
            <p class="mt-1 text-sm text-base-content/70">{entry.summary}</p>
            <.status_badge status={entry.status} label={status_label(entry.status)} class="mt-3" />
          </li>
        </ul>
      </section>
    </div>
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
      (Enum.map(@all_version_sections, &placeholder_entry(&1, version.id)) ++
         Enum.map(@all_version_pages, &existing_page_entry(&1, version.id)))
      |> Enum.filter(&ProductSurfaces.visible?(organization, &1.key))

    groups =
      [
        %{id: "settings-version", scope: scope_here(version), entries: version_entries},
        %{id: "settings-all-versions", scope: "All versions", entries: all_version_entries}
      ]
      |> Enum.reject(&(&1.entries == []))

    if "pathways_studio_admin" in user_roles do
      groups ++
        [%{id: "settings-organization", scope: "Organization", entries: @organization_entries}]
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

  defp status_label(:coming_soon), do: "Coming soon"
  defp status_label(:active), do: "Available"

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
