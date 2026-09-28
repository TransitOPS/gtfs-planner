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
  selection stays readable and clearable while a long list scrolls.

  The Fare rules and Checks bodies are added beside these components by the
  following steps.
  """

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
  current filter cannot show, and the action that clears the selection.

  Nothing selected renders the reference's hint in the stage's footer instead of
  the bar. Both counts are the server's own: the size of the selection, and the
  size of the selection the current filter and search do not match. The action
  row holds Clear; the assignment actions join it in step 19.

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
end
