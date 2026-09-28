defmodule GtfsPlannerWeb.Gtfs.RouteFormComponents do
  @moduledoc """
  Shared route form controls for the create drawer and Route › Details.

  `identity_fields/1` is the "Name and appearance" grammar both surfaces use:
  the route number, the route name, the modes this version already uses as
  radio chips with an "Other mode" select for the accepted modes that are left,
  and the version's agency presented as no agency, the only agency, or a
  select. The create drawer (step 21) and the Details workspace (step 22)
  render the same controls from the same route editor read, so the two
  surfaces cannot drift into different field grammars.

  The component is stateless. Every value comes from the caller's
  `to_form/2` changeset plus the read model's `mode_counts` and
  `agency_options`, and `prefix` namespaces the control ids so both forms can
  be rendered on one page without duplicate ids. Nothing here writes, reads or
  caches: drafts stay in the LiveView, and a client-side preview never
  establishes a persisted value (INV-6).

  The controls are written directly rather than through `CoreComponents.input/1`
  because the reference composes them that way and the shared component cannot
  honour it through the shared input: the two name controls carry one joint
  "at least one name" error that has to span both columns instead of wrapping
  inside the 132px route-number column, and both selects carry a chevron that
  has to sit inside the control's own box. `translate_error/1` and `icon/1`
  are still the shared components, and the class recipes are the same TransitOps
  ones `Gtfs.RoutesLive` already uses for these controls.
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.Route

  # The reference offers the three modes this version uses most as one-click
  # chips and keeps every other accepted mode behind "Other mode…".
  @chip_modes 3

  # The reference's control, label, help and chip treatments, written with this
  # application's TransitOps tokens. They are functions rather than module
  # attributes because a `~H` template reads an attribute without marking it
  # used, which fails `--warnings-as-errors`.
  defp control_class do
    "h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong placeholder:text-muted aria-[invalid=true]:border-2 aria-[invalid=true]:border-error-fg disabled:bg-canvas disabled:text-muted"
  end

  defp select_class do
    "h-11 w-full appearance-none rounded-control border border-control bg-white pl-3 pr-9 text-sm text-strong aria-[invalid=true]:border-2 aria-[invalid=true]:border-error-fg disabled:bg-canvas disabled:text-muted"
  end

  # A mode chosen from "Other mode…" reads as chosen the same way a chip does,
  # so the control the user actually used is never the one that looks idle.
  defp other_mode_class(other_on?) do
    [
      select_class(),
      other_on? && "border-2 border-action bg-selection font-[650] text-action"
    ]
  end

  defp label_class, do: "text-[13px] font-[650] text-default"

  defp help_class, do: "mt-1.5 text-[13px] text-muted"

  defp chip_class do
    "relative inline-flex min-h-11 cursor-pointer items-center rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas has-[:checked]:border-2 has-[:checked]:border-action has-[:checked]:bg-selection has-[:checked]:px-[15px] has-[:checked]:text-action has-[:focus-visible]:outline has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
  end

  # The one shape every field's failure message takes: the reference's inline
  # error line, announced from the control through `aria-describedby`.
  attr :id, :string, required: true
  attr :messages, :list, required: true

  defp error_line(assigns) do
    ~H"""
    <p
      :if={@messages != []}
      id={@id}
      class="mt-1.5 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
    >
      <.icon name="hero-exclamation-circle" class="mt-px size-3.5 shrink-0" />
      {Enum.join(@messages, " ")}
    </p>
    """
  end

  @doc """
  Renders the route number, route name, mode and agency fields.

  Both name inputs stay individually optional: R1 accepts either name, so the
  "at least one name" rule belongs to the server changeset and surfaces here as
  one shared error after blur validation, not as a browser `required`.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :prefix, :string, required: true, doc: "namespace for the stable control ids"
  attr :mode_counts, :list, default: [], doc: "scoped mode counts, most used first"
  attr :agency_options, :list, default: [], doc: "scoped agency options for this version"

  def identity_fields(assigns) do
    assigns = assign(assigns, :selected_mode, to_string(assigns.form[:route_type].value || ""))
    assigns = assign(assigns, :selected_agency, to_string(assigns.form[:agency_id].value || ""))
    assigns = assign(assigns, :chip_modes, chip_modes(assigns.mode_counts))
    assigns = assign(assigns, :other_modes, other_modes(assigns.chip_modes))

    assigns =
      assign(assigns, :other_mode?, assigns.selected_mode not in chip_mode_strings(assigns))

    assigns = assign(assigns, :name_errors, shared_name_errors(assigns.form))
    assigns = assign(assigns, :mode_errors, field_errors(assigns.form[:route_type]))
    assigns = assign(assigns, :agency_errors, field_errors(assigns.form[:agency_id]))

    ~H"""
    <div id={"#{@prefix}-identity"} class="grid gap-6">
      <div class="min-w-0">
        <div class="grid gap-3 sm:grid-cols-[132px_minmax(0,1fr)]">
          <div class="grid content-start gap-1.5">
            <label for={"#{@prefix}-short"} class={label_class()}>Route number</label>
            <input
              type="text"
              id={"#{@prefix}-short"}
              name={@form[:route_short_name].name}
              value={@form[:route_short_name].value}
              aria-invalid={to_string(@name_errors != [])}
              aria-describedby={described_by(@name_errors, "#{@prefix}-names-error")}
              phx-debounce="blur"
              autocomplete="off"
              spellcheck="false"
              class={[control_class(), "tabular-nums"]}
            />
          </div>
          <div class="grid content-start gap-1.5">
            <label for={"#{@prefix}-long"} class={label_class()}>Route name</label>
            <input
              type="text"
              id={"#{@prefix}-long"}
              name={@form[:route_long_name].name}
              value={@form[:route_long_name].value}
              aria-invalid={to_string(@name_errors != [])}
              aria-describedby={described_by(@name_errors, "#{@prefix}-names-error")}
              phx-debounce="blur"
              autocomplete="off"
              spellcheck="false"
              placeholder="For example, Downtown – Airport"
              class={control_class()}
            />
          </div>
        </div>
        <.error_line id={"#{@prefix}-names-error"} messages={@name_errors} />
        <p class={help_class()}>
          Enter a number, a name, or both. The number goes on the badge and signs; the name
          usually gives the ends of the line.
        </p>
      </div>

      <fieldset id={"#{@prefix}-mode-group"} class="min-w-0">
        <legend class={label_class()}>Mode</legend>
        <%!-- The select is written first in the DOM and ordered last visually, so
              the chips stay the last successful control for the shared
              `route[route_type]` name the reference splits across two fields.
              Browsers let the later successful control win, so a checked chip
              always takes effect; unchecked chips submit nothing, so an
              "Other mode…" choice still wins over them. The one cost is that
              keyboard order follows the DOM rather than the chips' visual
              position; the fieldset and its legend keep the group named
              either way. --%>
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <div class="relative order-last w-[190px]">
            <label for={"#{@prefix}-mode-other"} class="sr-only">Other mode</label>
            <select
              id={"#{@prefix}-mode-other"}
              name={@form[:route_type].name}
              aria-invalid={to_string(@mode_errors != [])}
              aria-describedby={described_by(@mode_errors, "#{@prefix}-mode-error")}
              class={other_mode_class(@other_mode?)}
            >
              <option value="">Other mode…</option>
              {Phoenix.HTML.Form.options_for_select(@other_modes, @selected_mode)}
            </select>
            <.chevron />
          </div>
          <label :for={value <- @chip_modes} class={chip_class()}>
            <input
              type="radio"
              id={"#{@prefix}-mode-#{value}"}
              name={@form[:route_type].name}
              value={value}
              checked={@selected_mode == to_string(value)}
              class="sr-only"
            />{Route.route_type_label(value)}
          </label>
        </div>
        <.error_line id={"#{@prefix}-mode-error"} messages={@mode_errors} />
        <p :if={@chip_modes != []} class={help_class()}>
          Modes already used in this version come first.
        </p>
      </fieldset>

      <div class="min-w-0">
        <%!-- Zero, one and many agencies are three different controls, and each
              one keeps the visible "Agency" label so the field never reads as
              missing. --%>
        <p
          :if={length(@agency_options) < 2}
          id={"#{@prefix}-agency-label"}
          class={label_class()}
        >
          Agency
        </p>

        <p :if={@agency_options == []} class={help_class()}>
          This version has no agency yet. Add the agency that operates this route in Settings ›
          Agencies.
        </p>

        <div
          :if={length(@agency_options) == 1}
          id={"#{@prefix}-agency-readonly"}
          class="grid gap-1.5"
        >
          <p id={"#{@prefix}-agency-name"} class="text-sm text-strong">
            {hd(@agency_options).agency_name}
          </p>
          <%!-- The version's only agency is the value this version can accept,
                so the read-only control submits it; the command rechecks it
                against the version's agencies under seam `S-1`. --%>
          <input
            type="hidden"
            id={"#{@prefix}-agency"}
            name={@form[:agency_id].name}
            value={hd(@agency_options).agency_id}
          />
          <p class={help_class()}>{one_agency_help(@selected_agency)}</p>
        </div>

        <div :if={length(@agency_options) > 1} class="grid gap-1.5">
          <label for={"#{@prefix}-agency"} class={label_class()}>Agency</label>
          <div class="relative max-w-[320px]">
            <select
              id={"#{@prefix}-agency"}
              name={@form[:agency_id].name}
              aria-invalid={to_string(@agency_errors != [])}
              aria-describedby={
                described_by(@agency_errors, "#{@prefix}-agency-error", "#{@prefix}-agency-help")
              }
              class={select_class()}
            >
              <option value="">Select an agency</option>
              {Phoenix.HTML.Form.options_for_select(
                Enum.map(@agency_options, &{&1.agency_name, &1.agency_id}),
                @selected_agency
              )}
            </select>
            <.chevron />
          </div>
          <.error_line id={"#{@prefix}-agency-error"} messages={@agency_errors} />
          <p id={"#{@prefix}-agency-help"} class={help_class()}>
            Required: this version has {length(@agency_options)} agencies.
          </p>
        </div>
      </div>
    </div>
    """
  end

  # The chevron the reference draws with an inline `use` reference. It is
  # absolutely positioned over the select's own `h-11` box rather than over the
  # surrounding field, so it stays centred however tall the field grows.
  attr :rest, :global

  defp chevron(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class="pointer-events-none absolute inset-x-0 top-0 flex h-11 items-center justify-end pr-2.5"
      {@rest}
    >
      <.icon name="hero-chevron-down" class="size-4 text-muted" />
    </span>
    """
  end

  # The most used modes in this version, capped at the reference's chip row.
  # `mode_counts` arrives ordered by descending count then ascending mode, and
  # is the only source: a version with no routes yet gets no chips and reaches
  # every accepted mode through "Other mode…".
  defp chip_modes(mode_counts) do
    mode_counts
    |> Enum.map(& &1.route_type)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@chip_modes)
  end

  defp chip_mode_strings(assigns) do
    Enum.map(["" | assigns.chip_modes], &to_string/1)
  end

  # R1's rule is about the pair, not either field, so the shared error is read
  # off the route-number field the changeset already owns and shown once across
  # both columns. Reading the long-name field as well keeps the message whole if
  # a later validation move puts the error there instead.
  defp shared_name_errors(form) do
    short = field_errors(form[:route_short_name])
    if short == [], do: field_errors(form[:route_long_name]), else: short
  end

  # `CoreComponents.input/1` only surfaces a field's errors once the form has
  # actually used that input, so a draft nobody typed into never shows a stale
  # message. The shared controls keep the same rule.
  defp field_errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, &translate_error/1)
    else
      []
    end
  end

  # A control names the descriptions it actually renders: the error line only
  # while it has errors, and standing help text whenever it is present.
  defp described_by(messages, error_id, help_id \\ nil) do
    [if(messages == [], do: nil, else: error_id), help_id]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  # An unassigned route in a one-agency version is stated as an assignment the
  # save will make, so the read-only control never implies a stored value the
  # route does not have yet.
  defp one_agency_help(""),
    do: "The only agency in this version. Saving assigns it to this route."

  defp one_agency_help(_selected),
    do: "The only agency in this version, so every route uses it."

  # Every accepted mode the chips do not already offer, so no accepted mode is
  # unreachable from the form.
  defp other_modes(chip_modes) do
    Route.route_type_options()
    |> Enum.reject(fn {_label, value} -> value in chip_modes end)
  end
end
