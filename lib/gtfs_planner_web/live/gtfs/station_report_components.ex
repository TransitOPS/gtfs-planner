defmodule GtfsPlannerWeb.Gtfs.StationReportComponents do
  @moduledoc """
  Function components for the station report dashboard.
  Transforms raw report data into structured, information-dense displays.
  """
  use Phoenix.Component

  alias GtfsPlanner.Gtfs.{Stop, Pathway}

  # ============================================================================
  # Status primitives
  # ============================================================================

  attr :status, :atom, required: true

  defp status_dot(assigns) do
    ~H"""
    <span
      class={[
        "inline-block size-2 rounded-full shrink-0 mt-1.5",
        @status == :pass && "bg-success",
        @status == :fail && "bg-error",
        @status == :warn && "bg-warning",
        @status == :info && "bg-base-content/30"
      ]}
      title={status_label(@status)}
    />
    """
  end

  defp status_label(:pass), do: "Pass"
  defp status_label(:fail), do: "Fail"
  defp status_label(:warn), do: "Warning"
  defp status_label(:info), do: "Info"

  # ============================================================================
  # Summary strip
  # ============================================================================

  attr :report, :map, required: true

  def summary_strip(assigns) do
    assigns = assign(assigns, :stats, summary_stats(assigns.report))

    ~H"""
    <div id="report-summary" class="grid grid-cols-2 md:grid-cols-4 gap-3">
      <div class="relative rounded-lg border border-base-content/20 bg-base-100 px-4 py-3">
        <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Integrity</p>
        <p class={[
          "text-lg font-semibold mt-0.5",
          @stats.integrity.fails > 0 && "text-error",
          @stats.integrity.fails == 0 && "text-success"
        ]}>
          {if @stats.integrity.fails > 0,
            do:
              "#{@stats.integrity.fails} #{if @stats.integrity.fails == 1, do: "issue", else: "issues"}",
            else: "OK"}
        </p>
      </div>

      <div class="rounded-lg border border-base-content/20 bg-base-100 px-4 py-3">
        <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Accessibility</p>
        <p class={[
          "text-lg font-semibold mt-0.5",
          @stats.accessibility.fails > 0 && "text-error",
          (@stats.accessibility.fails == 0 and @stats.accessibility.warns > 0) && "text-warning",
          (@stats.accessibility.fails == 0 and @stats.accessibility.warns == 0) && "text-success"
        ]}>
          <%= cond do %>
            <% @stats.accessibility.fails > 0 -> %>
              {@stats.accessibility.fails} {if @stats.accessibility.fails == 1,
                do: "gap",
                else: "gaps"}
            <% @stats.accessibility.warns > 0 -> %>
              {@stats.accessibility.warns} {if @stats.accessibility.warns == 1,
                do: "warning",
                else: "warnings"}
            <% true -> %>
              OK
          <% end %>
        </p>
      </div>

      <div class="rounded-lg border border-base-content/20 bg-base-100 px-4 py-3">
        <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Inventory</p>
        <p class="text-lg font-semibold mt-0.5 text-base-content">
          {@stats.inventory.nodes} nodes · {@stats.inventory.edges} edges
        </p>
      </div>

      <div class="rounded-lg border border-base-content/20 bg-base-100 px-4 py-3">
        <div class="flex items-center justify-between gap-2">
          <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Completeness</p>
          <details class="group">
            <summary
              id="report-summary-completeness-methodology-toggle"
              class="cursor-pointer list-none text-xs font-medium lowercase text-primary hover:text-primary/80 hover:underline transition-colors"
            >
              methodology
            </summary>
            <div
              id="report-summary-completeness-methodology"
              class="absolute right-4 mt-1 z-10 w-72 rounded-md border border-base-content/15 bg-base-100 p-2 text-xs text-base-content/75 shadow-sm"
            >
              Completeness is the average percent across pathway attribute completeness fields.
              Each field percent is populated pathways ÷ total pathways.
            </div>
          </details>
        </div>
        <p class="text-lg font-semibold mt-0.5 text-base-content">
          {format_percent(@stats.completeness.percent)}%
        </p>
      </div>
    </div>
    """
  end

  defp summary_stats(report) do
    sections = report.sections
    integrity_section = find_section(sections, "data_integrity")
    gps_section = find_section(sections, "gps")
    accessibility_section = find_section(sections, "accessibility")
    inventory_section = find_section(sections, "inventory")
    completeness_section = find_section(sections, "attribute_completeness")

    integrity_items = items_for(integrity_section) ++ items_for(gps_section)
    accessibility_items = items_for(accessibility_section)

    {nodes, edges} = inventory_counts(inventory_section)
    completeness_pct = aggregate_completeness(completeness_section)

    %{
      integrity: %{
        fails: Enum.count(integrity_items, &(&1.status == :fail)),
        total: length(integrity_items)
      },
      accessibility: %{
        fails: Enum.count(accessibility_items, &(&1.status == :fail)),
        warns: Enum.count(accessibility_items, &(&1.status == :warn)),
        total: length(accessibility_items)
      },
      inventory: %{nodes: nodes, edges: edges},
      completeness: %{percent: completeness_pct}
    }
  end

  defp items_for(nil), do: []
  defp items_for(%{items: items}), do: items

  defp inventory_counts(nil), do: {0, 0}

  defp inventory_counts(%{items: items}) do
    nodes =
      case Enum.find(items, &(&1.id == "node_inventory")) do
        %{value: v} when is_map(v) ->
          v |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()

        _ ->
          0
      end

    edges =
      case Enum.find(items, &(&1.id == "edge_inventory")) do
        %{value: v} when is_map(v) ->
          v |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()

        _ ->
          0
      end

    {nodes, edges}
  end

  defp aggregate_completeness(nil), do: 0.0

  defp aggregate_completeness(%{items: items}) do
    case Enum.find(items, &(&1.id == "pathway_attribute_completeness")) do
      %{value: v} when is_map(v) ->
        percents = v |> Map.values() |> Enum.map(& &1.percent)

        if percents == [],
          do: 0.0,
          else: Float.round(Enum.sum(percents) / length(percents), 1)

      _ ->
        0.0
    end
  end

  # ============================================================================
  # Data Integrity + GPS section
  # ============================================================================

  attr :section, :map, required: true
  attr :gps_section, :map, default: nil
  attr :methodology_mode, :boolean, default: false

  def integrity_section(assigns) do
    ~H"""
    <section
      id="report-section-data_integrity"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3 flex items-center justify-between gap-3">
        <h2 class="text-base font-semibold">Data Quality</h2>
        <button
          id="report-section-data_integrity-methodology-toggle"
          type="button"
          phx-click="toggle_methodology"
          phx-value-section_id="data_integrity"
          class="text-xs font-medium lowercase text-primary hover:text-primary/80 hover:underline transition-colors"
        >
          {if @methodology_mode, do: "back", else: "methodology"}
        </button>
      </header>

      <%= if @methodology_mode do %>
        <div id="report-section-data_integrity-methodology" class="px-4 py-4">
          <.methodology_table
            section_id="data_integrity"
            entries={methodology_entries("data_integrity", @section, @gps_section)}
          />
        </div>
      <% else %>
        <div class="divide-y divide-base-content/10">
          <.check_row :for={item <- @section.items} item={item} />

          <div :if={@gps_section} id="report-section-gps" class="px-4 py-4">
            <.gps_item :for={item <- @gps_section.items} item={item} />
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  attr :item, :map, required: true

  defp check_row(assigns) do
    ~H"""
    <div id={"report-item-#{@item.id}"} class="px-4 py-3">
      <div class="flex items-start gap-2">
        <.status_dot status={@item.status} />
        <div class="flex-1 min-w-0">
          <div class="flex items-baseline justify-between gap-3">
            <p class="text-sm font-medium">{@item.label}</p>
            <span class="text-sm font-mono shrink-0 text-base-content/70">
              {format_check_value(@item)}
            </span>
          </div>
          <.stop_id_list
            :if={
              @item.status == :fail and is_list(@item.details) and @item.details != [] and
                @item.id not in ["entrance_to_boarding_connectivity", "boarding_area_interconnection"]
            }
            item={@item}
            ids={@item.details}
          />
          <.connectivity_details
            :if={
              @item.id in ["entrance_to_boarding_connectivity", "boarding_area_interconnection"] and
                is_list(@item.details)
            }
            item={@item}
            details={@item.details}
          />
          <.children_details
            :if={@item.id == "minimum_station_children" and is_map(@item.details)}
            details={@item.details}
          />
        </div>
      </div>
    </div>
    """
  end

  defp format_check_value(%{id: "minimum_station_children", value: value})
       when is_boolean(value) do
    if value, do: "yes", else: "no"
  end

  defp format_check_value(%{value: value}) when is_integer(value), do: Integer.to_string(value)

  defp format_check_value(%{value: value}) when is_map(value) do
    Enum.map_join(value, " · ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp format_check_value(%{value: value}), do: to_string(value)

  attr :item, :map, required: true
  attr :ids, :list, required: true

  defp stop_id_list(assigns) do
    ~H"""
    <div id={"report-item-#{@item.id}-details"} class="mt-2">
      <p class="font-mono text-xs text-base-content/60">
        {Enum.join(@ids, ", ")}
      </p>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :details, :list, required: true

  defp connectivity_details(assigns) do
    ~H"""
    <div :if={@details != []} id={"report-item-#{@item.id}-details"} class="mt-2 space-y-0.5">
      <div :for={detail <- @details} class="flex items-center gap-1.5 text-xs font-mono">
        <span class={[
          "inline-block size-1.5 rounded-full",
          connectivity_ok?(detail) && "bg-success",
          not connectivity_ok?(detail) && "bg-error"
        ]} />
        <span class="text-base-content/70">{connectivity_id(detail)}</span>
      </div>
    </div>
    """
  end

  defp connectivity_ok?(%{reachable: r}), do: r
  defp connectivity_ok?(%{connected: c}), do: c
  defp connectivity_ok?(_), do: false

  defp connectivity_id(%{entrance_stop_id: id}), do: id
  defp connectivity_id(%{boarding_stop_id: id}), do: id
  defp connectivity_id(_), do: ""

  attr :details, :map, required: true

  defp children_details(assigns) do
    ~H"""
    <p class="mt-1 text-xs text-base-content/60">
      {Map.get(@details, :entrances, 0)} entrances · {Map.get(@details, :platforms, 0)} platforms
    </p>
    """
  end

  # GPS sub-item

  attr :item, :map, required: true

  defp gps_item(assigns) do
    assigns = assign(assigns, :rows, gps_rows(assigns.item.value))

    ~H"""
    <div id={"report-item-#{@item.id}"}>
      <div class="flex items-start gap-2 mb-2">
        <.status_dot status={@item.status} />
        <p class="text-sm font-medium">{@item.label}</p>
      </div>
      <table class="w-full text-sm">
        <thead>
          <tr class="text-left text-xs text-base-content/60">
            <th class="pb-1 font-medium">Type</th>
            <th class="pb-1 font-medium text-right">Present</th>
            <th class="pb-1 font-medium text-right">Missing</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-t border-base-200">
            <td class="py-1">{row.label}</td>
            <td class="py-1 text-right font-mono">{row.present}</td>
            <td class="py-1 text-right font-mono text-base-content/70">
              {row.missing}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp gps_rows(value) when is_map(value) do
    value
    |> Enum.map(fn {type_str, data} ->
      type_int = String.to_integer(type_str)

      %{
        type: type_int,
        label: Stop.location_type_label(type_int),
        present: data.present,
        missing: data.missing,
        required: data.required
      }
    end)
    |> Enum.sort_by(& &1.type)
  end

  defp gps_rows(_), do: []

  # ============================================================================
  # Accessibility section
  # ============================================================================

  attr :section, :map, required: true
  attr :methodology_mode, :boolean, default: false

  def accessibility_section(assigns) do
    step_free = find_item(assigns.section, "step_free_routes")
    wheelchair = find_item(assigns.section, "wheelchair_boarding_distribution")
    elevator = find_item(assigns.section, "elevator_level_coverage")
    escalator = find_item(assigns.section, "escalator_direction_summary")

    assigns =
      assigns
      |> assign(:step_free, step_free)
      |> assign(:wheelchair, wheelchair)
      |> assign(:elevator, elevator)
      |> assign(:escalator, escalator)

    ~H"""
    <section
      id="report-section-accessibility"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3 flex items-center justify-between gap-3">
        <h2 class="text-base font-semibold">{@section.title}</h2>
        <button
          id="report-section-accessibility-methodology-toggle"
          type="button"
          phx-click="toggle_methodology"
          phx-value-section_id="accessibility"
          class="text-xs font-medium lowercase text-primary hover:text-primary/80 hover:underline transition-colors"
        >
          {if @methodology_mode, do: "back", else: "methodology"}
        </button>
      </header>

      <%= if @methodology_mode do %>
        <div id="report-section-accessibility-methodology" class="px-4 py-4">
          <.methodology_table
            section_id="accessibility"
            entries={methodology_entries("accessibility", @section)}
          />
        </div>
      <% else %>
        <div class="divide-y divide-base-content/10">
          <.step_free_item :if={@step_free} item={@step_free} />
          <.wheelchair_item :if={@wheelchair} item={@wheelchair} />
          <.elevator_item :if={@elevator} item={@elevator} />
          <.escalator_item :if={@escalator} item={@escalator} />
        </div>
      <% end %>
    </section>
    """
  end

  attr :item, :map, required: true

  defp step_free_item(assigns) do
    summary = assigns.item.value
    matrix = assigns.item.details || []

    # Build matrix data for table rendering
    {entrance_ids, platform_ids, cell_map} = build_matrix_data(matrix)

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:matrix, matrix)
      |> assign(:entrance_ids, entrance_ids)
      |> assign(:platform_ids, platform_ids)
      |> assign(:cell_map, cell_map)

    ~H"""
    <div id="report-item-step_free_routes" class="px-4 py-4">
      <div class="flex items-start gap-2 mb-3">
        <.status_dot status={@item.status} />
        <div>
          <p class="text-sm font-medium">{@item.label}</p>
          <p class="text-xs text-base-content/60 mt-0.5">
            {Map.get(@summary, :connected_pairs, 0)}/{Map.get(@summary, :total_pairs, 0)} pairs connected
          </p>
        </div>
      </div>

      <%= if @matrix != [] and @entrance_ids != [] and @platform_ids != [] do %>
        <div class="overflow-x-auto">
          <table class="text-xs">
            <thead>
              <tr>
                <th class="pr-6 pb-1 text-left font-medium text-base-content/60 min-w-[8rem]"></th>
                <th
                  :for={pid <- @platform_ids}
                  class="px-2 pb-1 text-center font-mono font-medium text-base-content/60"
                  title={pid}
                >
                  {truncate_id(pid)}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={eid <- @entrance_ids} class="border-t border-base-200">
                <td class="pr-6 py-1 font-mono text-base-content/60 min-w-[14rem]" title={eid}>
                  {eid}
                </td>
                <td :for={pid <- @platform_ids} class="px-2 py-1 text-center">
                  <%= if Map.get(@cell_map, {eid, pid}) do %>
                    <span class="text-emerald-700">&#10003;</span>
                  <% else %>
                    <span class="text-base-content/40">&#10005;</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% else %>
        <p class="text-sm text-base-content/60">
          {cond do
            Map.get(@summary, :entrances, 0) == 0 ->
              "No entrances defined"

            Map.get(@summary, :boarding_areas, Map.get(@summary, :platforms, 0)) == 0 ->
              "No boarding areas defined"

            true ->
              "No route data"
          end}
        </p>
      <% end %>
    </div>
    """
  end

  defp build_matrix_data(matrix) when is_list(matrix) do
    entrance_ids = matrix |> Enum.map(& &1.entrance_stop_id) |> Enum.uniq()
    platform_ids = matrix |> Enum.map(& &1.platform_stop_id) |> Enum.uniq()

    cell_map =
      Map.new(matrix, fn cell ->
        {{cell.entrance_stop_id, cell.platform_stop_id}, cell.reachable}
      end)

    {entrance_ids, platform_ids, cell_map}
  end

  defp build_matrix_data(_), do: {[], [], %{}}

  defp truncate_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 10) <> ".."
  defp truncate_id(id), do: id

  attr :item, :map, required: true

  defp wheelchair_item(assigns) do
    assigns = assign(assigns, :rows, wheelchair_rows(assigns.item.value))

    ~H"""
    <div id="report-item-wheelchair_boarding_distribution" class="px-4 py-4">
      <div class="flex items-start gap-2 mb-2">
        <.status_dot status={@item.status} />
        <p class="text-sm font-medium">{@item.label}</p>
      </div>
      <table :if={@rows != []} class="w-full text-sm">
        <thead>
          <tr class="text-left text-xs text-base-content/60">
            <th class="pb-1 font-medium">Type</th>
            <th class="pb-1 font-medium text-right">No Info</th>
            <th class="pb-1 font-medium text-right">Accessible</th>
            <th class="pb-1 font-medium text-right">Not Accessible</th>
            <th class="pb-1 font-medium text-right">Empty</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-t border-base-200">
            <td class="py-1">{row.label}</td>
            <td class={["py-1 text-right font-mono", row.no_info > 0 && "text-warning"]}>
              {row.no_info}
            </td>
            <td class="py-1 text-right font-mono">{row.accessible}</td>
            <td class="py-1 text-right font-mono">{row.not_accessible}</td>
            <td class={["py-1 text-right font-mono", row.empty > 0 && "text-warning"]}>
              {row.empty}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp wheelchair_rows(value) when is_map(value) do
    value
    |> Enum.map(fn {type_str, counts} ->
      type_int = String.to_integer(type_str)

      %{
        type: type_int,
        label: Stop.location_type_label(type_int),
        no_info: Map.get(counts, "0", 0),
        accessible: Map.get(counts, "1", 0),
        not_accessible: Map.get(counts, "2", 0),
        empty: Map.get(counts, "empty", 0)
      }
    end)
    |> Enum.sort_by(& &1.type)
  end

  defp wheelchair_rows(_), do: []

  attr :item, :map, required: true

  defp elevator_item(assigns) do
    ~H"""
    <div id="report-item-elevator_level_coverage" class="px-4 py-4">
      <div class="flex items-start gap-2">
        <.status_dot status={@item.status} />
        <div>
          <div class="flex items-baseline gap-3">
            <p class="text-sm font-medium">{@item.label}</p>
            <span class="text-sm font-mono text-base-content/70">
              {Map.get(@item.value, :reachable_levels, 0)}/{Map.get(@item.value, :reachable_levels, 0) +
                Map.get(@item.value, :unreachable_levels, 0)} levels
            </span>
          </div>
          <div
            :if={is_map(@item.details) and Map.get(@item.details, :unreachable_levels, []) != []}
            class="mt-1.5 space-y-0.5"
          >
            <p :for={level <- @item.details.unreachable_levels} class="text-xs text-warning font-mono">
              Unreachable: {level.level_id}
              <span :if={level.level_index} class="text-base-content/50">
                (index {level.level_index})
              </span>
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true

  defp escalator_item(assigns) do
    ~H"""
    <div id="report-item-escalator_direction_summary" class="px-4 py-4">
      <div class="flex items-start gap-2">
        <.status_dot status={@item.status} />
        <div>
          <p class="text-sm font-medium">{@item.label}</p>
          <p class="text-sm text-base-content/70 mt-0.5">
            Up: <span class="font-mono">{Map.get(@item.value, :up, 0)}</span>
            · Down: <span class="font-mono">{Map.get(@item.value, :down, 0)}</span>
            · Unknown:
            <span class={["font-mono", Map.get(@item.value, :unknown, 0) > 0 && "text-warning"]}>
              {Map.get(@item.value, :unknown, 0)}
            </span>
          </p>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Entrance -> Platform Connectivity section
  # ============================================================================

  attr :section, :map, required: true
  attr :methodology_mode, :boolean, default: false

  def entrance_platform_connectivity_section(assigns) do
    item = find_item(assigns.section, "entrance_platform_paths")
    details = if item, do: item.details || [], else: []
    summary = if item, do: item.value || %{}, else: %{}
    {entrance_ids, platform_ids, cell_map} = build_matrix_data(details)
    grouped_details = group_connectivity_details_by_entrance(details)

    assigns =
      assigns
      |> assign(:item, item)
      |> assign(:details, details)
      |> assign(:summary, summary)
      |> assign(:entrance_ids, entrance_ids)
      |> assign(:platform_ids, platform_ids)
      |> assign(:cell_map, cell_map)
      |> assign(:grouped_details, grouped_details)

    ~H"""
    <section
      id="report-section-entrance_platform_connectivity"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3 flex items-center justify-between gap-3">
        <h2 class="text-base font-semibold">{@section.title}</h2>
        <button
          id="report-section-entrance_platform_connectivity-methodology-toggle"
          type="button"
          phx-click="toggle_methodology"
          phx-value-section_id="entrance_platform_connectivity"
          class="text-xs font-medium lowercase text-primary hover:text-primary/80 hover:underline transition-colors"
        >
          {if @methodology_mode, do: "back", else: "methodology"}
        </button>
      </header>

      <%= if @methodology_mode do %>
        <div id="report-section-entrance_platform_connectivity-methodology" class="px-4 py-4">
          <.methodology_table
            section_id="entrance_platform_connectivity"
            entries={methodology_entries("entrance_platform_connectivity", @section)}
          />
        </div>
      <% else %>
        <.entrance_platform_paths_item
          :if={@item}
          item={@item}
          details={@details}
          summary={@summary}
          entrance_ids={@entrance_ids}
          platform_ids={@platform_ids}
          cell_map={@cell_map}
          grouped_details={@grouped_details}
        />
      <% end %>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :details, :list, required: true
  attr :summary, :map, required: true
  attr :entrance_ids, :list, required: true
  attr :platform_ids, :list, required: true
  attr :cell_map, :map, required: true
  attr :grouped_details, :list, required: true

  defp entrance_platform_paths_item(assigns) do
    ~H"""
    <div id="report-item-entrance_platform_paths" class="px-4 py-4 space-y-3">
      <div class="flex items-start gap-2">
        <.status_dot status={@item.status} />
        <div>
          <p class="text-sm font-medium">{@item.label}</p>
          <p class="text-xs text-base-content/60 mt-0.5">
            {Map.get(@summary, :connected_pairs, 0)}/{Map.get(@summary, :total_pairs, 0)} pairs connected
            · {Map.get(@summary, :entrances, 0)} entrances · {Map.get(
              @summary,
              :boarding_areas,
              Map.get(@summary, :platforms, 0)
            )} boarding areas
          </p>
        </div>
      </div>

      <%= if @details != [] and @entrance_ids != [] and @platform_ids != [] do %>
        <div class="overflow-x-auto">
          <table class="text-xs">
            <thead>
              <tr>
                <th class="pr-6 pb-1 text-left font-medium text-base-content/60 min-w-[8rem]"></th>
                <th
                  :for={pid <- @platform_ids}
                  class="px-2 pb-1 text-center font-mono font-medium text-base-content/60"
                  title={pid}
                >
                  {truncate_id(pid)}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={eid <- @entrance_ids} class="border-t border-base-200">
                <td class="pr-6 py-1 font-mono text-base-content/60 min-w-[14rem]" title={eid}>
                  {eid}
                </td>
                <td :for={pid <- @platform_ids} class="px-2 py-1 text-center">
                  <%= if Map.get(@cell_map, {eid, pid}) do %>
                    <span class="text-emerald-700">&#10003;</span>
                  <% else %>
                    <span class="text-base-content/40">&#10005;</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% else %>
        <p class="text-sm text-base-content/60">No entrance-platform pairs available.</p>
      <% end %>

      <div :if={@grouped_details != []} class="space-y-2">
        <details
          :for={group <- @grouped_details}
          id={"report-entrance-#{dom_token(group.entrance_stop_id)}"}
          class="rounded-lg border border-base-content/15 px-3 py-2"
        >
          <summary class="cursor-pointer text-xs font-mono text-base-content/75">
            Entrance {group.entrance_stop_id}
          </summary>

          <div class="mt-2 space-y-2">
            <details
              :for={detail <- group.pairs}
              id={pair_details_dom_id(detail.entrance_stop_id, detail.platform_stop_id)}
              class="rounded-md border border-base-content/10 px-3 py-2"
            >
              <summary class="cursor-pointer text-xs font-mono text-base-content/75">
                {detail.platform_stop_id}
                <span class={[
                  "ml-2 font-medium",
                  detail.reachable && "text-success",
                  !detail.reachable && "text-error"
                ]}>
                  {if detail.reachable, do: "reachable", else: "not reachable"}
                </span>
              </summary>

              <%= if detail.reachable and detail.path != [] do %>
                <div class="mt-2 overflow-x-auto">
                  <table class="w-full text-xs">
                    <thead>
                      <tr class="text-left text-base-content/55">
                        <th class="pb-1 font-medium">Hop</th>
                        <th class="pb-1 font-medium">Stop</th>
                        <th class="pb-1 font-medium">Pathway</th>
                        <th class="pb-1 font-medium">Mode</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={{hop, index} <- Enum.with_index(detail.path, 1)}
                        class="border-t border-base-200"
                      >
                        <td class="py-1 font-mono">{index}</td>
                        <td class="py-1 font-mono">{hop.stop_id}</td>
                        <td class="py-1 font-mono">{hop.pathway_id || "-"}</td>
                        <td class="py-1">
                          {if is_integer(hop.pathway_mode),
                            do: Pathway.mode_label(hop.pathway_mode),
                            else: "-"}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% else %>
                <p class="mt-2 text-xs text-base-content/60">No directed path found.</p>
              <% end %>
            </details>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp pair_details_dom_id(entrance_stop_id, platform_stop_id) do
    "report-pair-#{dom_token(entrance_stop_id)}-#{dom_token(platform_stop_id)}"
  end

  defp dom_token(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/u, "_")
  end

  defp group_connectivity_details_by_entrance(details) when is_list(details) do
    details
    |> Enum.group_by(& &1.entrance_stop_id)
    |> Enum.map(fn {entrance_stop_id, pairs} ->
      %{entrance_stop_id: entrance_stop_id, pairs: Enum.sort_by(pairs, & &1.platform_stop_id)}
    end)
    |> Enum.sort_by(& &1.entrance_stop_id)
  end

  defp group_connectivity_details_by_entrance(_), do: []

  # ============================================================================
  # Inventory section
  # ============================================================================

  attr :section, :map, required: true

  def inventory_section(assigns) do
    node_inv = find_item(assigns.section, "node_inventory")
    edge_inv = find_item(assigns.section, "edge_inventory")
    directionality = find_item(assigns.section, "pathway_directionality")
    level_summary = find_item(assigns.section, "level_summary")
    nodes_per_level = find_item(assigns.section, "nodes_per_level")

    assigns =
      assigns
      |> assign(:node_inv, node_inv)
      |> assign(:edge_inv, edge_inv)
      |> assign(:directionality, directionality)
      |> assign(:level_summary, level_summary)
      |> assign(:nodes_per_level, nodes_per_level)

    ~H"""
    <section
      id="report-section-inventory"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3">
        <h2 class="text-base font-semibold">{@section.title}</h2>
      </header>

      <div class="divide-y divide-base-content/10">
        <.kv_grid_item
          :if={@node_inv}
          item={@node_inv}
          entries={labeled_counts(@node_inv.value, &Stop.location_type_label/1)}
        />
        <.kv_grid_item
          :if={@edge_inv}
          item={@edge_inv}
          entries={labeled_counts(@edge_inv.value, &Pathway.mode_label/1)}
        />
        <.directionality_item :if={@directionality} item={@directionality} />
        <.level_table_item
          :if={@level_summary}
          item={@level_summary}
          nodes_per_level={if @nodes_per_level, do: @nodes_per_level.value, else: %{}}
        />
      </div>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :entries, :list, required: true

  defp kv_grid_item(assigns) do
    ~H"""
    <div id={"report-item-#{@item.id}"} class="px-4 py-4">
      <p class="text-sm font-medium mb-2">{@item.label}</p>
      <div class="grid grid-cols-2 sm:grid-cols-3 gap-x-6 gap-y-1">
        <div :for={{label, count} <- @entries} class="flex justify-between text-sm">
          <span class="text-base-content/70">{label}</span>
          <span class="font-mono">{count}</span>
        </div>
      </div>
    </div>
    """
  end

  defp labeled_counts(value, label_fn) when is_map(value) do
    value
    |> Enum.map(fn {key, count} ->
      int_key = if is_integer(key), do: key, else: parse_int(key)
      {label_fn.(int_key), count}
    end)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp labeled_counts(_, _), do: []

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> -1
    end
  end

  defp parse_int(value) when is_atom(value) do
    value |> Atom.to_string() |> parse_int()
  end

  defp parse_int(_), do: -1

  attr :item, :map, required: true

  defp directionality_item(assigns) do
    ~H"""
    <div id={"report-item-#{@item.id}"} class="px-4 py-4">
      <p class="text-sm font-medium mb-1">{@item.label}</p>
      <p class="text-sm text-base-content/70">
        Bidirectional: <span class="font-mono">{Map.get(@item.value, :bidirectional, 0)}</span>
        · Unidirectional: <span class="font-mono">{Map.get(@item.value, :unidirectional, 0)}</span>
      </p>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :nodes_per_level, :map, required: true

  defp level_table_item(assigns) do
    details = assigns.item.details || []

    rows =
      Enum.map(details, fn level ->
        %{
          level_id: level.level_id,
          name: level.level_name,
          index: level.level_index,
          nodes: Map.get(assigns.nodes_per_level, level.level_id, 0)
        }
      end)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div id={"report-item-#{@item.id}"} class="px-4 py-4">
      <p class="text-sm font-medium mb-2">{@item.label}</p>
      <%= if @rows == [] do %>
        <p class="text-sm text-base-content/60">No levels defined</p>
      <% else %>
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-xs text-base-content/60">
              <th class="pb-1 font-medium">Level</th>
              <th class="pb-1 font-medium">Name</th>
              <th class="pb-1 font-medium text-right">Index</th>
              <th class="pb-1 font-medium text-right">Nodes</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class="border-t border-base-200">
              <td class="py-1 font-mono text-xs">{row.level_id}</td>
              <td class="py-1">{row.name}</td>
              <td class="py-1 text-right font-mono">{row.index}</td>
              <td class="py-1 text-right font-mono">{row.nodes}</td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Attribute Completeness section
  # ============================================================================

  attr :section, :map, required: true
  attr :methodology_mode, :boolean, default: false

  def completeness_section(assigns) do
    pathway_completeness = find_item(assigns.section, "pathway_attribute_completeness")
    mode_completeness = find_item(assigns.section, "mode_specific_completeness")
    signage = find_item(assigns.section, "signage_completeness")

    assigns =
      assigns
      |> assign(:pathway_completeness, pathway_completeness)
      |> assign(:mode_completeness, mode_completeness)
      |> assign(:signage, signage)

    ~H"""
    <section
      id="report-section-attribute_completeness"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3 flex items-center justify-between gap-3">
        <h2 class="text-base font-semibold">{@section.title}</h2>
        <button
          id="report-section-attribute_completeness-methodology-toggle"
          type="button"
          phx-click="toggle_methodology"
          phx-value-section_id="attribute_completeness"
          class="text-xs font-medium lowercase text-primary hover:text-primary/80 hover:underline transition-colors"
        >
          {if @methodology_mode, do: "back", else: "methodology"}
        </button>
      </header>

      <%= if @methodology_mode do %>
        <div id="report-section-attribute_completeness-methodology" class="px-4 py-4">
          <.methodology_table
            section_id="attribute_completeness"
            entries={methodology_entries("attribute_completeness", @section)}
          />
        </div>
      <% else %>
        <div class="divide-y divide-base-content/10">
          <.completeness_bars_item :if={@pathway_completeness} item={@pathway_completeness} />
          <.mode_completeness_item :if={@mode_completeness} item={@mode_completeness} />
          <.completeness_bars_item :if={@signage} item={@signage} />
        </div>
      <% end %>
    </section>
    """
  end

  attr :item, :map, required: true

  defp completeness_bars_item(assigns) do
    bars =
      assigns.item.value
      |> Enum.map(fn {field, stats} ->
        %{
          field: field_label(field),
          percent: stats.percent,
          present: stats.present,
          total: stats.total
        }
      end)
      |> Enum.sort_by(& &1.field)

    assigns = assign(assigns, :bars, bars)

    ~H"""
    <div id={"report-item-#{@item.id}"} class="px-4 py-4">
      <p class="text-sm font-medium mb-3">{@item.label}</p>
      <div class="space-y-2">
        <div :for={bar <- @bars} class="flex items-center gap-3">
          <span class="text-xs text-base-content/70 w-40 shrink-0 truncate" title={bar.field}>
            {bar.field}
          </span>
          <div class="flex-1 h-2 bg-base-200 rounded-full overflow-hidden">
            <div
              class={[
                "h-full rounded-full",
                bar.percent >= 80 && "bg-success",
                (bar.percent >= 40 and bar.percent < 80) && "bg-warning",
                bar.percent < 40 && "bg-error"
              ]}
              style={"width: #{bar.percent}%"}
            >
            </div>
          </div>
          <span class="text-xs font-mono text-base-content/60 w-24 shrink-0 text-right">
            {format_percent(bar.percent)}% ({bar.present}/{bar.total})
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true

  defp mode_completeness_item(assigns) do
    modes =
      assigns.item.value
      |> Enum.map(fn {mode, fields} ->
        bars =
          fields
          |> Enum.map(fn {field, stats} ->
            %{
              field: field_label(field),
              percent: stats.percent,
              present: stats.present,
              total: stats.total
            }
          end)
          |> Enum.sort_by(& &1.field)

        %{mode: mode, label: Pathway.mode_label(mode), bars: bars}
      end)
      |> Enum.sort_by(& &1.mode)

    assigns = assign(assigns, :modes, modes)

    ~H"""
    <div id={"report-item-#{@item.id}"} class="px-4 py-4">
      <p class="text-sm font-medium mb-3">{@item.label}</p>
      <div class="space-y-4">
        <div :for={mode <- @modes}>
          <p class="text-xs font-medium text-base-content/60 mb-1.5">{mode.label}</p>
          <%= if mode.bars == [] do %>
            <p class="text-xs text-base-content/40">No pathways</p>
          <% else %>
            <div class="space-y-1.5">
              <div :for={bar <- mode.bars} class="flex items-center gap-3">
                <span class="text-xs text-base-content/70 w-40 shrink-0 truncate" title={bar.field}>
                  {bar.field}
                </span>
                <div class="flex-1 h-2 bg-base-200 rounded-full overflow-hidden">
                  <div
                    class={[
                      "h-full rounded-full",
                      bar.percent >= 80 && "bg-success",
                      (bar.percent >= 40 and bar.percent < 80) && "bg-warning",
                      bar.percent < 40 && "bg-error"
                    ]}
                    style={"width: #{bar.percent}%"}
                  >
                  </div>
                </div>
                <span class="text-xs font-mono text-base-content/60 w-24 shrink-0 text-right">
                  {format_percent(bar.percent)}% ({bar.present}/{bar.total})
                </span>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Not Available section
  # ============================================================================

  attr :section, :map, required: true

  def unavailable_section(assigns) do
    item = find_item(assigns.section, "unavailable_metrics")
    details = if item, do: item.details || [], else: []

    assigns =
      assigns
      |> assign(:item, item)
      |> assign(:details, details)

    ~H"""
    <section
      id="report-section-not_available"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <details class="group">
        <summary class="px-4 py-3 cursor-pointer select-none flex items-center justify-between">
          <span class="text-sm text-base-content/50">
            {length(@details)} metrics not available in current schema
          </span>
          <span class="text-base-content/30 group-open:rotate-180 transition-transform text-xs">
            &#9660;
          </span>
        </summary>
        <div :if={@item} id={"report-item-#{@item.id}"} class="px-4 pb-3">
          <ul class="list-disc pl-5 text-xs text-base-content/50 space-y-0.5">
            <li :for={metric <- @details}>{metric}</li>
          </ul>
        </div>
      </details>
    </section>
    """
  end

  # ============================================================================
  # Methodology section
  # ============================================================================

  attr :section_id, :string, required: true
  attr :entries, :list, required: true

  defp methodology_table(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="hidden md:grid md:grid-cols-[minmax(10rem,1fr)_minmax(8rem,0.7fr)_minmax(20rem,2fr)] md:gap-4 text-xs uppercase tracking-wide text-base-content/50">
        <div>Metric</div>
        <div>Reporting Unit</div>
        <div>Methodology</div>
      </div>

      <div class="space-y-2">
        <div
          :for={entry <- @entries}
          id={"report-method-#{@section_id}-#{entry.item_id}"}
          class="grid grid-cols-1 md:grid-cols-[minmax(10rem,1fr)_minmax(8rem,0.7fr)_minmax(20rem,2fr)] gap-1 md:gap-4 rounded-lg border border-base-content/10 bg-base-100 p-3"
        >
          <div>
            <p class="text-[11px] uppercase tracking-wide text-base-content/45 md:hidden">Metric</p>
            <p class="text-sm font-medium">{entry.label}</p>
          </div>
          <div>
            <p class="text-[11px] uppercase tracking-wide text-base-content/45 md:hidden">
              Reporting unit
            </p>
            <p class="text-xs font-mono text-base-content/70">{entry.reporting_unit}</p>
          </div>
          <div>
            <p class="text-[11px] uppercase tracking-wide text-base-content/45 md:hidden">
              Methodology
            </p>
            <p class="text-sm text-base-content/80">{entry.methodology}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Shared helpers
  # ============================================================================

  defp methodology_entries("data_integrity", section, gps_section) do
    item_labels =
      (items_for(section) ++ items_for(gps_section))
      |> Map.new(fn item -> {item.id, item.label} end)

    [
      %{
        item_id: "isolated_nodes",
        reporting_unit: "count + stop_id list",
        methodology:
          "Count location_type 2/3/4 nodes that have zero undirected neighbors in the station pathway graph."
      },
      %{
        item_id: "boarding_area_parent_consistency",
        reporting_unit: "count + stop_id list",
        methodology:
          "For each boarding area (location_type 4), verify parent_station points to a platform (location_type 0)."
      },
      %{
        item_id: "station_parent_consistency",
        reporting_unit: "count + stop_id list",
        methodology:
          "Verify every platform, entrance, and generic node has parent_station equal to the current station stop_id."
      },
      %{
        item_id: "orphaned_platforms",
        reporting_unit: "count + stop_id list",
        methodology:
          "Flag platforms that do not have at least one boarding-area child with parent_station set to that platform."
      },
      %{
        item_id: "minimum_station_children",
        reporting_unit: "boolean + entrance/platform totals",
        methodology:
          "Pass when the station has at least one entrance and at least one platform among child stops."
      },
      %{
        item_id: "entrance_to_boarding_connectivity",
        reporting_unit: "reachable/unreachable counts + per-entrance detail",
        methodology:
          "Run directed reachability from each entrance to any boarding area using BFS over directed pathway edges."
      },
      %{
        item_id: "boarding_area_interconnection",
        reporting_unit: "connected/disconnected counts + per-boarding detail",
        methodology:
          "For each boarding area, run directed reachability to at least one other boarding area in the same graph."
      },
      %{
        item_id: "gps_presence_by_type",
        reporting_unit: "present/missing counts by location_type",
        methodology:
          "Group stops by location_type and count records with both stop_lat and stop_lon present versus missing."
      }
    ]
    |> apply_methodology_labels(item_labels)
  end

  defp methodology_entries("accessibility", section) do
    item_labels = items_for(section) |> Map.new(fn item -> {item.id, item.label} end)

    [
      %{
        item_id: "step_free_routes",
        reporting_unit: "connected_pairs/total_pairs + entrance x boarding matrix",
        methodology:
          "Build directed adjacency using only pathway modes 1, 3, 5, 6, and 7; evaluate reachability for each entrance-boarding pair."
      },
      %{
        item_id: "wheelchair_boarding_distribution",
        reporting_unit: "counts by location_type x wheelchair value",
        methodology:
          "Group child stops by location_type, then count wheelchair_boarding values (0, 1, 2, empty) in each group."
      },
      %{
        item_id: "elevator_level_coverage",
        reporting_unit: "reachable/unreachable level counts + level list",
        methodology:
          "From entrances (or all nodes if no entrances), traverse eligible pathways and compare reached levels against all levels with nodes."
      },
      %{
        item_id: "escalator_direction_summary",
        reporting_unit: "up/down/unknown counts",
        methodology:
          "For pathway_mode 4 rows, infer direction from from_level_index to to_level_index; mark bidirectional or missing index cases as unknown."
      }
    ]
    |> apply_methodology_labels(item_labels)
  end

  defp methodology_entries("attribute_completeness", section) do
    item_labels = items_for(section) |> Map.new(fn item -> {item.id, item.label} end)

    [
      %{
        item_id: "pathway_attribute_completeness",
        reporting_unit: "present/total + percent per field",
        methodology:
          "For each tracked pathway attribute, count non-empty values across station pathways and compute present ÷ total percent."
      },
      %{
        item_id: "mode_specific_completeness",
        reporting_unit: "present/total + percent by mode and field",
        methodology:
          "Partition pathways by pathway_mode, then compute field completeness percentages within each mode-specific subset."
      },
      %{
        item_id: "signage_completeness",
        reporting_unit: "present/total + percent for signage fields",
        methodology:
          "Count signposted_as on all pathways and reversed_signposted_as only when pathway is bidirectional, then compute percentages."
      }
    ]
    |> apply_methodology_labels(item_labels)
  end

  defp methodology_entries("entrance_platform_connectivity", section) do
    item_labels = items_for(section) |> Map.new(fn item -> {item.id, item.label} end)

    [
      %{
        item_id: "entrance_platform_paths",
        reporting_unit: "connected_pairs/total_pairs + pair matrix + hop paths",
        methodology:
          "Build directed adjacency from all station pathways, then run deterministic shortest-path BFS for each entrance-boarding pair and report hop-by-hop pathway metadata."
      }
    ]
    |> apply_methodology_labels(item_labels)
  end

  defp methodology_entries(_, _section), do: []

  defp apply_methodology_labels(entries, item_labels) do
    Enum.map(entries, fn entry ->
      Map.put(entry, :label, Map.get(item_labels, entry.item_id, entry.item_id))
    end)
  end

  defp find_section(sections, id) do
    Enum.find(sections, &(&1.id == id))
  end

  defp find_item(%{items: items}, id) do
    Enum.find(items, &(&1.id == id))
  end

  defp find_item(nil, _id), do: nil

  defp field_label(field) when is_atom(field) do
    field
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp field_label(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp field_label(field), do: to_string(field)

  defp format_percent(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> round() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, decimals: 1)
  end

  defp format_percent(value) when is_integer(value), do: Integer.to_string(value)
  defp format_percent(_), do: "0"
end
