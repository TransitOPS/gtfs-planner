defmodule GtfsPlannerWeb.Gtfs.StationReport2ConnectivityComponents do
  @moduledoc """
  HEEx components for the Route Detail (View 2) and Expanded Route (View 3)
  of the connectivity report.
  """
  use Phoenix.Component

  @mode_colors %{
    "Walkway" => "text-teal-600",
    "Elevator" => "text-amber-600",
    "Stairs" => "text-gray-500",
    "Escalator" => "text-gray-500",
    "Fare Gate" => "text-gray-500",
    "Moving Sidewalk" => "text-teal-600",
    "Exit Gate" => "text-gray-500"
  }

  # ── View 2: Route Detail ──────────────────────────────────────────────────

  attr :dimension, :atom, required: true
  attr :groups, :list, required: true
  attr :expanded_routes, :map, default: %{}

  def connectivity_route_detail(assigns) do
    assigns = assign(assigns, :dimension_label, dimension_label(assigns.dimension))

    ~H"""
    <div>
      <div class="flex items-center justify-between mb-5">
        <div class="flex items-center gap-3">
          <button
            phx-click="navigate_connectivity_summary"
            class="inline-flex items-center gap-1.5 text-sm font-medium text-teal-600 hover:text-teal-700 transition-colors duration-[15ms] cursor-pointer"
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path
                d="M10 3L5 8L10 13"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
            Summary
          </button>
          <span class="text-gray-300">|</span>
          <div>
            <p class="text-[11px] font-semibold text-gray-500 uppercase tracking-widest">
              Connectivity — Route Detail
            </p>
          </div>
        </div>
      </div>

      <div class="h-px bg-gray-300 mb-6"></div>

      <p class="text-sm font-medium text-gray-700 mb-4">{@dimension_label}</p>

      <div class="flex flex-col gap-5">
        <.source_group_card
          :for={group <- @groups}
          group={group}
          dimension={@dimension}
          expanded_routes={@expanded_routes}
        />
      </div>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :dimension, :atom, required: true
  attr :expanded_routes, :map, default: %{}

  def source_group_card(assigns) do
    worst = worst_target_status(assigns.group.targets)
    dot_color = status_dot_color(worst)

    assigns =
      assigns
      |> assign(:dot_color, dot_color)
      |> assign(:dimension_label, dimension_label(assigns.dimension))

    ~H"""
    <div class="bg-white border border-gray-400 rounded-lg overflow-hidden shadow-card">
      <div class="px-5 pt-4 pb-2 flex items-start justify-between">
        <div>
          <div class="flex items-center gap-2.5">
            <span class={"w-2 h-2 rounded-full shrink-0 #{@dot_color}"}></span>
            <h3 class="text-base font-semibold text-gray-900">{@group.source.name}</h3>
            <.level_pill
              :if={@group.source.level_name}
              name={@group.source.level_name}
              index={@group.source.level_index}
            />
          </div>
          <p class="text-xs text-gray-500 font-mono mt-1 ml-[18px]">{@group.source.stop_id}</p>
        </div>
        <span class="text-[11px] font-medium text-gray-500 uppercase tracking-wider mt-0.5">
          {@dimension_label}
        </span>
      </div>

      <div>
        <.target_row
          :for={target <- @group.targets}
          target={target}
          source_id={@group.source.stop_id}
          source_name={@group.source.name}
          expanded_routes={@expanded_routes}
        />
      </div>
    </div>
    """
  end

  attr :target, :map, required: true
  attr :source_id, :string, required: true
  attr :source_name, :string, required: true
  attr :expanded_routes, :map, default: %{}

  defp target_row(assigns) do
    nopath = assigns.target.status == :nopath
    inaccessible = not nopath and assigns.target.accessible == false
    key = {assigns.source_id, assigns.target.stop_id}
    expanded_route = Map.get(assigns.expanded_routes, key)
    expanded = expanded_route != nil
    route_region_id = "route-#{assigns.source_id}-#{assigns.target.stop_id}"

    assigns =
      assigns
      |> assign(:nopath, nopath)
      |> assign(:inaccessible, inaccessible)
      |> assign(:expanded, expanded)
      |> assign(:expanded_route, expanded_route)
      |> assign(:key, key)
      |> assign(:route_region_id, route_region_id)

    ~H"""
    <div class="border-b border-gray-100 last:border-b-0">
      <button
        class="w-full flex items-center justify-between py-3.5 px-4 text-left hover:bg-gray-50 transition-colors duration-[15ms] cursor-pointer"
        phx-click="toggle_route_expand"
        phx-value-source_id={@source_id}
        phx-value-target_id={@target.stop_id}
        aria-expanded={to_string(@expanded)}
        aria-controls={@route_region_id}
      >
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium text-gray-900">{@source_name} → {@target.name}</p>
        </div>

        <div class="flex items-center gap-6 shrink-0 ml-4">
          <div class="text-center min-w-[48px]">
            <p class="text-sm font-semibold text-gray-900 tabular-nums">
              {if @nopath, do: "—", else: "#{format_number(@target.time)}s"}
            </p>
            <p class="text-[10px] text-gray-500 mt-0.5">Time</p>
          </div>
          <div class="text-center min-w-[48px]">
            <p class="text-sm font-semibold text-gray-900 tabular-nums">
              {if @nopath, do: "—", else: "#{format_number(@target.distance)}m"}
            </p>
            <p class="text-[10px] text-gray-500 mt-0.5">Distance</p>
          </div>
          <div class="text-center min-w-[36px]">
            <p class="text-sm font-semibold text-gray-900">
              {cond do
                @nopath -> "—"
                @target.accessible -> "Yes"
                true -> "No"
              end}
            </p>
            <p class="text-[10px] text-gray-500 mt-0.5">Accessible</p>
          </div>
          <div class="min-w-[88px] flex justify-end">
            <.route_badge status={@target.status} />
          </div>
          <svg
            width="18"
            height="18"
            viewBox="0 0 18 18"
            fill="none"
            class={"shrink-0 transition-transform duration-150 #{if @expanded, do: "rotate-180", else: ""}"}
            aria-hidden="true"
          >
            <path
              d="M4.5 6.75L9 11.25L13.5 6.75"
              stroke="#6a7282"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </div>
      </button>

      <%= if @expanded and not @nopath and is_map(@expanded_route) do %>
        <div id={@route_region_id} role="region" class="border-t border-gray-200 bg-gray-50">
          <div class="p-5 border-b border-gray-200">
            <div class="flex items-start justify-between mb-4">
              <p class="text-xs text-gray-500 font-mono">
                {@expanded_route.target.stop_id} · {@expanded_route.target.meta}
              </p>
              <.route_badge status={@expanded_route.status} />
            </div>

            <div :for={w <- @expanded_route.warnings} class="mb-4">
              <.warning_banner message={w} />
            </div>

            <div class="flex items-baseline gap-8 text-sm">
              <div>
                <span class="text-gray-500">Total time </span>
                <span class="font-semibold text-gray-900">
                  {format_number(@expanded_route.time)}s
                </span>
              </div>
              <div>
                <span class="text-gray-500">Distance </span>
                <span class="font-semibold text-gray-900">
                  {format_number(@expanded_route.distance)}m
                </span>
              </div>
              <div>
                <span class="text-gray-500">Level changes </span>
                <span class="font-semibold text-gray-900">{@expanded_route.levels}</span>
                <span :if={@expanded_route.level_path} class="text-gray-500 ml-1">
                  ({@expanded_route.level_path})
                </span>
              </div>
              <div>
                <span class="text-gray-500">Accessible </span>
                <span class="font-semibold text-gray-900">
                  {if @expanded_route.accessible, do: "Yes", else: "No"}
                </span>
                <span :if={@expanded_route.accessible_note} class="text-gray-500 ml-1">
                  — {@expanded_route.accessible_note}
                </span>
              </div>
            </div>
          </div>

          <div class="px-5 py-4">
            <.step_table steps={@expanded_route.steps} />
          </div>
        </div>
      <% end %>

      <%= if @expanded and @nopath do %>
        <div id={@route_region_id} role="region" class="border-t border-gray-200 bg-gray-50 px-5 py-6">
          <div class="flex items-center gap-3 text-sm text-gray-600">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path
                d="M4 4L12 12M12 4L4 12"
                stroke="#dc2626"
                stroke-width="1.8"
                stroke-linecap="round"
              />
            </svg>
            <p>
              No directed path exists between these stops. Check that pathway records connect all intermediate nodes.
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── View 3: Step Table ─────────────────────────────────────────────────────

  attr :steps, :list, required: true

  defp step_table(assigns) do
    grouped = group_steps_by_level(assigns.steps)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <table class="w-full text-sm" style="border-collapse: collapse;">
      <thead>
        <tr class="border-b border-gray-200">
          <th class="text-left py-2 pr-2 text-[11px] font-medium text-gray-500 uppercase tracking-wider w-8">
            #
          </th>
          <th class="text-left py-2 pr-3 text-[11px] font-medium text-gray-500 uppercase tracking-wider w-24">
            Mode
          </th>
          <th class="text-left py-2 pr-3 text-[11px] font-medium text-gray-500 uppercase tracking-wider">
            Stop name
          </th>
          <th class="text-left py-2 pr-3 text-[11px] font-medium text-gray-500 uppercase tracking-wider">
            Instruction
          </th>
          <th class="text-right py-2 pr-3 text-[11px] font-medium text-gray-500 uppercase tracking-wider w-16">
            Time
          </th>
          <th class="text-right py-2 text-[11px] font-medium text-gray-500 uppercase tracking-wider w-14">
            Dist
          </th>
        </tr>
      </thead>
      <tbody>
        <%= for item <- @grouped do %>
          <%= if item.type == :level do %>
            <tr>
              <td
                colspan="6"
                class="pt-4 pb-1.5 text-[11px] font-bold text-gray-900 uppercase tracking-wider"
              >
                {item.name} ({format_level_index(item.index)})
              </td>
            </tr>
          <% else %>
            <tr class="border-b border-gray-100 last:border-b-0">
              <td class="py-2.5 pr-2 text-gray-500 tabular-nums">{item.num}</td>
              <td class="py-2.5 pr-3">
                <span class={"text-sm font-medium #{mode_color(item.mode)}"}>{item.mode || "—"}</span>
              </td>
              <td
                class="py-2.5 pr-3 text-gray-600 text-xs truncate max-w-[240px]"
                title={item.stop_name}
              >
                {item.stop_name || item.stop_id}
              </td>
              <td class="py-2.5 pr-3 text-gray-700">{item.instruction || "—"}</td>
              <td class="py-2.5 pr-3 text-right tabular-nums text-gray-900">
                <%= if item.time != nil do %>
                  <span class="inline-flex items-center gap-1">
                    <span class={if item.time_warning, do: "text-amber-600 font-semibold", else: ""}>
                      {format_number(item.time)}s
                    </span>
                    <span :if={item.time_warning} class="text-amber-500" aria-label="Time warning">
                      ⚠
                    </span>
                  </span>
                <% else %>
                  —
                <% end %>
              </td>
              <td class="py-2.5 text-right tabular-nums text-gray-900">
                {if item.dist != nil, do: "#{format_number(item.dist)}m", else: "—"}
              </td>
            </tr>
          <% end %>
        <% end %>
      </tbody>
    </table>
    """
  end

  # ── Shared badge/pill components ──────────────────────────────────────────

  attr :status, :atom, required: true

  def route_badge(assigns) do
    {label, bg, text} = route_badge_style(assigns.status)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:bg, bg)
      |> assign(:text_cls, text)

    ~H"""
    <span class={"inline-flex items-center px-2.5 py-0.5 text-xs font-semibold rounded #{@bg} #{@text_cls}"}>
      {@label}
    </span>
    """
  end

  attr :name, :string, required: true
  attr :index, :any, required: true

  def level_pill(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 text-xs font-medium rounded bg-amber-100 text-amber-800">
      {@name} · {format_level_index(@index)}
    </span>
    """
  end

  attr :message, :string, required: true

  def warning_banner(assigns) do
    ~H"""
    <div class="px-4 py-3 rounded-lg bg-amber-50 border border-amber-100">
      <p class="text-sm text-amber-900 leading-relaxed">{@message}</p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true

  def connectivity_empty_state(assigns) do
    ~H"""
    <div class="bg-white border border-gray-400 rounded-lg p-10 text-center shadow-card">
      <div class="w-12 h-12 mx-auto mb-4 rounded-full bg-gray-100 flex items-center justify-center">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
          <path
            d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            stroke="#99a1af"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </div>
      <h3 class="text-base font-semibold text-gray-900 mb-1">{@title}</h3>
      <p class="text-sm text-gray-600 max-w-md mx-auto">{@description}</p>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp group_steps_by_level(steps) do
    {grouped_rev, _} =
      Enum.reduce(steps, {[], nil}, fn step, {acc, current_level} ->
        step_item = Map.put(step, :type, :step)

        if step.level_name != current_level and step.level_name != nil do
          level_item = %{type: :level, name: step.level_name, index: step.level_index}
          {[step_item, level_item | acc], step.level_name}
        else
          {[step_item | acc], current_level}
        end
      end)

    Enum.reverse(grouped_rev)
  end

  defp worst_target_status(targets) do
    cond do
      Enum.all?(targets, &(&1.status == :reachable)) -> :green
      Enum.all?(targets, &(&1.status == :nopath)) -> :red
      true -> :amber
    end
  end

  defp status_dot_color(:green), do: "bg-emerald-500"
  defp status_dot_color(:red), do: "bg-red-400"
  defp status_dot_color(_), do: "bg-amber-400"

  defp route_badge_style(:reachable), do: {"Reachable", "bg-emerald-50", "text-emerald-700"}
  defp route_badge_style(:long), do: {"Long route", "bg-amber-50", "text-amber-700"}
  defp route_badge_style(:nopath), do: {"No path", "bg-red-50", "text-red-700"}

  defp dimension_label(:entrance_to_platform), do: "Entrance to platform"
  defp dimension_label(:platform_to_exit), do: "Platform to exit"
  defp dimension_label(:platform_to_platform), do: "Platform to platform"

  defp mode_color(mode), do: Map.get(@mode_colors, mode, "text-gray-500")

  defp format_number(nil), do: "—"
  defp format_number(n) when is_float(n) and n == trunc(n), do: Integer.to_string(trunc(n))
  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n), do: to_string(n)

  defp format_level_index(nil), do: ""

  defp format_level_index(index) when is_number(index) do
    val = index / 1.0
    formatted = :erlang.float_to_binary(abs(val), decimals: 1)
    if val < 0, do: "−" <> formatted, else: formatted
  end

  defp format_level_index(index), do: to_string(index)
end
