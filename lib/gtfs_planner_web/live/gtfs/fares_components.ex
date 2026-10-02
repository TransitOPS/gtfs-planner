defmodule GtfsPlannerWeb.Gtfs.FaresComponents do
  @moduledoc """
  Function components for the Fares workspace, built from the TransitOps
  application design system.

  This module owns the workspace's non-ideal states: the first-paint skeleton
  the disconnected render shows, and the load-error message that names what
  failed and offers the one recovery action. The skeleton mirrors the workspace
  body rather than replacing content already on screen, and the error copy states
  that saved zones and rules are unchanged, so a failed read is never mistaken
  for lost work.

  The Zones tab is one card. Its zone strip is the page's only navigation between
  zones: every zone in the version is one patch link, with a color dot, the name
  and a stop count, and each link carries its filter in the URL, so a zone
  survives a reload, a tab change and a copied link. Zone identity is
  byte-exact, so a link's query is built with `URI.encode_query/1` and no DOM ID
  ever carries a zone ID. The zone ID itself is muted detail in the stage line and
  the drawers, because the name is what the team recognizes.

  Below the strip, the stage header names what the current filter shows, and a
  fixed-height workspace holds the map beside the stop list (the map above the list
  below 1024 px, or the list alone). The stop list renders one page of
  `FareZones.list_stops/3` as a `:stops` stream, so the rows arrive as data and the
  table's own structure stays fixed while a search or a page change replaces its
  contents. Its first column is the row's selection checkbox, and the head's two
  actions select the page or every stop the filter and search match. The search
  field is handled on change and on submit alike: pressing Enter must not hand the
  form to the browser, because a native GET would replace the whole query string
  and drop the filter the operator is reading.

  The selection bar is the card's sticky footer and is always present: idle it
  says how to start, and with a selection it states what the server currently
  holds selected and how much of it the current filter cannot show. Its Assign
  zone action is the page's one primary while it shows, and it opens the
  assignment review, which is where a selection becomes a write.

  The zone drawer creates and edits zone metadata. It uses the shared planner
  drawer with `<.input>` fields, validates on change so a field error appears
  beside the field it belongs to, and puts the `FormErrorFocus` hook on its
  content so a failed submit moves focus to the first invalid field. Nothing
  about a failed submit, a duplicate ID or a zone another editor removed closes
  the drawer or discards what the operator typed: it stays open with the reason.
  An edit also states what the zone already carries, because changing its ID
  rewrites exactly the stop and fare-rule references the counts name.

  Reviewed bulk assignment is the dialog and the message that follows it. The
  dialog states what a save will change before anything is written and lists the
  reviewed rows; it never closes itself, so a stale review, a target zone another
  editor removed and a save that failed all leave the operator's review in place.
  The message reports what a completed save did and offers Undo, which is the
  domain's own restore of the exact previous zone bytes.

  The map is the stage's other way to read and change membership. Its root is
  static markup the `FareZoneMap` hook binds, so the server renders the controls
  and the canvas element once and never patches them; the hook hydrates from the
  `fare_zone_map_ready` reply and keeps its own state. The legend names the zones
  a marker can carry, and the fallback replaces the frame with its two ways out
  when the map cannot load, because the stop list is always a complete
  alternative.

  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, first_use: 1, message: 1]

  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Wording

  @review_row_limit 100

  @doc """
  Renders the workspace's first-paint skeleton.

  Shown while the connected load is still resolving, so the tab body never paints
  as an unexplained blank region.

  ## Examples

      <.loading />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def loading(assigns) do
    ~H"""
    <div
      id="fare-zones-loading"
      role="status"
      aria-busy="true"
      class={["overflow-clip rounded-card border border-subtle bg-white", @class]}
      {@rest}
    >
      <div class="motion-safe:animate-pulse" aria-hidden="true">
        <div class="flex gap-2 border-b border-subtle px-5 py-4">
          <div
            :for={width <- ~w(w-28 w-40 w-36 w-44 w-28)}
            class={["h-11 rounded-control bg-canvas", width]}
          >
          </div>
        </div>
        <div
          :for={_row <- 1..5}
          class="flex items-center gap-4 border-b border-subtle px-5 py-4"
        >
          <div class="size-[18px] rounded-badge bg-canvas"></div>
          <div class="grid flex-1 gap-2">
            <div class="h-3.5 w-3/5 rounded-badge bg-canvas"></div>
            <div class="h-3.5 w-2/5 rounded-badge bg-canvas"></div>
          </div>
        </div>
      </div>
      <p class="px-5 py-3 text-sm text-muted">Loading fares…</p>
    </div>
    """
  end

  @doc """
  Renders the Zones tab's zone strip: the filters the stop list can show.

  One chip per filter: All stops, every zone in the version (declared metadata or
  the exact stored ID), and No zone. A zone chip leads with a dot in the zone's
  own color, and the name is always in the chip, so color is never the only cue.
  The count is boardable stops only; No zone turns into a warning badge while it
  is above zero. Chips are patch links, so the filter lives in the URL, and the
  current one carries `aria-current` besides its tint and border.

  The strip wraps on a wide screen and scrolls inside its own container below
  `sm`, so a narrow layout never overflows the page.

  ## Examples

      <.zone_inventory inventory={@inventory} filter={@filter} patch_base={@zones_path} />
  """
  attr :inventory, :map, required: true, doc: "`FareZones.inventory/2`"
  attr :filter, :any, required: true, doc: "`:all`, `:unassigned` or `{:zone, id}`"
  attr :patch_base, :string, required: true, doc: "the Zones path, without a query"

  def zone_inventory(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        inventory_rows(assigns.inventory, assigns.filter, assigns.patch_base)
      )

    ~H"""
    <div id="fare-zone-inventory" class="min-w-0 max-sm:w-full sm:flex-1">
      <nav
        id="fare-zone-inventory-filters"
        aria-label="Fare zone filters"
        class="flex min-w-0 gap-2 overflow-x-auto py-0.5 sm:flex-wrap"
      >
        <.link
          :for={row <- @rows}
          id={row.id}
          patch={row.patch}
          aria-current={row.current? && "page"}
          class={chip_class(row.current?)}
        >
          <.zone_dot color={row.color} ring?={row.ring?} icon={row.icon} />
          <span id={"#{row.id}-title"}>{row.title}</span>
          <span id={"#{row.id}-count"} class={chip_count_class(row)}>{row.count}</span>
        </.link>
      </nav>
    </div>
    """
  end

  # The marker that leads a zone's name wherever it is listed: the zone's own
  # color as a filled dot, an outline for a stop with no zone, or an icon for the
  # filter that spans every zone. The name always sits beside it.
  attr :color, :string, default: nil, doc: "the zone's palette hex, or nil"
  attr :ring?, :boolean, default: false
  attr :icon, :string, default: nil
  attr :class, :any, default: "size-2.5"

  defp zone_dot(%{icon: icon} = assigns) when is_binary(icon) do
    ~H"""
    <.icon name={@icon} class="size-4 shrink-0 text-muted" />
    """
  end

  defp zone_dot(%{ring?: true} = assigns) do
    ~H"""
    <span
      class={[@class, "shrink-0 rounded-full border-2 border-control bg-white"]}
      aria-hidden="true"
    >
    </span>
    """
  end

  defp zone_dot(assigns) do
    ~H"""
    <span
      class={[@class, "shrink-0 rounded-full"]}
      style={@color && "background-color: #{@color}"}
      aria-hidden="true"
    >
    </span>
    """
  end

  @doc """
  Renders the stage header: what the current filter shows and how much of it.

  The optional `actions` slot is where the Zones tab adds its own controls beside
  the title, so the header stays one place. Passing `view` adds the "Map and list"
  / "List only" switch: which of the two the operator is reading is browser state,
  so the server only echoes it back.

  ## Examples

      <.stage_header title="All stops" subtitle="27 stops in this version" view={@view} />
  """
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :view, :any, default: nil, doc: "`nil` renders no switch; otherwise `:map` or `:list`"
  slot :actions

  def stage_header(assigns) do
    ~H"""
    <div
      id="fare-zone-stage-header"
      class="flex flex-wrap items-center gap-x-5 gap-y-2 border-y border-subtle px-4 py-2.5 sm:px-5"
    >
      <div class="min-w-0 flex-1 basis-[260px]">
        <%!-- The title is a stored zone ID for an undeclared zone, so its bytes are
        the DOM's bytes: no formatter whitespace may sit around it. --%>
        <h2 phx-no-format id="fare-zone-stage-title" class="truncate text-base font-bold text-strong">{@title}</h2>
        <p phx-no-format id="fare-zone-stage-subtitle" class="text-[13px] leading-snug text-muted">{@subtitle}</p>
      </div>
      <div
        :if={@actions != [] or @view != nil}
        class="flex flex-wrap items-center gap-2 max-sm:w-full"
      >
        {render_slot(@actions)}
        <.segmented_control
          :if={@view != nil}
          id="fare-zone-view"
          name="view"
          legend="Stop display"
          legend_class="sr-only"
          options={[{"Map and list", "map"}, {"List only", "list"}]}
          value={Atom.to_string(@view)}
          event="set_view"
          appearance={:joined}
          emphasis={:selection}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders the Zones tab's map: the hook's root and the controls it binds.

  The markup here is deliberately static. `phx-update="ignore"` keeps the server
  from patching anything inside the root, and the `FareZoneMap` hook binds the
  mode, zoom and fit controls itself, so Select/Pan is browser state the server
  never has to carry. `[data-map-hint]` ships the Select copy so the frame reads
  correctly before the hook mounts, and the hook keeps it current per mode.

  The frame fills the workspace's map column and never falls below 320 px, so the
  map neither pushes the stop list out of reach nor collapses when the list is
  short. The controls sit above the Leaflet panes so they stay operable while the
  map is dragged or zoomed. The hint clears the tile attribution Leaflet prints
  along the frame's bottom edge, which at 320 px wraps to two lines: the hint
  sits above that band instead of colliding with it.

  ## Examples

      <.zone_map />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def zone_map(assigns) do
    ~H"""
    <div
      id="fare-zone-map"
      phx-hook="FareZoneMap"
      phx-update="ignore"
      class={["relative min-h-80 flex-1 overflow-hidden bg-canvas", @class]}
      {@rest}
    >
      <%!-- The Leaflet container. The hook draws here and writes data-map-state,
      data-point-count and data-selected-count on it. --%>
      <div data-map-canvas class="absolute inset-0"></div>

      <div
        role="group"
        aria-label="Map mode"
        class="absolute left-3 top-3 z-[900] inline-flex divide-x divide-control overflow-hidden rounded-control border border-control bg-white shadow-card"
      >
        <.map_mode data-map-mode="select" aria-pressed="true" icon="hero-cursor-arrow-rays">
          Select stops
        </.map_mode>
        <.map_mode data-map-mode="pan" aria-pressed="false" icon="hero-hand-raised">
          Pan map
        </.map_mode>
      </div>

      <div class="absolute right-3 top-3 z-[900] grid gap-1.5">
        <.map_control data-map-zoom="in" label="Zoom in" icon="hero-plus" />
        <.map_control data-map-zoom="out" label="Zoom out" icon="hero-minus" />
        <.map_control data-map-fit label="Fit all stops" icon="hero-arrows-pointing-out" />
      </div>

      <p
        data-map-hint
        class="pointer-events-none absolute bottom-12 left-3 z-[900] max-w-[calc(100%-1.5rem)] rounded-control border border-subtle bg-white/95 px-2.5 py-1.5 text-[13px] leading-snug text-default"
      >
        Click stops or drag a box to select. The box does not create a zone boundary.
      </p>
    </div>
    """
  end

  # One mode button inside the map's segmented group. The hook flips
  # `aria-pressed`, and the pressed style follows it.
  attr :icon, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  defp map_mode(assigns) do
    ~H"""
    <button
      type="button"
      class="inline-flex min-h-11 items-center gap-1.5 px-3 text-sm font-[650] text-strong hover:bg-canvas focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus aria-pressed:bg-selection aria-pressed:text-action"
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  # One icon control inside the map frame. The frame sits over tiles, so each
  # control carries its own opaque surface, and its 44 px square keeps the touch
  # target the workspace's other controls use.
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global

  defp map_control(assigns) do
    ~H"""
    <button
      type="button"
      aria-label={@label}
      title={@label}
      class="inline-flex size-11 items-center justify-center rounded-control border border-control bg-white text-strong shadow-card hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      {@rest}
    >
      <.icon name={@icon} class="size-5" />
    </button>
    """
  end

  @doc """
  Renders the map's legend: a chip and name per zone a marker can carry, then
  No zone.

  Only zones with at least one boardable stop are listed, because the map draws
  exactly those stops; a zone with no stops has no marker to explain. The chip
  repeats what the marker prints, the zone ID in the zone's color, and the name
  beside it says which zone that is, so a color never carries the meaning alone.

  ## Examples

      <.map_legend zones={@inventory.zones} />
  """
  attr :zones, :list, required: true, doc: "the inventory's zones"

  def map_legend(assigns) do
    assigns = assign(assigns, :shown, Enum.filter(assigns.zones, &(&1.stop_count > 0)))

    ~H"""
    <div
      id="fare-zone-map-legend"
      class="flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-subtle px-4 py-2.5 text-[13px] text-default"
    >
      <span :for={zone <- @shown} class="flex items-center gap-1.5">
        <span
          class={id_chip_class(FareZone.color_hex(zone.color))}
          style={id_chip_style(FareZone.color_hex(zone.color))}
          aria-hidden="true"
        >
          <span class="truncate">{zone.zone_id}</span>
        </span>
        <span>{zone.name}</span>
      </span>
      <span class="flex items-center gap-1.5">
        <span class={id_chip_class(nil)} aria-hidden="true">–</span>
        <span>No zone</span>
      </span>
    </div>
    """
  end

  @doc """
  Renders the fallback the Zones tab shows when the map cannot load.

  Both ways out are here because the two failures are different: Retry map is for
  a map that can load now, and Use stop list is for an operator who wants the work
  done without the map. The stop list beside it stays a complete alternative
  either way, which is what the copy says. The fallback occupies the map's own
  column, so a failed map neither moves the list nor changes the workspace's
  layout when Retry brings the frame back. Both actions are secondary: the page's
  primary belongs to the task, not to the recovery.

  ## Examples

      <.map_unavailable />
  """
  def map_unavailable(assigns) do
    ~H"""
    <div
      id="fare-zone-map-unavailable"
      class="grid min-h-80 flex-1 place-items-center bg-canvas px-6 text-center"
    >
      <div class="max-w-[36ch]">
        <h3 class="text-base font-bold text-strong">The map is unavailable</h3>
        <p class="mt-1 text-sm text-muted">You can still find and assign every stop in the list.</p>
        <div class="mt-4 flex flex-wrap justify-center gap-2">
          <.button
            id="fare-zone-map-retry"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="retry_map"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Retry map
          </.button>
          <.button
            id="fare-zone-map-use-list"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="use_stop_list"
          >
            Use stop list
          </.button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Zones tab's stop search: one field in the card's top row, beside the
  zone strip.

  The form handles its change and its submit alike: pressing Enter must not hand
  the form to the browser, because a native GET would replace the whole query
  string and drop the zone, the No zone filter and the page the operator was
  reading.

  ## Examples

      <.stop_search q={@q} />
  """
  attr :q, :string, default: nil, doc: "the current search term"

  def stop_search(assigns) do
    ~H"""
    <form
      id="fare-zone-search-form"
      role="search"
      phx-change="search"
      phx-submit="search"
      class="min-w-0 max-sm:w-full sm:w-[260px]"
    >
      <.input
        id="fare-zone-search"
        name="q"
        type="search"
        value={@q}
        label="Search stops"
        placeholder="Name or ID"
        autocomplete="off"
        phx-debounce="300"
        class="h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong placeholder:text-muted"
      />
    </form>
    """
  end

  @doc """
  Renders the stage's stop list: the head with the unlocated count and the two
  selection actions, the rows and the empty states.

  The row subtexts name what an operator cannot see from the row alone: a
  platform is assigned separately from its station, and a stop without
  coordinates can still be selected from this list. The unlocated count is the
  filter's own, so it stays meaningful while a search narrows the visible rows.
  In the list-only view the stop ID has its own column; beside a map it is the
  row's second line, so the row stays legible at half width.

  Each empty state names what the current filter is missing and offers the one
  action that leaves it, which is All stops without a search.

  ## Examples

      <.stop_list
        stops={@streams.stops}
        stop_page={@stop_page}
        zones={@inventory.zones}
        filter={@filter}
        q={@q}
        view={@view}
        patch_base={@zones_path}
      />
  """
  attr :stops, :any, required: true, doc: "the `:stops` stream holding the current page"
  attr :stop_page, :map, required: true, doc: "`FareZones.list_stops/3`'s page map"
  attr :zones, :list, required: true, doc: "the inventory's zones, for names and colors"
  attr :filter, :any, required: true, doc: "`:all`, `:unassigned` or `{:zone, id}`"
  attr :q, :string, default: nil, doc: "the current search term"
  attr :view, :atom, values: [:map, :list], default: :map, doc: "which stage view is showing"
  attr :patch_base, :string, required: true, doc: "the Zones path, without a query"

  attr :selection, :any,
    required: true,
    doc: "the `MapSet` of selected stop UUIDs the server holds"

  attr :matching_count, :integer,
    required: true,
    doc: "how many stops the current filter and search match"

  def stop_list(assigns) do
    assigns =
      assigns
      |> assign(:zone_lookup, Map.new(assigns.zones, &{&1.zone_id, &1}))
      |> assign(:empty, empty_state_copy(assigns.filter, assigns.q))
      |> assign(:shown_count, length(assigns.stop_page.entries))

    ~H"""
    <%!-- The rows are a stream, so a change of view cannot re-render them: the
    view is a data attribute on the list, and the parts of a row that differ
    between the two views (the ID line and the ID column) follow it in CSS. --%>
    <div
      id="fare-zone-stop-list"
      data-view={@view}
      class="group/list flex min-h-0 min-w-0 flex-col"
    >
      <div class="flex min-h-14 flex-wrap items-center gap-x-4 gap-y-1 border-b border-subtle bg-canvas px-4 py-1.5 sm:px-5">
        <p id="fare-zone-stop-head" class="text-sm">
          <strong class="font-bold text-strong">Stops</strong>
          <span class="text-muted tabular-nums">· {@stop_page.total_count} shown</span>
        </p>
        <p id="fare-zone-without-location" class="text-[13px] text-muted">
          {@stop_page.without_location_count} without map location
        </p>
        <div :if={@stop_page.total_count > 0} class="flex flex-wrap items-center gap-x-2 sm:ml-auto">
          <%!-- The page's own rows, and the whole match the filter and search
          have, so a 100-row page of 150 stops can be selected either way. --%>
          <.button
            id="fare-zone-select-shown"
            type="button"
            variant="quiet"
            class="min-h-11 px-2 text-action hover:bg-transparent hover:underline"
            phx-click="select_page"
          >
            Select {@shown_count} shown
          </.button>
          <.button
            id="fare-zone-select-matching"
            type="button"
            variant="quiet"
            class="min-h-11 px-2 text-action hover:bg-transparent hover:underline"
            phx-click="select_matching"
          >
            Select all {@matching_count} matching
          </.button>
        </div>
      </div>

      <div
        :if={@stop_page.total_count == 0}
        id="fare-zone-stops-empty"
        class="grid place-items-center px-6 py-12 text-center"
      >
        <div class="max-w-[38ch]">
          <h3 class="text-base font-bold text-strong">{@empty.title}</h3>
          <p class="mt-1 text-sm text-muted">{@empty.body}</p>
          <div :if={@empty.action} class="mt-4">
            <.button
              id="fare-zone-stops-empty-action"
              variant="secondary"
              class="min-h-11"
              patch={@patch_base}
            >
              {@empty.action}
            </.button>
          </div>
        </div>
      </div>

      <div
        :if={@stop_page.total_count > 0}
        id="fare-zone-stops-container"
        class="min-h-0 flex-1 overflow-y-auto max-lg:max-h-[600px]"
      >
        <table class="w-full border-collapse text-left text-sm">
          <caption class="sr-only">Stops and their fare zones</caption>
          <thead class="group-data-[view=map]/list:sr-only">
            <tr class="text-[13px] font-[650] text-default">
              <th scope="col" class="w-14 border-b border-subtle bg-white py-2 pl-2 sm:pl-3">
                <span class="sr-only">Select</span>
              </th>
              <th scope="col" class="border-b border-subtle bg-white py-2 pr-3">Stop</th>
              <th
                scope="col"
                class="hidden w-28 border-b border-subtle bg-white py-2 pr-3 group-data-[view=list]/list:sm:table-cell"
              >
                Stop ID
              </th>
              <th scope="col" class="border-b border-subtle bg-white py-2 pr-4 sm:w-[190px]">
                Fare zone
              </th>
            </tr>
          </thead>
          <tbody id="fare-zone-stops" phx-update="stream">
            <tr
              :for={{dom_id, stop} <- @stops}
              id={dom_id}
              class={[
                "border-b border-subtle hover:bg-canvas",
                MapSet.member?(@selection, stop.id) && "bg-selection"
              ]}
            >
              <td class="w-14 py-0 pl-2 sm:pl-3">
                <label class="flex size-11 cursor-pointer items-center justify-center has-[:focus-visible]:outline-2 has-[:focus-visible]:-outline-offset-2 has-[:focus-visible]:outline-focus">
                  <input
                    type="checkbox"
                    class="size-[18px] accent-action"
                    checked={MapSet.member?(@selection, stop.id)}
                    aria-label={select_label(stop)}
                    phx-click="toggle_stop"
                    phx-value-id={stop.id}
                  />
                </label>
              </td>
              <td class="py-2 pr-3">
                <span class="block font-semibold text-strong">{stop.stop_name}</span>
                <span class="block text-[13px] tabular-nums text-muted group-data-[view=list]/list:sm:hidden">
                  ID {stop.stop_id}
                </span>
                <span :if={stop.parent_station} class="block text-[13px] text-muted">
                  Platform · assigned separately
                </span>
                <span :if={!stop.located?} class="block text-[13px] text-muted">
                  No map location · list selection available
                </span>
              </td>
              <td class="hidden py-2 pr-3 font-mono text-[13px] tabular-nums text-default group-data-[view=list]/list:sm:table-cell">
                {stop.stop_id}
              </td>
              <td class="py-2 pr-4">
                <% zone = Map.get(@zone_lookup, stop.zone_id) %>
                <span :if={is_nil(stop.zone_id)} class="inline-flex items-center gap-2 text-muted">
                  <.zone_dot ring?={true} /> No zone
                </span>
                <span :if={stop.zone_id} class="inline-flex items-center gap-2">
                  <.zone_dot color={zone && FareZone.color_hex(zone.color)} />
                  <span>{stop_zone_name(zone, stop.zone_id)}</span>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@stop_page.total_count > 0}
        id="fare-zone-stops-pagination"
        class="border-t border-subtle px-4 sm:px-5"
      >
        <.pagination
          page={@stop_page.page}
          per_page={@stop_page.per_page}
          total={@stop_page.total_count}
          entity="stops"
        />
      </div>
    </div>
    """
  end

  # The checkbox's own name is the row's stop, so an operator reading the row and
  # an operator moving through the column both know what each box selects.
  defp select_label(stop), do: "Select #{stop.stop_name}"

  @doc """
  Renders the selection bar: how many stops are selected, how much of that the
  current filter cannot show, and the actions that work on the selection.

  It is the card's sticky footer and is always present, so the layout never jumps
  when a selection starts: nothing selected renders the hint that teaches how to
  begin, and a selection renders the bar. Both counts are the server's own: the
  size of the selection, and the size of the selection the current filter and
  search do not match. Assign zone is the one primary while the bar shows, Remove
  zone needs only a selection, and Clear selection is a quiet text action.

  ## Examples

      <.selection_bar selection={@selection} matching_ids={@matching_ids} />
  """
  attr :selection, :any, required: true, doc: "the `MapSet` of selected stop UUIDs"

  attr :matching_ids, :any,
    required: true,
    doc: "the stop UUIDs the current filter and search match"

  def selection_bar(assigns) do
    selected_count = MapSet.size(assigns.selection)

    assigns =
      assigns
      |> assign(:selected_count, selected_count)
      |> assign(:empty?, selected_count == 0)
      |> assign(
        :outside_count,
        MapSet.size(MapSet.difference(assigns.selection, assigns.matching_ids))
      )

    ~H"""
    <div id="fare-zone-selection-bar" class={selection_bar_class(@empty?)}>
      <p :if={@empty?} id="fare-zone-selection-hint">
        Select stops in the list or on the map to assign or remove a zone.
      </p>

      <p :if={!@empty?} class="font-bold text-strong">
        <span id="fare-zone-selection-count">{selected_count_copy(@selected_count)}</span>
        <span
          :if={@outside_count > 0}
          id="fare-zone-selection-outside"
          class="ml-2 font-normal text-muted"
        >
          {@outside_count} outside this filter
        </span>
      </p>
      <.button
        :if={!@empty?}
        id="fare-zone-assign-selection"
        type="button"
        class="min-h-11"
        phx-click="open_assignment"
        phx-value-mode="assign"
      >
        Assign zone
      </.button>
      <.button
        :if={!@empty?}
        id="fare-zone-unassign-selection"
        type="button"
        variant="secondary"
        class="min-h-11"
        phx-click="open_assignment"
        phx-value-mode="unassign"
      >
        Remove zone
      </.button>
      <.button
        :if={!@empty?}
        id="fare-zone-clear-selection"
        type="button"
        variant="quiet"
        class="min-h-11 px-2 text-action hover:bg-transparent hover:underline"
        phx-click="clear_selection"
      >
        Clear selection
      </.button>
    </div>
    """
  end

  # The hint is the muted state of the same footer. The bar is the card's sticky
  # footer, so a selection made in a list taller than the viewport stays visible
  # and clearable while the rows scroll past it.
  defp selection_bar_class(true) do
    "sticky bottom-0 z-20 flex min-h-14 flex-wrap items-center gap-x-4 gap-y-1 border-t border-subtle bg-canvas px-4 py-1.5 text-sm text-muted sm:px-5"
  end

  defp selection_bar_class(false) do
    "sticky bottom-0 z-20 flex min-h-14 flex-wrap items-center gap-x-4 gap-y-1 border-t border-action bg-selection px-4 py-1.5 text-sm sm:px-5"
  end

  # The reference writes the count in the plural for every size; a count of one
  # stop is a sentence about a single stop, so it reads singular.
  defp selected_count_copy(1), do: "1 stop selected"
  defp selected_count_copy(count), do: "#{count} stops selected"

  # A stop's zone comes from the same inventory read as the strip above it, so
  # its name and color are the ones the filter list shows. A zone the inventory
  # does not carry is rendered by its exact stored ID rather than by a made-up
  # name.
  defp stop_zone_name(nil, zone_id), do: zone_id
  defp stop_zone_name(zone, _zone_id), do: zone.name

  # The empty states AC-23 names, in the order that decides which one shows: a
  # search that matches nothing is about the search even when a filter is also
  # applied, because clearing only the filter would leave the search in place.
  # Every state's single action returns to All stops without a search.
  defp empty_state_copy(_filter, q) when is_binary(q) do
    %{
      title: "No stops match your search",
      body: "Try a stop name or ID, or clear your search.",
      action: "Clear search and filters"
    }
  end

  defp empty_state_copy(:unassigned, nil) do
    %{
      title: "Every stop has a fare zone",
      body: "No stops are waiting for a zone.",
      action: "Show all stops"
    }
  end

  defp empty_state_copy({:zone, _zone_id}, nil) do
    %{
      title: "No stops in this zone yet",
      body: "Select stops from All stops, then assign them to this zone.",
      action: "Show all stops"
    }
  end

  # All stops with no search is empty only when the version has no boardable
  # stops at all. The zone filter's copy cannot be right here, so this state
  # reuses the stop catalog's first-use copy.
  defp empty_state_copy(:all, nil) do
    %{
      title: "No stops yet",
      body: "Stops appear here after you import a GTFS feed.",
      action: nil
    }
  end

  # The filters in the strip's order: All stops, then every zone sorted by its
  # exact ID, then No zone. The counts come from the inventory, so the strip never
  # disagrees with the version's data while a filter is applied.
  defp inventory_rows(inventory, filter, patch_base) do
    all = %{
      id: "fare-zone-row-all",
      current?: filter == :all,
      patch: zones_patch(patch_base, []),
      icon: "hero-square-3-stack-3d",
      ring?: false,
      color: nil,
      title: "All stops",
      count: inventory.boardable_count,
      alert?: false
    }

    zones =
      inventory.zones
      |> Enum.with_index(1)
      |> Enum.map(fn {zone, index} ->
        %{
          id: "fare-zone-row-#{index}",
          current?: filter == {:zone, zone.zone_id},
          patch: zones_patch(patch_base, zone: zone.zone_id),
          icon: nil,
          ring?: false,
          color: FareZone.color_hex(zone.color),
          title: zone.name,
          count: zone.stop_count,
          alert?: false
        }
      end)

    unassigned = %{
      id: "fare-zone-row-unassigned",
      current?: filter == :unassigned,
      patch: zones_patch(patch_base, filter: "unassigned"),
      icon: nil,
      ring?: true,
      color: nil,
      title: "No zone",
      count: inventory.unassigned_count,
      alert?: true
    }

    [all] ++ zones ++ [unassigned]
  end

  # `filter=unassigned` stays a separate key from `zone`, so a zone literally
  # named "unassigned" is its own filter. The query is assembled by
  # `URI.encode_query/1`, which escapes spaces and reserved characters.
  defp zones_patch(patch_base, []), do: patch_base
  defp zones_patch(patch_base, query), do: patch_base <> "?" <> URI.encode_query(query)

  defp chip_class(current?) do
    [
      "inline-flex min-h-11 shrink-0 items-center gap-2 rounded-control border px-3.5 text-sm font-semibold no-underline",
      if(current?,
        do: "border-action bg-selection text-strong",
        else: "border-subtle bg-white text-default hover:bg-canvas"
      )
    ]
  end

  # A count is muted beside the name. No zone is the one filter that is work to
  # do, so its count reads as a warning badge while it is above zero.
  defp chip_count_class(%{alert?: true, count: count}) when count > 0 do
    "rounded-badge bg-warning-bg px-1.5 text-[13px] font-bold tabular-nums text-warning-fg"
  end

  defp chip_count_class(_row), do: "text-[13px] font-normal tabular-nums text-muted"

  # The legend's chip repeats what the map's marker prints. A zone with a
  # declared color takes it; No zone gets the neutral chip.
  defp id_chip_class(nil) do
    "inline-grid h-7 min-w-7 max-w-[4.5rem] place-items-center overflow-hidden rounded border border-control bg-canvas px-1 text-xs font-semibold text-muted"
  end

  defp id_chip_class(_color) do
    "inline-grid h-7 min-w-7 max-w-[4.5rem] place-items-center overflow-hidden rounded border border-current px-1 text-xs font-semibold"
  end

  defp id_chip_style(nil), do: nil
  defp id_chip_style(color), do: "color: #{color}; background-color: #{color}1a"

  @doc """
  Renders the workspace's load-error state with its single recovery action.

  The title names what failed and the body says the saved data is untouched, so
  the operator can retry without doubting the version's data.

  ## Examples

      <.load_error />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def load_error(assigns) do
    ~H"""
    <div id="fare-zones-error" class={@class} {@rest}>
      <.message kind="error" title="Fares couldn’t load">
        Your saved zones and rules haven’t changed. Try loading this version again.
        <:action>
          <.button id="fare-zones-reload" phx-click="reload" class="min-h-11">
            <.icon name="hero-arrow-path" class="size-4" /> Reload fares
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders the Zones tab's first-use state, which replaces the workspace while
  the version's inventory carries no zone at all.

  The distinction matters: a filter that matches no stop is an empty list, not a
  first use, so only an inventory with no declared record, no stop zone ID and
  no fare-rule reference renders this. It says zones are optional, because a
  version whose riders pay one fare, or a fare that depends only on the route,
  needs none. Its single action opens the create drawer, and the import line tells
  an operator whose feed already carried zone IDs where they would appear.

  ## Examples

      <.first_use_empty />
  """
  def first_use_empty(assigns) do
    ~H"""
    <div id="fare-zone-first-use">
      <.first_use
        id="fare-zone-first-use-panel"
        title="Start with your first fare zone"
        icon="hero-map-pin"
      >
        A fare zone groups stops that share a fare area, such as “Newport local” or “Coast zone”.
        Name a zone, then select its stops on the map or in the list. A zone is a group of stops,
        not an area drawn on the map.
        <:action>
          <.button
            id="fare-zone-first-use-create"
            class="min-h-11"
            phx-click="open_zone_drawer"
            phx-value-opener_id="fare-zone-first-use-create"
          >
            <.icon name="hero-plus" class="size-4" /> Create first zone
          </.button>
          <p class="mt-4 text-[13px] text-muted">
            Zones are optional. If riders pay one fare, or the fare depends only on the route, you can skip them.
            Already have a feed? Stop zone IDs from an imported feed appear here on their own.
          </p>
        </:action>
      </.first_use>
    </div>
    """
  end

  @doc """
  Renders the assignment review: the AC-9 report of what a save would change.

  The dialog is where a selection becomes a write, and it states the whole
  change before it happens: how many stops are newly assigned, how many move from
  another zone, how many already hold the target, and which of their sibling
  platforms the selection does not cover. The reviewed rows follow, one per line
  with the zone each has now and the zone it would have.

  It never closes itself. A stale review, a target zone that another editor
  removed and a save that failed all leave the dialog open with its target and
  its rows, because the review is the work that must not be lost; the error or
  stale message inside the dialog names what happened, and `cancel_assignment`
  or a successful save is the only way out.

  Every state that cannot be saved says so in words. The confirm button is
  disabled while the review is stale (its "Refresh review" control is the way
  out), while an assign review has no zone to assign to, and while the review
  would change nothing; a save in flight shows its own "Saving…" label and is
  disabled by the dialog's `phx-disable-with`, which is what stops a second
  click reaching the server.

  ## Examples

      <.assignment_dialog :if={@assignment} assignment={@assignment} zones={@inventory.zones} />
  """
  attr :assignment, :map, required: true, doc: "the review state the socket holds"

  attr :zones, :list,
    required: true,
    doc: "the inventory's zones, offered as assign targets"

  def assignment_dialog(assigns) do
    assignment = assigns.assignment
    preview = assignment.preview
    rows = if preview, do: Enum.take(preview.rows, @review_row_limit), else: []

    assigns =
      assigns
      |> assign(:preview, preview)
      |> assign(:rows, rows)
      |> assign(:more, if(preview, do: length(preview.rows) - length(rows), else: 0))
      |> assign(:selected_count, if(preview, do: length(preview.rows), else: 0))
      |> assign(:remove?, assignment.mode == :unassign)
      |> assign(:target, assignment.target)
      |> assign(:options, target_options(assigns.zones))
      |> assign(:zone_lookup, Map.new(assigns.zones, &{&1.zone_id, &1}))
      |> assign(:summary, if(preview, do: assignment_summary(assignment), else: nil))
      |> assign(:reason, confirm_reason(assignment))
      |> assign(:confirm_disabled, not confirmable?(assignment))

    ~H"""
    <.confirm_dialog
      id="fare-zone-assignment-dialog"
      chrome="planner"
      open={true}
      title={assignment_title(@remove?, @selected_count)}
      confirm_label={assignment_confirm_label(@remove?, @preview)}
      pending_label="Saving…"
      on_confirm="apply_assignment"
      on_cancel="cancel_assignment"
      cancel_label="Keep selection"
      confirm_disabled={@confirm_disabled}
      return_focus_id={
        if @remove?, do: "fare-zone-unassign-selection", else: "fare-zone-assign-selection"
      }
      described_by="fare-zone-assignment-dialog-body"
      size="lg"
    >
      <%!-- One rhythm for the review's blocks: the wrapper owns the gap between
      them, so the summary, the warnings and the rows never touch. --%>
      <div id="fare-zone-assignment-review" class="grid gap-4">
        <p :if={@selected_count > 0} id="fare-zone-assignment-intro">
          Review what will change before you save.
        </p>

        <.message
          :if={@assignment.error}
          id="fare-zone-assignment-error"
          kind="error"
          title={@assignment.error}
          tabindex="-1"
          phx-mounted={JS.focus()}
        />

        <form
          :if={!@remove?}
          id="fare-zone-assignment-target-form"
          phx-change="change_assignment_target"
        >
          <.input
            id="fare-zone-assignment-target"
            name="target"
            type="select"
            label="Assign to zone"
            value={@target}
            options={@options}
          />
        </form>

        <div
          :if={@summary}
          id="fare-zone-assignment-summary"
          class={["grid gap-3", if(@remove?, do: "grid-cols-2", else: "grid-cols-3")]}
        >
          <.review_tile
            :for={tile <- @summary.tiles}
            id={"fare-zone-assignment-summary-#{tile.key}"}
            label={tile.label}
            value={tile.value}
            warn?={tile.warn?}
          />
        </div>

        <.message
          :if={not @remove? and @summary != nil and @summary.moved?}
          id="fare-zone-assignment-moved"
          kind="warning"
          title="Moving stops can change which fares apply to journeys that use them."
        >
          Existing fare rules keep their zone references.
        </.message>

        <.message
          :if={@summary != nil and @preview.unselected_sibling_count > 0}
          id="fare-zone-assignment-siblings"
          kind="info"
          title={sibling_platforms_copy(@preview.unselected_sibling_count)}
        >
          Each platform is assigned separately. Station groups are never changed silently.
        </.message>

        <div :if={@rows != []} id="fare-zone-assignment-rows">
          <p class="mb-1 text-[13px] font-[650] text-default">
            {Wording.count_noun(@selected_count, "stop")} in this review
          </p>
          <ul class="divide-y divide-subtle rounded-card border border-subtle text-sm">
            <li
              :for={{row, index} <- Enum.with_index(@rows, 1)}
              id={"fare-zone-assignment-row-#{index}"}
              class="flex items-center justify-between gap-3 px-3 py-2"
            >
              <span class="min-w-0 truncate text-strong">{row.stop_name || row.stop_id}</span>
              <span class="flex shrink-0 items-center gap-2 text-[13px] text-default">
                <.review_zone
                  id={"fare-zone-assignment-row-#{index}-from"}
                  zone_id={row.from}
                  lookup={@zone_lookup}
                />
                <span aria-label="becomes" class="text-muted">→</span>
                <.review_zone
                  id={"fare-zone-assignment-row-#{index}-to"}
                  zone_id={row.to}
                  lookup={@zone_lookup}
                  strong?={true}
                />
              </span>
            </li>
          </ul>
          <p :if={@more > 0} id="fare-zone-assignment-more" class="mt-1 text-[13px] text-muted">
            and {@more} more
          </p>
        </div>

        <%!-- The stale notice follows the reviewed rows and sits just above the
        footer, which is also where the disabled confirm button is: the operator
        re-reads what would be written, then sees that it moved. --%>
        <.message
          :if={@assignment.stale > 0}
          id="fare-zone-assignment-stale"
          kind="warning"
          title={stale_stops_copy(@assignment.stale)}
          tabindex="-1"
          phx-mounted={JS.focus()}
        >
          Nothing was saved. Refresh the review to see the current zones.
          <:action>
            <.button
              id="fare-zone-assignment-refresh"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="refresh_assignment"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh review
            </.button>
          </:action>
        </.message>

        <p :if={@reason} id="fare-zone-assignment-reason" class="text-sm text-muted">{@reason}</p>
      </div>
    </.confirm_dialog>
    """
  end

  # One count of the review, large over its label.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :warn?, :boolean, default: false

  defp review_tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-card border border-subtle px-3 py-3">
      <p class={[
        "font-display text-[28px] font-semibold leading-none tracking-[-0.035em] tabular-nums",
        if(@warn? and @value > 0, do: "text-warning-fg", else: "text-strong")
      ]}>
        {@value}
      </p>
      <p class="mt-1.5 text-[13px] leading-snug text-muted">{@label}</p>
    </div>
    """
  end

  # A zone in a reviewed row, by the name the team recognizes. A stop with no zone
  # is muted, and a zone the inventory does not carry is its exact stored ID.
  attr :id, :string, required: true
  attr :zone_id, :string, default: nil
  attr :lookup, :map, required: true
  attr :strong?, :boolean, default: false

  defp review_zone(%{zone_id: nil} = assigns) do
    ~H"""
    <span id={@id} class="text-muted">No zone</span>
    """
  end

  # A stored ID is byte-exact, so the name sits in its span without formatter
  # whitespace: what the review shows is what the save will write.
  defp review_zone(assigns) do
    assigns = assign(assigns, :name, zone_display_name(assigns.lookup, assigns.zone_id))

    ~H"""
    <span phx-no-format id={@id} class={[@strong? && "font-bold text-strong"]}>{@name}</span>
    """
  end

  @doc """
  Renders what a completed assignment did, with Undo while it is still offered.

  The message is the count the save applied, so it reports the write that
  happened rather than the review that was shown. Undo is present only while the
  socket still holds the applied changes: a second save, a tab change and a
  version switch each replace or drop it, and an undone or superseded change
  reports its outcome without the button.

  ## Examples

      <.saved_callout :if={@undo} undo={@undo} />
  """
  attr :undo, :map, required: true, doc: "the socket's `@undo` state"

  def saved_callout(assigns) do
    ~H"""
    <div id="fare-zone-saved" class="mb-4">
      <.message kind={@undo.kind} title={@undo.message}>
        <:action :if={@undo.applied}>
          <.button
            id="fare-zone-undo"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="undo_assignment"
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" /> Undo
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders the zone create/edit drawer.

  `entity` is the inventory entry the strip already shows, or nil to create.
  The entry is the form's own state: its exact stored `zone_id` bytes prefill the
  ID field and drive the domain's byte-for-byte decision, so an imported `" A"`
  survives a name-only edit untouched, and the counts it carries become the edit
  summary. A create instead states that the new zone starts empty.

  The form validates on change and on submit. A field error renders beside its
  field, the `FormErrorFocus` hook takes focus to the first invalid one, and
  `error` carries the outcomes that belong to no field - a zone another editor
  removed, or a version that is no longer a published version of the
  organization - so the drawer stays open and says what happened instead of
  discarding the operator's work.

  ## Examples

      <.zone_drawer open={@zone_drawer_open} entity={@zone_drawer_entry} form={@zone_form} />
  """
  attr :open, :boolean, default: false
  attr :entity, :map, default: nil, doc: "the inventory entry being edited, or nil to create"
  attr :form, :any, required: true, doc: "`FareZones.change_zone/2`'s form"
  attr :version_name, :string, default: nil, doc: "the version the zone belongs to"
  attr :error, :string, default: nil, doc: "a drawer-level reason the save did not happen"
  attr :return_focus_id, :string, default: nil

  def zone_drawer(assigns) do
    assigns =
      assigns
      |> assign(:editing?, not is_nil(assigns.entity))
      |> assign(
        :title,
        if(assigns.entity, do: "Edit #{assigns.entity.name}", else: "Create a fare zone")
      )
      |> assign(:colors, palette_swatches())
      |> assign(:selected_color, assigns.form[:color].value)

    ~H"""
    <.drawer
      id="fare-zone-drawer"
      chrome="planner"
      open={@open}
      on_close="close_zone_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[480px]"
    >
      <:lede :if={@version_name}>
        <span id="fare-zone-drawer-scope">
          {zone_drawer_scope(@editing?, @entity, @version_name)}
        </span>
      </:lede>

      <div
        id="fare-zone-drawer-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id="fare-zone-form"
          as={:zone}
          novalidate
          phx-change="validate_zone"
          phx-submit="save_zone"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.message
              :if={@error}
              id="fare-zone-drawer-error"
              kind="error"
              title={@error}
              tabindex="-1"
              phx-mounted={JS.focus()}
            />

            <p id="fare-zone-drawer-intro" class="text-sm text-muted">
              {if @editing?,
                do: "Update the name your team sees, or change the zone ID your feed carries.",
                else: "Start with a name people recognize. You can assign stops next."}
            </p>

            <.input
              id="fare-zone-name"
              field={@form[:name]}
              type="text"
              label="Zone name"
              placeholder="For example, Newport local"
              help="The name shown on chips, lists and maps."
              autocomplete="off"
              phx-debounce="300"
            />

            <.input
              id="fare-zone-id"
              field={@form[:zone_id]}
              type="text"
              label="Zone ID"
              placeholder="For example, NPT"
              help="A short code, unique in this version. It is written to your feed as zone_id. Use letters, numbers, hyphens or underscores."
              autocomplete="off"
              spellcheck="false"
              class="w-full max-w-[240px] input input-lg font-mono"
              phx-debounce="300"
            />

            <fieldset id="fare-zone-color" class="min-w-0">
              <legend class="mb-1.5 text-[13px] font-[650] text-default">Map color</legend>
              <div class="flex flex-wrap gap-2">
                <label
                  :for={color <- @colors}
                  class={[
                    "flex min-h-11 cursor-pointer items-center gap-2 rounded-control border px-3 text-sm",
                    "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus",
                    if(@selected_color == color.key,
                      do: "border-action bg-selection font-semibold text-strong",
                      else: "border-control bg-white text-default hover:bg-canvas"
                    )
                  ]}
                >
                  <input
                    type="radio"
                    id={"fare-zone-color-#{color.key}"}
                    name={@form[:color].name}
                    value={color.key}
                    checked={@selected_color == color.key}
                    class="size-[18px] accent-action"
                  />
                  <.zone_dot color={color.hex} class="size-3" />
                  {color.label}
                </label>
              </div>
              <p id="fare-zone-color-help" class="mt-1.5 text-[13px] text-muted">
                Colors this zone’s map markers and its chip. Markers also show the zone ID, so color is never the only cue.
              </p>
            </fieldset>

            <%!-- An edit names what changing the ID rewrites, because that is the
            difference between this drawer and renaming a display label. A
            drawer-level failure hides it: the inventory was just read again, so
            counts captured when the drawer opened could contradict the reason the
            save cannot happen. A field error keeps it - the save is still the
            operator's to retry. --%>
            <.message
              :if={@editing? and is_nil(@error)}
              id="fare-zone-drawer-summary"
              kind="info"
              title={edit_summary_title(@entity)}
            >
              <span id="fare-zone-drawer-summary-updates">
                Changing the zone ID updates these references together.
              </span>
              <span :if={@entity.other_stop_count > 0} id="fare-zone-drawer-summary-others">
                {station_line(@entity.other_stop_count)}
              </span>
            </.message>

            <.message
              :if={!@editing?}
              id="fare-zone-drawer-note"
              kind="info"
              title="A new zone starts empty."
            >
              It stays available while you choose its stops.
            </.message>
          </.drawer_scroll>

          <.drawer_footer>
            <%!-- The destructive exit is a text action at the footer's left, so
            it never reads as the drawer's own save. --%>
            <.button
              :if={@editing?}
              id="fare-zone-delete"
              type="button"
              variant="quiet"
              class="mr-auto min-h-11 px-2 text-error-fg hover:bg-error-bg"
              phx-click="open_delete_zone"
              phx-value-zone_id={@entity.zone_id}
              phx-value-opener_id={@return_focus_id}
            >
              <.icon name="hero-trash" class="size-4" /> Delete zone…
            </.button>
            <.button
              id="fare-zone-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_zone_drawer"
            >
              Cancel
            </.button>
            <.button id="fare-zone-save" type="submit" class="min-h-11" phx-disable-with="Saving…">
              {if @editing?, do: "Save zone", else: "Create zone"}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the confirm dialog that deletes a zone.

  `zone_delete` is the socket's whole dialog state: the inventory entry the
  dialog opened on, the replacement select's value, the counts that entry had
  when the dialog opened (the fence the write compares against), and the stale
  counts or error a refused write produced. The entry decides the dialog's
  shape. A zone fare rules use says "Replace references with" and offers the
  other inventory zones only, with nothing chosen until the operator chooses one;
  an unreferenced zone with stops says "Move its stops to" and offers No zone
  first; an empty zone replaces the select with its own sentence.

  The disabled confirm always says why. A zone fare rules use cannot be deleted
  without a replacement zone, so a version with no other zone keeps the zone and
  the reason on screen, and so does a dialog where no replacement is chosen yet
  (AC-27).

  ## Examples

      <.delete_zone_dialog
        :if={@zone_delete}
        zone_delete={@zone_delete}
        zones={@inventory.zones}
      />
  """
  attr :zone_delete, :map, required: true, doc: "the socket's `@zone_delete` state"
  attr :zones, :list, required: true, doc: "the inventory's zones, offered as replacements"
  attr :return_focus_id, :string, default: nil

  def delete_zone_dialog(assigns) do
    zone = assigns.zone_delete.zone
    options = delete_replacement_options(zone, assigns.zones)
    referenced? = zone.stop_count > 0 or zone.rule_count > 0

    needs_choice? =
      zone.rule_count > 0 and options != [] and is_nil(assigns.zone_delete.replacement)

    assigns =
      assigns
      |> assign(:zone, zone)
      |> assign(:options, options)
      |> assign(:referenced?, referenced?)
      |> assign(:replacement, assigns.zone_delete.replacement || "")
      |> assign(
        :replacement_label,
        if(zone.rule_count > 0, do: "Replace references with", else: "Move its stops to")
      )
      |> assign(:warning, delete_warning(zone))
      |> assign(:confirm_disabled, options == [] or needs_choice?)
      |> assign(:reason, delete_disabled_reason(zone, options, needs_choice?))

    ~H"""
    <.confirm_dialog
      id="fare-zone-delete-dialog"
      chrome="planner"
      open={true}
      title={"Delete #{@zone.name}?"}
      confirm_label="Delete zone"
      pending_label="Deleting…"
      on_confirm="delete_zone"
      on_cancel="cancel_delete_zone"
      cancel_label="Keep zone"
      confirm_disabled={@confirm_disabled}
      return_focus_id={@return_focus_id}
      described_by="fare-zone-delete-dialog-body"
    >
      <div id="fare-zone-delete-body" class="grid gap-4">
        <div class="grid gap-1">
          <p id="fare-zone-delete-consequence">
            {Wording.count_noun(@zone.stop_count, "stop")} and {Wording.count_noun(
              @zone.rule_count,
              "fare rule"
            )} use this zone.
          </p>
          <p :if={@zone.other_stop_count > 0} id="fare-zone-delete-others">
            {delete_station_line(@zone.other_stop_count)}
          </p>
        </div>

        <%!-- A refused write keeps the dialog open here, so the reason and the
        control it explains stay together. --%>
        <.message
          :if={@zone_delete.stale}
          id="fare-zone-delete-stale"
          kind="warning"
          title={stale_zone_copy(@zone_delete.stale)}
          tabindex="-1"
          phx-mounted={JS.focus()}
        />

        <.message
          :if={@zone_delete.error}
          id="fare-zone-delete-error"
          kind="error"
          title={@zone_delete.error}
          tabindex="-1"
          phx-mounted={JS.focus()}
        />

        <form
          :if={@referenced? and @options != []}
          id="fare-zone-delete-replacement-form"
          phx-change="change_replacement"
        >
          <.input
            id="fare-zone-delete-replacement"
            name="replacement"
            type="select"
            label={@replacement_label}
            value={@replacement}
            options={@options}
            prompt={if @zone.rule_count > 0, do: "Choose a zone"}
          />
        </form>

        <.message
          :if={@referenced? and @options != []}
          id="fare-zone-delete-warning"
          kind="warning"
          title={@warning}
        />

        <p :if={not @referenced?} id="fare-zone-delete-empty" class="text-sm">
          This empty zone has no references. Deleting it won’t change stops or fares.
        </p>

        <p :if={@reason} id="fare-zone-delete-reason" class="text-sm text-muted">{@reason}</p>
      </div>
    </.confirm_dialog>
    """
  end

  # The drawer header's line: which version the zone is in, and for an edit the
  # zone ID the feed carries.
  defp zone_drawer_scope(true, %{zone_id: zone_id}, version_name),
    do: "#{version_name} · zone ID #{zone_id}"

  defp zone_drawer_scope(_editing?, _entity, version_name), do: "Adds a zone to #{version_name}."

  # The palette in the drawer's own order, as radio data.
  defp palette_swatches do
    Enum.map(FareZone.palette(), fn {key, label, hex} ->
      %{key: key, label: label, hex: hex}
    end)
  end

  # The edit summary's headline: the counts the zone's ID rewrites.
  defp edit_summary_title(%{stop_count: stop_count, rule_count: rule_count}) do
    "#{Wording.count_noun(stop_count, "stop")} · #{rules_use_copy(rule_count)} this zone"
  end

  defp rules_use_copy(1), do: "1 fare rule uses"
  defp rules_use_copy(count), do: "#{count} fare rules use"

  # The station/entrance disclosure, written for the count it carries: the rest of
  # the workspace counts one of something in the singular too.
  defp station_line(1), do: "Also updates 1 station or entrance with this zone ID."

  defp station_line(count),
    do: "Also updates #{count} stations or entrances with this zone ID."

  defp delete_station_line(1), do: "Also moves 1 station or entrance with this zone ID."

  defp delete_station_line(count),
    do: "Also moves #{count} stations or entrances with this zone ID."

  defp stale_zone_copy(%{stop_count: stop_count, rule_count: rule_count}) do
    "This zone changed since you opened this dialog. It now has " <>
      "#{Wording.count_noun(stop_count, "stop")} and #{Wording.count_noun(rule_count, "fare rule")}."
  end

  # The replacement select. No zone is the unreferenced zone's own choice and
  # comes first when it is offered; a zone fare rules use can only move to
  # another inventory zone, which is what the write will accept.
  defp delete_replacement_options(%{zone_id: zone_id, rule_count: 0}, zones) do
    [{"No zone", ""} | target_options(Enum.reject(zones, &(&1.zone_id == zone_id)))]
  end

  defp delete_replacement_options(%{zone_id: zone_id}, zones) do
    target_options(Enum.reject(zones, &(&1.zone_id == zone_id)))
  end

  defp delete_warning(%{rule_count: rule_count}) when rule_count > 0 do
    "Stops and fare rules will move together. This changes which journeys the related fares cover."
  end

  defp delete_warning(_zone), do: "Stops are kept. Only their zone assignment changes."

  # A disabled confirm is never silent: a zone fare rules use with no other zone
  # to move them to, or with no zone chosen yet, says which.
  defp delete_disabled_reason(%{rule_count: rule_count}, [], _needs_choice?)
       when rule_count > 0 do
    "Create another zone first. Fare rules need a replacement zone."
  end

  defp delete_disabled_reason(_zone, _options, true) do
    "Choose the zone that takes over this zone’s stops and fare rules."
  end

  defp delete_disabled_reason(_zone, _options, _needs_choice?), do: nil

  # The select's options: every zone of the version's inventory, labeled by the
  # name people recognize beside the exact ID that travels with the feed.
  defp target_options(zones) do
    Enum.map(zones, &{"#{&1.name} · #{&1.zone_id}", &1.zone_id})
  end

  defp zone_display_name(lookup, zone_id) do
    case Map.get(lookup, zone_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _zone -> zone_id
    end
  end

  # The review's arithmetic as tiles, in the order that matters: what changes
  # first, then what does not.
  defp assignment_summary(assignment) do
    preview = assignment.preview

    case assignment.mode do
      :unassign ->
        %{
          tiles: [
            %{
              key: "changed",
              label: "Stops lose their zone",
              value: preview.changed_count,
              warn?: false
            },
            %{
              key: "unchanged",
              label: "Already have no zone",
              value: preview.unchanged_count,
              warn?: false
            }
          ],
          moved?: false
        }

      :assign ->
        %{
          tiles: [
            %{key: "added", label: "Newly assigned", value: preview.added_count, warn?: false},
            %{
              key: "moved",
              label: "Moved from another zone",
              value: preview.moved_count,
              warn?: true
            },
            %{
              key: "unchanged",
              label: "Already in this zone",
              value: preview.unchanged_count,
              warn?: false
            }
          ],
          moved?: preview.moved_count > 0
        }
    end
  end

  defp assignment_title(true, count) when count > 0,
    do: "Remove zone from #{Wording.count_noun(count, "stop")}"

  defp assignment_title(true, _count), do: "Remove zone from stops"

  defp assignment_title(false, count) when count > 0,
    do: "Assign #{Wording.count_noun(count, "stop")} to a zone"

  defp assignment_title(false, _count), do: "Assign stops to a zone"

  # The confirm repeats the verb and its object: how many stops will change.
  defp assignment_confirm_label(true, _preview), do: "Remove zone"

  defp assignment_confirm_label(false, %{changed_count: count}) when count > 0,
    do: "Assign #{Wording.count_noun(count, "stop")}"

  defp assignment_confirm_label(false, _preview), do: "Assign stops"

  # A review that would change nothing is not a failure, so it says what the
  # selection already is rather than leaving the disabled button unexplained.
  defp confirm_reason(%{mode: :assign, target: nil}), do: "Create a fare zone first."
  defp confirm_reason(%{stale: stale}) when stale > 0, do: nil
  defp confirm_reason(%{error: error}) when is_binary(error), do: nil
  defp confirm_reason(%{preview: nil}), do: nil

  defp confirm_reason(%{mode: :assign, preview: %{changed_count: 0}}),
    do: "Nothing to change: every selected stop already has this zone."

  defp confirm_reason(%{preview: %{changed_count: 0}}),
    do: "Nothing to change: every selected stop already has no zone."

  defp confirm_reason(_assignment), do: nil

  # A stale review, an unknown target and a lost selection each carry their own
  # visible reason, so they are not also "nothing to change".
  defp confirmable?(%{stale: stale}) when stale > 0, do: false
  defp confirmable?(%{error: error}) when is_binary(error), do: false
  defp confirmable?(%{mode: :assign, target: nil}), do: false
  defp confirmable?(%{preview: %{changed_count: count}}) when count > 0, do: true
  defp confirmable?(_assignment), do: false

  defp stale_stops_copy(1), do: "1 selected stop changed since you opened this review."

  defp stale_stops_copy(count),
    do: "#{count} selected stops changed since you opened this review."

  defp sibling_platforms_copy(1), do: "1 sibling platform is not selected."
  defp sibling_platforms_copy(count), do: "#{count} sibling platforms are not selected."
end
