defmodule GtfsPlannerWeb.ResultComponents do
  @moduledoc """
  Components from the TransitOps application design system for a page that
  reports what a check found: a summary card that leads with the conclusion, a
  titled section that groups findings by weight, a tone badge, and a disclosure
  card for the details behind the result.

  The caller owns every word and every number. A tone is wayfinding: the badge
  and section title always name the state in words, so a result reads without
  colour. Severity belongs to the section, so a row inside it does not repeat it.

  Tokens come from `assets/css/app.css` (`border-error-line`, `bg-error-bg`,
  `text-error-fg`, `rounded-card`, and so on); the components need no page scope.
  Called through an explicit import in each consumer, like `PlannerComponents`.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  @tones %{
    "error" => %{
      bar: "border-error-line",
      badge: "bg-error-bg text-error-fg",
      text: "text-error-fg",
      icon: "hero-x-circle"
    },
    "warning" => %{
      bar: "border-warning-line",
      badge: "bg-warning-bg text-warning-fg",
      text: "text-warning-fg",
      icon: "hero-exclamation-triangle"
    },
    "success" => %{
      bar: "border-success-line",
      badge: "bg-success-bg text-success-fg",
      text: "text-success-fg",
      icon: "hero-check-circle"
    },
    "info" => %{
      bar: "border-info-line",
      badge: "bg-info-bg text-info-fg",
      text: "text-info-fg",
      icon: "hero-information-circle"
    },
    "neutral" => %{
      bar: "border-control",
      badge: "bg-canvas text-muted",
      text: "text-muted",
      icon: "hero-information-circle"
    },
    "muted" => %{
      bar: "border-control",
      badge: "bg-canvas text-muted",
      text: "text-muted",
      icon: "hero-x-circle"
    }
  }

  @tone_values Map.keys(@tones)

  @doc """
  A short state label: the tone's icon and the state in words.

  The `muted` tone is for a failure that follows from another one already shown,
  so it reads as a consequence and not a second problem.

  ## Examples

      <.tone_badge tone="warning">Needs review</.tone_badge>
      <.tone_badge tone="error" icon="hero-question-mark-circle">Couldn't check</.tone_badge>
  """
  attr :tone, :string, values: @tone_values, required: true
  attr :icon, :string, default: nil, doc: "a hero icon name that replaces the tone's own icon"
  attr :spin, :boolean, default: false, doc: "turns the icon while work is in progress"
  attr :class, :any, default: nil, doc: "layout classes for the badge's place in its row"
  attr :rest, :global
  slot :inner_block, required: true

  def tone_badge(assigns) do
    assigns = assign(assigns, :t, Map.fetch!(@tones, assigns.tone))

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 rounded-badge px-2 py-1 text-[13px] font-semibold",
        @t.badge,
        @class
      ]}
      data-tone={@tone}
      {@rest}
    >
      <.icon
        name={@icon || @t.icon}
        class={["size-[15px] shrink-0", @spin && "motion-safe:animate-spin"]}
      /> {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  The first thing on a result page: a tone badge, one sentence that says what
  the result is, an optional paragraph under it, a row of up to three counts
  as evidence, and an optional footer strip for the next step or a stale-result
  reminder.

  A metric's `:label` names the count, its slot body is the caption, and its
  `:id` and `:value_id` are hooks for tests. The row is three equal columns, so
  give it three metrics or none.

  ## Examples

      <.result_summary id="summary" tone="error" badge="Problems found" title="3 problems to fix.">
        Start with the problems.
        <:metric label="Problems" value={3} tone="error">Blocking issues</:metric>
        <:foot>This page shows the check from 2:14 pm.</:foot>
      </.result_summary>
  """
  attr :id, :string, required: true
  attr :tone, :string, values: @tone_values, required: true
  attr :badge, :string, required: true
  attr :title, :string, required: true
  attr :title_id, :string, default: nil, doc: "overrides the title's id, `<id>-title`"
  attr :rest, :global, doc: "for example `role=\"alert\"` on a result that reports a failure"
  slot :inner_block
  slot :extra, doc: "content between the paragraph and the metric row"

  slot :metric do
    attr :label, :string, required: true
    attr :value, :any, required: true
    attr :tone, :string
    attr :id, :string
    attr :value_id, :string
  end

  slot :foot

  def result_summary(assigns) do
    assigns =
      assigns
      |> assign(:t, Map.fetch!(@tones, assigns.tone))
      |> assign(:title_dom_id, assigns.title_id || "#{assigns.id}-title")

    ~H"""
    <section
      id={@id}
      aria-labelledby={@title_dom_id}
      class="overflow-hidden rounded-card border border-subtle bg-white"
      {@rest}
    >
      <div class={["border-l-4 px-5 py-6 sm:px-7", @t.bar]}>
        <.tone_badge tone={@tone}>{@badge}</.tone_badge>
        <h2
          id={@title_dom_id}
          class="mt-3 max-w-[40rem] font-display text-[26px] font-semibold leading-tight tracking-[-0.025em] text-strong sm:text-[30px]"
        >
          {@title}
        </h2>
        <p :if={@inner_block != []} class="mt-3 max-w-[44rem] text-[15px] leading-relaxed">
          {render_slot(@inner_block)}
        </p>
        {render_slot(@extra)}
      </div>
      <dl
        :if={@metric != []}
        class="grid grid-cols-3 divide-x divide-subtle border-t border-subtle"
      >
        <div :for={metric <- @metric} id={metric[:id]} class="min-w-0 px-3 py-4 sm:px-7">
          <dt class="flex items-center gap-2 text-[13px] font-semibold text-strong">
            <span class={["hidden sm:inline-flex", tone(metric[:tone]).text]}>
              <.icon name={tone(metric[:tone]).icon} class="size-4" />
            </span>
            {metric.label}
          </dt>
          <dd
            id={metric[:value_id]}
            class="mt-2 font-display text-[32px] font-semibold leading-none tracking-[-0.03em] text-strong tabular-nums sm:text-[36px]"
          >
            {metric.value}
          </dd>
          <dd class="mt-1.5 text-[13px] text-muted">{render_slot(metric)}</dd>
        </div>
      </dl>
      <div
        :if={@foot != []}
        class="border-t border-subtle bg-canvas px-5 py-3 text-[13px] text-muted sm:px-7"
      >
        {render_slot(@foot)}
      </div>
    </section>
    """
  end

  @doc """
  A card that groups related rows under a canvas header: an optional tone icon,
  the title with its count, one line on what the group means, and an optional
  action at the right, such as Expand all.

  ## Examples

      <.result_section id="problems" tone="error" title="Problems" count={3} lede="Fix these first.">
        <:action><button type="button">Expand all</button></:action>
        ...rows...
      </.result_section>
  """
  attr :id, :string, required: true
  attr :tone, :string, default: nil, doc: "one of the summary tones; nil draws no icon"
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :lede, :string, default: nil
  slot :action
  slot :inner_block, required: true

  def result_section(assigns) do
    assigns = assign(assigns, :t, assigns.tone && Map.fetch!(@tones, assigns.tone))

    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-title"}
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-b border-subtle bg-canvas px-5 py-4">
        <div class="min-w-0">
          <h2
            id={"#{@id}-title"}
            class="flex items-center gap-2 font-sans text-lg font-bold leading-snug tracking-[-0.01em] text-strong"
          >
            <span :if={@t} class={@t.text}><.icon name={@t.icon} class="size-5" /></span>
            {@title}
            <span :if={@count} class="font-normal text-muted tabular-nums">{@count}</span>
          </h2>
          <p :if={@lede} class="mt-0.5 text-[13px] text-muted">{@lede}</p>
        </div>
        {render_slot(@action)}
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  A closed-by-default card for the details behind a result: technical facts,
  run identifiers, a raw error. The summary is a 44px target.

  ## Examples

      <.result_details id="about-check" title="Details about this check">
        <dl>...</dl>
      </.result_details>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :open, :boolean, default: false
  slot :inner_block, required: true

  def result_details(assigns) do
    ~H"""
    <details id={@id} open={@open} class="group mt-6 rounded-card border border-subtle bg-white px-5">
      <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 py-2 text-sm font-semibold text-strong [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-4 text-muted transition-transform group-open:rotate-90"
        />
        {@title}
      </summary>
      <div class="pb-5">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  defp tone(nil), do: Map.fetch!(@tones, "neutral")
  defp tone(name), do: Map.fetch!(@tones, name)
end
