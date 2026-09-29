defmodule GtfsPlannerWeb.Gtfs.FlexLive do
  @moduledoc """
  The version's flex services list (AC-3).

  This is the Flex area's landing surface, and it replaces the Coming soon
  placeholder that stood here: one streamed table of the version's services with
  their hours, booking summary and readiness badge, the export-state line, the
  first-use question when the version has none, and the map card whose hook
  arrives in step 20.

  The page's data arrives in one operational read through `Gtfs.load_flex_list/2`,
  so the disconnected render shows the loading placeholder and the connected load
  resolves to `:ready` or `:unavailable`. A lost database connection is a
  retryable banner, never an empty list that reads as the version's own answer,
  and `retry` re-runs the same load.

  Access is authorized at mount through `EnsureRole`, following the other GTFS
  pages. Every read is scoped to the selected organization and version inside the
  Flex context and `Flex.Checks` (R10, INV-4); the version switch is accepted
  only for a published version of the current organization.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FlexComponents

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.FlexComponents
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Flex")
     |> assign(:flex_state, :loading)
     |> assign(:services_count, 0)
     |> assign(:include_flex, true)
     |> assign(:has_fixed_routes?, true)
     |> stream_configure(:services, dom_id: &"flex-service-#{&1.id}")
     |> stream(:services, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns.flex_state == :loading do
      send(self(), :load_flex_services)
      {:noreply, socket}
    else
      {:noreply, load_services(socket)}
    end
  end

  @impl true
  def handle_info(:load_flex_services, socket), do: {:noreply, load_services(socket)}

  @impl true
  def handle_event("retry", _params, socket) do
    send(self(), :load_flex_services)
    {:noreply, assign(socket, :flex_state, :loading)}
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/flex")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/flex")}
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
        Flex
        <:subtitle>On-demand services in {@current_gtfs_version.name}</:subtitle>
        <:actions :if={@flex_state == :ready and @services_count > 0}>
          <.button id="create-service" variant="primary" class="min-h-11">
            Create flex service
          </.button>
        </:actions>
      </.header>

      <.exports_line
        :if={@flex_state == :ready}
        include_flex={@include_flex}
        has_fixed_routes?={@has_fixed_routes?}
        version_id={@current_gtfs_version.id}
      />

      <.loading :if={@flex_state == :loading} />
      <.list_error :if={@flex_state == :unavailable} />

      <div :if={@flex_state == :ready} class="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1fr)_440px]">
        <.first_use :if={@services_count == 0} />

        <.services_table
          :if={@services_count > 0}
          rows={@streams.services}
          count={@services_count}
        />

        <.list_map_card title={FlexComponents.map_title(@services_count)} />
      </div>
    </Layouts.app>
    """
  end

  # The version's services with everything the table renders: the readiness
  # checks are run once here for every service (each against the version's other
  # services, which the overlap rule compares), and the calendars map is the one
  # `RiderText` reads.
  defp load_services(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.load_flex_list(organization_id, version_id) do
      {:ok, load} ->
        rows =
          Enum.map(load.services, fn entry ->
            FlexComponents.list_row(entry.service, entry.checks, load.calendars, version_id)
          end)

        socket
        |> assign(:flex_state, :ready)
        |> assign(:services_count, length(rows))
        |> assign(:include_flex, load.include_flex)
        |> assign(:has_fixed_routes?, load.has_fixed_routes?)
        |> stream(:services, rows, reset: true)

      {:error, :unavailable} ->
        socket
        |> assign(:flex_state, :unavailable)
        |> assign(:services_count, 0)
        |> stream(:services, [], reset: true)
    end
  end
end
