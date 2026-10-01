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
  server-side identity reaches `Organizations.deactivate_user_in_organization/3`.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.InviteForm
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlannerWeb.Admin.Components
  alias GtfsPlannerWeb.ProductSurfaces

  import GtfsPlannerWeb.Admin.InviteFormState,
    only: [assign_invite_form: 2, invitation_detail: 1, normalize_invite_params: 1]

  import GtfsPlannerWeb.PlannerComponents,
    only: [
      back_link: 1,
      choice_cards: 1,
      drawer_footer: 1,
      first_use: 1,
      form_error_summary: 1,
      message: 1
    ]

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount {GtfsPlannerWeb.EnsureRole, :require_system_administrator}

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
      |> assign(:member_counts, nil)
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
        |> assign(:page_title, "Invite member")
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
        |> assign(:member_counts, Components.count_members(members))

      {:error, :unavailable} ->
        socket
        |> stream(:members, [], reset: true)
        |> assign(:members_empty?, false)
        |> assign(:members_state, :unavailable)
        |> assign(:member_counts, nil)
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

  defp put_organization_feedback(socket, kind, title, detail \\ nil) do
    assign(socket, :organization_feedback, %{kind: kind, title: title, detail: detail})
  end

  defp refuse_stale(socket) do
    socket
    |> assign(:pending_deactivation, nil)
    |> put_feedback(
      "error",
      "That member is no longer in this organization.",
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
      "The member list is unavailable right now.",
      "Nothing was changed. Try again in a moment.",
      nil
    )
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
    {:noreply, socket |> assign(:member_feedback, nil) |> load_members()}
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
         |> push_patch(to: ~p"/admin/organizations/#{organization.id}")}

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
         |> push_patch(to: ~p"/admin/organizations/#{organization.id}")}

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
         |> push_patch(to: ~p"/admin/organizations/#{organization.id}")}

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
         |> push_patch(to: ~p"/admin/organizations/#{organization.id}")}

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
             socket.assigns.organization.id,
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
             socket.assigns.organization.id
           ) do
        {:ok, _membership} ->
          socket
          |> put_feedback(
            "success",
            "#{member.user.email} activated.",
            "They can sign in to #{socket.assigns.organization.name} again.",
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
           socket.assigns.organization.id
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
  # Organization command helpers
  # ---------------------------------------------------------------------------

  defp save_organization(socket, :new, params) do
    case Organizations.create_organization(socket.assigns.current_user, params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_organization_feedback(
           "success",
           "#{organization.name} created.",
           "Open it from the list to invite its first administrator, so someone can sign in."
         )
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, :forbidden} ->
        {:noreply,
         refuse_organization(
           socket,
           params,
           "Your system administrator access has changed.",
           "The organization was not created. Ask a current system administrator to create it."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, reject_organization(socket, changeset, :insert)}
    end
  end

  defp save_organization(socket, :edit, params) do
    case Organizations.update_organization(
           socket.assigns.current_user,
           socket.assigns.organization,
           params
         ) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:organization, organization)
         |> put_organization_feedback("success", "#{organization.name} updated.")
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, :forbidden} ->
        {:noreply,
         refuse_organization(
           socket,
           params,
           "Your system administrator access has changed.",
           "The organization was not changed. Ask a current system administrator to change it."
         )}

      {:error, :not_found} ->
        {:noreply,
         refuse_organization(
           socket,
           params,
           "That organization no longer exists.",
           "Nothing was changed. Close this drawer to return to the list."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, reject_organization(socket, changeset, :update)}
    end
  end

  # A refused write keeps the drawer open with what was typed and says why
  # nothing was saved; focus moves to that message.
  defp refuse_organization(socket, params, title, detail) do
    draft =
      socket
      |> organization_subject()
      |> Organizations.change_organization(params)

    socket
    |> assign_organization_form(draft)
    |> assign(:organization_refusal, %{title: title, detail: detail})
    |> push_event("focus_form_error", %{
      form_id: "org-form",
      fallback_id: "organization-refusal"
    })
  end

  # A rejected save lists its problems in a summary and moves focus to the first
  # invalid field.
  defp reject_organization(socket, changeset, action) do
    socket
    |> assign_organization_form(Map.put(changeset, :action, action))
    |> push_event("focus_form_error", %{form_id: "org-form"})
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
    form = to_form(changeset)
    name_errors = organization_errors(form, changeset, :name)
    alias_errors = organization_errors(form, changeset, :alias)

    socket
    |> assign(:organization_form, form)
    |> assign(:organization_refusal, nil)
    |> assign(:organization_name_errors, name_errors)
    |> assign(:organization_alias_errors, alias_errors)
    |> assign(
      :organization_failures,
      organization_failures(changeset, name_errors, alias_errors)
    )
  end

  # On submit the errors are authoritative and always shown. While changing, a
  # field shows its errors once the person has used it.
  defp organization_errors(form, %Ecto.Changeset{action: action} = changeset, field) do
    if action in [:insert, :update] or used_input?(form[field]) do
      for {^field, error} <- changeset.errors,
          do: Components.organization_error_message(field, error)
    else
      []
    end
  end

  # The summary lists a rejected submit, once, with a link to each field. Live
  # validation is not a rejection and never produces one.
  defp organization_failures(%Ecto.Changeset{action: action}, name_errors, alias_errors)
       when action in [:insert, :update] do
    [
      {List.first(name_errors), "#organization-name"},
      {List.first(alias_errors), "#organization-alias"}
    ]
    |> Enum.filter(fn {message, _href} -> message end)
    |> Enum.map(fn {message, href} -> %{href: href, msg: message} end)
  end

  defp organization_failures(_changeset, _name_errors, _alias_errors), do: []

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
    target =
      if header_create?(socket.assigns),
        do: "create-organization-trigger",
        else: "organizations-empty-create"

    assign(socket, :org_drawer_return_focus_id, target)
  end

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

  defp org_drawer_title(:edit), do: "Edit organization"
  defp org_drawer_title(_live_action), do: "New organization"

  defp failures_title(:edit, [_one]), do: "Changes not saved. Fix this field:"
  defp failures_title(:edit, _failures), do: "Changes not saved. Fix these fields:"
  defp failures_title(_new, [_one]), do: "Organization not created. Fix this field:"
  defp failures_title(_new, _failures), do: "Organization not created. Fix these fields:"

  defp product_options do
    for product <- [:planner, :pathways] do
      %{
        value: Atom.to_string(product),
        label: ProductSurfaces.name(product),
        description: ProductSurfaces.description(product)
      }
    end
  end

  defp section_title_class,
    do: "font-display text-[24px] font-semibold tracking-[-0.025em] text-strong"

  # ---------------------------------------------------------------------------
  # Forms
  # ---------------------------------------------------------------------------

  attr :form, Phoenix.HTML.Form, required: true
  attr :live_action, :atom, required: true
  attr :name_errors, :list, required: true
  attr :alias_errors, :list, required: true
  attr :failures, :list, required: true
  attr :refusal, :map, default: nil

  defp organization_form(assigns) do
    assigns = assign(assigns, :product, to_string(assigns.form[:product].value))

    ~H"""
    <.form
      for={@form}
      id="org-form"
      novalidate
      phx-change="validate_organization"
      phx-submit="save_organization"
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="grid flex-1 content-start gap-5 overflow-y-auto px-5 py-5 sm:px-6">
        <.message
          :if={@refusal}
          id="organization-refusal"
          tabindex="-1"
          kind="error"
          title={@refusal.title}
        >
          {@refusal.detail}
        </.message>

        <.form_error_summary
          id="org-error-summary"
          title={failures_title(@live_action, @failures)}
          failures={@failures}
          class=""
        />

        <.input
          field={@form[:name]}
          id="organization-name"
          type="text"
          label="Name"
          help="Shown beside the logo in the header for everyone in this organization."
          maxlength="255"
          autocomplete="off"
          errors={@name_errors}
          required
        />

        <.input
          field={@form[:alias]}
          id="organization-alias"
          type="text"
          label="Alias"
          help="A short name that no other organization uses. Saved in lowercase, with spaces replaced by hyphens."
          maxlength="255"
          autocomplete="off"
          spellcheck="false"
          errors={@alias_errors}
          required
        />

        <.choice_cards
          id="organization-product"
          type="radio"
          name={@form[:product].name}
          label="Product"
          help="Sets the logo and which pages members see. Changing it later removes no data."
          options={product_options()}
          selected={[@product]}
        />
      </div>

      <.drawer_footer>
        <.button variant="secondary" class="min-h-11" patch={~p"/admin/organizations"}>
          Cancel
        </.button>
        <.button type="submit" class="min-h-11 min-w-[168px]" phx-disable-with="Saving…">
          {if @live_action == :new, do: "Create organization", else: "Save changes"}
        </.button>
      </.drawer_footer>
    </.form>
    """
  end

  # A region that could not be read: what failed, that nothing changed, and one
  # way to try again.
  attr :title, :string, required: true
  attr :retry_id, :string, required: true
  attr :retry_event, :string, required: true
  slot :inner_block, required: true

  defp region_unavailable(assigns) do
    ~H"""
    <div class="grid gap-4 rounded-card border border-subtle bg-white p-5">
      <.message kind="error" title={@title}>{render_slot(@inner_block)}</.message>
      <div>
        <.button
          id={@retry_id}
          variant="secondary"
          class="min-h-11"
          phx-click={@retry_event}
          phx-disable-with="Retrying…"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Retry loading
        </.button>
      </div>
    </div>
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
      <div id="admin-organizations-page" phx-hook="FormErrorFocus">
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

      <div class="mt-2 max-w-[820px]">
        <.message kind="error" title={record_error_title(@state)}>
          <span :if={@state == :not_found}>
            The link may be out of date, or the organization may have been removed. Nothing was
            changed.
          </span>
          <span :if={@state == :unavailable}>
            The organization could not be loaded because the database is unreachable. Nothing was
            changed.
          </span>
        </.message>

        <div class="mt-5 flex flex-wrap gap-3">
          <.button
            :if={@state == :unavailable}
            id="retry-organization"
            class="min-h-11"
            phx-click="retry_organization"
            phx-disable-with="Retrying…"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Retry loading
          </.button>
          <.button
            id="back-to-organizations"
            variant={if @state == :unavailable, do: "secondary", else: "primary"}
            class="min-h-11"
            navigate={~p"/admin/organizations"}
          >
            Back to organizations
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp organization_detail(assigns) do
    ~H"""
    <.back_link id="back-to-organizations" navigate={~p"/admin/organizations"}>
      Organizations
    </.back_link>

    <.header>
      {@organization.name}
      <:subtitle>Manage who can sign in and what each person can do.</:subtitle>
      <:actions>
        <.button
          :if={header_invite?(assigns)}
          id="invite-member-trigger"
          class="min-h-11"
          patch={~p"/admin/organizations/#{@organization.id}/invite"}
        >
          <.icon name="hero-plus" class="size-4" /> Invite member
        </.button>
      </:actions>
    </.header>

    <div class="mt-6 grid gap-10">
      <section aria-labelledby="members-title" class="min-w-0">
        <h2 id="members-title" class={section_title_class()}>Members</h2>

        <div id="member-action-feedback" class="mt-4 empty:mt-0">
          <.message
            :if={@member_feedback}
            kind={@member_feedback.kind}
            title={@member_feedback.title}
          >
            {@member_feedback.detail}
          </.message>
        </div>

        <div id="members-state" class="mt-4">
          <.region_unavailable
            :if={@members_state == :unavailable}
            title="Members are unavailable right now"
            retry_id="retry-members"
            retry_event="retry_members"
          >
            The member list could not load because the database is unreachable. The organization
            details are still current, and nothing was changed.
          </.region_unavailable>

          <Components.member_data_view
            :if={@members_state == :ready}
            id="members"
            members={@streams.members}
            empty?={@members_empty?}
            counts={@member_counts}
            marked_id={@member_feedback && @member_feedback.user_id}
            noun="member"
            invite_path={~p"/admin/organizations/#{@organization.id}/invite"}
            empty_title="No members yet"
            empty_icon="hero-users"
            empty_description={"Invite an administrator first so #{@organization.name} can manage its own people. Choose Editor as well if they also edit feed data."}
            invite_label="Invite member"
            resend_event="resend_invite"
            activate_event="activate_user"
            deactivate_event="request_deactivation"
          />
        </div>
      </section>

      <section aria-labelledby="organization-details-title" class="min-w-0">
        <h2 id="organization-details-title" class={section_title_class()}>
          Organization details
        </h2>
        <div class="mt-4 overflow-clip rounded-card border border-subtle bg-white">
          <dl class="text-sm">
            <div class="grid gap-x-6 gap-y-0.5 px-5 py-3 sm:grid-cols-[190px_minmax(0,1fr)]">
              <dt class="text-muted">Product</dt>
              <dd class="text-strong">
                <span class="font-semibold">{ProductSurfaces.name(@organization.product)}</span>
                <span class="mt-0.5 block max-w-[62ch] text-[13px] leading-snug text-muted">
                  {ProductSurfaces.description(@organization.product)}
                </span>
              </dd>
            </div>
            <div class="grid gap-x-6 gap-y-0.5 border-t border-subtle px-5 py-3 sm:grid-cols-[190px_minmax(0,1fr)]">
              <dt class="text-muted">Alias</dt>
              <dd class="break-all font-mono text-[13px] text-strong">{@organization.alias}</dd>
            </div>
            <div class="grid gap-x-6 gap-y-0.5 border-t border-subtle px-5 py-3 sm:grid-cols-[190px_minmax(0,1fr)]">
              <dt class="text-muted">Organization ID</dt>
              <dd class="break-all font-mono text-[13px] text-strong">
                <span id="organization-id" class="font-mono">{@organization.id}</span>
              </dd>
            </div>
          </dl>
        </div>
      </section>
    </div>

    <.drawer
      id="invite-drawer"
      chrome="planner"
      open={@live_action == :invite}
      on_close="close_drawer"
      title="Invite member"
      class="max-w-[480px]"
      initial_focus={:first_field}
      initial_focus_id="invite-email"
      return_focus_id={if header_invite?(assigns), do: "invite-member-trigger"}
    >
      <:lede>
        They get an email with a link to set a password and join {@organization.name}.
        The link works for 7 days.
      </:lede>
      <Components.invite_form
        :if={@live_action == :invite}
        form={@invite_form}
        email_errors={@invite_email_errors}
        roles_error={@invite_roles_error}
        base_error={@invite_base_error}
        failures={@invite_failures}
        cancel_path={~p"/admin/organizations/#{@organization.id}"}
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
        {Components.deactivation_body(@pending_deactivation, @organization)}
      </span>
    </.confirm_dialog>
    """
  end

  defp organization_index(assigns) do
    ~H"""
    <.header>
      Organizations
      <:subtitle>
        Create an organization for each agency you support, then invite its first administrator.
      </:subtitle>
      <:actions>
        <.button
          :if={header_create?(assigns)}
          id="create-organization-trigger"
          class="min-h-11"
          patch={~p"/admin/organizations/new"}
        >
          <.icon name="hero-plus" class="size-4" /> Create organization
        </.button>
      </:actions>
    </.header>

    <div id="organization-action-feedback" class="mt-6 empty:mt-0">
      <%= if @organization_feedback && @organization_feedback.detail do %>
        <.message kind={@organization_feedback.kind} title={@organization_feedback.title}>
          {@organization_feedback.detail}
        </.message>
      <% end %>
      <%= if @organization_feedback && !@organization_feedback.detail do %>
        <.message kind={@organization_feedback.kind} title={@organization_feedback.title} />
      <% end %>
    </div>

    <div id="organizations-state" class="mt-6">
      <.region_unavailable
        :if={@organizations_state == :unavailable}
        title="Organizations are unavailable right now"
        retry_id="retry-organizations"
        retry_event="retry_organizations"
      >
        The list could not load because the database is unreachable. Nothing was changed. Try
        again in a moment.
      </.region_unavailable>

      <.first_use
        :if={@organizations_state == :ready and @organizations_empty?}
        id="organizations-empty"
        title="No organizations yet"
        icon="hero-building-office-2"
      >
        An organization is a separate workspace with its own feed data and members. Create the
        first one, then invite its administrator.
        <:action>
          <.button
            id="organizations-empty-create"
            class="min-h-11"
            patch={~p"/admin/organizations/new"}
          >
            <.icon name="hero-plus" class="size-4" /> Create organization
          </.button>
        </:action>
      </.first_use>

      <section
        :if={@organizations_state == :ready and not @organizations_empty?}
        aria-label="Organizations"
        class="overflow-clip rounded-card border border-subtle bg-white"
      >
        <table class="w-full border-collapse text-left text-sm max-md:block">
          <caption class="sr-only">Organizations</caption>
          <thead class="max-md:hidden">
            <tr>
              <th scope="col" class={[Components.table_head_class(), "pl-5 pr-4"]}>Organization</th>
              <th scope="col" class={[Components.table_head_class(), "w-[96px] px-4"]}>
                <span class="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody id="organizations" phx-update="stream" class="max-md:block">
            <tr
              :for={{id, organization} <- @streams.organizations}
              id={id}
              class="border-b border-subtle last:border-b-0 hover:bg-canvas max-md:relative max-md:block max-md:px-4 max-md:py-2"
            >
              <th
                scope="row"
                data-label="Organization"
                class="py-1 pl-5 pr-4 text-left align-middle font-normal max-md:block max-md:p-0 max-md:pr-16"
              >
                <span class="flex flex-wrap items-baseline gap-x-3">
                  <.link
                    navigate={~p"/admin/organizations/#{organization.id}"}
                    class="inline-flex min-h-11 max-w-full items-center font-semibold text-strong underline decoration-subtle decoration-1 underline-offset-4 [overflow-wrap:anywhere] hover:decoration-strong"
                  >
                    {organization.name}
                  </.link>
                  <span class="font-mono text-[13px] text-muted [overflow-wrap:anywhere]">
                    {organization.alias}
                  </span>
                </span>
              </th>
              <td class="px-4 py-1 text-right align-middle max-md:absolute max-md:right-2 max-md:top-2 max-md:p-0">
                <.button
                  id={"edit-organization-#{organization.id}"}
                  variant="quiet"
                  class="min-h-11 px-3"
                  patch={~p"/admin/organizations/#{organization.id}/edit"}
                  aria-label={"Edit #{organization.name}"}
                >
                  Edit
                </.button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>

    <.drawer
      id="org-drawer"
      chrome="planner"
      open={@live_action in [:new, :edit]}
      on_close="close_drawer"
      title={org_drawer_title(@live_action)}
      class="max-w-[480px]"
      initial_focus={:first_field}
      initial_focus_id="organization-name"
      return_focus_id={@org_drawer_return_focus_id}
    >
      <:lede :if={@live_action != :edit}>
        A separate workspace with its own members, product and feed data. It starts with one
        empty version.
      </:lede>
      <:lede :if={@live_action == :edit and @organization}>{@organization.name}</:lede>
      <.organization_form
        :if={@live_action in [:new, :edit]}
        form={@organization_form}
        live_action={@live_action}
        name_errors={@organization_name_errors}
        alias_errors={@organization_alias_errors}
        failures={@organization_failures}
        refusal={@organization_refusal}
      />
    </.drawer>
    """
  end
end
