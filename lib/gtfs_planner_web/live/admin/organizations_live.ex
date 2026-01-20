defmodule GtfsPlannerWeb.Admin.OrganizationsLive do
  @moduledoc """
  LiveView for administrator-only organization management.
  Allows administrators to view all organizations, create new ones,
  and manage organization members.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Organizations

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount {GtfsPlannerWeb.EnsureRole, :require_system_administrator}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Organizations")
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

  defp assign_form(socket, %Organizations.Organization{} = org, attrs \\ %{}) do
    changeset = Organizations.change_organization(org, attrs)
    assign(socket, :form, to_form(changeset))
  end

  defp drawer_open?(live_action) when live_action in [:new, :edit], do: true
  defp drawer_open?(_), do: false

  @impl true
  def handle_event("validate", %{"organization" => org_params}, socket) do
    changeset =
      socket.assigns.organization
      |> Organizations.change_organization(org_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"organization" => org_params}, %{assigns: %{live_action: :new}} = socket) do
    case Organizations.create_organization(org_params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> stream_insert(:organizations, organization)
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("save", %{"organization" => org_params}, %{assigns: %{live_action: :edit}} = socket) do
    case Organizations.update_organization(socket.assigns.organization, org_params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> stream_insert(:organizations, organization)
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
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
      <.input field={@form[:name]} type="text" label="Name" maxlength="255" required />
      <.input field={@form[:alias]} type="text" label="Alias" maxlength="255" required />
      <p class="text-sm text-base-content/60">
        Alias will be auto-formatted: lowercase, spaces become hyphens
      </p>
      <:actions>
        <.link patch={~p"/admin/organizations"} class="btn btn-ghost">
          Cancel
        </.link>
        <.button phx-disable-with="Saving..." class="btn btn-primary">
          <%= if @live_action == :new, do: "Create Organization", else: "Update Organization" %>
        </.button>
      </:actions>
    </.simple_form>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <%= if @live_action == :show && @organization do %>
        <.header>
          {@organization.name}
          <:subtitle>Organization Details</:subtitle>
          <:actions>
            <.link navigate={~p"/admin/organizations"} class="btn btn-ghost">
              Back to Organizations
            </.link>
          </:actions>
        </.header>

        <div class="mt-8">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <div class="space-y-2">
                <p><strong>Alias:</strong> {@organization.alias}</p>
                <p><strong>ID:</strong> {@organization.id}</p>
              </div>

              <div class="divider"></div>

              <h4 class="text-lg font-semibold">Members</h4>
              <%= if @members == [] do %>
                <p class="text-sm text-gray-500">No members yet.</p>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table">
                    <thead>
                      <tr>
                        <th>Email</th>
                        <th>Roles</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={member <- @members}>
                        <td>{member.user.email}</td>
                        <td>
                          <div class="flex gap-2">
                            <span :for={role <- member.roles} class="badge badge-sm">
                              {role}
                            </span>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% else %>
        <div class="drawer drawer-end">
          <input id="org-drawer" type="checkbox" class="drawer-toggle" checked={drawer_open?(@live_action)} />
          
          <div class="drawer-content">
            <.header>
              Organizations
              <:subtitle>Manage organizations and their members</:subtitle>
              <:actions>
                <.link patch={~p"/admin/organizations/new"} class="btn btn-primary">
                  Create Organization
                </.link>
              </:actions>
            </.header>

            <div class="mt-8">
              <div id="organizations" phx-update="stream" class="space-y-4">
                <div :for={{id, org} <- @streams.organizations} id={id} class="card bg-base-100 shadow-xl">
                  <div class="card-body">
                    <h3 class="card-title">{org.name}</h3>
                    <p class="text-sm text-base-content/60">Alias: {org.alias}</p>
                    <div class="card-actions justify-end">
                      <.link patch={~p"/admin/organizations/#{org.id}/edit"} class="btn btn-sm btn-outline">
                        Edit
                      </.link>
                      <.link navigate={~p"/admin/organizations/#{org.id}"} class="btn btn-sm btn-outline">
                        View Details
                      </.link>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="drawer-side">
            <label for="org-drawer" aria-label="close sidebar" class="drawer-overlay"></label>
            <div class="bg-base-100 min-h-full max-w-3xl w-full p-4">
              <h3 class="text-lg font-bold mb-4">{@page_title}</h3>
              <%= if @live_action in [:new, :edit] do %>
                <.org_form form={@form} live_action={@live_action} />
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end