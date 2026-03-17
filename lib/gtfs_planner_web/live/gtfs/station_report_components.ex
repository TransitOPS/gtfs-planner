defmodule GtfsPlannerWeb.Gtfs.StationReportComponents do
  @moduledoc """
  Function components for the station report dashboard.
  Transforms raw report data into structured, information-dense displays.
  """
  use Phoenix.Component
  import GtfsPlannerWeb.CoreComponents, only: [icon: 1, drawer: 1, input: 1]

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
    naming_section = find_section(sections, "naming_conventions")
    pathway_section = find_section(sections, "pathway_validation")
    levels_section = find_section(sections, "levels_validation")
    accessibility_section = find_section(sections, "accessibility")
    inventory_section = find_section(sections, "inventory")
    completeness_section = find_section(sections, "attribute_completeness")

    all_integrity_items =
      items_for(integrity_section) ++
        items_for(gps_section) ++
        items_for(naming_section) ++
        items_for(pathway_section) ++
        items_for(levels_section)

    # Only count :error and :warning category items toward the integrity fail tally
    countable_items =
      Enum.filter(all_integrity_items, fn item ->
        category = Map.get(item, :category, :error)
        category in [:error, :warning]
      end)

    accessibility_items = items_for(accessibility_section)

    {nodes, edges} = inventory_counts(inventory_section)
    completeness_pct = aggregate_completeness(completeness_section)

    %{
      integrity: %{
        fails: Enum.count(countable_items, &(&1.status == :fail)),
        total: length(countable_items)
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
  attr :gtfs_version_id, :string, default: nil
  attr :station_stop_id, :string, default: nil

  def integrity_section(assigns) do
    assigns =
      assigns
      |> assign(:gps_table_items, gps_table_items(assigns.gps_section))
      |> assign(:gps_check_items, gps_check_items(assigns.gps_section))

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
          <.check_row
            :for={item <- @section.items}
            item={item}
            gtfs_version_id={@gtfs_version_id}
            station_stop_id={@station_stop_id}
          />

          <div :if={@gps_section} id="report-section-gps" class="px-4 py-4 space-y-4">
            <.gps_item :for={item <- @gps_table_items} item={item} />

            <div :if={@gps_check_items != []} class="divide-y divide-base-content/10">
              <.check_row
                :for={item <- @gps_check_items}
                item={item}
                gtfs_version_id={@gtfs_version_id}
                station_stop_id={@station_stop_id}
              />
            </div>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  defp gps_table_items(nil), do: []

  defp gps_table_items(%{items: items}) do
    Enum.filter(items, &(&1.id == "gps_presence_by_type" and is_map(&1.value)))
  end

  defp gps_check_items(nil), do: []

  defp gps_check_items(%{items: items}) do
    Enum.reject(items, &(&1.id == "gps_presence_by_type" and is_map(&1.value)))
  end

  attr :item, :map, required: true
  attr :gtfs_version_id, :string, default: nil
  attr :station_stop_id, :string, default: nil

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
              @item.status in [:fail, :warn] and is_list(@item.details) and @item.details != [] and
                @item.id not in ["entrance_to_platform_connectivity", "platform_interconnection"]
            }
            item={@item}
            ids={@item.details}
            gtfs_version_id={@gtfs_version_id}
            station_stop_id={@station_stop_id}
          />
          <.connectivity_details
            :if={
              @item.id in ["entrance_to_platform_connectivity", "platform_interconnection"] and
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
  attr :gtfs_version_id, :string, default: nil
  attr :station_stop_id, :string, default: nil

  defp stop_id_list(assigns) do
    assigns = assign(assigns, :entity_type, entity_type_for_item(assigns.item.id))

    ~H"""
    <div id={"report-item-#{@item.id}-details"} class="mt-2 space-y-0.5">
      <%= for detail <- @ids do %>
        <%= if is_map(detail) do %>
          <div class="flex items-baseline gap-2 text-xs">
            <.entity_link
              id={detail.id}
              entity_type={@entity_type}
            />
            <span class="text-base-content/50">{Map.get(detail, :reason, "")}</span>
          </div>
        <% else %>
          <.entity_link
            id={to_string(detail)}
            entity_type={@entity_type}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp entity_type_for_item("pathway_" <> _), do: "pathway"
  defp entity_type_for_item(_), do: "stop"

  attr :id, :string, required: true
  attr :gtfs_version_id, :string, default: nil
  attr :station_stop_id, :string, default: nil
  attr :entity_type, :string, default: "stop"

  defp entity_link(assigns) do
    ~H"""
    <span
      phx-click="select_entity"
      phx-value-entity_id={@id}
      phx-value-entity_type={@entity_type}
      class="font-mono text-xs text-primary hover:underline cursor-pointer"
    >
      {@id}
    </span>
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
  defp connectivity_id(%{platform_stop_id: id}), do: id
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

            Map.get(@summary, :platforms, 0) == 0 ->
              "No platforms defined"

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
  attr :reversed_pairs, :any, default: MapSet.new()
  attr :expanded_entrances, :any, default: MapSet.new()

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
          reversed_pairs={@reversed_pairs}
          expanded_entrances={@expanded_entrances}
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
  attr :reversed_pairs, :any, default: MapSet.new()
  attr :expanded_entrances, :any, default: MapSet.new()

  defp entrance_platform_paths_item(assigns) do
    ~H"""
    <div id="report-item-entrance_platform_paths" class="px-4 py-4 space-y-3">
      <div class="flex items-start gap-2">
        <.status_dot status={@item.status} />
        <div>
          <p class="text-sm font-medium">{@item.label}</p>
          <p class="text-xs text-base-content/60 mt-0.5">
            {Map.get(@summary, :connected_pairs, 0)}/{Map.get(@summary, :total_pairs, 0)} pairs connected
            · {Map.get(@summary, :accessible_pairs, 0)} accessible
            · {Map.get(@summary, :entrances, 0)} entrances · {Map.get(@summary, :platforms, 0)} platforms
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
          class="group rounded-lg border border-base-content/15 px-3 py-2"
          open={MapSet.member?(@expanded_entrances, group.entrance_stop_id)}
        >
          <summary
            class="cursor-pointer list-none text-xs font-mono text-base-content/75 flex items-center justify-between gap-2"
            phx-click="toggle_connectivity_entrance"
            phx-value-entrance_id={group.entrance_stop_id}
          >
            <span>Entrance {group.entrance_stop_id}</span>
            <.icon
              name="hero-chevron-down"
              class="h-4 w-4 text-base-content/70 transition-transform duration-200 group-open:rotate-180"
            />
          </summary>

          <div class="mt-3 space-y-5">
            <div
              :for={detail <- group.pairs}
              id={pair_details_dom_id(detail.entrance_stop_id, detail.platform_stop_id)}
              class="px-3 py-3 space-y-2 border-t border-base-content/10 first:border-t-0"
            >
              <div class="text-lg font-bold tracking-tight text-base-content">
                {detail.platform_stop_id}
                <span class={[
                  "ml-2 font-medium",
                  detail.reachable && "text-emerald-800",
                  !detail.reachable && "text-error"
                ]}>
                  {if detail.reachable, do: "reachable", else: "not reachable"}
                </span>
              </div>

              <.dual_path_display
                detail={detail}
                pair_id={pair_id(detail)}
                reversed_pairs={@reversed_pairs}
              />
            </div>
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

  attr :detail, :map, required: true
  attr :pair_id, :string, required: true
  attr :reversed_pairs, :any, default: MapSet.new()

  defp dual_path_display(assigns) do
    ~H"""
    <%= cond do %>
      <% not @detail.reachable -> %>
        <p class="mt-2 text-xs text-base-content/60">No directed path found.</p>
      <% @detail.paths_identical and @detail.shortest -> %>
        <div class="mt-1 mb-2">
          <span class="text-xs font-medium text-base-content/55">Default + Accessible</span>
        </div>
        <.trip_visualization
          enriched={@detail.shortest.enriched}
          pair_id={@pair_id}
          reversed?={MapSet.member?(@reversed_pairs, @pair_id)}
        />
      <% @detail.shortest && @detail.accessible_path && not @detail.paths_identical -> %>
        <div class="space-y-4">
          <div>
            <div class="mt-1 mb-2">
              <span class="text-xs font-medium text-base-content/55">Default path</span>
            </div>
            <.trip_visualization
              enriched={@detail.shortest.enriched}
              pair_id={"#{@pair_id}::default"}
              reversed?={MapSet.member?(@reversed_pairs, "#{@pair_id}::default")}
            />
          </div>
          <div>
            <div class="mt-1 mb-2">
              <span class="text-xs font-medium text-base-content/55">
                Accessible path (step-free)
              </span>
            </div>
            <.trip_visualization
              enriched={@detail.accessible_path.enriched}
              pair_id={"#{@pair_id}::accessible"}
              reversed?={MapSet.member?(@reversed_pairs, "#{@pair_id}::accessible")}
            />
          </div>
        </div>
      <% @detail.shortest && not @detail.accessible -> %>
        <.trip_visualization
          enriched={@detail.shortest.enriched}
          pair_id={@pair_id}
          reversed?={MapSet.member?(@reversed_pairs, @pair_id)}
        />
        <p class="text-xs text-warning mt-2">No step-free route available.</p>
      <% true -> %>
        <p class="mt-2 text-xs text-base-content/60">No directed path found.</p>
    <% end %>
    """
  end

  attr :enriched, :map, required: true
  attr :pair_id, :string, required: true
  attr :reversed?, :boolean, required: true

  defp trip_visualization(assigns) do
    display_hops = display_path(assigns.enriched, assigns.reversed?)
    totals = assigns.enriched.totals

    assigns =
      assigns
      |> assign(:display_hops, display_hops)
      |> assign(:totals, totals)
      |> assign(:has_unidirectional, not assigns.enriched.all_bidirectional)

    ~H"""
    <div id={"report-trip-visualization-#{dom_token(@pair_id)}"} class="mt-3 space-y-3">
      <.direction_toggle pair_id={@pair_id} reversed?={@reversed?} />

      <p
        :if={@reversed? and @has_unidirectional}
        id={"report-trip-direction-warning-#{dom_token(@pair_id)}"}
        class="text-xs text-warning"
      >
        Reverse display may not represent a traversable direction because one or more segments are unidirectional.
      </p>

      <.walk_summary_strip pair_id={@pair_id} totals={@totals} />
      <.segment_timeline_bar pair_id={@pair_id} hops={@display_hops} totals={@totals} />
      <.step_table pair_id={@pair_id} hops={@display_hops} totals={@totals} />
      <.vertical_profile_svg pair_id={@pair_id} hops={@display_hops} />
      <.analysis_cards pair_id={@pair_id} hops={@display_hops} totals={@totals} />
    </div>
    """
  end

  attr :pair_id, :string, required: true
  attr :reversed?, :boolean, required: true

  defp direction_toggle(assigns) do
    ~H"""
    <div id={"report-trip-direction-toggle-#{dom_token(@pair_id)}"} class="flex justify-end">
      <button
        id={"report-trip-direction-button-#{dom_token(@pair_id)}"}
        type="button"
        phx-click="toggle_path_direction"
        phx-value-pair_id={@pair_id}
        class={[
          "btn btn-xs transition-colors",
          @reversed? && "btn-primary shadow-none",
          !@reversed? && "btn-outline border-base-content/20"
        ]}
      >
        {if @reversed?, do: "Reverse view", else: "Forward view"}
      </button>
    </div>
    """
  end

  attr :pair_id, :string, required: true
  attr :totals, :map, required: true

  defp walk_summary_strip(assigns) do
    ~H"""
    <div
      id={"report-trip-summary-#{dom_token(@pair_id)}"}
      class="grid grid-cols-2 md:grid-cols-4 gap-2 text-xs"
    >
      <div class="rounded-md border border-base-content/15 px-2 py-1.5">
        <p class="text-base-content/55">Time</p>
        <p class="font-mono">{format_seconds(@totals.time_seconds)}</p>
      </div>
      <div class="rounded-md border border-base-content/15 px-2 py-1.5">
        <p class="text-base-content/55">Distance</p>
        <p class="font-mono">{format_meters(@totals.distance_meters)}</p>
      </div>
      <div class="rounded-md border border-base-content/15 px-2 py-1.5">
        <p class="text-base-content/55">Speed</p>
        <p class="font-mono">{format_speed(@totals.effective_speed)}</p>
      </div>
      <div class="rounded-md border border-base-content/15 px-2 py-1.5">
        <p class="text-base-content/55">Vertical</p>
        <p class="font-mono">{@totals.level_changes} changes · {@totals.unique_levels} levels</p>
      </div>
    </div>
    """
  end

  attr :pair_id, :string, required: true
  attr :hops, :list, required: true
  attr :totals, :map, required: true

  defp segment_timeline_bar(assigns) do
    segments = Enum.drop(assigns.hops, 1)
    widths = segment_widths(segments, assigns.totals.distance_meters)
    legend = segments |> Enum.map(& &1.pathway_mode) |> Enum.filter(&is_integer/1) |> Enum.uniq()

    assigns =
      assigns
      |> assign(:segments, Enum.zip(segments, widths))
      |> assign(:legend, legend)

    ~H"""
    <div id={"report-trip-timeline-#{dom_token(@pair_id)}"} class="space-y-2">
      <div class="flex h-3 overflow-hidden rounded-full border border-base-content/20">
        <div
          :for={{hop, width} <- @segments}
          class={["h-full", mode_color_class(hop.pathway_mode)]}
          style={"width: #{Float.round(width, 2)}%"}
          title={"#{hop.pathway_mode_label || "Unknown"} · #{format_seconds(hop.time_seconds)}"}
        />
      </div>
      <div class="flex flex-wrap gap-2 text-[11px] text-base-content/70">
        <span :for={mode <- @legend} class="inline-flex items-center gap-1">
          <span class={["inline-block h-2 w-2 rounded-full", mode_color_class(mode)]} />
          {Pathway.mode_label(mode)}
        </span>
      </div>
    </div>
    """
  end

  attr :pair_id, :string, required: true
  attr :hops, :list, required: true
  attr :totals, :map, required: true

  defp step_table(assigns) do
    segments = Enum.drop(assigns.hops, 1)

    total_distance =
      if is_number(assigns.totals.distance_meters), do: assigns.totals.distance_meters, else: 0.0

    assigns = assign(assigns, :segments, segments) |> assign(:total_distance, total_distance)

    ~H"""
    <div id={"report-trip-steps-#{dom_token(@pair_id)}"} class="overflow-x-auto">
      <table class="w-full text-xs">
        <thead>
          <tr class="text-left text-base-content/55">
            <th class="pb-1 font-medium">Step</th>
            <th class="pb-1 font-medium">Mode</th>
            <th class="pb-1 font-medium">Stop</th>
            <th class="pb-1 font-medium">Instruction</th>
            <th class="pb-1 font-medium">Time</th>
            <th class="pb-1 font-medium">Distance</th>
            <th class="pb-1 font-medium">Share</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{hop, idx} <- Enum.with_index(@segments, 1)} class="border-t border-base-200">
            <td class="py-1 font-mono">{idx}</td>
            <td class="py-1">
              <span class={["badge badge-xs text-white", mode_color_class(hop.pathway_mode)]}>
                {hop.pathway_mode_label || "Unknown"}
              </span>
            </td>
            <td class="py-1">
              <span class="font-mono">{hop.stop_id}</span>
            </td>
            <td class="py-1 text-base-content/65">
              {hop.display_signposted_as || "-"}
            </td>
            <td class="py-1 font-mono">{format_seconds(hop.time_seconds)}</td>
            <td class="py-1 font-mono">{format_meters(hop.distance_meters)}</td>
            <td class="py-1 font-mono">
              {distance_share(hop.distance_meters, @total_distance)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :pair_id, :string, required: true
  attr :hops, :list, required: true

  defp vertical_profile_svg(assigns) do
    points = profile_points(assigns.hops)

    unique_levels =
      points |> Enum.map(& &1.level_index) |> Enum.filter(&is_number/1) |> Enum.uniq()

    assigns = assign(assigns, :points, points) |> assign(:unique_levels, unique_levels)

    ~H"""
    <div id={"report-trip-profile-#{dom_token(@pair_id)}"}>
      <%= if length(@unique_levels) < 2 do %>
        <p class="text-xs text-base-content/60">
          Vertical profile not available for a single level path.
        </p>
      <% else %>
        <svg viewBox="0 0 420 120" class="w-full rounded-md border border-base-content/15 bg-base-50">
          <line x1="20" y1="100" x2="400" y2="100" stroke="currentColor" opacity="0.25" />
          <line x1="20" y1="15" x2="20" y2="100" stroke="currentColor" opacity="0.25" />
          <line
            :for={{from, to} <- Enum.zip(@points, Enum.drop(@points, 1))}
            x1={from.x}
            y1={from.y}
            x2={to.x}
            y2={to.y}
            stroke="#0f766e"
            stroke-width="2"
            stroke-dasharray={if(from.level_index != to.level_index, do: "4 3", else: "none")}
          />
          <circle
            :for={point <- @points}
            cx={point.x}
            cy={point.y}
            r="2.5"
            fill="#0f766e"
          />
        </svg>
      <% end %>
    </div>
    """
  end

  attr :pair_id, :string, required: true
  attr :hops, :list, required: true
  attr :totals, :map, required: true

  defp analysis_cards(assigns) do
    segments = Enum.drop(assigns.hops, 1)
    segment_count = max(length(segments), 1)
    signposted_segments = Enum.count(segments, &present_signage?/1)
    signage_pct = Float.round(signposted_segments * 100.0 / segment_count, 1)
    method_breakdown = Enum.frequencies_by(segments, &(&1.calculation_method || :unknown))

    efficiency =
      cond do
        not is_number(assigns.totals.effective_speed) -> "Unknown"
        assigns.totals.effective_speed >= 1.33 -> "At or above baseline"
        true -> "Below baseline"
      end

    assigns =
      assigns
      |> assign(:signage_pct, signage_pct)
      |> assign(:method_breakdown, method_breakdown)
      |> assign(:efficiency, efficiency)

    ~H"""
    <div id={"report-trip-analysis-#{dom_token(@pair_id)}"} class="grid gap-2 md:grid-cols-4 text-xs">
      <div class="rounded-md border border-base-content/15 px-2 py-2">
        <p class="text-base-content/55">Wayfinding</p>
        <p class="font-mono">{@signage_pct}% signposted</p>
      </div>
      <div class="rounded-md border border-base-content/15 px-2 py-2">
        <p class="text-base-content/55">Accessibility</p>
        <p class="font-mono">
          stairs={bool_flag(@totals.has_stairs)} esc={bool_flag(@totals.has_escalator)} elev={bool_flag(
            @totals.has_elevator
          )}
        </p>
      </div>
      <div class="rounded-md border border-base-content/15 px-2 py-2">
        <p class="text-base-content/55">Efficiency</p>
        <p class="font-mono">{@efficiency}</p>
      </div>
      <div class="rounded-md border border-base-content/15 px-2 py-2">
        <p class="text-base-content/55">Data completeness</p>
        <p class="font-mono truncate" title={inspect(@method_breakdown)}>
          {Enum.map_join(@method_breakdown, ", ", fn {method, count} -> "#{method}:#{count}" end)}
        </p>
      </div>
    </div>
    """
  end

  defp display_path(nil, _reversed?), do: []

  defp display_path(%{hops: hops}, false) do
    Enum.map(hops, &Map.put(&1, :display_signposted_as, signage_for_display(&1)))
  end

  defp display_path(%{hops: hops}, true) do
    case Enum.reverse(hops) do
      [] ->
        []

      [start_hop | rest] ->
        {rebuilt, _last_source} =
          Enum.map_reduce(rest, start_hop, fn hop, source_segment_hop ->
            rebuilt_hop =
              hop
              |> Map.put(:pathway_id, source_segment_hop.pathway_id)
              |> Map.put(:pathway_mode, source_segment_hop.pathway_mode)
              |> Map.put(:pathway_mode_label, source_segment_hop.pathway_mode_label)
              |> Map.put(:is_bidirectional, source_segment_hop.is_bidirectional)
              |> Map.put(:traversed_reverse?, reverse_traversal(source_segment_hop))
              |> Map.put(:signposted_as, source_segment_hop.signposted_as)
              |> Map.put(:reversed_signposted_as, source_segment_hop.reversed_signposted_as)
              |> Map.put(:level_diff, source_segment_hop.level_diff)
              |> Map.put(:time_seconds, source_segment_hop.time_seconds)
              |> Map.put(:distance_meters, source_segment_hop.distance_meters)
              |> Map.put(:calculation_method, source_segment_hop.calculation_method)
              |> Map.put(:display_signposted_as, nil)

            rebuilt_hop =
              Map.put(rebuilt_hop, :display_signposted_as, signage_for_display(rebuilt_hop))

            {rebuilt_hop, hop}
          end)

        [origin_display_hop(start_hop) | rebuilt]
    end
  end

  defp origin_display_hop(hop) do
    hop
    |> Map.put(:pathway_id, nil)
    |> Map.put(:pathway_mode, nil)
    |> Map.put(:pathway_mode_label, nil)
    |> Map.put(:is_bidirectional, nil)
    |> Map.put(:traversed_reverse?, nil)
    |> Map.put(:signposted_as, nil)
    |> Map.put(:reversed_signposted_as, nil)
    |> Map.put(:level_diff, nil)
    |> Map.put(:time_seconds, 0.0)
    |> Map.put(:distance_meters, nil)
    |> Map.put(:calculation_method, :origin)
    |> Map.put(:display_signposted_as, nil)
  end

  defp signage_for_display(%{pathway_id: pathway_id}) when pathway_id in [nil, ""], do: nil

  defp signage_for_display(%{traversed_reverse?: true, is_bidirectional: true} = hop) do
    normalize_signage_for_display(hop.reversed_signposted_as) ||
      normalize_signage_for_display(hop.signposted_as)
  end

  defp signage_for_display(hop) do
    normalize_signage_for_display(hop.signposted_as)
  end

  defp normalize_signage_for_display(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_signage_for_display(value), do: value

  defp present_signage?(hop) do
    hop
    |> Map.get(:display_signposted_as)
    |> case do
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end
  end

  defp reverse_traversal(%{traversed_reverse?: traversed_reverse?})
       when is_boolean(traversed_reverse?) do
    not traversed_reverse?
  end

  defp reverse_traversal(_), do: nil

  defp pair_id(detail) do
    "#{detail.entrance_stop_id}::#{detail.platform_stop_id}"
  end

  defp segment_widths([], _total_distance), do: []

  defp segment_widths(segments, total_distance)
       when is_number(total_distance) and total_distance > 0 do
    Enum.map(segments, fn segment ->
      distance = if is_number(segment.distance_meters), do: segment.distance_meters, else: 0.0
      distance * 100.0 / total_distance
    end)
  end

  defp segment_widths(segments, _total_distance) do
    equal = 100.0 / max(length(segments), 1)
    Enum.map(segments, fn _ -> equal end)
  end

  defp mode_color_class(1), do: "bg-sky-500"
  defp mode_color_class(2), do: "bg-amber-500"
  defp mode_color_class(3), do: "bg-cyan-500"
  defp mode_color_class(4), do: "bg-fuchsia-500"
  defp mode_color_class(5), do: "bg-emerald-600"
  defp mode_color_class(6), do: "bg-zinc-500"
  defp mode_color_class(7), do: "bg-rose-500"
  defp mode_color_class(_), do: "bg-base-content/35"

  defp profile_points(hops) do
    {points, _, max_distance, min_level, max_level} =
      Enum.reduce(hops, {[], 0.0, 0.0, nil, nil}, fn hop,
                                                     {acc, cum_dist, max_dist, min_lvl, max_lvl} ->
        new_cum_dist =
          cum_dist + if(is_number(hop.distance_meters), do: hop.distance_meters, else: 0.0)

        min_level = min_level(min_lvl, hop.level_index)
        max_level = max_level(max_lvl, hop.level_index)

        {
          acc ++ [%{cum_distance: new_cum_dist, level_index: hop.level_index}],
          new_cum_dist,
          max(max_dist, new_cum_dist),
          min_level,
          max_level
        }
      end)

    Enum.map(points, fn point ->
      x = 20.0 + scale(point.cum_distance, 0.0, max_distance, 380.0)
      y = 100.0 - scale(point.level_index || 0.0, min_level || 0.0, max_level || 0.0, 85.0)
      %{x: x, y: y, level_index: point.level_index}
    end)
  end

  defp min_level(nil, value) when is_number(value), do: value

  defp min_level(current, value) when is_number(current) and is_number(value),
    do: min(current, value)

  defp min_level(current, _), do: current

  defp max_level(nil, value) when is_number(value), do: value

  defp max_level(current, value) when is_number(current) and is_number(value),
    do: max(current, value)

  defp max_level(current, _), do: current

  defp scale(_value, min_value, max_value, _output_range) when min_value == max_value, do: 0.0

  defp scale(value, min_value, max_value, output_range) when is_number(value) do
    (value - min_value) * output_range / (max_value - min_value)
  end

  defp scale(_value, _min_value, _max_value, _output_range), do: 0.0

  defp format_seconds(value) when is_number(value), do: "#{Float.round(value, 1)}s"
  defp format_seconds(_), do: "-"

  defp format_meters(value) when is_number(value), do: "#{Float.round(value, 1)}m"
  defp format_meters(_), do: "-"

  defp format_speed(value) when is_number(value), do: "#{Float.round(value, 2)} m/s"
  defp format_speed(_), do: "-"

  defp distance_share(distance, total_distance)
       when is_number(distance) and is_number(total_distance) and total_distance > 0 do
    "#{Float.round(distance * 100.0 / total_distance, 1)}%"
  end

  defp distance_share(_distance, _total_distance), do: "-"

  defp bool_flag(true), do: "yes"
  defp bool_flag(false), do: "no"

  # ============================================================================
  # Naming Conventions section
  # ============================================================================

  attr :section, :map, required: true
  attr :gtfs_version_id, :string, default: nil
  attr :station_stop_id, :string, default: nil

  def naming_conventions_section(assigns) do
    ~H"""
    <section
      :if={@section}
      id="report-section-naming_conventions"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3">
        <h2 class="text-base font-semibold">{@section.title}</h2>
      </header>
      <div class="divide-y divide-base-content/10">
        <.check_row
          :for={item <- @section.items}
          item={item}
          gtfs_version_id={@gtfs_version_id}
          station_stop_id={@station_stop_id}
        />
      </div>
    </section>
    """
  end

  # ============================================================================
  # Pathway Validation section
  # ============================================================================

  attr :section, :map, required: true
  attr :gtfs_version_id, :string, default: nil
  attr :station_stop_id, :string, default: nil

  def pathway_validation_section(assigns) do
    ~H"""
    <section
      :if={@section}
      id="report-section-pathway_validation"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3">
        <h2 class="text-base font-semibold">{@section.title}</h2>
      </header>
      <div class="divide-y divide-base-content/10">
        <.check_row
          :for={item <- @section.items}
          item={item}
          gtfs_version_id={@gtfs_version_id}
          station_stop_id={@station_stop_id}
        />
      </div>
    </section>
    """
  end

  # ============================================================================
  # Levels Validation section
  # ============================================================================

  attr :section, :map, required: true
  attr :gtfs_version_id, :string, default: nil
  attr :station_stop_id, :string, default: nil

  def levels_validation_section(assigns) do
    ~H"""
    <section
      :if={@section}
      id="report-section-levels_validation"
      class="rounded-xl border border-base-content/20 bg-base-100"
    >
      <header class="border-b border-base-content/20 px-4 py-3">
        <h2 class="text-base font-semibold">{@section.title}</h2>
      </header>
      <div class="divide-y divide-base-content/10">
        <.check_row
          :for={item <- @section.items}
          item={item}
          gtfs_version_id={@gtfs_version_id}
          station_stop_id={@station_stop_id}
        />
      </div>
    </section>
    """
  end

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
        item_id: "entrance_to_platform_connectivity",
        reporting_unit: "reachable/unreachable counts + per-entrance detail",
        methodology:
          "Run directed reachability from each entrance to any platform (or boarding area under it) using BFS over directed pathway edges."
      },
      %{
        item_id: "platform_interconnection",
        reporting_unit: "connected/disconnected counts + per-platform detail",
        methodology:
          "For each platform, run directed reachability from the platform (or its boarding areas) to at least one other platform in the same graph."
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
        reporting_unit: "connected_pairs/total_pairs + entrance x platform matrix",
        methodology:
          "Build directed adjacency using only pathway modes 1, 3, 5, 6, and 7; evaluate reachability for each entrance-platform pair (targeting platforms and boarding areas under them)."
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
        reporting_unit: "connected_pairs/total_pairs + pair matrix + dual hop paths",
        methodology:
          "Build directed adjacency from all station pathways and a step-free subset, then run multi-target BFS for each entrance-platform pair. Report both default and accessible (step-free) paths with hop-by-hop pathway metadata."
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

  # ============================================================================
  # Entity drawer
  # ============================================================================

  attr :drawer_entity, :any, default: nil
  attr :drawer_type, :atom, default: nil
  attr :drawer_form, :any, default: nil
  attr :drawer_error, :string, default: nil

  def entity_drawer(assigns) do
    ~H"""
    <.drawer
      id="report-entity-drawer"
      open={@drawer_entity != nil}
      on_close="close_entity_drawer"
      title={drawer_title(@drawer_type, @drawer_entity)}
    >
      <div :if={@drawer_error} class="mb-4 text-sm text-error">{@drawer_error}</div>

      <.stop_drawer_form
        :if={@drawer_type == :stop && @drawer_entity && @drawer_form}
        entity={@drawer_entity}
        form={@drawer_form}
      />

      <.pathway_drawer_form
        :if={@drawer_type == :pathway && @drawer_entity && @drawer_form}
        entity={@drawer_entity}
        form={@drawer_form}
      />
    </.drawer>
    """
  end

  defp drawer_title(:stop, %{stop_id: stop_id}), do: stop_id
  defp drawer_title(:pathway, %{pathway_id: pathway_id}), do: pathway_id
  defp drawer_title(_, _), do: ""

  attr :entity, :map, required: true
  attr :form, :any, required: true

  defp stop_drawer_form(assigns) do
    ~H"""
    <div class="space-y-4">
      <dl class="space-y-2 text-sm">
        <div class="flex justify-between">
          <dt class="text-base-content/60">stop_id</dt>
          <dd class="font-mono">{@entity.stop_id}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">location_type</dt>
          <dd class="font-mono">
            {@entity.location_type} — {Stop.location_type_label(@entity.location_type)}
          </dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">parent_station</dt>
          <dd class="font-mono">{@entity.parent_station || "—"}</dd>
        </div>
      </dl>

      <.form
        for={@form}
        id="report-stop-edit-form"
        phx-submit="save_entity"
        as={:stop}
        class="space-y-3"
      >
        <.input field={@form[:stop_name]} label="stop_name" type="text" />
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:stop_lat]} label="stop_lat" type="text" />
          <.input field={@form[:stop_lon]} label="stop_lon" type="text" />
        </div>
        <.input field={@form[:level_id]} label="level_id" type="text" />
        <.input
          field={@form[:wheelchair_boarding]}
          label="wheelchair_boarding"
          type="select"
          options={[
            {"", ""},
            {"0 — No info", "0"},
            {"1 — Accessible", "1"},
            {"2 — Not accessible", "2"}
          ]}
        />
        <.input field={@form[:platform_code]} label="platform_code" type="text" />
        <button type="submit" class="btn btn-primary btn-sm w-full">Save changes</button>
      </.form>
    </div>
    """
  end

  attr :entity, :map, required: true
  attr :form, :any, required: true

  defp pathway_drawer_form(assigns) do
    ~H"""
    <div class="space-y-4">
      <dl class="space-y-2 text-sm">
        <div class="flex justify-between">
          <dt class="text-base-content/60">pathway_id</dt>
          <dd class="font-mono">{@entity.pathway_id}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">pathway_mode</dt>
          <dd class="font-mono">
            {@entity.pathway_mode} — {Pathway.mode_label(@entity.pathway_mode)}
          </dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">from_stop_id</dt>
          <dd class="font-mono">{@entity.from_stop_id}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">to_stop_id</dt>
          <dd class="font-mono">{@entity.to_stop_id}</dd>
        </div>
      </dl>

      <.form
        for={@form}
        id="report-pathway-edit-form"
        phx-submit="save_entity"
        as={:pathway}
        class="space-y-3"
      >
        <.input field={@form[:traversal_time]} label="traversal_time (seconds)" type="number" />
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:length]} label="length (meters)" type="text" />
          <.input field={@form[:min_width]} label="min_width (meters)" type="text" />
        </div>
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:stair_count]} label="stair_count" type="number" />
          <.input field={@form[:max_slope]} label="max_slope" type="text" />
        </div>
        <.input
          field={@form[:is_bidirectional]}
          label="is_bidirectional"
          type="select"
          options={[{"Yes", "true"}, {"No", "false"}]}
        />
        <.input field={@form[:signposted_as]} label="signposted_as" type="text" />
        <.input field={@form[:reversed_signposted_as]} label="reversed_signposted_as" type="text" />
        <button type="submit" class="btn btn-primary btn-sm w-full">Save changes</button>
      </.form>
    </div>
    """
  end
end
