defmodule GtfsPlannerWeb.ComponentsLive do
  use GtfsPlannerWeb, :live_view

  require Logger

  alias GtfsPlanner.Geocoding
  alias LiveSelect.Component, as: LiveSelectComponent

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"address_autocomplete" => ""}, as: :address_search)

    {:ok,
     socket
     |> assign(:page_title, "UI Components")
     |> assign(:form, form)
     |> assign(:selected_address, nil)
     |> assign(:selected_lat, nil)
     |> assign(:selected_lon, nil)
     |> assign(:selected_result, nil)
     |> assign(:saved_locations, [])
     |> assign(:last_results, [])}
  end

  @impl true
  def handle_event("live_select_change", %{"text" => text, "id" => id}, socket) do
    Logger.debug("Autocomplete search initiated for field: #{id}")

    case Geocoding.autocomplete(text) do
      {:ok, results} ->
        Logger.debug("Autocomplete returned #{length(results)} results")

        options =
          Enum.map(results, fn result ->
            %{
              label: result.formatted_address,
              value: result.formatted_address,
              tag: result,
              option: result.formatted_address
            }
          end)

        send_update(LiveSelectComponent, id: id, options: options)

        # Store results for later matching
        {:noreply, assign(socket, :last_results, results)}

      {:error, reason} ->
        Logger.error("Geocoding autocomplete failed: #{inspect(reason)}")
        send_update(LiveSelectComponent, id: id, options: [])
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "change",
        %{"address_search" => %{"address_autocomplete" => selection}},
        socket
      )
      when is_binary(selection) and selection != "" do
    Logger.debug("Address selection change event received for address_autocomplete field")

    # Match selection against last results
    result = Enum.find(socket.assigns.last_results, fn r -> r.formatted_address == selection end)

    socket =
      case result do
        nil ->
          socket

        result ->
          socket
          |> assign(:selected_address, result.formatted_address)
          |> assign(:selected_lat, result.lat)
          |> assign(:selected_lon, result.lon)
          |> assign(:selected_result, result)
      end

    {:noreply, socket}
  end

  def handle_event("change", _params, socket) do
    Logger.debug("Address form change event (no selection)")
    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "live_select_change",
        %{"text" => _text, "id" => _id, "field" => _field, selection: selection},
        socket
      ) do
    # This handles the selection event when user picks an option
    case selection do
      %{tag: result} when is_map(result) ->
        socket =
          socket
          |> assign(:selected_address, result.formatted_address)
          |> assign(:selected_lat, result.lat)
          |> assign(:selected_lon, result.lon)
          |> assign(:selected_result, result)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "address-form",
        %{"address_search" => %{"address_autocomplete" => selection}},
        socket
      ) do
    Logger.debug("Address form submitted for address_autocomplete field")

    # Match selection against last results
    result = Enum.find(socket.assigns.last_results, fn r -> r.formatted_address == selection end)

    socket =
      case result do
        nil ->
          Logger.debug("No matching address found in #{length(socket.assigns.last_results)} cached results")
          socket

        result ->
          Logger.debug("Address matched successfully from #{length(socket.assigns.last_results)} cached results")

          socket
          |> assign(:selected_address, result.formatted_address)
          |> assign(:selected_lat, result.lat)
          |> assign(:selected_lon, result.lon)
          |> assign(:selected_result, result)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("live_select_blur", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_location", _params, socket) do
    case socket.assigns.selected_result do
      nil ->
        {:noreply, socket}

      result ->
        saved_locations = [result | socket.assigns.saved_locations]
        {:noreply, assign(socket, :saved_locations, saved_locations)}
    end
  end

  @impl true
  def handle_event("delete_location", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    saved_locations = List.delete_at(socket.assigns.saved_locations, index)
    {:noreply, assign(socket, :saved_locations, saved_locations)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={[]}
    >
      <div class="max-w-4xl mx-auto">
        <h1 class="text-2xl font-bold mb-6">UI Components Demo</h1>

        <section class="mb-8">
          <h2 class="text-xl font-semibold mb-4">Address Autocomplete</h2>

          <div class="bg-base-100 border border-base-300 rounded-lg p-6">
            <.form for={@form} id="address-form" phx-change="address-form">
              <div class="mb-4">
                <label for="address_autocomplete" class="block text-sm font-medium mb-2">
                  Search Address
                </label>
                <.live_component
                  module={LiveSelect.Component}
                  id="address_autocomplete"
                  field={@form[:address_autocomplete]}
                  options={[]}
                  debounce={300}
                  placeholder="Type at least 3 characters..."
                  update_min_len={3}
                  dropdown_class="bg-base-300 border border-base-content/20 shadow-lg mt-1 text-base-content"
                  option_class="px-4 py-2.5 border-b border-base-content/10 last:border-b-0 text-base-content"
                  active_option_class="bg-primary text-primary-content"
                  available_option_class="hover:bg-base-content/10 cursor-pointer transition-colors"
                  text_input_class="input input-bordered w-full live-select-input"
                >
                  <:option :let={option}>
                    <div class="flex flex-col">
                      <span class="font-medium">{option.label}</span>
                    </div>
                  </:option>
                </.live_component>

                <%= if @selected_lat && @selected_lon do %>
                  <div class="mt-2 border border-base-content/20 bg-base-200/50 px-3 py-2">
                    <div class="grid grid-cols-2 gap-4 text-sm">
                      <div>
                        <span class="text-base-content/70">Lat</span>
                        <span class="ml-2 font-mono text-white">{@selected_lat}</span>
                      </div>
                      <div>
                        <span class="text-base-content/70">Lon</span>
                        <span class="ml-2 font-mono text-white">{@selected_lon}</span>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </.form>

            <%= if @selected_address do %>
              <div class="mt-6 border-t border-base-300 pt-6">
                <div class="flex justify-between items-center mb-4">
                  <h3 class="text-lg font-medium">Selected Location</h3>
                  <button
                    type="button"
                    phx-click="save_location"
                    class="btn btn-primary btn-sm"
                  >
                    Save Location
                  </button>
                </div>
                <dl class="divide-y divide-base-300">
                  <div class="py-3 grid grid-cols-3 gap-4">
                    <dt class="text-sm font-medium text-base-content/70">Address</dt>
                    <dd class="text-sm col-span-2">{@selected_address}</dd>
                  </div>
                  <div class="py-3 grid grid-cols-3 gap-4">
                    <dt class="text-sm font-medium text-base-content/70">Latitude</dt>
                    <dd class="text-sm col-span-2">{@selected_lat}</dd>
                  </div>
                  <div class="py-3 grid grid-cols-3 gap-4">
                    <dt class="text-sm font-medium text-base-content/70">Longitude</dt>
                    <dd class="text-sm col-span-2">{@selected_lon}</dd>
                  </div>
                  <%= if @selected_result.city do %>
                    <div class="py-3 grid grid-cols-3 gap-4">
                      <dt class="text-sm font-medium text-base-content/70">City</dt>
                      <dd class="text-sm col-span-2">{@selected_result.city}</dd>
                    </div>
                  <% end %>
                  <%= if @selected_result.state do %>
                    <div class="py-3 grid grid-cols-3 gap-4">
                      <dt class="text-sm font-medium text-base-content/70">State</dt>
                      <dd class="text-sm col-span-2">{@selected_result.state}</dd>
                    </div>
                  <% end %>
                  <%= if @selected_result.country do %>
                    <div class="py-3 grid grid-cols-3 gap-4">
                      <dt class="text-sm font-medium text-base-content/70">Country</dt>
                      <dd class="text-sm col-span-2">{@selected_result.country}</dd>
                    </div>
                  <% end %>
                </dl>
              </div>
            <% end %>
          </div>
        </section>

        <%= if @saved_locations != [] do %>
          <section class="mb-8">
            <h2 class="text-xl font-semibold mb-4">Saved Locations</h2>

            <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
              <table class="table w-full">
                <thead class="bg-base-200">
                  <tr>
                    <th class="border-b border-base-300">Address</th>
                    <th class="border-b border-base-300">Latitude</th>
                    <th class="border-b border-base-300">Longitude</th>
                    <th class="border-b border-base-300">City</th>
                    <th class="border-b border-base-300">State</th>
                    <th class="border-b border-base-300">Country</th>
                    <th class="border-b border-base-300"><span class="sr-only">Actions</span></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for {location, index} <- Enum.with_index(@saved_locations) do %>
                    <tr class="border-b border-base-300 last:border-b-0">
                      <td class="py-3">{location.formatted_address}</td>
                      <td class="py-3 font-mono text-sm">{location.lat}</td>
                      <td class="py-3 font-mono text-sm">{location.lon}</td>
                      <td class="py-3">{location.city || "—"}</td>
                      <td class="py-3">{location.state || "—"}</td>
                      <td class="py-3">{location.country || "—"}</td>
                      <td class="py-3">
                        <button
                          type="button"
                          phx-click="delete_location"
                          phx-value-index={index}
                          class="btn btn-ghost btn-sm text-error"
                          aria-label={"Delete location: " <> location.formatted_address}
                        >
                          Delete
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
