defmodule GtfsPlannerWeb.Gtfs.StopDetailComponents do
  @moduledoc """
  Presentation for `Gtfs.StopDetailLive` under the TransitOps design system.

  The page answers an operator's questions in order: where is this place, what can
  riders do here, what is inside it, and what did people find on site. The
  LiveView owns every state and event; the components here map its assigns to
  markup and the pure helpers at the bottom (`build_floors/2`, `inventory/3`,
  `stop_kind/1`) turn loaded regions into the words and groups the page shows.

  A stop that is not a station gets the location and service cards only: it has
  no floors, pathways or journal to show, so those sections are absent rather than
  empty.
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [button: 1, icon: 1, skeleton: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlannerWeb.Gtfs.StationJournalComponents

  @pathways_shown 6

  # ── shared pieces ──────────────────────────────────────────────────────────

  defp card, do: "overflow-hidden rounded-card border border-subtle bg-white"

  defp card_title,
    do: "font-display text-[22px] font-semibold leading-tight tracking-[-0.025em] text-strong"

  defp focus,
    do: "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"

  defp text_link_class do
    "inline-flex min-h-11 items-center gap-1.5 font-[650] text-action no-underline hover:text-action-hover hover:underline"
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  defp text_link(assigns) do
    ~H"""
    <.link id={@id} navigate={@navigate} class={[text_link_class(), @class]} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # A warning that owns one region of the page. It says what still works and
  # offers the one control that reloads only that region.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :retry_id, :string, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :role, :string, default: nil
  slot :inner_block, required: true

  defp region_error(assigns) do
    ~H"""
    <.message
      id={@id}
      kind="warning"
      title={@title}
      role={@role}
      aria-live={@role == "status" && "polite"}
    >
      {render_slot(@inner_block)}
      <:action>
        <.button
          id={@retry_id}
          variant="secondary"
          class="min-h-11 min-w-11"
          phx-click={@event}
        >
          <.icon name="hero-arrow-path" class="size-4" /> {@label}
        </.button>
      </:action>
    </.message>
    """
  end

  # Kept on one line in the template: a label's text must not carry indentation.
  defp dt_class, do: "text-[13px] font-[650] text-muted sm:flex sm:min-h-11 sm:items-center"

  # A label beside a list of several rows reads against the first of them, not
  # against the middle of the stack: centred on a four-row list it reads as a
  # caption for rows two and three.
  defp dt_class_top, do: "text-[13px] font-[650] text-muted sm:flex sm:pt-2"

  attr :label, :string, required: true
  attr :id, :string, default: nil

  attr :top?, :boolean,
    default: false,
    doc: "align the label to the top of a tall value rather than its middle"

  slot :inner_block, required: true
  slot :hint

  defp fact_row(assigns) do
    assigns = assign(assigns, :dt_class, if(assigns[:top?], do: dt_class_top(), else: dt_class()))

    ~H"""
    <div class="grid gap-x-4 gap-y-0.5 border-t border-subtle px-5 py-2 first:border-t-0 sm:grid-cols-[132px_minmax(0,1fr)]">
      <dt class={@dt_class}>{@label}</dt>
      <dd id={@id} class="min-w-0 self-center py-1 text-sm text-strong">
        <span class="flex flex-wrap items-center gap-x-3 gap-y-0.5 sm:min-h-9">
          {render_slot(@inner_block)}
        </span>
        <span :if={@hint != []} class="block text-[13px] text-muted">{render_slot(@hint)}</span>
      </dd>
    </div>
    """
  end

  @doc """
  Wheelchair access in words, with an icon and, when the value is the station's,
  the source. A gap reads "Not recorded": the record has no value, which is not
  the same as the place being inaccessible.
  """
  attr :status, :atom, required: true, values: [:accessible, :not_accessible, :unknown]
  attr :source, :atom, default: :direct, values: [:direct, :inherited, :missing]

  def access_status(assigns) do
    {label, icon_name, tone} =
      case assigns.status do
        :accessible -> {"Accessible", "hero-check-circle", "text-success-fg"}
        :not_accessible -> {"Not accessible", "hero-x-circle", "text-error-fg"}
        :unknown -> {"Not recorded", "hero-question-mark-circle", "text-muted"}
      end

    assigns =
      assigns |> assign(:label, label) |> assign(:icon_name, icon_name) |> assign(:tone, tone)

    ~H"""
    <span class="inline-flex flex-wrap items-center gap-x-2" data-accessibility={@status}>
      <span class={["inline-flex items-center gap-1.5 font-[650]", @tone]}>
        <.icon name={@icon_name} class="size-4" /> {@label}
      </span>
      <span
        :if={@source == :inherited}
        data-accessibility-source="inherited"
        class="text-[13px] font-normal text-muted"
      >
        Follows the station
      </span>
    </span>
    """
  end

  # ── page states ────────────────────────────────────────────────────────────

  @doc "The whole page could not be read. Nothing on it is stale, so it offers one reload."
  def unavailable(assigns) do
    ~H"""
    <div class="max-w-[720px]">
      <.message
        id="stop-unavailable"
        kind="error"
        title="We couldn't load this stop or station"
      >
        The data didn't respond. Nothing was changed. Reload to try again.
        <:action>
          <.button id="stop-retry" class="min-h-11" phx-click="retry">
            <.icon name="hero-arrow-path" class="size-4" /> Reload details
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc "A skeleton that mirrors the location and service cards while the stop loads."
  def loading(assigns) do
    ~H"""
    <div id="stop-loading">
      <.skeleton id="stop-loading-status" label="Loading stop details…" role="status">
        <div class="grid gap-6 lg:grid-cols-2">
          <div :for={rows <- [3, 4]} class={[card(), "p-5"]}>
            <div class="mb-5 h-5 w-32 rounded-badge bg-navy-100/60"></div>
            <div class="grid gap-4">
              <div :for={_row <- 1..rows} class="h-4 w-full rounded-badge bg-navy-100/60"></div>
            </div>
          </div>
        </div>
      </.skeleton>
    </div>
    """
  end

  # ── editing status ─────────────────────────────────────────────────────────

  @doc """
  The station's editing control: one secondary button that names the next action,
  and a sentence saying what it does. Editing status is a courtesy that tells
  teammates who is working here. It locks nothing, so the sentence says that too.
  """
  attr :status, :any, default: nil, doc: "the active editing status, or nil"
  attr :state, :atom, values: [:ready, :unavailable], default: :ready
  attr :current_user, :map, required: true

  def editing_control(%{state: :unavailable} = assigns) do
    ~H"""
    <div
      id="station-editing"
      phx-hook="FormErrorFocus"
      class="flex flex-col gap-1.5 sm:items-end"
    >
      <.button id="station-editing-status-button" variant="secondary" class="min-h-11" disabled>
        Start editing
      </.button>
      <p id="station-editing-hint" class="m-0 max-w-[32ch] text-[13px] text-muted sm:text-right">
        We couldn't check who is editing.
      </p>
      <button
        id="station-editing-reload"
        type="button"
        phx-click="retry_editing_status"
        class={[
          "inline-flex min-h-11 items-center font-[650] text-action hover:underline sm:self-end",
          focus()
        ]}
      >
        Reload status
      </button>
    </div>
    """
  end

  def editing_control(assigns) do
    assigns = assign(assigns, :owner?, editing_owner?(assigns.status, assigns.current_user))

    ~H"""
    <div
      id="station-editing"
      phx-hook="FormErrorFocus"
      class="flex flex-col gap-1.5 sm:items-end"
    >
      <.button
        id="station-editing-status-button"
        variant="secondary"
        class="min-h-11 max-sm:self-start"
        phx-click={editing_event(@status)}
        phx-disable-with={editing_busy_label(@status, @owner?)}
        aria-describedby="station-editing-hint"
      >
        {editing_label(@status, @owner?)}
      </.button>
      <p id="station-editing-hint" class="m-0 text-[13px] text-muted">
        {editing_hint(@status, @owner?)}
      </p>
    </div>
    """
  end

  @doc "Who is editing, what it means for the reader, and when it started."
  attr :status, :any, required: true
  attr :current_user, :map, required: true

  def editing_banner(assigns) do
    assigns = assign(assigns, :owner?, editing_owner?(assigns.status, assigns.current_user))

    ~H"""
    <.message
      id="station-editing-status-banner"
      kind={if @owner?, do: "info", else: "warning"}
      role="status"
      title={
        if @owner?,
          do: "You're editing this station.",
          else: "#{@status.user.email} is editing this station."
      }
    >
      <p :if={@owner?}>
        Teammates who open it see that you're editing. Select Finish editing when you're done.
      </p>
      <p :if={!@owner?}>
        You can view it, but it's best to wait before making changes. If they've finished, clear the status.
      </p>
      <p class="mt-1 text-[13px]">Started {relative_started_at(@status.started_at)}</p>
    </.message>
    """
  end

  @doc "An editing change that did not save, with the one control that repeats it."
  attr :kind, :atom, required: true, values: [:set, :clear]
  attr :status, :any, default: nil

  def editing_failure(assigns) do
    ~H"""
    <.message
      id="editing-error"
      kind="error"
      title={
        if @kind == :set,
          do: "We couldn't start editing",
          else: "We couldn't clear the editing status"
      }
    >
      {if @kind == :set,
        do: "Teammates won't see that you're editing. Try again.",
        else: "Teammates still see it. Try again."}
      <:action>
        <.button
          id="editing-error-retry"
          variant="secondary"
          class="min-h-11"
          phx-click={editing_event(@status)}
        >
          <.icon name="hero-arrow-path" class="size-4" /> Try again
        </.button>
      </:action>
    </.message>
    """
  end

  defp editing_owner?(nil, _current_user), do: false
  defp editing_owner?(status, current_user), do: status.user_id == current_user.id

  defp editing_event(nil), do: "set_station_editing_status"
  defp editing_event(_status), do: "clear_station_editing_status"

  defp editing_label(nil, _owner?), do: "Start editing"
  defp editing_label(_status, true), do: "Finish editing"
  defp editing_label(_status, false), do: "Clear editing status"

  defp editing_busy_label(nil, _owner?), do: "Starting…"
  defp editing_busy_label(_status, true), do: "Finishing…"
  defp editing_busy_label(_status, false), do: "Clearing…"

  defp editing_hint(nil, _owner?), do: "Lets teammates know you're editing."
  defp editing_hint(_status, true), do: "Tells teammates you're done."
  defp editing_hint(_status, false), do: "Clears the status for everyone."

  defp relative_started_at(%DateTime{} = started_at) do
    minutes =
      DateTime.utc_now()
      |> DateTime.diff(started_at, :second)
      |> max(0)
      |> div(60)

    cond do
      minutes == 0 -> "just now"
      minutes == 1 -> "1 minute ago"
      minutes < 60 -> "#{minutes} minutes ago"
      minutes < 120 -> "1 hour ago"
      true -> "#{div(minutes, 60)} hours ago"
    end
  end

  # ── location and service ───────────────────────────────────────────────────

  @doc """
  The stop page's More actions: the two operations that are not an edit, and
  the destructive one.

  A `<details>` disclosure rather than a button and a server-rendered menu,
  because this page has three links and no state: it opens and closes without a
  round trip, it works with JavaScript off, and it is keyboard operable without
  an event handler written for the purpose. Each link carries the Map view's
  `action=` so the panel the editor asked for is the one that opens, rather than
  the browse panel they would then have to open the panel from.

  The destructive action sits below a rule, says the verb and the object, and
  is styled in the error colour, so it reads as different in kind from the two
  that only change which panel is showing.
  """
  attr :id, :string, required: true
  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :stop, :map, required: true

  def stop_more_actions(assigns) do
    ~H"""
    <details id={@id} class="relative">
      <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas [&::-webkit-details-marker]:hidden">
        More actions <.icon name="hero-chevron-down" class="size-4" />
      </summary>

      <div
        class="absolute right-0 top-full z-30 mt-2 w-72 rounded-card border border-subtle bg-white p-2 shadow-float"
        role="menu"
        aria-label="More actions for this stop"
      >
        <.link
          :if={@stop.location_type != 1}
          id="stop-action-make-station"
          navigate={~p"/gtfs/#{@gtfs_version_id}/stops/map?stop=#{@stop_id}&action=make_station"}
          role="menuitem"
          class="flex min-h-11 flex-col justify-center rounded-control px-3 py-2 text-sm text-strong no-underline hover:bg-canvas"
        >
          Make this a station…<span class="text-[13px] text-muted">
            For a stop that is getting more bays
          </span>
        </.link>

        <.link
          id="stop-action-replace"
          navigate={~p"/gtfs/#{@gtfs_version_id}/stops/map?stop=#{@stop_id}&action=replace"}
          role="menuitem"
          class="flex min-h-11 flex-col justify-center rounded-control px-3 py-2 text-sm text-strong no-underline hover:bg-canvas"
        >
          Replace with another stop…<span class="text-[13px] text-muted">
            Moves its patterns and rules to a stop nearby
          </span>
        </.link>

        <div class="my-1 border-t border-subtle"></div>

        <.link
          id="stop-action-delete"
          navigate={~p"/gtfs/#{@gtfs_version_id}/stops/map?stop=#{@stop_id}&action=delete"}
          role="menuitem"
          class="flex min-h-11 items-center rounded-control px-3 text-sm font-semibold text-error-fg no-underline hover:bg-error-bg"
        >
          Delete stop…
        </.link>
      </div>
    </details>
    """
  end

  @doc """
  "Where this stop is used": the rows that name it, and nothing else.

  `StopReferences.usage/3` answers with a count per kind and, for the kinds an
  editor acts on, the rows themselves. Patterns are the rows worth naming —
  which route, which way, and how much weekday service — because that is what a
  rider recognises about a stop, and each one links to the pattern editor, which
  is where the pattern's stops are actually staged. Every other kind is one line
  with its count.

  The read is asynchronous on the page (`usage_state`), so the card renders a
  loading region and then the rows rather than blocking the rest of the page on
  fourteen queries. A read that fails is a warning with a retry, like the page's
  other regions, and it never reads as "nothing uses this stop".
  """
  attr :stop, :map, required: true
  attr :usage, :any, default: nil
  attr :usage_state, :atom, required: true, values: [:loading, :ready, :unavailable]
  attr :gtfs_version_id, :any, required: true
  attr :zone_name, :any, default: nil
  attr :class, :any, default: nil

  def usage_card(assigns) do
    ~H"""
    <section id="usage-card" aria-labelledby="usage-title" class={[card(), @class]}>
      <div class="px-5 pb-3 pt-4">
        <h2 id="usage-title" class={card_title()}>Where this stop is used</h2>
      </div>

      <%= case @usage_state do %>
        <% :loading -> %>
          <div
            id="usage-loading"
            role="status"
            aria-live="polite"
            class="border-t border-subtle px-5 py-4"
          >
            <p class="m-0 text-sm text-muted">Reading what uses this stop…</p>
          </div>
        <% :unavailable -> %>
          <div id="usage-unavailable" class="border-t border-subtle px-5 py-4">
            <.message kind="warning" title="What uses this stop could not be read">
              The rest of this page is unaffected. Reload to try again.
            </.message>
          </div>
        <% :ready -> %>
          <dl class="border-t border-subtle">
            <.fact_row label="Patterns" top?>
              <%= if @usage == nil or usage_patterns(@usage) == [] do %>
                <span id="usage-patterns-none" class="text-muted">
                  {if @stop.location_type == 1,
                    do: "No route calls at this station's bays.",
                    else: "No route serves this stop."}
                </span>
              <% else %>
                <ul id="usage-patterns" class="m-0 grid w-full list-none gap-2 p-0">
                  <li
                    :for={pattern <- usage_patterns(@usage)}
                    id={"usage-pattern-#{usage_dom_id(pattern.route_id)}-#{usage_dom_id(pattern.route_pattern_id)}"}
                    class="flex flex-wrap items-center gap-2"
                  >
                    <.usage_route_badge
                      short_name={pattern.route_short_name}
                      color={pattern.route_color}
                    />
                    <.text_link
                      id={"usage-pattern-link-#{usage_dom_id(pattern.route_id)}-#{usage_dom_id(pattern.route_pattern_id)}"}
                      navigate={
                        ~p"/gtfs/#{@gtfs_version_id}/routes/#{pattern.route_id}/patterns/#{pattern.route_pattern_id}?task=stops"
                      }
                      class="min-h-0 text-sm"
                    >
                      toward {pattern.headsign || "the end of the line"}
                    </.text_link>
                  </li>
                </ul>
                <span id="usage-weekday-trips" class="block text-[13px] text-muted">
                  {usage_trips_text(@usage)}
                </span>
              <% end %>
            </.fact_row>

            <.fact_row
              :for={row <- usage_count_rows(@usage, @zone_name)}
              label={row.label}
              id={row.dom_id}
            >
              <span :if={row.count_text} id={"#{row.dom_id}-count"}>{row.count_text}</span>
            </.fact_row>
          </dl>
      <% end %>
    </section>
    """
  end

  # The routes badge on a pattern row. The usage read joins the route in its own
  # organization and version and hands the two badge fields across, so the
  # detail page needs no second query for routes it will not otherwise draw.
  attr :short_name, :any, required: true
  attr :color, :any, default: nil

  defp usage_route_badge(assigns) do
    ~H"""
    <span
      class="inline-flex h-6 min-w-7 items-center justify-center rounded-badge px-1.5 text-[13px] font-bold text-white"
      style={usage_badge_style(assigns.color)}
    >
      {@short_name || "?"}
    </span>
    """
  end

  # A feed's route colour is six hexadecimal digits with or without the leading
  # `#` GTFS writes it without. Anything else is dropped rather than pasted into
  # a `style` attribute, so a hostile feed cannot close the attribute and
  # restyle the row; the badge falls back to the page's route blue.
  defp usage_badge_style("#" <> <<_::binary-size(6)>> = hex), do: "background: #{hex};"
  defp usage_badge_style(<<_::binary-size(6)>> = hex), do: "background: ##{hex};"
  defp usage_badge_style(_color), do: "background: #1f5fbf;"

  @doc false
  def usage_patterns(%{blocking: blocking}) do
    case Enum.find(blocking, &(&1.key == :route_pattern_stops)) do
      %{details: details} -> Enum.map(details, &usage_pattern/1)
      _unused -> []
    end
  end

  def usage_patterns(_usage), do: []

  # The usage read's pattern detail carries the badge fields the route join
  # picked up, so the card needs no second query for routes it will not
  # otherwise draw. The weekday trip count rides on the wrapper.
  defp usage_pattern(%{detail: pattern, weekday_trips: trips}) do
    Map.merge(pattern, %{route_id: pattern.route_id, weekday_trips: trips})
  end

  defp usage_trips_text(%{blocking: blocking} = usage) do
    case Enum.find(blocking, &(&1.key == :route_pattern_stops)) do
      %{details: details} when details != [] ->
        trips = details |> Enum.map(& &1.weekday_trips) |> Enum.sum()

        if trips == 0 do
          "No weekday trips recorded for these patterns."
        else
          "#{usage_count(trips, "weekday trip", "weekday trips")} stop here on weekdays."
        end

      _unused ->
        _ = usage
        "No weekday trips recorded."
    end
  end

  defp usage_trips_text(_usage), do: "No weekday trips recorded."

  # Everything that is not a pattern, one line each with its count. The fare
  # zone is read from the row the page already loaded rather than from the
  # usage, because it is the zone the stop is in and not a row that names it.
  defp usage_count_rows(%{blocking: blocking, descriptive: descriptive}, zone_name) do
    rows =
      Enum.flat_map(blocking ++ descriptive, fn
        %{key: :route_pattern_stops, label: _label, count: _count} ->
          []

        %{key: key, label: label, count: count} ->
          [usage_count_row(key, usage_label(key, label), count)]
      end)

    rows ++ [usage_zone_row(zone_name)]
  end

  defp usage_count_rows(_usage, zone_name), do: [usage_zone_row(zone_name)]

  # `StopReferences` labels each kind after the table it reads, which is the
  # right word for a delete review and the wrong one here: this card is about
  # what an editor touches, and "Map line sections from" is a join table's
  # name rather than a thing anybody does. The reader's words are here, and a
  # kind with no word of its own keeps the reference's own label.
  defp usage_label(:transfers_from, _label), do: "Transfer rules out"
  defp usage_label(:transfers_to, _label), do: "Transfer rules in"
  defp usage_label(:fare_leg_join_from, _label), do: "Fare rules out"
  defp usage_label(:fare_leg_join_to, _label), do: "Fare rules in"
  defp usage_label(:segments_from, _label), do: "Map lines"
  defp usage_label(:segments_to, _label), do: "Map lines"
  defp usage_label(:child_stops, _label), do: "Bays and platforms"
  defp usage_label(_key, label), do: label

  defp usage_count_row(key, label, count) do
    %{
      dom_id: "usage-#{usage_dom_id(key)}",
      label: label,
      count_text: usage_count(count, "row", "rows")
    }
  end

  defp usage_zone_row(zone_name) do
    %{
      dom_id: "usage-zone",
      label: "Fares",
      count_text: if(zone_name, do: "Zone #{zone_name}", else: "No fare zone recorded")
    }
  end

  defp usage_count(1, singular, _plural), do: "1 #{singular}"
  defp usage_count(count, _singular, plural), do: "#{count} #{plural}"

  defp usage_dom_id(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp usage_dom_id(value) when is_binary(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9_-]+\z/) do
      value
    else
      String.replace(value, ~r/[^A-Za-z0-9_-]/, "-")
    end
  end

  defp usage_dom_id(_value), do: "unknown"

  @doc "Where the place is: what it is called on the ground and its coordinates."
  attr :stop, :map, required: true
  attr :parent, :map, default: nil, doc: "`%{name: String.t(), navigate: String.t()}` or nil"
  attr :gtfs_version_id, :any, required: true
  attr :movable?, :boolean, default: false, doc: "the stop has coordinates a move could change"

  def location_card(assigns) do
    ~H"""
    <section id="location-card" aria-labelledby="location-title" class={card()}>
      <div class="flex flex-wrap items-center justify-between gap-3 px-5 pb-3 pt-4">
        <h2 id="location-title" class={card_title()}>Location</h2>
        <.button
          :if={@movable?}
          id="move-on-map"
          variant="secondary"
          class="min-h-11"
          navigate={~p"/gtfs/#{@gtfs_version_id}/stops/map?stop=#{@stop.stop_id}"}
        >
          <.icon name="hero-arrows-right-left" class="size-4" /> Move on map
        </.button>
      </div>
      <dl class="border-t border-subtle">
        <.fact_row :if={@parent} label="Part of">
          <.text_link id="stop-parent-link" navigate={@parent.navigate}>{@parent.name}</.text_link>
        </.fact_row>
        <.fact_row label="Description">
          <span :if={present?(@stop.stop_desc)} id="stop-description">{@stop.stop_desc}</span>
          <span :if={!present?(@stop.stop_desc)} id="stop-description" class="text-muted">
            No description.
          </span>
        </.fact_row>
        <.fact_row :if={coordinates(@stop)} label="Coordinates">
          <span id="stop-coordinates" class="tabular-nums">{coordinates(@stop)}</span>
        </.fact_row>
        <.fact_row :if={!coordinates(@stop)} label="Coordinates">
          <span id="stop-no-location" class="text-muted">No location recorded</span>
          <:hint>Coordinates come from the stops file in your feed.</:hint>
        </.fact_row>
        <.fact_row :if={@stop.location_type != 1 and present?(@stop.level_id)} label="Level">
          <span id="stop-level">{@stop.level_id}</span>
        </.fact_row>
        <.fact_row
          :if={@stop.location_type != 1 and present?(@stop.platform_code)}
          label="Platform code"
        >
          <span id="stop-platform-code">{@stop.platform_code}</span>
        </.fact_row>
      </dl>
    </section>
    """
  end

  @doc """
  What riders can do here: wheelchair access, fare zone, transfers and, for a
  station, how many of its levels have a floorplan.
  """
  attr :stop, :map, required: true
  attr :access, :map, required: true, doc: "`Stop.resolve_wheelchair_boarding/2` result"
  attr :gtfs_version_id, :any, required: true
  attr :fare_zone, :map, default: nil
  attr :platform_fare_zones, :list, default: []
  attr :child_stops_state, :atom, default: :ready
  attr :transfer_count, :integer, default: 0

  attr :levels, :any,
    default: :unavailable,
    doc: "the levels with floorplan status, or `:unavailable`"

  attr :in_station?, :boolean, default: false, doc: "the stop is inside a station"

  def service_card(assigns) do
    ~H"""
    <section id="facts-card" aria-labelledby="facts-title" class={card()}>
      <div class="px-5 pb-3 pt-4">
        <h2 id="facts-title" class={card_title()}>Service and access</h2>
      </div>
      <dl class="border-t border-subtle">
        <.fact_row label="Wheelchair access" id="stop-accessibility">
          <.access_status status={@access.status} source={@access.source} />
        </.fact_row>

        <.fact_row :if={@stop.location_type == 0} label="Fare zone">
          <span id="stop-fare-zone">{fare_zone_label(@fare_zone)}</span>
          <.text_link
            id="stop-fare-zone-link"
            navigate={fares_zone_path(@gtfs_version_id, @fare_zone && @fare_zone.zone_id)}
          >
            View in Fares
          </.text_link>
        </.fact_row>

        <.fact_row :if={@stop.location_type == 1} label="Fare zones">
          <%= cond do %>
            <% @child_stops_state == :unavailable -> %>
              <span id="station-platform-fare-zones">—</span>
            <% @platform_fare_zones == [] -> %>
              <span id="station-platform-fare-zones" class="text-muted">None</span>
            <% true -> %>
              <ul id="station-platform-fare-zones" class="flex flex-wrap items-center gap-x-4">
                <li :for={{zone, index} <- Enum.with_index(@platform_fare_zones)}>
                  <.text_link
                    id={"platform-fare-zone-#{index}"}
                    navigate={fares_zone_path(@gtfs_version_id, zone.zone_id)}
                  >
                    {fare_zone_label(zone)}
                  </.text_link>
                </li>
              </ul>
          <% end %>
          <:hint>From this station's platforms.</:hint>
        </.fact_row>

        <.fact_row label="Transfers">
          <.text_link
            id="stop-transfers-link"
            navigate={~p"/gtfs/#{@gtfs_version_id}/transfers?#{[stop: @stop.stop_id]}"}
          >
            {transfers_label(@transfer_count)} <.icon name="hero-arrow-right" class="size-4" />
          </.text_link>
        </.fact_row>

        <.fact_row :if={@stop.location_type == 1 and floorplan_summary(@levels)} label="Floorplans">
          <span id="station-floorplans-status">{floorplan_summary(@levels)}</span>
        </.fact_row>

        <.fact_row :if={@in_station?} label="Floorplan">
          <span :if={@stop.diagram_coordinate} id="diagram-status">Placed on a floorplan</span>
          <span :if={!@stop.diagram_coordinate} id="diagram-status" class="text-muted">
            Not on a floorplan
          </span>
        </.fact_row>
      </dl>
    </section>
    """
  end

  # ── inside a station ───────────────────────────────────────────────────────

  @doc """
  What is inside a station, floor by floor. Each floor is one card with its
  floorplan status and the stops on it; stops with no level get their own card,
  because pathways cannot use them yet.
  """
  attr :floors, :list, required: true, doc: "from `build_floors/2`"
  attr :child_stops_state, :atom, required: true
  attr :levels_state, :atom, required: true
  attr :stop, :map, required: true
  attr :gtfs_version_id, :any, required: true

  def inside(assigns) do
    ~H"""
    <section id="inside" aria-labelledby="inside-title" class="mt-10">
      <h2 id="inside-title" class={card_title()}>Inside this station</h2>
      <p class="mt-1 text-sm text-muted">
        Platforms, entrances and connection points, floor by floor.
      </p>
      <div class="mt-4 grid gap-4">
        <.region_error
          :if={@child_stops_state == :unavailable}
          id="child-stops-unavailable"
          title="The stops inside this station didn't load"
          retry_id="child-stops-retry"
          event="retry_child_stops"
          label="Reload stops"
        >
          The rest of the page is unaffected. Reload to see platforms, entrances and connection points.
        </.region_error>
        <.region_error
          :if={@levels_state == :unavailable}
          id="levels-unavailable"
          title="Floorplan status didn't load"
          retry_id="levels-retry"
          event="retry_levels"
          label="Reload levels"
        >
          Stops are grouped by level below. Reload to see which levels have floorplans.
        </.region_error>

        <div
          :if={@floors == [] and @child_stops_state == :ready and @levels_state == :ready}
          id="inside-empty"
          class="rounded-card border border-subtle bg-white px-6 py-9 text-center"
        >
          <div class="mx-auto max-w-[520px]">
            <span class="mx-auto grid size-12 place-items-center rounded-full bg-canvas text-muted">
              <.icon name="hero-square-3-stack-3d" class="size-6" />
            </span>
            <h3 class="mt-4 text-lg font-bold text-strong">Nothing is inside this station yet</h3>
            <p class="mt-1.5 text-sm text-muted">
              Platforms, entrances, levels and pathways you add in Floorplans appear here, floor by floor.
            </p>
            <div class="mt-5">
              <.text_link
                id="inside-empty-floorplans"
                navigate={diagram_path(@gtfs_version_id, @stop)}
              >
                Add stops in Floorplans <.icon name="hero-arrow-right" class="size-4" />
              </.text_link>
            </div>
          </div>
        </div>

        <.floor_card
          :for={floor <- @floors}
          floor={floor}
          stop={@stop}
          gtfs_version_id={@gtfs_version_id}
        />
      </div>
    </section>
    """
  end

  attr :floor, :map, required: true
  attr :stop, :map, required: true
  attr :gtfs_version_id, :any, required: true

  defp floor_card(assigns) do
    ~H"""
    <section id={"level-#{@floor.id}"} aria-labelledby={"level-#{@floor.id}-title"} class={card()}>
      <div
        :if={@floor.no_level?}
        class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle bg-warning-bg px-5 py-3.5 text-warning-fg"
      >
        <.icon name="hero-exclamation-triangle" class="size-[18px] shrink-0" />
        <div class="min-w-0 flex-1">
          <h3 id={"level-#{@floor.id}-title"} class="text-base font-bold">
            No level assigned
            <span class="font-normal">· {plural(length(@floor.stops), "stop")}</span>
          </h3>
          <p class="text-[13px]">Pathways can't use a stop until it has a level.</p>
        </div>
      </div>

      <div
        :if={!@floor.no_level?}
        class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle bg-canvas px-5 py-3.5"
      >
        <div class="min-w-0 flex-1 basis-[180px]">
          <h3 id={"level-#{@floor.id}-title"} class="text-base font-bold text-strong">
            {@floor.name}
          </h3>
          <p class="text-[13px] text-muted">{floor_caption(@floor)}</p>
        </div>
        <p
          :if={@floor.floorplan != :unknown}
          id={"diagram-status-#{@floor.id}"}
          class="inline-flex items-center gap-1.5 text-[13px] text-muted"
        >
          <.icon :if={@floor.floorplan == :added} name="hero-check-circle" class="size-4" />
          {if @floor.floorplan == :added, do: "Floorplan added", else: "No floorplan yet"}
        </p>
      </div>

      <p :if={@floor.stops == nil} class="px-5 py-4 text-sm text-muted">
        Stops on this level aren't available until they reload.
      </p>
      <p :if={@floor.stops == []} class="px-5 py-4 text-sm text-muted">
        No stops on this level yet. Add them in Floorplans.
      </p>
      <.stops_table
        :if={@floor.stops not in [nil, []]}
        floor={@floor}
        stop={@stop}
        gtfs_version_id={@gtfs_version_id}
      />
    </section>
    """
  end

  attr :floor, :map, required: true
  attr :stop, :map, required: true
  attr :gtfs_version_id, :any, required: true

  defp stops_table(assigns) do
    ~H"""
    <table
      id={"level-#{@floor.id}-stops"}
      class="w-full border-collapse text-left text-sm max-md:block"
    >
      <thead class="max-md:hidden">
        <tr>
          <th scope="col" class={[th_class(), "pl-5 pr-3"]}>
            <span class="flex min-h-10 items-center">Stop</span>
          </th>
          <th scope="col" class={[th_class(), "w-[34%] px-3"]}>
            <span class="flex min-h-10 items-center">Wheelchair access</span>
          </th>
          <th scope="col" class={[th_class(), "w-[120px] pl-3 pr-5"]}>
            <span class="sr-only">Action</span>
          </th>
        </tr>
      </thead>
      <tbody class="max-md:block">
        <tr
          :for={child <- @floor.stops}
          id={"child-stop-row-#{child.id}"}
          class="border-b border-subtle last:border-b-0 hover:bg-canvas max-md:block max-md:px-4 max-md:py-3"
        >
          <th scope="row" class="py-2 pl-5 pr-3 text-left font-normal max-md:block max-md:p-0">
            <span class="block font-[650] leading-snug text-strong">
              {child.stop_name || child.stop_id}
            </span>
            <span class="block text-[13px] text-muted">
              {child_caption(child)} · <span class="font-mono text-[12px]">{child.stop_id}</span>
            </span>
          </th>
          <td class="px-3 py-2 max-md:mt-1.5 max-md:block max-md:p-0">
            <% resolved = Stop.resolve_wheelchair_boarding(child, @stop) %>
            <.access_status status={resolved.status} source={resolved.source} />
          </td>
          <td class="py-1 pl-3 pr-5 text-right max-md:block max-md:p-0 max-md:text-left">
            <.text_link
              :if={@floor.no_level?}
              id={"assign-level-#{child.id}"}
              navigate={
                ~p"/gtfs/#{@gtfs_version_id}/stops/#{@stop.stop_id}/diagram?edit_child_stop_id=#{child.id}"
              }
            >
              Assign level
            </.text_link>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp th_class, do: "border-b border-subtle bg-white py-0 text-[13px] font-[650] text-muted"

  # ── pathways ───────────────────────────────────────────────────────────────

  @doc """
  How riders move between points in the station: each pathway named by the two
  points it joins. The first few show, and one control reveals the rest.
  """
  attr :state, :atom, required: true, values: [:ready, :unavailable]
  attr :pathways, :any, required: true, doc: "the `:pathways` stream"
  attr :count, :integer, required: true
  attr :empty?, :boolean, required: true
  attr :expanded?, :boolean, required: true
  attr :stop, :map, required: true
  attr :gtfs_version_id, :any, required: true

  def pathways_card(assigns) do
    ~H"""
    <section id="pathways-card" aria-labelledby="pathways-title" class={card()}>
      <div class="px-5 pb-3 pt-4">
        <h2 id="pathways-title" class={card_title()}>
          Pathways
          <span
            :if={@state == :ready and @count > 0}
            class="ml-1 align-middle text-sm font-[650] tabular-nums text-muted"
          >
            {@count}
          </span>
        </h2>
        <p class="mt-1 text-sm text-muted">
          How riders can walk, ride or climb between points in the station.
        </p>
      </div>

      <div class="border-t border-subtle">
        <div :if={@state == :unavailable} class="p-4">
          <.region_error
            id="pathways-unavailable"
            title="Pathways didn't load"
            retry_id="pathways-retry"
            event="retry_pathways"
            label="Reload pathways"
          >
            The rest of the page is unaffected. Reload to see how riders move through this station.
          </.region_error>
        </div>

        <div :if={@state == :ready and @empty?} id="pathways-empty" class="px-6 py-8 text-center">
          <h3 class="text-base font-bold text-strong">No pathways yet</h3>
          <p class="mx-auto mt-1 max-w-[44ch] text-sm text-muted">
            A pathway is a walkway, stairway, elevator or gate between two points in the station. Draw them in Floorplans.
          </p>
          <div class="mt-3">
            <.text_link
              id="pathways-empty-floorplans"
              navigate={diagram_path(@gtfs_version_id, @stop)}
            >
              Draw pathways in Floorplans <.icon name="hero-arrow-right" class="size-4" />
            </.text_link>
          </div>
        </div>

        <table
          :if={@state == :ready and not @empty?}
          id="pathways-table"
          class="w-full border-collapse text-left text-sm max-md:block"
        >
          <thead class="max-md:hidden">
            <tr>
              <th scope="col" class={[th_class(), "bg-canvas pl-5 pr-3"]}>
                <span class="flex min-h-10 items-center">Connection</span>
              </th>
              <th scope="col" class={[th_class(), "w-[130px] bg-canvas px-3"]}>
                <span class="flex min-h-10 items-center">Type</span>
              </th>
              <th scope="col" class={[th_class(), "w-[84px] bg-canvas px-3 text-right"]}>
                <span class="flex min-h-10 items-center justify-end">Length</span>
              </th>
              <th scope="col" class={[th_class(), "w-[84px] bg-canvas pl-3 pr-5 text-right"]}>
                <span class="flex min-h-10 items-center justify-end">Time</span>
              </th>
            </tr>
          </thead>
          <tbody id="pathways-rows" phx-update="stream" class="max-md:block">
            <tr
              :for={{dom_id, pathway} <- @pathways}
              id={dom_id}
              data-pathway-summary
              class="border-b border-subtle last:border-b-0 hover:bg-canvas max-md:block max-md:px-4 max-md:py-3"
            >
              <th scope="row" class="py-2.5 pl-5 pr-3 text-left font-normal max-md:block max-md:p-0">
                <span class="font-[650] text-strong">
                  {pathway_end(pathway, :from)}
                  <.pathway_arrow bidirectional?={pathway.is_bidirectional != false} />
                  {pathway_end(pathway, :to)}
                </span>
                <span class="block font-mono text-[12px] text-muted">{pathway.pathway_id}</span>
              </th>
              <td class="px-3 py-2.5 max-md:mt-1 max-md:inline-block max-md:p-0 max-md:pr-3">
                {Pathway.mode_label(pathway.pathway_mode)}
                <span
                  :if={pathway.pathway_mode == 2 and pathway.stair_count}
                  class="text-[13px] text-muted md:block max-md:before:mr-1 max-md:before:content-['·']"
                >
                  {pathway.stair_count} stairs
                </span>
              </td>
              <td class="px-3 py-2.5 text-right max-md:inline-block max-md:p-0 max-md:pr-3 max-md:text-left">
                <.metric value={pathway.length} unit="m" label="Length" />
              </td>
              <td class="py-2.5 pl-3 pr-5 text-right max-md:inline-block max-md:p-0 max-md:text-left">
                <.metric value={pathway.traversal_time} unit="s" label="Time" />
              </td>
            </tr>
          </tbody>
        </table>

        <div
          :if={@state == :ready and @count > pathways_shown()}
          class="border-t border-subtle px-3 py-1"
        >
          <button
            id="pathways-toggle"
            type="button"
            phx-click="toggle_pathways"
            aria-expanded={to_string(@expanded?)}
            class={[text_link_class(), "px-2", focus()]}
          >
            {if @expanded?, do: "Show fewer pathways", else: "Show all #{@count} pathways"}
            <.icon name="hero-chevron-down" class={["size-4", @expanded? && "rotate-180"]} />
          </button>
        </div>
      </div>
    </section>
    """
  end

  attr :bidirectional?, :boolean, required: true

  defp pathway_arrow(assigns) do
    ~H"""
    <span aria-hidden="true" class="font-normal text-muted">
      {if @bidirectional?, do: "↔", else: "→"}
    </span>
    <span class="sr-only">{if @bidirectional?, do: "and back to", else: "to"}</span>
    """
  end

  attr :value, :any, required: true
  attr :unit, :string, required: true
  attr :label, :string, required: true

  # A length or time the feed does not give reads "not set" to a screen reader
  # instead of a bare dash.
  defp metric(assigns) do
    ~H"""
    <span :if={!blank_metric?(@value)} class="tabular-nums">
      {metric_text(@value)} <span class="text-muted">{@unit}</span>
    </span>
    <span :if={blank_metric?(@value)} class="text-muted">
      <span aria-hidden="true">—</span><span class="sr-only">{@label} not set</span>
    </span>
    """
  end

  defp blank_metric?(nil), do: true
  defp blank_metric?(_value), do: false

  # The feed stores a length to the centimetre; "14.00 m" reads as false precision.
  defp metric_text(%Decimal{} = value),
    do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp metric_text(value), do: to_string(value)

  defp pathway_end(pathway, which) do
    stop = Map.get(pathway, if(which == :from, do: :from_stop, else: :to_stop))
    stop_id = Map.get(pathway, if(which == :from, do: :from_stop_id, else: :to_stop_id))

    case stop do
      %{stop_name: name} when is_binary(name) and name != "" -> name
      _ -> stop_id
    end
  end

  # ── journal ────────────────────────────────────────────────────────────────

  @doc """
  The journal summary: counts, the three newest entries, and each state the load
  can be in. A refresh that fails after a first load keeps the entries and says
  they may be out of date.
  """
  attr :state, :atom, required: true, values: [:idle, :loading, :ready, :error]
  attr :loaded_once?, :boolean, required: true
  attr :entries_empty?, :boolean, required: true
  attr :open_count, :integer, required: true
  attr :closed_count, :integer, required: true
  attr :entries, :any, required: true, doc: "the `:journal_recent_entries` stream"
  attr :targets, :map, required: true
  attr :local_times, :map, required: true
  attr :now, :any, required: true
  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true

  def journal_card(assigns) do
    ~H"""
    <section
      id="station-journal-summary"
      aria-labelledby="station-journal-title"
      aria-busy={to_string(@state == :loading)}
      class={card()}
    >
      <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 px-5 pb-3 pt-4">
        <div>
          <h2 id="station-journal-title" class={card_title()}>Journal</h2>
          <p class="mt-1 text-sm text-muted">Field notes and photos for this station.</p>
        </div>
        <div :if={not @entries_empty? and @loaded_once?} class="flex flex-wrap items-center gap-1.5">
          <span id="station-journal-open-count" class={count_badge()}>{@open_count} open</span>
          <span id="station-journal-closed-count" class={count_badge()}>{@closed_count} closed</span>
          <button
            id="journal-summary-refresh"
            type="button"
            phx-click={@state != :loading && "retry_journal"}
            class={[
              "grid size-11 min-h-11 min-w-11 place-items-center rounded-control text-muted hover:bg-canvas hover:text-strong",
              focus()
            ]}
            aria-label="Refresh journal entries"
            title="Refresh journal entries"
            aria-busy={to_string(@state == :loading)}
            aria-disabled={to_string(@state == :loading)}
          >
            <.icon
              name="hero-arrow-path"
              class={["size-4", @state == :loading && "motion-safe:animate-spin"]}
            />
          </button>
        </div>
      </div>

      <div class="border-t border-subtle">
        <%= cond do %>
          <% @state == :loading and not @loaded_once? -> %>
            <.skeleton
              id="journal-summary-loading"
              label="Loading journal entries"
              role="status"
              aria-live="polite"
              aria-busy="true"
              aria-atomic="true"
              class="journal-loading-delay p-5"
            >
              <div class="grid gap-4">
                <div :for={_row <- 1..3} class="grid gap-2">
                  <div class="h-3.5 w-11/12 rounded-badge bg-navy-100/60"></div>
                  <div class="h-3 w-1/3 rounded-badge bg-navy-100/60"></div>
                </div>
              </div>
            </.skeleton>
          <% @state == :error and not @loaded_once? -> %>
            <div class="p-4">
              <.region_error
                id="station-journal-unavailable"
                title="The journal didn't load"
                retry_id="station-journal-retry"
                event="retry_journal"
                label="Reload journal"
              >
                The rest of the page is unaffected. Reload to see notes and photos from the field.
              </.region_error>
            </div>
          <% @state == :error and @entries_empty? -> %>
            <div class="p-4 pb-0">
              <.region_error
                id="station-journal-refresh-warning"
                title="The journal may be out of date"
                retry_id="station-journal-retry"
                event="retry_journal"
                label="Reload journal"
                role="status"
              >
                Showing the last successful load, which had no entries.
              </.region_error>
            </div>
            <.journal_empty />
          <% @state == :error -> %>
            <div class="p-4">
              <.region_error
                id="station-journal-refresh-warning"
                title="The journal may be out of date"
                retry_id="station-journal-retry"
                event="retry_journal"
                label="Reload journal"
                role="status"
              >
                The last saved entries are still shown.
              </.region_error>
            </div>
            <.journal_rows
              entries={@entries}
              targets={@targets}
              local_times={@local_times}
              now={@now}
              gtfs_version_id={@gtfs_version_id}
              stop_id={@stop_id}
            />
          <% @entries_empty? -> %>
            <.journal_empty />
          <% true -> %>
            <.journal_rows
              entries={@entries}
              targets={@targets}
              local_times={@local_times}
              now={@now}
              gtfs_version_id={@gtfs_version_id}
              stop_id={@stop_id}
            />
        <% end %>
      </div>
    </section>
    """
  end

  defp journal_empty(assigns) do
    ~H"""
    <div id="station-journal-empty" class="px-6 py-8 text-center">
      <h3 class="text-base font-bold text-strong">No journal entries yet</h3>
      <p class="mx-auto mt-1 max-w-[40ch] text-sm text-muted">
        Notes and photos captured at this station with the Pathways field companion appear here for review.
      </p>
    </div>
    """
  end

  attr :entries, :any, required: true
  attr :targets, :map, required: true
  attr :local_times, :map, required: true
  attr :now, :any, required: true
  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true

  defp journal_rows(assigns) do
    ~H"""
    <div
      id="station-journal-summary-list"
      phx-update="stream"
      class="divide-y divide-subtle"
    >
      <.link
        :for={{dom_id, entry} <- @entries}
        id={dom_id}
        data-role="journal-summary-entry"
        navigate={
          ~p"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}/diagram?journal=open&entry_id=#{entry.id}"
        }
        class="block px-5 py-3 text-strong no-underline hover:bg-canvas focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
      >
        <span class={[
          "block text-sm line-clamp-2",
          if(is_nil(entry.closed_at), do: "text-strong", else: "text-muted")
        ]}>
          {entry.body}
        </span>
        <span class="mt-1.5 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-[13px] text-muted">
          <span class="inline-flex max-w-full items-center truncate rounded-badge border border-subtle px-1.5 py-px">
            {journal_target_label(entry, @targets)}
          </span>
          <span :if={not is_nil(entry.closed_at)} class={count_badge()}>Closed</span>
          <span class="ml-auto tabular-nums">
            <time datetime={DateTime.to_iso8601(entry.captured_at)}>
              {StationJournalComponents.relative_time(
                journal_local_time(entry, @local_times),
                @now
              )}
            </time>
          </span>
        </span>
      </.link>
    </div>
    <div class="border-t border-subtle px-3 py-1">
      <.text_link
        id="journal-footer-link"
        navigate={~p"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}/diagram?journal=open"}
        class="px-2"
      >
        Open journal in Floorplans <.icon name="hero-arrow-right" class="size-4" />
      </.text_link>
    </div>
    """
  end

  defp count_badge do
    "inline-flex items-center rounded-badge bg-canvas px-2 py-0.5 text-[13px] font-[650] leading-normal text-muted"
  end

  defp journal_target_label(entry, targets) do
    target_key = if entry.target_type == "pin", do: entry.stop_level_id, else: entry.target_id

    case {entry.target_type, Map.get(targets, target_key)} do
      {"station", _} -> "Station"
      {type, nil} -> String.capitalize(type)
      {type, %{label: label}} -> "#{String.capitalize(type)} · #{label}"
    end
  end

  defp journal_local_time(entry, local_times) do
    case Map.get(local_times, {entry.id, :captured}) do
      %NaiveDateTime{} = local -> local
      _ -> entry.captured_at |> DateTime.to_naive()
    end
  end

  # ── GTFS fields ────────────────────────────────────────────────────────────

  @doc """
  The stored fields behind the page, for someone matching it to a feed export.
  They sit behind a disclosure so the page leads with what riders see.
  """
  attr :stop, :map, required: true

  def gtfs_fields(assigns) do
    stop = assigns.stop

    fields =
      [
        {"stop_id", stop.stop_id},
        {"stop_name", stop.stop_name},
        {"location_type",
         "#{Stop.location_type_label(stop.location_type)} (#{stop.location_type})"},
        {"stop_desc", stop.stop_desc},
        {"stop_lat", stop.stop_lat && Decimal.to_string(stop.stop_lat, :normal)},
        {"stop_lon", stop.stop_lon && Decimal.to_string(stop.stop_lon, :normal)},
        {"parent_station", stop.parent_station},
        {"level_id", stop.level_id},
        {"platform_code", stop.platform_code},
        {"stop_code", stop.stop_code},
        {"tts_stop_name", stop.tts_stop_name},
        {"stop_url", stop.stop_url},
        {"zone_id", stop.zone_id},
        {"stop_timezone", stop.stop_timezone}
      ]
      |> Enum.reject(fn {name, value} -> name == "parent_station" and not present?(value) end)

    assigns =
      assigns
      |> assign(:fields, fields)
      |> assign(:kind, stop |> stop_kind() |> String.downcase())

    ~H"""
    <details id="gtfs-details" class="group mt-10 rounded-card border border-subtle bg-white">
      <summary class={[
        "flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 px-5 py-2 text-sm font-[650] text-strong hover:bg-canvas [&::-webkit-details-marker]:hidden",
        focus()
      ]}>
        <span>
          GTFS fields for this {@kind}
          <span class="ml-2 font-normal text-muted">For feed exports and troubleshooting</span>
        </span>
        <.icon
          name="hero-chevron-down"
          class="size-4 text-muted transition-transform group-open:rotate-180"
        />
      </summary>
      <dl class="grid gap-x-8 gap-y-3 border-t border-subtle px-5 py-4 sm:grid-cols-2 lg:grid-cols-3">
        <div :for={{name, value} <- @fields} class="min-w-0">
          <dt class="font-mono text-[12px] text-muted">{name}</dt>
          <dd class="break-words text-sm text-strong">
            <span :if={present?(value)}>{value}</span>
            <span :if={!present?(value)} class="text-muted">—</span>
          </dd>
        </div>
      </dl>
    </details>
    """
  end

  # ── pure helpers ───────────────────────────────────────────────────────────

  @doc "How many pathways show before the reveal control."
  def pathways_shown, do: @pathways_shown

  @doc """
  What kind of record this is, in the words a reader uses. A stop with a parent
  station is a platform; the same location type with no parent is a stop.
  """
  def stop_kind(%{location_type: 0, parent_station: parent}) when parent in [nil, ""], do: "Stop"
  def stop_kind(%{location_type: 0}), do: "Platform"
  def stop_kind(%{location_type: 1}), do: "Station"
  def stop_kind(%{location_type: 2}), do: "Entrance"
  def stop_kind(%{location_type: 3}), do: "Connection point"
  def stop_kind(%{location_type: 4}), do: "Boarding area"
  def stop_kind(_stop), do: "Stop"

  @doc """
  The line under the name, before the identifier. A station counts what is inside
  it; anything else names its kind.

  `child_stops` and `levels` are the loaded lists or `:unavailable`, so a region
  that failed to load is left out of the count instead of reading as zero.
  """
  def inventory(%{location_type: 1}, :unavailable, _levels), do: "Station"
  def inventory(%{location_type: 1}, [], _levels), do: "Station · nothing added yet"

  def inventory(%{location_type: 1}, child_stops, levels) do
    count = fn types -> Enum.count(child_stops, &(&1.location_type in types)) end

    parts =
      [plural(count.([0]), "platform"), plural(count.([2]), "entrance")] ++
        Enum.reject(
          [
            if(count.([3, 4]) > 0, do: plural(count.([3, 4]), "connection point")),
            if(is_list(levels) and levels != [], do: plural(length(levels), "level"))
          ],
          &is_nil/1
        )

    "Station · " <> Enum.join(parts, ", ")
  end

  def inventory(stop, _child_stops, _levels), do: stop_kind(stop)

  @doc """
  Groups a station's stops by floor, ground first and below-ground last.

  `levels` is what `Gtfs.list_levels_for_station/3` returns, and `child_stops`
  what `Gtfs.list_child_stops_for_parent/3` returns; either may be `:unavailable`.
  A floor's `:stops` is `nil` when the stops did not load, and its `:floorplan` is
  `:unknown` when the levels did not. Stops with no level form a last floor with
  `no_level?: true`.
  """
  def build_floors(:unavailable, :unavailable), do: []

  def build_floors(levels, child_stops) do
    by_level =
      if child_stops == :unavailable, do: %{}, else: Enum.group_by(child_stops, &child_level_id/1)

    declared =
      if levels == :unavailable,
        do: [],
        else: Enum.map(levels, &declared_floor(&1, by_level, child_stops))

    declared_ids = MapSet.new(declared, & &1.id)

    # A level the levels list did not report can still hold stops, when only the
    # levels region failed to load.
    undeclared =
      for {level_id, [%{level: level} | _] = stops} <- by_level,
          level_id != nil,
          not MapSet.member?(declared_ids, level_id) do
        floor(level, :unknown, stops)
      end

    Enum.sort_by(declared ++ undeclared, &level_order(&1.index)) ++ no_level_floor(by_level)
  end

  defp declared_floor(%{level: level, diagram_filename: filename}, by_level, child_stops) do
    stops = if child_stops == :unavailable, do: nil, else: Map.get(by_level, level.level_id, [])
    floor(level, if(present?(filename), do: :added, else: :missing), stops)
  end

  defp floor(level, floorplan, stops) do
    %{
      id: level.level_id,
      name: level.level_name || level.level_id,
      index: level.level_index,
      floorplan: floorplan,
      stops: stops,
      no_level?: false
    }
  end

  defp no_level_floor(by_level) do
    case Map.get(by_level, nil, []) do
      [] ->
        []

      stops ->
        [
          %{
            id: "none",
            name: "No level assigned",
            index: nil,
            floorplan: :unknown,
            stops: stops,
            no_level?: true
          }
        ]
    end
  end

  defp child_level_id(%{level: %{level_id: level_id}}), do: level_id
  defp child_level_id(_stop), do: nil

  # Ground is 0, upper floors count up and below-ground counts down, so a
  # station's street level comes first instead of its lowest basement.
  defp level_order(nil), do: 2_000
  defp level_order(index) when index >= 0, do: index
  defp level_order(index), do: 1_000 - index

  defp floor_caption(floor) do
    [level_index_label(floor.index), floor.stops && plural(length(floor.stops), "stop")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp level_index_label(nil), do: nil

  defp level_index_label(index) do
    if trunc(index) == index,
      do: "Level #{trunc(index)}",
      else: "Level #{index}"
  end

  defp child_caption(child) do
    [stop_kind(child), present?(child.platform_code) && "code #{child.platform_code}"]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp floorplan_summary(:unavailable), do: nil
  defp floorplan_summary([]), do: nil

  defp floorplan_summary(levels) do
    with_plan = Enum.count(levels, &present?(&1.diagram_filename))

    "#{with_plan} of #{plural(length(levels), "level")} #{if with_plan == 1, do: "has", else: "have"} a floorplan"
  end

  defp transfers_label(0), do: "No transfer rules here"
  defp transfers_label(count), do: "#{plural(count, "transfer rule")} here"

  defp coordinates(%{stop_lat: %Decimal{} = lat, stop_lon: %Decimal{} = lon}) do
    "#{Decimal.to_string(lat, :normal)}, #{Decimal.to_string(lon, :normal)}"
  end

  defp coordinates(_stop), do: nil

  defp diagram_path(gtfs_version_id, stop),
    do: ~p"/gtfs/#{gtfs_version_id}/stops/#{stop.stop_id}/diagram"

  # Every Fares link is built here, so the zone travels as its own query key
  # through `URI.encode_query/1` and `filter=unassigned` stays a different key
  # from `zone`. No zone ID reaches a DOM ID.
  defp fares_zone_path(gtfs_version_id, nil) do
    "/gtfs/#{gtfs_version_id}/settings/fares?" <> URI.encode_query(%{"filter" => "unassigned"})
  end

  defp fares_zone_path(gtfs_version_id, zone_id) do
    "/gtfs/#{gtfs_version_id}/settings/fares?" <> URI.encode_query(%{"zone" => zone_id})
  end

  # The zone as "name · ID", which is how the workspace names a zone; an
  # undeclared zone's name is its own ID, so the entry never reads as blank, and
  # a stop with no zone reads "None".
  defp fare_zone_label(nil), do: "None"

  defp fare_zone_label(%{zone_id: zone_id, name: name}) when is_binary(name) and name != "" do
    "#{name} · #{zone_id}"
  end

  defp fare_zone_label(%{zone_id: zone_id}), do: zone_id

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"
end
