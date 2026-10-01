defmodule GtfsPlannerWeb.Gtfs.AlertComponents do
  @moduledoc """
  The Alerts list page's own components: the four-tab strip, one alert row and
  the message an empty tab shows.

  All three are renderings of what `Alerts.list_alerts/2` already derived.
  Nothing here computes a tab, a count or a badge: the read model owns those, so
  a row cannot disagree with the count in its own tab (AC-9, R8).

  The page shows what an editor is working on now and what is coming. It shows
  no publication state and no publication action, because saving an alert never
  publishes one in this package (R2, CR-1). The words Live, Scheduled, Ended and
  feed therefore appear nowhere in this module.
  """

  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [status_badge: 1]

  alias GtfsPlannerWeb.Components.RouteIdentity

  # The four tabs in the order the read model groups them, with the words the
  # prototype uses for each. `in_progress` is In progress rather than Drafts:
  # this package saves an alert, it never schedules one.
  defp tab_items do
    [
      {:current, "Current"},
      {:upcoming, "Upcoming"},
      {:in_progress, "In progress"},
      {:past, "Past"}
    ]
  end

  # What each tab holds, in the reader's words rather than the reader's guess.
  @tab_empty %{
    current: {
      "Nothing is in effect",
      "No alert covers today. Riders see your scheduled service until you create one."
    },
    upcoming: {
      "Nothing is planned yet",
      "Planned work, holidays and events can be prepared ahead of the day they apply."
    },
    in_progress: {
      "No alerts in progress",
      "An alert you have started but not finished appears here until you save it as complete."
    },
    past: {
      "No earlier alerts",
      "An alert appears here once its last date has passed. It stays readable, and you can reuse it."
    }
  }

  @doc """
  Renders the `Current · N | Upcoming · N | In progress · N | Past · N` strip.

  The count is in the tab's own label, because the question a reader opens this
  page with is "how much is there", and a count they can see is one fewer click
  for the answer. Each tab is a link that patches `?tab=`, so the selected tab
  is in the URL and a reload or a shared link keeps it.

  `role="tablist"` with `aria-selected` on the pressed tab, and the pressed tab
  also carries `aria-current="page"`, so the selection is never signalled by
  colour alone.
  """
  attr :version_id, :any, required: true
  attr :tab, :atom, required: true
  attr :counts, :map, required: true, doc: "the four tab counts, keyed by tab atom"

  def tabs(assigns) do
    ~H"""
    <nav
      id="alerts-tabs"
      aria-label="Alerts by state"
      class="mt-6 flex gap-1 overflow-x-auto border-b border-subtle"
    >
      <.link
        :for={{key, label} <- tab_items()}
        id={"alerts-tab-#{key}"}
        patch={"/gtfs/#{@version_id}/alerts?tab=#{key}"}
        role="tab"
        aria-selected={to_string(@tab == key)}
        aria-current={@tab == key && "page"}
        data-count={Map.get(@counts, key, 0)}
        class={[
          "-mb-px inline-flex min-h-11 shrink-0 items-center gap-2 border-b-2 px-3 text-sm font-semibold no-underline",
          @tab == key && "border-action text-action",
          @tab != key && "border-transparent text-muted hover:text-strong"
        ]}
      >
        {label}
        <span class={[
          "rounded-badge px-1.5 text-[12px] font-bold tabular-nums",
          @tab == key && "bg-selection text-action",
          @tab != key && "bg-canvas text-muted"
        ]}>
          {Map.get(@counts, key, 0)}
        </span>
      </.link>
    </nav>
    """
  end

  @doc """
  Renders one alert as a table row.

  The title is the link, so the primary identifier is the target (table-row
  design §5), and the badges sit under it: what the alert is about, then the
  conditions a reader cannot derive from the dates alone. Every badge carries a
  word, because a colour alone says nothing to a reader who cannot see it.

  `Affects` names the routes by their own identity badges and counts the stops,
  which is the prototype's reading: an alert is about routes and places, and a
  route number is how an editor recognizes it.
  """
  attr :row, :map, required: true, doc: "one prepared row from `alerts_live.ex`"

  def row(assigns) do
    ~H"""
    <tr
      id={"alert-row-#{@row.alert.id}"}
      class="border-b border-subtle last:border-0 hover:bg-canvas/70"
    >
      <td class="px-5 py-3 align-top">
        <.link
          id={"alert-link-#{@row.alert.id}"}
          patch={@row.alert_path}
          class="font-semibold text-strong no-underline hover:text-action hover:underline"
        >
          {@row.title}
        </.link>
        <div class="mt-1 flex flex-wrap items-center gap-1.5">
          <span :if={@row.situation_label} class={chip_class()}>{@row.situation_label}</span>
          <.status_badge :if={not @row.alert.complete} status="draft" label="Incomplete" />
          <.status_badge
            :if={@row.needs_attention?}
            status="warning"
            label="Needs attention"
            data-role="alert-needs-attention"
          />
          <.status_badge
            :if={@row.check_in_due?}
            status="info"
            label="Check-in due"
            data-role="alert-check-in-due"
          />
        </div>
      </td>
      <td class="px-3 py-3 align-top">
        <.all_routes_badge :if={@row.system?} />
        <span :if={not @row.system? and @row.routes != []} class="flex flex-wrap gap-1">
          <RouteIdentity.route_badge :for={route <- @row.routes} route={route} />
        </span>
        <span :if={@row.stop_count > 0} class="mt-1 block text-[13px] text-muted">
          {stop_count_label(@row.stop_count)}
        </span>
      </td>
      <td class="px-3 py-3 align-top tabular-nums">
        <span class="block">{@row.when_summary}</span>
        <span :if={@row.check_in_label} class="mt-0.5 block text-[13px] text-muted">
          {@row.check_in_label}
        </span>
      </td>
      <td class="px-3 py-3 align-top text-[13px] text-muted">{@row.last_change}</td>
    </tr>
    """
  end

  @doc """
  Renders one alert as a stacked card, for the width where four columns cannot
  hold their content without sideways scrolling.

  It is the same row in one column: the title link, the badges, what the alert
  affects, when it applies, and who last changed it.
  """
  attr :row, :map, required: true, doc: "one prepared row from `alerts_live.ex`"

  def mobile_row(assigns) do
    ~H"""
    <li id={"alert-card-#{@row.alert.id}"} class="border-b border-subtle last:border-b-0 px-4 py-3">
      <.link
        id={"alert-card-link-#{@row.alert.id}"}
        patch={@row.alert_path}
        class="font-semibold text-strong no-underline hover:underline"
      >
        {@row.title}
      </.link>
      <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
        <span :if={@row.situation_label} class={chip_class()}>{@row.situation_label}</span>
        <.status_badge :if={not @row.alert.complete} status="draft" label="Incomplete" />
        <.status_badge :if={@row.needs_attention?} status="warning" label="Needs attention" />
        <.status_badge :if={@row.check_in_due?} status="info" label="Check-in due" />
      </div>
      <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
        <.all_routes_badge :if={@row.system?} />
        <RouteIdentity.route_badge :for={route <- @row.routes} route={route} />
        <span :if={@row.stop_count > 0} class="text-[13px] text-muted">
          {stop_count_label(@row.stop_count)}
        </span>
      </div>
      <p class="mt-1.5 text-[13px] text-muted tabular-nums">
        {@row.when_summary}<span :if={@row.check_in_label}> · {@row.check_in_label}</span>
      </p>
      <p class="mt-0.5 text-[13px] text-muted">{@row.last_change}</p>
    </li>
    """
  end

  @doc """
  Renders the message shown when the selected tab holds no alerts.

  Each tab says what belongs in it, because four identical "Nothing here"
  messages tell a reader who just saved an alert in another tab that this one is
  empty rather than that their alert is gone.
  """
  attr :tab, :atom, required: true

  def tab_empty(assigns) do
    assigns = assign(assigns, :empty, Map.fetch!(@tab_empty, assigns.tab))

    ~H"""
    <div
      id={"alerts-tab-empty-#{@tab}"}
      class="mt-4 rounded-card border border-subtle bg-white px-5 py-10 text-center"
    >
      <h2 class="font-display text-[20px] font-semibold tracking-[-0.02em] text-strong">
        {elem(@empty, 0)}
      </h2>
      <p class="mx-auto mt-2 max-w-[52ch] text-sm text-muted">{elem(@empty, 1)}</p>
    </div>
    """
  end

  # The prototype's "All routes" pill, for an alert about the whole system: it
  # is a label rather than a route, so it is not a route badge.
  defp all_routes_badge(assigns) do
    ~H"""
    <span class="inline-flex h-7 items-center rounded-badge bg-canvas px-2 text-[13px] font-semibold text-strong">
      All routes
    </span>
    """
  end

  defp chip_class do
    "rounded-selector bg-canvas px-2 py-0.5 text-[13px] font-medium text-muted"
  end

  defp stop_count_label(1), do: "1 stop"
  defp stop_count_label(count), do: "#{count} stops"
end
