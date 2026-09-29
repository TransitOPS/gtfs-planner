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
  badge. Times read as "5 min 58 s" and distances as "80 m".

  Every status badge is `ResultComponents.tone_badge/1`.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]
  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]
  import GtfsPlannerWeb.Components.TransitPresentation, only: [accessibility_status: 1]

  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  attr :group, :map, required: true
  attr :dimension, :atom, required: true
  attr :routes, :map, default: %{}
  attr :expanded_route_keys, :any, default: MapSet.new()

  @doc "Renders one source and every target route reachable from it."
  def source_group_card(assigns) do
    assigns = assign(assigns, :dimension_label, dimension_label(assigns.dimension))

    ~H"""
    <div class="overflow-clip rounded-control border border-subtle bg-white">
      <div class="flex flex-wrap items-start justify-between gap-2 border-b border-subtle bg-canvas px-4 py-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-baseline gap-2">
            <h4 class="break-words text-sm font-bold text-strong">{@group.source.name}</h4>
            <.level_chip
              :if={@group.source.level_name}
              name={@group.source.level_name}
              index={@group.source.level_index}
            />
          </div>
          <p class="mt-0.5 break-all font-mono text-[13px] text-muted">
            {@group.source.stop_id}
          </p>
        </div>
        <span class="shrink-0 text-[13px] font-[650] text-muted">{@dimension_label}</span>
      </div>

      <div class="divide-y divide-subtle">
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
        class={[
          "print:hidden flex min-h-11 w-full cursor-pointer flex-col gap-2 px-4 py-3 text-left",
          "motion-safe:transition-colors hover:bg-canvas",
          "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
        ]}
      >
        <span class="flex min-w-0 items-baseline gap-1">
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0 self-center text-muted"
          />
          <span class="break-words text-sm font-bold text-strong">
            {@source_name} → {@target.name}
          </span>
        </span>
        <.route_metrics target={@target} nopath={@nopath} />
      </button>

      <%!-- Print carries the same facts without the control affordance. --%>
      <div class="hidden px-4 py-3 print:block">
        <p class="break-words text-sm font-bold text-strong">{@source_name} → {@target.name}</p>
        <.route_metrics target={@target} nopath={@nopath} />
      </div>

      <div
        :if={is_map(@expanded_route)}
        id={@route_region_id}
        role="region"
        aria-label={"Route from #{@source_name} to #{@target.name}"}
        class={["border-t border-subtle px-4 py-4", not @expanded && "hidden print:block"]}
      >
        <div class="flex flex-wrap items-start justify-between gap-2">
          <p class="min-w-0 break-all font-mono text-[13px] text-muted">
            {@expanded_route.target.stop_id} · {@expanded_route.target.meta}
          </p>
          <.route_badge status={@expanded_route.status} />
        </div>

        <p
          :for={warning <- @expanded_route.warnings}
          class="mt-3 flex items-start gap-2 rounded-control bg-warning-bg px-3 py-2 text-sm text-warning-fg"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
          <span class="min-w-0 break-words">{warning}</span>
        </p>

        <dl class="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 text-sm sm:grid-cols-2 lg:grid-cols-4">
          <div class="flex flex-wrap items-baseline gap-x-2">
            <dt class="text-muted">Total time</dt>
            <dd class="font-bold tabular-nums text-strong">
              {format_time(@expanded_route.time)}
            </dd>
          </div>
          <div class="flex flex-wrap items-baseline gap-x-2">
            <dt class="text-muted">Distance</dt>
            <dd class="font-bold tabular-nums text-strong">
              {format_distance(@expanded_route.distance)}
            </dd>
          </div>
          <div class="flex flex-wrap items-baseline gap-x-2">
            <dt class="text-muted">Level changes</dt>
            <dd class="font-bold tabular-nums text-strong">
              {@expanded_route.levels}
              <span :if={@expanded_route.level_path} class="font-normal text-muted">
                ({@expanded_route.level_path})
              </span>
            </dd>
          </div>
          <div class="flex flex-wrap items-baseline gap-x-2">
            <dt class="text-muted">Accessibility</dt>
            <dd class="min-w-0">
              <.accessibility_status status={accessibility_state(@expanded_route.accessible)} />
              <span :if={@expanded_route.accessible_note} class="break-words text-muted">
                · {@expanded_route.accessible_note}
              </span>
            </dd>
          </div>
        </dl>

        <div class="mt-4">
          <.step_table steps={@expanded_route.steps} />
        </div>
      </div>

      <div
        :if={not is_map(@expanded_route)}
        id={@route_region_id}
        role="region"
        aria-label={"Route from #{@source_name} to #{@target.name}"}
        class={["border-t border-subtle px-4 py-4", not @expanded && "hidden print:block"]}
      >
        <p class="flex items-start gap-2 text-sm text-default">
          <.icon name="hero-x-circle" class="size-4 shrink-0 text-error-fg" />
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
        <span class="text-muted">Time</span>
        <span class="font-bold tabular-nums text-strong">
          {if @nopath, do: "—", else: format_time(@target.time)}
        </span>
      </span>
      <span class="inline-flex items-baseline gap-1">
        <span class="text-muted">Distance</span>
        <span class="font-bold tabular-nums text-strong">
          {if @nopath, do: "—", else: format_distance(@target.distance)}
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
      class="overflow-x-auto rounded-control border border-subtle focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
    >
      <table class="w-full text-sm">
        <thead class="bg-canvas">
          <tr class="border-b border-subtle">
            <.step_header>#</.step_header>
            <.step_header>Mode</.step_header>
            <.step_header>Stop name</.step_header>
            <.step_header>Instruction</.step_header>
            <.step_header align="right">Time</.step_header>
            <.step_header align="right">Distance</.step_header>
          </tr>
        </thead>
        <tbody class="divide-y divide-subtle">
          <%= for item <- @grouped do %>
            <tr :if={item.type == :level} class="bg-canvas/60">
              <th
                scope="colgroup"
                colspan="6"
                class="px-3 py-2 text-left text-[13px] font-[650] text-strong"
              >
                {item.name} ({format_level_index(item.index)})
              </th>
            </tr>
            <tr :if={item.type != :level}>
              <td class="px-3 py-2 tabular-nums text-muted">{item.num}</td>
              <td class="break-words px-3 py-2 font-[650] text-strong">{item.mode || "—"}</td>
              <td class="break-words px-3 py-2">{item.stop_name || item.stop_id}</td>
              <td class="break-words px-3 py-2">{item.instruction || "—"}</td>
              <td class="px-3 py-2 text-right tabular-nums">
                <%= if item.time != nil do %>
                  <span class={item.time_warning && "font-bold text-warning-fg"}>
                    {format_time(item.time)}
                  </span>
                  <span :if={item.time_warning} class="block text-[13px] text-warning-fg">
                    Long
                  </span>
                <% else %>
                  —
                <% end %>
              </td>
              <td class="px-3 py-2 text-right tabular-nums">
                {if item.dist != nil, do: format_distance(item.dist), else: "—"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :align, :string, default: "left", values: ~w(left right)
  slot :inner_block, required: true

  defp step_header(assigns) do
    ~H"""
    <th
      scope="col"
      class={[
        "px-3 py-2 text-[13px] font-[650] text-muted",
        @align == "right" && "text-right",
        @align == "left" && "text-left"
      ]}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end

  # ── Shared chips ───────────────────────────────────────────────────────────

  attr :status, :atom, required: true

  # Renders one route's outcome as a word plus a semantic token.
  defp route_badge(assigns) do
    ~H"""
    <.tone_badge
      tone={route_badge_tone(@status)}
      class="shrink-0 whitespace-nowrap"
      data-route-status={to_string(@status)}
    >
      {route_badge_label(@status)}
    </.tone_badge>
    """
  end

  attr :name, :string, required: true
  attr :index, :any, required: true

  # Renders a level identifier as a neutral chip; a level is a category, not a state.
  defp level_chip(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-badge border border-subtle bg-white px-2 py-0.5 text-[13px] text-default">
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

  defp route_badge_tone(:reachable), do: "success"
  defp route_badge_tone(:long), do: "warning"
  defp route_badge_tone(_nopath), do: "error"

  defp route_badge_label(:reachable), do: "Reachable"
  defp route_badge_label(:long), do: "Long route"
  defp route_badge_label(_nopath), do: "No path"

  defp dimension_label(:entrance_to_platform), do: "Entrance to platform"
  defp dimension_label(:platform_to_exit), do: "Platform to exit"
  defp dimension_label(:platform_to_platform), do: "Platform to platform"

  defp format_time(nil), do: "—"
  defp format_time(seconds) when is_number(seconds), do: Helpers.format_duration(seconds)
  defp format_time(other), do: to_string(other)

  defp format_distance(nil), do: "—"
  defp format_distance(meters), do: "#{format_number(meters)} m"

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
