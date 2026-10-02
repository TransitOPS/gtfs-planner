defmodule GtfsPlannerWeb.Gtfs.FlexComponents do
  @moduledoc """
  The Flex list's surfaces: the services table, the export-state line, the
  first-use question, the create drawer, the copy action, the map card, and the
  list's loading and error states.

  `FlexLive` owns the load and every value; these components render what they are
  given, so the copy the prototype fixes lives in one place per state. The table
  is a design-system table whose last column carries each service's
  `Flex.Checks.status/2` badge: the tone selects the badge's colour and icon and
  the label always carries the meaning, so the status is never signalled by
  colour alone.

  The create drawer is the shared `drawer/1` in the planner chrome, because the
  app's own `OverlayDialog` behaviour already gives a modal dialog that Esc
  closes, that keeps focus inside it, and that returns focus to the control that
  opened it. Its error summary follows the app's `FormErrorFocus` pattern: the
  summary carries `tabindex="-1"` and the page moves focus to it, and each item
  links to the field it names.

  The map card renders the `FlexAreaMap` hook's root (`#flex-list-map`) with the
  Leaflet stage inside it and the legend beneath it. The server never patches
  inside the root (`phx-update="ignore"`), because the hook owns that subtree
  once it mounts and draws the version's areas, route lines and connecting stops
  from the `map` payload `Flex.map_payload/2` builds.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.CoreComponents,
    only: [
      button: 1,
      confirm_dialog: 1,
      drawer: 1,
      header: 1,
      icon: 1,
      input: 1,
      skeleton: 1
    ]

  import GtfsPlannerWeb.PlannerComponents,
    only: [
      back_link: 1,
      drawer_footer: 1,
      drawer_scroll: 1,
      form_error_summary: 1,
      message: 1
    ]

  # The weekly service calendar row. Aliased away from `Calendar` so the
  # standard library's date formatting stays reachable in this module.
  alias GtfsPlanner.Gtfs.Calendar, as: ServiceCalendar
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Values
  alias GtfsPlanner.Wording

  # The two kinds a first-time editor chooses between (AC-4). Wording is the
  # prototype's. Both the first-use question and the create drawer render them,
  # so the drawer's kind radios and the question's buttons never drift apart.
  # `key` is the stored kind; `pattern` is the prototype's own name for the
  # radio, which keeps the drawer's control ids the ones the reference draws.
  @kinds [
    %{
      key: "area",
      pattern: "area",
      label: "Rides anywhere in an area",
      help:
        "Dial-a-ride or microtransit. Riders book a trip between any two places in the area, and can also ride to set stops."
    },
    %{
      key: "detour",
      pattern: "route",
      label: "A route that detours on request",
      help:
        "Route deviation. The bus keeps its timetable and leaves the route to pick up or drop off riders who ask."
    }
  ]

  # The distances the reference offers as equals (AC-29). The labels are the
  # prototype's `DISTANCES`, with the reference's own capitalisation and its
  # "most common" note on ¾ mile; the stored value is metres.
  @distance_choices [
    {"A few blocks (0.2 km)", 200},
    {"¼ mile (0.4 km)", 400},
    {"½ mile (0.8 km)", 800},
    {"¾ mile (1.2 km), most common", 1200},
    {"1 mile (1.6 km)", 1600}
  ]

  # The realtime answers `GtfsPlanner.Gtfs.ExportDefault` stores, labelled the
  # way the reference labels them (AC-29, AC-15). Each entry is the label and the
  # stored value, the order `options_for_select/2` expects, so the Settings page's
  # `<.input type="select">` and the service page's own `<option>` loop read the
  # same list. `realtime_options/0` hands them to both.
  @realtime_options [
    {"Main feed", "main"},
    {"Flex file", "flex"},
    {"Its own schedule file", "own"},
    {"No realtime", "none"},
    {"Not sure", "unsure"}
  ]

  @doc "The labelled realtime answers the service page and the settings page offer."
  def realtime_options, do: @realtime_options

  @doc """
  Builds the row the services table renders for one service.

  Every cell is a reader-facing summary of the stored service: the prototype's
  "where" line, `RiderText.hours_lines/3` for the hours, the short booking
  summary, and `Checks.status/2` for the badge. `checks` are the service's own
  readiness checks, so the badge reports the same status the service page will.
  """
  @spec list_row(FlexService.t(), [Checks.check()], map(), String.t()) :: map()
  def list_row(%FlexService{} = service, checks, calendars, version_id) do
    %{
      id: service.id,
      name: service.name,
      href: ~p"/gtfs/#{version_id}/flex/#{service.id}",
      where: RiderText.where_line(service),
      hours_lines: RiderText.hours_lines(service, service.areas, calendars),
      booking: booking_summary(service),
      status: Checks.status(service, checks)
    }
  end

  @doc """
  Renders the version's flex services as one row per service.

  Each row is the service's name as the link to its page, its hours summary
  (`RiderText.hours_lines/3`), its booking summary and its readiness badge, in
  the order the load returned (name, then id). The count is a status line above
  the table, and the table scrolls inside its own container so a 320 px viewport
  never scrolls the page sideways.
  """
  attr :rows, :any, required: true, doc: "the `:services` stream"
  attr :count, :integer, required: true

  def services_table(assigns) do
    ~H"""
    <div class="min-w-0 self-start">
      <div class="overflow-clip rounded-card border border-subtle bg-white">
        <div class="flex min-h-[52px] items-center border-b border-subtle px-4 py-1">
          <p
            id="flex-services-count"
            role="status"
            class="text-[13px] font-[650] tabular-nums text-strong"
          >
            {Wording.count_noun(@count, "flex service")}
          </p>
        </div>

        <%!-- The table keeps a readable width and scrolls inside its own card,
        so a narrow viewport never scrolls the page sideways. --%>
        <div class="overflow-x-auto">
          <table
            id="flex-services-table"
            class="w-full min-w-[640px] border-collapse text-left text-sm"
          >
            <caption class="sr-only">
              Flex services
            </caption>
            <thead>
              <tr class="bg-canvas">
                <th scope="col" class={head_class()}>Service</th>
                <th scope="col" class={head_class()}>Hours</th>
                <th scope="col" class={head_class()}>Booking</th>
                <th scope="col" class={head_class()}>Status</th>
              </tr>
            </thead>
            <tbody id="flex-services" phx-update="stream">
              <tr
                :for={{id, row} <- @rows}
                id={id}
                class="border-t border-subtle align-top hover:bg-canvas"
              >
                <td class="px-4 py-1">
                  <.link
                    navigate={row.href}
                    class="inline-flex min-h-11 items-center rounded-control text-[15px] font-[650] text-action no-underline underline-offset-4 hover:text-action-hover hover:underline"
                  >
                    {row.name}
                  </.link>
                  <p class="pb-2 text-[13px] text-muted">{row.where}</p>
                </td>
                <td class="px-4 py-3 text-default">
                  <span :for={line <- row.hours_lines} class="block tabular-nums">{line}</span>
                </td>
                <td class="px-4 py-3 text-default">{row.booking}</td>
                <td class="px-4 py-3">
                  <.badge tone={badge_tone(row.status.tone)} label={row.status.label} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <p id="flex-services-note" class="mt-3 text-[13px] text-muted">
        A service with problems isn’t exported until it’s fixed. The export run names any service it leaves out.
      </p>
    </div>
    """
  end

  defp head_class, do: "px-4 py-2.5 text-left text-[13px] font-[650] text-default"

  # A radio or checkbox inside a choice card shows its focus ring on the card,
  # because `.ds-page` removes the control's own outline.
  defp card_focus,
    do:
      "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"

  # `.ds-page` rings links, selects and text fields but not a raw `<button>`, so
  # every hand-rolled button in this module carries the design system's outline.
  defp focus_ring,
    do: "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"

  # A status as words on a tinted ground with a mark, so the meaning never rests
  # on colour alone. `tone` is the design system's own vocabulary; the flex list
  # and the service page both call it with `badge_tone/1`'s answer.
  attr :tone, :string, values: ~w(neutral success warning error), required: true
  attr :label, :string, required: true
  attr :id, :string, default: nil

  defp badge(assigns) do
    assigns = assign(assigns, :tone_class, badge_class(assigns.tone))
    assigns = assign(assigns, :icon_name, badge_icon(assigns.tone))

    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex min-h-7 items-center gap-1.5 whitespace-nowrap rounded-badge px-2 text-[13px] font-[650]",
        @tone_class
      ]}
    >
      <.icon name={@icon_name} class="size-3.5 shrink-0" />{@label}
    </span>
    """
  end

  defp badge_class("success"), do: "bg-success-bg text-success-fg"
  defp badge_class("warning"), do: "bg-warning-bg text-warning-fg"
  defp badge_class("error"), do: "bg-error-bg text-error-fg"
  defp badge_class("neutral"), do: "border border-subtle bg-canvas text-default"

  defp badge_icon("success"), do: "hero-check-circle"
  defp badge_icon("neutral"), do: "hero-information-circle"
  defp badge_icon(_alert), do: "hero-exclamation-triangle"

  @doc """
  Renders the export-state line: what a full export will do with these services.

  With flex on, the flex file is published beside the main feed, and the line
  says so; when the version has no fixed route at all, the flex file is the only
  feed (R15, AC-24's wording). With flex off, the line is a warning naming what
  riders lose and where the switch lives.
  """
  attr :include_flex, :boolean, required: true
  attr :has_fixed_routes?, :boolean, required: true
  attr :version_id, :string, required: true

  def exports_line(%{include_flex: false} = assigns) do
    ~H"""
    <.message
      id="flex-exports"
      kind="warning"
      role="status"
      title="Exports leave flex out."
      class="mt-5"
    >
      Riders won’t see these services in trip planners until flex is turned on.
      <.link
        href={~p"/gtfs/#{@version_id}/settings/export-defaults"}
        class="font-[650] text-warning-fg underline"
      >
        Change in Settings › Export defaults
      </.link>
    </.message>
    """
  end

  def exports_line(assigns) do
    ~H"""
    <div id="flex-exports" class="mt-5 grid gap-1 border-y border-subtle py-3 text-sm">
      <p class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span class="font-[650] text-strong">Exports</span>
        <span>{export_sentence(@has_fixed_routes?)}</span>
        <.link
          href={~p"/gtfs/#{@version_id}/settings/export-defaults"}
          class="font-[650] text-action hover:underline"
        >
          Change in Settings › Export defaults
        </.link>
      </p>
      <p class="text-[13px] text-muted">
        Riders see flex service in the Transit app and in trip planners built on OpenTripPlanner. Google Maps doesn’t accept flex data.
      </p>
    </div>
    """
  end

  @doc """
  Renders the first-use question: what kind of on-demand service the editor runs.

  The two kinds are the only actions, and each opens the create drawer with its
  kind already chosen. The pointer below them answers the other question the
  prototype answers here: a stop served only when booked belongs on the route's
  timetable, not in a new flex service.

  On a version with no services the copy action renders inside this state
  (AC-6). `sources` are the organization's other published versions that hold a
  service; the panel renders only when there is one to copy from, because a
  version with no services is the only version a copy may land in (R14) and a
  version with none to copy is no source at all.
  """
  attr :sources, :list, default: []
  attr :copy_form, :any, default: nil
  attr :copy_target, :any, default: nil
  attr :copy_error, :string, default: nil

  def first_use(assigns) do
    assigns = assign(assigns, :kinds, @kinds)

    ~H"""
    <section
      id="flex-first-use"
      aria-labelledby="flex-first-use-title"
      class="self-start rounded-card border border-subtle bg-white px-6 py-6"
    >
      <h2
        id="flex-first-use-title"
        class="font-display text-[24px] font-semibold tracking-[-0.025em] text-strong"
      >
        What kind of on-demand service do you run?
      </h2>
      <p class="mt-2 max-w-[60ch] text-sm leading-relaxed">
        Pick the closest match to create your first flex service. Describe it the way riders use it; GTFS Planner writes the GTFS-Flex files for trip planners.
      </p>

      <div class="mt-4 grid gap-2">
        <button
          :for={kind <- @kinds}
          id={"flex-create-#{kind.key}"}
          type="button"
          phx-click="open_create"
          phx-value-kind={kind.key}
          phx-value-opener_id={"flex-create-#{kind.key}"}
          class={[
            "flex min-h-11 items-start gap-3 rounded-card border border-subtle px-3 py-3 text-left hover:border-action hover:bg-canvas",
            focus_ring()
          ]}
        >
          <span class="min-w-0 flex-1">
            <span class="block text-sm font-[650] text-strong">{kind.label}</span>
            <span class="block text-[13px] text-muted">{kind.help}</span>
          </span>
          <span class="shrink-0" aria-hidden="true"><.kind_diagram kind={kind.key} /></span>
        </button>
      </div>

      <.booked_stops_pointer />

      <.copy_panel
        :if={@sources != []}
        sources={@sources}
        form={@copy_form}
        target={@copy_target}
        error={@copy_error}
      />
    </section>
    """
  end

  @doc """
  Renders the create drawer (AC-4): the two kinds, the one-name question, the
  booked-stops pointer, a detour's route and the name.

  `form` is the drawer's draft, so every control carries what the editor has
  answered; the page re-renders the drawer on each change, because choosing a
  kind or a one-name answer adds or removes a question. `errors` are
  `{field_id, message}` pairs for the summary and the controls it links to, and
  `error` is a failure no field owns.

  The name input takes focus when the drawer opens with a kind already chosen
  (the first-use buttons), and the drawer's heading otherwise, so the first
  usable control is focused rather than the form's first radio.
  """
  attr :open, :boolean, required: true
  attr :version_name, :string, required: true
  attr :form, :any, required: true
  attr :errors, :list, default: []
  attr :routes, :list, default: []
  attr :error, :string, default: nil
  attr :focus_id, :string, default: nil
  attr :return_focus_id, :string, default: nil

  def create_drawer(assigns) do
    assigns =
      assigns
      |> assign(:kinds, @kinds)
      |> assign(:kind, assigns.form[:kind].value)
      |> assign(:named, assigns.form[:named].value)
      |> assign(:route_options, Enum.map(assigns.routes, &{&1.name, &1.id}))
      |> assign(:error_ids, MapSet.new(Enum.map(assigns.errors, &elem(&1, 0))))
      |> assign(
        :failures,
        Enum.map(assigns.errors, fn {field_id, message} ->
          %{href: "##{field_id}", msg: message}
        end)
      )

    ~H"""
    <.drawer
      id="create-drawer"
      chrome="planner"
      open={@open}
      on_close="close_create"
      title="Create flex service"
      initial_focus={if @focus_id, do: :first_field, else: :heading}
      initial_focus_id={@focus_id}
      return_focus_id={@return_focus_id}
      class="max-w-[min(100vw,32.5rem)]"
    >
      <:lede><span id="create-drawer-description">{@version_name}</span></:lede>

      <div id="create-drawer-content" phx-hook="FormErrorFocus" class="flex min-h-0 flex-1 flex-col">
        <.form
          for={@form}
          id="create-form"
          novalidate
          phx-change="create_change"
          phx-submit="create_submit"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.form_error_summary
              :if={@errors != []}
              id="create-error-summary"
              title={summary_lead(@errors)}
              failures={@failures}
              class=""
            />

            <.message
              :if={@error}
              id="create-save-error"
              kind="error"
              title="Nothing was created"
              tabindex="-1"
            >
              {@error}
            </.message>

            <fieldset>
              <legend class="text-[13px] font-[650] text-default">How does it work?</legend>

              <div class="mt-2 grid gap-2">
                <label
                  :for={kind <- @kinds}
                  for={"create-pattern-#{kind.pattern}"}
                  class={[
                    "flex cursor-pointer items-start gap-3 rounded-card border px-3 py-3",
                    card_focus(),
                    if(@kind == kind.key,
                      do: "border-action shadow-[inset_0_0_0_1px_var(--color-action)]",
                      else: "border-subtle hover:bg-canvas"
                    )
                  ]}
                >
                  <input
                    type="radio"
                    id={"create-pattern-#{kind.pattern}"}
                    name="create[kind]"
                    value={kind.key}
                    checked={@kind == kind.key}
                    aria-invalid={error_flag(@error_ids, "create-pattern-#{kind.pattern}")}
                    class="mt-1 size-4 shrink-0 accent-[var(--color-action)]"
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block text-sm font-[650] text-strong">{kind.label}</span>
                    <span class="block text-[13px] text-muted">{kind.help}</span>
                  </span>
                  <span class="shrink-0" aria-hidden="true"><.kind_diagram kind={kind.key} /></span>
                </label>
              </div>

              <.booked_stops_pointer />

              <p
                :if={error_for(@errors, "create-pattern-area")}
                class="mt-1 text-[13px] font-[650] text-error-fg"
              >
                {error_for(@errors, "create-pattern-area")}
              </p>
            </fieldset>

            <fieldset :if={@kind == "area"}>
              <legend class="text-[13px] font-[650] text-default">
                Do riders know the areas by one name?
              </legend>

              <div class="mt-1 grid gap-1">
                <label
                  for="create-named-one"
                  class={[
                    "flex min-h-11 cursor-pointer items-start gap-3 rounded-control py-1",
                    card_focus()
                  ]}
                >
                  <input
                    type="radio"
                    id="create-named-one"
                    name="create[named]"
                    value="one"
                    checked={@named != "several"}
                    class="mt-1 size-4 shrink-0 accent-[var(--color-action)]"
                  />
                  <span class="text-sm">
                    Yes, one name
                    <span class="block text-[13px] text-muted">
                      Towns can still have their own hours, such as “Toledo only: weekdays 9 am–3 pm”.
                    </span>
                  </span>
                </label>

                <label
                  for="create-named-several"
                  class={[
                    "flex min-h-11 cursor-pointer items-start gap-3 rounded-control py-1",
                    card_focus()
                  ]}
                >
                  <input
                    type="radio"
                    id="create-named-several"
                    name="create[named]"
                    value="several"
                    checked={@named == "several"}
                    class="mt-1 size-4 shrink-0 accent-[var(--color-action)]"
                  />
                  <span class="text-sm">No, each area has its own name</span>
                </label>
              </div>

              <p
                :if={@named == "several"}
                id="create-several-names-advice"
                class="mt-1 rounded-card bg-canvas px-3 py-2 text-[13px] text-default"
              >
                Create one service for each name, such as Newport Dial-a-Ride and Toledo Flex, so trip planners show the names riders know. Start with the first one here.
              </p>
            </fieldset>

            <div :if={@kind == "detour"}>
              <.input
                field={@form[:route_id]}
                type="select"
                label="Route that detours"
                options={@route_options}
                prompt="Choose a route"
              />
              <p
                :if={error_for(@errors, "create_route_id")}
                class="mt-1 text-[13px] font-[650] text-error-fg"
              >
                {error_for(@errors, "create_route_id")}
              </p>
            </div>

            <div>
              <.input
                field={@form[:name]}
                type="text"
                label="Service name"
                autocomplete="off"
                phx-debounce="blur"
                placeholder="For example, Newport Dial-a-Ride"
                help="Riders see this name in trip planners. Use the name on your website and vehicles."
              />
              <p
                :if={error_for(@errors, "create_name")}
                class="mt-1 text-[13px] font-[650] text-error-fg"
              >
                {error_for(@errors, "create_name")}
              </p>
            </div>

            <p class="rounded-control bg-canvas px-3 py-2.5 text-[13px] text-muted">
              Next you’ll add when it runs, how riders book and where it goes. Exports leave it out until those are set.
            </p>
          </.drawer_scroll>

          <.drawer_footer>
            <.button type="button" variant="secondary" class="min-h-11" phx-click="close_create">
              Cancel
            </.button>
            <.button id="create-submit" type="submit" class="min-h-11">
              Create service
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the copy action for a version with no services (AC-6, R14).

  The select offers the organization's other published versions that hold a flex
  service, and the copy itself goes through the confirmation dialog, which names
  the source version and only then calls `Flex.copy_from_version/2`. A source
  that loses its last service between this page's load and the confirmation
  still copies nothing; the page reports that rather than leaving an
  unexplained empty list.
  """
  attr :sources, :list, required: true
  attr :form, :any, required: true
  attr :target, :any, default: nil
  attr :error, :string, default: nil

  def copy_panel(assigns) do
    assigns = assign(assigns, :options, Enum.map(assigns.sources, &{&1.name, &1.id}))

    ~H"""
    <section id="flex-copy" aria-labelledby="flex-copy-title" class="mt-6 border-t border-subtle pt-5">
      <h3 id="flex-copy-title" class="text-base font-[650] text-strong">
        Copy flex services from another version
      </h3>
      <p class="mt-1 text-[13px] text-muted">
        Copies every service and its areas, geometry included. A route, stop or calendar this version doesn’t have shows as a readiness error on the copy.
      </p>

      <.form
        for={@form}
        id="flex-copy-form"
        phx-submit="copy_from_version"
        class="mt-3 flex flex-wrap items-end gap-3"
      >
        <.input
          field={@form[:source_version_id]}
          type="select"
          label="Copy from"
          options={@options}
          prompt="Choose a version"
          class="w-full select min-w-[16rem]"
        />
        <.button id="copy-services" type="submit" variant="primary" class="min-h-11">
          Copy services
        </.button>
      </.form>

      <p
        :if={@error}
        id="flex-copy-error"
        role="alert"
        class="mt-2 text-[13px] font-[650] text-error-fg"
      >
        {@error}
      </p>

      <.confirm_dialog
        id="copy-confirm"
        chrome="planner"
        open={not is_nil(@target)}
        title="Copy flex services?"
        confirm_label="Copy services"
        pending_label="Copying…"
        on_confirm="confirm_copy"
        on_cancel="cancel_copy"
        described_by="copy-confirm-body"
        return_focus_id="copy-services"
      >
        <p :if={@target}>
          Every flex service in {@target.name}, and its areas, is copied into this version. This version has no services yet, so nothing is replaced.
        </p>
      </.confirm_dialog>
    </section>
    """
  end

  # The prototype's pointer, shared by the first-use question and the drawer so
  # the two surfaces answer the booked-stops question with the same words.
  defp booked_stops_pointer(assigns) do
    ~H"""
    <p class="mt-3 rounded-card bg-canvas px-3 py-2 text-[13px] text-default">
      <strong class="font-[650]">Stops served only when booked?</strong>
      Request stops and trips that run only when booked go on the route’s timetable, with the boarding choice “Booking required”. On-demand trips between set stops are an area service with a list of stops.
    </p>
    """
  end

  # The summary's own heading: one unanswered question stays singular, so a
  # single missing answer never reads as a list.
  defp summary_lead([_one]), do: "Answer one question to create the service"
  defp summary_lead(errors), do: "Answer #{length(errors)} questions to create the service"

  defp error_for(errors, field_id) do
    Enum.find_value(errors, fn {id, message} -> if id == field_id, do: message end)
  end

  defp error_flag(error_ids, field_id), do: to_string(MapSet.member?(error_ids, field_id))

  @doc """
  Renders the map card, its Leaflet stage and its legend.

  The title names what the hook draws: the version's flex areas under "Where
  flex runs", or only its fixed routes when the version has no service yet. The
  legend follows the reference: every item when flex services are on the map,
  and the fixed route alone when none is.

  `#flex-list-map` is the `FlexAreaMap` hook's root and is `phx-update="ignore"`,
  so the hook owns the stage for the life of the mount; the legend stays outside
  it so the server can word it for the state on screen.
  """
  attr :title, :string, required: true
  attr :legend, :atom, values: [:all, :routes], default: :all

  def list_map_card(assigns) do
    ~H"""
    <section
      aria-labelledby="flex-list-map-title"
      class="self-start overflow-hidden rounded-card border border-subtle bg-white lg:sticky lg:top-4"
    >
      <h2
        id="flex-list-map-title"
        class="border-b border-subtle px-4 py-2.5 text-base font-bold text-strong"
      >
        {@title}
      </h2>
      <div id="flex-list-map" phx-hook="FlexAreaMap" phx-update="ignore">
        <div class="flex-map-stage h-[480px] bg-canvas"></div>
      </div>
      <div
        id="flex-list-map-legend"
        class="flex flex-wrap gap-x-4 gap-y-1 border-t border-subtle px-4 py-2 text-[13px] text-default"
      >
        <span :if={@legend == :all} class="inline-flex items-center gap-1.5">
          <svg width="18" height="12" aria-hidden="true">
            <rect
              x="1"
              y="1"
              width="16"
              height="10"
              fill="#24c7d938"
              stroke="#087b95"
              stroke-width="1.5"
            />
          </svg>
          Flex area
        </span>
        <span class="inline-flex items-center gap-1.5">
          <svg width="22" height="12" aria-hidden="true">
            <path d="M1 6h20" stroke="#fff" stroke-width="6" />
            <path d="M1 6h20" stroke="#0d737d" stroke-width="3" />
          </svg>
          Fixed route
        </span>
        <span :if={@legend == :all} class="inline-flex items-center gap-1.5">
          <svg width="14" height="14" aria-hidden="true">
            <circle cx="7" cy="7" r="5" fill="#fff" stroke="#0a1330" stroke-width="2" />
            <circle cx="7" cy="7" r="2" fill="#0a1330" />
          </svg>
          Connecting stop
        </span>
      </div>
    </section>
    """
  end

  @doc """
  Renders the list's first-paint placeholder.

  The disconnected render shows it, and the connected load replaces it, so a slow
  read never shows an empty list that looks like the version's own answer.
  """
  def loading(assigns) do
    ~H"""
    <div
      id="flex-loading"
      class="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1fr)_440px]"
      aria-busy="true"
    >
      <div class="rounded-card border border-subtle bg-white p-4">
        <.skeleton rows={3} label="Loading flex services…" />
      </div>
      <.list_map_card title="Where flex runs" />
    </div>
    """
  end

  @doc """
  Renders the list's retryable load failure.

  A failed read is never an empty list: the error names what happened, reassures
  the editor that nothing was lost, and offers the one action that retries the
  same load.
  """
  def list_error(assigns) do
    ~H"""
    <div id="flex-list-error" class="mt-6">
      <.message kind="error" title="Couldn’t load flex services.">
        Your services are safe. Check your connection and try again.
        <:action>
          <.button id="flex-list-retry" variant="secondary" phx-click="retry" class="min-h-11">
            <.icon name="hero-arrow-path" class="size-4" /> Try again
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  The map card's title for the state on screen.
  """
  @spec map_title(non_neg_integer()) :: String.t()
  def map_title(0), do: "Fixed routes in this version"
  def map_title(_count), do: "Where flex runs"

  # The reference's two kind illustrations, copied as they are drawn there: a
  # service area with two stops and a route that leaves the line to a booked
  # stop. Decorative, so the button's own words carry the meaning.
  attr :kind, :string, required: true

  defp kind_diagram(%{kind: "area"} = assigns) do
    ~H"""
    <svg width="64" height="48" viewBox="0 0 64 48">
      <path
        d="M8 14 26 5l28 7 4 20-18 12-28-6z"
        fill="#24c7d938"
        stroke="#087b95"
        stroke-width="1.5"
        stroke-dasharray="4 3"
      />
      <circle cx="20" cy="30" r="3" fill="#0a1330" />
      <circle cx="46" cy="18" r="3" fill="#0a1330" />
      <path
        d="M22 28c6-8 14-10 21-10"
        fill="none"
        stroke="#0a1330"
        stroke-width="1.5"
        stroke-dasharray="2 2"
      />
    </svg>
    """
  end

  defp kind_diagram(assigns) do
    ~H"""
    <svg width="64" height="48" viewBox="0 0 64 48">
      <path d="M4 30h56" stroke="#0d737d" stroke-width="3" />
      <circle cx="12" cy="30" r="3" fill="#fff" stroke="#0a1330" stroke-width="1.5" />
      <circle cx="52" cy="30" r="3" fill="#fff" stroke="#0a1330" stroke-width="1.5" />
      <path
        d="M24 30c2-14 14-14 16 0"
        fill="none"
        stroke="#0d737d"
        stroke-width="2"
        stroke-dasharray="3 2"
      />
      <circle cx="32" cy="17" r="3" fill="#0a1330" />
    </svg>
    """
  end

  # The sentence a full export writes for these services (R15, AC-24).
  defp export_sentence(false) do
    "Your flex file is your only feed. It goes to the Transit app and OpenTripPlanner-based trip planners, not to Google."
  end

  defp export_sentence(true) do
    "Exports also write a flex file: your fixed routes plus flex, built and published with your main feed. Apps that show flex load it instead of the main feed, which stays as it is for Google Maps."
  end

  # `Checks.status/2` tones map onto the badge's vocabulary: a ready service
  # reads as success, a problem or suggestion keeps its own tone, and every
  # neutral label (inactive, not in trip planners) uses the neutral treatment.
  defp badge_tone(:success), do: "success"
  defp badge_tone(tone) when tone in [:warning, :error], do: to_string(tone)
  defp badge_tone(_tone), do: "neutral"

  # The row's short booking summary, ported from the prototype's `bookingShort`:
  # how riders book, then the service-wide rule's notice. A calendar-scoped rule
  # belongs to its own trips and stays on the service page.
  defp booking_summary(service) do
    contact = contact_word(service)

    case Enum.find(service.booking_rules, &is_nil(&1.service_id)) do
      nil -> contact
      rule -> contact <> notice_suffix(rule)
    end
  end

  defp contact_word(%FlexService{phone: phone, booking_url: url}) do
    cond do
      Values.present?(phone) and Values.present?(url) -> "Online or call"
      Values.present?(url) -> "Online"
      Values.present?(phone) -> "Call"
      true -> "No contact"
    end
  end

  defp notice_suffix(%FlexBookingRule{when: :now}), do: ", no notice"

  defp notice_suffix(%FlexBookingRule{when: :same_day, minutes: minutes})
       when is_integer(minutes),
       do: ", #{duration_short(minutes)} ahead"

  defp notice_suffix(%FlexBookingRule{when: :earlier_day, days: days, by: by} = rule)
       when is_integer(days) do
    business = if rule.business_days, do: "business ", else: ""
    unit = if days == 1, do: "day", else: "days"
    # Rider-facing wall-clock text, not a service time: RiderText.t12/2 owns it.
    ", by #{RiderText.t12(by, true)}, #{days} #{business}#{unit} ahead"
  end

  defp notice_suffix(%FlexBookingRule{}), do: ""

  defp duration_short(minutes) when minutes >= 60 and rem(minutes, 60) == 0,
    do: "#{div(minutes, 60)} hr"

  defp duration_short(minutes), do: "#{minutes} min"

  # --- the service page (AC-5) -------------------------------------------------

  # The three booking types R7 writes, with the prototype's own words; one is
  # chosen per rule and the chosen one's fields are the ones the editor sees.
  @rule_choices [
    %{
      key: "now",
      label: "Just before the trip",
      help: "Riders book when they are ready to go, usually in an app."
    },
    %{
      key: "same_day",
      label: "Earlier the same day",
      help: "A set number of minutes or hours ahead."
    },
    %{
      key: "earlier_day",
      label: "On an earlier day",
      help: "By a set time, one or more days ahead."
    }
  ]

  # The prototype's default for a phone line with set hours.
  @default_phone_hours %{"days" => "Mon–Fri", "from" => "08:00", "to" => "17:00"}

  @doc """
  Renders the service page's first paint.

  The blank is only ever on screen while the connected mount reads the service,
  and it mirrors the ready page's shape (a form column beside the rider preview)
  so the layout does not jump when the data lands.
  """
  def service_loading(assigns) do
    ~H"""
    <div
      id="flex-service-loading"
      class="mt-6 grid gap-10 xl:grid-cols-[minmax(0,640px)_minmax(0,1fr)]"
      aria-busy="true"
    >
      <div class="rounded-card border border-subtle bg-white p-4">
        <.skeleton rows={6} label="Loading this flex service…" />
      </div>
      <div class="self-start rounded-card border border-subtle bg-white p-4">
        <.skeleton rows={4} label="Loading the rider preview…" />
      </div>
    </div>
    """
  end

  @doc """
  Renders the state for a service this version does not hold: a deleted service,
  a service of another version or organization, or a malformed id. The way back
  is the list, and nothing on the page pretends a service is there.
  """
  attr :version_id, :string, required: true

  def service_not_found(assigns) do
    ~H"""
    <div id="flex-service-not-found" class="mt-6">
      <.message kind="error" title="That flex service isn’t in this version.">
        It may have been deleted, or the link may belong to another version.
        <:action>
          <.button
            id="flex-service-back"
            variant="secondary"
            navigate={~p"/gtfs/#{@version_id}/flex"}
            class="min-h-11"
          >
            Back to Flex
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders the retryable state for a read that lost its database connection.
  """
  def service_unavailable(assigns) do
    ~H"""
    <div id="flex-service-unavailable" class="mt-6">
      <.message kind="error" title="Couldn’t load this flex service.">
        Your service is safe. Check your connection and try again.
        <:action>
          <.button id="flex-service-retry" variant="secondary" phx-click="retry" class="min-h-11">
            <.icon name="hero-arrow-path" class="size-4" /> Try again
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders the service page's header: the way back to Flex, the service's name,
  where it runs and when it last changed, and the readiness badge.

  The badge is `Flex.Checks.status/2` for the draft on screen, so it reports what
  a save would publish rather than what the last save stored. The two rare
  actions share one menu, the account menu's client-side dropdown (`UserMenu`),
  which the server never re-renders: `phx-update="ignore"` keeps an open panel
  open across patches.
  """
  attr :service, :any, required: true
  attr :status, :any, required: true
  attr :version_id, :string, required: true

  def service_header(assigns) do
    assigns = assign(assigns, :updated, updated_line(assigns.service))

    ~H"""
    <div>
      <.back_link id="flex-service-back-link" navigate={~p"/gtfs/#{@version_id}/flex"}>
        Flex
      </.back_link>

      <.header>
        <span id="svc-title" tabindex="-1" class="outline-none">{@service.name}</span>
        <:subtitle>{RiderText.where_line(@service)} · {@updated}</:subtitle>
        <:actions>
          <.badge id="svc-status" tone={badge_tone(@status.tone)} label={@status.label} />

          <div id="more-menu" phx-hook="UserMenu" phx-update="ignore" class="relative">
            <button
              type="button"
              id="more-menu-trigger"
              data-user-menu-trigger
              aria-haspopup="menu"
              aria-expanded="false"
              aria-controls="more-menu-panel"
              class={[
                "inline-flex min-h-11 items-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas",
                focus_ring()
              ]}
            >
              <.icon name="hero-ellipsis-horizontal" class="size-4" /> More actions
            </button>
            <div
              id="more-menu-panel"
              data-user-menu-panel
              role="menu"
              aria-label="More actions"
              hidden
              class="absolute right-0 top-full z-30 mt-2 w-64 rounded-card border border-subtle bg-white p-2 shadow-float"
            >
              <button
                type="button"
                id="menu-export-details"
                role="menuitem"
                phx-click={close_more_menu(JS.push("show_export_details"))}
                class={[
                  "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-strong hover:bg-canvas focus:bg-canvas",
                  focus_ring()
                ]}
              >
                Show export details
              </button>
              <div class="my-1 border-t border-subtle"></div>
              <button
                type="button"
                id="menu-goto-status"
                role="menuitem"
                phx-click={close_more_menu(JS.push("goto_status"))}
                class={[
                  "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-strong hover:bg-canvas focus:bg-canvas",
                  focus_ring()
                ]}
              >
                Deactivate or delete…
              </button>
            </div>
          </div>
        </:actions>
      </.header>
    </div>
    """
  end

  # The hook opens and closes the panel through `hidden` and `aria-expanded`;
  # choosing an item does the same, so the panel is not left open behind the
  # drawer or the scroll the choice starts.
  defp close_more_menu(js) do
    js
    |> JS.set_attribute({"hidden", ""}, to: "#more-menu-panel")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#more-menu-trigger")
  end

  @doc """
  Renders the page-level error summary a failed save shows (AC-5).

  Every item links to the control that caused it, so the editor can jump from
  the summary to the field; the page moves focus to the summary when it appears.
  """
  attr :errors, :list, required: true

  def service_error_summary(assigns) do
    assigns =
      assign(
        assigns,
        :failures,
        Enum.map(assigns.errors, fn {field_id, message} ->
          %{href: "##{field_id}", msg: message}
        end)
      )

    ~H"""
    <.form_error_summary
      id="flex-service-error-summary"
      title={save_lead(@errors)}
      failures={@failures}
      class=""
    />
    """
  end

  @doc """
  Renders the "When it runs" section (R6).

  One row per hours window: the area it is scoped to when the service has more
  than one, the calendar, and its start and end. Under each row the calendar's
  own days, dates and exceptions, and the row's own window, so the editor sees
  what a next-day or long window means before saving. Below the rows, the week
  strip and the next days without service name the same facts the rider preview
  words.
  """
  attr :form, :any, required: true
  attr :service, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :calendars, :map, required: true
  attr :calendar_rows, :map, required: true
  attr :calendar_options, :list, required: true
  attr :trip_counts, :map, default: %{}
  attr :version_id, :string, required: true
  attr :today, :any, required: true
  attr :checks, :list, required: true

  def when_section(assigns) do
    assigns =
      assigns
      |> assign(:findings, section_findings(assigns.checks, :when))
      |> assign(:days, week_strip(assigns.service, assigns.calendar_rows))
      |> assign(
        :exceptions,
        upcoming_exceptions(assigns.service, assigns.calendar_rows, assigns.today)
      )
      |> assign(:multi_area?, length(assigns.service.areas) > 1)
      |> assign(:area_options, area_options(assigns.service))
      |> assign(:area?, assigns.service.kind == :area)
      |> assign(
        :title,
        if(assigns.service.kind == :area, do: "When it runs", else: "Which trips offer detours")
      )
      |> assign(:help, when_help(assigns.service))

    ~H"""
    <section id="sec-when" aria-labelledby="when-title" class="min-w-0 border-t border-subtle pt-5">
      <h2 id="when-title" class="text-base font-bold text-strong">{@title}</h2>
      <p class="mt-1 text-sm text-muted">{@help}</p>

      <div :if={@area?} id="f-hours" tabindex="-1" class="mt-3 grid gap-3 outline-none">
        <.inputs_for :let={hour} field={@form[:hours]}>
          <.hours_row
            hour={hour}
            field_errors={@field_errors}
            multi_area?={@multi_area?}
            area_options={@area_options}
            calendar_options={@calendar_options}
            calendar_rows={@calendar_rows}
          />
        </.inputs_for>
      </div>

      <button
        :if={@area?}
        id="add-hours"
        type="button"
        phx-click="add_hours"
        class={[
          "mt-2 inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action hover:underline",
          focus_ring()
        ]}
      >
        <.icon name="hero-plus" class="size-4" /> Add hours
      </button>

      <div :if={@area?} id="week-strip" class="mt-2">
        <.week_strip days={@days} />
      </div>

      <p :if={@exceptions != []} id="service-exceptions" class="mt-2 text-[13px] text-default">
        <span class="font-[650]">Next days without service:</span>
        <span class="tabular-nums">{Enum.join(@exceptions, ", ")}</span>
        ·
        <.link
          href={~p"/gtfs/#{@version_id}/calendars"}
          class="font-[650] text-action hover:underline"
        >
          Change in Calendars
        </.link>
      </p>

      <.detour_trips_section
        :if={not @area?}
        form={@form}
        service={@service}
        field_errors={@field_errors}
        calendar_options={@calendar_options}
        trip_counts={@trip_counts}
      />

      <.section_findings findings={@findings} />
    </section>
    """
  end

  # What one hours editor's words are per kind: an area service has hours riders
  # travel in, and a detour service's classes follow the trips it is allowed on
  # (step 23 renders those controls).
  @doc """
  Renders the "How riders book" section (R7) with the generated text preview.

  The three booking choices are the rule's `when`; only the chosen one's fields
  are rendered (the prototype's behaviour), so the editor sees one set of
  answers at a time. An area service may add one rule for one of its calendars.
  The contact block and the note follow, and the preview under them is the same
  `RiderText` the export writes.
  """
  attr :form, :any, required: true
  attr :service, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :calendars, :map, required: true
  attr :calendar_options, :list, required: true
  attr :checks, :list, required: true

  def booking_section(assigns) do
    assigns =
      assigns
      |> assign(:choices, @rule_choices)
      |> assign(:findings, section_findings(assigns.checks, :booking))
      |> assign(:phone_hours, assigns.service.phone_hours || @default_phone_hours)
      |> assign(
        :text_length,
        assigns.service |> RiderText.message(assigns.calendars) |> String.length()
      )

    ~H"""
    <section
      id="sec-booking"
      aria-labelledby="booking-title"
      class="min-w-0 border-t border-subtle pt-5"
    >
      <h2 id="booking-title" class="text-base font-bold text-strong">How riders book</h2>

      <fieldset class="mt-3">
        <legend class="text-sm font-[650] text-strong">When riders must book</legend>

        <.inputs_for :let={rule} field={@form[:booking_rules]}>
          <.rule_card
            :if={rule.index == 0}
            rule={rule}
            choices={@choices}
            field_errors={@field_errors}
            calendars={@calendars}
            calendar_options={@calendar_options}
          />
          <.scoped_rule_card
            :if={rule.index != 0}
            rule={rule}
            field_errors={@field_errors}
            calendars={@calendars}
            calendar_options={@calendar_options}
          />
        </.inputs_for>
      </fieldset>

      <button
        :if={@service.kind == :area}
        id="add-scoped-rule"
        type="button"
        phx-click="add_scoped_rule"
        class={[
          "mt-2 inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action hover:underline",
          focus_ring()
        ]}
      >
        <.icon name="hero-plus" class="size-4" /> Add rule for some days
      </button>

      <p :if={@service.kind == :detour} class="mt-2 text-[13px] text-muted">
        Detours use the route’s own trips, so there is one rule for all of them. Put day-specific exceptions in the note.
      </p>

      <div id="f-contact" tabindex="-1" class="mt-4 grid gap-3 outline-none sm:grid-cols-2">
        <.input
          field={@form[:phone]}
          type="tel"
          label="Booking phone"
          autocomplete="off"
          help="Filled in from your agency in Settings › Agencies"
          errors={errors_for(@field_errors, @form[:phone])}
        />
        <.input
          field={@form[:booking_url]}
          type="url"
          label="Booking link (optional)"
          autocomplete="off"
          spellcheck="false"
          placeholder="https://"
          help="A web page or app link where riders book"
          errors={errors_for(@field_errors, @form[:booking_url])}
        />

        <div class="sm:col-span-2">
          <.input
            type="checkbox"
            id="phone-hours-on"
            name="service[phone_hours_on]"
            checked={@service.phone_hours != nil}
            label="The phone line has set hours"
          />

          <div
            :if={@service.phone_hours != nil}
            class="mt-1 flex min-w-0 flex-wrap items-end gap-2 pl-7"
          >
            <.input
              type="select"
              id="phone-hours-days"
              name="service[phone_hours][days]"
              value={@phone_hours["days"]}
              label="Days"
              options={["Mon–Fri", "Mon–Sat", "Every day"]}
              class="select select-lg w-40 min-w-0"
            />
            <.input
              type="time"
              id="phone-hours-from"
              name="service[phone_hours][from]"
              value={@phone_hours["from"]}
              label="From"
              class="input input-lg w-36 min-w-0"
            />
            <.input
              type="time"
              id="phone-hours-to"
              name="service[phone_hours][to]"
              value={@phone_hours["to"]}
              label="To"
              class="input input-lg w-36 min-w-0"
            />
          </div>
        </div>

        <div class="sm:col-span-2">
          <.input
            field={@form[:info_url]}
            type="url"
            label="Fares and details page (optional)"
            autocomplete="off"
            spellcheck="false"
            placeholder="https://"
            errors={errors_for(@field_errors, @form[:info_url])}
          />
        </div>
      </div>

      <div id="booking-preview" class="mt-4 rounded-card bg-canvas px-4 py-3">
        <.booking_preview service={@service} calendars={@calendars} />
      </div>

      <div class="mt-4">
        <.input
          field={@form[:note]}
          type="textarea"
          rows="3"
          label="Extra note for riders (optional)"
          help="Only what the rule can’t say, for example “Tell the dispatcher if you use a wheelchair.”"
          errors={errors_for(@field_errors, @form[:note])}
        />
        <p
          id="note-count"
          class={[
            "text-[13px] tabular-nums",
            if(@text_length > 250, do: "font-[650] text-warning-fg", else: "text-muted")
          ]}
        >
          Text riders read: {@text_length} of about 250 characters
        </p>
      </div>

      <.section_findings findings={@findings} />
    </section>
    """
  end

  @doc """
  Renders the rider preview: the card a rider sees in a trip planner, built
  only from the draft and the same `RiderText` the export writes.
  """
  attr :service, :any, required: true
  attr :calendars, :map, required: true

  def rider_preview(assigns) do
    assigns =
      assigns
      |> assign(:name, RiderText.rider_name(assigns.service))
      |> assign(:where, RiderText.where_line(assigns.service))
      |> assign(
        :hours_lines,
        RiderText.hours_lines(assigns.service, assigns.service.areas, assigns.calendars)
      )
      |> assign(:message, RiderText.message(assigns.service, assigns.calendars))
      |> assign(:drop_off, RiderText.drop_off_message(assigns.service))

    ~H"""
    <div id="rider-preview">
      <p :if={not @service.active} class="text-sm text-muted">
        Inactive services don’t reach trip planners.
      </p>
      <p
        :if={@service.active and @service.riders == :registered and not @service.include_registered}
        class="text-sm text-muted"
      >
        Left out of the flex feed, so trip planners don’t show it. Riders reach it through your website and phone line.
      </p>

      <article
        :if={@service.active}
        class="rounded-card border border-subtle bg-white p-4 shadow-card"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class="inline-flex min-h-6 items-center rounded-badge bg-info-bg px-2 text-[12px] font-[650] text-info-fg">
            On-demand
          </span>
          <span class="font-[650] text-strong">{@name}</span>
        </div>

        <p class="mt-2 text-sm">{@where}</p>

        <p class="mt-1 text-sm tabular-nums text-default">
          <span :for={line <- @hours_lines} class="block">{line}</span>
        </p>

        <p :if={@message != ""} class="mt-2 text-sm text-strong">{@message}</p>
        <p :if={@drop_off} class="mt-1 text-sm text-default">{@drop_off}</p>

        <div class="mt-3 flex flex-wrap gap-2">
          <span
            :if={Values.present?(@service.phone)}
            class="inline-flex min-h-9 items-center gap-1.5 rounded-control border border-control px-3 text-sm font-[650] text-strong"
          >
            <.icon name="hero-phone" class="size-4" /> Call {@service.phone}
          </span>
          <span
            :if={Values.present?(@service.booking_url)}
            class="inline-flex min-h-9 items-center gap-1.5 rounded-control border border-control px-3 text-sm font-[650] text-strong"
          >
            <.icon name="hero-link" class="size-4" /> Book online
          </span>
          <span
            :if={Values.present?(@service.info_url)}
            class="inline-flex min-h-9 items-center text-sm font-[650] text-action"
          >
            More information
          </span>
        </div>
      </article>

      <p class="mt-3 text-[13px] text-muted">
        Google Maps doesn’t accept flex data. Trip planners show fixed routes first when both work.{if @service.kind ==
                                                                                                         :detour,
                                                                                                       do:
                                                                                                         " Some detour trips are listed twice."}
      </p>
    </div>
    """
  end

  @doc """
  Renders the booking preview: the text riders read and how three trip planners
  word the same rule, from `RiderText.message/2` and
  `RiderText.app_renderings/1`.
  """
  attr :service, :any, required: true
  attr :calendars, :map, required: true

  def booking_preview(assigns) do
    assigns =
      assigns
      |> assign(:message, RiderText.message(assigns.service, assigns.calendars))
      |> assign(:renderings, app_renderings(assigns.service))

    ~H"""
    <p class="text-sm font-[650] text-strong">Text riders read</p>
    <p class="mt-0.5 text-sm text-strong">
      <span :if={@message == ""} class="text-muted">Nothing yet</span>{@message}
    </p>
    <p class="mt-1 text-[13px] text-muted">
      Written from the rule first, then how to book, then your note, so the text and the rule always agree.
    </p>

    <p class="mt-3 text-sm font-[650] text-strong">How apps show the booking rule</p>
    <p :if={@renderings == []} class="mt-1 text-[13px] text-muted">
      Choose when riders must book to see how trip planners word it.
    </p>
    <dl :if={@renderings != []} class="mt-1 grid gap-1.5 text-[13px]">
      <div :for={{app, line, note} <- @renderings} class="grid gap-2 sm:grid-cols-[168px_1fr]">
        <dt class="text-muted">{app}</dt>
        <dd>
          <span class="font-[650] text-strong">{line}</span>
          <span class="block text-muted">{note}</span>
        </dd>
      </div>
    </dl>
    """
  end

  @doc """
  Renders the save bar: what a save would change, in rider terms, and the one
  Save (AC-5). The bar is only on screen while the draft differs from the saved
  service.
  """
  attr :service, :any, required: true
  attr :saved, :any, required: true
  attr :calendars, :map, required: true
  attr :saving, :boolean, default: false

  def save_bar(assigns) do
    changes = RiderText.changes(assigns.saved, assigns.service, assigns.calendars)
    assigns = assign(assigns, :changes, changes)

    ~H"""
    <div
      id="save-bar"
      class="fixed inset-x-0 bottom-0 z-40 border-t border-subtle bg-white shadow-float"
    >
      <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 px-4 py-3 sm:px-6 lg:px-8">
        <div class="min-w-0 text-sm text-strong">
          <p class="flex items-center gap-2 font-[650]">
            <.icon name="hero-information-circle" class="size-4 text-info-fg" />
            {save_bar_lead(@changes, @service.name)}
          </p>
          <ul
            :if={@changes != []}
            class="mt-0.5 flex flex-wrap gap-x-4 pl-6 text-[13px] text-default"
          >
            <li :for={change <- Enum.take(@changes, 3)} class="tabular-nums">{change}</li>
            <li :if={length(@changes) > 3} class="text-muted">
              and {length(@changes) - 3} more
            </li>
          </ul>
        </div>

        <div class="flex flex-wrap gap-3">
          <.button
            id="discard-changes"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="discard_changes"
          >
            Discard changes
          </.button>
          <.button
            id="save-btn"
            type="submit"
            form="flex-service-form"
            variant="primary"
            class="min-h-11"
            disabled={@saving}
            phx-disable-with="Saving…"
          >
            Save changes
          </.button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the service page's map card.

  The card is the `FlexAreaMap` hook's root (`#flex-service-map`,
  `phx-update="ignore"`), and the service page answers the hook's
  `flex_map_ready` with the service's own payload: its areas (or detour zones)
  selected and the other active services' areas muted.
  """
  attr :service, :any, required: true

  def service_map_card(assigns) do
    assigns =
      assign(
        assigns,
        :title,
        if(assigns.service.kind == :detour, do: "Detour area", else: "Service area")
      )

    ~H"""
    <section
      aria-labelledby="flex-service-map-title"
      class="self-start overflow-hidden rounded-card border border-subtle bg-white xl:sticky xl:top-4"
    >
      <h2
        id="flex-service-map-title"
        class="border-b border-subtle px-4 py-2.5 text-base font-bold text-strong"
      >
        {@title}
      </h2>
      <div id="flex-service-map" phx-hook="FlexAreaMap" phx-update="ignore">
        <div class="flex-map-stage h-[320px] bg-canvas"></div>
      </div>
      <div
        id="flex-service-map-legend"
        class="flex flex-wrap gap-x-4 gap-y-1 border-t border-subtle px-4 py-2 text-[13px] text-default"
      >
        <span class="inline-flex items-center gap-1.5">
          <svg width="18" height="12" aria-hidden="true">
            <rect
              x="1"
              y="1"
              width="16"
              height="10"
              fill="#24c7d938"
              stroke="#087b95"
              stroke-width="1.5"
            />
          </svg>
          Flex area
        </span>
        <span class="inline-flex items-center gap-1.5">
          <svg width="22" height="12" aria-hidden="true">
            <path d="M1 6h20" stroke="#fff" stroke-width="6" />
            <path d="M1 6h20" stroke="#0d737d" stroke-width="3" />
          </svg>
          Fixed route
        </span>
        <span class="inline-flex items-center gap-1.5">
          <svg width="14" height="14" aria-hidden="true">
            <circle cx="7" cy="7" r="5" fill="#fff" stroke="#0a1330" stroke-width="2" />
            <circle cx="7" cy="7" r="2" fill="#0a1330" />
          </svg>
          Connecting stop
        </span>
      </div>
    </section>
    """
  end

  @doc """
  Renders the area service's "Where riders can travel" section (AC-7, AC-29).

  Each stored area is summarised with its rider-facing name, how it was chosen,
  the size and stops `Flex.Geometry.stats/3` measures, and the way into the area
  editor. Below the list, "Add another area" patches to the same editor, and
  the connecting stops are chips with a stop select; adding or removing one
  changes the draft only, like every other answer on this page.
  """
  attr :service, :any, required: true
  attr :area_summaries, :list, required: true
  attr :stop_choices, :list, required: true
  attr :hub_options, :list, required: true
  attr :hub_pick, :any, default: nil
  attr :checks, :list, required: true

  def where_area_section(assigns) do
    assigns =
      assigns
      |> assign(:findings, section_findings(assigns.checks, :where))
      |> assign(:hubs, assigns.service.hub_stop_ids)

    ~H"""
    <section
      id="sec-where"
      aria-labelledby="where-title"
      class="min-w-0 border-t border-subtle pt-5"
    >
      <h2 id="where-title" class="text-base font-bold text-strong">Where riders can travel</h2>

      <ul :if={@area_summaries != []} id="f-area" tabindex="-1" class="mt-3 grid gap-2 outline-none">
        <li
          :for={summary <- @area_summaries}
          id={"f-area-#{summary.area.key}"}
          class="flex flex-wrap items-start justify-between gap-3 rounded-card border border-subtle px-4 py-3"
        >
          <div class="min-w-0">
            <p class="font-[650] text-strong">{summary.area.name}</p>
            <p class="text-[13px] text-muted">
              {source_line(summary.area)} · <span class="tabular-nums">{area_size(summary.km2)}</span>
            </p>
            <p class="mt-0.5 text-[13px] text-muted">Inside: {inside_line(summary)}</p>
          </div>
          <.button
            id={"edit-area-#{summary.area.key}"}
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="edit_area"
            phx-value-key={summary.area.key}
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit area
          </.button>
        </li>
      </ul>

      <div
        :if={@area_summaries == []}
        id="f-area"
        tabindex="-1"
        class="mt-3 rounded-card border border-dashed border-control px-4 py-4 outline-none"
      >
        <p class="text-sm text-strong">
          No area yet. Start from town limits, a distance from routes, a drawing or a file from your provider.
        </p>
        <.button
          id="add-area"
          type="button"
          variant="secondary"
          class="mt-3 min-h-11"
          phx-click="add_area"
        >
          <.icon name="hero-plus" class="size-4" /> Add area
        </.button>
      </div>

      <button
        :if={@area_summaries != []}
        id="add-area"
        type="button"
        phx-click="add_area"
        class={[
          "mt-2 inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action hover:underline",
          focus_ring()
        ]}
      >
        <.icon name="hero-plus" class="size-4" /> Add another area
      </button>

      <div class="mt-4">
        <p class="text-[13px] font-[650] text-default">
          Connecting stops <span class="font-normal text-muted">(optional)</span>
        </p>
        <p class="text-[13px] text-muted">
          Riders can also book a ride between the area and these stops, for example to catch a fixed route.
        </p>
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <span
            :for={stop_id <- @hubs}
            id={"hub-#{stop_id}"}
            class="inline-flex min-h-9 items-center gap-1 rounded-badge border border-subtle bg-canvas pl-2.5 text-sm text-strong"
          >
            {hub_name(@stop_choices, stop_id)}
            <button
              type="button"
              id={"remove-hub-#{stop_id}"}
              phx-click="remove_hub"
              phx-value-stop-id={stop_id}
              aria-label={"Remove #{hub_name(@stop_choices, stop_id)}"}
              title="Remove"
              class={[
                "inline-flex min-h-9 min-w-9 items-center justify-center rounded-badge text-muted hover:bg-white hover:text-strong",
                focus_ring()
              ]}
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </span>

          <span :if={@hub_options != []} class="inline-flex flex-wrap items-start gap-2">
            <.input
              type="select"
              id="hub-stop"
              name="hub_stop"
              value={@hub_pick}
              options={@hub_options}
              phx-change="pick_hub"
              aria-label="Stop to add"
              class="select w-56 min-w-0"
            />
            <.button
              id="add-hub"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="add_hub"
            >
              Add stop
            </.button>
          </span>
        </div>
      </div>

      <.section_findings findings={@findings} />
    </section>
    """
  end

  @doc """
  Renders the detour service's "Where the bus can detour" section (AC-29).

  Every field AC-29 names is here: the published distance with no default, who
  can ask for a detour, the timetable wording, what the distance is measured
  from, the stretch's first and last stop, how riders use detours, and the
  derived zone count and size `Flex.Geometry.detour_zones/3` measures. The route
  itself was chosen when the service was created, so it is stated rather than
  offered again.
  """
  attr :form, :any, required: true
  attr :service, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :route_stop_choices, :list, required: true
  attr :plan, :any, required: true
  attr :checks, :list, required: true

  def where_detour_section(assigns) do
    assigns =
      assigns
      |> assign(:findings, section_findings(assigns.checks, :where))
      |> assign(:zone_count, length(assigns.plan.zones))
      |> assign(:zone_km2, zone_km2(assigns.plan.zones))
      |> assign(:distance_choices, @distance_choices)

    ~H"""
    <section
      id="sec-where"
      aria-labelledby="where-title"
      class="min-w-0 border-t border-subtle pt-5"
    >
      <h2 id="where-title" class="text-base font-bold text-strong">Where the bus can detour</h2>

      <div class="mt-3 grid min-w-0 gap-4 sm:grid-cols-2">
        <div class="min-w-0">
          <p class="text-[13px] font-[650] text-default">Route</p>
          <p id="f-route" class="mt-1 text-sm text-strong">Route {@service.route_id}</p>
          <p class="mt-1 text-[13px] text-muted">
            Chosen when the service was created; its stops and trips live in Routes.
          </p>
        </div>

        <.input
          field={@form[:distance_m]}
          type="select"
          id="f-distance"
          label="Detours up to"
          prompt="Choose the distance you publish"
          options={@distance_choices}
          errors={control_errors(@field_errors, "f-distance")}
        />
      </div>
      <p class="-mt-2 text-[13px] text-muted">
        No default: agencies publish anything from a few blocks to a mile. Most publish ¾ mile.
      </p>

      <fieldset class="mt-4">
        <legend class="text-[13px] font-[650] text-default">Who can ask for a detour</legend>
        <div class="mt-1 grid gap-2 sm:grid-cols-2">
          <.choice_radio
            id="ada-only-no"
            group={@form[:ada_only].name}
            value="false"
            checked={to_string(@form[:ada_only].value) != "true"}
            label="Any rider"
            help=""
          />
          <.choice_radio
            id="ada-only-yes"
            group={@form[:ada_only].name}
            value="true"
            checked={to_string(@form[:ada_only].value) == "true"}
            label="ADA-eligible riders only"
            help="Detours replace paratransit here, so ¾ mile is the minimum."
          />
        </div>
      </fieldset>

      <div class="mt-4 [&_.label]:whitespace-normal">
        <.input
          field={@form[:wording]}
          id="f-wording"
          label="How your timetable and website describe it"
          placeholder="For example, up to ¾ mile from the route"
          help="Riders read these words in trip planners, so they match what you already publish."
          errors={control_errors(@field_errors, "f-wording")}
        />
      </div>

      <fieldset class="mt-4">
        <legend class="text-[13px] font-[650] text-default">Measured from</legend>
        <div class="mt-1 grid gap-2 sm:grid-cols-2">
          <.choice_radio
            id="measure-route"
            group={@form[:measure].name}
            value="route"
            checked={to_string(@form[:measure].value) == "route"}
            label="The route between stops"
            help="One area for each stretch between stops."
          />
          <.choice_radio
            id="measure-stops"
            group={@form[:measure].name}
            value="stops"
            checked={to_string(@form[:measure].value) == "stops"}
            label="Each stop"
            help="Riders board or leave near a stop, as on some call-ahead evening buses."
          />
        </div>
      </fieldset>

      <fieldset class="mt-4">
        <legend class="text-[13px] font-[650] text-default">Stretch of the route with detours</legend>
        <div class="mt-1 grid items-end gap-2 sm:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)]">
          <.input
            field={@form[:first_stop_id]}
            type="select"
            id="f-first"
            label="First stop"
            prompt="Choose a stop"
            options={@route_stop_choices}
            errors={control_errors(@field_errors, "f-first")}
          />
          <span class="pb-3 text-sm text-muted">to</span>
          <.input
            field={@form[:last_stop_id]}
            type="select"
            id="f-last"
            label="Last stop"
            prompt="Choose a stop"
            options={@route_stop_choices}
            errors={control_errors(@field_errors, "f-last")}
          />
        </div>
      </fieldset>

      <p id="where-summary" class="mt-2 text-sm">
        {@zone_count} detour {if @zone_count == 1, do: "area", else: "areas"}{measure_summary(
          @service
        )}. A rider can be picked up or dropped off between the scheduled times of the stops on either side.
        <span :if={@zone_km2} class="tabular-nums text-muted">{@zone_km2} km² in all.</span>
      </p>

      <fieldset class="mt-4">
        <legend class="text-[13px] font-[650] text-default">How riders use detours</legend>
        <div class="mt-1 grid gap-2">
          <.choice_radio
            id="dropoffs-tell-driver"
            group={@form[:dropoffs].name}
            value="tell_driver"
            checked={to_string(@form[:dropoffs].value) == "tell_driver"}
            label="Call ahead for a pickup; tell the driver where to get off"
            help="The most common policy in published feeds."
          />
          <.choice_radio
            id="dropoffs-book"
            group={@form[:dropoffs].name}
            value="book"
            checked={to_string(@form[:dropoffs].value) == "book"}
            label="Call ahead for pickups and drop-offs"
            help="The same booking rule applies to both."
          />
          <.choice_radio
            id="dropoffs-dropoff-only"
            group={@form[:dropoffs].name}
            value="dropoff_only"
            checked={to_string(@form[:dropoffs].value) == "dropoff_only"}
            label="Drop-offs only: tell the driver when boarding"
            help="No pickups away from the route, and no call needed."
          />
        </div>
      </fieldset>

      <.section_findings findings={@findings} />
    </section>
    """
  end

  @doc """
  Renders a detour service's "Which trips offer detours" controls (R6).

  The calendar checkboxes are the trips the detour service covers; a calendar
  with no trips on the route is disabled and its count is stated, the way the
  reference does. The time of day either keeps every trip or a band, whose two
  times are the window a trip's departure must fall in.
  """
  attr :form, :any, required: true
  attr :service, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :calendar_options, :list, required: true
  attr :trip_counts, :map, default: %{}

  def detour_trips_section(assigns) do
    assigns = assign(assigns, :band_on, band_on?(assigns.service))

    ~H"""
    <fieldset id="f-detour-calendars" tabindex="-1" class="mt-3 grid gap-2 outline-none">
      <legend class="sr-only">Calendars</legend>
      <label
        :for={{label, service_id} <- @calendar_options}
        class={[
          "flex min-h-11 cursor-pointer items-center gap-3 rounded-card border border-subtle px-3 py-2",
          card_focus()
        ]}
      >
        <input
          type="checkbox"
          id={"detour-calendar-#{service_id}"}
          name="service[calendar_service_ids][]"
          value={service_id}
          checked={service_id in @service.calendar_service_ids}
          disabled={Map.get(@trip_counts, service_id, 0) == 0}
          class="size-4 accent-[var(--color-action)]"
        />
        <span class="text-sm">
          <span class="font-[650] text-strong">{label}</span>
          <span class="text-muted">
            · {trip_count_label(Map.get(@trip_counts, service_id, 0), @service.route_id)}
          </span>
        </span>
      </label>
    </fieldset>

    <fieldset class="mt-4">
      <legend class="text-[13px] font-[650] text-default">Time of day</legend>
      <div class="mt-1 grid gap-2">
        <.choice_radio
          id="band-all"
          group="service[band_mode]"
          value="all"
          checked={not @band_on}
          label="All day"
          help=""
        />
        <.choice_radio
          id="band-certain"
          group="service[band_mode]"
          value="band"
          checked={@band_on}
          label="Only at certain times"
          help="Outside these times the bus keeps to its route. The FTA then treats it as a fixed route, so paratransit rules apply."
        />

        <div :if={@band_on} class="grid max-w-sm grid-cols-2 gap-2">
          <.input
            field={@form[:band_start]}
            type="time"
            label="From"
            class="input input-lg tabular-nums"
            errors={errors_for(@field_errors, @form[:band_start])}
          />
          <.input
            field={@form[:band_end]}
            type="time"
            label="To"
            class="input input-lg tabular-nums"
            errors={errors_for(@field_errors, @form[:band_end])}
          />
        </div>
      </div>
    </fieldset>
    """
  end

  @doc """
  Renders the "Who can ride" section (AC-29, R5).

  The two rider choices, and, for a registered-riders service, the eligibility
  wording, the prototype's ADA preset, and whether trip planners show it at
  all. The qualified name the preset's own wording produces is stated before the
  editor saves, so the name riders meet is never a surprise.
  """
  attr :form, :any, required: true
  attr :service, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :checks, :list, required: true

  def riders_section(assigns) do
    assigns = assign(assigns, :findings, section_findings(assigns.checks, :riders))

    ~H"""
    <section
      id="sec-riders"
      aria-labelledby="riders-title"
      class="min-w-0 border-t border-subtle pt-5"
    >
      <h2 id="riders-title" class="text-base font-bold text-strong">Who can ride</h2>

      <div class="mt-3 grid gap-2">
        <.choice_radio
          id="riders-anyone"
          group={@form[:riders].name}
          value="anyone"
          checked={to_string(@form[:riders].value) == "anyone"}
          label="Anyone"
          help=""
        />
        <.choice_radio
          id="riders-registered"
          group={@form[:riders].name}
          value="registered"
          checked={to_string(@form[:riders].value) == "registered"}
          label="Registered riders only"
          help="For example, older adults or riders with disabilities who have signed up."
        />
      </div>

      <div :if={@service.riders == :registered} class="mt-2 grid gap-3">
        <.input
          field={@form[:eligibility]}
          id="f-eligibility"
          label="Who can register"
          autocomplete="off"
          placeholder="Adults 60 and older and riders with disabilities"
          errors={control_errors(@field_errors, "f-eligibility")}
        />

        <button
          type="button"
          id="ada-preset"
          phx-click="ada_preset"
          class={[
            "-mt-2 inline-flex min-h-11 items-center gap-1 justify-self-start text-sm font-[650] text-action hover:underline",
            focus_ring()
          ]}
        >
          Use ADA defaults
        </button>

        <fieldset>
          <legend class="text-[13px] font-[650] text-default">In trip planners</legend>
          <div class="mt-1 grid gap-1">
            <.choice_radio
              id="publish-no"
              group={@form[:include_registered].name}
              value="false"
              checked={not @service.include_registered}
              label="Leave it out of the flex feed (default)"
              help="No trip planner can check who is registered."
            />
            <.choice_radio
              id="publish-yes"
              group={@form[:include_registered].name}
              value="true"
              checked={@service.include_registered}
              label="Show it, starting with who can ride"
              help="Needs a page with fares and details. The name says who it’s for."
            />
          </div>
        </fieldset>

        <p :if={@service.include_registered} id="rider-name" class="text-sm">
          Trip planners show it as <strong class="font-[650] text-strong">{RiderText.rider_name(@service)}</strong>.
        </p>
      </div>

      <.section_findings findings={@findings} />
    </section>
    """
  end

  @doc """
  Renders the "In exports" section (AC-29, AC-15).

  The headline is the export plan's own words for what the next export writes,
  with the prototype's reasons a service is left out; under it, where the flex
  file goes, the organization's realtime answer with its warning when the
  vendor reads its own schedule file, and the R3 note a detour service owes its
  route. The answer is organization-wide and saved the moment it is chosen, so
  the select never joins the page's own draft.
  """
  attr :service, :any, required: true
  attr :plan, :any, required: true
  attr :export_defaults, :any, required: true
  attr :status, :any, required: true

  def exports_section(assigns) do
    assigns =
      assigns
      |> assign(:headline, export_headline(assigns.service, assigns.plan, assigns.status))
      |> assign(:destination, destination_line(assigns.export_defaults))
      |> assign(:realtime_options, @realtime_options)
      |> assign(
        :realtime_note,
        realtime_note(assigns.export_defaults.realtime_source, assigns.service.route_id)
      )

    ~H"""
    <section
      id="sec-export"
      aria-labelledby="export-title"
      class="min-w-0 border-t border-subtle pt-5"
    >
      <h2 id="export-title" class="text-base font-bold text-strong">In exports</h2>

      <p id="export-summary" class="mt-2 text-sm text-strong">{@headline}</p>
      <p class="mt-1 text-[13px] text-muted">{@destination}</p>

      <div :if={@service.kind == :detour} class="mt-4">
        <div class="max-w-xs">
          <.input
            type="select"
            id="f-realtime"
            name="realtime_source"
            value={to_string(@export_defaults.realtime_source)}
            label="Which file does your realtime vendor read?"
            options={@realtime_options}
            phx-change="set_realtime"
          />
        </div>

        <.realtime_note_card :if={@realtime_note} note={@realtime_note} />

        <p class="mt-1 text-[13px] text-muted">
          One answer for your agency; it applies to every route.
        </p>
      </div>

      <p :if={@service.kind == :detour} id="export-r3-note" class="mt-3 text-[13px] text-muted">
        Each Route {@service.route_id} trip is exported once, with the detour stops placed between its fixed stops. The route stays a bus route.
      </p>

      <button
        type="button"
        id="export-details-button"
        phx-click="show_export_details"
        class={[
          "mt-3 inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action hover:underline",
          focus_ring()
        ]}
      >
        Show export details
      </button>
    </section>
    """
  end

  @doc """
  Renders the export-details drawer (AC-29).

  The plan's headline, the counts per file, and every planned row with its R11
  ID and what it holds — the same rows the export's own builders produce, so
  staff and data users read one preview rather than two. The detour rows'
  warnings are listed too, because the export run would report them.
  """
  attr :open, :boolean, required: true
  attr :service, :any, required: true
  attr :plan, :any, required: true
  attr :export_defaults, :any, required: true

  def export_details_drawer(assigns) do
    assigns =
      assigns
      |> assign(:notes, plan_notes(assigns.service, assigns.plan))
      |> assign(:included?, assigns.export_defaults.include_flex)

    ~H"""
    <.drawer
      id="export-details"
      chrome="planner"
      open={@open}
      on_close="close_export_details"
      title="Export details"
      return_focus_id="export-details-button"
      class="max-w-[min(100vw,44rem)]"
    >
      <:lede>
        For data users and consultants. IDs come from the service and stay the same between exports.
      </:lede>

      <.drawer_scroll>
        <div>
          <p class="text-sm text-strong">{@plan.headline}.</p>

          <dl class="mt-3 grid grid-cols-[150px_1fr] gap-x-3 gap-y-1 text-[13px]">
            <dt class="text-muted">Files</dt>
            <dd class="text-strong">
              Main feed (fixed routes) and flex file (fixed routes plus flex), built from one export and published together
            </dd>
            <dt class="text-muted">Flex exports</dt>
            <dd class="text-strong">
              {if @included?,
                do: "Included in the next full export",
                else: "Left out right now (Settings › Export defaults)"}
            </dd>
          </dl>
        </div>

        <table class="w-full border-collapse text-left text-sm">
          <caption class="sr-only">
            Rows by file
          </caption>
          <thead>
            <tr class="border-b border-subtle text-[13px] text-muted">
              <th scope="col" class="py-2 pr-3 font-[650]">What</th>
              <th scope="col" class="py-2 pr-3 font-[650]">File</th>
              <th scope="col" class="py-2 text-right font-[650]">Rows</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{what, count, file} <- @plan.counts} class="border-b border-subtle">
              <td class="py-2 pr-3">{what}</td>
              <td class="py-2 pr-3 font-mono text-[13px]">{file}</td>
              <td class="py-2 text-right tabular-nums">{count}</td>
            </tr>
          </tbody>
        </table>

        <div>
          <h3 class="text-base font-bold text-strong">Rows this service writes</h3>
          <ul id="export-details-rows" class="mt-2 grid gap-2">
            <li :for={row <- @plan.rows} class="rounded-card border border-subtle px-3 py-2">
              <p class="font-mono text-[13px] text-strong">{row.file} · {row.id}</p>
              <p class="mt-0.5 text-[13px] text-default">{row.summary}</p>
            </li>
          </ul>
        </div>

        <div :if={@plan.warnings != []} class="grid gap-2">
          <p class="text-[13px] font-[650] text-default">The next export would report</p>
          <ul class="grid gap-2">
            <li
              :for={warning <- @plan.warnings}
              class="flex items-start gap-2 rounded-card border border-warning-line bg-warning-bg px-3 py-2 text-[13px] text-warning-fg"
            >
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
              <span>{warning.detail}</span>
            </li>
          </ul>
        </div>

        <div class="grid gap-1 text-[13px] text-muted">
          <p :for={note <- @notes}>{note}</p>
        </div>
      </.drawer_scroll>
    </.drawer>
    """
  end

  @doc """
  Renders the "Status and removal" section (AC-7).

  Deactivating keeps everything and leaves the service out of exports;
  reactivating takes it back. Both ask through the shared confirmation, which
  repeats the verb and the object, and deleting names the service in its own
  confirmation before removing it and its areas.
  """
  attr :service, :any, required: true
  attr :status_action, :any, default: nil

  def status_section(assigns) do
    ~H"""
    <section
      id="sec-status"
      aria-labelledby="status-title"
      class="min-w-0 border-t border-subtle pt-5"
    >
      <h2 id="status-title" tabindex="-1" class="text-base font-bold text-strong outline-none">
        Status and removal
      </h2>

      <div class="mt-3 grid gap-3">
        <div class="flex flex-wrap items-center justify-between gap-3 rounded-card border border-subtle px-4 py-3">
          <div>
            <p class="text-sm font-[650] text-strong">
              {if @service.active, do: "Active", else: "Inactive"}
            </p>
            <p class="text-[13px] text-muted">
              {if @service.active,
                do: "Deactivating leaves the service out of exports and keeps its setup.",
                else: "Exports leave this service out."}
            </p>
          </div>
          <.button
            :if={@service.active}
            id="deactivate-service"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="deactivate"
          >
            Deactivate service
          </.button>
          <.button
            :if={not @service.active}
            id="reactivate-service"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="reactivate"
          >
            Reactivate service
          </.button>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-3 rounded-card border border-subtle px-4 py-3">
          <div>
            <p class="text-sm font-[650] text-strong">Delete service</p>
            <p class="text-[13px] text-muted">{delete_detail(@service)}</p>
          </div>
          <.button
            id="delete-service"
            type="button"
            variant="secondary"
            class="btn-outline-danger min-h-11"
            phx-click="delete"
          >
            <.icon name="hero-trash" class="size-4" /> Delete service
          </.button>
        </div>
      </div>

      <.confirm_dialog
        id="flex-service-deactivate-dialog"
        chrome="planner"
        open={@status_action == :deactivate}
        title={"Deactivate #{@service.name}?"}
        confirm_label="Deactivate service"
        cancel_label="Keep active"
        pending_label="Deactivating…"
        on_confirm="confirm_deactivate"
        on_cancel="cancel_status"
        described_by="flex-service-deactivate-dialog-body"
        return_focus_id="deactivate-service"
      >
        <p>
          Exports after this leave the service out, so riders stop seeing it in trip planners. Its setup is kept and you can reactivate it at any time. Exports already run are not changed.
        </p>
      </.confirm_dialog>

      <.confirm_dialog
        id="flex-service-delete-dialog"
        chrome="planner"
        open={@status_action == :delete}
        title={"Delete #{@service.name}?"}
        confirm_label="Delete service"
        cancel_label="Keep service"
        pending_label="Deleting…"
        on_confirm="confirm_delete"
        on_cancel="cancel_status"
        described_by="flex-service-delete-dialog-body"
        return_focus_id="delete-service"
      >
        <p>
          This removes the service, {delete_removes(@service)}. Exports after this leave it out.
        </p>
        <p class="mt-2">To stop publishing it but keep the setup, deactivate it instead.</p>
      </.confirm_dialog>
    </section>
    """
  end

  @doc """
  Renders the confirmation the save bar's Discard uses (AC-5).
  """
  attr :open, :boolean, required: true

  def discard_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="flex-service-discard-dialog"
      chrome="planner"
      open={@open}
      title="Discard unsaved changes?"
      confirm_label="Discard changes"
      cancel_label="Keep editing"
      pending_label="Discarding…"
      on_confirm="confirm_discard"
      on_cancel="keep_editing"
      described_by="flex-service-discard-dialog-body"
      return_focus_id="discard-changes"
    >
      <p>Your changes to this service will be lost. The saved service stays as it was.</p>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the confirmation an in-app departure uses while the draft is dirty
  (AC-5). The `DraftGuard` hook sends the path here instead of navigating.
  """
  attr :open, :boolean, required: true

  def leave_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="flex-service-leave-dialog"
      chrome="planner"
      open={@open}
      title="Leave with unsaved changes?"
      confirm_label="Discard changes"
      cancel_label="Keep editing"
      pending_label="Leaving…"
      on_confirm="confirm_leave"
      on_cancel="keep_editing"
      described_by="flex-service-leave-dialog-body"
      return_focus_id="svc-title"
    >
      <p>Your changes to this service will be lost.</p>
    </.confirm_dialog>
    """
  end

  ## the hours editor's parts

  # One hours row: where it applies, its calendar, its window, and what the
  # calendar and window mean in words. Inputs come from `inputs_for`, so their
  # names carry the row's index in the draft.
  attr :hour, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :multi_area?, :boolean, required: true
  attr :area_options, :list, required: true
  attr :calendar_options, :list, required: true
  attr :calendar_rows, :map, required: true

  defp hours_row(assigns) do
    assigns =
      assigns
      |> assign(:help, hours_help(assigns.hour, assigns.calendar_rows))
      |> assign(:span, if(assigns.multi_area?, do: "sm:col-span-5", else: "sm:col-span-4"))

    ~H"""
    <div
      id={"f-hours-row-#{@hour.index}"}
      class="grid items-end gap-x-2 gap-y-1 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)_minmax(0,1fr)_minmax(0,1fr)_44px]"
    >
      <div :if={@multi_area?} class="min-w-0">
        <.input
          field={@hour[:area_key]}
          type="select"
          label="Area"
          options={@area_options}
          prompt="All areas"
          errors={errors_for(@field_errors, @hour[:area_key])}
        />
      </div>

      <div class="min-w-0">
        <.input
          field={@hour[:service_id]}
          type="select"
          label="Calendar"
          options={@calendar_options}
          errors={errors_for(@field_errors, @hour[:service_id])}
        />
      </div>

      <div class="min-w-0">
        <.input
          field={@hour[:start]}
          type="time"
          label="From"
          class="input input-lg w-full min-w-0 tabular-nums"
          errors={errors_for(@field_errors, @hour[:start])}
        />
      </div>

      <div class="min-w-0">
        <.input
          field={@hour[:end]}
          type="time"
          label="To"
          class="input input-lg w-full min-w-0 tabular-nums"
          errors={errors_for(@field_errors, @hour[:end])}
        />
      </div>

      <div class="flex items-end">
        <button
          type="button"
          id={"remove-hours-#{@hour.index}"}
          phx-click="remove_hours"
          phx-value-index={@hour.index}
          aria-label="Remove these hours"
          title="Remove these hours"
          class={[
            "inline-flex min-h-11 min-w-11 items-center justify-center rounded-control border border-control text-default hover:bg-canvas",
            focus_ring()
          ]}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <p :if={@help} class={["text-[13px] text-muted", @span]}>{@help}</p>
    </div>
    """
  end

  # The week strip: Mon–Sun on a 5 am–2 am axis, so missing days, uneven hours
  # and late nights are visible at a glance. A window longer than 16 hours is a
  # readiness error and is left off the axis rather than drawn past its end.
  attr :days, :list, required: true

  defp week_strip(assigns) do
    ~H"""
    <div class="rounded-card border border-subtle px-3 py-2" aria-label="Hours by day of the week">
      <div class="grid gap-0.5">
        <div
          :for={day <- @days}
          class="grid grid-cols-[28px_minmax(0,1fr)_minmax(0,7.5rem)] items-center gap-2 text-[13px] leading-[18px] sm:grid-cols-[36px_1fr_172px]"
        >
          <span class="text-muted">{day.label}</span>
          <span class="relative h-3 rounded-badge bg-canvas">
            <span
              :for={bar <- day.bars}
              class="absolute inset-y-0 rounded-badge bg-cyan-700"
              style={bar.style}
            >
            </span>
          </span>
          <span class="min-w-0 tabular-nums text-default">
            <span :if={day.bars == []} class="text-muted">No service</span>{Enum.join(
              Enum.map(day.bars, & &1.text),
              ", "
            )}
          </span>
        </div>
      </div>

      <div
        class="mt-1 grid grid-cols-[28px_minmax(0,1fr)_minmax(0,7.5rem)] gap-2 text-[12px] text-muted sm:grid-cols-[36px_1fr_172px]"
        aria-hidden="true"
      >
        <span></span>
        <span class="flex justify-between tabular-nums">
          <span>5 am</span><span>12 pm</span><span>7 pm</span><span>2 am</span>
        </span>
        <span></span>
      </div>
    </div>
    """
  end

  ## the booking editor's parts

  # The service-wide rule: the three booking choices, and the fields of the one
  # that is chosen. `rule.index` is always 0 because the page keeps the
  # service-wide rule first (see `FlexServiceLive`'s `normalize_rules/1`).
  attr :rule, :any, required: true
  attr :choices, :list, required: true
  attr :field_errors, :map, default: %{}
  attr :calendars, :map, required: true
  attr :calendar_options, :list, required: true

  defp rule_card(assigns) do
    assigns =
      assigns
      |> assign(:rule_when, assigns.rule[:when].value)
      |> assign(:rule_index, assigns.rule.index)

    ~H"""
    <div class="mt-1 grid min-w-0 gap-2">
      <label
        :for={choice <- @choices}
        for={"booking-when-#{@rule_index}-#{choice.key}"}
        class={[
          "flex min-w-0 cursor-pointer items-start gap-3 rounded-card border px-3 py-3",
          card_focus(),
          if(to_string(@rule_when) == choice.key,
            do: "border-action shadow-[inset_0_0_0_1px_var(--color-action)]",
            else: "border-subtle hover:bg-canvas"
          )
        ]}
      >
        <input
          type="radio"
          id={"booking-when-#{@rule_index}-#{choice.key}"}
          name={@rule[:when].name}
          value={choice.key}
          checked={to_string(@rule_when) == choice.key}
          class="mt-1 size-4 shrink-0 accent-[var(--color-action)]"
        />
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-[650] text-strong">{choice.label}</span>
          <span class="block text-[13px] text-muted">{choice.help}</span>
        </span>
      </label>
    </div>

    <div :if={@rule_when != nil} class="mt-2 grid min-w-0 gap-3 pl-3">
      <.rule_fields
        rule={@rule}
        field_errors={@field_errors}
        calendars={@calendars}
        calendar_options={@calendar_options}
      />
    </div>
    """
  end

  # One calendar-scoped rule of an area service: which calendar, when riders
  # book on its trips, and the same fields the service-wide rule uses.
  attr :rule, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :calendars, :map, required: true
  attr :calendar_options, :list, required: true

  defp scoped_rule_card(assigns) do
    assigns =
      assigns
      |> assign(:rule_when, assigns.rule[:when].value)
      |> assign(:rule_index, assigns.rule.index)
      |> assign(:choices, Enum.map(@rule_choices, &{&1.label, &1.key}))

    ~H"""
    <div class="mt-2 min-w-0 rounded-card border border-subtle px-4 py-3">
      <p class="text-sm font-[650] text-strong">Different rule on some days</p>

      <div class="mt-2 grid min-w-0 gap-3 sm:grid-cols-2">
        <.input
          field={@rule[:service_id]}
          type="select"
          label="Calendar"
          options={@calendar_options}
          errors={errors_for(@field_errors, @rule[:service_id])}
        />
        <.input
          field={@rule[:when]}
          type="select"
          label="Riders book"
          options={@choices}
          id={"booking-rule-#{@rule_index}-when"}
          errors={errors_for(@field_errors, @rule[:when])}
        />
      </div>

      <div :if={@rule_when != nil} class="mt-2 grid min-w-0 gap-3">
        <.rule_fields
          rule={@rule}
          field_errors={@field_errors}
          calendars={@calendars}
          calendar_options={@calendar_options}
        />
      </div>

      <button
        type="button"
        id={"remove-scoped-rule-#{@rule_index}"}
        phx-click="remove_scoped_rule"
        phx-value-index={@rule_index}
        class={[
          "mt-2 inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action hover:underline",
          focus_ring()
        ]}
      >
        <.icon name="hero-x-mark" class="size-4" /> Remove this rule
      </button>
    </div>
    """
  end

  # The fields one booking rule holds, by its `when`: only the fields the chosen
  # booking type uses are rendered, so the editor answers one question at a time.
  attr :rule, :any, required: true
  attr :field_errors, :map, default: %{}
  attr :calendars, :map, required: true
  attr :calendar_options, :list, required: true

  defp rule_fields(assigns) do
    assigns = assign(assigns, :rule_when, assigns.rule[:when].value)

    ~H"""
    <div :if={to_string(@rule_when) == "now"} class="grid gap-2">
      <.input
        field={@rule[:max_days]}
        errors={errors_for(@field_errors, @rule[:max_days])}
        type="number"
        min="0"
        label="Also accepts up to (optional)"
        class="input input-lg w-24 min-w-0 tabular-nums"
        help="Riders read this in the text; GTFS has no field for it yet."
      />
      <p class="text-[13px] text-muted">days ahead</p>
    </div>

    <div :if={to_string(@rule_when) == "same_day"} class="grid min-w-0 gap-3 sm:grid-cols-2">
      <.input
        field={@rule[:minutes]}
        errors={errors_for(@field_errors, @rule[:minutes])}
        type="number"
        min="0"
        step="5"
        label="At least"
        class="input input-lg w-24 min-w-0 tabular-nums"
      />
      <.input
        field={@rule[:max_days]}
        errors={errors_for(@field_errors, @rule[:max_days])}
        type="number"
        min="0"
        label="Book up to (optional)"
        class="input input-lg w-24 min-w-0 tabular-nums"
      />
      <p class="text-[13px] text-muted sm:col-span-2">
        minutes before pickup, up to a number of days ahead.
      </p>
    </div>

    <div :if={to_string(@rule_when) == "earlier_day"} class="grid gap-3">
      <div class="flex min-w-0 flex-wrap items-end gap-2">
        <.input
          field={@rule[:by]}
          type="time"
          label="By"
          class="input input-lg w-36 min-w-0 tabular-nums"
          errors={errors_for(@field_errors, @rule[:by])}
        />
        <.input
          field={@rule[:days]}
          errors={errors_for(@field_errors, @rule[:days])}
          type="number"
          min="1"
          label="Days before the trip"
          class="input input-lg w-24 min-w-0 tabular-nums"
        />
      </div>

      <.input
        field={@rule[:business_days]}
        errors={errors_for(@field_errors, @rule[:business_days])}
        type="checkbox"
        label="Count business days only"
        help="Only days the reservation office is open count. The office-days calendar below is the one exports use."
      />

      <div :if={@rule[:business_days].value}>
        <.input
          field={@rule[:office_service_id]}
          errors={errors_for(@field_errors, @rule[:office_service_id])}
          type="select"
          label="Office days calendar"
          options={@calendar_options}
          prompt="Choose the office calendar"
        />
        <p class="text-[13px] text-muted">
          Some trip planners count calendar days, so the text riders read also says when to book Monday trips.
        </p>
      </div>

      <.input
        field={@rule[:max_days]}
        errors={errors_for(@field_errors, @rule[:max_days])}
        type="number"
        min="0"
        label="Book up to (optional)"
        class="input input-lg w-24 min-w-0 tabular-nums"
      />
    </div>
    """
  end

  defp when_help(%FlexService{kind: :detour}) do
    "Detour times follow each trip’s timetable, so they change when the schedule changes."
  end

  defp when_help(%FlexService{}) do
    "Riders can be picked up and dropped off any time in these hours. Holidays come from each calendar."
  end

  # The section's own readiness findings (errors, suggestions and context).
  attr :findings, :list, required: true

  defp section_findings(assigns) do
    ~H"""
    <ul :if={@findings != []} class="mt-3 grid gap-2">
      <li
        :for={finding <- @findings}
        class={[
          "flex items-start gap-2 rounded-card border px-3 py-2 text-[13px]",
          finding_classes(finding.level)
        ]}
      >
        <.icon name={finding_icon(finding.level)} class="mt-0.5 size-4" />
        <span>{finding.text}</span>
      </li>
    </ul>
    """
  end

  # --- the service page's helpers ---------------------------------------------

  # One radio card, the reference's `radio()`: a bordered label whose ring marks
  # the chosen answer and whose help line sits under its label. The sections
  # pass the form's own name so the answer travels with the form's change event.
  attr :id, :string, required: true
  attr :group, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :help, :string, default: ""

  defp choice_radio(assigns) do
    ~H"""
    <label
      for={@id}
      class={[
        "flex min-w-0 cursor-pointer items-start gap-3 rounded-card border px-3 py-2.5",
        card_focus(),
        if(@checked,
          do: "border-action shadow-[inset_0_0_0_1px_var(--color-action)]",
          else: "border-subtle hover:bg-canvas"
        )
      ]}
    >
      <input
        type="radio"
        id={@id}
        name={@group}
        value={@value}
        checked={@checked}
        class="mt-1 size-4 shrink-0 accent-[var(--color-action)]"
      />
      <span class="min-w-0 flex-1">
        <span class="block text-sm font-[650] text-strong">{@label}</span>
        <span :if={@help != ""} class="block text-[13px] text-muted">{@help}</span>
      </span>
    </label>
    """
  end

  @doc """
  How one area was chosen, in the words the editor met it in.

  Shared with the area editor's "From:" line (step 24), so a stored area and a
  draft read the same sentence.
  """
  def source_line(%FlexArea{source: :census} = area) do
    join_help([
      census_layer_label(area.census_layer),
      "U.S. Census Bureau #{area.census_vintage}",
      "water left out"
    ])
  end

  def source_line(%FlexArea{source: :route_distance} = area) do
    case area.distance_m do
      distance when is_integer(distance) ->
        "Distance from the current routes · #{distance_metres(distance)}"

      _missing ->
        "Distance from the current routes"
    end
  end

  def source_line(%FlexArea{source: :drawn}), do: "Drawn boundary"
  def source_line(%FlexArea{source: :file}), do: "Imported from a file"
  def source_line(%FlexArea{}), do: "Area"

  @doc "The Census layer's reader-facing label, or `nil` for a layer this app does not pick."
  def census_layer_label("place"), do: "Town or city limits"
  def census_layer_label("cdp"), do: "Census-designated place"
  def census_layer_label("county_subdivision"), do: "County subdivision"
  def census_layer_label("county"), do: "County"
  def census_layer_label(_layer), do: nil

  @doc "The non-empty parts joined with the app's separator."
  def join_help(parts) do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  @doc "Metres as the reference words them (`\"800 m\"`)."
  def distance_metres(distance), do: "#{distance} m"

  defp area_size(km2) when is_number(km2), do: "#{km2_text(km2)} km²"
  defp area_size(_km2), do: "size not measured yet"

  @doc "A measured area in km², one decimal at most (shared with the area editor)."
  def km2_text(value) do
    value
    |> Kernel.*(1.0)
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end

  defp inside_line(%{stop_ids: [], route_ids: []}), do: "no stops yet"

  defp inside_line(%{stop_ids: stops, route_ids: routes}) do
    stops_text = "#{length(stops)} #{plural_word(length(stops), "stop")}"

    case routes do
      [] -> stops_text
      routes -> "#{stops_text} on #{length(routes)} #{plural_word(length(routes), "route")}"
    end
  end

  defp hub_name(stop_choices, stop_id) do
    Enum.find_value(stop_choices, stop_id, fn {name, id} -> if id == stop_id, do: name end)
  end

  defp zone_km2([]), do: nil

  defp zone_km2(zones) do
    zones |> Enum.map(& &1.km2) |> Enum.sum() |> km2_text()
  end

  defp measure_summary(%FlexService{measure: :stops}), do: ", one around each stop"
  defp measure_summary(%FlexService{}), do: ", one for each stretch between stops"

  defp band_on?(%FlexService{band_start: start, band_end: finish}),
    do: Values.present?(start) or Values.present?(finish)

  defp band_note(%FlexService{band_start: start, band_end: finish})
       when is_binary(start) and is_binary(finish) do
    "Only trips departing between #{RiderText.range_text(%{start: start, end: finish})} get detour rows."
  end

  defp band_note(%FlexService{}), do: nil

  defp trip_count_label(0, route_id), do: "No Route #{route_id} trips"
  defp trip_count_label(1, route_id), do: "1 Route #{route_id} trip"
  defp trip_count_label(count, route_id), do: "#{count} Route #{route_id} trips"

  # The prototype's headline states, in its order: inactive first, then a
  # registered-riders service kept out of the feed, then a service that export
  # would leave out on a readiness error, and otherwise the plan's own words.
  defp export_headline(%FlexService{active: false}, _plan, _status),
    do: "Left out of exports while inactive."

  defp export_headline(
         %FlexService{riders: :registered, include_registered: false},
         _plan,
         _status
       ),
       do: "Left out of the flex feed: registered riders only, kept out of trip planners."

  defp export_headline(_service, _plan, %{errors: errors}) when errors > 0 do
    "Left out of the flex file until the problems are fixed. The flex file is still published without it, in step with your main feed, and the export run names it."
  end

  defp export_headline(_service, %{headline: headline}, _status), do: headline <> "."

  defp destination_line(%{include_flex: false}),
    do: "Exports leave flex out right now (Settings › Export defaults)."

  defp destination_line(_defaults),
    do:
      "Goes in the flex file, published with your main feed from the same export. The main feed doesn’t change."

  @doc """
  Renders the note one realtime answer carries (AC-15, AC-29).

  The service page puts it under the question for a detour service; the Settings
  page puts it under the same question for the organization's answer.
  """
  attr :id, :string, default: "realtime-note"
  attr :note, :map, required: true

  def realtime_note_card(assigns) do
    ~H"""
    <p id={@id} class={realtime_note_class(@note)}>
      <.icon :if={@note.icon} name={@note.icon} class="mt-0.5 size-4 shrink-0" />
      <span>{@note.text}</span>
    </p>
    """
  end

  @doc """
  Returns the note one realtime answer carries, or nil when it needs none.

  `route_id` is the route a detour service's trips belong to. The Settings page
  answers for every service at once, so it passes nil: the warning names flex
  trips rather than one route, and the two answers that match either file need
  no note there.
  """
  @spec realtime_note(atom() | String.t() | nil, String.t() | nil) :: map() | nil
  def realtime_note(:own, nil) do
    %{
      tone: :warning,
      icon: "hero-exclamation-triangle",
      text:
        "Apps can’t match its updates to flex trips, because the vendor’s file uses its own trip IDs. Ask the vendor to use the trip IDs in your feeds."
    }
  end

  def realtime_note(:own, route) do
    %{
      tone: :warning,
      icon: "hero-exclamation-triangle",
      text:
        "Apps can’t match its updates to Route #{route} trips, because the vendor’s file uses its own trip IDs. Ask the vendor to use the trip IDs in your feeds."
    }
  end

  def realtime_note(:unsure, _route) do
    %{
      tone: :info,
      icon: "hero-information-circle",
      text:
        "Ask your vendor. If it uses its own schedule file, apps can’t match its updates to these trips."
    }
  end

  def realtime_note(:none, _route), do: nil

  def realtime_note(source, nil) when source in [:main, :flex], do: nil

  def realtime_note(_source, _route) do
    %{
      tone: :help,
      icon: nil,
      text:
        "Trip IDs are the same in both files, so apps match realtime to detour trips either way."
    }
  end

  defp realtime_note_class(%{tone: :warning}),
    do:
      "mt-2 flex items-start gap-2 rounded-card border border-warning-line bg-warning-bg px-3 py-2 text-[13px] text-warning-fg"

  defp realtime_note_class(%{tone: :info}),
    do:
      "mt-2 flex items-start gap-2 rounded-card border border-info-line bg-info-bg px-3 py-2 text-[13px] text-info-fg"

  defp realtime_note_class(_note), do: "mt-2 text-[13px] text-muted"

  defp plan_notes(%FlexService{kind: :area}, _plan) do
    [
      "Flex trips here are windows when riders can travel, not vehicle work. Blocks, Runs and crew exports leave them out.",
      "Planned row layout for the next export."
    ]
  end

  defp plan_notes(%FlexService{kind: :detour} = service, _plan) do
    [
      "Each Route #{service.route_id} trip is written once: its fixed stops keep their times and the detour rows sit between them. The route type stays Bus (3).",
      band_note(service),
      "The booking deadline is written in the rule’s fields and, as a sentence, at the start of the message, because OpenTripPlanner’s web app shows only a day count.",
      "Planned row layout for the next export."
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp plan_notes(%FlexService{}, _plan), do: []

  defp delete_detail(%FlexService{kind: :detour}),
    do: "Removes the service, its detour areas and its booking rule from this version."

  defp delete_detail(%FlexService{}),
    do: "Removes the service, its areas and its booking rule from this version."

  defp delete_removes(%FlexService{kind: :detour} = service),
    do:
      "its detour areas and its booking rule. Route #{service.route_id} and its trips stay as they are"

  defp delete_removes(%FlexService{} = service),
    do:
      "its #{plural_word(length(service.areas), "area")} and its booking rule. Fixed routes and stops stay as they are"

  defp plural_word(1, word), do: word
  defp plural_word(_count, word), do: word <> "s"

  # The version's calendars as select options: every calendar the version holds,
  # every calendar a stored hours row or booking rule names (so a row whose
  # calendar is gone still shows its own id), named the way `RiderText` names it
  # and ordered by that name.
  def calendar_options(calendars, calendar_rows, service_ids) do
    (Map.keys(calendars) ++ Map.keys(calendar_rows) ++ service_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn service_id -> {calendar_label(calendars, service_id), service_id} end)
    |> Enum.sort_by(fn {label, service_id} -> {label, service_id} end)
  end

  defp calendar_label(calendars, service_id) do
    case Map.get(calendars, service_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _other -> service_id
    end
  end

  # The areas a rule may scope its hours to. With one area the row needs no
  # choice; with several, "All areas" stays the first option.
  defp area_options(%FlexService{areas: areas}) do
    areas
    |> Enum.map(&{area_label(&1), &1.key})
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp area_options(_service), do: []

  defp area_label(%{name: name}) when is_binary(name) and name != "", do: "#{name} only"
  defp area_label(%{key: key}), do: "#{key} only"

  # The day-and-date help under one hours row: the calendar's own days, dates and
  # exceptions, then the row's window when the end is the next day.
  defp hours_help(hour, calendar_rows) do
    case Map.get(calendar_rows, hour[:service_id].value) do
      %{} = row ->
        [
          days_label(row),
          dates_label(row),
          exceptions_label(row),
          next_day_label(hour)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      _missing ->
        # A calendar this version does not have: the readiness findings name it.
        nil
    end
  end

  defp days_label(%{calendar: %ServiceCalendar{} = calendar}) do
    [
      {"Mon", calendar.monday},
      {"Tue", calendar.tuesday},
      {"Wed", calendar.wednesday},
      {"Thu", calendar.thursday},
      {"Fri", calendar.friday},
      {"Sat", calendar.saturday},
      {"Sun", calendar.sunday}
    ]
    |> Enum.filter(fn {_day, runs} -> runs == 1 end)
    |> Enum.map(fn {day, _runs} -> day end)
    |> day_runs_text()
  end

  defp days_label(_row), do: nil

  defp day_runs_text([]), do: nil

  defp day_runs_text(days) do
    days
    |> Enum.with_index()
    |> Enum.reduce([], fn {_day, index}, runs ->
      case runs do
        [{first, last, _name} | rest] when index == last + 1 -> [{first, index, nil} | rest]
        _other -> [{index, index, nil} | runs]
      end
    end)
    |> Enum.reverse()
    |> Enum.map_join(", ", fn
      {index, index, _name} -> Enum.at(days, index)
      {first, last, _name} -> "#{Enum.at(days, first)}–#{Enum.at(days, last)}"
    end)
  end

  defp dates_label(%{
         calendar: %ServiceCalendar{start_date: %Date{} = from, end_date: %Date{} = to}
       }),
       do: "#{short_date(from)} – #{short_date(to)}"

  defp dates_label(_row), do: nil

  defp exceptions_label(%{exceptions: exceptions}) do
    off = Enum.count(exceptions, &(&1.exception_type == 2))
    added = Enum.count(exceptions, &(&1.exception_type == 1))

    case {off, added} do
      {0, 0} -> "No exceptions"
      {0, added} -> day_count(added) <> " added"
      {off, 0} -> day_count(off) <> " off"
      {off, added} -> day_count(off) <> " off, " <> day_count(added) <> " added"
    end
  end

  defp exceptions_label(_row), do: nil

  defp day_count(1), do: "1 day"
  defp day_count(count), do: "#{count} days"

  defp next_day_label(hour) do
    case RiderText.window(%{start: hour[:start].value, end: hour[:end].value}) do
      %{finish: finish} when finish > 1_440 -> "ends the next day"
      _other -> nil
    end
  end

  defp short_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  # One strip row per weekday: the draft's hours rows whose calendar runs that
  # day, placed on the 5 am–2 am axis the strip draws.
  defp week_strip(service, calendar_rows) do
    ~w(Mon Tue Wed Thu Fri Sat Sun)
    |> Enum.with_index()
    |> Enum.map(fn {label, index} ->
      bars =
        service.hours
        |> Enum.filter(&runs_on?(&1, calendar_rows, index))
        |> Enum.flat_map(&bar/1)

      %{label: label, bars: bars}
    end)
  end

  defp runs_on?(hour, calendar_rows, index) do
    with %{} = row <- Map.get(calendar_rows, hour.service_id),
         %ServiceCalendar{} = calendar <- Map.get(row, :calendar) do
      [
        calendar.monday,
        calendar.tuesday,
        calendar.wednesday,
        calendar.thursday,
        calendar.friday,
        calendar.saturday,
        calendar.sunday
      ]
      |> Enum.at(index) == 1
    else
      _other -> false
    end
  end

  defp bar(hour) do
    case RiderText.window(%{start: hour.start, end: hour.end}) do
      %{start: start, finish: finish} when finish - start <= 960 ->
        [%{style: bar_style(start, finish), text: RiderText.range_text(hour, compact: true)}]

      _other ->
        []
    end
  end

  # The strip's axis runs 5 am to 2 am (the reference's own frame).
  defp bar_style(start, finish) do
    "left: #{axis_position(start)}%; width: #{axis_position(finish) - axis_position(start)}%"
  end

  defp axis_position(minutes) do
    ((minutes - 300) / 1_260) |> max(0.0) |> min(1.0) |> Kernel.*(100)
  end

  # The next days the service's calendars take off, from the version's exception
  # rows: what the reference words as "Next days without service".
  defp upcoming_exceptions(service, calendar_rows, %Date{} = today) do
    used = service.hours |> Enum.map(& &1.service_id) |> Enum.uniq()

    calendar_rows
    |> Enum.filter(fn {service_id, _row} -> service_id in used end)
    |> Enum.flat_map(fn {_service_id, row} -> Map.get(row, :exceptions, []) end)
    |> Enum.filter(&(&1.exception_type == 2 and Date.compare(&1.date, today) != :lt))
    |> Enum.sort_by(& &1.date)
    |> Enum.take(3)
    |> Enum.map(&Calendar.strftime(&1.date, "%a, %b %-d"))
  end

  defp upcoming_exceptions(_service, _calendar_rows, _today), do: []

  # The messages the refused save named for one control, keyed by the id the
  # form renders for it.
  defp errors_for(field_errors, field) do
    Map.get(field_errors, field && field.id, [])
  end

  # The same lookup for a control whose rendered id is the reference's own
  # (`f-distance`, `f-wording`, …) rather than the form field's id.
  defp control_errors(field_errors, id) do
    Map.get(field_errors, id, [])
  end

  defp section_findings(checks, section) do
    Enum.filter(checks, &(&1.section == section))
  end

  defp finding_icon(:error), do: "hero-exclamation-circle"
  defp finding_icon(:warning), do: "hero-exclamation-triangle"
  defp finding_icon(_level), do: "hero-information-circle"

  defp finding_classes(:error), do: "border-error-line bg-error-bg text-error-fg"
  defp finding_classes(:warning), do: "border-warning-line bg-warning-bg text-warning-fg"
  defp finding_classes(_level), do: "border-info-line bg-info-bg text-info-fg"

  defp updated_line(%FlexService{updated_at: %DateTime{} = at}),
    do: "Updated #{short_date(DateTime.to_date(at))}"

  defp updated_line(%FlexService{}), do: "Not saved yet"

  defp save_lead([_one]), do: "Fix one thing to save"
  defp save_lead(errors), do: "Fix #{length(errors)} things to save"

  defp save_bar_lead([], name), do: "Unsaved changes to #{name}"
  defp save_bar_lead([_one], name), do: "1 unsaved change to #{name}"
  defp save_bar_lead(changes, name), do: "#{length(changes)} unsaved changes to #{name}"

  # The rule fields a booking rule's `when` uses; a rule with no answer yet
  # shows none of them, because the editor has not chosen a booking type.
  defp app_renderings(%FlexService{} = service) do
    case Enum.find(service.booking_rules, &(is_nil(&1.service_id) and not is_nil(&1.when))) do
      nil -> []
      rule -> RiderText.app_renderings(rule)
    end
  end
end
