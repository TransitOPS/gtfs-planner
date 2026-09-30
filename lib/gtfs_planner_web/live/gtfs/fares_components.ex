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

  The Fare rules tab reads the version's rules as one table row per UI rule, in
  the grouping the domain decided: a rule stored as several `fare_rules` rows is one
  row, and two rules that share a fare and route but differ in their journey or
  their through zones are two. Each row's journey names the zones the inventory
  names, and a rule that references a zone with no boardable stops, a fare with no
  price row or a route the version does not carry is marked in the row, so a
  reference that can be kept but not created is visible where the rule is read.

  The rule drawer is the create and edit surface for a rule, and it edits the
  group the page read rather than a key the browser sent. It asks in the order
  people think: which journeys, then which fare, under a sentence that follows
  every change. Its selects offer only what this version carries - the fares with
  their prices, the routes, and the zones with their IDs - plus, for an existing
  rule, the fare or route it already names when that row is gone, so an imported
  rule stays editable. A new rule starts with no fare chosen, so it cannot take
  the first fare in the list by accident. Nothing about a rejected save, a rule
  another editor changed or a vanished version closes the drawer or discards what
  the operator chose; the stale state offers Reload rule, which reloads the rule
  the drawer was opened on. Removal is the drawer's destructive exit: a
  confirmation names the rule and states that the fare itself remains.

  The Checks tab reads `FareZones.checks/2` as a checklist: four counts, then one
  row per finding in the order of how urgent it is, each with the reason in plain
  words and a link to where it is fixed. Checks that pass fold into one
  disclosure.
  """

  # The review lists at most this many rows; AC-25 asks for the first 100 and a
  # count of the rest.
  @review_row_limit 100

  # Trip planners build one rule set per fare, so a route or through-zone
  # condition on one rule reaches all of the fare's rules.
  @shared_fare_note "Rules that share a fare are read together by trip planners: a route or pass-through condition on one rule applies to all of that fare's rules."

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, first_use: 1, form_section: 1, message: 1]

  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.FareZone

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
  Renders the Fare rules tab: the intro, the table of rules and the empty states.

  Each row is one UI rule - the whole set of `fare_rules` rows sharing its fare,
  route, origin, destination and through-zone shape - so a rule stored as two
  `contains_id` rows renders once with both zones on its journey, and two rules
  that differ in any of those fields render as two rows. Nothing here regroups,
  splits or merges what `FareZones.list_rule_groups/2` read, and the rows arrive
  as a stream, so a later reload replaces the list rather than the surrounding
  tab.

  A table compares prices at a glance: journey, route, fare, and the price aligned
  right. Below 768 px each row becomes a small record with the journey and price
  side by side. The empty states are the tab's only zero states: no rules yet,
  and a version with no fares at all, where a rule has nothing to choose from.

  ## Examples

      <.rules_tab
        rule_groups={@streams.rule_groups}
        rule_count={length(@rule_groups)}
        zones={@inventory.zones}
        fares={@fares}
        import_path={~p"/gtfs/\#{@version.id}/import"}
      />
  """
  attr :rule_groups, :any, required: true, doc: "the `:rule_groups` stream"
  attr :rule_count, :integer, required: true, doc: "how many rules the load read"
  attr :fares, :list, required: true, doc: "`FareZones.list_fares/2`"
  attr :import_path, :string, required: true, doc: "where a version with no fares gets some"

  attr :zones, :list,
    required: true,
    doc: "the inventory's zones, for the names and stop counts the rows read"

  def rules_tab(assigns) do
    assigns =
      assigns
      |> assign(:zone_lookup, Map.new(assigns.zones, &{&1.zone_id, &1}))
      |> assign(:shared_fare_note, @shared_fare_note)

    ~H"""
    <div id="fare-rules-tab">
      <.message
        :if={@fares != [] or @rule_count > 0}
        id="fare-rules-intro"
        kind="info"
        title="Rules choose which fare applies to a journey."
      >
        Fares and their prices come from your imported feed and can’t be edited here.
      </.message>

      <.first_use
        :if={@rule_count == 0 and @fares == []}
        id="fare-rules-no-fares"
        title="No fares to choose from yet"
        icon="hero-ticket"
      >
        A fare rule picks one of this version’s fares. This version has none. Fares come from your
        feed’s fare list (fare_attributes.txt), so add them to your feed and import it again.
        <:action>
          <.button navigate={@import_path} class="min-h-11" id="fare-rules-import">
            <.icon name="hero-arrow-up-tray" class="size-4" /> Import a feed
          </.button>
        </:action>
      </.first_use>

      <.first_use
        :if={@rule_count == 0 and @fares != []}
        id="fare-rules-empty"
        title="No fare rules yet"
        icon="hero-ticket"
      >
        A fare rule says which fare riders pay for a journey: between two zones, within one zone, or
        on one route. Your feed has {fares_copy(length(@fares))} ready to use.
        <:action>
          <.button
            id="add-fare-rule"
            class="min-h-11"
            phx-click="open_rule_drawer"
            phx-value-opener_id="add-fare-rule"
          >
            <.icon name="hero-plus" class="size-4" /> Add first fare rule
          </.button>
        </:action>
      </.first_use>

      <section
        :if={@rule_count > 0}
        id="fare-rules-table"
        aria-label="Fare rules"
        class="mt-4 overflow-clip rounded-card border border-subtle bg-white"
      >
        <p
          id="fare-rules-count"
          class="flex min-h-14 items-center border-b border-subtle px-4 text-sm font-bold tabular-nums text-strong sm:px-5"
        >
          {rules_copy_count(@rule_count)}
        </p>
        <table class="w-full border-collapse text-left text-sm">
          <caption class="sr-only">Fare rules</caption>
          <thead class="max-md:sr-only">
            <tr class="bg-canvas text-[13px] font-[650] text-default">
              <th scope="col" class="border-b border-subtle py-3 pl-5 pr-3">Journey</th>
              <th scope="col" class="border-b border-subtle px-3 py-3">Route</th>
              <th scope="col" class="border-b border-subtle px-3 py-3">Fare</th>
              <th scope="col" class="border-b border-subtle px-3 py-3 text-right">Price</th>
              <th scope="col" class="border-b border-subtle py-3 pl-3 pr-5 text-right">
                <span class="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody id="fare-rule-list" phx-update="stream">
            <.rule_row
              :for={{dom_id, rule} <- @rule_groups}
              id={dom_id}
              rule={rule}
              zone_lookup={@zone_lookup}
            />
          </tbody>
        </table>
      </section>

      <p :if={@rule_count > 0} id="fare-rules-note" class="mt-4 max-w-[80ch] text-sm text-muted">
        Each rule applies in one direction, so a return journey needs its own rule. When more than
        one rule matches a journey, trip planners are expected to show the lowest fare. {@shared_fare_note}
      </p>
    </div>
    """
  end

  @doc """
  Renders one fare rule as a table row: its journey, route, fare, price and the
  action that opens it.

  The journey is the row's prominent line and reads the way the rule applies -
  "Newport local → Toledo & valley", "Within Coast zone", "Starting in Central",
  "Ending in Eastbank" or "Any journey" - and a rule that must pass through zones
  says so under it. Zone names are the inventory's, so a zone no record declares
  reads as its exact stored ID and no name is trimmed here. A rule that
  references a zone with no boardable stops, a fare with no price row or a route
  the version does not carry is marked under the journey, because an imported
  reference is kept while a new one cannot be created.

  "Edit rule" opens the drawer on this rule: it sends the row's own DOM ID, and
  the LiveView resolves that ID back to the group it streamed, so the reviewed
  rows come from the page's read rather than from anything the browser said about
  the rule (INV-4).

  ## Examples

      <.rule_row id={dom_id} rule={rule} zone_lookup={@zone_lookup} />
  """
  attr :id, :string, required: true, doc: "the stream's DOM ID, from the rule's own rows"
  attr :rule, :map, required: true, doc: "one `FareZones.list_rule_groups/2` group"
  attr :zone_lookup, :map, required: true, doc: "the inventory's zones by exact stored ID"

  def rule_row(assigns) do
    assigns =
      assigns
      |> assign(:journey, rule_journey_text(assigns.rule, assigns.zone_lookup))
      |> assign(:through, rule_through_text(assigns.rule, assigns.zone_lookup))
      |> assign(:stopless_zone, rule_stopless_zone(assigns.rule, assigns.zone_lookup))
      |> assign(:price, rule_price_text(assigns.rule))

    ~H"""
    <tr
      id={@id}
      class="border-b border-subtle align-middle last:border-b-0 hover:bg-canvas max-md:grid max-md:grid-cols-[minmax(0,1fr)_auto] max-md:gap-x-3 max-md:gap-y-1 max-md:p-4"
    >
      <td class="min-w-0 py-3 pl-5 pr-3 max-md:col-start-1 max-md:row-start-1 max-md:p-0">
        <%!-- Zone names are stored bytes, so no formatter whitespace may sit around
        the journey. --%>
        <span
          phx-no-format
          id={"#{@id}-journey"}
          class="block break-words text-[15px] font-semibold text-strong"
        >{@journey}</span>
        <span :if={@through} id={"#{@id}-through"} class="block text-[13px] text-muted">
          {@through}
        </span>
        <span
          :if={@stopless_zone || @rule.unknown_fare? || @rule.unknown_route?}
          class="mt-1.5 flex flex-wrap gap-1.5"
        >
          <.rule_flag :if={@stopless_zone} id={"#{@id}-stopless"} tone={:warning}>
            {@stopless_zone} has no stops
          </.rule_flag>
          <.rule_flag :if={@rule.unknown_fare?} id={"#{@id}-unknown-fare"} tone={:error}>
            Fare not in this version
          </.rule_flag>
          <.rule_flag :if={@rule.unknown_route?} id={"#{@id}-unknown-route"} tone={:warning}>
            Route {@rule.route_id} not in this version
          </.rule_flag>
        </span>
      </td>
      <td id={"#{@id}-route"} class="px-3 py-3 max-md:col-span-2 max-md:p-0 max-md:pt-1">
        <.rule_route rule={@rule} />
      </td>
      <td
        id={"#{@id}-fare"}
        class="px-3 py-3 font-semibold text-strong max-md:col-start-2 max-md:row-start-2 max-md:p-0 max-md:text-right max-md:text-[13px] max-md:font-normal max-md:text-muted"
      >
        {@rule.fare_id}
      </td>
      <td
        id={"#{@id}-price"}
        class="px-3 py-3 text-right max-md:col-start-2 max-md:row-start-1 max-md:p-0"
      >
        <span :if={@price} class="font-bold tabular-nums text-strong">{@price}</span>
        <span :if={!@price} class="text-muted">—</span>
      </td>
      <td class="py-2 pl-3 pr-5 text-right max-md:col-span-2 max-md:p-0 max-md:pt-2 max-md:text-left">
        <.button
          id={"#{@id}-edit"}
          variant="quiet"
          class="min-h-11 px-2 text-action hover:bg-transparent hover:underline"
          phx-click="open_rule_drawer"
          phx-value-rule_id={@id}
          phx-value-opener_id={"#{@id}-edit"}
        >
          Edit rule
        </.button>
      </td>
    </tr>
    """
  end

  # The route a rule is limited to: its own short name as a badge beside the long
  # name, "All routes" when it is not limited, and the route's ID when the
  # version no longer carries the route.
  attr :rule, :map, required: true

  defp rule_route(%{rule: %{route_id: nil}} = assigns) do
    ~H"""
    <span class="text-muted">All routes</span>
    """
  end

  defp rule_route(%{rule: %{route: nil}} = assigns) do
    ~H"""
    <span class="text-muted">Route {@rule.route_id}</span>
    """
  end

  defp rule_route(assigns) do
    assigns = assign(assigns, :short, present(assigns.rule.route.short_name))
    assigns = assign(assigns, :long, present(assigns.rule.route.long_name))

    ~H"""
    <span class="inline-flex items-center gap-2">
      <span
        :if={@short}
        class="inline-flex h-7 min-w-9 items-center justify-center rounded-badge bg-canvas px-1.5 text-[15px] font-extrabold leading-none tabular-nums text-strong"
      >
        {@short}
      </span>
      <span class="text-sm">{@long || (!@short && @rule.route_id)}</span>
    </span>
    """
  end

  # A problem in a rule the row can name, in words and an icon, so the mark never
  # depends on its color.
  attr :id, :string, required: true
  attr :tone, :atom, values: [:warning, :error], required: true
  slot :inner_block, required: true

  defp rule_flag(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center gap-1.5 rounded-badge px-2 py-0.5 text-[13px] font-[650]",
        @tone == :warning && "bg-warning-bg text-warning-fg",
        @tone == :error && "bg-error-bg text-error-fg"
      ]}
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5" /> {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders the Checks tab: the workspace's counts, its findings as a checklist and
  the checks that passed.

  Every row is derived from `FareZones.checks/2`, so the tab reports what the
  version's own data says rather than its own reading: one "Needs repair" row per
  zone fare rules use that has no boardable stops, one "Review" row while
  boardable stops have no zone, one "Review" row per fare whose rules trip planners
  combine, one "Note" row for the declared zones with nothing in them, and the
  "Source check" row only while fare rules reference zones at all. The four counts above the rows are those same rows, plus the checks that
  passed. With no needs-repair and no review row, the tab says so and points on to
  export.

  Each row that asks for an action carries a link, and its patch target is built by
  `URI.encode_query/1`, so a zone ID keeps its exact bytes and `filter=unassigned`
  stays a separate key from `zone`. Row DOM IDs are the row's index, never a zone
  ID.

  ## Examples

      <.checks_tab
        checks={@checks}
        patch_base={zones_path(@current_gtfs_version.id)}
        version_name={@current_gtfs_version.name}
        export_path={~p"/gtfs/\#{@current_gtfs_version.id}/export"}
      />
  """
  attr :checks, :map, required: true, doc: "`FareZones.checks/2`"
  attr :patch_base, :string, required: true, doc: "the Zones path, without a query"
  attr :version_name, :string, default: nil, doc: "the version the checks are for"
  attr :export_path, :string, required: true, doc: "where a clean version goes next"

  def checks_tab(assigns) do
    checks = assigns.checks

    clean? =
      checks.stopless_referenced == [] and checks.unassigned_count == 0 and
        checks.combined_fares == []

    passed =
      [
        {checks.rules_reference_zones? and checks.stopless_referenced == [],
         "Every zone used by a fare rule has stops."},
        {checks.unassigned_count == 0, "Every stop has a fare zone."},
        {checks.combined_fares == [],
         "No fare has rules that disagree on route or pass-through zones."},
        {checks.empty_declared == [], "No zone is empty."}
      ]
      |> Enum.filter(fn {passed?, _line} -> passed? end)
      |> Enum.map(fn {_passed?, line} -> line end)

    assigns =
      assigns
      |> assign(:stopless, checks.stopless_referenced)
      |> assign(:unassigned, checks.unassigned_count)
      |> assign(:empty_declared, checks.empty_declared)
      |> assign(:combined_fares, checks.combined_fares)
      |> assign(:clean?, clean?)
      |> assign(:passed, passed)

    ~H"""
    <div id="fare-checks-tab">
      <section
        aria-labelledby="fare-checks-heading"
        class="overflow-clip rounded-card border border-subtle bg-white"
      >
        <div class="border-b border-subtle px-4 py-4 sm:px-5">
          <h2
            id="fare-checks-heading"
            class="font-display text-[24px] font-semibold tracking-[-0.025em] text-strong"
          >
            Setup checks
          </h2>
          <p id="fare-checks-subtitle" class="mt-1 text-sm text-muted">
            Check zones and fare rules before you publish{if @version_name, do: " #{@version_name}"}.
          </p>
        </div>

        <dl
          id="fare-checks-counts"
          class="grid grid-cols-2 gap-x-4 gap-y-5 border-b border-subtle px-4 py-5 sm:grid-cols-4 sm:px-5"
        >
          <.check_count
            id="fare-checks-count-repair"
            label="Needs repair"
            value={length(@stopless)}
            tone="text-error-fg"
          />
          <.check_count
            id="fare-checks-count-review"
            label="To review"
            value={length(@combined_fares) + if(@unassigned > 0, do: 1, else: 0)}
            tone="text-warning-fg"
          />
          <.check_count
            id="fare-checks-count-note"
            label="Notes"
            value={if @empty_declared != [], do: 1, else: 0}
            tone="text-strong"
          />
          <.check_count
            id="fare-checks-count-passed"
            label="Checks passed"
            value={length(@passed)}
            tone="text-success-fg"
          />
        </dl>

        <div :if={@clean?} class="border-b border-subtle px-4 py-5 last:border-b-0 sm:px-5">
          <.message id="fare-check-clean" kind="success" title="No problems found">
            Every zone used by a fare rule has stops, and every stop has a fare zone.
            <:action>
              <.button
                id="fare-check-clean-export"
                variant="secondary"
                class="min-h-11"
                navigate={@export_path}
              >
                Export this version
              </.button>
            </:action>
          </.message>
        </div>

        <.check_row
          :for={{zone, index} <- Enum.with_index(@stopless)}
          id={"fare-check-stopless-#{index}"}
          tone={:error}
          label="Needs repair"
          title={stopless_zone_copy(zone)}
          body="Trip planners can’t match any stop to this zone, so the fares that use it never apply. Assign stops to the zone or change the rules that use it."
        >
          <%!-- The name is what the team recognizes. A declared zone's ID is the
          detail that travels with the feed, so it is stated beside the name; an
          undeclared zone is named by its ID already. --%>
          <p
            :if={zone.name != zone.zone_id}
            id={"fare-check-stopless-#{index}-zone-id"}
            class="basis-full text-[13px] text-muted"
          >
            Zone ID <span class="font-mono">{zone.zone_id}</span>
          </p>
          <.check_link
            id={"fare-check-stopless-#{index}-link"}
            patch={zones_patch(@patch_base, zone: zone.zone_id)}
          >
            Show {zone.name}
          </.check_link>
        </.check_row>

        <.check_row
          :if={@unassigned > 0}
          id="fare-check-unassigned"
          tone={:warning}
          label="Review"
          title={unassigned_stops_copy(@unassigned)}
          body="Journeys that use these stops won’t get a zone-based fare. That’s fine for stops on a route with its own fare."
        >
          <.check_link
            id="fare-check-unassigned-link"
            patch={zones_patch(@patch_base, filter: "unassigned")}
          >
            Review stops with no zone
          </.check_link>
        </.check_row>

        <.check_row
          :for={{fare, index} <- Enum.with_index(@combined_fares)}
          id={"fare-check-combine-#{index}"}
          tone={:warning}
          label="Review"
          title={combined_fare_title(fare)}
          body={combined_fare_detail(fare)}
        />

        <.check_row
          :if={@empty_declared != []}
          id="fare-check-empty"
          tone={:neutral}
          label="Note"
          title={empty_zones_copy(@empty_declared)}
          body="Empty zones stay in this workspace. Your feed records zones on stops, so a zone with no stops isn’t exported."
        >
          <.check_link
            :for={{zone, index} <- Enum.with_index(@empty_declared)}
            id={"fare-check-empty-#{index}-link"}
            patch={zones_patch(@patch_base, zone: zone.zone_id)}
          >
            Show {zone.name}
          </.check_link>
        </.check_row>

        <.check_row
          :if={@checks.rules_reference_zones?}
          id="fare-check-source"
          tone={:info}
          label="Source check"
          title="Compare zone assignments with your source feed"
          body="If this version was imported before stop zone IDs were kept, some stops may have lost their zones. Fare rules alone can’t show which stops belonged to which zone."
        >
          <details id="fare-check-source-detail" class="mt-1">
            <summary class="flex min-h-11 cursor-pointer items-center text-sm font-[650] text-action hover:underline">
              What to compare
            </summary>
            <p class="max-w-[70ch] pb-2 text-sm text-default">
              Check that each stop has the same zone as in your original feed. Importing the original feed again creates a new version that keeps its stop zones.
            </p>
          </details>
        </.check_row>

        <details :if={@passed != []} id="fare-checks-passed" class="px-4 sm:px-5">
          <summary
            id="fare-checks-passed-summary"
            class="flex min-h-12 cursor-pointer items-center text-sm font-[650] text-strong hover:underline"
          >
            {checks_passed_copy(length(@passed))}
          </summary>
          <ul class="grid gap-1.5 pb-4 text-sm">
            <li :for={line <- @passed} class="flex items-start gap-2 text-default">
              <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success-fg" />
              {line}
            </li>
          </ul>
        </details>
      </section>
    </div>
    """
  end

  # One of the four counts above the rows.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp check_count(assigns) do
    ~H"""
    <div id={@id}>
      <dt class="text-[13px] font-[650] text-default">{@label}</dt>
      <dd>
        <p class={[
          "font-display text-[34px] font-semibold leading-none tracking-[-0.035em] tabular-nums",
          if(@value > 0, do: @tone, else: "text-strong")
        ]}>
          {@value}
        </p>
      </dd>
    </div>
    """
  end

  @check_tones %{
    error: {"bg-error-bg text-error-fg", "hero-exclamation-triangle"},
    warning: {"bg-warning-bg text-warning-fg", "hero-exclamation-triangle"},
    info: {"bg-info-bg text-info-fg", "hero-information-circle"},
    neutral: {"bg-canvas text-muted", "hero-information-circle"}
  }

  # One check row: the badge on the left, the row's own words and its links on the
  # right. The badge's word is passed in rather than derived from a tone, because
  # the row's vocabulary is what the tab says, and its icon carries the meaning
  # when color cannot. The row stacks below `sm` so a narrow viewport reads it top
  # to bottom.
  attr :id, :string, required: true
  attr :tone, :atom, values: [:error, :warning, :info, :neutral], required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, default: nil
  slot :inner_block

  defp check_row(assigns) do
    {tone_class, icon_name} = Map.fetch!(@check_tones, assigns.tone)
    assigns = assigns |> assign(:tone_class, tone_class) |> assign(:icon_name, icon_name)

    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-2 border-b border-subtle px-4 py-5 last:border-b-0 sm:flex-row sm:gap-5 sm:px-5"
    >
      <div class="sm:w-36 sm:shrink-0">
        <span class={[
          "inline-flex items-center gap-1.5 rounded-badge px-2 py-0.5 text-[13px] font-[650]",
          @tone_class
        ]}>
          <.icon name={@icon_name} class="size-3.5" /> {@label}
        </span>
      </div>
      <div class="min-w-0 flex-1">
        <h3 class="text-base font-bold text-strong">{@title}</h3>
        <p :if={@body} class="mt-1 max-w-[70ch] text-sm text-default">{@body}</p>
        <div :if={@inner_block != []} class="mt-1 flex flex-wrap gap-x-5">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # A row's link to where the finding is fixed: the action colour, an arrow and a
  # 44 px target.
  attr :id, :string, required: true
  attr :patch, :string, required: true
  slot :inner_block, required: true

  defp check_link(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      class="inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action no-underline hover:text-action-hover hover:underline"
    >
      {render_slot(@inner_block)} <.icon name="hero-arrow-right" class="size-4" />
    </.link>
    """
  end

  @doc """
  Renders the rule drawer: the plain-language summary, the journey and fare
  sections and the destructive exit.

  The form is `FareZones.change_rule_group/2`'s changeset for the reviewed group
  (or nil for a new rule), so it validates what the write will validate and an
  untouched field is not a change. Each select offers this version's own catalog:
  fares with the price their row holds, zones as "Name · ID" with "· no stops"
  when the zone has no boardable stop, and routes with their names. An existing
  rule whose fare or route has no row keeps that value as its own option, so an
  imported rule stays editable without inventing a fare the version does not
  carry.

  The summary is read from the form's current values, so it states what the
  fields say now; a rejected save keeps the chosen values and its field errors
  beside the fields they belong to, and neither a stale rule nor a failed save
  closes the drawer.

  Trip planners combine every rule of one fare, so `combined_fare` carries a
  warning callout when the fare's rules, with this rule as the form has it, do not
  share one route or one through-zone set. The callout explains and never blocks
  the save.

  ## Examples

      <.rule_drawer
        open={@rule_drawer_open}
        reviewed={@reviewed_rule}
        form={@rule_form}
        fares={@fares}
        routes={@rule_routes}
        zones={@inventory.zones}
        version_name={@current_gtfs_version.name}
      />
  """
  attr :open, :boolean, default: false
  attr :reviewed, :map, default: nil, doc: "the group being edited, or nil to create"
  attr :form, :any, required: true, doc: "`FareZones.change_rule_group/2`'s form"
  attr :fares, :list, required: true, doc: "`FareZones.list_fares/2`"
  attr :routes, :list, required: true, doc: "`FareZones.list_rule_routes/2`"
  attr :zones, :list, required: true, doc: "the inventory's zones"

  attr :combined_fare, :map,
    default: nil,
    doc: "the rule's fare when trip planners would combine its rules differently, or nil"

  attr :version_name, :string, default: nil, doc: "the version the rule belongs to"
  attr :error, :string, default: nil, doc: "a drawer-level reason the save did not happen"

  attr :stale, :boolean,
    default: false,
    doc: "the reviewed rule changed under the drawer, so the save was refused"

  attr :return_focus_id, :string, default: nil

  def rule_drawer(assigns) do
    zone_lookup = Map.new(assigns.zones, &{&1.zone_id, &1})

    assigns =
      assigns
      |> assign(:editing?, not is_nil(assigns.reviewed))
      |> assign(
        :title,
        if(assigns.reviewed, do: "Edit fare rule", else: "Add fare rule")
      )
      |> assign(:zone_lookup, zone_lookup)
      |> assign(:shared_fare_note, @shared_fare_note)
      |> assign(:fare_options, fare_options(assigns.fares, assigns.reviewed))
      |> assign(:zone_options, zone_options(assigns.zones))
      |> assign(:contains_options, contains_options(assigns.zones))
      |> assign(:route_options, route_options(assigns.routes, assigns.reviewed))
      |> assign(:contains_name, assigns.form[:contains].name <> "[]")
      |> assign(:fare_errors, fare_errors(assigns.form))
      |> assign(
        :contains_errors,
        if(Phoenix.Component.used_input?(assigns.form[:contains]),
          do: Enum.map(assigns.form[:contains].errors, &translate_error/1),
          else: []
        )
      )
      |> assign(
        :summary,
        rule_summary(assigns.form, zone_lookup, assigns.fares, assigns.routes, assigns.reviewed)
      )

    ~H"""
    <.drawer
      id="fare-rule-drawer"
      chrome="planner"
      open={@open}
      on_close="close_rule_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[520px]"
    >
      <:lede :if={@version_name}>{@version_name}</:lede>

      <div
        id="fare-rule-drawer-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id="fare-rule-form"
          as={:rule}
          novalidate
          phx-change="validate_rule"
          phx-submit="save_rule"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.message
              :if={@stale}
              id="fare-rule-stale"
              kind="warning"
              title="This rule changed since you opened it."
              tabindex="-1"
              phx-mounted={JS.focus()}
            >
              Reload the rule to keep editing what it says now. Nothing was saved.
              <:action>
                <.button
                  id="fare-rule-reload"
                  type="button"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="reload_rule"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Reload rule
                </.button>
              </:action>
            </.message>

            <.message
              :if={@error}
              id="fare-rule-drawer-error"
              kind="error"
              title={@error}
              tabindex="-1"
              phx-mounted={JS.focus()}
            />

            <div class="rounded-card bg-canvas px-4 py-3.5">
              <p class="text-[13px] font-[650] text-default">What this rule does</p>
              <p id="fare-rule-summary" class="mt-1 text-[15px] text-strong" aria-live="polite">
                {@summary}
              </p>
            </div>

            <.form_section title="Which journeys" first?={true}>
              <div class="grid gap-4 sm:grid-cols-2">
                <.input
                  id="fare-rule-origin"
                  field={@form[:origin_id]}
                  type="select"
                  label="Journey starts in"
                  options={@zone_options}
                  prompt="Any zone"
                />

                <.input
                  id="fare-rule-destination"
                  field={@form[:destination_id]}
                  type="select"
                  label="Journey ends in"
                  options={@zone_options}
                  prompt="Any zone"
                />
              </div>

              <.input
                id="fare-rule-route"
                field={@form[:route_id]}
                type="select"
                label="On route"
                options={@route_options}
                prompt="All routes"
              />

              <%!-- A checkbox row per zone, named by its own position rather than by a
              zone ID (CR-7). The hidden empty value keeps `contains` in the form
              even when every box is unchecked, so clearing the through zones is a
              change the form can see. --%>
              <fieldset
                id="fare-rule-contains"
                aria-invalid={to_string(@contains_errors != [])}
                class="min-w-0"
              >
                <legend class="text-[13px] font-[650] text-default">
                  Zones the journey touches <span class="font-normal text-muted">(optional)</span>
                </legend>
                <p id="fare-rule-contains-help" class="text-[13px] text-muted">
                  Tick every zone the journey touches, including where it starts and ends. Trip planners match only journeys that touch exactly these zones. Leave all unchecked for no zone requirement.
                </p>
                <input type="hidden" name={@contains_name} value="" />
                <div class="mt-1 flex flex-wrap gap-x-5">
                  <label
                    :for={option <- @contains_options}
                    class="flex min-h-11 cursor-pointer items-center gap-2 text-sm has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
                  >
                    <input
                      type="checkbox"
                      id={option.id}
                      name={@contains_name}
                      value={option.zone_id}
                      checked={option.zone_id in @form[:contains].value}
                      class="size-[18px] accent-action"
                    />
                    {option.name}
                    <span :if={option.stopless?} class="text-muted">· no stops</span>
                  </label>
                </div>
                <p :if={@zones == []} class="py-2 text-sm text-muted">No zones yet.</p>
                <p
                  :if={@contains_errors != []}
                  id="fare-rule-contains-error"
                  class="mt-1.5 flex flex-col gap-1 text-[13px] font-semibold text-error-fg"
                >
                  <span :for={message <- @contains_errors}>{message}</span>
                </p>
              </fieldset>
            </.form_section>

            <.form_section title="Which fare">
              <.input
                id="fare-rule-fare"
                field={@form[:fare_id]}
                type="select"
                label="Charge this fare"
                options={@fare_options}
                prompt={if summary_value(@form[:fare_id].value), do: nil, else: "Choose a fare"}
                errors={@fare_errors}
                help="Prices come from this version’s fare list."
              />
            </.form_section>

            <.message
              :if={@combined_fare}
              id="fare-rule-combine-warning"
              kind="warning"
              title={combined_fare_title(@combined_fare)}
            >
              {combined_fare_detail(@combined_fare)}
            </.message>

            <p class="text-[13px] text-muted">
              A rule applies in one direction. To charge the same fare on the return journey, add a second rule with the start and end swapped.
            </p>

            <p id="fare-rule-shared-fare-note" class="text-[13px] text-muted">
              {@shared_fare_note}
            </p>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              :if={@editing?}
              id="fare-rule-remove"
              type="button"
              variant="quiet"
              class="mr-auto min-h-11 px-2 text-error-fg hover:bg-error-bg"
              phx-click="open_remove_rule"
            >
              <.icon name="hero-trash" class="size-4" /> Remove rule…
            </.button>
            <.button
              id="fare-rule-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_rule_drawer"
            >
              Cancel
            </.button>
            <.button id="fare-rule-save" type="submit" class="min-h-11" phx-disable-with="Saving…">
              Save rule
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the confirm dialog that removes one fare rule.

  The dialog names the rule and states what removal does and does not do before
  anything is written: the fare attribute stays, and the rule stops applying to
  its journeys. A refused removal - a rule another editor changed, or a pair that
  is no longer a published version - keeps the dialog open with its reason, and
  the drawer behind it is untouched, so nothing the operator chose is discarded
  (AC-20, AC-26).

  ## Examples

      <.remove_rule_dialog :if={@remove_rule} remove={@remove_rule} zones={@inventory.zones} />
  """
  attr :remove, :map, required: true, doc: "`%{rule: reviewed group, error: reason | nil}`"
  attr :zones, :list, required: true, doc: "the inventory's zones, for the names in the sentence"
  attr :return_focus_id, :string, default: nil

  def remove_rule_dialog(assigns) do
    assigns =
      assign(assigns, :consequence, remove_consequence(assigns.remove.rule, assigns.zones))

    ~H"""
    <.confirm_dialog
      id="fare-rule-remove-dialog"
      chrome="planner"
      open={true}
      title="Remove this fare rule?"
      confirm_label="Remove rule"
      pending_label="Removing…"
      on_confirm="remove_rule"
      on_cancel="cancel_remove_rule"
      cancel_label="Keep rule"
      return_focus_id={@return_focus_id}
      described_by="fare-rule-remove-dialog-body"
    >
      <div id="fare-rule-remove-body" class="grid gap-3">
        <p id="fare-rule-remove-consequence">{@consequence}</p>

        <.message
          :if={@remove.error}
          id="fare-rule-remove-error"
          kind="warning"
          title={@remove.error}
          tabindex="-1"
          phx-mounted={JS.focus()}
        />
      </div>
    </.confirm_dialog>
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
            {stops_copy(@selected_count)} in this review
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
            {stops_copy(@zone.stop_count)} and {fare_rules_copy(@zone.rule_count)} use this zone.
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
    "#{stops_copy(stop_count)} · #{rules_use_copy(rule_count)} this zone"
  end

  defp rules_use_copy(1), do: "1 fare rule uses"
  defp rules_use_copy(count), do: "#{count} fare rules use"

  # The station/entrance disclosure, written for the count it carries: the rest of
  # the workspace counts one of something in the singular too.
  defp station_line(1), do: "Also updates 1 station or entrance with this zone ID."

  defp station_line(count),
    do: "Also updates #{count} stations or entrances with this zone ID."

  # The delete dialog's own copy. A count of one reads as one, the way the
  # workspace's other count lines do.
  defp fare_rules_copy(1), do: "1 fare rule"
  defp fare_rules_copy(count), do: "#{count} fare rules"

  defp delete_station_line(1), do: "Also moves 1 station or entrance with this zone ID."

  defp delete_station_line(count),
    do: "Also moves #{count} stations or entrances with this zone ID."

  defp stale_zone_copy(%{stop_count: stop_count, rule_count: rule_count}) do
    "This zone changed since you opened this dialog. It now has " <>
      "#{stops_copy(stop_count)} and #{fare_rules_copy(rule_count)}."
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

  defp assignment_title(true, count) when count > 0, do: "Remove zone from #{stops_copy(count)}"
  defp assignment_title(true, _count), do: "Remove zone from stops"
  defp assignment_title(false, count) when count > 0, do: "Assign #{stops_copy(count)} to a zone"
  defp assignment_title(false, _count), do: "Assign stops to a zone"

  # The confirm repeats the verb and its object: how many stops will change.
  defp assignment_confirm_label(true, _preview), do: "Remove zone"

  defp assignment_confirm_label(false, %{changed_count: count}) when count > 0,
    do: "Assign #{stops_copy(count)}"

  defp assignment_confirm_label(false, _preview), do: "Assign stops"

  defp stops_copy(1), do: "1 stop"
  defp stops_copy(count), do: "#{count} stops"

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

  # The fare's price as the row's price column reads it, or nil when the rule's
  # fare has no `fare_attributes` row: a rule never shows a price no fare in the
  # version has.
  defp rule_price_text(%{fare: %{price: price, currency_type: currency_type}}),
    do: rule_price(price, currency_type)

  defp rule_price_text(_rule), do: nil

  # Every price an operator reads goes through `Fares.Money.format/2`, so a
  # rule, a drawer and the grid all round the same way and read the same.
  defp rule_price(price, currency_type),
    do: Money.format(price, currency_type)

  # The journey line: which end of the journey the rule restricts. Both ends
  # unrestricted is its own sentence rather than two "Any" halves, and a rule
  # whose ends are the same zone reads as staying within it.
  defp rule_journey_text(rule, zone_lookup) do
    journey_ends_text(rule.origin_id, rule.destination_id, zone_lookup)
  end

  defp journey_ends_text(nil, nil, _zone_lookup), do: "Any journey"

  defp journey_ends_text(zone_id, zone_id, zone_lookup),
    do: "Within " <> rule_zone_name(zone_lookup, zone_id)

  defp journey_ends_text(origin_id, nil, zone_lookup),
    do: "Starting in " <> rule_zone_name(zone_lookup, origin_id)

  defp journey_ends_text(nil, destination_id, zone_lookup),
    do: "Ending in " <> rule_zone_name(zone_lookup, destination_id)

  defp journey_ends_text(origin_id, destination_id, zone_lookup) do
    rule_zone_name(zone_lookup, origin_id) <> " → " <> rule_zone_name(zone_lookup, destination_id)
  end

  defp rule_through_text(%{contains: []}, _zone_lookup), do: nil

  defp rule_through_text(%{contains: contains}, zone_lookup) do
    "Passing through " <>
      (contains |> Enum.map(&rule_zone_name(zone_lookup, &1)) |> natural_join())
  end

  # The route's own text. A route with neither name falls back to its ID, so the
  # text never states an empty route.
  defp rule_route_text(%{route: nil, route_id: nil}), do: "All routes"
  defp rule_route_text(%{route: nil, route_id: route_id}), do: "Unknown route #{route_id}"

  defp rule_route_text(%{route: route, route_id: route_id}) do
    case Enum.reject([route.short_name, route.long_name], &(&1 in [nil, ""])) do
      [] -> route_id
      names -> Enum.join(names, " · ")
    end
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  # The name of the first zone the rule references that has no boardable stops:
  # the rule keeps the reference, so the row says which one instead of hiding it.
  # Every referenced zone is in the inventory, which reads its IDs from the rules
  # themselves.
  defp rule_stopless_zone(rule, zone_lookup) do
    rule
    |> rule_referenced_zones()
    |> Enum.find_value(fn zone_id ->
      case Map.get(zone_lookup, zone_id) do
        %{stop_count: 0} -> rule_zone_name(zone_lookup, zone_id)
        _zone -> nil
      end
    end)
  end

  defp rule_referenced_zones(rule) do
    Enum.reject([rule.origin_id, rule.destination_id], &is_nil/1) ++ rule.contains
  end

  # An undeclared zone is named by its exact stored ID, so a name is never
  # trimmed, re-cased or invented here.
  defp rule_zone_name(zone_lookup, zone_id) do
    case Map.get(zone_lookup, zone_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _zone -> zone_id
    end
  end

  # The drawer's fare options: this version's fares with their own prices, and
  # an edited rule's unknown fare as its own option so the rule stays editable
  # without inventing a fare the version does not carry.
  defp fare_options(fares, reviewed) do
    options = Enum.map(fares, &{fare_option_label(&1), &1.fare_id})

    case unknown_value(reviewed, :fare_id, fares, & &1.fare_id) do
      nil -> options
      fare_id -> [{"Unknown fare #{fare_id}", fare_id} | options]
    end
  end

  defp fare_option_label(%{} = fare) do
    fare.fare_id <> " · " <> rule_price(fare.price, fare.currency_type)
  end

  # The fare select's errors. A fare that was never chosen says so in words the
  # operator can act on, instead of the changeset's generic "can't be blank".
  defp fare_errors(form) do
    if Phoenix.Component.used_input?(form[:fare_id]) do
      Enum.map(form[:fare_id].errors, fn
        {"can't be blank", _opts} -> "Choose a fare."
        error -> translate_error(error)
      end)
    else
      []
    end
  end

  # The drawer's zone options, in the inventory's own byte order: "Name · ID",
  # with "· no stops" on a zone that has no boardable stop, which is the
  # reference a save refuses to add and an imported rule may already keep.
  defp zone_options(zones), do: Enum.map(zones, &{zone_option_label(&1), &1.zone_id})

  # The through-zone checkbox rows, named by their own position in the
  # inventory's byte order rather than by a zone ID (CR-7).
  defp contains_options(zones) do
    zones
    |> Enum.with_index()
    |> Enum.map(fn {zone, index} ->
      %{
        id: "fare-rule-contains-#{index}",
        zone_id: zone.zone_id,
        name: zone_display_name(%{zone.zone_id => zone}, zone.zone_id),
        stopless?: zone.stop_count == 0
      }
    end)
  end

  defp zone_option_label(%{stop_count: 0} = zone), do: zone_option_text(zone) <> " · no stops"
  defp zone_option_label(zone), do: zone_option_text(zone)

  defp zone_option_text(%{zone_id: zone_id, name: name}) when is_binary(name) and name != "",
    do: "#{name} · #{zone_id}"

  defp zone_option_text(%{zone_id: zone_id}), do: zone_id

  # The drawer's route options: "All routes" is the select's empty value, and an
  # edited rule's unknown route keeps its own option for the same reason a fare
  # does.
  defp route_options(routes, reviewed) do
    options =
      Enum.map(routes, &{rule_route_text(%{route: &1, route_id: &1.route_id}), &1.route_id})

    case unknown_value(reviewed, :route_id, routes, & &1.route_id) do
      nil -> options
      route_id -> [{"Unknown route #{route_id}", route_id} | options]
    end
  end

  # The value an edited rule already carries that the version's catalog does not,
  # or nil when the value is absent or the catalog carries it.
  defp unknown_value(reviewed, field, catalog, key_fun) do
    value = reviewed && Map.get(reviewed, field)

    if is_binary(value) and not Enum.any?(catalog, &(key_fun.(&1) == value)) do
      value
    end
  end

  # The plain-language summary, read from the form's current values rather than
  # from a saved rule, so it follows a change that validation has not seen yet.
  # A select's empty value and an unchecked checkbox row arrive as empty strings
  # (`[""]` for the through zones), which is "any" and "no through zones" here,
  # so they are normalized before the sentence is built.
  defp rule_summary(form, zone_lookup, fares, routes, reviewed) do
    "Riders pay " <>
      fare_summary(summary_value(form[:fare_id].value), fares, reviewed) <>
      " for " <>
      trip_phrase(
        summary_value(form[:origin_id].value),
        summary_value(form[:destination_id].value),
        zone_lookup
      ) <>
      " on " <>
      route_summary(summary_value(form[:route_id].value), routes, reviewed) <>
      rule_summary_visits(summary_contains(form[:contains].value), zone_lookup) <>
      "."
  end

  defp summary_value(value) when value in [nil, ""], do: nil
  defp summary_value(value), do: value

  defp summary_contains(values) when is_list(values), do: Enum.reject(values, &(&1 in [nil, ""]))
  defp summary_contains(_values), do: []

  # The journey as a phrase inside a sentence: "any journey", "journeys within
  # X", "journeys from X to Y", "journeys starting in X" or "journeys ending in Y".
  defp trip_phrase(nil, nil, _zone_lookup), do: "any journey"

  defp trip_phrase(origin_id, destination_id, zone_lookup) when origin_id == destination_id,
    do: "journeys within " <> rule_zone_name(zone_lookup, origin_id)

  defp trip_phrase(origin_id, nil, zone_lookup),
    do: "journeys starting in " <> rule_zone_name(zone_lookup, origin_id)

  defp trip_phrase(nil, destination_id, zone_lookup),
    do: "journeys ending in " <> rule_zone_name(zone_lookup, destination_id)

  defp trip_phrase(origin_id, destination_id, zone_lookup) do
    "journeys from " <>
      rule_zone_name(zone_lookup, origin_id) <>
      " to " <> rule_zone_name(zone_lookup, destination_id)
  end

  # The fare reads as its ID and the price its row holds, so the summary and the
  # rules table never describe the same fare two ways.
  defp fare_summary(nil, _fares, _reviewed), do: "the selected fare"

  defp fare_summary(fare_id, fares, reviewed) do
    case Enum.find(fares, &(&1.fare_id == fare_id)) do
      nil ->
        if(reviewed_value(reviewed, :fare_id) == fare_id,
          do: "Unknown fare #{fare_id}",
          else: fare_id
        )

      fare ->
        "#{fare.fare_id} (#{rule_price(fare.price, fare.currency_type)})"
    end
  end

  defp route_summary(nil, _routes, _reviewed), do: "any route"

  defp route_summary(route_id, routes, reviewed) do
    case Enum.find(routes, &(&1.route_id == route_id)) do
      nil ->
        if(reviewed_value(reviewed, :route_id) == route_id,
          do: "route #{route_id}",
          else: route_id
        )

      route ->
        "route " <> rule_route_text(%{route: route, route_id: route.route_id})
    end
  end

  # What removing a rule stops: its fare, the journeys it covered and the route it
  # was limited to, then the one thing that stays.
  defp remove_consequence(rule, zones) do
    zone_lookup = Map.new(zones, &{&1.zone_id, &1})

    route =
      case rule.route_id do
        nil -> ""
        _route_id -> " on route " <> rule_route_text(rule)
      end

    "#{rule.fare_id} will no longer apply to " <>
      trip_phrase(present(rule.origin_id), present(rule.destination_id), zone_lookup) <>
      rule_summary_visits(rule.contains, zone_lookup) <>
      route <> ". The fare stays in this version’s fare list."
  end

  # The Checks tab's own words. The count carries its own phrase, so "1 empty
  # zone" never reads "1 empty zones".
  defp stopless_zone_copy(%{name: name}), do: "Fare rules use #{name}, which has no stops"

  defp unassigned_stops_copy(1), do: "1 stop has no fare zone"
  defp unassigned_stops_copy(count), do: "#{count} stops have no fare zone"

  defp empty_zones_copy([%{name: name}]), do: "1 empty zone: #{name}"

  defp empty_zones_copy(zones) do
    "#{length(zones)} empty zones: " <> natural_join(Enum.map(zones, & &1.name))
  end

  defp checks_passed_copy(1), do: "1 check passed"
  defp checks_passed_copy(count), do: "#{count} checks passed"

  defp fares_copy(1), do: "1 fare"
  defp fares_copy(count), do: "#{count} fares"

  defp rules_copy_count(1), do: "1 fare rule"
  defp rules_copy_count(count), do: "#{count} fare rules"

  defp combined_fare_title(%{fare_id: fare_id}) do
    "Rules for fare #{fare_id} combine in trip planners"
  end

  # Only the conditions the fare's rules actually disagree on are named, so the
  # detail says what the trip planner will apply to every rule of the fare.
  defp combined_fare_detail(fare) do
    Enum.join(
      ["Trip planners read all rules of one fare together."] ++
        combined_routes_sentence(fare) ++ combined_zones_sentence(fare),
      " "
    )
  end

  defp combined_routes_sentence(%{routes_differ?: false}), do: []

  defp combined_routes_sentence(%{route_ids: route_ids}) do
    case Enum.reject(route_ids, &is_nil/1) do
      [route_id] ->
        [
          "This fare names route #{route_id} on some rules, so every rule of the fare applies only on that route."
        ]

      route_ids ->
        [
          "This fare names routes #{Enum.join(route_ids, ", ")} on some rules, so every rule of the fare applies only on those routes."
        ]
    end
  end

  defp combined_zones_sentence(%{contains_differ?: false}), do: []

  defp combined_zones_sentence(%{contains: [zone_id]}) do
    [
      "This fare lists pass-through zone #{zone_id} across its rules, so every rule of the fare requires a journey that touches exactly that zone."
    ]
  end

  defp combined_zones_sentence(%{contains: zone_ids}) do
    [
      "This fare lists pass-through zones #{Enum.join(zone_ids, ", ")} across its rules, so every rule of the fare requires a journey that touches exactly those zones."
    ]
  end

  defp rule_summary_visits([], _zone_lookup), do: ""

  defp rule_summary_visits(contains, zone_lookup) do
    ", passing through " <>
      (contains |> Enum.map(&rule_zone_name(zone_lookup, &1)) |> natural_join())
  end

  defp natural_join([one]), do: one
  defp natural_join([one, two]), do: "#{one} and #{two}"

  defp natural_join(names) do
    [last | rest] = Enum.reverse(names)
    Enum.join(Enum.reverse(rest), ", ") <> " and " <> last
  end

  defp reviewed_value(nil, _field), do: nil
  defp reviewed_value(reviewed, field), do: Map.get(reviewed, field)
end
