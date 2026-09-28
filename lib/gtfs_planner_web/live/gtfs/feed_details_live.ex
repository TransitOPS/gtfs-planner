defmodule GtfsPlannerWeb.Gtfs.FeedDetailsLive do
  @moduledoc """
  Reads and edits one version's feed information.

  Feed details describe the whole dataset a data consumer receives, so the page
  shows the publisher, the validity dates, the feed release and the technical
  contact in three sections, with "Not set" for every value the version does not
  carry yet (AC-1). A version with no `feed_info` row shows the first-use empty
  state instead, and mounting it writes nothing: the row appears only when the
  editor saves one (AC-2).

  Reading and writing both go through `GtfsPlanner.Gtfs.FeedSettings`, which is
  scoped to the organization and version and re-authorizes the actor inside the
  write transaction (CR-1). This LiveView never calls the unscoped
  `Gtfs.get_feed_info/1` and makes no `Repo` call of its own.

  The Edit and Set drawer holds the same nine fields in the prototype's three
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
  version switching keeps the section: only a published version of the current
  organization navigates, and the target is always `/settings/feed-details` of
  the selected version.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FeedSettingsComponents, only: [language_select: 1, unsaved_guard: 1]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.LanguageCodes
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @summary_subtitle "Publisher information for this version—not the contact details riders use."
  @empty_subtitle "Tell journey planners who publishes this dataset and when its information is valid."
  # The form ids the save handler hands to the `FormErrorFocus` hook; the drawer
  # markup spells the same ids, so the hook and the failure path agree.
  @form_id "feed-details-form"
  @form_error_id "feed-details-form-error"
  @not_set "Not set"

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
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply,
       socket
       |> push_event("gtfs_version_selected", %{version_id: version_id})
       |> push_navigate(to: feed_details_path(version_id))}
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
      {:noreply, push_navigate(socket, to: feed_details_path(version_id))}
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
    case FeedSettings.save_feed_info(audit_context(socket), params, socket.assigns.loaded_token) do
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
         |> push_navigate(to: settings_path(socket.assigns.current_gtfs_version.id))}
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
      <:sub_header>
        <.settings_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:feed_details} />
      </:sub_header>

      <.header>
        Feed details
        <:subtitle>{subtitle(@feed_info)}</:subtitle>
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

      <.feed_summary
        :if={@feed_info}
        feed_info={@feed_info}
        gtfs_version_id={@current_gtfs_version.id}
      />

      <.empty_state
        :if={is_nil(@feed_info)}
        id="feed-details-empty"
        title="Introduce your feed"
        class="mt-6"
      >
        Add the publisher, website, and language. Dates and technical contacts help others use your
        data with confidence.
        <:action>
          <.button
            id="feed-details-set"
            class="min-h-11"
            phx-click="open_editor"
            phx-value-opener_id="feed-details-set"
          >
            Set feed details
          </.button>
        </:action>
      </.empty_state>

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
        open={true}
        title="Discard unsaved changes?"
        confirm_label="Discard changes"
        pending_label="Discarding…"
        cancel_label="Keep editing"
        on_confirm="discard_changes"
        on_cancel="cancel_discard"
        confirm_variant="danger"
        described_by="feed-details-discard-body"
      >
        <p>Your edits will be lost. The saved details stay unchanged.</p>
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  # The drawer holds the prototype's three sections in its order: Publisher, then
  # Validity and version, then Technical contact. Fieldsets with visible legends
  # give the sections their names for keyboard and pointer users alike (CR-8).
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
      open={@open}
      on_close="close_editor"
      title={drawer_title(@feed_info)}
      return_focus_id={@return_focus_id}
    >
      <%!--
        The prototype's dirty line sits in the drawer header, and the shared
        header slot is where the repository already places this exact state
        (`#pathway-dirty-indicator`). The badge names the state in words, so the
        warning is readable without its colour.
      --%>
      <:header_actions>
        <span
          :if={@dirty?}
          id="feed-details-unsaved"
          class="badge badge-warning badge-sm whitespace-nowrap"
        >
          Unsaved changes
        </span>
      </:header_actions>

      <div id="feed-details-form-panel" phx-hook="FormErrorFocus">
        <.unsaved_guard id="feed-details-unsaved-guard" dirty={@dirty?} />

        <p id="feed-details-drawer-scope" class="text-xs text-base-content/70">
          {scope_line(@version, @organization)}
        </p>

        <p class="mt-2 text-sm text-base-content/70">
          Describe the publisher and validity of this entire dataset. Optional fields are marked.
        </p>

        <.form
          for={@form}
          id="feed-details-form"
          novalidate
          phx-change="validate"
          phx-submit="save"
          class="mt-4"
        >
          <.callout
            :if={save_failed?(@form)}
            id="feed-details-form-error"
            kind="error"
            title="Nothing was saved. Check the highlighted fields."
            tabindex="-1"
            class="mb-4"
          />

          <.conflict_callout :if={@conflict?} reloaded?={@conflict_reloaded?} />

          <fieldset class="mt-6 border-t border-base-300 pt-5 first:mt-0 first:border-t-0 first:pt-0">
            <legend class="pr-4 text-base font-semibold text-base-content">Publisher</legend>

            <div class="mt-4">
              <.input field={@form[:feed_publisher_name]} type="text" label="Publisher name" />
              <.input field={@form[:feed_publisher_url]} type="url" label="Publisher website" />

              <.language_select
                field={@form[:feed_lang]}
                label="Feed language"
                include_mul
                help="Choose Multilingual when the original dataset uses more than one language."
              />

              <.callout
                :if={@form[:feed_lang].value == "mul"}
                id="feed-details-mul-note"
                kind="info"
                title="Include translations with this feed"
                class="mb-4"
              >
                Use the translations file for each language in the original data. Selecting
                Multilingual does not create translations.
              </.callout>

              <.language_select
                field={@form[:default_lang]}
                label="Default language"
                optional
                help="Used when the rider’s language is unknown."
              />
            </div>
          </fieldset>

          <fieldset class="mt-6 border-t border-base-300 pt-5">
            <legend class="pr-4 text-base font-semibold text-base-content">
              Validity and version
            </legend>

            <div class="mt-4">
              <.input field={@form[:feed_start_date]} type="date" label="Valid from (optional)" />

              <.input
                field={@form[:feed_end_date]}
                type="date"
                label="Valid through (optional)"
                help="The last day covered by the published schedule information."
              />

              <.input
                field={@form[:feed_version]}
                type="text"
                label="Feed version (optional)"
                help="A label data consumers can use to recognize this release."
              />

              <div class="flex justify-end">
                <.button
                  id="feed-details-use-date-label"
                  type="button"
                  variant="quiet"
                  class="min-h-11"
                  phx-click="use_date_label"
                >
                  Use date label
                </.button>
              </div>

              <p class="text-sm text-base-content/70">
                Suggested label: {@date_label}. You can use your own naming scheme.
              </p>
            </div>
          </fieldset>

          <fieldset class="mt-6 border-t border-base-300 pt-5">
            <legend class="pr-4 text-base font-semibold text-base-content">
              Technical contact
            </legend>

            <div class="mt-4">
              <.input
                field={@form[:feed_contact_email]}
                type="email"
                label="Contact email (optional)"
                help="For questions about the data, not rider support."
              />

              <.input
                field={@form[:feed_contact_url]}
                type="url"
                label="Contact website (optional)"
              />
            </div>
          </fieldset>

          <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
            <.button
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_editor"
            >
              Cancel
            </.button>

            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">
              {submit_label(@feed_info)}
            </.button>
          </div>
        </.form>
      </div>
    </.drawer>
    """
  end

  # A conflicting save keeps the draft visible and names the two ways forward:
  # reloading the base now, or, once reloaded, saving again over it (AC-7).
  attr :reloaded?, :boolean, required: true

  defp conflict_callout(assigns) do
    ~H"""
    <.callout
      id="feed-details-conflict"
      kind={if @reloaded?, do: "info", else: "error"}
      title={conflict_title(@reloaded?)}
      class="mb-4"
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
    </.callout>
    """
  end

  # The three summary sections follow the prototype's order, and the aside stacks
  # below them until the summary has room for a 250px column beside it.
  attr :feed_info, :any, required: true
  attr :gtfs_version_id, :any, required: true

  defp feed_summary(assigns) do
    ~H"""
    <div id="feed-details-summary" class="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1fr)_250px]">
      <div class="rounded-box border border-base-300">
        <section id="feed-details-publisher" class="border-b border-base-300 p-6">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-base font-semibold text-base-content">Publisher</h2>
            <.status_badge status={:active} label="Details set" />
          </div>

          <.summary_list>
            <:row label="Name">{value(@feed_info.feed_publisher_name)}</:row>
            <:row label="Website">{value(@feed_info.feed_publisher_url)}</:row>
            <:row label="Feed language">{language(@feed_info.feed_lang)}</:row>
            <:row label="Default language">{language(@feed_info.default_lang)}</:row>
          </.summary_list>
        </section>

        <section id="feed-details-validity" class="border-b border-base-300 p-6">
          <h2 class="text-base font-semibold text-base-content">Validity and version</h2>

          <.summary_list>
            <:row label="Valid from">{date(@feed_info.feed_start_date)}</:row>
            <:row label="Valid through">{date(@feed_info.feed_end_date)}</:row>
            <:row label="Feed version">{value(@feed_info.feed_version)}</:row>
          </.summary_list>
        </section>

        <section id="feed-details-contact" class="p-6">
          <h2 class="text-base font-semibold text-base-content">Technical contact</h2>

          <.summary_list>
            <:row label="Email">{value(@feed_info.feed_contact_email)}</:row>
            <:row label="Website">{value(@feed_info.feed_contact_url)}</:row>
          </.summary_list>
        </section>
      </div>

      <aside class="text-sm text-base-content/70">
        <h2 class="text-base font-semibold text-base-content">One feed, one publisher</h2>
        <p class="mt-3">
          A regional partnership can publish a dataset containing several agencies. These details describe the whole dataset.
        </p>

        <h2 class="mt-6 text-base font-semibold text-base-content">For data consumers</h2>
        <p class="mt-3">
          Technical contacts receive questions about data quality. Rider contacts belong to each agency.
        </p>

        <.link
          id="feed-details-manage-agencies"
          navigate={agencies_path(@gtfs_version_id)}
          class="mt-6 inline-flex min-h-11 items-center font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
        >
          Manage agencies <span aria-hidden="true" class="ml-2">→</span>
        </.link>

        <p class="mt-6 border-t border-base-300 pt-6">
          These details are included when this version is exported. Saving does not publish the feed.
        </p>
      </aside>
    </div>
    """
  end

  attr :rest, :global

  slot :row, required: true do
    attr :label, :string, required: true
  end

  defp summary_list(assigns) do
    ~H"""
    <dl
      class="mt-4 grid grid-cols-1 gap-y-1 text-sm sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-x-6 sm:gap-y-4"
      {@rest}
    >
      <%= for row <- @row do %>
        <dt class="text-base-content/70">{row.label}</dt>
        <dd class="mb-3 break-words sm:mb-0">{render_slot(row)}</dd>
      <% end %>
    </dl>
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

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # The suggested label is the version's current date resolved the way the rest
  # of the app resolves it, and it is never written without the editor asking
  # (AC-5, R12).
  defp date_label(socket) do
    socket.assigns.current_organization.id
    |> DisplayClock.today(socket.assigns.current_gtfs_version.id)
    |> Map.fetch!(:date)
    |> Date.to_iso8601()
  end

  # A failed save is the only state that earns the view-level banner. Validation
  # on change marks its own fields and must not shout about a save never attempted.
  defp save_failed?(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action, errors: errors}})
       when action in [:update, :insert] and errors != [],
       do: true

  defp save_failed?(_form), do: false

  defp drawer_title(nil), do: "Set feed details"
  defp drawer_title(_feed_info), do: "Edit feed details"

  defp submit_label(nil), do: "Save feed details"
  defp submit_label(_feed_info), do: "Save changes"

  defp conflict_title(false), do: "Another editor changed these details"
  defp conflict_title(true), do: "Latest details loaded"
  defp conflict_body(false), do: "Nothing was saved. Your entries are kept."
  defp conflict_body(true), do: "Save again to replace their changes."

  defp scope_line(version, organization) do
    [version.name, organization.name]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join(" · ")
  end

  defp subtitle(nil), do: @empty_subtitle
  defp subtitle(_feed_info), do: @summary_subtitle

  defp value(nil), do: @not_set

  defp value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @not_set
      trimmed -> trimmed
    end
  end

  defp language(code) do
    case LanguageCodes.label(code) do
      nil -> @not_set
      label -> label
    end
  end

  defp date(nil), do: @not_set
  defp date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp feed_details_path(version_id), do: "/gtfs/#{version_id}/settings/feed-details"
  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"
  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"
end
