defmodule GtfsPlannerWeb.Admin.OrganizationsLive do
  @moduledoc """
  LiveView for administrator-only organization management.
  Allows administrators to view all organizations, create new ones,
  and manage organization members.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount {GtfsPlannerWeb.EnsureRole, :require_system_administrator}

  @impl true
  def mount(_params, _session, socket) do
    # user_roles is empty for administrators (they don't have org-scoped roles)
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Organizations")
     |> assign(:invite_form, nil)
     |> assign(:user_roles, user_roles)
     |> stream(:organizations, Organizations.list_organizations())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Organizations")
    |> assign(:organization, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Organization")
    |> assign(:organization, %Organizations.Organization{})
    |> assign_form(%Organizations.Organization{})
  end

  defp apply_action(socket, :show, %{"org_id" => org_id}) do
    organization = Organizations.get_organization!(org_id)
    members = Organizations.list_users_in_organization(org_id)

    socket
    |> assign(:page_title, "Organization Details")
    |> assign(:organization, organization)
    |> assign(:members, members)
  end

  defp apply_action(socket, :edit, %{"org_id" => org_id}) do
    organization = Organizations.get_organization!(org_id)

    socket
    |> assign(:page_title, "Edit Organization")
    |> assign(:organization, organization)
    |> assign_form(organization)
  end

  defp apply_action(socket, :invite, %{"org_id" => org_id}) do
    organization = Organizations.get_organization!(org_id)

    socket
    |> assign(:page_title, "Invite Member")
    |> assign(:organization, organization)
    |> assign_invite_form()
  end

  defp assign_form(socket, %Organizations.Organization{} = org, attrs \\ %{}) do
    changeset = Organizations.change_organization(org, attrs)
    assign(socket, :form, to_form(changeset))
  end

  defp assign_invite_form(socket, attrs \\ %{}) do
    # Ensure roles is always a list (not nil)
    attrs = Map.put_new(attrs, "roles", [])
    assign(socket, :invite_form, to_form(attrs, as: :invite))
  end

  defp available_roles do
    [
      {"Pathways Studio Admin", "pathways_studio_admin"},
      {"Pathways Studio Editor", "pathways_studio_editor"},
      {"Pathways Studio Viewer", "pathways_studio_viewer"}
    ]
  end

  defp humanize_role(role) when is_binary(role) do
    role
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_role(role) when is_atom(role), do: humanize_role(Atom.to_string(role))

  @impl true
  def handle_event("close_drawer", _params, socket) do
    path =
      if socket.assigns.live_action == :invite do
        ~p"/admin/organizations/#{socket.assigns.organization.id}"
      else
        ~p"/admin/organizations"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("validate", %{"organization" => org_params}, socket) do
    changeset =
      socket.assigns.organization
      |> Organizations.change_organization(org_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate_invite", %{"invite" => invite_params}, socket) do
    email = Map.get(invite_params, "email", "")
    email_valid? = Regex.match?(~r/^[^\s]+@[^\s]+$/, email)

    # Normalize roles: ensure it's a list and filter out empty strings
    roles = Map.get(invite_params, "roles", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    invite_params = Map.put(invite_params, "roles", roles)

    form_params =
      if email_valid? do
        invite_params
      else
        invite_params
        |> Map.put("errors", %{"email" => ["Invalid email format"]})
      end

    {:noreply, assign_invite_form(socket, form_params)}
  end

  @impl true
  def handle_event("resend_invite", %{"user-id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    case Accounts.resend_user_invite(user, fn token ->
           url(~p"/users/accept_invite/#{token}")
         end) do
      {:ok, _email} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation resent to #{user.email}")}

      {:error, :already_accepted} ->
        {:noreply,
         socket
         |> put_flash(:error, "User has already accepted their invitation")}
    end
  end

  @impl true
  def handle_event("send_invite", %{"invite" => invite_params}, socket) do
    email =
      invite_params
      |> Map.get("email", "")
      |> String.trim()
      |> String.downcase()

    roles = Map.get(invite_params, "roles", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    # Validate at least one role is selected
    if roles == [] do
      {:noreply,
       assign_invite_form(
         socket,
         Map.put(invite_params, "errors", %{"roles" => ["At least one role is required"]})
       )}
    else
      send_invite_with_roles(socket, email, roles, invite_params)
    end
  end

  @impl true
  def handle_event(
        "save",
        %{"organization" => org_params},
        %{assigns: %{live_action: :new}} = socket
      ) do
    case Organizations.create_organization(org_params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> stream_insert(:organizations, organization)
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Ensure action is set so form errors display
        changeset = Map.put(changeset, :action, :validate)
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event(
        "save",
        %{"organization" => org_params},
        %{assigns: %{live_action: :edit}} = socket
      ) do
    case Organizations.update_organization(socket.assigns.organization, org_params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> stream_insert(:organizations, organization)
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Ensure action is set so form errors display
        changeset = Map.put(changeset, :action, :validate)
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp send_invite_with_roles(socket, email, roles, invite_params) do
    case Accounts.invite_user(email, socket.assigns.organization.id) do
      {:ok, user} ->
        membership_attrs = %{
          user_id: user.id,
          organization_id: socket.assigns.organization.id,
          roles: roles
        }

        case Accounts.create_user_org_membership(membership_attrs) do
          {:ok, _membership} ->
            Accounts.deliver_user_invite(user, &url(~p"/users/accept_invite/#{&1}"))
            members = Organizations.list_users_in_organization(socket.assigns.organization.id)

            {:noreply,
             socket
             |> assign(:members, members)
             |> push_patch(to: ~p"/admin/organizations/#{socket.assigns.organization.id}")}

          {:error, changeset} ->
            {:noreply,
             assign_invite_form(socket, Map.put(invite_params, "errors", changeset.errors))}
        end

      {:error, changeset} ->
        {:noreply, assign_invite_form(socket, Map.put(invite_params, "errors", changeset.errors))}
    end
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :live_action, :atom, required: true

  defp org_form(assigns) do
    ~H"""
    <.simple_form
      for={@form}
      id="org-form"
      phx-change="validate"
      phx-submit="save"
    >
      <.input
        field={@form[:name]}
        type="text"
        label="Name"
        maxlength="255"
        required
      />
      <.input
        field={@form[:alias]}
        type="text"
        label="Alias"
        maxlength="255"
        required
        help="Alias will be auto-formatted: lowercase, spaces become hyphens"
      />
      <:actions>
        <div class="flex-1"></div>
        <.link patch={~p"/admin/organizations"} class="btn btn-ghost">
          Cancel
        </.link>
        <.button phx-disable-with="Saving..." class="btn btn-primary">
          {if @live_action == :new, do: "Create Organization", else: "Update Organization"}
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :available_roles, :list, required: true
  attr :organization, GtfsPlanner.Organizations.Organization, required: true

  defp invite_form(assigns) do
    # Get currently selected roles from the form
    selected_roles = assigns.form[:roles].value || []
    roles_error = get_in(assigns.form[:errors].value, ["roles"]) |> List.wrap() |> List.first()

    assigns =
      assigns
      |> assign(:selected_roles, selected_roles)
      |> assign(:roles_error, roles_error)

    ~H"""
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
        <.link patch={~p"/admin/organizations/#{@organization.id}"} class="btn btn-ghost">
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
    >
      <%= if @live_action == :show && @organization do %>
        <.header>
          {@organization.name}
          <:subtitle>Organization Details</:subtitle>
          <:actions>
            <.link navigate={~p"/admin/organizations"} class="btn btn-outline">
              Back to Organizations
            </.link>
          </:actions>
        </.header>

        <div class="mt-8 space-y-6">
          <div class="bg-base-100 border border-base-300 rounded-lg p-6">
            <.list>
              <:item title="Alias">{@organization.alias}</:item>
              <:item title="ID">{@organization.id}</:item>
            </.list>
          </div>

          <section class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
            <div class="flex items-center justify-between p-4 border-b border-base-300">
              <h2 class="text-base font-semibold">Members</h2>
              <.link
                patch={~p"/admin/organizations/#{@organization.id}/invite"}
                class="btn btn-sm btn-primary btn-active"
              >
                Invite member
              </.link>
            </div>
            <%= if @members == [] do %>
              <p class="text-sm text-base-content/60 p-4">No members yet.</p>
            <% else %>
              <table class="table">
                <thead>
                  <tr>
                    <th>Email</th>
                    <th>Roles</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={member <- @members}>
                    <td>{member.user.email}</td>
                    <td>
                      <div class="flex flex-wrap gap-2">
                        <span :for={role <- member.roles} class="badge badge-sm badge-outline">
                          {humanize_role(role)}
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="flex items-center gap-2 flex-wrap">
                        <button
                          :if={is_nil(member.user.hashed_password)}
                          type="button"
                          class="btn btn-xs"
                          phx-click="resend_invite"
                          phx-value-user-id={member.user.id}
                        >
                          <.icon name="hero-envelope" class="w-3 h-3" /> Resend Invite
                        </button>
                        <button
                          type="button"
                          class="btn btn-xs btn-disabled"
                          disabled
                          title="Coming soon"
                        >
                          <.icon name="hero-no-symbol" class="w-3 h-3" /> De-activate
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>
        </div>
      <% else %>
        <.header>
          Organizations
          <:subtitle>Manage organizations and their members</:subtitle>
          <:actions>
            <.link patch={~p"/admin/organizations/new"} class="btn btn-primary btn-active">
              Create Organization
            </.link>
          </:actions>
        </.header>

        <div class="mt-8 bg-base-100 border border-base-300 rounded-lg overflow-hidden">
          <.table id="organizations" rows={@streams.organizations}>
            <:col :let={{_id, org}} label="Name">{org.name}</:col>
            <:col :let={{_id, org}} label="Alias">{org.alias}</:col>
            <:action :let={{_id, org}}>
              <.link patch={~p"/admin/organizations/#{org.id}/edit"} class="link link-primary">
                Edit
              </.link>
            </:action>
            <:action :let={{_id, org}}>
              <.link navigate={~p"/admin/organizations/#{org.id}"} class="link link-primary">
                View
              </.link>
            </:action>
          </.table>
        </div>

        <.drawer
          id="org-drawer"
          open={@live_action in [:new, :edit, :invite]}
          on_close="close_drawer"
          title={@page_title}
          class="max-w-3xl"
        >
          <%= if @live_action in [:new, :edit] do %>
            <.org_form form={@form} live_action={@live_action} />
          <% end %>
          <%= if @live_action == :invite do %>
            <.invite_form
              form={@invite_form}
              available_roles={available_roles()}
              organization={@organization}
            />
          <% end %>
        </.drawer>
      <% end %>
    </Layouts.app>
    """
  end
end
