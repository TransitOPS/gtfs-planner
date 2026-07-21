defmodule GtfsPlannerWeb.Gtfs.StationReport2ConnectivityComponents do
  @moduledoc """
  Connectivity evidence for the station report: one card per source, one row per
  target, and the full step table for each route.

  Every route is built once by `StationReport2Live` and is always present in the
  document. Disclosure decides only what is visible on screen, so printing a
  freshly loaded report still carries complete source, target, route, and step
  evidence.

  Status is stated in words with a semantic token; accessibility is rendered by
  `TransitPresentation.accessibility_status/1` so its three states
  (accessible / not accessible / no data) are never flattened into a generic
  badge.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1, status_badge: 1, callout: 1]
  import GtfsPlannerWeb.Components.TransitPresentation, only: [accessibility_status: 1]

  attr :group, :map, required: true
  attr :dimension, :atom, required: true
  attr :routes, :map, default: %{}
  attr :expanded_route_keys, :any, default: MapSet.new()

  @doc "Renders one source and every target route reachable from it."
  def source_group_card(assigns) do
    assigns = assign(assigns, :dimension_label, dimension_label(assigns.dimension))

    ~H"""
    <%!-- Nested tier: no side borders or rounding of its own. The outermost
          card owns the only full border; this group announces itself with a
          tinted full-width header band and horizontal rules. --%>
    <div class="border-t border-base-300">
      <%!-- Indent scale: card content ps-4, group tier ps-8, expanded route
            evidence ps-12. Backgrounds and rules stay full width; only the
            content indents, so depth reads at a glance. --%>
      <div class="flex flex-wrap items-start justify-between gap-2 border-b border-base-300 bg-base-200 py-2.5 pe-4 ps-8">
        <div class="min-w-0">
          <div class="flex flex-wrap items-baseline gap-2">
            <h4 class="text-sm font-semibold break-words">{@group.source.name}</h4>
            <.level_chip
              :if={@group.source.level_name}
              name={@group.source.level_name}
              index={@group.source.level_index}
            />
          </div>
          <p class="mt-0.5 font-mono text-xs text-base-content/70 break-all">
            {@group.source.stop_id}
          </p>
        </div>
        <span class="shrink-0 text-xs font-medium text-base-content/70">{@dimension_label}</span>
      </div>

      <div class="divide-y divide-base-300">
        <.target_row
          :for={target <- @group.targets}
          target={target}
          source_id={@group.source.stop_id}
          source_name={@group.source.name}
          routes={@routes}
          expanded_route_keys={@expanded_route_keys}
        />
      </div>
    </div>
    """
  end

  attr :target, :map, required: true
  attr :source_id, :string, required: true
  attr :source_name, :string, required: true
  attr :routes, :map, default: %{}
  attr :expanded_route_keys, :any, default: MapSet.new()

  defp target_row(assigns) do
    key = {assigns.source_id, assigns.target.stop_id}

    assigns =
      assigns
      |> assign(:nopath, assigns.target.status == :nopath)
      # The route was built once with the report. Expansion only decides whether
      # it is visible on screen; it is always present for print.
      |> assign(:expanded_route, Map.get(assigns.routes, key))
      |> assign(:expanded, MapSet.member?(assigns.expanded_route_keys, key))
      |> assign(:route_region_id, "route-#{assigns.source_id}-#{assigns.target.stop_id}")

    ~H"""
    <div>
      <button
        type="button"
        data-report-control
        phx-click="toggle_route_expand"
        phx-value-source_id={@source_id}
        phx-value-target_id={@target.stop_id}
        aria-expanded={to_string(@expanded)}
        aria-controls={@route_region_id}
        class="print:hidden flex w-full min-h-11 cursor-pointer flex-col gap-2 py-3 pe-4 ps-8 text-left motion-safe:transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-inset"
      >
        <span class="flex min-w-0 items-baseline gap-1">
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0 self-center"
          />
          <span class="text-sm font-medium break-words">
            {@source_name} → {@target.name}
          </span>
        </span>
        <.route_metrics target={@target} nopath={@nopath} />
      </button>

      <%!-- Print carries the same facts without the control affordance. --%>
      <div class="hidden py-3 pe-4 ps-8 print:block">
        <p class="text-sm font-medium break-words">{@source_name} → {@target.name}</p>
        <.route_metrics target={@target} nopath={@nopath} />
      </div>

      <div
        :if={is_map(@expanded_route)}
        id={@route_region_id}
        role="region"
        aria-label={"Route from #{@source_name} to #{@target.name}"}
        class={["border-t border-base-300", not @expanded && "hidden print:block"]}
      >
        <div class="border-b border-base-300 py-3 pe-4 ps-12">
          <div class="flex flex-wrap items-start justify-between gap-2">
            <p class="min-w-0 font-mono text-xs text-base-content/70 break-all">
              {@expanded_route.target.stop_id} · {@expanded_route.target.meta}
            </p>
            <.route_badge status={@expanded_route.status} />
          </div>

          <div :for={warning <- @expanded_route.warnings} class="mt-3">
            <.callout kind="warning" title={warning} />
          </div>

          <dl class="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 text-sm sm:grid-cols-2 lg:grid-cols-4">
            <div class="flex flex-wrap items-baseline gap-x-2">
              <dt class="text-base-content/70">Total time</dt>
              <dd class="font-semibold tabular-nums">{format_number(@expanded_route.time)}s</dd>
            </div>
            <div class="flex flex-wrap items-baseline gap-x-2">
              <dt class="text-base-content/70">Distance</dt>
              <dd class="font-semibold tabular-nums">{format_number(@expanded_route.distance)}m</dd>
            </div>
            <div class="flex flex-wrap items-baseline gap-x-2">
              <dt class="text-base-content/70">Level changes</dt>
              <dd class="font-semibold tabular-nums">
                {@expanded_route.levels}
                <span :if={@expanded_route.level_path} class="font-normal text-base-content/70">
                  ({@expanded_route.level_path})
                </span>
              </dd>
            </div>
            <div class="flex flex-wrap items-baseline gap-x-2">
              <dt class="text-base-content/70">Accessibility</dt>
              <dd class="min-w-0">
                <.accessibility_status status={accessibility_state(@expanded_route.accessible)} />
                <span
                  :if={@expanded_route.accessible_note}
                  class="text-base-content/70 break-words"
                >
                  — {@expanded_route.accessible_note}
                </span>
              </dd>
            </div>
          </dl>
        </div>

        <div class="py-3 pe-4 ps-12">
          <.step_table steps={@expanded_route.steps} />
        </div>
      </div>

      <div
        :if={not is_map(@expanded_route)}
        id={@route_region_id}
        role="region"
        aria-label={"Route from #{@source_name} to #{@target.name}"}
        class={["border-t border-base-300 py-3 pe-4 ps-12", not @expanded && "hidden print:block"]}
      >
        <p class="flex items-start gap-2 text-sm">
          <.icon name="hero-x-circle" class="size-4 shrink-0 text-error" />
          <span class="break-words">
            No directed path exists between these stops. Check that pathway records connect all intermediate nodes.
          </span>
        </p>
      </div>
    </div>
    """
  end

  attr :target, :map, required: true
  attr :nopath, :boolean, required: true

  defp route_metrics(assigns) do
    ~H"""
    <span class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
      <span class="inline-flex items-baseline gap-1">
        <span class="text-base-content/70">Time</span>
        <span class="font-medium tabular-nums">
          {if @nopath, do: "—", else: "#{format_number(@target.time)}s"}
        </span>
      </span>
      <span class="inline-flex items-baseline gap-1">
        <span class="text-base-content/70">Distance</span>
        <span class="font-medium tabular-nums">
          {if @nopath, do: "—", else: "#{format_number(@target.distance)}m"}
        </span>
      </span>
      <.accessibility_status status={accessibility_state(@target.accessible)} />
      <.route_badge status={@target.status} />
    </span>
    """
  end

  defp accessibility_state(true), do: :accessible
  defp accessibility_state(false), do: :not_accessible
  defp accessibility_state(_unknown), do: :unknown

  # ── Step table ─────────────────────────────────────────────────────────────

  attr :steps, :list, required: true

  defp step_table(assigns) do
    assigns = assign(assigns, :grouped, group_steps_by_level(assigns.steps))

    ~H"""
    <div
      role="region"
      aria-label="Route steps"
      tabindex="0"
      class="overflow-x-auto focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-inset"
    >
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-base-300">
            <th scope="col" class="px-2 py-2 text-left text-xs font-semibold text-base-content/70">
              #
            </th>
            <th scope="col" class="px-2 py-2 text-left text-xs font-semibold text-base-content/70">
              Mode
            </th>
            <th scope="col" class="px-2 py-2 text-left text-xs font-semibold text-base-content/70">
              Stop name
            </th>
            <th scope="col" class="px-2 py-2 text-left text-xs font-semibold text-base-content/70">
              Instruction
            </th>
            <th scope="col" class="px-2 py-2 text-right text-xs font-semibold text-base-content/70">
              Time
            </th>
            <th scope="col" class="px-2 py-2 text-right text-xs font-semibold text-base-content/70">
              Dist
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-base-300">
          <%= for item <- @grouped do %>
            <tr :if={item.type == :level}>
              <th scope="colgroup" colspan="6" class="px-2 pt-3 pb-1 text-left text-xs font-semibold">
                {item.name} ({format_level_index(item.index)})
              </th>
            </tr>
            <tr :if={item.type != :level}>
              <td class="px-2 py-2 text-base-content/70 tabular-nums">{item.num}</td>
              <td class="px-2 py-2 font-medium break-words">{item.mode || "—"}</td>
              <td class="px-2 py-2 break-words">{item.stop_name || item.stop_id}</td>
              <td class="px-2 py-2 break-words">{item.instruction || "—"}</td>
              <td class="px-2 py-2 text-right tabular-nums">
                <%= if item.time != nil do %>
                  <span class={item.time_warning && "font-semibold text-warning"}>
                    {format_number(item.time)}s
                  </span>
                  <span :if={item.time_warning} class="block text-xs text-warning">Long</span>
                <% else %>
                  —
                <% end %>
              </td>
              <td class="px-2 py-2 text-right tabular-nums">
                {if item.dist != nil, do: "#{format_number(item.dist)}m", else: "—"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # ── Shared chips ───────────────────────────────────────────────────────────

  attr :status, :atom, required: true

  # Renders one route's outcome as a word plus a semantic token.
  defp route_badge(assigns) do
    ~H"""
    <.status_badge
      status={route_badge_status(@status)}
      label={route_badge_label(@status)}
      class="shrink-0"
      data-route-status={to_string(@status)}
    />
    """
  end

  attr :name, :string, required: true
  attr :index, :any, required: true

  # Renders a level identifier as a neutral chip; a level is a category, not a state.
  defp level_chip(assigns) do
    ~H"""
    <span class="rounded-selector inline-flex items-center border border-base-300 px-2 py-0.5 text-xs">
      {@name} · {format_level_index(@index)}
    </span>
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

  defp route_badge_status(:reachable), do: :pass
  defp route_badge_status(:long), do: :warning
  defp route_badge_status(_nopath), do: :failed

  defp route_badge_label(:reachable), do: "Reachable"
  defp route_badge_label(:long), do: "Long route"
  defp route_badge_label(_nopath), do: "No path"

  defp dimension_label(:entrance_to_platform), do: "Entrance to platform"
  defp dimension_label(:platform_to_exit), do: "Platform to exit"
  defp dimension_label(:platform_to_platform), do: "Platform to platform"

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
