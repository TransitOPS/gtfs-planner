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

  import GtfsPlannerWeb.PlannerComponents, only: [form_error_summary: 1]

  alias Phoenix.LiveView.JS
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias LiveSelect.Component, as: LiveSelectComponent

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
  Which place the alert is about: a `LiveSelect` over the version's stops.

  The combobox is the same control `Gtfs.TransfersLive` uses, so a stop an
  operator can find in the transfer editor is a stop they can find here. It
  carries no `phx-change` of its own: `LiveSelect` writes the chosen value into
  the form's hidden field and the form's own `phx-change` carries it, so a
  selection and a typed answer arrive through one writer (INV-1).

  The search matches on name, number and platform code, and lists only stops of
  the alert's own version, so the widget cannot offer a stop this alert could
  not store (CR-4). The prototype's "Affected routes at this place" is answered
  by the routes question that follows, which arrives with the serving routes
  already pressed.
  """
  attr :field, :any, required: true, doc: "the `to_form/2` field the combobox writes to"

  def place_question(assigns) do
    ~H"""
    <div id="alert-place" class="grid gap-2">
      <label for="place_stop_id_text_input" class="text-[13px] font-semibold text-strong">
        Find the stop or station
      </label>
      <.stop_search
        id="alert-place-stop"
        field={@field}
        placeholder="Stop name or number"
        hint="Search by name, number or platform code. Choosing a result names the place; typing alone does not."
      />
    </div>
    """
  end

  @doc """
  Which stops a detour skips, and the stretch that names them in one answer.

  The list is the chosen route's own stops in the order riders meet them, each
  one a toggle that writes at once, so Back loses nothing and Continue is only
  the action that moves on (AC-17, AC-18).

  The stretch is a `from`/`to` pair over the same list: choosing the two ends
  resolves the stops between them server-side, because the route's stop order is
  data and an editor should not have to count stops to describe a detour.
  """
  attr :options, :list,
    required: true,
    doc: "`Alerts.route_stops/2` options for the chosen routes"

  attr :selected, :list, required: true, doc: "row UUIDs the alert already skips"

  attr :stretch, :map,
    default: %{},
    doc: "the two ends named so far, keyed by \"from\" and \"to\""

  attr :error, :string, default: nil

  def stops_question(assigns) do
    assigns = assign(assigns, :selected, MapSet.new(assigns.selected))

    ~H"""
    <div id="alert-stops" class="grid gap-4">
      <p class="text-sm text-muted">
        Select only stops riders cannot use. Stops that still have service stay out of this alert.
      </p>

      <fieldset id="alert-stops-list" class="grid gap-2">
        <legend class="sr-only">Skipped stops</legend>
        <button
          :for={stop <- @options}
          id={"alert-stop-#{stop.id}"}
          type="button"
          phx-click="toggle_stop"
          phx-value-id={stop.id}
          aria-pressed={to_string(MapSet.member?(@selected, stop.id))}
          class={[
            "flex min-h-11 items-center gap-2 rounded-control border p-3 text-left text-sm",
            MapSet.member?(@selected, stop.id) && "border-action bg-selection",
            not MapSet.member?(@selected, stop.id) && "border-control hover:bg-canvas"
          ]}
        >
          <span class="min-w-0 flex-1 font-semibold text-strong">{stop.label}</span>
          <span :if={stop.platform_code} class="text-[13px] text-muted">{stop.platform_code}</span>
          <.icon
            :if={MapSet.member?(@selected, stop.id)}
            name="hero-check"
            class="size-4 shrink-0 text-action"
          />
        </button>

        <p :if={@options == []} id="alert-stops-empty" class="text-sm text-muted">
          Choose a route first, and its stops are listed here in the order riders meet them.
        </p>
      </fieldset>

      <details
        :if={@options != []}
        id="alert-stops-stretch"
        class="rounded-control border border-subtle p-3"
      >
        <summary class="cursor-pointer text-sm font-semibold text-strong">
          Select a stretch of stops
        </summary>
        <div class="mt-3 grid gap-3 sm:grid-cols-2">
          <div class="grid gap-1.5">
            <label for="alert-stretch-from" class="text-[13px] font-semibold text-strong">
              First skipped stop
            </label>
            <select
              id="alert-stretch-from"
              phx-change="select_stretch"
              phx-value-which="from"
              aria-label="First skipped stop"
              class="h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong"
            >
              <option value="">Choose…</option>
              <option :for={stop <- @options} value={stop.id} selected={stop.id == @stretch["from"]}>
                {stop.label}
              </option>
            </select>
          </div>

          <div class="grid gap-1.5">
            <label for="alert-stretch-to" class="text-[13px] font-semibold text-strong">
              Last skipped stop
            </label>
            <select
              id="alert-stretch-to"
              phx-change="select_stretch"
              phx-value-which="to"
              aria-label="Last skipped stop"
              class="h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong"
            >
              <option value="">Choose…</option>
              <option :for={stop <- @options} value={stop.id} selected={stop.id == @stretch["to"]}>
                {stop.label}
              </option>
            </select>
          </div>
        </div>
        <.button id="alert-stretch-select" type="button" class="mt-3" phx-click="select_stretch">
          Select stops
        </.button>
        <p class="mt-2 text-[13px] text-muted">
          Every stop between the two ends is skipped, in the route's own order.
        </p>
      </details>

      <p
        :if={@error}
        id="alert-stops-error"
        role="alert"
        tabindex="-1"
        class="text-sm font-semibold text-error-fg"
      >
        {@error}
      </p>

      <div class="border-t border-subtle pt-3">
        <.button id="all-stops-served" type="button" variant="quiet" phx-click="all_stops_served">
          All stops still served
        </.button>
        <p class="mt-1 text-[13px] text-muted">
          Riders can still reach every stop on these routes, so this is a delay notice rather than a
          detour.
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Whether the routes the alert does not name are affected at the same stops.

  This is the question the prototype asks in the stop's own words: "Route 12
  also stops at N Coast Hwy & NE 6th St. Is it affected too?" Each unchosen
  route that serves a chosen stop is named, with the stops it shares, because the
  reader is deciding about that place and not about a route in the abstract.

  Both answers are self-contained and save at once (AC-17). "Yes" stores the
  route/stop pairs that make those routes affected, so the alert's target stays
  the stops; "no" stores that they are not affected. The question is absent
  entirely when no unchosen route serves a chosen stop, which is the
  `steps_for/2` condition rather than a card that renders empty.
  """
  attr :routes, :list, required: true, doc: "unchosen routes with the stops they share"
  attr :all_routes?, :boolean, default: nil

  def shared_question(assigns) do
    ~H"""
    <div id="alert-shared" class="grid gap-4">
      <p :if={@routes == []} class="text-sm text-muted">
        No other route in this version serves the stops you chose.
      </p>

      <fieldset :if={@routes != []} class="rounded-control bg-info-bg p-4">
        <legend class="text-sm font-bold text-info-fg">Other routes use these stops too</legend>

        <p
          :for={entry <- @routes}
          id={"alert-shared-#{entry.route.id}"}
          class="mt-2 text-sm text-info-fg"
        >
          {shared_phrase(entry)}
        </p>

        <div :for={entry <- @routes} class="mt-3 grid gap-2 sm:grid-cols-2">
          <button
            id={"alert-shared-#{entry.route.id}-no"}
            type="button"
            phx-click="choose_shared"
            phx-value-answer="no"
            aria-pressed={to_string(@all_routes? == false)}
            class={[
              "flex min-h-11 items-center gap-2 rounded-control border bg-white p-3 text-left text-sm",
              @all_routes? == false && "border-action bg-selection",
              @all_routes? != false && "border-control hover:bg-canvas"
            ]}
          >
            <span class="min-w-0 flex-1 font-semibold text-strong">
              Only {entry.route.label}
            </span>
          </button>

          <button
            id={"alert-shared-#{entry.route.id}-yes"}
            type="button"
            phx-click="choose_shared"
            phx-value-answer="yes"
            aria-pressed={to_string(@all_routes? == true)}
            class={[
              "flex min-h-11 items-center gap-2 rounded-control border bg-white p-3 text-left text-sm",
              @all_routes? == true && "border-action bg-selection",
              @all_routes? != true && "border-control hover:bg-canvas"
            ]}
          >
            <span class="min-w-0 flex-1 font-semibold text-strong">
              {entry.route.label} is affected too
            </span>
          </button>
        </div>
      </fieldset>
    </div>
    """
  end

  # "Route 12 also stops at N Coast Hwy & NE 6th St. Is it affected too?" - the
  # prototype's own sentence, with the route's label and the stop names the
  # version gave them.
  defp shared_phrase(entry) do
    names =
      entry.stops
      |> Map.values()
      |> Enum.sort()
      |> Enum.join(", ")

    "#{entry.route.label} also stops at #{names}. Is it affected too?"
  end

  @doc """
  Where riders should board instead, and what is unavailable at an
  accessibility alert's place.

  Two answers to one question, as the reference has them: a stop from this
  version's list, or a written temporary location. The combobox excludes the
  stops the alert is already about and lists the chosen routes' stops first, so
  the affected stop cannot be offered to itself and the nearest stop on the same
  route is the first thing an editor sees (AC-18).

  **Write directions instead** clears the chosen stop rather than adding to it,
  because the two are alternatives; the textarea carries `phx-debounce="450"`
  like every other typed answer, so it saves once the typing settles. The
  facility field is the accessibility question's own answer and is cast by the
  same changeset.
  """
  attr :alert, :any, required: true
  attr :form, :any, required: true, doc: "the editor's `to_form/2` form, refused writes included"
  attr :field, :any, required: true, doc: "the `to_form/2` field the boarding combobox writes to"
  attr :directions_open?, :boolean, default: false
  attr :error, :string, default: nil

  def alternative_question(assigns) do
    ~H"""
    <div id="alert-alternative" class="grid gap-4">
      <div id="alert-boarding" class="grid gap-2">
        <label for="alternative_stop_id_text_input" class="text-[13px] font-semibold text-strong">
          Where should riders board instead?
        </label>
        <.stop_search
          id="alert-boarding-stop"
          field={@field}
          placeholder="Stop name or number"
          hint="Search by stop name or number. The stops this alert already names are not offered."
        />
      </div>

      <.button id="write-directions" type="button" variant="quiet" phx-click="write_directions">
        <.icon name="hero-pencil" class="size-4" /> Write directions instead
      </.button>

      <.inputs_for :let={f} field={@form[:scope]}>
        <.input
          :if={@directions_open?}
          id="write-directions-field"
          field={f[:alternative_directions]}
          type="textarea"
          label="Other boarding instructions"
          rows="3"
          maxlength="500"
          phx-debounce="450"
          help="Describe a temporary stop here, or add instructions for the selected stop."
        />

        <.input
          :if={@alert && @alert.situation == :accessibility}
          field={f[:facility]}
          type="text"
          label="Affected elevator, entrance or ramp"
          maxlength="200"
          phx-debounce="450"
          help="Name the facility riders cannot use."
        />
      </.inputs_for>

      <p
        :if={@error}
        id="alert-alternative-error"
        role="alert"
        tabindex="-1"
        class="text-sm font-semibold text-error-fg"
      >
        {@error}
      </p>
    </div>
    """
  end

  @doc """
  Which departures will not run, and on which dates (AC-19).

  A cancelled trip is named the way a rider names it - the first departure and
  where it goes - because the departures come from `Alerts.departures_on/4`,
  which reads the schedule of the alert's own version and offers only the trips
  whose service is active on the date being listed (AC-10, CR-4).

  The service date is chosen here rather than in the timing step: a cancelled
  trip carries its service date in the alert itself, and the specification's
  step sequence puts `departures` - with no `timing` - between `routes` and
  `reason` for `cancelled_trips`. **Add date** appends a date to the working
  list and gives it its own checklist; removing a date takes its pairs out of
  the alert.

  Every checkbox writes at once, so Back is lossless, and Continue is the
  action that moves on. A date the route does not run says so rather than
  showing an empty list.
  """
  attr :dates, :list,
    required: true,
    doc: "one `%{date: Date, departures: [departure]}` entry per service date, earliest first"

  attr :form, :any, required: true, doc: "the `to_form/2` form the date input writes to"

  attr :routes_chosen?, :boolean, default: false, doc: "whether the alert already names a route"

  attr :error, :string, default: nil

  def departures_question(assigns) do
    ~H"""
    <div id="alert-departures" class="grid gap-4">
      <p class="text-sm text-muted">
        Only the departures you choose are marked cancelled, and only on the dates you name here.
        Times past midnight say so.
      </p>

      <div id="alert-departure-dates" class="grid gap-2">
        <.input
          type="date"
          field={@form[:date]}
          id="service-date"
          label="Service date"
          help="Choose a date this route runs, then add it. Each date gets its own list of departures."
        />

        <div>
          <.button id="add-service-date" type="button" phx-click="add_service_date">
            <.icon name="hero-plus" class="size-4" /> Add date
          </.button>
        </div>
      </div>

      <p :if={not @routes_chosen?} id="alert-departures-no-route" class="text-sm text-muted">
        Choose a route first, and its departures are listed here for each date you name.
      </p>

      <div
        :for={group <- @dates}
        id={"alert-departures-#{Date.to_iso8601(group.date)}"}
        class="grid gap-2"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h3 class="text-sm font-semibold text-strong">
            {Calendar.strftime(group.date, "%A, %B %-d")}
          </h3>
          <.button
            id={"alert-remove-date-#{Date.to_iso8601(group.date)}"}
            type="button"
            variant="quiet"
            phx-click="remove_service_date"
            phx-value-date={Date.to_iso8601(group.date)}
          >
            <.icon name="hero-x-mark" class="size-4" /> Remove this date
          </.button>
        </div>

        <fieldset id={"alert-departure-list-#{Date.to_iso8601(group.date)}"} class="grid gap-2">
          <legend class="sr-only">Departures on {Calendar.strftime(group.date, "%A, %B %-d")}</legend>
          <%!-- The input sits beside its label rather than inside it. A checkbox
                 nested in the label that points at it is activated twice by the
                 keyboard - once by the control and once by the label - so Space
                 would store the pair and immediately take it back. --%>
          <div
            :for={departure <- group.departures}
            class="flex min-h-11 items-start gap-3 rounded-control border border-subtle px-3 py-2 has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
          >
            <input
              type="checkbox"
              id={"alert-departure-#{Date.to_iso8601(group.date)}-#{departure.trip_id}"}
              checked={departure.selected?}
              phx-click="toggle_departure"
              phx-value-trip-id={departure.trip_id}
              phx-value-date={Date.to_iso8601(group.date)}
              class="mt-1 size-5 shrink-0 accent-action"
            />
            <label
              for={"alert-departure-#{Date.to_iso8601(group.date)}-#{departure.trip_id}"}
              class="min-w-0 flex-1 cursor-pointer"
            >
              <span class="block text-sm font-[650] text-strong">{departure.label}</span>
              <span :if={departure.route_label} class="block text-[13px] text-muted">
                {departure.route_label}
              </span>
            </label>
          </div>

          <p
            :if={group.departures == []}
            id={"alert-departures-empty-#{Date.to_iso8601(group.date)}"}
            class="text-sm text-muted"
          >
            No departures run on this date.
          </p>
        </fieldset>
      </div>

      <p
        :if={@error}
        id="alert-departures-error"
        role="alert"
        tabindex="-1"
        class="text-sm font-semibold text-error-fg"
      >
        {@error}
      </p>
    </div>
    """
  end

  @doc """
  When this applies: the timing question, for a current or a planned alert
  (AC-20).

  The two halves are the prototype's own `nowWhen` and `plannedWhen` cards: a
  current alert asks when it started and how it ends, and a planned alert asks
  whether the change happens once or repeats each week, over which dates, at
  which time of day, with any individual dates added or removed.

  Every date and time is civil and is read in the version's own zone, which this
  card names; nothing here converts between zones (CR-7).

  The end-kind cards write the kind and reveal what that kind needs: a
  confirmed end expires the alert and so asks a date and a time, while an
  estimated or unknown end leaves it running and asks when staff check back.
  The overnight note appears whenever Until is at or before From, because that
  period ends on the following morning (R12). It is a sentence rather than a
  colour, because it is an instruction and not a warning.

  The preview is `Recurrence.occurrences/1` read from the saved answer, so the
  dates a reader counts here are the dates the alert stores, and an answer the
  bounds refuse shows the same message those bounds produce rather than a
  partial list.

  The notice date renders its derived default as its value - the later of the
  agency's today and seven days before the first date - so the rule is visible
  before it is typed rather than after it is stored.
  """
  attr :alert, :any, required: true
  attr :form, :any, required: true
  attr :now?, :boolean, required: true

  attr :date_form, :any,
    required: true,
    doc: "the `to_form/2` form the exception-date input writes to"

  attr :occurrences, :list, required: true, doc: "`Recurrence.occurrences/1` for the saved answer"
  attr :notice_value, :string, default: nil
  attr :check_in_options, :list, required: true, doc: "the check-in offsets this editor offers"
  attr :error, :string, default: nil

  def timing_question(assigns) do
    ~H"""
    <div id="alert-timing" class="grid gap-4">
      <p id="alert-timing-zone" class="text-sm text-muted">
        All dates and times are in {timing_zone(@alert)}.
      </p>

      <.now_timing_fields
        :if={@now?}
        alert={@alert}
        form={@form}
        check_in_options={@check_in_options}
      />

      <.planned_timing_fields
        :if={not @now?}
        alert={@alert}
        form={@form}
        date_form={@date_form}
        notice_value={@notice_value}
      />

      <div
        :if={not @now? and @occurrences != []}
        id="alert-timing-preview"
        class="rounded-card border border-subtle p-4"
      >
        <p id="alert-timing-count" class="text-sm font-bold text-strong">
          {occurrence_count(@occurrences)}
        </p>

        <ol id="alert-timing-occurrences" class="mt-2 grid max-h-72 gap-1 overflow-y-auto">
          <li
            :for={occurrence <- @occurrences}
            id={"alert-timing-occurrence-#{Date.to_iso8601(occurrence.date)}"}
            class="flex flex-wrap items-baseline justify-between gap-2 text-[13px]"
          >
            <span class="font-semibold text-strong">{long_date(occurrence.date)}</span>
            <span class="text-muted">{occurrence_window(occurrence)}</span>
          </li>
        </ol>
      </div>

      <p
        :if={@error}
        id="alert-timing-error"
        role="alert"
        tabindex="-1"
        class="text-sm font-semibold text-error-fg"
      >
        {@error}
      </p>
    </div>
    """
  end

  # The three ways a current disruption ends, in the prototype's words. A
  # function rather than a module attribute because it is read from the template
  # below, which the compiler does not count as an attribute use.
  defp end_kind_choices do
    [
      %{
        value: "unknown",
        label: "Not known yet",
        description: "Keep the alert live until someone ends it."
      },
      %{
        value: "estimated",
        label: "Estimated recovery",
        description: "Tell riders the estimate; keep it live until confirmed."
      },
      %{
        value: "confirmed",
        label: "Confirmed end time",
        description: "Automatically end the alert at this time."
      }
    ]
  end

  attr :alert, :any, required: true
  attr :form, :any, required: true
  attr :check_in_options, :list, required: true

  # The half of the timing question a current disruption asks: when it started
  # and how it ends.
  defp now_timing_fields(assigns) do
    ~H"""
    <div id="alert-timing-now-fields" class="grid gap-4">
      <.choice_cards
        id="alert-timing-end-kind"
        event="choose_end_kind"
        name="end_kind"
        choices={selected_choices(end_kind_choices(), end_kind_of(@alert))}
      />

      <.inputs_for :let={f} field={@form[:timing]}>
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={f[:start_date]}
            type="date"
            id="timing-start-date"
            label="Started"
            help="The date service changed."
          />

          <.input
            field={f[:start_time]}
            type="time"
            id="timing-start-time"
            label="Starting at"
            phx-debounce="450"
            help="The time riders were first affected."
          />

          <.input
            :if={end_time_shown?(@alert)}
            field={f[:end_time]}
            type="time"
            id="timing-end-time"
            label={if confirmed?(@alert), do: "End alert at", else: "Expected recovery"}
            phx-debounce="450"
          />

          <.input
            :if={confirmed?(@alert)}
            field={f[:end_date]}
            type="date"
            id="timing-end-date"
            label="Ends on"
            help="The alert expires on its own at this time."
          />

          <.input
            :if={check_in_shown?(@alert)}
            type="select"
            name="check_in_offset"
            id="timing-check-in"
            label="Remind me to check"
            options={Enum.map(@check_in_options, &{&1.label, Integer.to_string(&1.minutes)})}
            value={selected_check_in(@check_in_options)}
            help="A reminder for staff. The alert stays live until service is confirmed restored."
          />
        </div>
      </.inputs_for>
    </div>
    """
  end

  # A planned change: once, or the same days each week for a number of weeks.
  defp pattern_choices do
    [
      %{
        value: "continuous",
        label: "Once",
        description: "One date or a continuous period."
      },
      %{
        value: "weekly",
        label: "Repeats each week",
        description: "Select weekdays, then add or remove individual dates."
      }
    ]
  end

  # Monday to Sunday, as riders name them and as the ISO weekday numbers the
  # timing answer stores.
  defp weekdays do
    [
      %{iso: 1, short: "Mon", long: "Monday"},
      %{iso: 2, short: "Tue", long: "Tuesday"},
      %{iso: 3, short: "Wed", long: "Wednesday"},
      %{iso: 4, short: "Thu", long: "Thursday"},
      %{iso: 5, short: "Fri", long: "Friday"},
      %{iso: 6, short: "Sat", long: "Saturday"},
      %{iso: 7, short: "Sun", long: "Sunday"}
    ]
  end

  attr :alert, :any, required: true
  attr :form, :any, required: true
  attr :date_form, :any, required: true
  attr :notice_value, :string, default: nil

  defp planned_timing_fields(assigns) do
    ~H"""
    <div id="alert-timing-planned-fields" class="grid gap-4">
      <.choice_cards
        id="alert-timing-pattern"
        event="choose_pattern"
        name="pattern"
        choices={selected_choices(pattern_choices(), pattern_of(@alert))}
      />

      <.inputs_for :let={f} field={@form[:timing]}>
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={f[:first_date]}
            type="date"
            id="timing-first-date"
            label={if weekly?(@alert), do: "First date", else: "Starts on"}
          />

          <.input
            :if={not weekly?(@alert)}
            field={f[:last_date]}
            type="date"
            id="timing-last-date"
            label="Ends on"
          />

          <.input
            :if={weekly?(@alert)}
            field={f[:weeks]}
            type="number"
            id="timing-weeks"
            label="Number of weeks"
            min="1"
            max="52"
            phx-debounce="450"
            help="Between 1 and 52 weeks."
          />
        </div>

        <div class="mt-2 flex items-center gap-3">
          <%!-- The checkbox sits beside its label rather than inside it: a
                 control nested in the label that points at it is activated
                 twice by the keyboard. The hidden field is what carries the
                 "no longer all day" answer when the box is cleared. --%>
          <input type="hidden" name={f[:all_day].name} value="false" />
          <input
            type="checkbox"
            id="timing-all-day"
            name={f[:all_day].name}
            value="true"
            checked={checked?(f[:all_day].value)}
            class="size-5 shrink-0 accent-action"
          />
          <label for="timing-all-day" class="cursor-pointer text-sm font-semibold text-strong">
            All day
          </label>
        </div>

        <div :if={not all_day?(@alert)} class="mt-2 grid gap-4 sm:grid-cols-2">
          <.input
            field={f[:start_time]}
            type="time"
            id="timing-day-start"
            label="From"
            phx-debounce="450"
          />

          <.input
            field={f[:end_time]}
            type="time"
            id="timing-day-end"
            label="Until"
            phx-debounce="450"
          />
        </div>
      </.inputs_for>

      <p
        :if={overnight?(@alert)}
        id="alert-timing-overnight"
        class="text-sm font-semibold text-default"
      >
        Ends the following day. Each date below is the night it starts.
      </p>

      <div :if={weekly?(@alert)} id="alert-timing-weekly" class="grid gap-4">
        <fieldset id="alert-timing-weekdays" class="grid gap-2">
          <legend class="text-sm font-semibold text-strong">Days each week</legend>

          <div class="flex flex-wrap gap-1.5">
            <button
              :for={day <- weekdays()}
              id={"timing-weekday-#{day.iso}"}
              type="button"
              phx-click="toggle_weekday"
              phx-value-day={day.iso}
              aria-pressed={to_string(day.iso in weekdays_of(@alert))}
              aria-label={day.long}
              class={[
                "min-h-11 min-w-11 rounded-control border px-2 text-sm font-semibold transition-colors",
                day.iso in weekdays_of(@alert) && "border-action bg-selection text-action",
                day.iso not in weekdays_of(@alert) &&
                  "border-control text-strong hover:border-action hover:bg-selection"
              ]}
            >
              {day.short}
            </button>
          </div>
        </fieldset>

        <div id="alert-timing-dates" class="grid gap-2">
          <.input
            type="date"
            field={@date_form[:date]}
            id="timing-date"
            label="Add or remove a date"
            help="A date the pattern already covers is removed; any other date is added."
          />

          <div>
            <.button id="add-timing-date" type="button" phx-click="add_timing_date">
              <.icon name="hero-plus" class="size-4" /> Add date
            </.button>
          </div>

          <ul id="alert-timing-date-chips" class="flex flex-wrap gap-2">
            <li :for={date <- added_dates(@alert)} id={date_chip_id("added", date)}>
              <span class="inline-flex min-h-11 items-center gap-2 rounded-control border border-action bg-selection px-3 text-[13px] font-semibold text-action">
                {long_date(date)}
                <.button
                  id={date_chip_button_id("added", date)}
                  type="button"
                  variant="quiet"
                  phx-click="remove_timing_date"
                  phx-value-date={Date.to_iso8601(date)}
                >
                  <.icon name="hero-x-mark" class="size-4" /> Remove
                  <span class="sr-only">{long_date(date)}</span>
                </.button>
              </span>
            </li>

            <li :for={date <- removed_dates(@alert)} id={date_chip_id("removed", date)}>
              <span class="inline-flex min-h-11 items-center gap-2 rounded-control border border-dashed border-strong px-3 text-[13px] font-semibold text-strong line-through">
                {long_date(date)}
                <.button
                  id={date_chip_button_id("removed", date)}
                  type="button"
                  variant="quiet"
                  phx-click="remove_timing_date"
                  phx-value-date={Date.to_iso8601(date)}
                >
                  <.icon name="hero-arrow-uturn-left" class="size-4" /> Put it back
                  <span class="sr-only">{long_date(date)}</span>
                </.button>
              </span>
            </li>
          </ul>
        </div>
      </div>

      <.input
        type="date"
        name="alert[timing][notice_on]"
        id="timing-notice-on"
        label="Riders told from"
        value={@notice_value}
        help="Advance notice does not mean the disruption is happening yet. Riders see the alert from this date, and the service change applies from the dates above."
      />
    </div>
    """
  end

  defp timing_zone(%{timing: %{time_zone: zone}}) when is_binary(zone) and zone != "", do: zone
  defp timing_zone(_alert), do: "the agency's own time zone"

  defp timing_of(%{timing: timing}), do: timing
  defp timing_of(_alert), do: nil

  defp end_kind_of(alert), do: timing_of(alert) && timing_of(alert).end_kind
  defp pattern_of(alert), do: timing_of(alert) && timing_of(alert).pattern
  defp weekdays_of(alert), do: (timing_of(alert) && timing_of(alert).weekdays) || []
  defp added_dates(alert), do: (timing_of(alert) && timing_of(alert).added_dates) || []
  defp removed_dates(alert), do: (timing_of(alert) && timing_of(alert).removed_dates) || []

  defp weekly?(alert), do: pattern_of(alert) == :weekly
  defp confirmed?(alert), do: end_kind_of(alert) == :confirmed

  defp end_time_shown?(alert), do: end_kind_of(alert) in [:estimated, :confirmed]
  defp check_in_shown?(alert), do: end_kind_of(alert) in [:unknown, :estimated]

  defp all_day?(alert), do: timing_of(alert) != nil and timing_of(alert).all_day == true

  # A period whose end is at or before its start ends on the following civil
  # day (R12), so the answer needs saying in words.
  defp overnight?(alert) do
    case timing_of(alert) do
      %{start_time: start, end_time: %Time{} = end_time} ->
        not all_day?(alert) and Time.compare(end_time, start) != :gt

      _other ->
        false
    end
  end

  @doc """
  Why this is happening: the reason question, for every question (AC-21).

  The thirteen cards are the thirteen `GtfsPlanner.Alerts.Alert` causes in the
  prototype's own order and words, each once, so no card can offer a cause the
  row cannot store and none can go missing without a duplicate beside it. The
  two the specification keeps apart stay apart in words too: **Other reason**
  and **Not known yet** are their own cards rather than one "Other" answer.

  Choosing anything but **Other reason** is a self-contained choice and moves
  on by itself. **Other reason** has a second field, so it saves and reveals
  "Describe the other reason" instead, and the editor's Continue carries the
  reader on. That field is optional and never blocks: an alert whose other
  reason is blank is complete (AC-3).
  """
  attr :alert, :any, required: true
  attr :form, :any, required: true

  def reason_question(assigns) do
    ~H"""
    <div id="alert-reason" class="grid gap-4">
      <.choice_cards
        id="alert-cause"
        event="choose_cause"
        name="cause"
        choices={selected_choices(cause_choices(), cause_of(@alert))}
      />

      <div :if={other_cause?(@alert)} id="alert-reason-other">
        <.input
          field={@form[:cause_detail]}
          type="textarea"
          id="cause-detail"
          label="Describe the other reason"
          phx-debounce="450"
          help="This explanation is included in the rider message. Add only confirmed information."
        />
      </div>
    </div>
    """
  end

  # The prototype's CAUSES list, in its order and in its words: a rider is
  # choosing from what they saw happen, not from the feed's vocabulary. The
  # values are the schema's own enum names.
  #
  # A function rather than a module attribute because it is read from the
  # template above, which the compiler does not count as an attribute use - and
  # a template that reads an attribute the LiveView process never set raises
  # `KeyError` on every render.
  defp cause_choices do
    [
      %{value: "construction", label: "Construction or roadwork"},
      %{value: "accident", label: "Crash"},
      %{value: "weather", label: "Weather"},
      %{value: "police_activity", label: "Police activity"},
      %{value: "medical_emergency", label: "Medical emergency"},
      %{value: "demonstration", label: "Demonstration"},
      %{value: "special_event", label: "Special event"},
      %{value: "holiday", label: "Holiday"},
      %{value: "maintenance", label: "Maintenance"},
      %{value: "technical_problem", label: "Vehicle or equipment problem"},
      %{value: "strike", label: "Strike"},
      %{value: "other_cause", label: "Other reason"},
      %{value: "unknown_cause", label: "Not known yet"}
    ]
  end

  @doc """
  The card this question offers for a value, or `nil` for one it never offered.
  The handler asks before it writes, so a hand-made event cannot store a cause
  the reader was never shown.
  """
  def cause_choice(value) when is_binary(value) do
    Enum.find(cause_choices(), &(&1.value == value))
  end

  def cause_choice(_value), do: nil

  @doc """
  The words the editor, the Rider preview and the review use for a stored cause.
  """
  def cause_label(cause) do
    Enum.find_value(cause_choices(), &(&1.value == Atom.to_string(cause) && &1.label))
  end

  defp cause_of(alert), do: alert && alert.cause

  defp other_cause?(alert), do: cause_of(alert) == :other_cause

  defp selected_choices(choices, value) do
    Enum.map(choices, fn choice ->
      Map.put(choice, :selected?, Atom.to_string(value) == choice.value)
    end)
  end

  defp selected_check_in(options) do
    case Enum.find(options, & &1.selected?) do
      nil -> nil
      option -> Integer.to_string(option.minutes)
    end
  end

  defp checked?(value), do: value not in [nil, false, "false"]

  defp date_chip_id(kind, date), do: "alert-timing-#{kind}-#{Date.to_iso8601(date)}"

  defp date_chip_button_id(kind, date), do: "alert-timing-#{kind}-remove-#{Date.to_iso8601(date)}"

  defp occurrence_count(occurrences) do
    first = List.first(occurrences)
    last = List.last(occurrences)
    days = if length(occurrences) == 1, do: "day", else: "days"

    "#{length(occurrences)} #{days}: #{short_date(first.date)} to #{short_date(last.date)}"
  end

  # The window one occurrence covers, in the agency's own words: an all-day
  # period is the whole date, and an overnight period says so rather than
  # reading as an end before its start.
  defp occurrence_window(%{all_day?: true}), do: "All day"

  defp occurrence_window(%{starts: nil}), do: "All day"

  defp occurrence_window(%{starts: starts, ends: nil}), do: clock(starts)

  defp occurrence_window(%{starts: starts, ends: ends}) do
    overnight = if NaiveDateTime.compare(ends, starts) == :gt, do: "", else: " (next day)"
    "#{clock(starts)} to #{clock(ends)}#{overnight}"
  end

  defp clock(datetime), do: Calendar.strftime(datetime, "%-I:%M %p")

  defp long_date(date), do: Calendar.strftime(date, "%A, %B %-d")
  defp short_date(date), do: Calendar.strftime(date, "%b %-d")

  # The one combobox both stop questions use, styled like the transfers editor's
  # so the same control looks the same wherever an operator meets it.
  attr :id, :string, required: true
  attr :field, :any, required: true
  attr :placeholder, :string, required: true
  attr :hint, :string, required: true

  defp stop_search(assigns) do
    ~H"""
    <div class="relative">
      <.icon
        name="hero-magnifying-glass"
        class="pointer-events-none absolute left-3 top-[13px] z-10 size-5 text-muted"
      />
      <.live_component
        module={LiveSelectComponent}
        id={@id}
        field={@field}
        options={[]}
        debounce={200}
        update_min_len={0}
        placeholder={@placeholder}
        container_class="relative"
        text_input_class="h-11 w-full rounded-control border border-control bg-white pl-10 pr-3 text-sm text-strong placeholder:text-muted"
        text_input_selected_class="text-strong"
        dropdown_class="absolute inset-x-0 top-full z-50 mt-1 max-h-64 overflow-auto rounded-card border border-subtle bg-white p-1 text-strong shadow-float"
        option_class="flex min-h-11 flex-col justify-center rounded-control px-3 py-1.5 text-sm"
        active_option_class="bg-selection"
        available_option_class="cursor-pointer hover:bg-canvas"
      >
        <:option :let={option}>
          <span class="font-[650] text-strong">{option.label}</span>
          <span :if={Map.get(option, :hint)} class="text-[13px] text-muted">{option.hint}</span>
        </:option>
      </.live_component>
    </div>
    <p class="mt-1 text-[13px] text-muted">{@hint}</p>
    """
  end

  @doc """
  The message step: the wording a rider reads, and the advice beside it (AC-22).

  It is two states of one card, the way the prototype's message step is. With
  nothing worded yet it offers the organization's scripts, the ones for this
  alert's own situation first, each showing the fill-ins its header will take; the
  rest sit behind a disclosure rather than in a long list. Once there is wording
  it shows the text, where that wording came from, the checks beside it and the
  organization's own guidelines.

  **Review wording** is a warning callout, not a rewrite: the answers changed
  after this text was edited, so the text stays exactly as it was written and the
  callout offers the two ways forward - take the generated text again, or say the
  wording has been checked against the current answers. Nothing here ever
  overwrites the operator's words without an action (AC-22, FH-22).

  The checks are advisory in the same sense: they are reported, and the row saves
  whatever the header and description say whether or not they pass, because
  `Alerts.save_draft/4` reads none of them.

  The three inputs carry `phx-debounce="450"`, so typing saves 450 ms after the
  last keystroke rather than on every character (AC-16), and are named under
  `alert[message]` so `Alerts.save_draft/4` casts them through the message
  embed's own changeset. The values they render are the form's own, which keeps a
  typed value on screen when a save is refused: the editor rebuilds that form
  from the refused changeset, not from the row. A refused save's field error is
  rendered beside the field, never in place of it, so the reader can fix one word
  without retyping the sentence.
  """
  attr :alert, :any, required: true, doc: "the loaded alert, or `nil` before the first answer"
  attr :form, :any, required: true, doc: "the `to_form/2` assign for this alert"

  attr :scripts, :map,
    required: true,
    doc: "`%{matching: [script_option], other: [script_option]}`, prepared by the editor"

  attr :browsing?, :boolean, required: true, doc: "the script chooser is what the card shows"
  attr :script_name, :string, default: nil, doc: "the script the stored wording came from"

  attr :review?, :boolean,
    default: false,
    doc: "`Message.review_wording?/2` says the text needs a second look"

  attr :checks, :list,
    default: [],
    doc: "`Message.checks/2` over the stored answer and the current facts"

  attr :guidelines, :string, default: "", doc: "the organization's writing guidelines"

  def message_question(assigns) do
    ~H"""
    <div id="alert-message" class="grid gap-4">
      <div :if={@browsing?} id="message-scripts" class="grid gap-3">
        <p class="text-sm text-default">
          Scripts are your organization's tested wording. Your answers fill in the
          <span class="rounded-badge bg-soft px-1 text-[12px] font-semibold text-cyan-800">
            highlighted
          </span>
          parts.
        </p>

        <p id="message-scripts-matching" class="text-sm font-[650] text-strong">
          Scripts for {situation_phrase(@alert)}
        </p>
        <.script_list id="message-scripts-list" scripts={@scripts.matching} first={0} />

        <details :if={@scripts.other != []} id="message-scripts-other" class="group">
          <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between text-sm font-[650] text-strong [&::-webkit-details-marker]:hidden">
            Other scripts ({length(@scripts.other)})
            <.icon
              name="hero-chevron-down"
              class="size-4 text-muted transition-transform group-open:rotate-180"
            />
          </summary>
          <div class="grid gap-2 pb-3">
            <.script_list
              id="message-scripts-other-list"
              scripts={@scripts.other}
              first={length(@scripts.matching)}
            />
          </div>
        </details>

        <div class="flex flex-wrap items-center gap-2 border-t border-subtle pt-4">
          <span class="text-sm text-muted">Or</span>
          <.button id="write-message" type="button" variant="quiet" phx-click="write_own_message">
            Write it yourself
          </.button>
        </div>
      </div>

      <div :if={not @browsing?} id="message-wording" class="grid gap-4">
        <.callout
          :if={@review?}
          id="review-wording"
          kind="warning"
          title="The answers changed after this message was edited"
          class="rounded-card"
        >
          <p id="review-wording-body">
            Check the routes, stops and times against the current answers. Your wording stays as
            you wrote it until you replace it.
          </p>
          <div class="mt-3 flex flex-wrap items-center gap-2">
            <.button
              id="use-generated-text"
              type="button"
              variant="primary"
              phx-click="use_generated_text"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Use generated text
            </.button>
            <.button
              id="confirm-wording"
              type="button"
              variant="secondary"
              phx-click="confirm_wording"
            >
              <.icon name="hero-check" class="size-4" /> I checked the message
            </.button>
          </div>
        </.callout>

        <div class="flex flex-wrap items-center gap-2">
          <p id="message-origin" class="text-[13px] text-muted">
            <%= if @script_name do %>
              From script: <span class="font-[650] text-strong">{@script_name}</span>
            <% else %>
              Custom wording. Later answer changes will ask you to check this text.
            <% end %>
          </p>
          <div class="ml-auto flex flex-wrap gap-1">
            <.button
              id="use-generated-text-inline"
              type="button"
              variant="quiet"
              phx-click="use_generated_text"
            >
              Use generated text
            </.button>
            <.button id="browse-scripts" type="button" variant="quiet" phx-click="browse_scripts">
              Browse scripts
            </.button>
          </div>
        </div>

        <.inputs_for :let={f} field={@form[:message]}>
          <.input
            field={f[:header]}
            id="message-header"
            type="text"
            label="Short message"
            maxlength="120"
            phx-debounce="450"
            help="The headline apps show first. Some cut it off after one line."
          />
          <.input
            field={f[:description]}
            id="message-description"
            type="textarea"
            label="Details"
            rows="5"
            phx-debounce="450"
            help="When, where, why, and what to do instead."
          />
          <.input
            field={f[:url]}
            id="message-url"
            type="url"
            label="More information"
            phx-debounce="450"
            help="Optional. A web address riders can read for the full story."
          />
        </.inputs_for>

        <div id="message-guidelines" class="rounded-card bg-canvas px-4 py-3">
          <p class="text-sm font-bold text-strong">Your writing guidelines</p>
          <.advisory_checks scope="message" checks={@checks} />

          <details :if={@guidelines != ""} id="message-guidelines-text" class="group mt-1">
            <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between text-[13px] font-[650] text-action [&::-webkit-details-marker]:hidden">
              Read your organization's guidelines
              <.icon
                name="hero-chevron-down"
                class="size-4 transition-transform group-open:rotate-180"
              />
            </summary>
            <p id="message-guidelines-body" class="pb-2 text-[13px] leading-6 text-default">
              {@guidelines}
            </p>
          </details>
        </div>
      </div>
    </div>
    """
  end

  # One script list: a button per script carrying its own key, so the value the
  # reader chose is the script's own identity rather than a position in a list
  # that can be re-ordered. The header is shown with its fill-ins marked, which
  # is what tells a reader whether this script fits the alert they are writing.
  attr :id, :string, required: true
  attr :scripts, :list, required: true
  attr :first, :integer, required: true, doc: "the id offset, so each list's ids stay unique"

  defp script_list(assigns) do
    ~H"""
    <ul id={@id} class="grid gap-2">
      <li :for={{script, offset} <- Enum.with_index(@scripts)}>
        <button
          type="button"
          id={"message-script-#{@first + offset}"}
          phx-click="choose_script"
          phx-value-key={script.key}
          class="flex w-full min-h-11 flex-col items-start gap-1 rounded-card border border-control bg-white px-4 py-3 text-left hover:border-action hover:bg-selection"
        >
          <span class="flex w-full items-center gap-2">
            <span class="text-sm font-bold text-strong">{script.name}</span>
            <span class="ml-auto text-[12px] text-muted">{script_origin(script)}</span>
          </span>
          <span class="text-sm text-default">
            <.fill_in_chips template={script.header_template} />
          </span>
        </button>
      </li>
    </ul>
    """
  end

  # A script's header with each `[fill-in]` marked, the way the prototype marks
  # them: the words that are fixed and the words this alert's answers supply.
  attr :template, :string, default: nil

  defp fill_in_chips(assigns) do
    ~H"""
    <%= for part <- fill_in_parts(@template) do %>
      <%= case part do %>
        <% {:fill, name} -> %>
          <span class="rounded-badge bg-soft px-1 text-[12px] font-semibold text-cyan-800">
            {name}
          </span>
        <% {:text, text} -> %>
          {text}
      <% end %>
    <% end %>
    """
  end

  @fill_token ~r/\[([a-z ]+)\]/

  # One pass, so a fill-in inside a template's own text is never split twice.
  # The vocabulary is `GtfsPlanner.Alerts.Message`'s; this only marks what that
  # module will replace, and marks nothing the row cannot fill.
  defp fill_in_parts(nil), do: []

  defp fill_in_parts(template) when is_binary(template) do
    @fill_token
    |> Regex.split(template, include_captures: true)
    |> Enum.map(fn
      "[" <> _rest = token ->
        case Regex.run(@fill_token, token) do
          [_matched, name] -> {:fill, name}
          _not_a_fill_in -> {:text, token}
        end

      text ->
        {:text, text}
    end)
  end

  defp script_origin(%{built_in?: true}), do: "Built-in"
  defp script_origin(_script), do: "Your organization"

  defp situation_phrase(alert) do
    case situation_label(alert && alert.situation) do
      nil -> "this alert"
      label -> label |> String.downcase()
    end
  end

  # One list of guideline results, so the message step and the review cannot
  # report the same checks differently. `scope` names the surface, which keeps
  # each list's ids apart: the message step's checks and the review's are two
  # readings of `Message.checks/2`, not one list rendered twice.
  attr :scope, :string, required: true
  attr :checks, :list, required: true

  defp advisory_checks(assigns) do
    ~H"""
    <ul id={"#{@scope}-checks"} class="mt-1.5 grid gap-1">
      <li
        :for={check <- @checks}
        id={"#{@scope}-check-#{check.key}"}
        class={[
          "flex items-start gap-2 text-sm",
          check.ok? && "text-default",
          not check.ok? && "font-semibold text-warning-fg"
        ]}
      >
        <.icon
          name={if check.ok?, do: "hero-check", else: "hero-exclamation-triangle"}
          class={["size-4 mt-0.5 shrink-0", check.ok? && "text-success-fg"]}
        />
        <span>{check.text}</span>
      </li>
    </ul>
    """
  end

  @doc """
  The review step's body: the words a rider will read, and the facts beside them
  (AC-23).

  Two cards, in the prototype's own order. **What riders see** holds the header
  and description exactly as the row stores them - the operator's words,
  character for character, never a regenerated version - under the effect and
  the route badges. **Details** holds the answers as they were saved: When from
  `Alerts.Recurrence.summary/1`, Where riders see it and What's happening from
  the same `Alerts.labels_for/2` labels the Rider preview reads, Why from the
  chosen cause, and the link when the wording carries one. Every value is a
  reading of the saved row, so the review cannot describe an alert the row does
  not hold (CR-4).

  The questions still unanswered sit above them as `<.form_error_summary>`,
  each one a link to the step that answers it. They appear when **Save alert**
  runs `Alerts.Completion.errors/1` and finds some, and the summary takes the
  reader to the first: a refusal that leaves the reader on the button they just
  pressed is a refusal they can miss (AC-23, FH-23).

  The prototype's **Data sent to apps** card is absent with every publication
  state and action, because this package saves an alert and never sends one
  anywhere (R2, CR-1).
  """
  attr :alert, :any, required: true, doc: "the loaded alert, or `nil` before the first answer"

  attr :effect, :atom,
    default: nil,
    doc: "`Alerts.Completion.effect_for/1` for this alert"

  attr :routes, :list, default: [], doc: "affected route rows for their identity badges"
  attr :header, :string, default: nil
  attr :when_summary, :string, default: ""
  attr :where, :string, default: nil
  attr :what, :string, default: nil

  attr :errors, :list,
    default: [],
    doc: "`Alerts.Completion.errors/1` for the row, as `%{href: step path, msg: message}`"

  def review_details(assigns) do
    ~H"""
    <div id="alert-review" class="grid gap-4">
      <%!-- The summary is rendered only after **Save alert** has found these
           questions, so its own arrival is the moment to move the reader onto
           it. `phx-mounted` runs once, when LiveView adds the element, which is
           after the reply that drew it, and `:first-of-type` keeps the reader
           on the first question rather than the last of the list. --%>
      <div
        :if={@errors != []}
        id="review-errors-region"
        phx-mounted={JS.focus(to: "#review-errors a:first-of-type")}
      >
        <.form_error_summary
          id="review-errors"
          title="This alert is not finished yet"
          failures={@errors}
          class=""
        />
      </div>

      <section id="review-riders" class="overflow-clip rounded-card border border-subtle bg-white">
        <div class="border-b border-subtle px-4 py-3 sm:px-5">
          <h3 id="review-riders-title" class="text-base font-bold tracking-normal text-strong">
            What riders see
          </h3>
        </div>
        <div class="px-4 py-4 sm:px-5">
          <div class={["rounded-card border border-l-4 bg-white px-4 py-3", effect_border(@effect)]}>
            <div class="flex flex-wrap items-center gap-1.5">
              <span
                :if={@effect}
                id="review-effect"
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
            <p id="review-header" class="mt-1.5 text-[15px] font-bold leading-snug text-strong">
              {if blank?(@header), do: "Short message", else: @header}
            </p>
            <p
              :if={not blank?(description(@alert))}
              id="review-description"
              class="mt-1 text-sm leading-6 text-default"
            >
              {description(@alert)}
            </p>
          </div>
        </div>
      </section>

      <section id="review-details" class="overflow-clip rounded-card border border-subtle bg-white">
        <div class="border-b border-subtle px-4 py-3 sm:px-5">
          <h3 id="review-details-title" class="text-base font-bold tracking-normal text-strong">
            Details
          </h3>
        </div>
        <dl>
          <.detail_row id="review-when" label="When" value={@when_summary} />
          <.detail_row id="review-where" label="Where riders see it" value={@where} />
          <.detail_row id="review-what" label="What's happening" value={@what} />
          <.detail_row
            id="review-why"
            label="Why"
            value={cause_label(@alert && @alert.cause)}
          />
          <.detail_row id="review-link" label="Link" value={url_of(@alert)} />
        </dl>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil

  defp detail_row(assigns) do
    ~H"""
    <div id={@id} class="grid gap-1 border-t border-subtle px-4 py-3 sm:grid-cols-[200px_1fr] sm:px-5">
      <dt class="text-sm text-muted">{@label}</dt>
      <dd class="text-sm text-strong">{if blank?(@value), do: "Not chosen yet", else: @value}</dd>
    </div>
    """
  end

  @doc """
  The review step's right-hand card: what saving this alert means, the writing
  guidelines' own results, and the one action that finishes it (AC-23).

  **Save alert** is the whole action set of this step. It is the prototype's
  **Publish alert** and **Schedule alert** with the publication this package
  does not do removed, so the review ends in saving a draft rather than in
  sending one (R2, CR-1).

  A `:no_service` alert says what that effect does to a rider's trip plan,
  because it is the one effect that changes what a planner suggests rather than
  what an app displays. No other effect gets a consequence sentence, because no
  other effect has one to give.

  The checks are `Message.checks/2` over the same stored answer the message step
  read, so the review reports the same advice the operator already saw, and
  nothing here refuses the save: the checks are advisory (AC-12, AC-22).
  """
  attr :effect, :atom, default: nil, doc: "`Alerts.Completion.effect_for/1` for this alert"
  attr :checks, :list, default: [], doc: "`Message.checks/2` over the stored answer"

  def review_actions(assigns) do
    ~H"""
    <aside id="alert-review-actions" class="grid content-start gap-4 lg:sticky lg:top-4">
      <section class="grid gap-3 rounded-card border border-subtle bg-white p-4 sm:p-5">
        <h2 id="review-actions-title" class="text-base font-bold tracking-normal text-strong">
          Save this alert
        </h2>
        <p id="review-outcome" class="text-sm text-default">
          Saving keeps this alert with the version you are editing. You can change any answer,
          and the message, whenever you come back.
        </p>

        <p
          :if={@effect == :no_service}
          id="review-no-service"
          class="rounded-card bg-warning-bg px-3 py-2 text-sm text-warning-fg"
        >
          Trip planners may show these trips as cancelled.
        </p>

        <div id="review-guidelines" class="rounded-card bg-canvas px-3 py-2.5">
          <p id="review-guidelines-title" class="text-sm font-bold text-strong">
            Your writing guidelines
          </p>
          <p :if={@checks == []} id="review-checks-empty" class="text-sm text-muted">
            Write a headline and details, and this is where they are checked against your
            guidelines.
          </p>
          <.advisory_checks scope="review" checks={@checks} />
        </div>

        <.button id="save-alert" type="button" variant="primary" class="w-full" phx-click="save_alert">
          <.icon name="hero-check" class="size-4" /> Save alert
        </.button>
      </section>
    </aside>
    """
  end

  defp url_of(%{message: %{url: url}}), do: url
  defp url_of(_alert), do: nil

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
