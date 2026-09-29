defmodule GtfsPlannerWeb.PlannerComponents do
  @moduledoc """
  Components from the TransitOps application design system that pages migrated
  to it share: the in-place outcome message, the form error summary, the
  choice cards used for options that carry consequences, the first-use
  panel, the back link a child page carries above its heading, the
  footer that keeps a drawer form's actions in view, a drawer's titled form
  section and unsaved-changes badge, the link an aside leads on with, and the
  check that keeps an imported address from becoming a link.

  They read the design-system tokens declared in `assets/css/app.css`
  (`text-strong`, `bg-soft`, `border-control`, `rounded-control`, and so on) and
  need no page scope. The form error summary is styled by the `.form-error-summary`
  rules, which a page opts into with its own id (`#account-page`,
  `#admin-users-page`, `#admin-organizations-page`) or the `ds-page` class.

  Called through an explicit import in each consumer; not part of the global
  `GtfsPlannerWeb.html_helpers/0` import set.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  @message_tones %{
    "info" => {"bg-soft text-cyan-800", "text-cyan-700", "hero-information-circle", "status"},
    "success" => {"bg-soft text-cyan-800", "text-cyan-700", "hero-check-circle", "status"},
    "warning" => {"bg-warning-bg text-warning-fg", nil, "hero-exclamation-triangle", "alert"},
    "error" => {"bg-error-bg text-error-fg", nil, "hero-exclamation-triangle", "alert"}
  }

  @doc """
  The way back from a child page to the page that lists it, above the heading.

  A child page names its parent in the link ("Settings", "Organizations") instead
  of carrying the parent's tab bar, because the parent's list is already the
  navigation between siblings. The chevron and 44px target follow the design
  system's entity header. Focus draws its own outline, so the link needs no page
  scope.

  ## Examples

      <.back_link id="back-to-settings" navigate={~p"/gtfs/\#{@version.id}/settings"}>
        Settings
      </.back_link>
  """
  attr :id, :string, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def back_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "-ml-2 inline-flex min-h-11 items-center gap-1 rounded-control px-2 text-sm font-[650] text-muted no-underline",
        "hover:bg-canvas hover:text-strong",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      ]}
    >
      <.icon name="hero-chevron-left" class="size-4" /> {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  A link in a page's aside that leads on from what the aside says: an action
  colour, an arrow and a 44px target.

  ## Examples

      <.aside_link id="go-to-export" navigate={~p"/gtfs/\#{@version.id}/export"}>
        Go to export
      </.aside_link>
  """
  attr :id, :string, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def aside_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "mt-2 inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action no-underline",
        "hover:text-action-hover hover:underline"
      ]}
    >
      {render_slot(@inner_block)} <.icon name="hero-arrow-right" class="size-4" />
    </.link>
    """
  end

  @doc """
  Reports an outcome in place, next to the thing that changed.

  The title says what happened, in one sentence. The body, when given, says what
  happens next or what to do. Success and info use the design system's default
  cyan message so they match the rest of the application (success with a check,
  info with an information mark); green stays reserved for the Active status.
  Warnings and errors are announced (`role="alert"`), success and info are a
  polite status.

  The `:action` slot holds the one control that resolves the message. It sits at
  the right of the text from the `sm` breakpoint up and under it below that, so
  the fix is beside the problem it names.

  ## Examples

      <.message kind="success" title="Invitation sent to sam@agency.org.">
        The link in the email works for 7 days.
      </.message>

      <.message id="save-error" kind="error" title="Nothing was saved." />

      <.message kind="warning" title="Agencies use different timezones">
        Choose one timezone for this version.
        <:action><.button phx-click="resolve">Resolve timezones</.button></:action>
      </.message>
  """
  attr :kind, :string, required: true, values: ~w(info success warning error)
  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block
  slot :action

  def message(assigns) do
    {tone, icon_tone, icon_name, role} = Map.fetch!(@message_tones, assigns.kind)

    assigns =
      assigns
      |> assign(:tone, tone)
      |> assign(:icon_tone, icon_tone)
      |> assign(:icon_name, icon_name)
      |> assign(:role, role)

    ~H"""
    <div role={@role} class={["flex items-start gap-3 rounded-control px-4 py-3", @tone]} {@rest}>
      <.icon name={@icon_name} class={["mt-0.5 size-5 shrink-0", @icon_tone]} />
      <div class={[
        "min-w-0",
        @action != [] && "flex-1 sm:flex sm:items-center sm:justify-between sm:gap-6"
      ]}>
        <div class="min-w-0">
          <p class="text-sm font-bold">{@title}</p>
          <div :if={@inner_block != []} class="mt-0.5 text-sm">{render_slot(@inner_block)}</div>
        </div>
        <div :if={@action != []} class="mt-3 shrink-0 sm:mt-0">{render_slot(@action)}</div>
      </div>
    </div>
    """
  end

  @doc """
  The landing place after a rejected submit: every problem at once, each linking
  to the field it names. Renders nothing when there are no failures, so live
  validation, which is not a rejection, never produces one.

  `failures` is a list of `%{href: "#field-id", msg: "Sentence."}`. The panel takes
  focus by its id (`tabindex="-1"`) when the caller pushes focus to it. It leaves
  space below itself; a caller that already spaces its children, such as a drawer
  form laid out as a grid, passes `class=""`.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :failures, :list, required: true
  attr :class, :string, default: "mb-5"

  def form_error_summary(%{failures: []} = assigns) do
    ~H"""
    """
  end

  def form_error_summary(assigns) do
    ~H"""
    <div id={@id} role="alert" tabindex="-1" class={["form-error-summary", @class]}>
      <strong class="font-bold">{@title}</strong>
      <a :for={failure <- @failures} href={failure.href}>{failure.msg}</a>
    </div>
    """
  end

  @doc """
  What a view says when nothing is in it yet: what belongs here, and the one next
  step. The action goes in the `:action` slot, so the view keeps a single primary.

  ## Examples

      <.first_use id="members-empty" title="No members yet" icon="hero-users">
        Invite someone to give them access to Acme Transit.
        <:action><.button patch={~p"/invite"}>Invite member</.button></:action>
      </.first_use>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: nil, doc: "a hero icon name shown above the title"
  slot :inner_block, required: true
  slot :action

  def first_use(assigns) do
    ~H"""
    <div id={@id} class="rounded-card border border-subtle bg-white px-5 py-14 sm:px-10">
      <div class="mx-auto max-w-[520px] text-center">
        <span
          :if={@icon}
          class="mx-auto mb-4 grid size-12 place-items-center rounded-control bg-soft text-cyan-700"
        >
          <.icon name={@icon} class="size-6" />
        </span>
        <h2 class="font-display text-[24px] font-semibold tracking-[-0.025em] text-strong">
          {@title}
        </h2>
        <p class="mt-2 text-sm text-muted">{render_slot(@inner_block)}</p>
        <div :if={@action != []} class="mt-6">{render_slot(@action)}</div>
      </div>
    </div>
    """
  end

  @doc """
  A group of options where each choice carries a consequence.

  Each option is a whole-card target with its label and a one-line description, so
  the person reads what a choice allows before choosing it. The group is one
  `fieldset`: `aria-invalid` and the error live on it, and an invalid group outlines
  its cards. Input ids are `<id>-<value>`.

  `type="checkbox"` (the default) lets the person choose any number and expects a
  `name` ending in `[]`. `type="radio"` lets them choose one; `selected` then holds
  the one chosen value.

  ## Examples

      <.choice_cards
        id="invite-roles"
        name="invite[roles][]"
        label="Access level"
        help="Choose at least one."
        options={[
          %{value: "editor", label: "Editor", description: "Edits routes and stops."}
        ]}
        selected={@selected_roles}
        error={@roles_error}
      />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :type, :string, values: ~w(checkbox radio), default: "checkbox"
  attr :label, :string, required: true
  attr :options, :list, required: true, doc: "maps with :value, :label and :description"
  attr :selected, :list, default: []
  attr :help, :string, default: nil
  attr :error, :string, default: nil

  def choice_cards(assigns) do
    invalid? = assigns.error not in [nil, ""]
    help_id = if assigns.help, do: "#{assigns.id}-help"
    error_id = if invalid?, do: "#{assigns.id}-error"

    assigns =
      assigns
      |> assign(:invalid?, invalid?)
      |> assign(:help_id, help_id)
      |> assign(:error_id, error_id)
      |> assign(:describedby, Enum.reject([help_id, error_id], &is_nil/1) |> Enum.join(" "))

    ~H"""
    <fieldset
      id={@id}
      class="min-w-0"
      aria-describedby={if(@describedby != "", do: @describedby)}
      aria-invalid={to_string(@invalid?)}
    >
      <legend class="text-[13px] font-[650] text-default">{@label}</legend>
      <p :if={@help} id={@help_id} class="mt-0.5 text-[13px] text-muted">{@help}</p>
      <div class="mt-3 grid gap-2">
        <label
          :for={option <- @options}
          class={[
            "flex cursor-pointer items-start gap-3 rounded-control border bg-white px-4 py-3",
            "has-[:checked]:border-action has-[:checked]:bg-selection",
            "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus",
            if(@invalid?, do: "border-error-line", else: "border-control")
          ]}
        >
          <input
            type={@type}
            id={"#{@id}-#{option.value}"}
            name={@name}
            value={option.value}
            checked={option.value in @selected}
            class="mt-0.5 size-5 shrink-0 accent-action focus-visible:outline-0"
          />
          <span class="min-w-0">
            <span class="block text-sm font-bold text-strong">{option.label}</span>
            <span class="mt-0.5 block text-[13px] leading-snug text-muted">
              {option.description}
            </span>
          </span>
        </label>
      </div>
      <p
        :if={@invalid?}
        id={@error_id}
        class="mt-2 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
      >
        <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
        <span>{@error}</span>
      </p>
    </fieldset>
    """
  end

  @doc """
  A drawer form's actions, kept in view under the scrolling fields: Cancel, then
  the one primary at the right. A control that must sit at the left edge, such as
  Delete, takes `mr-auto`; a note that explains an unavailable action takes
  `basis-full` to sit on the row above the buttons.
  """
  slot :inner_block, required: true

  def drawer_footer(assigns) do
    ~H"""
    <footer class="flex flex-wrap items-center justify-end gap-3 border-t border-subtle bg-white px-5 py-4 sm:px-6">
      {render_slot(@inner_block)}
    </footer>
    """
  end

  @doc """
  One titled section of a drawer form: a legend over its fields, divided from the
  section above by a hairline. The divider lives on a wrapper because a fieldset
  border would run through the legend.
  """
  attr :title, :string, required: true
  attr :first?, :boolean, default: false, doc: "the first section has no divider above it"
  slot :inner_block, required: true

  def form_section(assigns) do
    ~H"""
    <div class={["min-w-0", !@first? && "border-t border-subtle pt-6"]}>
      <fieldset class="min-w-0">
        <legend class="mb-4 text-base font-bold text-strong">{@title}</legend>
        <div class="grid gap-5">{render_slot(@inner_block)}</div>
      </fieldset>
    </div>
    """
  end

  @doc """
  The drawer header's mark for a draft that differs from what is saved. It names
  the state in words, so the warning is readable without its colour.
  """
  attr :id, :string, required: true

  def unsaved_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class="inline-flex items-center gap-1.5 whitespace-nowrap rounded-badge bg-warning-bg px-2 py-1 text-[13px] font-[650] leading-none text-warning-fg"
    >
      <.icon name="hero-exclamation-triangle" class="size-4" /> Unsaved changes
    </span>
    """
  end

  @doc """
  The address a stored web or email value may open, or `nil`.

  A stored value is arbitrary text when it came from an import, so a page links
  it only when the browser can follow it safely: `:web` needs a plain http(s)
  URL and `:email` a plain address; anything else stays text and never becomes an
  `href`.
  """
  def safe_href(:web, value) when is_binary(value) do
    if String.match?(value, ~r{\Ahttps?://\S+\z}i), do: value
  end

  def safe_href(:email, value) when is_binary(value) do
    if String.match?(value, ~r/\A[^\s@]+@[^\s@]+\z/), do: "mailto:" <> value
  end

  def safe_href(_kind, _value), do: nil
end
