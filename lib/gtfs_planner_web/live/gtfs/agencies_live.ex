defmodule GtfsPlannerWeb.Gtfs.AgenciesLive do
  @moduledoc """
  Shows one version's agencies with their route counts and its timezone state.

  Agencies are the transit providers riders see in journey planners, so the page
  answers three questions at once: who operates this version, which routes each
  provider runs (R5, AC-9), and whether every agency agrees on one schedule
  timezone (AC-10). Each route count links to the Routes list filtered to that
  agency, or to the unfiltered list when the version has one agency, because a
  single-agency list filtered to it says the same thing.

  One agency reads as a summary of what riders see (name, website, rider contact,
  route count) with its GTFS terms behind a disclosure, and Edit details is the
  page's primary. Two or more read as a streamed table whose headers sort by name
  or route count, keeping the sort in assigns and resetting the stream; Create
  agency is the primary. The schedule timezone is a fact about the version, so it
  sits in a panel beside the agencies; the table gains a Timezone column, sortable
  and marked "Needs review" on every row whose zone differs from the version
  zone, only while the agencies disagree. That problem also raises a warning
  message that names the reason and carries Resolve timezones, which takes the
  primary. A version with no agency shows the first-use empty state instead: it
  names the routes that still need an agency so the editor knows what creating
  the first one will assign (AC-11).

  Reads go through `GtfsPlanner.Gtfs.FeedSettings`, scoped to the organization
  and version, and the timezone verdict is `DisplayClock`'s own: this LiveView
  holds no timezone rule of its own (INV-4) and makes no `Repo` call (CR-1).

  The panel's Change timezone action and the warning's Resolve timezones action
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
  `#agency-drawer`, whose form holds the prototype's two sections, Name and
  website and Rider contact. Only the version's first agency carries a schedule
  timezone field, because the first agency decides the version's zone and every
  later one takes it (R2, AC-12); validating and saving go through
  `FeedSettings.change_agency/2` and `create_agency/2` (CR-1). A version that
  already has agencies but no single valid zone cannot take another one: both
  actions open the timezone flow instead, and the server refuses the same case
  with `:timezone_unresolved` (AC-13). An unsaved form is protected like the Feed
  details drawer — the discard question on every close route and the shared
  `unsaved_guard/1` hook on reload (AC-6).

  Editing is that drawer over one stored row. Each name in the table, and Edit
  details on the summary, is a button that loads its row with the scoped
  `FeedSettings.get_agency/3` and keeps the `updated_at` it loaded in the socket,
  never in a hidden field (CR-1, CR-9); the drawer shows the agency ID as a
  read-only note where it would be edited, the version zone as a note instead of
  a second zone field, and saves through `FeedSettings.update_agency/4`. A save
  another editor beat is a conflict rather than a silent overwrite: the draft
  stays on screen with "Load latest", and once the latest row and its token are
  loaded the next save replaces their values (AC-15, AC-16). A row that is gone —
  deleted, foreign or from another version — flashes "This agency no longer
  exists." and opens nothing (AC-28).

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

  import GtfsPlannerWeb.PlannerComponents,
    only: [
      aside_link: 1,
      back_link: 1,
      drawer_footer: 1,
      drawer_scroll: 1,
      first_use: 1,
      form_section: 1,
      message: 1,
      safe_href: 2,
      scope_line: 1,
      unsaved_badge: 1
    ]

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.LanguageCodes
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
     |> assign(:sole_agency, nil)
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
      <div id="agencies-page" class="ds-page">
        <.back_link id="settings-back" navigate={settings_path(@current_gtfs_version.id)}>
          Settings
        </.back_link>

        <.header>
          Agencies
          <:subtitle>
            {subtitle(@health.agency_count)}
            <.scope_line id="agencies-scope" icon="hero-calendar">
              {version_scope(@current_gtfs_version)}
            </.scope_line>
          </:subtitle>
          <:actions :if={@health.agency_count > 0}>
            <.button
              id="agencies-create"
              variant={create_variant(@health)}
              class="min-h-11"
              phx-click="open_create"
              phx-value-opener_id="agencies-create"
            >
              <.icon name="hero-plus" class="size-4" /> Create agency
            </.button>
          </:actions>
        </.header>

        <%!-- The message's margin lives on a wrapper because the component spreads
        global attributes onto its own class list. --%>
        <div :if={zone_problem?(@health)} class="mb-6">
          <.message
            id="agencies-timezone-callout"
            kind="warning"
            title={callout_title(@health.zone)}
          >
            Choose one timezone for this version. Calendars use UTC until then.
            <:action>
              <.button
                id="agencies-resolve-timezones"
                type="button"
                class="min-h-11"
                phx-click="open_timezone"
                phx-value-opener_id="agencies-resolve-timezones"
              >
                Resolve timezones
              </.button>
            </:action>
          </.message>
        </div>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem] lg:items-start">
          <div class="min-w-0">
            <.first_use
              :if={@health.agency_count == 0}
              id="agencies-empty"
              title="Give your service a name"
              icon="hero-building-office"
            >
              {empty_body(@health.unassigned_routes)}
              <:action>
                <.button
                  id="agencies-create-first"
                  class="min-h-11"
                  phx-click="open_create"
                  phx-value-opener_id="agencies-create-first"
                >
                  <.icon name="hero-plus" class="size-4" /> Create first agency
                </.button>
              </:action>
            </.first_use>

            <.agency_summary
              :if={@sole_agency}
              row={@sole_agency}
              variant={edit_variant(@health)}
              version_id={@current_gtfs_version.id}
              agency_count={@health.agency_count}
            />

            <.agencies_table
              :if={@health.agency_count > 0 and is_nil(@sole_agency)}
              rows={@streams.agencies}
              health={@health}
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              version={@current_gtfs_version}
            />
          </div>

          <.related_information
            health={@health}
            version_id={@current_gtfs_version.id}
          />
        </div>

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
          chrome="planner"
          open={true}
          title="Discard unsaved changes?"
          confirm_label="Discard changes"
          pending_label="Discarding…"
          cancel_label="Keep editing"
          on_confirm="confirm_discard_agency"
          on_cancel="cancel_discard_agency"
          described_by="agency-discard-body"
        >
          <p>{agency_discard_body(@agency_drawer)}</p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  # One agency reads as a summary of everything riders can see, not as a
  # one-row list: editing it is far more common than adding another, so Edit
  # details is the page's primary (`edit_variant/1`). The row is the same
  # `FeedSettings.list_agencies/2` read the table uses.
  attr :row, :map, required: true
  attr :variant, :string, required: true
  attr :version_id, :any, required: true
  attr :agency_count, :integer, required: true

  defp agency_summary(assigns) do
    agency = assigns.row.agency

    assigns =
      assigns
      |> assign(:agency, agency)
      |> assign(:opener_id, "agency-open-#{agency.id}")
      |> assign(:website_href, safe_href(:web, agency.agency_url))

    ~H"""
    <article
      id="agency-summary"
      aria-labelledby="agency-summary-name"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-start justify-between gap-4 p-5 sm:p-6">
        <div class="flex min-w-0 items-start gap-4">
          <span class="grid size-12 shrink-0 place-items-center rounded-control bg-canvas text-strong">
            <.icon name="hero-building-office" class="size-6" />
          </span>
          <div class="min-w-0">
            <h2
              id="agency-summary-name"
              class="break-words font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong"
            >
              {@agency.agency_name}
            </h2>
            <a
              :if={@website_href}
              id="agency-summary-website"
              href={@website_href}
              target="_blank"
              rel="noopener noreferrer"
              class={[link_class(), "mt-1 inline-flex min-h-11 items-center gap-1.5 text-sm"]}
            >
              {website_host(@agency.agency_url)}
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5 shrink-0" />
            </a>
            <p :if={is_nil(@website_href)} class="mt-1 break-all text-sm text-muted">
              {website_host(@agency.agency_url)}
            </p>
          </div>
        </div>

        <.button
          id={@opener_id}
          variant={@variant}
          class="min-h-11"
          phx-click="open_edit"
          phx-value-id={@agency.id}
          phx-value-opener_id={@opener_id}
        >
          <.icon name="hero-pencil-square" class="size-4" /> Edit details
        </.button>
      </div>

      <div class="grid border-t border-subtle md:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)]">
        <section class="p-5 sm:p-6" aria-labelledby="agency-summary-contact">
          <h3 id="agency-summary-contact" class="text-base font-bold text-strong">Rider contact</h3>
          <dl class="mt-2 divide-y divide-subtle">
            <.contact_row
              id="agency-summary-phone"
              icon="hero-phone"
              label="Phone"
              value={present(@agency.agency_phone)}
            />
            <.contact_row
              id="agency-summary-email"
              icon="hero-envelope"
              label="Email"
              value={present(@agency.agency_email)}
              kind={:email}
            />
            <.contact_row
              id="agency-summary-fare"
              icon="hero-ticket"
              label="Fare website"
              value={present(@agency.agency_fare_url)}
              kind={:web}
            />
            <.contact_row
              id="agency-summary-language"
              icon="hero-language"
              label="Language"
              value={LanguageCodes.label(@agency.agency_lang)}
            />
          </dl>
        </section>

        <section
          class="border-t border-subtle p-5 sm:p-6 md:border-l md:border-t-0"
          aria-labelledby="agency-summary-routes"
        >
          <h3 id="agency-summary-routes" class="text-base font-bold text-strong">Routes</h3>
          <p
            id="agency-summary-route-count"
            class="mt-3 font-display text-[40px] font-semibold leading-none tracking-tight tabular-nums text-strong"
          >
            {@row.route_count}
          </p>
          <p class="mt-1 text-sm text-default">
            {if @row.route_count == 0,
              do: "No routes use this agency yet.",
              else: "Routes riders see under this agency."}
          </p>
          <.link
            id="agency-summary-routes-link"
            navigate={routes_path(@version_id, @agency_count, @row)}
            class="mt-2 inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action no-underline hover:text-action-hover hover:underline"
            aria-label={"View #{@row.route_count} routes for #{@agency.agency_name}"}
          >
            View routes <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </section>
      </div>

      <%!-- The GTFS terms are for someone matching this agency to a file, so they
      sit behind a disclosure instead of beside what riders see. --%>
      <details id="agency-summary-technical" class="group border-t border-subtle">
        <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 px-5 text-sm font-[650] text-strong hover:bg-canvas sm:px-6 [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-4 transition-transform group-open:rotate-90"
          /> Technical details
        </summary>
        <dl class="grid gap-x-6 gap-y-3 px-5 pb-5 pt-2 text-sm sm:grid-cols-[8.5rem_minmax(0,1fr)] sm:px-6">
          <dt class="text-[13px] text-muted">Agency ID</dt>
          <dd class="min-w-0 break-all">
            <code class="rounded-badge bg-canvas px-1.5 py-0.5 font-mono text-[13px] text-strong">
              {@agency.agency_id}
            </code>
            <span class="mt-1 block text-[13px] text-muted">
              Set when the agency was created. Imports and exports keep it.
            </span>
          </dd>
          <dt class="text-[13px] text-muted">Stored timezone</dt>
          <dd class="min-w-0 break-all">
            <code
              :if={present(@agency.agency_timezone)}
              class="rounded-badge bg-canvas px-1.5 py-0.5 font-mono text-[13px] text-strong"
            >
              {@agency.agency_timezone}
            </code>
            <span :if={is_nil(present(@agency.agency_timezone))} class="text-muted">Not set</span>
          </dd>
          <dt class="text-[13px] text-muted">GTFS file</dt>
          <dd class="text-[13px] text-muted">
            These details are exported as <code class="font-mono">agency.txt</code>.
          </dd>
        </dl>
      </details>
    </article>
    """
  end

  # One row of a summary: the field's icon and name over its value, "Not set"
  # when the agency does not carry it. A web address or email is a link only when
  # `safe_href/2` says the browser can follow it.
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :kind, :atom, values: [:text, :web, :email], default: :text

  defp contact_row(assigns) do
    assigns = assign(assigns, :href, safe_href(assigns.kind, assigns.value))

    ~H"""
    <div class="grid grid-cols-[7.5rem_minmax(0,1fr)] items-center gap-3 sm:grid-cols-[8.5rem_minmax(0,1fr)]">
      <dt class="flex items-center gap-2 text-[13px] text-muted">
        <.icon name={@icon} class="size-4 shrink-0" /> {@label}
      </dt>
      <dd
        id={@id}
        class="flex min-h-11 min-w-0 flex-wrap items-center py-1 text-sm text-strong [overflow-wrap:anywhere]"
      >
        <span :if={is_nil(@value)} class="text-muted">Not set</span>
        <a
          :if={@href}
          href={@href}
          target={@kind == :web && "_blank"}
          rel={@kind == :web && "noopener noreferrer"}
          class={link_class()}
        >
          {@value}
        </a>
        <span :if={@value && is_nil(@href)}>{@value}</span>
      </dd>
    </div>
    """
  end

  # Two or more agencies are a collection, so they read as a table. Each name
  # opens its row; Routes links to the Routes list filtered to that agency. The
  # Timezone column shows only while the version has a timezone problem: when
  # every agency agrees the zone is a fact about the version, not a column, and
  # it sits in the Schedule timezone panel.
  attr :rows, :any, required: true, doc: "the `:agencies` stream"
  attr :health, :map, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :version, :any, required: true

  defp agencies_table(assigns) do
    assigns = assign(assigns, :show_zone?, unresolved_zone?(assigns.health.zone))

    ~H"""
    <section id="agencies-list" aria-labelledby="agencies-list-title">
      <div class="overflow-hidden rounded-card border border-subtle bg-white">
        <div class="px-5 py-4">
          <h2 id="agencies-list-title" class="text-base font-bold text-strong">
            {agency_count_label(@health.agency_count)}
          </h2>
        </div>

        <div id="agencies-container">
          <table class="w-full border-collapse text-sm">
            <caption class="sr-only">
              Agencies in {@version.name}
            </caption>
            <thead class="max-md:hidden">
              <tr class="border-t border-subtle bg-canvas">
                <.sort_head
                  label="Agency"
                  key="name"
                  sort={column_sort_state(@sort_by, @sort_dir, :name)}
                />
                <th scope="col" class={head_class()}>Rider contact</th>
                <.sort_head
                  :if={@show_zone?}
                  label="Timezone"
                  key="timezone"
                  sort={column_sort_state(@sort_by, @sort_dir, :timezone)}
                />
                <.sort_head
                  label="Routes"
                  key="routes"
                  align="right"
                  sort={column_sort_state(@sort_by, @sort_dir, :routes)}
                />
              </tr>
            </thead>
            <tbody id="agencies" phx-update="stream">
              <tr
                :for={{id, row} <- @rows}
                id={id}
                class="border-t border-subtle align-top hover:bg-canvas max-md:block max-md:px-4 max-md:py-4"
              >
                <td data-label="Agency" class="px-5 py-1.5 max-md:block max-md:p-0">
                  <div>
                    <button
                      id={"agency-open-#{row.agency.id}"}
                      type="button"
                      phx-click="open_edit"
                      phx-value-id={row.agency.id}
                      phx-value-opener_id={"agency-open-#{row.agency.id}"}
                      class={[
                        "inline-flex min-h-11 items-center break-words text-left font-[650] text-action underline-offset-4 hover:text-action-hover hover:underline",
                        focus_class()
                      ]}
                    >
                      {row.agency.agency_name}
                    </button>
                  </div>
                  <div class="mb-1.5 break-all text-[13px] text-muted">
                    {website_host(row.agency.agency_url)}
                  </div>
                </td>
                <td data-label="Rider contact" class="px-5 py-1.5 max-md:mt-1 max-md:block max-md:p-0">
                  <.contact_lines
                    phone={present(row.agency.agency_phone)}
                    email={present(row.agency.agency_email)}
                  />
                </td>
                <td
                  :if={@show_zone?}
                  data-label="Timezone"
                  class="px-5 py-1.5 max-md:mt-1 max-md:block max-md:p-0"
                >
                  <div class={[
                    "flex min-h-11 items-center break-all",
                    !row.agency.agency_timezone && "text-muted"
                  ]}>
                    {row.agency.agency_timezone || "Not set"}
                  </div>
                  <span
                    :if={row_needs_review?(row.agency.agency_timezone, @health.zone)}
                    class="mb-1.5 inline-flex items-center gap-1.5 rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-semibold text-warning-fg"
                  >
                    <.icon name="hero-exclamation-triangle" class="size-3.5" /> {needs_review()}
                  </span>
                </td>
                <td
                  data-label="Routes"
                  class="px-5 py-1.5 text-right max-md:mt-1 max-md:block max-md:p-0 max-md:text-left"
                >
                  <.link
                    navigate={routes_path(@version.id, @health.agency_count, row)}
                    class="inline-flex min-h-11 items-center gap-2 whitespace-nowrap text-sm font-[650] tabular-nums text-action no-underline hover:text-action-hover hover:underline"
                    aria-label={"View #{row.route_count} routes for #{row.agency.agency_name}"}
                  >
                    {routes_label(row.route_count)} <.icon name="hero-arrow-right" class="size-4" />
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <p class="mt-3 text-[13px] text-muted">Select an agency name to edit its details.</p>
    </section>
    """
  end

  defp head_class, do: "px-5 py-1.5 text-left text-[13px] font-semibold text-strong"

  attr :label, :string, required: true
  attr :key, :string, required: true
  attr :sort, :string, required: true
  attr :align, :string, default: "left"

  defp sort_head(assigns) do
    ~H"""
    <th
      scope="col"
      aria-sort={sort_aria(@sort)}
      class={[head_class(), @align == "right" && "text-right"]}
    >
      <button
        type="button"
        phx-click="sort"
        phx-value-key={@key}
        class={[
          "-mx-2 inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 font-semibold hover:bg-white",
          focus_class(),
          @align == "right" && "flex-row-reverse"
        ]}
      >
        {@label}
        <span
          aria-hidden="true"
          class={[@sort == "none" && "text-muted", @sort != "none" && "text-action"]}
        >
          {sort_arrow(@sort)}
        </span>
      </button>
    </th>
    """
  end

  defp sort_aria("asc"), do: "ascending"
  defp sort_aria("desc"), do: "descending"
  defp sort_aria(_none), do: "none"

  defp sort_arrow("asc"), do: "↑"
  defp sort_arrow("desc"), do: "↓"
  defp sort_arrow(_none), do: "↕"

  # Phone first and email under it, so the row shows what riders would call
  # before what they would write.
  attr :phone, :string, default: nil
  attr :email, :string, default: nil

  defp contact_lines(assigns) do
    assigns = assign(assigns, :lines, Enum.reject([assigns.phone, assigns.email], &is_nil/1))

    ~H"""
    <div :if={@lines == []} class="flex min-h-11 items-center text-muted">No contact details</div>
    <div :if={@lines != []} class="flex min-h-11 items-center break-all text-strong">
      {hd(@lines)}
    </div>
    <div :if={length(@lines) > 1} class="mb-1.5 break-all text-[13px] text-muted">
      {Enum.at(@lines, 1)}
    </div>
    """
  end

  # The aside answers the two questions the list cannot: which timezone the
  # version runs on, and whether the publisher is set here. Both hold whether or
  # not an agency exists yet, except the timezone, which needs one to describe.
  attr :health, :map, required: true
  attr :version_id, :any, required: true

  defp related_information(assigns) do
    ~H"""
    <aside
      id="agencies-aside"
      class="grid gap-4 lg:sticky lg:top-6"
      aria-label="Related information"
    >
      <section
        :if={@health.agency_count > 0}
        id="agencies-timezone-band"
        aria-labelledby="agencies-timezone-title"
        class="rounded-card border border-subtle bg-white p-5"
      >
        <h2 id="agencies-timezone-title" class="text-base font-bold text-strong">
          Schedule timezone
        </h2>

        <%= case @health.zone do %>
          <% {:ok, zone} -> %>
            <p
              id="agencies-timezone-value"
              class="mt-3 break-words font-display text-[22px] font-semibold leading-tight tracking-[-0.02em] text-strong"
            >
              {zone}
            </p>
            <p class="mt-2 text-sm text-default">
              Timetable times are read in this timezone. Every agency in this version shares it.
            </p>
            <.button
              id="agencies-change-timezone"
              type="button"
              variant="secondary"
              class="mt-4 min-h-11"
              phx-click="open_timezone"
              phx-value-opener_id="agencies-change-timezone"
            >
              <.icon name="hero-clock" class="size-4" /> Change timezone
            </.button>
          <% {:unresolved, reason} -> %>
            <p class="mt-3 inline-flex items-center gap-2 rounded-badge bg-warning-bg px-2.5 py-1 text-sm font-semibold text-warning-fg">
              <.icon name="hero-exclamation-triangle" class="size-4" /> {needs_review()}
            </p>
            <p class="mt-3 text-sm text-default">{unresolved_detail(reason)}</p>
            <p class="mt-2 text-sm text-muted">
              Use Resolve timezones to choose one for every agency.
            </p>
        <% end %>
      </section>

      <section id="agencies-support-note" class="rounded-card bg-canvas p-5">
        <%= if @health.agency_count == 0 do %>
          <h2 class="text-base font-bold leading-snug text-strong">Already have a GTFS feed?</h2>
          <p class="mt-2 text-sm text-default">Importing a feed brings its agencies with it.</p>
          <.aside_link id="agencies-review-import" navigate={import_path(@version_id)}>
            Review an import
          </.aside_link>
        <% else %>
          <h2 class="text-base font-bold leading-snug text-strong">
            The publisher can be different
          </h2>
          <p class="mt-2 text-sm text-default">
            An agency identifies the service riders use. The organization publishing your dataset
            can be different.
          </p>
          <.aside_link id="agencies-view-feed-details" navigate={feed_details_path(@version_id)}>
            View feed details
          </.aside_link>
        <% end %>
      </section>
    </aside>
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
      chrome="planner"
      open={@mode != nil}
      on_close="close_timezone"
      title={timezone_drawer_title(@mode, @resolved?)}
      return_focus_id={@return_focus_id}
      initial_focus={:first_field}
      class="max-w-[560px]"
    >
      <:lede>
        <span id="agency-timezone-drawer-scope">{scope_line(@version, @organization)}</span>
      </:lede>

      <div
        :if={@mode}
        id="agency-timezone-form-panel"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <%= cond do %>
          <% @mode == :choose -> %>
            <.form
              for={@form}
              id="agency-timezone-form"
              novalidate
              phx-submit="review_timezone"
              class="flex min-h-0 flex-1 flex-col"
            >
              <.drawer_scroll>
                <%!-- A create action that could not open its own form leaves the reason
                here, so the editor reads why the timezone flow opened instead (AC-13). --%>
                <.message :if={@notice} id="agency-timezone-notice" kind="info" title={@notice} />

                <p class="text-sm text-muted">
                  Every agency in this version must use one schedule timezone. Review the affected
                  agencies before applying a change.
                </p>

                <.timezone_input field={@form[:zone]} zones={@zones} id="agency-timezone-zone" />

                <.message
                  id="agency-timezone-impact"
                  kind="warning"
                  title={"This affects every agency in #{@version.name}"}
                >
                  Clock times will stay the same. Their timezone interpretation will change. Review
                  affected schedules before exporting.
                </.message>

                <ul
                  id="agency-timezone-current"
                  class="divide-y divide-subtle border-y border-subtle"
                >
                  <li :for={row <- @agencies} class="flex items-start justify-between gap-4 py-3">
                    <span class="font-semibold text-strong">{row.agency.agency_name}</span>
                    <span class="break-all text-right text-sm text-muted">
                      {row.agency.agency_timezone || "Not set"}
                    </span>
                  </li>
                </ul>
              </.drawer_scroll>

              <.drawer_footer>
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
              </.drawer_footer>
            </.form>
          <% @mode == :review -> %>
            <.form
              for={@form}
              id="agency-timezone-review-form"
              novalidate
              phx-submit="apply_timezone"
              class="flex min-h-0 flex-1 flex-col"
            >
              <.drawer_scroll>
                <.timezone_review_body mode={@mode} review={@review} version={@version} />

                <%!-- The acknowledgement is apply's own precondition. --%>
                <.input
                  id="agency-timezone-ack"
                  name="timezone[acknowledged]"
                  type="checkbox"
                  checked={false}
                  label="I have checked that this is the timezone used by these schedules."
                  errors={ack_errors(@ack_error)}
                />
              </.drawer_scroll>

              <.drawer_footer>
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
              </.drawer_footer>
            </.form>
          <% true -> %>
            <div class="flex min-h-0 flex-1 flex-col">
              <.drawer_scroll>
                <.message
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
                </.message>

                <.timezone_review_body mode={@mode} review={@review} version={@version} />
              </.drawer_scroll>

              <.drawer_footer>
                <.button
                  id="agency-timezone-back"
                  type="button"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="back_timezone"
                >
                  Back
                </.button>
              </.drawer_footer>
            </div>
        <% end %>
      </div>
    </.drawer>
    """
  end

  # What the review lists, shared by the review step and the stale step that
  # keeps it on screen: the summary (review only), one row per agency with the
  # zone it holds now, and the reminder that clock times are not converted.
  attr :mode, :atom, required: true
  attr :review, :map, required: true
  attr :version, :any, required: true

  defp timezone_review_body(assigns) do
    ~H"""
    <.message
      :if={@mode == :review}
      id="agency-timezone-review-summary"
      kind="warning"
      title={"#{agencies_label(@review.agencies)} will use #{@review.zone}"}
    >
      Only {@version.name} changes. Other versions keep their current timezone.
    </.message>

    <ul id="agency-timezone-review-list" class="divide-y divide-subtle border-y border-subtle">
      <li :for={agency <- @review.agencies} class="flex items-start justify-between gap-4 py-3">
        <div class="min-w-0">
          <div class="font-semibold text-strong">{agency.agency_name}</div>
          <div class="mt-1 break-all text-sm text-muted">
            {agency.from} → {@review.zone}
          </div>
        </div>
        <div class="whitespace-nowrap text-sm text-muted">
          {routes_label(agency.route_count)}
        </div>
      </li>
    </ul>

    <p id="agency-timezone-not-converted" class="rounded-control bg-canvas p-4 text-sm text-muted">
      Route and trip clock times are not converted. Check calendars, schedules, and overnight
      service after this change.
    </p>
    """
  end

  # The create and edit drawers are the prototype's agency form: Name and website,
  # then Rider contact, in one surface whose fields the edit mode reuses
  # unchanged. Only the create form of a version's first agency carries the
  # schedule timezone field — a later agency shows the zone the version already
  # holds and takes it on save, and the edit form shows that zone as a note
  # because a second zone is what the timezone flow exists to prevent
  # (R2, AC-12, AC-15). The edit mode adds the identity note above the fields and
  # names the stored row in the title.
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
      chrome="planner"
      open={@mode != nil}
      on_close="close_agency_drawer"
      title={agency_drawer_title(@mode, @agency, @delete_mode)}
      return_focus_id={@return_focus_id}
      initial_focus={:first_field}
      class="max-w-[560px]"
    >
      <:header_actions>
        <.unsaved_badge :if={@dirty?} id="agency-unsaved" />
      </:header_actions>
      <:lede>
        <span id="agency-drawer-scope">{scope_line(@version, @organization)}</span>
      </:lede>

      <div
        :if={@mode}
        id="agency-form-panel"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.unsaved_guard id="agency-unsaved-guard" dirty={@dirty?} />

        <%= if @delete_mode do %>
          <.agency_delete_panel
            delete={@delete_mode}
            form={@delete_form}
            review={@delete_review}
            agency={@agency}
            route_count={@delete_route_count}
            target_options={@delete_target_options}
          />
        <% else %>
          <.form
            for={@form}
            id="agency-form"
            novalidate
            phx-change="validate_agency"
            phx-submit="save_agency"
            class="flex min-h-0 flex-1 flex-col"
          >
            <.drawer_scroll>
              <.message
                :if={save_failed?(@form)}
                id="agency-form-error"
                kind="error"
                title={save_failed_title(@mode)}
                tabindex="-1"
              />

              <.conflict_message :if={@conflict?} reloaded?={@conflict_reloaded?} />

              <p class="text-sm text-muted">{agency_drawer_intro(@mode)}</p>

              <%!--
                The GTFS agency ID is derived from the name and preserved across
                imports and exports, so the edit form shows it as a fact and
                submits no field for it (R1).
              --%>
              <p
                :if={@mode == :edit and @agency}
                id="agency-identity"
                class="rounded-control bg-canvas px-4 py-3 text-[13px] text-muted"
              >
                Agency ID <strong class="text-strong">{@agency.agency_id}</strong>
                · Preserved in imports and exports
              </p>

              <.agency_form_fields
                form={@form}
                first_agency?={@first_agency?}
                zone={@zone}
                zone_names={@zone_names}
              />
            </.drawer_scroll>

            <.drawer_footer>
              <%!-- A disabled action still names why it is unavailable, and the
              reason sits with the control that cannot be used (AC-19). --%>
              <p
                :if={@last_agency? and @mode == :edit}
                id="agency-delete-reason"
                class="basis-full text-[13px] text-muted"
              >
                This is the last agency in the version and can't be deleted.
              </p>

              <.button
                :if={@mode == :edit}
                id="agency-delete"
                type="button"
                variant="quiet"
                class="mr-auto min-h-11 text-error-fg hover:bg-error-bg disabled:pointer-events-none disabled:text-muted disabled:opacity-60"
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
            </.drawer_footer>
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
    <%= cond do %>
      <% @delete == :delete_blocked -> %>
        <div id="agency-delete-blocked" class="flex min-h-0 flex-1 flex-col">
          <.drawer_scroll>
            <.message
              id="agency-delete-blocked-callout"
              kind="warning"
              title={"#{@agency.agency_name} cannot be deleted yet"}
            >
              <p>{blocked_body(@review.blockers)}</p>
            </.message>

            <ul id="agency-delete-blockers" class="divide-y divide-subtle border-y border-subtle">
              <li
                :for={fare_id <- @review.blockers.fare_ids}
                class="flex items-start justify-between gap-4 py-3"
              >
                <span class="text-muted">Fare attribute</span>
                <span class="break-all font-semibold text-strong">{fare_id}</span>
              </li>
              <li
                :for={attribution_id <- @review.blockers.attribution_ids}
                class="flex items-start justify-between gap-4 py-3"
              >
                <span class="text-muted">Attribution</span>
                <span class="break-all font-semibold text-strong">{attribution_id}</span>
              </li>
            </ul>

            <p class="text-sm text-muted">
              Route ownership will stay unchanged until every dependency can be moved safely.
            </p>
          </.drawer_scroll>

          <.drawer_footer>
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
          </.drawer_footer>
        </div>
      <% @delete == :delete_choose -> %>
        <div id="agency-delete-choose" class="flex min-h-0 flex-1 flex-col">
          <.form
            for={@form}
            id="agency-delete-form"
            novalidate
            phx-submit="review_delete"
            class="flex min-h-0 flex-1 flex-col"
          >
            <.drawer_scroll>
              <p class="text-sm text-muted">{delete_choose_intro(@route_count)}</p>

              <p
                id="agency-delete-identity"
                class="rounded-control bg-canvas px-4 py-3 text-[13px] text-muted"
              >
                Agency ID <strong class="text-strong">{@agency.agency_id}</strong>
                · {routes_label(@route_count)}
              </p>

              <.form_section :if={@route_count > 0} title="Move routes to" first?>
                <.input
                  field={@form[:target_id]}
                  type="select"
                  label="Receiving agency"
                  prompt="Choose agency"
                  options={@target_options}
                  help="Route IDs and schedules will stay unchanged."
                />
              </.form_section>

              <p class="text-sm text-muted">
                Review the exact changes before anything is deleted.
              </p>
            </.drawer_scroll>

            <.drawer_footer>
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
            </.drawer_footer>
          </.form>
        </div>
      <% true -> %>
        <div
          id={if @delete == :delete_stale, do: "agency-delete-stale", else: "agency-delete-review"}
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.message
              :if={@delete == :delete_stale}
              id="agency-delete-stale-notice"
              kind="error"
              title="The agencies or routes changed during your review"
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
            </.message>

            <.message
              id="agency-delete-summary"
              kind="warning"
              title={"#{@agency.agency_name} will be deleted"}
            >
              <p>{delete_review_summary(@review)}</p>
              <p :if={@review.translation_count > 0} id="agency-delete-translations">
                {translations_label(@review.translation_count)}
              </p>
            </.message>

            <ul
              :if={@review.routes != []}
              id="agency-delete-routes"
              class="divide-y divide-subtle border-y border-subtle"
            >
              <li :for={route <- @review.routes} class="flex items-start justify-between gap-4 py-3">
                <span class="min-w-0 text-strong">
                  <strong>{route.route_id}</strong> {route_name(route)}
                </span>
                <span class="whitespace-nowrap text-sm text-muted">Keep route ID</span>
              </li>
            </ul>

            <p id="agency-delete-total" class="rounded-control bg-canvas p-4 text-sm text-muted">
              The move and deletion must succeed together. If this review becomes out of date,
              nothing is changed.
            </p>
          </.drawer_scroll>

          <.drawer_footer>
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
          </.drawer_footer>
        </div>
    <% end %>
    """
  end

  # A conflicting save keeps the draft and the entries the editor typed and
  # names the two ways forward: reloading the base now, or, once reloaded,
  # saving again over it. It is the Feed details drawer's pattern over one
  # agency row (AC-16).
  attr :reloaded?, :boolean, required: true

  defp conflict_message(assigns) do
    ~H"""
    <.message
      id="agency-conflict"
      kind={if @reloaded?, do: "info", else: "error"}
      title={conflict_title(@reloaded?)}
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
    </.message>
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
    |> assign(:sole_agency, sole_agency(rows))
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

  defp subtitle(0),
    do: "Name the organization that runs your service. Trip planners show it next to every route."

  defp subtitle(_count),
    do: "The organizations that run your routes, as riders see them in trip planners."

  defp version_scope(version) do
    "Applies to #{present(version.name) || "this version"} only. Each version keeps its own agencies."
  end

  # One agency is a summary rather than a list; the row is the same one the table
  # would stream.
  defp sole_agency([row]), do: row
  defp sole_agency(_rows), do: nil

  # The one primary follows what the editor most likely does next. With one agency
  # that is editing it, with several it is adding another, and a timezone problem
  # outranks both because nothing else on the page is right until it is resolved.
  defp create_variant(health) do
    if health.agency_count > 1 and resolved_zone?(health.zone), do: "primary", else: "secondary"
  end

  defp edit_variant(health), do: if(resolved_zone?(health.zone), do: "primary", else: "secondary")

  defp zone_problem?(health), do: health.agency_count > 0 and unresolved_zone?(health.zone)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  # Links and fields take the design system's focus outline from the page scope;
  # a bare button does not, so the buttons this page draws itself carry it.
  defp focus_class do
    "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
  end

  defp link_class do
    "break-all font-medium text-action underline decoration-1 underline-offset-4 hover:text-action-hover"
  end

  defp needs_review, do: "Needs review"

  # Every row keeps its own agency ID in the query, except a version with one
  # agency: the list filtered to that agency is the unfiltered list (AC-9).
  defp routes_path(version_id, agency_count, row) do
    if agency_count == 1,
      do: ~p"/gtfs/#{version_id}/routes",
      else: ~p"/gtfs/#{version_id}/routes?#{[agency_id: row.agency.agency_id]}"
  end

  defp unresolved_zone?({:unresolved, _reason}), do: true
  defp unresolved_zone?({:ok, _zone}), do: false

  defp callout_title({:unresolved, :conflicting}), do: "Agencies use different timezones"
  defp callout_title({:unresolved, :invalid}), do: "The agency timezone isn’t recognized"
  defp callout_title({:unresolved, :missing}), do: "The agency timezone is missing"

  # What the Schedule timezone panel says beside "Needs review". The zone itself
  # is not part of the verdict, so the sentence names the problem, and the rows
  # in the table carry each agency's own zone.
  defp unresolved_detail(:conflicting), do: "Agencies use different timezones."
  defp unresolved_detail(:invalid), do: "The saved timezone isn’t one trip planners recognize."
  defp unresolved_detail(:missing), do: "No timezone is saved for this version."

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

  defp agency_count_label(1), do: "1 agency"
  defp agency_count_label(count), do: "#{count} agencies"

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
  defp feed_details_path(version_id), do: "/gtfs/#{version_id}/settings/feed-details"
  defp import_path(version_id), do: "/gtfs/#{version_id}/import"

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"
end
