defmodule GtfsPlannerWeb.Gtfs.AgenciesLive do
  @moduledoc """
  Lists one version's agencies with their route counts and its timezone state.

  Agencies are the transit providers riders see in journey planners, so the page
  answers three questions at once: who operates this version, which routes each
  provider runs (R5, AC-9), and whether every agency agrees on one schedule
  timezone (AC-10). Each route count links to the Routes list filtered to that
  agency, or to the unfiltered list when the version has one agency, because a
  single-agency list filtered to it says the same thing.

  The list is a streamed `table` whose headers sort by name, timezone or route
  count, keeping the sort in assigns and resetting the stream. A version with no
  agency shows the first-use empty state instead: it names the routes that still
  need an agency so the editor knows what creating the first one will assign
  (AC-11). A version whose agencies disagree on a timezone keeps the list — the
  single-agency decision this package recorded — and flags the disagreement
  through the band, the warning callout that names the reason, and a "Needs
  review" note on every row whose zone differs from the version zone.

  Reads go through `GtfsPlanner.Gtfs.FeedSettings`, scoped to the organization
  and version, and the timezone verdict is `DisplayClock`'s own: this LiveView
  holds no timezone rule of its own (INV-4) and makes no `Repo` call (CR-1).

  The band's Change timezone action and the callout's Resolve timezones action
  open one drawer that follows the prototype's choose → review → apply route: the
  editor names a zone from `DisplayClock.zone_names/0`, sees every agency with the
  zone it holds now and the routes it operates, and acknowledges that the change
  does not convert stored clock times before anything is written (AC-17). The
  drawer calls `FeedSettings.review_timezone_change/2` and
  `apply_timezone_change/3`; a review whose agencies or zone no longer match
  returns `:stale_review`, which shows the stale notice with Review again and
  writes nothing (AC-18).

  Access follows the other Settings pages. The `:gtfs_routes` session supplies the
  user, organization and published version, and this LiveView declares the editor
  guard itself because a session alone grants no GTFS access. Version switching
  keeps the section: only a published version of the current organization
  navigates, and the target is always `/settings/agencies` of that version.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FeedSettingsComponents, only: [timezone_input: 1]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  # The zone field is the only place this page validates a zone, and the server
  # refusal is what the editor reads: the copy the prototype uses for the same
  # refusal.
  @invalid_zone_error "Choose a valid timezone, such as America/New_York."
  @missing_ack_error "Confirm that the selected timezone is used by these schedules before applying it."

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agencies")
     |> assign(:health, %{agency_count: 0, unassigned_routes: 0, zone: {:unresolved, :missing}})
     |> assign(:sort_by, :name)
     |> assign(:sort_dir, :asc)
     |> assign(:timezone_drawer, nil)
     |> assign(:timezone_form, nil)
     |> assign(:timezone_agencies, [])
     |> assign(:zone_names, [])
     |> assign(:timezone_review, nil)
     |> assign(:timezone_ack_error, nil)
     |> assign(:return_focus_id, nil)
     |> stream(:agencies, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_agencies(socket)}
  end

  @impl true
  def handle_event("sort", %{"key" => key}, socket) do
    {sort_by, sort_dir} = next_sort(socket.assigns.sort_by, socket.assigns.sort_dir, key)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> load_agencies()}
  end

  # A selection of this page's own version is nothing to do: the switcher hook
  # returns before it sends the event for the version it already shows, and
  # `gtfs_version_loaded/2` below ignores the same case, so both events agree that
  # only another published version of this organization navigates.
  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if version_id != to_string(socket.assigns.current_gtfs_version.id) &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply,
       socket
       |> push_event("gtfs_version_selected", %{version_id: version_id})
       |> push_navigate(to: agencies_path(version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: agencies_path(version_id))}
    else
      {:noreply, socket}
    end
  end

  # Opening loads two reads the drawer needs and nothing else: the accepted zone
  # names, which are the same list `DisplayClock` validates against (INV-4), and
  # the agencies the change would rewrite, so the change is named before it is
  # reviewed (AC-17). The opener id survives the close so `OverlayDialog` can
  # return focus.
  @impl true
  def handle_event("open_timezone", params, socket) do
    {:noreply,
     socket
     |> assign(:timezone_drawer, :choose)
     |> assign(:timezone_form, timezone_form(prefilled_zone(socket.assigns.health.zone)))
     |> assign(:timezone_agencies, agencies_in_scope(socket))
     |> assign(:timezone_review, nil)
     |> assign(:timezone_ack_error, nil)
     |> assign(:zone_names, DisplayClock.zone_names())
     |> assign(:return_focus_id, params["opener_id"])}
  end

  @impl true
  def handle_event("review_timezone", %{"timezone" => %{"zone" => zone}}, socket),
    do: review_timezone(socket, zone)

  # Review again, after a stale review, sends the zone the server already holds
  # rather than a form field, so the zone never round-trips through the client.
  @impl true
  def handle_event("review_timezone", %{"zone" => zone}, socket),
    do: review_timezone(socket, zone)

  def handle_event("review_timezone", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("back_timezone", _params, socket) do
    case socket.assigns.timezone_review do
      %{zone: zone} ->
        {:noreply,
         socket
         |> assign(:timezone_drawer, :choose)
         |> assign(:timezone_review, nil)
         |> assign(:timezone_ack_error, nil)
         |> assign(:timezone_form, timezone_form(zone))}

      nil ->
        {:noreply, close_timezone(socket)}
    end
  end

  # A review with no drawer behind it is not a state the UI can submit.
  @impl true
  def handle_event("apply_timezone", _params, %{assigns: %{timezone_review: nil}} = socket),
    do: {:noreply, socket}

  @impl true
  def handle_event("apply_timezone", %{"timezone" => %{"acknowledged" => "true"}}, socket) do
    review = socket.assigns.timezone_review

    case FeedSettings.apply_timezone_change(
           audit_context(socket),
           review.zone,
           review.fingerprint
         ) do
      {:ok, count} ->
        {:noreply,
         socket
         |> close_timezone()
         |> load_agencies()
         |> put_flash(
           :info,
           "Timezone updated for #{count} agencies. Review affected schedules before exporting."
         )}

      {:error, :stale_review} ->
        # The review stays on screen: it is what the editor reviewed, and the
        # stale notice is where Review again starts a fresh one (AC-18).
        {:noreply, assign(socket, :timezone_drawer, :stale)}

      # Apply validates the zone the review already validated, so this refusal
      # only follows a zone submitted outside the review: the field is where the
      # editor can correct it.
      {:error, :invalid_timezone} ->
        {:noreply,
         socket
         |> assign(:timezone_drawer, :choose)
         |> assign(:timezone_review, nil)
         |> assign(:timezone_form, timezone_form(review.zone, @invalid_zone_error))}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> close_timezone()
         |> put_flash(:error, "You no longer have editor access to this organization.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> close_timezone()
         |> put_flash(:error, "This version is no longer available.")
         |> push_navigate(to: settings_path(socket.assigns.current_gtfs_version.id))}
    end
  end

  # The acknowledgement is apply's own precondition and not a field of the zone
  # form: nothing is written, the drawer names the missing confirmation beside
  # the checkbox, and focus lands on it.
  def handle_event("apply_timezone", _params, socket) do
    {:noreply,
     socket
     |> assign(:timezone_ack_error, @missing_ack_error)
     |> focus_timezone_error()}
  end

  # Every route out of the drawer — Cancel, the close button and, through the
  # `OverlayDialog` hook's dismiss control, Escape and the backdrop — lands here,
  # so the reviewed draft never survives a close.
  @impl true
  def handle_event("close_timezone", _params, socket), do: {:noreply, close_timezone(socket)}

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
      <:sub_header>
        <.settings_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:agencies} />
      </:sub_header>

      <%= if @health.agency_count == 0 do %>
        <.header>
          Agencies
          <:subtitle>{first_use_subtitle()}</:subtitle>
        </.header>

        <.empty_state id="agencies-empty" title="Give your service a name" class="mt-6">
          {empty_body(@health.unassigned_routes)}
        </.empty_state>

        <.support_note id="agencies-support-note">
          Already have a GTFS feed?
          <.link
            navigate={~p"/gtfs/#{@current_gtfs_version.id}/import"}
            class="link link-primary"
          >
            Review an import
          </.link>
          to bring its agencies with it.
        </.support_note>
      <% else %>
        <.header>
          Agencies
          <:subtitle>{subtitle()}</:subtitle>
        </.header>

        <%!-- `callout/1` spreads global attributes onto its own class, so the margin
        lives on a wrapper rather than being passed to the component. --%>
        <div :if={unresolved_zone?(@health.zone)} class="mt-4">
          <.callout
            id="agencies-timezone-callout"
            kind="warning"
            title={callout_title(@health.zone)}
          >
            Choose one timezone for this version. Calendars use UTC until then.
            <div class="mt-3">
              <.button
                id="agencies-resolve-timezones"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="open_timezone"
                phx-value-opener_id="agencies-resolve-timezones"
              >
                Resolve timezones
              </.button>
            </div>
          </.callout>
        </div>

        <div class="mt-6">
          <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
            <.table id="agencies" rows={@streams.agencies} responsive="stack">
              <:col
                :let={{_id, row}}
                label="Agency"
                sort_key="name"
                sort_event="sort"
                sort={column_sort_state(@sort_by, @sort_dir, :name)}
              >
                <div class="font-semibold">{row.agency.agency_name}</div>
                <div class="mt-1 text-xs break-words text-base-content/70">
                  {website_host(row.agency.agency_url)}
                </div>
              </:col>
              <:col
                :let={{_id, row}}
                label="Timezone"
                sort_key="timezone"
                sort_event="sort"
                sort={column_sort_state(@sort_by, @sort_dir, :timezone)}
              >
                <div>{row.agency.agency_timezone || "Not set"}</div>
                <div
                  :if={row_needs_review?(row.agency.agency_timezone, @health.zone)}
                  class="mt-1 text-xs text-base-content/70"
                >
                  {needs_review()}
                </div>
              </:col>
              <:col
                :let={{_id, row}}
                label="Routes"
                align="right"
                sort_key="routes"
                sort_event="sort"
                sort={column_sort_state(@sort_by, @sort_dir, :routes)}
              >
                <.link
                  navigate={routes_path(@current_gtfs_version.id, @health.agency_count, row)}
                  class="inline-flex min-h-11 items-center gap-2 whitespace-nowrap font-semibold text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
                  aria-label={"View #{row.route_count} routes for #{row.agency.agency_name}"}
                >
                  {row.route_count} <span aria-hidden="true">→</span>
                </.link>
              </:col>
            </.table>
          </div>
          <p class="mt-2 text-sm text-base-content/70">
            Agency names open their details. Route counts show the routes they operate.
          </p>
        </div>

        <section
          id="agencies-timezone-band"
          class="mt-6 flex flex-wrap items-center justify-between gap-4 border-b border-base-300 pb-4"
        >
          <div>
            <h2 class="text-sm font-semibold text-base-content">One timezone for this version</h2>
            <p class="mt-1 text-sm text-base-content/70">{band_state(@health.zone)}</p>
          </div>

          <.button
            id="agencies-change-timezone"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="open_timezone"
            phx-value-opener_id="agencies-change-timezone"
          >
            Change timezone
          </.button>
        </section>

        <.support_note id="agencies-support-note">
          An agency identifies the service riders use. The organization publishing your dataset can
          be different.
          <.link
            navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings/feed-details"}
            class="link link-primary"
          >
            View feed details
          </.link>
        </.support_note>
      <% end %>

      <.timezone_drawer
        mode={@timezone_drawer}
        form={@timezone_form}
        zones={@zone_names}
        agencies={@timezone_agencies}
        review={@timezone_review}
        ack_error={@timezone_ack_error}
        resolved?={resolved_zone?(@health.zone)}
        return_focus_id={@return_focus_id}
        version={@current_gtfs_version}
        organization={@current_organization}
      />
    </Layouts.app>
    """
  end

  # The drawer holds the prototype's two steps in one surface: choose a zone, then
  # review what it rewrites. `mode` is nil while the drawer is closed, and the body
  # renders only when it is open, so a closed drawer holds no zone field, no
  # acknowledgement and no agency list to submit by accident.
  attr :mode, :any, required: true
  attr :form, :any, required: true
  attr :zones, :list, required: true
  attr :agencies, :list, required: true
  attr :review, :any, required: true
  attr :ack_error, :string, default: nil
  attr :resolved?, :boolean, required: true
  attr :return_focus_id, :string, default: nil
  attr :version, :any, required: true
  attr :organization, :any, required: true

  defp timezone_drawer(assigns) do
    ~H"""
    <.drawer
      id="agency-timezone-drawer"
      open={@mode != nil}
      on_close="close_timezone"
      title={timezone_drawer_title(@mode, @resolved?)}
      return_focus_id={@return_focus_id}
    >
      <div :if={@mode} id="agency-timezone-form-panel" phx-hook="FormErrorFocus">
        <p id="agency-timezone-drawer-scope" class="text-xs text-base-content/70">
          {scope_line(@version, @organization)}
        </p>

        <%= if @mode == :choose do %>
          <p class="mt-2 text-sm text-base-content/70">
            Every agency in this version must use one schedule timezone. Review the affected agencies
            before applying a change.
          </p>

          <.form
            for={@form}
            id="agency-timezone-form"
            novalidate
            phx-submit="review_timezone"
            class="mt-4"
          >
            <fieldset class="mt-5 border-t border-base-300 pt-5">
              <legend class="pr-4 text-base font-semibold text-base-content">
                Schedule timezone
              </legend>
              <div class="mt-4">
                <.timezone_input field={@form[:zone]} zones={@zones} id="agency-timezone-zone" />
              </div>
            </fieldset>

            <div class="mt-5">
              <.callout
                id="agency-timezone-impact"
                kind="warning"
                title={"This affects every agency in #{@version.name}"}
              >
                Clock times will stay the same. Their timezone interpretation will change. Review
                affected schedules before exporting.
              </.callout>
            </div>

            <ul
              id="agency-timezone-current"
              class="mt-5 divide-y divide-base-200 border-y border-base-300"
            >
              <li
                :for={row <- @agencies}
                class="flex items-start justify-between gap-4 py-3"
              >
                <span class="font-semibold">{row.agency.agency_name}</span>
                <span class="text-sm text-base-content/70">
                  {row.agency.agency_timezone || "Not set"}
                </span>
              </li>
            </ul>

            <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
              <.button
                id="agency-timezone-cancel"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="close_timezone"
              >
                Cancel
              </.button>

              <.button id="agency-timezone-review" type="submit" class="min-h-11">
                Review change
              </.button>
            </div>
          </.form>
        <% else %>
          <div class="mt-5">
            <.callout
              :if={@mode == :stale}
              id="agency-timezone-stale"
              kind="warning"
              title="The agencies changed during your review"
            >
              Nothing was changed.
              <div class="mt-3">
                <.button
                  id="agency-timezone-review-again"
                  type="button"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="review_timezone"
                  phx-value-zone={@review.zone}
                >
                  Review again
                </.button>
              </div>
            </.callout>

            <.callout
              :if={@mode == :review}
              id="agency-timezone-review-summary"
              kind="warning"
              title={"#{agencies_label(@review.agencies)} will use #{@review.zone}"}
            >
              Only {@version.name} changes. Other versions keep their current timezone.
            </.callout>
          </div>

          <ul
            id="agency-timezone-review-list"
            class="mt-5 divide-y divide-base-200 border-y border-base-300"
          >
            <li :for={agency <- @review.agencies} class="flex items-start justify-between gap-4 py-3">
              <div>
                <div class="font-semibold">{agency.agency_name}</div>
                <div class="mt-1 text-sm text-base-content/70">
                  {agency.from} → {@review.zone}
                </div>
              </div>
              <div class="whitespace-nowrap text-sm text-base-content/70">
                {routes_label(agency.route_count)}
              </div>
            </li>
          </ul>

          <p
            id="agency-timezone-not-converted"
            class="mt-5 rounded-box bg-base-200 p-4 text-sm text-base-content/70"
          >
            Route and trip clock times are not converted. Check calendars, schedules, and overnight
            service after this change.
          </p>

          <.form
            :if={@mode == :review}
            for={@form}
            id="agency-timezone-review-form"
            novalidate
            phx-submit="apply_timezone"
            class="mt-5"
          >
            <%!--
              The acknowledgement is the prototype's check line. The wrapper only
              relaxes `.input`'s label: its label is a no-wrap flex line, which
              clipped this 66-character sentence inside the phone drawer.
            --%>
            <div class="[&_.label]:whitespace-normal">
              <.input
                id="agency-timezone-ack"
                name="timezone[acknowledged]"
                type="checkbox"
                checked={false}
                label="I have checked that this is the timezone used by these schedules."
                errors={ack_errors(@ack_error)}
              />
            </div>

            <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
              <.button
                id="agency-timezone-back"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="back_timezone"
              >
                Back
              </.button>

              <.button
                id="agency-timezone-apply"
                type="submit"
                class="min-h-11"
                phx-disable-with="Applying…"
              >
                Apply timezone
              </.button>
            </div>
          </.form>

          <div
            :if={@mode == :stale}
            class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5"
          >
            <.button
              id="agency-timezone-back"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="back_timezone"
            >
              Back
            </.button>
          </div>
        <% end %>
      </div>
    </.drawer>
    """
  end

  attr :rest, :global
  slot :inner_block, required: true

  defp support_note(assigns) do
    ~H"""
    <p class="mt-6 flex max-w-3xl items-start gap-2 text-sm text-base-content/70" {@rest}>
      <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  # The health read and the rows are two scoped context calls, and the rows are
  # sorted in memory because the sort is a header click rather than a query
  # parameter: a version holds a handful of agencies, so re-reading is the whole
  # cost of a click.
  defp load_agencies(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    rows = FeedSettings.list_agencies(organization_id, version_id)
    health = FeedSettings.agency_health(organization_id, version_id)

    socket
    |> assign(:health, health)
    |> stream(
      :agencies,
      sort_rows(rows, socket.assigns.sort_by, socket.assigns.sort_dir)
      |> Enum.map(&Map.put(&1, :id, &1.agency.id)),
      reset: true
    )
  end

  defp sort_rows(rows, :name, dir), do: Enum.sort_by(rows, & &1.agency.agency_name, dir)

  defp sort_rows(rows, :timezone, dir),
    do: Enum.sort_by(rows, &(&1.agency.agency_timezone || ""), dir)

  defp sort_rows(rows, :routes, dir), do: Enum.sort_by(rows, & &1.route_count, dir)

  defp next_sort(current_by, current_dir, key) do
    case parse_sort_key(key) do
      nil -> {current_by, current_dir}
      ^current_by -> {current_by, toggle_dir(current_dir)}
      sort_by -> {sort_by, :asc}
    end
  end

  defp parse_sort_key("name"), do: :name
  defp parse_sort_key("timezone"), do: :timezone
  defp parse_sort_key("routes"), do: :routes
  defp parse_sort_key(_key), do: nil

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  defp column_sort_state(sort_by, sort_dir, column) when column == sort_by,
    do: to_string(sort_dir)

  defp column_sort_state(_sort_by, _sort_dir, _column), do: "none"

  defp subtitle, do: "Manage the public identity and contact details of your transit providers."

  defp first_use_subtitle,
    do: "The transit providers riders will see in journey planners."

  defp needs_review, do: "Needs review"

  # Every row keeps its own agency ID in the query, except a version with one
  # agency: the list filtered to that agency is the unfiltered list (AC-9).
  defp routes_path(version_id, agency_count, row) do
    base = "/gtfs/#{version_id}/routes"

    if agency_count == 1, do: base, else: "#{base}?agency_id=#{row.agency.agency_id}"
  end

  defp band_state({:ok, zone}), do: "#{zone} · Used by all agencies and their schedules."
  defp band_state({:unresolved, _reason}), do: needs_review()

  defp unresolved_zone?({:unresolved, _reason}), do: true
  defp unresolved_zone?({:ok, _zone}), do: false

  defp callout_title({:unresolved, :conflicting}), do: "Agencies use different timezones"
  defp callout_title({:unresolved, :invalid}), do: "The agency timezone isn’t recognized"
  defp callout_title({:unresolved, :missing}), do: "The agency timezone is missing"

  # A row is flagged when its own zone is not the one the version resolved: with an
  # unresolved version zone any stored zone differs, exactly as the prototype's
  # rows read.
  defp row_needs_review?(zone, {:ok, version_zone}), do: zone not in [nil, "", version_zone]
  defp row_needs_review?(zone, {:unresolved, _reason}), do: zone not in [nil, ""]

  defp website_host(url) when is_binary(url), do: URI.parse(url).host || url
  defp website_host(_url), do: ""

  defp empty_body(0) do
    "Create the first agency with its public name, website, and timezone. You can then start adding routes."
  end

  defp empty_body(count) do
    "#{unassigned_routes_sentence(count)} Creating the first agency assigns these routes to it."
  end

  defp unassigned_routes_sentence(1), do: "1 route has no agency yet."
  defp unassigned_routes_sentence(count), do: "#{count} routes have no agency yet."

  # One review → apply pair, and the drawer is the only caller: a refused review
  # stays on the zone field, and every scope refusal closes the drawer because
  # there is no version left to change.
  defp review_timezone(socket, zone) do
    case FeedSettings.review_timezone_change(audit_context(socket), zone) do
      {:ok, review} ->
        {:noreply,
         socket
         |> assign(:timezone_drawer, :review)
         |> assign(:timezone_review, review)
         |> assign(:timezone_form, timezone_form(review.zone))
         |> assign(:timezone_ack_error, nil)}

      {:error, :invalid_timezone} ->
        {:noreply,
         socket
         |> assign(:timezone_drawer, :choose)
         |> assign(:timezone_review, nil)
         |> assign(:timezone_form, timezone_form(zone, @invalid_zone_error))}

      # The version's last agency can disappear between opening the drawer and
      # reviewing: nothing can be changed, so the drawer closes and the page
      # behind it shows the version as it now is.
      {:error, :no_agencies} ->
        {:noreply,
         socket
         |> close_timezone()
         |> load_agencies()
         |> put_flash(:error, "This version has no agencies, so there is no timezone to change.")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> close_timezone()
         |> put_flash(:error, "You no longer have editor access to this organization.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> close_timezone()
         |> put_flash(:error, "This version is no longer available.")
         |> push_navigate(to: settings_path(socket.assigns.current_gtfs_version.id))}
    end
  end

  defp close_timezone(socket) do
    socket
    |> assign(:timezone_drawer, nil)
    |> assign(:timezone_review, nil)
    |> assign(:timezone_ack_error, nil)
    |> assign(:timezone_agencies, [])
    |> assign(:zone_names, [])
  end

  # The zone is one free-text field the context validates in one place, so the
  # form is one value plus, after a refused review, the error that review
  # returned. No client-side rule repeats `DisplayClock.valid_zone?/1` (INV-4).
  defp timezone_form(zone, error \\ nil) do
    {%{}, %{zone: :string}}
    |> Ecto.Changeset.cast(%{"zone" => zone}, [:zone])
    |> add_zone_error(error)
    |> to_form(as: :timezone)
  end

  # A refused review is a keystroke-shaped round trip rather than a save, and the
  # action is what makes the error the editor's own submitted value: Phoenix
  # drops the errors of a changeset with no action, so the refusal would render
  # nowhere without it.
  defp add_zone_error(changeset, nil), do: changeset

  defp add_zone_error(changeset, message) do
    changeset
    |> Ecto.Changeset.add_error(:zone, message)
    |> Map.put(:action, :validate)
  end

  # A resolved version prefills the zone it holds; an unresolved one has no zone
  # to change, so the field starts blank and the drawer's title says what the
  # action is (AC-10, AC-17).
  defp prefilled_zone({:ok, zone}), do: zone
  defp prefilled_zone({:unresolved, _reason}), do: ""

  defp agencies_in_scope(socket) do
    FeedSettings.list_agencies(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id
    )
  end

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # The acknowledgement is a checkbox inside the review form, so the hook's own
  # invalid-control lookup finds it first and the fallback id only matters if the
  # error is ever rendered away from the control.
  defp focus_timezone_error(socket) do
    push_event(socket, "focus_form_error", %{
      form_id: "agency-timezone-review-form",
      fallback_id: "agency-timezone-ack"
    })
  end

  defp timezone_drawer_title(nil, _resolved?), do: "Change version timezone"
  defp timezone_drawer_title(:choose, true), do: "Change version timezone"
  # An unresolved version has no zone to change, so the same field is named for
  # what it does there: choosing one (AC-10, AC-17).
  defp timezone_drawer_title(:choose, false), do: "Resolve agency timezones"
  defp timezone_drawer_title(_review, _resolved?), do: "Review timezone change"

  defp resolved_zone?({:ok, _zone}), do: true
  defp resolved_zone?({:unresolved, _reason}), do: false

  defp agencies_label([_agency]), do: "1 agency"
  defp agencies_label(agencies), do: "#{length(agencies)} agencies"

  defp routes_label(1), do: "1 route"
  defp routes_label(count), do: "#{count} routes"

  defp ack_errors(nil), do: []
  defp ack_errors(message), do: [message]

  defp scope_line(version, organization) do
    [version.name, organization.name]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join(" · ")
  end

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"
end
