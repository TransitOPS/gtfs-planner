defmodule GtfsPlannerWeb.Gtfs.StopsMapComponents do
  @moduledoc """
  The Map view's chrome: the page header with the List | Map switch, the map
  stage with its loading and unavailable states, and the browse panel that
  lists the stops inside the current view.

  Everything here is server-rendered markup. The map stage's Leaflet canvas is
  the one element the `StopMap` hook owns, and it carries `phx-update="ignore"`
  so a diff never re-renders a map Leaflet is holding. The panel around it, the
  banner that reports an unavailable street map and the stop rows are ordinary
  diffs, which is what makes the list keep working when the map does not.

  The panel is a region, not a modal: the design system's inspector rule. The
  object being edited is drawn beside the editor, so the editor is a panel and
  the map keeps its place.

  The search field and its results are here rather than in the view because they
  are markup with states, and the panel's states are the design system's: a
  field the editor can type in, results that are 44 px buttons, and a message
  that says what to try when nothing matched.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  alias GtfsPlanner.Gtfs.StopReferences
  alias Phoenix.HTML.Form

  @doc """
  The page header: the title, the List | Map switch, the version's stop count
  and the Add stop primary.

  The switch is two links, not tabs, because the two are two routes of one page
  and either must work without JavaScript. `aria-current="page"` names the view
  being looked at.
  """
  attr :id, :string, required: true
  attr :version, :map, required: true
  attr :stop_count, :integer, required: true
  attr :station_count, :integer, required: true
  attr :loading, :boolean, required: true

  def page_header(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-x-6 gap-y-2 border-b border-subtle bg-white px-4 py-3 sm:px-5"
    >
      <h1 class="font-display text-[28px] font-semibold tracking-[-0.025em] text-strong">
        Stops &amp; stations
      </h1>

      <div class="flex rounded-control border border-control" role="group" aria-label="View">
        <.link
          id="stops-map-view-list"
          navigate={~p"/gtfs/#{@version.id}/stops"}
          class="flex min-h-11 items-center gap-2 rounded-l-control px-4 text-sm font-semibold text-strong no-underline hover:bg-canvas"
        >
          <.icon name="hero-list-bullet" class="size-4" /> List
        </.link>
        <.link
          id="stops-map-view-map"
          aria-current="page"
          class="flex min-h-11 items-center gap-2 rounded-r-control border-l border-control bg-selection px-4 text-sm font-bold text-action no-underline"
        >
          <.icon name="hero-map" class="size-4" /> Map
        </.link>
      </div>

      <p id="stops-map-scope-note" class="m-0 text-sm text-muted" aria-live="polite">
        {scope_note(assigns)}
      </p>

      <div class="ml-auto flex items-center gap-3">
        <.button
          id="stops-map-add-stop"
          type="button"
          class="min-h-11"
          phx-click="start_add"
          disabled={@loading}
        >
          <.icon name="hero-plus" class="size-4" /> Add stop
        </.button>
      </div>
    </div>
    """
  end

  @doc """
  The map stage: the hook's container, the loading overlay, the unavailable
  banner and the mode caption.

  The banner names what still works rather than replacing the stage, because a
  street basemap that failed to load costs the editor their bearings and not
  their stop list, their route lines or their coordinates.
  """
  attr :id, :string, required: true
  attr :map_state, :atom, required: true, values: [:loading, :ready, :unavailable]
  attr :caption, :map, default: nil
  attr :slot, :any, default: nil

  def map_stage(assigns) do
    ~H"""
    <div id={@id} class="relative min-h-[320px] overflow-hidden bg-canvas">
      <%!-- The hook's canvas. `phx-update="ignore"` because Leaflet owns every
             child of it and a diff would take the map out of its hands.
             `z-0` gives the canvas its own stacking context: Leaflet's panes run
             from z-index 200 to 700, and without this they compete with the
             caption and the legend — both at z-10 — and win, so a basemap tile
             paints over the words that explain it. --%>
      <div
        id="stop-map"
        phx-hook="StopMap"
        phx-update="ignore"
        class="absolute inset-0 z-0"
      >
      </div>

      <%!-- The hook's overlay: the placement pin and the crosshair. It is
             rendered here and ignored by every diff for the canvas's own
             reason: the browser owns the elements inside it, and a pin taken
             away by a diff the editor did not ask for is a placement nobody
             can finish. --%>
      <div id="stop-map-overlay" phx-update="ignore" class="stop-map-overlay">
        <div id="stop-map-crosshair" class="stop-map-crosshair" aria-hidden="true" hidden>
          <span class="stop-map-crosshair-v"></span>
          <span class="stop-map-crosshair-h"></span>
        </div>
      </div>

      <div
        :if={@map_state == :loading}
        id="stops-map-loading"
        class="absolute inset-0 grid place-content-center"
      >
        <p
          id="stops-map-loading-caption"
          role="status"
          class="m-0 rounded-control bg-white px-3 py-2 text-sm font-semibold text-strong shadow-card"
        >
          Loading map&hellip;
        </p>
      </div>

      <div
        :if={@map_state == :unavailable}
        id="stops-map-unavailable"
        role="alert"
        class="absolute left-3 right-[68px] top-3 z-10 flex flex-wrap items-center gap-3 rounded-card border border-warning-line bg-warning-bg px-4 py-3 text-sm text-warning-fg shadow-float"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <p class="m-0 min-w-[240px] flex-1">
          <strong>Street map unavailable.</strong>
          Stops and routes still show, and you can place a stop by entering coordinates.
        </p>
        <button
          id="stops-map-retry"
          type="button"
          class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas"
          phx-click="retry_map"
        >
          Retry map
        </button>
      </div>

      <div
        :if={@caption}
        id="stops-map-caption"
        class="absolute left-3 top-3 z-10 max-w-[min(360px,calc(100%-80px))] rounded-card border border-subtle bg-white px-4 py-3 shadow-float"
      >
        <p class="m-0 text-[15px] font-bold text-strong">{@caption.title}</p>
        <p :if={@caption.text} class="m-0 mt-0.5 text-[13px] text-default">{@caption.text}</p>
      </div>

      <.map_legend />
      <.map_zoom />
    </div>
    """
  end

  @doc """
  The zoom stack: plus, minus and "show every stop" at the top right of the
  stage.

  Leaflet's own control is switched off in favour of this one because it is
  top-left, 34 px, and its buttons are not the 44 px targets the rest of the
  workspace uses. It sits outside `#stop-map` for the legend's reason: Leaflet
  owns every child of the canvas.
  """
  def map_zoom(assigns) do
    ~H"""
    <div
      class="absolute right-3 top-3 z-10 grid overflow-hidden rounded-control border border-control bg-overlay shadow-card"
      role="group"
      aria-label="Map zoom"
    >
      <button
        type="button"
        data-map-zoom="in"
        aria-label="Zoom in"
        title="Zoom in"
        class="flex size-11 items-center justify-center text-strong hover:bg-canvas"
      >
        <.icon name="hero-plus" class="size-5" />
      </button>
      <button
        type="button"
        data-map-zoom="out"
        aria-label="Zoom out"
        title="Zoom out"
        class="flex size-11 items-center justify-center border-t border-control text-strong hover:bg-canvas"
      >
        <.icon name="hero-minus" class="size-5" />
      </button>
      <button
        type="button"
        data-map-fit
        aria-label="Show every stop"
        title="Show every stop"
        class="flex size-11 items-center justify-center border-t border-control text-strong hover:bg-canvas"
      >
        <.icon name="hero-arrows-pointing-in" class="size-5" />
      </button>
    </div>
    """
  end

  @doc """
  The legend: what the marks on the map mean, then the basemap and route toggles.

  It sits at the bottom left, inside the stage and outside `#stop-map`, because
  Leaflet owns every child of the canvas and a legend placed in there would be
  the first thing a `fitBounds` threw away. Below `xl` it clears Leaflet's own
  attribution strip: at 390 px the legend wraps to three rows and its bottom
  edge lands on the credits, which reads as one overlapping smear. The two
  toggles change what is drawn and nothing the server stores, so the hook
  handles them on the client; the basemap buttons carry `aria-pressed` because
  they are a pair of choices, not two independent actions.
  """
  def map_legend(assigns) do
    ~H"""
    <div
      id="stops-map-legend"
      class="absolute bottom-8 left-3 z-10 flex max-w-[calc(100%-24px)] flex-wrap items-center gap-x-4 gap-y-1 rounded-control border border-subtle bg-overlay px-3 py-1 text-[13px] text-default shadow-card xl:bottom-3"
    >
      <span class="inline-flex items-center gap-1.5">
        <svg width="22" height="16" viewBox="0 0 22 16" aria-hidden="true">
          <circle cx="8" cy="8" r="5.5" fill="#fff" stroke="#0f1a3d" stroke-width="2"></circle>
          <path
            d="M15 8l4 0M17 5.5l2.5 2.5-2.5 2.5"
            fill="none"
            stroke="#1a2654"
            stroke-width="1.6"
          >
          </path>
        </svg>
        Stop, arrow shows travel
      </span>
      <span class="inline-flex items-center gap-1.5">
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
          <circle
            cx="8"
            cy="8"
            r="5.5"
            fill="#fff"
            stroke="#7a85ac"
            stroke-width="2"
            stroke-dasharray="3 2"
          >
          </circle>
        </svg>
        Not served
      </span>
      <span class="inline-flex items-center gap-1.5">
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
          <rect x="2" y="2" width="12" height="12" rx="3" fill="#0f1a3d"></rect>
        </svg>
        Station
      </span>
      <span
        class="inline-flex overflow-hidden rounded-control border border-control"
        role="group"
        aria-label="Base map"
      >
        <button
          type="button"
          data-map-basemap="streets"
          aria-pressed="true"
          class="min-h-11 px-3 text-[13px] text-strong hover:bg-canvas"
        >
          Streets
        </button>
        <button
          type="button"
          data-map-basemap="satellite"
          aria-pressed="false"
          class="min-h-11 border-l border-control px-3 text-[13px] text-strong hover:bg-canvas"
        >
          Satellite
        </button>
      </span>
      <label class="inline-flex min-h-11 cursor-pointer items-center gap-2">
        <input
          type="checkbox"
          data-map-routes
          checked
          class="size-4 accent-action"
        /> Routes
      </label>
      <span class="hidden max-xl:inline text-muted">Arrow keys move the map</span>
    </div>
    """
  end

  @doc """
  The browse panel: a heading that says what the list holds, then the stops.

  The heading's second line is the reason the list changes without the page
  reloading: panning or zooming the map changes which stops are in view, and an
  editor who did not know that would read a short list as missing stops.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :inner_block, required: true

  def browse_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label="Stop details"
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div class="border-b border-subtle px-5 py-4">
        <h2 class="font-display text-[22px] font-semibold text-strong">{@title}</h2>
        <p class="mt-1 text-sm text-muted">{@subtitle}</p>
      </div>
      <div class="min-h-0 flex-1 overflow-y-auto">{render_slot(@inner_block)}</div>
    </aside>
    """
  end

  @doc """
  The panel's search field: a labelled text field with a magnifier in it.

  It is a form rather than a bare input because `phx-change` only fires inside
  one, and the form submits to the same search so Enter answers the question
  the editor is already asking. The value comes from a `to_form/2` the view
  rebuilt from the query it just handled, so a draft survives a refused or slow
  address search instead of being wiped by the re-render.

  The classes are given in full rather than inherited: `.input`'s defaults are
  not combined with an override, and the field has to match the panel's other
  controls at 44 px with the icon inside it.
  """
  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, required: true

  def search_field(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-change="search" phx-submit="search" class="mt-5">
      <label for={"#{@id}-query"} class="block text-sm font-semibold text-strong">
        {@label}
      </label>
      <div class="relative mt-1.5">
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-3 top-1/2 size-5 -translate-y-1/2 text-muted"
        />
        <.input
          field={@form[:query]}
          id={"#{@id}-query"}
          type="search"
          autocomplete="off"
          phx-debounce="250"
          placeholder={@placeholder}
          class="h-11 w-full rounded-control border border-control pl-10 pr-3 text-[15px] placeholder:text-muted"
        />
      </div>
    </.form>
    """
  end

  @doc """
  What the search found: the stops that matched, the places that matched, and
  what to try when neither did.

  The two groups are separate because they answer different questions — "is
  this stop in my feed" and "is this where my stop goes" — and an editor who
  cannot tell them apart searches for the wrong thing twice.

  `unavailable?` is the address service failing, not a search that found
  nothing. It is a line beside the stop results rather than a replacement for
  them: stop search is this version's own data and keeps working.
  """
  attr :id, :string, required: true
  attr :query, :string, required: true
  attr :stops, :list, default: []
  attr :places, :list, default: []
  attr :unavailable?, :boolean, default: false
  attr :empty_text, :string, default: nil

  def search_results(assigns) do
    ~H"""
    <div id={@id} class="px-5">
      <div :if={@unavailable?} id={"#{@id}-unavailable"} class="mt-4">
        <.message
          kind="warning"
          title="Address search is unavailable"
          id={"#{@id}-unavailable-message"}
        >
          Stops in this version still match. Search again later for streets and places.
        </.message>
      </div>

      <div class="mt-4 grid gap-4">
        <div :if={@stops != []}>
          <h3 class="m-0 text-[13px] font-bold text-muted">Stops</h3>
          <ul id={"#{@id}-stops"} class="m-0 mt-1 list-none p-0">
            <li :for={row <- @stops} id={"#{@id}-stop-#{row.stop_id}"}>
              <.stop_row row={row} selectable />
            </li>
          </ul>
        </div>

        <div :if={@places != []}>
          <h3 class="m-0 text-[13px] font-bold text-muted">Places</h3>
          <ul id={"#{@id}-places"} class="m-0 mt-1 list-none p-0">
            <li :for={{place, index} <- Enum.with_index(@places)} id={"#{@id}-place-#{index}"}>
              <.place_row place={place} />
            </li>
          </ul>
        </div>

        <p :if={@stops == [] and @places == []} id={"#{@id}-empty"} class="m-0 text-sm">
          {@empty_text || default_empty_text(@query)}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The "things to check" disclosure: what the version's stops are getting wrong,
  and the one action each finding offers.

  The count is in the summary because a disclosure whose contents are hidden has
  to say how much is hidden, and it is text rather than a colour for the same
  reason — a badge nobody can read is not a count.

  The rows are the version's own findings, so the summary is a claim the
  disclosure has to answer for; each row's text names the stops or the pattern
  it is about, because a title an editor cannot act on is a title they have to
  re-derive from the map.

  A duplicate offers a second action. "They&rsquo;re different stops" is the
  answer a person has when the finding is real and the data is right, and it
  dismisses the row for this session without touching the feed: two stops a metre
  apart are a judgement call, and the judgement belongs to the editor.

  The disclosure is a button and a region rather than a `<details>` element,
  because its open state has to survive a server-rendered re-render — a native
  one does not, and the row list would snap shut under the reader mid-check.
  """
  attr :id, :string, required: true
  attr :checks, :list, required: true
  attr :open?, :boolean, default: false

  def checks_disclosure(assigns) do
    ~H"""
    <div id={@id} class="mt-5 ml-5 mr-5 rounded-card border border-subtle">
      <button
        type="button"
        id={"#{@id}-toggle"}
        phx-click="toggle_checks"
        aria-expanded={to_string(@open?)}
        aria-controls={"#{@id}-items"}
        class="flex min-h-11 w-full cursor-pointer items-center gap-2 rounded-card px-4 py-2 text-left text-sm font-bold text-strong"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning-fg" />
        {length(@checks)} {pluralize(length(@checks), "thing")} to check
        <span class="ml-auto text-[13px] font-semibold text-muted">
          {if @open?, do: "Hide", else: "Show"}
        </span>
      </button>

      <ul
        id={"#{@id}-items"}
        hidden={!@open?}
        class="m-0 list-none divide-y divide-subtle border-t border-subtle p-0"
      >
        <li
          :for={check <- @checks}
          id={"#{@id}-#{check.dom_id}"}
          data-check-kind={check.kind}
          data-check-key={check.key}
          class="px-4 py-3 text-sm"
        >
          <p class="m-0 font-bold text-strong">{check.title}</p>
          <p class="m-0 mt-0.5 text-[13px]">{check.text}</p>
          <div class="mt-1 flex flex-wrap items-center gap-x-5 gap-y-1">
            <button
              type="button"
              phx-click="review_check"
              phx-value-key={check.key}
              class="inline-flex min-h-11 items-center gap-1.5 text-left text-sm font-semibold text-action hover:underline"
            >
              {check.action}
            </button>
            <button
              :if={check.kind == :duplicate}
              type="button"
              id={"#{@id}-dismiss-#{check.dom_id}"}
              phx-click="dismiss_check"
              phx-value-key={check.key}
              class="inline-flex min-h-11 items-center gap-1.5 text-left text-sm font-semibold text-action hover:underline"
            >
              They&rsquo;re different stops
            </button>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  One place from the address search: a pin, its name and what kind of place it is.

  A place is a button because choosing it is the whole point of searching for
  one — in add mode it becomes the draft's position, and in browse mode it moves
  the pin to where the editor is looking.
  """
  attr :place, :map, required: true

  def place_row(assigns) do
    ~H"""
    <button
      type="button"
      data-stop-map-place
      phx-click="choose_place"
      phx-value-lat={@place.lat}
      phx-value-lon={@place.lon}
      phx-value-address={@place.formatted_address}
      class="flex min-h-11 w-full items-center gap-3 rounded-control px-2 py-2 text-left hover:bg-canvas"
    >
      <.icon name="hero-map-pin" class="size-5 shrink-0 text-muted" />
      <span class="min-w-0 flex-1">
        <span class="block text-[14px] font-semibold text-strong">
          {@place.formatted_address}
        </span>
        <span class="block text-[13px] text-muted">{place_subtitle(@place)}</span>
      </span>
    </button>
    """
  end

  @doc """
  The panel's loading state: the heading a reader sees first, then skeletons
  shaped like the rows that follow.
  """
  attr :id, :string, required: true
  attr :skeleton_widths, :list, default: [62, 48, 70, 54, 66]

  def browse_panel_loading(assigns) do
    ~H"""
    <div
      :for={width <- @skeleton_widths}
      id={"#{@id}-#{width}"}
      class="flex items-start gap-3 px-5 py-3"
    >
      <span class="mt-0.5 block size-5 shrink-0 rounded-full bg-navy-100/60 motion-safe:animate-pulse">
      </span>
      <span class="min-w-0 flex-1">
        <span
          class="block h-4 rounded-badge bg-navy-100/60 motion-safe:animate-pulse"
          style={"width: #{width}%"}
        >
        </span>
        <span class="mt-2 block h-3.5 w-24 rounded-badge bg-navy-100/60 motion-safe:animate-pulse">
        </span>
      </span>
      <span class="h-5 w-7 shrink-0 rounded-badge bg-navy-100/60 motion-safe:animate-pulse"></span>
    </div>
    """
  end

  @doc """
  The stops inside the current view, stations first.

  A station is listed before the stops around it because a station is what an
  editor looks for when they are looking for a stop, and the bays are reachable
  from it.
  """
  attr :id, :string, required: true
  attr :stops, :list, required: true

  def stop_list(assigns) do
    ~H"""
    <div id={@id} class="px-5 pb-6">
      <h3 class="mb-0 mt-4 text-[13px] font-bold text-muted">On the map now</h3>
      <ul id={"#{@id}-items"} class="m-0 mt-1 list-none p-0">
        <li :for={row <- @stops} id={"#{@id}-item-#{row.id}"}>
          <.stop_row row={row} selectable />
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  One stop in the browse list: its marker shape, its name, what a rider would be
  told and the routes that call there.

  The route badges are the answer to "which bus stops here", which is the first
  question about a stop anybody asks, so it is on the row rather than behind a
  click.

  A row is read-only until something can be done with it. `selectable` marks the
  rows whose activation opens the edit panel, which is now every row the panel
  lists: the edit panel is behind them, so a row that looked pressable and
  did nothing is no longer either true or worth keeping.
  """
  attr :row, :map, required: true
  attr :selectable, :boolean, default: false

  def stop_row(%{selectable: true} = assigns) do
    assigns = assign(assigns, :row_id, "stops-map-row-#{assigns.row.stop_id}")

    ~H"""
    <button
      type="button"
      id={@row_id}
      phx-click="select_stop"
      phx-value-stop_id={@row.stop_id}
      class="flex min-h-11 w-full items-start gap-3 rounded-control px-2 py-2 text-left hover:bg-canvas"
    >
      <.stop_row_body row={@row} />
    </button>
    """
  end

  def stop_row(assigns) do
    assigns = assign(assigns, :row_id, "stops-map-row-#{assigns.row.stop_id}")

    ~H"""
    <div
      id={@row_id}
      class="flex min-h-11 w-full items-start gap-3 rounded-control px-2 py-2"
    >
      <.stop_row_body row={@row} />
    </div>
    """
  end

  @doc false
  attr :row, :map, required: true

  def stop_row_body(assigns) do
    ~H"""
    <span class="mt-0.5 flex size-5 shrink-0 items-center justify-center">
      <span :if={@row.location_type == 1} class="size-3.5 rounded-[3px] bg-strong"></span>
      <span
        :if={@row.location_type != 1}
        class={[
          "size-3.5 rounded-full border-2 bg-white",
          @row.served? && "border-strong",
          !@row.served? && "border-dashed border-navy-300"
        ]}
      >
      </span>
    </span>

    <span class="min-w-0 flex-1">
      <span class="block text-[14px] font-semibold text-strong">{@row.name}</span>
      <span class="block text-[13px] text-muted">{row_subtitle(@row)}</span>
    </span>

    <span class="flex shrink-0 flex-wrap justify-end gap-1">
      <.route_badge :for={route <- @row.routes} route={route} />
    </span>
    """
  end

  @doc """
  A route's badge: its short name on the route's own colour, with the long name
  for anything that reads the row rather than the map.
  """
  attr :route, :map, required: true

  def route_badge(assigns) do
    ~H"""
    <span
      title={@route.long_name || @route.short_name}
      class="inline-flex h-5 min-w-6 items-center justify-center rounded-badge px-1.5 text-[12px] font-bold"
      style={badge_style(@route)}
    >
      {@route.short_name}
    </span>
    """
  end

  @doc """
  The first-use panel for a version with no stops: what stops are for, the one
  next step, and the way in from an existing feed.
  """
  attr :id, :string, required: true
  attr :version, :map, required: true

  def first_use_panel(assigns) do
    ~H"""
    <div id={@id} class="border-b border-subtle px-5 py-5">
      <h2 class="font-display text-[22px] font-semibold text-strong">
        No stops in this version yet
      </h2>
      <p class="mt-1 text-sm text-muted">{@version.name} was started from scratch.</p>

      <p class="mt-4 text-[15px] text-strong">
        Stops are where your buses pick up riders. Add them here, then build patterns from them.
      </p>

      <ol class="mt-4 space-y-3 pl-5 text-[15px] text-strong">
        <li>
          Click <.link
            id="stops-map-first-use-add"
            href="#stops-map-first-use-add"
            class="font-bold text-action no-underline hover:underline"
            phx-click="start_add"
          >Add stop</.link>.
        </li>
        <li>Click the curb where riders wait. We suggest a name from the streets.</li>
        <li>Check the name and access, then create it.</li>
      </ol>

      <p class="mt-4 text-[15px] text-strong">Have a stops file from another system?</p>
      <.button
        id="stops-map-first-use-import"
        navigate={~p"/gtfs/#{@version.id}/import"}
        variant="secondary"
        class="mt-3 min-h-11"
      >
        <.icon name="hero-arrow-up-tray" class="size-4" /> Import feed
      </.button>
    </div>
    """
  end

  @doc """
  The add-mode panel: the caption's counterpart, the optional address search,
  the location the editor has chosen, and the form that names it.

  The panel is the whole create flow rather than a shell with the form behind
  it, because a form the server has to be asked for is a form that arrives after
  the editor has started typing. Everything here is the server's own state: the
  draft, its errors, the placement, the suggestions and what the placement
  deserves to be told.

  Before a placement the form's fields are dimmed rather than hidden. A
  paragraph in their place would be replaced by fields, which is a layout jump;
  dimmed fields say the same thing — "they come next" — and keep the panel from
  moving when the pin lands.
  """
  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :version_name, :string, required: true
  attr :search_form, :any, required: true
  attr :query, :string, required: true
  attr :places, :list, default: []
  attr :unavailable?, :boolean, default: false
  attr :form, :any, required: true
  attr :placement, :any, required: true
  attr :where, :string, default: nil
  attr :warnings, :list, default: []
  attr :suggestion, :any, default: nil
  attr :reverse_error, :any, default: nil
  attr :errors, :map, default: %{}
  attr :advice, :list, default: []
  attr :code_issue, :string, default: nil
  attr :zone_note, :string, default: nil
  attr :saving?, :boolean, default: false
  attr :coords_open?, :boolean, default: false
  attr :tech_open?, :boolean, default: false
  attr :failure, :string, default: nil

  def add_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label={if @kind == :station, do: "Add a station", else: "Add a stop"}
      phx-hook="FormErrorFocus"
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <%!-- The form is taller than the workspace at 900px, so it scrolls in the
             same shell the browse panel scrolls in. A create button below the
             fold of a panel that cannot scroll is a stop nobody can make. --%>
      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-5 py-5">
          <h2 class="font-display text-[22px] font-semibold text-strong">
            {if @kind == :station, do: "New station", else: "New stop"}
          </h2>
          <p class="mt-1 text-sm text-muted">
            Adds a {if @kind == :station, do: "station", else: "stop"} to {@version_name}.
          </p>

          <.search_field
            id="stops-map-address-search"
            form={@search_form}
            label="Find an address or intersection (optional)"
            placeholder="For example, 9th & US 101"
          />

          <p :if={@query == ""} id="stops-map-address-hint" class="m-0 mt-1.5 text-[13px] text-muted">
            Results favour places near your stops.
          </p>

          <.search_results
            :if={@query != ""}
            id="stops-map-address-results"
            query={@query}
            places={@places}
            unavailable?={@unavailable?}
            empty_text="No match near this version's stops. Try a street name."
          />

          <div :if={@failure} id="stops-map-add-failure" class="mt-5">
            <.message
              kind="error"
              title="We couldn’t save this stop"
              id="stops-map-add-failure-message"
            >
              {@failure} Your draft is still here. Try again.
            </.message>
          </div>

          <div :if={@errors != %{}} id="stops-map-add-errors" class="mt-5">
            <.message
              kind="error"
              title={error_summary_title(@errors)}
              id="stops-map-add-errors-message"
            >
              <ul class="m-0 list-disc pl-5">
                <li :for={{field, error} <- summary_errors(@errors)}>
                  <a href={"#stops-map-add-#{field}"} class="font-semibold text-error-fg underline">
                    {error.short}
                  </a>
                </li>
              </ul>
            </.message>
          </div>

          <.form
            for={@form}
            id="stops-map-add-form"
            phx-change="add_field"
            phx-submit="create_stop"
            class="mt-5"
          >
            <fieldset class="m-0 min-w-0 border-0 p-0">
              <legend class="mb-2 p-0 text-[15px] font-bold text-strong">Location</legend>
              <.add_location
                placement={@placement}
                form={@form}
                where={@where}
                warnings={@warnings}
                coords_open?={@coords_open?}
                errors={@errors}
              />
            </fieldset>

            <p
              :if={@kind == :stop and @placement == nil}
              id="stops-map-add-switch"
              class="m-0 mt-5 text-[13px] text-muted"
            >
              Adding a station, like a transit center with several bays?
              <button
                id="stops-map-add-kind-station"
                type="button"
                phx-click="add_kind"
                phx-value-kind="station"
                class="inline-flex min-h-11 items-center font-semibold text-action underline underline-offset-4"
              >
                Add a station
              </button>
            </p>

            <div class={["mt-7 grid gap-5", @placement == nil && "opacity-60"]}>
              <.add_fields
                kind={@kind}
                form={@form}
                errors={@errors}
                suggestion={@suggestion}
                reverse_error={@reverse_error}
                advice={@advice}
                code_issue={@code_issue}
                zone_note={@zone_note}
              />
            </div>

            <div :if={@placement != nil} class="mt-7">
              <.add_tech
                form={@form}
                errors={@errors}
                kind={@kind}
                tech_open?={@tech_open?}
              />
            </div>

            <div class="mt-7 flex flex-wrap items-center gap-3">
              <p
                id="stops-map-add-status"
                role="status"
                class="m-0 mr-auto text-[13px] text-muted"
              >
                {if @saving?, do: "Creating…"}
              </p>
              <button
                id="stops-map-add-cancel"
                type="button"
                class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas disabled:opacity-70"
                phx-click="cancel_add"
                disabled={@saving?}
              >
                Cancel
              </button>
              <.button
                id="stops-map-add-create"
                type="submit"
                class="min-h-11"
                disabled={@saving?}
              >
                {if @saving?,
                  do: "Creating…",
                  else: if(@kind == :station, do: "Create station", else: "Create stop")}
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  The Location fieldset: either the instruction and the ways in, or the point
  that was placed, its sentence, its coordinates and what it deserves to be told.

  The warnings are advisory and each carries one action. "Move it across the
  street" posts the line the finding is about rather than a point, so the
  reflection is made by the server from the line it holds: a client-chosen
  point would be a position the geometry never agreed to.
  """
  attr :placement, :any, required: true
  attr :form, :any, required: true
  attr :where, :string, default: nil
  attr :warnings, :list, default: []
  attr :coords_open?, :boolean, default: false
  attr :errors, :map, default: %{}

  def add_location(assigns) do
    ~H"""
    <div :if={@placement == nil}>
      <p class="m-0 text-[15px] text-strong">
        Click the map where riders wait, on the side of the street the bus stops on.
      </p>

      <button
        id="stops-map-add-coords-toggle"
        type="button"
        phx-click="toggle_coords"
        aria-expanded={to_string(@coords_open?)}
        class="mt-2 inline-flex min-h-11 items-center gap-1.5 text-sm font-semibold text-action no-underline hover:underline"
      >
        <.icon name="hero-crosshair" class="size-4" /> Enter coordinates instead
      </button>

      <div :if={@coords_open?} class="mt-3">
        <.coord_fields
          lat_field={:lat}
          lon_field={:lon}
          lat_error="lat"
          lon_error="lon"
          form={@form}
          errors={@errors}
        />
      </div>
    </div>

    <div :if={@placement != nil}>
      <p id="stops-map-add-where" class="m-0 text-[15px] font-semibold text-strong">
        {@where}
      </p>
      <p class="m-0 mt-1 text-[13px] text-muted">
        Drag the pin to adjust. The stop is not saved until you create it.
      </p>

      <.coord_fields
        lat_field={:lat}
        lon_field={:lon}
        lat_error="lat"
        lon_error="lon"
        form={@form}
        errors={@errors}
      />

      <div id="stops-map-add-warnings" class="mt-3 grid gap-3">
        <.add_warning :for={warning <- @warnings} warning={warning} />
      </div>
    </div>
    """
  end

  @doc """
  One thing the placed draft deserves to be told: a warning with an action, or
  a line of context. The row is a `<p>` for the copy and the action is a button
  in the same voice as the checks list, so a reader who has learned one panel's
  actions has learned the other's.
  """
  attr :warning, :map, required: true

  def add_warning(%{warning: %{kind: kind}} = assigns)
      when kind in [:nearby, :passing, :no_pattern] do
    ~H"""
    <p
      id={"stops-map-#{@warning.dom_id}"}
      data-add-warning={@warning.kind}
      class="m-0 text-[13px] text-muted"
    >
      {@warning.text}
    </p>
    """
  end

  def add_warning(assigns) do
    ~H"""
    <div
      id={"stops-map-#{@warning.dom_id}"}
      data-add-warning={@warning.kind}
      role="status"
      class="rounded-card border border-warning-line bg-warning-bg px-4 py-3 text-[13px] text-warning-fg"
    >
      <p class="m-0 flex items-start gap-2 font-bold">
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
        {@warning.title}
      </p>
      <p class="m-0 mt-1">{@warning.text}</p>
      <p :if={@warning.action} class="m-0 mt-1">
        <button
          id={"stops-map-#{@warning.dom_id}-action"}
          type="button"
          phx-click={warning_action(@warning)}
          phx-value-key={@warning.action_key}
          class="inline-flex min-h-11 items-center font-semibold text-action underline underline-offset-4"
        >
          {@warning.action_label}
        </button>
      </p>
    </div>
    """
  end

  @doc """
  The two coordinate fields, and the note that a pasted pair fills both.

  They are the same two numbers the pin is at, in a form an editor can type
  into: a stop placed from a gazetteer or a survey sheet arrives as a pair of
  numbers and nobody should have to drag a pin to it.
  """
  attr :id, :string, default: "stops-map-add"
  attr :lat_field, :atom, required: true
  attr :lon_field, :atom, required: true
  attr :lat_error, :string, required: true
  attr :lon_error, :string, required: true
  attr :form, :any, required: true
  attr :errors, :map, default: %{}

  def coord_fields(assigns) do
    ~H"""
    <div class="mt-3 grid grid-cols-2 gap-3">
      <div>
        <label for={"#{@id}-lat"} class="block text-sm font-semibold text-strong">
          Latitude
        </label>
        <.input
          field={@form[@lat_field]}
          id={"#{@id}-lat"}
          errors={field_errors(@errors, @lat_error)}
          type="text"
          inputmode="decimal"
          autocomplete="off"
          class={coord_input_class(Map.has_key?(@errors, @lat_error))}
        />
      </div>

      <div>
        <label for={"#{@id}-lon"} class="block text-sm font-semibold text-strong">
          Longitude
        </label>
        <.input
          field={@form[@lon_field]}
          id={"#{@id}-lon"}
          errors={field_errors(@errors, @lon_error)}
          type="text"
          inputmode="decimal"
          autocomplete="off"
          class={coord_input_class(Map.has_key?(@errors, @lon_error))}
        />
      </div>
    </div>
    <p class="m-0 mt-1 text-[13px] text-muted">
      Pasting &ldquo;44.6376, -124.0530&rdquo; into Latitude fills both and moves the pin.
    </p>
    """
  end

  # A map form's fields carry no "was this used" flag, so `<.input>` would keep
  # `aria-invalid` false on a field the server has just refused. The messages go
  # to the control instead, which is what makes it announce its own state.
  defp field_errors(errors, field) do
    case Map.get(errors, field) do
      %{long: message} -> [message]
      _ -> []
    end
  end

  defp coord_input_class(invalid?) do
    [
      "h-11 w-full rounded-control border px-3 text-[15px]",
      invalid? && "border-error-line text-error-fg",
      !invalid? && "border-control"
    ]
  end

  @doc """
  The fields a placed stop is named by: name, description, sign number,
  wheelchair access, and the fare zone as a read-only line.

  The zone is a line rather than a select because production has no zone editor
  on this surface: the nearest stops' zone is stated, and the rule that zones
  are managed in Settings is the instruction. A select here would offer a choice
  this page cannot honour.
  """
  attr :kind, :atom, required: true
  attr :form, :any, required: true
  attr :errors, :map, default: %{}
  attr :suggestion, :any, default: nil
  attr :reverse_error, :any, default: nil
  attr :advice, :list, default: []
  attr :code_issue, :string, default: nil
  attr :zone_note, :string, default: nil

  def add_fields(assigns) do
    ~H"""
    <div>
      <label for="stops-map-add-name" class="block text-sm font-semibold text-strong">Name</label>
      <.input
        field={@form[:name]}
        id="stops-map-add-name"
        errors={field_errors(@errors, "name")}
        type="text"
        autocomplete="off"
        class={text_input_class(Map.has_key?(@errors, "name"))}
      />

      <div
        :if={@suggestion && @suggestion != :loading && @suggestion.alternatives != []}
        id="stops-map-add-suggestions"
        class="mt-1 flex flex-wrap items-center gap-x-3 text-[13px] text-muted"
      >
        <span>Other options:</span>
        <button
          :for={name <- @suggestion.alternatives}
          id={"stops-map-add-suggestion-#{slug(name)}"}
          type="button"
          phx-click="add_suggestion"
          phx-value-field="name"
          phx-value-text={name}
          class="inline-flex min-h-11 items-center font-semibold text-action underline underline-offset-4"
        >
          {name}
        </button>
      </div>

      <ul :if={@advice != []} id="stops-map-add-advice" class="m-0 mt-1.5 grid list-none gap-1 p-0">
        <li
          :for={advice <- @advice}
          class="flex gap-1.5 text-[13px] font-semibold text-warning-fg"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
          {advice}
        </li>
      </ul>

      <p
        :if={@reverse_error}
        id="stops-map-add-reverse-error"
        class="m-0 mt-1.5 text-[13px] text-muted"
      >
        We couldn&rsquo;t look up the streets here. Type a name riders will recognise.
      </p>

      <p class="m-0 mt-1 text-[13px] text-muted">
        Riders see this on signs and in trip planners: the street the bus is on, then the cross
        street or a landmark people know.
      </p>
    </div>

    <div :if={@kind == :stop}>
      <label for="stops-map-add-desc" class="block text-sm font-semibold text-strong">
        Description <span class="font-normal text-muted">(optional)</span>
      </label>
      <.input
        field={@form[:desc]}
        id="stops-map-add-desc"
        type="text"
        autocomplete="off"
        class="h-11 w-full rounded-control border border-control px-3 text-[15px]"
      />

      <div
        :if={@suggestion && @suggestion != :loading && @suggestion.description}
        id="stops-map-add-desc-suggestion"
        class="mt-1 text-[13px] text-muted"
      >
        This side of the street:
        <button
          id="stops-map-add-desc-suggestion-action"
          type="button"
          phx-click="add_suggestion"
          phx-value-field="desc"
          phx-value-text={@suggestion.description}
          class="inline-flex min-h-11 items-center font-semibold text-action underline underline-offset-4"
        >
          {@suggestion.description}
        </button>
      </div>

      <p class="m-0 mt-1 text-[13px] text-muted">
        Tells apart stops with the same name, such as the two sides of a street.
      </p>

      <div>
        <label for="stops-map-add-code" class="mt-5 block text-sm font-semibold text-strong">
          Sign number <span class="font-normal text-muted">(optional)</span>
        </label>
        <.input
          field={@form[:code]}
          id="stops-map-add-code"
          type="text"
          inputmode="numeric"
          autocomplete="off"
          class="h-11 max-w-[180px] rounded-control border border-control px-3 font-mono text-[15px]"
        />
        <p
          :if={@code_issue}
          id="stops-map-add-code-issue"
          class="m-0 mt-1.5 text-[13px] font-semibold text-warning-fg"
        >
          {@code_issue}
        </p>
        <p class="m-0 mt-1 text-[13px] text-muted">
          The number on the sign riders use to look up arrivals.
        </p>
      </div>
    </div>

    <fieldset class="m-0 min-w-0 border-0 p-0">
      <legend class="p-0 text-sm font-semibold text-strong">Wheelchair access</legend>
      <div class="mt-1.5 flex flex-wrap gap-x-5">
        <label
          :for={{value, label} <- wheelchair_choices()}
          class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-[15px] text-strong"
        >
          <input
            type="radio"
            id={"stops-map-add-wb-#{value}"}
            name="stop[wheelchair_boarding]"
            value={value}
            checked={@form[:wheelchair_boarding].value == value}
            class="size-4 accent-action"
          />
          {label}
        </label>
      </div>
      <p class="m-0 mt-1 text-[13px] text-muted">
        Leave Not recorded until someone has checked the stop, its landing pad and its route to
        the curb.
      </p>
    </fieldset>

    <div :if={@kind == :stop}>
      <p id="stops-map-add-zone" class="m-0 text-[13px] text-muted">
        {@zone_note} Zones are managed in Settings &rsaquo; Fares.
      </p>
    </div>

    <p :if={@kind == :station} id="stops-map-add-station-note" class="m-0 text-sm text-muted">
      Add its bays or platforms after you create it, on the station page. Trips stop at bays, not
      at the station itself.
    </p>
    """
  end

  @doc """
  The collapsed "Stop ID and feed details" block: the ID, the spoken name and
  the stop's web page.

  It is a button and a region rather than a `<details>` element because a native
  disclosure's open state is not the server's, and a re-render would snap it
  shut under the reader while they are typing an ID into it.

  For a new stop the ID is editable and prefilled with the version's next one.
  It cannot change after the stop exists, so this is the only place an editor
  gets to choose it.
  """
  attr :form, :any, required: true
  attr :errors, :map, default: %{}
  attr :kind, :atom, required: true
  attr :tech_open?, :boolean, default: false

  def add_tech(assigns) do
    ~H"""
    <div id="stops-map-add-tech" class="rounded-card border border-subtle">
      <button
        id="stops-map-add-tech-toggle"
        type="button"
        phx-click="toggle_tech"
        aria-expanded={to_string(@tech_open?)}
        aria-controls="stops-map-add-tech-items"
        class="flex min-h-11 w-full cursor-pointer items-center gap-2 rounded-card px-4 py-2 text-left text-sm font-bold text-strong"
      >
        <.icon name="hero-chevron-right" class="size-4 text-muted" /> Stop ID and feed details
        <span class="ml-auto text-[13px] font-semibold text-muted">
          {if @tech_open?, do: "Hide", else: "Show"}
        </span>
      </button>

      <div
        :if={@tech_open?}
        id="stops-map-add-tech-items"
        class="grid gap-4 border-t border-subtle px-4 py-4"
      >
        <div>
          <label for="stops-map-add-stop-id" class="block text-sm font-semibold text-strong">
            Stop ID
          </label>
          <.input
            field={@form[:stop_id]}
            id="stops-map-add-stop-id"
            errors={field_errors(@errors, "stop_id")}
            type="text"
            autocomplete="off"
            class={[
              "h-11 max-w-[180px] rounded-control px-3 font-mono text-[15px]",
              Map.has_key?(@errors, "stop_id") && "border-error-line text-error-fg",
              !Map.has_key?(@errors, "stop_id") && "border-control"
            ]}
          />
          <p class="m-0 mt-1 text-[13px] text-muted">
            The next number after your highest stop ID. It can&rsquo;t change once the stop
            exists, so this is the only place to choose it.
          </p>
        </div>

        <div>
          <label for="stops-map-add-tts" class="block text-sm font-semibold text-strong">
            Spoken name <span class="font-normal text-muted">(optional)</span>
          </label>
          <.input
            field={@form[:tts_stop_name]}
            id="stops-map-add-tts"
            type="text"
            autocomplete="off"
            placeholder="Southeast First Street and U S one oh one"
            class="h-11 w-full rounded-control border border-control px-3 text-[15px]"
          />
          <p class="m-0 mt-1 text-[13px] text-muted">
            How screen readers and announcements should say the name, when abbreviations would be
            read wrong.
          </p>
        </div>

        <div>
          <label for="stops-map-add-url" class="block text-sm font-semibold text-strong">
            Stop web page <span class="font-normal text-muted">(optional)</span>
          </label>
          <.input
            field={@form[:stop_url]}
            id="stops-map-add-url"
            type="url"
            autocomplete="off"
            class="h-11 w-full rounded-control border border-control px-3 text-[15px]"
          />
        </div>

        <p class="m-0 text-[13px] text-muted">
          GTFS: <span class="font-mono">stop_id</span>, <span class="font-mono">stop_code</span>
          is the sign number, <span class="font-mono">stop_desc</span>
          the description, <span class="font-mono">tts_stop_name</span>
          the spoken name.
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The panel after a stop is created: what was made, the patterns it could be
  added to, and the way to make the next stop.

  The pattern list is the panel's reason for existing. A stop that is not on a
  pattern is not in any trip yet, and the stop editor is the only place that
  knows which patterns pass the point — so the one action that makes the new stop
  real is a link from here into each of them, carrying the stop and the index
  the pattern editor will insert it at.

  Each link is a real navigation, and the fallback is a sentence rather than an
  empty list: a version whose routes are not drawn yet has nothing to offer, and
  "no pattern passes here" is a better answer than a heading with nothing under
  it.
  """
  attr :id, :string, required: true
  attr :stop, :map, required: true
  attr :version_name, :string, required: true

  def created_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label="Stop created"
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-5 py-5">
          <h2 class="font-display text-[22px] font-semibold text-strong">
            {if @stop.kind == "station", do: "Station created", else: "Stop created"}
          </h2>
          <p class="mt-1 text-sm text-muted">
            {@stop.name} &middot; ID {@stop.stop_id}
          </p>

          <div class="mt-5" id="stops-map-created-message">
            <.message
              kind="success"
              title={"#{@stop.name} is in #{@version_name}"}
              id="stops-map-created-success"
            >
              {Enum.reject([@stop.desc, @stop.wheelchair, @stop.zone], &(&1 in [nil, ""]))
              |> Enum.join(" · ")}
            </.message>
          </div>

          <h3 class="mb-0 mt-6 text-[15px] font-bold text-strong">Next: add it to a pattern</h3>

          <div id="stops-map-created-patterns" class="mt-1">
            <ul :if={@stop.patterns != []} class="m-0 list-none divide-y divide-subtle p-0 text-sm">
              <li
                :for={pattern <- @stop.patterns}
                id={"stops-map-created-#{pattern.dom_id}"}
                class="flex items-center gap-3 py-2.5"
              >
                <.route_badge route={pattern.route} />
                <span class="min-w-0 flex-1">
                  <span :if={pattern.headsign} class="block truncate">
                    toward {pattern.headsign}
                  </span>
                  <span class="block text-[13px] text-muted">{pattern.between}</span>
                </span>
                <.link
                  navigate={pattern.href}
                  class="shrink-0 inline-flex min-h-11 items-center rounded-control border border-subtle px-3 text-sm font-semibold text-action no-underline hover:bg-canvas"
                >
                  Add to pattern
                </.link>
              </li>
            </ul>

            <p :if={@stop.patterns == []} class="m-0 text-sm">
              No pattern passes here yet. Add the stop from a pattern’s stop list when the route is
              ready.
            </p>
          </div>

          <p :if={@stop.patterns != []} class="m-0 mt-2 text-[13px] text-muted">
            Opens the pattern editor with the stop in place. Trips get a time for it when you next
            edit or estimate their times.
          </p>

          <div class="mt-6 flex flex-wrap items-center gap-3">
            <.link
              navigate={@stop.href}
              class="mr-auto inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong no-underline hover:bg-canvas"
            >
              Open stop
            </.link>
            <button
              id="stops-map-created-another"
              type="button"
              phx-click="add_another"
              class="inline-flex min-h-11 items-center gap-2 rounded-control bg-action px-4 text-sm font-semibold text-white hover:opacity-90"
            >
              <.icon name="hero-plus" class="size-4" /> Add another stop
            </button>
          </div>
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  The stop edit panel: what the stop is, the fields that change it, what else
  names it, and the footer that says whether anything has changed yet.

  The panel owns three things the browse list deliberately did not.
  It owns the **dirty state**, which the footer states in words rather than by
  greying the Save button alone — a disabled button with no sentence is a control
  an editor has to guess at. It owns the **fare zone**, which is text with a
  link rather than a select, because zone assignment belongs to Settings ›
  Fares and a select here would offer a choice this page cannot
  honour. And it owns the **unsaved-changes guard**: Escape, Cancel and choosing
  another stop all pass through the same dialog rather than each inventing its
  own.

  "Not served" is information only. The editor does not change the export, so
  there is no keep-in-feed checkbox here, and a checkbox that changed nothing
  would be worse than its absence.

  The `phx-window-keydown` is on the panel rather than the document because the
  panel is the only thing that can be dirty, and a key handler that fires from a
  panel nobody is editing would guard an exit nobody took.
  """
  attr :id, :string, required: true
  attr :stop, :map, required: true
  attr :form, :any, required: true
  attr :where, :string, default: nil
  attr :usage, :any, default: nil
  attr :zone_name, :string, default: nil
  attr :zone_id, :string, default: nil
  attr :zone_href, :string, required: true
  attr :errors, :map, default: %{}
  attr :dirty?, :boolean, default: false
  attr :saving?, :boolean, default: false
  attr :outcome, :atom, default: :none
  attr :move, :map, default: nil
  attr :move_saved, :map, default: nil
  attr :pin_off_canvas?, :boolean, default: false
  attr :conflict, :map, default: nil
  attr :more_open?, :boolean, default: false
  attr :replace_none_within, :string, default: nil
  attr :tech_open?, :boolean, default: false
  attr :discard_action, :any, default: nil

  def edit_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label="Edit stop"
      phx-hook="FormErrorFocus"
      phx-window-keydown={@dirty? && "edit_escape"}
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-5 py-5">
          <div class="flex items-start gap-3">
            <div class="min-w-0 flex-1">
              <h2 class="font-display text-[22px] font-semibold text-strong">
                {@stop.name}
              </h2>
              <div class="mt-1 flex flex-wrap items-center gap-2">
                <p class="m-0 text-sm text-muted">{edit_subtitle(@stop)}</p>
                <%!-- The routes beside the ID: a stop is identified to a rider
                     by the routes that call at it, so the panel says so before
                     any field does. --%>
                <span class="flex flex-wrap items-center gap-1">
                  <.route_badge :for={route <- @stop.routes} route={route} />
                </span>
              </div>
            </div>

            <%!-- More actions is a server-held disclosure rather than a native
                 `<details>`, for the same reason as the "things to check"
                 disclosure: a re-render from a `phx-change` on the form would
                 snap a native one shut under the editor who opened it. --%>
            <div class="relative shrink-0">
              <button
                id="stops-map-edit-more"
                type="button"
                phx-click="toggle_edit_more"
                aria-expanded={to_string(@more_open?)}
                aria-label="More actions for this stop"
                aria-haspopup="menu"
                class="flex size-11 cursor-pointer items-center justify-center rounded-control text-strong hover:bg-canvas"
              >
                <.icon name="hero-ellipsis-vertical" class="size-5" />
              </button>

              <div
                :if={@more_open?}
                id="stops-map-edit-more-menu"
                role="menu"
                aria-label="More actions for this stop"
                class="absolute right-0 top-full z-30 mt-1 w-72 rounded-card border border-subtle bg-white p-2 shadow-float"
              >
                <a
                  id="stops-map-edit-open-page"
                  href={@stop.href}
                  class="flex min-h-11 items-center gap-2 rounded-control px-3 text-sm text-strong no-underline hover:bg-canvas"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open stop page
                </a>

                <%!-- The destructive action sits below a rule and says the
                     verb and the object, so it reads as different in kind from
                     the two that only change which panel is showing. --%>
                <div class="my-1 border-t border-subtle"></div>
                <button
                  :if={station_offerable?(@stop)}
                  id="stops-map-edit-station"
                  type="button"
                  phx-click="start_make_station"
                  class="flex min-h-11 w-full flex-col justify-center rounded-control px-3 py-2 text-left text-sm text-strong hover:bg-canvas"
                >
                  Make this a station…<span class="text-[13px] text-muted">
                    Groups it with bays under one name. Its ID stays.
                  </span>
                </button>
                <button
                  id="stops-map-edit-replace"
                  type="button"
                  phx-click="start_replace"
                  class="flex min-h-11 w-full flex-col justify-center rounded-control px-3 py-2 text-left text-sm text-strong hover:bg-canvas"
                >
                  Replace with another stop…<span class="text-[13px] text-muted">
                    Moves its patterns and rules to a stop nearby
                  </span>
                </button>
                <button
                  id="stops-map-edit-delete"
                  type="button"
                  phx-click="start_delete"
                  class="flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm font-semibold text-error-fg hover:bg-error-bg"
                >
                  Delete {if @stop.location_type == 1, do: "station", else: "stop"}…
                </button>
              </div>
            </div>
          </div>

          <div :if={@stop.location_type == 1} id="stops-map-edit-bays" class="mt-5">
            <.bays_block bays={@stop.bays} />
          </div>

          <div :if={@move_saved} id="stops-map-move-saved" class="mt-5">
            <%!-- A move that landed is confirmed on the panel the editor is left
                 on: the review has been answered, and what remains is a stop at
                 its new position and a line drawn for it. --%>
            <.message kind="success" title="The stop has moved" id="stops-map-move-saved-message">
              {moved_message(@move_saved)}
            </.message>
          </div>

          <.replace_none_message
            :if={@replace_none_within}
            id="stops-map-edit-replace-none"
            within={@replace_none_within}
            class="mt-5"
          />

          <div
            :if={@outcome == :stale and @conflict}
            id="stops-map-edit-conflict"
            class="mt-5"
          >
            <.message
              kind="warning"
              role="status"
              title={conflict_title(@conflict)}
              id="stops-map-edit-conflict-message"
            >
              {conflict_body(@conflict)}
            </.message>
          </div>

          <div :if={@outcome == :failed} id="stops-map-edit-failed" class="mt-5">
            <.message
              kind="error"
              title="We couldn’t save this stop"
              id="stops-map-edit-failed-message"
            >
              Nothing was changed. Your edits are still here. Check your connection and save again.
            </.message>
          </div>

          <div :if={@errors != %{}} id="stops-map-edit-errors" class="mt-5">
            <.message
              kind="error"
              title={error_summary_title(@errors)}
              id="stops-map-edit-errors-message"
            >
              <ul class="m-0 list-disc pl-5">
                <li :for={{field, error} <- summary_errors(@errors)}>
                  <a href={"#stops-map-edit-#{field}"} class="font-semibold text-error-fg underline">
                    {error.short}
                  </a>
                </li>
              </ul>
            </.message>
          </div>

          <.form
            for={@form}
            id="stops-map-edit-form"
            phx-change="edit_field"
            phx-submit="save_stop"
            class="mt-5"
          >
            <fieldset class="m-0 min-w-0 border-0 p-0">
              <legend class="mb-2 p-0 text-[15px] font-bold text-strong">Location</legend>
              <p
                :if={@where}
                id="stops-map-edit-where"
                class="m-0 text-[15px] font-semibold text-strong"
              >
                {@where}
              </p>
              <.coord_fields
                id="stops-map-edit"
                lat_field={:stop_lat}
                lon_field={:stop_lon}
                lat_error="stop_lat"
                lon_error="stop_lon"
                form={@form}
                errors={@errors}
              />
              <%!-- The move, in the editor's own units. A stop is corrected on a
                   curb, so the distance is stated in feet and the pin's nudge is
                   stated in feet too; "Put it back" undoes the move and leaves
                   every other typed field alone. --%>
              <p :if={@move} id="stops-map-edit-moved" class="m-0 mt-1 text-[13px] text-strong">
                Moved {feet(@move.distance_m)} of where it was.{if @move.band == :correction,
                  do: " A small correction, so it saves without a review.",
                  else: " This far needs a review before it saves."}
                <button
                  id="stops-map-edit-put-back"
                  type="button"
                  phx-click="put_back"
                  class="font-semibold text-action underline underline-offset-4"
                >
                  Put it back
                </button>
                <button
                  :if={@pin_off_canvas?}
                  id="stops-map-edit-find-pin"
                  type="button"
                  phx-click="find_pin"
                  class="ml-2 font-semibold text-action underline underline-offset-4"
                >
                  Find the pin
                </button>
              </p>
              <p :if={is_nil(@move)} class="m-0 mt-1 text-[13px] text-muted">
                Drag the pin on the map to move it. The saved position stays until you save.
              </p>
            </fieldset>

            <div class="mt-7 grid gap-5">
              <div>
                <label for="stops-map-edit-name" class="block text-sm font-semibold text-strong">
                  Name
                </label>
                <.input
                  field={@form[:stop_name]}
                  id="stops-map-edit-name"
                  errors={field_errors(@errors, "stop_name")}
                  type="text"
                  autocomplete="off"
                  class={text_input_class(Map.has_key?(@errors, "stop_name"))}
                />
                <p class="m-0 mt-1 text-[13px] text-muted">
                  Riders see this on signs and in trip planners: the street the bus is on, then the
                  cross street or a landmark people know.
                </p>
              </div>

              <div :if={@stop.location_type == 0}>
                <label for="stops-map-edit-desc" class="block text-sm font-semibold text-strong">
                  Description <span class="font-normal text-muted">(optional)</span>
                </label>
                <.input
                  field={@form[:stop_desc]}
                  id="stops-map-edit-desc"
                  type="text"
                  autocomplete="off"
                  class="h-11 w-full rounded-control border border-control px-3 text-[15px]"
                />
                <p class="m-0 mt-1 text-[13px] text-muted">
                  Tells apart stops with the same name, such as the two sides of a street.
                </p>
              </div>

              <div :if={@stop.location_type == 0}>
                <label for="stops-map-edit-code" class="block text-sm font-semibold text-strong">
                  Sign number <span class="font-normal text-muted">(optional)</span>
                </label>
                <.input
                  field={@form[:stop_code]}
                  id="stops-map-edit-code"
                  type="text"
                  inputmode="numeric"
                  autocomplete="off"
                  class="h-11 max-w-[180px] rounded-control border border-control px-3 font-mono text-[15px]"
                />
                <p class="m-0 mt-1 text-[13px] text-muted">
                  The number on the sign riders use to look up arrivals.
                </p>
              </div>

              <fieldset class="m-0 min-w-0 border-0 p-0">
                <legend class="p-0 text-sm font-semibold text-strong">Wheelchair access</legend>
                <div class="mt-1.5 flex flex-wrap gap-x-5">
                  <label
                    :for={{value, label} <- wheelchair_choices()}
                    class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-[15px] text-strong"
                  >
                    <input
                      type="radio"
                      id={"stops-map-edit-wb-#{value}"}
                      name="stop[wheelchair_boarding]"
                      value={value}
                      checked={@form[:wheelchair_boarding].value == value}
                      class="size-4 accent-action"
                    />
                    {label}
                  </label>
                </div>
                <p class="m-0 mt-1 text-[13px] text-muted">
                  Leave Not recorded until someone has checked the stop, its landing pad and its
                  route to the curb.
                </p>
              </fieldset>

              <div :if={@stop.location_type == 0}>
                <p class="m-0 text-sm font-semibold text-strong" id="stops-map-edit-zone-label">
                  Fare zone
                </p>
                <%!-- Read-only, and a link rather than a select: zone assignment is
                     Settings › Fares', so this panel states the stop's zone and
                     sends the editor where it can be changed. --%>
                <p class="m-0 mt-1 text-[15px] text-strong" id="stops-map-edit-zone">
                  {zone_text(@zone_id, @zone_name)}
                </p>
                <p class="m-0 mt-1 text-[13px] text-muted">
                  Zones are managed in <.link
                    id="stops-map-edit-zone-link"
                    navigate={@zone_href}
                    class="font-semibold text-action underline underline-offset-4"
                  >
                    Settings &rsaquo; Fares &rsaquo; Zones
                  </.link>.
                </p>
              </div>
            </div>

            <.edit_usage id="stops-map-edit-used" usage={@usage} station?={@stop.location_type == 1} />

            <div class="mt-7">
              <.edit_tech form={@form} stop={@stop} open?={@tech_open?} />
            </div>

            <div class="mt-7 flex flex-wrap items-center gap-3">
              <p
                id="stops-map-edit-status"
                role="status"
                class={[
                  "m-0 mr-auto text-[13px]",
                  @dirty? && "font-semibold text-warning-fg",
                  !@dirty? && "text-muted"
                ]}
              >
                {if @saving?,
                  do: "Saving…",
                  else: if(@dirty?, do: "Unsaved changes", else: "No changes yet")}
              </p>
              <button
                id="stops-map-edit-cancel"
                type="button"
                phx-click="cancel_edit"
                disabled={@saving?}
                class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas disabled:opacity-70"
              >
                Cancel
              </button>
              <.button
                id="stops-map-edit-save"
                type="submit"
                class="min-h-11"
                disabled={@saving? or not @dirty?}
              >
                {if @saving?,
                  do: "Saving…",
                  else:
                    if(@move && @move.band != :correction && @stop.routes != [],
                      do: "Review move",
                      else: "Save changes"
                    )}
              </.button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- One dialog for every exit. It is a dialog rather than a panel of its
           own because the question is the same each time and the answer is one
           of two buttons; the pending exit lives in `@discard_action`, so
           Escape, Cancel and choosing another stop share one question and one
           answer rather than three copies of it. --%>
      <.confirm_dialog
        id="stops-map-discard"
        chrome="planner"
        open={@discard_action != nil}
        title={discard_title(@discard_action, @stop)}
        cancel_label="Keep editing"
        cancel_id="stops-map-discard-keep"
        on_cancel="keep_editing"
        confirm_label="Discard changes"
        confirm_id="stops-map-discard-go"
        pending_label="Discarding…"
        on_confirm="discard_changes"
        pending={false}
        described_by="stops-map-discard-body"
      >
        {discard_body(@discard_action)}
      </.confirm_dialog>
    </aside>
    """
  end

  @doc """
  The move review: what a move this far would change, and the two answers.

  A move past the correction band is not a save, because a stop's position is
  what its riders recognise and what the pattern lines run past. The panel
  therefore asks two questions — whether this is the same stop at all, past the
  far band, and what happens to the lines either side of the stop — and writes
  nothing until both are answered.
  """
  attr :id, :string, required: true
  attr :stop, :map, default: nil
  attr :review, :map, default: nil
  attr :loading?, :boolean, default: false
  attr :distance, :any, default: nil
  attr :lines, :atom, default: :redraw
  attr :answer, :atom, default: nil
  attr :errors, :list, default: []
  attr :saving?, :boolean, default: false
  attr :outcome, :atom, default: :none
  attr :saved, :map, default: nil

  def move_review_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label="Review move"
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-5 py-5">
          <h2
            id="stops-map-move-heading"
            tabindex="-1"
            autofocus
            class="font-display text-[22px] font-semibold text-strong"
          >
            Review move
          </h2>
          <p class="m-0 mt-1 text-sm text-muted">
            {(@stop && @stop.name) || "This stop"}
          </p>

          <%!-- The review is read outside the command's transaction, so it is
               a line the panel waits on rather than a frozen form. --%>
          <div :if={@loading?} id="stops-map-move-loading" role="status" class="mt-5">
            <.message kind="info" title="Reading the lines that pass here">
              Working out which patterns this move would change&hellip;
            </.message>
          </div>

          <div :if={@outcome == :review_failed} id="stops-map-move-review-failed" class="mt-5">
            <.message
              kind="error"
              title="We couldn’t review this move"
              id="stops-map-move-review-failed-message"
            >
              Nothing was saved and your edits are still here. Go back to editing and save
              again in a moment.
            </.message>
          </div>

          <div :if={@outcome == :stale_review} id="stops-map-move-stale" class="mt-5">
            <.message
              kind="warning"
              title="This stop changed while you were reviewing"
              id="stops-map-move-stale-message"
            >
              Nothing was saved. Someone else changed this stop after the review was read, so the
              lines above no longer describe it. Close the panel, look at the stop again, and move it
              once more.
            </.message>
          </div>

          <div :if={@outcome == :move_failed} id="stops-map-move-failed" class="mt-5">
            <.message
              kind="error"
              title="We couldn’t save this move"
              id="stops-map-move-failed-message"
            >
              Nothing was changed. Your edits are still here. Check your connection and try again.
            </.message>
          </div>

          <div :if={@errors != []} id="stops-map-move-errors" class="mt-5">
            <.message
              kind="error"
              title="This move needs an answer"
              id="stops-map-move-errors-message"
            >
              <ul class="m-0 list-disc pl-5">
                <li :for={message <- @errors}>{message}</li>
              </ul>
            </.message>
          </div>

          <%= if @review do %>
            <p id="stops-map-move-distance" class="m-0 mt-5 text-[15px] font-semibold text-strong">
              Moves {feet(@review.distance_m)} of where the stop was.
            </p>
            <p :if={@review.band != :far} class="m-0 mt-2 text-sm">
              It keeps ID {@stop && @stop.stop_id}, so riders&rsquo; saved stops and real-time arrivals
              follow it.
            </p>

            <.far_choice
              id="stops-map-move-far"
              review={@review}
              band={@review.band}
              answer={@answer}
              stop={@stop}
            />

            <fieldset
              :if={@answer != :new}
              class="m-0 mt-6 min-w-0 border-0 p-0"
              id="stops-map-move-lines"
            >
              <legend class="p-0 text-[15px] font-bold text-strong">
                {length(@review.patterns)} patterns stop here
              </legend>
              <ul id="stops-map-move-patterns" class="m-0 mt-2 list-none p-0 text-sm">
                <li
                  :for={pattern <- @review.patterns}
                  id={"stops-map-move-pattern-#{dom_id(pattern.route_pattern_id)}"}
                  class="flex items-start gap-2 py-1.5"
                >
                  <.route_badge
                    :if={pattern_route(@stop, pattern)}
                    route={pattern_route(@stop, pattern)}
                  />
                  <span>
                    toward {pattern.headsign || "the end of the line"}
                    <span class="block text-[13px] text-muted">
                      Line from {pattern.from_name || "the start"} to {pattern.to_name || "the end"} changes: {outcome_words(
                        pattern.outcome
                      )}
                    </span>
                  </span>
                </li>
              </ul>

              <p class="m-0 mt-3 text-sm font-semibold text-strong">Their map lines</p>
              <label class="mt-1 flex min-h-11 cursor-pointer items-start gap-3 py-1">
                <input
                  type="radio"
                  name="move[lines]"
                  value="redraw"
                  checked={@lines == :redraw}
                  phx-click="move_choice"
                  phx-value-lines="redraw"
                  class="mt-1 size-4 accent-action"
                />
                <span>
                  <span class="block text-[15px] text-strong">Redraw along the streets</span>
                  <span class="block text-[13px] text-muted">
                    Recommended. Only the highlighted sections change.
                  </span>
                </span>
              </label>
              <label class="flex min-h-11 cursor-pointer items-start gap-3 py-1">
                <input
                  type="radio"
                  name="move[lines]"
                  value="keep"
                  checked={@lines == :keep}
                  phx-click="move_choice"
                  phx-value-lines="keep"
                  class="mt-1 size-4 accent-action"
                />
                <span>
                  <span class="block text-[15px] text-strong">Keep the old lines for now</span>
                  <span class="block text-[13px] text-muted">
                    The sections are marked out of date in each pattern&rsquo;s map.
                  </span>
                </span>
              </label>
            </fieldset>

            <section class="mt-6">
              <h3 class="m-0 text-[15px] font-bold text-strong">Also changes</h3>
              <ul
                id="stops-map-move-also"
                class="m-0 mt-1 list-none divide-y divide-subtle p-0 text-sm"
              >
                <li :for={line <- also_changes(@review, @stop)} class="py-2">{line}</li>
              </ul>
            </section>

            <div :if={@answer == :new} class="mt-5">
              <p id="stops-map-move-new" class="m-0 text-sm">
                Next you&rsquo;ll name the new stop. Its patterns can then use it in place of {(@stop &&
                                                                                                  @stop.name) ||
                  "this stop"} with Replace.
              </p>
            </div>
          <% end %>
        </div>
      </div>

      <div class="border-t border-subtle px-5 py-4">
        <div class="flex flex-wrap items-center gap-3">
          <button
            id="stops-map-move-back"
            type="button"
            phx-click="back_to_edit"
            disabled={@saving?}
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas disabled:opacity-70"
          >
            Back to editing
          </button>
          <.button
            id="stops-map-move-save"
            type="button"
            phx-click="save_move"
            disabled={@saving? or @review == nil}
            class="ml-auto min-h-11"
          >
            {if @answer == :new,
              do: "Continue to new stop",
              else: if(@saving?, do: "Saving…", else: "Save move")}
          </.button>
        </div>
      </div>
    </aside>
    """
  end

  defp far_choice(assigns) do
    assigns = assign(assigns, :id, "stops-map-move-far")

    ~H"""
    <fieldset
      :if={@band == :far}
      class="m-0 mt-5 min-w-0 border-0 p-0"
      id="stops-map-move-far"
      tabindex="-1"
    >
      <legend class="p-0 text-[15px] font-bold text-strong">Is this the same stop?</legend>
      <label class="mt-1 flex min-h-11 cursor-pointer items-start gap-3 py-1">
        <input
          type="radio"
          name="move[answer]"
          value="same"
          checked={@answer == :same}
          phx-click="move_choice"
          phx-value-answer="same"
          class="mt-1 size-4 accent-action"
        />
        <span>
          <span class="block text-[15px] text-strong">Yes, the same stop has moved here</span>
          <span class="block text-[13px] text-muted">
            It keeps ID {@stop && @stop.stop_id}. Riders&rsquo; saved stops and real-time arrivals
            follow it to the new place.
          </span>
        </span>
      </label>
      <label class="flex min-h-11 cursor-pointer items-start gap-3 py-1">
        <input
          type="radio"
          name="move[answer]"
          value="new"
          checked={@answer == :new}
          phx-click="move_choice"
          phx-value-answer="new"
          class="mt-1 size-4 accent-action"
        />
        <span>
          <span class="block text-[15px] text-strong">No, this is a new stop</span>
          <span class="block text-[13px] text-muted">
            Creates a new stop here. The old stop stays where it is until you replace it or take it
            out of its patterns.
          </span>
        </span>
      </label>
    </fieldset>
    """
  end

  # The far-move question is asked only past the band where it changes the
  # answer: closer than that a move is a correction of this stop, not a claim
  # about which stop this is.

  # What one pattern's outcome means, in the words the reference uses. An outcome
  # the editor cannot act on is stated as the thing that happened rather than as
  # the atom that produced it.
  defp outcome_words(:redraw), do: "Will redraw."
  defp outcome_words(:no_line), do: "No line to redraw."
  defp outcome_words({:blocked, _reason}), do: "Blocked: trips don’t match the stops."

  defp outcome_words({:routing_failed, _reason}),
    do: "Blocked: the street route couldn’t be found."

  defp outcome_words(_other), do: "The line stays as it is."

  # The answer to "Replace with another stop…" when no stop is within reach. Both
  # buttons that ask the question show it where they are, so a press is never
  # answered by nothing.
  attr :id, :string, required: true
  attr :within, :string, required: true
  attr :class, :string, default: nil

  defp replace_none_message(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <.message kind="info" title="No stop to replace this one with" id={"#{@id}-message"}>
        No other stop is within {@within} of it.
      </.message>
    </div>
    """
  end

  defp moved_message(%{redrawn: [], stale: []}), do: "The stop is at its new position."

  defp moved_message(%{redrawn: redrawn, stale: []}) do
    "#{count_word(length(redrawn), "pattern", "patterns")} redrawn for the new position."
  end

  defp moved_message(%{redrawn: redrawn, stale: stale}) do
    "#{count_word(length(redrawn), "pattern", "patterns")} redrawn and #{count_word(length(stale), "pattern", "patterns")} marked out of date."
  end

  # "Also changes" is everything the review read that the move does not change
  # by writing: what the editor should expect to be different afterwards.
  defp also_changes(review, stop) do
    weekday = review.weekday_trips

    transfers =
      Enum.map(review.transfers, fn transfer ->
        "Transfer to #{transfer.label}: the walk becomes #{feet(transfer.after_m)} " <>
          "(was #{feet(transfer.before_m)}). The #{transfer.min_transfer_time}-minute minimum " <>
          "still covers it."
      end)

    relief =
      Enum.map(review.relief_points, fn relief ->
        "#{relief}. The relief point moves with the stop."
      end)

    [
      "#{count_word(weekday, "weekday trip", "weekday trips")} keep their scheduled times. " <>
        "Times estimated between timepoints are worked out again from the new distances at export."
    ] ++ transfers ++ relief ++ [fare_zone_line(stop)]
  end

  defp fare_zone_line(%{zone_id: nil}),
    do: "Fare zone stays the same — this stop is not in a zone."

  defp fare_zone_line(_stop), do: "Fare zone stays the same."

  defp pattern_route(%{routes: routes}, pattern) when is_list(routes),
    do: Enum.find(routes, &(&1.route_id == pattern.route_id))

  defp pattern_route(_stop, _pattern), do: nil

  # The panel states distances in feet because a curb is measured in feet; the
  # whole number is what an editor can act on, and anything under a foot is a
  # rounding difference rather than a move.
  defp feet(nil), do: ""

  defp feet(metres) do
    whole = (metres * 3.280839895) |> round()

    if whole < 1, do: "less than a foot", else: "#{whole} ft"
  end

  defp count_word(1, singular, _plural), do: "1 #{singular}"
  defp count_word(count, _singular, plural), do: "#{count} #{plural}"

  @doc """
  "Where it's used": what names this stop besides its own row.

  `StopReferences.usage/3` answers with a count per kind and, for the kinds an
  editor acts on, the rows themselves. Only the blocking list is rendered: a
  descriptive reference is context for the delete and replace panels, and
  listing it here would make the panel taller than the information it carries.
  """
  attr :id, :string, required: true
  attr :usage, :any, default: nil
  attr :station?, :boolean, default: false

  def edit_usage(assigns) do
    ~H"""
    <section :if={not @station?} class="mt-7">
      <h3 class="m-0 text-[15px] font-bold text-strong">Where it&rsquo;s used</h3>

      <div :if={@usage == nil} id={"#{@id}-loading"} role="status" class="mt-1 text-sm text-muted">
        Reading what uses this stop&hellip;
      </div>

      <p :if={@usage != nil and usage_rows(@usage) == []} id={"#{@id}-empty"} class="m-0 mt-1 text-sm">
        Nothing uses this stop. No pattern, rule or run names it.
      </p>

      <ul
        :if={@usage != nil and usage_rows(@usage) != []}
        id={"#{@id}-items"}
        class="m-0 mt-1 list-none divide-y divide-subtle p-0 text-sm"
      >
        <li :for={row <- usage_rows(@usage)} id={row.dom_id} class="flex items-center gap-2 py-1.5">
          <.route_badge :if={row.route} route={row.route} />
          <span :if={row.headsign} class="toward {row.headsign}">toward {row.headsign}</span>
          <span :if={is_nil(row.route) and is_nil(row.headsign)} class="min-w-0 flex-1">
            {row.text}
          </span>
          <span
            :if={row.trips}
            class="ml-auto text-[13px] text-muted"
            title="Trips that run Monday to Friday"
          >
            {row.trips} weekday trips
          </span>
          <span :if={is_nil(row.trips)} class="ml-auto text-[13px] text-muted">{row.count_text}</span>
        </li>
      </ul>

      <p :if={@usage != nil and usage_rows(@usage) != []} class="m-0 mt-1 text-[13px] text-muted">
        A move redraws these patterns&rsquo; lines next to the stop; you review it before saving.
      </p>
    </section>
    """
  end

  # The usage read answers with a count per kind, and with the rows themselves
  # for the kinds an editor acts on. A pattern is the row worth naming — which
  # route, which way, and how much service — because that is what a rider
  # recognises about the stop, so it is rendered as a row rather than a total.
  # Every other kind is one line each, with its count, because the panel's claim
  # is that the stop is in use and these are the kinds that put it there.
  defp usage_rows(%{blocking: blocking}) do
    Enum.flat_map(blocking, &usage_item_rows/1)
  end

  defp usage_item_rows(%{key: :route_pattern_stops, details: details}) do
    Enum.map(details, fn detail ->
      %{
        dom_id: "stops-map-edit-used-pattern-#{dom_id(detail.detail.route_pattern_id)}",
        route: pattern_route(detail.detail),
        headsign: detail.detail.headsign,
        trips: detail.weekday_trips,
        text: nil,
        count_text: nil
      }
    end)
  end

  defp usage_item_rows(%{key: key, label: label, count: count, details: details}) do
    if details == [] do
      [
        %{
          dom_id: "stops-map-edit-used-#{key}",
          route: nil,
          headsign: nil,
          trips: nil,
          text: label,
          count_text: "#{count} #{pluralize(count, "row")}"
        }
      ]
    else
      Enum.map(details, fn detail ->
        %{
          dom_id: "stops-map-edit-used-#{key}-#{dom_id(detail.label)}",
          route: nil,
          headsign: nil,
          trips: nil,
          text: "#{label}: #{detail.label}",
          count_text: nil
        }
      end)
    end
  end

  # The badge takes the shape the browse rows already use, so a route reads the
  # same wherever it appears. A pattern with no route colour falls back to the
  # panel's own ink inside `route_badge/1`.
  defp pattern_route(detail) do
    %{
      short_name: detail.route_short_name || detail.route_id,
      long_name: detail.route_id,
      color: detail.route_color
    }
  end

  # DOM ids carry a feed's own strings, which are GTFS IDs (letters, digits,
  # underscores, dashes) but here also stop names. Anything else is replaced and
  # given a hash, so a feed cannot inject markup or make two rows share an id.
  defp dom_id(value) when is_binary(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9_-]+\z/) do
      value
    else
      safe = String.replace(value, ~r/[^A-Za-z0-9_-]/, "-")
      "#{safe}-#{:erlang.phash2(value)}"
    end
  end

  defp dom_id(_value), do: "unknown"

  @doc """
  A station's bays: the stops that name it as their parent.

  Trips stop at bays, not at the station, so a station's own row is not where an
  editor moves riders. Each bay carries its ID, which is what a pattern's stop
  list holds.
  """
  attr :bays, :list, required: true

  def bays_block(assigns) do
    ~H"""
    <section>
      <h3 class="m-0 text-[15px] font-bold text-strong">Bays</h3>
      <ul
        :if={@bays != []}
        id="stops-map-edit-bay-items"
        class="m-0 mt-1 list-none divide-y divide-subtle p-0 text-sm"
      >
        <li
          :for={bay <- @bays}
          id={"stops-map-edit-bay-#{bay.dom_id}"}
          class="flex items-center gap-3 py-2"
        >
          <span class="min-w-0 flex-1">
            <span class="block truncate">{bay.name}</span>
            <span class="block font-mono text-[13px] text-muted">ID {bay.stop_id}</span>
          </span>
        </li>
      </ul>
      <p :if={@bays == []} id="stops-map-edit-bay-empty" class="m-0 mt-1 text-sm text-muted">
        No bays yet. Add them on the station page.
      </p>
      <p class="m-0 mt-1 text-[13px] text-muted">
        Trips stop at bays. Add bays, entrances and walkways on the station page.
      </p>
    </section>
    """
  end

  @doc """
  The delete panels: why a stop cannot be deleted yet, and what deleting it
  would remove when it can.

  One panel with two states, because the question is the same one asked twice.
  `delete_mode/1` answers which state the review's own contents call for — a
  blocking row makes the answer "not yet", and its absence makes the answer
  "here is what goes" — so the panel cannot show a Delete button beside rows
  that would refuse it, and cannot show a refusal for a stop nothing uses.

  The blocked state has no primary action on purpose: the ways out of it are
  edits elsewhere in the feed, and offering a button here would invite a
  deletion that writes nothing.
  """
  attr :id, :string, required: true
  attr :stop, :map, required: true
  attr :review, :any, default: nil
  attr :loading?, :boolean, default: false
  attr :version_id, :any, default: nil
  attr :saving?, :boolean, default: false
  attr :outcome, :atom, default: :none
  attr :replace_none_within, :string, default: nil

  def delete_panel(assigns) do
    assigns = assign(assigns, :mode, delete_mode(assigns.review))

    ~H"""
    <aside
      id={@id}
      aria-label="Delete stop"
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-5 py-5">
          <h2
            id="stops-map-delete-heading"
            tabindex="-1"
            autofocus
            class="font-display text-[22px] font-semibold text-strong"
          >
            {if @mode == :blocked and @review,
              do: "Can’t delete #{@stop.name} yet",
              else: "Delete #{@stop.name}?"}
          </h2>
          <p class="m-0 mt-1 text-sm text-muted">
            {delete_subtitle(@stop, @mode)}
          </p>

          <div :if={@loading?} id="stops-map-delete-loading" role="status" class="mt-5">
            <.message kind="info" title="Reading what uses this stop">
              Checking the patterns, runs and rules that name it&hellip;
            </.message>
          </div>

          <div :if={@outcome == :refused and @review} id="stops-map-delete-refused" class="mt-5">
            <.message
              kind="warning"
              role="status"
              title="Nothing was deleted."
              id="stops-map-delete-refused-message"
            >
              What uses this stop changed while the question was open, so the delete was refused
              rather than removing a row you were not shown. Nothing was changed; here is what uses
              it now.
            </.message>
          </div>

          <div :if={@outcome == :failed} id="stops-map-delete-failed" class="mt-5">
            <.message
              kind="error"
              title={
                if @review,
                  do: "We couldn’t delete this stop",
                  else: "We couldn’t check what uses this stop"
              }
              id="stops-map-delete-failed-message"
            >
              Nothing was changed. Check your connection and try again.
            </.message>
          </div>

          <%= if @mode == :blocked and @review do %>
            <div id="stops-map-delete-blocked-message" class="mt-5">
              <.message kind="warning" role="status" title={blocked_title(@review)}>
                Deleting it would change service, so the stop stays until nothing schedules a visit
                here.
              </.message>
            </div>

            <h3 class="mb-0 mt-6 text-[15px] font-bold text-strong">Still using this stop</h3>
            <ul
              id="stops-map-delete-blocked-list"
              class="m-0 mt-1 list-none divide-y divide-subtle border-y border-subtle p-0 text-sm"
            >
              <li
                :for={row <- delete_blocked_rows(@review, @version_id)}
                id={row.dom_id}
                class="flex items-center gap-3 py-2.5"
              >
                <span class="w-[76px] shrink-0 text-[13px] text-muted">{row.kind}</span>
                <.route_badge :if={row.route} route={row.route} />
                <span class="min-w-0 flex-1">
                  {row.text}
                  <span :if={row.sub} class="block text-[13px] text-muted">{row.sub}</span>
                </span>
                <.link
                  :if={row.href}
                  id={row.link_id}
                  navigate={row.href}
                  class="inline-flex min-h-11 items-center text-sm font-semibold text-action no-underline hover:underline"
                >
                  Open
                </.link>
              </li>
            </ul>

            <h3 class="mb-0 mt-6 text-[15px] font-bold text-strong">To get unstuck</h3>
            <ul class="m-0 mt-2 grid list-none gap-3 p-0 text-sm">
              <li>
                <span class="font-semibold text-strong">The stop is closing:</span>
                remove it from each pattern in the pattern editor. Trips then skip it, and you can
                delete it here.
              </li>
              <li>
                <span class="font-semibold text-strong">Another stop serves the same place:</span>
                replace it. Patterns, trips and rules move to the other stop in one reviewed step.
              </li>
            </ul>

            <button
              id="stops-map-delete-replace"
              type="button"
              phx-click="start_replace"
              class="mt-4 inline-flex min-h-11 items-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas"
            >
              <.icon name="hero-arrows-right-left" class="size-4" /> Replace with another stop…
            </button>

            <.replace_none_message
              :if={@replace_none_within}
              id="stops-map-delete-replace-none"
              within={@replace_none_within}
              class="mt-3"
            />

            <p :if={delete_pending_count(@review) > 0} class="m-0 mt-6 text-[13px] text-muted">
              When it can be deleted, its {count_word(
                delete_pending_count(@review),
                "transfer rule",
                "transfer rules"
              )}
              {if delete_pending_count(@review) == 1, do: "is", else: "are"} removed with it.
            </p>
          <% end %>

          <%= if @mode == :confirm and @review do %>
            <p id="stops-map-delete-clear" class="m-0 mt-5 text-[15px] text-strong">
              No pattern or trip stops here, and no run changes drivers here.
            </p>

            <%= if delete_removed(@review) != [] do %>
              <h3 class="mb-0 mt-5 text-[15px] font-bold text-strong">Removed with it</h3>
              <ul
                id="stops-map-delete-removed"
                class="m-0 mt-1 list-disc pl-5 text-sm"
              >
                <li :for={row <- delete_removed(@review)} id={row.dom_id} class="py-0.5">
                  {row.text}
                </li>
              </ul>
            <% end %>

            <p class="m-0 mt-5 text-sm">
              The deletion is recorded in this version&rsquo;s history. Other versions keep their copy
              of the stop.
            </p>
            <p class="m-0 mt-2 text-sm">
              Closed only for a season? Keep it instead. A stop with no trips still exports, and
              when service returns it is there with the same ID and sign number.
            </p>
          <% end %>
        </div>
      </div>

      <div class="border-t border-subtle px-5 py-4">
        <div class="flex flex-wrap items-center gap-3">
          <button
            id="stops-map-delete-keep"
            type="button"
            phx-click="back_to_edit"
            disabled={@saving?}
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas disabled:opacity-70"
          >
            {if @mode == :blocked, do: "Back to stop", else: "Keep stop"}
          </button>
          <button
            :if={@mode == :blocked}
            id="stops-map-delete-close"
            type="button"
            phx-click="cancel_edit"
            disabled={@saving?}
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas disabled:opacity-70"
          >
            Close
          </button>

          <.button
            :if={@mode == :confirm}
            id="stops-map-delete-go"
            type="button"
            phx-click="delete_stop"
            variant="danger"
            disabled={@saving? or @review == nil}
            class="ml-auto min-h-11"
          >
            {if @saving?,
              do: "Deleting…",
              else: "Delete #{if @stop.location_type == 1, do: "station", else: "stop"}"}
          </.button>
        </div>
      </div>
    </aside>
    """
  end

  # The state is the review's own answer, not a param: a blocking row means the
  # delete cannot happen, and the command refuses on exactly those rows, so the
  # panel asking for a confirmation beside one would be asking for a write the
  # command would roll back.
  defp delete_mode(%{blocking: [_ | _]}), do: :blocked
  defp delete_mode(%{blocking: []}), do: :confirm
  defp delete_mode(_no_review), do: :blocked

  defp delete_subtitle(stop, :confirm) do
    if stop.location_type == 1 do
      "Station · ID #{stop.stop_id}"
    else
      "Stop · ID #{stop.stop_id}#{if stop.routes == [], do: " · Not served", else: ""}"
    end
  end

  defp delete_subtitle(stop, _mode), do: "Stop · ID #{stop.stop_id}"

  # The message names what blocks it in the editor's terms: the patterns and the
  # weekday service they carry, which is what stopping here costs.
  defp blocked_title(review) do
    patterns = delete_pattern_count(review)
    trips = delete_weekday_trips(review)

    cond do
      patterns > 0 and trips > 0 ->
        "#{patterns} #{pluralize(patterns, "pattern")} and #{trips} weekday trips stop here"

      patterns > 0 ->
        "#{patterns} #{pluralize(patterns, "pattern")} stop here"

      trips > 0 ->
        "#{trips} weekday trips stop here"

      true ->
        "Something else still uses this stop"
    end
  end

  defp delete_pattern_count(review) do
    case Enum.find(review.blocking, &(&1.key == :route_pattern_stops)) do
      nil -> 0
      item -> length(item.details)
    end
  end

  defp delete_weekday_trips(review) do
    case Enum.find(review.blocking, &(&1.key == :route_pattern_stops)) do
      nil ->
        0

      item ->
        item.details
        |> Enum.map(&Map.get(&1, :weekday_trips, 0))
        |> Enum.sum()
    end
  end

  # Every blocking row, one per thing that names the stop, with a link to where
  # it is edited when there is one place to edit it. A pattern opens in the
  # pattern editor, a run opens on the runs page, and a station's own structure
  # is edited on the station page — the three places a reader can act on.
  defp delete_blocked_rows(review, version_id) do
    Enum.flat_map(review.blocking, &delete_blocked_item(&1, version_id))
  end

  defp delete_blocked_item(%{key: :route_pattern_stops, details: details}, version_id) do
    Enum.map(details, fn detail ->
      pattern = detail.detail

      %{
        dom_id: "stops-map-delete-blocked-pattern-#{dom_id(pattern.route_pattern_id)}",
        link_id: "stops-map-delete-open-pattern-#{dom_id(pattern.route_pattern_id)}",
        kind: "Pattern",
        route: pattern_route(pattern),
        text: "toward #{pattern.headsign || "the end of the line"}",
        sub: "#{detail.weekday_trips} weekday trips",
        href: pattern_href(version_id, pattern)
      }
    end)
  end

  defp delete_blocked_item(%{key: :relief_points, details: details}, version_id) do
    Enum.map(details, fn detail ->
      %{
        dom_id: "stops-map-delete-blocked-run-#{dom_id(detail.label)}",
        link_id: "stops-map-delete-open-run-#{dom_id(detail.label)}",
        kind: "Runs",
        route: nil,
        text: detail.label,
        sub: nil,
        href: version_id && "/gtfs/#{version_id}/runs"
      }
    end)
  end

  defp delete_blocked_item(%{key: :child_stops, details: details}, version_id) do
    Enum.map(details, fn detail ->
      %{
        dom_id: "stops-map-delete-blocked-bay-#{dom_id(detail.detail.stop_id)}",
        link_id: "stops-map-delete-open-bay-#{dom_id(detail.detail.stop_id)}",
        kind: "Bays",
        route: nil,
        text: "#{detail.label} · ID #{detail.detail.stop_id}",
        sub: nil,
        href: version_id && "/gtfs/#{version_id}/stops/#{detail.detail.stop_id}"
      }
    end)
  end

  defp delete_blocked_item(%{key: key, label: label, count: count, details: details}, version_id) do
    if details == [] do
      [
        %{
          dom_id: "stops-map-delete-blocked-#{key}",
          link_id: nil,
          kind: "",
          route: nil,
          text: "#{count_word(count, "row", "rows")} in #{label}",
          sub: nil,
          href: stop_page_href(version_id, key)
        }
      ]
    else
      Enum.map(details, fn detail ->
        %{
          dom_id: "stops-map-delete-blocked-#{key}-#{dom_id(detail.label)}",
          link_id: nil,
          kind: "",
          route: nil,
          text: "#{label}: #{detail.label}",
          sub: nil,
          href: nil
        }
      end)
    end
  end

  # Only a station's own rows lead somewhere an editor can change them, and even
  # those are read on the station page rather than edited from here, so a link
  # that went nowhere useful would be worse than no link.
  defp stop_page_href(_version_id, _key), do: nil

  defp pattern_href(nil, _pattern), do: nil

  defp pattern_href(version_id, pattern) do
    "/gtfs/#{version_id}/routes/#{pattern.route_id}/patterns/#{pattern.route_pattern_id}"
  end

  # What a delete removes, named row by row. A count cannot be read here — "1
  # translations" tells an editor nothing about the Spanish name that is about to
  # go — so a kind with details is listed by them.
  defp delete_removed(review) do
    Enum.flat_map(review.descriptive, &delete_removed_item/1)
  end

  defp delete_removed_item(%{key: key, label: label, count: count, details: details}) do
    cond do
      key in [:transfers_from, :transfers_to] and details != [] ->
        Enum.map(details, fn detail ->
          %{
            dom_id: "stops-map-delete-removed-#{key}-#{dom_id(detail.label)}",
            text: "Transfer rule to #{detail.label}"
          }
        end)

      details == [] ->
        [
          %{
            dom_id: "stops-map-delete-removed-#{key}",
            text: "#{count_word(count, "row", "rows")} in #{label}"
          }
        ]

      true ->
        Enum.map(details, fn detail ->
          %{
            dom_id: "stops-map-delete-removed-#{key}-#{dom_id(detail.label)}",
            text: detail.label
          }
        end)
    end
  end

  defp delete_pending_count(review) do
    review.descriptive
    |> Enum.filter(
      &(&1.key in [:transfers_from, :transfers_to, :fare_leg_join_from, :fare_leg_join_to])
    )
    |> Enum.map(& &1.count)
    |> Enum.sum()
  end

  @doc """
  The make-station panel: what a station is for, and the two things it needs.

  A station is a name riders look for with bays under it, so the panel leads
  with that and then says the thing that makes the operation safe: the stop
  keeps its ID, so every trip, transfer and fare zone that names it keeps
  naming it. The station name is a suggestion until the editor edits it — the
  landmark is a starting point, not the answer.
  """
  attr :id, :string, required: true
  attr :stop, :map, required: true
  attr :form, :any, required: true
  attr :usage, :any, default: nil
  attr :landmark, :any, default: nil
  attr :loading?, :boolean, default: false
  attr :errors, :map, default: %{}
  attr :refusal, :string, default: nil
  attr :saving?, :boolean, default: false

  def station_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label="Make this stop a station"
      phx-hook="FormErrorFocus"
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-5 py-5">
          <h2
            id="stops-map-station-heading"
            tabindex="-1"
            autofocus
            class="font-display text-[22px] font-semibold text-strong"
          >
            Make {@stop.name} a station
          </h2>
          <p class="m-0 mt-1 text-sm text-muted">Stop · ID {@stop.stop_id}</p>

          <div :if={@loading?} id="stops-map-station-loading" role="status" class="mt-5">
            <.message kind="info" title="Looking for a landmark">
              Finding the place riders know this corner by&hellip;
            </.message>
          </div>

          <p id="stops-map-station-why" class="m-0 mt-5 text-[15px] text-strong">
            A station groups bays under one name that riders look for, like Newport Transit Center.
          </p>
          <p id="stops-map-station-keeps" class="m-0 mt-2 text-sm">
            This stop becomes the station&rsquo;s first bay. It keeps ID {@stop.stop_id} and its sign
            number, so its {station_trips_text(@usage)} stay as they are.
          </p>

          <div :if={@refusal} id="stops-map-station-refused" class="mt-5">
            <.message
              kind="warning"
              role="status"
              title="This stop is already part of a station"
              id="stops-map-station-refused-message"
            >
              {@refusal}
            </.message>
          </div>

          <div :if={@errors != %{}} id="stops-map-station-errors" class="mt-5">
            <.message
              kind="error"
              title="Fix this to create the station"
              id="stops-map-station-errors-message"
            >
              <ul class="m-0 list-disc pl-5">
                <li :for={{field, message} <- station_error_rows(@errors)}>
                  <a
                    href={"#stops-map-station-#{field}"}
                    class="font-semibold text-error-fg underline"
                  >
                    {message}
                  </a>
                </li>
              </ul>
            </.message>
          </div>

          <.form
            :if={is_nil(@refusal)}
            for={@form}
            id="stops-map-station-form"
            phx-change="station_field"
            phx-submit="create_station"
          >
            <div class="mt-6 grid gap-5">
              <div>
                <label for="stops-map-station-name" class="block text-sm font-semibold text-strong">
                  Station name
                </label>
                <.input
                  field={@form[:station_name]}
                  id="stops-map-station-name"
                  type="text"
                  autocomplete="off"
                  class={text_input_class(Map.has_key?(@errors, "station_name"))}
                />
                <p
                  :if={@landmark}
                  id="stops-map-station-landmark"
                  class="m-0 mt-1 text-[13px] text-muted"
                >
                  Suggested from the nearest landmark, {@landmark}.
                </p>
                <p :if={is_nil(@landmark)} class="m-0 mt-1 text-[13px] text-muted">
                  Use the name riders look for.
                </p>
              </div>

              <div>
                <label for="stops-map-station-bay" class="block text-sm font-semibold text-strong">
                  This stop&rsquo;s bay
                </label>
                <.input
                  field={@form[:platform_code]}
                  id="stops-map-station-bay"
                  type="text"
                  autocomplete="off"
                  class="h-11 w-full max-w-[120px] rounded-control border border-control px-3 font-mono text-[15px]"
                />
                <p id="stops-map-station-bay-note" class="m-0 mt-1 text-[13px] text-muted">
                  Its name becomes {bay_name_preview(@form)}. Add the other bays on the station page.
                </p>
              </div>
            </div>
          </.form>
        </div>
      </div>

      <div class="border-t border-subtle px-5 py-4">
        <div class="flex flex-wrap items-center gap-3">
          <button
            id="stops-map-station-cancel"
            type="button"
            phx-click="back_to_edit"
            disabled={@saving?}
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas disabled:opacity-70"
          >
            Cancel
          </button>
          <.button
            :if={is_nil(@refusal)}
            id="stops-map-station-go"
            type="submit"
            form="stops-map-station-form"
            disabled={@saving?}
            class="ml-auto min-h-11"
          >
            {if @saving?, do: "Creating…", else: "Create station"}
          </.button>
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  The replace panel: which stop to keep, what moving everything to it changes,
  and the one button that does it.

  The candidates are a convenience rather than the limit — the panel says a
  stop can also be chosen by clicking it on the map — so the list is the nearest
  few rather than a picklist of everything in the version.

  The review and the refusal share the panel rather than being two of them: the
  refusals are the review's own answer, so an editor who picks a stop the
  command will refuse reads the words here instead of pressing a button that
  does nothing. There is no apply button at all in that state, for the same
  reason the blocked delete has none.
  """
  attr :id, :string, required: true
  attr :stop, :map, required: true
  attr :candidates, :list, default: []
  attr :with, :any, default: nil
  attr :usage, :any, default: nil
  attr :review, :any, default: nil
  attr :refusals, :list, default: []
  attr :loading?, :boolean, default: false
  attr :delete_old?, :boolean, default: true
  attr :saving?, :boolean, default: false
  attr :outcome, :atom, default: :none
  attr :saved, :map, default: nil

  def replace_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label="Replace stop"
      class="flex min-h-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-5 py-5">
          <h2
            id="stops-map-replace-heading"
            tabindex="-1"
            autofocus
            class="font-display text-[22px] font-semibold text-strong"
          >
            Replace {@stop.name}
          </h2>
          <p class="m-0 mt-1 text-sm text-muted">
            Stop · ID {@stop.stop_id} · move what uses it to another stop
          </p>

          <div :if={@loading?} id="stops-map-replace-loading" role="status" class="mt-5">
            <.message kind="info" title="Reading what would move">
              Working out what this stop is used by, and where it would go&hellip;
            </.message>
          </div>

          <div :if={@outcome == :failed} id="stops-map-replace-failed" class="mt-5">
            <.message
              kind="error"
              title="We couldn’t replace this stop"
              id="stops-map-replace-failed-message"
            >
              Nothing was changed. Check your connection and try again.
            </.message>
          </div>

          <fieldset class="m-0 mt-5 min-w-0 border-0 p-0" id="stops-map-replace-candidates">
            <legend class="p-0 text-[15px] font-bold text-strong">Keep this stop instead</legend>
            <div class="mt-2 grid gap-1">
              <label
                :for={candidate <- @candidates}
                id={"stops-map-replace-candidate-#{dom_id(candidate.stop_id)}"}
                class={[
                  "flex min-h-11 cursor-pointer items-start gap-3 rounded-control px-2 py-2 hover:bg-canvas",
                  (@with != nil and @with.stop_id == candidate.stop_id) && "bg-selection"
                ]}
              >
                <input
                  type="radio"
                  name="replace_with"
                  value={candidate.stop_id}
                  checked={@with != nil and @with.stop_id == candidate.stop_id}
                  phx-click="choose_replace"
                  phx-value-stop_id={candidate.stop_id}
                  class="mt-1 size-4 accent-action"
                />
                <span class="min-w-0 flex-1">
                  <span class="block text-[15px] font-semibold text-strong">{candidate.name}</span>
                  <span class="block text-[13px] text-muted">
                    {candidate.away} away · {candidate.desc || "no description"} · ID {candidate.stop_id}
                  </span>
                </span>
              </label>
            </div>
            <p class="m-0 mt-1 text-[13px] text-muted">
              Nearest first. You can also click a stop on the map.
            </p>
          </fieldset>

          <%= if @refusals != [] do %>
            <div id="stops-map-replace-refused" class="mt-5">
              <.message
                kind="warning"
                role="status"
                title="This replace would break something"
                id="stops-map-replace-refused-message"
              >
                <ul class="m-0 list-disc pl-5">
                  <li :for={reason <- replace_refusal_words(@refusals, @stop)}>{reason}</li>
                </ul>
              </.message>
            </div>
          <% end %>

          <%= if @review do %>
            <section :if={@outcome != :stale} class="mt-6">
              <h3 class="m-0 text-[15px] font-bold text-strong">What changes</h3>
              <ul
                id="stops-map-replace-changes"
                class="m-0 mt-1 list-none divide-y divide-subtle p-0 text-sm"
              >
                <li
                  :for={row <- replace_change_rows(@review, @usage, @with)}
                  id={row.dom_id}
                  class={["flex items-start gap-2 py-2", row.route && "flex items-center"]}
                >
                  <.route_badge :if={row.route} route={row.route} />
                  <span class="min-w-0 flex-1">{row.text}</span>
                </li>
              </ul>
              <p :if={@with} class="m-0 mt-2 text-[13px] text-muted">
                {@with.name} keeps its name, ID {@with.stop_id} and sign number.
              </p>
            </section>

            <div
              :if={@outcome == :stale}
              id="stops-map-replace-stale"
              class="mt-5"
            >
              <.message
                kind="warning"
                role="status"
                title="This changed while you were reading"
                id="stops-map-replace-stale-message"
              >
                Nothing was replaced. What used this stop has changed since the review was read, so
                it no longer describes it. Choose again to read it afresh.
              </.message>
            </div>

            <label class="mt-5 flex min-h-11 cursor-pointer items-start gap-3">
              <input
                type="checkbox"
                id="stops-map-replace-delete-old"
                checked={@delete_old?}
                phx-click="replace_delete_old"
                phx-value-delete={to_string(!@delete_old?)}
                class="mt-1 size-4 accent-action"
              />
              <span>
                <span class="block text-[15px] text-strong">Delete {@stop.name} afterwards</span>
                <span class="block text-[13px] text-muted">
                  Nothing will use it. Its ID won’t be reused for another place.
                </span>
              </span>
            </label>
          <% end %>
        </div>
      </div>

      <div class="border-t border-subtle px-5 py-4">
        <div class="flex flex-wrap items-center gap-3">
          <button
            id="stops-map-replace-cancel"
            type="button"
            phx-click="back_to_edit"
            disabled={@saving?}
            class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-4 text-sm font-semibold text-strong hover:bg-canvas disabled:opacity-70"
          >
            Cancel
          </button>
          <.button
            :if={@review != nil and @refusals == []}
            id="stops-map-replace-go"
            type="button"
            phx-click="apply_replace"
            disabled={@saving?}
            class="ml-auto min-h-11"
          >
            {if @saving?,
              do: "Replacing…",
              else: replace_apply_label(@review)}
          </.button>
        </div>
      </div>
    </aside>
    """
  end

  # What changes, one row per kind that has rows. A kind with no rows is not
  # listed: the review is the arithmetic an editor reads before agreeing, and a
  # list of the fourteen kinds that do nothing is a list nobody finishes.
  defp replace_change_rows(review, usage, with) do
    review.changes
    |> Enum.filter(&(&1.count > 0))
    |> Enum.flat_map(&replace_change_rows_for(&1, usage, with))
  end

  # A pattern is the one kind an editor reads as a sentence rather than a count:
  # which route, which way, and how much service keeps its times. Those three
  # are the usage read the panel already holds — the same rows the edit panel
  # lists — and the count that says they all move comes from the review.
  defp replace_change_rows_for(%{key: :route_pattern_stops} = change, usage, with) do
    case replace_pattern_rows(usage, with) do
      [] -> [generic_change_row(change)]
      rows -> rows
    end
  end

  defp replace_change_rows_for(change, _usage, _with), do: [generic_change_row(change)]

  defp generic_change_row(change) do
    %{
      dom_id: "stops-map-replace-change-#{change.key}",
      route: nil,
      text: replace_change_text(change)
    }
  end

  defp replace_pattern_rows(%{blocking: blocking}, with) do
    case Enum.find(blocking, &(&1.key == :route_pattern_stops)) do
      nil ->
        []

      %{details: details} ->
        Enum.map(details, fn detail ->
          pattern = detail.detail

          %{
            dom_id: "stops-map-replace-change-#{dom_id(pattern.route_pattern_id)}",
            route: pattern_route(pattern),
            text:
              "toward #{pattern.headsign || "the end of the line"} stops at #{with.name} instead." <>
                trips_sentence(detail.weekday_trips)
          }
        end)
    end
  end

  defp replace_pattern_rows(_usage, _with), do: []

  defp trips_sentence(0), do: ""

  defp trips_sentence(count),
    do: " #{count_word(count, "weekday trip", "weekday trips")} keep their times."

  defp replace_change_text(%{label: label, count: count, dropped: dropped}) do
    "#{label}: #{count_word(count, "row", "rows")}" <> replace_dropped_text(dropped)
  end

  # A drop is a row the new stop already has, so carrying the old one across
  # would put two rows on one key. Saying so is the difference between a review
  # an editor can agree to and one they have to take on trust.
  defp replace_dropped_text(dropped) when dropped > 0 do
    ", and #{count_word(dropped, "row", "rows")} the new stop already has " <>
      if(dropped == 1, do: "is", else: "are") <> " not duplicated"
  end

  defp replace_dropped_text(_dropped), do: ""

  # The button repeats the scope, because a replace that touches one pattern and
  # a replace that touches nine are different decisions and the editor should
  # not have to open the review to tell them apart.
  defp replace_apply_label(review) do
    "Replace in #{count_word(replace_pattern_count(review), "pattern", "patterns")}"
  end

  defp replace_pattern_count(review) do
    case Enum.find(review.changes, &(&1.key == :route_pattern_stops)) do
      nil -> 0
      change -> change.count
    end
  end

  # The refusals are the command's own words, restated for a reader rather than
  # for a log. Each reason says what would be wrong with the feed afterwards,
  # because "refused" on its own does not tell an editor what to do instead.
  defp replace_refusal_words(refusals, stop) do
    Enum.map(refusals, &replace_refusal_word(&1, stop))
  end

  defp replace_refusal_word(:same_stop, _stop),
    do: "That is the same stop. Choose a different one."

  defp replace_refusal_word(:station, _stop),
    do:
      "A station is a drawing with entrances and levels under it, so its patterns are not moved onto a stop, and a stop’s are not moved onto a station."

  defp replace_refusal_word(:child, _stop),
    do:
      "One of these is a bay. A bay’s trips belong to its station, so merging the two would lose which stop riders were taken to."

  defp replace_refusal_word(:type_mismatch, _stop),
    do: "These are different kinds of place — one is not interchangeable with the other."

  defp replace_refusal_word({:consecutive_pattern, patterns}, stop),
    do:
      "#{pluralize(length(patterns), "pattern")} would visit the new stop twice in a row, because they already stop at #{stop_label(stop)} and then at the stop you chose. Nothing was changed."

  defp replace_refusal_word({:consecutive_trip, count}, _stop),
    do: "#{count_word(count, "trip", "trips")} would stop there twice in a row."

  defp replace_refusal_word({:blocked, key}, _stop) do
    "The #{StopReferences.fetch(key).label} describes this stop, and moving everything off it would leave them describing nothing."
  end

  defp replace_refusal_word(_other, _stop), do: "This replace would change what the feed says."

  defp stop_label(stop), do: "#{stop.name || stop.stop_id} (#{stop.stop_id})"

  @doc """
  The collapsed "Stop ID and feed details" block.

  The ID is text, not a field: it cannot change, and a disabled input
  still looks editable to a reader who has not been told why. The spoken name
  and the web page are fields, because they are content rather than identity.
  """
  attr :form, :any, required: true
  attr :stop, :map, required: true
  attr :open?, :boolean, default: false

  def edit_tech(assigns) do
    ~H"""
    <div id="stops-map-edit-tech" class="rounded-card border border-subtle">
      <button
        id="stops-map-edit-tech-toggle"
        type="button"
        phx-click="toggle_edit_tech"
        aria-expanded={to_string(@open?)}
        aria-controls="stops-map-edit-tech-items"
        class="flex min-h-11 w-full cursor-pointer items-center gap-2 rounded-card px-4 py-2 text-left text-sm font-bold text-strong"
      >
        <.icon name="hero-chevron-right" class="size-4 text-muted" /> Stop ID and feed details
        <span class="ml-auto text-[13px] font-semibold text-muted">
          {if @open?, do: "Hide", else: "Show"}
        </span>
      </button>

      <div
        :if={@open?}
        id="stops-map-edit-tech-items"
        class="grid gap-4 border-t border-subtle px-4 py-4"
      >
        <div>
          <p class="m-0 text-sm font-semibold text-strong">Stop ID</p>
          <p id="stops-map-edit-stop-id" class="m-0 mt-1 font-mono text-[15px] text-strong">
            {@stop.stop_id}
          </p>
          <p class="m-0 mt-1 text-[13px] text-muted">
            Stop IDs don&rsquo;t change. Trip planners, real-time arrivals and riders&rsquo; saved
            stops find the stop by its ID, so it stays the same when you move or rename it. To use a
            different ID, add a new stop and replace this one with it.
          </p>
        </div>

        <div>
          <label for="stops-map-edit-tts" class="block text-sm font-semibold text-strong">
            Spoken name <span class="font-normal text-muted">(optional)</span>
          </label>
          <.input
            field={@form[:tts_stop_name]}
            id="stops-map-edit-tts"
            type="text"
            autocomplete="off"
            placeholder="Southeast First Street and U S one oh one"
            class="h-11 w-full rounded-control border border-control px-3 text-[15px]"
          />
          <p class="m-0 mt-1 text-[13px] text-muted">
            How screen readers and announcements should say the name, when abbreviations would be read
            wrong.
          </p>
        </div>

        <div>
          <label for="stops-map-edit-url" class="block text-sm font-semibold text-strong">
            Stop web page <span class="font-normal text-muted">(optional)</span>
          </label>
          <.input
            field={@form[:stop_url]}
            id="stops-map-edit-url"
            type="url"
            autocomplete="off"
            class="h-11 w-full rounded-control border border-control px-3 text-[15px]"
          />
        </div>

        <p class="m-0 text-[13px] text-muted">
          GTFS: <span class="font-mono">stop_id</span>, <span class="font-mono">stop_code</span>
          is
          the sign number, <span class="font-mono">stop_desc</span>
          the description, <span class="font-mono">tts_stop_name</span>
          the spoken name.
        </p>
      </div>
    </div>
    """
  end

  # The heading's second line: what kind of stop this is, its ID, and either the
  # routes that call there or the fact that nothing does. "Not served" is the
  # whole answer for an unserved stop — there is no keep-in-feed question to
  # ask, because the editor does not change the export.
  defp edit_subtitle(%{location_type: 1} = stop) do
    "Station · ID #{stop.stop_id} · #{stop.bay_count} #{pluralize(stop.bay_count, "bay")}"
  end

  defp edit_subtitle(%{parent_station: parent} = stop) when is_binary(parent) and parent != "" do
    "Bay · ID #{stop.stop_id} · #{stationable_parent_name(stop)}"
  end

  defp edit_subtitle(%{routes: []} = stop), do: "Stop · ID #{stop.stop_id} · Not served"
  defp edit_subtitle(stop), do: "Stop · ID #{stop.stop_id}"

  # A bay names its station, because that is the name a rider looks for and the
  # only one the panel can read from the stop itself.
  defp stationable_parent_name(%{parent_name: name}) when is_binary(name) and name != "", do: name
  defp stationable_parent_name(stop), do: stop.parent_station

  # A stop that is already a bay, or already a station, is not offered the
  # operation: the command refuses it and the panel would open to say so.
  defp station_offerable?(stop) do
    stop.location_type == 0 and is_nil(stop.parent_station) and station_reachable?(stop)
  end

  # A stop the map cannot place is a stop with no coordinates, and a station
  # made beside it would be placed nowhere.
  defp station_reachable?(%{point: {lat, lon}}), do: is_number(lat) and is_number(lon)

  defp station_reachable?(_stop), do: false

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  # A stop with no zone says so; a stop whose zone has no `fare_zones` record
  # shows its ID, because `FareZones.zone_names/3` resolves an undeclared zone to
  # its exact ID rather than dropping it.
  defp zone_text(nil, _name), do: "No fare zone"
  defp zone_text(_id, nil), do: "No fare zone"
  defp zone_text(_id, name), do: name

  defp conflict_title(%{actor: nil}), do: "Someone else saved this stop"
  defp conflict_title(%{actor: actor}), do: "#{actor} saved a change to this stop"

  defp conflict_body(%{fields: fields}) when fields != [] do
    "They changed #{Enum.join(fields, ", ")}. Your changes haven’t been saved."
  end

  defp conflict_body(_conflict),
    do: "Their changes haven’t been saved over. Yours haven’t been saved either."

  defp discard_title(nil, _stop), do: "Discard changes?"

  defp discard_title(_action, stop), do: "Discard changes to #{stop.name}?"

  defp discard_body(_action),
    do: "The stop keeps its saved name, details and position. Nothing you typed is saved."

  # An action names what it acts on rather than carrying it: the panel looks the
  # key up among the warnings it is rendering and refuses anything else, so a
  # forged key cannot move a draft somewhere the geometry did not agree to.
  defp warning_action(%{action: :open_duplicate}), do: "open_duplicate"
  defp warning_action(%{action: :move_across}), do: "move_across"
  defp warning_action(_warning), do: nil

  defp text_input_class(invalid?) do
    [
      "h-11 w-full rounded-control border px-3 text-[15px]",
      invalid? && "border-error-line text-error-fg",
      !invalid? && "border-control"
    ]
  end

  defp wheelchair_choices,
    do: [{"1", "Wheelchair accessible"}, {"2", "Not accessible"}, {"0", "Not recorded"}]

  defp error_summary_title(errors) do
    count = map_size(errors)

    "Fix #{count} #{if count == 1, do: "thing", else: "things"} to create this stop"
  end

  # The summary lists errors in the order the fields appear on the form, so the
  # first link is the first field the reader reaches going down the panel.
  # What the operation keeps working, in the units an editor thinks in: the
  # trips that already call here, read from the usage the panel already holds.
  defp station_trips_text(%{blocking: blocking}) do
    case Enum.find(blocking, &(&1.key == :route_pattern_stops)) do
      %{details: details} when details != [] ->
        trips = details |> Enum.map(& &1.weekday_trips) |> Enum.sum()

        served = count_word(trips, "weekday trip", "weekday trips")

        if trips == 0,
          do: "transfer rule and fare zone",
          else: "#{served}, transfer rule and fare zone"

      _unused ->
        "transfer rule and fare zone"
    end
  end

  defp station_trips_text(_usage), do: "transfer rule and fare zone"

  # The name the bay will carry, written out from the two fields as they are
  # typed, because that is the change the command makes besides the parent.
  defp bay_name_preview(form) do
    name = Form.input_value(form, :station_name)
    bay = Form.input_value(form, :platform_code)

    ~s("#{name}, Bay #{bay}")
  end

  # The station form has its own two fields, so it names them rather than
  # borrowing the add panel's list: a message about a field that is not on this
  # form would send the editor looking for an input that is not there.
  defp station_error_rows(errors) do
    Enum.flat_map(~w(station_name platform_code), fn field ->
      case Map.fetch(errors, field) do
        {:ok, {_short, message}} -> [{field, message}]
        :error -> []
      end
    end)
  end

  defp summary_errors(errors) do
    Enum.flat_map(~w(location name desc stop_id lat lon), fn field ->
      case Map.fetch(errors, field) do
        {:ok, error} -> [{field, error}]
        :error -> []
      end
    end)
  end

  # A DOM id cannot carry a suggestion's own words, so it carries a slug of them.
  # Two suggestions that slug alike are the same words, and the browser keeps the
  # first, which is the same row rendered twice.
  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  The line under the panel's heading when a search result is chosen: what kind
  of stop this is and which ID the editor will be editing.

  The ID is on it because it is the thing an editor copies into a sign, a
  dispatcher's note or a support ticket, and reading it off a list of forty
  rows is a job nobody should have to do mid-selection.
  """
  attr :row, :map, required: true

  def selection_note(%{location_type: 1} = row) do
    "Station · ID #{row.stop_id} · #{row.bays} #{pluralize(row.bays, "bay")}"
  end

  def selection_note(row) do
    [
      "Stop · ID #{row.stop_id}",
      presence(row.desc),
      if(row.served?, do: nil, else: "Not served")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp presence(""), do: nil
  defp presence(nil), do: nil
  defp presence(text), do: text

  # A place's second line says what kind of thing it is and where it is. It is
  # built from the address the service returned rather than a fixed word, so a
  # place in another town says so instead of reading as one on this feed.
  defp place_subtitle(place) do
    where = [place.city, place.state] |> Enum.map(&presence/1) |> Enum.reject(&is_nil/1)
    where = Enum.join(where, ", ")

    Enum.reject(["Address", if(where == "", do: nil, else: where)], &is_nil/1)
    |> Enum.join(" · ")
  end

  # An empty result names what was not found and one thing to try instead. A
  # bare "no results" leaves an editor guessing what kind of answer the field
  # would have given.
  defp default_empty_text(query),
    do: "No stops or places match “#{query}”. Try a street name, like “9th”."

  @doc """
  How many stops a version holds, in the words both the header and the browse
  panel use.

  One function, because a header that says "16 stops and 1 station" beside a
  panel that says "17 in this version" is a page that contradicts itself about
  its own data, and a reader who notices stops trusting either number.
  """
  def scope_note(%{loading: true}), do: ""

  def scope_note(%{stop_count: 0, loading: false}), do: "No stops yet"

  def scope_note(%{stop_count: stop_count, station_count: 0, loading: false, version: version}) do
    "#{stop_count} #{pluralize(stop_count, "stop")} in #{version.name}"
  end

  def scope_note(%{
        stop_count: stop_count,
        station_count: station_count,
        loading: false,
        version: version
      }) do
    "#{stop_count} #{pluralize(stop_count, "stop")} and #{station_count} #{pluralize(station_count, "station")} in #{version.name}"
  end

  defp row_subtitle(%{location_type: 1, bays: bays}) when bays > 0,
    do: "Station · #{bays} #{pluralize(bays, "bay")}"

  defp row_subtitle(%{location_type: 1}), do: "Station"

  defp row_subtitle(row) do
    [
      if(row.desc in [nil, ""], do: nil, else: row.desc),
      if(row.served?, do: nil, else: "Not served"),
      "ID #{row.stop_id}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp badge_style(%{color: color, text_color: text_color})
       when is_binary(color) and is_binary(text_color) do
    background = css_color(color)
    named = css_color(text_color)

    # `route_text_color` is optional in GTFS and this app fills a blank with
    # `000000`, which is not what an agency chose — it is what it declined to
    # say. Black text on a dark route colour is unreadable, and a route number
    # that cannot be read is worse than no badge at all, so a named ink is
    # honoured only when it actually meets the 4.5:1 contrast floor against the
    # route's own colour. Otherwise the ink is chosen from that colour.
    if contrast_ratio(named, background) >= 4.5 do
      "background: #{background}; color: #{named};"
    else
      "background: #{background}; color: #{contrast_ink(background)};"
    end
  end

  defp badge_style(%{color: color}) when is_binary(color),
    do: "background: #{css_color(color)}; color: #{contrast_ink(css_color(color))};"

  defp badge_style(_route), do: "background: #27344b; color: #ffffff;"

  # A route colour is six hexadecimal digits in an import, with or without the
  # leading `#` GTFS writes them without, and a `route_text_color` is optional.
  # A badge's whole job is to be read, so the text colour falls back to white and
  # the background falls back to the page's own ink when a feed carries neither.
  # Anything that is not six hex digits is dropped rather than pasted into a
  # `style` attribute, so a hostile feed cannot close the attribute and restyle
  # the row.
  defp css_color("#" <> <<_::binary-size(6)>> = hex), do: hex
  defp css_color(<<_::binary-size(6)>> = hex), do: "#" <> hex
  defp css_color(_other), do: "#27344b"

  # The ink a badge needs when the feed named no `route_text_color`. Agencies
  # write pale route colours as often as dark ones, and white on a pale yellow
  # route number is unreadable, so the choice is made from the colour's own
  # luminance rather than assumed. The relative-luminance coefficients are the
  # sRGB ones from WCAG 2.1.
  defp contrast_ink("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    luminance = 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)

    if luminance > 0.179, do: "#0a1330", else: "#ffffff"
  end

  defp contrast_ink(_other), do: "#ffffff"

  # WCAG 2.1's relative-luminance ratio.
  defp contrast_ratio(foreground, background) do
    light = max(luminance(foreground), luminance(background))
    dark = min(luminance(foreground), luminance(background))

    (light + 0.05) / (dark + 0.05)
  end

  defp luminance("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
  end

  defp luminance(_other), do: 0.0

  defp channel(<<byte::binary-size(2), _rest::binary>>) do
    value = String.to_integer(byte, 16) / 255

    if value <= 0.03928, do: value / 12.92, else: ((value + 0.055) / 1.055) ** 2.4
  end
end
