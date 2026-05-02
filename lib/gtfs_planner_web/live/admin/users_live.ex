defmodule GtfsPlannerWeb.Admin.UsersLive do
  @moduledoc """
  LiveView for managing users within an organization.
  Requires pathways_studio_admin role.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations

  on_mount {GtfsPlannerWeb.EnsureRole, :require_pathways_studio_admin}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Manage Users")
      |> assign(:invite_form, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    members = Organizations.list_users_in_organization(socket.assigns.current_organization.id)

    socket
    |> assign(:members, members)
    |> assign(:invite_form, nil)
  end

  defp apply_action(socket, :invite, _params) do
    members = Organizations.list_users_in_organization(socket.assigns.current_organization.id)

    socket
    |> assign(:members, members)
    |> assign_invite_form(%{})
  end

  defp apply_action(socket, :show, _params) do
    members = Organizations.list_users_in_organization(socket.assigns.current_organization.id)

    socket
    |> assign(:members, members)
    |> assign(:invite_form, nil)
  end

  defp apply_action(socket, :organization_settings, _params) do
    members = Organizations.list_users_in_organization(socket.assigns.current_organization.id)

    organization_form =
      socket.assigns.current_organization
      |> Organizations.change_organization()
      |> to_form()

    socket
    |> assign(:members, members)
    |> assign(:invite_form, nil)
    |> assign(:organization_form, organization_form)
  end

  # Helper functions (Step 9)

  defp available_roles do
    [
      {"Pathways Studio Admin", "pathways_studio_admin"},
      {"Pathways Studio Editor", "pathways_studio_editor"}
    ]
  end

  defp humanize_role(role) do
    case role do
      "pathways_studio_admin" -> "Pathways Studio Admin"
      "pathways_studio_editor" -> "Pathways Studio Editor"
      "administrator" -> "Administrator"
      _ -> role
    end
  end

  defp assign_invite_form(socket, params) do
    form = Phoenix.Component.to_form(params, as: :invite)
    assign(socket, :invite_form, form)
  end

  defp allowed_org_params(params), do: Map.take(params, ["name"])

  # Event handlers (Steps 11-15)

  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/users")}
  end

  @impl true
  def handle_event("validate_organization", %{"organization" => org_params}, socket) do
    changeset =
      socket.assigns.current_organization
      |> Organizations.change_organization(allowed_org_params(org_params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :organization_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_organization", %{"organization" => org_params}, socket) do
    case Organizations.update_organization(
           socket.assigns.current_organization,
           allowed_org_params(org_params)
         ) do
      {:ok, organization} ->
        socket =
          socket
          |> assign(:current_organization, organization)
          |> put_flash(:info, "Organization updated successfully")
          |> push_patch(to: ~p"/admin/users")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :organization_form, to_form(%{changeset | action: :validate}))}
    end
  end

  @impl true
  def handle_event("validate_invite", %{"invite" => invite_params}, socket) do
    # Validate email format
    email = Map.get(invite_params, "email", "")
    email_valid? = Regex.match?(~r/^[^\s]+@[^\s]+$/, email)

    # Normalize roles to list, filter empty strings
    roles =
      invite_params
      |> Map.get("roles", %{})
      |> case do
        roles when is_map(roles) -> Map.values(roles)
        roles when is_list(roles) -> roles
        _ -> []
      end
      |> Enum.filter(&(&1 != ""))

    validated_params =
      invite_params
      |> Map.put("email", email)
      |> Map.put("roles", roles)
      |> Map.put("email_valid?", email_valid?)

    {:noreply, assign_invite_form(socket, validated_params)}
  end

  @impl true
  def handle_event("send_invite", %{"invite" => invite_params}, socket) do
    email = Map.get(invite_params, "email", "")

    # Normalize roles to list, filter empty strings
    roles =
      invite_params
      |> Map.get("roles", %{})
      |> case do
        roles when is_map(roles) -> Map.values(roles)
        roles when is_list(roles) -> roles
        _ -> []
      end
      |> Enum.filter(&(&1 != ""))

    # Validate at least one role is selected
    if Enum.empty?(roles) do
      params_with_error = Map.put(invite_params, "error", "At least one role must be selected")
      {:noreply, assign_invite_form(socket, params_with_error)}
    else
      case Accounts.invite_user(email, socket.assigns.current_organization.id) do
        {:ok, user} ->
          # Create or update user org membership
          membership_attrs = %{
            user_id: user.id,
            organization_id: socket.assigns.current_organization.id,
            roles: roles
          }

          case Accounts.create_user_org_membership(membership_attrs) do
            {:ok, _membership} ->
              # Send invitation email
              Accounts.deliver_user_invite(user, &url(~p"/users/accept_invite/#{&1}"))

              # Refresh members list and close drawer
              members =
                Organizations.list_users_in_organization(socket.assigns.current_organization.id)

              socket =
                socket
                |> assign(:members, members)
                |> put_flash(:info, "User invited successfully")
                |> push_patch(to: ~p"/admin/users")

              {:noreply, socket}

            {:error, _changeset} ->
              params_with_error = Map.put(invite_params, "error", "Failed to create membership")
              {:noreply, assign_invite_form(socket, params_with_error)}
          end

        {:error, reason} ->
          error_message =
            case reason do
              :invalid_email -> "Invalid email address"
              _ -> "Failed to invite user"
            end

          params_with_error = Map.put(invite_params, "error", error_message)
          {:noreply, assign_invite_form(socket, params_with_error)}
      end
    end
  end

  @impl true
  def handle_event("resend_invite", %{"user-id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    case Accounts.deliver_user_invite(user, &url(~p"/users/accept_invite/#{&1}")) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Invitation email resent")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to resend invitation")}
    end
  end

  @impl true
  def handle_event("deactivate", %{"user-id" => user_id}, socket) do
    case Organizations.deactivate_user_in_organization(
           user_id,
           socket.assigns.current_organization.id
         ) do
      {:ok, _} ->
        # Refresh members list
        members = Organizations.list_users_in_organization(socket.assigns.current_organization.id)

        socket =
          socket
          |> assign(:members, members)
          |> put_flash(:info, "User deactivated")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to deactivate user")}
    end
  end

  @impl true
  def handle_event("activate", %{"user-id" => user_id}, socket) do
    case Organizations.activate_user_in_organization(
           user_id,
           socket.assigns.current_organization.id
         ) do
      {:ok, _} ->
        # Refresh members list
        members = Organizations.list_users_in_organization(socket.assigns.current_organization.id)

        socket =
          socket
          |> assign(:members, members)
          |> put_flash(:info, "User activated")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to activate user")}
    end
  end

  # Organization settings form component (Step 6)

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
        type="text"
        label="Organization name"
        maxlength="255"
        required
      />

      <:actions>
        <div class="flex-1"></div>
        <.link patch={~p"/admin/users"} class="btn btn-ghost">
          Cancel
        </.link>
        <.button phx-disable-with="Saving..." class="btn btn-primary">
          Save changes
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  # Invite form component (Step 10)

  attr :form, :any, required: true
  attr :available_roles, :list, required: true
  attr :organization, :map, required: true

  defp invite_form(assigns) do
    # Get currently selected roles from the form
    selected_roles = assigns.form[:roles].value || []
    roles_error = assigns.form[:error].value

    assigns =
      assigns
      |> assign(:selected_roles, selected_roles)
      |> assign(:roles_error, roles_error)

    ~H"""
    <p class="text-sm text-base-content/70 mb-6">
      Send an invitation to join {@organization.name}
    </p>

    <.simple_form
      for={@form}
      id="invite-form"
      phx-change="validate_invite"
      phx-submit="send_invite"
    >
      <.input
        field={@form[:email]}
        type="email"
        label="Email"
        placeholder="user@example.com"
        required
      />

      <.checkbox_group
        name="invite[roles][]"
        label="Roles"
        options={@available_roles}
        selected={@selected_roles}
        required
        error={@roles_error}
      />

      <:actions>
        <div class="flex-1"></div>
        <.link patch={~p"/admin/users"} class="btn btn-ghost">
          Cancel
        </.link>
        <.button phx-disable-with="Sending..." class="btn btn-primary">
          Send Invite
        </.button>
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
      <.header>
        Users
        <:subtitle>Manage users in {@current_organization.name}</:subtitle>
        <:actions>
          <.link patch={~p"/admin/users/organization-settings"} class="btn btn-ghost">
            Organization settings
          </.link>
          <.link patch={~p"/admin/users/invite"} class="btn btn-primary btn-active">
            Invite User
          </.link>
        </:actions>
      </.header>

      <div class="mt-8">
        <div class="overflow-x-auto">
          <table class="table w-full bg-base-100">
            <thead>
              <tr>
                <th>Email</th>
                <th>Roles</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={member <- @members} id={"user-#{member.user.id}"}>
                <td>{member.user.email}</td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={role <- member.roles}
                      class="badge badge-sm badge-outline"
                    >
                      {humanize_role(role)}
                    </span>
                  </div>
                </td>
                <td>
                  <%= if member.deactivated_at do %>
                    <span class="badge badge-outline badge-error">Deactivated</span>
                  <% else %>
                    <span class="badge badge-outline badge-accent">Active</span>
                  <% end %>
                </td>
                <td>
                  <div class="flex gap-2">
                    <%= if is_nil(member.user.hashed_password) do %>
                      <button
                        phx-click="resend_invite"
                        phx-value-user-id={member.user.id}
                        class="btn btn-sm btn-ghost"
                      >
                        Resend Invite
                      </button>
                    <% end %>
                    <%= if member.deactivated_at do %>
                      <button
                        phx-click="activate"
                        phx-value-user-id={member.user.id}
                        class="btn btn-sm btn-ghost"
                      >
                        Activate
                      </button>
                    <% else %>
                      <button
                        phx-click="deactivate"
                        phx-value-user-id={member.user.id}
                        class="btn btn-sm btn-ghost"
                      >
                        Deactivate
                      </button>
                    <% end %>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <.drawer
        id="invite-drawer"
        open={@live_action == :invite}
        on_close="close_drawer"
        title="Invite User"
        class="max-w-3xl"
      >
        <%= if @invite_form do %>
          <.invite_form
            form={@invite_form}
            available_roles={available_roles()}
            organization={@current_organization}
          />
        <% end %>
      </.drawer>

      <.drawer
        id="organization-settings-drawer"
        open={@live_action == :organization_settings}
        on_close="close_drawer"
        title="Organization settings"
        class="max-w-3xl"
      >
        <.organization_settings_form
          :if={@live_action == :organization_settings}
          form={@organization_form}
        />
      </.drawer>
    </Layouts.app>
    """
  end
end
