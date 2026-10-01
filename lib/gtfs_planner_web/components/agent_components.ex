defmodule GtfsPlannerWeb.AgentComponents do
  @moduledoc """
  The helper panel's presentation components.

  The panel is a function of its assigns. Every pack-specific string — the
  panel title, the intro sentence, the example requests and the scope line —
  arrives as data, so this module names no pack and carries no pack copy
  (INV-1). It reuses the shared button, callout, input and icon primitives
  instead of redeclaring them.

  Assistant text is interpolated with `{...}`, which is HEEx escaping: HTML
  tags and Markdown links or images in a model reply stay literal, and no
  element is ever built from model output (INV-4).

  ## Stream contract

  `agent_panel/1` consumes `entries` the way a LiveView stream is consumed: a
  comprehension over `{dom_id, entry}` tuples inside the `#agent-entries`
  container. The element for each item must carry that `dom_id`, so
  `agent_entry/1` takes its `id` from the caller rather than recomputing it.
  The LiveView that owns the conversation configures
  `stream_configure(:agent_entries, dom_id: &"agent-entry-\#{&1.id}")`.

  The first-conversation block is a non-stream item with its own DOM id. A
  `phx-update="stream"` container cannot remove such an item once painted, so
  `:only-child` hides the block as soon as an entry exists and
  `entries_empty?` keeps its content from going stale.

  ## Hook

  `.AgentPanel` owns the client behavior of one panel: it submits the composer
  on Cmd+Enter or Ctrl+Enter inside the composer textarea, keeps the transcript
  pinned to the newest entry when it was already near the bottom, and focuses
  the composer when the panel mounts. Shared focus events belong to the
  LiveView's persistent wrapper, not here.
  """

  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [button: 1, callout: 1, icon: 1, input: 1]

  @panel_statuses [
    :idle,
    :working,
    :ended,
    :forbidden,
    :unavailable,
    :limit,
    :allowance_exhausted
  ]

  @doc """
  Renders the helper panel: header, transcript, status, notice and composer.

  `status` is the conversation status. `entries` is the conversation stream.
  `entries_empty?` is true before the conversation has any entry. `notice`
  carries a panel-level refusal or advisory; `nil` renders no notice.
  """
  attr :id, :string, required: true, doc: "the panel's DOM id"
  attr :title, :string, required: true, doc: "the pack's panel title"
  attr :intro, :string, required: true, doc: "one sentence of scope for the first conversation"
  attr :examples, :list, required: true, doc: "example requests offered as buttons"

  attr :scope_line, :string,
    required: true,
    doc: "the screen and dataset this conversation belongs to"

  attr :status, :atom, required: true, values: @panel_statuses

  attr :entries, :any,
    required: true,
    doc: "the conversation stream, consumed as {dom_id, entry} tuples"

  attr :form, Phoenix.HTML.Form, required: true, doc: "the composer form"
  attr :notice, :string, default: nil, doc: "a panel-level refusal or advisory"
  attr :entries_empty?, :boolean, required: true, doc: "true before the conversation has an entry"

  def agent_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      phx-hook=".AgentPanel"
      aria-labelledby={"#{@id}-title"}
      class="flex min-w-0 flex-col rounded-box border border-base-300 bg-base-100 text-sm"
    >
      <header class="border-b border-base-300 px-4 py-3.5">
        <div class="flex items-center justify-between gap-3">
          <h2 id={"#{@id}-title"} class="text-lg font-semibold">{@title}</h2>
          <.button
            id="agent-panel-close"
            type="button"
            phx-click="agent_close"
            variant="quiet"
            size="sm"
            class="min-h-11 min-w-11"
            aria-label={"Close " <> @title}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.button>
        </div>
        <p class="mt-1.5 text-xs text-base-content/70">{@scope_line}</p>
      </header>

      <div class="flex items-center border-b border-base-300 px-2 py-1">
        <.button
          id="agent-new-conversation"
          type="button"
          phx-click="agent_new"
          variant="quiet"
          size="sm"
          disabled={@status == :working}
        >
          New conversation
        </.button>
      </div>

      <div
        id="agent-entries"
        phx-update="stream"
        class="min-h-0 flex-1 space-y-6 overflow-y-auto px-4 py-4"
      >
        <div id="agent-first-conversation" class="hidden only:block">
          <div :if={@entries_empty?}>
            <p class="text-xs font-bold text-base-content/70">{@title}</p>
            <p class="mt-2 text-base font-semibold">What needs to change?</p>
            <p class="mt-2.5 text-base-content/70">{@intro}</p>
            <div class="mt-5 grid gap-2.5">
              <.button
                :for={{example, index} <- Enum.with_index(@examples, 1)}
                id={"agent-example-#{index}"}
                type="button"
                phx-click="agent_example"
                phx-value-text={example}
                variant="secondary"
                class="min-h-11 w-full justify-start text-left font-normal"
              >
                {example}
              </.button>
            </div>
          </div>
        </div>

        <.agent_entry :for={{dom_id, entry} <- @entries} id={dom_id} entry={entry} title={@title} />
      </div>

      <p
        id="agent-status"
        role="status"
        aria-live="polite"
        class="px-4 py-1.5 text-xs text-base-content/70"
      >
        {status_text(@status)}
      </p>

      <.callout :if={@notice} id="agent-notice" kind="warning" title={@notice} class="mx-4 mb-3" />

      <.form
        for={@form}
        id="agent-composer"
        phx-submit="agent_send"
        class="border-t border-base-300 px-4 py-3.5"
      >
        <.input
          field={@form[:message]}
          type="textarea"
          id="agent-composer-input"
          label={"Message " <> @title}
          maxlength="2000"
          disabled={composer_locked?(@status)}
          class="textarea min-h-20 w-full text-sm"
        />
        <div class="flex flex-wrap items-center justify-between gap-3">
          <small id="agent-composer-hint" class="text-xs text-base-content/70">
            {composer_hint(@status)}
          </small>
          <div class="flex items-center gap-2">
            <.button
              :if={@status == :working}
              id="agent-stop"
              type="button"
              phx-click="agent_stop"
              variant="secondary"
              size="sm"
              class="min-h-11"
            >
              Stop request
            </.button>
            <.button
              id="agent-send"
              type="submit"
              variant="primary"
              size="sm"
              class="min-h-11"
              disabled={send_disabled?(@status)}
            >
              Send message
            </.button>
          </div>
        </div>
      </.form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".AgentPanel">
        export default {
          mounted() {
            this.transcript = this.el.querySelector("#agent-entries")
            this.nearBottom = true
            this.transcript.scrollTop = this.transcript.scrollHeight

            this.onScroll = () => {
              this.nearBottom =
                this.transcript.scrollHeight - this.transcript.scrollTop - this.transcript.clientHeight <= 48
            }
            this.transcript.addEventListener("scroll", this.onScroll)

            this.onKeydown = (event) => {
              if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey)) return
              if (event.target.id !== "agent-composer-input") return
              event.preventDefault()
              this.el.querySelector("#agent-composer").requestSubmit()
            }
            this.el.addEventListener("keydown", this.onKeydown)

            document.getElementById("agent-composer-input")?.focus()
          },
          updated() {
            if (this.nearBottom) this.transcript.scrollTop = this.transcript.scrollHeight
          }
        }
      </script>
    </aside>
    """
  end

  @doc """
  Renders one conversation entry.

  `id` is the stream's DOM id for the entry. User entries carry the person's
  text behind a left rule; assistant entries carry the pack title, a status
  badge, the reply text, the activity disclosure and, when the turn prepared a
  change, the prepared-change card.
  """
  attr :id, :string, required: true, doc: "the stream dom_id for this entry"
  attr :entry, :map, required: true, doc: "one conversation entry"
  attr :title, :string, required: true, doc: "the pack's panel title"

  def agent_entry(assigns) do
    badge = entry_badge(assigns.entry)
    prepared_badge = prepared_badge(assigns.entry)

    assigns =
      assigns
      |> assign(:badge_label, badge && elem(badge, 0))
      |> assign(:badge_tone, badge && elem(badge, 1))
      |> assign(:prepared_badge, prepared_badge)
      |> assign(:callout_kind, callout_kind(assigns.entry.status))

    ~H"""
    <article id={@id} class="text-sm">
      <div class="mb-2 flex items-center justify-between gap-2 text-xs font-bold text-base-content/70">
        <span>{if @entry.role == :user, do: "You", else: @title}</span>
        <span :if={@badge_label} class={["badge badge-sm", @badge_tone]}>
          {@badge_label}
        </span>
      </div>

      <div :if={@entry.role == :user} class="border-l-2 border-base-300 pl-3">
        <p class="whitespace-pre-line">{@entry.text}</p>
      </div>

      <div :if={@entry.role == :assistant}>
        <.callout :if={@callout_kind} kind={@callout_kind} title={@entry.text}>
          <.button
            :if={@entry.status == :failed}
            id={"agent-retry-#{@entry.id}"}
            type="button"
            phx-click="agent_retry"
            phx-value-entry={@entry.id}
            variant="secondary"
            size="sm"
            class="mt-1 min-h-11"
          >
            Retry request
          </.button>
        </.callout>

        <.agent_evidence_card
          :for={{evidence, index} <- Enum.with_index(@entry.evidence, 1)}
          id={"agent-evidence-#{@entry.id}-#{index}"}
          evidence={evidence}
        />

        <p
          :if={is_nil(@callout_kind) and @entry.text != ""}
          id={prose_id(@entry)}
          class={[
            "whitespace-pre-line",
            @entry.evidence != [] && "mt-3.5 text-base-content/80"
          ]}
        >
          <span
            :if={@entry.evidence != []}
            class="mb-0.5 block text-xs font-bold text-base-content/60"
          >
            Model reply
          </span>
          {@entry.text}
        </p>

        <details
          :if={@entry.activity != []}
          class="mt-3.5 border-l-2 border-info/40 pl-3 text-xs text-base-content/70"
        >
          <summary class="min-h-11 cursor-pointer py-1.5 font-semibold text-info">
            Checked {length(@entry.activity)} {activity_noun(@entry.activity)} · View activity
          </summary>
          <ol class="mt-1 list-decimal pl-5">
            <li :for={label <- @entry.activity} class="py-0.5">{label}</li>
          </ol>
        </details>

        <section
          :if={@entry.prepared}
          id={"agent-prepared-#{@entry.id}"}
          tabindex="-1"
          class="mt-4 overflow-hidden rounded-box border border-base-300"
        >
          <div class="bg-base-200 px-3.5 py-3.5">
            <span class={["badge badge-sm", elem(@prepared_badge, 1)]}>
              {elem(@prepared_badge, 0)}
            </span>
            <h3 class="mt-2 text-sm font-semibold">{@entry.prepared.summary.title}</h3>
            <p class="mt-1 text-xs text-base-content/70">{@entry.prepared.summary.detail}</p>
          </div>
          <ul class="px-3.5 py-1">
            <li
              :for={line <- @entry.prepared.summary.lines}
              class="border-b border-base-200 py-2.5 last:border-0"
            >
              {line}
            </li>
          </ul>
          <div :if={not @entry.applied?} class="border-t border-base-300 px-3.5 py-3">
            <.button
              id={"agent-review-prepared-#{@entry.id}"}
              type="button"
              phx-click="agent_review_prepared"
              phx-value-entry={@entry.id}
              size="sm"
              class="min-h-11 w-full"
            >
              Review prepared change
            </.button>
          </div>
        </section>
      </div>
    </article>
    """
  end

  @doc """
  Renders one server evidence card: the authoritative count, the server facts,
  completeness, the source it was read from and its resolved resource links.

  `evidence` is the panel's resolved value. Nothing here is built from model
  text, and a resource the panel did not link renders as plain text beside a
  visible reason rather than as a link that looks trustworthy (AC-4).
  """
  attr :id, :string, required: true, doc: "the card's DOM id"
  attr :evidence, :map, required: true, doc: "one resolved server evidence payload"

  def agent_evidence_card(assigns) do
    assigns =
      assigns
      |> assign(:facts, Map.get(assigns.evidence, :facts, []))
      |> assign(:resources, Map.get(assigns.evidence, :resources, []))
      |> assign(:exclusions, Map.get(assigns.evidence, :exclusions, []))
      |> assign(:complete?, assigns.evidence.completeness == :complete)

    ~H"""
    <section
      id={@id}
      data-evidence-kind={@evidence.kind}
      data-evidence-completeness={Atom.to_string(@evidence.completeness)}
      class="mt-4 overflow-hidden rounded-box border border-base-300"
    >
      <div class="bg-base-200 px-3.5 py-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span class="text-xs font-bold text-base-content/70">Server result</span>
          <span class={["badge badge-sm", if(@complete?, do: "badge-info", else: "badge-warning")]}>
            {if @complete?, do: "Complete", else: "Incomplete"}
          </span>
        </div>
        <h3 class="mt-1.5 text-sm font-semibold">{@evidence.title}</h3>
        <p class="mt-1 text-base font-semibold">
          {number(@evidence.total)} {@evidence.total_label}
        </p>
        <p
          :if={not @complete? and @evidence.completeness_reason}
          class="mt-1 text-xs text-base-content/70"
        >
          {@evidence.completeness_reason}
        </p>
      </div>

      <dl
        :if={@facts != []}
        class="grid grid-cols-[auto_1fr] items-baseline gap-x-3 gap-y-1.5 px-3.5 py-3 text-xs"
      >
        <%= for fact <- @facts do %>
          <dt class="text-base-content/70">{fact.label}</dt>
          <dd class="font-semibold">{fact.value}</dd>
        <% end %>
      </dl>

      <ul :if={@resources != []} class="border-t border-base-300 px-3.5 py-2 text-xs">
        <li
          :for={resource <- @resources}
          class="grid grid-cols-[auto_1fr] items-baseline gap-x-3 gap-y-0.5 py-2 text-xs"
        >
          <span class="text-base-content/70">{resource_kind(resource)}</span>
          <.link
            :if={resource[:link]}
            navigate={resource[:link]}
            class="link min-h-11 py-1 font-semibold underline"
          >
            {Map.get(resource, :label) || resource.id}
          </.link>
          <span :if={is_nil(resource[:link])} class="font-semibold">
            {Map.get(resource, :label) || resource.id}
          </span>
          <span :if={is_nil(resource[:link])} class="col-start-2 text-base-content/60">
            no link for this reference
          </span>
        </li>
      </ul>

      <ul
        :if={@exclusions != []}
        class="border-t border-base-300 px-3.5 py-2 text-xs text-base-content/70"
      >
        <li :for={exclusion <- @exclusions} class="py-0.5">Excluded · {exclusion}</li>
      </ul>

      <p class="border-t border-base-300 px-3.5 py-2 text-xs text-base-content/60">
        Source · {@evidence.source_ref} · digest {short_digest(@evidence.digest)}{revision(
          @evidence.source_revision
        )}
      </p>
    </section>
    """
  end

  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value), do: to_string(value)

  # The kind is a code-owned label, so it is shown as a word rather than a raw
  # schema token, without this module naming any pack's resource kinds.
  defp resource_kind(%{kind: kind}) when is_binary(kind), do: String.capitalize(kind)
  defp resource_kind(_resource), do: "resource"

  defp short_digest(digest) when is_binary(digest), do: binary_part(digest, 0, 12)
  defp short_digest(_digest), do: "unavailable"

  defp revision(nil), do: ""
  defp revision(revision), do: " · revision " <> revision

  defp prose_id(entry), do: "agent-prose-#{entry.id}"

  # Copy for the conversation status. The panel announces the same words a
  # reader sees, so the working, ended, forbidden, unavailable and exhausted
  # states are visible and audible from one place (AC-2, AC-4, AC-12, AC-18).
  defp status_text(:working), do: "Working…"
  defp status_text(:ended), do: "This conversation ended. Start a new conversation."
  defp status_text(:forbidden), do: "Your access changed. The helper stopped."

  defp status_text(:unavailable),
    do: "This route or service version is no longer available. The helper stopped."

  defp status_text(:limit), do: "This conversation reached its limit. Start a new conversation."

  defp status_text(:allowance_exhausted),
    do: "Daily assistant limit reached. It resets at 00:00 UTC."

  defp status_text(_idle), do: nil

  # The hint explains a composer that cannot send; otherwise it repeats the
  # one review rule that applies to every request.
  defp composer_hint(:ended), do: "This conversation ended. Start a new conversation."
  defp composer_hint(:limit), do: "This conversation reached its limit. Start a new conversation."

  defp composer_hint(:allowance_exhausted),
    do: "Try a new conversation after 00:00 UTC."

  defp composer_hint(_status), do: "Review changes before applying."

  defp send_disabled?(status),
    do: status in [:working, :ended, :forbidden, :unavailable, :limit, :allowance_exhausted]

  defp composer_locked?(status),
    do: status in [:ended, :forbidden, :unavailable, :limit, :allowance_exhausted]

  defp entry_badge(%{status: :working}), do: {"Working", nil}

  defp entry_badge(%{status: :done, prepared: %{}, applied?: true}),
    do: {"Applied", "badge-success"}

  defp entry_badge(%{status: :done, prepared: %{}}), do: {"Review ready", "badge-info"}
  defp entry_badge(%{status: :done}), do: nil
  defp entry_badge(%{status: :stopped}), do: {"Stopped", nil}
  defp entry_badge(%{status: :incomplete}), do: {"Incomplete", "badge-warning"}
  defp entry_badge(%{status: :allowance_exhausted}), do: {"Daily limit", "badge-warning"}
  defp entry_badge(%{status: :failed}), do: {"Unavailable", "badge-error"}
  defp entry_badge(%{status: :forbidden}), do: nil
  defp entry_badge(%{status: :unavailable}), do: nil

  defp prepared_badge(%{applied?: true}), do: {"Applied", "badge-success"}
  defp prepared_badge(_entry), do: {"Ready to review", "badge-info"}

  defp callout_kind(:stopped), do: "warning"
  defp callout_kind(:incomplete), do: "warning"
  defp callout_kind(:failed), do: "error"
  defp callout_kind(:allowance_exhausted), do: "warning"
  defp callout_kind(:forbidden), do: "error"
  defp callout_kind(:unavailable), do: "error"
  defp callout_kind(_status), do: nil

  defp activity_noun([_one]), do: "step"
  defp activity_noun(_many), do: "steps"
end
