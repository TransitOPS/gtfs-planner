defmodule GtfsPlannerWeb.Gtfs.RoutePatternListComponents do
  @moduledoc """
  The route's Patterns tab: the page `RoutePatternLive` renders for its `:index`
  action, in the TransitOps application design system.

  It draws every state of the list from the assigns the LiveView already keeps:
  loading, unavailable, first use, trips that are not in a pattern yet, a failed
  build, a stale read, editing access removed, the list itself, and the
  "Generate missing paths" task with its dialog and results. State decisions stay
  in the LiveView; these components present them.

  The patterns are one `:patterns` stream of rows and direction headings
  (`stream_items/1`), so the table needs one tbody and every row can carry its own
  map-line status without a second stream for phones.
  """
  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, first_use: 1, message: 1]
  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1]

  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlannerWeb.Gtfs.RoutePatternAlignmentEvents

  @doc """
  Turns the loaded pattern summaries into the items of the `:patterns` stream: a
  heading before the first pattern of each direction, then that direction's
  patterns. The summaries arrive ordered by direction, so a direction is one run.
  """
  def stream_items(summaries) do
    summaries
    |> Enum.chunk_by(& &1.pattern.direction_id)
    |> Enum.flat_map(fn [first | _rest] = group ->
      direction_id = first.pattern.direction_id

      heading = %{
        id: "direction-#{direction_id}",
        kind: :direction,
        direction_id: direction_id,
        count: length(group)
      }

      [heading | Enum.map(group, &%{id: &1.id, kind: :pattern, summary: &1})]
    end)
  end

  attr :load_state, :atom, required: true, values: [:loading, :unavailable, :ready]
  attr :route, :map, default: nil
  attr :version, :map, required: true, doc: "the current GTFS version"
  attr :patterns, :any, required: true, doc: "the `:patterns` stream from `stream_items/1`"
  attr :patterns_empty?, :boolean, required: true
  attr :pattern_count, :integer, required: true
  attr :route_trip_count, :integer, required: true
  attr :pending_trip_count, :integer, required: true
  attr :custom_trip_count, :integer, required: true
  attr :derivation_error, :string, default: nil
  attr :build_state, :atom, required: true
  attr :build_error, :string, default: nil
  attr :build_summary, :map, default: nil, doc: "%{created, linked, custom} after a build"
  attr :stale?, :boolean, required: true
  attr :editable?, :boolean, required: true
  attr :editor_revoked?, :boolean, required: true
  attr :new_path, :string, required: true
  attr :bulk_candidates, :list, required: true, doc: "patterns with missing sections"
  attr :bulk_selected, :any, default: nil, doc: "MapSet of selected natural route_pattern_ids"
  attr :bulk_dialog, :map, default: nil
  attr :bulk_result, :map, default: nil
  attr :bulk_error, :atom, default: nil
  attr :bulk_pending, :boolean, default: false

  def page(%{load_state: :loading} = assigns) do
    ~H"""
    <div id="route-patterns-page" class="ds-page">
      <div id="patterns-loading" aria-busy="true" class="pt-4">
        <p role="status" class="inline-flex min-h-11 items-center text-sm text-muted">
          Loading patterns…
        </p>
        <div class="motion-safe:animate-pulse" aria-hidden="true">
          <div class="mt-1 flex items-center gap-4">
            <div class="h-10 w-12 rounded-badge bg-canvas"></div>
            <div class="h-9 w-72 max-w-full rounded-badge bg-canvas"></div>
          </div>
          <div class="mt-3 h-4 w-56 rounded-badge bg-canvas"></div>
          <div class="mt-6 flex gap-6 border-b border-subtle pb-3">
            <div class="h-4 w-14 rounded-badge bg-canvas"></div>
            <div class="h-4 w-20 rounded-badge bg-canvas"></div>
            <div class="h-4 w-20 rounded-badge bg-canvas"></div>
          </div>
          <div class="mt-8 h-8 w-48 rounded-badge bg-canvas"></div>
          <div class="mt-3 h-4 w-[420px] max-w-full rounded-badge bg-canvas"></div>
          <div class="mt-6 rounded-card border border-subtle bg-white">
            <div class="h-[52px] border-b border-subtle"></div>
            <div class="h-11 border-b border-subtle bg-canvas"></div>
            <div
              :for={width <- ~w(46% 38% 52% 42%)}
              class="flex h-[66px] items-center gap-6 border-b border-subtle px-5 last:border-b-0"
            >
              <div class="grid flex-1 gap-2">
                <div class="h-4 rounded-badge bg-canvas" style={"width: #{width}"}></div>
                <div class="h-3 w-[28%] rounded-badge bg-canvas"></div>
              </div>
              <div class="h-6 w-24 rounded-badge bg-canvas max-md:hidden"></div>
              <div class="h-4 w-10 rounded-badge bg-canvas max-md:hidden"></div>
              <div class="h-4 w-16 rounded-badge bg-canvas max-md:hidden"></div>
              <div class="h-6 w-28 rounded-badge bg-canvas max-md:hidden"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The route is unknown when the first read fails, so the page keeps only the way
  # back and a retry.
  def page(%{load_state: :unavailable} = assigns) do
    ~H"""
    <div id="route-patterns-page" class="ds-page">
      <h1 class="sr-only">Route patterns</h1>
      <nav aria-label="Breadcrumb" class="pt-4">
        <.back_link id="route-back-to-routes" navigate={"/gtfs/#{@version.id}/routes"}>
          Routes
        </.back_link>
      </nav>
      <div class="mt-4 max-w-[680px]">
        <.message id="patterns-unavailable" kind="error" title="This route’s patterns didn’t load">
          The patterns didn’t respond, so nothing is shown. Nothing has changed, and the rest of
          the app still works. Try again, or go back to the routes list.
          <:action>
            <.button
              id="patterns-retry"
              type="button"
              variant="secondary"
              phx-click="reload_patterns"
              class="min-h-11"
            >
              <.reload_label busy="Reloading…">Reload patterns</.reload_label>
            </.button>
          </:action>
        </.message>
      </div>
    </div>
    """
  end

  def page(assigns) do
    assigns =
      assigns
      |> assign(:editable?, assigns.editable? and not assigns.editor_revoked?)
      |> assign(:build_failed?, assigns.derivation_error != nil or assigns.build_error != nil)
      |> assign(:blocked?, blocked?(assigns))

    assigns = assign(assigns, :create_mode, create_mode(assigns))

    ~H"""
    <div id="route-patterns-page" class="ds-page">
      <.route_header route={@route} gtfs_version_id={@version.id} active_tab={:patterns} />

      <section aria-labelledby="patterns-heading" class="pt-7">
        <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
          <h2
            id="patterns-heading"
            class="font-display text-[26px] font-semibold leading-tight tracking-[-0.025em] text-strong sm:text-[30px]"
          >
            Stop patterns
          </h2>
          <.button
            :if={@create_mode != :hidden}
            id="patterns-create"
            navigate={@new_path}
            variant={if(@create_mode == :primary, do: "primary", else: "secondary")}
            class="min-h-11"
          >
            <.icon name="hero-plus" class="size-4" /> Create pattern
          </.button>
        </div>
        <p class="mt-1.5 max-w-[80ch] text-[15px] leading-relaxed text-default">
          The stop sequences this route runs, such as the full route, a short turn or a
          school-day deviation.
        </p>

        <div class="mt-4 hidden gap-4 has-[>*]:grid">
          <.build_summary_message :if={@build_summary} summary={@build_summary} />

          <.message
            :if={@stale?}
            id="patterns-stale"
            kind="warning"
            title="These patterns may be out of date"
          >
            We couldn’t refresh them just now, so you’re seeing the last patterns and counts we
            loaded. Refresh to try again.
            <:action>
              <.button
                id="patterns-stale-reload"
                type="button"
                variant="secondary"
                phx-click="reload_patterns"
                class="min-h-11"
              >
                <.reload_label busy="Refreshing…">Refresh patterns</.reload_label>
              </.button>
            </:action>
          </.message>

          <.message
            :if={@editor_revoked?}
            id="pattern-editor-revoked"
            kind="warning"
            title="Your editing access was removed"
          >
            You can still look at these patterns, but you can’t change them. Ask an organization
            administrator to restore the editor role, then reload.
            <:action>
              <.button
                id="pattern-editor-reload"
                type="button"
                variant="secondary"
                phx-click="reload_patterns"
                class="min-h-11"
              >
                <.reload_label busy="Reloading…">Reload page</.reload_label>
              </.button>
            </:action>
          </.message>

          <.message
            :if={@pending_trip_count > 0 and not @patterns_empty? and @editable?}
            id="patterns-partial"
            kind="info"
            title={"#{plural(@pending_trip_count, "trip is", "trips are")} not in a pattern yet"}
          >
            Build patterns from their stop order and direction. Their current times stay unchanged.
            <:action>
              <.build_button
                id="patterns-build-retry"
                variant="secondary"
                build_state={@build_state}
              />
            </:action>
          </.message>

          <.message
            :if={@build_failed?}
            id="patterns-derivation-error"
            kind="error"
            title="We could not build patterns for this route"
          >
            <p>{build_failed_body(@pending_trip_count)}</p>
            <p :if={@build_error} id="patterns-build-error" class="mt-2 font-bold">
              {@build_error}
            </p>
            <details :if={@derivation_error} class="group mt-2">
              <summary class="inline-flex min-h-11 cursor-pointer items-center gap-1 font-[650] hover:underline">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 transition-transform group-open:rotate-90"
                /> Technical details
              </summary>
              <p class="rounded-control bg-white/70 px-3 py-2 font-mono text-[12px] leading-relaxed text-strong [overflow-wrap:anywhere]">
                {@derivation_error}
              </p>
            </details>
            <:action :if={@editable?}>
              <.build_button
                id="patterns-build-error-retry"
                variant={if(@patterns_empty?, do: "primary", else: "secondary")}
                build_state={@build_state}
              />
            </:action>
          </.message>

          <.message
            :if={@bulk_error == :routing_unavailable}
            id="patterns-bulk-unavailable"
            kind="error"
            title="Street routing is unavailable"
          >
            No paths were suggested and nothing was changed. Draw the missing sections by hand, or
            try again later.
          </.message>

          <.message
            :if={@bulk_error == :too_many_sections}
            id="patterns-bulk-too-many"
            kind="error"
            title="Too many sections selected"
          >
            One run covers at most {RoutePatternAlignmentEvents.bulk_section_limit()} sections. Choose fewer patterns and try
            again.
          </.message>
        </div>

        <div class="mt-4">
          <%= cond do %>
            <% not @patterns_empty? -> %>
              <.list_card
                route={@route}
                version={@version}
                patterns={@patterns}
                pattern_count={@pattern_count}
                route_trip_count={@route_trip_count}
                editable?={@editable?}
                editor_revoked?={@editor_revoked?}
                bulk_candidates={@bulk_candidates}
                bulk_result={@bulk_result}
                bulk_pending={@bulk_pending}
              />
            <% @build_failed? -> %>
              <%!-- The error message above carries the retry, so no second panel offers it. --%>
            <% @pending_trip_count > 0 -> %>
              <.first_use id="patterns-unlinked" title="Group your trips into patterns">
                <strong class="font-[650] tabular-nums text-strong">
                  {plural(@pending_trip_count, "trip", "trips")}
                </strong>
                on this route {if(@pending_trip_count == 1, do: "is", else: "are")} not in a pattern yet.
                Building patterns groups them by direction and stop order, and keeps their current
                times.
                <:action :if={@editable?}>
                  <.build_button id="patterns-build" variant="primary" build_state={@build_state} />
                </:action>
              </.first_use>
            <% @blocked? -> %>
              <div class="grid gap-4">
                <.message id="patterns-build-blocked" kind="info" title="No trips to group">
                  <%= if @custom_trip_count > 0 do %>
                    {custom_trips_sentence(@custom_trip_count)} so nothing can be grouped
                    automatically. Create a pattern by hand, or <.link
                      id="patterns-review-schedules"
                      navigate={~p"/gtfs/#{@version.id}/routes/#{@route.route_id}/schedules"}
                      class="font-[650] underline"
                    >
                      review those trips on the Schedules tab</.link>.
                  <% else %>
                    No trips on this route are waiting to be grouped into patterns.
                  <% end %>
                </.message>
                <.first_pattern
                  id="patterns-empty-inline"
                  editable?={@editable?}
                  new_path={@new_path}
                />
              </div>
            <% true -> %>
              <.first_pattern id="patterns-empty" editable?={@editable?} new_path={@new_path} />
          <% end %>
        </div>

        <p
          :if={@editable?}
          id="patterns-scope-note"
          class="mt-3 max-w-[72ch] text-[13px] text-muted"
        >
          Changes to patterns update {@version.name}, a published version. Every change shows the
          trips it affects before you confirm it.
        </p>
      </section>

      <.bulk_dialog dialog={@bulk_dialog} selected={@bulk_selected} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :editable?, :boolean, required: true
  attr :new_path, :string, required: true

  defp first_pattern(assigns) do
    ~H"""
    <.first_use id={@id} title="Add the first pattern">
      A pattern is one stop sequence this route runs. Choose a direction and the stops it visits,
      then set its timings.
      <:action :if={@editable?}>
        <.button id="patterns-create-empty" navigate={@new_path} class="min-h-11">
          <.icon name="hero-plus" class="size-4" /> Create pattern
        </.button>
      </:action>
    </.first_use>
    """
  end

  attr :id, :string, required: true
  attr :variant, :string, required: true
  attr :build_state, :atom, required: true

  defp build_button(assigns) do
    ~H"""
    <.button
      id={@id}
      type="button"
      variant={@variant}
      phx-click="build_patterns"
      phx-disable-with="Building patterns…"
      disabled={@build_state == :building}
      class="min-h-11"
    >
      Build patterns from trips
    </.button>
    """
  end

  attr :busy, :string, required: true
  slot :inner_block, required: true

  # The label of a button that re-reads the list. While its click is in flight the
  # icon spins and the label says so; `phx-disable-with` would replace the icon.
  defp reload_label(assigns) do
    ~H"""
    <.icon name="hero-arrow-path" class="size-4 phx-click-loading:motion-safe:animate-spin" />
    <span class="phx-click-loading:hidden">{render_slot(@inner_block)}</span>
    <span class="hidden phx-click-loading:inline">{@busy}</span>
    """
  end

  attr :summary, :map, required: true

  defp build_summary_message(assigns) do
    ~H"""
    <.message
      id="patterns-build-summary"
      kind="success"
      title={build_summary_title(@summary)}
    >
      {build_summary_body(@summary)}
    </.message>
    """
  end

  attr :route, :map, required: true
  attr :version, :map, required: true
  attr :patterns, :any, required: true
  attr :pattern_count, :integer, required: true
  attr :route_trip_count, :integer, required: true
  attr :editable?, :boolean, required: true
  attr :editor_revoked?, :boolean, required: true
  attr :bulk_candidates, :list, required: true
  attr :bulk_result, :map, default: nil
  attr :bulk_pending, :boolean, required: true

  defp list_card(assigns) do
    candidates = assigns.bulk_candidates
    suggesting? = assigns.bulk_pending or assigns.bulk_result != nil

    assigns =
      assigns
      |> assign(:show_attention?, assigns.editable? and candidates != [] and not suggesting?)
      |> assign(:attention_first?, attention_first?(candidates, assigns.pattern_count))

    ~H"""
    <div
      id="patterns-list-container"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div
        id="patterns-summary"
        class="flex min-h-[52px] flex-wrap items-center gap-x-4 border-b border-subtle px-4 py-1 text-[13px] md:px-5"
      >
        <p class="tabular-nums">
          <strong id="patterns-count" class="font-[650] text-strong">
            {plural(@pattern_count, "pattern", "patterns")}
          </strong>
          <span id="pattern-trip-count" class="ml-1 text-muted">
            {plural(@route_trip_count, "trip", "trips")} across all service days
          </span>
        </p>
        <button
          type="button"
          id="patterns-help-toggle"
          aria-expanded="false"
          aria-controls="patterns-help-panel"
          phx-click={
            JS.toggle_attribute({"aria-expanded", "true", "false"})
            |> JS.toggle_attribute({"hidden", "hidden"}, to: "#patterns-help-panel")
          }
          class={[
            "inline-flex min-h-11 items-center gap-1.5 rounded-control font-[650] text-action hover:underline",
            "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          ]}
        >
          <.icon name="hero-information-circle" class="size-4" /> How to read this list
        </button>
        <button
          type="button"
          id="patterns-reload"
          phx-click="reload_patterns"
          class={[
            "-mr-2 ml-auto inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 font-[650] text-action hover:underline",
            "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          ]}
        >
          <.reload_label busy="Refreshing…">Refresh</.reload_label>
        </button>
      </div>

      <.help_panel />

      <div
        :if={not @editable? and not @editor_revoked?}
        id="patterns-readonly-note"
        class="flex items-start gap-3 border-b border-subtle bg-canvas px-4 py-3 text-sm text-default md:px-5"
      >
        <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0 text-muted" />
        <p>
          <strong class="font-[650] text-strong">View only.</strong>
          Ask an organization administrator for editor access if you need to change patterns.
        </p>
      </div>

      <.attention
        :if={@show_attention? and @attention_first?}
        candidates={@bulk_candidates}
        first?={true}
      />

      <div
        :if={@bulk_pending}
        id="patterns-bulk-running"
        class="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-subtle bg-soft px-4 py-3 text-cyan-800 md:px-5"
      >
        <.icon name="hero-arrow-path" class="size-5 shrink-0 text-cyan-700 motion-safe:animate-spin" />
        <p role="status" class="min-w-0 flex-1 basis-[240px] text-sm font-[650]">
          Finding street paths…
        </p>
        <.button
          id="patterns-bulk-cancel"
          type="button"
          variant="secondary"
          phx-click="cancel_bulk_generation"
          class="min-h-11"
        >
          Cancel
        </.button>
      </div>

      <div :if={@bulk_result} class="border-b border-subtle p-4 md:px-5">
        <.bulk_notice result={@bulk_result} version={@version} />
      </div>

      <table id="patterns-table" class="w-full border-collapse text-left text-sm max-md:block">
        <caption class="sr-only">
          Stop patterns for {@route.route_long_name || @route.route_short_name || @route.route_id}, grouped by direction
        </caption>
        <thead class="max-md:hidden">
          <tr class="bg-canvas">
            <th scope="col" class={[head_class(), "pl-5"]}>Pattern</th>
            <th scope="col" class={[head_class(), "w-[150px]"]}>Use on this route</th>
            <th scope="col" class={[head_class(), "w-[84px] text-right"]}>Stops</th>
            <th scope="col" class={[head_class(), "w-[120px] text-right"]}>Trips</th>
            <th scope="col" class={[head_class(), "w-[210px]"]}>Map line</th>
            <th scope="col" class="h-11 w-12 py-0 pr-3"><span class="sr-only">Open</span></th>
          </tr>
        </thead>
        <tbody id="patterns-list" phx-update="stream" class="max-md:block">
          <%= for {id, item} <- @patterns do %>
            <.direction_row :if={item.kind == :direction} id={id} item={item} />
            <.pattern_row
              :if={item.kind == :pattern}
              id={id}
              summary={item.summary}
              bulk_result={@bulk_result}
            />
          <% end %>
        </tbody>
      </table>

      <.attention
        :if={@show_attention? and not @attention_first?}
        candidates={@bulk_candidates}
        first?={false}
      />
    </div>
    """
  end

  defp head_class, do: "h-11 px-4 py-0 text-[13px] font-[650] text-default"

  # Legend, closed until asked. It defines the words the list uses once, so the
  # rows can stay short.
  defp help_panel(assigns) do
    ~H"""
    <div
      id="patterns-help-panel"
      hidden
      class="grid gap-6 border-b border-subtle bg-canvas px-4 py-5 text-sm text-default md:grid-cols-3 md:px-5"
    >
      <div class="grid content-start gap-4">
        <div>
          <h3 class="text-sm font-bold text-strong">A pattern is one stop sequence</h3>
          <p class="mt-1">
            It lists the stops one kind of trip serves, in order. Trips follow a pattern. Each
            pattern keeps its own timings (named sets of running times, such as Weekday peak) and
            a map line.
          </p>
        </div>
        <div>
          <h3 class="text-sm font-bold text-strong">When to add another pattern</h3>
          <p class="mt-1">
            Add one for a different direction, a short turn or a different set of stops. If only
            the running times change, add a timing to the pattern you already have.
          </p>
        </div>
      </div>
      <div>
        <h3 class="text-sm font-bold text-strong">Use on this route</h3>
        <dl class="mt-1 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
          <dt class="font-[650] text-strong">Typical</dt>
          <dd>The stops most trips serve.</dd>
          <dt class="font-[650] text-strong">Deviation</dt>
          <dd>A variation of a typical pattern, such as a short turn.</dd>
          <dt class="font-[650] text-strong">Atypical</dt>
          <dd>Special routing that runs only a few times a day.</dd>
          <dt class="font-[650] text-strong">Detour</dt>
          <dd>A temporary routing. <span class="text-[13px] text-muted">GTFS: diversion.</span></dd>
          <dt class="font-[650] text-strong">Reference</dt>
          <dd>
            Lists every stop and may have no trips.
            <span class="text-[13px] text-muted">GTFS: canonical.</span>
          </dd>
        </dl>
      </div>
      <div class="grid content-start gap-4">
        <div>
          <h3 class="text-sm font-bold text-strong">Map line</h3>
          <p class="mt-1">
            The path the bus drives between stops. Each pair of neighboring stops is a section.
            <strong class="font-[650] text-strong">Ready</strong>
            means every section has a saved path and the line matches the current stops.
            <strong class="font-[650] text-strong">Blocked</strong>
            means a stop has no location, or two neighboring stops share one, so the section
            cannot be drawn.
          </p>
        </div>
        <p class="text-[13px] text-muted">
          In the exported feed a pattern is not its own file. Each trip carries its stops
          (<code class="font-mono text-[12px]">stop_times.txt</code>) and map line
          (<code class="font-mono text-[12px]">shapes.txt</code>).
        </p>
      </div>
    </div>
    """
  end

  attr :candidates, :list, required: true
  attr :first?, :boolean, required: true

  # Map lines that still need paths. It leads the card when most patterns need
  # them (right after an import) and closes it otherwise.
  defp attention(assigns) do
    assigns =
      assign(assigns, :sections, Enum.sum(Enum.map(assigns.candidates, & &1.missing)))

    ~H"""
    <div
      id="patterns-attention"
      class={[
        "flex flex-wrap items-center gap-x-4 gap-y-2 bg-canvas px-4 py-3 md:px-5",
        if(@first?, do: "border-b border-subtle", else: "border-t border-subtle")
      ]}
    >
      <.icon name="hero-map" class="size-5 shrink-0 text-muted" />
      <p class="min-w-0 flex-1 basis-[260px] text-sm text-default">
        <strong class="font-[650] text-strong">
          {plural(length(@candidates), "pattern has", "patterns have")}
          {plural(@sections, "section", "sections")} without a path.
        </strong>
        We can suggest street paths for them. You review each one before it is saved.
      </p>
      <.button
        id="patterns-bulk-generate"
        type="button"
        variant="secondary"
        phx-click="open_bulk"
        class="min-h-11"
      >
        Generate missing paths
      </.button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true

  defp direction_row(assigns) do
    ~H"""
    <tr id={@id} class="border-t border-subtle max-md:block">
      <th
        scope="rowgroup"
        colspan="6"
        class="pb-2 pl-5 pr-4 pt-4 text-left font-normal max-md:block max-md:px-4 max-md:pb-1"
      >
        <span class="text-[15px] font-[650] text-strong">
          {RoutePattern.direction_label(@item.direction_id)}
        </span>
        <span class="ml-2 text-[13px] font-normal text-muted">
          {plural(@item.count, "pattern", "patterns")}
        </span>
      </th>
    </tr>
    """
  end

  attr :id, :string, required: true
  attr :summary, :map, required: true
  attr :bulk_result, :map, default: nil

  # The whole row opens the pattern; the name button is the keyboard path and the
  # map-line cell keeps its own target. Below `md` the cells wrap into one card.
  defp pattern_row(assigns) do
    pattern = assigns.summary.pattern
    natural_id = pattern.route_pattern_id

    assigns =
      assigns
      |> assign(:pattern, pattern)
      |> assign(:natural_id, natural_id)
      |> assign(:name, pattern_name(pattern))
      |> assign(:bulk_entry, bulk_entry(assigns.bulk_result, natural_id))

    ~H"""
    <tr
      id={@id}
      phx-click="open_pattern"
      phx-value-pattern-id={@natural_id}
      class={[
        "cursor-pointer border-t border-subtle hover:bg-canvas",
        "max-md:flex max-md:flex-wrap max-md:items-center max-md:gap-x-3 max-md:gap-y-1 max-md:px-4 max-md:py-3"
      ]}
    >
      <td data-label="Pattern" class="py-3 pl-5 pr-4 align-middle max-md:basis-full max-md:p-0">
        <button
          id={"pattern-open-#{@summary.id}"}
          type="button"
          phx-click="open_pattern"
          phx-value-pattern-id={@natural_id}
          class={[
            "block rounded-control text-left text-[15px] font-[650] leading-snug text-strong hover:underline",
            "[overflow-wrap:anywhere] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          ]}
        >
          {@name}
        </button>
        <p class="mt-0.5 text-[13px] text-muted">
          {service_description(@pattern)} · {plural(@summary.timing_count, "timing", "timings")}
        </p>
      </td>
      <td data-label="Use on this route" class="px-4 align-middle max-md:p-0">
        <.use_chip typicality={@pattern.route_pattern_typicality} />
      </td>
      <td
        data-label="Stops"
        class="px-4 text-right align-middle tabular-nums max-md:p-0 max-md:text-left max-md:text-[13px] max-md:text-muted"
      >
        <span class="max-md:hidden">{@summary.stop_count}</span>
        <span class="md:hidden">{plural(@summary.stop_count, "stop", "stops")}</span>
      </td>
      <td
        data-label="Trips"
        class="px-4 text-right align-middle tabular-nums max-md:p-0 max-md:text-left max-md:text-[13px] max-md:text-muted"
      >
        <span :if={@summary.trip_count == 0} class="text-muted">
          <span class="max-md:hidden">Not used yet</span>
          <span class="md:hidden">· not used yet</span>
        </span>
        <span :if={@summary.trip_count > 0}>
          <span class="max-md:hidden">{@summary.trip_count}</span>
          <span class="md:hidden">· {plural(@summary.trip_count, "trip", "trips")}</span>
        </span>
      </td>
      <td
        data-label="Map line"
        class="px-4 align-middle max-md:flex max-md:basis-full max-md:items-center max-md:gap-x-2 max-md:p-0"
      >
        <span class="shrink-0 text-[13px] text-muted md:hidden">Map line</span>
        <.map_cell
          summary={@summary}
          name={@name}
          natural_id={@natural_id}
          bulk_entry={@bulk_entry}
        />
      </td>
      <td class="py-0 pr-3 text-right align-middle text-muted max-md:hidden" aria-hidden="true">
        <.icon name="hero-chevron-right" class="size-4" />
      </td>
    </tr>
    """
  end

  attr :typicality, :any, required: true

  defp use_chip(assigns) do
    {tone, text} = use_label(assigns.typicality)
    assigns = assign(assigns, tone: tone, text: text)

    ~H"""
    <span class={chip_class(@tone)}>{@text}</span>
    """
  end

  attr :summary, :map, required: true
  attr :name, :string, required: true
  attr :natural_id, :string, required: true
  attr :bulk_entry, :map, default: nil

  # The map-line cell is the way to the pattern's map-line task. After a bulk run
  # it reports what the run found for this pattern instead.
  defp map_cell(%{bulk_entry: nil} = assigns) do
    {tone, icon, text} = map_status(Map.get(assigns.summary, :alignment))
    assigns = assign(assigns, tone: tone, icon: icon, text: text)

    ~H"""
    <button
      type="button"
      id={"pattern-alignment-#{@natural_id}"}
      phx-click="open_pattern_alignment"
      phx-value-pattern-id={@natural_id}
      aria-label={"Open the map line for #{@name}: #{@text}"}
      class="group inline-flex min-h-11 items-center rounded-control focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
    >
      <span
        id={"pattern-alignment-status-#{@natural_id}"}
        class={[chip_class(@tone), "group-hover:ring-1 group-hover:ring-current"]}
      >
        <.icon name={@icon} class="size-3.5" />{@text}
      </span>
    </button>
    """
  end

  defp map_cell(assigns) do
    suggested = map_size(assigns.bulk_entry.suggestions)
    failed = map_size(assigns.bulk_entry.failed)
    assigns = assign(assigns, suggested: suggested, failed: failed)

    ~H"""
    <div class="flex flex-wrap items-center gap-x-3">
      <button
        type="button"
        id={"pattern-bulk-review-#{@natural_id}"}
        phx-click="review_bulk_suggestions"
        phx-value-pattern-id={@natural_id}
        aria-label={
          if(@suggested > 0,
            do: "Review the suggested paths for #{@name}",
            else: "Draw the sections by hand for #{@name}"
          )
        }
        class="group inline-flex min-h-11 items-center rounded-control focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        <span
          :if={@suggested > 0}
          id={"pattern-bulk-success-#{@natural_id}"}
          class={[chip_class(:warning), "group-hover:ring-1 group-hover:ring-current"]}
        >
          <.icon name="hero-clock" class="size-3.5" />Review suggestion
        </span>
        <span
          :if={@suggested == 0}
          id={"pattern-bulk-failed-#{@natural_id}"}
          class={[chip_class(:error), "group-hover:ring-1 group-hover:ring-current"]}
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5" />Draw {plural(
            @failed,
            "section",
            "sections"
          )}
        </span>
      </button>
      <p
        :if={@suggested > 0 and @failed > 0}
        id={"pattern-bulk-failed-#{@natural_id}"}
        class="-mt-1 flex items-center gap-1 pb-1 text-[13px] text-error-fg"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />{@failed} to draw by hand
      </p>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :version, :map, required: true

  defp bulk_notice(assigns) do
    %{generated: generated, total: total} = assigns.result

    assigns =
      assigns
      |> assign(:generated, generated)
      |> assign(:total, total)

    ~H"""
    <.message
      id="patterns-bulk-notice"
      kind={if(@generated == @total, do: "success", else: "warning")}
      title={"Suggested paths for #{@generated} of #{plural(@total, "section", "sections")}"}
    >
      <%= cond do %>
        <% @generated == @total -> %>
          Review each suggested path before saving it to {@version.name}.
        <% @generated == 0 -> %>
          Draw the sections by hand, or try again later.
        <% true -> %>
          Review the suggestions before saving them. Sections without a suggestion need a path you
          draw by hand.
      <% end %>
    </.message>
    """
  end

  attr :dialog, :map, default: nil
  attr :selected, :any, default: nil

  # Choose the patterns to include, see how many sections that covers, then
  # confirm. The list holds the selection, so the limit is met by unchecking.
  defp bulk_dialog(assigns) do
    assigns =
      assign(
        assigns,
        :first_id,
        assigns.dialog && List.first(assigns.dialog.candidates) &&
          "pattern-bulk-select-#{hd(assigns.dialog.candidates).id}"
      )

    ~H"""
    <.confirm_dialog
      id="alignment-bulk-dialog"
      chrome="planner"
      size="lg"
      open={@dialog != nil}
      title="Generate missing paths?"
      confirm_label="Generate paths"
      pending_label="Generating…"
      confirm_disabled={not bulk_ready?(@dialog)}
      on_confirm="confirm_bulk_generation"
      on_cancel="alignment_close_dialog"
      described_by="alignment-bulk-dialog-body"
      return_focus_id="patterns-bulk-cancel"
      data-initial-focus-id={@first_id}
    >
      <div :if={@dialog}>
        <p>
          We suggest street paths for the sections that have none. Saved and custom paths stay
          unchanged, and nothing is saved until you review each suggestion.
        </p>
        <fieldset class="mt-5">
          <legend class="text-[13px] font-[650] text-default">Patterns to include</legend>
          <ul class="mt-2 max-h-[min(320px,40vh)] divide-y divide-subtle overflow-y-auto rounded-card border border-subtle">
            <li :for={candidate <- @dialog.candidates}>
              <label class="flex min-h-14 cursor-pointer items-center gap-3 px-3 py-2 hover:bg-canvas">
                <input
                  type="checkbox"
                  id={"pattern-bulk-select-#{candidate.id}"}
                  name="bulk-pattern"
                  value={candidate.id}
                  checked={bulk_checked?(@selected, candidate.id)}
                  phx-click="toggle_bulk_select"
                  phx-value-pattern-id={candidate.id}
                  class="size-5 shrink-0 accent-action focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                />
                <span class="min-w-0 flex-1 text-sm font-[650] leading-snug text-strong [overflow-wrap:anywhere]">
                  {candidate.name}
                </span>
                <span class="shrink-0 text-[13px] tabular-nums text-muted">
                  {plural(candidate.missing, "section", "sections")}
                </span>
              </label>
            </li>
          </ul>
        </fieldset>
        <p
          id="alignment-bulk-summary"
          role="status"
          class={[
            "mt-4 flex items-start gap-2 text-sm",
            if(@dialog.too_many?,
              do: "rounded-card bg-warning-bg px-3 py-2.5 text-warning-fg",
              else: "text-strong"
            )
          ]}
        >
          <%= cond do %>
            <% @dialog.too_many? -> %>
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
              <span>
                <strong class="font-[650]">Choose fewer patterns.</strong>
                These cover {plural(@dialog.total, "section", "sections")}, and one run covers at most {RoutePatternAlignmentEvents.bulk_section_limit()}.
              </span>
            <% @dialog.total == 0 -> %>
              <span class="text-muted">Choose at least one pattern.</span>
            <% true -> %>
              <span>
                <strong class="font-[650] tabular-nums">
                  {plural(@dialog.total, "section", "sections")}
                </strong>
                in {plural(@dialog.pattern_count, "pattern", "patterns")} will get a suggested path.
              </span>
          <% end %>
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  # --- state ------------------------------------------------------------------

  # Nothing can be grouped automatically: the build found nothing waiting, or every
  # trip keeps its imported times.
  defp blocked?(assigns) do
    assigns.build_state == :blocked or
      (assigns.patterns_empty? and assigns.pending_trip_count == 0 and
         assigns.custom_trip_count > 0)
  end

  # One primary per view. Creating a pattern is the primary in the list, steps
  # back to secondary while the body offers a bigger next step (building patterns
  # from trips), and disappears when an empty state already offers it.
  defp create_mode(%{editable?: false}), do: :hidden

  defp create_mode(%{patterns_empty?: false}), do: :primary

  defp create_mode(assigns) do
    if assigns.build_failed? or assigns.pending_trip_count > 0, do: :secondary, else: :hidden
  end

  # When most patterns need paths (right after an import) the task comes first.
  defp attention_first?(candidates, pattern_count),
    do: length(candidates) > 1 and length(candidates) * 2 >= pattern_count

  defp bulk_ready?(nil), do: false
  defp bulk_ready?(%{too_many?: true}), do: false
  defp bulk_ready?(%{total: total}), do: total > 0

  defp bulk_checked?(%MapSet{} = selected, id), do: MapSet.member?(selected, id)
  defp bulk_checked?(_selected, _id), do: false

  defp bulk_entry(%{patterns: patterns}, id) when is_map(patterns) do
    case Map.get(patterns, id) do
      %{suggestions: suggestions, failed: failed} = entry
      when map_size(suggestions) > 0 or map_size(failed) > 0 ->
        entry

      _ ->
        nil
    end
  end

  defp bulk_entry(_result, _id), do: nil

  # --- wording ----------------------------------------------------------------

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(count, _one, many), do: "#{count} #{many}"

  @doc "The name a pattern goes by in lists: its name, or its ID when it has none."
  def pattern_name(pattern) do
    if blank?(pattern.route_pattern_name),
      do: pattern.route_pattern_id,
      else: pattern.route_pattern_name
  end

  defp service_description(pattern) do
    if blank?(pattern.route_pattern_time_desc),
      do: "No service description",
      else: pattern.route_pattern_time_desc
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp custom_trips_sentence(1),
    do: "1 trip on this route keeps the stop times it was imported with,"

  defp custom_trips_sentence(count),
    do: "#{count} trips on this route keep the stop times they were imported with,"

  defp build_failed_body(pending) when pending > 0 do
    "#{plural(pending, "trip is", "trips are")} still not in a pattern. Their times are unchanged. " <>
      "Try again, or create a pattern by hand."
  end

  defp build_failed_body(_pending), do: "Try again, or create a pattern by hand."

  defp build_summary_title(%{created: created}) when created > 0,
    do: "Built #{plural(created, "pattern", "patterns")} from your trips"

  defp build_summary_title(%{linked: linked}),
    do: "Added #{plural(linked, "trip", "trips")} to your patterns"

  defp build_summary_body(%{created: created, linked: linked, custom: custom})
       when created > 0 do
    kept =
      if custom > 0,
        do:
          ", and #{plural(custom, "trip keeps", "trips keep")} the stop times it was imported with",
        else: ""

    "#{plural(linked, "trip is", "trips are")} now in a pattern#{kept}. " <>
      "Open each pattern to check its stops and how it is used."
  end

  defp build_summary_body(_summary) do
    "They joined the patterns that already match their stops and direction, and their times are unchanged."
  end

  # The operator's word for a route pattern's typicality; the GTFS name stays in
  # the legend. Unset is neutral, the usual pattern is informational, and a
  # detour is the one that asks for attention.
  defp use_label(nil), do: {:neutral, "Not set"}
  defp use_label(0), do: {:neutral, "Not set"}
  defp use_label(1), do: {:info, "Typical"}
  defp use_label(2), do: {:neutral, "Deviation"}
  defp use_label(3), do: {:neutral, "Atypical"}
  defp use_label(4), do: {:warning, "Detour"}
  defp use_label(5), do: {:info, "Reference"}
  defp use_label(_typicality), do: {:neutral, "Unknown"}

  # Same precedence as the map line's summary everywhere else: missing sections,
  # then blocked, then how the saved line compares with the export.
  defp map_status(nil), do: {:neutral, "hero-minus-circle", "Not saved yet"}

  defp map_status(%{missing: missing}) when missing > 0,
    do: {:error, "hero-exclamation-triangle", "#{plural(missing, "section", "sections")} missing"}

  defp map_status(%{blocked: blocked}) when blocked > 0,
    do: {:error, "hero-x-circle", "Blocked"}

  defp map_status(%{export: :current}), do: {:success, "hero-check-circle", "Ready"}
  defp map_status(%{export: :stale}), do: {:warning, "hero-clock", "Out of date"}
  defp map_status(%{export: :imported}), do: {:neutral, "hero-document-text", "Imported line"}
  defp map_status(_status), do: {:neutral, "hero-minus-circle", "Not saved yet"}

  @chip "inline-flex items-center gap-1.5 whitespace-nowrap rounded-badge px-2 py-1 text-[13px] font-[650] leading-5"

  defp chip_class(:success), do: [@chip, "bg-success-bg text-success-fg"]
  defp chip_class(:warning), do: [@chip, "bg-warning-bg text-warning-fg"]
  defp chip_class(:error), do: [@chip, "bg-error-bg text-error-fg"]
  defp chip_class(:info), do: [@chip, "bg-info-bg text-info-fg"]
  defp chip_class(:neutral), do: [@chip, "bg-canvas text-default"]
end
