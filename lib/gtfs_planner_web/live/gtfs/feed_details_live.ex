defmodule GtfsPlannerWeb.Gtfs.FeedDetailsLive do
  @moduledoc """
  Reads and edits one version's feed information.

  Feed details describe the whole dataset a data consumer receives, so the page
  shows the publisher, the dates and version, and the data contact in three
  cards, each row saying why apps read the value and reading "Not set" when the
  version does not carry it yet (AC-1). A version with no `feed_info` row shows
  the first-use empty state instead, and mounting it writes nothing: the row
  appears only when the editor saves one (AC-2). Both states keep the notes on
  where riders find agency contact details and that saving does not publish.

  Reading and writing both go through `GtfsPlanner.Gtfs.FeedSettings`, which is
  scoped to the organization and version and re-authorizes the actor inside the
  write transaction (CR-1). This LiveView never calls the unscoped
  `Gtfs.get_feed_info/1` and makes no `Repo` call of its own.

  The Edit and Set drawer holds the same nine fields in the page's three
  sections, validates them on change, and saves through
  `FeedSettings.save_feed_info/3` (AC-3, AC-4). The `updated_at` the drawer opened
  with is kept in socket assigns and sent back as the save token, so a concurrent
  change reports a conflict instead of overwriting it, and the draft stays in the
  form (AC-7, CR-9). "Use date label" is an explicit action that reads
  `GtfsPlanner.Gtfs.DisplayClock.today/2`, never an automatic fill (AC-5).

  A draft is protected on both sides of the boundary. Every close route the
  drawer offers — Cancel, the close button, Escape and the backdrop — asks
  "Discard unsaved changes?" while the form differs from the stored row, and the
  hidden `unsaved_guard/1` hook raises the browser's leave-page prompt on reload
  (AC-6). The same `FeedSettings.change_feed_info/2` changeset decides what
  "differs" means, so a whitespace-only edit, a value re-typed unchanged or an
  untouched imported value is not a draft.

  Access follows the other Settings pages through the `:gtfs_routes` session, and
  the page reaches the rest of Settings through the "Settings" back link instead
  of the tab bar. Version switching keeps the section: only a published version
  of the current organization navigates, and the target is always
  `/settings/feed-details` of the selected version.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FeedSettingsComponents, only: [language_select: 1, unsaved_guard: 1]

  import GtfsPlannerWeb.PlannerComponents,
    only: [
      aside_link: 1,
      back_link: 1,
      drawer_footer: 1,
      first_use: 1,
      form_section: 1,
      message: 1,
      safe_href: 2,
      scope_line: 1,
      unsaved_badge: 1
    ]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.LanguageCodes
  alias GtfsPlanner.Values
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.GtfsVersionNavigation
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The form ids the save handler hands to the `FormErrorFocus` hook; the drawer
  # markup spells the same ids, so the hook and the failure path agree.
  @form_id "feed-details-form"
  @form_error_id "feed-details-form-error"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Feed details")
     |> assign(:feed_info, nil)
     |> assign(:loaded_token, nil)
     |> assign(:form, feed_details_form(nil, %{}))
     |> assign(:drawer_open?, false)
     |> assign(:dirty?, false)
     |> assign(:confirm_close?, false)
     |> assign(:conflict?, false)
     |> assign(:conflict_reloaded?, false)
     |> assign(:return_focus_id, nil)
     |> assign(:date_label, date_label(socket))}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    feed_info = load_feed_info(socket)

    {:noreply,
     socket
     |> assign(:feed_info, feed_info)
     |> assign(:loaded_token, token(feed_info))}
  end

  # A selection of this page's own version is nothing to do: the switcher hook
  # returns before it sends the event for the version it already shows, and
  # `gtfs_version_loaded/2` below ignores the same case, so both events agree that
  # only another published version of this organization navigates.
  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if version_id != to_string(socket.assigns.current_gtfs_version.id) &&
         GtfsVersionNavigation.published_for_current_organization?(socket, version_id) do
      {:noreply,
       socket
       |> push_event("gtfs_version_selected", %{version_id: version_id})
       |> push_navigate(to: ~p"/gtfs/#{version_id}/settings/feed-details")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         GtfsVersionNavigation.published_for_current_organization?(socket, version_id) do
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/settings/feed-details")}
    else
      {:noreply, socket}
    end
  end

  # Opening the drawer re-reads the row so the form and its save token describe
  # the stored state as of the moment the editor starts (AC-7, CR-9). The opener
  # id comes from the clicked control and survives the close, so the
  # `OverlayDialog` hook can return focus.
  @impl true
  def handle_event("open_editor", params, socket) do
    feed_info = load_feed_info(socket)

    {:noreply,
     socket
     |> assign(:feed_info, feed_info)
     |> assign(:loaded_token, token(feed_info))
     |> assign(:form, feed_details_form(feed_info, %{}))
     |> assign(:dirty?, false)
     |> assign(:confirm_close?, false)
     |> assign(:conflict?, false)
     |> assign(:conflict_reloaded?, false)
     |> assign(:return_focus_id, params["opener_id"])
     |> assign(:date_label, date_label(socket))
     |> assign(:drawer_open?, true)}
  end

  # Every route out of the drawer — Cancel, the close button and, through the
  # `OverlayDialog` hook's dismiss control, Escape and the backdrop — lands on
  # this event, so a changed draft is asked about exactly once (AC-6).
  @impl true
  def handle_event("close_editor", _params, socket) do
    {:noreply, request_close(socket)}
  end

  @impl true
  def handle_event("cancel_discard", _params, socket) do
    {:noreply, assign(socket, :confirm_close?, false)}
  end

  # Discarding drops the draft and closes: the row is untouched, so reopening
  # shows the stored values again.
  @impl true
  def handle_event("discard_changes", _params, socket) do
    {:noreply, close_editor(socket)}
  end

  @impl true
  def handle_event("validate", %{"feed_info" => params}, socket) do
    changeset = FeedSettings.change_feed_info(socket.assigns.feed_info, params)

    {:noreply, assign_draft(socket, changeset, :validate)}
  end

  # The suggestion the button applies is the label the drawer prints, so the two
  # cannot disagree across a long-lived session; the draft the editor has already
  # typed replaces only the field the button owns (R12).
  @impl true
  def handle_event("use_date_label", _params, socket) do
    params = Map.put(draft_params(socket), "feed_version", socket.assigns.date_label)
    changeset = FeedSettings.change_feed_info(socket.assigns.feed_info, params)

    {:noreply, assign_draft(socket, changeset, :validate)}
  end

  @impl true
  def handle_event("save", %{"feed_info" => params}, socket) do
    case FeedSettings.save_feed_info(
           AuditContext.from_assigns(socket.assigns),
           params,
           socket.assigns.loaded_token
         ) do
      {:ok, feed_info} ->
        {:noreply,
         socket
         |> assign(:feed_info, feed_info)
         |> assign(:loaded_token, token(feed_info))
         |> close_editor()
         |> put_flash(:info, "Feed details saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_draft(changeset)
         |> push_event("focus_form_error", %{
           form_id: @form_id,
           fallback_id: @form_error_id
         })}

      {:error, :stale} ->
        # The base moved while the drawer was open: keep the draft, keep the
        # values the editor typed, and write nothing (AC-7).
        changeset = FeedSettings.change_feed_info(socket.assigns.feed_info, params)

        {:noreply,
         socket
         |> assign_draft(changeset)
         |> assign(:conflict?, true)
         |> assign(:conflict_reloaded?, false)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> close_editor()
         |> put_flash(:error, "You no longer have editor access to this organization.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> close_editor()
         |> put_flash(:error, "This version is no longer available.")
         |> push_navigate(to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/settings")}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # Reloading the base keeps the draft the editor typed and the token the next
  # save compares against, so the following save replaces what the other editor
  # stored instead of reporting the same conflict again (AC-7).
  @impl true
  def handle_event("load_latest", _params, socket) do
    feed_info = load_feed_info(socket)
    changeset = FeedSettings.change_feed_info(feed_info, draft_params(socket))

    {:noreply,
     socket
     |> assign(:feed_info, feed_info)
     |> assign(:loaded_token, token(feed_info))
     |> assign_draft(changeset)
     |> assign(:conflict?, true)
     |> assign(:conflict_reloaded?, true)}
  end

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
      <div id="feed-details-page" class="ds-page">
        <.back_link id="settings-back" navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings"}>
          Settings
        </.back_link>

        <.header>
          Feed details
          <:subtitle>
            Tell trip planners who publishes this schedule, how long it’s valid and who to contact
            about the data.
            <.scope_line id="feed-details-scope" icon="hero-calendar">
              {version_scope(@current_gtfs_version)}
            </.scope_line>
          </:subtitle>
          <:actions :if={@feed_info}>
            <.button
              id="feed-details-edit"
              class="min-h-11"
              phx-click="open_editor"
              phx-value-opener_id="feed-details-edit"
            >
              Edit feed details
            </.button>
          </:actions>
        </.header>

        <div class="mt-2 grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem] lg:items-start">
          <div class="min-w-0">
            <.feed_summary :if={@feed_info} feed_info={@feed_info} />

            <.first_use
              :if={is_nil(@feed_info)}
              id="feed-details-empty"
              title="No feed details yet"
              icon="hero-document-text"
            >
              Feed details tell trip planners who publishes this schedule, when it ends and who to
              contact if something looks wrong. You can export without them, but data checkers flag
              the missing file.
              <:action>
                <.button
                  id="feed-details-set"
                  class="min-h-11"
                  phx-click="open_editor"
                  phx-value-opener_id="feed-details-set"
                >
                  Set up feed details
                </.button>
              </:action>
            </.first_use>
          </div>

          <.related_information gtfs_version_id={@current_gtfs_version.id} />
        </div>

        <.feed_details_drawer
          open={@drawer_open?}
          feed_info={@feed_info}
          form={@form}
          dirty?={@dirty?}
          conflict?={@conflict?}
          conflict_reloaded?={@conflict_reloaded?}
          return_focus_id={@return_focus_id}
          date_label={@date_label}
          version={@current_gtfs_version}
          organization={@current_organization}
        />

        <%!--
          The discard question is the only exit from a changed draft, so the drawer
          stays open and visible behind it. Escape belongs to the dialog while it
          is up: the `OverlayDialog` hook turns it into a click on "Keep editing".
          `described_by` names `.confirm_dialog`'s own `#feed-details-discard-body`
          wrapper, so the paragraph inside it carries no id of its own.
        --%>
        <.confirm_dialog
          :if={@confirm_close?}
          id="feed-details-discard"
          chrome="planner"
          open={true}
          title="Discard unsaved changes?"
          confirm_label="Discard changes"
          pending_label="Discarding…"
          cancel_label="Keep editing"
          on_confirm="discard_changes"
          on_cancel="cancel_discard"
          described_by="feed-details-discard-body"
        >
          <p>Your edits will be lost. The saved details stay unchanged.</p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  # The drawer holds the three sections in the page's order: Publisher, Dates and
  # version, then Data contact. Fieldsets with visible legends give the sections
  # their names for keyboard and pointer users alike (CR-8).
  attr :open, :boolean, required: true
  attr :feed_info, :any, required: true
  attr :form, :any, required: true
  attr :dirty?, :boolean, required: true
  attr :conflict?, :boolean, required: true
  attr :conflict_reloaded?, :boolean, required: true
  attr :return_focus_id, :string, default: nil
  attr :date_label, :string, required: true
  attr :version, :any, required: true
  attr :organization, :any, required: true

  defp feed_details_drawer(assigns) do
    ~H"""
    <.drawer
      id="feed-details-drawer"
      chrome="planner"
      open={@open}
      on_close="close_editor"
      title={drawer_title(@feed_info)}
      return_focus_id={@return_focus_id}
      initial_focus={:first_field}
      class="max-w-[560px]"
    >
      <%!--
        The shared header slot is where the repository places the unsaved state
        (`#pathway-dirty-indicator`). The badge names the state in words, so the
        warning is readable without its colour.
      --%>
      <:header_actions>
        <.unsaved_badge :if={@dirty?} id="feed-details-unsaved" />
      </:header_actions>
      <:lede>
        <span id="feed-details-drawer-scope">{scope_line(@version, @organization)}</span>
      </:lede>

      <div id="feed-details-form-panel" phx-hook="FormErrorFocus" class="flex min-h-0 flex-1 flex-col">
        <.unsaved_guard id="feed-details-unsaved-guard" dirty={@dirty?} />

        <.form
          for={@form}
          id="feed-details-form"
          novalidate
          phx-change="validate"
          phx-submit="save"
          class="flex min-h-0 flex-1 flex-col"
        >
          <div class="grid flex-1 content-start gap-5 overflow-y-auto px-5 py-5 sm:px-6">
            <.message
              :if={save_failed?(@form)}
              id="feed-details-form-error"
              tabindex="-1"
              kind="error"
              title="Nothing was saved. Check the highlighted fields."
            />

            <.conflict_message :if={@conflict?} reloaded?={@conflict_reloaded?} />

            <p class="text-sm text-muted">
              These details describe your whole schedule dataset, not one agency. Fields marked
              optional can stay blank.
            </p>

            <.form_section title="Publisher" first?>
              <.input
                field={@form[:feed_publisher_name]}
                errors={field_errors(@form, :feed_publisher_name)}
                type="text"
                label="Publisher name"
                help="The organization that publishes this feed. It can differ from your agencies."
              />
              <.input
                field={@form[:feed_publisher_url]}
                errors={field_errors(@form, :feed_publisher_url)}
                type="url"
                label="Publisher website"
                help="Your organization’s home page, starting with https://."
              />

              <.language_select
                field={@form[:feed_lang]}
                errors={field_errors(@form, :feed_lang)}
                label="Feed language"
                include_mul
                help="The main language of route and stop names. Choose Multilingual only if names appear in several languages."
              />

              <.message
                :if={@form[:feed_lang].value == "mul"}
                id="feed-details-mul-note"
                kind="info"
                title="Include translations with this feed"
              >
                Use the translations file for each language in the original data. Selecting
                Multilingual does not create translations.
              </.message>

              <.language_select
                field={@form[:default_lang]}
                errors={field_errors(@form, :default_lang)}
                label="Default language"
                optional
                help="Used when an app doesn’t know the rider’s language."
              />
            </.form_section>

            <.form_section title="Dates and version">
              <div class="grid gap-5 sm:grid-cols-2">
                <.input
                  field={@form[:feed_start_date]}
                  errors={field_errors(@form, :feed_start_date)}
                  type="date"
                  label="Valid from (optional)"
                  help="First day apps treat this schedule as reliable."
                />
                <.input
                  field={@form[:feed_end_date]}
                  errors={field_errors(@form, :feed_end_date)}
                  type="date"
                  label="Valid through (optional)"
                  help="Use your last scheduled service day. Later days with no service read as “no service” in apps."
                />
              </div>

              <div class="grid content-start gap-2">
                <.input
                  field={@form[:feed_version]}
                  errors={field_errors(@form, :feed_version)}
                  type="text"
                  label="Feed version (optional)"
                  help={"Any label works, such as #{@date_label} or Fall 2026. Change it whenever you release new data."}
                />

                <.button
                  id="feed-details-use-date-label"
                  type="button"
                  variant="secondary"
                  class="min-h-11 justify-self-start"
                  phx-click="use_date_label"
                >
                  Use today’s date
                </.button>
              </div>
            </.form_section>

            <.form_section title="Data contact">
              <.input
                field={@form[:feed_contact_email]}
                errors={field_errors(@form, :feed_contact_email)}
                type="email"
                label="Contact email (optional)"
                help="For questions about the data, not rider support."
              />
              <.input
                field={@form[:feed_contact_url]}
                errors={field_errors(@form, :feed_contact_url)}
                type="url"
                label="Contact website (optional)"
                help="A support page or web form for data questions."
              />
            </.form_section>
          </div>

          <.drawer_footer>
            <.button type="button" variant="secondary" class="min-h-11" phx-click="close_editor">
              Cancel
            </.button>
            <.button type="submit" class="min-h-11 min-w-[148px]" phx-disable-with="Saving…">
              {submit_label(@feed_info)}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  # A conflicting save keeps the draft visible and names the two ways forward:
  # reloading the base now, or, once reloaded, saving again over it (AC-7).
  attr :reloaded?, :boolean, required: true

  defp conflict_message(assigns) do
    ~H"""
    <.message
      id="feed-details-conflict"
      kind={if @reloaded?, do: "info", else: "error"}
      title={conflict_title(@reloaded?)}
    >
      <p>{conflict_body(@reloaded?)}</p>

      <.button
        :if={!@reloaded?}
        id="feed-details-load-latest"
        type="button"
        variant="secondary"
        class="mt-3 min-h-11"
        phx-click="load_latest"
      >
        Load latest
      </.button>
    </.message>
    """
  end

  # The three summary cards, each a titled list of one row per field. A row says
  # what the field is and why it matters to the apps that read it; an unset value
  # reads "Not set".
  attr :feed_info, :any, required: true

  defp feed_summary(assigns) do
    ~H"""
    <div id="feed-details-summary" class="grid gap-6">
      <.summary_card
        id="feed-details-publisher"
        title="Publisher"
        description="Who trip planners credit for the whole dataset, even when it covers several agencies."
      >
        <:row
          label="Publisher name"
          hint="Apps may credit this name as your data’s source."
          value={Values.presence(@feed_info.feed_publisher_name)}
        />
        <:row
          label="Publisher website"
          hint="Where data users go to learn about the publisher."
          value={Values.presence(@feed_info.feed_publisher_url)}
          kind={:web}
        />
        <:row
          label="Feed language"
          hint="Sets how apps capitalize and format names."
          value={language(@feed_info.feed_lang)}
        />
        <:row
          label="Default language"
          hint="Used when an app doesn’t know the rider’s language."
          value={language(@feed_info.default_lang)}
        />
      </.summary_card>

      <.summary_card
        id="feed-details-validity"
        title="Dates and version"
        description="How long apps can rely on this data, and which release it is."
      >
        <:row
          label="Valid from"
          hint="First day apps treat this schedule as reliable."
          value={@feed_info.feed_start_date && Wording.date(@feed_info.feed_start_date)}
          kind={:date}
        />
        <:row
          label="Valid through"
          hint="Apps stop relying on this schedule after this day."
          value={@feed_info.feed_end_date && Wording.date(@feed_info.feed_end_date)}
          kind={:date}
        />
        <:row
          label="Feed version"
          hint="Apps compare this label to spot new releases."
          value={Values.presence(@feed_info.feed_version)}
        />
      </.summary_card>

      <.summary_card
        id="feed-details-contact"
        title="Data contact"
        description="Who trip-planner teams reach about data problems. Riders use each agency’s contact details instead."
      >
        <:row
          label="Contact email"
          hint="Where trip-planner teams send data questions."
          value={Values.presence(@feed_info.feed_contact_email)}
          kind={:email}
        />
        <:row
          label="Contact website"
          hint="A support page or web form for data questions."
          value={Values.presence(@feed_info.feed_contact_url)}
          kind={:web}
        />
      </.summary_card>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  slot :row, required: true do
    attr :label, :string, required: true
    attr :hint, :string, required: true
    attr :value, :string
    attr :kind, :atom
  end

  defp summary_card(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-title"}
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4">
        <h2 id={"#{@id}-title"} class="text-lg font-bold leading-snug tracking-[-0.01em] text-strong">
          {@title}
        </h2>
        <p class="mt-0.5 text-[13px] text-muted">{@description}</p>
      </div>

      <dl class="divide-y divide-navy-100">
        <div
          :for={row <- @row}
          class="grid gap-x-8 gap-y-1 px-5 py-3.5 sm:grid-cols-[minmax(0,15rem)_minmax(0,1fr)] sm:items-start xl:grid-cols-[minmax(0,22rem)_minmax(0,1fr)]"
        >
          <dt>
            <span data-role="field-label" class="block text-sm font-semibold text-strong">
              {row.label}
            </span>
            <span class="mt-0.5 block text-[13px] leading-snug text-muted">{row.hint}</span>
          </dt>
          <dd data-role="field-value" class="min-w-0 text-[15px] text-strong">
            <.summary_value value={row[:value]} kind={row[:kind] || :text} />
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  # A web address or email opens as a link only when it is one the browser can
  # follow safely: an imported value is arbitrary text, so anything else stays
  # plain rather than becoming an `href`.
  attr :value, :string, default: nil
  attr :kind, :atom, values: [:text, :date, :web, :email], default: :text

  defp summary_value(assigns) do
    assigns = assign(assigns, :href, safe_href(assigns.kind, assigns.value))

    ~H"""
    <span :if={is_nil(@value)} class="text-muted">Not set</span>
    <a
      :if={@href}
      href={@href}
      target={@kind == :web && "_blank"}
      rel={@kind == :web && "noopener noreferrer"}
      class="break-all font-medium text-action underline decoration-1 underline-offset-4 hover:text-action-hover"
    >
      {@value}
    </a>
    <span :if={@value && is_nil(@href)} class={[@kind == :date && "tabular-nums", "break-words"]}>
      {@value}
    </span>
    """
  end

  # What editors ask most: where do riders reach us, and does saving change what
  # apps see? Both answers hold whether or not details exist yet.
  attr :gtfs_version_id, :any, required: true

  defp related_information(assigns) do
    ~H"""
    <aside
      id="feed-details-aside"
      class="grid gap-4 lg:sticky lg:top-6"
      aria-label="Related information"
    >
      <section class="rounded-card bg-canvas p-5">
        <h2 class="text-base font-bold leading-snug text-strong">Rider contact lives on agencies</h2>
        <p class="mt-2 text-sm text-default">
          Phone numbers and websites riders use are set for each agency. These details describe the
          dataset itself.
        </p>
        <.aside_link
          id="feed-details-manage-agencies"
          navigate={~p"/gtfs/#{@gtfs_version_id}/settings/agencies"}
        >
          Manage agencies
        </.aside_link>
      </section>

      <section class="rounded-card bg-canvas p-5">
        <h2 class="text-base font-bold leading-snug text-strong">Saving doesn’t publish</h2>
        <p class="mt-2 text-sm text-default">
          These details are included when this version is exported. Trip planners see them after
          you export the version and share the feed.
        </p>
        <.aside_link id="feed-details-go-to-export" navigate={~p"/gtfs/#{@gtfs_version_id}/export"}>
          Go to export
        </.aside_link>
      </section>
    </aside>
    """
  end

  defp close_editor(socket) do
    socket
    |> assign(:drawer_open?, false)
    |> assign(:dirty?, false)
    |> assign(:confirm_close?, false)
    |> assign(:conflict?, false)
    |> assign(:conflict_reloaded?, false)
  end

  # A changed draft is never discarded by accident: every close route lands
  # here, and only "Discard changes" reaches `close_editor/1`.
  defp request_close(%{assigns: %{dirty?: true}} = socket),
    do: assign(socket, :confirm_close?, true)

  defp request_close(socket), do: close_editor(socket)

  defp feed_details_form(feed_info, attrs) do
    feed_info
    |> FeedSettings.change_feed_info(attrs)
    |> to_form(as: :feed_info)
  end

  # The form, the action it reports and the dirty state always move together, so
  # one helper binds them: a handler cannot show a draft the guard would ignore,
  # or guard a form that shows nothing. `action: :validate` marks the round trip
  # as a keystroke, so `used_input?/1` shows an error beside the field the editor
  # has touched and the save-failure callout stays for saves only.
  defp assign_draft(socket, changeset, action \\ nil) do
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset

    socket
    |> assign(:form, to_form(changeset, as: :feed_info))
    |> assign(:dirty?, dirty?(changeset))
  end

  # `FeedSettings.change_feed_info/2` owns what "changed" means, so the dirty
  # state and the saved result cannot disagree: `cast/3` records nothing for a
  # value equal to the stored row, `trim_string_fields/1` drops a
  # whitespace-only edit, and Ecto's empty values turn a blank field into nil.
  # An imported value the editor rules reject is therefore not a draft until the
  # editor touches it, and the guard and the discard dialog always agree.
  defp dirty?(%Ecto.Changeset{} = changeset), do: changeset.changes != %{}

  defp draft_params(socket), do: socket.assigns.form.source.params || %{}

  defp load_feed_info(socket) do
    FeedSettings.get_feed_info(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id
    )
  end

  defp token(nil), do: nil
  defp token(%{updated_at: updated_at}), do: updated_at

  # The suggested label is the version's current date resolved the way the rest
  # of the app resolves it, and it is never written without the editor asking
  # (AC-5, R12).
  defp date_label(socket) do
    socket.assigns.current_organization.id
    |> DisplayClock.today(socket.assigns.current_gtfs_version.id)
    |> Map.fetch!(:date)
    |> Date.to_iso8601()
  end

  # One sentence per failed rule, saying what to enter instead of repeating the
  # changeset's wording. The URL, email, language and date-order rules carry no
  # metadata, so the field names them. A field shows its errors once the editor
  # has used it or a save was refused, as `<.input>` does on its own.
  defp field_errors(form, field) do
    input = form[field]

    if used_input?(input),
      do: Enum.map(input.errors, &error_message(form, field, &1)),
      else: []
  end

  defp error_message(form, field, {_message, opts} = error) do
    case {opts[:validation], opts[:kind]} do
      {:required, _kind} -> required_message(field, error)
      {:length, :max} -> "Use #{opts[:count]} characters or fewer."
      _other -> rule_message(form, field, error)
    end
  end

  defp required_message(:feed_publisher_name, _error), do: "Enter the publisher name."
  defp required_message(:feed_publisher_url, _error), do: "Enter the publisher website."
  defp required_message(:feed_lang, _error), do: "Choose the feed language."
  defp required_message(_field, error), do: translate_error(error)

  defp rule_message(_form, field, _error) when field in [:feed_publisher_url, :feed_contact_url],
    do: "Enter a full web address, starting with https:// or http://."

  defp rule_message(_form, :feed_contact_email, _error),
    do: "Enter an email address, such as data@agency.org."

  defp rule_message(_form, field, _error) when field in [:feed_lang, :default_lang],
    do: "Choose a language from the list."

  defp rule_message(form, :feed_end_date, {_message, []}) do
    case Ecto.Changeset.get_field(form.source, :feed_start_date) do
      nil -> "Choose a date on or after the valid-from date."
      start -> "Choose a date on or after #{Wording.date(start)}, the valid-from date."
    end
  end

  defp rule_message(_form, _field, error), do: translate_error(error)

  # A failed save is the only state that earns the view-level banner. Validation
  # on change marks its own fields and must not shout about a save never attempted.
  defp save_failed?(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action, errors: errors}})
       when action in [:update, :insert] and errors != [],
       do: true

  defp save_failed?(_form), do: false

  defp drawer_title(nil), do: "Set up feed details"
  defp drawer_title(_feed_info), do: "Edit feed details"

  defp submit_label(nil), do: "Save feed details"
  defp submit_label(_feed_info), do: "Save changes"

  defp conflict_title(false), do: "Another editor changed these details"
  defp conflict_title(true), do: "Latest details loaded"

  defp conflict_body(false),
    do: "Nothing was saved. Your entries are kept. Load the latest details, then save again."

  defp conflict_body(true), do: "Save again to replace their changes."

  defp scope_line(version, organization) do
    [version.name, organization.name]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join(" · ")
  end

  defp version_scope(version) do
    "Applies to #{Values.presence(version.name) || "this version"} only. Each version keeps its own feed details."
  end

  # The display helper returns nil for a value the version does not carry, so
  # `summary_value/1` is the one place that words it "Not set".
  defp language(code), do: LanguageCodes.label(code)
end
