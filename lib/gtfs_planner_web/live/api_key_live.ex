defmodule GtfsPlannerWeb.ApiKeyLive do
  @moduledoc """
  LiveView for managing API keys in an organization.
  Allows administrators to create and delete API keys.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Organizations

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-12">
      <div>
        <.header>
          API Keys
          <:subtitle>Manage API keys for {@organization.name}.</:subtitle>
        </.header>

        <div class="space-y-12 max-w-4xl">
          <div>
            <.header>
              Create API Key
              <:subtitle>Generate a new API key for programmatic access.</:subtitle>
            </.header>

            <.simple_form for={@form} id="api_key_form" phx-submit="create">
              <.input
                field={@form[:description]}
                type="text"
                label="Description"
                placeholder="e.g., Production API key"
                required
              />

              <.input
                field={@form[:roles]}
                type="select"
                label="Roles"
                multiple
                options={@role_options}
              />

              <:actions>
                <.button phx-disable-with="Creating...">Create API Key</.button>
              </:actions>
            </.simple_form>
          </div>

          <%= if @show_api_key do %>
            <div class="alert alert-info">
              <.icon name="hero-exclamation-triangle" class="w-6 h-6" />
              <div>
                <h3 class="font-bold">Save your API key!</h3>
                <div class="text-xs">Copy this key now. You won't be able to see it again.</div>
              </div>
            </div>

            <div class="bg-base-200 rounded-lg p-4 shadow-sm">
              <label class="label">
                <span class="label-text font-medium">API Key</span>
              </label>
              <div class="flex gap-2">
                <input
                  type="text"
                  id="api_key_display"
                  class="input input-bordered flex-1 font-mono"
                  value={@api_key_token}
                  readonly
                />
                <button
                  type="button"
                  class="btn"
                  phx-click="copy_api_key"
                  phx-value-token={@api_key_token}
                >
                  <.icon name="hero-document-duplicate" class="w-5 h-5" /> Copy
                </button>
              </div>
            </div>
          <% end %>

          <div>
            <.header>
              Existing API Keys
              <:subtitle>Manage your organization's API keys.</:subtitle>
            </.header>

            <div id="api_keys" phx-update="stream">
              <div :for={{id, api_key} <- @streams.api_keys} id={id} class="space-y-4">
                <div class="bg-base-200 rounded-lg p-4 shadow-sm">
                  <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
                    <div class="flex-1">
                      <p class="font-medium text-lg">{api_key.description}</p>
                      <p class="text-sm text-base-content/70">
                        Version: {api_key.version}
                      </p>
                      <p class="text-sm text-base-content/70">
                        Roles: {format_roles(api_key.roles)}
                      </p>
                      <p class="text-sm text-base-content/70">
                        Created: {format_date(api_key.inserted_at)}
                      </p>
                    </div>

                    <button
                      type="button"
                      class="btn btn-sm btn-error"
                      phx-click="delete"
                      phx-value-api-key-id={api_key.id}
                      phx-confirm="Are you sure you want to delete this API key? This action cannot be undone."
                    >
                      <.icon name="hero-trash" class="w-4 h-4" /> Delete
                    </button>
                  </div>
                </div>
              </div>

              <div :if={Enum.empty?(@streams.api_keys)} class="text-center py-12 text-base-content/70">
                <.icon name="hero-key" class="w-16 h-16 mx-auto mb-4 opacity-50" />
                <p class="text-lg">No API keys yet</p>
                <p class="text-sm">Create an API key to enable programmatic access</p>
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
      api_keys = Organizations.list_api_keys(organization.id)

      socket =
        socket
        |> assign(:organization, organization)
        |> stream(:api_keys, api_keys)
        |> assign(:form, to_form(%{"description" => "", "roles" => []}))
        |> assign(:role_options, [
          {"Administrator", "administrator"},
          {"Read Only", "read_only"}
        ])
        |> assign(:show_api_key, false)
        |> assign(:api_key_token, nil)

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("create", %{"description" => description, "roles" => roles}, socket) do
    organization = socket.assigns.current_organization

    # Convert roles list to array
    roles_array = if is_list(roles), do: roles, else: []

    case Organizations.create_api_key(organization, %{
           description: description,
           roles: roles_array
         }) do
      {:ok, {_api_key, token}} ->
        # Refresh the API key list
        api_keys = Organizations.list_api_keys(organization.id)

        socket =
          socket
          |> stream(:api_keys, api_keys, reset: true)
          |> put_flash(:info, "API key created successfully")
          |> assign(:show_api_key, true)
          |> assign(:api_key_token, token)
          |> assign(:form, to_form(%{"description" => "", "roles" => []}))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to create API key: #{inspect(changeset.errors)}")
          |> assign(:form, to_form(changeset))

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete", %{"api_key_id" => api_key_id}, socket) do
    organization = socket.assigns.current_organization

    with api_key when not is_nil(api_key) <- Organizations.get_api_key!(api_key_id),
         true <- api_key.organization_id == organization.id,
         {:ok, _api_key} <- Organizations.delete_api_key(api_key) do
      socket =
        socket
        |> stream_delete(:api_keys, api_key_id)
        |> put_flash(:info, "API key deleted")

      {:noreply, socket}
    else
      nil ->
        socket =
          socket
          |> put_flash(:error, "API key not found")

        {:noreply, socket}

      false ->
        socket =
          socket
          |> put_flash(:error, "You can only delete API keys from your own organization")

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to delete API key")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("copy_api_key", %{"token" => token}, socket) do
    socket =
      socket
      |> push_event("copy_to_clipboard", %{text: token})
      |> put_flash(:info, "API key copied to clipboard")

    {:noreply, socket}
  end

  defp format_roles([]), do: "No roles"
  defp format_roles(roles), do: Enum.join(roles, ", ")

  defp format_date(datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> Date.to_string()
  end
end
