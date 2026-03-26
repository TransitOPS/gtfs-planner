defmodule GtfsPlannerWeb.Gtfs.StationReport2Components do
  @moduledoc """
  Function components for the station report 2 dashboard.
  Each section is an independent placeholder awaiting implementation.
  """
  use Phoenix.Component

  @max_visible 5

  attr :report, :map, default: nil

  def station_inventory_section(assigns) do
    ~H"""
    <section id="report2-station-inventory">
      <h2 class="text-lg font-semibold">Station Inventory</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :items, :list, required: true
  attr :gtfs_version_id, :any, required: true

  def data_quality_section(assigns) do
    ~H"""
    <section id="report2-data-quality">
      <div class="flex items-baseline justify-between mb-3 px-1">
        <h2 class="text-xl font-semibold text-gray-900" style="line-height: 1.375;">Data Quality</h2>
      </div>
      <div class="bg-white border border-gray-400 rounded-lg shadow-card overflow-hidden">
        <div class="divide-y divide-gray-200">
          <.report_check_row
            :for={item <- @items}
            item={item}
            gtfs_version_id={@gtfs_version_id}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :items, :list, required: true
  attr :gtfs_version_id, :any, required: true

  def gps_checks_section(assigns) do
    ~H"""
    <section id="report2-gps-checks">
      <div class="flex items-baseline justify-between mb-3 px-1">
        <h2 class="text-xl font-semibold text-gray-900" style="line-height: 1.375;">GPS</h2>
      </div>
      <div class="bg-white border border-gray-400 rounded-lg shadow-card overflow-hidden">
        <div class="divide-y divide-gray-200">
          <.report_check_row
            :for={item <- @items}
            item={item}
            gtfs_version_id={@gtfs_version_id}
          />
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
  attr :gtfs_version_id, :any, required: true

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
          <.check_details
            :if={@item.detail_layout != nil}
            item={@item}
            gtfs_version_id={@gtfs_version_id}
          />
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
  attr :gtfs_version_id, :any, required: true

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
    assigns =
      assigns
      |> assign(:visible, Enum.take(details, @max_visible))
      |> assign(:overflow, Enum.drop(details, @max_visible))

    ~H"""
    <details class="mt-2.5">
      <summary class="inline-flex items-center gap-1 text-xs font-medium text-teal-600 hover:text-teal-700" style="transition-duration: 15ms;">
        <svg class="chevron w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path d="M9 5l7 7-7 7"/></svg>
        <%= @item.detail_label %>
      </summary>
      <div class="mt-2 grid grid-cols-1 gap-0.5">
        <.stop_id_link :for={stop_id <- @visible} stop_id={stop_id} gtfs_version_id={@gtfs_version_id} />
        <.overflow_stop_ids :if={@overflow != []} overflow={@overflow} gtfs_version_id={@gtfs_version_id} />
      </div>
    </details>
    """
  end

  defp check_details(%{item: %{detail_layout: :stop_ids_with_dots, details: details}} = assigns)
       when is_list(details) and details != [] do
    assigns =
      assigns
      |> assign(:visible, Enum.take(details, @max_visible))
      |> assign(:overflow, Enum.drop(details, @max_visible))

    ~H"""
    <details class="mt-2.5">
      <summary class="inline-flex items-center gap-1 text-xs font-medium text-teal-600 hover:text-teal-700" style="transition-duration: 15ms;">
        <svg class="chevron w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path d="M9 5l7 7-7 7"/></svg>
        <%= @item.detail_label %>
      </summary>
      <div class="mt-2 grid grid-cols-1 gap-1">
        <div :for={stop_id <- @visible} class="flex items-center gap-2">
          <span class="w-1.5 h-1.5 rounded-full bg-red-500 shrink-0"></span>
          <.stop_id_link_inline stop_id={stop_id} gtfs_version_id={@gtfs_version_id} />
        </div>
        <.overflow_stop_ids_with_dots :if={@overflow != []} overflow={@overflow} gtfs_version_id={@gtfs_version_id} />
      </div>
    </details>
    """
  end

  defp check_details(%{item: %{detail_layout: :stop_ids_with_reasons, details: details}} = assigns)
       when is_list(details) and details != [] do
    assigns =
      assigns
      |> assign(:visible, Enum.take(details, @max_visible))
      |> assign(:overflow, Enum.drop(details, @max_visible))

    ~H"""
    <details class="mt-2.5">
      <summary class="inline-flex items-center gap-1 text-xs font-medium text-teal-600 hover:text-teal-700" style="transition-duration: 15ms;">
        <svg class="chevron w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path d="M9 5l7 7-7 7"/></svg>
        <%= @item.detail_label %>
      </summary>
      <div class="mt-2 grid grid-cols-1 gap-1.5">
        <div :for={entry <- @visible} class="flex items-baseline gap-3">
          <.stop_id_link stop_id={entry.id} gtfs_version_id={@gtfs_version_id} class="shrink-0" />
          <span class="text-xs text-gray-500"><%= entry.reason %></span>
        </div>
        <.overflow_stop_ids_with_reasons :if={@overflow != []} overflow={@overflow} gtfs_version_id={@gtfs_version_id} />
      </div>
    </details>
    """
  end

  defp check_details(assigns) do
    ~H""
  end

  # --- Stop ID link helpers ---

  attr :stop_id, :string, required: true
  attr :gtfs_version_id, :any, required: true
  attr :class, :string, default: ""

  defp stop_id_link(assigns) do
    ~H"""
    <.link
      navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}/report_2"}
      class={"text-xs text-teal-600 hover:text-teal-700 cursor-pointer #{@class}"}
      style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;"
    >
      <%= @stop_id %>
    </.link>
    """
  end

  attr :stop_id, :string, required: true
  attr :gtfs_version_id, :any, required: true

  defp stop_id_link_inline(assigns) do
    ~H"""
    <.link
      navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}/report_2"}
      class="text-xs text-gray-700 hover:text-teal-700 cursor-pointer"
      style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;"
    >
      <%= @stop_id %>
    </.link>
    """
  end

  # --- Overflow (+ N more) helpers ---

  attr :overflow, :list, required: true
  attr :gtfs_version_id, :any, required: true

  defp overflow_stop_ids(assigns) do
    ~H"""
    <details>
      <summary class="text-xs text-gray-500 cursor-pointer mt-1" style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;">
        + <%= length(@overflow) %> more
      </summary>
      <div class="grid grid-cols-1 gap-0.5 mt-0.5">
        <.stop_id_link :for={stop_id <- @overflow} stop_id={stop_id} gtfs_version_id={@gtfs_version_id} />
      </div>
    </details>
    """
  end

  attr :overflow, :list, required: true
  attr :gtfs_version_id, :any, required: true

  defp overflow_stop_ids_with_dots(assigns) do
    ~H"""
    <details>
      <summary class="text-xs text-gray-500 cursor-pointer mt-1" style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;">
        + <%= length(@overflow) %> more
      </summary>
      <div class="grid grid-cols-1 gap-1 mt-0.5">
        <div :for={stop_id <- @overflow} class="flex items-center gap-2">
          <span class="w-1.5 h-1.5 rounded-full bg-red-500 shrink-0"></span>
          <.stop_id_link_inline stop_id={stop_id} gtfs_version_id={@gtfs_version_id} />
        </div>
      </div>
    </details>
    """
  end

  attr :overflow, :list, required: true
  attr :gtfs_version_id, :any, required: true

  defp overflow_stop_ids_with_reasons(assigns) do
    ~H"""
    <details>
      <summary class="text-xs text-gray-500 cursor-pointer mt-1" style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;">
        + <%= length(@overflow) %> more
      </summary>
      <div class="grid grid-cols-1 gap-1.5 mt-0.5">
        <div :for={entry <- @overflow} class="flex items-baseline gap-3">
          <.stop_id_link stop_id={entry.id} gtfs_version_id={@gtfs_version_id} class="shrink-0" />
          <span class="text-xs text-gray-500"><%= entry.reason %></span>
        </div>
      </div>
    </details>
    """
  end

  defp text_class_for_status(:fail), do: "text-red-700"
  defp text_class_for_status(:pass), do: "text-green-800"
  defp text_class_for_status(:warn), do: "text-yellow-800"
  defp text_class_for_status(_), do: "text-gray-700"
end
