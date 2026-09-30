defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareComponents do
  @moduledoc """
  The compare page shell (spec 19, `AC-13`, `AC-14`): the route header, the title
  row with its view toggle and calendar select, the loading skeleton and the
  unavailable state.

  The ready state leaves the `#compare-slots`, `#compare-summary`,
  `#compare-stops` and `#compare-map` containers empty for the later steps that
  fill them, and owns the `#compare-workspace` grid they sit in. Every state
  decision stays in `RoutePatternCompareLive`; these components present it. They
  reuse `RouteWorkspace.route_header/1` and `PlannerComponents.message/1` and add
  no parallel header or callout (`CR-1`).

  The calendar options read the loaded comparison and the view switch only makes
  sense with content, so both show once a read has succeeded (the prototype hides
  them while loading and after a failure); the title stays, and the state below it
  says what is happening.
  """
  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1]

  attr :load_state, :atom, required: true, values: [:loading, :unavailable, :ready]

  attr :route, :map,
    default: nil,
    doc: "the loaded route; nil while loading and after a failed read"

  attr :version, :map, required: true, doc: "the current GTFS version"
  attr :view, :atom, required: true, values: [:two, :all], doc: "the URL's `view` param"
  attr :comparison, :map, default: nil, doc: "the loaded comparison; nil before it loads or fails"
  attr :two_path, :string, required: true, doc: "the compare URL with `view` cleared"
  attr :all_path, :string, required: true, doc: "the compare URL with `view=all`"
  attr :patterns_path, :string, required: true, doc: "the route's Patterns tab"

  def page(assigns) do
    ~H"""
    <div id="compare-page" class="ds-page">
      <.route_header
        route={@route}
        gtfs_version_id={@version.id}
        active_tab={:patterns}
        loading={@load_state == :loading}
      />

      <section id="compare-view" aria-labelledby="compare-title" class="pt-6">
        <div id="compare-toolbar" class="flex flex-wrap items-center gap-x-5 gap-y-3">
          <h2
            id="compare-title"
            class="mr-auto font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong sm:text-[26px]"
          >
            Compare patterns
          </h2>

          <div
            :if={@load_state == :ready}
            id="compare-view-toggle"
            role="group"
            aria-label="View"
            class="inline-flex rounded-control border border-control bg-white p-0.5"
          >
            <.link
              id="compare-view-two"
              patch={@two_path}
              aria-current={@view == :two && "page"}
              class={view_option_class()}
            >
              <.icon name="hero-view-columns" class="size-4" /> Two patterns
            </.link>
            <.link
              id="compare-view-all"
              patch={@all_path}
              aria-current={@view == :all && "page"}
              class={view_option_class()}
            >
              <.icon name="hero-squares-2x2" class="size-4" /> All patterns
            </.link>
          </div>

          <label :if={@comparison} for="compare-calendar" class="flex items-center gap-2">
            <span class="text-sm font-[650] text-strong">Trips on</span>
            <select
              id="compare-calendar"
              name="service"
              phx-change="select_calendar"
              class="h-11 w-[250px] max-w-full rounded-control border border-control bg-white px-3 text-sm text-strong"
            >
              <option
                :for={calendar <- @comparison.calendars}
                value={calendar.service_id}
                selected={calendar.service_id == @comparison.service_id}
              >
                {calendar_label(calendar, @comparison)}
              </option>
            </select>
          </label>
        </div>

        <%= cond do %>
          <% @load_state == :loading -> %>
            <.loading_skeleton />
          <% @load_state == :unavailable -> %>
            <.unavailable patterns_path={@patterns_path} />
          <% @view == :all -> %>
            <%!-- The all-patterns overview lands in a later step. --%>
          <% true -> %>
            <.two_pattern_containers />
        <% end %>
      </section>
    </div>
    """
  end

  # The prototype's view switch: an inset group whose current option takes the
  # selection tint. The view is URL state, so each option is a patch link and
  # marks itself with `aria-current`; the target grows to the 44 px control floor
  # the screens all share.
  defp view_option_class do
    [
      "inline-flex min-h-11 items-center gap-2 rounded-control px-3.5 text-sm font-[650] text-muted no-underline",
      "hover:text-strong aria-[current=page]:bg-selection aria-[current=page]:text-action"
    ]
  end

  # "Weekday (A 2 · B 1 trips)", or the A count alone while B is not chosen yet.
  defp calendar_label(calendar, comparison) do
    a_trips = Map.get(calendar.trips, comparison.a.pattern.route_pattern_id, 0)

    case comparison.b do
      nil ->
        "#{calendar.name} (#{a_trips} trips)"

      b ->
        b_trips = Map.get(calendar.trips, b.pattern.route_pattern_id, 0)
        "#{calendar.name} (A #{a_trips} · B #{b_trips} trips)"
    end
  end

  defp loading_skeleton(assigns) do
    ~H"""
    <div id="compare-loading" class="mt-5 motion-safe:animate-pulse" aria-busy="true">
      <p role="status" class="text-sm text-muted">Lining up the stops…</p>

      <div class="mt-3 grid gap-3 md:grid-cols-[minmax(0,1fr)_44px_minmax(0,1fr)]">
        <div class="h-[168px] rounded-card border border-subtle bg-canvas"></div>
        <div></div>
        <div class="h-[168px] rounded-card border border-subtle bg-canvas"></div>
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-[minmax(0,1fr)_400px]">
        <div class="grid gap-4">
          <div class="h-40 rounded-card bg-canvas"></div>
          <div class="h-[420px] rounded-card bg-canvas"></div>
        </div>
        <div class="flex h-[620px] items-center justify-center rounded-card bg-canvas text-sm text-muted">
          Loading map…
        </div>
      </div>
    </div>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <div id="compare-unavailable" class="mt-5 max-w-[720px]">
      <.message kind="error" title="The comparison didn’t load">
        We couldn’t read these two patterns just now. Nothing has changed. Try again, or go back to
        the patterns list.
        <:action>
          <div class="flex flex-wrap items-center gap-3">
            <.button
              id="compare-retry"
              type="button"
              variant="secondary"
              phx-click="retry"
              class="min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Try again
            </.button>
            <.link
              id="compare-unavailable-back"
              navigate={@patterns_path}
              class="inline-flex min-h-11 items-center font-[650] text-strong underline"
            >
              Back to patterns
            </.link>
          </div>
        </:action>
      </.message>
    </div>
    """
  end

  # The compare workspace's layout; later steps fill the empty containers. The
  # slots row and the two-column workspace mirror the prototype, including the
  # map's own column, which stacks above the table below `lg`.
  defp two_pattern_containers(assigns) do
    ~H"""
    <div id="compare-two-view" class="mt-4">
      <div
        id="compare-slots"
        class="grid items-stretch gap-3 md:grid-cols-[minmax(0,1fr)_44px_minmax(0,1fr)]"
      >
      </div>

      <div
        id="compare-workspace"
        class="mt-6 grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(340px,400px)]"
      >
        <div class="grid min-w-0 gap-6">
          <section id="compare-summary" aria-label="What’s different"></section>
          <section id="compare-stops" aria-label="Stop by stop"></section>
        </div>
        <aside
          id="compare-map-pane"
          aria-label="Map of both patterns"
          class="max-lg:order-first lg:sticky lg:top-4"
        >
          <div id="compare-map"></div>
        </aside>
      </div>
    </div>
    """
  end
end
