defmodule GtfsPlannerWeb.Gtfs.AlertsLive do
  @moduledoc """
  LiveView for the Alerts list: the version's alerts grouped into Current,
  Upcoming, In progress and Past.

  Every row is a rendering of `Alerts.list_alerts/2`, which is the only place a
  tab, a count or a badge is decided. The page reads that read model with the
  agency's own civil time as of this load, so a tab cannot disagree with its own
  count and the check-in badge is read in the agency's day rather than UTC's
  (AC-9, CR-7). Because the read model is scoped to the context's version, the
  list is the version being edited and never the version the editor last looked
  at elsewhere (R1, CR-4).

  The page shows what an editor is working on now and what is coming. It carries
  no publication state and no publication action: saving an alert never
  publishes one in this package, so Live, Scheduled, Ended, End and feed copy is
  absent here by construction, not by omission (R2, CR-1).

  A row's title is a patch to `/alerts/:id`, which step 14's editor owns. Until
  that route exists the link still reads as the row's identity and carries its
  own label, which is what the table needs; the destination is that editor's
  URL, not a second route defined here.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.AlertComponents,
    only: [mobile_row: 1, row: 1, tab_empty: 1, tabs: 1]

  import GtfsPlannerWeb.PlannerComponents, only: [first_use: 1, message: 1]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock

  # The tabs the read model groups into, in the order the strip shows them. An
  # unknown `?tab=` value is not an error a reader should see: it falls back to
  # Current, the tab the page opens on.
  @tabs [:current, :upcoming, :in_progress, :past]

  # The alert's situation in a rider's words. This is what the alert is about,
  # so it sits under the title; the effect itself is the editor's own derivation
  # and belongs to the review step, not to a list row.
  @situations %{
    delay: "Delays",
    detour: "Detour",
    stop_moved: "Stop moved",
    stop_closed: "Stop closed",
    cancelled_trips: "Cancelled departures",
    accessibility: "Accessibility",
    suspension: "Service suspension",
    service_change: "Service change"
  }

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Alerts")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:tab, :current)
     |> assign(:counts, %{})
     |> assign(:alerts_state, :loading)
     |> assign(:alerts_empty?, true)
     |> stream(:alerts, [])
     |> stream(:alerts_mobile, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_alerts(socket, tab(params))}
  end

  # The whole page is one read. The four counts come from the same map the rows
  # do, so a tab can never show a count its own rows contradict.
  defp load_alerts(socket, tab) do
    audit_context = audit_context(socket)

    case Alerts.list_alerts(audit_context, Alerts.agency_now(audit_context)) do
      {:ok, grouped} ->
        counts = Map.new(@tabs, &{&1, length(Map.fetch!(grouped, &1))})
        rows = prepare_rows(Map.fetch!(grouped, tab), socket)

        socket
        |> assign(:tab, tab)
        |> assign(:counts, counts)
        |> assign(:alerts_state, :ready)
        |> assign(:alerts_empty?, Enum.all?(@tabs, &(Map.fetch!(grouped, &1) == [])))
        |> stream(:alerts, rows, reset: true)
        |> stream(:alerts_mobile, rows, reset: true)

      # `EnsureRole` already refuses a member without the editor role, so this
      # branch is the fail-closed answer to a membership that lapsed between
      # mount and this read: the page stays up and says it cannot list.
      {:error, :forbidden} ->
        socket
        |> assign(:alerts_state, :unavailable)
        |> assign(:alerts_empty?, true)
        |> stream(:alerts, [], reset: true)
        |> stream(:alerts_mobile, [], reset: true)
    end
  end

  defp tab(%{"tab" => value}) when is_binary(value) do
    Enum.find(@tabs, &(Atom.to_string(&1) == value)) || :current
  end

  defp tab(_params), do: :current

  # -- Rows ----------------------------------------------------------------

  # One pass per row, so a row carries everything its markup reads and the
  # template never queries. The route rows come from `Alerts.routes_for/2`, the
  # same scoped read the editor's own labels are built from, so a row cannot
  # name a route the editor's text does not (CR-4).
  defp prepare_rows(rows, socket) do
    audit_context = audit_context(socket)
    zone = DisplayClock.resolve_zone(audit_context.organization_id, audit_context.gtfs_version_id)
    today = DateTime.utc_now() |> DisplayClock.local_date(zone) |> Date.to_iso8601()
    emails = editor_emails(Enum.map(rows, & &1.alert.updated_by_id))
    routes = Alerts.routes_for(audit_context, Enum.map(rows, & &1.alert))

    Enum.map(rows, &prepare_row(&1, socket, zone, today, emails, routes))
  end

  defp prepare_row(row, socket, zone, today, emails, routes) do
    alert = row.alert
    referenced = Alerts.Listing.referenced_ids(alert)
    local_change = [alert.updated_at] |> DisplayClock.localize_many(zone) |> List.first()

    %{
      # A stream item's `:id` is its DOM identity, so the two streams render the
      # same rows under the same ids and either can update one row in place.
      id: alert.id,
      alert: alert,
      alert_path: "/gtfs/#{socket.assigns.current_gtfs_version.id}/alerts/#{alert.id}",
      title: alert_title(alert),
      situation_label: Map.get(@situations, alert.situation),
      # Walking the stored identities keeps the alert's own order and drops an
      # identity the version no longer has, which is the one the row's Needs
      # attention badge names.
      routes: Enum.flat_map(referenced.routes, &(Map.get(routes, &1, []) |> List.wrap())),
      system?: referenced.routes == [],
      stop_count: referenced.stops |> Enum.uniq() |> length(),
      when_summary: when_summary(alert),
      check_in_label: check_in_label(alert),
      last_change: last_change(local_change, today, Map.get(emails, alert.updated_by_id)),
      needs_attention?: row.needs_attention?,
      check_in_due?: row.check_in_due?
    }
  end

  # A saved draft with no header yet is titled by its situation instead of by a
  # blank line, so an In progress row is still nameable in a list.
  defp alert_title(%{message: %{header: header}} = alert) when is_binary(header) do
    if String.trim(header) == "", do: fallback_title(alert), else: header
  end

  defp alert_title(alert), do: fallback_title(alert)

  defp fallback_title(%{situation: situation}) do
    case Map.get(@situations, situation) do
      nil -> "Untitled alert"
      label -> "#{label} alert in progress"
    end
  end

  # The timing answer's own summary, which already names the pattern, the dates
  # and the exceptions. An alert that has not answered timing yet says so
  # rather than showing an empty cell.
  defp when_summary(%{timing: nil} = alert) do
    if alert.complete, do: "Timing not set", else: "Not answered yet"
  end

  defp when_summary(alert) do
    case Recurrence.summary(alert.timing) do
      "" -> "Not answered yet"
      summary -> summary
    end
  end

  # A check-in is the operator's own reminder, so the row repeats it with the
  # time they stored. Both values are civil in the agency's zone, so nothing is
  # converted here (CR-7).
  defp check_in_label(%{timing: %{check_in_at: nil}}), do: nil

  defp check_in_label(%{timing: %{check_in_at: check_in_at}}) do
    "Check-in at #{DisplayClock.format_time(check_in_at)}"
  end

  defp check_in_label(_alert), do: nil

  # The change column names when, in the agency's own words, and who. The date
  # is shown only when it is not today, because a reader looking at today's list
  # already knows the row was touched today.
  defp last_change(local_change, today, email) do
    date = NaiveDateTime.to_date(local_change)
    time = DisplayClock.format_time(local_change)

    stamp =
      if Date.to_iso8601(date) == today do
        time
      else
        "#{Calendar.strftime(date, "%b %-d")}, #{time}"
      end

    case email do
      nil -> stamp
      email -> "#{stamp} by #{email}"
    end
  end

  # One read per distinct editor rather than one per row. A user row is never
  # deleted in this application, so the read cannot miss.
  defp editor_emails(user_ids) do
    user_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn user_id -> {user_id, Accounts.get_user!(user_id).email} end)
  end

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # -- Rendering -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <div id="alerts-page" class="ds-page">
        <.header>
          Alerts
          <:subtitle>
            Tell riders about detours, delays and closures. Create an urgent notice, or prepare
            planned work ahead of the day it applies.
          </:subtitle>
          <%!-- One primary per view. With no alert at all the first-use panel
                 carries it, so the header's goes away rather than offering the
                 same action twice. --%>
          <:actions :if={@alerts_state == :ready and not @alerts_empty?}>
            <.link
              id="create-alert"
              patch={"/gtfs/#{@current_gtfs_version.id}/alerts/new"}
              class={[
                "inline-flex min-h-11 items-center gap-2 rounded-control px-4 text-sm font-semibold no-underline",
                "bg-action text-action-content hover:bg-action-hover"
              ]}
            >
              <.icon name="hero-plus" class="size-4" /> Create alert
            </.link>
          </:actions>
        </.header>

        <.message
          :if={@alerts_state == :unavailable}
          id="alerts-unavailable"
          kind="error"
          title="These alerts are not available to you."
        >
          You no longer have permission to change alerts in this organization.
        </.message>

        <%= if @alerts_state == :ready do %>
          <%!-- An organization with no alerts at all gets the first-use panel
                 instead of four empty tabs: four empty tabs describe an
                 organization that is choosing, not one that has nothing. --%>
          <.first_use
            :if={@alerts_empty?}
            id="alerts-first-use"
            title="No alerts yet"
            icon="hero-bell-alert"
          >
            Alerts tell riders about detours, delays, closed stops and service changes. Create one
            when something changes on the street, or prepare planned work ahead of the day it
            applies.
            <:action>
              <.link
                id="create-alert-first-use"
                patch={"/gtfs/#{@current_gtfs_version.id}/alerts/new"}
                class={[
                  "inline-flex min-h-11 items-center gap-2 rounded-control px-4 text-sm font-semibold no-underline",
                  "bg-action text-action-content hover:bg-action-hover"
                ]}
              >
                <.icon name="hero-plus" class="size-4" /> Create alert
              </.link>
            </:action>
          </.first_use>

          <%= if not @alerts_empty? do %>
            <.tabs
              version_id={@current_gtfs_version.id}
              tab={@tab}
              counts={@counts}
            />

            <.tab_empty :if={@counts[@tab] == 0} tab={@tab} />

            <section
              :if={@counts[@tab] > 0}
              id="alerts-list"
              aria-label="Alerts"
              class="mt-4 overflow-clip rounded-card border border-subtle bg-white"
            >
              <%!-- Four columns cannot hold their content at phone width, so the
                     table is desktop-only and the same rows render as cards
                     below it. Both come from the one stream, so a row's badges
                     and its target are the same words either way. --%>
              <div class="hidden md:block">
                <table class="w-full text-left text-sm">
                  <thead class="text-[13px] text-muted">
                    <tr class="border-b border-subtle">
                      <th scope="col" class="px-5 py-2.5 font-semibold">Alert</th>
                      <th scope="col" class="px-3 py-2.5 font-semibold">Affects</th>
                      <th scope="col" class="px-3 py-2.5 font-semibold">When</th>
                      <th scope="col" class="px-3 py-2.5 font-semibold">Last change</th>
                    </tr>
                  </thead>
                  <tbody id="alerts" phx-update="stream">
                    <.row :for={{_dom_id, row} <- @streams.alerts} row={row} />
                  </tbody>
                </table>
              </div>

              <ul id="alerts-mobile" phx-update="stream" class="divide-y divide-subtle md:hidden">
                <.mobile_row :for={{_dom_id, row} <- @streams.alerts_mobile} row={row} />
              </ul>
            </section>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
