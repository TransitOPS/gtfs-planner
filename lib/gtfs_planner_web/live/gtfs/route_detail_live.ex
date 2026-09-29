defmodule GtfsPlannerWeb.Gtfs.RouteDetailLive do
  @moduledoc """
  LiveView for viewing GTFS route details.
  Requires pathways_studio_editor role.

  The page reads as a summary of a route, in words: what riders see (number,
  name, mode, colors, description, web page), the agency and how riders board
  between stops, and whether the route is active. The stored GTFS values sit
  behind a disclosure, because a plain-language value such as "Only at stops"
  hides the `1` a person comparing exports still needs. Transfers sit beside the
  summary as the one related page the route has a count for.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.PlannerComponents,
    only: [aside_link: 1, back_link: 1, message: 1, safe_href: 2]

  import GtfsPlannerWeb.RouteWorkspace, only: [mode_label: 1, route_header: 1, route_label: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # GTFS `continuous_pickup` and `continuous_drop_off` values, as a sentence
  # fragment that follows "Pickup and drop-off:".
  @boarding %{
    0 => "anywhere along the route",
    1 => "only at stops",
    2 => "call the agency first",
    3 => "arrange with the driver"
  }

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Route Details")
     |> assign(:user_roles, user_roles)
     |> assign(:active_tab, :details)
     |> assign(:route_state, :loading)}
  end

  @impl true
  def handle_params(%{"route_id" => route_id} = _params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    active_tab = socket.assigns[:live_action] || :details

    socket =
      socket
      |> assign(:route_id, route_id)
      |> assign(:active_tab, active_tab)

    case Gtfs.fetch_catalog_route(organization_id, gtfs_version_id, route_id) do
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Route not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/routes")}

      {:error, :unavailable} ->
        {:noreply, assign(socket, :route_state, :unavailable)}

      {:ok, route} ->
        {:noreply,
         socket
         |> assign(:route, route)
         |> assign(:route_state, :ready)
         |> assign(:transfer_count, related_transfers(organization_id, gtfs_version_id, route))}
    end
  end

  @impl true
  def handle_event("retry", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.fetch_catalog_route(organization_id, gtfs_version_id, route_id) do
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Route not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/routes")}

      {:error, :unavailable} ->
        {:noreply, assign(socket, :route_state, :unavailable)}

      {:ok, route} ->
        {:noreply,
         socket
         |> assign(:route, route)
         |> assign(:route_state, :ready)
         |> assign(:transfer_count, related_transfers(organization_id, gtfs_version_id, route))}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    route_id = socket.assigns[:route_id]

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      path =
        if route_id,
          do: ~p"/gtfs/#{version_id}/routes/#{route_id}",
          else: "/gtfs/#{version_id}/routes"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    route_id = socket.assigns[:route_id]

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      path =
        if route_id,
          do: ~p"/gtfs/#{version_id}/routes/#{route_id}",
          else: "/gtfs/#{version_id}/routes"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  # The related-transfer count is a direct facade call, never the catalog adapter
  # (CR-15): the details page's own read may be a substituted adapter, but the
  # count is the same predicate the filtered list uses (CR-4).
  defp related_transfers(organization_id, gtfs_version_id, route) do
    Gtfs.count_general_transfers(organization_id, gtfs_version_id, route: route.route_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <div id="route-detail-page" class="ds-page">
        <%= case @route_state do %>
          <% :unavailable -> %>
            <.back_link id="route-back" navigate={~p"/gtfs/#{@current_gtfs_version.id}/routes"}>
              Routes
            </.back_link>
            <div class="mt-4 max-w-[680px]">
              <.message id="route-unavailable" kind="error" title="This route didn't load">
                The route data didn't respond, so nothing is shown. Nothing has changed.
                <:action>
                  <.button
                    id="route-retry"
                    type="button"
                    variant="secondary"
                    class="min-h-11"
                    phx-click="retry"
                    phx-disable-with="Trying again…"
                  >
                    Try again
                  </.button>
                </:action>
              </.message>
            </div>
          <% :ready -> %>
            <.route_header
              route={@route}
              gtfs_version_id={@current_gtfs_version.id}
              active_tab={@active_tab}
            />

            <div class="mt-6 grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_320px] xl:gap-8">
              <.route_summary route={@route} />

              <aside id="route-aside" aria-label="Related information" class="grid gap-4">
                <section
                  id="route-transfers"
                  aria-labelledby="route-transfers-title"
                  class="rounded-card border border-subtle bg-white p-5"
                >
                  <h2 id="route-transfers-title" class="text-base font-bold text-strong">
                    Transfers
                  </h2>
                  <p id="route-transfers-summary" class="mt-2 text-sm text-default">
                    {transfers_summary(@transfer_count, route_label(@route))}
                  </p>
                  <.aside_link
                    id="route-transfers-link"
                    navigate={
                      ~p"/gtfs/#{@current_gtfs_version.id}/transfers?#{[route: @route.route_id]}"
                    }
                  >
                    View transfers
                  </.aside_link>
                </section>
              </aside>
            </div>
          <% _ -> %>
            <p
              id="route-loading"
              role="status"
              class="inline-flex min-h-11 items-center text-sm text-muted"
            >
              Loading route…
            </p>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :route, :map, required: true

  defp route_summary(assigns) do
    {swatch_style, swatch_class} = RouteIdentity.route_colors(assigns.route)
    web_href = safe_href(:web, assigns.route.route_url)

    assigns =
      assigns
      |> assign(:swatch_style, swatch_style)
      |> assign(:swatch_class, swatch_class)
      |> assign(:web_href, web_href)
      |> assign(:valid_color?, swatch_style != nil)
      |> assign(:boarding, boarding_lines(assigns.route))
      |> assign(:gtfs_values, gtfs_values(assigns.route))

    ~H"""
    <section
      id="route-details"
      aria-labelledby="route-details-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle px-5 py-3">
        <h2 id="route-details-title" class="text-lg font-bold text-strong">Route details</h2>
        <p class="text-[13px] text-muted">What riders see, and how this route is set up.</p>
      </div>

      <.fact_group id="route-riders-see" title="What riders see">
        <.fact id="route-fact-number" label="Route number">
          <.value text={@route.route_short_name} class="tabular-nums" />
        </.fact>
        <.fact id="route-fact-name" label="Route name">
          <.value text={@route.route_long_name} />
        </.fact>
        <.fact id="route-fact-mode" label="Mode">{mode_label(@route.route_type)}</.fact>
        <.fact id="route-fact-colors" label="Colors">
          <span class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span
              aria-hidden="true"
              class={["size-5 shrink-0 rounded-badge ring-1 ring-inset ring-subtle", @swatch_class]}
              style={@swatch_style}
            >
            </span>
            <span class="font-mono">{color_text(@route.route_color)}</span>
            <span class="text-muted">background,</span>
            <span class="font-mono">{color_text(@route.route_text_color)}</span>
            <span class="text-muted">text</span>
          </span>
          <span :if={!@valid_color?} class="mt-1 block text-[13px] text-muted">
            This isn't a six-digit color, so the route shows as gray.
          </span>
        </.fact>
        <.fact id="route-fact-description" label="Description">
          <.value text={@route.route_desc} />
        </.fact>
        <.fact id="route-fact-url" label="Web page">
          <%= cond do %>
            <% @web_href -> %>
              <a
                href={@web_href}
                target="_blank"
                rel="noopener"
                class="inline-flex items-start gap-1.5 break-all font-medium text-action underline decoration-1 underline-offset-4 hover:text-action-hover"
              >
                {@route.route_url}
                <.icon name="hero-arrow-top-right-on-square" class="mt-0.5 size-4 shrink-0" />
              </a>
            <% present?(@route.route_url) -> %>
              <span class="break-all">{@route.route_url}</span>
              <span class="mt-1 block text-[13px] text-muted">
                Not a link: it doesn't start with http:// or https://.
              </span>
            <% true -> %>
              <.value text={nil} />
          <% end %>
        </.fact>
      </.fact_group>

      <.fact_group id="route-agency-boarding" title="Agency and boarding">
        <.fact id="route-fact-agency" label="Agency ID">
          <.value text={@route.agency_id} />
        </.fact>
        <.fact id="route-fact-boarding" label="Boarding between stops">
          <p :for={line <- @boarding}>{line}</p>
        </.fact>
        <.fact id="route-fact-order" label="Display order">
          <%= if is_integer(@route.route_sort_order) do %>
            <span class="tabular-nums">{@route.route_sort_order}</span>
            <span class="text-muted">· lower numbers list first in trip planners</span>
          <% else %>
            <.value text={nil} />
          <% end %>
        </.fact>
        <.fact id="route-fact-network" label="Fare network">
          <.value text={@route.network_id} />
        </.fact>
      </.fact_group>

      <.fact_group id="route-availability" title="Availability">
        <.fact id="route-fact-status" label="Status">
          <%= if @route.active do %>
            <span class="inline-flex items-center gap-2">
              <span aria-hidden="true" class="size-2 rounded-full bg-success-line"></span> Active
            </span>
          <% else %>
            <span class="inline-flex items-center gap-2 text-muted">
              <.icon name="hero-eye-slash" class="size-4" /> Inactive
            </span>
          <% end %>
        </.fact>
      </.fact_group>

      <details id="route-gtfs-values" class="group border-t border-subtle">
        <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 px-5 text-[13px] font-[650] text-default hover:text-strong [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-4 text-muted motion-safe:transition-transform group-open:rotate-90"
          /> GTFS values for this route
        </summary>
        <div class="px-5 pb-4">
          <p class="mb-2 text-[13px] text-muted">
            The values stored for this route, under the field names
            <span class="font-mono">routes.txt</span>
            uses. Useful when you compare this route with another tool.
          </p>
          <table class="w-full border-collapse text-[13px]">
            <thead>
              <tr>
                <th
                  scope="col"
                  class="border-b border-subtle py-1.5 pr-4 text-left font-[650] text-default"
                >
                  Field
                </th>
                <th
                  scope="col"
                  class="border-b border-subtle py-1.5 text-left font-[650] text-default"
                >
                  Value
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{field, value} <- @gtfs_values}>
                <th
                  scope="row"
                  class="border-b border-subtle py-1.5 pr-4 text-left align-top font-mono font-normal text-muted"
                >
                  {field}
                </th>
                <td class="border-b border-subtle py-1.5 align-top font-mono text-strong [overflow-wrap:anywhere]">
                  <%= if present?(value) do %>
                    {value}
                  <% else %>
                    <span class="font-sans text-muted">empty</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp fact_group(assigns) do
    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-title"}>
      <h3 id={"#{@id}-title"} class="px-5 pb-2 pt-5 text-sm font-bold text-strong">{@title}</h3>
      <dl class="text-sm">{render_slot(@inner_block)}</dl>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div
      id={@id}
      class="grid gap-x-6 gap-y-0.5 border-t border-subtle px-5 py-3 sm:grid-cols-[190px_minmax(0,1fr)]"
    >
      <dt class="text-muted">{@label}</dt>
      <dd class="min-w-0 break-words text-strong">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :text, :any, required: true
  attr :class, :string, default: nil

  defp value(assigns) do
    ~H"""
    <span :if={present?(@text)} class={@class}>{@text}</span>
    <span :if={!present?(@text)} class="text-muted">Not set</span>
    """
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  # A valid color reads as `#RRGGBB`; anything else is shown as stored, so a
  # person can see what the feed holds and why the route draws gray.
  defp color_text(value) do
    case RouteIdentity.normalize_hex(value) do
      {:ok, hex} -> "#" <> hex
      :error -> value
    end
  end

  defp boarding_lines(%{continuous_pickup: same, continuous_drop_off: same}),
    do: ["Pickup and drop-off: #{boarding_label(same)}"]

  defp boarding_lines(route) do
    [
      "Pickup: #{boarding_label(route.continuous_pickup)}",
      "Drop-off: #{boarding_label(route.continuous_drop_off)}"
    ]
  end

  defp boarding_label(value), do: Map.get(@boarding, value, "not set")

  defp transfers_summary(0, label), do: "No transfer rules mention #{label}."
  defp transfers_summary(1, label), do: "1 transfer rule mentions #{label}."
  defp transfers_summary(count, label), do: "#{count} transfer rules mention #{label}."

  defp gtfs_values(route) do
    [
      {"route_id", route.route_id},
      {"agency_id", route.agency_id},
      {"route_short_name", route.route_short_name},
      {"route_long_name", route.route_long_name},
      {"route_desc", route.route_desc},
      {"route_type", route.route_type},
      {"route_url", route.route_url},
      {"route_color", route.route_color},
      {"route_text_color", route.route_text_color},
      {"route_sort_order", route.route_sort_order},
      {"continuous_pickup", route.continuous_pickup},
      {"continuous_drop_off", route.continuous_drop_off},
      {"network_id", route.network_id}
    ]
    |> Enum.map(fn {field, value} -> {field, stored_text(value)} end)
  end

  defp stored_text(nil), do: nil
  defp stored_text(value) when is_binary(value), do: value
  defp stored_text(value), do: to_string(value)
end
