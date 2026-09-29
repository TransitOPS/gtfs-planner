defmodule GtfsPlannerWeb.Gtfs.FlexComponents do
  @moduledoc """
  The Flex list's surfaces: the services table, the export-state line, the
  first-use question, the map card, and the list's loading and error states.

  `FlexLive` owns the load and every value; these components render what they are
  given, so the copy the prototype fixes lives in one place per state. The table
  is the shared `table/1`, whose last column carries each service's
  `Flex.Checks.status/2` badge: the tone selects the badge's colour and the
  label always carries the meaning, so the status is never signalled by colour
  alone.

  The map card renders an empty `#flex-list-map` container. Step 20 attaches the
  `FlexAreaMap` hook and fills it with the version's areas, routes and stops; the
  server never patches inside it (`phx-update="ignore"`), because the hook owns
  that subtree once it mounts.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.CoreComponents,
    only: [button: 1, callout: 1, skeleton: 1, status_badge: 1, table: 1]

  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexService

  # The two kinds a first-time editor chooses between (AC-4). Wording is the
  # prototype's; the drawer that these buttons open arrives in step 21, so they
  # carry the kind as data rather than an event this page does not yet handle.
  @kinds [
    %{
      key: "area",
      label: "Rides anywhere in an area",
      help:
        "Dial-a-ride or microtransit. Riders book a trip between any two places in the area, and can also ride to set stops."
    },
    %{
      key: "detour",
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

  The two kinds are the only actions, and the pointer below them answers the
  other question the prototype answers here: a stop served only when booked
  belongs on the route's timetable, not in a new flex service.
  """
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
          data-kind={kind.key}
          class="flex min-h-11 items-start gap-3 rounded-card border border-subtle px-3 py-3 text-left hover:border-action hover:bg-canvas"
        >
          <span class="min-w-0 flex-1">
            <span class="block text-sm font-[650] text-strong">{kind.label}</span>
            <span class="block text-[13px] text-muted">{kind.help}</span>
          </span>
          <span class="shrink-0" aria-hidden="true"><.kind_diagram kind={kind.key} /></span>
        </button>
      </div>

      <p class="mt-3 rounded-card bg-canvas px-3 py-2 text-[13px] text-default">
        <strong class="font-[650]">Stops served only when booked?</strong>
        Request stops and trips that run only when booked go on the route’s timetable, with the boarding choice “Booking required”. On-demand trips between set stops are an area service with a list of stops.
      </p>
    </section>
    """
  end

  @doc """
  Renders the map card with its empty map container.

  The title names what the hook will draw: the version's flex areas under "Where
  flex runs", or only its fixed routes when the version has no service yet.
  """
  attr :title, :string, required: true

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
      <div id="flex-list-map" phx-update="ignore" class="relative" style="height: 480px"></div>
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

  defp count_label(1), do: "1 flex service"
  defp count_label(count), do: "#{count} flex services"

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
