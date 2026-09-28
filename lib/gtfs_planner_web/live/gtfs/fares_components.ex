defmodule GtfsPlannerWeb.Gtfs.FaresComponents do
  @moduledoc """
  Function components for the Fare zones workspace.

  This module owns the workspace's non-ideal states: the first-paint skeleton
  the disconnected render shows, and the load-error callout that names what
  failed and offers the one recovery action. The skeleton mirrors the workspace
  body rather than replacing content already on screen, and the error copy states
  that saved zones are unchanged, so a failed read is never mistaken for lost
  work.

  The Zones tab's inventory panel and stage header live here too. The inventory
  is the page's only navigation: every zone in the version is one patch link
  that carries its filter in the URL, so a zone survives a reload, a tab change
  and a copied link. Zone identity is byte-exact, so a link's query is built
  with `URI.encode_query/1` and no DOM ID ever carries a zone ID.

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
