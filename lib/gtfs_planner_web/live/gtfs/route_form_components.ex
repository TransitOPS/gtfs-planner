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

  `rider_fields/1` and `additional_details/1` are the Details-side remainder of
  the reference's field order: rider information (description, web page) and the
  collapsed Additional details disclosure (display order, boarding defaults, fare
  network and the read-only route ID, with its values repeated in the summary so
  the closed disclosure still states them). The create drawer does not render
  them, so they are mounted by `RouteDetailLive` alone.

  `color_fields/1` is the shared "Route color / Text color" pair: the picker
  and hex fields, the Automatic/Custom mode chips, and the contrast readout
  with its one-click automatic fix. It renders the whole readout server-side
  from the same `RouteIdentity` arithmetic the app's badge uses, and
  `assets/js/route_details_editor.js` keeps it live while the operator types,
  so the two surfaces agree on what a draft will look like without either
  surface asking the server what it already knows (R7, C-2, INV-6).

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
  alias GtfsPlannerWeb.Components.RouteIdentity

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

  # The reference's non-blocking advisory: a left-bordered warning note that
  # explains itself and never blocks a save (AC-20). An error keeps its own red
  # line; a warning is a different color and a different element, so an
  # advisory can never read as a validation failure.
  attr :id, :string, required: true
  attr :class, :any, default: nil, doc: "extra spacing classes merged into the box"
  attr :rest, :global
  slot :inner_block, required: true

  defp field_warning(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex items-start gap-2 rounded-control border-l-[3px] border-warning-line bg-warning-bg px-3 py-2 text-[13px] text-warning-fg",
        @class
      ]}
      {@rest}
    >
      <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
      <div class="min-w-0">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  # The reference caps a route number's usefulness at 12 characters: trip
  # planners may cut longer numbers off. Code points, not bytes, so a number
  # with combining or wide characters is measured the way riders see it.
  @max_number_code_points 12

  @doc """
  Computes the advisory field warnings one form draft earns (AC-20, R7).

  Input is one map:

    * `:draft` — the draft the warnings describe, with the editor fields
      (`route_short_name`, `route_color`, `route_url`, `agency_id`,
      `continuous_pickup`, `continuous_drop_off`); a changeset's applied
      changes are the caller's own draft projection
    * `:changed` — `:all` when every draft value is new (creation), or the
      changed editor fields; only a changed field earns its warning, so an
      untouched imported value never produces one
    * `:current_uuid` — the route UUID a Details draft edits; its own saved
      row is excluded from the candidate comparison
    * `:candidates` — the scoped saved routes projected to UUID, natural ID,
      short name and color (`Routes.route_editor/3`)
    * `:agencies` — the version's agency options with their home URLs
    * `:geometry` — `%{patterns_missing: n}` from the route map projection,
      `:unavailable` when that read failed, or `nil`; unknown geometry is
      never reported as missing

  Returns `%{short: nil | ..., similar: nil | ..., url: nil | ..., boarding:
  nil | ...}`. Every entry renders as an advisory and none of them blocks a
  save. Invalid input is not a warning: an unusable color or URL earns nothing
  here and stays the changeset's error.
  """
  def field_warnings(input \\ %{}) do
    draft = Map.get(input, :draft) || %{}
    changed = Map.get(input, :changed, :all)
    current_uuid = Map.get(input, :current_uuid)
    candidates = candidates_excluding(Map.get(input, :candidates) || [], current_uuid)

    %{
      short: short_warning(draft, changed, candidates),
      similar: similar_warning(draft, changed, candidates),
      url: url_warning(draft, changed, Map.get(input, :agencies) || []),
      boarding: boarding_warning(draft, changed, Map.get(input, :geometry))
    }
  end

  defp candidates_excluding(candidates, nil), do: candidates

  defp candidates_excluding(candidates, current_uuid) do
    Enum.reject(candidates, fn candidate -> candidate[:id] == current_uuid end)
  end

  # Duplicate takes precedence over the length note, the way the reference
  # orders them: a trimmed, case-folded match on another route's number is the
  # more concrete confusion.
  defp short_warning(draft, changed, candidates) do
    if field_changed?(:route_short_name, changed) do
      number = normalized_number(Map.get(draft, :route_short_name))

      cond do
        is_nil(number) ->
          nil

        duplicate = Enum.find(candidates, &(normalized_number(&1[:route_short_name]) == number)) ->
          %{kind: :duplicate, route: duplicate}

        String.length(number) > @max_number_code_points ->
          %{kind: :too_long}

        true ->
          nil
      end
    else
      nil
    end
  end

  defp normalized_number(nil), do: nil

  defp normalized_number(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      number -> String.downcase(number)
    end
  end

  defp similar_warning(draft, changed, candidates) do
    if field_changed?(:route_color, changed) do
      case RouteIdentity.similar_color(Map.get(draft, :route_color), candidates) do
        %{route: route} -> %{route: route}
        nil -> nil
      end
    else
      nil
    end
  end

  # The warning names the agency the draft's page actually belongs to: the
  # selected agency, or the version's only agency when the draft does not name
  # one yet. Trailing slashes and letter case do not make a home page a route
  # page.
  defp url_warning(draft, changed, agencies) do
    if field_changed?(:route_url, changed) or field_changed?(:agency_id, changed) do
      url = normalized_url(Map.get(draft, :route_url))
      agency = effective_agency(Map.get(draft, :agency_id), agencies)

      if url && agency && agency[:agency_url] && normalized_url(agency[:agency_url]) == url do
        %{agency: agency}
      else
        nil
      end
    else
      nil
    end
  end

  defp effective_agency(agency_id, agencies) when is_binary(agency_id) and agency_id != "" do
    Enum.find(agencies, &(&1[:agency_id] == agency_id))
  end

  defp effective_agency(_agency_id, [agency]), do: agency
  defp effective_agency(_agency_id, _agencies), do: nil

  defp normalized_url(nil), do: nil

  defp normalized_url(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      url -> url |> String.replace_trailing("/", "") |> String.downcase()
    end
  end

  # Continuous boarding means little where a path between stops is known to be
  # absent: the map projection counts patterns with `:missing` sections, and
  # unavailable or absent geometry reports nothing rather than fabricating a
  # missing path from unknown data.
  defp boarding_warning(_draft, _changed, nil), do: nil
  defp boarding_warning(_draft, _changed, :unavailable), do: nil

  defp boarding_warning(draft, changed, %{patterns_missing: patterns_missing})
       when is_integer(patterns_missing) and patterns_missing > 0 do
    if field_changed?(:continuous_pickup, changed) or
         field_changed?(:continuous_drop_off, changed) do
      boarding_enabled? =
        Map.get(draft, :continuous_pickup) != 1 or Map.get(draft, :continuous_drop_off) != 1

      if boarding_enabled?, do: %{patterns_missing: patterns_missing}, else: nil
    else
      nil
    end
  end

  defp boarding_warning(_draft, _changed, _geometry), do: nil

  # Creation evaluates its new values; Details warns only about changed fields.
  defp field_changed?(_field, :all), do: true
  defp field_changed?(field, changed) when is_list(changed), do: field in changed

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

  attr :short_warning, :map,
    default: nil,
    doc: "advisory `%{kind: :duplicate | :too_long}` from `field_warnings/1`"

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

    assigns =
      assign(
        assigns,
        :short_described_by,
        described_by(
          assigns.name_errors,
          "#{assigns.prefix}-names-error",
          nil,
          (assigns.short_warning && "#{assigns.prefix}-short-warn") || nil
        )
      )

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
              aria-describedby={@short_described_by}
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
        <.field_warning :if={@short_warning} id={"#{@prefix}-short-warn"}>
          <%= if @short_warning.kind == :duplicate do %>
            <strong class="font-[650]">
              Route {@short_warning.route[:route_id]}
            </strong>
            <%= if present_name?(@short_warning.route[:route_short_name]) do %>
              already uses the number “{@short_warning.route[:route_short_name]}”. Riders may mix
              them up. You can still save.
            <% else %>
              already has this number without its own name. Riders may mix them up. You can still
              save.
            <% end %>
          <% else %>
            Trip planners may cut off numbers longer than 12 characters. Put words in the route
            name instead.
          <% end %>
        </.field_warning>
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

  @doc """
  Renders Route color, Text color and the contrast readout.

  `form` carries `route_color`/`route_text_color` plus the identity fields the
  preview badge needs. `text_mode` is the caller's draft transport mode
  (`"automatic"` or `"custom"`, the transient metadata R1 lets
  `Route.editor_changeset/3` pop before its cast); without it the mode is
  derived from the colors the way the reference's `draftFrom` does, so an
  unedited Details form shows a saved custom text color as Custom and never as
  Automatic, and an unrelated save cannot change it.

  Only hex values submit. The picker carries no name, the Automatic/Custom
  radios submit the top-level transient `text_mode` rather than a `route[…]`
  schema field, and the automatic hex is resolved server-side; nothing but a
  resolved hex ever reaches `route_color` or `route_text_color`.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :prefix, :string, required: true, doc: "namespace for the stable control ids"

  attr :text_mode, :string,
    default: nil,
    doc: "the draft's automatic|custom transport mode; derived from the colors when absent"

  attr :nav_guard, :boolean,
    default: false,
    doc: "arm the RouteDetailsEditor dirty-navigation guard on this hook instance"

  attr :nav_dirty, :boolean,
    default: false,
    doc: "the server's dirty verdict the guard mirrors; read only when nav_guard is set"

  attr :similar_warning, :map,
    default: nil,
    doc: "advisory `%{route: candidate}` from `field_warnings/1` for the draft color"

  def color_fields(assigns) do
    assigns = assign(assigns, :colors, color_preview(assigns.form, assigns.text_mode))
    assigns = assign(assigns, :color_errors, field_errors(assigns.form[:route_color]))
    assigns = assign(assigns, :text_errors, field_errors(assigns.form[:route_text_color]))
    assigns = assign(assigns, :badge_route, badge_route(assigns.form))
    assigns = assign(assigns, :warned?, assigns.colors.usable? and not assigns.colors.readable?)

    assigns =
      assign(
        assigns,
        :color_described_by,
        described_by(
          assigns.color_errors,
          "#{assigns.prefix}-color-error",
          "#{assigns.prefix}-color-help",
          (assigns.similar_warning && "#{assigns.prefix}-color-warn") || nil
        )
      )

    ~H"""
    <div
      id={"#{@prefix}-color-fields"}
      phx-hook="RouteDetailsEditor"
      data-prefix={@prefix}
      data-nav-guard={@nav_guard && "true"}
      data-dirty={@nav_guard && to_string(@nav_dirty)}
      class="grid gap-3"
    >
      <div class="grid gap-x-6 gap-y-4 sm:grid-cols-[auto_minmax(0,1fr)]">
        <div class="grid content-start gap-1.5">
          <label for={"#{@prefix}-color"} class={label_class()}>
            Route color <span class="font-normal text-muted">(optional)</span>
          </label>
          <%!-- The picker is a local editing affordance and carries no name, so
                the hex field is the one `route[route_color]` value that submits
                (R7: the picker is local; the server revalidates what arrives). --%>
          <div class="flex items-center gap-2">
            <input
              type="color"
              id={"#{@prefix}-color-picker"}
              value={"#" <> (@colors.background || "FFFFFF")}
              aria-label="Pick route color"
              title="Pick route color"
              class="h-11 w-14 shrink-0 cursor-pointer rounded-control border border-control bg-white p-1"
            />
            <div class="relative w-[136px]">
              <span class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted">
                #
              </span>
              <input
                type="text"
                id={"#{@prefix}-color"}
                name={@form[:route_color].name}
                value={@form[:route_color].value}
                phx-debounce="blur"
                autocomplete="off"
                spellcheck="false"
                placeholder="FFFFFF"
                aria-invalid={to_string(@color_errors != [])}
                aria-describedby={@color_described_by}
                class={[control_class(), "pl-7 uppercase tabular-nums"]}
              />
            </div>
          </div>
        </div>
        <fieldset id={"#{@prefix}-text-mode-group"} class="min-w-0">
          <legend class={label_class()}>Text color</legend>
          <div class="mt-1.5 flex flex-wrap items-center gap-2">
            <label for={"#{@prefix}-text-mode-automatic"} class={chip_class()}>
              <input
                type="radio"
                id={"#{@prefix}-text-mode-automatic"}
                name="text_mode"
                value="automatic"
                checked={@colors.mode == "automatic"}
                class="sr-only"
              />Automatic
            </label>
            <label for={"#{@prefix}-text-mode-custom"} class={chip_class()}>
              <input
                type="radio"
                id={"#{@prefix}-text-mode-custom"}
                name="text_mode"
                value="custom"
                checked={@colors.mode == "custom"}
                class="sr-only"
              />Custom
            </label>
          </div>
          <%!-- The automatic hex is resolved server-side, so the custom field
                only appears when the operator asked for a custom one. It keeps
                whatever it held when the mode is switched away, so switching
                Automatic -> Custom is lossless and never rewrites a saved
                custom color. --%>
          <div
            id={"#{@prefix}-text-wrap"}
            class={text_wrap_class(@colors)}
          >
            <span class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted">
              #
            </span>
            <label for={"#{@prefix}-text"} class="sr-only">Custom text color</label>
            <input
              type="text"
              id={"#{@prefix}-text"}
              name={@form[:route_text_color].name}
              value={@form[:route_text_color].value}
              phx-debounce="blur"
              autocomplete="off"
              spellcheck="false"
              placeholder="000000"
              aria-invalid={to_string(@text_errors != [])}
              aria-describedby={described_by(@text_errors, "#{@prefix}-text-error")}
              class={[control_class(), "pl-7 uppercase tabular-nums"]}
            />
          </div>
        </fieldset>
      </div>
      <.error_line id={"#{@prefix}-color-error"} messages={@color_errors} />
      <.error_line id={"#{@prefix}-text-error"} messages={@text_errors} />
      <.field_warning :if={@similar_warning} id={"#{@prefix}-color-warn"}>
        Looks like Route {@similar_warning.route[:route_id]} {similar_color_label(
          @similar_warning.route
        )} on a map. You can still use it.
      </.field_warning>
      <p id={"#{@prefix}-color-help"} class={help_class()}>
        Six hex digits from your brand guide, or pick one; blank means white. Automatic text is
        black or white, whichever reads better.
      </p>
      <%!-- Every part of the readout is always rendered and only ever shown or
            hidden, so a LiveView update that repaints this region cannot destroy
            the fix action an operator is standing on. --%>
      <div
        id={"#{@prefix}-contrast"}
        data-readable={to_string(@colors.usable? and not @warned?)}
        class={contrast_box_class(@warned?)}
      >
        <span id={"#{@prefix}-contrast-badge"}>
          <RouteIdentity.route_badge
            route={@badge_route}
            class="h-8 min-w-9 text-[15px] font-extrabold"
          />
        </span>
        <span
          id={"#{@prefix}-contrast-verdict"}
          class={verdict_class(@colors)}
        >
          <span id={"#{@prefix}-contrast-icon-ok"} class={icon_class(@warned?)}>
            <.icon name="hero-check-circle" class="size-4" />
          </span>
          <span id={"#{@prefix}-contrast-icon-low"} class={icon_class(not @warned?)}>
            <.icon name="hero-exclamation-triangle" class="size-4" />
          </span>
          <span id={"#{@prefix}-contrast-verdict-text"}>{contrast_verdict(@colors)}</span>
        </span>
        <span id={"#{@prefix}-contrast-ratio"} class="tabular-nums">
          {contrast_readout(@colors)}
        </span>
        <div id={"#{@prefix}-contrast-advice"} class={advice_class(@warned?)}>
          <p>{fallback_note(@colors)}</p>
          <button
            type="button"
            id={"#{@prefix}-use-automatic"}
            class="mt-1 inline-flex min-h-11 items-center font-[650] underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            Use automatic text color
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders Description and Web page — the Details "Rider information" section.

  Both controls are optional, so both are labelled as such and neither carries a
  browser `required`; R1 rejects only a blank *pair* of names, and the URL rule
  (`http(s)` with a nonempty host) is the server changeset's.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :prefix, :string, required: true, doc: "namespace for the stable control ids"

  attr :url_warning, :map,
    default: nil,
    doc: "advisory `%{agency: option}` from `field_warnings/1` for the draft URL"

  def rider_fields(assigns) do
    assigns = assign(assigns, :desc_errors, field_errors(assigns.form[:route_desc]))
    assigns = assign(assigns, :url_errors, field_errors(assigns.form[:route_url]))

    assigns =
      assign(
        assigns,
        :url_described_by,
        described_by(
          assigns.url_errors,
          "#{assigns.prefix}-url-error",
          "#{assigns.prefix}-url-help",
          (assigns.url_warning && "#{assigns.prefix}-url-warn") || nil
        )
      )

    ~H"""
    <div id={"#{@prefix}-rider"} class="grid gap-6">
      <div class="grid gap-1.5">
        <label for={"#{@prefix}-desc"} class={label_class()}>
          Description <span class="font-normal text-muted">(optional)</span>
        </label>
        <textarea
          id={"#{@prefix}-desc"}
          name={@form[:route_desc].name}
          rows="3"
          spellcheck="false"
          aria-invalid={to_string(@desc_errors != [])}
          aria-describedby={
            described_by(@desc_errors, "#{@prefix}-desc-error", "#{@prefix}-desc-help")
          }
          class="min-h-[88px] w-full resize-y rounded-control border border-control bg-white px-3 py-2.5 text-sm text-strong placeholder:text-muted aria-[invalid=true]:border-2 aria-[invalid=true]:border-error-fg disabled:bg-canvas disabled:text-muted"
        >{@form[:route_desc].value}</textarea>
        <.error_line id={"#{@prefix}-desc-error"} messages={@desc_errors} />
        <p id={"#{@prefix}-desc-help"} class={help_class()}>
          Where and when it runs, in a sentence. Don't repeat the route name.
        </p>
      </div>

      <div class="grid gap-1.5">
        <label for={"#{@prefix}-url"} class={label_class()}>
          Web page <span class="font-normal text-muted">(optional)</span>
        </label>
        <input
          type="url"
          id={"#{@prefix}-url"}
          name={@form[:route_url].name}
          value={@form[:route_url].value}
          autocomplete="off"
          spellcheck="false"
          placeholder="https://"
          aria-invalid={to_string(@url_errors != [])}
          aria-describedby={described_by(@url_errors, "#{@prefix}-url-error", "#{@prefix}-url-help")}
          class={control_class()}
        />
        <.error_line id={"#{@prefix}-url-error"} messages={@url_errors} />
        <.field_warning :if={@url_warning} id={"#{@prefix}-url-warn"}>
          This is {@url_warning.agency[:agency_name]}’s home page. Link to a page about this
          route, such as its timetable.
        </.field_warning>
        <p id={"#{@prefix}-url-help"} class={help_class()}>
          A page riders can open for this route. It must start with http:// or https://.
        </p>
      </div>
    </div>
    """
  end

  # The four GTFS continuous-boarding values, labelled the way the reference
  # labels them; R1 accepts exactly 0..3 and the changeset rejects anything else.
  defp boarding_options do
    [
      {"Not allowed", 1},
      {"Anywhere along the route", 0},
      {"Arrange with the driver", 3},
      {"Call the agency first", 2}
    ]
  end

  @doc """
  Renders the collapsible "Additional details" section.

  The summary stays readable while the disclosure is closed by repeating the
  saved display order, boarding defaults, fare network and read-only route ID as
  one line; a value the route does not have is named as not set rather than
  dropped, so the summary never silently loses a field. The route ID is reading
  material, not a control: R1 makes the natural ID creation-only, so this section
  states it and cannot change it.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :prefix, :string, required: true, doc: "namespace for the stable control ids"
  attr :route_id, :string, required: true, doc: "the saved natural ID, rendered read-only"
  attr :open?, :boolean, default: false

  attr :boarding_warning, :map,
    default: nil,
    doc: """
    advisory `%{patterns_missing: n}` from `field_warnings/1`; `href` names the
    surface where the missing paths are added
    """

  def additional_details(assigns) do
    assigns = assign(assigns, :summary, additional_summary(assigns.form, assigns.route_id))
    assigns = assign(assigns, :sort_errors, field_errors(assigns.form[:route_sort_order]))
    assigns = assign(assigns, :pickup_errors, field_errors(assigns.form[:continuous_pickup]))
    assigns = assign(assigns, :drop_errors, field_errors(assigns.form[:continuous_drop_off]))
    assigns = assign(assigns, :network_errors, field_errors(assigns.form[:network_id]))

    assigns =
      assigns
      |> assign(:pickup_value, option_value(assigns.form[:continuous_pickup].value))
      |> assign(:drop_value, option_value(assigns.form[:continuous_drop_off].value))

    ~H"""
    <details
      id={"#{@prefix}-additional"}
      open={@open?}
      class="group min-w-0 rounded-card border border-subtle"
    >
      <summary class="flex min-h-14 cursor-pointer list-none items-center gap-3 px-4 [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-4 shrink-0 text-muted transition-transform group-open:rotate-90"
        />
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-[650] text-strong">Additional details</span>
          <span id={"#{@prefix}-additional-summary"} class="block truncate text-[13px] text-muted">
            {@summary}
          </span>
        </span>
      </summary>

      <div class="grid gap-6 border-t border-subtle px-4 pb-5 pt-4">
        <div class="grid gap-1.5">
          <label for={"#{@prefix}-sort"} class={label_class()}>
            Display order <span class="font-normal text-muted">(optional)</span>
          </label>
          <input
            type="text"
            inputmode="numeric"
            id={"#{@prefix}-sort"}
            name={@form[:route_sort_order].name}
            value={@form[:route_sort_order].value}
            autocomplete="off"
            aria-invalid={to_string(@sort_errors != [])}
            aria-describedby={
              described_by(@sort_errors, "#{@prefix}-sort-error", "#{@prefix}-sort-help")
            }
            class={[control_class(), "max-w-[140px] tabular-nums"]}
          />
          <.error_line id={"#{@prefix}-sort-error"} messages={@sort_errors} />
          <p id={"#{@prefix}-sort-help"} class={help_class()}>
            Trip planners list routes with lower numbers first. Blank sorts after numbered routes.
          </p>
        </div>

        <fieldset id={"#{@prefix}-boarding-group"} class="min-w-0">
          <legend class={label_class()}>Boarding between stops</legend>
          <p class="mt-0.5 text-[13px] text-muted">
            The default for every trip on this route. A pattern can set different rules for
            particular stops.
          </p>
          <div class="mt-3 grid gap-3 sm:grid-cols-2">
            <div class="grid gap-1.5">
              <label for={"#{@prefix}-pickup"} class={label_class()}>Pickup</label>
              <div class="relative">
                <select
                  id={"#{@prefix}-pickup"}
                  name={@form[:continuous_pickup].name}
                  aria-invalid={to_string(@pickup_errors != [])}
                  aria-describedby={described_by(@pickup_errors, "#{@prefix}-pickup-error")}
                  class={select_class()}
                >
                  {Phoenix.HTML.Form.options_for_select(boarding_options(), @pickup_value)}
                </select>
                <.chevron />
              </div>
              <.error_line id={"#{@prefix}-pickup-error"} messages={@pickup_errors} />
            </div>
            <div class="grid gap-1.5">
              <label for={"#{@prefix}-dropoff"} class={label_class()}>Drop-off</label>
              <div class="relative">
                <select
                  id={"#{@prefix}-dropoff"}
                  name={@form[:continuous_drop_off].name}
                  aria-invalid={to_string(@drop_errors != [])}
                  aria-describedby={described_by(@drop_errors, "#{@prefix}-dropoff-error")}
                  class={select_class()}
                >
                  {Phoenix.HTML.Form.options_for_select(boarding_options(), @drop_value)}
                </select>
                <.chevron />
              </div>
              <.error_line id={"#{@prefix}-dropoff-error"} messages={@drop_errors} />
            </div>
          </div>
          <.field_warning :if={@boarding_warning} id={"#{@prefix}-cont-warn"} class="mt-2">
            {boarding_warning_text(@boarding_warning.patterns_missing)}
            <.link
              :if={@boarding_warning[:href]}
              navigate={@boarding_warning.href}
              class="font-[650] text-warning-fg underline"
            >
              Add the missing paths
            </.link>
          </.field_warning>
        </fieldset>

        <div class="grid gap-1.5">
          <label for={"#{@prefix}-network"} class={label_class()}>
            Fare network <span class="font-normal text-muted">(optional)</span>
          </label>
          <input
            type="text"
            id={"#{@prefix}-network"}
            name={@form[:network_id].name}
            value={@form[:network_id].value}
            autocomplete="off"
            spellcheck="false"
            aria-invalid={to_string(@network_errors != [])}
            aria-describedby={
              described_by(@network_errors, "#{@prefix}-network-error", "#{@prefix}-network-help")
            }
            class={[control_class(), "max-w-[240px] font-mono"]}
          />
          <.error_line id={"#{@prefix}-network-error"} messages={@network_errors} />
          <p id={"#{@prefix}-network-help"} class={help_class()}>
            Only if your fares group routes into networks. Leave blank otherwise.
          </p>
        </div>

        <div class="grid gap-1">
          <p class={label_class()}>Route ID</p>
          <p id={"#{@prefix}-route-id"} class="font-mono text-sm text-strong">{@route_id}</p>
          <p class={help_class()}>
            Trips, transfers and fare rules refer to this ID, so it can't be changed here.
          </p>
        </div>
      </div>
    </details>
    """
  end

  # The closed disclosure still states every value it holds: the display order,
  # the two boarding defaults, the fare network when the route has one, and the
  # read-only route ID. A value the route does not have is named as not set.
  defp additional_summary(form, route_id) do
    boarding = boarding_option_label(form[:continuous_pickup].value)

    [
      "Display order #{form[:route_sort_order].value || "not set"}",
      "Boarding between stops: #{boarding}",
      if(blank_value?(form[:network_id].value),
        do: nil,
        else: "Network #{form[:network_id].value}"
      ),
      "Route ID #{route_id}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp boarding_option_label(value) do
    value = option_value(value)

    Enum.find_value(boarding_options(), "—", fn {label, option} ->
      option_value(option) == value && label
    end)
  end

  # "1 pattern has…" / "2 patterns have…", the reference's own sentence, with
  # the count of patterns the map projection reported known-missing sections
  # for.
  defp boarding_warning_text(1),
    do:
      "1 pattern has sections without a path, so riders can’t tell where boarding between stops applies there."

  defp boarding_warning_text(count),
    do:
      "#{count} patterns have sections without a path, so riders can’t tell where boarding between stops applies there."

  # Select options compare as strings; a saved integer and a submitted string are
  # the same choice.
  defp option_value(value) when is_integer(value), do: to_string(value)
  defp option_value(value) when is_binary(value), do: value
  defp option_value(_value), do: ""

  defp blank_value?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

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

  @doc """
  Returns a form field's translated errors, honoring `used_input?/1`.

  Public because a mounting surface that renders its own control outside this
  module (the create drawer's identifier override) has to apply the same rule
  as the shared controls rather than inventing a second one.
  """
  def field_errors(%Phoenix.HTML.FormField{} = field) do
    # `CoreComponents.input/1` only surfaces a field's errors once the form has
    # actually used that input, so a draft nobody typed into never shows a stale
    # message. The shared controls keep the same rule.
    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, &translate_error/1)
    else
      []
    end
  end

  # A control names the descriptions it actually renders: the error line only
  # while it has errors, standing help text whenever it is present, and the
  # field's advisory while it has one.
  defp described_by(messages, error_id, help_id \\ nil, warn_id \\ nil) do
    [if(messages == [], do: nil, else: error_id), help_id, warn_id]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  defp present_name?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_name?(_value), do: false

  # The saved color a similar-color advisory names; the candidate projection
  # stores it already normalized, so the label is the stored value verbatim.
  defp similar_color_label(%{route_color: color}) when is_binary(color), do: "(##{color})"
  defp similar_color_label(_route), do: ""

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

  # The preview's own arithmetic, in one place: the picker value, the checked
  # mode chip, and what the contrast readout says. `RouteIdentity` is the same
  # owner the app's badge uses, so the readout cannot describe a badge the
  # application would not draw, and
  # `assets/js/route_identity_preview.js` recomputes the same four values in the
  # browser after every keystroke.
  defp color_preview(form, text_mode) do
    color = draft_color(form[:route_color].value)
    text = draft_color(form[:route_text_color].value)

    # R1 normalizes a new/changed blank route color to FFFFFF, so a blank
    # draft previews as white. A nonblank color the server will reject has no
    # preview at all: it is `nil` here, and the error line above is the truth.
    background =
      case color do
        {:ok, hex} -> hex
        :blank -> "FFFFFF"
        :invalid -> nil
      end

    mode = text_mode || derived_text_mode(background, text)

    requested =
      cond do
        mode != "automatic" ->
          case text do
            {:ok, hex} -> hex
            :blank -> "000000"
            :invalid -> nil
          end

        is_nil(background) ->
          nil

        true ->
          RouteIdentity.automatic_text_color(background)
      end

    ratio =
      if background && requested,
        do: RouteIdentity.contrast_ratio(background, requested),
        else: nil

    %{
      background: background,
      mode: mode,
      requested: requested,
      ratio: ratio,
      readable?: ratio != nil and ratio >= 4.5,
      usable?: ratio != nil,
      fallback: background && RouteIdentity.automatic_text_color(background)
    }
  end

  # A draft color is blank, usable hex, or unusable, and the three are different
  # things: blank normalizes to the R1 default, while unusable is an error the
  # changeset rejects and no preview may stand in for.
  defp draft_color(nil), do: :blank
  defp draft_color(""), do: :blank

  defp draft_color(value) when is_binary(value) do
    if String.trim(value) == "" do
      :blank
    else
      case RouteIdentity.normalize_hex(value) do
        {:ok, hex} -> {:ok, hex}
        :error -> :invalid
      end
    end
  end

  defp draft_color(_value), do: :invalid

  # With no draft transport mode, the colors decide. Blank text is automatic
  # because a blank value carries no operator intent and the app already resolves
  # one automatically everywhere else (`RouteIdentity.resolve_foreground/2`);
  # anything else is Custom unless it already is the automatic pick, which is
  # the reference's own `draftFrom` rule and what keeps an imported custom text
  # color Custom across an unrelated edit.
  defp derived_text_mode(_background, :blank), do: "automatic"

  defp derived_text_mode(background, {:ok, text}) do
    if background && text == RouteIdentity.automatic_text_color(background),
      do: "automatic",
      else: "custom"
  end

  defp derived_text_mode(_background, :invalid), do: "custom"

  # The preview badge is the application badge, given the form's own values:
  # `route_badge/1` normalizes them and falls back to a neutral surface for a
  # value the server will reject, which is exactly what the readout describes.
  defp badge_route(form) do
    %{
      route_id: form[:route_id].value,
      route_short_name: form[:route_short_name].value,
      route_color: form[:route_color].value,
      route_text_color: form[:route_text_color].value
    }
  end

  defp contrast_box_class(true),
    do:
      "flex min-h-11 flex-wrap items-center gap-x-3 gap-y-1 rounded-control border border-warning bg-warning/10 px-3 py-2 text-[13px] text-warning"

  defp contrast_box_class(_readable),
    do:
      "flex min-h-11 flex-wrap items-center gap-x-3 gap-y-1 rounded-control bg-canvas px-3 py-2 text-[13px] text-default"

  defp text_wrap_class(%{mode: "custom"}), do: "relative mt-2 w-[136px]"
  defp text_wrap_class(_colors), do: "relative mt-2 w-[136px] hidden"

  # A draft color with nothing to measure against states no verdict rather than
  # claiming a ratio it cannot compute.
  defp verdict_class(%{usable?: false}),
    do: "inline-flex items-center gap-1.5 font-[650] hidden"

  defp verdict_class(_colors), do: "inline-flex items-center gap-1.5 font-[650]"

  defp icon_class(hide?), do: (hide? && "hidden") || nil

  defp advice_class(warned?), do: (warned? && "basis-full") || "basis-full hidden"

  defp contrast_verdict(%{usable?: false}), do: ""
  defp contrast_verdict(%{readable?: true}), do: "Easy to read"
  defp contrast_verdict(_colors), do: "Hard to read"

  defp contrast_readout(%{usable?: false}), do: "–:1 contrast"

  defp contrast_readout(%{ratio: ratio, readable?: true}),
    do: "#{:erlang.float_to_binary(ratio, decimals: 1)}:1 contrast"

  defp contrast_readout(%{ratio: ratio}),
    do: "#{:erlang.float_to_binary(ratio, decimals: 1)}:1 contrast, below 4.5:1"

  # "black"/"white" for the two colors the automatic pick can return, which is
  # the whole set of fallbacks the readout can name.
  defp fallback_note(%{fallback: nil}), do: ""

  defp fallback_note(%{fallback: fallback}) do
    "The app shows this badge with #{color_name(fallback)} text; exports keep what you enter."
  end

  defp color_name("000000"), do: "black"
  defp color_name("FFFFFF"), do: "white"
  defp color_name(hex), do: "##{hex}"

  @doc """
  Renders the merge comparison another editor's save produced (R4, AC-8).

  `merge` is the conflict payload `Gtfs.update_route/5` returned: the fresh
  current source and the field-level comparison. Disjoint changes get one
  deliberate "Save both changes"; overlapping fields get an explicit
  keep-mine/use-saved radio group each (the coupled color pair is one group
  named for `route_color`, which the LiveView copies to its pair member).
  The panel is rendered inside the details form, so its submit carries the
  operator's current draft plus the merge binding; "Discard my changes" is a
  plain click that reloads the latest saved values.
  """
  attr :merge, :map, required: true
  attr :saved_by, :string, required: true
  attr :intro, :string, required: true
  attr :rows, :list, required: true
  attr :groups, :list, required: true

  def merge_conflict(assigns) do
    assigns =
      assign(
        assigns,
        :choices_required?,
        assigns.merge.comparison.status == :choices_required
      )

    ~H"""
    <div
      id="route-conflict"
      tabindex="-1"
      class="rounded-control border border-warning bg-warning/10 px-4 py-3 outline-none"
    >
      <div class="flex items-start gap-3">
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
        <div class="min-w-0 flex-1">
          <p class="text-sm font-bold text-strong">{@saved_by}</p>
          <p class="mt-0.5 text-sm text-default">{@intro}</p>

          <table
            id="route-conflict-table"
            class="mt-3 w-full border-collapse overflow-hidden rounded-control bg-white text-left text-[13px]"
          >
            <thead>
              <tr class="border-b border-subtle bg-canvas">
                <th scope="col" class="px-3 py-2 font-[650]">Field</th>
                <th scope="col" class="px-3 py-2 font-[650]">Now saved</th>
                <th scope="col" class="px-3 py-2 font-[650]">Your draft</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @rows}
                class="border-b border-subtle last:border-0"
              >
                <th scope="row" class="px-3 py-2 text-left font-[650]">{row.label}</th>
                <td class="px-3 py-2">{row.theirs}</td>
                <td class="px-3 py-2">{row.mine}</td>
              </tr>
            </tbody>
          </table>

          <fieldset :for={group <- @groups} class="mt-3 grid gap-1.5">
            <legend class="text-[13px] font-[650] text-default">{group.label}</legend>
            <div class="flex flex-wrap gap-3">
              <label class={choice_class()}>
                <input
                  type="radio"
                  required
                  class="sr-only"
                  name={"merge[fields][#{group.field}]"}
                  value="mine"
                /> Keep mine
              </label>
              <label class={choice_class()}>
                <input
                  type="radio"
                  required
                  class="sr-only"
                  name={"merge[fields][#{group.field}]"}
                  value="theirs"
                /> Use saved
              </label>
            </div>
          </fieldset>

          <div class="mt-3 flex flex-wrap gap-3">
            <.button
              type="submit"
              name="merge_confirm"
              value="true"
              id="route-conflict-save"
              class="min-h-11 min-w-[150px]"
            >
              {if @choices_required?, do: "Save chosen changes", else: "Save both changes"}
            </.button>
            <.button
              type="button"
              variant="secondary"
              id="route-conflict-discard"
              phx-click="discard_merge"
              class="min-h-11"
            >
              Discard my changes
            </.button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp choice_class do
    "relative inline-flex min-h-11 cursor-pointer items-center rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas has-[:checked]:border-2 has-[:checked]:border-action has-[:checked]:bg-selection has-[:checked]:px-[15px] has-[:checked]:text-action has-[:focus-visible]:outline has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
  end
end
