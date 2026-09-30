defmodule GtfsPlannerWeb.Gtfs.RoutePatternComponents do
  @moduledoc """
  Function components for the route pattern editor.

  The patterns list, the pattern detail header, the Details task, the ordered
  Stops task and the Timings task each render one region of the editor. State
  decisions stay in `GtfsPlannerWeb.Gtfs.RoutePatternLive`; these components
  only present the loaded values, the staged task state and the specified copy.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.RouteWorkspace, only: [badge: 1]

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlannerWeb.Gtfs.RoutePatternHeadsignComponents
  alias GtfsPlannerWeb.RouteWorkspace

  # ── The editor: header, tabs, tasks and the save bar ──
  #
  # Design-system markup for the four tasks. State decisions stay in
  # `RoutePatternLive`; these components present what they are given.

  @doc """
  Renders the pattern detail header: the location trail, the pattern name and
  its figures, the saved-state badge, the Pattern actions menu and the task
  tabs. A saved pattern also offers "Compare with another pattern", which opens
  the comparison page with this pattern as A.

  Each tab may carry one chip, given in `tab_chips` by task: `{:count, n}`,
  `:unsaved`, `:started`, `{:missing, n}` or `:blocked`. The trail's Patterns
  crumb is a button so leaving with unsaved edits asks first.
  """
  attr :creating, :boolean, required: true
  attr :route, :map, required: true
  attr :gtfs_version_id, :any, required: true
  attr :pattern_name, :string, required: true
  attr :direction_id, :integer, required: true
  attr :toward, :string, default: nil, doc: "where trips head, from the headsign"
  attr :stop_count, :integer, required: true
  attr :trip_count, :integer, required: true
  attr :timing_count, :integer, default: 0
  attr :task, :atom, required: true
  attr :tasks, :list, required: true
  attr :tab_chips, :map, default: %{}
  attr :dirty?, :boolean, required: true
  attr :show_actions, :boolean, default: false

  attr :compare_path, :string,
    default: nil,
    doc: "the compare page with this pattern as A; nil while creating one"

  def pattern_detail_header(assigns) do
    ~H"""
    <div id="pattern-header">
      <RouteWorkspace.crumbs
        id="pattern-crumbs"
        route={@route}
        gtfs_version_id={@gtfs_version_id}
        current={if @creating, do: "New pattern", else: @pattern_name}
      >
        <:section>
          <button
            type="button"
            id="pattern-back"
            phx-click="back_to_patterns"
            class="inline-flex min-h-11 items-center text-muted hover:text-strong hover:underline"
          >
            Patterns
          </button>
        </:section>
      </RouteWorkspace.crumbs>

      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3 pb-4">
        <div class="min-w-0 max-w-[1040px]">
          <h1 id="pattern-title" class="break-words">
            {if @creating, do: "Create pattern", else: @pattern_name}
          </h1>
          <p class="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-sm text-muted">
            <span id="pattern-direction">
              {RoutePattern.direction_label(@direction_id)}<span :if={@toward}> · toward {@toward}</span>
            </span>
            <span aria-hidden="true">·</span>
            <span id="pattern-stop-count">
              <strong class="font-[650] tabular-nums text-strong">{@stop_count}</strong>
              {if @stop_count == 1, do: "stop", else: "stops"}
            </span>
            <span aria-hidden="true">·</span>
            <span :if={@creating} id="pattern-trip-total">No trips yet</span>
            <span :if={not @creating} id="pattern-trip-total">
              <strong class="font-[650] tabular-nums text-strong">{@trip_count}</strong>
              {trip_count_noun(@trip_count)} {trip_verb(@trip_count)} this pattern
            </span>
            <span :if={not @creating} aria-hidden="true">·</span>
            <span :if={not @creating} id="pattern-timing-total">
              <strong class="font-[650] tabular-nums text-strong">{@timing_count}</strong>
              {if @timing_count == 1, do: "timing", else: "timings"}
            </span>
            <span :if={@compare_path} aria-hidden="true">·</span>
            <.link
              :if={@compare_path}
              id="pattern-compare"
              navigate={@compare_path}
              class="inline-flex min-h-11 items-center font-[650] text-action underline hover:text-action-hover"
            >
              Compare with another pattern
            </.link>
          </p>
        </div>

        <div class="flex shrink-0 items-center gap-2">
          <.badge
            id="edit-status"
            tone={status_tone(@dirty?, @creating)}
            icon={status_icon(@dirty?, @creating)}
          >
            {status_label(@dirty?, @creating)}
          </.badge>
          <.pattern_actions :if={@show_actions} />
        </div>
      </div>

      <nav
        id="pattern-tabs"
        aria-label="Pattern sections"
        class="-mx-4 overflow-x-auto border-b border-subtle px-4 sm:mx-0 sm:px-0"
      >
        <div class="flex min-w-max gap-1">
          <button
            :for={task <- @tasks}
            type="button"
            id={"pattern-task-#{task}"}
            phx-click="switch_task"
            phx-value-task={task}
            aria-current={@task == task && "page"}
            class="-mb-px inline-flex min-h-11 items-center gap-2 whitespace-nowrap border-b-[3px] border-transparent px-3 text-sm font-semibold text-muted hover:text-strong aria-[current=page]:border-action aria-[current=page]:text-action sm:px-4"
          >
            {task_label(task)}
            <.tab_chip chip={Map.get(@tab_chips, task)} />
          </button>
        </div>
      </nav>
    </div>
    """
  end

  attr :chip, :any, default: nil

  defp tab_chip(%{chip: nil} = assigns) do
    ~H"""
    """
  end

  defp tab_chip(%{chip: {:count, count}} = assigns) do
    assigns = assign(assigns, :count, count)

    ~H"""
    <span class="tabular-nums text-muted">{@count}</span>
    """
  end

  defp tab_chip(%{chip: :unsaved} = assigns) do
    ~H"""
    <.badge tone="warning" class="px-1.5">Unsaved</.badge>
    """
  end

  defp tab_chip(%{chip: :started} = assigns) do
    ~H"""
    <.badge tone="neutral" class="px-1.5">Started</.badge>
    """
  end

  defp tab_chip(%{chip: :blocked} = assigns) do
    ~H"""
    <.badge tone="error" class="px-1.5">Blocked</.badge>
    """
  end

  defp tab_chip(%{chip: {:missing, count}} = assigns) do
    assigns = assign(assigns, :count, count)

    ~H"""
    <.badge tone="error" class="px-1.5">{@count} missing</.badge>
    """
  end

  # Copy and Delete are two rare actions, so they share one menu. The menu is
  # the account menu's client-side dropdown (`UserMenu`), which the server never
  # re-renders: `phx-update="ignore"` keeps an open panel open across patches.
  defp pattern_actions(assigns) do
    ~H"""
    <div id="pattern-actions" phx-hook="UserMenu" phx-update="ignore" class="relative">
      <button
        type="button"
        id="pattern-actions-trigger"
        data-user-menu-trigger
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls="pattern-actions-panel"
        class="inline-flex min-h-11 items-center gap-2 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas"
      >
        Pattern actions <.icon name="hero-chevron-down" class="size-4 text-muted" />
      </button>
      <div
        id="pattern-actions-panel"
        data-user-menu-panel
        role="menu"
        aria-label="Pattern actions"
        hidden
        class="absolute right-0 top-full z-30 mt-2 w-60 rounded-card border border-subtle bg-white p-2 shadow-float"
      >
        <button
          type="button"
          id="pattern-copy"
          role="menuitem"
          phx-click={close_actions(JS.push("copy_pattern"))}
          class="flex min-h-11 w-full items-center gap-2 rounded-control px-3 text-left text-sm text-strong hover:bg-canvas focus:bg-canvas"
        >
          <.icon name="hero-document-duplicate" class="size-4 text-muted" /> Copy pattern
        </button>
        <button
          type="button"
          id="pattern-delete"
          role="menuitem"
          phx-click={close_actions(JS.push("open_delete_pattern"))}
          class="flex min-h-11 w-full items-center gap-2 rounded-control px-3 text-left text-sm text-error-fg hover:bg-canvas focus:bg-canvas"
        >
          <.icon name="hero-trash" class="size-4" /> Delete pattern
        </button>
      </div>
    </div>
    """
  end

  # The hook opens and closes the panel through `hidden` and `aria-expanded`;
  # choosing an item does the same, so the panel is not left open behind a
  # dialog the choice opens.
  defp close_actions(js) do
    js
    |> JS.set_attribute({"hidden", ""}, to: "#pattern-actions-panel")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#pattern-actions-trigger")
  end

  @doc """
  Renders the Details task: name, direction, the future-trip headsign default,
  the service description, how the pattern is used on the route, and the
  Additional details disclosure that keeps the display order and pattern ID out
  of the primary path.

  The form has no button of its own: the save bar's primary submits it through
  the `form` attribute.

  The headsign field carries the headsign surfaces: the usage line while the
  field matches the stored default, and the wording warnings plus the inline
  update box while it is edited. `headsign_usage` is the map
  `Gtfs.headsign_usage/4` returns (nil while creating, where no usage exists);
  `headsign_box` and `headsign_warnings` hold the prepared update-box and
  warning props the LiveView derives from the draft, or nil when unchanged.
  """
  attr :form, :any, required: true
  attr :submit_event, :string, required: true
  attr :pattern_id, :string, default: nil
  attr :dirty?, :boolean, required: true
  attr :headsign_usage, :map, default: nil
  attr :headsign_changed?, :boolean, default: false
  attr :headsign_box, :map, default: nil
  attr :headsign_warnings, :map, default: nil

  def details_task(assigns) do
    ~H"""
    <section
      id="pattern-details-task"
      aria-labelledby="pattern-details-heading"
      class="max-w-[720px] rounded-card border border-subtle bg-white p-5"
    >
      <h2 id="pattern-details-heading" class="text-base font-bold text-strong">Pattern details</h2>
      <p class="mt-1 text-[13px] text-muted">How this pattern is named and described in the feed.</p>

      <.form
        for={@form}
        id="pattern-details-form"
        phx-change="validate_details"
        phx-submit={@submit_event}
        class="mt-5 grid gap-5"
      >
        <.input
          field={@form[:name]}
          id="pattern-details-name"
          type="text"
          label="Pattern name"
          help="Say where trips start and end. Add a via street or landmark if it differs from another pattern."
        />
        <.input
          field={@form[:direction_id]}
          id="pattern-details-direction"
          type="select"
          label="Direction"
          options={RoutePattern.direction_options()}
          help="Patterns that run the same way share a direction. GTFS doesn’t say which value means inbound or outbound, so match what this route already uses."
        />
        <.input
          field={@form[:headsign]}
          id="pattern-details-headsign"
          type="text"
          label="Headsign (optional)"
          help="What the vehicle sign shows, such as “Lincoln City” or “Lincoln City via Depoe Bay”. Trips you add get it."
        />
        <%= cond do %>
          <% @headsign_changed? and @headsign_warnings -> %>
            <RoutePatternHeadsignComponents.wording_warnings
              id="headsign-warnings"
              warnings={@headsign_warnings.warnings}
              value={@headsign_warnings.value}
              sibling={@headsign_warnings.sibling}
              route={@headsign_warnings.route}
            />
            <RoutePatternHeadsignComponents.update_box
              id="headsign-update"
              from={@headsign_box.from}
              to={@headsign_box.to}
              followers={@headsign_box.followers}
              selected_follow={@headsign_box.selected_follow}
              extra={@headsign_box.extra}
              others={@headsign_box.others}
              shielded={@headsign_box.shielded}
              update?={@headsign_box.update?}
            />
          <% @headsign_usage -> %>
            <RoutePatternHeadsignComponents.usage_line id="headsign-usage" usage={@headsign_usage} />
          <% true -> %>
        <% end %>
        <.input
          field={@form[:time_desc]}
          id="pattern-details-description"
          type="text"
          label="When this pattern runs (optional)"
          help="A note for people reading the feed, such as “Weekday evenings only”. It doesn’t set service days; calendars do that."
        />
        <.input
          field={@form[:typicality]}
          id="pattern-details-typicality"
          type="select"
          label="Use on this route"
          options={typicality_choices()}
          help={typicality_help(@form[:typicality].value)}
        />

        <details id="pattern-details-additional" class="group rounded-card border border-subtle">
          <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 px-4 text-sm font-[650] text-strong [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right"
              class="size-4 text-muted transition-transform group-open:rotate-90"
            /> Additional details
          </summary>
          <div class="grid gap-4 px-4 pb-4">
            <.input
              field={@form[:sort_order]}
              id="pattern-details-order"
              type="number"
              min="0"
              label="Display order (optional)"
              help="Lower numbers appear first within each direction."
            />
            <p class="text-[13px] text-muted">
              Pattern ID
              <code
                id="pattern-details-id"
                class="rounded-badge bg-canvas px-1.5 py-0.5 font-mono text-[13px] text-default"
              >
                {@pattern_id || "assigned when you create the pattern"}
              </code>
            </p>
          </div>
        </details>
      </.form>
    </section>
    """
  end

  @doc """
  Renders the Stops task.

  An existing pattern shows its ordered stop occurrences with their move and
  remove controls; creating a pattern stages stops from the scoped stop search
  until the pattern is created. Custom trips block every structural control and
  explain why, and reordering is offered only while no trips use the pattern.
  """
  attr :creating, :boolean, required: true
  attr :stop_rows, :list, required: true
  attr :ring_color, :string, default: nil, doc: "the route color as normalized hex, or nil"
  attr :custom_trip_count, :integer, required: true
  attr :trip_count, :integer, required: true
  attr :timing_count, :integer, required: true
  attr :reorderable?, :boolean, required: true
  attr :dirty?, :boolean, required: true
  attr :search_form, :any, required: true
  attr :search_options, :list, required: true
  attr :search_status, :string, required: true
  attr :search_truncated?, :boolean, required: true
  attr :insert_form, :any, required: true
  attr :busy?, :boolean, default: false

  def stops_task(assigns) do
    assigns = assign(assigns, :blocked?, assigns.custom_trip_count > 0)

    ~H"""
    <section
      id="pattern-stops-task"
      aria-labelledby="pattern-stops-heading"
      class="max-w-3xl rounded-card border border-subtle bg-white"
    >
      <div class="px-4 pt-4">
        <div class="flex items-baseline justify-between gap-3">
          <h2 id="pattern-stops-heading" class="text-base font-bold text-strong">Stops in order</h2>
          <span id="pattern-stops-total" class="text-[13px] tabular-nums text-muted">
            {length(@stop_rows)} {if length(@stop_rows) == 1, do: "stop", else: "stops"}
          </span>
        </div>
        <p class="mt-1 text-[13px] text-muted">
          From the first stop to the last, including stops visited again on a loop.
        </p>

        <div :if={@blocked?} id="pattern-stops-custom" class="mt-3">
          <.message kind="warning" title="These trips have custom times">
            <strong class="tabular-nums">{@custom_trip_count}</strong>
            custom-time {trip_count_noun(@custom_trip_count)} {trip_verb(@custom_trip_count)} this pattern. They keep the stop
            times they were imported with, so the stop list can’t change while they do. Copy the
            pattern to work on separate service.
            <:action>
              <button
                id="pattern-copy-callout"
                type="button"
                phx-click="copy_pattern"
                class="btn btn-outline min-h-11"
              >
                Copy pattern
              </button>
            </:action>
          </.message>
        </div>

        <p
          :if={not @blocked? and @trip_count > 0}
          id="pattern-stops-impact"
          class="mt-3 text-[13px] text-default"
        >
          Adding or removing a stop updates <strong class="tabular-nums">{@trip_count}</strong>
          {trip_count_noun(@trip_count)} across {@timing_count} {if @timing_count == 1,
            do: "timing",
            else: "timings"}. Stops can’t be reordered while trips use this pattern. Copy the
          pattern to change the order.
        </p>
        <button
          :if={not @blocked? and @trip_count > 0}
          id="pattern-copy-inline"
          type="button"
          phx-click="copy_pattern"
          class="mt-1 -ml-2 inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 text-[13px] font-[650] text-action hover:bg-selection hover:text-action-hover"
        >
          <.icon name="hero-document-duplicate" class="size-4" /> Copy pattern
        </button>

        <p
          :if={not @blocked? and @trip_count == 0 and not @creating}
          class="mt-3 text-[13px] text-muted"
        >
          No trips use this pattern yet, so you can change its stop order freely.
        </p>
      </div>

      <div
        id="pattern-stop-add"
        class="sticky top-0 z-10 mt-3 border-y border-subtle bg-canvas px-4 py-3"
      >
        <label for="stop_search_stop_id_text_input" class={label_class()}>Add a stop</label>
        <.form for={@search_form} id="pattern-stop-search-form" phx-change="choose_stop">
          <div id="pattern-stop-search-region" class="relative mt-1.5">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-1/2 z-[1] size-5 -translate-y-1/2 text-muted"
            />
            <.live_component
              module={LiveSelect.Component}
              id="pattern-stop-search"
              field={@search_form[:stop_id]}
              options={@search_options}
              debounce={200}
              update_min_len={1}
              disabled={@blocked? or @busy?}
              placeholder="Stop name or stop ID"
              dropdown_class="absolute left-0 right-0 top-full z-20 mt-1 max-h-72 overflow-auto rounded-card border border-subtle bg-white p-1 text-strong shadow-float"
              option_class="rounded-control px-3 py-1.5"
              active_option_class="bg-selection text-strong"
              available_option_class="cursor-pointer hover:bg-canvas"
              text_input_class={field_input_class() <> " pl-10"}
            >
              <:option :let={option}>
                <span
                  id={"pattern-stop-option-#{option.value}"}
                  class="flex min-h-9 items-center justify-between gap-3 text-sm"
                >
                  <span class="min-w-0 truncate font-semibold text-strong">{option.label}</span>
                  <span class="shrink-0 text-[13px] tabular-nums text-muted">
                    Stop {option.value}
                  </span>
                </span>
              </:option>
            </.live_component>
          </div>
        </.form>

        <p
          id="pattern-stop-search-status"
          role="status"
          class={[
            "mt-1.5 text-[13px]",
            if(search_unavailable?(@search_status),
              do: "font-semibold text-error-fg",
              else: "text-muted"
            )
          ]}
        >
          {@search_status}
        </p>
        <p :if={@search_truncated?} id="pattern-stop-search-hint" class="text-[13px] text-muted">
          Refine your search to see the remaining matches.
        </p>

        <.form
          :if={not @creating}
          for={@insert_form}
          id="pattern-insert-form"
          phx-change="set_insert_after"
          class="mt-3"
        >
          <.input
            field={@insert_form[:insert_after]}
            id="pattern-insert-after"
            type="select"
            label="Insert position"
            options={insert_options(@stop_rows)}
            help="Choose where the new stop belongs before you search."
          />
        </.form>
      </div>

      <ol id="pattern-stops" data-dirty={to_string(@dirty?)} class="py-2">
        <li
          :for={row <- @stop_rows}
          id={"pattern-stop-#{row.position}"}
          tabindex="-1"
          class={[
            "stop-line relative flex min-h-[58px] items-center gap-3 px-4 py-0.5 hover:bg-canvas",
            "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus",
            new_row?(row, @creating) && "bg-canvas"
          ]}
        >
          <span
            class={[
              "relative z-[1] flex size-[30px] shrink-0 items-center justify-center rounded-full bg-white text-[13px] font-bold tabular-nums text-strong",
              if(new_row?(row, @creating),
                do: "border-2 border-dashed border-strong",
                else: "border-2 border-strong"
              )
            ]}
            style={!new_row?(row, @creating) && @ring_color && "border-color: ##{@ring_color}"}
          >
            {row.position}
          </span>
          <span class="min-w-0 flex-1 py-1">
            <span class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
              <span class="text-sm font-semibold text-strong">{row.name}</span>
              <.badge :if={new_row?(row, @creating)} tone="warning">New · unsaved</.badge>
            </span>
            <span class="block text-[13px] text-muted">
              Stop {row.stop_id}
              <span :if={row.position == 1}> · First stop</span>
              <span :if={row.last?}> · Last stop</span>
            </span>
          </span>
          <span class="flex shrink-0 items-center">
            <button
              :if={@reorderable?}
              type="button"
              id={"pattern-stop-#{row.position}-move-up"}
              phx-click="move_stop"
              phx-value-index={row.position}
              phx-value-direction="-1"
              disabled={row.position == 1 or @blocked? or @busy?}
              aria-label={"Move #{row.name} up"}
              title="Move up"
              class="btn btn-ghost btn-square min-h-11 min-w-11"
            >
              <.icon name="hero-arrow-up" class="size-4" />
            </button>
            <button
              :if={@reorderable?}
              type="button"
              id={"pattern-stop-#{row.position}-move-down"}
              phx-click="move_stop"
              phx-value-index={row.position}
              phx-value-direction="1"
              disabled={row.last? or @blocked? or @busy?}
              aria-label={"Move #{row.name} down"}
              title="Move down"
              class="btn btn-ghost btn-square min-h-11 min-w-11"
            >
              <.icon name="hero-arrow-down" class="size-4" />
            </button>
            <button
              type="button"
              id={"pattern-remove-stop-#{row.position}"}
              phx-click="remove_stop"
              phx-value-index={row.position}
              disabled={@blocked? or @busy?}
              aria-label={"Remove #{row.name}"}
              title="Remove stop"
              class="btn btn-ghost btn-square min-h-11 min-w-11"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </span>
        </li>
      </ol>

      <div :if={@stop_rows == []} id="pattern-stops-empty" class="px-6 pb-10 pt-6 text-center">
        <p class="text-sm font-bold text-strong">No stops yet</p>
        <p class="mx-auto mt-1 max-w-[40ch] text-sm text-muted">
          {if @creating,
            do: "No stops added yet. Add at least two stops before creating the pattern.",
            else: "This pattern has no saved stops. Add at least two stops to build its stop list."}
        </p>
      </div>
    </section>
    """
  end

  @doc """
  Renders the page-wide save bar, sticky at the bottom of the editor.

  The primary always names the current task ("Save stops", "Save running
  times") and the bar always says the save changes a published version. When
  nothing is unsaved the primary is disabled and the status line says why. A
  message the last action produced replaces the status line so it stays in view
  where the person acted.

  `primary` holds the button: `:id`, `:label`, `:click` (an event name or a
  `JS` command) or `:form` (an id the button submits), `:disabled?`, `:title`
  and the optional `:pending_label` shown by `phx-disable-with` while the
  submit round-trip is in flight. `secondary` optionally holds one quiet
  button with `:id`, `:label` and `:click`.
  """
  attr :primary, :map, required: true
  attr :secondary, :map, default: nil
  attr :status, :map, required: true, doc: "%{tone: atom, text: string}"
  attr :version_name, :string, required: true
  attr :creating, :boolean, default: false

  def save_bar(assigns) do
    ~H"""
    <div id="pattern-save-bar" class="pe-savebar sticky bottom-0 z-20 -mb-8 mt-6">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2 py-3">
        <div class="min-w-0 flex-1 max-sm:basis-full sm:basis-[260px]">
          <p
            id="pattern-save-status"
            class={["flex items-start gap-2 text-sm", status_text_class(@status.tone)]}
          >
            <.icon
              :if={status_bar_icon(@status.tone)}
              name={status_bar_icon(@status.tone)}
              class="mt-0.5 size-4 shrink-0"
            />
            <span class={@status.tone in [:warning, :error, :success] && "font-semibold"}>
              {@status.text}
            </span>
          </p>
          <p id="published-version-notice" class="mt-0.5 text-[13px] text-muted max-sm:hidden">
            {if @creating,
              do: "The new pattern is added to #{@version_name}, a published version.",
              else: "Changes apply to #{@version_name}, a published version, as soon as you save."}
          </p>
        </div>
        <button
          :if={@secondary}
          id={@secondary.id}
          type="button"
          phx-click={@secondary.click}
          class="btn btn-outline min-h-11 max-sm:flex-1"
        >
          {@secondary.label}
        </button>
        <button
          id={@primary.id}
          type={if @primary[:form], do: "submit", else: "button"}
          form={@primary[:form]}
          phx-click={@primary[:click]}
          phx-disable-with={@primary[:pending_label]}
          data-commit={@primary[:commit]}
          disabled={@primary.disabled?}
          data-unavailable={@primary.disabled? || nil}
          title={@primary[:title]}
          class="btn btn-primary min-h-11 max-sm:flex-1"
        >
          {@primary.label}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Running times task: the timing summaries, the elapsed arrival and
  departure inputs with their sample-trip clock times, the per-stop timepoint and
  boarding disclosures, and the timing headsign disclosure.

  Editing stays on elapsed time from the first departure, which is what the
  feed stores. A cell the person changed turns amber and an invalid cell takes a
  2px error border with its message under the row. The save button lives in the
  page's save bar.

  The timing headsign renders as a disclosure in the toolbar area: the closed
  summary names the shown value and where it comes from, and the opened body
  holds the field with the timing's usage line, or the wording warnings and the
  inline update box while the field is edited. `headsign_summary` carries the
  prepared `%{value:, own?:, pattern_value:}` the LiveView derives from the
  loaded timing and pattern; `headsign_usage`, `headsign_box` and
  `headsign_warnings` are the prepared headsign surfaces, nil when they do not
  apply. Copy, hierarchy and states follow the headsign propagation prototype.
  """
  attr :timings, :any, required: true
  attr :selected_timing, :any, required: true
  attr :timing_rows, :list, required: true
  attr :timing_form, :any, required: true
  attr :timing_options, :list, required: true
  attr :preview_time, :string, required: true
  attr :timing_headsign, :string, required: true

  attr :headsign_summary, :map,
    default: %{value: nil, own?: false, pattern_value: nil},
    doc:
      "the disclosure summary: shown value, whether the timing sets its own, and the pattern's value"

  attr :headsign_open?, :boolean, default: false
  attr :headsign_usage, :map, default: nil
  attr :headsign_changed?, :boolean, default: false
  attr :headsign_box, :map, default: nil
  attr :headsign_warnings, :map, default: nil
  attr :timing_error, :string, default: nil
  attr :custom_trip_count, :integer, required: true
  attr :dirty?, :boolean, required: true
  attr :busy?, :boolean, default: false
  attr :filling?, :boolean, default: false
  attr :timing_blank_note, :string, default: nil
  attr :blank_count, :integer, default: 0
  attr :fill, :map, default: nil
  attr :fill_preview, :map, default: nil
  attr :fill_distances, :list, default: []
  attr :fill_coords, :list, default: []
  attr :fill_sections, :list, default: []
  attr :retime, :map, default: nil
  attr :offline?, :boolean, default: false

  def timings_task(assigns) do
    assigns =
      assigns
      |> assign(:trip_count, selected_trip_count(assigns.timings, assigns.selected_timing))
      |> assign(:preview_by_position, preview_by_position(assigns[:fill_preview]))
      |> assign(:failed_positions, failed_preview_positions(assigns[:fill_preview]))
      |> assign(:riders_default, riders_default(assigns))
      |> assign(:last_row_position, last_row_position(assigns.timing_rows))

    ~H"""
    <section
      id="pattern-timings-task"
      aria-labelledby="pattern-timings-heading"
      class="rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-start justify-between gap-3 px-4 pb-3 pt-4">
        <div>
          <h2 id="pattern-timings-heading" class="text-base font-bold text-strong">Running times</h2>
          <p class="mt-1 max-w-[72ch] text-[13px] text-muted">
            A timing is one set of running times for these stops, such as a slower weekend timing.
            Each trip uses one timing.
          </p>
        </div>
        <span class="flex gap-2">
          <button
            id="timing-fill"
            type="button"
            phx-click="open_fill"
            disabled={@busy? or @filling? or @timing_rows == []}
            class="btn btn-outline min-h-11"
          >
            <.icon name="hero-clock" class="size-4" /> Fill times
          </button>
          <button
            id="timing-add"
            type="button"
            phx-click="open_timing_dialog"
            phx-value-mode="add"
            disabled={@busy? or @filling?}
            class={["btn min-h-11", if(@timings == [], do: "btn-primary", else: "btn-outline")]}
          >
            <.icon name="hero-plus" class="size-4" /> Add timing
          </button>
        </span>
      </div>

      <div
        :if={@timings == []}
        id="pattern-timings-empty"
        class="border-t border-subtle px-5 py-12 text-center"
      >
        <p class="text-sm font-bold text-strong">No timings yet</p>
        <p class="mx-auto mt-1 max-w-[46ch] text-sm text-muted">
          A pattern starts with one timing valued at zero.
        </p>
      </div>

      <div
        :if={@timings != []}
        class="flex flex-wrap items-end gap-x-4 gap-y-2 border-y border-subtle bg-canvas px-4 py-3"
      >
        <.form for={@timing_form} id="timing-form" phx-change="select_timing" class="w-full sm:w-80">
          <.input
            id="timing-select"
            name="timing_id"
            value={@selected_timing && @selected_timing.id}
            type="select"
            label="Timing"
            options={@timing_options}
            disabled={@filling?}
          />
        </.form>

        <p id="timing-summary" class="min-w-[180px] flex-1 pb-3 text-sm text-default">
          <strong class="tabular-nums">{@trip_count}</strong>
          {trip_count_noun(@trip_count)} {trip_verb(@trip_count)} this timing.
          <span :if={@custom_trip_count > 0} class="text-muted">
            {@custom_trip_count} custom-time {trip_count_noun(@custom_trip_count)} won’t change.
          </span>
          <span :if={@trip_count == 0} class="text-muted">
            Nothing uses it yet, so it can be deleted.
          </span>
        </p>

        <form id="timing-preview-form" phx-change="preview_timing" class="w-[150px]">
          <.input
            id="timing-preview"
            name="preview_time"
            value={@preview_time}
            type="text"
            label="Sample departure"
            inputmode="numeric"
            autocomplete="off"
            aria-describedby="timing-preview-help"
          />
        </form>

        <span class="flex gap-1 pb-2">
          <button
            id="timing-rename"
            type="button"
            phx-click="open_timing_dialog"
            phx-value-mode="rename"
            disabled={@busy? or @filling?}
            class="btn btn-outline min-h-11"
          >
            Rename timing
          </button>
          <button
            id="timing-delete"
            type="button"
            phx-click="open_delete_timing"
            disabled={@busy? or @filling?}
            class="btn btn-outline min-h-11"
          >
            Delete timing
          </button>
        </span>

        <p id="timing-preview-help" class="basis-full text-[13px] text-muted">
          Sample trip times are a preview: 24-hour time such as 08:00, or 25:00 for after
          midnight. Trip start times won’t change.
        </p>
      </div>

      <details
        :if={@selected_timing}
        id="timing-headsign-disclosure"
        open={@headsign_open? or @headsign_changed?}
        class="group border-t border-subtle px-4 py-1 sm:px-5"
      >
        <summary
          id="timing-headsign-summary"
          phx-click="toggle_timing_headsign_disclosure"
          class="flex min-h-11 cursor-pointer list-none flex-wrap items-center gap-x-2 text-sm [&::-webkit-details-marker]:hidden"
        >
          <.icon
            name="hero-chevron-right"
            class="size-4 text-muted transition-transform group-open:rotate-90"
          />
          <span class="font-[650] text-default">Headsign:</span>
          <RoutePatternHeadsignComponents.headsign_value value={@headsign_summary.value} />
          <span class="text-muted">
            · {if(@headsign_summary.own?, do: "this timing’s own", else: "from the pattern")}
          </span>
          <span class="ml-1 font-[650] text-action group-open:hidden">Change</span>
          <span
            :if={@headsign_usage && @headsign_usage.differ > 0}
            class="ml-auto text-[13px] text-muted group-open:hidden"
          >
            {@headsign_usage.differ} of {@headsign_usage.total} trips differ
          </span>
        </summary>
        <div class="max-w-[640px] pb-4 pl-6">
          <form id="timing-headsign-form" phx-change="validate_timing_row">
            <.input
              id="timing-headsign"
              name="timing_headsign"
              value={@timing_headsign}
              type="text"
              label={"Headsign for " <> @selected_timing.name <> " (optional)"}
              help={timing_headsign_help(@headsign_summary.pattern_value)}
            />
          </form>
          <%= cond do %>
            <% @headsign_changed? and @headsign_warnings -> %>
              <RoutePatternHeadsignComponents.wording_warnings
                id="timing-headsign-warnings"
                warnings={@headsign_warnings.warnings}
                value={@headsign_warnings.value}
                sibling={@headsign_warnings.sibling}
                route={@headsign_warnings.route}
              />
              <RoutePatternHeadsignComponents.update_box
                id="timing-headsign-update"
                from={@headsign_box.from}
                to={@headsign_box.to}
                followers={@headsign_box.followers}
                selected_follow={@headsign_box.selected_follow}
                extra={@headsign_box.extra}
                others={@headsign_box.others}
                shielded={@headsign_box.shielded}
                update?={@headsign_box.update?}
              />
            <% @headsign_usage -> %>
              <RoutePatternHeadsignComponents.usage_line
                id="timing-headsign-usage"
                usage={@headsign_usage}
                scope_label="timing"
              />
            <% true -> %>
          <% end %>
        </div>
      </details>

      <div
        :if={@timing_blank_note != nil or (@fill == nil and (@blank_count || 0) > 0)}
        id="timing-blank-note"
        class="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-subtle bg-canvas px-4 py-3"
      >
        <p class="min-w-[180px] flex-1 text-sm text-default">
          {@timing_blank_note || blank_note_text(@blank_count)}
        </p>
        <button
          id="timing-blank-fill"
          type="button"
          phx-click="open_fill"
          disabled={@busy? or @filling?}
          class="btn btn-outline min-h-11"
        >
          Fill times
        </button>
      </div>

      <div
        :if={@retime != nil}
        id="timing-retime"
        class="mb-3 rounded-card border border-subtle bg-white px-4 py-3"
      >
        <p class="text-sm text-default">
          Stop {@retime.anchor} moved by {format_retime_delta(@retime.moved_seconds)}. {retime_stops_text(
            @retime.stops
          )} Select re-estimate to preview only the
          stops around it.
        </p>
        <div class="mt-2 flex gap-2">
          <button
            id="timing-retime-go"
            type="button"
            phx-click="reestimate"
            phx-value-anchor={@retime.anchor}
            class="btn btn-outline min-h-11"
          >
            Re-estimate around stop {@retime.anchor}
          </button>
          <button
            id="timing-retime-dismiss"
            type="button"
            phx-click="dismiss_retime"
            class="btn btn-ghost min-h-11"
          >
            Dismiss
          </button>
        </div>
      </div>

      <div
        :if={@timing_rows != []}
        class={@fill != nil && "grid items-start lg:grid-cols-[minmax(0,1fr)_minmax(0,22rem)]"}
      >
        <div
          :if={@fill != nil and @fill_preview != nil}
          class="order-first border-b border-subtle lg:order-last lg:border-b-0 lg:border-l"
        >
          <.fill_panel
            fill={@fill}
            preview={@fill_preview}
            rows={@timing_rows}
            distances={@fill_distances}
            coords={@fill_coords}
            sections={@fill_sections}
            offline?={@offline?}
          />
        </div>
        <div class={@fill != nil && "order-last min-w-0 lg:order-first"}>
          <div class="px-4 py-3">
            <.message
              kind="info"
              id="timing-origin"
              title="Times are measured from the first departure"
            >
              Enter minutes:seconds, for example 04:30. The first arrival is relative to the first
              departure, so a negative first arrival keeps a terminal arrival that happens before its
              departure. Departure can be later than arrival to allow waiting.
            </.message>
          </div>

          <form id="timing-edit-form" phx-change="validate_timing_row">
            <table id="timing-table" class="pe-times w-full border-collapse text-left">
              <caption class="sr-only">
                Running times for {@selected_timing && @selected_timing.name}
              </caption>
              <thead>
                <tr>
                  <th scope="col" class="pl-4">Stop</th>
                  <th scope="col">
                    Arrive
                    <span class="block text-xs font-normal text-muted">min:sec from start</span>
                  </th>
                  <th scope="col">
                    Depart
                    <span class="block text-xs font-normal text-muted">min:sec from start</span>
                  </th>
                  <th scope="col">
                    Sample trip
                    <span class="block text-xs font-normal text-muted">arrive → depart</span>
                  </th>
                  <th scope="col">
                    Riders see
                    <span class="block text-xs font-normal text-muted">headsign at this stop</span>
                  </th>
                  <th scope="col">Timepoint</th>
                </tr>
              </thead>
              <tbody id="timing-rows">
                <%= for row <- @timing_rows do %>
                  <.timing_row
                    row={row}
                    timing_error={@timing_error}
                    preview_row={Map.get(@preview_by_position, row.position)}
                    failed_preview?={MapSet.member?(@failed_positions, row.position)}
                    riders_default={@riders_default}
                    last?={row.position == @last_row_position}
                  />
                <% end %>
              </tbody>
            </table>

            <div class="border-t border-subtle p-4 text-[13px] text-muted">
              <p class="font-[650] text-default">About timepoints and boarding</p>
              <p id="timing-help-timepoint" class="mt-1">
                A timepoint is a stop with a published time. Buses wait there if they’re early.
                Unchecked stops show estimated times.
              </p>
              <p id="timing-help" class="mt-1">
                Pickup and drop-off options: Regular, Not available, Phone the agency, or Arrange
                with the driver.
              </p>
            </div>
          </form>
        </div>
      </div>
    </section>
    """
  end

  # The disclosure field's help names the pattern headsign the blank falls back
  # to, per the prototype's copy.
  defp timing_headsign_help(pattern_value)
       when is_binary(pattern_value) and pattern_value != "" do
    "Leave blank to use the pattern’s headsign, #{pattern_value}. Set one only when every trip on " <>
      "this timing shows a different destination, such as a school timing signed “Lincoln City " <>
      "via Taft High”."
  end

  defp timing_headsign_help(_pattern_value) do
    "Leave blank to use the pattern’s headsign. Set one only when every trip on this timing shows " <>
      "a different destination, such as a school timing signed “Lincoln City via Taft High”."
  end

  # The Riders see column's muted fallback: the timing's effective default, the
  # value the prototype's `norm(t.headsign) || pv()` shows on rows without a
  # stop headsign.
  defp riders_default(%{selected_timing: %{headsign: timing_headsign}} = assigns) do
    Headsigns.effective_default(timing_headsign, assigns.headsign_summary.pattern_value)
  end

  defp riders_default(_), do: nil

  # The final row's "Last stop · none" wins over a stop headsign there, as the
  # prototype's `last ? … : stopHs ? …` does.
  defp last_row_position([]), do: nil
  defp last_row_position(rows), do: List.last(rows).position

  attr :row, :map, required: true
  attr :timing_error, :string, default: nil
  attr :preview_row, :map, default: nil
  attr :failed_preview?, :boolean, default: false

  attr :riders_default, :string,
    default: nil,
    doc: "the timing's effective default, shown muted when the stop sets no headsign"

  attr :last?, :boolean, default: false

  defp timing_row(assigns) do
    assigns =
      assigns
      |> assign(:arrival_edited?, time_edited?(assigns.row, :arrival))
      |> assign(:departure_edited?, time_edited?(assigns.row, :departure))
      |> assign(:estimated?, Map.get(assigns.row, :estimated, false))
      |> assign(
        :preview_estimate?,
        assigns[:preview_row] != nil and assigns.preview_row.estimated
      )
      |> assign(:chips, board_chips(assigns.row))
      |> assign(:stop_headsign, Headsigns.normalize(assigns.row.stop_headsign))
      |> assign(
        :error?,
        assigns.row.arrival_error == true or assigns.row.departure_error == true
      )

    ~H"""
    <tr
      id={"timing-row-#{@row.position}"}
      class={["pe-row", (@estimated? or @preview_estimate?) && "bg-soft/60"]}
    >
      <th scope="row" class="pe-cell-stop">
        <span class="flex items-baseline gap-2">
          <span class="w-5 shrink-0 text-[13px] tabular-nums text-muted">{@row.position}</span>
          <span class="min-w-0">
            <span class="block text-sm font-semibold text-strong">{@row.name}</span>
            <span class="mt-0.5 flex flex-wrap items-center gap-1 text-[13px] font-normal text-muted">
              <span>Stop {@row.stop_id}</span>
              <.badge :if={@estimated?} tone="info">Estimated</.badge>
              <span
                :for={chip <- @chips}
                class="rounded-badge bg-canvas px-1.5 py-0.5 text-xs font-semibold text-muted"
              >
                {chip}
              </span>
            </span>
          </span>
        </span>
      </th>
      <td>
        <%= if @preview_estimate? do %>
          <div
            id={"timing-cell-estimate-#{@row.position}"}
            class="flex h-11 w-[104px] items-center rounded-control border border-dashed border-cyan-700 bg-soft px-3 text-sm font-semibold tabular-nums text-cyan-800"
            title="Estimate, not saved"
          >
            {GtfsTime.format_offset(@preview_row.arrival)}
          </div>
          <p class="mt-0.5 text-[12px] tabular-nums text-muted">
            <%= case was_state(@preview_row.previous, @preview_row.arrival) do %>
              <% :blank -> %>
                was blank
              <% :same -> %>
                no change
              <% {:changed, was} -> %>
                was <s>{GtfsTime.format_offset(was)}</s>
            <% end %>
          </p>
        <% else %>
          <label class="pe-cell-label" for={"timing-arrival-#{@row.position}"}>
            {if @row.position == 1,
              do: "Arrival relative to first departure",
              else: "Arrive (min:sec)"}
            <span class="sr-only">at {@row.name}</span>
          </label>
          <input
            id={"timing-arrival-#{@row.position}"}
            name={"timing[#{@row.position}][arrival]"}
            type="text"
            inputmode="numeric"
            autocomplete="off"
            value={@row.arrival}
            data-estimated={if(Map.get(@row, :estimated), do: "true")}
            aria-invalid={@row.arrival_error && "true"}
            aria-describedby={@row.arrival_error && "timing-error-#{@row.position}"}
            class={time_input_class(@row.arrival_error, @arrival_edited?, @estimated?)}
          />
          <p
            :if={@failed_preview? and blank_value?(@row.arrival) and blank_value?(@row.departure)}
            class="mt-0.5 text-[12px] italic text-muted"
          >
            Not filled
          </p>
        <% end %>
      </td>
      <td>
        <%= if @preview_estimate? do %>
          <div
            class="flex h-11 w-[104px] items-center rounded-control border border-dashed border-cyan-700 bg-soft px-3 text-sm font-semibold tabular-nums text-cyan-800"
            title="Estimate, not saved"
          >
            {GtfsTime.format_offset(@preview_row.departure)}
          </div>
        <% else %>
          <label class="pe-cell-label" for={"timing-departure-#{@row.position}"}>
            Depart (min:sec)<span class="sr-only"> at {@row.name}</span>
          </label>
          <input
            id={"timing-departure-#{@row.position}"}
            name={"timing[#{@row.position}][departure]"}
            type="text"
            inputmode="numeric"
            autocomplete="off"
            value={@row.departure}
            data-estimated={if(Map.get(@row, :estimated), do: "true")}
            aria-invalid={@row.departure_error && "true"}
            aria-describedby={@row.departure_error && "timing-error-#{@row.position}"}
            class={time_input_class(@row.departure_error, @departure_edited?, @estimated?)}
          />
        <% end %>
      </td>
      <td class="pe-cell-sample">
        <span class="pe-cell-label">Sample trip</span>
        <span
          id={"timing-preview-#{@row.position}"}
          class="block text-sm tabular-nums text-strong"
        >
          {sample_trip(@row)}
        </span>
      </td>
      <td
        id={"timing-riders-#{@row.position}"}
        class={["pe-cell-riders", @stop_headsign && "bg-info-bg/60"]}
      >
        <span class="pe-cell-label">Riders see</span>
        <%= cond do %>
          <% @last? -> %>
            <span class="text-[13px] text-muted">Last stop · none</span>
          <% @stop_headsign -> %>
            <span class="text-sm font-[650] text-strong">{@stop_headsign}</span>
            <span class="block text-[12px] text-muted">Set at this stop</span>
          <% is_nil(@riders_default) -> %>
            <span class="text-sm italic text-muted">No headsign</span>
          <% true -> %>
            <span class="text-sm text-muted">{@riders_default}</span>
        <% end %>
      </td>
      <td class="pe-cell-timepoint">
        <label
          class="flex min-h-11 cursor-pointer items-center gap-2 text-sm"
          for={"timing-timepoint-#{@row.position}"}
        >
          <input type="hidden" name={"timing[#{@row.position}][timepoint]"} value="0" />
          <input
            id={"timing-timepoint-#{@row.position}"}
            name={"timing[#{@row.position}][timepoint]"}
            type="checkbox"
            value="1"
            checked={@row.timepoint}
            class="checkbox"
          />
          <span class="md:sr-only">Timepoint</span>
          <span class="sr-only">at {@row.name}</span>
        </label>
      </td>
    </tr>
    <tr :if={@error?} id={"timing-err-#{@row.position}"} class="pe-err-row">
      <td colspan="6" id={"timing-error-#{@row.position}"}>
        <.icon name="hero-exclamation-triangle" class="mr-1.5 inline size-4 align-[-3px]" />
        Stop {@row.position}, {@row.name}: {@timing_error || "Check this time."}
      </td>
    </tr>
    <tr id={"timing-options-#{@row.position}"} class="pe-options-row">
      <td colspan="6">
        <details id={"timing-boarding-#{@row.position}"} class="group">
          <summary class="flex min-h-11 cursor-pointer list-none items-center gap-1.5 text-[13px] font-[650] text-muted hover:text-strong [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right"
              class="size-4 transition-transform group-open:rotate-90"
            /> Boarding options<span class="sr-only"> for {@row.name}</span>
          </summary>
          <div class="grid gap-4 pb-3 pl-5 sm:grid-cols-2">
            <div class="fieldset">
              <label>
                <span class="label">Pickup</span>
                <select
                  id={"timing-pickup-#{@row.position}"}
                  name={"timing[#{@row.position}][pickup]"}
                  class="w-full select select-lg"
                >
                  <option
                    :for={option <- pickup_options()}
                    value={option.value}
                    selected={@row.pickup == option.value}
                  >
                    {option.label}
                  </option>
                </select>
              </label>
              <p>Can riders board here? Phone and driver options are for request stops.</p>
            </div>
            <div class="fieldset">
              <label>
                <span class="label">Drop-off</span>
                <select
                  id={"timing-dropoff-#{@row.position}"}
                  name={"timing[#{@row.position}][drop_off]"}
                  class="w-full select select-lg"
                >
                  <option
                    :for={option <- pickup_options()}
                    value={option.value}
                    selected={@row.drop_off == option.value}
                  >
                    {option.label}
                  </option>
                </select>
              </label>
              <p>Can riders get off here?</p>
            </div>
            <div class="fieldset sm:col-span-2">
              <label>
                <span class="label">Stop headsign (optional)</span>
                <input
                  id={"timing-stop-headsign-#{@row.position}"}
                  name={"timing[#{@row.position}][headsign]"}
                  type="text"
                  value={@row.stop_headsign}
                  class="w-full input input-lg"
                />
              </label>
              <p>Use only if the destination shown to riders changes at this stop.</p>
            </div>
          </div>
        </details>
      </td>
    </tr>
    """
  end

  @doc """
  Renders the Fill times between timepoints preview panel: the not-saved
  header, the preview summary, the scope/method options, the problem and pace
  warnings with buttons that focus the stop to fix, the server-rendered "Time
  along the route" chart and the `#fill-map` payload container step 14 mounts
  the Leaflet preview from.

  `preview` is a `GtfsPlanner.Gtfs.TimingFill.preview/4` result, `rows` are
  the staged timing rows (for stop names), `distances` are cumulative metres
  per visit and `coords` are `{lat, lon}` tuples or nil per visit.
  """
  attr :fill, :map, required: true
  attr :preview, :map, required: true
  attr :rows, :list, default: []
  attr :distances, :list, default: []
  attr :coords, :list, default: []
  attr :sections, :list, default: []
  attr :offline?, :boolean, default: false

  def fill_panel(assigns) do
    map_payload =
      fill_map_payload(assigns.rows, assigns.coords, assigns.preview, assigns[:sections] || [])

    assigns =
      assigns
      |> assign(:names, Map.new(assigns.rows, &{&1.position, &1.name}))
      |> assign(:straight_count, straight_preview_spans(assigns.preview))
      |> assign(:straight_map?, straight_map?(map_payload))
      |> assign(:map_json, Jason.encode!(map_payload))

    ~H"""
    <aside
      id="fill-panel"
      aria-labelledby="fill-title"
      phx-window-keydown="cancel_fill"
      phx-key="escape"
      class="min-w-0 bg-white"
    >
      <div class="flex items-start gap-3 border-b border-subtle bg-soft px-4 py-3">
        <div class="min-w-0 flex-1">
          <.badge tone="info">Preview · not saved</.badge>
          <h2 id="fill-title" tabindex="-1" class="mt-2 text-lg font-bold text-strong">
            Fill times between timepoints
          </h2>
        </div>
        <button
          id="fill-close"
          type="button"
          phx-click="cancel_fill"
          aria-label="Cancel filling times"
          title="Cancel"
          class="btn btn-ghost min-h-11 px-2"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <div class="grid gap-4 px-4 py-3">
        <p id="fill-summary" role="status" class="text-sm text-strong">{@preview.summary}</p>

        <p
          :if={@fill.only_anchor != nil}
          class="rounded-control bg-canvas px-3 py-2 text-[13px] text-default"
        >
          Only the sections next to <strong>{Map.get(@names, @fill.only_anchor + 1, "stop #{@fill.only_anchor + 1}")}</strong>.
        </p>

        <.form
          for={to_form(%{"scope" => to_string(@fill.scope), "method" => to_string(@fill.method)})}
          id="fill-form"
          phx-change="change_fill"
          class="grid gap-4"
        >
          <fieldset>
            <legend class="text-sm font-[650] text-default">Fill</legend>
            <div class="mt-1 grid gap-2">
              <label class="flex cursor-pointer items-center gap-2 rounded-control border border-subtle px-3 py-2 text-sm">
                <input
                  id="fill-scope-missing"
                  type="radio"
                  name="scope"
                  value="missing"
                  checked={@fill.scope == :missing}
                  class="radio"
                />
                <span>
                  <span class="block font-semibold text-strong">Stops without times</span>
                  <span class="block text-[13px] text-default">
                    Keeps every time already entered.
                  </span>
                </span>
              </label>
              <label class="flex cursor-pointer items-center gap-2 rounded-control border border-subtle px-3 py-2 text-sm">
                <input
                  id="fill-scope-between"
                  type="radio"
                  name="scope"
                  value="between"
                  checked={@fill.scope == :between}
                  class="radio"
                />
                <span>
                  <span class="block font-semibold text-strong">
                    Every stop between timepoints
                  </span>
                  <span class="block text-[13px] text-default">
                    Replaces times typed at other stops too. To keep one, make that stop a
                    timepoint.
                  </span>
                </span>
              </label>
            </div>
          </fieldset>
          <fieldset>
            <legend class="text-sm font-[650] text-default">Share the time by</legend>
            <div class="mt-1 grid gap-2">
              <label class="flex cursor-pointer items-center gap-2 rounded-control border border-subtle px-3 py-2 text-sm">
                <input
                  id="fill-method-distance"
                  type="radio"
                  name="method"
                  value="distance"
                  checked={@fill.method == :distance}
                  class="radio"
                />
                <span>
                  <span class="block font-semibold text-strong">Distance along the path</span>
                  <span class="block text-[13px] text-default">
                    Stops farther apart get more of the time.
                  </span>
                </span>
              </label>
              <label class="flex cursor-pointer items-center gap-2 rounded-control border border-subtle px-3 py-2 text-sm">
                <input
                  id="fill-method-even"
                  type="radio"
                  name="method"
                  value="even"
                  checked={@fill.method == :even}
                  class="radio"
                />
                <span>
                  <span class="block font-semibold text-strong">Equal time per stop</span>
                  <span class="block text-[13px] text-default">
                    Same share for every stop, whatever the distance.
                  </span>
                </span>
              </label>
            </div>
          </fieldset>
        </.form>

        <div
          :if={@preview.problems != [] or @preview.fast_spans != [] or @straight_count > 0}
          id="fill-problems"
          class="grid gap-2"
        >
          <div
            :for={problem <- @preview.problems}
            class="rounded-control bg-error-bg px-3 py-2"
          >
            <p class="text-sm text-error-fg">{problem.message}</p>
            <button
              type="button"
              phx-click="focus_form_error"
              phx-value-id={"timing-arrival-#{problem.position}"}
              class="inline-flex min-h-11 items-center text-sm font-[650] text-error-fg underline underline-offset-4"
            >
              Go to stop {problem.position}
            </button>
          </div>
          <div
            :for={fast <- @preview.fast_spans}
            class="rounded-control bg-warning-bg px-3 py-2"
          >
            <p class="text-sm text-warning-fg">
              Check the times from {stop_name(@names, fast.from_position)} to {stop_name(
                @names,
                fast.to_position
              )}. The bus would average {round(fast.mph)} mph there. Estimates follow
              the timepoints, so fix those first.
            </p>
            <button
              type="button"
              phx-click="focus_form_error"
              phx-value-id={"timing-arrival-#{fast.to_position}"}
              class="inline-flex min-h-11 items-center text-sm font-[650] text-warning-fg underline underline-offset-4"
            >
              Go to stop {fast.to_position}
            </button>
          </div>
          <div
            :if={@straight_count > 0 and @fill.method == :distance}
            class="rounded-control bg-warning-bg px-3 py-2"
          >
            <p class="text-sm text-warning-fg">
              {straight_span_text(@straight_count)} use the straight line between stops,
              which is shorter than the road. Stops there may get too little time.
            </p>
            <button
              id="fill-use-even"
              type="button"
              phx-click="change_fill"
              phx-value-method="even"
              class="inline-flex min-h-11 items-center text-sm font-[650] text-warning-fg underline underline-offset-4"
            >
              Use equal time per stop
            </button>
          </div>
        </div>
      </div>

      <div class="border-t border-subtle px-4 pb-3 pt-3">
        <div class="flex items-baseline justify-between gap-3">
          <h3 class="text-sm font-bold text-strong">Time along the route</h3>
          <p class="text-[13px] text-muted">Steeper is slower</p>
        </div>
        <.fill_profile preview={@preview} distances={@distances} />
      </div>

      <div class="border-t border-subtle px-4 pb-4 pt-3">
        <h3 class="text-sm font-bold text-strong">On the map</h3>
        <div
          id="fill-map"
          phx-hook="FillPreviewMap"
          phx-update="ignore"
          data-fill-map={@map_json}
          class="mt-2 h-[320px] rounded-card border border-subtle bg-canvas"
        />
        <p id="fill-map-legend" class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-muted">
          <span class="inline-flex items-center gap-1.5">
            <span class="inline-block size-3 rounded-[3px] bg-navy-700"></span>Timepoint
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span class="inline-block size-2.5 rounded-full border-2 border-dashed border-cyan-700 bg-cyan-50"></span>Estimate
          </span>
          <span :if={@straight_map?} class="inline-flex items-center gap-1.5">
            <span class="inline-block w-4 border-t-2 border-dashed border-warning-fg"></span>No path, straight line
          </span>
        </p>
        <p id="fill-map-error" hidden class="mt-2 text-[13px] text-warning-fg">
          Map preview unavailable. The fill summary above still applies.
        </p>
        <p class="mt-2 text-[13px] text-muted">
          Estimates are not saved until you save running times.
        </p>
      </div>

      <div class="flex flex-wrap items-center justify-end gap-2 border-t border-subtle px-4 py-3">
        <p class="mr-auto min-w-[150px] flex-1 text-[13px] text-muted">
          {fill_footer_note(@preview.changed, @offline?)}
        </p>
        <button
          id="fill-cancel"
          type="button"
          phx-click="cancel_fill"
          class="btn btn-outline min-h-11"
        >
          Cancel
        </button>
        <button
          id="fill-apply"
          type="button"
          phx-click="apply_fill"
          disabled={@preview.changed == 0}
          class="btn btn-primary min-h-11"
        >
          {fill_apply_label(@preview)}
        </button>
      </div>
    </aside>
    """
  end

  @doc """
  Renders the "Time along the route" chart for a fill preview as an inline
  SVG: distance along the path runs left to right, time from the start runs
  top to bottom. Timed rows the fill keeps are squares, estimated rows are
  circles, and every span with a known pace carries a speed label — bold
  warning text when the span implies more than 60 mph.
  """
  attr :preview, :map, required: true
  attr :distances, :list, default: []

  def fill_profile(assigns) do
    assigns = assign(assigns, :profile, build_profile(assigns.preview, assigns.distances))

    ~H"""
    <div id="fill-profile" class="mt-2">
      <svg
        viewBox="0 0 480 220"
        role="img"
        aria-label="Time along the route"
        class="block h-auto w-full"
      >
        <line
          :for={grid <- @profile.grid}
          x1={grid.x1}
          x2={grid.x2}
          y1={grid.y}
          y2={grid.y}
          class="stroke-subtle"
          stroke-width="1"
        />
        <text
          :for={grid <- @profile.grid}
          x={grid.label_x}
          y={grid.label_y}
          text-anchor="end"
          font-size="11"
          class="fill-muted"
        >
          {grid.label}
        </text>
        <line
          :for={hop <- @profile.hops}
          x1={hop.x1}
          y1={hop.y1}
          x2={hop.x2}
          y2={hop.y2}
          stroke-width="2.5"
          stroke-dasharray={hop.straight? && "6 4"}
          class={if hop.straight?, do: "stroke-warning-fg", else: "stroke-strong"}
        />
        <line
          :for={dwell <- @profile.dwells}
          x1={dwell.x}
          x2={dwell.x}
          y1={dwell.y1}
          y2={dwell.y2}
          stroke-width="2.5"
          class="stroke-strong"
        />
        <line
          :for={tick <- @profile.ticks}
          x1={tick.x}
          x2={tick.x}
          y1={tick.y1}
          y2={tick.y2}
          stroke-width="2"
          class="stroke-error-line"
        />
        <rect
          :for={anchor <- @profile.anchors}
          x={anchor.x}
          y={anchor.y}
          width="9"
          height="9"
          rx="1.5"
          fill="currentColor"
          class="text-strong"
        />
        <circle
          :for={estimate <- @profile.estimates}
          cx={estimate.x}
          cy={estimate.y}
          r="4.5"
          fill="currentColor"
          class="text-cyan-700"
        />
        <text
          :for={label <- @profile.labels}
          x={label.x}
          y={label.y}
          text-anchor="middle"
          font-size="11"
          class={if label.fast?, do: "fill-warning-fg font-bold", else: "fill-muted"}
        >
          {label.text}
        </text>
        <text
          x={@profile.x_left}
          y={@profile.x_base}
          text-anchor="start"
          font-size="11"
          class="fill-muted"
        >
          0
        </text>
        <text
          x={@profile.x_right}
          y={@profile.x_base}
          text-anchor="end"
          font-size="11"
          class="fill-muted"
        >
          {@profile.x_max_label} along the path
        </text>
      </svg>
      <p class="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-muted">
        <span class="inline-flex items-center gap-1.5">
          <span class="inline-block size-2.5 rounded-[2px] bg-strong"></span>Timepoint or kept time
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="inline-block size-2.5 rounded-full border-2 border-cyan-700 bg-soft"></span>Estimate
        </span>
        <span
          :if={Enum.any?(@preview.spans, &(&1.source == :straight_line and &1.error == nil))}
          class="inline-flex items-center gap-1.5"
        >
          <span class="inline-block w-4 border-t-2 border-dashed border-warning-fg"></span>No path,
          straight line
        </span>
      </p>
    </div>
    """
  end

  @doc """
  Renders the pre-apply review for a staged stop edit.

  Every timing's proposed added-stop values, estimates and trip count are shown
  before the final action, and each timing must be acknowledged separately so a
  value the reviewer never saw can never be silently confirmed. While an
  acknowledgement is missing, the dialog says why the confirm is unavailable.
  """
  attr :review, :any, required: true
  attr :confirm_label, :string, required: true
  attr :ready?, :boolean, required: true
  attr :requires_acknowledgement?, :boolean, required: true
  attr :version_name, :string, required: true

  def stop_review_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="stop-review-dialog"
      open={@review != nil}
      title={review_title(@review, "Save these stops?")}
      confirm_label={@confirm_label}
      pending_label="Updating…"
      on_confirm="apply_stop_review"
      on_cancel="cancel_review"
      described_by="stop-review-dialog-body"
      confirm_variant="primary"
      chrome="planner"
      size="xl"
      confirm_disabled={not @ready?}
      pending={@review != nil and @review.busy}
      return_focus_id="pattern-save-stops"
    >
      <form :if={@review} id="stop-review-values-form" phx-change="update_review_value">
        <p>
          This updates every timing on this pattern.
          <strong class="text-strong">This changes {@version_name}, a published version.</strong>
        </p>

        <div class={[
          "mt-3 flex gap-3 rounded-card bg-error-bg px-4 py-3 text-error-fg",
          is_nil(@review.error) && "hidden"
        ]}>
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
          <div>
            <p id="stop-review-error" role="alert" class="font-bold">
              {@review.error && @review.error.message}
            </p>
            <button
              :if={@review.error && @review.error.action == :refresh}
              id="stop-review-refresh"
              type="button"
              phx-click="refresh_review"
              class="btn btn-outline mt-2 min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh review
            </button>
            <button
              :if={@review.error && @review.error.action == :retry}
              id="stop-review-retry"
              type="button"
              phx-click="retry_review"
              class="btn btn-outline mt-2 min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Try review again
            </button>
          </div>
        </div>

        <p :if={@review.resequenced?} id="stop-review-reorder-note" class="mt-2">
          The stop order changed, so each timing keeps its times by position: the first stop keeps the first time, the second stop the second, and so on. Check the times below and adjust them on the Timings tab after saving.
        </p>

        <div
          :for={block <- @review.blocks}
          id={"stop-review-timing-#{block.timing_id}"}
          class="mt-3 rounded-card border border-subtle p-3"
        >
          <p class="text-sm font-[650] text-strong">
            {block.name}
            <span class="font-normal text-muted">
              · {block.trip_count_label}
              <span :if={block.shift}>{" · start shifts by " <> block.shift}</span>
            </span>
          </p>

          <p
            :if={block.added == [] and block.resequenced == []}
            class="mt-1 text-[13px] text-muted"
          >
            No added stops in this timing. Its retained times stay as they are.
          </p>

          <ul
            :if={block.resequenced != []}
            id={"stop-review-resequenced-#{block.timing_id}"}
            class="mt-2 divide-y divide-subtle text-sm"
          >
            <li
              :for={row <- block.resequenced}
              id={"stop-review-resequenced-#{block.timing_id}-#{row.id}"}
              class="flex flex-wrap justify-between gap-x-4 py-1"
            >
              <span class="font-medium">{row.name}</span>
              <span class="tabular-nums">Arrive {row.arrival} · Depart {row.departure}</span>
            </li>
          </ul>

          <div
            :for={added <- block.added}
            class="mt-2 grid items-end gap-2 sm:grid-cols-[minmax(0,1fr)_112px_112px]"
          >
            <p class="text-sm">
              <span class="block font-semibold text-strong">{added.name}</span>
              <span :if={added.estimated?} class="text-[13px] text-muted">
                Estimated between its neighbours
              </span>
            </p>
            <div>
              <label
                class={label_class()}
                for={"stop-review-value-#{block.timing_id}-#{added.key}-arrival"}
              >
                Arrive
              </label>
              <input
                id={"stop-review-value-#{block.timing_id}-#{added.key}-arrival"}
                name={"review[#{block.timing_id}][#{added.key}][arrival]"}
                type="text"
                inputmode="numeric"
                autocomplete="off"
                value={added.arrival}
                aria-invalid={added.invalid? && "true"}
                aria-describedby={added.invalid? && "stop-review-error"}
                class={[
                  "mt-1 tabular-nums",
                  field_input_class(),
                  added.invalid? && "border-2 border-error-fg"
                ]}
              />
            </div>
            <div>
              <label
                class={label_class()}
                for={"stop-review-value-#{block.timing_id}-#{added.key}-departure"}
              >
                Depart
              </label>
              <input
                id={"stop-review-value-#{block.timing_id}-#{added.key}-departure"}
                name={"review[#{block.timing_id}][#{added.key}][departure]"}
                type="text"
                inputmode="numeric"
                autocomplete="off"
                value={added.departure}
                aria-invalid={added.invalid? && "true"}
                aria-describedby={added.invalid? && "stop-review-error"}
                class={[
                  "mt-1 tabular-nums",
                  field_input_class(),
                  added.invalid? && "border-2 border-error-fg"
                ]}
              />
            </div>
          </div>

          <label
            class="mt-2 flex min-h-11 cursor-pointer items-center gap-2 text-sm"
            for={"stop-review-ack-#{block.timing_id}"}
          >
            <input
              id={"stop-review-ack-#{block.timing_id}"}
              type="checkbox"
              checked={block.acknowledged}
              data-acknowledged={to_string(block.acknowledged)}
              phx-click="acknowledge_review_timing"
              phx-value-timing_id={block.timing_id}
              class="checkbox"
            />
            <span>I reviewed these values for {block.name}.</span>
          </label>
        </div>

        <p :if={not @review.resequenced?} class="mt-3 text-[13px] text-muted">
          Retained stop times keep their absolute clocks; added stop times are what this review
          applies. The path on the map isn’t redrawn, so check Alignment afterward.
        </p>
        <p
          :if={@requires_acknowledgement? and not @ready? and is_nil(@review.error)}
          id="stop-review-why"
          class="mt-2 text-[13px] font-semibold text-default"
        >
          Confirm the values for every timing to continue.
        </p>
        <p :if={@review.resequenced?} class="mt-3 text-[13px] text-muted">
          The listed times replace the stored times; added stop times are what this review
          applies. Geometry is not recalculated.
        </p>
      </form>
    </.confirm_dialog>
    """
  end

  @doc "Renders the confirmation for a timing save that updates trips."
  attr :review, :any, required: true
  attr :version_name, :string, required: true

  def timing_review_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="timing-review-dialog"
      confirm_disabled={@review != nil and @review.error != nil}
      open={@review != nil}
      title={review_title(@review, "Update trips?")}
      confirm_label="Update trips"
      pending_label="Updating…"
      on_confirm="apply_timing_review"
      on_cancel="cancel_timing_review"
      described_by="timing-review-dialog-body"
      confirm_variant="primary"
      chrome="planner"
      pending={@review != nil and @review.busy}
      return_focus_id="timing-save"
    >
      <div :if={@review}>
        <p>
          This saves the selected timing and updates the arrival and departure times of its trips.
          Trip start times stay the same.
          <strong class="text-strong">This changes {@version_name}, a published version.</strong>
        </p>
        <div class={[
          "mt-3 flex gap-3 rounded-card bg-error-bg px-4 py-3 text-error-fg",
          is_nil(@review.error) && "hidden"
        ]}>
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
          <div>
            <p id="timing-review-error" role="alert" class="font-bold">
              {@review.error && @review.error.message}
            </p>
            <button
              :if={@review.error && @review.error.action == :refresh}
              id="timing-review-refresh"
              type="button"
              phx-click="refresh_timing_review"
              class="btn btn-outline mt-2 min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh review
            </button>
            <button
              :if={@review.error && @review.error.action == :retry}
              id="timing-review-retry"
              type="button"
              phx-click="retry_timing_review"
              class="btn btn-outline mt-2 min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Try saving again
            </button>
          </div>
        </div>
      </div>
    </.confirm_dialog>
    """
  end

  @doc "Renders the add/rename timing dialog with its inline name error."
  attr :dialog, :any, required: true

  def timing_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="timing-dialog"
      open={@dialog != nil}
      title={timing_dialog_title(@dialog)}
      confirm_label={timing_dialog_confirm_label(@dialog)}
      pending_label="Saving…"
      on_confirm="confirm_timing_dialog"
      on_cancel="close_timing_dialog"
      described_by="timing-dialog-body"
      confirm_variant="primary"
      chrome="planner"
    >
      <form
        :if={@dialog}
        id="timing-dialog-form"
        phx-change="validate_timing_dialog"
        class="grid gap-4"
      >
        <div class="fieldset">
          <label>
            <span class="label">Timing name</span>
            <input
              id="timing-name"
              name="name"
              type="text"
              value={@dialog.name}
              autocomplete="off"
              aria-invalid={@dialog.error && "true"}
              aria-describedby={timing_name_described_by(@dialog)}
              class="w-full input input-lg"
            />
          </label>
          <p id="timing-dialog-help">
            Use a name that helps staff choose the right running times, such as “Weekday peak”.
          </p>
          <p
            :if={@dialog.error}
            id="timing-dialog-error"
            role="alert"
            class="flex items-start gap-1.5"
          >
            <.icon name="hero-exclamation-circle" />{@dialog.error}
          </p>
        </div>

        <div :if={@dialog.mode == :add} class="fieldset">
          <label>
            <span class="label">Start with</span>
            <select id="timing-source" name="source_timing_id" class="w-full select select-lg">
              <option value="">Blank timing (all times zero)</option>
              <option
                :for={option <- @dialog.source_options}
                value={option.value}
                selected={@dialog.source_timing_id == option.value}
              >
                {option.label}
              </option>
            </select>
          </label>
          <p>No trips use a new timing until you assign them.</p>
        </div>
      </form>
    </.confirm_dialog>
    """
  end

  @doc "Renders an informational dialog for a refused operation."
  attr :dialog, :any, required: true

  def blocked_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="pattern-blocked-dialog"
      open={@dialog != nil}
      pending_label="Close"
      title={@dialog && @dialog.title}
      confirm_label={(@dialog && Map.get(@dialog, :action_label)) || "Close"}
      cancel_label="Close"
      on_confirm="close_blocked_dialog"
      on_cancel="close_blocked_dialog"
      described_by="pattern-blocked-dialog-body"
      chrome="planner"
      return_focus_id="pattern-actions-trigger"
      single_action={true}
    >
      <div>
        <p>{@dialog && @dialog.message}</p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc "Renders the confirmation for deleting an unused timing."
  attr :dialog, :any, required: true

  def timing_delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="timing-delete-dialog"
      open={@dialog != nil}
      title={if @dialog, do: "Delete #{@dialog.name}?", else: "Delete timing?"}
      pending_label="Deleting…"
      confirm_label="Delete timing"
      cancel_label="Keep timing"
      on_confirm="confirm_delete_timing"
      on_cancel="close_blocked_dialog"
      described_by="timing-delete-dialog-body"
      confirm_variant="danger"
      chrome="planner"
      return_focus_id="timing-delete"
    >
      <div>
        <p>
          No trips use {@dialog && @dialog.name}. This removes its timing values when you confirm.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc "Renders the confirmation for deleting an unused pattern."
  attr :dialog, :any, required: true

  def pattern_delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="pattern-delete-dialog"
      open={@dialog != nil}
      title={if @dialog, do: "Delete #{@dialog.name}?", else: "Delete this pattern?"}
      pending_label="Deleting…"
      confirm_label="Delete pattern"
      cancel_label="Keep pattern"
      on_confirm="confirm_delete_pattern"
      on_cancel="close_blocked_dialog"
      described_by="pattern-delete-dialog-body"
      confirm_variant="danger"
      chrome="planner"
      return_focus_id="pattern-actions-trigger"
    >
      <div>
        <p>
          No trips use {@dialog && @dialog.name}. Deleting it removes its stops and timings when you
          confirm.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the editor's connectivity state while the browser is offline.

  The wrapper is what the editor hook shows and hides on connection changes; the
  message inside is announced when it appears.
  """
  attr :offline?, :boolean, required: true

  def connectivity_banner(assigns) do
    ~H"""
    <div
      id="pattern-connectivity"
      class="pt-4"
      hidden={not @offline?}
      aria-hidden={to_string(not @offline?)}
    >
      <.message kind="warning" title="Connection lost">
        Your edits are still here. Reconnect before saving; saving stays off until then.
      </.message>
    </div>
    """
  end

  defp review_title(nil, fallback), do: fallback

  defp review_title(%{impact: %{trips_affected: affected}}, fallback) when affected in [nil, 0],
    do: fallback

  defp review_title(%{impact: %{trips_affected: 1}}, _fallback), do: "Update 1 trip?"

  defp review_title(%{impact: %{trips_affected: affected}}, _fallback),
    do: "Update #{affected} trips?"

  defp timing_dialog_title(nil), do: "Add timing"

  defp timing_dialog_title(%{mode: :rename, name: name}) when is_binary(name) and name != "",
    do: "Rename #{name}"

  defp timing_dialog_title(%{mode: :rename}), do: "Rename timing"
  defp timing_dialog_title(_dialog), do: "Add timing"

  defp timing_dialog_confirm_label(%{mode: :rename}), do: "Rename timing"
  defp timing_dialog_confirm_label(_dialog), do: "Add timing"

  defp timing_name_described_by(%{error: nil}), do: "timing-dialog-help"
  defp timing_name_described_by(_dialog), do: "timing-dialog-help timing-dialog-error"

  defp selected_trip_count(_timings, nil), do: 0

  defp selected_trip_count(timings, selected) do
    case Enum.find(timings, &(&1.timing.id == selected.id)) do
      %{trip_count: count} -> count
      nil -> 0
    end
  end

  defp insert_options(stop_rows) do
    end_label =
      case List.last(stop_rows) do
        nil -> "At the end"
        last -> "At the end, after #{last.position}. #{last.name}"
      end

    [{end_label, ""}, {"Before the first stop", "-1"}] ++
      Enum.map(stop_rows, fn row ->
        {"After #{row.position}. #{row.name}", Integer.to_string(row.position)}
      end)
  end

  defp pickup_options do
    [
      %{value: "0", label: "Regular"},
      %{value: "1", label: "Not available"},
      %{value: "2", label: "Phone the agency"},
      %{value: "3", label: "Arrange with the driver"}
    ]
  end

  # The words a stop's boarding exceptions show next to its ID, so a row says
  # what its collapsed options hold.
  @board_words %{"2" => "phone the agency", "3" => "ask the driver"}

  defp board_chips(row) do
    [
      board_chip("Pickup", "No pickup", row.pickup),
      board_chip("Drop-off", "No drop-off", row.drop_off),
      headsign_chip(row.stop_headsign)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp board_chip(_label, _none, "0"), do: nil
  defp board_chip(_label, none, "1"), do: none

  defp board_chip(label, _none, value) do
    case Map.fetch(@board_words, value) do
      {:ok, words} -> "#{label}: #{words}"
      :error -> nil
    end
  end

  defp headsign_chip(headsign) when headsign in [nil, ""], do: nil
  defp headsign_chip(headsign), do: "Headsign: #{headsign}"

  # A cell is edited when it no longer holds the value the timing was loaded
  # with; a row without a loaded value never reads as edited.
  defp time_edited?(row, :arrival), do: edited?(row.arrival, Map.get(row, :stored_arrival))
  defp time_edited?(row, :departure), do: edited?(row.departure, Map.get(row, :stored_departure))

  defp edited?(_value, nil), do: false
  defp edited?(value, stored), do: value != stored

  defp time_input_class(invalid?, edited?, estimated?) do
    [
      "h-11 w-[104px] rounded-control border px-3 text-sm tabular-nums",
      cond do
        invalid? -> "border-2 border-error-fg bg-white text-strong"
        estimated? -> "border-cyan-700 bg-soft text-cyan-800"
        edited? -> "border-warning-line bg-warning-bg text-strong"
        true -> "border-control bg-white text-strong"
      end
    ]
  end

  # Which "was …" line an estimated preview cell shows: the staged value the
  # estimate replaces, or that there was nothing (or no change) before.
  defp was_state({nil, _departure}, _estimate), do: :blank
  defp was_state({previous, _departure}, estimate) when previous == estimate, do: :same
  defp was_state({previous, _departure}, _estimate), do: {:changed, previous}

  defp blank_value?(nil), do: true
  defp blank_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_value?(_value), do: false

  defp blank_note_text(1),
    do:
      "1 stop doesn’t have times yet. Fill it from the timepoints on either side, or type it. Every stop needs a time before you can save."

  defp blank_note_text(count),
    do:
      "#{count} stops don’t have times yet. Fill them from the timepoints on either side, or type them. Every stop needs a time before you can save."

  defp preview_by_position(nil), do: %{}
  defp preview_by_position(%{rows: rows}), do: Map.new(rows, &{&1.position, &1})
  defp preview_by_position(_preview), do: %{}

  # Positions inside a span the estimator refused to fill, so their blank
  # cells read "Not filled" instead of looking merely empty.
  defp failed_preview_positions(nil), do: MapSet.new()

  defp failed_preview_positions(%{spans: spans}) do
    spans
    |> Enum.filter(&(&1.error != nil))
    |> Enum.flat_map(&Enum.to_list((&1.from_position + 1)..&1.to_position))
    |> MapSet.new()
  end

  defp failed_preview_positions(_preview), do: MapSet.new()

  defp format_retime_delta(seconds) when is_integer(seconds) and seconds >= 0,
    do: "#{GtfsTime.format_offset(seconds)} later"

  defp format_retime_delta(seconds) when is_integer(seconds),
    do: "#{GtfsTime.format_offset(-seconds)} earlier"

  defp format_retime_delta(_seconds), do: "an unknown amount"

  defp retime_stops_text(1), do: "1 stop would move."
  defp retime_stops_text(count), do: "#{count} stops would move."

  defp fill_apply_label(%{changed: 1}), do: "Fill 1 stop"
  defp fill_apply_label(%{changed: 0}), do: "Fill stops"
  defp fill_apply_label(%{changed: count}), do: "Fill #{count} stops"
  defp fill_apply_label(_preview), do: "Nothing to fill"

  defp fill_footer_note(_changed, true),
    do: "Connection lost. Filling still works; saving waits until you reconnect."

  defp fill_footer_note(0, _offline?),
    do: "Nothing to fill with these choices."

  defp fill_footer_note(_changed, _offline?),
    do: "Nothing is saved until you save running times."

  defp stop_name(names, position), do: Map.get(names, position, "stop #{position}")

  defp straight_span_text(1), do: "1 section has no path on the map and"
  defp straight_span_text(count), do: "#{count} sections have no path on the map and"

  defp straight_preview_spans(%{spans: spans}) do
    Enum.count(spans, &(&1.source == :straight_line and &1.error == nil))
  end

  defp straight_preview_spans(_preview), do: 0

  # The `#fill-map` payload the FillPreviewMap hook mounts the Leaflet preview
  # from. Stops carry `[lon, lat]` pairs (conversion from the estimator's
  # `{lat, lon}` tuples happens only here, per INV-4); kinds reuse the panel's
  # vocabulary, with `blocked` for blank stops an error span leaves unfilled.
  # Sections carry full `[lon, lat]` polylines: saved path geometry where the
  # alignment has it, else the straight connector between the visits.
  defp fill_map_payload(rows, coords, preview, sections) do
    {estimated, labels, blocked} = preview_maps(preview)
    by_position = Map.new(rows, &{&1.position, Enum.at(coords, &1.position - 1)})

    %{
      stops:
        Enum.map(rows, fn row ->
          %{
            position: row.position,
            name: Map.get(row, :name),
            coord: lonlat(Enum.at(coords, row.position - 1)),
            kind:
              map_stop_kind(
                row,
                Map.get(estimated, row.position, false),
                MapSet.member?(blocked, row.position)
              ),
            label: Map.get(labels, row.position)
          }
        end),
      sections: fill_map_sections(sections, by_position)
    }
  end

  defp preview_maps(%{rows: preview_rows, spans: spans}) do
    estimated =
      preview_rows |> Enum.filter(& &1.estimated) |> Map.new(&{&1.position, true})

    labels =
      Map.new(preview_rows, fn row ->
        {row.position, preview_label(row.arrival)}
      end)

    blocked =
      spans
      |> Enum.filter(&(Map.get(&1, :error) != nil))
      |> Enum.flat_map(&Enum.to_list(&1.from_position..&1.to_position//1))
      |> MapSet.new()

    {estimated, labels, blocked}
  end

  defp preview_maps(_preview), do: {%{}, %{}, MapSet.new()}

  defp preview_label(arrival) when is_integer(arrival), do: GtfsTime.format_offset(arrival)
  defp preview_label(_arrival), do: nil

  # One line per section with known geometry. A section with saved path
  # points draws from the full polyline; a section without points but with
  # two known endpoints draws the straight connector; a section with a
  # missing endpoint (including `:blocked`) or corrupt path points is never
  # fabricated and stays off the map.
  defp fill_map_sections(sections, by_position) do
    Enum.flat_map(sections, fn section ->
      case section_geometry(
             section,
             lonlat(Map.get(by_position, section.from)),
             lonlat(Map.get(by_position, section.to))
           ) do
        nil -> []
        entry -> [entry]
      end
    end)
  end

  defp section_geometry(_section, nil, _to_coord), do: nil
  defp section_geometry(_section, _from_coord, nil), do: nil

  defp section_geometry(%{kind: kind} = section, from_coord, to_coord)
       when kind in [:override, :shared] do
    case valid_points(section.points) do
      {:ok, [_ | _] = points} ->
        %{
          from: section.from,
          to: section.to,
          points: [from_coord] ++ points ++ [to_coord],
          source: "path"
        }

      {:ok, []} ->
        straight_section(section, from_coord, to_coord)

      :corrupt ->
        nil
    end
  end

  defp section_geometry(section, from_coord, to_coord),
    do: straight_section(section, from_coord, to_coord)

  defp straight_section(section, from_coord, to_coord) do
    %{from: section.from, to: section.to, points: [from_coord, to_coord], source: "straight"}
  end

  defp valid_points(points) when is_list(points) do
    lonlats = Enum.map(points, &lonlat_pair/1)
    if Enum.all?(lonlats, &(!is_nil(&1))), do: {:ok, lonlats}, else: :corrupt
  end

  defp valid_points(_points), do: {:ok, []}

  defp lonlat_pair([lon, lat]) when is_number(lon) and is_number(lat), do: [lon, lat]
  defp lonlat_pair(_point), do: nil

  defp straight_map?(%{sections: sections}) do
    Enum.any?(sections, &(&1.source == "straight"))
  end

  defp straight_map?(_payload), do: false

  defp lonlat({lat, lon}) when is_number(lat) and is_number(lon), do: [lon, lat]
  defp lonlat(_coord), do: nil

  defp map_stop_kind(_row, true, _blocked?), do: "estimate"

  defp map_stop_kind(row, false, blocked?) do
    cond do
      blank_value?(Map.get(row, :arrival)) and blank_value?(Map.get(row, :departure)) and blocked? ->
        "blocked"

      blank_value?(Map.get(row, :arrival)) and blank_value?(Map.get(row, :departure)) ->
        "blank"

      Map.get(row, :timepoint) == true ->
        "timepoint"

      true ->
        "stop"
    end
  end

  # Profile geometry for `fill_profile/1`: x is metres along the path (even
  # spacing when distances are missing), y is seconds from the start. All
  # coordinates are pre-rendered strings so the template stays declarative.
  defp build_profile(preview, distances) do
    rows = Map.get(preview, :rows, [])
    spans = Map.get(preview, :spans, [])
    {by_pos, max_d, max_t, scale_y, frame} = profile_scales(rows, distances)
    {width, height, left, right, _top, bottom} = frame
    marks = profile_marks(rows, by_pos, scale_y, height - bottom)

    %{
      hops: profile_hops(rows, spans, by_pos, scale_y),
      dwells: profile_dwells(rows, by_pos, scale_y),
      anchors: marks.anchors,
      estimates: marks.estimates,
      ticks: marks.ticks,
      labels: profile_labels(spans, by_pos, scale_y),
      grid: profile_grid(frame, max_t, scale_y),
      x_max_label: distance_label(max_d),
      x_left: svg_num(left),
      x_right: svg_num(width - right),
      x_base: svg_num(height - bottom + 15)
    }
  end

  defp profile_frame, do: {480, 220, 40, 10, 10, 28}

  defp profile_scales(rows, distances) do
    count = length(rows)
    frame = profile_frame()
    {_width, height, _left, _right, top, bottom} = frame
    {xs, max_d} = profile_xs(rows, distances, count)
    max_t = profile_max_t(rows)
    scale_y = fn t -> height - bottom - t / max_t * (height - top - bottom) end

    by_pos =
      Map.new(rows, fn row ->
        {row.position,
         %{
           x: profile_x(Enum.at(xs, row.position - 1) || 0, max_d, frame),
           arrival: row.arrival,
           departure: row.departure,
           estimated: row.estimated
         }}
      end)

    {by_pos, max_d, max_t, scale_y, frame}
  end

  defp profile_x(distance, max_d, {width, _height, left, right, _top, _bottom}) do
    left + distance / max_d * (width - left - right)
  end

  defp profile_point_timed?(by_pos, pos) do
    case Map.get(by_pos, pos) do
      %{arrival: arrival, departure: departure}
      when is_integer(arrival) and is_integer(departure) ->
        true

      _ ->
        false
    end
  end

  defp profile_hops(rows, spans, by_pos, scale_y) do
    rows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [previous, current] ->
      profile_point_timed?(by_pos, previous.position) and
        profile_point_timed?(by_pos, current.position)
    end)
    |> Enum.map(fn [previous, current] ->
      from = Map.fetch!(by_pos, previous.position)
      to = Map.fetch!(by_pos, current.position)

      %{
        x1: svg_num(from.x),
        y1: svg_num(scale_y.(from.departure)),
        x2: svg_num(to.x),
        y2: svg_num(scale_y.(to.arrival)),
        straight?: hop_straight?(spans, current.position)
      }
    end)
  end

  defp profile_dwells(rows, by_pos, scale_y) do
    for row <- rows,
        point = Map.get(by_pos, row.position),
        is_integer(point.arrival) and is_integer(point.departure) and
          point.arrival != point.departure do
      %{
        x: svg_num(point.x),
        y1: svg_num(scale_y.(point.arrival)),
        y2: svg_num(scale_y.(point.departure))
      }
    end
  end

  defp profile_marks(rows, by_pos, scale_y, base_y) do
    {anchors, estimates, ticks} =
      Enum.reduce(rows, {[], [], []}, fn row, {anchors, estimates, ticks} ->
        point = Map.fetch!(by_pos, row.position)

        cond do
          row.estimated and profile_point_timed?(by_pos, row.position) ->
            {anchors, [%{x: svg_num(point.x), y: svg_num(scale_y.(row.arrival))} | estimates],
             ticks}

          profile_point_timed?(by_pos, row.position) ->
            {[%{x: svg_num(point.x - 4), y: svg_num(scale_y.(row.arrival) - 4)} | anchors],
             estimates, ticks}

          true ->
            {anchors, estimates,
             [%{x: svg_num(point.x), y1: svg_num(base_y - 5), y2: svg_num(base_y)} | ticks]}
        end
      end)

    %{anchors: anchors, estimates: estimates, ticks: ticks}
  end

  defp profile_labels(spans, by_pos, scale_y) do
    spans
    |> Enum.filter(&(&1.error == nil and is_number(&1.mph)))
    |> Enum.map(fn span ->
      from = Map.get(by_pos, span.from_position)
      to = Map.get(by_pos, span.to_position)

      if is_nil(from) or is_nil(to) or not profile_point_timed?(by_pos, span.from_position) or
           not profile_point_timed?(by_pos, span.to_position) do
        nil
      else
        %{
          x: svg_num((from.x + to.x) / 2),
          y: svg_num((scale_y.(from.departure) + scale_y.(to.arrival)) / 2 + 14),
          text: "#{round(span.mph)} mph",
          fast?: span.mph > 60
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp profile_grid({width, _height, left, right, _top, _bottom}, max_t, scale_y) do
    for fraction <- [0, 0.5, 1] do
      gy = scale_y.(max_t * fraction)

      %{
        x1: svg_num(left),
        x2: svg_num(width - right),
        y: svg_num(gy),
        label_x: svg_num(left - 5),
        label_y: svg_num(gy + 4),
        label: "#{round(max_t * fraction / 60)}"
      }
    end
  end

  defp profile_xs(rows, distances, count) do
    xs = Enum.map(rows, fn row -> Enum.at(distances, row.position - 1) end)
    known = Enum.filter(xs, &is_number/1)
    max_d = if known == [], do: nil, else: Enum.max(known)

    if max_d in [nil, 0] do
      {Enum.map(rows, fn row -> (row.position - 1) * 1.0 end), max(count - 1, 1) * 1.0}
    else
      step = max_d / max(count - 1, 1)

      {Enum.map(rows, fn row ->
         Enum.at(distances, row.position - 1) || (row.position - 1) * step
       end), max_d * 1.0}
    end
  end

  defp profile_max_t(rows) do
    times =
      rows |> Enum.flat_map(&[&1.arrival, &1.departure]) |> Enum.filter(&is_integer/1)

    max(Enum.max(times, fn -> 0 end), 60)
  end

  defp hop_straight?(spans, to_position) do
    case Enum.find(
           spans,
           &(&1.from_position < to_position and to_position <= &1.to_position)
         ) do
      %{source: :straight_line, error: nil} -> true
      _ -> false
    end
  end

  defp distance_label(max_d) when max_d >= 1609.344,
    do: "#{Float.round(max_d / 1609.344, 1)} mi"

  defp distance_label(max_d), do: "#{round(max_d)} m"

  defp svg_num(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1)

  defp svg_num(value) when is_integer(value), do: Integer.to_string(value)
  defp svg_num(value), do: to_string(value)

  # The arrival and departure a sample trip would show, once when they match.
  defp sample_trip(%{preview_arrival: same, preview_departure: same}), do: same
  defp sample_trip(row), do: "#{row.preview_arrival} → #{row.preview_departure}"

  defp label_class, do: "text-[13px] font-[650] text-default"

  defp field_input_class,
    do:
      "h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong disabled:border-subtle disabled:bg-canvas disabled:text-muted"

  defp new_row?(row, creating?), do: is_nil(row.id) and not creating?

  # The stop search's own status line carries the outage; matching its words
  # here keeps the LiveView's copy the single source.
  defp search_unavailable?(status), do: String.contains?(status, "unavailable")

  # The plain-language names of the six GTFS route-pattern typicality values,
  # which the stored integers keep.
  defp typicality_choices do
    [
      {"Not set", 0},
      {"Typical · runs regularly", 1},
      {"Deviation · a regular variation of the route", 2},
      {"Atypical · special routing that runs a few times a day", 3},
      {"Diversion · planned detour, shuttle or snow route", 4},
      {"Canonical reference · lists every stop, not scheduled", 5}
    ]
  end

  defp typicality_help(value) do
    case to_string(value) do
      "1" -> "The pattern most trips on this route follow."
      "2" -> "A regular variation, such as a short turn or an express."
      "3" -> "Special routing that runs only a handful of times a day."
      "4" -> "A planned detour, bus shuttle or snow route."
      "5" -> "Lists every physical stop; not currently scheduled to run."
      _ -> "How this pattern fits the route’s usual service. Most patterns are typical."
    end
  end

  defp status_tone(true, _creating), do: "warning"
  defp status_tone(false, true), do: "neutral"
  defp status_tone(false, false), do: "success"

  defp status_icon(true, _creating), do: "hero-clock"
  defp status_icon(false, true), do: nil
  defp status_icon(false, false), do: "hero-check-circle"

  defp status_label(true, true), do: "Not created yet"
  defp status_label(true, false), do: "Unsaved changes"
  defp status_label(false, true), do: "New pattern"
  defp status_label(false, false), do: "Saved in this version"

  defp status_text_class(:warning), do: "text-warning-fg"
  defp status_text_class(:error), do: "text-error-fg"
  defp status_text_class(:success), do: "text-success-fg"
  defp status_text_class(:ready), do: "text-success-fg"
  defp status_text_class(:info), do: "text-default"
  defp status_text_class(_tone), do: "text-muted"

  defp status_bar_icon(:warning), do: "hero-clock"
  defp status_bar_icon(:error), do: "hero-exclamation-triangle"
  defp status_bar_icon(:success), do: "hero-check-circle"
  defp status_bar_icon(:ready), do: "hero-check-circle"
  defp status_bar_icon(:info), do: "hero-information-circle"
  defp status_bar_icon(_tone), do: nil

  defp task_label(:stops), do: "Stops"
  defp task_label(:timings), do: "Running times"
  defp task_label(:alignment), do: "Alignment"
  defp task_label(:details), do: "Details"

  @doc """
  Renders the page-level error alert and the polite status region.

  The regions stay in the page for assistive technology. A page that shows the
  same message in its save bar, where it stays in view, hides the region's own
  copy with `hide_error?` and `hide_status?`.
  """
  attr :error, :string, default: nil
  attr :status, :string, default: nil
  attr :hide_error?, :boolean, default: false
  attr :hide_status?, :boolean, default: false

  def status_regions(assigns) do
    ~H"""
    <div
      id="error"
      role="alert"
      class={[
        @hide_error? && "sr-only",
        !@hide_error? && @error &&
          "mt-4 rounded-control bg-error-bg px-4 py-3 text-sm font-bold text-error-fg"
      ]}
    >
      {@error}
    </div>
    <div
      id="status"
      role="status"
      aria-live="polite"
      class={[
        @hide_status? && "sr-only",
        !@hide_status? && @status &&
          "mt-4 rounded-control bg-soft px-4 py-3 text-sm font-bold text-cyan-800"
      ]}
    >
      {@status}
    </div>
    """
  end

  defp trip_count_noun(1), do: "trip"
  defp trip_count_noun(_count), do: "trips"

  defp trip_verb(1), do: "uses"
  defp trip_verb(_count), do: "use"
end
