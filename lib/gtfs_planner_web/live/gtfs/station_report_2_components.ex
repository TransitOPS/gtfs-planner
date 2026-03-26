defmodule GtfsPlannerWeb.Gtfs.StationReport2Components do
  @moduledoc """
  Function components for the station report 2 dashboard.
  Each section is an independent placeholder awaiting implementation.
  """
  use Phoenix.Component

  alias GtfsPlanner.Gtfs.{Stop, Pathway}

  attr :report, :map, default: nil

  def station_inventory_section(assigns) do
    inventory = compute_inventory(assigns.report)
    assigns = assign(assigns, :inventory, inventory)

    ~H"""
    <section id="report2-station-inventory">
      <h2 class="text-2xl font-bold text-gray-900 mb-6">Station Inventory</h2>

      <%!-- Node inventory by location type --%>
      <div class="mb-6">
        <div class="bg-white border border-gray-400 rounded-lg shadow-sm overflow-hidden">
          <div class="bg-gray-50 border-b border-gray-400 px-5 py-3">
            <h2 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Node inventory by location type</h2>
          </div>
          <div class="p-5">
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-4">
              <.stat_card :for={item <- @inventory.node_counts} count={item.count} label={item.label} />
            </div>
          </div>
        </div>
      </div>

      <%!-- Edge inventory by pathway mode --%>
      <div class="mb-6">
        <div class="bg-white border border-gray-400 rounded-lg shadow-sm overflow-hidden">
          <div class="bg-gray-50 border-b border-gray-400 px-5 py-3">
            <h2 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Edge inventory by pathway mode</h2>
          </div>
          <div class="p-5">
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
              <.stat_card :for={item <- @inventory.edge_counts} count={item.count} label={item.label} />
            </div>
          </div>
        </div>
      </div>

      <%!-- Pathway directionality --%>
      <div class="mb-6">
        <div class="bg-white border border-gray-400 rounded-lg shadow-sm overflow-hidden">
          <div class="bg-gray-50 border-b border-gray-400 px-5 py-3">
            <h2 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Pathway directionality</h2>
          </div>
          <div class="p-5">
            <div class="grid grid-cols-2 gap-4" style="max-width: 400px;">
              <.stat_card count={@inventory.directionality.bidirectional} label="Bidirectional" />
              <.stat_card count={@inventory.directionality.unidirectional} label="Unidirectional" />
            </div>
          </div>
        </div>
      </div>

      <%!-- Level count, names, and indices --%>
      <div class="mb-6">
        <div class="bg-white border border-gray-400 rounded-lg shadow-sm overflow-hidden">
          <div class="bg-gray-50 border-b border-gray-400 px-5 py-3">
            <h2 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Level count, names, and indices</h2>
          </div>
          <div class="overflow-x-auto">
            <table class="w-full text-sm text-left">
              <thead>
                <tr class="border-b border-gray-200">
                  <th class="px-5 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Level</th>
                  <th class="px-5 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">Name</th>
                  <th class="px-5 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wider text-right">Index</th>
                  <th class="px-5 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wider text-right">Nodes</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200">
                <tr :for={level <- @inventory.levels}>
                  <td class="px-5 py-3.5 text-sm text-gray-900 font-mono text-[13px]">
                    {level.level_id}
                  </td>
                  <td class="px-5 py-3.5 text-sm text-gray-900">{level.level_name || "—"}</td>
                  <td class="px-5 py-3.5 text-sm text-gray-900 text-right tabular-nums">
                    {format_level_index(level.level_index)}
                  </td>
                  <td class="px-5 py-3.5 text-sm font-medium text-gray-900 text-right tabular-nums">
                    {level.node_count}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :count, :integer, required: true
  attr :label, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-lg bg-gray-50 border border-gray-200 px-4 py-4">
      <div class="text-2xl font-semibold text-gray-900 leading-tight">{@count}</div>
      <p class="mt-1 text-sm font-medium text-gray-500">{@label}</p>
    </div>
    """
  end

  defp compute_inventory(snapshot) do
    all_stops = [snapshot.station | snapshot.child_stops]
    node_count_map = Enum.frequencies_by(all_stops, & &1.location_type)

    node_counts =
      Enum.map(0..4, fn type ->
        %{label: Stop.location_type_label(type), count: Map.get(node_count_map, type, 0)}
      end)

    edge_count_map = Enum.frequencies_by(snapshot.pathways, & &1.pathway_mode)

    edge_counts =
      Enum.map(1..7, fn mode ->
        %{label: Pathway.mode_label(mode), count: Map.get(edge_count_map, mode, 0)}
      end)

    {bi, uni} =
      Enum.reduce(snapshot.pathways, {0, 0}, fn pathway, {bi, uni} ->
        if pathway.is_bidirectional, do: {bi + 1, uni}, else: {bi, uni + 1}
      end)

    levels =
      Enum.map(snapshot.levels, fn %{level: level, stop_count: stop_count} ->
        %{
          level_id: level.level_id,
          level_name: level.level_name,
          level_index: level.level_index,
          node_count: stop_count
        }
      end)

    %{
      node_counts: node_counts,
      edge_counts: edge_counts,
      directionality: %{bidirectional: bi, unidirectional: uni},
      levels: levels
    }
  end

  defp format_level_index(index) when is_float(index) do
    formatted = :erlang.float_to_binary(abs(index), decimals: 1)

    if index < 0 do
      # Use typographic minus (−) not hyphen-minus (-)
      "−" <> formatted
    else
      formatted
    end
  end


  attr :items, :list, required: true

  def data_quality_section(assigns) do
    ~H"""
    <section id="report2-data-quality">
      <div class="flex items-baseline justify-between mb-3 px-1">
        <h2 class="text-xl font-semibold text-gray-900" style="line-height: 1.375;">Data Quality</h2>
      </div>
      <div class="bg-white border border-gray-400 rounded-lg shadow-card overflow-hidden">
        <div class="divide-y divide-gray-200">
          <.report_check_row :for={item <- @items} item={item} />
        </div>
      </div>
    </section>
    """
  end

  attr :items, :list, required: true

  def gps_checks_section(assigns) do
    ~H"""
    <section id="report2-gps-checks">
      <div class="flex items-baseline justify-between mb-3 px-1">
        <h2 class="text-xl font-semibold text-gray-900" style="line-height: 1.375;">GPS</h2>
      </div>
      <div class="bg-white border border-gray-400 rounded-lg shadow-card overflow-hidden">
        <div class="divide-y divide-gray-200">
          <.report_check_row :for={item <- @items} item={item} />
        </div>
      </div>
    </section>
    """
  end

  attr :report, :map, default: nil

  def naming_conventions_section(assigns) do
    ~H"""
    <section id="report2-naming-conventions">
      <h2 class="text-lg font-semibold">Naming Conventions</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def reachability_connectivity_section(assigns) do
    ~H"""
    <section id="report2-reachability-connectivity">
      <h2 class="text-lg font-semibold">Reachability & Connectivity</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def pathway_field_completeness_section(assigns) do
    ~H"""
    <section id="report2-pathway-field-completeness">
      <h2 class="text-lg font-semibold">Pathway Field Completeness</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def accessibility_section(assigns) do
    ~H"""
    <section id="report2-accessibility">
      <h2 class="text-lg font-semibold">Accessibility</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  # --- Private components ---

  attr :item, :map, required: true

  defp report_check_row(assigns) do
    ~H"""
    <div class="px-5 py-4">
      <div class="flex items-start gap-3">
        <.status_badge status={@item.status} />
        <div class="flex-1 min-w-0">
          <div class="flex items-baseline justify-between gap-4">
            <p class="text-sm font-medium text-gray-900"><%= @item.label %></p>
            <.check_value item={@item} />
          </div>
          <p class="text-xs text-gray-500 mt-0.5"><%= @item.description %></p>
          <.check_details :if={@item.detail_layout != nil} item={@item} />
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(%{status: :fail} = assigns) do
    ~H"""
    <span class="inline-flex items-center justify-center gap-1.5 w-[76px] shrink-0 px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wider bg-red-100 text-red-800">
      <span class="w-1.5 h-1.5 rounded-full bg-red-600 shrink-0"></span>
      Fail
    </span>
    """
  end

  defp status_badge(%{status: :pass} = assigns) do
    ~H"""
    <span class="inline-flex items-center justify-center gap-1.5 w-[76px] shrink-0 px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wider bg-green-100 text-green-800">
      <span class="w-1.5 h-1.5 rounded-full bg-green-600 shrink-0"></span>
      Pass
    </span>
    """
  end

  defp status_badge(%{status: :warn} = assigns) do
    ~H"""
    <span class="inline-flex items-center justify-center gap-1.5 w-[76px] shrink-0 px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wider bg-yellow-100 text-yellow-800">
      <span class="w-1.5 h-1.5 rounded-full bg-yellow-600 shrink-0"></span>
      Warning
    </span>
    """
  end

  defp status_badge(%{status: :info} = assigns) do
    ~H"""
    <span class="inline-flex items-center justify-center w-[76px] shrink-0 px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wider bg-gray-100 text-gray-700">
      Info
    </span>
    """
  end

  attr :item, :map, required: true

  defp check_value(%{item: %{value_format: :count, value: nil}} = assigns) do
    ~H""
  end

  defp check_value(%{item: %{value_format: :count, status: status, value: value}} = assigns)
       when status in [:pass, :info] and (value == 0 or value == nil) do
    ~H"""
    <span class="text-sm text-gray-500 shrink-0" style="font-variant-numeric: tabular-nums;">
      <%= @item.value %>
    </span>
    """
  end

  defp check_value(%{item: %{value_format: :count}} = assigns) do
    ~H"""
    <span class="text-sm text-gray-900 font-medium shrink-0" style="font-variant-numeric: tabular-nums;">
      <%= @item.value %>
    </span>
    """
  end

  defp check_value(%{item: %{value_format: :boolean, value: true}} = assigns) do
    ~H"""
    <span class="text-sm text-green-800 font-medium shrink-0">Yes</span>
    """
  end

  defp check_value(%{item: %{value_format: :boolean, value: false}} = assigns) do
    ~H"""
    <span class="text-sm text-red-700 font-medium shrink-0">No</span>
    """
  end

  defp check_value(%{item: %{value_format: :text}} = assigns) do
    assigns = assign(assigns, :text_class, text_class_for_status(assigns.item.status))

    ~H"""
    <span class={"text-sm font-medium shrink-0 #{@text_class}"}><%= @item.value %></span>
    """
  end

  defp check_value(%{item: %{value_format: :compound, id: "entrance_to_platform_connectivity"}} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 shrink-0">
      <span :if={@item.value.unreachable > 0} class="text-xs text-red-700 font-medium" style="font-variant-numeric: tabular-nums;">
        <%= @item.value.unreachable %> unreachable
      </span>
      <span :if={@item.value.unreachable > 0} class="text-xs text-gray-500">&middot;</span>
      <span class="text-xs text-gray-500" style="font-variant-numeric: tabular-nums;">
        <%= @item.value.reachable %> reachable
      </span>
    </div>
    """
  end

  defp check_value(%{item: %{value_format: :compound, id: "platform_interconnection"}} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 shrink-0">
      <span :if={@item.value.disconnected > 0} class="text-xs text-red-700 font-medium" style="font-variant-numeric: tabular-nums;">
        <%= @item.value.disconnected %> disconnected
      </span>
      <span :if={@item.value.disconnected > 0} class="text-xs text-gray-500">&middot;</span>
      <span class="text-xs text-gray-500" style="font-variant-numeric: tabular-nums;">
        <%= @item.value.connected %> connected
      </span>
    </div>
    """
  end

  defp check_value(assigns) do
    ~H""
  end

  attr :item, :map, required: true

  defp check_details(%{item: %{detail_layout: :table}} = assigns) do
    ~H"""
    <div class="mt-3 border border-gray-200 rounded-md overflow-hidden">
      <table class="w-full text-sm">
        <thead>
          <tr class="bg-gray-50 text-left text-xs text-gray-500 font-medium">
            <th class="px-3 py-2">Type</th>
            <th class="px-3 py-2 text-right">Present</th>
            <th class="px-3 py-2 text-right">Missing</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <tr :for={row <- @item.details}>
            <td class="px-3 py-2 text-sm text-gray-700"><%= row.type_label %></td>
            <td class={"px-3 py-2 text-sm text-right #{if row.present > 0, do: "text-gray-900 font-medium", else: "text-gray-500"}"} style="font-variant-numeric: tabular-nums;">
              <%= row.present %>
            </td>
            <td class={"px-3 py-2 text-sm text-right #{if row.missing > 0, do: "text-gray-900 font-medium", else: "text-gray-500"}"} style="font-variant-numeric: tabular-nums;">
              <%= row.missing %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp check_details(%{item: %{detail_layout: :stop_ids, details: details}} = assigns)
       when is_list(details) and details != [] do
    ~H"""
    <details class="group mt-2.5">
      <summary class="inline-flex items-center gap-1 text-xs font-medium text-teal-600 hover:text-teal-700 cursor-pointer">
        <svg class="w-3 h-3 transition-transform duration-150 group-open:rotate-90" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path d="M9 5l7 7-7 7"/></svg>
        <%= @item.detail_label %>
      </summary>
      <div class="mt-2 grid grid-cols-1 gap-0.5">
        <.stop_name_link :for={entry <- @item.details} stop_id={entry.id} name={entry.name} />
      </div>
    </details>
    """
  end

  defp check_details(%{item: %{detail_layout: :stop_ids_with_dots, details: details}} = assigns)
       when is_list(details) and details != [] do
    ~H"""
    <details class="group mt-2.5">
      <summary class="inline-flex items-center gap-1 text-xs font-medium text-teal-600 hover:text-teal-700 cursor-pointer">
        <svg class="w-3 h-3 transition-transform duration-150 group-open:rotate-90" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path d="M9 5l7 7-7 7"/></svg>
        <%= @item.detail_label %>
      </summary>
      <div class="mt-2 grid grid-cols-1 gap-1">
        <div :for={entry <- @item.details} class="flex items-center gap-2">
          <span class="w-1.5 h-1.5 rounded-full bg-red-500 shrink-0"></span>
          <.stop_name_link stop_id={entry.id} name={entry.name} />
        </div>
      </div>
    </details>
    """
  end

  defp check_details(%{item: %{detail_layout: :stop_ids_with_reasons, details: details}} = assigns)
       when is_list(details) and details != [] do
    ~H"""
    <details class="group mt-2.5">
      <summary class="inline-flex items-center gap-1 text-xs font-medium text-teal-600 hover:text-teal-700 cursor-pointer">
        <svg class="w-3 h-3 transition-transform duration-150 group-open:rotate-90" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path d="M9 5l7 7-7 7"/></svg>
        <%= @item.detail_label %>
      </summary>
      <div class="mt-2 grid grid-cols-1 gap-1.5">
        <div :for={entry <- @item.details} class="flex items-baseline gap-3">
          <.stop_name_link stop_id={entry.id} name={entry.name} class="shrink-0" />
          <span class="text-xs text-gray-500"><%= entry.reason %></span>
        </div>
      </div>
    </details>
    """
  end

  defp check_details(assigns) do
    ~H""
  end

  attr :stop_id, :string, required: true
  attr :name, :string, required: true
  attr :class, :string, default: ""

  defp stop_name_link(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_entity"
      phx-value-entity_id={@stop_id}
      phx-value-entity_type="stop"
      title={@stop_id}
      class={"text-left text-xs text-teal-600 hover:text-teal-700 cursor-pointer #{@class}"}
    >
      <%= @name %>
    </button>
    """
  end

  defp text_class_for_status(:fail), do: "text-red-700"
  defp text_class_for_status(:pass), do: "text-green-800"
  defp text_class_for_status(:warn), do: "text-yellow-800"
  defp text_class_for_status(_), do: "text-gray-700"
end
