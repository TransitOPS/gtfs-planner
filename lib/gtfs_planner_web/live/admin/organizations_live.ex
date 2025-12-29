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
  end

  defp apply_action(socket, :show, %{"org_id" => org_id}) do
    organization = Organizations.get_organization!(org_id)
    members = Organizations.list_users_in_organization(org_id)

    socket
    |> assign(:page_title, "Organization Details")
    |> assign(:organization, organization)
    |> assign(:members, members)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Organizations
        <:subtitle>Manage organizations and their members</:subtitle>
        <:actions>
          <.link navigate={~p"/admin/organizations/new"} class="btn btn-primary">
            Create Organization
          </.link>
        </:actions>
      </.header>

      <%= if @live_action == :index do %>
        <div class="mt-8">
          <div id="organizations" phx-update="stream" class="space-y-4">
            <div :for={{id, org} <- @streams.organizations} id={id} class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h3 class="card-title">{org.name}</h3>
                <p class="text-sm text-gray-600">Alias: {org.alias}</p>
                <div class="card-actions justify-end">
                  <.link navigate={~p"/admin/organizations/#{org.id}"} class="btn btn-sm btn-outline">
                    View Details
                  </.link>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @live_action == :new do %>
        <div class="mt-8">
          <div class="card bg-base-100 shadow-xl max-w-2xl">
            <div class="card-body">
              <h3 class="card-title">Create New Organization</h3>
              <p class="text-sm text-gray-600">
                Organization creation form will be implemented here.
              </p>
              <div class="card-actions justify-end mt-4">
                <.link navigate={~p"/admin/organizations"} class="btn btn-ghost">
                  Cancel
                </.link>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @live_action == :show && @organization do %>
        <div class="mt-8">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title">{@organization.name}</h3>
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

              <div class="card-actions justify-end mt-4">
                <.link navigate={~p"/admin/organizations"} class="btn btn-ghost">
                  Back to Organizations
                </.link>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
