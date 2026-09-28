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

  Creation is the same drawer pattern in its simplest form: the header's Create
  agency action and the empty state's Create first agency action open
  `#agency-drawer`, whose form holds the prototype's two sections. Only the
  version's first agency carries a schedule timezone field, because the first
  agency decides the version's zone and every later one takes it (R2, AC-12);
  validating and saving go through `FeedSettings.change_agency/2` and
  `create_agency/2` (CR-1). A version that already has agencies but no single
  valid zone cannot take another one: both actions open the timezone flow
  instead, and the server refuses the same case with `:timezone_unresolved`
  (AC-13). An unsaved form is protected like the Feed details drawer — the
  discard question on every close route and the shared `unsaved_guard/1` hook on
  reload (AC-6).

  Editing is that drawer over one stored row. Each name in the list is a button
  that loads its row with the scoped `FeedSettings.get_agency/3` and keeps the
  `updated_at` it loaded in the socket, never in a hidden field (CR-1, CR-9);
  the drawer shows the prototype's read-only identity box where the ID would be
  edited, the version zone as a note instead of a second zone field, and saves
  through `FeedSettings.update_agency/4`. A save another editor beat is a
  conflict rather than a silent overwrite: the draft stays on screen with "Load
  latest", and once the latest row and its token are loaded the next save
  replaces their values (AC-15, AC-16). A row that is gone — deleted, foreign or
  from another version — flashes "This agency no longer exists." and opens
  nothing (AC-28).

  Deleting an agency is the same drawer's third route. The edit footer's Delete
  agency action switches it to the prototype's choose → review → apply steps: the
  editor names the agency that receives the routes, reviews every route that will
  move with the fingerprint that binds the command held in the socket, and
  applies it through `FeedSettings.delete_agency/4` (INV-3). A fare attribute or
  attribution that names the agency blocks the deletion instead and is listed by
  ID, the version's last agency cannot be deleted at all, and a review the version
  has moved past shows the stale notice with Refresh review and writes nothing
  (AC-19, AC-20, AC-21, AC-22).

  Access follows the other Settings pages. The `:gtfs_routes` session supplies the
  user, organization and published version, and this LiveView declares the editor
  guard itself because a session alone grants no GTFS access. Version switching
  keeps the section: only a published version of the current organization
  navigates, and the target is always `/settings/agencies` of that version.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FeedSettingsComponents,
    only: [agency_form_fields: 1, timezone_input: 1, unsaved_guard: 1]

  alias GtfsPlanner.Gtfs.Agency
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
  # A version that already has agencies keeps one zone, so a new agency can only
  # be added once the version resolves it: the create actions open the timezone
  # flow with this note instead of a form that could not be saved (AC-13).
  @zone_needed_note "Choose one timezone before adding an agency."
  # The form ids the save failure hands to the `FormErrorFocus` hook; the drawer
  # markup spells the same ids, so the hook and the failure path agree.
  @agency_form_id "agency-form"
  @agency_form_error_id "agency-form-error"
  # One sentence for both ways an edit can lose its row — deleted since the list
  # was read, or a UUID from another organization or version (AC-28).
  @agency_missing_error "This agency no longer exists."
  # The deletion's receiving agency is required whenever the agency has routes,
  # and the refusal belongs beside the field that made it (AC-20).
  @target_required_error "Choose the agency that will receive these routes."
  @invalid_target_error "Choose an agency that is still in this version."

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
     |> assign(:timezone_notice, nil)
     |> assign(:agency_drawer, nil)
     |> assign(:agency_form, nil)
     |> assign(:agency_baseline, nil)
     |> assign(:agency_loaded_updated_at, nil)
     |> assign(:agency_conflict?, false)
     |> assign(:agency_conflict_reloaded?, false)
     |> assign(:agency_dirty?, false)
     |> assign(:agency_confirm_discard?, false)
     |> assign(:discard_action, nil)
     |> assign(:agency_delete, nil)
     |> assign(:agency_delete_form, nil)
     |> assign(:agency_delete_review, nil)
     |> assign(:delete_route_count, 0)
     |> assign(:delete_target_options, [])
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
    {:noreply, open_timezone_drawer(socket, params["opener_id"], nil)}
  end

  # Both creation actions land here, and the version's zone decides what opens:
  # with agencies already in the version but no single valid zone, a create could
  # not be saved, so the timezone flow opens under its own note (AC-13). With no
  # agencies the drawer's own timezone field is where that first zone comes from.
  @impl true
  def handle_event("open_create", params, socket) do
    if socket.assigns.health.agency_count > 0 && unresolved_zone?(socket.assigns.health.zone) do
      {:noreply, open_timezone_drawer(socket, params["opener_id"], @zone_needed_note)}
    else
      {:noreply, open_create_drawer(socket, params["opener_id"])}
    end
  end

  # Every agency name in the list opens the row it names. The load is the same
  # scoped read the list uses (CR-1), so a UUID from another organization or
  # version opens nothing and says so instead of showing a form that could not be
  # saved (AC-28).
  @impl true
  def handle_event("open_edit", params, socket) do
    {:noreply, open_edit_drawer(socket, params["id"], params["opener_id"])}
  end

  # Validation on change goes through `FeedSettings.change_agency/2`, the same
  # changeset the save uses, so a change the save would refuse is visible beside
  # its field as the editor types it (R9, AC-12).
  # A change event can arrive after the drawer closed; there is no draft to validate.
  @impl true
  def handle_event("validate_agency", _params, %{assigns: %{agency_baseline: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("validate_agency", %{"agency" => params}, socket) do
    changeset = FeedSettings.change_agency(socket.assigns.agency_baseline, params)

    {:noreply, assign_agency_draft(socket, changeset, :validate)}
  end

  def handle_event("validate_agency", _params, socket), do: {:noreply, socket}

  # The edit drawer's save is the same form event as the create drawer's, so the
  # open drawer decides which context call the one write path makes.
  @impl true
  def handle_event(
        "save_agency",
        %{"agency" => params},
        %{assigns: %{agency_drawer: :edit}} = socket
      ),
      do: {:noreply, update_edited_agency(socket, params)}

  # The one write path of the create drawer: the context authorizes the actor,
  # locks the published version, resolves the zone, chooses the ID and runs the
  # backfill in one transaction (R1, R2, R6, R10, INV-2, INV-5).
  @impl true
  def handle_event("save_agency", %{"agency" => params}, socket) do
    case FeedSettings.create_agency(audit_context(socket), params) do
      {:ok, agency} ->
        {:noreply,
         socket
         |> close_agency()
         |> load_agencies()
         |> put_flash(:info, "#{agency.agency_name} created.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_agency_draft(changeset)
         |> push_event("focus_form_error", %{
           form_id: @agency_form_id,
           fallback_id: @agency_form_error_id
         })}

      # The version lost its single zone between opening the drawer and saving, so
      # no agency was created. The page reloads first, because the drawer that
      # opens next describes the version as it now is, not as it was when the
      # form was opened.
      {:error, :timezone_unresolved} ->
        {:noreply,
         socket
         |> close_agency()
         |> load_agencies()
         |> open_timezone_drawer(nil, @zone_needed_note)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> close_agency()
         |> put_flash(:error, "You no longer have editor access to this organization.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> close_agency()
         |> put_flash(:error, "This version is no longer available.")
         |> push_navigate(to: settings_path(socket.assigns.current_gtfs_version.id))}
    end
  end

  def handle_event("save_agency", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("load_latest_agency", _params, socket) do
    {:noreply, reload_edited_agency(socket)}
  end

  # Every route out of the create drawer — Cancel, the close button and, through
  # the `OverlayDialog` hook's dismiss control, Escape and the backdrop — lands on
  # this event, so a changed draft is asked about exactly once (AC-6).
  @impl true
  def handle_event("close_agency_drawer", _params, socket) do
    {:noreply, request_agency_close(socket)}
  end

  @impl true
  def handle_event("cancel_discard_agency", _params, socket) do
    {:noreply, socket |> assign(:agency_confirm_discard?, false) |> assign(:discard_action, nil)}
  end

  @impl true
  def handle_event("confirm_discard_agency", _params, socket) do
    {:noreply, confirm_discard(socket)}
  end

  # The edit footer's Delete agency action and the review step's Back both land
  # here. A changed draft is asked about first, because the deletion reviews the
  # stored agency and the entries would be lost on either path (AC-6); from the
  # review step the same event returns to the receiving-agency choice with the
  # choice the editor already made still selected.
  @impl true
  def handle_event("start_delete", _params, socket) do
    cond do
      socket.assigns.agency_dirty? ->
        {:noreply,
         socket |> assign(:discard_action, :delete) |> assign(:agency_confirm_discard?, true)}

      socket.assigns.agency_delete in [:delete_review, :delete_stale] ->
        {:noreply, assign(socket, :agency_delete, :delete_choose)}

      true ->
        {:noreply, open_delete_drawer(socket)}
    end
  end

  # The review is the context's own: it reads what would move, what blocks the
  # deletion and the fingerprint that binds this command, and the drawer shows one
  # of three states from that result (AC-20, AC-21, INV-3). An agency with no
  # routes renders no field at all, so the form's payload is empty and the missing
  # receiving agency is the same command either way.
  @impl true
  def handle_event(
        "review_delete",
        params,
        %{assigns: %{agency_delete: :delete_choose}} = socket
      ),
      do:
        {:noreply, review_agency_deletion(socket, chosen_target(params["agency_delete"] || %{}))}

  # A review with no deletion step open is not a state the UI can submit.
  def handle_event("review_delete", _params, socket), do: {:noreply, socket}

  # Refresh review re-runs the review, after the context refused to apply one,
  # with the same receiving agency: the editor reviews the version as it is now
  # rather than the one they reviewed (AC-22).
  @impl true
  def handle_event(
        "refresh_delete_review",
        _params,
        %{assigns: %{agency_delete_review: nil}} = socket
      ),
      do: {:noreply, socket}

  @impl true
  def handle_event("refresh_delete_review", _params, socket) do
    review = socket.assigns.agency_delete_review

    {:noreply, review_agency_deletion(socket, review.target && review.target.id)}
  end

  # Apply hands the reviewed fingerprint back unchanged: the context re-reads the
  # version under its write lock and refuses with `:stale_review` if anything the
  # review observed has moved, so a stale command moves and deletes nothing
  # (AC-22, INV-3).
  @impl true
  def handle_event(
        "apply_delete",
        _params,
        %{assigns: %{agency_delete: :delete_review}} = socket
      ),
      do: {:noreply, apply_agency_deletion(socket)}

  def handle_event("apply_delete", _params, socket), do: {:noreply, socket}

  # "Back to agency" returns to the form the drawer opened with, so the blocked
  # state has a way out that is not the close button (AC-21).
  @impl true
  def handle_event("back_to_agency", _params, socket) do
    {:noreply, assign(socket, :agency_delete, nil)}
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
        <.settings_nav
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:agencies}
          organization={@current_organization}
        />
      </:sub_header>

      <%= if @health.agency_count == 0 do %>
        <.header>
          Agencies
          <:subtitle>{first_use_subtitle()}</:subtitle>
        </.header>

        <.empty_state id="agencies-empty" title="Give your service a name" class="mt-6">
          {empty_body(@health.unassigned_routes)}
          <:action>
            <.button
              id="agencies-create-first"
              class="min-h-11"
              phx-click="open_create"
              phx-value-opener_id="agencies-create-first"
            >
              Create first agency
            </.button>
          </:action>
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
          <:actions>
            <.button
              id="agencies-create"
              class="min-h-11"
              phx-click="open_create"
              phx-value-opener_id="agencies-create"
            >
              Create agency
            </.button>
          </:actions>
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
                <button
                  id={"agency-open-#{row.agency.id}"}
                  type="button"
                  phx-click="open_edit"
                  phx-value-id={row.agency.id}
                  phx-value-opener_id={"agency-open-#{row.agency.id}"}
                  class="inline-block min-h-11 text-left font-semibold break-words text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
                >
                  {row.agency.agency_name}
                </button>
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
        notice={@timezone_notice}
        resolved?={resolved_zone?(@health.zone)}
        return_focus_id={@return_focus_id}
        version={@current_gtfs_version}
        organization={@current_organization}
      />

      <.agency_drawer
        mode={@agency_drawer}
        form={@agency_form}
        agency={@agency_baseline}
        first_agency?={@health.agency_count == 0}
        last_agency?={@health.agency_count == 1}
        delete_mode={@agency_delete}
        delete_form={@agency_delete_form}
        delete_review={@agency_delete_review}
        delete_route_count={@delete_route_count}
        delete_target_options={@delete_target_options}
        zone={zone_name(@health.zone)}
        zone_names={@zone_names}
        conflict?={@agency_conflict?}
        conflict_reloaded?={@agency_conflict_reloaded?}
        dirty?={@agency_dirty?}
        return_focus_id={@return_focus_id}
        version={@current_gtfs_version}
        organization={@current_organization}
      />

      <%!--
        The discard question is the only exit from a changed draft, so the create
        drawer stays open and visible behind it. Escape belongs to the dialog while
        it is up: the `OverlayDialog` hook turns it into a click on "Keep editing".
        `described_by` names `.confirm_dialog`'s own `#agency-discard-body` wrapper,
        so the paragraph inside it carries no id of its own.
      --%>
      <.confirm_dialog
        :if={@agency_confirm_discard?}
        id="agency-discard"
        open={true}
        title="Discard unsaved changes?"
        confirm_label="Discard changes"
        pending_label="Discarding…"
        cancel_label="Keep editing"
        on_confirm="confirm_discard_agency"
        on_cancel="cancel_discard_agency"
        confirm_variant="danger"
        described_by="agency-discard-body"
      >
        <p>{agency_discard_body(@agency_drawer)}</p>
      </.confirm_dialog>
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
  attr :notice, :string, default: nil
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
          <%!-- A create action that could not open its own form leaves the reason
          here, so the editor reads why the timezone flow opened instead (AC-13). --%>
          <.callout
            :if={@notice}
            id="agency-timezone-notice"
            kind="info"
            title={@notice}
            class="mt-4"
          />

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

  # The create and edit drawers are the prototype's agency form: Agency
  # identity, then Rider contact, in one surface whose fields step 18's edit mode
  # reuses unchanged. Only the create form of a version's first agency carries
  # the schedule timezone field — a later agency shows the zone the version
  # already holds and takes it on save, and the edit form shows that zone as a
  # note because a second zone is what the timezone flow exists to prevent
  # (R2, AC-12, AC-15). The edit mode adds the prototype's identity box above the
  # fields and names the stored row in the title.
  #
  # The edit footer also carries the deletion's first action, and the same drawer
  # then shows one of the deletion's steps in place of the form: choosing the
  # receiving agency, reviewing what moves, what blocks the deletion, or the stale
  # notice after the context refused an apply (AC-19, AC-20, AC-21, AC-22).
  attr :mode, :any, required: true
  attr :form, :any, required: true
  attr :agency, :any, default: nil
  attr :first_agency?, :boolean, required: true
  attr :last_agency?, :boolean, required: true
  attr :delete_mode, :any, required: true
  attr :delete_form, :any, required: true
  attr :delete_review, :any, required: true
  attr :delete_route_count, :integer, required: true
  attr :delete_target_options, :list, required: true
  attr :zone, :string, default: nil
  attr :zone_names, :list, required: true
  attr :conflict?, :boolean, required: true
  attr :conflict_reloaded?, :boolean, required: true
  attr :dirty?, :boolean, required: true
  attr :return_focus_id, :string, default: nil
  attr :version, :any, required: true
  attr :organization, :any, required: true

  defp agency_drawer(assigns) do
    ~H"""
    <.drawer
      id="agency-drawer"
      open={@mode != nil}
      on_close="close_agency_drawer"
      title={agency_drawer_title(@mode, @agency, @delete_mode)}
      return_focus_id={@return_focus_id}
    >
      <:header_actions>
        <span
          :if={@dirty?}
          id="agency-unsaved"
          class="badge badge-warning badge-sm whitespace-nowrap"
        >
          Unsaved changes
        </span>
      </:header_actions>

      <div :if={@mode} id="agency-form-panel" phx-hook="FormErrorFocus">
        <.unsaved_guard id="agency-unsaved-guard" dirty={@dirty?} />

        <p id="agency-drawer-scope" class="text-xs text-base-content/70">
          {scope_line(@version, @organization)}
        </p>

        <%= if @delete_mode do %>
          <p :if={@delete_mode == :delete_choose} class="mt-2 text-sm text-base-content/70">
            {delete_choose_intro(@delete_route_count)}
          </p>

          <.agency_delete_panel
            delete={@delete_mode}
            form={@delete_form}
            review={@delete_review}
            agency={@agency}
            route_count={@delete_route_count}
            target_options={@delete_target_options}
          />
        <% else %>
          <p class="mt-2 text-sm text-base-content/70">
            {agency_drawer_intro(@mode)}
          </p>

          <%!--
            The prototype's identity box. The GTFS agency ID is derived from the
            name and preserved across imports and exports, so the edit form shows
            it as a fact and submits no field for it (R1).
          --%>
          <p
            :if={@agency}
            id="agency-identity"
            class="mt-4 rounded-box bg-base-200 px-4 py-3 text-xs text-base-content/70"
          >
            Agency ID <strong class="text-base-content">{@agency.agency_id}</strong>
            · Preserved in imports and exports
          </p>

          <.form
            for={@form}
            id="agency-form"
            novalidate
            phx-change="validate_agency"
            phx-submit="save_agency"
            class="mt-4"
          >
            <.callout
              :if={save_failed?(@form)}
              id="agency-form-error"
              kind="error"
              title={save_failed_title(@mode)}
              tabindex="-1"
              class="mb-4"
            />

            <.conflict_callout :if={@conflict?} reloaded?={@conflict_reloaded?} />

            <.agency_form_fields
              form={@form}
              first_agency?={@first_agency?}
              zone={@zone}
              zone_names={@zone_names}
            />

            <div class="mt-8 border-t border-base-300 pt-5">
              <%!-- A disabled action still names why it is unavailable, and the
              reason sits with the control that cannot be used (AC-19). --%>
              <p
                :if={@last_agency?}
                id="agency-delete-reason"
                class="mb-3 text-xs text-base-content/70"
              >
                This is the last agency in the version and can't be deleted.
              </p>

              <div class="flex flex-wrap items-center justify-end gap-3">
                <.button
                  :if={@mode == :edit}
                  id="agency-delete"
                  type="button"
                  variant="quiet"
                  class="mr-auto min-h-11 text-error disabled:pointer-events-none disabled:opacity-60"
                  disabled={@last_agency?}
                  phx-click="start_delete"
                >
                  Delete agency
                </.button>

                <.button
                  id="agency-cancel"
                  type="button"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="close_agency_drawer"
                >
                  Cancel
                </.button>

                <.button
                  id="agency-save"
                  type="submit"
                  class="min-h-11"
                  phx-disable-with={agency_pending_label(@mode)}
                >
                  {agency_submit_label(@mode)}
                </.button>
              </div>
            </div>
          </.form>
        <% end %>
      </div>
    </.drawer>
    """
  end

  # The deletion's steps in the prototype's order: name the receiving agency,
  # then review exactly what moves, and apply the command the review bound. The
  # blocked state replaces the review while a fare attribute or an attribution
  # names the agency, and the stale state replaces it when the version moved after
  # the review — both keep the next action that can advance the editor on screen
  # (R7, AC-20, AC-21, AC-22).
  attr :delete, :any, required: true
  attr :form, :any, required: true
  attr :review, :any, required: true
  attr :agency, :any, required: true
  attr :route_count, :integer, required: true
  attr :target_options, :list, required: true

  defp agency_delete_panel(assigns) do
    ~H"""
    <%= if @delete == :delete_blocked do %>
      <div id="agency-delete-blocked">
        <.callout
          id="agency-delete-blocked-callout"
          kind="warning"
          title={"#{@agency.agency_name} cannot be deleted yet"}
          class="mt-4"
        >
          <p>{blocked_body(@review.blockers)}</p>
        </.callout>

        <ul id="agency-delete-blockers" class="mt-5 divide-y divide-base-200 border-y border-base-300">
          <li
            :for={fare_id <- @review.blockers.fare_ids}
            class="flex items-start justify-between gap-4 py-3"
          >
            <span class="text-base-content/70">Fare attribute</span>
            <span class="font-semibold">{fare_id}</span>
          </li>
          <li
            :for={attribution_id <- @review.blockers.attribution_ids}
            class="flex items-start justify-between gap-4 py-3"
          >
            <span class="text-base-content/70">Attribution</span>
            <span class="font-semibold">{attribution_id}</span>
          </li>
        </ul>

        <p class="mt-5 text-sm text-base-content/70">
          Route ownership will stay unchanged until every dependency can be moved safely.
        </p>

        <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
          <.button
            id="agency-delete-back-to-agency"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="back_to_agency"
          >
            Back to agency
          </.button>

          <.button
            id="agency-delete-close"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="close_agency_drawer"
          >
            Close
          </.button>
        </div>
      </div>
    <% else %>
      <%= if @delete == :delete_choose do %>
        <div id="agency-delete-choose">
          <p
            id="agency-delete-identity"
            class="mt-4 rounded-box bg-base-200 px-4 py-3 text-xs text-base-content/70"
          >
            Agency ID <strong class="text-base-content">{@agency.agency_id}</strong>
            · {routes_label(@route_count)}
          </p>

          <.form
            for={@form}
            id="agency-delete-form"
            novalidate
            phx-submit="review_delete"
            class="mt-4"
          >
            <fieldset :if={@route_count > 0} class="mt-5 border-t border-base-300 pt-5">
              <legend class="pr-4 text-base font-semibold text-base-content">Move routes to</legend>

              <div class="mt-4">
                <.input
                  field={@form[:target_id]}
                  type="select"
                  label="Receiving agency"
                  prompt="Choose agency"
                  options={@target_options}
                  help="Route IDs and schedules will stay unchanged."
                />
              </div>
            </fieldset>

            <p class="mt-5 text-sm text-base-content/70">
              Review the exact changes before anything is deleted.
            </p>

            <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
              <.button
                id="agency-delete-cancel"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="close_agency_drawer"
              >
                Cancel
              </.button>

              <.button id="agency-delete-review-submit" type="submit" class="min-h-11">
                Review deletion
              </.button>
            </div>
          </.form>
        </div>
      <% else %>
        <div id={if @delete == :delete_stale, do: "agency-delete-stale", else: "agency-delete-review"}>
          <.callout
            :if={@delete == :delete_stale}
            id="agency-delete-stale-notice"
            kind="error"
            title="The agencies or routes changed during your review"
            class="mt-4"
          >
            <p>Nothing was moved or deleted.</p>
            <div class="mt-3">
              <.button
                id="agency-delete-refresh"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="refresh_delete_review"
              >
                Refresh review
              </.button>
            </div>
          </.callout>

          <.callout
            id="agency-delete-summary"
            kind="warning"
            title={"#{@agency.agency_name} will be deleted"}
            class="mt-4"
          >
            <p>{delete_review_summary(@review)}</p>
            <p :if={@review.translation_count > 0} id="agency-delete-translations">
              {translations_label(@review.translation_count)}
            </p>
          </.callout>

          <ul
            :if={@review.routes != []}
            id="agency-delete-routes"
            class="mt-5 divide-y divide-base-200 border-y border-base-300"
          >
            <li :for={route <- @review.routes} class="flex items-start justify-between gap-4 py-3">
              <span><strong>{route.route_id}</strong> {route_name(route)}</span>
              <span class="whitespace-nowrap text-sm text-base-content/70">Keep route ID</span>
            </li>
          </ul>

          <p
            id="agency-delete-total"
            class="mt-5 rounded-box bg-base-200 p-4 text-sm text-base-content/70"
          >
            The move and deletion must succeed together. If this review becomes out of date,
            nothing is changed.
          </p>

          <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
            <.button
              id="agency-delete-back"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="start_delete"
            >
              Back
            </.button>

            <%!-- The reviewed command is the only apply that can succeed, so a
            stale review disables the submit and offers Refresh review instead
            (AC-22). --%>
            <.button
              id="agency-delete-apply"
              type="button"
              variant="danger"
              class="min-h-11"
              disabled={@delete == :delete_stale}
              phx-click="apply_delete"
              phx-disable-with="Deleting…"
            >
              {delete_apply_label(@review)}
            </.button>
          </div>
        </div>
      <% end %>
    <% end %>
    """
  end

  # A conflicting save keeps the draft and the entries the editor typed and
  # names the two ways forward: reloading the base now, or, once reloaded,
  # saving again over it. It is the Feed details drawer's pattern over one
  # agency row (AC-16).
  attr :reloaded?, :boolean, required: true

  defp conflict_callout(assigns) do
    ~H"""
    <.callout
      id="agency-conflict"
      kind={if @reloaded?, do: "info", else: "error"}
      title={conflict_title(@reloaded?)}
      class="mb-4"
    >
      <p>{conflict_body(@reloaded?)}</p>

      <.button
        :if={!@reloaded?}
        id="agency-load-latest"
        type="button"
        variant="secondary"
        class="mt-3 min-h-11"
        phx-click="load_latest_agency"
      >
        Load latest
      </.button>
    </.callout>
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

  # One entry point for both actions that open the timezone drawer: the band and
  # the callout themselves, and a create action that a version's unresolved zone
  # sends here instead of opening a form it could not save (AC-13).
  defp open_timezone_drawer(socket, opener_id, notice) do
    socket
    |> assign(:timezone_drawer, :choose)
    |> assign(:timezone_form, timezone_form(prefilled_zone(socket.assigns.health.zone)))
    |> assign(:timezone_agencies, agencies_in_scope(socket))
    |> assign(:timezone_review, nil)
    |> assign(:timezone_ack_error, nil)
    |> assign(:timezone_notice, notice)
    |> assign(:zone_names, DisplayClock.zone_names())
    |> assign(:return_focus_id, opener_id)
  end

  defp close_timezone(socket) do
    socket
    |> assign(:timezone_drawer, nil)
    |> assign(:timezone_review, nil)
    |> assign(:timezone_ack_error, nil)
    |> assign(:timezone_notice, nil)
    |> assign(:timezone_agencies, [])
    |> assign(:zone_names, [])
  end

  # The create form is built on an empty agency carrying the scope, so the
  # changeset the drawer validates with is the one the save would insert, and the
  # zone catalog is read only for the first agency: that is the one case with a
  # timezone field to suggest names for (R2).
  defp open_create_drawer(socket, opener_id) do
    baseline = %Agency{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id
    }

    first_agency? = socket.assigns.health.agency_count == 0

    socket
    |> clear_agency_edit_state()
    |> assign(:agency_baseline, baseline)
    |> assign(:agency_drawer, :create)
    |> assign(:agency_confirm_discard?, false)
    |> assign(:zone_names, if(first_agency?, do: DisplayClock.zone_names(), else: []))
    |> assign(:return_focus_id, opener_id)
    |> assign_agency_draft(FeedSettings.change_agency(baseline, %{}))
  end

  # Opening the edit drawer reads the row through the scoped context read and
  # keeps the `updated_at` it loaded in the socket, never in the form (CR-1,
  # CR-9). A row that is gone, foreign or malformed opens nothing: the page
  # behind the drawer is the version as it now is, and the flash says why.
  defp open_edit_drawer(socket, id, opener_id) do
    case FeedSettings.get_agency(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           id
         ) do
      nil ->
        put_flash(socket, :error, @agency_missing_error)

      agency ->
        socket
        |> assign(:agency_baseline, agency)
        |> assign(:agency_drawer, :edit)
        |> assign(:agency_loaded_updated_at, agency.updated_at)
        |> assign(:agency_confirm_discard?, false)
        |> assign(:agency_conflict?, false)
        |> assign(:agency_conflict_reloaded?, false)
        |> assign(:zone_names, [])
        |> assign(:return_focus_id, opener_id)
        |> assign_agency_draft(FeedSettings.change_agency(agency, %{}))
    end
  end

  # The one write path of the edit drawer: the context authorizes the actor,
  # share-locks the published version, loads the scoped row under its own lock
  # and compares the token the drawer loaded, in one transaction (R8, R10,
  # INV-2, INV-5). A token that no longer matches is reported as the conflict it
  # is, with the draft and the entries kept and nothing written (AC-16).
  defp update_edited_agency(socket, params) do
    case FeedSettings.update_agency(
           audit_context(socket),
           socket.assigns.agency_baseline.id,
           params,
           socket.assigns.agency_loaded_updated_at
         ) do
      {:ok, _agency} ->
        socket
        |> close_agency()
        |> load_agencies()
        |> put_flash(:info, "Changes saved.")

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign_agency_draft(changeset)
        |> push_event("focus_form_error", %{
          form_id: @agency_form_id,
          fallback_id: @agency_form_error_id
        })

      {:error, :stale} ->
        changeset = FeedSettings.change_agency(socket.assigns.agency_baseline, params)

        socket
        |> assign_agency_draft(changeset)
        |> assign(:agency_conflict?, true)
        |> assign(:agency_conflict_reloaded?, false)

      {:error, :forbidden} ->
        socket
        |> close_agency()
        |> put_flash(:error, "You no longer have editor access to this organization.")

      # The row can be deleted by another editor while this drawer is open, and
      # the scoped load reports that as the same `:not_found` a foreign id gets:
      # nothing is written and the page reloads without the row (AC-28).
      {:error, :not_found} ->
        socket
        |> close_agency()
        |> load_agencies()
        |> put_flash(:error, @agency_missing_error)
    end
  end

  # Reloading the base keeps the draft the editor typed and the token the next
  # save compares against, so saving again replaces what the other editor stored
  # instead of reporting the same conflict a second time (AC-16).
  defp reload_edited_agency(socket) do
    baseline = socket.assigns.agency_baseline

    case FeedSettings.get_agency(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           baseline && baseline.id
         ) do
      nil ->
        socket
        |> close_agency()
        |> load_agencies()
        |> put_flash(:error, @agency_missing_error)

      latest ->
        changeset = FeedSettings.change_agency(latest, agency_draft_params(socket))

        socket
        |> assign(:agency_baseline, latest)
        |> assign(:agency_loaded_updated_at, latest.updated_at)
        |> assign_agency_draft(changeset)
        |> assign(:agency_conflict?, true)
        |> assign(:agency_conflict_reloaded?, true)
    end
  end

  # The values the editor has typed, read back from the form they were typed in,
  # so reloading the base replaces the stored row and not the draft.
  defp agency_draft_params(%{assigns: %{agency_form: %Phoenix.HTML.Form{} = form}}),
    do: form.source.params || %{}

  defp agency_draft_params(_socket), do: %{}

  # Delete agency switches the same drawer to the deletion's first step. The
  # version is read first, so the refusal and the choices describe it as it now
  # is: a row another editor deleted closes the drawer with the same sentence the
  # rest of the flow uses (AC-28), and an agency set of one has no receiving
  # agency to offer, so the action stays unavailable with its reason (AC-19).
  # Entering the step also resets the form, because the deletion reviews the
  # stored agency and the close that reached here already discarded the entries.
  defp open_delete_drawer(socket) do
    socket = load_agencies(socket)
    agency = socket.assigns.agency_baseline
    rows = agencies_in_scope(socket)

    cond do
      is_nil(agency) ->
        assign(socket, :agency_delete, nil)

      not Enum.any?(rows, &(&1.agency.id == agency.id)) ->
        socket |> close_agency() |> put_flash(:error, @agency_missing_error)

      length(rows) < 2 ->
        assign(socket, :agency_delete, nil)

      true ->
        socket
        |> assign_agency_draft(FeedSettings.change_agency(agency, %{}))
        |> assign(:agency_delete, :delete_choose)
        |> assign(:agency_delete_review, nil)
        |> assign(:delete_route_count, agency_route_count(rows, agency))
        |> assign(:delete_target_options, delete_target_options(rows, agency))
        |> assign_delete_form(nil)
    end
  end

  # Discarding continues to what the close was for. The deletion reviews the
  # stored agency, so the entries are discarded and the same drawer switches to
  # its first deletion step instead of closing (AC-6).
  defp confirm_discard(%{assigns: %{discard_action: :delete}} = socket) do
    socket
    |> assign(:discard_action, nil)
    |> assign(:agency_confirm_discard?, false)
    |> open_delete_drawer()
  end

  defp confirm_discard(socket), do: close_agency(socket)

  # The context's review decides which step the editor sees: what blocks the
  # deletion first, then what would move. Each refusal lands where the editor can
  # act on it, and a scope that is gone closes the drawer rather than showing a
  # command that cannot be applied (AC-19, AC-20, AC-21, INV-3).
  defp review_agency_deletion(socket, target_id) do
    case FeedSettings.review_agency_deletion(
           audit_context(socket),
           socket.assigns.agency_baseline.id,
           target_id
         ) do
      {:ok, review} ->
        socket
        |> assign(:agency_delete_review, review)
        |> assign(
          :agency_delete,
          if(deletion_blocked?(review), do: :delete_blocked, else: :delete_review)
        )
        |> assign_delete_form(target_id)

      {:error, :target_required} ->
        socket
        |> assign(:agency_delete, :delete_choose)
        |> assign_delete_form(target_id, @target_required_error)

      {:error, :invalid_target} ->
        socket
        |> assign(:agency_delete, :delete_choose)
        |> assign_delete_form(target_id, @invalid_target_error)

      # The version came down to one agency between opening this step and
      # reviewing it, so there is nothing to delete: the page reloads, the drawer
      # behind the step shows the row it names, and the reason the action is
      # unavailable is on screen (AC-19).
      {:error, :last_agency} ->
        socket |> load_agencies() |> assign(:agency_delete, nil)

      {:error, :forbidden} ->
        socket
        |> close_agency()
        |> put_flash(:error, "You no longer have editor access to this organization.")

      {:error, :not_found} ->
        socket
        |> close_agency()
        |> load_agencies()
        |> put_flash(:error, @agency_missing_error)
    end
  end

  # The one write of the deletion flow: the context authorizes the actor, locks
  # the published version row, re-reads the reviewed state and compares the
  # fingerprint the review returned (R7, INV-2, INV-3). A version that moved
  # returns `:stale_review` with nothing written, which is the step that offers
  # Refresh review (AC-22).
  defp apply_agency_deletion(socket) do
    review = socket.assigns.agency_delete_review

    case FeedSettings.delete_agency(
           audit_context(socket),
           review.agency.id,
           review.target && review.target.id,
           review.fingerprint
         ) do
      {:ok, %{moved_routes: moved_routes, target: target}} ->
        socket
        |> close_agency()
        |> load_agencies()
        |> put_flash(:info, deleted_flash(review.agency, moved_routes, target))

      # The review stays on screen: it is what the editor reviewed, and the stale
      # notice is where Refresh review starts a fresh one (AC-22).
      {:error, :stale_review} ->
        assign(socket, :agency_delete, :delete_stale)

      {:error, :forbidden} ->
        socket
        |> close_agency()
        |> put_flash(:error, "You no longer have editor access to this organization.")

      # The reviewed id came from the server, so a malformed one is only reachable
      # by a caller outside this page: what remains is a version that stopped
      # being writable, and the editor is sent back to Settings (AC-28).
      {:error, :not_found} ->
        socket
        |> close_agency()
        |> put_flash(:error, "This version is no longer available.")
        |> push_navigate(to: settings_path(socket.assigns.current_gtfs_version.id))
    end
  end

  # The receiving agency is a form field so its refusal is shown beside the
  # control that caused it, the way the zone field carries a refused review. The
  # choice is kept as the field's value, so re-reviewing the same command does
  # not ask the editor to choose again (R7).
  defp assign_delete_form(socket, target_id, error \\ nil) do
    changeset =
      {%{}, %{target_id: :string}}
      |> Ecto.Changeset.cast(%{"target_id" => target_id}, [:target_id])
      |> add_form_error(:target_id, error)

    assign(
      socket,
      :agency_delete_form,
      to_form(changeset, as: :agency_delete, id: "agency-delete-form")
    )
  end

  # The select's prompt submits an empty string and a form with no field at all
  # submits nothing: both are the absent receiving agency, and the context decides
  # whether this command needs one (R7).
  defp chosen_target(params) do
    case params["target_id"] do
      nil -> nil
      "" -> nil
      target_id -> target_id
    end
  end

  defp deletion_blocked?(review) do
    review.blockers.fare_ids != [] or review.blockers.attribution_ids != []
  end

  defp agency_route_count(rows, agency) do
    case Enum.find(rows, &(&1.agency.id == agency.id)) do
      nil -> 0
      row -> row.route_count
    end
  end

  defp delete_target_options(rows, agency) do
    rows
    |> Enum.reject(&(&1.agency.id == agency.id))
    |> Enum.map(&{&1.agency.agency_name, &1.agency.id})
  end

  # The form, the action it reports and the dirty state always move together, so
  # one helper binds them: a handler cannot show a draft the guard would ignore,
  # or guard a form that shows nothing. `action: :validate` marks the round trip
  # as a keystroke, so `used_input?/1` shows an error beside the field the editor
  # has touched and the create-failure callout stays for saves only.
  defp assign_agency_draft(socket, changeset, action \\ nil) do
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset

    socket
    |> assign(:agency_form, to_form(changeset, as: :agency, id: @agency_form_id))
    |> assign(:agency_dirty?, changeset.changes != %{})
  end

  # A changed draft is never discarded by accident: every close route lands
  # here, and only "Discard changes" reaches `close_agency/1`.
  defp request_agency_close(%{assigns: %{agency_dirty?: true}} = socket),
    do: assign(socket, :agency_confirm_discard?, true)

  defp request_agency_close(socket), do: close_agency(socket)

  defp close_agency(socket) do
    socket
    |> assign(:agency_drawer, nil)
    |> assign(:agency_form, nil)
    |> assign(:agency_baseline, nil)
    |> assign(:agency_dirty?, false)
    |> assign(:agency_confirm_discard?, false)
    |> assign(:discard_action, nil)
    |> assign(:agency_delete, nil)
    |> assign(:agency_delete_form, nil)
    |> assign(:agency_delete_review, nil)
    |> assign(:delete_route_count, 0)
    |> assign(:delete_target_options, [])
    |> assign(:zone_names, [])
    |> clear_agency_edit_state()
  end

  # The edit-only state — the loaded `updated_at` token (CR-9) and the conflict
  # callout — never survives into a closed drawer or a create form that has no
  # stored row behind it.
  defp clear_agency_edit_state(socket) do
    socket
    |> assign(:agency_loaded_updated_at, nil)
    |> assign(:agency_conflict?, false)
    |> assign(:agency_conflict_reloaded?, false)
  end

  # A failed save is the only state that earns the view-level banner. Validation
  # on change marks its own fields and must not shout about a save never attempted.
  defp save_failed?(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action, errors: errors}})
       when action in [:update, :insert] and errors != [],
       do: true

  defp save_failed?(_form), do: false

  # The edit drawer is titled with the stored name, which is what the list row
  # the editor clicked showed (AC-15); the deletion steps are titled for what
  # they do — the agency they would remove, the removal review, or what blocks
  # it — and the create drawer has one title.
  defp agency_drawer_title(_mode, %Agency{agency_name: name}, :delete_choose),
    do: "Delete #{name}?"

  defp agency_drawer_title(_mode, _agency, :delete_blocked), do: "Agency still used by fares"

  defp agency_drawer_title(_mode, _agency, mode) when mode in [:delete_review, :delete_stale],
    do: "Review agency removal"

  defp agency_drawer_title(:edit, %Agency{agency_name: name}, nil), do: name
  defp agency_drawer_title(_mode, _agency, nil), do: "Create agency"

  # The chooser's intro is the prototype's own sentence for each case: routes make
  # the receiving agency the point of the step, and no routes means the deletion
  # removes only the identity and contact details (AC-20).
  defp delete_choose_intro(0),
    do:
      "This agency has no routes. Deleting it removes its identity and contact details from this version."

  defp delete_choose_intro(_route_count),
    do: "Keep the routes by assigning them to another agency before removing this provider."

  defp delete_review_summary(%{target: nil}), do: "No routes or fare references need to move."

  defp delete_review_summary(review) do
    "#{routes_label(length(review.routes))} will move to #{review.target.agency_name}. " <>
      "No routes will be deleted."
  end

  defp translations_label(1), do: "1 translation of this agency's text is also removed."

  defp translations_label(count),
    do: "#{count} translations of this agency's text are also removed."

  defp delete_apply_label(%{target: nil}), do: "Delete agency"
  defp delete_apply_label(_review), do: "Move routes and delete"

  # The blocked state names what has to move first, so the list of IDs below it
  # reads as references rather than as unexplained rows (AC-21).
  defp blocked_subject(%{fare_ids: [_], attribution_ids: []}),
    do: "A fare attribute still refers"

  defp blocked_subject(%{fare_ids: [], attribution_ids: [_]}),
    do: "An attribution still refers"

  defp blocked_subject(_blockers), do: "Fare attributes and attributions still refer"

  defp blocked_body(blockers) do
    "#{blocked_subject(blockers)} to this agency. " <>
      "Reassign those references before moving routes and deleting the agency."
  end

  # The reviewed routes are named by their long name where they have one and
  # their short name where they do not, the way the Routes list reads them.
  defp route_name(%{route_long_name: name}) when is_binary(name) and name != "", do: name
  defp route_name(%{route_short_name: name}), do: name || ""

  defp deleted_flash(agency, 0, nil), do: "#{agency.agency_name} deleted."

  defp deleted_flash(agency, moved_routes, target) do
    "#{agency.agency_name} deleted. #{moved_routes_label(moved_routes)} to #{target.agency_name}."
  end

  defp moved_routes_label(1), do: "1 route moved"
  defp moved_routes_label(count), do: "#{count} routes moved"

  defp agency_drawer_intro(:edit),
    do: "Keep the details riders see in journey planners up to date. Optional fields are marked."

  defp agency_drawer_intro(_mode),
    do: "Use the public name riders recognize. Optional fields are marked."

  defp save_failed_title(:edit), do: "Nothing was saved. Check the highlighted fields."
  defp save_failed_title(_mode), do: "Nothing was created. Check the highlighted fields."

  defp agency_submit_label(:edit), do: "Save changes"
  defp agency_submit_label(_mode), do: "Create agency"

  defp agency_pending_label(:edit), do: "Saving…"
  defp agency_pending_label(_mode), do: "Creating…"

  defp agency_discard_body(:edit),
    do: "Your entries will be lost. The stored agency stays unchanged."

  defp agency_discard_body(_mode), do: "Your entries will be lost. No agency is created."

  defp conflict_title(false), do: "Another editor changed this agency"
  defp conflict_title(true), do: "Latest agency loaded"
  defp conflict_body(false), do: "Nothing was saved. Your entries are kept."
  defp conflict_body(true), do: "Save again to replace their changes."

  defp zone_name({:ok, zone}), do: zone
  defp zone_name({:unresolved, _reason}), do: nil

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

  # The zone is one free-text field the context validates in one place, so the
  # form is one value plus, after a refused review, the error that review
  # returned. No client-side rule repeats `DisplayClock.valid_zone?/1` (INV-4).
  defp timezone_form(zone, error \\ nil) do
    {%{}, %{zone: :string}}
    |> Ecto.Changeset.cast(%{"zone" => zone}, [:zone])
    |> add_form_error(:zone, error)
    |> to_form(as: :timezone)
  end

  # A refused review is a keystroke-shaped round trip rather than a save, and the
  # action is what makes the error the editor's own submitted value: Phoenix
  # drops the errors of a changeset with no action, so the refusal would render
  # nowhere without it. Both the zone field and the deletion's receiving agency
  # show their refusal this way.
  defp add_form_error(changeset, _field, nil), do: changeset

  defp add_form_error(changeset, field, message) do
    changeset
    |> Ecto.Changeset.add_error(field, message)
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
