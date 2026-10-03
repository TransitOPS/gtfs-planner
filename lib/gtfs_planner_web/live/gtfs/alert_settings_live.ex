defmodule GtfsPlannerWeb.Gtfs.AlertSettingsLive do
  @moduledoc """
  Settings › Alerts: the organization's message scripts and its writing
  guidelines.

  Both are organization data that everyone in the organization shares, so the
  version in the URL is navigation context and this page ignores it, exactly as
  the garages and fleet pages do. The two destinations are one LiveView with one
  action each and a `?tab=` query, so the tabs are links that patch between them
  and the selected tab survives a reload (AC-24).

  The scripts tab is a rendering of `Alerts.list_scripts/1`: this
  organization's own scripts in their `position` order, then the read-only
  built-ins. A built-in has no row to edit and no Edit button; **Copy to edit**
  is `Alerts.copy_built_in_script/2`, the only way a default becomes an
  organization's own script, which is what keeps one tenant's wording out of
  every other tenant's defaults (AC-11, R10, FH-24). The page is therefore
  never empty: an organization with no scripts of its own still reads the eight
  built-in ones.

  The drawer is the only writer. It seeds its form from the persisted row, and
  a refused save keeps what was typed: `AlertScript.changeset/2`'s errors are
  shown on the field that caused them (an unknown placeholder or a `<%` tag is
  refused there, not by this page) and the entered templates stay in the form.
  A script another editor deleted while the drawer was open leaves the typed
  wording in place and turns the drawer into Create script, so saving again
  re-creates it. Delete script asks first, because the wording cannot be
  recovered. Identity is never cast: the organization and the script's place in
  the list are owned by the `Alerts` command (R4, CR-2).

  The guidelines tab is one document in one textarea with a hidden base
  revision, saved through `Alerts.save_guidelines/3`. A save from a form
  rendered before another editor's save is refused and says so, because a
  silent overwrite is the one outcome R6 forbids; **Reload guidelines** is the
  way through.

  A membership that lapses between mount and a write gets `{:error, :forbidden}`
  from the command, which this page reports as a notice while keeping the drawer
  and the entered text. Nothing is written and no success is reported (R5,
  FH-24).

  This page carries no publication action: a script or a guideline never
  publishes an alert by itself. An alert is accepted for publication only from
  the alert editor's own review step (R2, CR-1).
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.AlertComponents, only: [situation_label: 1]

  import GtfsPlannerWeb.PlannerComponents,
    only: [back_link: 1, drawer_footer: 1, drawer_scroll: 1, message: 1, scope_line: 1]

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.AlertScript
  alias GtfsPlanner.Alerts.Message
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Versions

  # The two destinations this page has. An unknown `?tab=` value is not an error
  # a reader should see: it falls back to the scripts tab, which is the tab the
  # page opens on.
  @tabs [:scripts, :guidelines]

  @script_fields [:id, :name, :situation, :header_template, :description_template, :position]

  @tab_titles [
    scripts: "Message scripts",
    guidelines: "Writing guidelines"
  ]

  @stale_guidelines_message "Someone else changed these guidelines. Reload to see their version."
  @forbidden_message "You no longer have permission to change the organization's alert wording."
  @unknown_built_in_message "That built-in script is not one this app offers."
  @script_deleted_message "Someone deleted this script. Your changes are still here; create script to save them again."

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access_in_organization}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Alerts")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:settings_state, :loading)
     |> assign(:tab, :scripts)
     |> assign(:tab_titles, @tab_titles)
     |> assign(:script_count, 0)
     |> assign(:built_in_count, 0)
     |> stream(:scripts, [])
     |> assign(:script_notice, nil)
     |> assign(:script_drawer_open, false)
     |> assign(:script_entity, nil)
     |> assign(:script_delete_target, nil)
     |> assign(:script_drawer_title, "Create script")
     |> assign(:script_return_focus_id, nil)
     |> assign(:script_form, script_form(%AlertScript{}, %{}))
     |> assign(:guidelines, %{text: "", revision: 0})
     |> assign(:guidelines_notice, nil)
     |> assign(:guidelines_stale?, false)
     |> assign(:guidelines_form, guidelines_form("", 0))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :tab, tab(params))

    case socket.assigns[:current_organization] do
      # An editor with no organization in context - a system administrator who
      # has none selected - reaches the explicit unavailable state. This page is
      # the organization's wording, and there is nothing to read without one.
      nil ->
        {:noreply,
         socket
         |> assign(:settings_state, :organization_required)
         |> assign(:script_notice, nil)
         |> assign(:guidelines_notice, nil)
         |> stream(:scripts, [], reset: true)}

      _organization ->
        {:noreply,
         socket
         |> assign(:settings_state, :ready)
         |> refresh_scripts()
         |> load_guidelines()}
    end
  end

  # The guidelines are read on every arrival, including a tab that does not show
  # them, so the hidden revision the form carries is always the revision this
  # page last read rather than one left behind by a previous visit.
  defp load_guidelines(socket) do
    %{text: text, revision: revision} = Alerts.get_guidelines(audit_context(socket))

    store_guidelines(socket, text, revision)
  end

  # -- Scripts ---------------------------------------------------------------

  @impl true
  def handle_event("open_create_script", params, socket) do
    {:noreply,
     socket
     |> assign(:script_entity, nil)
     |> assign(:script_form, script_form(%AlertScript{}, %{}))
     |> assign(:script_drawer_title, "Create script")
     |> assign(:script_return_focus_id, opener_id(params))
     |> assign(:script_notice, nil)
     |> assign(:script_drawer_open, true)}
  end

  @impl true
  def handle_event("open_edit_script", %{"script_id" => script_id}, socket)
      when is_binary(script_id) do
    case find_script(socket, script_id) do
      nil ->
        {:noreply, socket}

      script ->
        {:noreply,
         socket
         |> assign(:script_entity, script)
         |> assign(:script_form, script_form(script, %{}))
         |> assign(:script_drawer_title, "Edit script")
         |> assign(:script_return_focus_id, "edit-script-#{script_id}")
         |> assign(:script_notice, nil)
         |> assign(:script_drawer_open, true)}
    end
  end

  def handle_event("open_edit_script", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_script_drawer", _params, socket) do
    {:noreply, close_script_drawer(socket)}
  end

  @impl true
  def handle_event("validate_script", %{"script" => params}, socket) do
    changeset =
      socket.assigns.script_entity
      |> script_base()
      |> AlertScript.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :script_form, to_form(changeset, as: :script))}
  end

  def handle_event("validate_script", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_script", %{"script" => params}, socket) do
    result =
      case socket.assigns.script_entity do
        nil -> Alerts.create_script(audit_context(socket), params)
        script -> Alerts.update_script(audit_context(socket), script.id, params)
      end

    case result do
      {:ok, script} ->
        {:noreply,
         socket
         |> close_script_drawer()
         |> refresh_scripts()
         |> assign(:script_notice, "#{script.name} saved.")}

      # The refused form keeps what was typed: the changeset carries the entered
      # templates and its own errors, so the drawer shows the field error beside
      # the text that caused it (AC-24, R10).
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :script_form, to_form(changeset, as: :script))}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:script_form, script_form(script_base(socket.assigns.script_entity), params))
         |> assign(:script_notice, @forbidden_message)}

      # The script is gone: another editor of this organization deleted it while
      # the drawer was open. The typed wording stays, and saving creates it anew.
      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:script_entity, nil)
         |> assign(:script_form, script_form(%AlertScript{}, params))
         |> assign(:script_drawer_title, "Create script")
         |> assign(:script_notice, @script_deleted_message)
         |> refresh_scripts()}

      # Any other refusal is not a save, so the drawer closes on the refreshed
      # list.
      {:error, _reason} ->
        {:noreply, socket |> close_script_drawer() |> refresh_scripts()}
    end
  end

  def handle_event("save_script", _params, socket), do: {:noreply, socket}

  # Deleting loses the wording for good, so the drawer asks first.
  @impl true
  def handle_event("delete_script", %{"script_id" => script_id}, socket)
      when is_binary(script_id) do
    case socket.assigns.script_entity do
      %AlertScript{id: ^script_id} = script ->
        {:noreply, assign(socket, :script_delete_target, script)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_script", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_delete_script", _params, socket) do
    {:noreply, assign(socket, :script_delete_target, nil)}
  end

  @impl true
  def handle_event("confirm_delete_script", _params, socket) do
    case socket.assigns.script_delete_target do
      nil -> {:noreply, socket}
      script -> {:noreply, delete_script(assign(socket, :script_delete_target, nil), script)}
    end
  end

  @impl true
  def handle_event("copy_built_in_script", %{"key" => key}, socket) when is_binary(key) do
    case Alerts.copy_built_in_script(audit_context(socket), key) do
      {:ok, script} ->
        {:noreply,
         socket
         |> assign(:script_entity, script)
         |> assign(:script_form, script_form(script, %{}))
         |> assign(:script_drawer_title, "Edit script")
         |> assign(:script_return_focus_id, "copy-builtin-#{key}")
         |> assign(:script_notice, nil)
         |> assign(:script_drawer_open, true)
         |> refresh_scripts()}

      {:error, :unknown_built_in} ->
        {:noreply, assign(socket, :script_notice, @unknown_built_in_message)}

      {:error, %Ecto.Changeset{}} ->
        # The copy carries the built-in's own templates, so this only happens if
        # a default ever falls outside the placeholder vocabulary. It stores
        # nothing, and the drawer stays closed with the reason on the page.
        {:noreply, assign(socket, :script_notice, @unknown_built_in_message)}

      {:error, :forbidden} ->
        {:noreply, assign(socket, :script_notice, @forbidden_message)}
    end
  end

  def handle_event("copy_built_in_script", _params, socket), do: {:noreply, socket}

  # -- Guidelines ------------------------------------------------------------

  @impl true
  def handle_event("save_guidelines", %{"guidelines" => params}, socket) do
    {text, revision} = guidelines_params(params)

    case Alerts.save_guidelines(audit_context(socket), text, revision) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> store_guidelines(settings.guidelines || "", settings.revision)
         |> assign(:guidelines_notice, "Guidelines saved.")}

      {:error, :stale} ->
        {:noreply, stale_guidelines(socket, text, revision)}

      # The refused document stays in the form beside its error, at the base
      # revision it was written from.
      {:error, %Ecto.Changeset{errors: errors}} ->
        {:noreply,
         assign(
           socket,
           :guidelines_form,
           guidelines_form(text, revision, Keyword.take(errors, [:guidelines]))
         )}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:guidelines_form, guidelines_form(text, revision))
         |> assign(:guidelines_notice, @forbidden_message)}
    end
  end

  def handle_event("save_guidelines", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reload_guidelines", _params, socket) do
    %{text: text, revision: revision} = Alerts.get_guidelines(audit_context(socket))

    {:noreply, store_guidelines(socket, text, revision)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", _params, socket) do
    # Alerts settings are organization data, so a version in context changes the
    # navbar and nothing on this page. There is no version here to re-resolve
    # and no answer to record: the scripts and the guidelines are read from the
    # organization on every arrival, so a version event simply leaves the page
    # the reader is on.
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    # The same answer for a deliberate switch, plus the navbar's own event so
    # the switcher stores the selection it now represents. The version is
    # checked against this organization first, so a forged event cannot put a
    # version of another tenant into this organization's own context.
    if owned_version?(socket, version_id) do
      {:noreply, push_event(socket, "gtfs_version_selected", %{version_id: version_id})}
    else
      {:noreply, socket}
    end
  end

  defp owned_version?(socket, version_id) do
    is_binary(version_id) &&
      Versions.published_gtfs_version_for_org?(
        socket.assigns.current_organization.id,
        version_id
      )
  end

  # The stored document becomes the form's source, so a save or a reload shows
  # what is stored and carries the revision the next save is expected at. A
  # refused save deliberately does not: the reader keeps their own words and the
  # base revision they were editing from (R6).
  defp store_guidelines(socket, text, revision) do
    socket
    |> assign(:guidelines, %{text: text, revision: revision})
    |> assign(:guidelines_form, guidelines_form(text, revision))
    |> assign(:guidelines_stale?, false)
    |> assign(:guidelines_notice, nil)
  end

  # A refused save keeps the entered text and the hidden revision the form was
  # rendered from, so the reader's words are not lost by a conflict (R6).
  defp stale_guidelines(socket, text, revision) do
    socket
    |> assign(:guidelines_form, guidelines_form(text, revision))
    |> assign(:guidelines_stale?, true)
    |> assign(:guidelines_notice, @stale_guidelines_message)
  end

  # -- Reads and state -------------------------------------------------------

  # A stream cannot be counted, so both counts come from the same read the rows
  # do: the organization's own scripts first, then the built-ins it can copy.
  defp refresh_scripts(socket) do
    scripts = Alerts.list_scripts(audit_context(socket))

    socket
    |> assign(:script_count, Enum.count(scripts, &(not &1.built_in?)))
    |> assign(:built_in_count, Enum.count(scripts, & &1.built_in?))
    |> stream(:scripts, Enum.map(scripts, &script_row/1), reset: true)
  end

  # LiveView prefixes a stream item's DOM id with the container's name, so the
  # comprehension's `id` is not the script's own identity and cannot be built
  # into another element's id. `:dom_key` carries the script's own identity
  # instead - its UUID, or a built-in's stable key - and the row's controls are
  # named from it.
  defp script_row(%{built_in?: true} = script) do
    key = built_in_key(script.key)

    Map.merge(script, %{id: "builtin-#{key}", dom_key: "builtin-#{key}", built_in_key: key})
  end

  defp script_row(script), do: Map.put(script, :dom_key, "org-#{script.id}")

  defp built_in_key("builtin:" <> key), do: key
  defp built_in_key(key), do: key

  defp tab(%{"tab" => value}) when is_binary(value) do
    Enum.find(@tabs, &(Atom.to_string(&1) == value)) || :scripts
  end

  defp tab(_params), do: :scripts

  # `list_scripts/1` returns organization scripts first, so the first matching one
  # for an organization script's UUID is that script. A forged id is another
  # organization's script, which is not in this list at all. The drawer's form
  # is a changeset, so the listed option becomes the struct it describes.
  defp find_script(socket, script_id) do
    audit_context(socket)
    |> Alerts.list_scripts()
    |> Enum.find(&(not &1.built_in? and &1.id == script_id))
    |> case do
      nil -> nil
      script -> struct(AlertScript, Map.take(script, @script_fields))
    end
  end

  defp script_base(nil), do: %AlertScript{}
  defp script_base(script), do: script

  defp delete_script(socket, script) do
    case Alerts.delete_script(audit_context(socket), script.id) do
      {:ok, deleted} ->
        socket
        |> close_script_drawer()
        |> refresh_scripts()
        |> assign(:script_notice, "#{deleted.name} deleted.")

      {:error, :forbidden} ->
        assign(socket, :script_notice, @forbidden_message)

      # A missing row is the outcome the person asked for.
      {:error, _reason} ->
        socket |> close_script_drawer() |> refresh_scripts()
    end
  end

  # The opener id survives the close so the shipped OverlayDialog hook can still
  # return focus to the control that opened the drawer.
  defp close_script_drawer(socket) do
    socket
    |> assign(:script_drawer_open, false)
    |> assign(:script_entity, nil)
  end

  defp script_form(script, attrs) do
    script
    |> AlertScript.changeset(attrs)
    |> to_form(as: :script)
  end

  # The guidelines form is a plain document rather than a changeset: the base
  # revision is a hidden field the reader never edits, and `save_guidelines/3`
  # compares it against the row the transaction holds.
  defp guidelines_form(text, revision, errors \\ []) do
    to_form(%{"guidelines" => text, "revision" => revision}, as: :guidelines, errors: errors)
  end

  defp guidelines_params(%{"guidelines" => text, "revision" => revision})
       when is_binary(text) and is_binary(revision) do
    case Integer.parse(revision) do
      {value, ""} -> {text, value}
      _not_a_revision -> {text, -1}
    end
  end

  defp guidelines_params(%{"guidelines" => text}) when is_binary(text), do: {text, -1}
  defp guidelines_params(_params), do: {"", -1}

  defp opener_id(%{"opener_id" => opener_id}) when is_binary(opener_id), do: opener_id
  defp opener_id(_params), do: "create-script"

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: selected_version_id(socket),
      station_stop_id: nil,
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

  defp alerts_path(tab), do: "/alerts/settings?tab=#{tab}"

  # Where **Settings** goes back to. The version's own Settings page when the
  # organization has a version selected, and the organization's alert list when
  # it does not, because there is no version Settings page to return to there.
  defp settings_path(current_gtfs_version) do
    case current_gtfs_version do
      %{id: version_id} -> "/gtfs/#{version_id}/settings"
      _no_version -> "/alerts"
    end
  end

  # -- Rendering -------------------------------------------------------------

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
      <div id="alert-settings-page" class="ds-page">
        <.back_link id="settings-back" navigate={settings_path(assigns[:current_gtfs_version])}>
          Settings
        </.back_link>

        <.message
          :if={@settings_state == :organization_required}
          id="alert-settings-organization-required"
          kind="error"
          title="Alerts need an organization."
        >
          Choose an organization to see and change its alert wording.
        </.message>

        <%= if @settings_state != :organization_required do %>
          <.header>
            Alerts
            <:subtitle>
              Wording everyone in {@current_organization.name} uses for alerts. Changes apply to new
              alerts.
              <.scope_line id="alert-settings-scope" icon="hero-square-3-stack-3d">
                Applies to every service version at {@current_organization.name}. Switching versions
                doesn't change these scripts or guidelines.
              </.scope_line>
            </:subtitle>
            <:actions :if={@tab == :scripts}>
              <.button
                id="create-script"
                class="min-h-11"
                phx-click="open_create_script"
                phx-value-opener_id="create-script"
              >
                <.icon name="hero-plus" class="size-4" /> Create script
              </.button>
            </:actions>
          </.header>

          <div
            id="alert-settings-tabs"
            role="tablist"
            aria-label="Alert settings"
            class="mt-4 flex gap-1 overflow-x-auto border-b border-subtle"
          >
            <.link
              :for={{key, title} <- @tab_titles}
              id={"alert-settings-tab-#{key}"}
              patch={alerts_path(key)}
              role="tab"
              aria-selected={to_string(@tab == key)}
              aria-current={@tab == key && "page"}
              class={[
                "-mb-px inline-flex min-h-11 shrink-0 items-center border-b-2 px-3 text-sm font-[650] no-underline",
                @tab == key && "border-action text-action",
                @tab != key && "border-transparent text-muted hover:text-strong"
              ]}
            >
              {title}
            </.link>
          </div>

          <div :if={@tab == :scripts} id="alert-settings-scripts" class="mt-5 grid gap-4">
            <%!-- While the modal drawer is open the page is inert behind its backdrop,
                 so a refusal is shown inside the drawer instead. --%>
            <.message
              :if={@script_notice && !@script_drawer_open}
              id="script-notice"
              kind="info"
              title={@script_notice}
            />

            <p id="scripts-intro" class="max-w-[80ch] text-sm text-default">
              Scripts are your tested wording for common alerts. The form offers the scripts for
              what's happening, and the fill-ins take their values from the alert. Built-in scripts
              are read-only; copy one to change it.
            </p>

            <.scripts_table
              rows={@streams.scripts}
              script_count={@script_count}
              built_in_count={@built_in_count}
            />
          </div>

          <div
            :if={@tab == :guidelines}
            id="alert-settings-guidelines"
            class="mt-5 grid gap-5 lg:grid-cols-[minmax(0,1fr)_320px]"
          >
            <div class="min-w-0">
              <.message
                :if={@guidelines_notice}
                id="guidelines-notice"
                kind={if @guidelines_stale?, do: "warning", else: "success"}
                title={@guidelines_notice}
              >
                <:action :if={@guidelines_stale?}>
                  <.button
                    id="guidelines-reload"
                    type="button"
                    variant="secondary"
                    phx-click="reload_guidelines"
                  >
                    Reload guidelines
                  </.button>
                </:action>
              </.message>

              <section
                id="guidelines-card"
                aria-labelledby="guidelines-title"
                class="overflow-clip rounded-card border border-subtle bg-white"
              >
                <div class="flex min-h-[52px] items-center justify-between gap-3 border-b border-subtle px-4 py-1 md:px-5">
                  <h2 id="guidelines-title" class="text-base font-bold text-strong">
                    Guidelines
                  </h2>
                  <p id="guidelines-revision" class="text-[13px] text-muted">
                    {revision_label(@guidelines.revision)}
                  </p>
                </div>

                <.form
                  for={@guidelines_form}
                  id="guidelines-form"
                  novalidate
                  phx-submit="save_guidelines"
                  class="grid gap-4 p-4 md:p-5"
                >
                  <.input
                    field={@guidelines_form[:revision]}
                    type="hidden"
                  />
                  <.input
                    field={@guidelines_form[:guidelines]}
                    id="guidelines-text"
                    type="textarea"
                    rows="18"
                    label="Writing guidelines"
                    help="One guideline per paragraph. The message step checks the wording against these."
                  />

                  <div class="flex justify-end">
                    <.button
                      id="save-guidelines"
                      type="submit"
                      class="min-h-11"
                      phx-disable-with="Saving…"
                    >
                      Save guidelines
                    </.button>
                  </div>
                </.form>
              </section>
            </div>

            <aside class="grid content-start gap-4">
              <section
                id="guidelines-apply"
                aria-labelledby="guidelines-apply-title"
                class="rounded-card border border-subtle bg-white p-4 sm:p-5"
              >
                <h2
                  id="guidelines-apply-title"
                  class="text-base font-bold tracking-normal text-strong"
                >
                  Where these apply
                </h2>
                <p class="mt-2 text-sm text-default">
                  <strong class="text-strong">Form:</strong>
                  the message step checks the short message and details against them as you type.
                </p>
                <p class="mt-2 text-sm text-default">
                  <strong class="text-strong">Assistant:</strong>
                  follows them when it drafts, and says which ones a draft does not meet.
                </p>
                <p class="mt-3 text-[13px] text-muted">
                  Written in plain sentences. The checks the form runs are fixed rules based on these;
                  new guidelines guide the assistant and appear as reminders.
                </p>
              </section>
            </aside>
          </div>

          <.script_drawer
            open={@script_drawer_open}
            title={@script_drawer_title}
            entity={@script_entity}
            form={@script_form}
            notice={@script_notice}
            return_focus_id={@script_return_focus_id}
          />

          <.confirm_dialog
            :if={@script_delete_target}
            id="script-delete-confirm"
            chrome="planner"
            open={true}
            title={"Delete #{@script_delete_target.name}?"}
            confirm_label="Delete script"
            cancel_label="Keep script"
            pending_label="Deleting…"
            on_confirm="confirm_delete_script"
            on_cancel="cancel_delete_script"
            described_by="script-delete-confirm-body"
            return_focus_id="script-delete"
          >
            <p>
              This removes the script for everyone in {@current_organization.name}. Alerts already
              written keep their text. You can't undo it.
            </p>
          </.confirm_dialog>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # The organization's own scripts first, then the read-only built-ins. The
  # For column is the situation a script is offered for; the actions column is
  # the difference between a script this organization owns and a default it
  # cannot change in place (AC-11, AC-24).
  attr :rows, :any, required: true, doc: "the `:scripts` stream"
  attr :script_count, :integer, required: true
  attr :built_in_count, :integer, required: true

  defp scripts_table(assigns) do
    ~H"""
    <section
      id="scripts-list"
      aria-label="Message scripts"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="flex min-h-[52px] items-center border-b border-subtle px-4 py-1 md:px-5">
        <p id="scripts-status" class="text-[13px] font-[650] tabular-nums text-strong">
          {count_label(@script_count, "script")} of your own · {count_label(
            @built_in_count,
            "built-in"
          )} to copy
        </p>
      </div>

      <table id="scripts-table" class="w-full border-collapse text-left text-sm">
        <caption class="sr-only">
          Message scripts
        </caption>
        <thead class="max-md:hidden">
          <tr class="bg-canvas">
            <th scope="col" class="px-5 py-2.5 text-left text-[13px] font-[650] text-default">
              Script
            </th>
            <th scope="col" class="px-3 py-2.5 text-left text-[13px] font-[650] text-default">
              For
            </th>
            <th
              scope="col"
              class="w-[1%] px-5 py-2.5 text-right text-[13px] font-[650] text-default whitespace-nowrap"
            >
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody id="scripts" phx-update="stream">
          <tr
            :for={{id, script} <- @rows}
            id={id}
            class="border-t border-subtle align-top hover:bg-canvas max-md:block max-md:px-4 max-md:py-3"
          >
            <td data-label="Script" class="py-3 pl-5 pr-4 max-md:block max-md:p-0">
              <button
                :if={not script.built_in?}
                id={"script-name-#{script.id}"}
                type="button"
                phx-click="open_edit_script"
                phx-value-script_id={script.id}
                class={[
                  "grid min-h-11 min-w-0 content-center rounded-control text-left [overflow-wrap:anywhere]",
                  "group",
                  focus_class()
                ]}
              >
                <span class="text-[15px] font-[650] text-action underline-offset-4 group-hover:text-action-hover group-hover:underline">
                  {script.name}
                </span>
                <span class="text-[13px] text-default">{script.header_template}</span>
              </button>

              <span :if={script.built_in?} class="grid min-h-11 min-w-0 content-center">
                <span class="text-[15px] font-[650] text-strong">{script.name}</span>
                <span class="text-[13px] text-default">{script.header_template}</span>
              </span>
            </td>
            <td data-label="For" class="px-3 py-3 max-md:mt-1 max-md:block max-md:p-0">
              <span
                id={"script-for-#{script.dom_key}"}
                class="inline-flex items-center rounded-badge bg-canvas px-2 py-0.5 text-[12px] font-[650] text-default"
              >
                {situation_label(script.situation) || script.situation}
              </span>
            </td>
            <td
              data-label="Actions"
              class="py-3 pl-3 pr-5 text-right whitespace-nowrap max-md:mt-1 max-md:block max-md:p-0 max-md:text-left"
            >
              <.button
                :if={not script.built_in?}
                id={"edit-script-#{script.id}"}
                type="button"
                class="min-h-11 whitespace-nowrap"
                phx-click="open_edit_script"
                phx-value-script_id={script.id}
                aria-label={"Edit script: #{script.name}"}
              >
                Edit
              </.button>

              <.button
                :if={script.built_in?}
                id={"copy-builtin-#{script.built_in_key}"}
                type="button"
                variant="secondary"
                class="min-h-11 whitespace-nowrap"
                phx-click="copy_built_in_script"
                phx-value-key={script.built_in_key}
                aria-label={"Copy to edit: #{script.name}"}
              >
                Copy to edit
              </.button>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  # The drawer is the only place a script is written. Its form is seeded from the
  # persisted row, so a refused save shows the changeset that caused it beside
  # the templates that were typed (AC-24).
  attr :open, :boolean, required: true
  attr :title, :string, required: true
  attr :entity, :any, default: nil
  attr :form, :any, required: true
  attr :notice, :string, default: nil, doc: "why the last save was refused"
  attr :return_focus_id, :string, default: nil

  defp script_drawer(assigns) do
    ~H"""
    <.drawer
      id="script-drawer"
      chrome="planner"
      open={@open}
      on_close="close_script_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[560px]"
    >
      <:lede>
        <span id="script-drawer-scope">Settings › Alerts › Message scripts</span>
      </:lede>

      <.form
        for={@form}
        id="script-form"
        novalidate
        phx-change="validate_script"
        phx-submit="save_script"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.message :if={@notice && @open} id="script-drawer-notice" kind="error" title={@notice} />

          <.message
            :if={save_failed?(@form)}
            id="script-form-error"
            kind="error"
            title="Script not saved"
            tabindex="-1"
          >
            Fix the fields marked below, then save again.
          </.message>

          <.input
            field={@form[:name]}
            id="script-name"
            type="text"
            label="Name"
            help="What staff see when they choose a script."
            autocomplete="off"
            phx-debounce="blur"
            phx-blur="validate_script"
          />

          <.input
            field={@form[:situation]}
            id="script-situation"
            type="select"
            label="Offer it for"
            prompt="Choose a situation"
            options={Enum.map(Alert.situations(), &{situation_label(&1), &1})}
          />

          <div id="script-fill-ins" class="rounded-control bg-canvas px-4 py-3">
            <p class="text-sm font-[650] text-strong">Fill-ins</p>
            <p class="mt-0.5 text-[13px] text-muted">
              Put one of these in a template in square brackets and the alert's own answers fill it
              in.
            </p>
            <ul class="mt-2 flex flex-wrap gap-1.5">
              <li :for={placeholder <- Message.placeholders()}>
                <span
                  id={"fill-in-#{String.replace(placeholder, " ", "-")}"}
                  class="inline-flex min-h-11 items-center rounded-control border border-control bg-white px-2.5 text-[13px] font-semibold text-cyan-800"
                >
                  [{placeholder}]
                </span>
              </li>
            </ul>
          </div>

          <.input
            field={@form[:header_template]}
            id="script-header"
            type="text"
            label="Short message"
            help="The headline apps show first. Some cut it off after one line."
            phx-debounce="450"
          />

          <.input
            field={@form[:description_template]}
            id="script-description"
            type="textarea"
            rows="5"
            label="Details"
            help="When, where, why, and what to do instead."
            phx-debounce="450"
          />
        </.drawer_scroll>

        <.drawer_footer>
          <.button
            :if={@entity}
            id="script-delete"
            type="button"
            variant="quiet"
            class="mr-auto min-h-11 text-error-fg hover:bg-error-bg"
            phx-click="delete_script"
            phx-value-script_id={@entity.id}
          >
            <.icon name="hero-trash" class="size-4" /> Delete script
          </.button>
          <.button
            id="script-cancel"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="close_script_drawer"
          >
            Cancel
          </.button>
          <.button id="script-save" type="submit" class="min-h-11" phx-disable-with="Saving…">
            {if @entity, do: "Save changes", else: "Create script"}
          </.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  # A failed save is the only state that earns the drawer's banner; validating a
  # field marks that field and must not shout about a save never attempted.
  defp save_failed?(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action}, errors: errors})
       when action in [:update, :insert] and errors != [],
       do: true

  defp save_failed?(_form), do: false

  defp revision_label(0), do: "Recommended guidelines, not changed yet"
  defp revision_label(revision), do: "Revision #{revision}"

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"

  defp focus_class,
    do: "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
end
