defmodule GtfsPlannerWeb.Admin.UsersLive do
  @moduledoc """
  Organization-scoped member administration for `/admin/users`.

  Owns every piece of state the shared presentation deliberately does not: the
  member LiveStream, the separate `members_empty?` flag and `members_state`
  read outcome, the in-flow `member_feedback` region, the invitation form, and
  the confirmed-deactivation target.

  Reads go through `GtfsPlanner.Organizations.list_users_for_admin/1` so a lost
  database connection becomes a retryable region instead of a crash, while
  query and programmer defects stay visible.

  Deactivation is server-owned. The browser may only *request* a user ID; both
  the request and the confirmation resolve that member again from a fresh
  organization-scoped read, and only the resolved server-side identity is ever
  passed to `Organizations.deactivate_user_in_organization/3`.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.InviteForm
  alias GtfsPlanner.Organizations
  alias GtfsPlannerWeb.Admin.Components

  import GtfsPlannerWeb.Admin.InviteFormState,
    only: [assign_invite_form: 2, invitation_detail: 1, normalize_invite_params: 1]

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, form_error_summary: 1, message: 1]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_pathways_studio_admin}

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:members_empty?, false)
      |> assign(:members_state, :ready)
      |> assign(:member_counts, nil)
      |> assign(:members_only_you?, false)
      |> assign(:member_feedback, nil)
      |> assign(:organization_save_failed?, false)
      |> assign(:pending_deactivation, nil)
      |> assign(:deactivation_return_focus_id, nil)
      |> assign(:organization_form, organization_form(socket.assigns.current_organization))
      |> assign_invite_form(InviteForm.changeset(%{}))
      |> stream(:members, [], dom_id: &Components.member_dom_id/1)
      |> load_members()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :invite) do
    socket
    |> assign(:page_title, "Invite user")
    |> assign_invite_form(InviteForm.changeset(%{}))
  end

  defp apply_action(socket, :organization_settings) do
    socket
    |> assign(:page_title, "Organization settings")
    |> assign(:organization_save_failed?, false)
    |> assign(:organization_form, organization_form(socket.assigns.current_organization))
  end

  defp apply_action(socket, :index), do: assign(socket, :page_title, "Users")

  # ---------------------------------------------------------------------------
  # Member reads
  # ---------------------------------------------------------------------------

  # One loader. Every refresh path — first load, retry, invitation, resend,
  # activation, and confirmed deactivation — resets the stream through here so
  # the rendered rows and the emptiness flag can never disagree.
  defp load_members(socket) do
    case Organizations.list_users_for_admin(socket.assigns.current_organization.id) do
      {:ok, members} ->
        socket
        |> stream(:members, members, reset: true)
        |> assign(:members_empty?, members == [])
        |> assign(:members_state, :ready)
        |> assign(:member_counts, Components.count_members(members))
        |> assign(:members_only_you?, only_viewer?(members, socket.assigns.current_user))

      {:error, :unavailable} ->
        socket
        |> stream(:members, [], reset: true)
        |> assign(:members_empty?, false)
        |> assign(:members_state, :unavailable)
        |> assign(:member_counts, nil)
        |> assign(:members_only_you?, false)
    end
  end

  # The list holds one person and it is the viewer: the next step is to invite
  # someone, so the page says so under the list instead of leaving a one-row table.
  defp only_viewer?([%{user: %{id: id}}], %{id: id}), do: true
  defp only_viewer?(_members, _current_user), do: false

  # Resolves a browser-supplied user ID inside the active organization. The ID
  # is only ever compared against server-owned values, never handed to a query,
  # so a malformed value is an ordinary miss rather than a cast error.
  defp resolve_member(socket, user_id) when is_binary(user_id) do
    case Organizations.list_users_for_admin(socket.assigns.current_organization.id) do
      {:ok, members} ->
        case Enum.find(members, &(&1.user.id == user_id)) do
          nil -> {:error, :not_found}
          member -> {:ok, member}
        end

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp resolve_member(_socket, _user_id), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Feedback
  # ---------------------------------------------------------------------------

  # Every outcome says what happened (`title`) and what it means next (`detail`).
  # `user_id` names the row the outcome is about, which the table tints; a stream
  # row only re-renders when the stream is reset, so the callers reload the list.
  defp put_feedback(socket, kind, title, detail, user_id) do
    assign(socket, :member_feedback, %{kind: kind, title: title, detail: detail, user_id: user_id})
  end

  # Clearing an outcome that named a row also un-tints that row.
  defp clear_feedback(%{assigns: %{member_feedback: %{user_id: user_id}}} = socket)
       when not is_nil(user_id) do
    socket |> assign(:member_feedback, nil) |> load_members()
  end

  defp clear_feedback(socket), do: assign(socket, :member_feedback, nil)

  defp refuse_stale(socket) do
    socket
    |> assign(:pending_deactivation, nil)
    |> put_feedback(
      "error",
      "That user is no longer in #{socket.assigns.current_organization.name}.",
      "The list has been refreshed.",
      nil
    )
    |> load_members()
  end

  defp refuse_unavailable(socket) do
    socket
    |> assign(:pending_deactivation, nil)
    |> put_feedback(
      "error",
      "The list of users did not respond, so nothing was changed.",
      "Try the action again in a moment.",
      nil
    )
  end

  # ---------------------------------------------------------------------------
  # Events — reads
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("retry_members", _params, socket) do
    {:noreply, socket |> assign(:member_feedback, nil) |> load_members()}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/users")}
  end

  # ---------------------------------------------------------------------------
  # Events — invitation
  # ---------------------------------------------------------------------------

  def handle_event("validate_invite", %{"invite" => params}, socket) do
    changeset =
      params
      |> normalize_invite_params()
      |> InviteForm.changeset()
      |> Map.put(:action, :validate)

    {:noreply, assign_invite_form(socket, changeset)}
  end

  def handle_event("send_invite", %{"invite" => params}, socket) do
    params = normalize_invite_params(params)
    organization = socket.assigns.current_organization

    result =
      Accounts.invite_member(
        Map.get(params, "email", ""),
        organization.id,
        Map.get(params, "roles", []),
        &url(~p"/users/accept_invite/#{&1}"),
        actor: socket.assigns.current_user,
        login_url: url(~p"/users/log_in")
      )

    case result do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign_invite_form(InviteForm.changeset(%{}))
         |> put_feedback(
           "success",
           "Invitation sent to #{user.email}.",
           invitation_detail(user),
           user.id
         )
         |> load_members()
         |> push_patch(to: ~p"/admin/users")}

      {:ok, :added, user} ->
        {:noreply,
         socket
         |> assign_invite_form(InviteForm.changeset(%{}))
         |> put_feedback(
           "success",
           "#{user.email} now has access to #{organization.name}.",
           invitation_detail(user),
           user.id
         )
         |> load_members()
         |> push_patch(to: ~p"/admin/users")}

      {:partial, :notification_failed, user, _reason} ->
        {:noreply,
         socket
         |> assign_invite_form(InviteForm.changeset(%{}))
         |> put_feedback(
           "warning",
           "#{user.email} was added to #{organization.name}, but the notification email could not be sent.",
           "They can already sign in. Let them know they now have access.",
           user.id
         )
         |> load_members()
         |> push_patch(to: ~p"/admin/users")}

      {:partial, :delivery_failed, user, _reason} ->
        {:noreply,
         socket
         |> assign_invite_form(InviteForm.changeset(%{}))
         |> put_feedback(
           "warning",
           "#{user.email} was added to #{organization.name}, but the invitation email did not send.",
           "Select Resend invite on their row to try again.",
           user.id
         )
         |> load_members()
         |> push_patch(to: ~p"/admin/users")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_feedback(
           "error",
           "Your administrator access has changed.",
           "Nothing was changed. Ask a current organization administrator to send the invitation.",
           nil
         )
         |> push_event("focus_form_error", %{
           form_id: "invite-form",
           fallback_id: "invite-service-error"
         })}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign_invite_form(changeset)
         |> push_event("focus_form_error", %{
           form_id: "invite-form",
           fallback_id: "invite-service-error"
         })}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — member actions
  # ---------------------------------------------------------------------------

  def handle_event("resend_invite", %{"user-id" => user_id}, socket) do
    with_resolved_member(socket, user_id, fn socket, member ->
      case Accounts.resend_user_invite(
             socket.assigns.current_user,
             socket.assigns.current_organization.id,
             member.user.id,
             &url(~p"/users/accept_invite/#{&1}")
           ) do
        {:ok, _delivery} ->
          socket
          |> put_feedback(
            "success",
            "Invitation resent to #{member.user.email}.",
            "The new link works for 7 days.",
            member.user.id
          )
          |> load_members()

        {:error, :already_accepted} ->
          socket
          |> put_feedback(
            "warning",
            "#{member.user.email} has already accepted their invitation.",
            "The list is refreshed, and they now show as Active.",
            member.user.id
          )
          |> load_members()

        {:error, :forbidden} ->
          put_feedback(
            socket,
            "error",
            "Your administrator access has changed.",
            "Nothing was changed. Ask a current organization administrator to resend the invitation.",
            nil
          )

        {:error, :not_found} ->
          refuse_stale(socket)

        {:error, _reason} ->
          socket
          |> put_feedback(
            "error",
            "The invitation to #{member.user.email} could not be sent.",
            "Nothing changed. Try again in a few minutes.",
            member.user.id
          )
          |> load_members()
      end
    end)
  end

  def handle_event("activate_user", %{"user-id" => user_id}, socket) do
    with_resolved_member(socket, user_id, fn socket, member ->
      case Organizations.activate_user_in_organization(
             socket.assigns.current_user,
             member.user.id,
             socket.assigns.current_organization.id
           ) do
        {:ok, _membership} ->
          socket
          |> put_feedback(
            "success",
            "#{member.user.email} activated.",
            "They can sign in to #{socket.assigns.current_organization.name} again.",
            member.user.id
          )
          |> load_members()

        {:error, _reason} ->
          socket
          |> put_feedback(
            "error",
            "#{member.user.email} could not be activated.",
            "Their access is unchanged. Try again.",
            member.user.id
          )
          |> load_members()
      end
    end)
  end

  # The request only *proposes* a target. The member is resolved from a fresh
  # organization-scoped read and the resolved server-side value is what gets
  # stored, so a stale or foreign browser ID never becomes a confirmable target.
  def handle_event("request_deactivation", %{"user-id" => user_id}, socket) do
    case resolve_member(socket, user_id) do
      {:ok, member} ->
        {:noreply,
         socket
         |> clear_feedback()
         |> assign(:pending_deactivation, member)
         |> assign(:deactivation_return_focus_id, "deactivate-user-#{member.user.id}")}

      {:error, :not_found} ->
        {:noreply, refuse_stale(socket)}

      {:error, :unavailable} ->
        {:noreply, refuse_unavailable(socket)}
    end
  end

  def handle_event("cancel_deactivation", _params, socket) do
    {:noreply, assign(socket, :pending_deactivation, nil)}
  end

  # Confirmation reads no browser value at all. It re-resolves the stored
  # server-owned identity inside the active organization and only then mutates.
  def handle_event("confirm_deactivation", _params, socket) do
    case socket.assigns.pending_deactivation do
      nil ->
        {:noreply, socket}

      %{user: %{id: user_id}} ->
        case resolve_member(socket, user_id) do
          {:ok, member} -> {:noreply, deactivate_member(socket, member)}
          {:error, :not_found} -> {:noreply, refuse_stale(socket)}
          {:error, :unavailable} -> {:noreply, refuse_unavailable(socket)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Events — organization settings
  # ---------------------------------------------------------------------------

  def handle_event("validate_organization", %{"organization" => org_params}, socket) do
    changeset =
      socket.assigns.current_organization
      |> Organizations.change_organization(allowed_org_params(org_params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:organization_save_failed?, false)
     |> assign(:organization_form, to_form(changeset))}
  end

  def handle_event("save_organization", %{"organization" => org_params}, socket) do
    case Organizations.update_organization(
           socket.assigns.current_organization,
           allowed_org_params(org_params)
         ) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:current_organization, organization)
         |> assign(:organization_form, organization_form(organization))
         |> put_flash(:info, "Organization updated")
         |> push_patch(to: ~p"/admin/users")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:organization_save_failed?, true)
         |> assign(:organization_form, to_form(%{changeset | action: :validate}))
         |> push_event("focus_form_error", %{form_id: "organization-settings-form"})}
    end
  end

  defp with_resolved_member(socket, user_id, fun) do
    case resolve_member(socket, user_id) do
      {:ok, member} -> {:noreply, fun.(socket, member)}
      {:error, :not_found} -> {:noreply, refuse_stale(socket)}
      {:error, :unavailable} -> {:noreply, refuse_unavailable(socket)}
    end
  end

  defp deactivate_member(socket, member) do
    case Organizations.deactivate_user_in_organization(
           socket.assigns.current_user,
           member.user.id,
           socket.assigns.current_organization.id
         ) do
      {:ok, _membership} ->
        socket
        |> assign(:pending_deactivation, nil)
        # The row now offers activation, so that is where focus belongs.
        |> assign(:deactivation_return_focus_id, "activate-user-#{member.user.id}")
        |> put_feedback(
          "success",
          "#{member.user.email} deactivated.",
          "They were signed out of every session and cannot sign in until you activate them again.",
          member.user.id
        )
        |> load_members()

      {:error, reason} ->
        socket
        |> assign(:pending_deactivation, nil)
        |> put_feedback(
          "error",
          Components.deactivation_error(reason, member.user.email),
          "Their access is unchanged.",
          member.user.id
        )
        |> load_members()
    end
  end

  # ---------------------------------------------------------------------------
  # Form helpers
  # ---------------------------------------------------------------------------

  defp organization_form(organization) do
    organization |> Organizations.change_organization() |> to_form()
  end

  defp allowed_org_params(params), do: Map.take(params, ["name"])

  # The organization name is the form's only field, so there is one error and it
  # reads the same beside the field and in the summary.
  defp organization_name_errors(form, save_failed?) do
    if save_failed? or Phoenix.Component.used_input?(form[:name]) do
      for error <- Keyword.get_values(form.source.errors, :name),
          do: Components.organization_error_message(:name, error)
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  attr :form, Phoenix.HTML.Form, required: true
  attr :save_failed?, :boolean, required: true

  defp organization_settings_form(assigns) do
    assigns =
      assign(assigns, :errors, organization_name_errors(assigns.form, assigns.save_failed?))

    ~H"""
    <.form
      for={@form}
      id="organization-settings-form"
      novalidate
      phx-change="validate_organization"
      phx-submit="save_organization"
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="grid flex-1 content-start gap-5 overflow-y-auto px-5 py-5 sm:px-6">
        <.form_error_summary
          id="organization-error-summary"
          title="Changes not saved. Fix this field:"
          failures={
            if @save_failed? and @errors != [],
              do: [%{href: "#organization-name", msg: List.first(@errors)}],
              else: []
          }
          class=""
        />

        <.input
          field={@form[:name]}
          id="organization-name"
          type="text"
          label="Organization name"
          help="Shown next to the logo in the page header."
          maxlength="255"
          autocomplete="off"
          errors={@errors}
          required
        />
      </div>

      <.drawer_footer>
        <.button variant="secondary" class="min-h-11" patch={~p"/admin/users"}>Cancel</.button>
        <.button type="submit" class="min-h-11 min-w-[132px]" phx-disable-with="Saving…">
          Save changes
        </.button>
      </.drawer_footer>
    </.form>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={@user_roles}
      current_organization={@current_organization}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <div id="admin-users-page" phx-hook="FormErrorFocus">
        <.header>
          Users
          <:subtitle>
            Invite colleagues and choose what each person can do in {@current_organization.name}.
          </:subtitle>
          <:actions>
            <.button
              id="organization-settings-trigger"
              variant="quiet"
              class="min-h-11"
              patch={~p"/admin/users/organization-settings"}
            >
              <.icon name="hero-adjustments-horizontal" class="size-4 text-muted" />
              Organization settings
            </.button>
            <.button
              :if={header_invite?(assigns)}
              id="invite-user-trigger"
              class="min-h-11"
              patch={~p"/admin/users/invite"}
            >
              <.icon name="hero-plus" class="size-4" /> Invite user
            </.button>
          </:actions>
        </.header>

        <div id="member-action-feedback" class="mt-6 empty:mt-0">
          <.message
            :if={@member_feedback}
            kind={@member_feedback.kind}
            title={@member_feedback.title}
          >
            {@member_feedback.detail}
          </.message>
        </div>

        <div id="members-state" class="mt-6">
          <div :if={@members_state == :unavailable} id="members-unavailable" class="max-w-[720px]">
            <.message kind="error" title="Users could not load">
              The list of users did not respond, so nothing here has changed. Reload to try again.
            </.message>
            <.button
              id="retry-members"
              variant="secondary"
              class="mt-4 min-h-11"
              phx-click="retry_members"
              phx-disable-with="Reloading…"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Reload users
            </.button>
          </div>

          <Components.member_data_view
            :if={@members_state == :ready}
            id="members"
            members={@streams.members}
            empty?={@members_empty?}
            counts={@member_counts}
            marked_id={@member_feedback && @member_feedback.user_id}
            first_use?={@members_only_you?}
            invite_path={~p"/admin/users/invite"}
            empty_title="No users yet"
            empty_description={"Invite someone to give them access to #{@current_organization.name}. They get an email with a link to set a password."}
            invite_label="Invite user"
            resend_event="resend_invite"
            activate_event="activate_user"
            deactivate_event="request_deactivation"
          />
        </div>

        <.drawer
          id="invite-drawer"
          chrome="planner"
          open={@live_action == :invite}
          on_close="close_drawer"
          title="Invite user"
          class="max-w-[480px]"
          initial_focus={:first_field}
          initial_focus_id="invite-email"
          return_focus_id={invite_focus_id(assigns)}
        >
          <:lede>
            They get an email with a link to set a password and join {@current_organization.name}.
            The link works for 7 days.
          </:lede>
          <Components.invite_form
            :if={@live_action == :invite}
            form={@invite_form}
            email_errors={@invite_email_errors}
            roles_error={@invite_roles_error}
            base_error={@invite_base_error}
            failures={@invite_failures}
            cancel_path={~p"/admin/users"}
          />
        </.drawer>

        <.drawer
          id="organization-settings-drawer"
          chrome="planner"
          open={@live_action == :organization_settings}
          on_close="close_drawer"
          title="Organization settings"
          class="max-w-[480px]"
          initial_focus={:first_field}
          initial_focus_id="organization-name"
          return_focus_id="organization-settings-trigger"
        >
          <:lede>Applies to everyone in {@current_organization.name}.</:lede>
          <.organization_settings_form
            :if={@live_action == :organization_settings}
            form={@organization_form}
            save_failed?={@organization_save_failed?}
          />
        </.drawer>

        <.confirm_dialog
          id="deactivate-user-dialog"
          chrome="planner"
          open={@pending_deactivation != nil}
          title={Components.deactivation_title(@pending_deactivation)}
          confirm_label="Deactivate user"
          pending_label="Deactivating user…"
          cancel_label="Keep access"
          on_confirm="confirm_deactivation"
          on_cancel="cancel_deactivation"
          return_focus_id={@deactivation_return_focus_id}
          described_by="deactivate-user-dialog-body"
        >
          <span :if={@pending_deactivation}>
            {Components.deactivation_body(@pending_deactivation, @current_organization)}
          </span>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  # The empty state and the only-you panel carry their own invitation CTA, so the
  # header primary is omitted there to keep exactly one primary action per state.
  defp header_invite?(assigns) do
    not (assigns.members_state == :ready and (assigns.members_empty? or assigns.members_only_you?))
  end

  # Closing the invitation drawer returns focus to the button that opened it.
  defp invite_focus_id(assigns) do
    cond do
      header_invite?(assigns) -> "invite-user-trigger"
      assigns.members_only_you? -> "first-use-invite"
      true -> nil
    end
  end
end
