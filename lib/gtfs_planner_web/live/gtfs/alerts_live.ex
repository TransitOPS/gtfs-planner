defmodule GtfsPlannerWeb.Gtfs.AlertsLive do
  @moduledoc """
  LiveView for the Alerts list: the organization's alerts grouped into Current,
  Upcoming, In progress and Past, and the organization's active schedule.

  Every row is a rendering of `Alerts.workspace/2`, which is the only place a
  tab, a count, a route badge or a Needs attention flag is decided. The page reads
  that workspace with one UTC instant, and each row is classified and stamped in
  that alert's own retained zone, so a tab cannot disagree with its own count and
  an alert written against another version's zone is read on its own civil day
  rather than the version the editor last selected (AC-8, AC-9, CR-7). The
  workspace is organization scoped and resolves every target against the
  organization's one active schedule, so the list is the organization's alerts
  and never a slice of one selected version (AC-8, AC-19).

  The active schedule is the page's own subject, separate from the version menu in
  the header: that menu is navigation and this page never reads it. The page names
  the active schedule and, when another published schedule exists, offers the
  editor a form that selects it with `Versions.set_active_schedule/3`. The form
  carries only the chosen version. The expectation that the selection has not moved
  is the token this view read with its workspace, so a forged or stale submit can
  only be refused, and a refusal rereads the workspace and keeps the choice the
  editor made. A committed change by anyone reaches the page on the organization's
  active-schedule topic and reloads the counts, the rows and the labels together.
  An organization with no active schedule lists nothing and offers no create; it
  offers the selection when it has a published schedule to select (AC-11, AC-24).

  The page shows what an editor is working on now and what is coming. It
  carries no publication action, but it does carry one piece of publication
  state: a confirmed removal whose bytes a served manifest has not dropped yet,
  read from `Alerts.Publication.pending_removals/1`, so an alert that is gone
  from the list is not silently still public (AC-16, FH-14).

  A row's title navigates to `/alerts/:id`, and Create alert to `/alerts/new`.
  Both are `AlertEditorLive`'s routes, so they are live navigations rather than
  patches of this page. None of them carries a version: the list is reachable
  from the organization navigation before the organization has any schedule at
  all (AC-8).
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.AlertComponents,
    only: [mobile_row: 1, row: 1, tab_empty: 1, tabs: 1]

  import GtfsPlannerWeb.PlannerComponents, only: [first_use: 1, message: 1]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Publication
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.AlertComponents

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
    # A committed change of the active schedule, by anyone, is a hint to reread.
    # The organization is absent for a system administrator who chose none.
    with %{id: organization_id} <- socket.assigns[:current_organization],
         true <- connected?(socket) do
      Phoenix.PubSub.subscribe(
        GtfsPlanner.PubSub,
        Versions.active_schedule_topic(organization_id)
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "Alerts")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:tab, :current)
     |> assign(:counts, %{})
     |> assign(:alerts_state, :loading)
     |> assign(:alerts_empty?, true)
     |> assign(:pending_removals, [])
     |> assign(:active_version, nil)
     |> assign(:active_token, nil)
     |> assign(:schedule_options, [])
     |> assign(:schedule_error, nil)
     |> assign(:schedule_form_open?, false)
     |> assign_choice(nil)
     |> stream_configure(:alerts, dom_id: &"alert-row-#{&1.id}")
     |> stream_configure(:alerts_mobile, dom_id: &"alert-card-#{&1.id}")
     |> stream(:alerts, [])
     |> stream(:alerts_mobile, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_alerts(socket, tab(params))}
  end

  @impl true
  def handle_event(
        "set_active_schedule",
        %{"active_schedule" => %{"version_id" => version_id}},
        %{assigns: %{active_token: %{}}} = socket
      )
      when is_binary(version_id) do
    {:noreply, set_active_schedule(socket, version_id)}
  end

  # The disclosure's open state is held here, not only in the browser: the server
  # sets the attribute on every render, so a render caused by someone else's change
  # would otherwise close the form under an editor who is choosing.
  def handle_event("toggle_schedule_form", _params, socket) do
    {:noreply, assign(socket, :schedule_form_open?, not socket.assigns.schedule_form_open?)}
  end

  # A forged event with no usable shape, or one sent while the page holds no
  # expectation to submit against (there is no form then), changes nothing.
  def handle_event("set_active_schedule", _params, %{assigns: %{active_token: %{}}} = socket) do
    {:noreply, refuse_schedule(socket, :not_found, nil)}
  end

  def handle_event("set_active_schedule", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:active_schedule_changed, %{revision: revision}}, socket) do
    case socket.assigns.active_token do
      %{revision: held} when revision <= held -> {:noreply, socket}
      _older_or_none -> {:noreply, load_alerts(socket, socket.assigns.tab)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The token is the expectation this view read with its workspace, never a value
  # the client sent, so a form built from an older page cannot talk its way past a
  # change that happened since.
  defp set_active_schedule(socket, version_id) do
    result =
      if String.trim(version_id) == "" do
        {:error, :blank}
      else
        Versions.set_active_schedule(
          audit_context(socket),
          version_id,
          socket.assigns.active_token
        )
      end

    case result do
      {:ok, _active} ->
        socket
        |> assign(:schedule_error, nil)
        |> assign(:schedule_form_open?, false)
        |> load_alerts(socket.assigns.tab)
        |> push_event("focus_scoped_target", %{id: "alerts-active-name"})

      {:error, reason} ->
        refuse_schedule(socket, reason, version_id)
    end
  end

  # A refusal rereads the workspace, so the page shows what is true now, and keeps
  # the choice the editor made when it is still on offer so a second try is one
  # submit. Focus returns to the select the error describes.
  defp refuse_schedule(socket, reason, submitted) do
    socket = load_alerts(socket, socket.assigns.tab)

    choice =
      if Enum.any?(socket.assigns.schedule_options, fn {id, _name} -> id == submitted end),
        do: submitted,
        else: socket.assigns.schedule_choice

    socket
    |> assign_choice(choice)
    |> assign(:schedule_error, schedule_refusal(reason))
    |> assign(:schedule_form_open?, true)
    |> push_event("focus_form_error", %{form_id: "alerts-active-schedule", fallback_id: nil})
  end

  defp schedule_refusal(:blank), do: "Choose a schedule."

  defp schedule_refusal(:stale_active),
    do:
      "The active schedule changed since you opened this page. The page now shows the current " <>
        "one; choose again to change it."

  defp schedule_refusal(:not_found),
    do: "That schedule is not available in this organization. Choose another."

  defp schedule_refusal(:not_usable),
    do: "That schedule is not published yet. Choose a published schedule."

  defp schedule_refusal(:forbidden),
    do: "You no longer have permission to choose the active schedule."

  defp assign_choice(socket, choice) do
    assign(socket, :schedule_form, to_form(%{"version_id" => choice}, as: :active_schedule))
    |> assign(:schedule_choice, choice)
  end

  # The whole page is one read. The four counts come from the same map the rows
  # do, so a tab can never show a count its own rows contradict. The active
  # schedule, the token the selector submits against and the rows are assigned
  # together for the same reason.
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
        |> clear_alerts()

      _organization ->
        load_alerts_for_organization(socket, tab)
    end
  end

  defp load_alerts_for_organization(socket, tab) do
    audit_context = audit_context(socket)

    case Alerts.workspace(audit_context, DateTime.utc_now()) do
      {:ok, %{active: active} = workspace} ->
        %{groups: grouped, routes_by_id: routes, diagnostics_by_alert: diagnostics} = workspace
        counts = Map.new(@tabs, &{&1, length(Map.fetch!(grouped, &1))})
        rows = prepare_rows(Map.fetch!(grouped, tab), socket, routes, diagnostics)

        socket
        |> assign(:tab, tab)
        |> assign(:counts, counts)
        |> assign(:alerts_state, :ready)
        |> assign(:alerts_empty?, Enum.all?(@tabs, &(Map.fetch!(grouped, &1) == [])))
        |> assign(:pending_removals, pending_removals(audit_context))
        |> assign_schedule(active.version, active.token)
        |> stream(:alerts, rows, reset: true)
        |> stream(:alerts_mobile, rows, reset: true)

      # Every target resolves against the active schedule, so without one there is
      # nothing to list or create against. The editor can still choose one.
      {:error, :no_active_schedule} ->
        case Versions.active_schedule(audit_context) do
          {:ok, %{token: token}} ->
            socket
            |> assign(:alerts_state, :no_active_schedule)
            |> assign(:pending_removals, pending_removals(audit_context))
            |> assign_schedule(nil, token)
            |> clear_rows()

          {:error, :forbidden} ->
            unavailable(socket)
        end

      # `EnsureRole` already refuses a member without the editor role, so this
      # branch is the fail-closed answer to a membership that lapsed between
      # mount and this read: the page stays up and says it cannot list.
      {:error, :forbidden} ->
        unavailable(socket)
    end
  end

  defp unavailable(socket) do
    socket
    |> assign(:alerts_state, :unavailable)
    |> clear_alerts()
  end

  defp clear_alerts(socket) do
    socket
    |> assign(:pending_removals, [])
    |> assign(:active_version, nil)
    |> assign(:active_token, nil)
    |> assign(:schedule_options, [])
    |> clear_rows()
  end

  defp clear_rows(socket) do
    socket
    |> assign(:alerts_empty?, true)
    |> stream(:alerts, [], reset: true)
    |> stream(:alerts_mobile, [], reset: true)
  end

  # The choices are the organization's published schedules, read fresh with every
  # workspace so a schedule published while the page is open is on offer. The
  # select starts on the persisted selection, not on a stale draft.
  defp assign_schedule(socket, version, token) do
    socket
    |> assign(:active_version, version)
    |> assign(:active_token, token)
    |> assign(
      :schedule_options,
      Versions.list_gtfs_versions_for_dropdown(socket.assigns.current_organization.id)
    )
    |> assign_choice(version && version.id)
  end

  defp tab(%{"tab" => value}) when is_binary(value) do
    Enum.find(@tabs, &(Atom.to_string(&1) == value)) || :current
  end

  defp tab(_params), do: :current

  # -- Rows ----------------------------------------------------------------

  # One pass per row, so a row carries everything its markup reads and the
  # template never queries. The route rows come from the workspace's own
  # `routes_by_id`, read from the same active schedule as the row's Needs
  # attention flag, so a row cannot name a route its own flag contradicts (CR-4).
  #
  # Each row's change stamp is localized in that alert's own retained zone, so an
  # organization holding alerts from several versions reads every row against the
  # day its own answers were written in. One conversion query is issued per
  # distinct zone, which for a single-zone organization is one.
  defp prepare_rows(rows, socket, routes, diagnostics) do
    audit_context = audit_context(socket)
    alerts = Enum.map(rows, & &1.alert)
    organization_timezone = Alerts.organization_zone(audit_context)

    emails = editor_emails(Enum.map(alerts, & &1.updated_by_id))
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
      prepare_row(row, local_change, today, emails, routes, diagnostics)
    end)
  end

  defp prepare_row(row, local_change, today, emails, routes, diagnostics) do
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
      # identity the active schedule lacks, which is the one the row's Needs
      # attention badge names.
      routes: referenced.routes |> Enum.map(&Map.get(routes, &1)) |> Enum.reject(&is_nil/1),
      # Only an alert that said it is about the whole system, or about a place on
      # every route, reads "All routes". A draft that has not reached the routes
      # question, or whose routes were all deselected, names nothing yet.
      system?: referenced.routes == [] and system_shape?(alert),
      stop_count: referenced.stops |> Enum.uniq() |> length(),
      when_summary: when_summary(alert),
      check_in_label: check_in_label(alert),
      last_change: last_change(local_change, today, Map.get(emails, alert.updated_by_id)),
      needs_attention?: row.needs_attention?,
      attention_notes: attention_notes(Map.get(diagnostics, alert.id, [])),
      check_in_due?: row.check_in_due?
    }
  end

  # What the active schedule lacks or cannot honour, in the feed IDs the alert
  # retains, so the badge says which target to look at without a click. At most
  # three are spelled out; the editor lists them all.
  @notes_shown 3

  defp attention_notes(diagnostics) do
    notes = diagnostics |> Enum.map(&AlertComponents.target_note/1) |> Enum.uniq()

    case Enum.split(notes, @notes_shown) do
      {shown, []} -> shown
      {shown, rest} -> shown ++ ["and #{length(rest)} more"]
    end
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

  # Alerts belongs to the organization, so the list, its labels and its change
  # stamps are organization-scoped. The context names no version: the workspace
  # resolves every target against the active schedule it locks, and the version
  # menu in the header is navigation that this page never consults (AC-8, AC-19).
  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # A removal the delivery steps have not applied yet. The alert is already
  # gone from the list, so this is the one place its pending withdrawal is still
  # visible; reading it cannot publish or withdraw anything (AC-16).
  defp pending_removals(%AuditContext{organization_id: organization_id}) do
    Publication.pending_removals(organization_id)
  end

  defp pending_removal_message([single]) do
    label = Map.get(single, :header) || "An alert"
    "#{label} was removed and is still on the public feed until the next update."
  end

  defp pending_removal_message(removals) do
    "#{length(removals)} removed alerts are still on the public feed until the next update."
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
      <div id="alerts-page" class="ds-page" phx-hook="FormErrorFocus">
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

        <%!-- No active schedule is the page's first-use state: nothing is listed or
               created until one is chosen, and the one next step is the choice. --%>
        <.first_use
          :if={@alerts_state == :no_active_schedule}
          id="alerts-no-active"
          title="No active schedule"
          icon="hero-calendar-days"
        >
          <%= if @schedule_options == [] do %>
            Alerts check their routes, stops and departures against the active schedule. This
            organization has no published schedule yet. The first schedule that is published
            becomes active.
          <% else %>
            Alerts check their routes, stops and departures against the active schedule. Choose
            the published schedule to use.
          <% end %>
          <:action :if={@schedule_options != []}>
            <.schedule_form
              form={@schedule_form}
              options={@schedule_options}
              error={@schedule_error}
              prompt="Choose a schedule"
              variant="primary"
              class="mx-auto flex max-w-sm flex-col gap-1 text-left"
            />
          </:action>
        </.first_use>

        <.message
          :if={@alerts_state == :unavailable}
          id="alerts-unavailable"
          kind="error"
          title="These alerts are not available to you."
        >
          You no longer have permission to change alerts in this organization.
        </.message>

        <.message
          :if={@pending_removals != []}
          id="alerts-pending-removal"
          kind="warning"
          title="Removal in progress"
        >
          {pending_removal_message(@pending_removals)}
        </.message>

        <%= if @alerts_state == :ready do %>
          <%!-- Choosing another schedule is rare next to reading the list, so the
                 name and what it means are always on the page and the form sits
                 behind a disclosure. A refusal opens it again. --%>
          <section
            id="alerts-active"
            aria-labelledby="alerts-active-heading"
            class="mt-6 rounded-card border border-subtle bg-white px-4 py-3 sm:px-5"
          >
            <h2 id="alerts-active-heading" class="text-[13px] font-semibold text-muted">
              Active schedule
            </h2>
            <p
              id="alerts-active-name"
              tabindex="-1"
              class="mt-0.5 text-base font-semibold text-strong [overflow-wrap:anywhere]"
            >
              {@active_version.name}
            </p>
            <p class="mt-1 max-w-[60ch] text-[13px] text-muted">
              Alerts check their targets against this schedule. The version menu in the header
              does not change it.
            </p>
            <details
              :if={Enum.any?(@schedule_options, fn {id, _name} -> id != @active_version.id end)}
              id="alerts-active-more"
              open={@schedule_form_open?}
              class="group"
            >
              <summary
                id="alerts-active-toggle"
                phx-click="toggle_schedule_form"
                class="-ml-1 mt-1 flex min-h-11 w-fit cursor-pointer list-none items-center gap-1.5 rounded-control px-1 text-sm font-semibold text-action hover:underline [&::-webkit-details-marker]:hidden"
              >
                <.icon
                  name="hero-chevron-right"
                  class="size-4 transition-transform group-open:rotate-90"
                /> Change schedule
              </summary>
              <.schedule_form
                form={@schedule_form}
                options={@schedule_options}
                error={@schedule_error}
                variant="secondary"
                class="mt-1 flex w-full flex-col gap-1 pb-1 sm:w-72"
              />
            </details>
          </section>

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

  # The one form that selects the organization's active schedule. It posts only the
  # chosen version; the server supplies the expectation (see the moduledoc).
  attr :form, :map, required: true
  attr :options, :list, required: true, doc: "published schedules as `{id, name}`"
  attr :error, :string, default: nil
  attr :prompt, :string, default: nil
  attr :variant, :string, values: ~w(primary secondary), required: true
  attr :class, :string, required: true

  defp schedule_form(assigns) do
    ~H"""
    <.form for={@form} id="alerts-active-schedule" phx-submit="set_active_schedule" class={@class}>
      <.input
        field={@form[:version_id]}
        id="alerts-active-schedule-version"
        type="select"
        label="Schedule"
        options={for {id, name} <- @options, do: {name, id}}
        prompt={@prompt}
        errors={List.wrap(@error)}
        required
      />
      <.button
        id="alerts-active-schedule-submit"
        type="submit"
        variant={@variant}
        class={["min-h-11", @variant == "secondary" && "w-fit"]}
        phx-disable-with="Setting schedule…"
      >
        Set active schedule
      </.button>
    </.form>
    """
  end
end
