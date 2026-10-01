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
  - `place` — the hook reported a point the editor chose, by click or by Enter
    on the canvas. The point becomes the draft's position and is echoed back.
  - `pin_moved` — the editor dragged or nudged the pin. One report per change,
    and the point is echoed back the same way.

  Each of these is idempotent and order-independent: the panel recomputes from
  the whole model rather than from deltas, so a report that arrives twice, or
  after the version changed, is answered from what the server holds now.

  ## The draft position is the server's

  The hook moves its pin the instant a pointer or a key moves it, because a
  drag that waits for a round trip lags the hand. What it moved to is the
  server's to answer: `place` and `pin_moved` both write `placement`, and the
  pin the browser draws is the one `push_map_mode/1` last echoed. A refused
  write therefore has nothing behind it — the next echo is the position the
  server still holds, and nothing was saved to leave behind (INV-4).
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
      search_field: 1,
      search_results: 1,
      stop_list: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Gtfs.StopsMap
  alias GtfsPlannerWeb.Gtfs.StopsMapComponents
  require Logger

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

  # A search is an answer, not a list to read: the browse panel's forty rows say
  # "there is more here" and a result list does not. Six stops and four places
  # are the counts the prototype shows, and they are chosen so a screenful of
  # them still fits at 390 px.
  @search_stop_limit 6
  @search_place_limit 4

  # The form name the search field's params arrive under.
  @search_as :search

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
     |> assign(:placement, nil)
     |> assign(:scope_error, nil)
     |> assign_search("", [], [], false)}
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

  def handle_event("start_add", _params, socket),
    do: {:noreply, socket |> assign(:panel, :add) |> assign(:placement, nil) |> push_map_mode()}

  def handle_event("cancel_add", _params, socket),
    do:
      {:noreply, socket |> assign(:panel, :browse) |> assign(:placement, nil) |> push_map_mode()}

  # A point the editor chose on the map. It is the draft's position and nothing
  # else: nothing is written until the add flow is submitted, so a placement
  # that is abandoned leaves no row behind.
  def handle_event("place", params, socket),
    do: {:noreply, assign_placement(socket, params)}

  def handle_event("pin_moved", params, socket),
    do: {:noreply, assign_placement(socket, params)}

  # Search answers two questions at once, and the field is one field: "is this
  # stop in my feed" (this version's own rows) and "where do I put the new one"
  # (the address service). They are searched together and rendered apart, so an
  # editor never has to choose a mode to find out whether a stop exists.
  def handle_event("search", %{"search" => %{"query" => raw}}, socket),
    do: {:noreply, run_search(socket, raw)}

  # A search field that arrives without a query is a search for nothing, which
  # is the same as no search: the panel returns to the list it had.
  def handle_event("search", _params, socket),
    do:
      {:noreply,
       assign_search(
         socket,
         socket.assigns.search_query,
         socket.assigns.search_stops,
         socket.assigns.search_places,
         socket.assigns.search_unavailable?
       )}

  # Choosing a stop from the results selects it. The panel's heading becomes
  # that stop, which is the selection an editor can see before the edit panel
  # (step 30) takes the heading over.
  def handle_event("select_stop", %{"stop_id" => stop_id}, socket) do
    if Enum.any?(socket.assigns.search_stops, &(&1.stop_id == stop_id)) do
      {:noreply, assign(socket, :selected_stop_id, stop_id)}
    else
      # A result id that is not one this search produced is refused rather than
      # looked up: the panel only shows what the search returned, so accepting
      # an id it never showed would select a stop the editor cannot see.
      {:noreply, socket}
    end
  end

  def handle_event("select_stop", _params, socket), do: {:noreply, socket}

  # Choosing a place is a placement. It writes the same `placement` a click on
  # the map writes, so the pin, the caption and the map's mode are unchanged by
  # how the editor got there — one draft, one position.
  def handle_event("choose_place", params, socket),
    do: {:noreply, assign_placement(socket, params)}

  # --- search ----------------------------------------------------------------

  defp run_search(socket, raw) do
    case String.trim(raw || "") do
      "" ->
        assign_search(socket, "", [], [], false)

      query ->
        stops = matching_stop_rows(socket.assigns, query)

        case Geocoding.autocomplete(query, bias: search_bias(socket.assigns.model)) do
          {:ok, places} ->
            assign_search(socket, query, stops, Enum.take(places, @search_place_limit), false)

          # A query shorter than the address service's minimum is not a failure,
          # it is a query it has not answered yet. It reads as "nothing yet",
          # which is what it is.
          {:error, :text_too_short} ->
            assign_search(socket, query, stops, [], false)

          {:error, reason} ->
            Logger.error("Geocoding autocomplete failed: #{inspect(reason)}")
            assign_search(socket, query, stops, [], true)
        end
    end
  end

  # The stop half of a search runs against this version's own rows, so it keeps
  # working when the address service does not — which is the whole reason the
  # two halves are separate in the panel.
  defp matching_stop_rows(%{panel: :add}, _query), do: []

  defp matching_stop_rows(assigns, query) do
    needle = String.downcase(query)

    assigns.model
    |> located_stops()
    |> Enum.filter(fn stop ->
      String.contains?(String.downcase(stop.name || ""), needle) or
        String.downcase(stop.stop_id) == needle
    end)
    |> Enum.sort_by(&{&1.location_type != 1, &1.name || &1.stop_id})
    |> Enum.take(@search_stop_limit)
    |> Enum.map(&row(assigns.model, &1))
  end

  # Address results are ranked near the stops this version already has, because
  # an editor is placing a stop in the feed they are editing and not looking
  # for an address anywhere in the world. The bias is the midpoint of the
  # loaded stops' bounds as `{lon, lat}`, the order the geocoding adapter's
  # `:bias` takes. A version with no located stop has no midpoint, and an
  # unranked search beats a fabricated one.
  defp search_bias(nil), do: nil

  defp search_bias(model) do
    points = for point <- Enum.map(model.stops, & &1.point), point, do: point

    case points do
      [] ->
        nil

      points ->
        {midpoint(points, 0), midpoint(points, 1)}
    end
  end

  # `StopsMap` points are `{lon, lat}` tuples.
  defp midpoint(points, axis) do
    values = Enum.map(points, &elem(&1, axis))
    (Enum.min(values) + Enum.max(values)) / 2
  end

  # One place the search's four assigns live, so every exit from a search —
  # cleared, answered, too short, failed — leaves the form holding what the
  # editor typed rather than what the last render happened to know.
  defp assign_search(socket, query, stops, places, unavailable?) do
    socket
    |> assign(:search_query, query)
    |> assign(:search_form, to_form(%{"query" => query}, as: @search_as))
    |> assign(:search_stops, stops)
    |> assign(:search_places, places)
    |> assign(:search_unavailable?, unavailable?)
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
            caption={map_caption(assigns)}
          />

          <%= if @panel == :add do %>
            <.add_panel
              id="stops-map-add-panel"
              form={@search_form}
              query={@search_query}
              places={@search_places}
              unavailable?={@search_unavailable?}
            />
          <% else %>
            <.browse_panel
              id="stops-map-panel"
              title={panel_title(assigns)}
              subtitle={panel_subtitle(assigns)}
            >
              <.search_field
                id="stops-map-search"
                form={@search_form}
                label="Find a stop, street or place"
                placeholder="Name, stop ID or cross street"
              />

              <%= if @stops_state == :loading do %>
                <div id="stops-map-panel-loading" role="status">
                  <span class="sr-only">Loading stops&hellip;</span>
                  <.browse_panel_loading id="stops-map-skeleton" />
                </div>
              <% else %>
                <%= if @model == nil or @model.stops == [] do %>
                  <.first_use_panel id="stops-map-first-use" version={@current_gtfs_version} />
                <% else %>
                  <%!-- A search replaces the list rather than sitting above it:
                        forty rows under a result set is a page an editor has to
                        scroll past to see what they searched for. --%>
                  <%= if @search_query == "" do %>
                    <.stop_list id="stops-map-list" stops={panel_rows(assigns)} />
                  <% else %>
                    <.search_results
                      id="stops-map-search-results"
                      query={@search_query}
                      stops={@search_stops}
                      places={@search_places}
                      unavailable?={@search_unavailable?}
                    />
                  <% end %>
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

  # A chosen search result takes over the panel's heading. Step 30 replaces
  # this with the edit panel's own heading; until then the selection has to be
  # visible somewhere, and the heading is the one place the editor is already
  # looking.
  defp panel_title(%{selected_stop_id: stop_id} = assigns) when is_binary(stop_id) do
    case selected_row(assigns, stop_id) do
      %{name: name} -> name
      nil -> panel_title(%{assigns | selected_stop_id: nil})
    end
  end

  defp panel_title(%{panel: :first_use}), do: "No stops in this version yet"

  defp panel_title(%{stops_state: :unavailable}), do: "Stops could not load"
  defp panel_title(_assigns), do: "Stops in this area"

  defp panel_subtitle(%{selected_stop_id: stop_id} = assigns) when is_binary(stop_id) do
    case selected_row(assigns, stop_id) do
      nil -> panel_subtitle(%{assigns | selected_stop_id: nil})
      row -> StopsMapComponents.selection_note(row)
    end
  end

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

  # The row for a chosen result, rebuilt from the loaded model rather than
  # remembered: a stop that was removed while the panel was open has no row,
  # and a heading for a stop this version no longer holds would be a lie.
  defp selected_row(%{model: nil}, _stop_id), do: nil

  defp selected_row(assigns, stop_id) do
    case Enum.find(located_stops(assigns.model), &(&1.stop_id == stop_id)) do
      nil -> nil
      stop -> row(assigns.model, stop)
    end
  end

  # The mode, the pin and the ghost are the hook's half of a placement, and the
  # server decides all three: a point only becomes the pin once the server has
  # read it, and the pin only moves when the server echoes a new point. Add mode
  # is the panel asking for a place, so it ends as soon as there is one.
  defp push_map_mode(socket) do
    # `push_event/3` answers the socket with the push on it, and that answer is
    # the socket: dropping it drops the push, silently, and the map goes on
    # believing it is browsing while the panel is asking for a place.
    if connected?(socket) do
      push_event(socket, "stop_map:mode", mode_payload(socket.assigns))
    else
      socket
    end
  end

  # Add mode is the panel asking for a place, so it ends as soon as there is
  # one: a placed stop is adjusted by its pin, not by placing it again.
  defp mode_payload(%{placement: {lat, lon}}),
    do: %{mode: :browse, pin: %{lat: lat, lon: lon, label: "New stop"}, ghost: nil}

  defp mode_payload(assigns) do
    mode = if assigns.panel == :add, do: :add, else: :browse

    # `ghost` is the position a stop already has in the database, which no
    # placement has yet.
    %{mode: mode, pin: nil, ghost: nil}
  end

  # A point that cannot be read is refused rather than clamped. A lat/lon pair
  # is a position on the Earth, and "north" is not one; saving a clamped pair
  # would put a stop in a place nobody chose.
  defp assign_placement(socket, params) do
    case parse_point(params) do
      {:ok, {lat, lon}} ->
        socket
        |> assign(:placement, {lat, lon})
        |> push_map_mode()

      :error ->
        socket
    end
  end

  defp parse_point(%{"lat" => lat, "lon" => lon}) do
    with {:ok, lat} <- number(lat),
         {:ok, lon} <- number(lon),
         true <- abs(lat) <= 90.0,
         true <- abs(lon) <= 180.0 do
      {:ok, {lat, lon}}
    else
      _ -> :error
    end
  end

  defp parse_point(_params), do: :error

  defp map_caption(%{panel: :add, placement: nil}) do
    %{
      title: "Click the curb where riders wait",
      text:
        "Zoom in until you can see the street edge. Press Enter to place it at the crosshair. Escape cancels."
    }
  end

  defp map_caption(%{panel: :add, placement: {_lat, _lon}}) do
    %{
      title: "Drag the pin to adjust",
      text: "Or focus the pin and use the arrow keys: about 3 ft a press, 30 ft with Shift."
    }
  end

  defp map_caption(_assigns), do: nil

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
