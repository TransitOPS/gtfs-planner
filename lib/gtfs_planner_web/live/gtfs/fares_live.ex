defmodule GtfsPlannerWeb.Gtfs.FaresLive do
  @moduledoc """
  The Fare zones workspace shell for Settings › This version › Fares.

  One LiveView serves the workspace's three destinations — `/settings/fares`
  (`:zones`), `/settings/fares/rules` (`:rules`) and `/settings/fares/checks`
  (`:checks`). The tabs patch between them, so the Zones tab's query state
  (`?zone=`, `?filter=`, `?q=`, `?page=`) stays in the URL and a tab change
  neither remounts the page nor drops it.

  Access is authorized at mount through `EnsureRole`, following the other GTFS
  pages: there is no view-only GTFS role, and `Gtfs.FareZones` enforces the
  organization and version scope on every read the workspace performs. The
  workspace's data arrives in one operational read through
  `Gtfs.load_fare_workspace/3`, so a lost database connection resolves to one
  load-error state with a single recovery action instead of a blank page, a
  partial workspace, or a crash reported as downtime.

  The disconnected render shows the skeleton; the connected load resolves to
  `:ready` or `:unavailable`, and `reload` re-runs the same load. The Zones tab
  renders the version's inventory, the filter the URL asked for and the stop
  list below the stage header.

  The stop list is the page's second URL state owner: searching patches `?q=`
  and drops `?page=`, and pagination patches `?page=`, both keeping the current
  filter so a control never silently changes which stops are listed. Each load
  resets the `:stops` stream to the page `FareZones.list_stops/3` returned, so
  the rows are data and the table itself is not re-rendered per row.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FaresComponents,
    only: [load_error: 1, loading: 1, stage_header: 1, stop_list: 1, zone_inventory: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fare zones")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:load_state, :loading)
     |> assign(:inventory, nil)
     |> assign(:checks, nil)
     |> assign(:stop_page, nil)
     |> assign(:filter, :all)
     |> assign(:q, nil)
     |> assign(:page, 1)
     |> stream(:stops, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {filter, q, page} = zones_params(socket.assigns.live_action, params)

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:q, q)
      |> assign(:page, page)

    if connected?(socket) do
      {:noreply, load_workspace(socket)}
    else
      # The static render ships the skeleton; the connected mount owns the load.
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load_workspace(socket)}

  # Searching patches `q` and drops `page`: a new search starts at its own first
  # page. The filter stays, so a search inside a zone keeps listing that zone.
  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: zones_url(socket, search_query(q)))}
  end

  # Pagination keeps both the filter and the search, so page 2 shows the next
  # page of the same list instead of the next page of everything.
  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: zones_url(socket, page: parse_page(page)))}
  end

  # Copy of GaragesLive's version handlers, pointed at the current tab so a
  # version switch keeps the operator on the workspace view they were reading.
  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: fares_path(version_id, socket.assigns.live_action))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: fares_path(version_id, socket.assigns.live_action))}
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
        <.settings_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:fares} />
      </:sub_header>

      <.header>
        Fare zones
        <:subtitle>Group stops into zones, then define when a fare applies.</:subtitle>
      </.header>

      <.fares_tabs
        gtfs_version_id={@current_gtfs_version.id}
        active_tab={@live_action}
        checks_count={if @load_state == :ready, do: checks_count(@checks), else: nil}
      />

      <.loading :if={@load_state == :loading} />

      <.load_error :if={@load_state == :unavailable} />

      <%= if @load_state == :ready do %>
        <div
          :if={@live_action == :zones}
          id="fare-zones-panel"
          class="mt-2 overflow-hidden rounded-box border border-base-300 bg-base-100 md:grid md:grid-cols-[240px_minmax(0,1fr)]"
        >
          <.zone_inventory
            inventory={@inventory}
            filter={@filter}
            patch_base={zones_path(@current_gtfs_version.id)}
          />

          <section id="fare-zone-stage" class="min-w-0" aria-label="Stops workspace">
            <.stage_header
              title={stage_title(@filter, @inventory)}
              subtitle={stage_subtitle(@filter, @inventory)}
            />

            <.stop_list
              stops={@streams.stops}
              stop_page={@stop_page}
              zones={@inventory.zones}
              filter={@filter}
              q={@q}
              patch_base={zones_path(@current_gtfs_version.id)}
            />
          </section>
        </div>
        <div :if={@live_action == :rules} id="fare-rules-panel" class="mt-2"></div>
        <div :if={@live_action == :checks} id="fare-checks-panel" class="mt-2"></div>
      <% end %>
    </Layouts.app>
    """
  end

  # The stop page is only meaningful on the Zones tab, where the filter, search
  # and page come from the URL. `filter=unassigned` is its own key so a zone
  # literally named "unassigned" cannot collide with the unassigned filter.
  defp zones_params(:zones, params) do
    {stop_filter(params), normalize_query(params["q"]), parse_page(params["page"])}
  end

  defp zones_params(_action, _params), do: {:all, nil, 1}

  defp stop_filter(%{"zone" => zone}) when is_binary(zone) and zone != "", do: {:zone, zone}
  defp stop_filter(%{"filter" => "unassigned"}), do: :unassigned
  defp stop_filter(_params), do: :all

  defp normalize_query(value) when is_binary(value) and value != "", do: value
  defp normalize_query(_value), do: nil

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _other -> 1
    end
  end

  defp parse_page(_value), do: 1

  # The stop list's search and pagination both patch the Zones path, carrying the
  # filter that is currently selected. The filter's value is byte-exact and the
  # query is assembled by `URI.encode_query/1`, so a zone ID with a space or a
  # reserved character survives the round trip.
  defp zones_url(socket, query) do
    path = zones_path(socket.assigns.current_gtfs_version.id)
    query = stop_filter_query(socket.assigns.filter) ++ query

    case query do
      [] -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end

  defp stop_filter_query(:unassigned), do: [filter: "unassigned"]
  defp stop_filter_query({:zone, zone_id}), do: [zone: zone_id]
  defp stop_filter_query(:all), do: []

  defp search_query(q) when is_binary(q) and q != "", do: [q: q]
  defp search_query(_q), do: []

  defp load_workspace(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    opts = [
      filter: socket.assigns.filter,
      q: socket.assigns.q,
      page: socket.assigns.page
    ]

    case Gtfs.load_fare_workspace(organization_id, gtfs_version_id, opts) do
      {:ok, %{inventory: inventory, checks: checks, stops: stop_page}} ->
        socket
        |> assign(:inventory, inventory)
        |> assign(:checks, checks)
        |> assign(:stop_page, stop_page)
        |> stream(:stops, stop_page.entries, reset: true)
        |> assign(:load_state, :ready)
        |> resolve_zone_filter(inventory)

      {:error, :unavailable} ->
        # The previous load stays in assigns so a failed refresh never erases
        # values a later step can still render; the state decides what is shown.
        assign(socket, :load_state, :unavailable)
    end
  end

  # A `zone` value the inventory does not carry - a stale link, or a zone renamed
  # or deleted since the URL was made - shows All stops rather than a filter that
  # matches nothing. The IDs are compared byte-for-byte, never trimmed.
  #
  # The stop page in hand was read for the unknown filter, so it is read again
  # for :all: the list below the header must describe the filter the header and
  # the inventory show. Reading the inventory first is not an option, because
  # the workspace arrives in one load (and this LiveView issues no query of its
  # own).
  defp resolve_zone_filter(%{assigns: %{filter: {:zone, zone_id}}} = socket, inventory) do
    if Enum.any?(inventory.zones, &(&1.zone_id == zone_id)) do
      socket
    else
      socket |> assign(:filter, :all) |> load_workspace()
    end
  end

  defp resolve_zone_filter(socket, _inventory), do: socket

  # The stage names the stops the filter shows. A zone filter is named by the
  # zone's display name, or by its exact ID when the inventory has no record.
  defp stage_title(:all, _inventory), do: "All stops"
  defp stage_title(:unassigned, _inventory), do: "Unassigned stops"

  defp stage_title({:zone, zone_id}, inventory) do
    case Enum.find(inventory.zones, &(&1.zone_id == zone_id)) do
      nil -> zone_id
      zone -> zone.name
    end
  end

  # Counts are the filter's own: boardable stops of the version, of the zone, or
  # without a zone. A zone's count is its boardable membership, so a zone carried
  # only by stations reads 0 and "Empty zone".
  defp stage_subtitle(:all, inventory),
    do: "#{stops_count(inventory.boardable_count)} in this version"

  defp stage_subtitle(:unassigned, inventory),
    do: "#{stops_count(inventory.unassigned_count)}"

  defp stage_subtitle({:zone, zone_id}, inventory) do
    count =
      case Enum.find(inventory.zones, &(&1.zone_id == zone_id)) do
        nil -> 0
        zone -> zone.stop_count
      end

    "#{stops_count(count)} · Zone ID #{zone_id}"
  end

  defp stops_count(1), do: "1 stop"
  defp stops_count(count), do: "#{count} stops"

  # One issue per stopless referenced zone, plus one for unassigned stops. The
  # caller passes nil while the workspace load has not resolved, so the badge
  # never claims a clean version on data nobody has read yet.
  defp checks_count(%{stopless_referenced: stopless, unassigned_count: unassigned}) do
    length(stopless) + if unassigned > 0, do: 1, else: 0
  end

  defp zones_path(version_id), do: "/gtfs/#{version_id}/settings/fares"

  defp fares_path(version_id, :rules), do: "/gtfs/#{version_id}/settings/fares/rules"
  defp fares_path(version_id, :checks), do: "/gtfs/#{version_id}/settings/fares/checks"
  defp fares_path(version_id, _zones), do: zones_path(version_id)
end
