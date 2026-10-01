defmodule GtfsPlannerWeb.Gtfs.AlertComponents do
  @moduledoc """
  The components the Alerts list page and the alert editor share: the four-tab
  strip, one alert row, the message an empty tab shows, and the editor's own
  frame - the mode control with its preference link, the step progress row, the
  question card, the Rider preview and the bottom save bar.

  The list components are renderings of what `Alerts.list_alerts/2` already
  derived. Nothing here computes a tab, a count or a badge: the read model owns
  those, so a row cannot disagree with the count in its own tab (AC-9, R8).

  The editor components are the shell every question step renders inside. The
  progress row and the question card take the step list `AlertEditorLive.steps_for/2`
  produced and never build one of their own, so the row an editor reads and the
  step the editor is on cannot come from two different sequences (INV-2). The
  Rider preview shows saved answers only: the header the editor wrote, the When
  summary `Alerts.Recurrence.summary/1` derived, and the labels
  `Alerts.labels_for/2` read from the alert's own version (CR-4).

  The bottom bar carries the save state in the reader's words - `Saving…`,
  `Saved`, `Not saved.` - and offers the actions that state allows: Retry for a
  refused save, Load latest and Save as new alert for a stale one. The bar never
  offers a way to overwrite a newer revision: a stale save is resolved by taking
  one side or the other, never by forcing (R6, AC-16).

  None of these surfaces shows a publication state or a publication action,
  because saving an alert never publishes one in this package (R2, CR-1). The
  words Live, Scheduled, Ended, End and feed therefore appear nowhere in this
  module.
  """

  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents,
    only: [button: 1, callout: 1, icon: 1, input: 1, segmented_control: 1, status_badge: 1]

  alias Phoenix.LiveView.JS
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlannerWeb.Components.RouteIdentity

  # The words a reader recognizes: the situation is what the alert is about and
  # the effect is what riders' apps do about it. The preview names the effect
  # because that is the word riders read.
  @situation_labels %{
    delay: "Delays",
    detour: "Detour",
    stop_moved: "Stop moved",
    stop_closed: "Stop closed",
    cancelled_trips: "Cancelled departures",
    accessibility: "Accessibility",
    suspension: "Service suspension",
    service_change: "Service change"
  }

  @effect_labels %{
    no_service: "No service",
    reduced_service: "Fewer departures",
    significant_delays: "Delays",
    detour: "Detour",
    additional_service: "Extra service",
    modified_service: "Modified service",
    other_effect: "Service information",
    unknown_effect: "Service information",
    stop_moved: "Stop moved",
    no_effect: "No change to service",
    accessibility_issue: "Accessibility issue"
  }

  @doc """
  The words the editor and the preview use for a stored situation and effect.
  """
  def situation_label(situation), do: Map.get(@situation_labels, situation)
  def effect_label(effect), do: Map.get(@effect_labels, effect)

  @doc """
  The name a rider knows a route by: its short name, then its long name, then the
  feed ID the version gave it.

  The same words `Alerts.Targets` puts on a route option, so a route reads the
  same in a pick list, in the Rider preview and in a review. A row is a
  `Gtfs.Route`, so this reads the struct's fields rather than an option map's
  `:label`.
  """
  def route_label(route) do
    Enum.find_value([route.route_short_name, route.route_long_name], route.route_id, fn value ->
      if is_binary(value) and String.trim(value) != "", do: String.trim(value)
    end)
  end

  # -- Editor frame -------------------------------------------------------

  # The four tabs in the order the read model groups them, with the words the
  # prototype uses for each. `in_progress` is In progress rather than Drafts:
  # this package saves an alert, it never schedules one.
  defp tab_items do
    [
      {:current, "Current"},
      {:upcoming, "Upcoming"},
      {:in_progress, "In progress"},
      {:past, "Past"}
    ]
  end

  # What each tab holds, in the reader's words rather than the reader's guess.
  @tab_empty %{
    current: {
      "Nothing is in effect",
      "No alert covers today. Riders see your scheduled service until you create one."
    },
    upcoming: {
      "Nothing is planned yet",
      "Planned work, holidays and events can be prepared ahead of the day they apply."
    },
    in_progress: {
      "No alerts in progress",
      "An alert you have started but not finished appears here until you save it as complete."
    },
    past: {
      "No earlier alerts",
      "An alert appears here once its last date has passed. It stays readable, and you can reuse it."
    }
  }

  @doc """
  Renders the `Current · N | Upcoming · N | In progress · N | Past · N` strip.

  The count is in the tab's own label, because the question a reader opens this
  page with is "how much is there", and a count they can see is one fewer click
  for the answer. Each tab is a link that patches `?tab=`, so the selected tab
  is in the URL and a reload or a shared link keeps it.

  `role="tablist"` with `aria-selected` on the pressed tab, and the pressed tab
  also carries `aria-current="page"`, so the selection is never signalled by
  colour alone.
  """
  attr :version_id, :any, required: true
  attr :tab, :atom, required: true
  attr :counts, :map, required: true, doc: "the four tab counts, keyed by tab atom"

  def tabs(assigns) do
    ~H"""
    <nav
      id="alerts-tabs"
      aria-label="Alerts by state"
      class="mt-6 flex gap-1 overflow-x-auto border-b border-subtle"
    >
      <.link
        :for={{key, label} <- tab_items()}
        id={"alerts-tab-#{key}"}
        patch={"/gtfs/#{@version_id}/alerts?tab=#{key}"}
        role="tab"
        aria-selected={to_string(@tab == key)}
        aria-current={@tab == key && "page"}
        data-count={Map.get(@counts, key, 0)}
        class={[
          "-mb-px inline-flex min-h-11 shrink-0 items-center gap-2 border-b-2 px-3 text-sm font-semibold no-underline",
          @tab == key && "border-action text-action",
          @tab != key && "border-transparent text-muted hover:text-strong"
        ]}
      >
        {label}
        <span class={[
          "rounded-badge px-1.5 text-[12px] font-bold tabular-nums",
          @tab == key && "bg-selection text-action",
          @tab != key && "bg-canvas text-muted"
        ]}>
          {Map.get(@counts, key, 0)}
        </span>
      </.link>
    </nav>
    """
  end

  @doc """
  Renders one alert as a table row.

  The title is the link, so the primary identifier is the target (table-row
  design §5), and the badges sit under it: what the alert is about, then the
  conditions a reader cannot derive from the dates alone. Every badge carries a
  word, because a colour alone says nothing to a reader who cannot see it.

  `Affects` names the routes by their own identity badges and counts the stops,
  which is the prototype's reading: an alert is about routes and places, and a
  route number is how an editor recognizes it.
  """
  attr :row, :map, required: true, doc: "one prepared row from `alerts_live.ex`"

  def row(assigns) do
    ~H"""
    <tr
      id={"alert-row-#{@row.alert.id}"}
      class="border-b border-subtle last:border-0 hover:bg-canvas/70"
    >
      <td class="px-5 py-3 align-top">
        <.link
          id={"alert-link-#{@row.alert.id}"}
          patch={@row.alert_path}
          class="font-semibold text-strong no-underline hover:text-action hover:underline"
        >
          {@row.title}
        </.link>
        <div class="mt-1 flex flex-wrap items-center gap-1.5">
          <span :if={@row.situation_label} class={chip_class()}>{@row.situation_label}</span>
          <.status_badge :if={not @row.alert.complete} status="draft" label="Incomplete" />
          <.status_badge
            :if={@row.needs_attention?}
            status="warning"
            label="Needs attention"
            data-role="alert-needs-attention"
          />
          <.status_badge
            :if={@row.check_in_due?}
            status="info"
            label="Check-in due"
            data-role="alert-check-in-due"
          />
        </div>
      </td>
      <td class="px-3 py-3 align-top">
        <.all_routes_badge :if={@row.system?} />
        <span :if={not @row.system? and @row.routes != []} class="flex flex-wrap gap-1">
          <RouteIdentity.route_badge :for={route <- @row.routes} route={route} />
        </span>
        <span :if={@row.stop_count > 0} class="mt-1 block text-[13px] text-muted">
          {stop_count_label(@row.stop_count)}
        </span>
      </td>
      <td class="px-3 py-3 align-top tabular-nums">
        <span class="block">{@row.when_summary}</span>
        <span :if={@row.check_in_label} class="mt-0.5 block text-[13px] text-muted">
          {@row.check_in_label}
        </span>
      </td>
      <td class="px-3 py-3 align-top text-[13px] text-muted">{@row.last_change}</td>
    </tr>
    """
  end

  @doc """
  Renders one alert as a stacked card, for the width where four columns cannot
  hold their content without sideways scrolling.

  It is the same row in one column: the title link, the badges, what the alert
  affects, when it applies, and who last changed it.
  """
  attr :row, :map, required: true, doc: "one prepared row from `alerts_live.ex`"

  def mobile_row(assigns) do
    ~H"""
    <li id={"alert-card-#{@row.alert.id}"} class="border-b border-subtle last:border-b-0 px-4 py-3">
      <.link
        id={"alert-card-link-#{@row.alert.id}"}
        patch={@row.alert_path}
        class="font-semibold text-strong no-underline hover:underline"
      >
        {@row.title}
      </.link>
      <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
        <span :if={@row.situation_label} class={chip_class()}>{@row.situation_label}</span>
        <.status_badge :if={not @row.alert.complete} status="draft" label="Incomplete" />
        <.status_badge :if={@row.needs_attention?} status="warning" label="Needs attention" />
        <.status_badge :if={@row.check_in_due?} status="info" label="Check-in due" />
      </div>
      <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
        <.all_routes_badge :if={@row.system?} />
        <RouteIdentity.route_badge :for={route <- @row.routes} route={route} />
        <span :if={@row.stop_count > 0} class="text-[13px] text-muted">
          {stop_count_label(@row.stop_count)}
        </span>
      </div>
      <p class="mt-1.5 text-[13px] text-muted tabular-nums">
        {@row.when_summary}<span :if={@row.check_in_label}> · {@row.check_in_label}</span>
      </p>
      <p class="mt-0.5 text-[13px] text-muted">{@row.last_change}</p>
    </li>
    """
  end

  @doc """
  Renders the message shown when the selected tab holds no alerts.

  Each tab says what belongs in it, because four identical "Nothing here"
  messages tell a reader who just saved an alert in another tab that this one is
  empty rather than that their alert is gone.
  """
  attr :tab, :atom, required: true

  def tab_empty(assigns) do
    assigns = assign(assigns, :empty, Map.fetch!(@tab_empty, assigns.tab))

    ~H"""
    <div
      id={"alerts-tab-empty-#{@tab}"}
      class="mt-4 rounded-card border border-subtle bg-white px-5 py-10 text-center"
    >
      <h2 class="font-display text-[20px] font-semibold tracking-[-0.02em] text-strong">
        {elem(@empty, 0)}
      </h2>
      <p class="mx-auto mt-2 max-w-[52ch] text-sm text-muted">{elem(@empty, 1)}</p>
    </div>
    """
  end

  @doc """
  The Guided form / Assistant control, with the preference link beside it.

  Both segments are links to the same editor with a different `?mode=`, so the
  mode an editor is in is in the URL and a refresh keeps it (AC-15). The link
  switches modes without touching a single answer, because both modes read and
  write the same draft.

  **Make default** stores the mode this editor is in as the reader's preference,
  and then the control reads "Default" instead of offering the link again. It is
  the prototype's placement: the preference is a quiet setting beside the choice
  rather than a separate settings page.

  The control renders its own `<form>`, so it must stay outside the editor's
  draft form: a nested form is not valid HTML and the browser drops the inner
  one together with its change event.
  """
  attr :id, :string, required: true
  attr :mode, :atom, required: true, doc: ":form or :assistant"
  attr :preferred, :atom, required: true, doc: "the reader's stored preference"
  attr :class, :any, default: nil

  def mode_control(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-wrap items-center gap-2", @class]}>
      <.segmented_control
        id={"#{@id}-control"}
        name="mode"
        legend="How to create this alert"
        legend_class="sr-only"
        options={[{"Guided form", "form"}, {"Assistant", "assistant"}]}
        value={@mode}
        event="set_mode"
        appearance={:joined}
        emphasis={:selection}
      />
      <.button
        :if={@mode != @preferred}
        id="make-default-mode"
        type="button"
        variant="quiet"
        phx-click="make_default_mode"
        aria-label="Make this the default way to create alerts"
      >
        Make default
      </.button>
      <span
        :if={@mode == @preferred}
        id="alert-mode-default"
        class="text-[13px] font-semibold text-muted"
      >
        Default
      </span>
    </div>
    """
  end

  @doc """
  The horizontal step progress: which questions this alert asks, which one is
  open, and which are already answered.

  The step list arrives prepared by `AlertEditorLive.steps_for/2`, so this row
  cannot show a step the editor's own navigation does not have (INV-2). An
  answered step carries a check icon and its name; an unanswered one carries its
  position, because "3. Timing" says where the editor is in a way a check alone
  does not. A step the editor has not reached yet is not a link: there is
  nothing behind it to go back to.
  """
  attr :steps, :list, required: true, doc: "prepared steps from `steps_for/2`"

  def progress(assigns) do
    ~H"""
    <nav
      id="alert-progress"
      aria-label="Alert progress"
      class="mb-4 flex flex-wrap gap-x-3 gap-y-1 border-b border-subtle pb-3"
    >
      <%= for step <- @steps do %>
        <span class="contents">
          <.link
            :if={step.reachable?}
            id={step.id}
            patch={step.patch}
            aria-current={step.current? && "step"}
            class={[
              "inline-flex min-h-11 items-center gap-1.5 text-[13px] no-underline",
              step.current? && "font-bold text-action hover:underline",
              not step.current? && "text-muted hover:text-strong hover:underline"
            ]}
          >
            <.icon
              :if={step.answered? and not step.current?}
              name="hero-check"
              class="size-3.5 text-success-fg"
            />
            <span :if={not (step.answered? and not step.current?)}>{step.position}.</span>
            {step.label}
          </.link>
          <span
            :if={not step.reachable?}
            id={step.id}
            aria-disabled="true"
            class="inline-flex min-h-11 items-center gap-1.5 text-[13px] text-muted opacity-60"
          >
            <.icon
              :if={step.answered? and not step.current?}
              name="hero-check"
              class="size-3.5 text-success-fg"
            />
            <span :if={not (step.answered? and not step.current?)}>{step.position}.</span>
            {step.label}
          </span>
        </span>
      <% end %>
    </nav>
    """
  end

  @doc """
  The card the current question renders inside.

  The eyebrow names where the editor is ("Start an alert", "Happening now"), the
  heading is the question itself, and the hint tells the editor that a single
  choice moves on. The heading takes focus when the card mounts, so advancing to
  the next question reads the next question rather than the previous one.

  The body is a slot: each step renders its own controls, and the card only
  frames them. The Back link patches to the previous step in the sequence the
  caller prepared, so Back never leaves the step list.

  Focus follows the question. The heading is the focus target, and it sits
  inside a wrapper whose id names the step: LiveView keys its DOM patch on an
  element's `id`, so a new step is a new wrapper, a new wrapper runs
  `phx-mounted` again, and the focus lands on the question just opened rather
  than staying on the card the reader pressed (AC-17). Putting `phx-mounted` on
  the heading itself would run exactly once, on the first question the editor
  ever showed.
  """
  attr :id, :string, required: true
  attr :step, :atom, required: true, doc: "the step key, so each question is its own element"
  attr :eyebrow, :string, required: true
  attr :heading, :string, required: true
  attr :hint, :string, default: nil
  attr :back, :string, default: nil, doc: "patch path to the previous step, when there is one"
  slot :inner_block, required: true
  slot :actions

  def question_card(assigns) do
    assigns = assign(assigns, :title_id, "#{assigns.id}-title")

    ~H"""
    <section
      id={@id}
      class="rounded-card border border-subtle bg-white p-4 sm:p-6"
    >
      <p class="mb-1 text-[13px] font-semibold text-muted">{@eyebrow}</p>
      <div
        id={"#{@id}-heading-#{@step}"}
        phx-mounted={JS.focus(to: "##{@title_id}")}
      >
        <h2 id={@title_id} tabindex="-1" class="text-xl font-bold tracking-normal text-strong">
          {@heading}
        </h2>
        <p :if={@hint} id={"#{@id}-hint"} class="mt-1 text-sm text-muted">{@hint}</p>
      </div>
      <div id="alert-question-body" class="mt-5">
        {render_slot(@inner_block)}
      </div>
      <div class="mt-5 flex flex-wrap items-center gap-3 border-t border-subtle pt-4">
        <.link
          :if={@back}
          id={"#{@id}-back"}
          patch={@back}
          class="inline-flex min-h-11 items-center gap-1 rounded-control px-2 text-sm font-semibold text-action no-underline hover:bg-canvas hover:underline"
        >
          <.icon name="hero-chevron-left" class="size-4" /> Back
        </.link>
        {render_slot(@actions)}
      </div>
    </section>
    """
  end

  @doc """
  The Rider preview: the alert as a rider's app shows it, then the three facts
  the editor has already saved.

  It is a reading of saved answers, never a draft of the editor's input: the
  header, the `Recurrence.summary/1` sentence for When, and the route and stop
  labels `Alerts.labels_for/2` read from the alert's own version (CR-4). A draft
  that has answered nothing says so in words rather than showing an empty card,
  because an empty card reads as a broken one.

  "Draft - review before publishing" and "Data sent to apps" are prototype
  elements this package does not have: saving an alert never publishes one, so
  there is nothing to review before publishing and no outbound payload to show
  (R2, CR-1).
  """
  attr :alert, :any, required: true, doc: "the loaded alert, or `nil` before the first answer"
  attr :header, :string, default: nil
  attr :when_summary, :string, default: ""
  attr :effect, :atom, default: nil
  attr :routes, :list, default: [], doc: "affected route rows for their identity badges"
  attr :where, :string, default: nil, doc: "the `Where riders see it` sentence"
  attr :what, :string, default: nil, doc: "the `What's happening` sentence"

  def rider_preview(assigns) do
    ~H"""
    <aside id="alert-preview" class="grid gap-4 lg:sticky lg:top-4">
      <section class="overflow-clip rounded-card border border-subtle bg-white">
        <div class="border-b border-subtle px-4 py-3 sm:px-5">
          <h2 class="text-base font-bold tracking-normal text-strong">Rider preview</h2>
          <p class="text-[13px] text-muted">What riders see</p>
        </div>
        <div class="px-4 pb-4 pt-4 sm:px-5">
          <div id="alert-preview-message">
            <.empty_preview :if={is_nil(@alert)} />
            <.preview_message
              :if={@alert}
              effect={@effect}
              routes={@routes}
              header={@header}
              description={description(@alert)}
            />
          </div>
          <dl id="alert-preview-facts" class="mt-4">
            <.fact_row id="alert-preview-when" label="When" value={@when_summary} />
            <.fact_row id="alert-preview-where" label="Where riders see it" value={@where} />
            <.fact_row id="alert-preview-what" label="What's happening" value={@what} />
          </dl>
        </div>
      </section>
    </aside>
    """
  end

  defp preview_message(assigns) do
    ~H"""
    <div class={[
      "rounded-card border border-l-4 border-subtle bg-white px-4 py-3 shadow-card",
      effect_border(@effect)
    ]}>
      <div class="flex flex-wrap items-center gap-1.5">
        <span
          :if={@effect}
          id="alert-preview-effect"
          class="inline-flex items-center gap-1 text-[13px] font-semibold text-strong"
        >
          <.icon name={effect_icon(@effect)} class="size-4" />
          {effect_label(@effect)}
        </span>
        <.all_routes_badge :if={@routes == [] and @effect} />
        <span :if={@routes != []} class="flex flex-wrap items-center gap-1">
          <RouteIdentity.route_badge :for={route <- @routes} route={route} />
        </span>
      </div>
      <p id="alert-preview-header" class="mt-1.5 text-[15px] font-bold leading-snug text-strong">
        {if blank?(@header), do: "Short message", else: @header}
      </p>
      <p :if={not blank?(@description)} class="mt-1 text-sm leading-6 text-default">
        {@description}
      </p>
    </div>
    """
  end

  defp empty_preview(assigns) do
    ~H"""
    <div
      id="alert-preview-empty"
      class="rounded-card border border-dashed border-control px-4 py-6 text-center text-sm text-muted"
    >
      Your rider message will appear here as you fill in the details.
    </div>
    """
  end

  defp fact_row(assigns) do
    ~H"""
    <div id={@id} class="grid gap-0.5 border-t border-subtle py-2.5">
      <dt class="text-[13px] text-muted">{@label}</dt>
      <dd class="text-sm text-strong">
        {if blank?(@value), do: "Not chosen yet", else: @value}
      </dd>
    </div>
    """
  end

  # The prototype's dashed placeholder for an alert with nothing saved yet.
  defp description(%{message: %{description: description}}), do: description
  defp description(_alert), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # The left border carries the effect's severity, so a rider-facing card reads
  # the same way here as it does in an app.
  defp effect_border(:no_service), do: "border-l-error-fg"
  defp effect_border(:other_effect), do: "border-l-info-fg"
  defp effect_border(:additional_service), do: "border-l-info-fg"
  defp effect_border(nil), do: "border-l-control"
  defp effect_border(_effect), do: "border-l-warning-fg"

  defp effect_icon(:detour), do: "hero-arrow-right"
  defp effect_icon(:stop_moved), do: "hero-map-pin"
  defp effect_icon(:significant_delays), do: "hero-clock"
  defp effect_icon(:no_service), do: "hero-x-circle"
  defp effect_icon(:reduced_service), do: "hero-arrows-up-down"
  defp effect_icon(:additional_service), do: "hero-plus"
  defp effect_icon(:accessibility_issue), do: "hero-chevron-up-down"
  defp effect_icon(_effect), do: "hero-information-circle"

  @doc """
  The first question's two choices: happening now, or starting later.

  Both are answers a reader can give without filling in a field, so both are
  buttons that save and move on rather than a choice followed by a Continue -
  which is what makes the first answer the moment the draft row is created. The
  selected answer keeps its check, so a reader who goes back can see what they
  already answered.
  """
  attr :alert, :any, required: true
  attr :event, :string, required: true
  attr :name, :string, required: true

  def urgency_question(assigns) do
    ~H"""
    <.choice_cards
      id="alert-urgency"
      event={@event}
      name={@name}
      choices={urgency_choices(assigns.alert)}
    />
    """
  end

  defp urgency_choices(alert) do
    Enum.map(
      [
        %{
          value: "now",
          urgency: :now,
          label: "Happening now",
          description: "Get an urgent disruption out to riders.",
          icon: "hero-signal"
        },
        %{
          value: "planned",
          urgency: :planned,
          label: "Starts later",
          description: "Give riders notice of upcoming work or changes.",
          icon: "hero-calendar-days"
        }
      ],
      &Map.put(&1, :selected?, alert != nil and alert.urgency == &1.urgency)
    )
  end

  @doc """
  A question whose whole answer is one choice: a set of cards, each of which
  saves and moves on by itself.

  This is the prototype's `advanceChoices`, and it is one component because the
  urgency, situation, change, mode and direction questions differ only in the
  cards they offer. Each card is a `<button type="button">` carrying its value
  as `phx-value-<name>`, so Enter and Space activate it the way a reader
  expects and the value never travels as a typed field.

  `aria-pressed` marks the answer the alert already holds, so a reader who comes
  back sees which card they pressed; a chosen card keeps its check and an
  unchosen one shows the chevron the prototype shows.
  """
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :name, :string, required: true

  attr :choices, :list,
    required: true,
    doc: "maps with :value, :label and optional :description, :icon and :selected?"

  def choice_cards(assigns) do
    ~H"""
    <div id={@id} class="grid gap-3 sm:grid-cols-2">
      <button
        :for={choice <- @choices}
        id={"#{@id}-#{choice.value}"}
        type="button"
        phx-click={@event}
        {value_attr(@name, choice.value)}
        aria-pressed={to_string(Map.get(choice, :selected?, false))}
        class={[
          "group flex min-h-11 items-start gap-3 rounded-control border bg-white p-4 text-left",
          "hover:border-action hover:bg-selection motion-reduce:transition-none transition-colors",
          Map.get(choice, :selected?, false) && "border-action bg-selection"
        ]}
      >
        <.icon
          :if={Map.get(choice, :icon)}
          name={choice.icon}
          class="mt-0.5 size-5 shrink-0 text-action"
        />
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-bold text-strong">{choice.label}</span>
          <span :if={Map.get(choice, :description)} class="mt-1 block text-[13px] text-default">
            {choice.description}
          </span>
        </span>
        <.icon
          name={if(Map.get(choice, :selected?, false), do: "hero-check", else: "hero-chevron-right")}
          class="mt-0.5 size-4 shrink-0 text-action"
        />
      </button>
    </div>
    """
  end

  @doc """
  The eight situations an alert can be about, in the prototype's order.

  The wording is the prototype's: a reader picks the sentence that describes
  their day, and the description tells them what the choice opens up next. The
  values are `GtfsPlanner.Alerts.Alert`'s own situations, so a card cannot offer
  a situation the row cannot store.
  """
  @situation_choices [
    %{
      value: "delay",
      label: "Delays",
      description: "Service is running late.",
      icon: "hero-clock"
    },
    %{
      value: "detour",
      label: "Detour",
      description: "A different path, with stops skipped.",
      icon: "hero-arrow-right"
    },
    %{
      value: "stop_moved",
      label: "Stop moved",
      description: "Riders board somewhere else.",
      icon: "hero-map-pin"
    },
    %{
      value: "stop_closed",
      label: "Stop closed",
      description: "A stop cannot be used.",
      icon: "hero-x-circle"
    },
    %{
      value: "cancelled_trips",
      label: "Trips cancelled",
      description: "Specific departures will not run.",
      icon: "hero-calendar-days"
    },
    %{
      value: "suspension",
      label: "Service suspended",
      description: "A route or the whole system is not running.",
      icon: "hero-pause-circle"
    },
    %{
      value: "accessibility",
      label: "Accessibility issue",
      description: "An elevator, entrance or ramp is unavailable.",
      icon: "hero-chevron-up-down"
    },
    %{
      value: "service_change",
      label: "Service change",
      description: "Fewer trips, extra service or rider information.",
      icon: "hero-information-circle"
    }
  ]

  attr :alert, :any, required: true
  attr :event, :string, required: true

  def situation_question(assigns) do
    ~H"""
    <.choice_cards
      id="situation"
      event={@event}
      name="situation"
      choices={situations_for(assigns.alert)}
    />
    """
  end

  defp situations_for(alert) do
    Enum.map(@situation_choices, fn choice ->
      Map.put(
        choice,
        :selected?,
        alert != nil and alert.situation == String.to_atom(choice.value)
      )
    end)
  end

  @doc """
  The one question a service change asks before its routes: what changes.

  The three answers are the prototype's, in its order, and each is the value
  `Alert.service_change_kind` stores.
  """
  @change_choices [
    %{
      value: "fewer_trips",
      label: "Fewer trips",
      description: "Riders find some departures missing."
    },
    %{
      value: "extra_service",
      label: "Extra service",
      description: "Riders find departures that are not usual."
    },
    %{
      value: "information",
      label: "Information for riders",
      description: "Nothing changes; riders should know."
    }
  ]

  attr :alert, :any, required: true
  attr :event, :string, required: true

  def change_question(assigns) do
    ~H"""
    <.choice_cards
      id="change"
      event={@event}
      name="kind"
      choices={changes_for(assigns.alert)}
    />
    """
  end

  defp changes_for(alert) do
    Enum.map(@change_choices, fn choice ->
      Map.put(
        choice,
        :selected?,
        alert != nil and alert.service_change_kind == String.to_atom(choice.value)
      )
    end)
  end

  @doc """
  Which service is affected: one card per route type the version actually runs.

  The question only appears for a version with more than one route type
  (`steps_for/2`), and the options are that version's own route types rather than
  the whole GTFS table, so a card is never a service the agency does not run.
  """
  attr :alert, :any, required: true
  attr :event, :string, required: true
  attr :route_types, :list, required: true, doc: "the version's route types, ascending"

  def mode_question(assigns) do
    ~H"""
    <.choice_cards
      id="mode"
      event={@event}
      name="route_type"
      choices={modes_for(assigns.alert, assigns.route_types)}
    />
    """
  end

  defp modes_for(alert, route_types) do
    Enum.map(route_types, fn route_type ->
      %{
        value: Integer.to_string(route_type),
        route_type: route_type,
        label: Route.route_type_label(route_type),
        description: "Every #{String.downcase(Route.route_type_label(route_type))} route.",
        icon: "hero-truck"
      }
    end)
    |> Enum.map(fn choice ->
      Map.put(
        choice,
        :selected?,
        alert != nil and scope_of(alert).mode_route_type == choice.route_type
      )
    end)
  end

  @doc """
  Which direction is affected: both, or one of the directions the chosen routes
  run.

  "Both directions" stores no direction at all, which is how the scope answer
  says "every direction"; a narrower alert stores the direction's own number.
  """
  attr :alert, :any, required: true
  attr :event, :string, required: true
  attr :directions, :list, required: true, doc: "`Alerts.route_directions/2` options"

  def direction_question(assigns) do
    ~H"""
    <.choice_cards
      id="direction"
      event={@event}
      name="direction"
      choices={directions_for(assigns.alert, assigns.directions)}
    />
    """
  end

  defp directions_for(alert, directions) do
    chosen = if(alert, do: scope_of(alert).direction_id, else: nil)

    [
      %{
        value: "both",
        direction_id: nil,
        label: "Both directions",
        description: "The whole route is affected."
      }
      | Enum.map(directions, fn direction ->
          %{
            value: Integer.to_string(direction.direction_id),
            direction_id: direction.direction_id,
            label: direction.label,
            description: "One direction of the chosen routes."
          }
        end)
    ]
    |> Enum.map(&Map.put(&1, :selected?, &1.direction_id == chosen))
  end

  @doc """
  Which routes are affected: a search, a multi-select of the matches, and the
  system-wide choice.

  This is the one question in the sequence that is not self-contained, so it does
  not advance on a click: a route multi-select needs **Continue**, and Continue
  with nothing chosen says so inline and stays on the question rather than moving
  to one the editor cannot answer.

  Each route is a button carrying `aria-pressed`, and each toggle saves at once
  through `Alerts.save_draft/4`, which is what makes Back lossless: the choices
  are on the row before Continue is pressed. The search is a plain text input
  whose keystrokes ask `Alerts.search_routes/2` for the version's matches, so the
  list never holds a route the editor could not store (CR-4).
  """
  attr :id, :string, default: "alert-routes"
  attr :options, :list, required: true, doc: "`Alerts.search_routes/2` options"
  attr :selected, :list, required: true, doc: "row UUIDs the alert already names"
  attr :query, :string, default: ""
  attr :error, :string, default: nil
  attr :allow_system?, :boolean, default: true
  attr :system_selected?, :boolean, default: false

  def routes_question(assigns) do
    assigns = assign(assigns, :selected, MapSet.new(assigns.selected))

    ~H"""
    <div id={@id} class="grid gap-4">
      <div class="flex flex-wrap items-center gap-2">
        <.button
          :if={@allow_system?}
          id="alert-routes-system"
          type="button"
          variant={if @system_selected?, do: "secondary", else: "quiet"}
          phx-click="choose_system_scope"
        >
          <.icon name="hero-globe-alt" class="size-4" /> The whole system
        </.button>
        <span :if={@system_selected?} class="text-[13px] font-semibold text-muted">
          Every route in this version is affected.
        </span>
      </div>

      <div :if={not @system_selected?} class="grid gap-3">
        <label for="alert-route-search" class="text-[13px] font-semibold text-strong">
          Find a route
        </label>
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-3 top-[13px] size-5 text-muted"
          />
          <input
            type="search"
            id="alert-route-search"
            name="route_query"
            value={@query}
            phx-keyup="search_routes"
            phx-debounce="200"
            autocomplete="off"
            placeholder="Route number or name"
            class="h-11 w-full rounded-control border border-control bg-white pl-10 pr-3 text-sm text-strong placeholder:text-muted"
          />
        </div>

        <div id="alert-route-options" class="grid gap-2 sm:grid-cols-2">
          <button
            :for={route <- @options}
            id={"alert-route-#{route.id}"}
            type="button"
            phx-click="toggle_route"
            phx-value-id={route.id}
            aria-pressed={to_string(MapSet.member?(@selected, route.id))}
            class={[
              "flex min-h-11 items-center gap-2 rounded-control border p-3 text-left text-sm",
              MapSet.member?(@selected, route.id) && "border-action bg-selection",
              not MapSet.member?(@selected, route.id) && "border-control hover:bg-canvas"
            ]}
          >
            <span class="min-w-0 flex-1 font-semibold text-strong">{route.label}</span>
            <.icon
              :if={MapSet.member?(@selected, route.id)}
              name="hero-check"
              class="size-4 shrink-0 text-action"
            />
          </button>
        </div>

        <p :if={@options == []} id="alert-route-empty" class="text-sm text-muted">
          <%= if @query == "" do %>
            Type a route number or name to search this version's routes.
          <% else %>
            No matching routes. Try a number or another name.
          <% end %>
        </p>
      </div>

      <p id="alert-routes-count" class="text-[13px] text-muted">
        {count_text(MapSet.size(@selected), @system_selected?)}
      </p>

      <p
        :if={@error}
        id="alert-routes-error"
        role="alert"
        tabindex="-1"
        class="rounded-control bg-error-bg p-3 text-sm font-semibold text-error-fg"
      >
        {@error}
      </p>
    </div>
    """
  end

  defp count_text(_count, true), do: "Every route in this version is selected."

  defp count_text(1, false), do: "1 route selected · Select all affected routes."
  defp count_text(count, false), do: "#{count} routes selected · Select all affected routes."

  # The choice travels as `phx-value-<name>`, so each card names which answer it
  # carries rather than every card inventing its own event.
  defp value_attr(name, value), do: [{:"phx-value-#{name}", value}]

  defp scope_of(%{scope: nil}), do: %GtfsPlanner.Alerts.ScopeAnswer{}
  defp scope_of(%{scope: scope}), do: scope

  @doc """
  The rider message fields: the two pieces of text an alert is made of.

  Both inputs carry `phx-debounce="450"`, so typing saves 450 ms after the last
  keystroke rather than on every character (AC-16), and both are named under
  `alert[message]` so `Alerts.save_draft/4` casts them through the message
  embed's own changeset. The values they render are the form's own, which is
  what keeps a typed value on screen when a save is refused: the editor rebuilds
  that form from the refused changeset, not from the row, so an input shows what
  was typed rather than what the database still holds.

  A refused save's field error is rendered beside the field, never in place of
  it, so the reader can fix one word without retyping the sentence.
  """
  attr :form, :any, required: true, doc: "the `to_form/2` assign for this alert"

  def message_fields(assigns) do
    ~H"""
    <div id="alert-message-fields" class="grid gap-4">
      <.inputs_for :let={f} field={@form[:message]}>
        <.input
          field={f[:header]}
          type="text"
          label="Short message"
          maxlength="120"
          phx-debounce="450"
          help="One line naming the effect and the place."
        />
        <.input
          field={f[:description]}
          type="textarea"
          label="Full message"
          rows="5"
          phx-debounce="450"
          help="Add the cause, the time and what to do instead."
        />
      </.inputs_for>
    </div>
    """
  end

  @doc """
  The banner a stale save raises in place of the ordinary question body.

  It says what happened and offers exactly two ways forward: take the newer
  saved draft (**Load latest**), or keep the typed values as a separate alert
  (**Save as new alert**). There is deliberately no "overwrite" action: a stale
  write never overwrites a newer revision, and a banner offering to force it
  would be the same failure wearing a button (R6, AC-16).
  """
  attr :id, :string, default: "alert-conflict"

  def conflict_banner(assigns) do
    ~H"""
    <.callout
      id={@id}
      kind="warning"
      title="This alert changed in another tab or by another editor."
      class="mb-4 rounded-card"
    >
      <p id={"#{@id}-body"}>
        Your latest changes aren't saved. Load the current draft to keep going, or save what
        you have here as a new alert.
      </p>
      <div class="mt-3 flex flex-wrap items-center gap-2">
        <.button id="conflict-load-latest" type="button" variant="primary" phx-click="load_latest">
          <.icon name="hero-arrow-path" class="size-4" /> Load latest
        </.button>
        <.button
          id="conflict-save-new"
          type="button"
          variant="secondary"
          phx-click="save_as_new"
        >
          Save as new alert
        </.button>
      </div>
    </.callout>
    """
  end

  @doc """
  The bottom bar: the save status on the left, the way out on the right.

  The status line is a polite live region, so a save that lands while the editor
  is reading the question is announced rather than silent (AC-16). The wording
  is the prototype's save vocabulary rather than its own: `Saving…` while a save
  is in flight, `Saved` once the server has acknowledged it, `Not saved.` with a
  **Retry** action when it has not. The status therefore never claims `Saved`
  before the server has actually said so (FH-16).

  **Save and close** is the primary action: it saves and returns to the list, so
  leaving the editor never silently drops what was typed. Delete alert sits at
  the left because it is destructive and must not be the button nearest Save.
  """
  attr :id, :string, default: "alert-save-bar"
  attr :status, :string, required: true
  attr :state, :atom, required: true, doc: ":idle, :saving, :saved or :error"
  attr :show_delete?, :boolean, default: false
  attr :back_path, :string, required: true

  attr :form_id, :string,
    default: nil,
    doc: "the draft form's id, so Save and close submits what is typed"

  def save_bar(assigns) do
    ~H"""
    <div id={@id} class="mt-6 border-t border-subtle bg-white">
      <div class="flex flex-wrap items-center gap-3 px-4 py-3 sm:px-6">
        <div class="mr-auto min-w-0">
          <p
            id="alert-save-status"
            role="status"
            aria-live="polite"
            class={[
              "text-[13px]",
              @state == :error && "font-semibold text-error-fg",
              @state != :error && "text-muted"
            ]}
          >
            {@status}
          </p>
          <.button
            :if={@state == :error}
            id="alert-save-retry"
            type="button"
            variant="quiet"
            phx-click="retry_save"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Retry
          </.button>
        </div>
        <.button
          :if={@show_delete?}
          id="delete-alert"
          type="button"
          variant="quiet"
          phx-click="open_delete"
        >
          <.icon name="hero-trash" class="size-4" /> Delete alert
        </.button>
        <.link
          id="alert-back-to-list"
          navigate={@back_path}
          class="inline-flex min-h-11 items-center gap-2 rounded-control px-4 text-sm font-semibold no-underline hover:bg-canvas"
        >
          Back to alerts
        </.link>
        <.button
          :if={@form_id}
          id="alert-save-close"
          type="submit"
          variant="primary"
          form={@form_id}
        >
          Save and close
        </.button>
        <%!-- The assistant frame owns its own questions in step 27 and has no
             draft form to submit yet, so the same action is a click there. --%>
        <.button
          :if={is_nil(@form_id)}
          id="alert-save-close"
          type="button"
          variant="primary"
          phx-click="save_and_close"
        >
          Save and close
        </.button>
      </div>
    </div>
    """
  end

  # The prototype's "All routes" pill, for an alert about the whole system: it
  # is a label rather than a route, so it is not a route badge.
  defp all_routes_badge(assigns) do
    ~H"""
    <span class="inline-flex h-7 items-center rounded-badge bg-canvas px-2 text-[13px] font-semibold text-strong">
      All routes
    </span>
    """
  end

  defp chip_class do
    "rounded-selector bg-canvas px-2 py-0.5 text-[13px] font-medium text-muted"
  end

  defp stop_count_label(1), do: "1 stop"
  defp stop_count_label(count), do: "#{count} stops"
end
