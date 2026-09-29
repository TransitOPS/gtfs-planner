defmodule GtfsPlannerWeb.Gtfs.FlexComponents do
  @moduledoc """
  The Flex list's surfaces: the services table, the export-state line, the
  first-use question, the create drawer, the copy action, the map card, and the
  list's loading and error states.

  `FlexLive` owns the load and every value; these components render what they are
  given, so the copy the prototype fixes lives in one place per state. The table
  is the shared `table/1`, whose last column carries each service's
  `Flex.Checks.status/2` badge: the tone selects the badge's colour and the
  label always carries the meaning, so the status is never signalled by colour
  alone.

  The create drawer is the shared `drawer/1`, because the app's own
  `OverlayDialog` behaviour already gives a modal dialog that Esc closes, that
  keeps focus inside it, and that returns focus to the control that opened it.
  Its error summary follows the app's `FormErrorFocus` pattern: the summary
  carries `tabindex="-1"` and the page moves focus to it, and each item links to
  the field it names.

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
      callout: 1,
      confirm_dialog: 1,
      drawer: 1,
      input: 1,
      skeleton: 1,
      status_badge: 1,
      table: 1
    ]

  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexService

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
      href: "/gtfs/#{version_id}/flex/#{service.id}",
      where: where_line(service),
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
    <div class="min-w-0 self-start rounded-card border border-subtle bg-white">
      <p
        id="flex-services-count"
        role="status"
        class="border-b border-subtle bg-canvas px-4 py-2.5 text-[13px] font-[650] text-default"
      >
        {count_label(@count)}
      </p>

      <div class="overflow-x-auto">
        <div class="min-w-[640px]">
          <.table id="flex-services" rows={@rows}>
            <:col :let={{_id, row}} label="Service">
              <a
                href={row.href}
                class="font-[650] text-action no-underline hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
              >
                {row.name}
              </a>
              <p class="mt-0.5 text-[13px] text-muted">{row.where}</p>
            </:col>

            <:col :let={{_id, row}} label="Hours">
              <span :for={line <- row.hours_lines} class="block tabular-nums">{line}</span>
            </:col>

            <:col :let={{_id, row}} label="Booking">{row.booking}</:col>

            <:col :let={{_id, row}} label="Status">
              <.status_badge
                status={badge_tone(row.status.tone)}
                label={row.status.label}
                class="whitespace-nowrap"
              />
            </:col>
          </.table>
        </div>
      </div>
    </div>
    """
  end

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
    <.callout
      id="flex-exports"
      kind="warning"
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
    </.callout>
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
      class="self-start rounded-card border border-subtle px-6 py-6"
    >
      <h2 id="flex-first-use-title" class="text-[24px]">
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
          class="flex min-h-11 items-start gap-3 rounded-card border border-subtle px-3 py-3 text-left hover:border-action hover:bg-canvas"
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

    ~H"""
    <.drawer
      id="create-drawer"
      open={@open}
      on_close="close_create"
      title="Create flex service"
      initial_focus={if @focus_id, do: :first_field, else: :heading}
      initial_focus_id={@focus_id}
      return_focus_id={@return_focus_id}
      class="max-w-[min(100vw,32.5rem)]"
    >
      <div id="create-drawer-content" phx-hook="FormErrorFocus">
        <p id="create-drawer-description" class="mb-4 text-sm text-muted">
          {@version_name}
        </p>

        <.form
          for={@form}
          id="create-form"
          novalidate
          phx-change="create_change"
          phx-submit="create_submit"
          class="grid gap-5"
        >
          <div :if={@errors != []}>
            <div
              id="create-error-summary"
              tabindex="-1"
              role="alert"
              class="rounded-card border-2 border-error-line px-4 py-3 text-sm outline-none"
            >
              <p class="font-[650] text-error-fg">{summary_lead(@errors)}</p>
              <ul class="mt-1 grid gap-0.5 pl-5 [list-style:disc]">
                <li :for={{field_id, message} <- @errors}>
                  <a href={"##{field_id}"} class="text-error-fg underline">{message}</a>
                </li>
              </ul>
            </div>
          </div>

          <div :if={@error}>
            <.callout id="create-save-error" kind="error" title="Nothing was created" tabindex="-1">
              {@error}
            </.callout>
          </div>

          <fieldset>
            <legend class="text-sm font-[650] text-strong">How does it work?</legend>

            <div class="mt-2 grid gap-2">
              <label
                :for={kind <- @kinds}
                for={"create-pattern-#{kind.pattern}"}
                class={[
                  "flex cursor-pointer items-start gap-3 rounded-card border px-3 py-3",
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
            <legend class="text-sm font-[650] text-strong">
              Do riders know the areas by one name?
            </legend>

            <div class="mt-1 grid gap-1">
              <label
                for="create-named-one"
                class="flex min-h-11 cursor-pointer items-start gap-3 py-1"
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
                class="flex min-h-11 cursor-pointer items-start gap-3 py-1"
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

          <p class="text-[13px] text-muted">
            Next you’ll add when it runs, how riders book and where it goes. Exports leave it out until those are set.
          </p>
        </.form>
      </div>

      <%!-- The one primary action sits in the drawer's pinned footer, so it
      stays reachable while the answers above it scroll. The two controls
      belong to the form through its own id. --%>
      <:footer>
        <div class="flex flex-wrap items-center justify-end gap-3">
          <.button type="button" variant="secondary" class="min-h-11" phx-click="close_create">
            Cancel
          </.button>
          <.button
            id="create-submit"
            type="submit"
            form="create-form"
            variant="primary"
            class="min-h-11"
          >
            Create service
          </.button>
        </div>
      </:footer>
    </.drawer>
    """
  end

  @doc """
  Renders the copy action for a version with no services (AC-6, R14).

  The select offers the organization's other published versions that hold a flex
  service, and the copy itself goes through the confirmation dialog, which names
  the source version and only then calls `Flex.copy_from_version/4`. A source
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
          class="w-full select select-lg min-w-[16rem]"
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
        open={not is_nil(@target)}
        title="Copy flex services?"
        confirm_label="Copy services"
        pending_label="Copying…"
        on_confirm="confirm_copy"
        on_cancel="cancel_copy"
        confirm_variant="primary"
        described_by="copy-confirm-body"
        return_focus_id="copy-services"
      >
        <p :if={@target} id="copy-confirm-body">
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
    <div id="flex-list-error" class="mt-6" role="alert">
      <.callout kind="error" title="Couldn’t load flex services.">
        <p>Your services are safe. Check your connection and try again.</p>
        <div class="mt-3">
          <.button id="flex-list-retry" phx-click="retry" class="min-h-11">Try again</.button>
        </div>
      </.callout>
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

  @doc """
  The version's service count as riders read it, shared by the table's caption
  and the copy action's confirmation.
  """
  @spec count_label(non_neg_integer()) :: String.t()
  def count_label(1), do: "1 flex service"
  def count_label(count), do: "#{count} flex services"

  # The sentence a full export writes for these services (R15, AC-24).
  defp export_sentence(false) do
    "Your flex file is your only feed. It goes to the Transit app and OpenTripPlanner-based trip planners, not to Google."
  end

  defp export_sentence(true) do
    "Exports also write a flex file: your fixed routes plus flex, built and published with your main feed. Apps that show flex load it instead of the main feed, which stays as it is for Google Maps."
  end

  # `Checks.status/2` tones map onto the shared badge vocabulary: a ready service
  # reads as a pass, a problem or suggestion keeps its own tone, and every
  # neutral label (inactive, not in trip planners) uses the neutral treatment.
  defp badge_tone(:success), do: "pass"
  defp badge_tone(tone) when tone in [:warning, :error], do: to_string(tone)
  defp badge_tone(_tone), do: :neutral

  # The row's "where" line, ported from the prototype's `whereLine`. A detour
  # names its route and distance; an area service names its areas. The stretch's
  # stop IDs and the connecting-stop IDs stay off this line: the service page
  # (step 23) shows them with the names riders read.
  defp where_line(%FlexService{kind: :detour} = service) do
    case service.distance_m do
      nil ->
        "Detours from Route #{service.route_id}; distance not set"

      distance ->
        "Detours up to #{distance_label(distance)} from Route #{service.route_id}#{measure_suffix(service)}"
    end
  end

  defp where_line(%FlexService{kind: :area} = service) do
    case area_names(service) do
      [] -> "No area yet"
      names -> "Anywhere in #{Enum.join(names, " or ")}"
    end
  end

  defp area_names(service) do
    service.areas
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp measure_suffix(%FlexService{measure: :stops}), do: " stops"
  defp measure_suffix(%FlexService{}), do: ""

  defp distance_label(200), do: "a few blocks"
  defp distance_label(400), do: "¼ mile"
  defp distance_label(800), do: "½ mile"
  defp distance_label(1200), do: "¾ mile"
  defp distance_label(1600), do: "1 mile"
  defp distance_label(distance), do: "#{distance} m"

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
      present?(phone) and present?(url) -> "Online or call"
      present?(url) -> "Online"
      present?(phone) -> "Call"
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
    ", by #{compact_clock(by)}, #{days} #{business}#{unit} ahead"
  end

  defp notice_suffix(%FlexBookingRule{}), do: ""

  defp duration_short(minutes) when minutes >= 60 and rem(minutes, 60) == 0,
    do: "#{div(minutes, 60)} hr"

  defp duration_short(minutes), do: "#{minutes} min"

  # "HH:MM" as riders read it: "4 pm" on the hour, "4:30 pm" otherwise.
  defp compact_clock(time) when is_binary(time) do
    case String.split(time, ":") do
      [hours, minutes] -> clock_from_parts(hours, minutes)
      _other -> time
    end
  end

  defp compact_clock(time), do: time

  defp clock_from_parts(hours, minutes) do
    case {Integer.parse(hours), Integer.parse(minutes)} do
      {{hours, ""}, {minutes, ""}} -> clock(hours, minutes)
      _unreadable -> hours <> ":" <> minutes
    end
  end

  defp clock(hours, 0), do: "#{hour12(hours)} #{meridiem(hours)}"

  defp clock(hours, minutes) do
    "#{hour12(hours)}:#{String.pad_leading(Integer.to_string(minutes), 2, "0")} #{meridiem(hours)}"
  end

  defp hour12(hours), do: rem(rem(hours, 24) + 11, 12) + 1

  defp meridiem(hours), do: if(rem(hours, 24) >= 12, do: "pm", else: "am")

  defp present?(value), do: is_binary(value) and value != ""
end
