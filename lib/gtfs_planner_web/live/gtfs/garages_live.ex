defmodule GtfsPlannerWeb.Gtfs.GaragesLive do
  @moduledoc """
  LiveView listing the organization's garages.

  Garages belong to the organization and ignore GTFS versions: the version in
  the URL is navigation context and selects which `stops.stop_id` values the
  conflict notice compares against. Access is authorized at mount through
  `EnsureRole`, following the other GTFS pages — there is no view-only GTFS role,
  and the context enforces tenancy on every call.

  The list is the first half of the Garages page. The add/edit drawer arrives
  with its own step, so the two actions render disabled and carry a short note
  rather than emitting events no handler owns yet.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.OperationsComponents, only: [scope_note: 1]

  alias GtfsPlanner.Operations
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Garages")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:garage_count, 0)
     |> assign(:garages_empty?, true)
     |> assign(:assigned_vehicle_count, 0)
     |> assign(:garage_conflicts, [])
     |> stream(:garages, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    garages = Operations.list_garages(organization_id)
    conflicts = Operations.garage_stop_id_conflicts(organization_id, gtfs_version_id, garages)

    {:noreply,
     socket
     |> assign(:garage_count, length(garages))
     |> assign(:garages_empty?, garages == [])
     |> assign(:assigned_vehicle_count, Enum.sum(Enum.map(garages, & &1.vehicle_count)))
     |> assign(:garage_conflicts, conflicts)
     |> stream(:garages, garages, reset: true)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/blocks/garages")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/blocks/garages")}
    else
      {:noreply, socket}
    end
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
      <.header>
        Garages
        <:subtitle>Set where your vehicles start and end the day.</:subtitle>
        <:actions>
          <.button
            id="import-tods"
            variant="secondary"
            class="min-h-11"
            disabled
            title="Not available yet"
          >
            Import from TODS file
          </.button>
          <.button
            id="add-garage"
            variant={if(@garages_empty?, do: "secondary", else: "primary")}
            class="min-h-11"
            disabled
            title="Not available yet"
          >
            Add garage
          </.button>
        </:actions>
      </.header>

      <.scope_note organization_name={@current_organization.name} class="mt-2" />

      <p id="garages-actions-note" class="mt-2 text-sm text-base-content/70">
        Adding and importing garages are not available yet.
      </p>

      <.blocks_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:garages} />

      <p :if={!@garages_empty?} id="garages-status" class="mt-3 text-sm text-base-content/70">
        {@garage_count} garages · {@assigned_vehicle_count} vehicles assigned
      </p>

      <%!-- `callout/1` spreads global attributes onto its own class, so the margin
      lives on a wrapper rather than being passed to the component. --%>
      <div :if={@garage_conflicts != []} class="mt-4">
        <.callout
          id="garage-conflicts"
          kind="warning"
          title="Garage IDs conflict with public stops"
        >
          These garage IDs match stop IDs in this version, so an operations export cannot be created.
          <ul class="mt-2 space-y-1">
            <li :for={conflict <- @garage_conflicts}>
              Garage "{conflict.garage_name}" ({conflict.garage_id}) matches the stop "{conflict.stop_name}".
            </li>
          </ul>
        </.callout>
      </div>

      <div :if={!@garages_empty?} class="mt-6">
        <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
          <.table id="garages-table" rows={@streams.garages}>
            <:col :let={{_id, garage}} label="Name">
              <span class="font-semibold">{garage.name}</span>
            </:col>
            <:col :let={{_id, garage}} label="Garage ID">
              <span class="font-mono text-sm">{garage.garage_id}</span>
            </:col>
            <:col :let={{_id, garage}} label="Location">
              <div>{garage_location(garage)}</div>
              <div :if={garage_has_address?(garage)} class="text-xs text-base-content/70">
                {garage_coordinates(garage)}
              </div>
            </:col>
            <:col :let={{_id, garage}} label="Vehicles" align="right">
              {garage.vehicle_count}
            </:col>
            <:action :let={{_id, garage}}>
              <.link
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/blocks/fleet?garage=#{garage.id}"}
                class="inline-flex min-h-11 items-center whitespace-nowrap text-sm font-medium text-primary underline"
              >
                View vehicles
              </.link>
            </:action>
          </.table>
        </div>
        <p class="mt-2 text-sm text-base-content/70">
          Garage locations help calculate travel to the first trip and back from the last trip.
        </p>
      </div>

      <.empty_state
        :if={@garages_empty?}
        id="garages-first-use-empty"
        title="Add your first garage"
        class="mt-6"
      >
        Add where your vehicles start and end the day. Garages are needed to plan travel to and from service.
        <:action>
          <.button id="add-garage-empty" class="min-h-11" disabled title="Not available yet">
            Add garage
          </.button>
        </:action>
      </.empty_state>
    </Layouts.app>
    """
  end

  defp garage_has_address?(garage), do: garage.address not in [nil, ""]

  defp garage_location(garage) do
    if garage_has_address?(garage), do: garage.address, else: garage_coordinates(garage)
  end

  defp garage_coordinates(garage) do
    "#{Decimal.to_string(garage.lat)}, #{Decimal.to_string(garage.lon)}"
  end
end
