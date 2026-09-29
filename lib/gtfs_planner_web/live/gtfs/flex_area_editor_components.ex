defmodule GtfsPlannerWeb.Gtfs.FlexAreaEditorComponents do
  @moduledoc """
  The area editor's panels (AC-10 to AC-14), rendered inside
  `GtfsPlannerWeb.Gtfs.FlexServiceLive`'s `:area` action.

  Each panel is one way to set the candidate area: official Census town limits
  (`Boundaries.places_near/1` over the version's stop extent, or the
  name-and-state search when the version has no stops), a distance from the
  version's routes (`Flex.Geometry.route_buffer/4`), drawing (step 25 owns the
  interaction) and a GeoJSON file (`Flex.Geometry.import_features/1`). The panel
  beside them is the candidate's own block: the name riders see, where the
  boundary came from, what is inside it, the overlap with other active services
  and the comparison with the saved area.

  The copy and the option order are the reference's
  (`references/flex-service-area-prototype.html`, states `choose`, `town`,
  `census-unavailable`, `routes`, `import`, `import-pick`, `import-swapped`,
  `import-lines`); the SVG basemap, the fake place list and the prototype's
  client-side simplification stay out (CR-9). The map is the shared
  `FlexAreaMap` hook (step 20), read-only until step 25.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.Gtfs.FlexComponents,
    only: [census_layer_label: 1, distance_metres: 1, join_help: 1, km2_text: 1]

  alias GtfsPlanner.Boundaries

  @doc """
  The editor's page header: the way back to the service, the editor's title, and
  the two actions that leave the editor — Cancel, and Use this area, which stays
  disabled with its reason while the candidate is not usable yet.
  """
  attr :service, :any, required: true
  attr :title, :string, required: true
  attr :use_reason, :string, default: nil

  def editor_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-4 pb-3 pt-3">
      <div class="min-w-0">
        <button
          type="button"
          id="area-back"
          phx-click="cancel_area"
          class="inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action hover:underline"
        >
          <.icon name="hero-chevron-left" class="size-4" /> {@service.name}
        </button>
        <h1
          id="area-title"
          tabindex="-1"
          class="text-[32px] font-bold leading-9 text-strong outline-none"
        >
          {@title}
        </h1>
      </div>

      <div class="flex flex-wrap items-center gap-3">
        <p id="area-subtitle" class="max-w-[34ch] text-right text-[13px] text-muted">
          The service keeps this area when you save it.
        </p>
        <button
          type="button"
          id="cancel-area"
          phx-click="cancel_area"
          class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
        >
          Cancel
        </button>
        <button
          type="button"
          id="use-area"
          phx-click="use_area"
          disabled={@use_reason != nil}
          aria-describedby={@use_reason && "use-area-reason"}
          class="inline-flex min-h-11 items-center rounded-control bg-action px-4 text-sm font-[650] text-white hover:bg-action-hover disabled:cursor-not-allowed disabled:bg-canvas disabled:text-muted"
        >
          Use this area
        </button>
        <p :if={@use_reason} id="use-area-reason" class="text-[13px] font-[650] text-warning-fg">
          {@use_reason}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The four ways to set an area, in the reference's order: official Census town
  limits first, then distance from routes, drawing and a GeoJSON file.
  """
  attr :error, :string, default: nil

  def choose_panel(assigns) do
    ~H"""
    <div>
      <.panel_heading>How do you want to set the area?</.panel_heading>
      <p class="mt-1 text-[13px] text-muted">
        You can adjust the boundary afterwards whichever way you start.
      </p>

      <p :if={@error} id="area-error" role="alert" class="mt-2 text-sm font-[650] text-error-fg">
        {@error}
      </p>

      <div class="mt-3 grid gap-2">
        <.option
          id="area-mode-town"
          source="town"
          icon="hero-building-office-2"
          title="Town or city limits"
          help="Official Census boundaries: cities, townships and counties. Good for a dial-a-ride that serves a whole town."
        />
        <.option
          id="area-mode-routes"
          source="routes"
          icon="hero-map"
          title="Distance from routes"
          help="Everything within a set distance of fixed routes, for general-public service."
        />
        <.option
          id="area-mode-draw"
          source="draw"
          icon="hero-pencil"
          title="Draw on the map"
          help="Click to place points around the area."
        />
        <.option
          id="area-mode-import"
          source="import"
          icon="hero-arrow-up-tray"
          title="Import a file"
          help="GeoJSON from your on-demand provider or county GIS."
        />
      </div>
    </div>
    """
  end

  @doc """
  Town or city limits: the places the Census service answers for the version's
  stop extent (or the name-and-state search when the version has no stops), the
  CDP label, and the unavailable state that names three next actions and changes
  nothing.

  The place the editor picked stays the list's own selected radio (`pick`), the
  way the reference's list marks the chosen town; without it a re-render of the
  panel would leave the list with nothing selected.
  """
  attr :places, :list, required: true
  attr :state, :atom, required: true
  attr :slow?, :boolean, default: false
  attr :no_stops?, :boolean, required: true
  attr :search_name, :string, default: ""
  attr :search_state, :string, default: ""
  attr :pick, :string, default: nil
  attr :error, :string, default: nil

  def census_panel(assigns) do
    assigns = assign(assigns, :states, Boundaries.states())

    ~H"""
    <div>
      <.back_to_choose />
      <.panel_heading>Town or city limits</.panel_heading>

      <div
        :if={@state == :unavailable}
        id="census-unavailable"
        role="alert"
        class="mt-3 rounded-card border border-warning-line bg-warning-bg px-3 py-3 text-sm text-warning-fg"
      >
        <p class="font-[650]">Census boundaries unavailable</p>
        <p class="mt-1">
          The Census Bureau’s boundary service didn’t answer. Areas you’ve already saved aren’t affected. Try again later, import a boundary file from your county GIS, or draw the area.
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <button
            type="button"
            id="census-retry"
            phx-click="census_retry"
            class="inline-flex min-h-11 items-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Try again
          </button>
          <button
            type="button"
            id="census-draw"
            phx-click="choose_source"
            phx-value-source="draw"
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas"
          >
            Draw on the map
          </button>
          <button
            type="button"
            id="census-import"
            phx-click="choose_source"
            phx-value-source="import"
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas"
          >
            Import a file
          </button>
        </div>
      </div>

      <p
        :if={@state == :loading and @slow?}
        id="census-loading"
        role="status"
        class="mt-3 flex items-center gap-2 text-sm text-muted"
      >
        <span class="loading loading-spinner loading-sm" aria-hidden="true"></span>
        Asking the Census Bureau…
      </p>

      <form
        :if={@no_stops? and @state != :unavailable}
        id="census-search-form"
        phx-submit="census_search"
        class="mt-3 grid gap-3 sm:grid-cols-2"
      >
        <label class="block min-w-0">
          <span class="text-sm font-[650] text-strong">Place name</span>
          <input
            type="text"
            id="census-search-name"
            name="place_name"
            value={@search_name}
            autocomplete="off"
            class="input input-lg mt-1 w-full min-w-0"
          />
        </label>
        <label class="block min-w-0">
          <span class="text-sm font-[650] text-strong">State</span>
          <select
            id="census-search-state"
            name="state_fips"
            class="select select-lg mt-1 w-full min-w-0"
          >
            <option value="">Choose a state</option>
            <option :for={{name, code} <- @states} value={code} selected={code == @search_state}>
              {name}
            </option>
          </select>
        </label>
        <div class="sm:col-span-2">
          <.button id="census-search-submit" type="submit" class="min-h-11">
            Search the Census Bureau
          </.button>
        </div>
      </form>

      <p :if={@error} id="census-error" class="mt-3 text-sm font-[650] text-error-fg">{@error}</p>

      <form :if={@places != []} id="census-place-form" phx-change="census_pick">
        <fieldset class="mt-3">
          <legend class="text-sm font-[650] text-strong">Place</legend>
          <div class="mt-1 grid gap-2">
            <label
              :for={place <- @places}
              id={"census-place-#{place.geoid}"}
              class="flex cursor-pointer items-start gap-3 rounded-card border border-subtle px-3 py-2.5 hover:bg-canvas"
            >
              <input
                type="radio"
                name="geoid"
                value={place.geoid}
                checked={@pick == place.geoid}
                class="mt-1 size-4 shrink-0 accent-[var(--color-action)]"
              />
              <span class="min-w-0">
                <span class="block text-sm font-[650] text-strong">
                  {place.name}
                  <span class="font-normal text-muted">{layer_kind(place)}</span>
                </span>
                <span class="block text-[13px] tabular-nums text-muted">
                  {census_place_meta(place)}
                </span>
              </span>
            </label>
          </div>
        </fieldset>
      </form>

      <p :if={@no_stops? and @state == :idle} class="mt-3 text-[13px] text-muted">
        This version has no stops with coordinates, so search for the place by name and state.
      </p>

      <p
        :if={@no_stops? and @state == :ok and @places == []}
        id="census-search-empty"
        class="mt-3 text-sm text-muted"
      >
        No place matches that name in that state. Check the spelling, or try the county subdivision or county instead.
      </p>

      <p class="mt-3 text-[13px] text-muted">
        Source: U.S. Census Bureau, boundaries as of January 1, 2026 (public domain). Also offers townships and counties; census-designated places are marked as not legal boundaries.
      </p>
    </div>
    """
  end

  @doc """
  Distance from routes: the version's route checkboxes, the distance, and the
  note that the area follows the current routes.
  """
  attr :routes, :list, required: true
  attr :route_ids, :list, required: true
  attr :distance, :integer, required: true
  attr :distance_choices, :list, required: true
  attr :error, :string, default: nil

  def routes_panel(assigns) do
    ~H"""
    <div>
      <.back_to_choose />
      <.panel_heading>Distance from routes</.panel_heading>

      <form id="area-routes-form" phx-change="route_buffer" class="mt-3">
        <fieldset>
          <legend class="text-sm font-[650] text-strong">Routes</legend>
          <div class="mt-1 grid gap-1">
            <label
              :for={route <- @routes}
              id={"area-route-#{route.id}"}
              class="flex min-h-11 cursor-pointer items-center gap-3"
            >
              <input
                type="checkbox"
                name="route_ids[]"
                value={route.id}
                checked={route.id in @route_ids}
                class="size-4 shrink-0 accent-[var(--color-action)]"
              />
              <span
                class="inline-flex min-w-9 justify-center rounded-badge px-1.5 text-[13px] font-bold text-white"
                style={"background-color: #{route.color || "#0d737d"}"}
              >
                {route.short_name || route.id}
              </span>
              <span class="text-sm">{route.long_name || route.name}</span>
            </label>
          </div>
        </fieldset>

        <label class="mt-3 block">
          <span class="text-sm font-[650] text-strong">Distance</span>
          <select id="area-distance" name="distance_m" class="select select-lg mt-1 w-full min-w-0">
            <option
              :for={{label, metres} <- @distance_choices}
              value={metres}
              selected={metres == @distance}
            >
              {label}
            </option>
          </select>
        </label>
      </form>

      <p class="mt-1 text-[13px] text-muted">
        Measured in a straight line each side of the route. Water is left out.
      </p>

      <p id="area-follows-routes" class="mt-3 rounded-card bg-canvas px-3 py-2 text-[13px] text-muted">
        Follows the current routes. The area updates when these routes change.
      </p>

      <p :if={@error} id="area-route-error" class="mt-2 text-sm font-[650] text-error-fg">
        {@error}
      </p>

      <p class="mt-3 text-[13px] text-muted">
        For general-public service. ADA paratransit areas come later, as a layer generated from the timetable that changes by time of day.
      </p>
    </div>
    """
  end

  @doc """
  Import a file: the GeoJSON chooser, the file's polygon features to choose
  between, and the three file problems the editor reports instead — lines, a
  swapped coordinate order and an unreadable file.
  """
  attr :upload, :any, required: true
  attr :upload_state, :atom, required: true
  attr :upload_error, :string, default: nil
  attr :file_name, :string, default: nil
  attr :file_error, :atom, default: nil
  attr :features, :list, required: true
  attr :pick, :integer, default: nil
  attr :name_field, :string, default: nil

  def import_panel(assigns) do
    ~H"""
    <div>
      <.back_to_choose />
      <.panel_heading>Import a file</.panel_heading>

      <.form
        for={%{}}
        id="area-upload-form"
        phx-change="validate_upload"
        phx-submit="validate_upload"
        class="mt-3"
      >
        <.upload_field
          id="area-upload"
          upload={@upload}
          label="GeoJSON file"
          help="GeoJSON (.geojson or .json), up to 5 MB. The file stays on this computer."
          action_label="Choose a GeoJSON file or drag and drop"
          cancel_event="cancel_area_upload"
          state={@upload_state}
          error={@upload_error}
        />
      </.form>

      <.callout
        :if={@file_error == :lines}
        id="area-file-lines"
        kind="error"
        title="This file has lines, not areas"
      >
        A flex area must be a closed shape. If this is a route, use Distance from routes instead.
        <div class="mt-2">
          <button
            type="button"
            id="area-file-routes"
            phx-click="choose_source"
            phx-value-source="routes"
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas"
          >
            Use distance from routes
          </button>
        </div>
      </.callout>

      <.callout
        :if={@file_error == :swapped}
        id="area-file-swapped"
        kind="error"
        title="This file lists latitude and longitude the wrong way round"
      >
        GeoJSON lists longitude first; this file seems to list latitude first.
        <div class="mt-2">
          <button
            type="button"
            id="area-file-swap"
            phx-click="swap_coordinates"
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas"
          >
            Swap and preview
          </button>
        </div>
      </.callout>

      <.callout
        :if={@file_error == :unreadable}
        id="area-file-unreadable"
        kind="error"
        title="This file could not be read as GeoJSON"
      >
        Choose a GeoJSON document, or export one from your provider or county GIS.
      </.callout>

      <form :if={@features != []} id="area-feature-form" phx-change="pick_feature" class="mt-3">
        <fieldset>
          <legend class="text-sm font-[650] text-strong">
            {@file_name} · {length(@features)} {plural_word(length(@features), "area")}
          </legend>
          <div class="mt-1 grid gap-2">
            <label
              :for={feature <- @features}
              id={"area-feature-#{feature.index}"}
              class="flex cursor-pointer items-start gap-3 rounded-card border border-subtle px-3 py-2.5 hover:bg-canvas"
            >
              <input
                type="radio"
                name="feature"
                value={feature.index}
                checked={@pick == feature.index}
                class="mt-1 size-4 shrink-0 accent-[var(--color-action)]"
              />
              <span class="min-w-0">
                <span class="block text-sm font-[650] text-strong">{feature.name}</span>
                <span :if={@name_field} class="block text-[13px] text-muted">
                  Named by the file’s “{@name_field}” field
                </span>
              </span>
            </label>
          </div>
        </fieldset>
      </form>
    </div>
    """
  end

  @doc """
  Drawing on the map: the reference's own instructions. The tools themselves are
  the map's toolbar beside it (step 25), so this panel says what the map does
  rather than pretending to edit.
  """
  attr :error, :string, default: nil

  def draw_panel(assigns) do
    ~H"""
    <div>
      <.back_to_choose />
      <.panel_heading>Draw on the map</.panel_heading>

      <ol class="mt-2 grid gap-1 pl-5 text-sm [list-style:decimal]">
        <li>Click the map to place points around the area.</li>
        <li>Click the first point, or press Enter, to finish.</li>
        <li>Backspace removes the last point. Escape stops drawing.</li>
      </ol>

      <p :if={@error} id="area-error" role="alert" class="mt-2 text-sm font-[650] text-error-fg">
        {@error}
      </p>

      <.callout id="area-draw-tools" kind="info" title="Editing points" class="mt-3">
        Drag a point to move it, click the boundary to add one, Delete to remove the selected point, and Undo or Redo for every change. Arrow keys move the selected point 20 m (100 m with Shift). Previous point and Next point walk the boundary. Simplify runs on the server and keeps the boundary valid.
      </.callout>
    </div>
    """
  end

  @doc """
  The candidate's own block: the name riders see, where the boundary came from,
  what is inside it (AC-14), the overlap with another active service as
  information, and the comparison with the saved area when something changed.
  """
  attr :candidate, :any, default: nil
  attr :name_form, :any, required: true
  attr :name_error, :string, default: nil
  attr :stats, :any, default: nil
  attr :overlaps, :list, required: true
  attr :compare, :any, default: nil
  attr :stop_choices, :list, required: true

  def stats_panel(assigns) do
    assigns =
      assigns
      |> assign(:stop_names, Map.new(assigns.stop_choices, fn {name, id} -> {id, name} end))
      |> assign(:source_line, source_line(assigns.candidate))

    ~H"""
    <div id="area-details" class="border-t border-subtle pt-4">
      <.form for={@name_form} id="area-name-form" phx-change="area_name" phx-submit="use_area">
        <.input
          field={@name_form[:name]}
          id="area-name"
          label="Area name riders see"
          help="Trip planners show it on the map. Use a place name riders know."
          errors={name_errors(@name_error)}
        />
      </.form>

      <p :if={@source_line} id="area-source" class="mt-2 text-[13px] text-muted">
        From: {@source_line}
      </p>

      <h2 id="area-inside-title" class="mt-4 text-xl font-bold text-strong">What’s inside</h2>

      <dl id="area-stats" class="mt-2 grid grid-cols-[96px_1fr] gap-x-3 gap-y-1 text-sm">
        <dt class="text-muted">Size</dt>
        <dd class="tabular-nums text-strong">{size_text(@stats)}</dd>
        <dt class="text-muted">Stops</dt>
        <dd class="text-strong">{stops_text(@stats, @stop_names)}</dd>
        <dt class="text-muted">Routes</dt>
        <dd class="text-strong">{routes_text(@stats)}</dd>
      </dl>

      <.callout
        :for={overlap <- @overlaps}
        id={"area-overlap-#{overlap.service_id}"}
        kind="info"
        title="Overlaps another service"
      >
        {km2_text(overlap.km2)} km² is also served by {overlap.name}. Riders there may see both services.
      </.callout>

      <.callout
        :if={@compare && compared?(@compare)}
        id="area-compare"
        kind="warning"
        title="Compared with the saved area"
      >
        <ul class="grid gap-0.5">
          <li class="tabular-nums">{delta_text(@compare)}</li>
          <li :if={@compare.stops_left != []}>
            No longer inside: {stop_list(@compare.stops_left, @stop_names)}
          </li>
          <li :if={@compare.stops_joined != []}>
            Now inside: {stop_list(@compare.stops_joined, @stop_names)}
          </li>
        </ul>
      </.callout>
    </div>
    """
  end

  @doc """
  The map the editor draws the candidate on, with the point tools above it
  (AC-12): Pan, Edit points and Draw on the left, Undo, Redo, Simplify and the
  point walk on the right, and the boundary's own count beside them. The
  crossing message and the simplification's result sit under the toolbar, where
  the reason "Use this area" is disabled stays next to the map it explains.

  The shared `FlexAreaMap` hook owns the map stage; Pan, Edit points, Draw and
  Simplify are the server's events, while Undo, Redo and Previous/Next point
  dispatch a DOM action because the history and the handle focus live in the
  hook. Undo, Redo and the point walk carry no server-rendered disabled state:
  the hook enables them when the history has somewhere to go.
  """
  attr :mode, :atom, required: true
  attr :source, :atom, required: true
  attr :editable, :boolean, required: true
  attr :vertices, :integer, default: nil
  attr :crossing, :any, default: nil
  attr :simplify_note, :string, default: nil

  def area_map(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div
        id="flex-area-tools"
        class="flex flex-wrap items-center gap-x-2 gap-y-1 border-b border-subtle px-3 py-2"
      >
        <div class="flex flex-wrap items-center gap-2" role="group" aria-label="Map tools">
          <.map_button id="area-mode-pan" event="area_mode" value="pan" pressed={@mode == :pan}>
            Pan
          </.map_button>
          <.map_button
            id="area-mode-edit"
            event="area_mode"
            value="edit"
            pressed={@mode == :edit}
            disabled={not @editable}
            title={not @editable && "Set the area first."}
          >
            Edit points
          </.map_button>
          <.map_button
            id="area-mode-draw"
            event="choose_source"
            value="draw"
            pressed={@mode == :draw}
          >
            Draw
          </.map_button>
        </div>

        <div class="flex flex-wrap items-center gap-2" role="group" aria-label="Boundary edits">
          <.map_action id="area-undo" action="undo">Undo</.map_action>
          <.map_action id="area-redo" action="redo">Redo</.map_action>
          <button
            type="button"
            id="area-simplify"
            phx-click="flex_area_simplify"
            disabled={@vertices == nil}
            class="inline-flex min-h-9 items-center rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas disabled:cursor-not-allowed disabled:text-muted"
          >
            Simplify
          </button>
          <.map_action id="area-prev-point" action="previous_point">Previous point</.map_action>
          <.map_action id="area-next-point" action="next_point">Next point</.map_action>
        </div>

        <p id="area-vertices" class="ml-auto text-[13px] tabular-nums text-muted">
          {vertices_text(@vertices)}
        </p>
      </div>

      <.callout
        :if={@crossing}
        id="area-crossing"
        kind="error"
        title="The boundary crosses itself"
        class="rounded-none"
      >
        Move the point at the red mark so the edges don’t cross. Exports refuse a boundary that crosses itself.
      </.callout>

      <p
        :if={@simplify_note}
        id="area-simplify-note"
        role="status"
        class="border-b border-subtle px-3 py-2 text-[13px] text-muted"
      >
        {@simplify_note}
      </p>

      <div
        id="flex-area-map"
        phx-hook="FlexAreaMap"
        phx-update="ignore"
        class="relative min-h-0 flex-1 overflow-hidden border-subtle lg:border-l"
      >
        <div class="flex-map-stage h-[62vh] min-h-[480px] bg-canvas lg:h-[calc(100dvh-244px)]"></div>
      </div>
    </div>
    """
  end

  # One map-tool button: the server's event, and its pressed state on screen as
  # well as in aria (daisyUI's outline carries no pressed look by itself).
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value, :string, required: true
  attr :pressed, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :title, :string, default: nil
  slot :inner_block, required: true

  defp map_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@event}
      phx-value-mode={@event == "area_mode" && @value}
      phx-value-source={@event == "choose_source" && @value}
      aria-pressed={to_string(@pressed)}
      disabled={@disabled}
      title={@title}
      class={[
        "inline-flex min-h-9 items-center rounded-control border border-control px-3 text-sm font-[650]",
        @pressed && "bg-action text-white hover:bg-action-hover",
        !@pressed && "bg-white text-strong hover:bg-canvas",
        @disabled && "cursor-not-allowed text-muted"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # One of the hook's own buttons: a DOM action, not a server event, because the
  # history and the handle focus never leave the browser. The disabled state
  # starts on and the hook keeps it true to what the history can do.
  attr :id, :string, required: true
  attr :action, :string, required: true
  attr :disabled, :boolean, default: true
  slot :inner_block, required: true

  defp map_action(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={JS.dispatch("flex-area:action", to: "#flex-area-map", detail: %{action: @action})}
      disabled={@disabled}
      class="inline-flex min-h-9 items-center rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas disabled:cursor-not-allowed disabled:text-muted"
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp vertices_text(nil), do: ""
  defp vertices_text(1), do: "1 point"
  defp vertices_text(count), do: "#{count} points"

  # --- shared parts -----------------------------------------------------------

  attr :source, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :help, :string, required: true
  attr :id, :string, required: true

  defp option(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="choose_source"
      phx-value-source={@source}
      class="flex min-h-11 w-full items-start gap-3 rounded-card border border-subtle px-3 py-3 text-left hover:border-action hover:bg-canvas"
    >
      <.icon name={@icon} class="mt-0.5 size-5 shrink-0 text-action" />
      <span class="min-w-0">
        <span class="block text-sm font-[650] text-strong">{@title}</span>
        <span class="block text-[13px] text-muted">{@help}</span>
      </span>
    </button>
    """
  end

  slot :inner_block, required: true

  defp panel_heading(assigns) do
    ~H"""
    <h2 id="area-panel-title" tabindex="-1" class="text-xl font-bold text-strong outline-none">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  defp back_to_choose(assigns) do
    ~H"""
    <button
      type="button"
      id="area-back-to-choose"
      phx-click="choose_source"
      phx-value-source="choose"
      class="-mt-2 inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action hover:underline"
    >
      <.icon name="hero-chevron-left" class="size-4" /> Other ways to set the area
    </button>
    """
  end

  # The picker's line under a place: the CDP label, the layer and the GEOID the
  # editor stores with the boundary, so the choice is identifiable before it is
  # measured.
  defp layer_kind(%{cdp?: true}), do: " Census-designated place"
  defp layer_kind(%{layer: layer}) when is_binary(layer), do: label_or_blank(layer)
  defp layer_kind(_place), do: ""

  defp label_or_blank(layer) do
    case census_layer_label(layer) do
      nil -> ""
      label -> " " <> label
    end
  end

  defp census_place_meta(%{geoid: geoid, layer: layer}), do: "#{layer} · GEOID #{geoid}"

  # Where the candidate boundary came from, in the words the picker used. The
  # Census line is the provenance AC-10 stores: the vintage and the GEOID.
  defp source_line(%{source: :census} = candidate) do
    join_help([
      "U.S. Census Bureau #{candidate.census_vintage} boundaries (GEOID #{candidate.census_geoid})",
      "Census water areas left out"
    ])
  end

  defp source_line(%{source: :route_distance, distance_m: distance})
       when is_integer(distance) do
    "Distance from the current routes · #{distance_metres(distance)}"
  end

  defp source_line(%{source: :route_distance}), do: "Distance from the current routes"
  defp source_line(%{source: :file} = candidate), do: "Imported from #{candidate.file_name}"
  defp source_line(%{source: :drawn}), do: "Drawn on the map"
  defp source_line(_candidate), do: nil

  defp name_errors(nil), do: []
  defp name_errors(message), do: [message]

  defp size_text(%{km2: km2}) when is_number(km2) do
    "#{km2_text(km2)} km² (#{sq_mi_text(km2)} sq mi)"
  end

  defp size_text(_stats), do: "not measured yet"

  defp sq_mi_text(km2) do
    km2 |> Kernel./(2.59) |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)
  end

  defp stops_text(%{stop_ids: []}, _stop_names), do: "None"
  defp stops_text(%{stop_ids: stop_ids}, stop_names), do: stop_list(stop_ids, stop_names)
  defp stops_text(_stats, _stop_names), do: "None"

  defp routes_text(%{route_ids: []}), do: "No fixed routes"
  defp routes_text(%{route_ids: route_ids}), do: Enum.join(route_ids, ", ")
  defp routes_text(_stats), do: "No fixed routes"

  defp stop_list(stop_ids, stop_names) do
    Enum.map_join(stop_ids, ", ", &Map.get(stop_names, &1, &1))
  end

  # The comparison shows only when it says something: the reference hides it
  # when the area barely moved and no stop changed sides.
  defp compared?(%{km2_before: before, km2_after: now, stops_left: left, stops_joined: joined}) do
    abs(now - before) >= 0.05 or left != [] or joined != []
  end

  defp delta_text(%{km2_before: before, km2_after: now}) do
    sign = if now < before, do: "", else: "+"
    "#{sign}#{km2_text(now - before)} km² (#{km2_text(before)} → #{km2_text(now)} km²)"
  end

  defp plural_word(1, word), do: word
  defp plural_word(_count, word), do: word <> "s"
end
