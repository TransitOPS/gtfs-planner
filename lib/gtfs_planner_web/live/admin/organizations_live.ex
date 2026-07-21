defmodule GtfsPlannerWeb.Admin.OrganizationsLive do
  @moduledoc """
  System-administrator organization management for `/admin/organizations`.

  Owns three independent read states so one failure never hides the rest of the
  page: the organization index (`organizations_state`), the requested
  organization record (`organization_state`), and that organization's members
  (`members_state`). A member read failure therefore leaves the loaded
  organization metadata on screen and degrades only the member region.

  Both collections render from LiveStreams with separate `*_empty?` flags; the
  streams are reset on every load, retry, and mutation, and nothing enumerates
  or duplicates them.

  Route text is classified before it reaches a read. A malformed `:org_id` is
  rejected by `Ecto.UUID.cast/1`, so it can never reach `Repo.get/2` and raise
  `Ecto.Query.CastError`; only well-formed identifiers reach
  `Organizations.fetch_organization_for_admin/1`, where a missing record and an
  unreachable database stay distinct.

  Deactivation is server-owned. The browser may only *propose* a user ID; the
  request and the confirmation each resolve that member again from a fresh read
  scoped to the organization currently in the route, and only the resolved
  server-side identity reaches `Organizations.deactivate_user_in_organization/2`.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.InviteForm
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlannerWeb.Admin.Components
  alias GtfsPlannerWeb.CoreComponents

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount {GtfsPlannerWeb.EnsureRole, :require_system_administrator}

  @unavailable_action "The member list is unavailable right now, so nothing was changed. Retry and try again."
  @stale_target "That member is no longer in this organization. The list has been refreshed."

  # Routes that need the requested organization record.
  @record_actions [:show, :edit, :invite]
  # Routes whose background page is the organization detail rather than the index.
  @detail_actions [:show, :invite]

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      # Administrators hold no organization-scoped roles, so the layout gets an
      # explicit empty list rather than a missing assign.
      |> assign(:user_roles, socket.assigns[:user_roles] || [])
      |> assign(:page_title, "Organizations")
      |> assign(:organization, nil)
      |> assign(:organization_state, :ready)
      |> assign(:requested_org_id, nil)
      |> assign(:organizations_empty?, false)
      |> assign(:organizations_state, :ready)
      |> assign(:members_empty?, false)
      |> assign(:members_state, :ready)
      |> assign(:organization_feedback, nil)
      |> assign(:member_feedback, nil)
      |> assign(:pending_deactivation, nil)
      |> assign(:deactivation_return_focus_id, nil)
      |> assign(:org_drawer_return_focus_id, nil)
      |> assign_organization_form(Organizations.change_organization(%Organization{}))
      |> assign_invite_form(InviteForm.changeset(%{}))
      |> stream(:organizations, [], dom_id: &organization_dom_id/1)
      |> stream(:members, [], dom_id: &Components.member_dom_id/1)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Organizations")
    |> assign(:organization, nil)
    |> load_organizations()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New organization")
    |> assign(:organization, nil)
    |> assign_organization_form(Organizations.change_organization(%Organization{}))
    |> load_organizations()
    |> assign_org_drawer_return_focus(:new)
  end

  defp apply_action(socket, :edit, %{"org_id" => org_id}) do
    socket = load_organization(socket, org_id)

    case socket.assigns.organization_state do
      :ready ->
        socket
        |> assign(:page_title, "Edit organization")
        |> assign_organization_form(
          Organizations.change_organization(socket.assigns.organization)
        )
        |> load_organizations()
        |> assign_org_drawer_return_focus(:edit)

      _unresolved ->
        assign(socket, :page_title, "Organization")
    end
  end

  defp apply_action(socket, :show, %{"org_id" => org_id}) do
    socket = load_organization(socket, org_id)

    case socket.assigns.organization_state do
      :ready ->
        socket
        |> assign(:page_title, socket.assigns.organization.name)
        |> load_members()

      _unresolved ->
        assign(socket, :page_title, "Organization")
    end
  end

  # The invitation drawer opens over the organization detail, so the record and
  # the member stream are loaded first. Closing the drawer then reveals the same
  # page it was opened from instead of jumping back to the index.
  defp apply_action(socket, :invite, %{"org_id" => _org_id} = params) do
    socket = apply_action(socket, :show, params)

    case socket.assigns.organization_state do
      :ready ->
        socket
        |> assign(:page_title, "Member invitation")
        |> assign_invite_form(InviteForm.changeset(%{}))

      _unresolved ->
        # `org_id` is never rendered; it is only re-classified on retry.
        socket
    end
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  defp load_organizations(socket) do
    case Organizations.list_organizations_for_admin() do
      {:ok, organizations} ->
        socket
        |> stream(:organizations, organizations, reset: true)
        |> assign(:organizations_empty?, organizations == [])
        |> assign(:organizations_state, :ready)

      {:error, :unavailable} ->
        socket
        |> stream(:organizations, [], reset: true)
        |> assign(:organizations_empty?, false)
        |> assign(:organizations_state, :unavailable)
    end
  end

  # Malformed route text is classified here, before any query is built, so an
  # invalid UUID becomes an ordinary not-found instead of an Ecto cast error.
  defp load_organization(socket, org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, id} -> fetch_organization(socket, id)
      :error -> put_organization_state(socket, :not_found, nil, nil)
    end
  end

  defp fetch_organization(socket, id) do
    case Organizations.fetch_organization_for_admin(id) do
      {:ok, organization} -> put_organization_state(socket, :ready, organization, id)
      {:error, :not_found} -> put_organization_state(socket, :not_found, nil, nil)
      {:error, :unavailable} -> put_organization_state(socket, :unavailable, nil, id)
    end
  end

  defp put_organization_state(socket, state, organization, requested_id) do
    socket
    |> assign(:organization_state, state)
    |> assign(:organization, organization)
    |> assign(:requested_org_id, requested_id)
  end

  # One loader. Initial load, retry, invitation, resend, activation, and
  # confirmed deactivation all reset the stream through here, so the rendered
  # rows and the emptiness flag can never disagree.
  defp load_members(socket) do
    case Organizations.list_users_for_admin(socket.assigns.organization.id) do
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

  # Resolves a browser-supplied user ID inside the organization currently in the
  # route. The ID is only ever compared against server-owned values, never
  # handed to a query, so a malformed value is an ordinary miss.
  defp resolve_member(socket, user_id) when is_binary(user_id) do
    case Organizations.list_users_for_admin(socket.assigns.organization.id) do
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

  defp put_organization_feedback(socket, kind, title) do
    assign(socket, :organization_feedback, %{kind: kind, title: title})
  end

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
  # Events — reads and navigation
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("retry_organizations", _params, socket) do
    {:noreply, socket |> assign(:organization_feedback, nil) |> load_organizations()}
  end

  def handle_event("retry_organization", _params, socket) do
    socket = load_organization(socket, socket.assigns.requested_org_id)

    socket =
      if socket.assigns.organization_state == :ready, do: load_members(socket), else: socket

    {:noreply, socket}
  end

  def handle_event("retry_members", _params, socket) do
    {:noreply, socket |> clear_feedback() |> load_members()}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, push_patch(socket, to: close_destination(socket))}
  end

  # ---------------------------------------------------------------------------
  # Events — organization create and edit
  # ---------------------------------------------------------------------------

  def handle_event("validate_organization", %{"organization" => params}, socket) do
    changeset =
      socket
      |> organization_subject()
      |> Organizations.change_organization(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_organization_form(socket, changeset)}
  end

  def handle_event("save_organization", %{"organization" => params}, socket) do
    save_organization(socket, socket.assigns.live_action, params)
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
    organization = socket.assigns.organization

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
         |> push_patch(to: ~p"/admin/organizations/#{organization.id}")}

      {:partial, :delivery_failed, user, _reason} ->
        {:noreply,
         socket
         |> assign_invite_form(InviteForm.changeset(%{}))
         |> put_feedback(
           "warning",
           "#{user.email} was added to #{organization.name}, but the invitation email could not be sent. Use Resend invite on their row.",
           user.id
         )
         |> push_patch(to: ~p"/admin/organizations/#{organization.id}")}

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
          put_feedback(
            socket,
            "success",
            "Invitation resent to #{member.user.email}.",
            member.user.id
          )

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
             socket.assigns.organization.id
           ) do
        {:ok, _membership} ->
          socket
          |> put_feedback("success", "#{member.user.email} activated.", member.user.id)
          |> load_members()

        {:error, _reason} ->
          socket
          |> put_feedback("error", "#{member.user.email} could not be activated.", member.user.id)
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
           socket.assigns.organization.id
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
  # Organization command helpers
  # ---------------------------------------------------------------------------

  defp save_organization(socket, :new, params) do
    case Organizations.create_organization(params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_organization_feedback("success", "#{organization.name} created.")
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_organization_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp save_organization(socket, :edit, params) do
    case Organizations.update_organization(socket.assigns.organization, params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:organization, organization)
         |> put_organization_feedback("success", "#{organization.name} updated.")
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_organization_form(socket, Map.put(changeset, :action, :update))}
    end
  end

  defp organization_subject(%{
         assigns: %{live_action: :edit, organization: %Organization{} = org}
       }),
       do: org

  defp organization_subject(_socket), do: %Organization{}

  defp close_destination(%{
         assigns: %{live_action: :invite, organization: %Organization{id: id}}
       }),
       do: ~p"/admin/organizations/#{id}"

  defp close_destination(_socket), do: ~p"/admin/organizations"

  defp organization_dom_id(%Organization{id: id}), do: "organization-#{id}"

  # ---------------------------------------------------------------------------
  # Form helpers
  # ---------------------------------------------------------------------------

  defp assign_organization_form(socket, changeset) do
    socket
    |> assign(:organization_form, to_form(changeset))
    |> assign(:organization_name_errors, submitted_errors(changeset, :name))
    |> assign(:organization_alias_errors, submitted_errors(changeset, :alias))
  end

  # The drawer closes by patching back to the index, so the live action that
  # opened it is already gone when the overlay hook restores focus. The trigger
  # is therefore resolved once, when the drawer opens, and kept.
  defp assign_org_drawer_return_focus(socket, :edit) do
    assign(
      socket,
      :org_drawer_return_focus_id,
      "edit-organization-#{socket.assigns.organization.id}"
    )
  end

  defp assign_org_drawer_return_focus(socket, :new) do
    target = if header_create?(socket.assigns), do: "create-organization-trigger"
    assign(socket, :org_drawer_return_focus_id, target)
  end

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
  defp submitted_errors(%Ecto.Changeset{action: action} = changeset, field)
       when action in [:insert, :update],
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
  # Render helpers
  # ---------------------------------------------------------------------------

  defp record_route?(live_action), do: live_action in @record_actions
  defp detail_route?(live_action), do: live_action in @detail_actions

  # Exactly one primary action per state: when an empty state supplies the CTA,
  # the header primary is omitted rather than duplicated.
  defp header_create?(assigns) do
    not (assigns.organizations_state == :ready and assigns.organizations_empty?)
  end

  defp header_invite?(assigns) do
    not (assigns.members_state == :ready and assigns.members_empty?)
  end

  defp record_error_title(:unavailable), do: "Organizations are unavailable right now"
  defp record_error_title(_state), do: "That organization was not found"

  defp deactivation_title(nil), do: "Deactivate user"
  defp deactivation_title(%{user: user}), do: "Deactivate #{user.email}?"

  # ---------------------------------------------------------------------------
  # Forms
  # ---------------------------------------------------------------------------

  attr :form, Phoenix.HTML.Form, required: true
  attr :live_action, :atom, required: true
  attr :name_errors, :list, required: true
  attr :alias_errors, :list, required: true

  defp organization_form(assigns) do
    ~H"""
    <.simple_form
      for={@form}
      id="org-form"
      phx-change="validate_organization"
      phx-submit="save_organization"
    >
      <.input
        field={@form[:name]}
        id="organization-name"
        type="text"
        label="Name"
        maxlength="255"
        errors={@name_errors}
        required
      />
      <.input
        field={@form[:alias]}
        id="organization-alias"
        type="text"
        label="Alias"
        maxlength="255"
        errors={@alias_errors}
        required
        help="Lowercase, with spaces replaced by hyphens."
      />

      <:actions>
        <div class="flex-1"></div>
        <.button variant="quiet" class="min-h-11" patch={~p"/admin/organizations"}>Cancel</.button>
        <.button type="submit" class="min-h-11" phx-disable-with="Saving…">
          {if @live_action == :new, do: "Create organization", else: "Save changes"}
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :email_errors, :list, required: true
  attr :roles_error, :string, default: nil
  attr :base_error, :string, default: nil
  attr :organization, Organization, required: true

  defp invite_form(assigns) do
    assigns = assign(assigns, :selected_roles, assigns.form[:roles].value || [])

    ~H"""
    <p class="mb-6 text-sm text-base-content/70">
      The invitee gets an email with a link to set a password and join {@organization.name}.
    </p>

    <.callout :if={@base_error} id="invite-service-error" kind="error" title={@base_error}>
      Nothing was saved. Correct the details or try again.
    </.callout>

    <.simple_form for={@form} id="invite-form" phx-change="validate_invite" phx-submit="send_invite">
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
        <.button variant="quiet" class="min-h-11" patch={~p"/admin/organizations/#{@organization.id}"}>
          Cancel
        </.button>
        <.button type="submit" class="min-h-11" phx-disable-with="Sending invite…">
          Send invite
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={@user_roles}
    >
      <div id="admin-organizations-page" phx-hook=".InviteErrorFocus">
        <%= if unresolved_record?(assigns) do %>
          <.organization_record_state state={@organization_state} />
        <% else %>
          <%= if detail_route?(@live_action) do %>
            {organization_detail(assigns)}
          <% else %>
            {organization_index(assigns)}
          <% end %>
        <% end %>
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

  defp unresolved_record?(assigns) do
    record_route?(assigns.live_action) and assigns.organization_state != :ready
  end

  # A stable, non-leaking recovery state. The requested identifier is never
  # echoed, so a probed ID is not reflected back into the page.
  attr :state, :atom, required: true

  defp organization_record_state(assigns) do
    ~H"""
    <div id="organization-record-state">
      <.header>
        Organization
        <:subtitle>This organization could not be opened.</:subtitle>
      </.header>

      <div class="mt-6">
        <.callout kind="error" title={record_error_title(@state)}>
          <p :if={@state == :not_found}>
            The link may be out of date, or the organization may have been removed. Nothing was
            changed.
          </p>
          <p :if={@state == :unavailable}>
            The organization could not be loaded because the database is unreachable. Nothing was
            changed.
          </p>
          <div class="mt-3 flex flex-wrap gap-3">
            <.button
              :if={@state == :unavailable}
              id="retry-organization"
              size="sm"
              class="min-h-11"
              phx-click="retry_organization"
              phx-disable-with="Retrying…"
            >
              Retry
            </.button>
            <.button
              id="back-to-organizations"
              variant={if @state == :unavailable, do: "secondary", else: "primary"}
              size="sm"
              class="min-h-11"
              navigate={~p"/admin/organizations"}
            >
              Back to organizations
            </.button>
          </div>
        </.callout>
      </div>
    </div>
    """
  end

  defp organization_detail(assigns) do
    ~H"""
    <.header>
      {@organization.name}
      <:subtitle>Organization</:subtitle>
      <:actions>
        <.button
          id="back-to-organizations"
          variant="secondary"
          class="min-h-11"
          navigate={~p"/admin/organizations"}
        >
          Back to organizations
        </.button>
        <.button
          :if={header_invite?(assigns)}
          id="invite-member-trigger"
          class="min-h-11"
          patch={~p"/admin/organizations/#{@organization.id}/invite"}
        >
          Invite member
        </.button>
      </:actions>
    </.header>

    <div class="mt-6">
      <.list>
        <:item title="Alias">{@organization.alias}</:item>
        <:item title="Organization ID">
          <span id="organization-id" class="font-mono text-sm break-all">{@organization.id}</span>
        </:item>
      </.list>
    </div>

    <section class="mt-10">
      <h2 class="text-base font-semibold">Members</h2>

      <div id="member-action-feedback" class="mt-4 empty:mt-0">
        <.callout
          :if={@member_feedback}
          kind={@member_feedback.kind}
          title={@member_feedback.title}
        />
      </div>

      <div id="members-state" class="mt-4">
        <.callout
          :if={@members_state == :unavailable}
          kind="error"
          title="Members are unavailable right now"
        >
          The member list could not be loaded because the database is unreachable. The organization
          details above are still current, and nothing was changed.
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
          invite_path={~p"/admin/organizations/#{@organization.id}/invite"}
          empty_title="No members yet"
          empty_description={"Invite someone to give them access to #{@organization.name}."}
          invite_label="Invite member"
          resend_event="resend_invite"
          activate_event="activate_user"
          deactivate_event="request_deactivation"
        />
      </div>
    </section>

    <.drawer
      id="invite-drawer"
      open={@live_action == :invite}
      on_close="close_drawer"
      title="Member invitation"
      initial_focus={:first_field}
      initial_focus_id="invite-email"
      return_focus_id={if header_invite?(assigns), do: "invite-member-trigger"}
    >
      <.invite_form
        :if={@live_action == :invite}
        form={@invite_form}
        email_errors={@invite_email_errors}
        roles_error={@invite_roles_error}
        base_error={@invite_base_error}
        organization={@organization}
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
        {@pending_deactivation.user.email} loses access to {@organization.name} and is signed out
        of every web and mobile session immediately. The account is kept and can be activated
        again from this list.
      </span>
    </.confirm_dialog>
    """
  end

  defp organization_index(assigns) do
    ~H"""
    <.header>
      Organizations
      <:subtitle>Manage organizations and their members.</:subtitle>
      <:actions>
        <.button
          :if={header_create?(assigns)}
          id="create-organization-trigger"
          class="min-h-11"
          patch={~p"/admin/organizations/new"}
        >
          Create organization
        </.button>
      </:actions>
    </.header>

    <div id="organization-action-feedback" class="mt-6 empty:mt-0">
      <.callout
        :if={@organization_feedback}
        kind={@organization_feedback.kind}
        title={@organization_feedback.title}
      />
    </div>

    <div id="organizations-state" class="mt-6">
      <.callout
        :if={@organizations_state == :unavailable}
        kind="error"
        title="Organizations are unavailable right now"
      >
        The organization list could not be loaded because the database is unreachable. Nothing was
        changed.
        <div class="mt-3">
          <.button
            id="retry-organizations"
            variant="secondary"
            size="sm"
            class="min-h-11"
            phx-click="retry_organizations"
            phx-disable-with="Retrying…"
          >
            Retry
          </.button>
        </div>
      </.callout>

      <.empty_state
        :if={@organizations_state == :ready and @organizations_empty?}
        id="organizations-empty"
        title="No organizations yet"
      >
        Create the first organization to give its members access to Pathways Studio.
        <:action>
          <.button class="min-h-11" navigate={~p"/admin/organizations/new"}>
            Create organization
          </.button>
        </:action>
      </.empty_state>

      <div
        :if={@organizations_state == :ready and not @organizations_empty?}
        class="rounded-box border border-base-300 bg-base-100 overflow-hidden"
      >
        <.table id="organizations" rows={@streams.organizations} responsive="stack">
          <:col :let={{_id, organization}} label="Name">
            <.link
              navigate={~p"/admin/organizations/#{organization.id}"}
              class="link link-primary font-semibold"
            >
              {organization.name}
            </.link>
          </:col>
          <:col :let={{_id, organization}} label="Alias">
            <span class="font-mono text-sm">{organization.alias}</span>
          </:col>
          <:action :let={{_id, organization}}>
            <.button
              id={"edit-organization-#{organization.id}"}
              variant="quiet"
              size="sm"
              class="min-h-11"
              patch={~p"/admin/organizations/#{organization.id}/edit"}
              aria-label={"Edit #{organization.name}"}
            >
              Edit
            </.button>
          </:action>
        </.table>
      </div>
    </div>

    <.drawer
      id="org-drawer"
      open={@live_action in [:new, :edit]}
      on_close="close_drawer"
      title="Organization"
      initial_focus={:first_field}
      initial_focus_id="organization-name"
      return_focus_id={@org_drawer_return_focus_id}
    >
      <.organization_form
        :if={@live_action in [:new, :edit]}
        form={@organization_form}
        live_action={@live_action}
        name_errors={@organization_name_errors}
        alias_errors={@organization_alias_errors}
      />
    </.drawer>
    """
  end
end
