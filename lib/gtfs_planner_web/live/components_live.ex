defmodule GtfsPlannerWeb.ComponentsLive do
  use GtfsPlannerWeb, :live_view

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
     |> assign(:selected_result, nil)}
  end

  @impl true
  def handle_event("live_select_change", %{"text" => text, "id" => id}, socket) do
    IO.inspect(text, label: "🔍 LIVE_SELECT_CHANGE FIRED WITH TEXT")

    case Geocoding.autocomplete(text) do
      {:ok, results} ->
        IO.inspect(length(results), label: "✅ GOT RESULTS COUNT")

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

      {:error, reason} ->
        IO.inspect(reason, label: "❌ GEOCODING ERROR")
        send_update(LiveSelectComponent, id: id, options: [])
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("change", %{"address_search" => %{"address_autocomplete" => selection}}, socket)
      when is_binary(selection) and selection != "" do
    # The selection contains the formatted address
    # We need to find the corresponding result from the last search
    # Since live_select stores the full result in the tag, we'll capture it on selection
    {:noreply, socket}
  end

  def handle_event("change", _params, socket) do
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
  def handle_event("live_select_blur", _params, socket) do
    {:noreply, socket}
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
            <.form for={@form} id="address-form">
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
                  dropdown_class="bg-base-300 border border-base-content/20 shadow-lg mt-1"
                  option_class="px-4 py-2.5 border-b border-base-content/10 last:border-b-0"
                  active_option_class="bg-primary text-primary-content"
                  available_option_class="hover:bg-base-content/10 cursor-pointer transition-colors"
                  text_input_class="input input-bordered w-full"
                >
                  <:option :let={option}>
                    <div class="flex flex-col">
                      <span class="font-medium"><%= option.label %></span>
                    </div>
                  </:option>
                </.live_component>
              </div>
            </.form>

            <%= if @selected_address do %>
              <div class="mt-6 border-t border-base-300 pt-6">
                <h3 class="text-lg font-medium mb-4">Selected Location</h3>
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
      </div>
    </Layouts.app>
    """
  end
end
