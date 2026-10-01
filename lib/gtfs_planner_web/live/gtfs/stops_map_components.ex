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
          <.stop_row row={row} />
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

  A row is read-only until something can be done with it. `selectable` is set
  where choosing the row selects that stop, which today is the search results:
  the browse list's own rows stay inert until the edit panel behind them exists,
  because a row that looks pressable and does nothing is worse than a row that
  does not look pressable.
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

  Before a placement the form's fields are dimmed rather than hidden. The
  prototype shows a paragraph in their place, and a paragraph that is replaced
  by fields is a layout jump; dimmed fields say the same thing — "they come
  next" — and keep the panel from moving when the pin lands.
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
        <.coord_fields form={@form} errors={@errors} />
      </div>
    </div>

    <div :if={@placement != nil}>
      <p id="stops-map-add-where" class="m-0 text-[15px] font-semibold text-strong">
        {@where}
      </p>
      <p class="m-0 mt-1 text-[13px] text-muted">
        Drag the pin to adjust. The stop is not saved until you create it.
      </p>

      <.coord_fields form={@form} errors={@errors} />

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
  attr :form, :any, required: true
  attr :errors, :map, default: %{}

  def coord_fields(assigns) do
    ~H"""
    <div class="mt-3 grid grid-cols-2 gap-3">
      <div>
        <label for="stops-map-add-lat" class="block text-sm font-semibold text-strong">
          Latitude
        </label>
        <.input
          field={@form[:lat]}
          id="stops-map-add-lat"
          errors={field_errors(@errors, "lat")}
          type="text"
          inputmode="decimal"
          autocomplete="off"
          class={coord_input_class(Map.has_key?(@errors, "lat"))}
        />
      </div>

      <div>
        <label for="stops-map-add-lon" class="block text-sm font-semibold text-strong">
          Longitude
        </label>
        <.input
          field={@form[:lon]}
          id="stops-map-add-lon"
          errors={field_errors(@errors, "lon")}
          type="text"
          inputmode="decimal"
          autocomplete="off"
          class={coord_input_class(Map.has_key?(@errors, "lon"))}
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

  It is a button and a region rather than a `<details>` element for step 27's
  reason: a native disclosure's open state is not the server's, and a re-render
  would snap it shut under the reader while they are typing an ID into it.

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
  The panel after a stop is created: what was made, and the way to make the next
  one. The pattern list step 29 adds hangs under the same heading.
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

          <div class="mt-6 flex flex-wrap items-center gap-3">
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

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

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
