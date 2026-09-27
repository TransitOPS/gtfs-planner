defmodule GtfsPlannerWeb.Gtfs.FleetLive do
  @moduledoc """
  LiveView for the organization's fleet: the summary, the URL-backed filters and
  the bounded vehicle list.

  Vehicles belong to the organization and ignore GTFS versions: the version in
  the URL is navigation context, and a version switch keeps the active filters in
  the query string. Access is authorized at mount through `EnsureRole` like the
  other GTFS pages; the context enforces tenancy on every call.

  `type`, `garage` and `q` are the only query parameters the page acts on. `type`
  and `garage` accept a vehicle type or garage UUID, `none` for the unassigned
  rows, or nothing; any other value is ignored rather than forwarding a
  malformed or unknown UUID to the context. `q` is a literal, case-insensitive
  substring search — `Operations.list_vehicles/2` escapes `%` and `_`, so those
  characters match themselves instead of acting as SQL wildcards.

  The summary counts the whole tenant fleet, not the filtered subset:
  `Operations.fleet_summary/1` buckets by garage × type and the page derives the
  total and the number of vehicles needing a garage or type from those buckets.
  Rows stream through `#vehicles-table`, so about two thousand vehicles do not
  balloon the socket.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.OperationsComponents, only: [scope_note: 1]

  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fleet")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:fleet_query, nil)
     |> assign(:fleet_filters, empty_filters())
     |> assign(:filters_form, filters_form(empty_filters()))
     |> assign(:filters_active?, false)
     |> assign(:vehicle_type_options, [])
     |> assign(:garage_options, [])
     |> assign(:total_count, 0)
     |> assign(:filtered_count, 0)
     |> assign(:needs_assignment_count, 0)
     |> assign(:summary_garages, [])
     |> assign(:vehicles_empty?, true)
     |> stream(:vehicles, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, refresh_fleet(socket, params, uri)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query = filter_query_params(params)
    {:noreply, push_patch(socket, to: fleet_url(socket, query))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: fleet_url(socket, %{}))}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: fleet_path(version_id, socket.assigns.fleet_query))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: fleet_path(version_id, socket.assigns.fleet_query))}
    else
      {:noreply, socket}
    end
  end

  # --- rendering -------------------------------------------------------------

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
        Fleet
        <:subtitle>List your vehicles to check that a plan fits your fleet.</:subtitle>
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
            id="add-vehicles-header"
            variant={if(@vehicles_empty?, do: "secondary", else: "primary")}
            class="min-h-11"
            disabled
            title="Not available yet"
          >
            Add vehicles
          </.button>
        </:actions>
      </.header>

      <.scope_note organization_name={@current_organization.name} class="mt-2" />

      <p id="fleet-actions-note" class="mt-2 text-sm text-base-content/70">
        Adding and importing vehicles are not available yet.
      </p>

      <.blocks_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:fleet} />

      <%!-- `callout/1` spreads global attributes onto its own class, so the margin
      lives on a wrapper rather than being passed to the component. --%>
      <div :if={@needs_assignment_count > 0} class="mt-4">
        <.callout
          id="fleet-partial-warning"
          kind="warning"
          title="Some vehicles need a type or garage"
        >
          {needs_assignment_sentence(@needs_assignment_count)} Assign them so fleet checks can count them.
        </.callout>
      </div>

      <div
        :if={!@vehicles_empty?}
        id="fleet-summary"
        class="mt-6 grid grid-cols-1 gap-5 border-y border-base-300 py-4 sm:grid-cols-3"
      >
        <div
          :for={entry <- @summary_garages}
          class="sm:border-r sm:border-base-300 sm:pr-5 sm:last:border-r-0 sm:last:pr-0"
        >
          <p class="font-semibold">{entry.garage.name}</p>
          <p class="mt-1 text-sm text-base-content/70">{entry.types_text}</p>
        </div>
        <div class="sm:border-r sm:border-base-300 sm:pr-5 sm:last:border-r-0 sm:last:pr-0">
          <p class="font-semibold">{@total_count} vehicles total</p>
          <p class="mt-1 text-sm text-base-content/70">
            {@needs_assignment_count} need a garage or type
          </p>
        </div>
      </div>

      <section aria-labelledby="vehicles-title" class="mt-6">
        <h2 id="vehicles-title" class="text-lg font-semibold">
          Vehicles <span class="text-sm font-normal text-base-content/70">{@total_count}</span>
        </h2>

        <.empty_state
          :if={@vehicles_empty?}
          id="vehicles-first-use-empty"
          title="Add your first vehicles"
          class="mt-4"
        >
          Enter one vehicle or add a numbered group, such as 1201 through 1215.
          <:action>
            <.button id="add-vehicles" class="min-h-11" disabled title="Not available yet">
              Add vehicles
            </.button>
          </:action>
        </.empty_state>

        <.form
          :if={!@vehicles_empty?}
          for={@filters_form}
          id="vehicle-filters"
          phx-change="filter"
          class="mt-4 flex flex-wrap items-end gap-4"
        >
          <.input
            field={@filters_form[:q]}
            type="search"
            label="Find vehicle"
            placeholder="Number, label or plate"
            class="input input-bordered min-h-11"
            phx-debounce="300"
          />
          <.input
            field={@filters_form[:type]}
            type="select"
            label="Vehicle type"
            prompt="All types"
            options={@vehicle_type_options}
            class="select select-bordered min-h-11"
          />
          <.input
            field={@filters_form[:garage]}
            type="select"
            label="Garage"
            prompt="All garages"
            options={@garage_options}
            class="select select-bordered min-h-11"
          />
          <.button
            :if={@filters_active?}
            id="clear-filters"
            type="button"
            variant="quiet"
            class="min-h-11"
            phx-click="clear_filters"
          >
            Clear filters
          </.button>
        </.form>

        <div :if={!@vehicles_empty? && @filtered_count > 0} class="mt-2">
          <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
            <.table id="vehicles-table" rows={@streams.vehicles}>
              <:col :let={{_id, vehicle}} label="Vehicle ID">
                <span class="font-mono text-sm font-semibold">{vehicle.vehicle_id}</span>
              </:col>
              <:col :let={{_id, vehicle}} label="Label">
                <span :if={blank?(vehicle.vehicle_label)} class="text-base-content/70">—</span>
                <span :if={!blank?(vehicle.vehicle_label)}>{vehicle.vehicle_label}</span>
              </:col>
              <:col :let={{_id, vehicle}} label="Type">
                <span :if={is_nil(vehicle.vehicle_type)} class="badge badge-warning badge-sm">
                  Not assigned
                </span>
                <span :if={vehicle.vehicle_type}>{vehicle.vehicle_type.name}</span>
              </:col>
              <:col :let={{_id, vehicle}} label="Garage">
                <span :if={is_nil(vehicle.garage)} class="badge badge-warning badge-sm">
                  Not assigned
                </span>
                <span :if={vehicle.garage}>{vehicle.garage.name}</span>
              </:col>
              <:col :let={{_id, vehicle}} label="License plate">
                <span :if={blank?(vehicle.license_plate)} class="text-base-content/70">—</span>
                <span :if={!blank?(vehicle.license_plate)}>{vehicle.license_plate}</span>
              </:col>
            </.table>
          </div>
          <p id="vehicles-count" class="mt-2 text-sm text-base-content/70">
            {@filtered_count} of {@total_count} vehicles
          </p>
        </div>

        <.empty_state
          :if={!@vehicles_empty? && @filtered_count == 0}
          id="vehicles-filtered-empty"
          title="No vehicles match"
          class="mt-4"
        >
          Try another number or clear the filters.
          <:action>
            <.button
              id="clear-filters-empty"
              variant="secondary"
              class="min-h-11"
              phx-click="clear_filters"
            >
              Clear filters
            </.button>
          </:action>
        </.empty_state>
      </section>
    </Layouts.app>
    """
  end

  # --- fleet state -----------------------------------------------------------

  defp refresh_fleet(socket, params, uri) do
    organization_id = socket.assigns.current_organization.id

    filters = filters_from_params(params)
    vehicles = Operations.list_vehicles(organization_id, filter_values(filters))
    summary = Operations.fleet_summary(organization_id)
    counts = summary_counts(summary)

    socket
    |> assign(:fleet_query, URI.parse(uri).query)
    |> assign(:fleet_filters, filters)
    |> assign(:filters_form, filters_form(filters))
    |> assign(:filters_active?, filters_active?(filters))
    |> assign(:vehicle_type_options, vehicle_type_options(organization_id))
    |> assign(:garage_options, garage_options(organization_id))
    |> assign(:total_count, counts.total)
    |> assign(:filtered_count, length(vehicles))
    |> assign(:needs_assignment_count, counts.needs_assignment)
    |> assign(:summary_garages, summary_garages(summary))
    |> assign(:vehicles_empty?, counts.total == 0)
    |> stream(:vehicles, vehicles, reset: true)
  end

  # Both option lists are the organization's own rows, ordered by name, so they
  # are rebuilt from the loaded filter options on every refresh rather than
  # cached across a mutation. "Not assigned" is the `none` filter the context
  # accepts, which selects the rows whose garage or type is nil.
  defp vehicle_type_options(organization_id) do
    Enum.map(Operations.list_vehicle_types(organization_id), &{&1.name, &1.id}) ++
      [{"Not assigned", "none"}]
  end

  defp garage_options(organization_id) do
    Enum.map(Operations.list_garages(organization_id), &{&1.name, &1.id}) ++
      [{"Not assigned", "none"}]
  end

  defp empty_filters, do: %{"q" => "", "type" => "", "garage" => ""}

  defp filters_form(filters), do: to_form(filters)

  defp filters_from_params(params) do
    %{
      "q" => query_param(params["q"]),
      "type" => assignment_param(params["type"]),
      "garage" => assignment_param(params["garage"])
    }
  end

  # A blank query means "no filter"; any other text is kept verbatim, including
  # a literal `%` or `_`, which the context escapes for the substring match.
  defp query_param(value) when is_binary(value), do: value
  defp query_param(_value), do: ""

  # `none` selects the unassigned rows; a valid UUID selects one row's parent;
  # anything else is ignored so a malformed or foreign identifier never reaches
  # the context as a filter.
  defp assignment_param("none"), do: "none"

  defp assignment_param(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> ""
    end
  end

  defp assignment_param(_value), do: ""

  defp filter_values(filters) do
    %{
      type: assignment_value(filters["type"]),
      garage: assignment_value(filters["garage"]),
      q: present(filters["q"])
    }
  end

  defp assignment_value("none"), do: :none
  defp assignment_value(""), do: nil
  defp assignment_value(value), do: value

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp filters_active?(filters) do
    Enum.any?(~w(type garage), &(filters[&1] != "")) or present(filters["q"]) != nil
  end

  defp filter_query_params(params) do
    %{}
    |> put_present("q", params["q"])
    |> put_present("type", params["type"])
    |> put_present("garage", params["garage"])
  end

  defp put_present(query, _key, value) when value in [nil, ""], do: query
  defp put_present(query, key, value) when is_binary(value), do: Map.put(query, key, value)
  defp put_present(query, _key, _value), do: query

  defp fleet_url(socket, query) do
    case URI.encode_query(query) do
      "" -> fleet_path(socket.assigns.current_gtfs_version.id, nil)
      encoded -> fleet_path(socket.assigns.current_gtfs_version.id, encoded)
    end
  end

  # --- summary ---------------------------------------------------------------

  defp summary_counts(summary) do
    %{
      total: Enum.sum(Enum.map(summary, & &1.count)),
      needs_assignment:
        summary
        |> Enum.filter(&(is_nil(&1.garage) or is_nil(&1.vehicle_type)))
        |> Enum.map(& &1.count)
        |> Enum.sum()
    }
  end

  # Buckets arrive ordered by garage then type (unassigned last), so consecutive
  # buckets share a garage. The unassigned-garage buckets have no cell of their
  # own: those vehicles appear in the total and in the "need a garage or type"
  # figure instead.
  defp summary_garages(summary) do
    summary
    |> Enum.reject(&is_nil(&1.garage))
    |> Enum.chunk_by(& &1.garage.id)
    |> Enum.map(fn [first | _] = buckets ->
      %{garage: first.garage, types_text: types_text(buckets)}
    end)
  end

  defp types_text(buckets) do
    case Enum.map_join(buckets, " · ", fn bucket ->
           "#{bucket.count} #{vehicle_type_name(bucket.vehicle_type)}"
         end) do
      "" -> "No vehicles assigned"
      text -> text
    end
  end

  defp vehicle_type_name(%VehicleType{name: name}), do: name
  defp vehicle_type_name(nil), do: "No type"

  defp needs_assignment_sentence(1), do: "1 vehicle needs a type or garage."
  defp needs_assignment_sentence(count), do: "#{count} vehicles need a type or garage."

  defp blank?(value), do: value in [nil, ""]

  # The Fleet query string carries its filters, so a version switch keeps it in
  # the URL instead of dropping the operator's current view.
  defp fleet_path(version_id, query) when query in [nil, ""] do
    "/gtfs/#{version_id}/blocks/fleet"
  end

  defp fleet_path(version_id, query) do
    "/gtfs/#{version_id}/blocks/fleet?#{query}"
  end
end
