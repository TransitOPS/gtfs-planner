defmodule GtfsPlannerWeb.Gtfs.FaresComponents do
  @moduledoc """
  Function components for the Fare zones workspace.

  This module owns the workspace's non-ideal states: the first-paint skeleton
  the disconnected render shows, and the load-error callout that names what
  failed and offers the one recovery action. The skeleton mirrors the workspace
  body rather than replacing content already on screen, and the error copy states
  that saved zones are unchanged, so a failed read is never mistaken for lost
  work.

  The Zones tab's inventory panel, stage header and stop list live here too. The
  inventory is the page's only navigation: every zone in the version is one patch
  link that carries its filter in the URL, so a zone survives a reload, a tab
  change and a copied link. Zone identity is byte-exact, so a link's query is
  built with `URI.encode_query/1` and no DOM ID ever carries a zone ID.

  The stop list renders one page of `FareZones.list_stops/3` as a `:stops`
  stream, so the rows arrive as data and the table's own structure stays fixed
  while a search or a page change replaces its contents. Its first column is the
  row's selection checkbox, and the head's two actions select the page or every
  stop the filter and search match. The search field is handled on change and on
  submit alike: pressing Enter must not hand the form to the browser, because a
  native GET would replace the whole query string and drop the filter the
  operator is reading.

  The selection bar states what the server currently holds selected and how much
  of it the current filter cannot show, and it is the stage's sticky footer, so a
  selection stays readable and clearable while a long list scrolls. Its actions
  open the assignment review, which is where a selection becomes a write.

  The zone drawer creates and edits zone metadata. It reuses the shared
  `drawer/1` with `<.input>` fields, validates on change so a field error appears
  beside the field it belongs to, and puts the `FormErrorFocus` hook on its
  content so a failed submit moves focus to the first invalid field. Nothing
  about a failed submit, a duplicate ID or a zone another editor removed closes
  the drawer or discards what the operator typed: it stays open with the reason.
  An edit also states what the zone already carries, because changing its ID
  rewrites exactly the stop and fare-rule references the counts name.

  Reviewed bulk assignment is the dialog and the callout that follows it. The
  dialog states what a save will change before anything is written and lists the
  reviewed rows; it never closes itself, so a stale review, a target zone another
  editor removed and a save that failed all leave the operator's review in place.
  The callout reports what a completed save did and offers Undo, which is the
  domain's own restore of the exact previous zone bytes.

  The Fare rules and Checks bodies are added beside these components by the
  following steps.
  """

  # The review lists at most this many rows; AC-25 asks for the first 100 and a
  # count of the rest.
  @review_row_limit 100

  use GtfsPlannerWeb, :html

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
    <.skeleton
      id="fare-zones-loading"
      rows={4}
      label="Loading fare zones…"
      role="status"
      aria-busy="true"
      class={["py-6", @class]}
      {@rest}
    />
    """
  end

  @doc """
  Renders the Zones tab's "Your zones" inventory and its filters.

  One row per filter: All stops, every zone in the version (declared metadata or
  the exact stored ID), and Unassigned. The row shows the zone's ID in its color
  next to the zone name, and the count is boardable stops only. Rows are patch
  links, so the filter lives in the URL; the current one carries `aria-current`
  and a left border in addition to its tint.

  Below `md` the rows form a horizontal strip that scrolls inside its own
  container, so the narrow layout never overflows the page.

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
    <aside id="fare-zone-inventory" class="md:border-r md:border-base-300">
      <div class="hidden items-center justify-between gap-3 border-b border-base-300 px-4 py-4 md:flex">
        <h3 class="text-base font-semibold">Your zones</h3>
        <.status_badge
          id="fare-zone-inventory-count"
          status={:default}
          label={Integer.to_string(length(@inventory.zones))}
        />
      </div>

      <nav
        id="fare-zone-inventory-filters"
        aria-label="Fare zone filters"
        class="flex overflow-x-auto border-b border-base-300 md:block"
      >
        <.link
          :for={row <- @rows}
          id={row.id}
          patch={row.patch}
          aria-current={row.current? && "page"}
          class={inventory_row_class(row.current?)}
        >
          <span class={chip_class(row.color)} style={chip_style(row.color)} aria-hidden="true">
            <span class="truncate">{row.marker}</span>
          </span>
          <span class="min-w-0 flex-1">
            <strong class="block truncate font-semibold">{row.title}</strong>
            <small class="block truncate text-xs text-base-content/70">{row.subtitle}</small>
          </span>
          <span id={"#{row.id}-count"} class="text-sm tabular-nums">{row.count}</span>
        </.link>
      </nav>

      <div class="hidden px-4 py-4 text-sm text-base-content/70 md:block">
        <p>Each stop belongs to one zone.</p>
        <p class="mt-4">Zone names help your team. Zone IDs travel with your GTFS feed.</p>
      </div>
    </aside>
    """
  end

  @doc """
  Renders the stage's header: what the current filter shows and how much of it.

  The optional `actions` slot is where a tab adds its own controls beside the
  title, so the header stays one place instead of one per step.

  ## Examples

      <.stage_header title="All stops" subtitle="27 stops in this version" />
  """
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :actions

  def stage_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3 border-b border-base-300 px-4 py-3">
      <div class="min-w-0">
        <h3 id="fare-zone-stage-title" class="text-base font-semibold">{@title}</h3>
        <p id="fare-zone-stage-subtitle" class="text-sm text-base-content/70">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders the stage's stop list: search, the unlocated count, the rows and the
  empty states.

  The row subtexts name what an operator cannot see from the row alone: a
  platform is assigned separately from its station, and a stop without
  coordinates can still be selected from this list. The unlocated count is the
  filter's own, so it stays meaningful while a search narrows the visible rows.

  Each empty state names what the current filter is missing and offers the one
  action that leaves it, which is All stops without a search.

  ## Examples

      <.stop_list
        stops={@streams.stops}
        stop_page={@stop_page}
        zones={@inventory.zones}
        filter={@filter}
        q={@q}
        patch_base={@zones_path}
      />
  """
  attr :stops, :any, required: true, doc: "the `:stops` stream holding the current page"
  attr :stop_page, :map, required: true, doc: "`FareZones.list_stops/3`'s page map"
  attr :zones, :list, required: true, doc: "the inventory's zones, for names and colors"
  attr :filter, :any, required: true, doc: "`:all`, `:unassigned` or `{:zone, id}`"
  attr :q, :string, default: nil, doc: "the current search term"
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
    <div id="fare-zone-stop-list">
      <form
        id="fare-zone-search-form"
        phx-change="search"
        phx-submit="search"
        class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300 px-4 py-3"
      >
        <div class="w-full max-w-sm">
          <.input
            id="fare-zone-search"
            name="q"
            type="search"
            value={@q}
            label="Search stops"
            placeholder="Search stops by name or ID"
            phx-debounce="300"
          />
        </div>
        <p id="fare-zone-without-location" class="pb-3 text-sm text-base-content/70">
          {@stop_page.without_location_count} without map location
        </p>
      </form>

      <div class="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
        <p id="fare-zone-stop-head" class="text-sm">
          <strong>Stops</strong>
          <span class="text-base-content/70">· {@stop_page.total_count} shown</span>
        </p>
        <div :if={@stop_page.total_count > 0} class="flex flex-wrap items-center gap-2">
          <%!-- The page's own rows, and the whole match the filter and search
          have, so a 100-row page of 150 stops can be selected either way. --%>
          <.button
            id="fare-zone-select-shown"
            type="button"
            variant="quiet"
            size="sm"
            class="min-h-11 text-primary underline-offset-2 hover:underline"
            phx-click="select_page"
          >
            Select {@shown_count} shown
          </.button>
          <.button
            id="fare-zone-select-matching"
            type="button"
            variant="quiet"
            size="sm"
            class="min-h-11 text-primary underline-offset-2 hover:underline"
            phx-click="select_matching"
          >
            Select all {@matching_count} matching
          </.button>
        </div>
      </div>

      <.empty_state
        :if={@stop_page.total_count == 0}
        id="fare-zone-stops-empty"
        title={@empty.title}
        class="m-4"
      >
        {@empty.body}
        <:action :if={@empty.action}>
          <.link
            id="fare-zone-stops-empty-action"
            patch={@patch_base}
            class="btn btn-outline btn-sm min-h-11"
          >
            {@empty.action}
          </.link>
        </:action>
      </.empty_state>

      <.table
        :if={@stop_page.total_count > 0}
        id="fare-zone-stops"
        rows={@stops}
        responsive="stack"
      >
        <:col :let={{_id, stop}} label="Select">
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            checked={MapSet.member?(@selection, stop.id)}
            aria-label={select_label(stop)}
            phx-click="toggle_stop"
            phx-value-id={stop.id}
          />
        </:col>
        <:col :let={{_id, stop}} label="Stop">
          <span class="block font-semibold">{stop.stop_name}</span>
          <span :if={stop.parent_station} class="block text-xs text-base-content/70">
            Platform · assigned separately
          </span>
          <span :if={!stop.located?} class="block text-xs text-base-content/70">
            No map location · list selection available
          </span>
        </:col>
        <:col :let={{_id, stop}} label="Stop ID">
          <span class="font-mono tabular-nums">{stop.stop_id}</span>
        </:col>
        <:col :let={{_id, stop}} label="Fare zone">
          <% zone = Map.get(@zone_lookup, stop.zone_id) %>
          <% color = zone && FareZone.color_hex(zone.color) %>
          <span class="flex items-center gap-2">
            <span class={chip_class(color)} style={chip_style(color)} aria-hidden="true">
              <span class="truncate">{stop.zone_id || "–"}</span>
            </span>
            <span>{stop_zone_name(zone, stop.zone_id)}</span>
          </span>
        </:col>
      </.table>

      <div
        :if={@stop_page.total_count > 0}
        id="fare-zone-stops-pagination"
        class="border-t border-base-300 px-4"
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

  Nothing selected renders the reference's hint in the stage's footer instead of
  the bar. Both counts are the server's own: the size of the selection, and the
  size of the selection the current filter and search do not match. The action
  row holds Clear beside the two assignment actions; Unassign needs only a
  selection, while Assign zone needs a zone to assign to, so it is disabled with
  the reason visible beside the count when the version has none.

  ## Examples

      <.selection_bar selection={@selection} matching_ids={@matching_ids} zones={@inventory.zones} />
  """
  attr :selection, :any, required: true, doc: "the `MapSet` of selected stop UUIDs"

  attr :matching_ids, :any,
    required: true,
    doc: "the stop UUIDs the current filter and search match"

  attr :zones, :list, required: true, doc: "the inventory's zones, the assign targets"

  def selection_bar(assigns) do
    selected_count = MapSet.size(assigns.selection)

    assigns =
      assigns
      |> assign(:selected_count, selected_count)
      |> assign(:empty?, selected_count == 0)
      |> assign(:assignable?, assigns.zones != [])
      |> assign(
        :outside_count,
        MapSet.size(MapSet.difference(assigns.selection, assigns.matching_ids))
      )

    ~H"""
    <div id="fare-zone-selection-bar" class={selection_bar_class(@empty?)}>
      <p :if={@empty?} id="fare-zone-selection-hint" class="text-sm text-base-content/70">
        Select stops to assign or remove a fare zone.
      </p>

      <div :if={!@empty?} class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p id="fare-zone-selection-count" class="font-semibold">
            {selected_count_copy(@selected_count)}
          </p>
          <p :if={@outside_count > 0} id="fare-zone-selection-outside" class="text-xs">
            {@outside_count} outside current filter
          </p>
          <p :if={!@assignable?} id="fare-zone-assign-unavailable" class="text-xs">
            Create a fare zone first.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.button
            id="fare-zone-clear-selection"
            type="button"
            variant="quiet"
            size="sm"
            class="min-h-11 text-neutral-content underline-offset-2 hover:bg-transparent hover:underline"
            phx-click="clear_selection"
          >
            Clear
          </.button>
          <.button
            id="fare-zone-unassign-selection"
            type="button"
            variant="secondary"
            size="sm"
            class="min-h-11"
            phx-click="open_assignment"
            phx-value-mode="unassign"
          >
            Unassign
          </.button>
          <.button
            id="fare-zone-assign-selection"
            type="button"
            variant="primary"
            size="sm"
            class="min-h-11"
            phx-click="open_assignment"
            phx-value-mode="assign"
            disabled={!@assignable?}
          >
            Assign zone
          </.button>
        </div>
      </div>
    </div>
    """
  end

  # The hint is the reference's line under the list. The bar is the stage's
  # sticky footer, so a selection made in a list taller than the viewport stays
  # visible and clearable while the rows scroll past it.
  defp selection_bar_class(true), do: "px-4 py-3"

  defp selection_bar_class(false) do
    "sticky bottom-0 z-10 bg-neutral px-4 py-3 text-neutral-content"
  end

  # The reference writes the count in the plural for every size; a count of one
  # stop is a sentence about a single stop, so it reads singular.
  defp selected_count_copy(1), do: "1 stop selected"
  defp selected_count_copy(count), do: "#{count} stops selected"

  # A stop's zone comes from the same inventory read as the panel beside it, so
  # its name and color are the ones the filter list shows. A zone the inventory
  # does not carry is rendered by its exact stored ID rather than by a made-up
  # name, and Unassigned has no zone to name.
  defp stop_zone_name(_zone, nil), do: "Unassigned"
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
      title: "No unassigned stops",
      body: "Every stop in this version has a fare zone.",
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
  # stops at all. The reference's fallback copy names a zone filter, which cannot
  # be right here, so this state reuses the stop catalog's first-use copy.
  defp empty_state_copy(:all, nil) do
    %{
      title: "No stops yet",
      body: "Stops appear here after you import a GTFS feed.",
      action: nil
    }
  end

  # The filter list in the reference's order: All stops, then every zone sorted
  # by its exact ID, then Unassigned. The counts come from the inventory, so the
  # panel never disagrees with the version's data while a filter is applied.
  defp inventory_rows(inventory, filter, patch_base) do
    all = %{
      id: "fare-zone-row-all",
      current?: filter == :all,
      patch: zones_patch(patch_base, []),
      marker: "⊙",
      color: nil,
      title: "All stops",
      subtitle: "Every zone",
      count: inventory.boardable_count
    }

    zones =
      inventory.zones
      |> Enum.with_index(1)
      |> Enum.map(fn {zone, index} ->
        %{
          id: "fare-zone-row-#{index}",
          current?: filter == {:zone, zone.zone_id},
          patch: zones_patch(patch_base, zone: zone.zone_id),
          marker: zone.zone_id,
          color: FareZone.color_hex(zone.color),
          title: zone.name,
          subtitle: zone_subtitle(zone),
          count: zone.stop_count
        }
      end)

    unassigned = %{
      id: "fare-zone-row-unassigned",
      current?: filter == :unassigned,
      patch: zones_patch(patch_base, filter: "unassigned"),
      marker: "–",
      color: nil,
      title: "Unassigned",
      subtitle: "Needs assignment",
      count: inventory.unassigned_count
    }

    [all] ++ zones ++ [unassigned]
  end

  # `filter=unassigned` stays a separate key from `zone`, so a zone literally
  # named "unassigned" is its own filter. The query is assembled by
  # `URI.encode_query/1`, which escapes spaces and reserved characters.
  defp zones_patch(patch_base, []), do: patch_base
  defp zones_patch(patch_base, query), do: patch_base <> "?" <> URI.encode_query(query)

  defp zone_subtitle(%{zone_id: zone_id, stop_count: 0}), do: "ID #{zone_id} · Empty zone"
  defp zone_subtitle(%{zone_id: zone_id}), do: "ID #{zone_id}"

  defp inventory_row_class(current?) do
    [
      "flex min-h-11 min-w-40 shrink-0 items-center gap-3 border-b border-base-200 border-l-[3px] px-4 py-3",
      "hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2",
      "md:w-full md:min-w-0 md:shrink",
      if(current?, do: "border-l-primary bg-primary/10", else: "border-l-transparent")
    ]
  end

  # A declared zone's chip carries its own color; an implied zone or Unassigned
  # gets the neutral chip. The ID is repeated in the row's subtitle, so the chip
  # itself is decorative and hidden from assistive tech.
  defp chip_class(nil) do
    "inline-grid h-7 min-w-7 max-w-[4.5rem] place-items-center overflow-hidden rounded border border-base-content/30 bg-base-200 px-1 text-xs font-semibold text-base-content/70"
  end

  defp chip_class(_color) do
    "inline-grid h-7 min-w-7 max-w-[4.5rem] place-items-center overflow-hidden rounded border border-current px-1 text-xs font-semibold"
  end

  defp chip_style(nil), do: nil
  defp chip_style(color), do: "color: #{color}; background-color: #{color}1a"

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
    <div id="fare-zones-error" class={["mt-2", @class]} {@rest}>
      <.callout kind="error" title="Fare zones couldn’t load">
        <p>Your saved zones haven’t changed. Try loading this version again.</p>
        <%!-- The callout body renders inline, so the block wrapper is what keeps
        the action below the message instead of on top of it. --%>
        <div class="mt-3">
          <.button id="fare-zones-reload" phx-click="reload" class="min-h-11">
            Reload fare zones
          </.button>
        </div>
      </.callout>
    </div>
    """
  end

  @doc """
  Renders the Zones tab's first-use state, which replaces the workspace while
  the version's inventory carries no zone at all.

  The distinction matters: a filter that matches no stop is an empty list, not a
  first use, so only an inventory with no declared record, no stop zone ID and
  no fare-rule reference renders this. Its single action opens the create
  drawer, and the import line tells an operator whose feed already carried zone
  IDs where they would appear.

  ## Examples

      <.first_use_empty />
  """
  def first_use_empty(assigns) do
    ~H"""
    <div id="fare-zone-first-use" class="mt-2">
      <.empty_state title="Start with your first fare zone">
        <p>
          A zone groups stops that share a fare area. Give it a name, then select its stops on the map or in a list.
        </p>
        <p class="mt-3">Already have a feed? Stop zone IDs from an imported feed appear here.</p>
        <:action>
          <.button
            id="fare-zone-first-use-create"
            variant="primary"
            class="min-h-11"
            phx-click="open_zone_drawer"
            phx-value-opener_id="fare-zone-first-use-create"
          >
            Create first zone
          </.button>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the assignment review: the AC-9 report of what a save would change.

  The dialog is where a selection becomes a write, and it states the whole
  change before it happens: how many assignments change, how they split between
  unassigned stops that gain the target and stops that move from another zone,
  how many selected stops already hold it, and which of their sibling platforms
  the selection does not cover. The reviewed rows follow, named one per line with
  the zone they have now and the zone they would have, so the operator reads the
  exact bytes the save will write.

  It never closes itself. A stale review, a target zone that another editor
  removed and a save that failed all leave the dialog open with its target and
  its rows, because the review is the work that must not be lost; the error or
  stale callout inside the dialog names what happened, and `cancel_assignment`
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
      |> assign(:summary, if(preview, do: assignment_summary(assignment), else: nil))
      |> assign(:reason, confirm_reason(assignment))
      |> assign(:confirm_disabled, not confirmable?(assignment))

    ~H"""
    <.confirm_dialog
      id="fare-zone-assignment-dialog"
      open={true}
      title={if @remove?, do: "Remove zone assignments", else: "Assign selected stops"}
      confirm_label={if @remove?, do: "Remove assignments", else: "Save assignments"}
      pending_label="Saving…"
      on_confirm="apply_assignment"
      on_cancel="cancel_assignment"
      cancel_label="Keep selection"
      confirm_disabled={@confirm_disabled}
      confirm_variant={if @remove?, do: "danger", else: "primary"}
      return_focus_id={
        if @remove?, do: "fare-zone-unassign-selection", else: "fare-zone-assign-selection"
      }
      described_by="fare-zone-assignment-dialog-body"
      size="lg"
    >
      <%!-- One rhythm for the review's blocks: the wrapper owns the gap between
      them, so the summary, the warnings and the rows never touch. --%>
      <div id="fare-zone-assignment-review" class="space-y-3">
        <p :if={@selected_count > 0} id="fare-zone-assignment-intro">
          {selected_stops_copy(@selected_count)} before saving.
        </p>

        <.callout
          :if={@assignment.error}
          id="fare-zone-assignment-error"
          kind="error"
          title={@assignment.error}
          role="alert"
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

        <.callout
          :if={@summary}
          id="fare-zone-assignment-summary"
          kind="info"
          title={@summary.headline}
        >
          <p id="fare-zone-assignment-summary-change">{@summary.change_line}</p>
          <p id="fare-zone-assignment-summary-unchanged">{@summary.unchanged_line}</p>
        </.callout>

        <.callout
          :if={not @remove? and @summary != nil and @summary.moved?}
          id="fare-zone-assignment-moved"
          kind="warning"
          title="Moving stops can change which fares apply to their journeys."
        >
          <p>Existing fare rules keep their zone references.</p>
        </.callout>

        <.callout
          :if={@summary != nil and @preview.unselected_sibling_count > 0}
          id="fare-zone-assignment-siblings"
          kind="info"
          title={sibling_platforms_copy(@preview.unselected_sibling_count)}
        >
          <p>Each platform is assigned separately; station groups are never changed silently.</p>
        </.callout>

        <div :if={@rows != []} id="fare-zone-assignment-rows">
          <div
            :for={{row, index} <- Enum.with_index(@rows, 1)}
            id={"fare-zone-assignment-row-#{index}"}
            class="flex items-center justify-between gap-3 border-b border-base-200 py-2"
          >
            <span class="text-base-content">{row.stop_name || row.stop_id}</span>
            <span class="shrink-0 text-xs tabular-nums">
              {zone_label(row.from)} → {zone_label(row.to)}
            </span>
          </div>
          <p :if={@more > 0} id="fare-zone-assignment-more" class="py-2 text-xs">
            and {@more} more
          </p>
        </div>

        <%!-- The reference puts the stale notice after the reviewed rows and just
        above the footer, which is also where the disabled confirm button is: the
        operator re-reads what would be written, then sees that it moved. --%>
        <.callout
          :if={@assignment.stale > 0}
          id="fare-zone-assignment-stale"
          kind="warning"
          title={stale_stops_copy(@assignment.stale)}
          role="alert"
          tabindex="-1"
          phx-mounted={JS.focus()}
        >
          <div class="mt-2">
            <.button
              id="fare-zone-assignment-refresh"
              type="button"
              variant="secondary"
              size="sm"
              class="min-h-11"
              phx-click="refresh_assignment"
            >
              Refresh review
            </.button>
          </div>
        </.callout>

        <p :if={@reason} id="fare-zone-assignment-reason">{@reason}</p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders what a completed assignment did, with Undo while it is still offered.

  The message is the count the save applied, so the callout reports the write
  that happened rather than the review that was shown. Undo is present only
  while the socket still holds the applied changes: a second save, a tab change
  and a version switch each replace or drop it, and an undone or superseded
  change reports its outcome without the button.

  ## Examples

      <.saved_callout :if={@undo} undo={@undo} />
  """
  attr :undo, :map, required: true, doc: "the socket's `@undo` state"

  def saved_callout(assigns) do
    ~H"""
    <div id="fare-zone-saved" class="mb-3 mt-3">
      <.callout kind={@undo.kind} title={@undo.message}>
        <div :if={@undo.applied} class="mt-2">
          <.button
            id="fare-zone-undo"
            type="button"
            variant="secondary"
            size="sm"
            class="min-h-11"
            phx-click="undo_assignment"
          >
            Undo
          </.button>
        </div>
      </.callout>
    </div>
    """
  end

  @doc """
  Renders the zone create/edit drawer.

  `entity` is the inventory entry the panel already shows, or nil to create.
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

    ~H"""
    <.drawer
      id="fare-zone-drawer"
      open={@open}
      on_close="close_zone_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
    >
      <div id="fare-zone-drawer-content" phx-hook="FormErrorFocus">
        <p id="fare-zone-drawer-intro" class="mb-4 text-sm text-base-content/70">
          {if @editing?,
            do: "Update the label your team sees, or change the ID carried in your feed.",
            else: "Start with a name people recognize. You can assign stops next."}
        </p>

        <div :if={@error} class="mb-4">
          <.callout
            id="fare-zone-drawer-error"
            kind="error"
            title={@error}
            role="alert"
            tabindex="-1"
            phx-mounted={JS.focus()}
          />
        </div>

        <.form
          for={@form}
          id="fare-zone-form"
          as={:zone}
          novalidate
          phx-change="validate_zone"
          phx-submit="save_zone"
          class="space-y-1"
        >
          <.input
            id="fare-zone-name"
            field={@form[:name]}
            type="text"
            label="Zone name"
            placeholder="e.g. Central"
            phx-debounce="300"
          />

          <.input
            id="fare-zone-id"
            field={@form[:zone_id]}
            type="text"
            label="Zone ID"
            placeholder="e.g. A"
            help="Unique in this version. Use letters, numbers, hyphens or underscores."
            phx-debounce="300"
          />

          <.input
            id="fare-zone-color"
            field={@form[:color]}
            type="select"
            label="Map color"
            options={palette_options()}
            help="Markers also show the zone ID, so color is never the only cue."
          />

          <%!-- An edit names what changing the ID rewrites, because that is the
          difference between this drawer and renaming a display label. A
          drawer-level failure hides it: the inventory was just read again, so
          counts captured when the drawer opened could contradict the reason the
          save cannot happen. A field error keeps it - the save is still the
          operator's to retry. --%>
          <.callout
            :if={@editing? and is_nil(@error)}
            id="fare-zone-drawer-summary"
            kind="info"
            title={edit_summary_title(@entity)}
          >
            <p id="fare-zone-drawer-summary-updates">
              Changing this ID updates these references together.
            </p>
            <p :if={@entity.other_stop_count > 0} id="fare-zone-drawer-summary-others">
              {station_line(@entity.other_stop_count)}
            </p>
          </.callout>

          <.callout
            :if={!@editing?}
            id="fare-zone-drawer-note"
            kind="info"
            title="Your new zone starts empty. It remains available while you build its stop membership."
          />

          <%!-- The destructive exit sits where the reference puts it: inside the
          edit form, under the summary that names what the ID carries. It is a
          text action, not a filled button, so it never reads as the drawer's
          own save. --%>
          <div :if={@editing?} class="pt-2">
            <.button
              id="fare-zone-delete"
              type="button"
              variant="quiet"
              class="min-h-11 text-error"
              phx-click="open_delete_zone"
              phx-value-zone_id={@entity.zone_id}
              phx-value-opener_id={@return_focus_id}
            >
              Delete zone…
            </.button>
          </div>

          <div class="flex flex-wrap items-center gap-3 pt-3">
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">
              {if @editing?, do: "Save zone", else: "Create zone"}
            </.button>
            <.button type="button" variant="quiet" class="min-h-11" phx-click="close_zone_drawer">
              Cancel
            </.button>
          </div>
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
  other inventory zones only; an unreferenced zone with stops says "Move its
  stops to" and offers Unassigned first; an empty zone replaces the select with
  its own sentence and deletes from "Delete empty zone".

  The disabled confirm always says why. A zone fare rules use cannot be deleted
  without a replacement zone, so a version with no other zone keeps the zone and
  the reason on screen rather than offering a button that would write anyway
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
      |> assign(
        :confirm_label,
        if(referenced?, do: "Replace & delete", else: "Delete empty zone")
      )
      |> assign(:confirm_disabled, options == [])
      |> assign(:reason, delete_disabled_reason(zone, options))

    ~H"""
    <.confirm_dialog
      id="fare-zone-delete-dialog"
      open={true}
      title={"Delete #{@zone.name}?"}
      confirm_label={@confirm_label}
      pending_label="Deleting…"
      on_confirm="delete_zone"
      on_cancel="cancel_delete_zone"
      cancel_label="Keep zone"
      confirm_disabled={@confirm_disabled}
      confirm_variant="danger"
      return_focus_id={@return_focus_id}
      described_by="fare-zone-delete-dialog-body"
      size="lg"
    >
      <div id="fare-zone-delete-body" class="space-y-3">
        <p id="fare-zone-delete-consequence">
          {stops_copy(@zone.stop_count)} and {fare_rules_copy(@zone.rule_count)} use this zone.
        </p>

        <p :if={@zone.other_stop_count > 0} id="fare-zone-delete-others">
          {delete_station_line(@zone.other_stop_count)}
        </p>

        <%!-- The reference puts the dialog's own message where the body starts,
        above the select it explains. A refused write keeps the dialog open
        here, so the reason and the control it explains stay together. --%>
        <.callout
          :if={@zone_delete.stale}
          id="fare-zone-delete-stale"
          kind="warning"
          title={stale_zone_copy(@zone_delete.stale)}
          role="alert"
          tabindex="-1"
          phx-mounted={JS.focus()}
        />

        <.callout
          :if={@zone_delete.error}
          id="fare-zone-delete-error"
          kind="error"
          title={@zone_delete.error}
          role="alert"
          tabindex="-1"
          phx-mounted={JS.focus()}
        />

        <form
          :if={@referenced?}
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
          />
        </form>

        <.callout
          :if={@referenced?}
          id="fare-zone-delete-warning"
          kind="warning"
          title={@warning}
        />

        <p :if={not @referenced?} id="fare-zone-delete-empty">
          This empty zone has no references. Deleting it will not change stops or fares.
        </p>

        <p :if={@reason} id="fare-zone-delete-reason">{@reason}</p>
      </div>
    </.confirm_dialog>
    """
  end

  # The edit summary's headline: the reference's counts plus the sentence the
  # card fixes, the counts kept as the callout's own title.
  defp edit_summary_title(%{stop_count: stop_count, rule_count: rule_count}) do
    "#{stops_copy(stop_count)} · #{rules_copy(rule_count)}."
  end

  defp rules_copy(1), do: "1 related fare rule"
  defp rules_copy(count), do: "#{count} related fare rules"

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

  # The replacement select. Unassigned is the unreferenced zone's own choice and
  # comes first when it is offered; a zone fare rules use can only move to
  # another inventory zone, which is what the write will accept.
  defp delete_replacement_options(%{zone_id: zone_id, rule_count: 0}, zones) do
    [{"Unassigned", ""} | target_options(Enum.reject(zones, &(&1.zone_id == zone_id)))]
  end

  defp delete_replacement_options(%{zone_id: zone_id}, zones) do
    target_options(Enum.reject(zones, &(&1.zone_id == zone_id)))
  end

  defp delete_warning(%{rule_count: rule_count}) when rule_count > 0 do
    "Stops and fare rules will move together. This changes which journeys the related fares cover."
  end

  defp delete_warning(_zone), do: "Stops are kept. Only their zone assignment changes."

  # A disabled confirm is never silent. The only state that disables it is a
  # zone fare rules use with no other zone to move them to.
  defp delete_disabled_reason(%{rule_count: rule_count}, []) when rule_count > 0 do
    "Create another zone first. Fare rules need a replacement zone."
  end

  defp delete_disabled_reason(_zone, _options), do: nil

  # The palette's own labels, keyed by the palette key `FareZone` stores.
  defp palette_options do
    Enum.map(FareZone.palette(), fn {key, label, _hex} -> {label, key} end)
  end

  # The select's options: every zone of the version's inventory, labeled by the
  # name people recognize beside the exact ID that travels with the feed.
  defp target_options(zones) do
    Enum.map(zones, &{"#{&1.name} · #{&1.zone_id}", &1.zone_id})
  end

  # The review's own arithmetic, in the reference's order: what changes first,
  # then what does not.
  defp assignment_summary(assignment) do
    preview = assignment.preview

    case assignment.mode do
      :unassign ->
        %{
          headline: "#{assignments_copy(preview.changed_count)} will change",
          change_line: "#{stops_copy(preview.changed_count)} become unassigned",
          unchanged_line: already_copy(:unassign, preview.unchanged_count),
          moved?: false
        }

      :assign ->
        %{
          headline: "#{assignments_copy(preview.changed_count)} will change",
          change_line: "#{added_copy(preview.added_count)} · #{moved_copy(preview.moved_count)}",
          unchanged_line: already_copy(:assign, preview.unchanged_count),
          moved?: preview.moved_count > 0
        }
    end
  end

  defp zone_label(nil), do: "None"
  defp zone_label(zone_id), do: zone_id

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
    do: "Nothing to change: every selected stop is already unassigned."

  defp confirm_reason(_assignment), do: nil

  # A stale review, an unknown target and a lost selection each carry their own
  # visible reason, so they are not also "nothing to change".
  defp confirmable?(%{stale: stale}) when stale > 0, do: false
  defp confirmable?(%{error: error}) when is_binary(error), do: false
  defp confirmable?(%{mode: :assign, target: nil}), do: false
  defp confirmable?(%{preview: %{changed_count: count}}) when count > 0, do: true
  defp confirmable?(_assignment), do: false

  defp selected_stops_copy(1), do: "Review 1 selected stop"
  defp selected_stops_copy(count), do: "Review #{count} selected stops"

  defp assignments_copy(1), do: "1 assignment"
  defp assignments_copy(count), do: "#{count} assignments"

  defp added_copy(1), do: "1 unassigned stop added"
  defp added_copy(count), do: "#{count} unassigned stops added"

  defp moved_copy(1), do: "1 moved from another zone"
  defp moved_copy(count), do: "#{count} moved from another zone"

  defp already_copy(:unassign, 1), do: "1 already unassigned · left unchanged"
  defp already_copy(:unassign, count), do: "#{count} already unassigned · left unchanged"
  defp already_copy(:assign, 1), do: "1 already in this zone · left unchanged"
  defp already_copy(:assign, count), do: "#{count} already in this zone · left unchanged"

  defp stale_stops_copy(1), do: "1 selected stop changed since you opened this review."

  defp stale_stops_copy(count),
    do: "#{count} selected stops changed since you opened this review."

  defp sibling_platforms_copy(1), do: "1 sibling platform is not selected."
  defp sibling_platforms_copy(count), do: "#{count} sibling platforms are not selected."
end
