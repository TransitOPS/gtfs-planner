defmodule GtfsPlannerWeb.Gtfs.AgenciesLive do
  @moduledoc """
  Lists one version's agencies with their route counts and its timezone state.

  Agencies are the transit providers riders see in journey planners, so the page
  answers three questions at once: who operates this version, which routes each
  provider runs (R5, AC-9), and whether every agency agrees on one schedule
  timezone (AC-10). Each route count links to the Routes list filtered to that
  agency, or to the unfiltered list when the version has one agency, because a
  single-agency list filtered to it says the same thing.

  The list is a streamed `table` whose headers sort by name, timezone or route
  count, keeping the sort in assigns and resetting the stream. A version with no
  agency shows the first-use empty state instead: it names the routes that still
  need an agency so the editor knows what creating the first one will assign
  (AC-11). A version whose agencies disagree on a timezone keeps the list — the
  single-agency decision this package recorded — and flags the disagreement
  through the band, the warning callout that names the reason, and a "Needs
  review" note on every row whose zone differs from the version zone.

  Reads go through `GtfsPlanner.Gtfs.FeedSettings`, scoped to the organization
  and version, and the timezone verdict is `DisplayClock`'s own: this LiveView
  holds no timezone rule of its own (INV-4) and makes no `Repo` call (CR-1).

  Access follows the other Settings pages. The `:gtfs_routes` session supplies the
  user, organization and published version, and this LiveView declares the editor
  guard itself because a session alone grants no GTFS access. Version switching
  keeps the section: only a published version of the current organization
  navigates, and the target is always `/settings/agencies` of that version.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agencies")
     |> assign(:health, %{agency_count: 0, unassigned_routes: 0, zone: {:unresolved, :missing}})
     |> assign(:sort_by, :name)
     |> assign(:sort_dir, :asc)
     |> stream(:agencies, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_agencies(socket)}
  end

  @impl true
  def handle_event("sort", %{"key" => key}, socket) do
    {sort_by, sort_dir} = next_sort(socket.assigns.sort_by, socket.assigns.sort_dir, key)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> load_agencies()}
  end

  # A selection of this page's own version is nothing to do: the switcher hook
  # returns before it sends the event for the version it already shows, and
  # `gtfs_version_loaded/2` below ignores the same case, so both events agree that
  # only another published version of this organization navigates.
  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if version_id != to_string(socket.assigns.current_gtfs_version.id) &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply,
       socket
       |> push_event("gtfs_version_selected", %{version_id: version_id})
       |> push_navigate(to: agencies_path(version_id))}
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
      {:noreply, push_navigate(socket, to: agencies_path(version_id))}
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
      <:sub_header>
        <.settings_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:agencies} />
      </:sub_header>

      <%= if @health.agency_count == 0 do %>
        <.header>
          Agencies
          <:subtitle>{first_use_subtitle()}</:subtitle>
        </.header>

        <.empty_state id="agencies-empty" title="Give your service a name" class="mt-6">
          {empty_body(@health.unassigned_routes)}
        </.empty_state>

        <.support_note id="agencies-support-note">
          Already have a GTFS feed?
          <.link
            navigate={~p"/gtfs/#{@current_gtfs_version.id}/import"}
            class="link link-primary"
          >
            Review an import
          </.link>
          to bring its agencies with it.
        </.support_note>
      <% else %>
        <.header>
          Agencies
          <:subtitle>{subtitle()}</:subtitle>
        </.header>

        <%!-- `callout/1` spreads global attributes onto its own class, so the margin
        lives on a wrapper rather than being passed to the component. --%>
        <div :if={unresolved_zone?(@health.zone)} class="mt-4">
          <.callout
            id="agencies-timezone-callout"
            kind="warning"
            title={callout_title(@health.zone)}
          >
            Choose one timezone for this version. Calendars use UTC until then.
          </.callout>
        </div>

        <div class="mt-6">
          <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
            <.table id="agencies" rows={@streams.agencies} responsive="stack">
              <:col
                :let={{_id, row}}
                label="Agency"
                sort_key="name"
                sort_event="sort"
                sort={column_sort_state(@sort_by, @sort_dir, :name)}
              >
                <div class="font-semibold">{row.agency.agency_name}</div>
                <div class="mt-1 text-xs break-words text-base-content/70">
                  {website_host(row.agency.agency_url)}
                </div>
              </:col>
              <:col
                :let={{_id, row}}
                label="Timezone"
                sort_key="timezone"
                sort_event="sort"
                sort={column_sort_state(@sort_by, @sort_dir, :timezone)}
              >
                <div>{row.agency.agency_timezone || "Not set"}</div>
                <div
                  :if={row_needs_review?(row.agency.agency_timezone, @health.zone)}
                  class="mt-1 text-xs text-base-content/70"
                >
                  {needs_review()}
                </div>
              </:col>
              <:col
                :let={{_id, row}}
                label="Routes"
                align="right"
                sort_key="routes"
                sort_event="sort"
                sort={column_sort_state(@sort_by, @sort_dir, :routes)}
              >
                <.link
                  navigate={routes_path(@current_gtfs_version.id, @health.agency_count, row)}
                  class="inline-flex min-h-11 items-center gap-2 whitespace-nowrap font-semibold text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
                  aria-label={"View #{row.route_count} routes for #{row.agency.agency_name}"}
                >
                  {row.route_count} <span aria-hidden="true">→</span>
                </.link>
              </:col>
            </.table>
          </div>
          <p class="mt-2 text-sm text-base-content/70">
            Agency names open their details. Route counts show the routes they operate.
          </p>
        </div>

        <section id="agencies-timezone-band" class="mt-6 border-b border-base-300 pb-4">
          <h2 class="text-sm font-semibold text-base-content">One timezone for this version</h2>
          <p class="mt-1 text-sm text-base-content/70">{band_state(@health.zone)}</p>
        </section>

        <.support_note id="agencies-support-note">
          An agency identifies the service riders use. The organization publishing your dataset can
          be different.
          <.link
            navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings/feed-details"}
            class="link link-primary"
          >
            View feed details
          </.link>
        </.support_note>
      <% end %>
    </Layouts.app>
    """
  end

  attr :rest, :global
  slot :inner_block, required: true

  defp support_note(assigns) do
    ~H"""
    <p class="mt-6 flex max-w-3xl items-start gap-2 text-sm text-base-content/70" {@rest}>
      <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  # The health read and the rows are two scoped context calls, and the rows are
  # sorted in memory because the sort is a header click rather than a query
  # parameter: a version holds a handful of agencies, so re-reading is the whole
  # cost of a click.
  defp load_agencies(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    rows = FeedSettings.list_agencies(organization_id, version_id)
    health = FeedSettings.agency_health(organization_id, version_id)

    socket
    |> assign(:health, health)
    |> stream(
      :agencies,
      sort_rows(rows, socket.assigns.sort_by, socket.assigns.sort_dir)
      |> Enum.map(&Map.put(&1, :id, &1.agency.id)),
      reset: true
    )
  end

  defp sort_rows(rows, :name, dir), do: Enum.sort_by(rows, & &1.agency.agency_name, dir)

  defp sort_rows(rows, :timezone, dir),
    do: Enum.sort_by(rows, &(&1.agency.agency_timezone || ""), dir)

  defp sort_rows(rows, :routes, dir), do: Enum.sort_by(rows, & &1.route_count, dir)

  defp next_sort(current_by, current_dir, key) do
    case parse_sort_key(key) do
      nil -> {current_by, current_dir}
      ^current_by -> {current_by, toggle_dir(current_dir)}
      sort_by -> {sort_by, :asc}
    end
  end

  defp parse_sort_key("name"), do: :name
  defp parse_sort_key("timezone"), do: :timezone
  defp parse_sort_key("routes"), do: :routes
  defp parse_sort_key(_key), do: nil

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  defp column_sort_state(sort_by, sort_dir, column) when column == sort_by,
    do: to_string(sort_dir)

  defp column_sort_state(_sort_by, _sort_dir, _column), do: "none"

  defp subtitle, do: "Manage the public identity and contact details of your transit providers."

  defp first_use_subtitle,
    do: "The transit providers riders will see in journey planners."

  defp needs_review, do: "Needs review"

  # Every row keeps its own agency ID in the query, except a version with one
  # agency: the list filtered to that agency is the unfiltered list (AC-9).
  defp routes_path(version_id, agency_count, row) do
    base = "/gtfs/#{version_id}/routes"

    if agency_count == 1, do: base, else: "#{base}?agency_id=#{row.agency.agency_id}"
  end

  defp band_state({:ok, zone}), do: "#{zone} · Used by all agencies and their schedules."
  defp band_state({:unresolved, _reason}), do: needs_review()

  defp unresolved_zone?({:unresolved, _reason}), do: true
  defp unresolved_zone?({:ok, _zone}), do: false

  defp callout_title({:unresolved, :conflicting}), do: "Agencies use different timezones"
  defp callout_title({:unresolved, :invalid}), do: "The agency timezone isn’t recognized"
  defp callout_title({:unresolved, :missing}), do: "The agency timezone is missing"

  # A row is flagged when its own zone is not the one the version resolved: with an
  # unresolved version zone any stored zone differs, exactly as the prototype's
  # rows read.
  defp row_needs_review?(zone, {:ok, version_zone}), do: zone not in [nil, "", version_zone]
  defp row_needs_review?(zone, {:unresolved, _reason}), do: zone not in [nil, ""]

  defp website_host(url) when is_binary(url), do: URI.parse(url).host || url
  defp website_host(_url), do: ""

  defp empty_body(0) do
    "Create the first agency with its public name, website, and timezone. You can then start adding routes."
  end

  defp empty_body(count) do
    "#{unassigned_routes_sentence(count)} Creating the first agency assigns these routes to it."
  end

  defp unassigned_routes_sentence(1), do: "1 route has no agency yet."
  defp unassigned_routes_sentence(count), do: "#{count} routes have no agency yet."

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"
end
