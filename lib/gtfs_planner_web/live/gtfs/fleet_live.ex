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

  A collapsed `#vehicle-types` disclosure holds the types table and its add/edit
  drawer. A type is organization-wide and ignores versions like a vehicle; its
  optional limit is edited as hours and stored as minutes by
  `Operations.VehicleType`, and in-use deletion is refused by the database
  constraint the delete translates to a message.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.OperationsComponents, only: [scope_note: 1]

  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Versions

  @vehicle_type_form_id "vehicle-type-form"
  @vehicle_type_form_error_id "vehicle-type-form-error"

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
     |> assign(:vehicle_types_count, 0)
     |> assign(:vehicle_types_empty?, true)
     |> assign(:vehicle_types_open?, false)
     |> assign(:type_drawer_open, false)
     |> assign(:type_entity, nil)
     |> assign(:type_form, vehicle_type_form(%VehicleType{}, %{}))
     |> assign(:type_drawer_title, "Add vehicle type")
     |> assign(:type_drawer_return_focus_id, nil)
     |> assign(:type_notice, nil)
     |> assign(:type_delete_target, nil)
     |> assign(:type_in_use, nil)
     |> stream(:vehicles, [])
     |> stream(:vehicle_types, [])}
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

  # The disclosure is a native `<details>`, so the browser owns the toggle and
  # the summary click only keeps the server's `open` attribute in step. Without
  # this the rest of the page's patches would strip the attribute and collapse an
  # expanded list mid-edit.
  @impl true
  def handle_event("toggle_vehicle_types", _params, socket) do
    {:noreply, assign(socket, :vehicle_types_open?, not socket.assigns.vehicle_types_open?)}
  end

  # --- vehicle type drawer ---------------------------------------------------

  @impl true
  def handle_event("open_vehicle_type", %{"type_id" => id} = params, socket)
      when is_binary(id) and id != "" do
    case load_vehicle_type(socket, id) do
      nil ->
        {:noreply, socket}

      vehicle_type ->
        {:noreply, open_edit_vehicle_type(socket, vehicle_type, params["opener_id"])}
    end
  end

  def handle_event("open_vehicle_type", params, socket) do
    {:noreply, open_add_vehicle_type(socket, params["opener_id"])}
  end

  @impl true
  def handle_event("close_vehicle_type_drawer", _params, socket) do
    {:noreply, close_vehicle_type_drawer(socket)}
  end

  @impl true
  def handle_event("validate_vehicle_type", %{"vehicle_type" => params}, socket) do
    changeset =
      socket
      |> vehicle_type_base()
      |> Operations.change_vehicle_type(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :type_form, to_form(changeset, as: :vehicle_type))}
  end

  def handle_event("validate_vehicle_type", _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_vehicle_type", %{"vehicle_type" => params}, socket) do
    organization_id = socket.assigns.current_organization.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}

    result =
      case socket.assigns.type_entity do
        nil ->
          Operations.create_vehicle_type(organization_id, actor, params)

        vehicle_type ->
          Operations.update_vehicle_type(organization_id, actor, vehicle_type.id, params)
      end

    case result do
      {:ok, vehicle_type} ->
        {:noreply,
         socket
         |> close_vehicle_type_drawer()
         |> load_fleet()
         |> assign(:type_notice, "#{vehicle_type.name} saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:type_form, to_form(changeset, as: :vehicle_type))
         |> push_event("focus_form_error", %{
           form_id: @vehicle_type_form_id,
           fallback_id: @vehicle_type_form_error_id
         })}

      {:error, :not_found} ->
        # The type disappeared between opening the drawer and saving.
        {:noreply, socket |> close_vehicle_type_drawer() |> load_fleet()}
    end
  end

  def handle_event("save_vehicle_type", _params, socket), do: {:noreply, socket}

  # --- vehicle type deletion -------------------------------------------------

  @impl true
  def handle_event("delete_vehicle_type", %{"type_id" => id}, socket) when is_binary(id) do
    case load_vehicle_type(socket, id) do
      nil ->
        {:noreply, socket}

      %VehicleType{vehicle_count: count} = vehicle_type when count > 0 ->
        {:noreply, assign(socket, :type_in_use, vehicle_type)}

      vehicle_type ->
        {:noreply, assign(socket, :type_delete_target, vehicle_type)}
    end
  end

  def handle_event("delete_vehicle_type", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_delete_vehicle_type", _params, socket) do
    {:noreply, assign(socket, :type_delete_target, nil)}
  end

  @impl true
  def handle_event("dismiss_vehicle_type_in_use", _params, socket) do
    {:noreply, assign(socket, :type_in_use, nil)}
  end

  @impl true
  def handle_event("confirm_delete_vehicle_type", _params, socket) do
    case socket.assigns.type_delete_target do
      nil -> {:noreply, socket}
      vehicle_type -> delete_vehicle_type(socket, vehicle_type)
    end
  end

  defp delete_vehicle_type(socket, vehicle_type) do
    case Operations.delete_vehicle_type(socket.assigns.current_organization.id, vehicle_type.id) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> assign(:type_delete_target, nil)
         |> close_vehicle_type_drawer()
         |> load_fleet()
         |> assign(:type_notice, "#{deleted.name} deleted.")}

      {:error, {:in_use, vehicles: _count}} ->
        {:noreply,
         socket |> assign(:type_delete_target, nil) |> assign(:type_in_use, vehicle_type)}

      {:error, :not_found} ->
        {:noreply, socket |> assign(:type_delete_target, nil) |> load_fleet()}
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

      <p :if={@type_notice} id="vehicle-type-notice" role="status" class="mt-3 text-sm text-success">
        {@type_notice}
      </p>

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

      <%!-- Native disclosure: the reference groups type management behind a
      collapsed summary so the vehicle list keeps the page. The summary click
      only mirrors the browser's toggle state to the server, which keeps the
      attribute from being stripped by an unrelated patch. --%>
      <details
        id="vehicle-types"
        open={@vehicle_types_open?}
        class="mt-6 border-b border-base-300 pb-3"
      >
        <summary
          id="vehicle-types-summary"
          phx-click="toggle_vehicle_types"
          class="min-h-11 cursor-pointer text-base font-semibold"
        >
          Vehicle types
          <span class="text-sm font-normal text-base-content/70">
            · {@vehicle_types_count} types · Manage types and limits
          </span>
        </summary>

        <section aria-labelledby="types-title" class="mt-3">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 id="types-title" class="text-lg font-semibold">Vehicle types</h2>
              <p class="text-sm text-base-content/70">
                Group vehicles with the same operating limits.
              </p>
            </div>
            <.button
              id="add-vehicle-type"
              variant="secondary"
              class="min-h-11"
              phx-click="open_vehicle_type"
              phx-value-opener_id="add-vehicle-type"
            >
              Add type
            </.button>
          </div>

          <div
            :if={!@vehicle_types_empty?}
            class="mt-3 bg-base-100 border border-base-300 rounded-box overflow-hidden"
          >
            <.table id="vehicle-types-table" rows={@streams.vehicle_types}>
              <:col :let={{_id, vehicle_type}} label="Name">
                <button
                  id={"vehicle-type-name-#{vehicle_type.id}"}
                  type="button"
                  phx-click="open_vehicle_type"
                  phx-value-type_id={vehicle_type.id}
                  phx-value-opener_id={"vehicle-type-name-#{vehicle_type.id}"}
                  class="text-left font-semibold text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
                >
                  {vehicle_type.name}
                </button>
              </:col>
              <:col :let={{_id, vehicle_type}} label="Maximum time away from garage">
                {limit_text(vehicle_type.max_out_minutes)}
              </:col>
              <:col :let={{_id, vehicle_type}} label="Vehicles" align="right">
                {vehicle_type.vehicle_count}
              </:col>
            </.table>
          </div>

          <p
            :if={@vehicle_types_empty?}
            id="vehicle-types-empty"
            class="mt-3 text-sm text-base-content/70"
          >
            No vehicle types yet. Add a type to group similar vehicles.
          </p>
        </section>
      </details>

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

      <.vehicle_type_drawer
        open={@type_drawer_open}
        title={@type_drawer_title}
        entity={@type_entity}
        form={@type_form}
        return_focus_id={@type_drawer_return_focus_id}
      />

      <.confirm_dialog
        :if={@type_delete_target}
        id="vehicle-type-delete-confirm"
        open={true}
        title={"Delete #{@type_delete_target.name}?"}
        confirm_label="Delete type"
        pending_label="Deleting…"
        on_confirm="confirm_delete_vehicle_type"
        on_cancel="cancel_delete_vehicle_type"
        described_by="vehicle-type-delete-confirm-body"
        return_focus_id="delete-vehicle-type"
      >
        <p>This removes the type from this organization.</p>
      </.confirm_dialog>

      <.confirm_dialog
        :if={@type_in_use}
        id="vehicle-type-in-use-dialog"
        open={true}
        title="Vehicle type is in use"
        confirm_label="Delete type"
        cancel_label="Close"
        pending_label="Deleting…"
        on_confirm="dismiss_vehicle_type_in_use"
        on_cancel="dismiss_vehicle_type_in_use"
        single_action={true}
        described_by="vehicle-type-in-use-dialog-body"
        return_focus_id="delete-vehicle-type"
      >
        <p>
          {@type_in_use.vehicle_count} vehicles use {@type_in_use.name}. Set a different type for those vehicles before deleting it.
        </p>
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :open, :boolean, required: true
  attr :title, :string, required: true
  attr :entity, :any, default: nil
  attr :form, :any, required: true
  attr :return_focus_id, :string, default: nil

  defp vehicle_type_drawer(assigns) do
    assigns =
      assigns
      |> assign(:form_id, @vehicle_type_form_id)
      |> assign(:form_error_id, @vehicle_type_form_error_id)

    ~H"""
    <.drawer
      id="vehicle-type-drawer"
      open={@open}
      on_close="close_vehicle_type_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
    >
      <div id="vehicle-type-drawer-content" phx-hook="FormErrorFocus">
        <p id="vehicle-type-drawer-description" class="mb-4 text-sm text-base-content/70">
          Group vehicles that can do the same work.
        </p>

        <.form
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_vehicle_type"
          phx-submit="save_vehicle_type"
          class="space-y-1"
        >
          <div :if={save_failed?(@form)} class="mb-4">
            <.callout
              id={@form_error_id}
              kind="error"
              title="Check the highlighted fields"
              tabindex="-1"
            >
              Nothing was saved. Correct the fields marked below, then save again.
            </.callout>
          </div>

          <.input field={@form[:name]} type="text" label="Type name" />

          <.input
            field={@form[:max_out_hours]}
            type="number"
            min="1"
            max="24"
            step="0.25"
            label="Maximum time away from garage (optional)"
            class="input input-bordered min-h-11 max-w-[180px] block"
            help="Hours, from 1 to 24. Leave blank for no limit. Useful for vehicles that need to recharge or refuel."
          />

          <div :if={@entity} class="mt-4">
            <.callout
              id="vehicle-type-assigned-vehicles"
              kind={if @entity.vehicle_count > 0, do: "warning", else: "info"}
              title={"#{@entity.vehicle_count} vehicles use this type"}
            >
              {if @entity.vehicle_count > 0,
                do: "Assign them to another type before deleting it.",
                else: "This type has no assigned vehicles."}
            </.callout>
          </div>

          <div class="flex flex-wrap items-center gap-3 pt-3">
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">Save type</.button>
            <.button
              type="button"
              variant="quiet"
              class="min-h-11"
              phx-click="close_vehicle_type_drawer"
            >
              Cancel
            </.button>
            <.button
              :if={@entity}
              id="delete-vehicle-type"
              type="button"
              variant="danger"
              class="min-h-11"
              phx-click="delete_vehicle_type"
              phx-value-type_id={@entity.id}
            >
              Delete type
            </.button>
          </div>
        </.form>
      </div>
    </.drawer>
    """
  end

  # --- fleet state -----------------------------------------------------------

  defp refresh_fleet(socket, params, uri) do
    filters = filters_from_params(params)

    socket
    |> assign(:fleet_query, URI.parse(uri).query)
    |> assign(:fleet_filters, filters)
    |> assign(:filters_form, filters_form(filters))
    |> assign(:filters_active?, filters_active?(filters))
    |> load_fleet()
  end

  # Loads every list the page renders from the current filter state. Both a URL
  # change and a type mutation reuse it, so a renamed type's name also updates
  # the vehicle rows and the summary breakdown without a separate query path.
  defp load_fleet(socket) do
    organization_id = socket.assigns.current_organization.id

    vehicles =
      Operations.list_vehicles(organization_id, filter_values(socket.assigns.fleet_filters))

    summary = Operations.fleet_summary(organization_id)
    vehicle_types = Operations.list_vehicle_types(organization_id)
    garages = Operations.list_garages(organization_id)
    counts = summary_counts(summary)

    socket
    |> assign(:vehicle_type_options, vehicle_type_options(vehicle_types))
    |> assign(:garage_options, garage_options(garages))
    |> assign(:total_count, counts.total)
    |> assign(:filtered_count, length(vehicles))
    |> assign(:needs_assignment_count, counts.needs_assignment)
    |> assign(:summary_garages, summary_garages(summary))
    |> assign(:vehicles_empty?, counts.total == 0)
    |> assign(:vehicle_types_count, length(vehicle_types))
    |> assign(:vehicle_types_empty?, vehicle_types == [])
    |> stream(:vehicles, vehicles, reset: true)
    |> stream(:vehicle_types, vehicle_types, reset: true)
  end

  # Both option lists are the organization's own rows, ordered by name, so they
  # are rebuilt from the loaded rows on every refresh rather than cached across
  # a mutation. "Not assigned" is the `none` filter the context accepts, which
  # selects the rows whose garage or type is nil.
  defp vehicle_type_options(vehicle_types) do
    Enum.map(vehicle_types, &{&1.name, &1.id}) ++ [{"Not assigned", "none"}]
  end

  defp garage_options(garages) do
    Enum.map(garages, &{&1.name, &1.id}) ++ [{"Not assigned", "none"}]
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

  # --- vehicle type state ----------------------------------------------------

  defp vehicle_type_form(vehicle_type, attrs) do
    vehicle_type
    |> Operations.change_vehicle_type(attrs)
    |> to_form(as: :vehicle_type)
  end

  defp vehicle_type_base(socket), do: socket.assigns.type_entity || %VehicleType{}

  defp open_add_vehicle_type(socket, opener_id) do
    socket
    |> assign(:type_entity, nil)
    |> assign(:type_form, vehicle_type_form(%VehicleType{}, %{}))
    |> assign(:type_drawer_title, "Add vehicle type")
    |> assign(:type_drawer_return_focus_id, opener_id)
    |> assign(:type_notice, nil)
    |> assign(:type_drawer_open, true)
  end

  defp open_edit_vehicle_type(socket, vehicle_type, opener_id) do
    socket
    |> assign(:type_entity, vehicle_type)
    |> assign(:type_form, vehicle_type_form(vehicle_type, %{}))
    |> assign(:type_drawer_title, "Edit vehicle type")
    |> assign(:type_drawer_return_focus_id, opener_id)
    |> assign(:type_notice, nil)
    |> assign(:type_drawer_open, true)
  end

  defp close_vehicle_type_drawer(socket) do
    socket
    |> assign(:type_drawer_open, false)
    |> assign(:type_entity, nil)
  end

  defp load_vehicle_type(socket, id) when is_binary(id) do
    socket.assigns.current_organization.id
    |> Operations.list_vehicle_types()
    |> Enum.find(&(&1.id == id))
  end

  defp load_vehicle_type(_socket, _id), do: nil

  # Stored minutes are whole; a quarter-hour step keeps the hour value short.
  defp limit_text(nil), do: "No limit set"

  defp limit_text(minutes) when is_integer(minutes) do
    hours =
      minutes
      |> Decimal.new()
      |> Decimal.div(60)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    "#{hours} hours"
  end

  # A failed save is the only state that earns the view-level banner. Validation
  # on change marks its own fields and must not shout about a save never attempted.
  defp save_failed?(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action}, errors: errors})
       when action in [:update, :insert] and errors != [],
       do: true

  defp save_failed?(_form), do: false

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
