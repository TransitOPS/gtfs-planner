defmodule GtfsPlannerWeb.PlannerComponents do
  @moduledoc """
  Components from the TransitOps application design system that pages migrated
  to it share: the in-place outcome message, the form error summary, the
  choice cards used for options that carry consequences, the first-use
  panel, the back link a child page carries above its heading, the scope line
  under its title, the scrolling body and footer that keep a drawer form's
  actions in view, a drawer's titled form section and unsaved-changes badge, the
  link an aside leads on with, the removable constraint chip and sortable column
  header a list workbench carries, and the check that keeps an imported address
  from becoming a link.

  They read the design-system tokens declared in `assets/css/app.css`
  (`text-strong`, `bg-soft`, `border-control`, `rounded-control`, and so on) and
  need no page scope. The form error summary is styled by the `.form-error-summary`
  rules, which a page opts into with its own id (`#account-page`,
  `#admin-users-page`, `#admin-organizations-page`) or the `ds-page` class.

  Called through an explicit import in each consumer; not part of the global
  `GtfsPlannerWeb.html_helpers/0` import set.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1, sort_glyph: 1]

  @message_tones %{
    "neutral" => {"bg-canvas text-default", "text-muted", "hero-information-circle", "status"},
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
  The line under a page's title that says what the page's data applies to: one
  version, or every version of the organization. It reads as part of the
  subtitle, so it goes inside the header's `:subtitle` slot, and the icon
  names the kind of scope.

  ## Examples

      <.header>
        Garages
        <:subtitle>
          Set where vehicles start and end the day.
          <.scope_line id="garages-scope" icon="hero-square-3-stack-3d">
            Applies to every service version at Acme Transit.
          </.scope_line>
        </:subtitle>
      </.header>
  """
  attr :id, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def scope_line(assigns) do
    ~H"""
    <span id={@id} class="mt-2 flex items-start gap-1.5">
      <.icon name={@icon} class="mt-0.5 size-4 shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </span>
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
  polite status. A warning that reports a state rather than a failure, such as
  "may be out of date", passes `role="status"` so it does not interrupt.

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
  attr :kind, :string, required: true, values: ~w(neutral info success warning error)
  attr :title, :string, required: true
  attr :icon, :string, default: nil, doc: "a hero icon name that replaces the kind's own mark"
  attr :class, :any, default: nil

  attr :role, :string,
    default: nil,
    doc:
      "overrides the announcement role, for a warning or error that is a polite status rather than an alert"

  attr :rest, :global
  slot :inner_block
  slot :action

  def message(assigns) do
    {tone, icon_tone, icon_name, kind_role} = Map.fetch!(@message_tones, assigns.kind)
    role = assigns.role || kind_role

    assigns =
      assigns
      |> assign(:tone, tone)
      |> assign(:icon_tone, icon_tone)
      |> assign(:icon_name, assigns.icon || icon_name)
      |> assign(:role, role)

    ~H"""
    <div
      role={@role}
      class={["flex items-start gap-3 rounded-control px-4 py-3", @tone, @class]}
      {@rest}
    >
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
  The scrolling part of a drawer step, above its persistent footer: the fields
  of a form, or the review a step asks the person to read.
  """
  slot :inner_block, required: true

  def drawer_scroll(assigns) do
    ~H"""
    <div class="grid flex-1 content-start gap-5 overflow-y-auto px-5 py-5 sm:px-6">
      {render_slot(@inner_block)}
    </div>
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
  A removable chip for one active list constraint (a search term or a filter).

  The chip shows what the person chose, not the query param, and its
  `aria-label` spells out the action. `kind` names the constraint ("Route") in
  front of its value when the value alone would be ambiguous. Clicking sends
  `remove_filter` with the chip's `key`.
  """
  attr :id, :string, required: true
  attr :key, :string, required: true, doc: "the query param this chip dismisses"
  attr :label, :string, required: true, doc: "the value the person chose"
  attr :kind, :string, default: nil
  attr :disabled, :boolean, default: false

  def constraint_chip(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="remove_filter"
      phx-value-key={@key}
      disabled={@disabled}
      class="inline-flex min-h-11 items-center gap-1.5 rounded-badge border border-subtle bg-white pl-2.5 pr-2 text-[13px] text-strong hover:bg-canvas disabled:cursor-not-allowed disabled:hover:bg-white"
      aria-label={"Remove filter " <> Enum.join(Enum.reject([@kind, @label], &is_nil/1), " ")}
    >
      <span :if={@kind} class="text-muted">{@kind}</span>
      <span class="font-[650]">{@label}</span>
      <.icon name="hero-x-mark" class="size-3.5 text-muted" />
    </button>
    """
  end

  @doc """
  A sortable column header for a workbench table (sticky canvas header, 44px
  target), without the shared `<.table>` component's daisyUI chrome.

  Clicking sends `sort` with the column's `sort_key`. `sort_key` must be an
  existing atom name; `sort_by` and `sort_dir` are the table's current sort.
  """
  attr :label, :string, required: true
  attr :sort_key, :string, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""

  def sort_header(assigns) do
    state = column_sort_state(assigns.sort_by, assigns.sort_dir, assigns.sort_key)

    assigns =
      assigns
      |> assign(:aria_sort, aria_sort_value(state))
      |> assign(:indicator, sort_indicator(state))

    ~H"""
    <th
      scope="col"
      aria-sort={@aria_sort}
      class={[
        "sticky top-0 z-10 border-b border-subtle bg-canvas text-[13px] font-[650] text-default",
        @class
      ]}
    >
      <button
        type="button"
        phx-click="sort"
        phx-value-key={@sort_key}
        disabled={@disabled}
        class="inline-flex min-h-11 items-center gap-1.5 hover:text-strong hover:underline disabled:cursor-not-allowed disabled:hover:no-underline"
      >
        {@label}<span aria-hidden="true">{@indicator}</span>
      </button>
    </th>
    """
  end

  defp column_sort_state(sort_by, sort_dir, sort_key) do
    if String.to_existing_atom(sort_key) == sort_by, do: Atom.to_string(sort_dir), else: "none"
  end

  defp aria_sort_value("asc"), do: "ascending"
  defp aria_sort_value("desc"), do: "descending"
  defp aria_sort_value(_other), do: "none"

  # An unsorted column gets the neutral double arrow, because a single arrow
  # would imply a sort that is not there.
  defp sort_indicator(state), do: sort_glyph(state)

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
