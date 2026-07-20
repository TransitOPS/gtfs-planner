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
  passed to `Organizations.deactivate_user_in_organization/2`.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.InviteForm
  alias GtfsPlanner.Organizations
  alias GtfsPlannerWeb.Admin.Components
  alias GtfsPlannerWeb.CoreComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_pathways_studio_admin}

  @unavailable_action "The member list is unavailable right now, so nothing was changed. Retry and try again."
  @stale_target "That member is no longer in this organization. The list has been refreshed."

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
      |> assign(:member_feedback, nil)
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

      {:error, :unavailable} ->
        socket
        |> stream(:members, [], reset: true)
        |> assign(:members_empty?, false)
        |> assign(:members_state, :unavailable)
    end
  end

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

  defp put_feedback(socket, kind, title, user_id) do
    assign(socket, :member_feedback, %{kind: kind, title: title, user_id: user_id})
  end

  defp clear_feedback(socket), do: assign(socket, :member_feedback, nil)

  defp refuse_stale(socket) do
    socket
    |> assign(:pending_deactivation, nil)
    |> put_feedback("error", @stale_target, nil)
    |> load_members()
  end

  defp refuse_unavailable(socket) do
    socket
    |> assign(:pending_deactivation, nil)
    |> put_feedback("error", @unavailable_action, nil)
  end

  # ---------------------------------------------------------------------------
  # Events — reads
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("retry_members", _params, socket) do
    {:noreply, socket |> clear_feedback() |> load_members()}
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
        &url(~p"/users/accept_invite/#{&1}")
      )

    case result do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign_invite_form(InviteForm.changeset(%{}))
         |> put_feedback("success", "Invitation sent to #{user.email}.", user.id)
         |> load_members()
         |> push_patch(to: ~p"/admin/users")}

      {:partial, :delivery_failed, user, _reason} ->
        {:noreply,
         socket
         |> assign_invite_form(InviteForm.changeset(%{}))
         |> put_feedback(
           "warning",
           "#{user.email} was added to #{organization.name}, but the invitation email could not be sent. Use Resend invite on their row.",
           user.id
         )
         |> load_members()
         |> push_patch(to: ~p"/admin/users")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign_invite_form(changeset)
         |> push_event("focus_first_invite_error", %{})}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — member actions
  # ---------------------------------------------------------------------------

  def handle_event("resend_invite", %{"user-id" => user_id}, socket) do
    with_resolved_member(socket, user_id, fn socket, member ->
      case Accounts.resend_user_invite(member.user, &url(~p"/users/accept_invite/#{&1}")) do
        {:ok, _delivery} ->
          socket
          |> put_feedback("success", "Invitation resent to #{member.user.email}.", member.user.id)

        {:error, :already_accepted} ->
          socket
          |> put_feedback(
            "warning",
            "#{member.user.email} has already accepted their invitation.",
            member.user.id
          )
          |> load_members()

        {:error, _reason} ->
          put_feedback(
            socket,
            "error",
            "The invitation to #{member.user.email} could not be sent.",
            member.user.id
          )
      end
    end)
  end

  def handle_event("activate_user", %{"user-id" => user_id}, socket) do
    with_resolved_member(socket, user_id, fn socket, member ->
      case Organizations.activate_user_in_organization(
             member.user.id,
             socket.assigns.current_organization.id
           ) do
        {:ok, _membership} ->
          socket
          |> put_feedback("success", "#{member.user.email} activated.", member.user.id)
          |> load_members()

        {:error, _reason} ->
          socket
          |> put_feedback(
            "error",
            "#{member.user.email} could not be activated.",
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

    {:noreply, assign(socket, :organization_form, to_form(changeset))}
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
        {:noreply, assign(socket, :organization_form, to_form(%{changeset | action: :validate}))}
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
           member.user.id,
           socket.assigns.current_organization.id
         ) do
      {:ok, _membership} ->
        socket
        |> assign(:pending_deactivation, nil)
        # The row now offers activation, so that is where focus belongs.
        |> assign(:deactivation_return_focus_id, "activate-user-#{member.user.id}")
        |> put_feedback("success", "#{member.user.email} deactivated.", member.user.id)
        |> load_members()

      {:error, _reason} ->
        socket
        |> assign(:pending_deactivation, nil)
        |> put_feedback("error", "#{member.user.email} could not be deactivated.", member.user.id)
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

  # Roles arrive as a list, a map, or not at all when every box is unchecked.
  defp normalize_invite_params(params) do
    roles =
      case Map.get(params, "roles") do
        nil -> []
        roles when is_list(roles) -> roles
        roles when is_map(roles) -> Map.values(roles)
        role -> [role]
      end

    Map.put(params, "roles", roles)
  end

  defp assign_invite_form(socket, changeset) do
    socket
    |> assign(:invite_form, to_form(changeset, as: :invite))
    |> assign(:invite_email_errors, submitted_errors(changeset, :email))
    |> assign(:invite_roles_error, roles_error(changeset))
    |> assign(:invite_base_error, List.first(field_errors(changeset, :base)))
  end

  defp field_errors(changeset, field) do
    for {^field, error} <- changeset.errors, do: CoreComponents.translate_error(error)
  end

  # On submit the errors are authoritative and always shown. While changing,
  # the shared input falls back to the repository's touched-input behaviour.
  defp submitted_errors(%Ecto.Changeset{action: :insert} = changeset, field),
    do: field_errors(changeset, field)

  defp submitted_errors(_changeset, _field), do: []

  # A checkbox group has no useful blur, so its error appears on submit and on
  # any change the operator actually made to the group.
  defp roles_error(%Ecto.Changeset{action: nil}), do: nil

  defp roles_error(%Ecto.Changeset{action: :validate, params: params} = changeset) do
    if Map.has_key?(params, "_unused_roles"),
      do: nil,
      else: List.first(field_errors(changeset, :roles))
  end

  defp roles_error(changeset), do: List.first(field_errors(changeset, :roles))

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  attr :form, Phoenix.HTML.Form, required: true
  attr :email_errors, :list, required: true
  attr :roles_error, :string, default: nil
  attr :base_error, :string, default: nil
  attr :organization, :map, required: true

  defp invite_form(assigns) do
    assigns = assign(assigns, :selected_roles, assigns.form[:roles].value || [])

    ~H"""
    <p class="mb-6 text-sm text-base-content/70">
      The invitee gets an email with a link to set a password and join {@organization.name}.
    </p>

    <.callout :if={@base_error} id="invite-service-error" kind="error" title={@base_error}>
      Nothing was saved. Correct the details or try again.
    </.callout>

    <.simple_form
      for={@form}
      id="invite-form"
      phx-change="validate_invite"
      phx-submit="send_invite"
    >
      <.input
        field={@form[:email]}
        id="invite-email"
        type="email"
        label="Email"
        autocomplete="email"
        errors={@email_errors}
        required
      />

      <.checkbox_group
        id="invite-roles"
        name="invite[roles][]"
        label="Roles"
        options={InviteForm.available_roles()}
        selected={@selected_roles}
        error={@roles_error}
        required
      />

      <:actions>
        <div class="flex-1"></div>
        <.button variant="quiet" class="min-h-11" patch={~p"/admin/users"}>Cancel</.button>
        <.button type="submit" class="min-h-11" phx-disable-with="Sending invite…">
          Send invite
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  defp organization_settings_form(assigns) do
    ~H"""
    <.simple_form
      for={@form}
      id="organization-settings-form"
      phx-change="validate_organization"
      phx-submit="save_organization"
    >
      <.input
        field={@form[:name]}
        id="organization-name"
        type="text"
        label="Organization name"
        maxlength="255"
        required
      />

      <:actions>
        <div class="flex-1"></div>
        <.button variant="quiet" class="min-h-11" patch={~p"/admin/users"}>Cancel</.button>
        <.button type="submit" class="min-h-11" phx-disable-with="Saving…">Save changes</.button>
      </:actions>
    </.simple_form>
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
      <div id="admin-users-page" phx-hook=".InviteErrorFocus">
        <.header>
          Users
          <:subtitle>Manage who can work in {@current_organization.name}.</:subtitle>
          <:actions>
            <.button
              id="organization-settings-trigger"
              variant="secondary"
              class="min-h-11"
              patch={~p"/admin/users/organization-settings"}
            >
              Organization settings
            </.button>
            <.button
              :if={header_invite?(assigns)}
              id="invite-user-trigger"
              class="min-h-11"
              patch={~p"/admin/users/invite"}
            >
              Invite user
            </.button>
          </:actions>
        </.header>

        <div id="member-action-feedback" class="mt-6 empty:mt-0">
          <.callout
            :if={@member_feedback}
            kind={@member_feedback.kind}
            title={@member_feedback.title}
          />
        </div>

        <div id="members-state" class="mt-6">
          <.callout
            :if={@members_state == :unavailable}
            kind="error"
            title="Members are unavailable right now"
          >
            The member list could not be loaded because the database is unreachable. Nothing was
            changed.
            <div class="mt-3">
              <.button
                id="retry-members"
                variant="secondary"
                size="sm"
                class="min-h-11"
                phx-click="retry_members"
                phx-disable-with="Retrying…"
              >
                Retry
              </.button>
            </div>
          </.callout>

          <Components.member_data_view
            :if={@members_state == :ready}
            id="members"
            members={@streams.members}
            empty?={@members_empty?}
            invite_path={~p"/admin/users/invite"}
            empty_title="No members yet"
            empty_description={"Invite someone to give them access to #{@current_organization.name}."}
            invite_label="Invite user"
            resend_event="resend_invite"
            activate_event="activate_user"
            deactivate_event="request_deactivation"
          />
        </div>

        <.drawer
          id="invite-drawer"
          open={@live_action == :invite}
          on_close="close_drawer"
          title="User invitation"
          initial_focus={:first_field}
          initial_focus_id="invite-email"
          return_focus_id={if header_invite?(assigns), do: "invite-user-trigger"}
        >
          <.invite_form
            :if={@live_action == :invite}
            form={@invite_form}
            email_errors={@invite_email_errors}
            roles_error={@invite_roles_error}
            base_error={@invite_base_error}
            organization={@current_organization}
          />
        </.drawer>

        <.drawer
          id="organization-settings-drawer"
          open={@live_action == :organization_settings}
          on_close="close_drawer"
          title="Organization settings"
          initial_focus={:first_field}
          initial_focus_id="organization-name"
          return_focus_id="organization-settings-trigger"
        >
          <.organization_settings_form
            :if={@live_action == :organization_settings}
            form={@organization_form}
          />
        </.drawer>

        <.confirm_dialog
          id="deactivate-user-dialog"
          open={@pending_deactivation != nil}
          title={deactivation_title(@pending_deactivation)}
          confirm_label="Deactivate user"
          pending_label="Deactivating user…"
          on_confirm="confirm_deactivation"
          on_cancel="cancel_deactivation"
          return_focus_id={@deactivation_return_focus_id}
          described_by="deactivate-user-dialog-body"
        >
          <span :if={@pending_deactivation}>
            {@pending_deactivation.user.email} loses access to {@current_organization.name} and is
            signed out of every web and mobile session immediately. The account is kept and can be
            activated again from this list.
          </span>
        </.confirm_dialog>
      </div>
    </Layouts.app>

    <%!-- Moves focus to the first invalid invitation control after a failed submit,
         through the repository's colocated-hook pattern. Decision 0.12 excludes
         live-region announcements, so focus movement is the whole contract. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".InviteErrorFocus">
      export default {
        mounted() {
          this.handleEvent("focus_first_invite_error", () => {
            const form = document.getElementById("invite-form");
            const invalid = form && form.querySelector('[aria-invalid="true"]');
            if (!invalid) return;
            // A grouped control (the roles fieldset) carries the invalid state
            // but is not focusable itself, so descend to its first control.
            const focusable = invalid.matches("input, select, textarea, button")
              ? invalid
              : invalid.querySelector(
                  "input:not([disabled]), select:not([disabled]), textarea:not([disabled]), button:not([disabled])"
                );
            // The event can arrive before LiveView finishes patching and
            // restoring focus, so claim focus on the next frame instead.
            requestAnimationFrame(() => (focusable || invalid).focus());
          })
        }
      }
    </script>
    """
  end

  # The empty state carries its own invitation CTA, so the header primary is
  # omitted there to keep exactly one primary action per state.
  defp header_invite?(assigns) do
    not (assigns.members_state == :ready and assigns.members_empty?)
  end

  defp deactivation_title(nil), do: "Deactivate user"
  defp deactivation_title(%{user: user}), do: "Deactivate #{user.email}?"
end
