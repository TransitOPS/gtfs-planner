defmodule GtfsPlannerWeb.Gtfs.StopDetailLive do
  @moduledoc """
  LiveView for viewing a GTFS stop or station: where it is, what riders can do
  there and, for a station, what is inside it and what people found on site.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  require Logger
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopReferences
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.StopDetailComponents
  alias GtfsPlannerWeb.StationWorkspace

  import GtfsPlannerWeb.Gtfs.StopDetailComponents,
    only: [
      editing_banner: 1,
      editing_control: 1,
      editing_failure: 1,
      gtfs_fields: 1,
      inside: 1,
      journal_card: 1,
      loading: 1,
      location_card: 1,
      pathways_card: 1,
      service_card: 1,
      stop_more_actions: 1,
      usage_card: 1,
      unavailable: 1
    ]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @journal_load_key :journal_summary_load

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Stop details")
     |> assign(:user_roles, user_roles)
     |> assign(:stop_state, :loading)
     |> assign(:parent_station, nil)
     |> assign(:child_stops_state, :ready)
     |> assign(:child_stops, [])
     |> assign(:fare_zone, nil)
     |> assign(:platform_fare_zones, [])
     |> assign(:levels_state, :ready)
     |> assign(:levels, [])
     |> assign(:floors, [])
     |> assign(:inventory, "")
     |> assign(:pathways_state, :ready)
     |> assign(:pathways_expanded?, false)
     |> assign(:editing_status_state, :ready)
     |> assign(:station_editing_status, nil)
     |> assign(:editing_error, nil)
     |> assign(:pathways_empty?, true)
     |> assign(:pathways_count, 0)
     |> assign(:journal_scope, nil)
     |> assign(:journal_state, :idle)
     |> assign(:journal_loaded_once?, false)
     |> assign(:journal_refresh_error?, false)
     |> assign(:journal_open_count, 0)
     |> assign(:journal_closed_count, 0)
     |> assign(:journal_entries_empty?, true)
     |> assign(:journal_targets, %{})
     |> assign(:journal_local_times, %{})
     |> assign(:journal_now, nil)
     |> assign(:usage, nil)
     |> assign(:usage_zone_name, nil)
     |> assign(:usage_state, :loading)
     |> assign(:usage_for, nil)
     |> stream(:pathways, [])
     |> stream_configure(:journal_recent_entries,
       dom_id: fn entry -> "station-journal-summary-#{entry.id}" end
     )
     |> stream(:journal_recent_entries, [])}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
    {:noreply, socket |> assign(:stop_id, stop_id) |> load_stop()}
  end

  # "Where this stop is used" reads fourteen tables, so it runs beside the page
  # rather than in front of it: the location and service cards paint first and
  # the usage card fills in. The token names the stop it was read for, so an
  # answer that arrives after the editor moved on is dropped rather than
  # answering for the wrong stop.
  @usage_load_key :stop_usage_load

  @impl true
  def handle_async(@usage_load_key, {:ok, {:ok, {usage, zone_name}}}, socket) do
    if socket.assigns.usage_for == socket.assigns.stop_id do
      {:noreply,
       socket
       |> assign(:usage, usage)
       |> assign(:usage_zone_name, zone_name)
       |> assign(:usage_state, :ready)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@usage_load_key, _result, socket) do
    # A failed read leaves the card's own unavailable state rather than an empty
    # list: "nothing uses this stop" and "we could not read it" are different
    # answers, and only one of them is true.
    if socket.assigns.usage_for == socket.assigns.stop_id do
      {:noreply, assign(socket, :usage_state, :unavailable)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(@journal_load_key, {:ok, {:ok, payload}}, socket) do
    socket =
      socket
      |> assign(:journal_state, :ready)
      |> assign(:journal_loaded_once?, true)
      |> assign(:journal_refresh_error?, false)
      |> assign(:journal_open_count, payload.open_count)
      |> assign(:journal_closed_count, payload.closed_count)
      |> assign(:journal_entries_empty?, payload.entries == [])
      |> assign(:journal_targets, payload.targets)
      |> assign(:journal_local_times, payload.local_times)
      |> assign(:journal_now, payload.now)
      |> stream(:journal_recent_entries, payload.recent_entries, reset: true)

    {:noreply, socket}
  end

  @impl true
  def handle_async(@journal_load_key, {:ok, {:error, _exception}}, socket) do
    socket =
      if socket.assigns.journal_loaded_once? do
        socket
        |> assign(:journal_state, :error)
        |> assign(:journal_refresh_error?, true)
      else
        socket
        |> assign(:journal_state, :error)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_async(@journal_load_key, {:exit, _reason}, socket) do
    socket =
      if socket.assigns.journal_loaded_once? do
        socket
        |> assign(:journal_state, :error)
        |> assign(:journal_refresh_error?, true)
      else
        socket
        |> assign(:journal_state, :error)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:station_editing_status_updated, status}, socket) do
    {:noreply,
     socket
     |> assign(:station_editing_status, status)
     |> assign(:editing_status_state, :ready)
     |> assign(:editing_error, nil)}
  end

  @impl true
  def handle_info(
        {:station_journal_changed, station_id},
        %{assigns: %{journal_scope: %{station_id: station_id}}} = socket
      ) do
    {:noreply, load_journal_summary(socket)}
  end

  def handle_info({:station_journal_changed, _station_id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, load_stop(socket)}

  @impl true
  def handle_event("retry_child_stops", _params, socket) do
    {:noreply, load_child_stops_region(socket)}
  end

  @impl true
  def handle_event("retry_levels", _params, socket) do
    {:noreply, load_levels_region(socket)}
  end

  @impl true
  def handle_event("retry_pathways", _params, socket) do
    {:noreply, load_pathways_region(socket)}
  end

  @impl true
  def handle_event("retry_journal", _params, socket) do
    {:noreply, load_journal_summary(socket)}
  end

  @impl true
  def handle_event("retry_editing_status", _params, socket) do
    {:noreply, load_editing_status_region(socket)}
  end

  @impl true
  def handle_event("toggle_pathways", _params, socket) do
    socket = update(socket, :pathways_expanded?, &(!&1))
    {:noreply, load_pathways_region(socket)}
  end

  @impl true
  def handle_event("set_station_editing_status", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.set_station_editing_status(
           organization_id,
           gtfs_version_id,
           socket.assigns.stop,
           socket.assigns.current_user
         ) do
      {:ok, status} ->
        {:noreply,
         socket
         |> assign(:station_editing_status, status)
         |> assign(:editing_error, nil)
         |> focus_editing_button()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:editing_error, :set)
         |> focus_editing_button()}
    end
  end

  @impl true
  def handle_event("clear_station_editing_status", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.clear_station_editing_status(
           organization_id,
           gtfs_version_id,
           socket.assigns.stop.id
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:station_editing_status, nil)
         |> assign(:editing_error, nil)
         |> focus_editing_button()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:editing_error, :clear)
         |> focus_editing_button()}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    stop_id = socket.assigns[:stop_id]

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      path =
        if stop_id,
          do: ~p"/gtfs/#{version_id}/stops/#{stop_id}",
          else: "/gtfs/#{version_id}/stops"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    stop_id = socket.assigns[:stop_id]

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      path =
        if stop_id,
          do: ~p"/gtfs/#{version_id}/stops/#{stop_id}",
          else: "/gtfs/#{version_id}/stops"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  # `phx-disable-with` blurs the button while the change saves, so focus goes
  # back to it once the outcome is on the page, whether it saved or not. The
  # shared `FormErrorFocus` hook on the control's wrapper does the focusing.
  defp focus_editing_button(socket) do
    push_event(socket, "focus_scoped_target", %{id: "station-editing-status-button"})
  end

  defp load_stop(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version = socket.assigns.current_gtfs_version

    case Gtfs.fetch_catalog_stop(organization_id, gtfs_version.id, socket.assigns.stop_id) do
      {:error, :not_found} ->
        socket
        |> put_flash(
          :error,
          "We couldn't find that stop or station in #{gtfs_version.name}. " <>
            "It may have been removed or renamed in that version."
        )
        |> push_navigate(to: "/gtfs/#{gtfs_version.id}/stops")

      {:error, :unavailable} ->
        assign(socket, :stop_state, :unavailable)

      {:ok, stop} ->
        socket
        |> assign(:stop, stop)
        |> assign(:page_title, stop.stop_name || stop.stop_id)
        |> assign(:stop_state, :ready)
        |> assign(:parent_station, load_parent(organization_id, gtfs_version.id, stop))
        |> assign(:fare_zone, fare_zone(socket, stop))
        |> assign(:transfer_count, related_transfers(organization_id, gtfs_version.id, stop))
        |> start_usage_read(stop)
        |> load_regions()
    end
  end

  # The usage read answers for whatever stop is on the page now, so the assign
  # that says which stop it is for is set before the task starts rather than
  # after — otherwise a fast answer could land before the token does.
  defp start_usage_read(socket, stop) do
    socket = assign(socket, :usage_for, stop.stop_id)

    if connected?(socket) do
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id

      start_async(socket, @usage_load_key, fn ->
        {:ok,
         {StopReferences.usage(organization_id, gtfs_version_id, stop),
          usage_zone_name(organization_id, gtfs_version_id, stop)}}
      end)
    else
      socket
    end
  end

  # The fare zone the stop sits in, named by this version. A stop with no zone
  # is an ordinary answer rather than a missing one.
  defp usage_zone_name(_organization_id, _gtfs_version_id, %Stop{zone_id: nil}),
    do: nil

  defp usage_zone_name(organization_id, gtfs_version_id, %Stop{zone_id: zone_id}) do
    FareZones.zone_names(organization_id, gtfs_version_id, [zone_id])[zone_id]
  end

  # A platform, entrance or connection point names its station and inherits the
  # station's wheelchair value, so the parent is read once with the stop. A
  # parent that cannot be read leaves the ID as its name and the value unknown.
  defp load_parent(organization_id, gtfs_version_id, %Stop{parent_station: parent_id})
       when is_binary(parent_id) and parent_id != "" do
    case Gtfs.fetch_catalog_stop(organization_id, gtfs_version_id, parent_id) do
      {:ok, parent} -> parent
      {:error, _reason} -> nil
    end
  end

  defp load_parent(_organization_id, _gtfs_version_id, _stop), do: nil

  # The related-transfer count is a direct facade call, never the catalog adapter
  # (CR-15): this page's own read may be a substituted adapter, but the count is
  # the same predicate the filtered list uses (CR-4), so a station counts its
  # children exactly as the list's stop filter does.
  defp related_transfers(organization_id, gtfs_version_id, stop) do
    Gtfs.count_general_transfers(organization_id, gtfs_version_id, stop: stop.stop_id)
  end

  # Only a station has stops, levels, pathways and an editing status of its own.
  # A stop, platform or entrance has none of them, so its page reads no regions.
  defp load_regions(%{assigns: %{stop: %Stop{location_type: 1}}} = socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    if connected?(socket) do
      :ok = Gtfs.subscribe_station_editing_status(organization_id, gtfs_version_id, stop.id)
    end

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)

    socket
    |> apply_child_stops_region(regions.child_stops)
    |> apply_levels_region(regions.levels)
    |> apply_pathways_region(regions.pathways)
    |> apply_editing_status_region(regions.editing_status)
    |> setup_journal_scope()
  end

  defp load_regions(%{assigns: %{stop: stop}} = socket) do
    assign(socket, :inventory, StopDetailComponents.inventory(stop, [], []))
  end

  defp load_child_stops_region(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)
    apply_child_stops_region(socket, regions.child_stops)
  end

  defp load_levels_region(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)
    apply_levels_region(socket, regions.levels)
  end

  defp load_pathways_region(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)
    apply_pathways_region(socket, regions.pathways)
  end

  defp load_editing_status_region(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)
    apply_editing_status_region(socket, regions.editing_status)
  end

  defp apply_child_stops_region(socket, {:ok, child_stops}) do
    socket
    |> assign(:child_stops_state, :ready)
    |> assign(:child_stops, child_stops)
    |> assign(:platform_fare_zones, platform_fare_zones(socket, child_stops))
    |> assign_inside()
  end

  defp apply_child_stops_region(socket, {:error, :unavailable}) do
    socket
    |> assign(:child_stops_state, :unavailable)
    |> assign_inside()
  end

  # What is inside a station reads from two regions at once: the stops group by
  # the levels, and the header counts both. Either region may be missing, so the
  # groups are rebuilt whenever one of them changes.
  defp assign_inside(socket) do
    %{stop: stop, child_stops: child_stops, levels: levels} = socket.assigns

    child_stops =
      if socket.assigns.child_stops_state == :ready, do: child_stops, else: :unavailable

    levels = if socket.assigns.levels_state == :ready, do: levels, else: :unavailable

    socket
    |> assign(:floors, StopDetailComponents.build_floors(levels, child_stops))
    |> assign(:inventory, StopDetailComponents.inventory(stop, child_stops, levels))
  end

  # The fare zone a boardable stop itself carries, named by this version through
  # `FareZones.zone_names/3` (a zone record's name, or the ID when the zone is
  # implied by stops or fare rules rather than declared). A station's or an
  # entrance's own `zone_id` is not a fare zone on this page (CR-5), and the
  # stored bytes are shown exactly as they are kept (INV-3).
  defp fare_zone(socket, %Stop{location_type: 0, zone_id: zone_id}) when is_binary(zone_id) do
    %{zone_id: zone_id, name: Map.get(zone_names(socket, [zone_id]), zone_id, zone_id)}
  end

  defp fare_zone(_socket, _stop), do: nil

  # A station's platform fare zones are the distinct zones of the boardable stops
  # in its child-stops region: entrances, boarding areas and platforms without a
  # zone contribute nothing, and the station's own `zone_id` is never used
  # (CR-5). The IDs keep their exact stored bytes in byte order, so the entry is
  # stable between loads (INV-3).
  defp platform_fare_zones(%{assigns: %{stop: %Stop{location_type: 1}}} = socket, child_stops) do
    zone_ids =
      child_stops
      |> Enum.filter(&(&1.location_type == 0 and is_binary(&1.zone_id)))
      |> Enum.map(& &1.zone_id)
      |> Enum.uniq()
      |> Enum.sort()

    names = zone_names(socket, zone_ids)

    Enum.map(zone_ids, fn zone_id ->
      %{zone_id: zone_id, name: Map.get(names, zone_id, zone_id)}
    end)
  end

  defp platform_fare_zones(_socket, _child_stops), do: []

  defp zone_names(socket, zone_ids) do
    FareZones.zone_names(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id,
      zone_ids
    )
  end

  defp apply_levels_region(socket, {:ok, levels}) do
    socket
    |> assign(:levels_state, :ready)
    |> assign(:levels, levels)
    |> assign_inside()
  end

  defp apply_levels_region(socket, {:error, :unavailable}) do
    socket
    |> assign(:levels_state, :unavailable)
    |> assign_inside()
  end

  # Only the first few pathways stream in until the reader asks for the rest, so
  # a station with hundreds of them does not push the journal off the page.
  defp apply_pathways_region(socket, {:ok, pathways}) do
    shown =
      if socket.assigns.pathways_expanded?,
        do: pathways,
        else: Enum.take(pathways, StopDetailComponents.pathways_shown())

    socket
    |> assign(:pathways_state, :ready)
    |> assign(:pathways_empty?, pathways == [])
    |> assign(:pathways_count, length(pathways))
    |> stream(:pathways, shown, reset: true)
  end

  defp apply_pathways_region(socket, {:error, :unavailable}) do
    assign(socket, :pathways_state, :unavailable)
  end

  defp apply_editing_status_region(socket, {:ok, status}) do
    socket
    |> assign(:editing_status_state, :ready)
    |> assign(:station_editing_status, status)
  end

  defp apply_editing_status_region(socket, {:error, :unavailable}) do
    assign(socket, :editing_status_state, :unavailable)
  end

  defp setup_journal_scope(socket) do
    stop = socket.assigns.stop

    if stop.location_type == 1 do
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      actor_id = socket.assigns.current_user.id

      case Gtfs.resolve_station_journal_scope(
             organization_id,
             gtfs_version_id,
             stop.id,
             actor_id
           ) do
        {:ok, scope} ->
          socket
          |> subscribe_journal_if_connected(scope)
          |> assign(:journal_scope, scope)
          |> start_journal_load(scope)

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  defp subscribe_journal_if_connected(socket, scope) do
    if connected?(socket) do
      case journal_source().subscribe_station_journal(scope) do
        :ok ->
          socket

        {:error, reason} ->
          Logger.warning("station_journal_subscription_failed", reason: inspect(reason))
          socket
      end
    else
      socket
    end
  end

  defp start_journal_load(socket, scope) do
    source = journal_source()

    socket
    |> assign(:journal_state, :loading)
    |> start_async(@journal_load_key, fn ->
      run_journal_summary_load(source, scope)
    end)
  end

  defp run_journal_summary_load(source, scope) do
    entries = source.list_station_journal(scope, status: :all, order: :desc)

    open_count = Enum.count(entries, &is_nil(&1.closed_at))
    closed_count = Enum.count(entries, &(not is_nil(&1.closed_at)))

    recent_entries = Enum.take(entries, 3)

    targets = fetch_journal_targets(source, scope, recent_entries)
    zone = source.resolve_display_zone(scope.organization_id, scope.gtfs_version_id)
    {local_times, now} = localize_journal_times(source, recent_entries, zone)

    {:ok,
     %{
       entries: entries,
       open_count: open_count,
       closed_count: closed_count,
       recent_entries: recent_entries,
       targets: targets,
       local_times: local_times,
       now: now
     }}
  rescue
    exception -> {:error, exception}
  end

  defp load_journal_summary(socket) do
    scope = socket.assigns.journal_scope
    start_journal_load(socket, scope)
  end

  defp fetch_journal_targets(source, scope, entries) do
    target_types = MapSet.new(entries, & &1.target_type)

    child_stops =
      if MapSet.member?(target_types, "node") do
        source.list_child_stops_for_parent(
          scope.organization_id,
          scope.gtfs_version_id,
          scope.station_id
        )
      else
        []
      end

    pathways =
      if MapSet.member?(target_types, "pathway") do
        source.list_pathways_for_station(
          scope.organization_id,
          scope.gtfs_version_id,
          scope.station_id
        )
      else
        []
      end

    stop_levels =
      if MapSet.member?(target_types, "pin") do
        source.list_stop_levels_for_station(
          scope.organization_id,
          scope.gtfs_version_id,
          scope.station_id
        )
      else
        []
      end

    node_presentations =
      Map.new(child_stops, fn stop ->
        {stop.id, %{label: journal_target_label(stop.stop_name, stop.stop_id)}}
      end)

    pathway_presentations =
      Map.new(pathways, fn pathway ->
        {pathway.id, %{label: journal_target_label(pathway.pathway_id, pathway.id)}}
      end)

    pin_presentations =
      Map.new(stop_levels, fn stop_level ->
        label = journal_target_label(stop_level.level.level_name, stop_level.level.level_id)
        {stop_level.id, %{label: label}}
      end)

    node_presentations
    |> Map.merge(pathway_presentations)
    |> Map.merge(pin_presentations)
  end

  defp journal_target_label(primary, _fallback) when is_binary(primary) and primary != "",
    do: primary

  defp journal_target_label(_primary, fallback), do: to_string(fallback)

  defp localize_journal_times(source, entries, zone) do
    tagged_times =
      Enum.map(entries, fn entry -> {{entry.id, :captured}, entry.captured_at} end)

    [now | localized_times] =
      source.localize_display_times(
        [DateTime.utc_now() | Enum.map(tagged_times, &elem(&1, 1))],
        zone
      )

    local_times =
      tagged_times
      |> Enum.zip(localized_times)
      |> Map.new(fn {{{entry_id, kind}, _utc}, local} -> {{entry_id, kind}, local} end)

    {local_times, now}
  end

  defp journal_source do
    Application.get_env(:gtfs_planner, :station_journal_source, Gtfs)
  end

  # The station's own link back is the stops list; a stop inside a station names
  # its station instead. The name falls back to the ID when the station itself
  # could not be read.
  defp parent_link(%Stop{parent_station: parent_id}, parent, gtfs_version_id)
       when is_binary(parent_id) and parent_id != "" do
    %{
      name: (parent && (parent.stop_name || parent.stop_id)) || parent_id,
      navigate: ~p"/gtfs/#{gtfs_version_id}/stops/#{parent_id}"
    }
  end

  defp parent_link(_stop, _parent, _gtfs_version_id), do: nil

  # A stop can be moved on the map only when it has coordinates to move: the
  # map places a pin, and a stop with no point has nothing to drag. A station
  # is excluded because its bays are the things riders wait at, which is what
  # its "Edit on map" links to.
  defp movable?(%{stop: %Stop{location_type: 1}}), do: false

  defp movable?(%{stop: stop}) do
    present?(stop.stop_lat) and present?(stop.stop_lon)
  end

  defp movable?(_assigns), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:station?, assigns[:stop_state] == :ready and assigns.stop.location_type == 1)
      |> assign(
        :parent_link,
        assigns[:stop_state] == :ready &&
          parent_link(assigns.stop, assigns.parent_station, assigns.current_gtfs_version.id)
      )

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
        <StationWorkspace.station_header
          :if={@stop_state == :ready}
          title={@stop.stop_name || @stop.stop_id}
          stop_id={@stop.stop_id}
          gtfs_version_id={@current_gtfs_version.id}
          tabs?={@station?}
          back={@parent_link && %{label: @parent_link.name, navigate: @parent_link.navigate}}
        >
          <:meta>{@inventory}</:meta>
          <:actions>
            <%!-- A station keeps Open floorplans as its one primary; the map is
                   beside it because a station's own coordinates are not where
                   riders wait, and its bays are edited from the map. --%>
            <%= if @station? do %>
              <.editing_control
                status={@station_editing_status}
                state={@editing_status_state}
                current_user={@current_user}
              />
              <.button
                id="station-edit-on-map"
                variant="secondary"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/map?stop=#{@stop.stop_id}"}
                class="min-h-11"
              >
                <.icon name="hero-map" class="size-4" /> Edit on map
              </.button>
              <.button
                id="open-floorplans"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/#{@stop.stop_id}/diagram"}
                class="min-h-11"
              >
                <.icon name="hero-map" class="size-4" /> Open floorplans
              </.button>
            <% else %>
              <%!-- A stop's page is where an editor already is, so the two
                     operations that are not an edit open on the map with the
                     panel already asked for. --%>
              <.stop_more_actions
                id="stop-more-actions"
                gtfs_version_id={@current_gtfs_version.id}
                stop_id={@stop.stop_id}
                stop={@stop}
              />
              <.button
                id="edit-stop"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/map?stop=#{@stop.stop_id}"}
                class="min-h-11"
              >
                <.icon name="hero-pencil-square" class="size-4" /> Edit stop
              </.button>
            <% end %>
          </:actions>
        </StationWorkspace.station_header>
        <StationWorkspace.station_header
          :if={@stop_state != :ready}
          title="Stop details"
          gtfs_version_id={@current_gtfs_version.id}
          tabs?={false}
        />
      </:sub_header>

      <div id="stop-detail-page" class="ds-page pt-2">
        <%= case @stop_state do %>
          <% :unavailable -> %>
            <.unavailable />
          <% :ready -> %>
            <div
              :if={@station? and (@station_editing_status || @editing_error)}
              class="mb-6 grid gap-3"
            >
              <.editing_banner
                :if={@station_editing_status}
                status={@station_editing_status}
                current_user={@current_user}
              />
              <.editing_failure
                :if={@editing_error}
                kind={@editing_error}
                status={@station_editing_status}
              />
            </div>

            <div class="grid items-start gap-6 lg:grid-cols-2">
              <.location_card
                stop={@stop}
                parent={@parent_link}
                gtfs_version_id={@current_gtfs_version.id}
                movable?={movable?(assigns)}
              />
              <.service_card
                stop={@stop}
                access={Stop.resolve_wheelchair_boarding(@stop, @parent_station)}
                gtfs_version_id={@current_gtfs_version.id}
                fare_zone={@fare_zone}
                platform_fare_zones={@platform_fare_zones}
                child_stops_state={@child_stops_state}
                transfer_count={@transfer_count}
                levels={if @levels_state == :ready, do: @levels, else: :unavailable}
                in_station?={not is_nil(@parent_link)}
              />
            </div>

            <.usage_card
              class="mt-6"
              stop={@stop}
              usage={@usage}
              usage_state={@usage_state}
              gtfs_version_id={@current_gtfs_version.id}
              zone_name={@usage_zone_name}
            />

            <.inside
              :if={@station?}
              floors={@floors}
              child_stops_state={@child_stops_state}
              levels_state={@levels_state}
              stop={@stop}
              gtfs_version_id={@current_gtfs_version.id}
            />

            <div :if={@station?} class="mt-10 grid gap-6 lg:grid-cols-12">
              <div class={if @journal_scope, do: "lg:col-span-7", else: "lg:col-span-12"}>
                <.pathways_card
                  state={@pathways_state}
                  pathways={@streams.pathways}
                  count={@pathways_count}
                  empty?={@pathways_empty?}
                  expanded?={@pathways_expanded?}
                  stop={@stop}
                  gtfs_version_id={@current_gtfs_version.id}
                />
              </div>
              <div :if={@journal_scope} class="lg:col-span-5">
                <.journal_card
                  state={@journal_state}
                  loaded_once?={@journal_loaded_once?}
                  entries_empty?={@journal_entries_empty?}
                  open_count={@journal_open_count}
                  closed_count={@journal_closed_count}
                  entries={@streams.journal_recent_entries}
                  targets={@journal_targets}
                  local_times={@journal_local_times}
                  now={@journal_now}
                  gtfs_version_id={@current_gtfs_version.id}
                  stop_id={@stop.stop_id}
                />
              </div>
            </div>

            <.gtfs_fields stop={@stop} />
          <% _ -> %>
            <.loading />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
