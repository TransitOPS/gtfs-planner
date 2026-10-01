defmodule GtfsPlannerWeb.Gtfs.StopsMapLive do
  @moduledoc """
  The Map view: the stop editing workspace on `/gtfs/:version/stops/map`.

  The List view answers "which stops are in this feed". The Map view answers
  "where is this stop, and what else is around it", which is the question the
  List view cannot answer at all — and it is the question every edit starts
  from, because a stop's place on the street is the thing being corrected.

  The page owns the server side of the map. `GtfsPlanner.Gtfs.StopsMap.load/2`
  reads the version in a fixed number of queries, the page turns that into the
  `display_payload/2` the hook draws, and the hook reports back the only two
  things the server cannot know: which stops are inside the current view, and
  whether the street basemap is there at all.

  ## What the hook reports

  - `stop_map_ready` — the canvas exists and the payload can be drawn.
  - `stop_map_bounds` — the current view, as south/west/north/east. The browse
    panel lists the stops inside it, so panning changes the list.
  - `map_unavailable` — Leaflet or the tile proxy failed. The list, the route
    lines and coordinate entry keep working; only the basemap is gone.

  Each of these is idempotent and order-independent: the panel recomputes from
  the whole model rather than from deltas, so a report that arrives twice, or
  after the version changed, is answered from what the server holds now.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StopsMapComponents,
    only: [
      browse_panel: 1,
      browse_panel_loading: 1,
      first_use_panel: 1,
      add_panel: 1,
      map_stage: 1,
      page_header: 1,
      stop_list: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  alias GtfsPlanner.Gtfs.StopsMap
  alias GtfsPlannerWeb.Gtfs.StopsMapComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # Lines are simplified to this tolerance before they reach the browser. The
  # step-10 budget measured 2.0 m dropping 77% of the points at a 10,000-stop
  # envelope, and a point that does not move the road on screen is a point the
  # editor cannot see. The spec's own rule for the tolerance is the same one:
  # what an editor can see on the map is the tolerance applied.
  @line_tolerance_m 2.0

  # The browse panel is a working list, not a search result: this is how many
  # stops it will show before it stops being a list an editor can read. The
  # prototype uses forty; the count is here rather than in the panel because it
  # is a decision about the model, not about the markup.
  @panel_limit 40

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Stops & stations")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:map_state, :loading)
     |> assign(:panel, :browse)
     |> assign(:model, nil)
     |> assign(:map_state_reason, nil)
     |> assign(:view_bounds, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:stops_state, :loading)
     |> assign(:scope_error, nil)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if connected?(socket) do
      {:noreply, start_load(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:load_model, {:ok, {:ok, model}}, socket) do
    socket =
      socket
      |> assign(:model, model)
      |> assign(:stops_state, :ready)
      |> assign(:scope_error, nil)
      |> assign_new_panel()

    {:noreply, push_scene(socket)}
  end

  def handle_async(:load_model, {:ok, {:error, :unavailable}}, socket) do
    {:noreply,
     socket
     |> assign(:stops_state, :unavailable)
     |> assign(:scope_error, "The stops for this version could not be read.")}
  end

  def handle_async(:load_model, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:stops_state, :unavailable)
     |> assign(:scope_error, "The stops for this version could not be read.")}
  end

  @impl true
  def handle_event("stop_map_ready", _params, socket) do
    {:noreply, socket |> assign(:map_state, :ready) |> then(&push_scene/1)}
  end

  def handle_event("stop_map_bounds", params, socket) do
    case parse_bounds(params) do
      {:ok, bounds} ->
        {:noreply, assign(socket, :view_bounds, bounds)}

      :error ->
        # A malformed view is ignored rather than believed: an empty panel
        # would read as "this feed has no stops", which is a lie about data.
        {:noreply, socket}
    end
  end

  def handle_event("map_unavailable", _params, socket) do
    {:noreply, socket |> assign(:map_state, :unavailable) |> assign(:map_state_reason, nil)}
  end

  def handle_event("retry_map", _params, socket) do
    {:noreply, socket |> assign(:map_state, :loading) |> then(&push_scene/1)}
  end

  def handle_event("start_add", _params, socket), do: {:noreply, assign(socket, :panel, :add)}
  def handle_event("cancel_add", _params, socket), do: {:noreply, assign(socket, :panel, :browse)}

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
      width="wide"
    >
      <div
        id="stops-map-page"
        class="ds-page overflow-clip rounded-card border border-subtle bg-white"
      >
        <.page_header
          id="stops-map-header"
          version={@current_gtfs_version}
          stop_count={stop_count(@model)}
          station_count={station_count(@model)}
          loading={@stops_state == :loading}
        />

        <%!-- The scope error is above the workspace rather than inside it: the
               workspace is the map and the panel, and a message between them
               would shrink both. --%>
        <div :if={@scope_error} id="stops-map-unavailable-read" class="px-4 pt-4 sm:px-5">
          <.message kind="error" title={@scope_error}>
            The street map needs the version's stops. Reload the page to try again.
          </.message>
        </div>

        <div
          id="stops-map-workspace"
          class="grid min-h-0 lg:h-[calc(100vh-13rem)] lg:grid-cols-[minmax(0,1fr)_408px]"
        >
          <.map_stage
            id="stops-map-stage"
            map_state={@map_state}
            caption={map_caption(@panel)}
          />

          <%= if @panel == :add do %>
            <.add_panel id="stops-map-add-panel" />
          <% else %>
            <.browse_panel
              id="stops-map-panel"
              title={panel_title(assigns)}
              subtitle={panel_subtitle(assigns)}
            >
              <%= if @stops_state == :loading do %>
                <div id="stops-map-panel-loading" role="status">
                  <span class="sr-only">Loading stops…</span>
                  <.browse_panel_loading id="stops-map-skeleton" />
                </div>
              <% else %>
                <%= if @model == nil or @model.stops == [] do %>
                  <.first_use_panel id="stops-map-first-use" version={@current_gtfs_version} />
                <% else %>
                  <.stop_list id="stops-map-list" stops={panel_rows(assigns)} />
                <% end %>
              <% end %>
            </.browse_panel>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The read runs in the LiveView process so the panel and the map never wait on
  # it: the page paints its chrome and the loading states first, and the list
  # arrives when the read does.
  defp start_load(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    start_async(socket, :load_model, fn -> StopsMap.load(organization_id, gtfs_version_id) end)
  end

  # A version with no stops opens the first-use panel rather than an empty list.
  # An empty list would read as a broken read; this reads as a version nobody has
  # added stops to yet.
  defp assign_new_panel(socket) do
    case socket.assigns.model do
      %{stops: []} -> assign(socket, :panel, :first_use)
      _model -> socket
    end
  end

  defp push_scene(socket) do
    case socket.assigns.model do
      nil ->
        socket

      model ->
        push_event(socket, "stop_map:scene", %{
          payload:
            StopsMap.display_payload(model, @line_tolerance_m)
            |> Map.put(:tolerance_m, @line_tolerance_m)
        })
    end
  end

  # The rows the panel lists: the stops inside the view the hook last reported,
  # or every located stop before any view has been reported. Sorting puts
  # stations first (an editor looking for a stop looks for its station), then
  # orders by name so the list does not jump as the map pans.
  defp panel_rows(assigns) do
    stops =
      case assigns.view_bounds do
        nil -> located_stops(assigns.model)
        bounds -> Enum.filter(located_stops(assigns.model), &inside?(&1.point, bounds))
      end

    stops
    |> Enum.sort_by(&{&1.location_type != 1, &1.name || &1.stop_id})
    |> Enum.take(@panel_limit)
    |> Enum.map(&row(assigns.model, &1))
  end

  defp row(model, stop) do
    %{
      id: stop.stop_id,
      stop_id: stop.stop_id,
      name: stop.name || stop.stop_id,
      desc: stop.desc,
      code: stop.code,
      location_type: stop.location_type,
      served?: stop.served?,
      bays: bay_count(model, stop),
      routes: stop_routes(model, stop)
    }
  end

  defp located_stops(nil), do: []

  defp located_stops(model), do: Enum.filter(model.stops, & &1.point)

  # A stop's routes are the routes of the patterns that visit it. The model
  # carries the patterns per stop and the route per pattern, so this is a
  # lookup rather than a second read.
  defp stop_routes(model, stop) do
    route_ids =
      model.lines
      |> Enum.filter(&(&1.pattern_id in stop.pattern_ids))
      |> Enum.map(& &1.route_id)
      |> Enum.uniq()

    route_ids
    |> Enum.map(&Map.get(model.routes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(&1.short_name || &1.long_name || &1.route_id))
  end

  # A station's bays are the stops that name it as their parent. The model
  # carries each stop's `parent_station`, so this is a count over what is loaded
  # rather than a read.
  defp bay_count(model, stop) do
    model.stops
    |> Enum.count(&(&1.parent_station == stop.stop_id))
  end

  defp inside?(nil, _bounds), do: false

  defp inside?({lon, lat}, {south, west, north, east}) do
    lat >= south and lat <= north and lon >= west and lon <= east
  end

  defp stop_count(nil), do: 0
  defp stop_count(%{stops: stops}), do: Enum.count(stops, &(&1.location_type == 0))

  defp station_count(nil), do: 0
  defp station_count(%{stops: stops}), do: Enum.count(stops, &(&1.location_type == 1))

  defp panel_title(%{panel: :first_use}), do: "No stops in this version yet"

  defp panel_title(%{stops_state: :unavailable}), do: "Stops could not load"
  defp panel_title(_assigns), do: "Stops in this area"

  defp panel_subtitle(%{stops_state: :loading}), do: "Reading this version’s stops…"
  defp panel_subtitle(%{stops_state: :unavailable}), do: "The list is kept."

  defp panel_subtitle(%{panel: :first_use}),
    do: "This version was started from scratch."

  defp panel_subtitle(%{view_bounds: nil} = assigns) do
    # The same wording the header uses, so the header and the panel cannot
    # disagree about how many stops the version has: stations are counted
    # separately in both, and only the listed rows are counted here.
    listed = panel_rows(assigns)

    StopsMapComponents.scope_note(%{
      stop_count: count_type(listed, 0),
      station_count: count_type(listed, 1),
      loading: false,
      version: assigns.current_gtfs_version
    })
  end

  defp panel_subtitle(%{view_bounds: _bounds} = assigns) do
    listed = panel_rows(assigns) |> length()

    "#{listed} on the map · pan or zoom to change the list"
  end

  defp count_type(rows, location_type) do
    Enum.count(rows, &(&1.location_type == location_type))
  end

  defp map_caption(:add),
    do: %{
      title: "Click the curb where riders wait",
      text: "Zoom in until you can see the street edge."
    }

  defp map_caption(_panel), do: nil

  # Bounds arrive from the hook as JSON numbers. A view that cannot be read is
  # rejected rather than clamped: a clamped box would quietly list the wrong
  # stops.
  defp parse_bounds(%{"south" => south, "west" => west, "north" => north, "east" => east}) do
    with {:ok, south} <- number(south),
         {:ok, west} <- number(west),
         {:ok, north} <- number(north),
         {:ok, east} <- number(east),
         true <- south <= north and west <= east do
      {:ok, {south, west, north, east}}
    else
      _ -> :error
    end
  end

  defp parse_bounds(_params), do: :error

  defp number(value) when is_number(value), do: {:ok, value * 1.0}

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp number(_value), do: :error
end
