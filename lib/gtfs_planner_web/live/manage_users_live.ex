defmodule GtfsPlannerWeb.ManageUsersLive do
  @moduledoc """
  LiveView for managing users in an organization.
  Allows administrators to invite users, remove users, and update roles.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-12">
      <div>
        <.header>
          Manage Users
          <:subtitle>Manage users and their roles in {@organization.name}.</:subtitle>
        </.header>

        <div class="space-y-12 max-w-4xl">
          <div>
            <.header>
              Invite User
              <:subtitle>Send an invitation to join this organization.</:subtitle>
            </.header>

            <.simple_form
              for={@invite_form}
              id="invite_form"
              phx-submit="invite_user"
              phx-change="validate_invite"
            >
              <.input
                field={@invite_form[:email]}
                type="email"
                label="Email address"
                placeholder="user@example.com"
                required
              />

              <:actions>
                <.button phx-disable-with="Sending...">Send Invitation</.button>
              </:actions>
            </.simple_form>
          </div>

          <div>
            <.header>
              Users
              <:subtitle>Manage organization members and their roles.</:subtitle>
            </.header>

            <div id="users" phx-update="stream">
              <div :for={{id, user_data} <- @streams.users} id={id} class="space-y-4">
                <div class="bg-base-200 rounded-lg p-4 shadow-sm">
                  <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
                    <div class="flex-1">
                      <p class="font-medium text-lg">{user_data.user.email}</p>
                      <p class="text-sm text-base-content/70">
                        Roles: {format_roles(user_data.roles)}
                      </p>
                    </div>

                    <div class="flex items-center gap-2">
                      <button
                        type="button"
                        class="btn btn-sm"
                        phx-click="update_roles"
                        phx-value-user-id={user_data.user.id}
                      >
                        <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> Edit Roles
                      </button>

                      <button
                        type="button"
                        class="btn btn-sm btn-error"
                        phx-click="remove_user"
                        phx-value-user-id={user_data.user.id}
                        phx-confirm="Are you sure you want to remove this user from the organization?"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" /> Remove
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div :if={Enum.empty?(@streams.users)} class="text-center py-12 text-base-content/70">
                <.icon name="hero-users" class="w-16 h-16 mx-auto mb-4 opacity-50" />
                <p class="text-lg">No users in this organization yet</p>
                <p class="text-sm">Invite users to get started</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.current_organization

    if organization do
      users = Organizations.list_users_in_organization(organization.id)

      socket =
        socket
        |> assign(:organization, organization)
        |> stream(:users, users, key: fn %{user: user} -> user.id end)
        |> assign(:invite_form, to_form(%{"email" => ""}))
        |> assign(:role_form, to_form(%{"roles" => []}))

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("invite_user", %{"email" => email}, socket) do
    organization = socket.assigns.current_organization

    case Accounts.invite_user(email, organization.id) do
      {:ok, user} ->
        # Send invitation email
        Accounts.deliver_user_invite(user, fn token ->
          url(~p"/users/accept_invite/#{token}")
        end)

        # Add user to organization
        case Organizations.add_user_to_organization(user.id, organization.id, []) do
          {:ok, _membership} ->
            # Refresh the user list
            users = Organizations.list_users_in_organization(organization.id)

            socket =
              socket
              |> stream(:users, users, reset: true)
              |> put_flash(:info, "Invitation sent to #{email}")
              |> assign(:invite_form, to_form(%{"email" => ""}))

            {:noreply, socket}

          {:error, _changeset} ->
            socket =
              socket
              |> put_flash(:error, "Failed to add user to organization")

            {:noreply, socket}
        end

      {:error, changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to invite user: #{inspect(changeset.errors)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    organization = socket.assigns.current_organization
    current_user_id = socket.assigns.current_user.id

    # Prevent removing yourself
    if user_id == current_user_id do
      socket =
        socket
        |> put_flash(:error, "You cannot remove yourself from the organization")

      {:noreply, socket}
    else
      case Organizations.remove_user_from_organization(user_id, organization.id) do
        {:ok, _membership} ->
          # Remove from stream
          socket =
            socket
            |> stream_delete(:users, user_id)
            |> put_flash(:info, "User removed from organization")

          {:noreply, socket}

        {:error, :not_found} ->
          socket =
            socket
            |> put_flash(:error, "User not found in organization")

          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("update_roles", %{"user_id" => user_id, "roles" => roles_params}, socket) do
    organization = socket.assigns.current_organization

    # Parse roles from checkbox form
    roles =
      roles_params
      |> Enum.filter(fn {_role, value} -> value == "true" end)
      |> Enum.map(fn {role, _value} -> role end)

    case Organizations.update_user_roles(user_id, organization.id, roles) do
      {:ok, _membership} ->
        # Refresh the user list to show updated roles
        users = Organizations.list_users_in_organization(organization.id)

        socket =
          socket
          |> stream(:users, users, reset: true)
          |> put_flash(:info, "User roles updated")

        {:noreply, socket}

      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, "User not found in organization")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate_invite", %{"email" => _email}, socket) do
    {:noreply, socket}
  end

  defp format_roles([]), do: "No roles"
  defp format_roles(roles), do: Enum.join(roles, ", ")
end
