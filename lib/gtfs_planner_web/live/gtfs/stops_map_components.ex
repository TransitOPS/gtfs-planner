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
  """

  use GtfsPlannerWeb, :html

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
             child of it and a diff would take the map out of its hands. --%>
      <div id="stop-map" phx-hook="StopMap" phx-update="ignore" class="absolute inset-0"></div>

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
  the first thing a `fitBounds` threw away. The two toggles change what is drawn
  and nothing the server stores, so the hook handles them on the client; the
  basemap buttons carry `aria-pressed` because they are a pair of choices, not
  two independent actions.
  """
  def map_legend(assigns) do
    ~H"""
    <div
      id="stops-map-legend"
      class="absolute bottom-3 left-3 z-10 flex max-w-[calc(100%-24px)] flex-wrap items-center gap-x-4 gap-y-1 rounded-control border border-subtle bg-overlay px-3 py-1 text-[13px] text-default shadow-card"
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
      class="flex items-start gap-3 px-4 py-3"
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
    <div id={@id} class="px-4 pb-6">
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
  click. The rows are read-only in this shell: selecting one opens the edit
  panel, which is the next step's work, so a row that looked pressable here
  would be a control that does nothing.
  """
  attr :row, :map, required: true

  def stop_row(assigns) do
    ~H"""
    <div
      id={"stops-map-row-#{@row.stop_id}"}
      class="flex min-h-11 w-full items-start gap-3 rounded-control px-2 py-2"
    >
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
    </div>
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
  The add-mode panel shell: the caption's counterpart in the panel, and the way
  back out. The form itself arrives with the add flow.
  """
  attr :id, :string, required: true

  def add_panel(assigns) do
    ~H"""
    <div id={@id} class="px-5 py-5">
      <h2 class="font-display text-[22px] font-semibold text-strong">New stop</h2>
      <p class="mt-1 text-sm text-muted">Click the curb where riders wait.</p>
      <button
        id="stops-map-add-cancel"
        type="button"
        class="mt-4 inline-flex min-h-11 items-center text-sm font-semibold text-action no-underline hover:underline"
        phx-click="cancel_add"
      >
        Cancel
      </button>
    </div>
    """
  end

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
