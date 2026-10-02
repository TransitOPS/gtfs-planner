defmodule GtfsPlannerWeb.Gtfs.AlertsLive do
  @moduledoc """
  LiveView for the Alerts list: the organization's alerts grouped into Current,
  Upcoming, In progress and Past.

  Every row is a rendering of `Alerts.list_alerts/2`, which is the only place a
  tab, a count or a badge is decided. The page reads that read model with one UTC
  instant, and each row is classified and stamped in that alert's own retained
  zone, so a tab cannot disagree with its own count and an alert written against
  another version's zone is read on its own civil day rather than the version the
  editor last selected (AC-8, AC-9, CR-7). The read model is organization
  scoped, so the list is the organization's alerts and never a slice of one
  selected version (AC-8).

  The page shows what an editor is working on now and what is coming. It carries
  no publication state and no publication action: saving an alert never
  publishes one in this package, so Live, Scheduled, Ended, End and feed copy is
  absent here by construction, not by omission (R2, CR-1).

  A row's title navigates to `/alerts/:id`, and Create alert to `/alerts/new`.
  Both are `AlertEditorLive`'s routes, so they are live navigations rather than
  patches of this page. None of them carries a version: the list is reachable
  from the organization navigation before the organization has any schedule at
  all, which is why the audit context's version is the navbar's when there is
  one and `nil` when there is none (AC-8).
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

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access_in_organization}

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
     |> stream_configure(:alerts, dom_id: &"alert-row-#{&1.id}")
     |> stream_configure(:alerts_mobile, dom_id: &"alert-card-#{&1.id}")
     |> stream(:alerts, [])
     |> stream(:alerts_mobile, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_alerts(socket, tab(params))}
  end

  # The whole page is one read. The four counts come from the same map the rows
  # do, so a tab can never show a count its own rows contradict.
  #
  # A reader with no organization in context - a system administrator who has
  # none selected - sees the explicit unavailable state. `AssignOrganization`
  # assigns it rather than halting, because this page is the destination the
  # organization navigation offers and a page that answers "not here" is a
  # truthful answer where a mount that reads a missing assign is not.
  defp load_alerts(socket, tab) do
    case socket.assigns[:current_organization] do
      nil ->
        socket
        |> assign(:alerts_state, :organization_required)
        |> assign(:alerts_empty?, true)
        |> stream(:alerts, [], reset: true)
        |> stream(:alerts_mobile, [], reset: true)

      _organization ->
        load_alerts_for_organization(socket, tab)
    end
  end

  defp load_alerts_for_organization(socket, tab) do
    audit_context = audit_context(socket)

    case Alerts.list_alerts(audit_context, DateTime.utc_now()) do
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
  #
  # Each row's change stamp is localized in that alert's own retained zone, so an
  # organization holding alerts from several versions reads every row against the
  # day its own answers were written in. One conversion query is issued per
  # distinct zone, which for a single-zone organization is one.
  defp prepare_rows(rows, socket) do
    audit_context = audit_context(socket)
    alerts = Enum.map(rows, & &1.alert)
    organization_timezone = Alerts.organization_zone(audit_context)

    emails = editor_emails(Enum.map(alerts, & &1.updated_by_id))
    routes = Alerts.routes_for(audit_context, alerts)
    now_utc = DateTime.utc_now()

    stamps =
      alerts
      |> Enum.group_by(&Alerts.Listing.zone(&1, organization_timezone))
      |> Enum.flat_map(fn {zone, zone_alerts} ->
        instants = [now_utc | Enum.map(zone_alerts, & &1.updated_at)]

        [today | changes] = DisplayClock.localize_many(instants, %{timezone: zone})
        today = Date.to_iso8601(NaiveDateTime.to_date(today))

        Enum.zip(zone_alerts, changes)
        |> Enum.map(fn {alert, change} -> {alert.id, {today, change}} end)
      end)
      |> Map.new()

    Enum.map(rows, fn row ->
      {today, local_change} = Map.fetch!(stamps, row.alert.id)
      prepare_row(row, local_change, today, emails, routes)
    end)
  end

  defp prepare_row(row, local_change, today, emails, routes) do
    alert = row.alert
    referenced = Alerts.Listing.referenced_ids(alert)

    %{
      # `mount/3` configures each stream's dom_id from this id. The row and card
      # components render the same ids, which the client needs to find (and on a
      # tab change, reset) the elements a stream inserted.
      id: alert.id,
      alert: alert,
      alert_path: "/alerts/#{alert.id}",
      title: alert_title(alert),
      situation_label: Map.get(@situations, alert.situation),
      # Walking the stored identities keeps the alert's own order and drops an
      # identity the version no longer has, which is the one the row's Needs
      # attention badge names.
      routes: Enum.flat_map(referenced.routes, &(Map.get(routes, &1, []) |> List.wrap())),
      # Only an alert that said it is about the whole system, or about a place on
      # every route, reads "All routes". A draft that has not reached the routes
      # question, or whose routes were all deselected, names nothing yet.
      system?: referenced.routes == [] and system_shape?(alert),
      stop_count: referenced.stops |> Enum.uniq() |> length(),
      when_summary: when_summary(alert),
      check_in_label: check_in_label(alert),
      last_change: last_change(local_change, today, Map.get(emails, alert.updated_by_id)),
      needs_attention?: row.needs_attention?,
      check_in_due?: row.check_in_due?
    }
  end

  defp system_shape?(%{scope: %{shape: shape}}), do: shape in [:system, :stop_all_routes]
  defp system_shape?(_alert), do: false

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

  # The version is the navbar's when the organization has one and `nil` when it
  # does not. Alerts belongs to the organization, so the list, its labels and
  # its change stamps are organization-scoped either way; the version only names
  # the schedule an alert was written against, and an organization with no
  # schedule has none to name (AC-8, AC-10).
  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: selected_version_id(socket),
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  defp selected_version_id(socket) do
    case socket.assigns[:current_gtfs_version] do
      %{id: version_id} -> version_id
      _no_version -> nil
    end
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
              navigate={~p"/alerts/new"}
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
          :if={@alerts_state == :organization_required}
          id="alerts-organization-required"
          kind="error"
          title="Alerts need an organization."
        >
          Choose an organization to see and write its alerts.
        </.message>

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
                navigate={~p"/alerts/new"}
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
